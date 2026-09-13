// 本地通知中心（UNUserNotificationCenter）——替代 expo-notifications。
//
// 为什么整包替换：本仓只用到五件事——权限查询/请求、投递本地通知（立即/定时）、
// 角标、前台展示策略、点击通知深链。expo-notifications 为这五件事引入了推送注册
// （APNs）/分类/服务端注册/Android 渠道等完整链路，而本仓 enablePush=false、
// 无任何分类或 action（grep categoryIdentifier/actionIdentifier 零命中）。
//
// 投递只有一个入口 deliver(...)：后台轮询、签到提醒、签到进度三处调用点不再各写
// 一份 UNMutableNotificationContent；角标同样只有 setBadge(_:) 一个出口。
//
// 前台展示策略（原 JS setNotificationHandler）必须在原生做：willPresent 是唯一
// 能在 App 前台决定 banner/list/sound/badge 的位置；JS 侧 handler 是 expo 自己
// 的桥（且要求 3 秒内响应，超时系统直接丢弃通知）。sign_progress（签到进度）
// 保持"只刷通知中心列表、不弹横幅、不响铃、不动角标"——原特例逐字段保留。
//
// 点击通知 → 深链：didReceive 直接进 TiebaNavigator.open(url:)（原生路由表是
// 唯一一份解析），不再走 JS 的 addNotificationResponseReceivedListener +
// navOpenDeepLink 往返。冷启动时导航壳尚未挂载（didFinishLaunching 早于 scene
// 连接），此时把 URL 暂存，等 window 变 key（= install 完成）再冲刷——这正是
// expo 用 pendingResponses 干的事，只是这里不绕 JS。
//
// 并发契约：delegate 回调在 UNUserNotificationCenter 的私有队列，暂存/冲刷用锁；
// 派发（open）必在 main。Swift 6 下以 @unchecked Sendable 声明这套访问纪律。
import Foundation
import UIKit
import UserNotifications
import os

