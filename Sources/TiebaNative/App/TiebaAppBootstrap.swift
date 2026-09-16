import BackgroundTasks
import Foundation
import UIKit
import os

/// 纯原生启动路径。
///
/// 调用点：AppDelegate 的 didFinishLaunching（installLaunchHandlers）、
/// scene(_:willConnectTo:)（start，建壳后、makeKeyAndVisible 前）与 scene 生命周期
/// 回调（sceneDidBecomeActive / sceneDidEnterBackground）。
/// 首帧前只保留"会话快照读入内存"这一项 IO，其余全部进延迟段。
/// 本文件**只读偏好**（不写）。
@MainActor
public final class TiebaAppBootstrap {
  public static let shared = TiebaAppBootstrap()
  /// nonisolated：延迟段的非主 actor 代码也要打日志（Logger 本身 Sendable）。
  nonisolated private static let log = Logger(subsystem: "com.tiebalite.app", category: "bootstrap")

  /// 底部「消息」tab 下标（未读角标挂它，与 TiebaNavigator 的 tabNames 同序）。
  static let notificationsTabIndex = 2

  private weak var window: UIWindow?
  private var started = false
  /// 系统外观变化 → 跟随模式下重刷主题（iOS 17 registerForTraitChanges）。
  private var traitRegistration: UITraitChangeRegistration?
  /// 自动检测更新：同会话只跑一次（原 JS 的 lastCheckedAt 内存节流同义）。
  private var autoUpdateChecked = false

  private init() {}

  // MARK: - 入口

  /// launch 阶段（AppDelegate.didFinishLaunching）必须完成的两件事，缺一即静默失效：
  /// BGTask 的 launch handler 必须在启动结束前注册；UNUserNotificationCenter 的
  /// delegate 必须早于 scene 回调（冷启动点通知的响应只在 launch 阶段可达）。
  public func installLaunchHandlers() {
    TiebaNotificationCenter.shared.install()
    registerBackgroundTask(TiebaBackgroundSync.notificationTaskIdentifier)
    registerBackgroundTask(TiebaBackgroundSync.autoSignTaskIdentifier)
  }

