import CryptoKit
import ExpoModulesCore
import Foundation
import ObjectiveC
import UIKit

public final class TiebaNativeModule: Module {
  public func definition() -> ModuleDefinition {
    Name("TiebaNative")

    // 导航栏双击回顶：手势在 UINavigationBar 上识别（见 navDoubleTap section），
    // JS 侧 useNavDoubleTapToTop 订阅并按焦点分发到各页列表。
    Events("onNavDoubleTap")

    // ── 大图查看器状态栏隐藏 ──
    // RN 的 <StatusBar hidden /> 走 UIApplication 旧 API，iOS 27 上 no-op；
    // 这里绕开它：直接改写状态栏可见性查询入口再请求刷新。
    // 查看器 Modal 打开/关闭各调一次。
    Function("setModalStatusBarHidden") { (hidden: Bool) in
      Self.applyModalStatusBarHidden(hidden)
    }

    Function("protoInitialize") { (json: String) throws in
      // 启动首个 JS→原生调用：捕获模块实例供静态上下文发事件（双击回顶）。
      Self.navEventModuleInstance = self
      _ = Self.navBarGlassDump
      Self.adoptStatusBarManager()
      _ = Self.hdrChromeDump
      try TiebaProtoRegistry.shared.initialize(json: json)
    }

    /// SwiftProtobuf 编码：messagePath + JS 对象 JSON（驼峰键，未知字段忽略）
    /// → wire bytes → base64。替换 JS 侧 protobufjs 编码（2026-08-29）。
    Function("protoEncode") { (messagePath: String, json: String) throws -> String in
      let wire = try TiebaSwiftProto.encodeJSON(messagePath: messagePath, json: json)
      return wire.base64EncodedString()
    }

    /// 原生 MD5（CryptoKit Insecure.MD5）：32 位小写 hex，与 JS md5 包逐字节一致。
    /// 签名链（sign.ts / auth.ts）走这里，把纯 JS 哈希挪出 JS 线程。
    Function("md5Hex") { (input: String) -> String in
      let digest = Insecure.MD5.hash(data: Data(input.utf8))
      return digest.map { String(format: "%02x", $0) }.joined()
    }

    AsyncFunction("protoPost") {
      (
        url: String,
        headers: [String: String],
        formFields: [[String]],
        protoDataBase64: String,
        skipSign: Bool,
        responseType: String,
        requestId: String,
        timeoutMs: Double?
      ) async throws -> String in
      guard let protoData = Data(base64Encoded: protoDataBase64) else {
        throw TiebaProtoError.invalidWire("invalid proto base64")
      }
      let responseData = try await TiebaNativeClient.shared.postProto(
        urlString: url,
        headers: headers,
        formFields: formFields,
        protoData: protoData,
        skipSign: skipSign,
        requestId: requestId,
        timeout: timeoutMs ?? 15000
      )
      // Decode on a background queue via SwiftProtobuf generated code
      // (schema-driven，无白名单投影——全字段输出；int64/enum 归一化到旧形状),
      // then serialize to a JSON string. A flat string crosses the bridge far
      // cheaper than a deeply nested dictionary. 解码+序列化都在 detached 内
      // 完成，跨界只传 Sendable 的 String。
      let decoded = try await Task.detached(priority: .userInitiated) {
        let decoded = try TiebaSwiftProto.decode(messagePath: responseType, bytes: responseData)
        let jsonData = try JSONSerialization.data(withJSONObject: decoded)
        return String(data: jsonData, encoding: .utf8) ?? "{}"
      }.value
      return decoded
    }

    Function("cancelProtoRequest") { (requestId: String) in
      TiebaNativeClient.shared.cancel(requestId: requestId)
    }

    AsyncFunction("makeThumbnail") {
      (
        sourceUri: String,
        width: Double,
        height: Double,
        cacheKey: String,
        referer: String?,
        targetWidth: Double?
      ) async throws -> String in
      try await TiebaImageIO.shared.makeThumbnail(
        sourceUri: sourceUri,
        width: width,
        height: height,
        cacheKey: cacheKey,
        referer: referer,
        targetWidth: targetWidth
      )
    }

    AsyncFunction("applyWatermark") {
      (sourceUri: String, text: String) async throws -> String in
      try await TiebaImageIO.shared.applyWatermark(sourceUri: sourceUri, text: text)
    }

    Function("clearThumbnailCache") {
      _ = try? TiebaImageIO.shared.clearCache()
    }

    // 设置 → 最大缓存大小：运行时调整原生缩略图磁盘上限（默认 200MB）
    Function("setThumbnailCacheLimit") { (bytes: Double) in
      TiebaImageIO.shared.diskLimitBytes = Int64(bytes)
    }

    // 设置 → 震动反馈总开关：JS 偏好 hapticFeedback 同步给原生，闸住 chrome
    // 光效附带的 UIImpactFeedbackGenerator（返回钮/导航栏右钮/底栏项）。
    Function("setHapticFeedbackEnabled") { (enabled: Bool) in
      TiebaNativeModule.hapticChromeHapticsEnabled = enabled
    }

    // 应用实际主题→原生顶栏 chrome（导航栏/搜索栏材质 trait）：Appearance.
    // setColorScheme 只覆盖 RN 窗口，原生栏仍随系统——"深色常驻+系统浅色"
    // 时顶栏一片白（真机实测 2026-08-26）。force 幂等重挂时顺带改写。
    // 2026-09-02：参数改 Optional——null=跟随系统（自动切换模式），
    // override 还原 unspecified + 窗口底色动态随系统，防"应用手动深色
    // + 系统自动切换"双锁死。
    Function("setChromeUserInterfaceStyle") { (dark: Bool?) in
      TiebaNativeModule.chromeDarkMode = dark
      DispatchQueue.main.async {
        TiebaNativeModule.forceNavBarLiquidGlass()
      }
    }

    // v31 路由门控：四个主 tab（关注/动态/消息/我的）顶栏是 RN 自绘搜索行/
    // 页签，栏材质会把它们糊掉（用户实测"无差别模糊"）——JS 按路由开关。
    // v34（2026-09-11）：开=系统默认栏背景（UIKit 原生材质），关=透明；
    // 路由切换即清空"已规范化"标记，让 force 按新路由重写一遍外观。
    Function("setNavBarGlassEnabled") { (enabled: Bool) in
      TiebaNativeModule.navGlassRouteEnabled = enabled
      DispatchQueue.main.async {
        TiebaNativeModule.nativeAppearanceBars.removeAllObjects()
        TiebaNativeModule.forceNavBarLiquidGlass()
      }
    }

    Function("isLiveActivitySupported") {
      supportsLiveActivities
    }

    Function("areLiveActivitiesEnabled") {
      guard supportsLiveActivities else { return false }
      return TiebaLiveActivityManager.areActivitiesEnabled()
    }

    AsyncFunction("startLiveActivity") { (state: [String: Any]) async throws -> String? in
      guard supportsLiveActivities else { return nil }
      return try await TiebaLiveActivityManager.shared.start(state: state)
    }

    AsyncFunction("updateLiveActivity") { (activityId: String, state: [String: Any]) async throws in
      guard supportsLiveActivities else { return }
      await TiebaLiveActivityManager.shared.update(activityId: activityId, state: state)
    }

    AsyncFunction("endLiveActivity") { (activityId: String, state: [String: Any], dismissalPolicy: String) async throws in
      guard supportsLiveActivities else { return }
      await TiebaLiveActivityManager.shared.end(
        activityId: activityId,
        state: state,
        dismissalPolicy: dismissalPolicy
      )
    }

    AsyncFunction("endAllLiveActivities") { (state: [String: Any], dismissalPolicy: String) async throws in
      guard supportsLiveActivities else { return }
      await TiebaLiveActivityManager.shared.endAll(
        state: state,
        dismissalPolicy: dismissalPolicy
      )
    }

    Function("saveBackgroundSnapshot") { (payload: [String: Any]) in
      TiebaBackgroundSync.shared.saveBackgroundSnapshot(payload)
    }

    Function("clearBackgroundSnapshot") {
      TiebaBackgroundSync.shared.clearBackgroundSnapshot()
    }

    Function("setPrivacyShieldEnabled") { (enabled: Bool) in
      TiebaPrivacyShield.shared.setEnabled(enabled)
    }

    Function("registerNotificationSync") { (minutes: Double) throws in
      try TiebaBackgroundSync.shared.registerNotificationPoll(minutes: minutes)
    }

    Function("cancelNotificationSync") {
      TiebaBackgroundSync.shared.cancelNotificationSync()
    }

    Function("setNotificationCounts") {
      (uid: String, reply: Int, at: Int, agree: Int, total: Int) in
      TiebaBackgroundSync.shared.setNotificationCounts(
        uid: uid,
        reply: reply,
        at: at,
        agree: agree,
        total: total
      )
    }

    Function("getNotificationCounts") { (uid: String) -> [String: Any]? in
      TiebaBackgroundSync.shared.getNotificationCounts(uid: uid)
    }

    Function("clearNotificationCounts") { (uid: String) in
      TiebaBackgroundSync.shared.clearNotificationCounts(uid: uid)
    }

    Function("registerAutoSign") { (hour: Int, minute: Int) throws in
      try TiebaBackgroundSync.shared.registerAutoSign(hour: hour, minute: minute)
    }

    Function("cancelAutoSign") {
      TiebaBackgroundSync.shared.cancelAutoSign()
    }

    Function("cancelAllBackgroundTasks") {
      TiebaBackgroundSync.shared.cancelAll()
    }

    Function("isAutoSignRegistered") { () -> Bool in
      TiebaBackgroundSync.shared.isAutoSignRegistered()
    }

    Function("scheduleSignReminder") { (hour: Int, minute: Int) in
      TiebaBackgroundSync.shared.scheduleSignReminder(hour: hour, minute: minute)
    }

    Function("cancelSignReminder") {
      TiebaBackgroundSync.shared.cancelSignReminder()
    }

    View(TiebaRichTextView.self) {
      Events("onLinkPress", "onUserPress", "onTopicPress", "onContentHeightChange")

      Prop("contentWidth") { (view, width: Double) in
        view.contentWidth = CGFloat(width)
      }

      Prop("fontSize") { (view, size: Double) in
        view.fontSize = CGFloat(size)
      }

      Prop("lineHeight") { (view, height: Double) in
        view.lineHeight = CGFloat(height)
      }

      Prop("textColor") { (view, color: UIColor?) in
        view.textColor = color ?? .label
      }

      Prop("linkColor") { (view, color: UIColor?) in
        view.linkColor = color ?? .systemBlue
      }

      Prop("runs") { (view, runs: [[String: Any]]) in
        view.runs = runs
      }
    }

    View(TiebaAudioWaveformView.self) {
      Prop("heights") { (view, heights: [Double]) in
        view.heights = heights
      }
      Prop("isPlaying") { (view, isPlaying: Bool) in
        view.isPlaying = isPlaying
      }
      Prop("color") { (view, color: UIColor?) in
        view.color = color ?? .systemBlue
      }
      Prop("inactiveColor") { (view, color: UIColor?) in
        view.inactiveColor = color ?? .secondaryLabel
      }
    }

    // ── iOS 26 美化波（P1）：原生按压 + 原生信息流卡片 ──

    // ── 原生分段控件（吧页 segment：列表头内 SwiftUI 嵌套断链，UIKit 可点） ──

    View(TiebaSegmentedControlView.self) {
      Events("onValueChange")

      Prop("titles") { (view, titles: [String]) in
        view.titles = titles
      }
      Prop("selectedIndex") { (view, index: Int) in
        view.selectedIndex = index
      }
    }

    // ── 系统原生搜索框（UISearchBar 直出，搜索页「原生样式」诉求）──

    View(TiebaSearchBarView.self) {
      Events("onTextChange", "onSubmit", "onCancel")

      Prop("placeholder") { (view, value: String) in
        view.placeholder = value
      }
      Prop("text") { (view, value: String) in
        view.text = value
      }
      Prop("showCancel") { (view, value: Bool) in
        view.showCancel = value
      }
      Prop("autoFocus") { (view, value: Bool) in
        view.autoFocus = value
      }
    }

    // ── 长按图片上下文菜单（X 同款：压暗 + 居中大图预览 + 菜单在预览正下方）──

    View(TiebaPhotoContextMenuView.self) {
      Events("onAction", "onMenuPresent")

      Prop("fullUrl") { (view, url: String?) in
        view.fullUrl = url
      }
      Prop("imageWidth") { (view, width: Double) in
        view.imageWidth = width
      }
      Prop("imageHeight") { (view, height: Double) in
        view.imageHeight = height
      }
      Prop("actions") { (view, actions: [[String: Any]]) in
        view.actions = actions
      }
      Prop("previewEnabled") { (view, enabled: Bool) in
        view.previewEnabled = enabled
      }
    }
  }

