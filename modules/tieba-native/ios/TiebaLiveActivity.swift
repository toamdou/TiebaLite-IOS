import ActivityKit
import ExpoModulesCore
import Foundation

@available(iOS 16.2, *)
@MainActor
final class TiebaLiveActivityManager {
  static let shared = TiebaLiveActivityManager()

  private var activities: [String: Activity<LiveActivityKitAttributes>] = [:]

  private init() {}

  nonisolated static func areActivitiesEnabled() -> Bool {
    ActivityAuthorizationInfo().areActivitiesEnabled
  }

  func start(state: [String: Any]) throws -> String {
    guard ActivityAuthorizationInfo().areActivitiesEnabled else {
      throw TiebaLiveActivityError.disabled
    }
    let attributes = LiveActivityKitAttributes(
      name: state["name"] as? String ?? "TiebaLiteSign",
      extra: state["extra"] as? [String: String]
    )
    let content = ActivityContent(
      state: Self.makeState(state),
      staleDate: nil,
      relevanceScore: 0
    )
    let activity = try Activity<LiveActivityKitAttributes>.request(
      attributes: attributes,
      content: content,
      pushType: nil
    )
    activities[activity.id] = activity
    return activity.id
  }

  func update(activityId: String, state: [String: Any]) async {
    // 缓存未命中时回落系统活动列表（对齐 endAll 的遍历写法）：app 重启后
    // 内存缓存为空，但系统里可能仍有该活动（如签到 Live Activity 存续期间
    // 杀进程再开），命中后补入缓存，后续 update/end 直接走缓存。
    guard let activity = cachedOrLiveActivity(activityId) else { return }
    let content = ActivityContent(
      state: Self.makeState(state),
      staleDate: nil,
      relevanceScore: 0
    )
    await activity.update(content, alertConfiguration: nil)
  }

  func end(activityId: String, state: [String: Any], dismissalPolicy: String) async {
    guard let activity = cachedOrLiveActivity(activityId) else { return }
    let content = ActivityContent(
      state: Self.makeState(state),
      staleDate: nil,
      relevanceScore: 0
    )
    await activity.end(content, dismissalPolicy: Self.endPolicy(dismissalPolicy))
    activities.removeValue(forKey: activityId)
  }

  /// 缓存优先，未命中则从系统活动列表找回并补入缓存；两端都没有才返回 nil。
  private func cachedOrLiveActivity(_ activityId: String) -> Activity<LiveActivityKitAttributes>? {
    if let cached = activities[activityId] {
      return cached
    }
    guard let live = Activity<LiveActivityKitAttributes>.activities.first(where: { $0.id == activityId }) else {
      return nil
    }
    activities[activityId] = live
    return live
  }

  func endAll(state: [String: Any], dismissalPolicy: String) async {
    let content = ActivityContent(
      state: Self.makeState(state),
      staleDate: nil,
      relevanceScore: 0
    )
    let policy = Self.endPolicy(dismissalPolicy)
    for activity in Activity<LiveActivityKitAttributes>.activities {
      await activity.end(content, dismissalPolicy: policy)
    }
    activities.removeAll()
  }

  private static func makeState(
    _ raw: [String: Any]
  ) -> LiveActivityKitAttributes.ContentState {
    LiveActivityKitAttributes.ContentState(
      title: raw["title"] as? String ?? "",
      subtitle: raw["subtitle"] as? String,
      body: raw["body"] as? String,
      currentForum: raw["currentForum"] as? String,
      status: raw["status"] as? String,
      progress: raw["progress"] as? Double,
      date: raw["date"] as? Double,
      imageName: raw["imageName"] as? String,
      tintColorHex: raw["tintColorHex"] as? String,
      leading: raw["leading"] as? String,
      trailing: raw["trailing"] as? String,
      extra: raw["extra"] as? [String: String]
    )
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
