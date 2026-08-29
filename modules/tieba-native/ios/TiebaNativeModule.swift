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
      // cheaper than a deeply nested dictionary.
      let decoded = try await Task.detached(priority: .userInitiated) {
        try TiebaSwiftProto.decode(messagePath: responseType, bytes: responseData)
      }.value
      let jsonData = try JSONSerialization.data(withJSONObject: decoded)
      return String(data: jsonData, encoding: .utf8) ?? "{}"
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
    Function("setChromeUserInterfaceStyle") { (dark: Bool) in
      TiebaNativeModule.chromeDarkMode = dark
      DispatchQueue.main.async {
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

  private static var modalStatusBarHidden = false
  private static var modalStatusBarSwizzled = false
  private static var statusBarStyle: UIStatusBarStyle = .default
  private static var statusBarManagerAdopted = false

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

  // 顶栏液态玻璃修复（v3，2026-08-22）：
  // 实测（iOS 27）写 UINavigationBar 级 / UINavigationItem 级 appearance 的
  // backgroundEffect 全部无效——渲染层 _UIBarBackground 的 UIVisualEffectView
  // 始终 effect=none（UIKit 对 UINavigationBar 不再走 appearance 材质路径，
  // 与底栏 NativeTabs 结论一致：写 appearance 反而退出系统自动玻璃管线）。
  // 正确做法是直接操作渲染层：给 _UIBarBackground 下的 UIVisualEffectView 设
  // effect=systemMaterial（与底栏 ae0537b 同一材质结论），并挂自上而下渐变
  // mask（顶部实、底部渐隐——系统原生效果：内容从 bar 底部平滑透入、无硬
  // 底边横线）。UIKit 在页面切换/布局变化时会重建 _UIBarBackground（effect
  // 复位为 none），所以启动后持续幂等重挂。
  private static let navBarGlassDump: Void = {
    let nc = NotificationCenter.default
    nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        TiebaNativeModule.forceNavBarLiquidGlass()
      }
    }
    // 持续幂等重挂：KVO 覆盖"effect 被系统改动"，timer 兜底 "_UIBarBackground
    // 整个重建（新材质视图无人监听）。force 内部幂等短路（effect 已是
    // systemMaterial 跳过；无 bar 直接 return），1.5s 一次成本可忽略。
    // 必须用非调度构造器再显式挂主 run loop：本静态初始化在 JS 线程触发
    // （protoInitialize），scheduledTimer 会把 timer 挂上 JS run loop，
    // 之后 RunLoop.main.add 无法迁移——每 1.5s 在 JS 线程执行 setEffect:
    // 触发 Auto Layout 仅主线程断言 SIGABRT（进二级页面必崩，2026-08-26）。
    // 用默认模式而非 .common：tracking 期间（滚动、系统手势动画）不打断主
    // 线程；该窗口由滚动 swizzle + KVO 覆盖（见 navGlassScrollDump 注释）。
    let timer = Timer(timeInterval: 1.5, repeats: true) { _ in
      TiebaNativeModule.forceNavBarLiquidGlass()
    }
    RunLoop.main.add(timer, forMode: .default)
    // 滚动帧级兜底：iOS 27 滚动态可能直接换掉 _UIBarBackground 实例（KVO 随
    // 旧视图失效），1.5s timer 的间隙里顶栏就是实心的。swizzle 所有
    // UIScrollView 的 setContentOffset，滚动中每帧走轻量恢复（只写 effect，
    // 不重建 mask 不 flush，幂等短路），把不透明窗口压到一帧以内。
    _ = TiebaNativeModule.navGlassScrollDump
    return ()
  }()

  private static var navGlassScrollSwizzled = false
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
        let wantedStyle: UIUserInterfaceStyle = TiebaNativeModule.chromeDarkMode ? .dark : .light
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
    let selector = #selector(UIScrollView.setContentOffset(_:animated:))
    guard let method = class_getInstanceMethod(UIScrollView.self, selector) else { return }
    let original = method_getImplementation(method)
    typealias SetOffsetFn = @convention(c) (AnyObject, Selector, CGPoint, Bool) -> Void
    let originalFn = unsafeBitCast(original, to: SetOffsetFn.self)
    let block: @convention(block) (AnyObject, CGPoint, Bool) -> Void = { scrollView, offset, animated in
      originalFn(scrollView, selector, offset, animated)
      if abs(offset.y) > 1 {
        TiebaNativeModule.reapplyNavBarGlassOnScroll()
      }
    }
    method_setImplementation(method, imp_implementationWithBlock(block))
    return ()
  }()

  /// 滚动期间的轻量恢复：只把 bar 背景材质重挂为 systemMaterial（不重建
  /// gradient mask、不 flush），覆盖 _UIBarBackground 实例重建/effect 重置。
  /// 遍历走 weak 缓存（force 路径填充），幂等短路下每帧零分配。
  private static func reapplyNavBarGlassOnScroll() {
    guard Thread.isMainThread else { return }
    guard !cachedNavBars.allObjects.isEmpty else { return }
    var touched = false
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for navBar in cachedNavBars.allObjects {
      if let bg = findBarBackgroundView(in: navBar), !isGlassApplied(bg.effect) {
        // 与 force 同款两段式重挂（置空→赋值），见上注释
        bg.effect = UIVisualEffect()
        bg.effect = barGlassEffect
        touched = true
      }
    }
    CATransaction.commit()
    if touched {
      // 材质切换涉及一次 layout pass，交给下一 runloop；不做每帧 flush。
      DispatchQueue.main.async {
        TiebaNativeModule.forceNavBarLiquidGlass()
      }
    }
  }

  // 渐变 mask 的名字标记：同一视图重复挂载时直接更新 frame，不重复创建。
  // 参数升级时同步升版本号——复用分支只校验名字与 colors 非空、不比较数值，
  // 不改名则存量旧参数 mask 会经 timer/KVO 路径永久存活。
  private static let gradientMaskName = "tiebaNavGlassGradient.v11"

  // 共享材质常量：滚动 swizzle / KVO / timer 热路径只做比较与复用，不再分配
  // （此前每次比较或重挂都新建一个 UIBlurEffect，飞速滑动时每帧多次堆分配）。
  // v8（2026-08-26）：弃用 UIGlassEffect。真机三轮实测其在本 β 上：①自绘
  // 内缩圆角形状，全宽 bar 四角（尤下部两角）露出无材质空白区；②材质基底
  // 偏白，透明度只能靠 mask 硬压；③自带边框亮线即"底部明显边界"。三者均
  // 为材质自身渲染行为，mask/数值无法根治。换 systemUltraThinMaterial：
  // 全幅均匀超轻磨砂、自动深浅色、无角部缺口无边框线。
  fileprivate static let barGlassEffect: UIVisualEffect = UIBlurEffect(style: .systemUltraThinMaterial)

  // 导航栏弱引用缓存：滚动恢复路径（每帧）不做全树扫描，只遍历该缓存；
  // forceNavBarLiquidGlass（timer/KVO 路径）负责填充与刷新。
  private static let cachedNavBars = NSHashTable<UINavigationBar>.weakObjects()

  // 滚动/交互中 UIKit 会把 bar 背景的 effect 重置为 none（系统滚动态默认），
  // 1.5s 兜底 timer 太慢（用户实测"滑动时顶栏没有透明效果"）→ 对已挂载的
  // 材质视图 KVO 监听 effect，一旦被系统改掉立即重挂，滚动全程保持玻璃。
  // weak 表去重：视图重建（dealloc）后自动释放，表条目失效。
  private static let glassObservedViews = NSHashTable<UIVisualEffectView>.weakObjects()
  fileprivate static var glassKvoContext = 0
  private static let glassKvoObserver = NavGlassEffectObserver()

  private static func observeGlassEffect(on view: UIVisualEffectView) {
    guard !glassObservedViews.contains(view) else { return }
    glassObservedViews.add(view)
    view.addObserver(
      glassKvoObserver,
      forKeyPath: "effect",
      options: [.new],
      context: &glassKvoContext
    )
  }

  // 幂等判据（2026-08-26 真机冻结修复）：不能用实例相等（==/!=）——iOS 27β
  // 上 UIGlassEffect 经 getter 取回的是副本/内部包装，isEqual 不做语义比较，
  // 与共享常量永远不等 → force 每轮都判"需重挂"，两步写入又各自触发 KVO
  // 再排下一轮，主线程陷入永久重挂风暴（实测：进二级页数秒整机冻死、顶栏
  // 刷成实白、滚动与退后台全程卡顿）。改按动态类判同：当前 effect 属共享
  // 常量的同类（含子类）即视为已是玻璃；系统复位态（nil / 其他类）不命中。
  fileprivate static func isGlassApplied(_ effect: UIVisualEffect?) -> Bool {
    guard let effect = effect else { return false }
    return effect.isKind(of: type(of: barGlassEffect))
  }

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
      }
    }
    guard !bars.isEmpty else { return false }
    var applied = false
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for navBar in bars {
      // 双击回顶手势：随 force 的 timer/KVO 扫描覆盖新建的 bar（≤1.5s 延迟）。
      installNavDoubleTapToTop(on: navBar)
      // 应用主题→栏 trait：深色常驻+系统浅色时原生栏材质（含 UISearchBar）
      // 会跟系统渲染成浅色（真机实测一片白），override 拉回应用主题。
      let wantedStyle: UIUserInterfaceStyle = TiebaNativeModule.chromeDarkMode ? .dark : .light
      if navBar.overrideUserInterfaceStyle != wantedStyle {
        navBar.overrideUserInterfaceStyle = wantedStyle
        applied = true
      }
      // bar 自带底保持系统默认（透明）：不透明底垫在 _UIBarBackground 材质
      // 之下被一并模糊，整条 bar 变成纯色带而非玻璃——"返回按钮栏有背景色"
      // 根因（2026-08-27 真机实测）。材质落地前的白闪由 didMoveToWindow
      // 立即写 trait + layoutSubviews force + 主窗口底色兜底覆盖。
      // 底边界来源之二=系统发丝分隔线（bar 内容视图底部的细 imageView）：
      // 在材质视图 mask 作用范围之外，mask 终端 α0 盖不住，必须单独隐藏
      // （用户实测"底部有一条很明显边界"，2026-08-26）。幂等：已隐藏即跳过。
      hideBarHairlines(in: navBar)
      if let bg = findBarBackgroundView(in: navBar) {
        // 渲染层材质：幂等（isGlassApplied 类判同，见该函数注释）。重赋前先
        // 置空再挂：UIKit 对同一视图重复赋 Liquid Glass 有渲染失效问题（expo#43732）。
        if !isGlassApplied(bg.effect) {
          bg.effect = UIVisualEffect()
          bg.effect = barGlassEffect
          applied = true
        }
        // 滚动中被系统重置时即时恢复（KVO 兜底 1.5s timer 的扫描间隙）。
        observeGlassEffect(on: bg)
        // 渐变分段遮罩（v11，2026-08-29）：v10 平台段 α 0.50、底部 5% 渐隐，
        // 真机反馈整条 bar 半透（返回键/右侧按钮行"掉出顶栏"、最下端透明）。
        // v11 平台段整体 α 1.0（状态区到 0.96 全实——返回键/药丸全部覆盖），
        // 仅最后 ~4% 快速归零（终端 α0，保留内容平滑透入、无硬底边横线）。
        // 幂等复用：同名 mask 且 colors 未被清空时只同步 frame。UIKit 在
        // 页面切换/布局重建 _UIBarBackground 时可能保留旧 mask 但清空其
        // colors（实测楼中楼页 mask 存在但 colors 空、渐变丢失）——只有
        // 这种损坏态才重建，避免滚动热路径每次 force 都新建 layer。
        // 首帧竞态：bar 未布局完时 bounds 为零尺寸，此时挂 mask 等于全透明
        // 顶栏（"第一次打开吧页顶栏透明"根因之一）——bounds 非零才挂，
        // layoutSubviews hook 会在布局完成后异步补挂（≤1 帧 + force 兜底）。
        if bg.layer.bounds.width > 0 && bg.layer.bounds.height > 0 {
        if let existing = bg.layer.mask as? CAGradientLayer,
           existing.name == gradientMaskName,
           let colors = existing.colors as? [CGColor], !colors.isEmpty {
          existing.frame = bg.layer.bounds
        } else {
          let mask = CAGradientLayer()
          mask.name = gradientMaskName
          mask.colors = [
            UIColor(white: 1, alpha: 1.0).cgColor,  // loc 0.000 顶端全实
            UIColor(white: 1, alpha: 1.0).cgColor,  // loc 0.050 状态区/灵动岛
            UIColor(white: 1, alpha: 1.0).cgColor,  // loc 0.960 平台（返回键/右侧药丸全实）
            UIColor(white: 1, alpha: 0.65).cgColor,  // loc 0.980 快速衰减
            UIColor(white: 1, alpha: 0.20).cgColor,  // loc 0.992
            UIColor(white: 1, alpha: 0).cgColor,     // loc 1.000 精确归零
          ]
          mask.locations = [0, 0.05, 0.96, 0.98, 0.992, 1]
          mask.startPoint = CGPoint(x: 0.5, y: 0)
          mask.endPoint = CGPoint(x: 0.5, y: 1)
          mask.frame = bg.layer.bounds
          bg.layer.mask = mask
          applied = true
        }
        }
      }
      // appearance 一律不写（写了会让 UIKit 退出自动玻璃管线，底栏同结论）；
      // 仅确保 translucent，使内容可以延伸到 bar 下。
      if navBar.isTranslucent != true {
        navBar.isTranslucent = true
        applied = true
      }
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

  // 在 UINavigationBar 子树中找背景材质视图（_UIBarBackground 内的
  // UIVisualEffectView——渲染层材质宿主；bar 直接子视图里没有则返回 nil）。
  // 先按高度 ≥90 找（过滤 52pt 版按钮等小 effect view）；扑空时降级按
  // 高度 ≥40 再找一遍——iOS 26/27 的 bar 背景布局曾变化（材质视图高度
  // 不恒定），找不到等于效果没施加（顶栏退回系统默认遮罩）。
  private static func findBarBackgroundView(in bar: UINavigationBar) -> UIVisualEffectView? {
    if let v = findVisualEffectView(in: bar, minHeight: barBackgroundMinHeight) {
      return v
    }
    return findVisualEffectView(in: bar, minHeight: 40)
  }

  private static func findVisualEffectView(in view: UIView, minHeight: CGFloat) -> UIVisualEffectView? {
    if let v = view as? UIVisualEffectView, v.frame.height >= minHeight {
      return v
    }
    for subview in view.subviews {
      if let v = findVisualEffectView(in: subview, minHeight: minHeight) {
        return v
      }
    }
    return nil
  }

  // bar 背景材质视图最小高度：过滤掉 52pt 版按钮等小 effect view。
  private static let barBackgroundMinHeight: CGFloat = 90

  // 隐藏 bar 子树里的发丝分隔线：细（≤2pt）imageView 即命中。正常图标
  // （返回箭头/按钮 icon）高度远大于此，不受影响。
  private static func hideBarHairlines(in bar: UINavigationBar) {
    func scan(_ view: UIView) {
      if let iv = view as? UIImageView, iv.bounds.height <= 2, !iv.isHidden {
        iv.isHidden = true
      }
      for sub in view.subviews { scan(sub) }
    }
    scan(bar)
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
  private static weak var navEventModuleInstance: TiebaNativeModule?
  /// 双击门卫 delegate 的关联对象键（见 installNavDoubleTapToTop）。
  private static var navDoubleTapGateKey: UInt8 = 0

  /// 安装幂等：force 由 timer/KVO 反复跑，按手势类型判重。
  /// 双击识别不拦单击按钮动作——UIControl 在第一击 touch-up 即派发，
  /// 识别器只在第二击开始后才可能成功（误触返回键最坏=一次返回+空回顶）。
  private static func installNavDoubleTapToTop(on bar: UINavigationBar) {
    let installed = bar.gestureRecognizers?.contains { $0 is NavDoubleTapGesture } ?? false
    guard !installed else { return }
    let tap = NavDoubleTapGesture(
      target: TiebaNativeModule.self,
      action: #selector(navDoubleTapped(_:))
    )
    tap.numberOfTapsRequired = 2
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
  private static var hdrChromeSwizzled = false
  /// chrome 按压触觉总闸：由 JS 在偏好变化与启动时同步（默认开）。
  fileprivate static var hapticChromeHapticsEnabled = true
  /// 应用实际主题（JS 下发）：顶栏 chrome overrideUserInterfaceStyle 用。
  fileprivate static var chromeDarkMode = false
  /// 应用主题对应的窗口底色：push 转场期间新屏内容未渲染、透出窗口背景时
  /// 不发白的兜底（深色模式"先白后黑"的最后一环，2026-08-26）。
  private static var chromeWindowColor: UIColor {
    chromeDarkMode ? UIColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1) : .white
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
  private static var lastChromeControl: UIControl?
  private static var lastChromeAt: TimeInterval = 0

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

/// 顶栏玻璃材质 KVO 观察者：系统把 effect 改回非 systemMaterial 时立即重挂，
/// 让滚动全程保持液态玻璃（配合 1.5s 兜底扫描，覆盖 _UIBarBackground 重建）。
private final class NavGlassEffectObserver: NSObject {
  override func observeValue(
    forKeyPath keyPath: String?,
    of object: Any?,
    change: [NSKeyValueChangeKey: Any]?,
    context: UnsafeMutableRawPointer?
  ) {
    guard context == &TiebaNativeModule.glassKvoContext else {
      super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
      return
    }
    guard let view = object as? UIVisualEffectView else { return }
    // 已是玻璃（isGlassApplied 类判同）无事可做；否则下一帧重挂（含渐变
    // mask 重建）。实例相等比较在 iOS 27β 上永不成立，会造成 KVO→force
    // 重挂风暴，见 isGlassApplied 注释。复用共享常量：滚动中高频触发，
    // 此处不做任何分配。
    if TiebaNativeModule.isGlassApplied(view.effect) { return }
    DispatchQueue.main.async {
      _ = TiebaNativeModule.forceNavBarLiquidGlass()
    }
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