  // MARK: - 状态栏接管（隐藏 + 样式）

  // ⚠️ Swift 6 并发契约：以下静态状态全部仅主线程读写——swizzle 回调/触摸/
  // 布局/KVO 都在主线程，载入路径自带主线程守卫或主队列跳转。ObjectiveC
  // runtime 互操作（imp_implementationWithBlock 等）无法携带隔离标注，
  // 故统一以 nonisolated(unsafe) 声明非隔离存储，维持原有语义。
  nonisolated(unsafe) private static var modalStatusBarHidden = false
  nonisolated(unsafe) private static var modalStatusBarSwizzled = false
  nonisolated(unsafe) private static var statusBarStyle: UIStatusBarStyle = .default
  nonisolated(unsafe) private static var statusBarManagerAdopted = false

  /// iOS 27 状态栏机制（实测）：
  /// - 隐藏：系统不再查询公开的 prefersStatusBarHidden（全程零查询），改查
  ///   私有 UIViewController._preferredStatusBarVisibility（typeEncoding
  ///   i16@0:8，枚举 2=可见 1=隐藏，系统默认返 2）。
  /// - RN 的 RCTStatusBarManager.setStyle: 原实现要求
  ///   UIViewControllerBasedStatusBarAppearance=NO，否则 RCTLogError 红屏
  ///   （且底层 [UIApplication setStatusBarStyle:] 在 iOS 27 已是 no-op）。
  /// 因此这里 swizzle 掉 RCTStatusBarManager 两个写入方法，把请求改走
  /// VC 级查询：既消红屏，又让样式真正生效。查看器（overFullScreen
  /// modal）打开时全 app 报告隐藏，关闭时恢复。
  static func adoptStatusBarManager() {
    guard !statusBarManagerAdopted else { return }
    guard let cls = NSClassFromString("RCTStatusBarManager") else { return }
    statusBarManagerAdopted = true
    if let mth = class_getInstanceMethod(cls, NSSelectorFromString("setStyle:animated:")) {
      let imp = imp_implementationWithBlock({ (_: AnyObject, style: String, _: Bool) -> Void in
        switch style {
        case "light-content": TiebaNativeModule.statusBarStyle = .lightContent
        case "dark-content": TiebaNativeModule.statusBarStyle = .darkContent
        default: TiebaNativeModule.statusBarStyle = .default
        }
        TiebaNativeModule.refreshStatusBarAppearance()
      } as @convention(block) (AnyObject, String, Bool) -> Void)
      method_setImplementation(mth, imp)
    }
    if let mth = class_getInstanceMethod(cls, NSSelectorFromString("setHidden:withAnimation:")) {
      let imp = imp_implementationWithBlock({ (_: AnyObject, hidden: Bool, _: String) -> Void in
        TiebaNativeModule.applyModalStatusBarHidden(hidden)
      } as @convention(block) (AnyObject, Bool, String) -> Void)
      method_setImplementation(mth, imp)
    }
    // 样式查询入口（公开 API）：iOS 27 实测系统仍会查询，返回 swizzle 维护的样式
    if let mth = class_getInstanceMethod(UIViewController.self,
                                        #selector(getter: UIViewController.preferredStatusBarStyle)) {
      let imp = imp_implementationWithBlock({ (_: AnyObject) -> UIStatusBarStyle in
        return TiebaNativeModule.statusBarStyle
      } as @convention(block) (AnyObject) -> UIStatusBarStyle)
      method_setImplementation(mth, imp)
    }
  }