  /// 模拟器守卫：BGTaskScheduler 注册在模拟器不可用（同 submit）。
  ///
  /// ⚠️ `nonisolated` 是必需的，不是风格问题：launch handler 由 BGTaskScheduler 在
  /// **后台队列**上调用（真机崩溃报告实证：BGTaskScheduler _runTask: →
  /// closure #1 in registerBackgroundTask → swift_task_checkIsolated →
  /// dispatch_assert_queue_fail，SIGTRAP，2026-09-13 两次）。本类是 @MainActor，
  /// 闭包会被推断成 @MainActor，于是运行期隔离检查在后台队列上直接崩；标
  /// nonisolated 后闭包不再继承主 actor，而 handle(_:) 本身是非隔离方法
  /// （TiebaBackgroundSync 用 @unchecked Sendable 声明线程纪律），无需跳主线程。
  private nonisolated func registerBackgroundTask(_ identifier: String) {
    #if targetEnvironment(simulator)
    return
    #else
    BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
      TiebaBackgroundSync.shared.handle(task)
    }
    #endif
  }

  public func start(in window: UIWindow) {
    guard !started else { return }
    started = true
    self.window = window

    // 顶栏 chrome / chrome 触觉的安装（swizzle 钩子，必须早于首帧）。
    TiebaChrome.installNavBarChromeHooks()
    TiebaChrome.installChromeHapticsHooks()

    // 首帧前唯一保留的 IO：冷启动把持久化会话读进内存快照（原生后台签到/通知/
    // 各页 isLoggedIn 都读它，而 TiebaSession 目前只在登录路径 load）。
    TiebaBackgroundSnapshot.shared.load()

    // 主题/偏好必须在深链压栈前落地：selectTab 在栈深 > 1 时会 popToRoot，
    // 挪到延迟段会把冷启动深链顶掉；这几条都是 SQLite 点查，不是首帧瓶颈。
    applyBootPreferences()
    observeTraitChanges(on: window)
    startSplash()
    installMemoryWarningObserver()

    // 其余启动项（僵尸会话清理 / 157KB 描述符解析 / 磁盘清扫 / 后台任务重排）
    // 全部离开主线程：@MainActor 类里的 Task{} 会继承主 actor，必须显式 detached。
    Task.detached(priority: .utility) { await TiebaAppBootstrap.runDeferredWork() }
  }

  // MARK: - scene 生命周期（AppDelegate 转发）

  /// 回前台：触觉引擎预热、前台消息轮询。
  public func sceneDidBecomeActive() {
    if TiebaPreferences.bool("hapticFeedback", default: true) { TiebaSceneHaptics.warmUp() }
    TiebaForegroundNotifier.shared.handleDidBecomeActive()
  }

  /// 进后台：触觉引擎销毁省电。
  public func sceneDidEnterBackground() {
    TiebaSceneHaptics.shutdown()
  }

  // MARK: - 同步启动项（首帧前）

  private func applyBootPreferences() {
    applyTheme()
    TiebaChrome.setHapticChromeHapticsEnabled(
      TiebaPreferences.bool("hapticFeedback", default: true)
    )
    TiebaNavigator.shared.setTabBarMinimizeEnabled(
      TiebaPreferences.bool("tabBarMinimizeEnabled", default: true)
    )
    applyCacheLimits()
    applyStartTab()
  }

  /// 主题 → 原生壳（tint/navTint/背景/状态栏/窗口底色）。原生页面各自出现时
  /// 也会重刷，这里补的是「冷启动到首次进入设置页」之间的窗口。
  private func applyTheme() {
    let followSystem = TiebaPreferences.bool("followSystemDarkMode", default: true)
    let dark = TiebaSettingsForm.isDark(systemIsDark: systemIsDark)
    let themeName = TiebaThemePalette.themeName(dark: dark)
    let accent = TiebaThemePalette.accent(
      themeName: themeName,
      customPrimary: TiebaPreferenceSnapshot.string("customPrimaryColor"),
      isDark: dark
    )
    TiebaSettingsForm.applyTheme(dark: dark, accentHex: accent)
    // 跟随模式必须下发 nil：具体值会锁死窗口 trait，系统切换不再生效
    // （原 ThemeContext 的 Appearance.setColorScheme('unspecified') 同判据）。
    // ⚠️ 这是**全应用唯一的深浅决策点**（连同设置页 applyChrome 的同一条）：
    // 落点是窗口级 override（TiebaChrome.setChromeDarkMode 同步写），栏/底栏/
    // 宿主/表单都不再各自写 override，随窗口继承。
    TiebaChrome.setChromeDarkMode(followSystem ? nil : dark)
  }

  /// 系统外观：新窗口自己的 trait 在 makeKeyAndVisible 前还是 unspecified，
  /// 必须问 scene（它随屏幕解析）。
  private var systemIsDark: Bool {
    let style = window?.windowScene?.traitCollection.userInterfaceStyle
      ?? window?.traitCollection.userInterfaceStyle
      ?? .light
    return style == .dark
  }

  /// 启动默认页（设置→使用习惯→首页）。首帧前应用：深链/通知冷启动随后压栈，
  /// 不会被这次切 tab 顶掉（selectTab 在栈深 > 1 时会 popToRoot）。
  private func applyStartTab() {
    let startTab = TiebaPreferences.string("startTab", default: "index")
    guard let index = TiebaRouteTable.tabNames.firstIndex(of: startTab), index > 0 else { return }
    TiebaNavigator.shared.selectTab(index)
  }

  /// 图片缓存上限（设置→最大缓存大小，默认 400MB）。内存档口径见
  /// TiebaNuke.memoryLimitBytes(forDiskBytes:)（磁盘/4 夹 32–96MB，唯一一份公式）。
  private func applyCacheLimits() {
    let mb = max(0, TiebaPreferences.number("cacheMaxSizeMb", default: 400))
    let bytes = Int(mb * 1024 * 1024)
    TiebaNuke.setCacheLimits(
      diskBytes: bytes,
      memoryBytes: TiebaNuke.memoryLimitBytes(forDiskBytes: bytes)
    )
  }

  /// 启动图：原生挂载（幂等）后延一帧淡出。原 JS 在 bundle 求值期 prevent、
  /// 首帧 hide；这里 prevent 更早，hide 让出一次主队列（makeKeyAndVisible 已返回）。
  private func startSplash() {
    TiebaSplashController.shared.setOptions(fade: true, durationMs: 280)
    TiebaSplashController.shared.preventAutoHide()
    DispatchQueue.main.async { TiebaSplashController.shared.hide() }
  }

  private func observeTraitChanges(on window: UIWindow) {
    // 跟随系统模式的实时切换链（这里是唯一入口）：窗口 trait 变 → applyTheme →
    // 导航壳（tint/navTint/底色/状态栏字色 + 逐宿主子页 trait）+ TiebaSystemUI
    // 根视图底色 + 窗口级深浅重申；其余页面/栏没有自己的 override，随窗口 trait
    // 原生一起变（含 presented）。手动模式下窗口有 override，系统切档不触发这里。
    traitRegistration = window.registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
      (_: UIWindow, _) in
      guard TiebaPreferences.bool("followSystemDarkMode", default: true) else { return }
      TiebaAppBootstrap.shared.applyTheme()
    }
  }

  private func installMemoryWarningObserver() {
    // 内存告警 → 清图片缓存（原 JS 经 tieba-system 事件转一手，现直接观察系统通知）。
    NotificationCenter.default.addObserver(
      forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
    ) { _ in
      TiebaNuke.clearCaches()
    }
  }

  // MARK: - 延迟启动项（首帧后、协作线程池）

  /// nonisolated static：@MainActor 类的实例方法默认继承主 actor，这些
  /// Keychain/JSON/磁盘工作不能占主线程；主 actor 只接收末尾的挂载点。
  private nonisolated static func runDeferredWork() async {
    // 描述符解析最先完成：注册表契约是"先于任何请求建表"，本段在首帧前发起，
    // 任何页面请求都排在首帧 + 网络 RTT 之后，远慢于一次本地解析。
    TiebaProtoRegistry.shared.loadBundled()
    // 旧 TiebaImageIO 磁盘目录一次性清扫（可能上百 MB，放后台不卡首帧）。
    Task.detached(priority: .utility) {
      TiebaNuke.removeLegacyImageCacheDirectory()
    }
    // 吧头像磁盘缓存在后台读进内存：否则首个用到它的 cell 会在主线程解析整张表。
    TiebaForumAvatarCache.shared.warmUp()
    // 僵尸会话清理（Keychain 读 + 可能整份删除）：首帧前不做。
    TiebaSession.purgeOrphanedSession()
    maybeAutoCleanCache()
    scheduleAutoSign()
    await recoverLiveActivities()
    await setupNotifications()
    // 主 actor 只接收必须挂 UI/主 actor 单例的挂载点。
    await MainActor.run {
      TiebaForegroundNotifier.shared.start()
      TiebaClipboardLinkDetector.shared.start()
    }
    await MainActor.run { TiebaAppBootstrap.shared.maybeAutoCheckUpdate() }
  }

  /// 缓存定期自动清理（设置可选 1/3/7/15/30 天，0 = 关闭）。
  private nonisolated static func maybeAutoCleanCache() {
    let days = Int(TiebaPreferences.number("cacheAutoCleanDays", default: 0))
    guard days > 0 else { return }
    let key = "@tiebalite:cache_auto_clean_at"
    let now = Date().timeIntervalSince1970 * 1000
    let last = Double(TiebaKvStore.shared.get(key: key) ?? "0") ?? 0
    if last > 0, now - last < Double(days) * 86_400_000 { return }
    clearImageCaches()
    try? TiebaKvStore.shared.set(key: key, value: String(Int(now)))
  }

  /// 只清图片类缓存（自动清理用，不动用户数据）。
  private nonisolated static func clearImageCaches() {
    // 删整个 Caches 目录（Nuke DataCache 与 URLCache 都在其下；Nuke 内存层
    // 只删目录清不到，必须再走 clearCaches）。
    if let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
      let contents = try? FileManager.default.contentsOfDirectory(
        at: cacheDirectory, includingPropertiesForKeys: nil
      )
    {
      for url in contents { try? FileManager.default.removeItem(at: url) }
    }
    TiebaNuke.clearCaches()
    URLCache.shared.removeAllCachedResponses()
  }

  /// 冷启动重排自动签到（原 JS ensureAutoSignScheduled）：BGTask 请求不保证跨启动
  /// 存活，偏好里开着就重新提交一次（registerAutoSign 内部按 identifier 覆盖）。
  private nonisolated static func scheduleAutoSign() {
    guard TiebaPreferences.bool("autoSign", default: false) else { return }
    let parts = TiebaPreferences
      .string("autoSignTime", default: "08:00")
      .split(separator: ":")
      .compactMap { Int($0) }
    guard parts.count == 2 else { return }
    do {
      try TiebaBackgroundSync.shared.registerAutoSign(hour: parts[0], minute: parts[1])
      TiebaBackgroundSync.shared.scheduleSignReminder(hour: parts[0], minute: parts[1])
    } catch {
      log.error("auto sign re-register failed: \(String(describing: error), privacy: .public)")
    }
  }

  /// 抢救残留的签到 Live Activity（进程被杀后灵动岛会一直挂着）——原 JS
  /// recoverStaleSignLiveActivities，含清掉持久化的 activity id。
  private nonisolated static func recoverLiveActivities() async {
    try? TiebaKvStore.shared.remove(key: "tiebalite_sign_live_activity_id")
    guard TiebaLiveActivityManager.areActivitiesEnabled() else { return }
    let state = LiveActivityKitAttributes.ContentState(
      title: "签到已中断",
      subtitle: "签到进程已停止",
      status: "中断",
      progress: 0,
      imageName: "xmark.circle.fill",
      tintColorHex: "#3B82F6"
    )
    await TiebaLiveActivityManager.shared.endAll(state: state, dismissalPolicy: .immediate)
  }

  /// 通知权限 + 原生后台同步注册（原 JS setupNotifications）。
  private nonisolated static func setupNotifications() async {
    let center = TiebaNotificationCenter.shared
    var status = await center.permissionStatus()
    if status == .notDetermined { status = await center.requestPermission() }
    guard TiebaForegroundNotifier.allowsDelivery(status) else {
      // 未授权 = 后台拉取无意义（与 JS 同语义：拒绝就撤销注册）。
      TiebaBackgroundSync.shared.cancelNotificationSync()
      return
    }
    do {
      try TiebaBackgroundSync.shared.registerNotificationPoll(
        minutes: TiebaForegroundNotifier.preferredBackgroundMinutes
      )
    } catch {
      log.error("register notification sync failed: \(String(describing: error), privacy: .public)")
    }
  }

  /// 自动检测更新（设置开关，默认开）：同会话一次，静默失败。
  /// 结果落在 TiebaUpdateService，「关于」页读同一份状态（原 updateStore 同义）。
  private func maybeAutoCheckUpdate() {
    guard !autoUpdateChecked else { return }
    autoUpdateChecked = true
    guard TiebaPreferences.bool("autoCheckUpdate", default: true) else { return }
    Task { await TiebaUpdateService.shared.check() }
  }
}
