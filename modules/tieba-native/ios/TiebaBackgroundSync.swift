import BackgroundTasks
import Foundation
import os

/// BGTask 调度器单例：expirationHandler（系统队列）与 Task 工作体（协作池）
/// 按设计并发，finish 由 TaskCompletionFlag 的锁保证 setTaskCompleted 恰好
/// 一次。Swift 6 下以 @unchecked Sendable 声明该不变量。
///
/// 实现按职责拆文件：本地状态/JSON 辅助见 TiebaBackgroundSync+State.swift，
/// 通知轮询见 +Notifications.swift，自动签到与签到提醒见 +AutoSign.swift；
/// 存储属性（extension 不能新增）与共享键名留在本文件。
final class TiebaBackgroundSync: @unchecked Sendable {
  static let shared = TiebaBackgroundSync()
  static let notificationTaskIdentifier = "com.tiebalite.app.notification-sync"
  static let autoSignTaskIdentifier = "com.tiebalite.app.auto-sign"

  /// 关键错误点日志（注册失败/任务失败等，非同帧级日志，不会刷屏）。
  /// internal 而非 private：+Notifications/+AutoSign 是跨文件 extension，
  /// private 在 Swift 里是文件级可见，扩展读不到（编译期报 inaccessible）。
  static let log = Logger(
    subsystem: "com.tiebalite.app",
    category: "background-sync"
  )

  /// 跨文件 extension 读写（+State/+Notifications/+AutoSign），故为 internal。
  let defaults = UserDefaults.standard
  /// 时间常量：自动签到的"明天此刻"兜底用。
  static let oneDay: TimeInterval = 24 * 60 * 60
  private let intervalKey = "tiebalite.native.notification_interval_minutes"
  private let autoSignTimeKey = "tiebalite.native.auto_sign_time"
  private let autoSignSuccessPrefixKey = "tiebalite.native.auto_sign_success"
  private let autoSignSummaryPrefixKey = "tiebalite.native.auto_sign_summary"

  // 键名构造被跨文件 extension 共用（+State/+Notifications/+AutoSign），故放宽
  // 为 internal；前缀键本身仍 private。
  func lastCountsKey(_ uid: String) -> String {
    return "tiebalite.native.last_counts.\(uid)"
  }

  func autoSignSuccessKey(_ uid: String) -> String {
    return "\(autoSignSuccessPrefixKey).\(uid)"
  }

  func autoSignSummaryKey(_ uid: String) -> String {
    return "\(autoSignSummaryPrefixKey).\(uid)"
  }

  func registerNotificationPoll(minutes: Double) throws {
    // BGTaskScheduler 仅真机可用：模拟器上访问即抛 "not available on this
    // platform"（每次启动红屏，2026-09-09 模拟器实测）。模拟器静默跳过——
    // 后台调度本就是真机能力，JS 侧注册语义保持成功。
    #if targetEnvironment(simulator)
    return
    #endif
    defaults.set(minutes, forKey: intervalKey)
    let request = BGAppRefreshTaskRequest(identifier: Self.notificationTaskIdentifier)
    request.earliestBeginDate = Date(timeIntervalSinceNow: minutes * 60)
    // 如实上抛 + 日志化：系统只允许 ~10 个挂起 BGTask，超出时 submit 抛错，
    // 旧实现 try? 吞掉后 JS 侧无声无息（后台提醒悄悄失效）。
    do {
      try BGTaskScheduler.shared.submit(request)
    } catch {
      Self.log.error("registerNotificationPoll submit failed: \(error.localizedDescription, privacy: .public)")
      throw error
    }
  }

  func registerAutoSign(hour: Int, minute: Int) throws {
    // 模拟器守卫：同 registerNotificationPoll（BGTaskScheduler 真机专属）。
    #if targetEnvironment(simulator)
    return
    #endif
    defaults.set("\(hour):\(minute)", forKey: autoSignTimeKey)
    let request = BGProcessingTaskRequest(identifier: Self.autoSignTaskIdentifier)
    request.requiresNetworkConnectivity = true
    request.earliestBeginDate = nextAutoSignDate(hour: hour, minute: minute)
    do {
      try BGTaskScheduler.shared.submit(request)
    } catch {
      Self.log.error("registerAutoSign submit failed: \(error.localizedDescription, privacy: .public)")
      throw error
    }
  }