  /// 改写状态栏隐藏查询：swizzle 基类 _preferredStatusBarVisibility，
  /// 大图查看器打开时全 app 返回 1（隐藏），关闭返回 2（可见）。
  static func applyModalStatusBarHidden(_ hidden: Bool) {
    modalStatusBarHidden = hidden
    let sel = NSSelectorFromString("_preferredStatusBarVisibility")
    if !modalStatusBarSwizzled,
       let mth = class_getInstanceMethod(UIViewController.self, sel) {
      modalStatusBarSwizzled = true
      let imp = imp_implementationWithBlock({ (_: AnyObject) -> Int in
        TiebaNativeModule.modalStatusBarHidden ? 1 : 2
      } as @convention(block) (AnyObject) -> Int)
      method_setImplementation(mth, imp)
    }
    refreshStatusBarAppearance()
  }

  /// 通知系统重新查询状态栏外观（最顶层 presented VC 即 RN Modal）
  /// 延迟到下一 runloop 再请求：调用方常在动画/布局提交期（Modal present/
  /// dismiss），彼时同步 setNeedsStatusBarAppearanceUpdate 会触发 UIKit
  /// _noteOverlayInsetsDidChange 断言 abort（真机退出大图闪退的崩溃堆栈，
  /// JS 侧延迟恢复是主修，这里双保险）。
  static func refreshStatusBarAppearance() {
    DispatchQueue.main.async {
      for window in UIApplication.shared.connectedScenes
        .compactMap({ ($0 as? UIWindowScene)?.keyWindow }) {
        var vc = window.rootViewController
        while let presented = vc?.presentedViewController {
          vc = presented
        }
        vc?.setNeedsStatusBarAppearanceUpdate()
      }
    }
  }

