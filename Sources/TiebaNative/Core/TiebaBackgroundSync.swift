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
    // 模拟器守卫：同注册路径（BGTaskScheduler 真机专属，模拟器上访问即抛错）。
    #if !targetEnvironment(simulator)
    // 只取消本模块登记的两个 identifier：cancelAllTaskRequests() 会把其它子系统
    // （expo-* 扩展等）登记的请求一并清掉，"清除全部数据"不该越界动它们。
    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.notificationTaskIdentifier)
    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.autoSignTaskIdentifier)
    #endif
    defaults.removeObject(forKey: intervalKey)
    defaults.removeObject(forKey: autoSignTimeKey)
    cancelSignReminder()
  }

  func isAutoSignRegistered() -> Bool {
    return defaults.object(forKey: autoSignTimeKey) != nil
  }

  func handle(_ task: BGTask) {
    // BGTask 是系统对象、非 Sendable，而工作体闭包是 @escaping @Sendable
    // （Task 会跑在协作线程池）。所以闭包不直接捕获 task：先装进
    // BackgroundTaskHandle（见该类的访问纪律），闭包只捕获这个 Sendable 句柄
    // 与锁保护的 TaskCompletionFlag——这两样才是允许跨线程共享的类型。
    let taskHandle = BackgroundTaskHandle(task)
    let completion = TaskCompletionFlag()
    let work = WorkTaskHolder()
    task.expirationHandler = {
      // 到期不只是上报完成：还要取消在飞工作。改前只标记完成，URLSession 请求
      // 仍会跑到自身超时（15s/25s）才结束——系统已判该任务结束，这段时间的
      // 联网与解码是纯粹的浪费（射频/CPU/发热）。
      work.cancel()
      self.finish(taskHandle, completion: completion, success: false)
    }
    // ⚠️ 闭包内必须显式 self.（2026-09-12 补）：work.run 的闭包是
    // @escaping @Sendable，Swift 要求显式捕获语义；漏写会编译失败。
    work.run {
      do {
        TiebaBackgroundSnapshot.shared.load()
        if taskHandle.identifier == Self.notificationTaskIdentifier {
          try await self.performNotificationSync()
        } else if taskHandle.identifier == Self.autoSignTaskIdentifier {
          try await self.performAutoSign()
        }
        self.reschedule(forIdentifier: taskHandle.identifier)
        self.finish(taskHandle, completion: completion, success: true)
      } catch {
        Self.log.error("background task \(taskHandle.identifier, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        self.reschedule(forIdentifier: taskHandle.identifier)
        self.finish(taskHandle, completion: completion, success: false)
      }
    }
  }

  /// 按 identifier 重排下一次调度。BGTask 本体不进 @Sendable 工作体
  ///（见 BackgroundTaskHandle）：identifier 是它唯一被读的属性。
  private func reschedule(forIdentifier identifier: String) {
    if identifier == Self.notificationTaskIdentifier {
      rescheduleNotificationPoll()
    } else if identifier == Self.autoSignTaskIdentifier {
      rescheduleAutoSign()
    }
  }

  /// BGTask 的 Sendable 句柄：BGTask 本身非 Sendable，本模块对它只有两种
  /// 操作，边界明确——
  ///   1. identifier 只读：BGTask 创建后 identifier 不再变化；
  ///   2. complete(_:)：setTaskCompleted 只上报完成，由 TaskCompletionFlag
  ///      保证恰好一次（重复调用会 abort 进程），故不存在两线程并发写。
  /// expirationHandler 的赋值发生在 expirationHandler/工作体两条路径启动之前
  ///（handle 内，同一线程完成），此后无人再写 BGTask 的任何属性。
  /// @unchecked Sendable 声明的就是这套"手动同步 + 只读共享"的访问纪律；
  /// 除纪律覆盖的部分外本类没有共享可变状态，不是拿它压编译错误。
  private final class BackgroundTaskHandle: @unchecked Sendable {
    private let task: BGTask

    init(_ task: BGTask) {
      self.task = task
    }

    var identifier: String { task.identifier }

    func complete(_ success: Bool) {
      task.setTaskCompleted(success: success)
    }
  }

  /// BGTask 的一次性完成标志。expirationHandler（系统队列）与工作体（协作
  /// 线程池）可能并发调用 finish：用锁保护"恰好一次 setTaskCompleted"
  /// （重复调用会 abort 进程）。用引用类型而不是 `inout` 捕获局部变量——
  /// 后者要求对捕获变量独占访问贯穿整个调用，两线程并发进入时 Swift 独占性
  /// 检查会直接 trap（release 下为未定义行为），锁挡不住。
  ///
  /// @unchecked Sendable：本类就是一个"锁保护的盒子"，done 的读写全部在
  /// lock 内（take() 是唯一入口），被 expirationHandler 与工作体两个并发
  /// 上下文共享正是它的设计目标——Swift 6 下必须把这条不变量写进类型。
  private final class TaskCompletionFlag: @unchecked Sendable {
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

  private func finish(_ task: BackgroundTaskHandle, completion: TaskCompletionFlag, success: Bool) {
    guard completion.take() else { return }
    task.complete(success)
  }

  /// 后台任务工作体句柄：expirationHandler（系统队列）与工作体的创建可能交错，
  /// 到期甚至可能早于"任务入箱"，所以取消标记与任务引用都在锁内维护——晚到的
  /// 任务会立刻被取消，不会留下一个没人取消的在飞请求。
  private final class WorkTaskHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var cancelled = false

    func run(_ body: @escaping @Sendable () async -> Void) {
      let job = Task { await body() }
      lock.lock()
      if cancelled {
        lock.unlock()
        job.cancel()
        return
      }
      task = job
      lock.unlock()
    }

    func cancel() {
      lock.lock()
      cancelled = true
      let job = task
      lock.unlock()
      job?.cancel()
    }
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