// public：app target（tiebalite）经 import TiebaNative 调用 cold-start 响应入口。
public final class TiebaNotificationCenter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
  public static let shared = TiebaNotificationCenter()
  static let log = Logger(subsystem: "com.tiebalite.app", category: "notifications")

  /// 冷启动暂存的深链。锁保护：delegate 回调在私有队列、冲刷在 main。
  private let lock = NSLock()
  private var pendingDeepLinks: [String] = []
  private var observers: [NSObjectProtocol] = []
  /// 最近处理的响应指纹（通知 id + 投递时刻），用于两条通道去重（见 handle(response:)）。
  private var lastHandledResponseKey: String?

  private override init() {
    super.init()
  }

  // MARK: - 装配

  /// 启动期（didFinishLaunching，早于 JS 与任何本地通知投递）接管 delegate。
  /// 这是"冷启动点通知"唯一可达的窗口：didReceive 在 scene 连接前后即可能回调，
  /// 晚设 delegate 会把响应整个丢掉。
  func install() {
    UNUserNotificationCenter.current().delegate = self
  }

  // MARK: - UNUserNotificationCenterDelegate

  /// 前台展示策略（原 JS setNotificationHandler 的原生等价物）。
  /// sign_progress 只进列表：签到进行中每完成一个吧就一条横幅会盖住签到页，
  /// 用户明确要求"进度不打扰、结束后 toast 汇报"。
  public func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler:
      @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    let type = notification.request.content.userInfo["type"] as? String
    if type == "sign_progress" {
      completionHandler([.list])
    } else {
      completionHandler([.banner, .list, .sound, .badge])
    }
  }

  /// 点击通知（App 运行中/后台唤起）：转给统一入口 handle(response:)。
  public func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    handle(response: response)
    completionHandler()
  }

  /// 响应统一入口。两条投递通道共用：
  ///   1. UNUserNotificationCenterDelegate.didReceive（App 运行中/后台点击）；
  ///   2. UIScene.ConnectionOptions.notificationResponse（scene 冷启动，见 AppDelegate）
  ///      ——iOS 13+ scene 应用的两条通道都可能触发同一次点击，按
  ///      "通知 id + 投递时刻"指纹去重，保证只导航一次。
  /// 无 url 的通知（签到完成/提醒）只记录指纹、不做导航。
  public func handle(response: UNNotificationResponse) {
    let request = response.notification.request
    let key = "\(request.identifier)|\(response.notification.date.timeIntervalSince1970)"
    lock.lock()
    let duplicate = lastHandledResponseKey == key
    lastHandledResponseKey = key
    lock.unlock()
    guard !duplicate else { return }
    guard let url = request.content.userInfo["url"] as? String, !url.isEmpty else { return }
    route(deepLink: url)
  }

  // MARK: - 深链路由

  private func route(deepLink: String) {
    DispatchQueue.main.async {
      if self.hasKeyWindow {
        self.open(deepLink)
      } else {
        // 冷启动：导航壳还没 install（AppDelegate 在 scene 连接时才建壳）。
        // 暂存 + 等 window 变 key 再冲刷，与冷启动 URL 深链同一时机。
        self.lock.lock()
        self.pendingDeepLinks.append(deepLink)
        self.lock.unlock()
        self.observeWindowReady()
      }
    }
  }

  private var hasKeyWindow: Bool {
    for case let scene as UIWindowScene in UIApplication.shared.connectedScenes
    where scene.windows.contains(where: { $0.isKeyWindow }) {
      return true
    }
    return false
  }

  private func observeWindowReady() {
    guard observers.isEmpty else { return }
    let center = NotificationCenter.default
    // didBecomeKey 在 install(w: makeKeyAndVisible) 之后立刻到；didBecomeActive 是
    // 兜底（某些启动顺序下 key 通知早于 observer 安装）。
    observers.append(center.addObserver(
      forName: UIWindow.didBecomeKeyNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in self?.flushPendingDeepLinks() })
    observers.append(center.addObserver(
      forName: UIApplication.didBecomeActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in self?.flushPendingDeepLinks() })
  }

  private func flushPendingDeepLinks() {
    guard hasKeyWindow else { return }
    lock.lock()
    let urls = pendingDeepLinks
    pendingDeepLinks.removeAll()
    lock.unlock()
    guard !urls.isEmpty else { return }
    for observer in observers {
      NotificationCenter.default.removeObserver(observer)
    }
    observers.removeAll()
    for url in urls {
      open(url)
    }
  }

  private func open(_ deepLink: String) {
    guard let url = URL(string: deepLink) else {
      Self.log.error("invalid deep link in notification payload: \(deepLink, privacy: .public)")
      return
    }
    if !TiebaNavigator.shared.open(url: url) {
      // 原生路由表不认（不是本仓的深链格式）：记日志，不静默。
      Self.log.error("notification deep link not recognized: \(deepLink, privacy: .public)")
    }
  }

  // MARK: - 权限

  /// 当前授权状态。调用方直接按 UNAuthorizationStatus 分支（granted/provisional/
  /// ephemeral 都算"允许投递"，与原 allowsNotifications 的判定一致）。
  func permissionStatus() async -> UNAuthorizationStatus {
    let settings = await UNUserNotificationCenter.current().notificationSettings()
    return settings.authorizationStatus
  }

  /// 请求权限（alert+badge+sound，与原 requestPermissionsAsync 的 ios 选项一致）。
  /// 返回请求后的**真实状态**而不是本次 granted：临时授权（provisional）只有
  /// settings 里才看得出来，只看请求结果会把"静默推送授权"误判成拒绝。
  func requestPermission() async -> UNAuthorizationStatus {
    do {
      _ = try await UNUserNotificationCenter.current()
        .requestAuthorization(options: [.alert, .badge, .sound])
    } catch {
      Self.log.error("requestAuthorization failed: \(error.localizedDescription, privacy: .public)")
    }
    return await permissionStatus()
  }

  // MARK: - 投递 / 撤回 / 角标

  /// 唯一投递入口（trigger == nil = 立即；签到提醒传 UNCalendarNotificationTrigger）。
  /// 后台轮询、签到提醒、签到进度三处不再各写一份 UNMutableNotificationContent。
  /// 投递结果必须回读：未授权/被限流时 add 会失败，静默丢弃等于通知悄悄失效。
  func deliver(
    identifier: String,
    title: String,
    body: String,
    playSound: Bool = false,
    badge: Int? = nil,
    interruptionLevel: UNNotificationInterruptionLevel? = nil,
    dataType: String? = nil,
    deepLink: String? = nil,
    trigger: UNNotificationTrigger? = nil
  ) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    if playSound {
      content.sound = .default
    }
    if let badge {
      content.badge = NSNumber(value: badge)
    }
    if let interruptionLevel {
      content.interruptionLevel = interruptionLevel
    }
    var userInfo: [String: Any] = [:]
    if let dataType, !dataType.isEmpty {
      userInfo["type"] = dataType
    }
    if let deepLink, !deepLink.isEmpty {
      userInfo["url"] = deepLink
    }
    content.userInfo = userInfo
    let request = UNNotificationRequest(
      identifier: identifier,
      content: content,
      trigger: trigger
    )
    UNUserNotificationCenter.current().add(request) { error in
      if let error {
        Self.log.error("add notification failed: \(error.localizedDescription, privacy: .public)")
      }
    }
  }

  /// 撤回同 id 的通知：已投递（通知中心里的横幅/列表项）+ 待投递两处都删。
  /// 只删一处会留下幽灵（签到进度用同一 id 反复刷新，旧实现两处都删）。
  func cancel(identifier: String) {
    let center = UNUserNotificationCenter.current()
    center.removeDeliveredNotifications(withIdentifiers: [identifier])
    center.removePendingNotificationRequests(withIdentifiers: [identifier])
  }

  /// 角标统一出口（applicationIconBadgeNumber 自 iOS 17 起废弃）。系统关掉
  /// "标记"时 setBadgeCount 抛错属预期，只记日志、不改变调用方流程。
  func setBadge(_ count: Int) async {
    do {
      try await UNUserNotificationCenter.current().setBadgeCount(count)
    } catch {
      Self.log.error("setBadgeCount failed: \(error.localizedDescription, privacy: .public)")
    }
  }
}