  // 顶栏 chrome 的幂等重挂入口（v3 起，2026-08-22；v34 起职责收窄）：窗口/
  // 导航容器底色、栏 trait、栏外观（透明）、双击回顶手势、滚动边缘模糊按
  // 路由幂等重挂。入口=启动 + 回前台 + 转场完成（didShow）+ 1.5s timer +
  // bar 的 didMoveToWindow/layoutSubviews。
  //
  // 历史（勿再回头）：v3–v33 曾在渲染层直接操作 _UIBarBackground 里的
  // UIVisualEffectView（设 systemMaterial/ultraThin + 渐变 mask）自建磨砂——
  // iOS 27 上栏底材质会被 UIKit 按 appearance 重建（双图层感/矩形磨砂），
  // v34 起全部撤除，模糊改由系统的滚动边缘效果承担（softStyle）。
  private static let navBarGlassDump: Void = {
    let nc = NotificationCenter.default
    nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        TiebaNativeModule.forceNavBarLiquidGlass()
      }
    }
    // 转场完成兜底（2026-09-02 代码修复）：push/pop 动画期间 RunLoop 处于
    // tracking 模式，1.5s timer 被跳过；_UIBarBackground 在转场中重建，
    // 新 bar 的材质要等 timer 恢复才挂（"进帖子页无效果"的 timing 缺口）。
    // didShow 在动画完成时触发 → 主线程强制 force，重建窗口压到一帧内。
    nc.addObserver(
      forName: Notification.Name("UINavigationControllerDidShowNotification"),
      object: nil,
      queue: .main
    ) { _ in
      DispatchQueue.main.async {
        TiebaNativeModule.forceNavBarLiquidGlass()
      }
    }
    // 持续幂等重挂：KVO 覆盖"effect 被系统改动"，timer 兜底 "_UIBarBackground
    // 整个重建（新 bar 无人接管材质）。1.5s 一次成本可忽略。
    // 必须用非调度构造器再显式挂主 run loop：本静态初始化在 JS 线程触发
    // （protoInitialize），scheduledTimer 会把 timer 挂上 JS run loop，
    // 之后 RunLoop.main.add 无法迁移——每 1.5s 在 JS 线程执行视图写入
    // 触发 Auto Layout 仅主线程断言 SIGABRT（进二级页面必崩，2026-08-26）。
    // 用默认模式而非 .common：tracking 期间（滚动、系统手势动画）不打断主
    // 线程；布局完成事件由 navGlassScrollDump 的 didMoveToWindow/layout
    // Subviews swizzle 兜底（v21 起玻璃层自建、不受系统重置，无需滚动恢复）。
    let timer = Timer(timeInterval: 1.5, repeats: true) { _ in
      TiebaNativeModule.forceNavBarLiquidGlass()
    }
    RunLoop.main.add(timer, forMode: .default)
    // 新 bar 挂载/布局即 force：didMoveToWindow 首帧深色防"先白后黑"、
    // layoutSubviews 收尾材质视图建成/布局变化后的时机缺口。
    _ = TiebaNativeModule.navGlassScrollDump
    return ()
  }()

  nonisolated(unsafe) private static var navGlassScrollSwizzled = false
  private static let navGlassScrollDump: Void = {
    guard !navGlassScrollSwizzled else { return }
    navGlassScrollSwizzled = true
    // 新 bar 挂载即应用：页面 push 瞬间新 UINavigationBar 首次进 window，
    // 等 1.5s 兜底扫描的话深色模式下会先渲染系统浅色（真机实测"先白后黑"）。
    // didMoveToWindow 必在主线程；这里同步直写 override（不必等 force 扫描
    // ——bar 未入 window 时 collectNavigationBars 扫不到、force 会早退，
    // trait 一旦写入，UIKit 自带的初始渲染就是深色），再补一轮 force。
    let moveSelector = #selector(UIView.didMoveToWindow)
    if let moveMethod = class_getInstanceMethod(UINavigationBar.self, moveSelector) {
      let moveOriginal = method_getImplementation(moveMethod)
      typealias MoveFn = @convention(c) (AnyObject, Selector) -> Void
      let moveOriginalFn = unsafeBitCast(moveOriginal, to: MoveFn.self)
      let moveBlock: @convention(block) (AnyObject) -> Void = { bar in
        moveOriginalFn(bar, moveSelector)
        guard let navBar = bar as? UINavigationBar else { return }
        let wantedStyle: UIUserInterfaceStyle = TiebaNativeModule.chromeUserInterfaceStyle
        navBar.overrideUserInterfaceStyle = wantedStyle
        // 时机补齐：didMoveToWindow 时 _UIBarBackground 往往还没建成，
        // force 扫描不到材质视图（真机实测此时 force 早退）→ 补一次延迟
        // 重挂，首帧即深色玻璃（"先白后黑"修复，2026-08-27）。
        _ = TiebaNativeModule.forceNavBarLiquidGlass()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
          _ = TiebaNativeModule.forceNavBarLiquidGlass()
        }
      }
      method_setImplementation(moveMethod, imp_implementationWithBlock(moveBlock))
    }
    // layoutSubviews 兜底：bar 每次布局（含 _UIBarBackground 建成）后异步
    // 重挂。放在布局结束后执行，避免在布局 pass 内 flush 引起递归。
    let layoutSelector = #selector(UIView.layoutSubviews)
    if let layoutMethod = class_getInstanceMethod(UINavigationBar.self, layoutSelector) {
      let layoutOriginal = method_getImplementation(layoutMethod)
      typealias LayoutFn = @convention(c) (AnyObject, Selector) -> Void
      let layoutOriginalFn = unsafeBitCast(layoutOriginal, to: LayoutFn.self)
      let layoutBlock: @convention(block) (AnyObject) -> Void = { bar in
        layoutOriginalFn(bar, layoutSelector)
        DispatchQueue.main.async {
          _ = TiebaNativeModule.forceNavBarLiquidGlass()
        }
      }
      method_setImplementation(layoutMethod, imp_implementationWithBlock(layoutBlock))
    }
    // v21 说明：不再有 setContentOffset swizzle/滚动恢复——自建玻璃层不属
    // 系统材质管理，系统不会重置它；滚动中玻璃层持续存在（layoutSubviews
    // 兜底 force 收尾布局变化）。
    return ()
  }()

  // ── v34 原生顶栏（2026-09-11 用户定调）──
  // 用户要求："顶栏完全使用 UIKit，并遵循 iOS 26 之后的 UIKit 设计规范"，
  // 且点名要 iOS 26 的"无边界"模糊（当前系统 iOS 27 的默认观感是矩形硬边磨砂）。
  //
  // 结论（SDK 原文）：iOS 26 起顶栏的模糊由滚动边缘效果承担——
  // UIScrollEdgeEffect.Style.soft = "A soft-edged scroll edge effect"
  //（无边界渐进模糊，内容滚到栏下才出现，看得清背后内容）；
  // .hard = "hard cutoff and dividing line"（矩形硬边+分隔线，用户嫌的那种）。
  // 因此 v19–v33 的自建磨砂层（自建 UIVisualEffectView + CAGradientLayer 渐变
  // mask）、系统材质清空（clearBarEffects）、发丝隐藏（hideBarHairlines）、
  // 三套 appearance 置透明/置默认（v30/v30b）全部撤除：栏底不画任何材质，
  // 模糊交还 UIKit 的 UIScrollView.topEdgeEffect（见 applyTopScrollEdgeEffect）。
  //
  // 栏外观只保留"透明"这一个决定，并由 setter swizzle 拦住 RNScreens 按
  // headerTransparent/headerBlurEffect 的写入（它会把旧材质/默认栏底写回来，
  // 垫出一块矩形磨砂）。
  private static let navGlassLayerLegacyPrefix = "tieba.navGlassLayer."

  // v31 路由门控（setNavBarGlassEnabled）：主 tab 页关、吧页/帖子页开——
  // v34 起门控的对象是滚动边缘模糊（栏底材质已全应用撤除）。
  nonisolated(unsafe) fileprivate static var navGlassRouteEnabled = true

  /// 已按当前路由规范化过外观的 bar（路由切换时清空）。外观只在"该 bar 还没
  /// 规范化"时写一次——重写会让 UIKit 重建栏底，每 1.5s 重写就是滚动闪烁源。
  private static let nativeAppearanceBars = NSHashTable<UINavigationBar>.weakObjects()

  /// 栏外观：一律透明（栏底材质=矩形磨砂，用户点名不要；模糊由边缘效果承担）。
  /// 三套外观槽（standard / compact / scrollEdge）同值：滚动全程同一观感。
  private static func applyNativeBarAppearance(to bar: UINavigationBar) {
    let appearance = makeNativeBarAppearance()
    bar.standardAppearance = appearance
    bar.compactAppearance = appearance
    bar.scrollEdgeAppearance = appearance
    // item 级外观优先于栏级：RNScreens 的 headerTransparent / headerBlurEffect
    // 写的就是这一层，留着会把栏级外观整个盖掉（v30b 同源结论）→ 置 nil
    // 继承栏级。
    if let item = bar.topItem {
      if item.standardAppearance != nil { item.standardAppearance = nil }
      if item.scrollEdgeAppearance != nil { item.scrollEdgeAppearance = nil }
      if item.compactAppearance != nil { item.compactAppearance = nil }
    }
  }

  private static func makeNativeBarAppearance() -> UINavigationBarAppearance {
    let appearance = UINavigationBarAppearance()
    appearance.configureWithTransparentBackground()
    return appearance
  }

  /// 外部 appearance 写入的规范化：保留写入方的标题/按钮排版属性，背景一律
  /// 归一成透明（headerBlurEffect 的旧材质、系统默认栏底都不作数）。
  fileprivate static func normalizedBarAppearance(
    _ incoming: UINavigationBarAppearance?
  ) -> UINavigationBarAppearance {
    let appearance = (incoming?.copy() as? UINavigationBarAppearance) ?? UINavigationBarAppearance()
    appearance.configureWithTransparentBackground()
    return appearance
  }

  /// 外部栏外观写入拦截：RNScreens 应用 screen options 时直接写 standard /
  /// compact / scrollEdge（headerTransparent → 透明底，headerBlurEffect →
  /// 旧材质），会把系统原生材质覆盖掉。拦下每次写入做背景规范化后落库——
  /// 既不必周期性重写 appearance，也不怕 RN 侧后写覆盖。
  nonisolated(unsafe) private static var navGlassAppearanceSwizzled = false
  private static let navGlassAppearanceSwizzle: Void = {
    guard !navGlassAppearanceSwizzled else { return }
    navGlassAppearanceSwizzled = true
    let selectors = [
      NSSelectorFromString("setStandardAppearance:"),
      NSSelectorFromString("setCompactAppearance:"),
      NSSelectorFromString("setScrollEdgeAppearance:"),
    ]
    for selector in selectors {
      guard let method = class_getInstanceMethod(UINavigationBar.self, selector) else { continue }
      let original = method_getImplementation(method)
      typealias SetAppearanceFn = @convention(c) (UINavigationBar, Selector, UINavigationBarAppearance?) -> Void
      let originalFn = unsafeBitCast(original, to: SetAppearanceFn.self)
      let block: @convention(block) (UINavigationBar, UINavigationBarAppearance?) -> Void = { bar, incoming in
        originalFn(bar, selector, TiebaNativeModule.normalizedBarAppearance(incoming))
      }
      method_setImplementation(method, imp_implementationWithBlock(block))
    }
    return ()
  }()

  // v21–v33 自建层存量清扫：老版本升级/同进程换实现时把残留层拆掉，否则它会
  // 一直盖在栏底（前缀扫描；只扫 bar 子树与宿主 bar 的直接子视图——自建层当年
  // 就挂在这两处，不做整屏递归）。幂等。
  private static func removeStaleGlassLayers(in bar: UINavigationBar) {
    func scan(_ view: UIView, deep: Bool) {
      for sub in view.subviews {
        if let id = sub.accessibilityIdentifier, id.hasPrefix(navGlassLayerLegacyPrefix) {
          sub.removeFromSuperview()
          continue
        }
        if deep { scan(sub, deep: true) }
      }
    }
    scan(bar, deep: true)
    if let host = bar.superview { scan(host, deep: false) }
  }

  /// 顶层可见页面视图（presented 链 → 导航栈顶）：顶栏模糊的作用域。
  private static func topScreenView() -> UIView? {
    let windows = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
    let keyWindow = windows.first { $0.isKeyWindow && $0.windowLevel == .normal } ?? windows.first
    guard let window = keyWindow, var vc = window.rootViewController else { return nil }
    while let presented = vc.presentedViewController { vc = presented }
    if let nav = vc as? UINavigationController, let top = nav.topViewController { vc = top }
    return vc.view
  }

  /// 顶栏模糊 = 系统的滚动边缘效果（iOS 26 规范形态）。给顶层页面里"顶边贴着
  /// 屏幕顶"的滚动视图打开 topEdgeEffect 的 soft 样式：内容滚到栏下时由 UIKit
  /// 做渐进模糊——无边界、无硬切边、看得清背后内容。hard 样式（"hard cutoff
  /// and dividing line"，即用户嫌的矩形硬边）与栏底材质一律不用。
  ///
  /// 路由链：内容页（吧页/帖子页/用户主页/搜索/设置…）全开 soft；主 tab
  ///（RN 自绘顶栏，无原生栏）显式关 hidden。关的一侧必须自己写，不能靠
  /// RNScreens 的 scrollEdgeEffects prop——那个 prop 用
  /// findScrollViewInFirstDescendantChainFrom（沿 subviews[0] 逐层下沉）定位，
  /// 命中谁不可控，漏配的滚动视图会落到系统默认样式（iOS 27 = hard 矩形硬边）。
  ///
  /// 只有"**整屏竖向列表**"配 soft：栏下真正滚动的是它。其余顶边贴屏幕顶的
  /// 滚动视图（吧页分段页的原生 pager=横向分页、行内横滑条…）一律显式关掉：
  /// effect 的 hidden 默认是 false，不写就是系统 automatic 样式（iOS 27 上解析成
  /// hard 矩形磨砂+分隔线），而 pager 的顶边同样在栏下、又盖在列表之上，
  /// 于是 hard 叠 soft，用户看到的就是"矩形磨砂 + 明显底边"。
  /// 反过来给 pager 也开 soft 更糟（2026-09-11 v36 实测）：两层软模糊叠在一起，
  /// 滑动时栏下内容被糊死。幂等：已是目标状态时不写（写会打断进行中的模糊动画）。
  @discardableResult
  private static func applyTopScrollEdgeEffect(glass: Bool) -> Bool {
    guard #available(iOS 26.0, *) else { return false }
    guard let screen = topScreenView(), screen.bounds.height > 0 else { return false }
    var changed = false
    func configure(_ scroll: UIScrollView) {
      let frameInScreen = scroll.convert(scroll.bounds, to: screen)
      let vertical = scroll.contentSize.width <= scroll.bounds.width + 1
      // 横向可见性：分页器并排放着各段页面，屏幕外的页面也有列表，只有当前
      // 可见那一屏的列表才算候选（否则会把栏交给一个看不见的列表）。
      let onScreenX = frameInScreen.minX >= -1
        && frameInScreen.maxX <= screen.bounds.width + 1
      let isList = vertical && !scroll.isPagingEnabled && onScreenX
        && frameInScreen.height > screen.bounds.height * 0.4
      let qualifies = frameInScreen.minY <= 1 && frameInScreen.height > 80
        && !scroll.isHidden && scroll.alpha > 0.01
      guard qualifies else { return }
      if glass && isList {
        if scroll.topEdgeEffect.isHidden {
          scroll.topEdgeEffect.isHidden = false
          changed = true
        }
        if scroll.topEdgeEffect.style !== UIScrollEdgeEffect.Style.soft {
          scroll.topEdgeEffect.style = .soft
          changed = true
        }
      } else if !scroll.topEdgeEffect.isHidden {
        // 顶边同样贴屏幕顶但不是"整屏竖向列表"的（分页器 pager、横滑条…）
        // 一律显式关掉：effect 的 hidden 默认是 false，不写就落到系统
        // automatic 样式（iOS 27 上解析成 hard 矩形磨砂+分隔线）。
        scroll.topEdgeEffect.isHidden = true
        changed = true
      }
    }
    func scan(_ view: UIView) {
      if let scroll = view as? UIScrollView { configure(scroll) }
      for sub in view.subviews { scan(sub) }
    }
    scan(screen)
    return changed
  }

  // 导航栏弱引用缓存：force 扫到的 bar 登记，供 refresh 等按需遍历。
  private static let cachedNavBars = NSHashTable<UINavigationBar>.weakObjects()

  @discardableResult
  fileprivate static func forceNavBarLiquidGlass() -> Bool {
    // 全部工作（视图树遍历 + effect/mask 写入）只允许主线程：setEffect:
    // 内部走 NSISEngine，非主线程直接触发 Auto Layout 断言 SIGABRT。
    // timer/KVO/通知各入口理论都应主线程，这里统一兜底跳转而非崩溃。
    guard Thread.isMainThread else {
      DispatchQueue.main.async { TiebaNativeModule.forceNavBarLiquidGlass() }
      return false
    }
    let bars = collectNavigationBars()
    // 无导航栏（splash/首帧前）直接短路：不碰 CATransaction。此前每 1.5s
    // 无条件 CATransaction.flush() 会反复强制主线程完成挂起布局，打断
    // 首帧渲染事务，splash（原生首帧自动隐藏）被拖住数秒。
    // 窗口底色同步（幂等比较，零成本）：深色模式下 push 转场窗口透底不发白。
    // 只写主窗口（key 且 .normal）：系统临时浮层（上下文菜单等）被刷成不透明
    // 底色后，菜单收起时残留窗口会把整屏盖成纯色——长按图片退出后"整个画面
    // 一片空白"的真根因（2026-08-27 真机两次复现；该浮层非 key、level 更高）。
    for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
      for window in scene.windows
      where window.isKeyWindow && window.windowLevel == .normal {
        if window.backgroundColor != TiebaNativeModule.chromeWindowColor {
          window.backgroundColor = TiebaNativeModule.chromeWindowColor
        }
        // 2026-09-02 修复"右滑退出漏白"：pop/push 转场容器（UITransitionView）
        // 背景跟随 window 的 trait 而非 backgroundColor——手动深色 + 系统浅色时
        // 容器按系统渲染成白，页面移开露出白底（真机实测）。窗口 trait 同步
        // 应用主题，转场容器随之深色；nil 跟随系统时不锁（自动切换）。
        let windowStyle = TiebaNativeModule.chromeUserInterfaceStyle
        if window.overrideUserInterfaceStyle != windowStyle {
          window.overrideUserInterfaceStyle = windowStyle
        }
      }
    }
    // 2026-09-02 修复"用力回弹漏白"：UIScrollView 回弹露出的是导航栈容器
    // （UINavigationController.view）——iOS 27 其默认背景跟随系统 trait，
    // 手动深色 + 系统浅色/居中系统时按浅色 systemBackground 渲染成白。
    // 与 window 同源同步应用主题底色（幂等比较，不破坏系统默认 nil 语义）。
    // 覆盖全部嵌套导航容器（非仅 rootViewController 层级）。
    let navContainerBG = TiebaNativeModule.chromeWindowColor
    for navView in TiebaNativeModule.collectNavigationContainerViews() {
      if navView.backgroundColor != navContainerBG {
        navView.backgroundColor = navContainerBG
      }
    }
    guard !bars.isEmpty else { return false }
    var applied = false
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for navBar in bars {
      cachedNavBars.add(navBar)
      // 双击回顶手势：随 force 的 timer/KVO 扫描覆盖新建的 bar（≤1.5s 延迟）。
      installNavDoubleTapToTop(on: navBar)
      // 回弹/转场漏白（2026-09-02 二轮）：页面实际所在的是导航容器
      // （UINavigationController.view，可能嵌套非 window.rootViewController），
      // iOS 27 其背景默认跟随系统 trait——手动深色+系统浅色时按浅色
      // systemBackground 渲染成白，用力甩列表（bounce）即漏出。每个 bar
      // 所在的导航容器同步应用主题底色（幂等）。
      // 应用主题→栏 trait：深色常驻+系统浅色时原生栏材质（含 UISearchBar）
      // 会跟系统渲染成浅色（真机实测一片白），override 拉回应用主题。
      let wantedStyle: UIUserInterfaceStyle = TiebaNativeModule.chromeUserInterfaceStyle
      if navBar.overrideUserInterfaceStyle != wantedStyle {
        navBar.overrideUserInterfaceStyle = wantedStyle
        applied = true
      }
      // bar 自带底保持系统默认（透明）：不透明底垫在 _UIBarBackground 材质
      // 之下被一并模糊，整条 bar 变成纯色带而非玻璃——"返回按钮栏有背景色"
      // 根因（2026-08-27 真机实测）。材质落地前的白闪由 didMoveToWindow
      // 立即写 trait + layoutSubviews force + 主窗口底色兜底覆盖。
      // v34（2026-09-11）：栏外观整体交还 UIKit——不再清材质、不再隐藏发丝
      // 线、不再写透明 appearance，由 applyNativeBarAppearance 按路由写系统
      // 默认/透明外观，其余（材质、分隔、滚动行为）全部按 iOS 26 规范由系统
      // 自渲染。只在"该 bar 还没按当前路由规范化"时写一次（重写会触发 UIKit
      // 重建栏底，周期性重写即滚动闪烁源）；外部后写由 setter swizzle 兜住。
      if !TiebaNativeModule.nativeAppearanceBars.contains(navBar) {
        _ = TiebaNativeModule.navGlassAppearanceSwizzle
        TiebaNativeModule.removeStaleGlassLayers(in: navBar)
        TiebaNativeModule.applyNativeBarAppearance(to: navBar)
        TiebaNativeModule.nativeAppearanceBars.add(navBar)
        applied = true
      }
    }
    // v34：顶栏模糊 = 系统滚动边缘效果（soft，iOS 26 规范形态），按路由门控
    //（吧页/帖子页开，其余页面显式关）。随 force 的节奏幂等重挂：push 新页、
    // 分段切换、列表重建都会带来新的滚动视图。
    if TiebaNativeModule.applyTopScrollEdgeEffect(glass: TiebaNativeModule.navGlassRouteEnabled) {
      applied = true
    }
    CATransaction.commit()
    // Fabric 的 JS 线程会在任意时刻 flush CA transaction：若导航栏仍带 dirty
    // layout，会在 JS 线程执行 Auto Layout（UIKit 限制仅主线程）→ SIGABRT。
    // 这里在主线程强制完成布局，把脏标记消化掉。仅在真写了材质时才 flush：
    // 空转轮询每 1.5s 强制同步布局本身就会干扰滚动/系统动画（实测卡顿源）。
    if applied {
      CATransaction.flush()
    }
    return applied
  }

  /// 扫描全部窗口的 VC 层级找 UINavigationController（可能嵌套）的 view：
  /// 回弹/转场漏白底色同步对象（2026-09-02）。UINavigationBar 无
  /// navigationController 属性，从 VC 树直接遍历最可靠。
  private static func collectNavigationContainerViews() -> [UIView] {
    var views: [UIView] = []
    func scan(_ vc: UIViewController?) {
      guard let vc else { return }
      if let nav = vc as? UINavigationController {
        views.append(nav.view)
        // 嵌套子栈（presented/child）一并覆盖
        for child in nav.viewControllers { scan(child) }
      }
      for child in vc.children { scan(child) }
      scan(vc.presentedViewController)
    }
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    for scene in scenes {
      for window in scene.windows {
        scan(window.rootViewController)
      }
    }
    return views
  }

  private static func collectNavigationBars() -> [UINavigationBar] {
    var bars: [UINavigationBar] = []
    func scan(_ view: UIView) {
      if let bar = view as? UINavigationBar {
        bars.append(bar)
      }
      for subview in view.subviews {
        scan(subview)
      }
    }
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    for scene in scenes {
      for window in scene.windows {
        scan(window)
      }
    }
    return bars
  }

  private var supportsLiveActivities: Bool {
    if #available(iOS 16.2, *) {
      return true
    }
    return false
  }

  // MARK: - 导航栏双击回顶（搜索/吧页/帖内/楼中楼；开关在设置-浏览）

  // 事件发送需要模块实例（sendEvent 是实例方法，手势回调是静态上下文）：
  // protoInitialize（启动首个 JS→原生调用）捕获，weak 不延长生命周期。
  nonisolated(unsafe) private static weak var navEventModuleInstance: TiebaNativeModule?
  /// 双击门卫 delegate 的关联对象键（见 installNavDoubleTapToTop）。
  nonisolated(unsafe) private static var navDoubleTapGateKey: UInt8 = 0

  /// 安装幂等：force 由 timer/KVO 反复跑，按手势类型判重。
  /// iOS 27β 上 UITapGestureRecognizer(numberOfTapsRequired:2) 在导航栏上
  /// 偶发"单击即触发"（真机 2026-09-01 实证：点一次就回顶）——双击判定改放
  /// JS 侧（useNavDoubleTapToTop 400ms 窗口），原生只上报 bar 标题/空白区的
  /// 单击（onNavDoubleTap 事件语义=bar 单击，JS 负责两次判定与抑制）。
  /// 门卫保留：左右边缘区与栏内 UIControl 不识别——事件仅在标题/空白区发出。
  private static func installNavDoubleTapToTop(on bar: UINavigationBar) {
    let installed = bar.gestureRecognizers?.contains { $0 is NavDoubleTapGesture } ?? false
    guard !installed else { return }
    let tap = NavDoubleTapGesture(
      target: TiebaNativeModule.self,
      action: #selector(navDoubleTapped(_:))
    )
    tap.numberOfTapsRequired = 1
    // 必须关闭 touches 延迟（默认 true）！否则栏内所有 UIControl（返回钮/
    // 搜索钮/药丸）的 touch-up 要等双击判定窗口结束才派发——返回按钮点击
    // 后延迟 ~0.3s 才响应、振动落在返回之后（真机实测 2026-08-26）。
    tap.delaysTouchesBegan = false
    tap.delaysTouchesEnded = false
    // 命中栏内 UIControl（返回钮/按钮）时不启动识别：小目标上快速连点会
    // 被误判成双击回顶，页面跳顶后才弹菜单（真机实测反直觉，2026-08-26）。
    // delegate 须强持有：挂到手势的关联对象上随其存亡。
    let gate = NavDoubleTapGate()
    tap.delegate = gate
    objc_setAssociatedObject(tap, &navDoubleTapGateKey, gate, .OBJC_ASSOCIATION_RETAIN)
    bar.addGestureRecognizer(tap)
  }

  @objc private static func navDoubleTapped(_ recognizer: UITapGestureRecognizer) {
    guard let module = navEventModuleInstance else { return }
    module.sendEvent("onNavDoubleTap", ["source": "navbar"])
  }

  // MARK: - Chrome HDR 按压高光（返回钮 / 导航栏右钮 / 底栏钮）

  // 系统 chrome 按钮（返回箭头、headerRight 原生钮、NativeTabs 底栏项）是
  // UIControl；RN 的 Pressable 不是 UIControl，不走这条链路（JS 侧由
  // HdrPressable 负责）。命中 touch 的往往是按钮内部的子视图（如 chevron
  // imageView）而非控件本身，所以 swizzle 挂在 UIView 上：先调原实现，再沿
  // 响应链向上找最近 UIControl；其祖先含 UINavigationBar/UITabBar 才挂光效。
  // 过滤条件之外的视图零开销短路。
  nonisolated(unsafe) private static var hdrChromeSwizzled = false
  /// chrome 按压触觉总闸：由 JS 在偏好变化与启动时同步（默认开）。
  nonisolated(unsafe) fileprivate static var hapticChromeHapticsEnabled = true
  /// 应用实际主题（JS 下发）：顶栏 chrome overrideUserInterfaceStyle 用。
  /// nil = 跟随系统（自动切换模式），非 nil = 应用手动指定深/浅。
  nonisolated(unsafe) fileprivate static var chromeDarkMode: Bool? = nil
  /// 回弹漏白诊断一次性旗标（2026-09-02 临时，验完即删）
  /// 应用主题对应的窗口底色：push 转场期间新屏内容未渲染、透出窗口背景时
  /// 不发白的兜底（深色模式"先白后黑"的最后一环，2026-08-26）。
  /// nil 随系统：动态色跟随系统 trait（自动切换模式下不锁应用值，
  /// 系统切深/浅时转场底色同步变化——2026-09-02 修复）。
  private static var chromeWindowColor: UIColor {
    guard let dark = chromeDarkMode else {
      return UIColor { trait in
        trait.userInterfaceStyle == .dark
          ? UIColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1)
          : .white
      }
    }
    return dark ? UIColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1) : .white
  }

  /// 应用主题 → 顶栏 chrome trait（wantedStyle）：nil 还原 unspecified（跟随系统）。
  fileprivate static var chromeUserInterfaceStyle: UIUserInterfaceStyle {
    guard let dark = chromeDarkMode else { return .unspecified }
    return dark ? .dark : .light
  }

  private static let hdrChromeDump: Void = {
    guard !hdrChromeSwizzled else { return }
    hdrChromeSwizzled = true
    // 双通道覆盖：纯 UIView 重写 touchesBegan 的控件（iOS 27 返回钮等
    // _UIModernBarButton 往往重写且不调 super）走 UIControl 通道。
    // applyChromeHdr 内部按（控件，时间窗）去重，双通道不重复反馈。
    let selector = #selector(UIView.touchesBegan(_:with:))
    if let method = class_getInstanceMethod(UIView.self, selector) {
      let original = method_getImplementation(method)
      typealias TouchesBeganFn = @convention(c) (AnyObject, Selector, Set<UITouch>, UIEvent?) -> Void
      let originalFn = unsafeBitCast(original, to: TouchesBeganFn.self)
      let block: @convention(block) (AnyObject, Set<UITouch>, UIEvent?) -> Void = { view, touches, event in
        originalFn(view, selector, touches, event)
        TiebaNativeModule.applyChromeHdr(to: view)
      }
      method_setImplementation(method, imp_implementationWithBlock(block))
    }
    if let controlMethod = class_getInstanceMethod(UIControl.self, #selector(UIControl.touchesBegan(_:with:))) {
      let controlOriginal = method_getImplementation(controlMethod)
      typealias ControlTouchesFn = @convention(c) (AnyObject, Selector, Set<UITouch>, UIEvent?) -> Void
      let controlOriginalFn = unsafeBitCast(controlOriginal, to: ControlTouchesFn.self)
      let controlBlock: @convention(block) (AnyObject, Set<UITouch>, UIEvent?) -> Void = { control, touches, event in
        controlOriginalFn(control, #selector(UIControl.touchesBegan(_:with:)), touches, event)
        TiebaNativeModule.applyChromeHdr(to: control)
      }
      method_setImplementation(controlMethod, imp_implementationWithBlock(controlBlock))
    }
    return ()
  }()

  /// 同控件去重：UIView/UIControl 双通道 + 连按重放都从两次降至一次。
  nonisolated(unsafe) private static var lastChromeControl: UIControl?
  nonisolated(unsafe) private static var lastChromeAt: TimeInterval = 0

  private static func applyChromeHdr(to view: AnyObject) {
    guard let host = view as? UIView else { return }
    var control: UIControl?
    var isBar = false
    var cursor: UIView? = host
    while let v = cursor {
      if control == nil, let c = v as? UIControl {
        control = c
      }
      if v is UINavigationBar || v is UITabBar {
        isBar = true
        break
      }
      cursor = v.superview
    }
    guard isBar, let target = control,
          target.bounds.width > 0, target.bounds.height > 0 else { return }
    // 2026-09-03：收紧为系统 chrome 按钮类——RN 0.81+ 的 Pressable 渲染为
    // 原生 UIButton，信息流卡片（导航栈内）触摸时沿链命中 UINavigationBar
    // 即误触发 chrome 触觉（用户实测"滑动碰到点赞按钮也振动"）。系统
    // 返回钮/底栏项类名含 Bar/Tab + Button（_UIModernBarButton/
    // _UIButtonBarButton/_UITabBarButton）；RN 按钮类名（RCT*）不含，排除。
    let clsName = String(describing: type(of: target))
    let isSystemChromeButton = clsName.localizedCaseInsensitiveContains("Button")
      && (clsName.localizedCaseInsensitiveContains("Bar")
        || clsName.localizedCaseInsensitiveContains("Tab"))
    guard isSystemChromeButton else { return }
    // 双通道（UIView/UIControl）+ 快速连按去重：同一控件 800ms 内只反馈
    // 一次。返回键曾被实测「点击一次振两次」：pop 转场期间 UIKit 向原按钮
    // 重放 touchesBegan（约 150-400ms 后，250ms 去重窗之外），第二次振动
    // 恰落在「返回上一级之后」（2026-08-27 真机复现）。双通道同帧双发
    // （同一控件 <5ms）仍由本窗口覆盖。
    let now = ProcessInfo.processInfo.systemUptime
    if target === lastChromeControl, now - lastChromeAt < 0.8 { return }
    lastChromeControl = target
    lastChromeAt = now
    debugPrint("[tieba-chrome] haptic fire target=\(type(of: target))")
    HdrChromeFlash.play(on: target)
  }
}

