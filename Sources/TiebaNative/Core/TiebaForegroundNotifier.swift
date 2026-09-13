import Foundation
import UIKit
import UserNotifications
import os

/// 前台消息轮询（原 src/services/NotificationPoller.ts 的原生等价物）。
///
/// 工作体直接复用 TiebaBackgroundSync.performNotificationSync()——与
/// BGAppRefreshTask 走同一份逻辑、同一份 uid 基线，这里只补「回前台触发一次」
/// 与「未读角标回填」两层。定时轮询由系统后台任务负责（BGTask），前台不再
/// 常驻 Timer：didBecomeActive 已经天然覆盖"用户回来看消息"的时机。
@MainActor
final class TiebaForegroundNotifier {
  static let shared = TiebaForegroundNotifier()
  private static let log = Logger(subsystem: "com.tiebalite.app", category: "notifier")

  private var started = false
  private var polling = false
  /// 上次轮询所属 uid：登出后 TiebaSession 已清空快照，只有这里还知道该清谁的基线。
  private var lastKnownUid = ""
  private var sessionObserver: NSObjectProtocol?

  private init() {}

  func start() {
    guard !started else { return }
    started = true
    sessionObserver = NotificationCenter.default.addObserver(
      forName: TiebaSession.didChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.syncBackgroundRegistration() }
    }
    if UIApplication.shared.applicationState == .active {
      poll()
    }
  }

  /// sceneDidBecomeActive 转发（AppDelegate → TiebaAppBootstrap）。start() 尚未
  /// 跑完时交给 start() 的 active 分支补首次轮询，避免冷启动双发。
  func handleDidBecomeActive() {
    guard started else { return }
    poll()
  }

  private func syncBackgroundRegistration() {
    guard TiebaSession.isLoggedIn else {
      TiebaBackgroundSync.shared.cancelNotificationSync()
      // 原 JS clearNotificationBaseline(previousUid)：清基线，重新登录后
      // 登出期间的增量才会再提醒一次（同 uid 再登录时基线不会残留）。
      if !lastKnownUid.isEmpty {
        TiebaBackgroundSync.shared.clearNotificationCounts(uid: lastKnownUid)
        lastKnownUid = ""
      }
      TiebaNavigator.shared.setTabBadge(index: TiebaAppBootstrap.notificationsTabIndex, text: "")
      Task { await TiebaNotificationCenter.shared.setBadge(0) }
      return
    }
    Task {
      let status = await TiebaNotificationCenter.shared.permissionStatus()
      guard Self.allowsDelivery(status) else { return }
      try? TiebaBackgroundSync.shared.registerNotificationPoll(minutes: Self.preferredBackgroundMinutes)
      self.poll()
    }
  }

  /// 授权状态 → 是否允许投递（granted/provisional/ephemeral 同判）。
  /// nonisolated：启动延迟段（非主 actor）也要用它决定后台注册去留。
  nonisolated static func allowsDelivery(_ status: UNAuthorizationStatus) -> Bool {
    status == .authorized || status == .provisional || status == .ephemeral
  }

  /// 后台 BGTask 间隔 = 偏好 notificationPollMinutes（设置页 30/60/120，坏值 30）。
  nonisolated static var preferredBackgroundMinutes: Double {
    let raw = TiebaPreferences.number("notificationPollMinutes", default: 30)
    return raw == 60 || raw == 120 ? raw : 30
  }

  private func poll() {
    guard !polling, UIApplication.shared.applicationState == .active else { return }
    polling = true
    let uid = TiebaBackgroundSnapshot.shared.uid
    if !uid.isEmpty { lastKnownUid = uid }
    Task { @MainActor in
      defer { self.polling = false }
      do {
        try await TiebaBackgroundSync.shared.performNotificationSync()
      } catch {
        Self.log.error("foreground poll failed: \(String(describing: error), privacy: .public)")
        return
      }
      self.refreshTabBadge()
    }
  }

  /// 未读数 → 消息 tab 角标（原 JS 由 notificationStore 订阅下发；原生侧
  /// 消息页自己的 markSeen 也写同一处）。
  private func refreshTabBadge() {
    let uid = TiebaBackgroundSnapshot.shared.uid
    guard !uid.isEmpty,
      let counts = TiebaBackgroundSync.shared.getNotificationCounts(uid: uid)
    else { return }
    let total = counts["total"] as? Int ?? 0
    TiebaNavigator.shared.setTabBadge(
      index: TiebaAppBootstrap.notificationsTabIndex,
      text: total > 99 ? "99+" : (total > 0 ? String(total) : "")
    )
  }
}