  func cancelAutoSign() {
    #if targetEnvironment(simulator)
    return
    #endif
    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.autoSignTaskIdentifier)
    defaults.removeObject(forKey: autoSignTimeKey)
  }

  func cancelNotificationSync() {
    #if targetEnvironment(simulator)
    return
    #endif
    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.notificationTaskIdentifier)
    defaults.removeObject(forKey: intervalKey)
  }

  func cancelAll() {
    BGTaskScheduler.shared.cancelAllTaskRequests()
    defaults.removeObject(forKey: intervalKey)
    defaults.removeObject(forKey: autoSignTimeKey)
    cancelSignReminder()
  }

  func isAutoSignRegistered() -> Bool {
    return defaults.object(forKey: autoSignTimeKey) != nil
  }

  func handle(_ task: BGTask) {
    let completion = TaskCompletionFlag()
    task.expirationHandler = {
      self.finish(task, completion: completion, success: false)
    }
    Task {
      do {
        TiebaBackgroundSnapshot.shared.load()
        if task.identifier == Self.notificationTaskIdentifier {
          try await performNotificationSync()
        } else if task.identifier == Self.autoSignTaskIdentifier {
          try await performAutoSign()
        }
        reschedule(for: task)
        finish(task, completion: completion, success: true)
      } catch {
        Self.log.error("background task \(task.identifier, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        reschedule(for: task)
        finish(task, completion: completion, success: false)
      }
    }
  }

  private func reschedule(for task: BGTask) {
    if task.identifier == Self.notificationTaskIdentifier {
      rescheduleNotificationPoll()
    } else if task.identifier == Self.autoSignTaskIdentifier {
      rescheduleAutoSign()
    }
  }

  /// BGTask 的一次性完成标志。expirationHandler（系统队列）与工作体（协作
  /// 线程池）可能并发调用 finish：用锁保护"恰好一次 setTaskCompleted"
  /// （重复调用会 abort 进程）。用引用类型而不是 `inout` 捕获局部变量——
  /// 后者要求对捕获变量独占访问贯穿整个调用，两线程并发进入时 Swift 独占性
  /// 检查会直接 trap（release 下为未定义行为），锁挡不住。
  private final class TaskCompletionFlag {
    private var done = false
    private let lock = NSLock()

    /// 第一次调用返回 true（应当调用 setTaskCompleted），此后恒为 false。
    func take() -> Bool {
      lock.lock()
      defer { lock.unlock() }
      guard !done else { return false }
      done = true
      return true
    }
  }

  private func finish(_ task: BGTask, completion: TaskCompletionFlag, success: Bool) {
    guard completion.take() else { return }
    task.setTaskCompleted(success: success)
  }

  private func rescheduleNotificationPoll() {
    let minutes = defaults.double(forKey: intervalKey)
    guard minutes > 0 else { return }
    do {
      try registerNotificationPoll(minutes: minutes)
    } catch {
      // 吞掉会让"后台提醒失效"无声无息（旧实现 try? 的教训，见注册路径注释）。
      Self.log.error("reschedule notification poll failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  private func rescheduleAutoSign() {
    guard let raw = defaults.string(forKey: autoSignTimeKey) else { return }
    let parts = raw.split(separator: ":").compactMap { Int($0) }
    guard parts.count == 2 else { return }
    do {
      try registerAutoSign(hour: parts[0], minute: parts[1])
    } catch {
      Self.log.error("reschedule auto sign failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  private func nextAutoSignDate(hour: Int, minute: Int) -> Date {
    let calendar = Calendar.current
    var components = calendar.dateComponents([.year, .month, .day], from: Date())
    components.hour = hour
    components.minute = minute
    // 取不到今天的候选（日历异常）时退化为"明天此刻"。
    guard let candidate = calendar.date(from: components) else {
      return Date(timeIntervalSinceNow: Self.oneDay)
    }
    return candidate > Date() ? candidate : calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
  }
}