/// 导航栏双击手势的类型标记：幂等安装时按此判重（不与业务手势混淆）。
private final class NavDoubleTapGesture: UITapGestureRecognizer {}

// 双击回顶手势的门卫：点击落在 bar 内 UIControl（或其后代）时不开始识别，
// 把快速连点还给按钮本身（见 installNavDoubleTapToTop 注释）。左右边缘区
// （返回钮/右侧按钮群所在，药丸等非 UIControl 宿主也在）同样不识别——
// 用户在小目标周围空白处连点瞄准时不应触发回顶（真机实测反直觉）。
private final class NavDoubleTapGate: NSObject, UIGestureRecognizerDelegate {
  func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
    guard let bar = g.view else { return true }
    let p = g.location(in: bar)
    if p.x < 64 || p.x > bar.bounds.width - 64 { return false }
    var hit = bar.hitTest(p, with: nil)
    while hit != nil, hit !== bar {
      if hit is UIControl { return false }
      hit = hit?.superview
    }
    return true
  }
}

/// 单次触发的 chrome 按钮按压高光：缩放回弹（"点击时稍微扩大"）+ 控件内
/// 白闪 + 外扩光晕（超出控件边界 10pt，用户要求亮区往外扩）。全部附加在目标
/// 控件上、非交互；动画结束自移除。与 JS HdrPressable 同一视觉语言、同一
/// SDR 合成做法（App Store 同款），亮度拉满。
private final class HdrChromeFlash: UIView {
  /// 'HDR'：同一控件连按时先摘掉旧光效再重放。
  private static let markerTag = 0x4844

