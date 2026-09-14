import ActivityKit
import Foundation

/// start 的完整载荷投影：模块侧 AsyncFunction 收到的是自由字典 [String: Any]
/// （非 Sendable），而管理器在主 actor——跨域前先在调用队列把字典归一成值类型，
/// 字典一个字段都不进主 actor（否则 Swift 6 判 sending 'state'）。
struct TiebaLiveActivityPayload: Sendable {
  let name: String
  let extra: [String: String]?
  let state: LiveActivityKitAttributes.ContentState

  init(raw: [String: Any]) {
    self.name = raw["name"] as? String ?? "TiebaLiteSign"
    self.extra = raw["extra"] as? [String: String]
    self.state = LiveActivityKitAttributes.ContentState(raw: raw)
  }
}

/// ActivityKit 句柄的 Sendable 包装。@unchecked 的不变量：Activity 是系统活动的
/// 只读句柄（attributes/id 是 let，activityState 由系统维护且只有 getter），
/// 而它自己的 update/end/request 全部声明为 nonisolated async——框架契约就是可
/// 从任意隔离域调用；SDK 只是还没跟上 Swift 6 的 Sendable 标注。本包装只在
/// @MainActor 的 TiebaLiveActivityManager 内读写缓存，唯一"送出"的去处就是这些
/// nonisolated API，所以这条断言被刻意收窄在管理器内部，不外泄给调用方。
private struct TiebaLiveActivityHandle: @unchecked Sendable {
  let activity: Activity<LiveActivityKitAttributes>
}

@MainActor
final class TiebaLiveActivityManager {
  static let shared = TiebaLiveActivityManager()

  private var activities: [String: TiebaLiveActivityHandle] = [:]

  private init() {}

  nonisolated static func areActivitiesEnabled() -> Bool {
    ActivityAuthorizationInfo().areActivitiesEnabled
  }

  func start(payload: TiebaLiveActivityPayload) throws -> String {
    guard ActivityAuthorizationInfo().areActivitiesEnabled else {
      throw TiebaLiveActivityError.disabled
    }
    let attributes = LiveActivityKitAttributes(name: payload.name, extra: payload.extra)
    let content = ActivityContent(
      state: payload.state,
      staleDate: nil,
      relevanceScore: 0
    )
    let activity = try Activity<LiveActivityKitAttributes>.request(
      attributes: attributes,
      content: content,
      pushType: nil
    )
    activities[activity.id] = TiebaLiveActivityHandle(activity: activity)
    return activity.id
  }

  func update(activityId: String, state: LiveActivityKitAttributes.ContentState) async {
    // 缓存未命中时回落系统活动列表（对齐 endAll 的遍历写法）：app 重启后
    // 内存缓存为空，但系统里可能仍有该活动（如签到 Live Activity 存续期间
    // 杀进程再开），命中后补入缓存，后续 update/end 直接走缓存。
    guard let handle = cachedOrLiveActivity(activityId) else { return }
    let content = ActivityContent(
      state: state,
      staleDate: nil,
      relevanceScore: 0
    )
    await handle.activity.update(content, alertConfiguration: nil)
  }

  func end(activityId: String, state: LiveActivityKitAttributes.ContentState, dismissalPolicy: String) async {
    guard let handle = cachedOrLiveActivity(activityId) else { return }
    let content = ActivityContent(
      state: state,
      staleDate: nil,
      relevanceScore: 0
    )
    await handle.activity.end(content, dismissalPolicy: Self.endPolicy(dismissalPolicy))
    activities.removeValue(forKey: activityId)
  }

  /// 缓存优先，未命中则从系统活动列表找回并补入缓存；两端都没有才返回 nil。
  private func cachedOrLiveActivity(_ activityId: String) -> TiebaLiveActivityHandle? {
    if let cached = activities[activityId] {
      // 用户在锁屏上划掉、或活动已结束：内存里的对象已失效，剪掉再走系统列表。
      // 改前这种条目会一直留在缓存里（虽然量很小，但没有理由留着）。
      if cached.activity.activityState == .dismissed || cached.activity.activityState == .ended {
        activities.removeValue(forKey: activityId)
      } else {
        return cached
      }
    }
    guard let live = Activity<LiveActivityKitAttributes>.activities.first(where: { $0.id == activityId }) else {
      return nil
    }
    let handle = TiebaLiveActivityHandle(activity: live)
    activities[activityId] = handle
    return handle
  }

  /// 结束「签到」类中断残留的活动（切换展示位 / 上次中途退出）：文案与旧页
  /// 的「签到已中断」一致，immediate = 立刻从锁屏与通知中心撤掉。
  func endAllInterrupted() async {
    let state: [String: Any] = [
      "title": "签到已中断", "subtitle": "签到进程已停止", "status": "中断", "pill": "中断",
      "progress": 0.0, "imageName": "xmark.circle.fill",
      "tintColorHex": "#3B82F6", "accent": "#FF6B5E",
    ]
    await endAll(
      state: LiveActivityKitAttributes.ContentState(raw: state),
      dismissalPolicy: "immediate"
    )
  }

  func endAll(state: LiveActivityKitAttributes.ContentState, dismissalPolicy: String) async {
    let content = ActivityContent(
      state: state,
      staleDate: nil,
      relevanceScore: 0
    )
    let policy = Self.endPolicy(dismissalPolicy)
    // Activity.activities 的返回值来自 nonisolated 静态属性、不与主 actor 状态相连，
    // 可以直接送进 nonisolated 的 end（内容本身已因 Sendable 而合法）。
    for activity in Activity<LiveActivityKitAttributes>.activities {
      await activity.end(content, dismissalPolicy: policy)
    }
    activities.removeAll()
  }

  private static func endPolicy(_ raw: String) -> ActivityUIDismissalPolicy {
    raw == "immediate" ? .immediate : .default
  }
}

enum TiebaLiveActivityError: LocalizedError {
  case disabled

  var errorDescription: String? {
    switch self {
    case .disabled:
      return "Live Activities are not enabled for this app."
    }
  }
}
