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

    // 顶栏磨砂强度无级调节（v20 均一 mask 的 α，2026-09-03）：拖动即时
    // 生效——更新共享 alpha 并刷新已挂 mask 的强度（未挂 bar 由 force
    // 的 v20 均一 mask 创建路径读取）。设置-浏览 Slider 实验已撤销，无 UI
    // 消费方，保留为可编程管线。
    Function("setNavBarGlassAlpha") { (alpha: Double) in
      TiebaNativeModule.navBarGlassAlpha = CGFloat(min(max(alpha, 0), 1))
      DispatchQueue.main.async {
        TiebaNativeModule.refreshNavBarGlassMaskAlpha()
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

  // 顶栏渐变模糊（v3，2026-08-22 起；2026-09-03 液态玻璃撤销后回归本方案）：
  // 实测（iOS 27）写 UINavigationBar 级 / UINavigationItem 级 appearance 的
  // backgroundEffect 全部无效——渲染层 _UIBarBackground 的 UIVisualEffectView
  // 始终 effect=none（UIKit 对 UINavigationBar 不再走 appearance 材质路径，
  // 与底栏 NativeTabs 结论一致：写 appearance 反而退出系统自动玻璃管线）。
  // 正确做法是直接操作渲染层：给 _UIBarBackground 下的 UIVisualEffectView 设
  // effect=systemMaterial，并挂自上而下渐变 mask（顶部磨砂、底部渐隐——
  // 内容从 bar 底部平滑透入、无硬底边横线）。UIKit 在页面切换/布局变化时
  // 会重建 _UIBarBackground（effect 复位为 none），所以启动后持续幂等重挂。
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

  // ── v21 自建全高玻璃层（2026-09-03 架构重写）──
  // 系统材质视图（_UIBarBackground 内）的布局/高度/重建由 iOS 27 私有管理，
  // 吧页首进"覆盖不全、往返后才全"及多轮 mask 观感漂移均源于它。v21 起
  // 不再操作系统材质视图（直接隐藏，防双层模糊），模糊由导航容器里自建的
  // UIVisualEffectView 承担：覆盖从导航容器顶部（状态栏顶）到 bar 底 +
  // navGlassLayerExtension 延伸段，bar 区内均一磨砂（navBarGlassAlpha）、
  // 延伸段渐隐到 0——渐变模糊、全覆盖、无系统边框全部由本层决定。
  private static let navGlassLayerIdentifier = "tieba.navGlassLayer.v1"
  private static let navGlassLayerExtension: CGFloat = 32
  // v25（2026-09-03）：玻璃层停用——用户实测 0.5 磨砂在顶栏上表现成
  // "盖了一层遮罩"（雾化盖住内容）。恢复干净顶栏（完全透明、内容直穿），
  // 渐变模糊方案后续按用户观感重新设计；存量层由 force 移除。
  private static let navGlassLayerEnabled = false

  // 顶栏磨砂强度（玻璃层 mask alpha）：v22（2026-09-03）起顶部 0.5、bar 底
  // 0.15、延伸段 0——bar 内顶部→底部渐变（明显可见的磨砂层次，用户要求
  // 的"渐变模糊"；0.15 均一实测视觉上等于没有模糊）。顶部强度走
  // setNavBarGlassAlpha/refreshNavBarGlassMaskAlpha 可编程管线（默认 0.5；
  // 设置-浏览 Slider 实验已撤销，无 UI 消费方）。
  nonisolated(unsafe) fileprivate static var navBarGlassAlpha: CGFloat = 0.5
  /// mask 底部（bar 底）强度：与顶部形成 bar 内渐变，延伸段继续 → 0。
  private static let navBarGlassBottomAlpha: CGFloat = 0.15
  /// 顶部均一段占层高比例（bar 内 0→barTopFade 保持顶部强度后开始渐变）。
  private static let navGlassTopFade: CGFloat = 0.55

  /// 无级调节即时生效：把当前所有玻璃层的 mask 强度刷成新 alpha。
  /// 只改 colors 不动 name/结构（幂等路径不冲突）；无层的 bar 交给 force
  /// 的创建路径（读取 navBarGlassAlpha）。
  private static func refreshNavBarGlassMaskAlpha() {
    guard Thread.isMainThread else {
      DispatchQueue.main.async { refreshNavBarGlassMaskAlpha() }
      return
    }
    for navBar in cachedNavBars.allObjects {
      guard let layer = navBar.subviews
        .compactMap({ $0 as? UIVisualEffectView })
        .first(where: { $0.accessibilityIdentifier == navGlassLayerIdentifier }),
        let mask = layer.layer.mask as? CAGradientLayer,
        mask.name == navGlassLayerIdentifier else { continue }
      mask.colors = [
        UIColor(white: 1, alpha: navBarGlassAlpha).cgColor,
        UIColor(white: 1, alpha: navBarGlassAlpha).cgColor,
        UIColor(white: 1, alpha: navBarGlassBottomAlpha).cgColor,
        UIColor(white: 1, alpha: 0).cgColor,
      ]
    }
  }

  // 共享材质常量：热路径只做比较与复用，不再分配。
  // v15（2026-09-01）：ultraThin 模糊太弱像水渍 → .systemMaterial 常规磨砂，
  // mask α0.38；v16 用户再降 → α0.25。9-02 液态玻璃实验（.regular/.clear）已
  // 整体撤销，9-03 回归 systemMaterial；v21 起材质由自建玻璃层使用。
  fileprivate static let barGlassEffect: UIVisualEffect = UIBlurEffect(style: .systemMaterial)

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
    // 诊断（2026-09-02 临时，验完即删）：回弹漏白——打印窗口/导航容器
    // 背景与实际 override 状态，确认哪一层仍按系统浅色渲染。
    if !TiebaNativeModule.bounceDiagLogged {
      TiebaNativeModule.bounceDiagLogged = true
      let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      for scene in scenes {
        for window in scene.windows where window.isKeyWindow {
          NSLog("[bounce-debug] chromeDark=%{public}@ windowBG=%@ windowOverride=%ld rootVC=%{public}@",
                TiebaNativeModule.chromeDarkMode.map(String.init) ?? "nil",
                String(describing: window.backgroundColor),
                window.overrideUserInterfaceStyle.rawValue,
                String(describing: type(of: window.rootViewController)))
          if let navVC = window.rootViewController as? UINavigationController {
            NSLog("[bounce-debug] navVC.view.bg=%@ override=%ld",
                  String(describing: navVC.view.backgroundColor),
                  navVC.overrideUserInterfaceStyle.rawValue)
          }
          if let root = window.rootViewController?.view {
            NSLog("[bounce-debug] rootView.bg=%@ override=%ld",
                  String(describing: root.backgroundColor),
                  root.overrideUserInterfaceStyle.rawValue)
          }
        }
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
      // 底边界来源之二=系统发丝分隔线（bar 内容视图底部的细 imageView）：
      // 在材质视图 mask 作用范围之外，mask 终端 α0 盖不住，必须单独隐藏
      // （用户实测"底部有一条很明显边界"，2026-08-26）。幂等：已隐藏即跳过。
      hideBarHairlines(in: navBar)
      // v21（2026-09-03 架构重写）：不再给系统材质视图挂 effect/mask——
      // 那块的布局/高度/重建节奏由 iOS 27 _UIBarBackground 私有管理，吧页
      // 首进"覆盖不全"、往返后才全即其重建所致（用户连续多轮实测）。
      // 系统材质视图隐藏 + effect 置空（v25 起 effect 也置空：仅 hidden 会被
      // 系统布局重置回显，effect 置空在渲染层兜底，双保险防"遮罩"残留）。
      // v26：全面清理——bar 子树所有 UIVisualEffectView 一并清空（主材质
      // 视图之外可能还有局部毛玻璃小块，"顶栏缺一点"观感来源）；UISearchBar
      // 内部材质不碰（独立搜索页的搜索框有正常模糊背景）。
      TiebaNativeModule.clearBarEffects(in: navBar)
      if let bgC = findBarBackgroundContainer(in: navBar), bgC.backgroundColor != nil {
        bgC.backgroundColor = .clear
      }
      // v25：玻璃层停用——移除已存在的层（v24 装在设备上的旧层必须清掉，
      // 否则遮罩残留；开关重新打开后由 ensureNavGlassLayer 重建）。
      if !TiebaNativeModule.navGlassLayerEnabled {
        if let old = navBar.subviews
          .compactMap({ $0 as? UIVisualEffectView })
          .first(where: { $0.accessibilityIdentifier == TiebaNativeModule.navGlassLayerIdentifier }) {
          old.removeFromSuperview()
        }
      }
      // appearance 一律不写（写了会让 UIKit 退出自动玻璃管线，底栏同结论）；
      // 仅确保 translucent，使内容可以延伸到 bar 下。
      if navBar.isTranslucent != true {
        navBar.isTranslucent = true
        applied = true
      }
      // 底部发丝影线兜底（2026-08-26 起）：系统 shadow image 独立于材质
      // mask 的细线，单独设破，不写 appearance。
      if navBar.shadowImage != nil {
        navBar.shadowImage = UIImage()
        applied = true
      }
      // 自建全高玻璃层：bar 布局未定（bounds 零尺寸）时跳过，下一轮 force
      //（layoutSubviews/didShow/timer）补建并对齐。
      if navBar.bounds.width > 0, navBar.bounds.height > 20 {
        TiebaNativeModule.ensureNavGlassLayer(in: navBar)
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

  // ── v21 自建全高玻璃层实现 ──
  // 玻璃层覆盖范围：导航容器顶部（状态栏顶）→ bar 底 + 延伸段。mask 在
  // bar 区内均一（navBarGlassAlpha），延伸段渐隐到 0。每轮 force 对齐
  // frame/mask（bar 布局变化 → layoutSubviews 兜底 force）；identifier
  // 幂等复用，不在系统 bar 子树内，系统重置/重建不影响本层。

  /// _UIBarBackground 容器（系统 bar 私有背景根）：透明化以防止它盖住
  /// 自建玻璃层（系统若置了不透明底色，材质视图隐藏后会露出实色带）。
  private static func findBarBackgroundContainer(in bar: UINavigationBar) -> UIView? {
    for sub in bar.subviews
    where String(describing: type(of: sub)).contains("UIBarBackground") {
      return sub
    }
    return nil
  }

  private static func ensureNavGlassLayer(in bar: UINavigationBar) {
    guard navGlassLayerEnabled else { return }
    let layer: UIVisualEffectView
    if let existing = bar.subviews
      .compactMap({ $0 as? UIVisualEffectView })
      .first(where: { $0.accessibilityIdentifier == navGlassLayerIdentifier }) {
      layer = existing
      if layer.isHidden { layer.isHidden = false }
    } else {
      // v24（2026-09-03）：层插 bar 最底层——v23 插"BarContentView 之下"
      // 实效是盖住了标题文字（用户实测"字上有遮罩看不清"）。最底层 +
      // 标题内容永远在其上；背景容器透明且系统材质已隐藏，模糊采样穿透。
      layer = UIVisualEffectView(effect: barGlassEffect)
      layer.accessibilityIdentifier = navGlassLayerIdentifier
      layer.isUserInteractionEnabled = false
      bar.insertSubview(layer, at: 0)
    }
    // 每轮保证最底：iOS 27 bar 布局可能重排子视图顺序（v23 盖字教训）。
    if bar.subviews.first !== layer {
      bar.sendSubviewToBack(layer)
    }
    // frame：window 坐标换算。bar 顶部可能在状态栏之下（"少一截"根因）
    // ——层上边缘用负 y 上移到 bar 顶对应的屏幕顶部区，下边缘 = bar 底 +
    // 延伸段。层高 = barTop(屏幕) + bar 高 + 延伸。
    guard bar.bounds.width > 0, bar.bounds.height > 20 else { return }
    let barTopInWindow = bar.convert(CGPoint(x: 0, y: 0), to: nil).y
    let height = barTopInWindow + bar.bounds.height + navGlassLayerExtension
    let target = CGRect(x: 0, y: -barTopInWindow, width: bar.bounds.width, height: height)
    if !layer.frame.equalTo(target) {
      layer.frame = target
    }
    // mask：bar 内渐变（顶部 navBarGlassAlpha → bar 底 navBarGlassBottomAlpha），
    // 延伸段 → 0。fade = bar 底位置（层高比例），渐隐带落在 bar 外，bar 底
    // 无硬分界。
    let barH = barTopInWindow + bar.bounds.height
    let fade = min(max(barH / height, 0.3), 0.9)
    let mask: CAGradientLayer
    if let existing = layer.layer.mask as? CAGradientLayer,
       existing.name == navGlassLayerIdentifier {
      mask = existing
    } else {
      mask = CAGradientLayer()
      mask.name = navGlassLayerIdentifier
      mask.startPoint = CGPoint(x: 0.5, y: 0)
      mask.endPoint = CGPoint(x: 0.5, y: 1)
      layer.layer.mask = mask
    }
    mask.frame = layer.bounds
    mask.colors = [
      UIColor(white: 1, alpha: navBarGlassAlpha).cgColor,
      UIColor(white: 1, alpha: navBarGlassAlpha).cgColor,
      UIColor(white: 1, alpha: navBarGlassBottomAlpha).cgColor,
      UIColor(white: 1, alpha: 0).cgColor,
    ]
    mask.locations = [
      0,
      NSNumber(value: min(navGlassTopFade, fade * 0.8)),
      NSNumber(value: fade),
      1,
    ]
  }

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

  /// v26 全面材质清理：bar 子树所有 UIVisualEffectView 置空 effect + 隐藏
  ///（遮罩残留的通用清除；UISearchBar 内部材质跳过）。幂等，每轮 force 跑。
  private static func clearBarEffects(in bar: UINavigationBar) {
    func scan(_ view: UIView) {
      if view is UISearchBar { return }
      if let ev = view as? UIVisualEffectView {
        if ev.effect != nil {
          ev.effect = UIVisualEffect()
        }
        if !ev.isHidden {
          ev.isHidden = true
        }
      }
      for sub in view.subviews { scan(sub) }
    }
    scan(bar)
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
  nonisolated(unsafe) fileprivate static var bounceDiagLogged = false
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