  static func play(on control: UIControl) {
    if let existing = control.viewWithTag(markerTag) {
      existing.removeFromSuperview()
    }
    // 触觉与光效同源同刻：chrome 按钮（返回/导航右钮/底栏项）按压的轻震动。
    // 受全局"震动反馈"开关约束（JS 侧经 setHapticFeedbackEnabled 同步）。
    if TiebaNativeModule.hapticChromeHapticsEnabled {
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    let flash = HdrChromeFlash(frame: control.bounds)
    flash.tag = markerTag
    flash.isUserInteractionEnabled = false
    control.addSubview(flash)

    // 控件内白闪（SDR 合成拉满：峰值 1.0 纯白）
    let glow = UIView(frame: control.bounds)
    glow.backgroundColor = .white
    glow.layer.cornerRadius = 9
    flash.addSubview(glow)

    // 外扩光晕：超出控件边界 10pt，稍低透明度模拟玻璃受光漫射
    let halo = UIView(frame: control.bounds.insetBy(dx: -10, dy: -10))
    halo.backgroundColor = .white
    halo.layer.cornerRadius = 15
    flash.addSubview(halo)

    // 峰值瞬间置位（按压瞬间即亮，不缓起），再同步淡出
    glow.alpha = 1.0
    halo.alpha = 0.7

    // 缩放回弹：0.12s 弹到 1.18，弹簧回 1（transform 不影响布局）。
    // 契约：调用方（applyChromeHdr，命中导航/底栏内 UIControl 的 touch）不得
    // 自带 transform 或在其上加动画——本函数直接读写 control.transform。
    // 刻意不做 layer.removeAllAnimations() 式"先取消旧动画"：命中的控件位于
    // 系统 chrome 内，可能携带与按压无关的第三方动画（角标/进度等），无条件
    // 清动画会误伤；这里以"调用方零 transform"契约 + markerTag 摘旧光效兜底。
    control.transform = .identity
    UIView.animate(withDuration: 0.12, animations: {
      control.transform = CGAffineTransform(scaleX: 1.18, y: 1.18)
    }) { _ in
      UIView.animate(
        withDuration: 0.28, delay: 0, usingSpringWithDamping: 0.55,
        initialSpringVelocity: 0.4, options: []
      ) {
        control.transform = .identity
      }
    }

    UIView.animate(withDuration: 0.55, delay: 0, options: [.curveEaseOut], animations: {
      glow.alpha = 0
    })
    UIView.animate(withDuration: 0.62, delay: 0, options: [.curveEaseOut], animations: {
      halo.alpha = 0
    }) { _ in
      flash.removeFromSuperview()
    }
  }
}
