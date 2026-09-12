// TiebaNative 模块的注册表（Expo Modules API 2.0 宏 + 1.0 DSL 混合模式）：
//   - @ExpoModule/@JS/@Event 成员由宏直接绑进模块的 JS 对象（直连 JSI：参数按
//     静态类型逐个解码，绕开 1.0 的 [Any] 动态派发路径），模块名由宏合成的
//     _jsName 提供，不再写 Name("...")；
//   - definition() 只留 2.0 暂无对应的成员：五个原生视图（2.0 的视图
//     @ViewProps/@ExpoView 尚未落地）与「自由字典参数/返回值」的函数（本版
//     core 尚未提供自由字典解码入口），以及两个图像函数（见 definition 注释）。
// 具体实现按职责拆到同目录的扩展文件——
//   TiebaNavBarChrome.swift      原生顶栏（透明外观 / setter swizzle / 滚动边缘模糊）
//   TiebaStatusBarTakeover.swift 状态栏接管（隐藏 + 样式 swizzle）
//   TiebaChromeHaptics.swift     系统 chrome 按钮的按压高光与触觉
//   TiebaNavDoubleTapToTop.swift 导航栏单击上报（JS 侧双击判定）
//   HdrChromeFlash.swift         按压高光视图类
import CryptoKit
import ExpoModulesCore
import Foundation
import ObjectiveC
import UIKit

/// onNavDoubleTap 的事件负载：与 1.0 时代 sendEvent 的 ["source": "navbar"] 同形。
@Record
struct NavDoubleTapPayload {
  var source: String
}

@ExpoModule("TiebaNative")
public final class TiebaNativeModule: Module {
  // MARK: - 事件

  /// 导航栏单击上报：手势在 UINavigationBar 上识别（见 TiebaNavDoubleTapToTop.swift），
  /// JS 侧 useNavDoubleTapToTop 订阅后自行做双击判定并按焦点分发。
  /// emit 由 core 调度到 JS 线程，可从任意线程（此处=主线程手势回调）调用。
  @Event("onNavDoubleTap")
  var onNavDoubleTap: (NavDoubleTapPayload) -> Void

  // MARK: - 状态栏 / 原型编解码

  /// 大图查看器状态栏隐藏：RN 的 <StatusBar hidden /> 走 UIApplication 旧 API，
  /// iOS 27 上 no-op；这里绕开它：直接改写状态栏可见性查询入口再请求刷新。
  /// 查看器 Modal 打开/关闭各调一次。
  @JS
  func setModalStatusBarHidden(hidden: Bool) {
    Self.applyModalStatusBarHidden(hidden)
  }

  @JS
  func protoInitialize(json: String) throws {
    // 启动首个 JS→原生调用：捕获模块实例供静态上下文发事件（双击回顶）。
    Self.retainEventModule(self)
    Self.installNavBarChromeHooks()
    Self.adoptStatusBarManager()
    Self.installChromeHapticsHooks()
    try TiebaProtoRegistry.shared.initialize(json: json)
  }

  /// SwiftProtobuf 编码：messagePath + JS 对象 JSON（驼峰键，未知字段忽略）
  /// → wire bytes → base64。替换 JS 侧 protobufjs 编码（2026-08-29）。
  @JS
  func protoEncode(messagePath: String, json: String) throws -> String {
    let wire = try TiebaSwiftProto.encodeJSON(messagePath: messagePath, json: json)
    return wire.base64EncodedString()
  }

  /// 原生 MD5（CryptoKit Insecure.MD5）：32 位小写 hex，与 JS md5 包逐字节一致。
  /// 签名链（sign.ts / auth.ts）走这里，把纯 JS 哈希挪出 JS 线程。
  @JS
  func md5Hex(input: String) -> String {
    let digest = Insecure.MD5.hash(data: Data(input.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  /// 2.0 的 async 成员起手在 JS 线程、到首个 await 才离开（1.0 的 AsyncFunction
  /// 是整段在后台队列），所以这里只留一次 base64 解码在 await 之前——解码 +
  /// JSON 序列化本来就在显式 detached 里跑。
  @JS
  func protoPost(
    url: String,
    headers: [String: String],
    formFields: [[String]],
    protoDataBase64: String,
    skipSign: Bool,
    responseType: String,
    requestId: String,
    timeoutMs: Double?
  ) async throws -> String {
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

  @JS
  func cancelProtoRequest(requestId: String) {
    TiebaNativeClient.shared.cancel(requestId: requestId)
  }

  // MARK: - 缩略图缓存

  @JS
  func clearThumbnailCache() {
    _ = try? TiebaImageIO.shared.clearCache()
  }

  /// 设置 → 最大缓存大小：运行时调整原生缩略图磁盘上限（默认 200MB）
  @JS
  func setThumbnailCacheLimit(bytes: Double) {
    TiebaImageIO.shared.diskLimitBytes = Int64(bytes)
  }

  // MARK: - 顶栏 chrome / 触觉

  /// 设置 → 震动反馈总开关：JS 偏好 hapticFeedback 同步给原生，闸住 chrome
  /// 光效附带的 UIImpactFeedbackGenerator（返回钮/导航栏右钮/底栏项）。
  @JS
  func setHapticFeedbackEnabled(enabled: Bool) {
    TiebaNativeModule.setHapticChromeHapticsEnabled(enabled)
  }

  /// 应用实际主题→原生顶栏 chrome（导航栏/搜索栏材质 trait）：Appearance.
  /// setColorScheme 只覆盖 RN 窗口，原生栏仍随系统——"深色常驻+系统浅色"
  /// 时顶栏一片白（真机实测 2026-08-26）。force 幂等重挂时顺带改写。
  /// 2026-09-02：参数改 Optional——null=跟随系统（自动切换模式），
  /// override 还原 unspecified + 窗口底色动态随系统，防"应用手动深色
  /// + 系统自动切换"双锁死。
  @JS
  func setChromeUserInterfaceStyle(dark: Bool?) {
    TiebaNativeModule.setChromeDarkMode(dark)
    DispatchQueue.main.async {
      TiebaNativeModule.forceNavBarLiquidGlass()
    }
  }

  /// v31 路由门控：四个主 tab（关注/动态/消息/我的）顶栏是 RN 自绘搜索行/
  /// 页签，栏材质会把它们糊掉（用户实测"无差别模糊"）——JS 按路由开关。
  /// v34（2026-09-11）：开=系统默认栏背景（UIKit 原生材质），关=透明；
  /// 路由切换即清空"已规范化"标记，让 force 按新路由重写一遍外观。
  @JS
  func setNavBarGlassEnabled(enabled: Bool) {
    TiebaNativeModule.setNavBarRouteEnabled(enabled)
    DispatchQueue.main.async {
      TiebaNativeModule.resetBarAppearanceCache()
      TiebaNativeModule.forceNavBarLiquidGlass()
    }
  }

  // MARK: - 灵动岛（签到）

  @JS
  func isLiveActivitySupported() -> Bool {
    supportsLiveActivities
  }

  @JS
  func areLiveActivitiesEnabled() -> Bool {
    guard supportsLiveActivities else { return false }
    return TiebaLiveActivityManager.areActivitiesEnabled()
  }

  // MARK: - 后台快照 / 隐私遮罩

  @JS
  func clearBackgroundSnapshot() {
    TiebaBackgroundSync.shared.clearBackgroundSnapshot()
  }

  @JS
  func setPrivacyShieldEnabled(enabled: Bool) {
    TiebaPrivacyShield.shared.setEnabled(enabled)
  }

  // MARK: - 消息轮询 / 自动签到

  @JS
  func registerNotificationSync(minutes: Double) throws {
    try TiebaBackgroundSync.shared.registerNotificationPoll(minutes: minutes)
  }

  @JS
  func cancelNotificationSync() {
    TiebaBackgroundSync.shared.cancelNotificationSync()
  }

  @JS
  func setNotificationCounts(uid: String, reply: Int, at: Int, agree: Int, total: Int) {
    TiebaBackgroundSync.shared.setNotificationCounts(
      uid: uid,
      reply: reply,
      at: at,
      agree: agree,
      total: total
    )
  }

  @JS
  func clearNotificationCounts(uid: String) {
    TiebaBackgroundSync.shared.clearNotificationCounts(uid: uid)
  }

  @JS
  func registerAutoSign(hour: Int, minute: Int) throws {
    try TiebaBackgroundSync.shared.registerAutoSign(hour: hour, minute: minute)
  }

  @JS
  func cancelAutoSign() {
    TiebaBackgroundSync.shared.cancelAutoSign()
  }

  @JS
  func cancelAllBackgroundTasks() {
    TiebaBackgroundSync.shared.cancelAll()
  }

  @JS
  func isAutoSignRegistered() -> Bool {
    TiebaBackgroundSync.shared.isAutoSignRegistered()
  }

  @JS
  func scheduleSignReminder(hour: Int, minute: Int) {
    TiebaBackgroundSync.shared.scheduleSignReminder(hour: hour, minute: minute)
  }

  @JS
  func cancelSignReminder() {
    TiebaBackgroundSync.shared.cancelSignReminder()
  }

  // MARK: - 1.0 DSL（2.0 暂无对应能力）

  /// 留下的成员分三类，都不改 JS 契约（同名、同参数、同步/异步同语义）：
  /// 1. 五个原生视图：2.0 的 @ViewProps/@ExpoView 还没落地，视图连同其
  ///    Prop/Events 一并留在 1.0（混合模式是官方预期的中间态）。
  /// 2. 自由字典参数/返回值：startLiveActivity/updateLiveActivity/
  ///    endLiveActivity/endAllLiveActivities/saveBackgroundSnapshot 收
  ///    [String: Any]，getNotificationCounts 返回 [String: Any]?——本版 core
  ///    没有自由字典解码入口（解码只有静态类型路径），2.0 只能改建
  ///    @Record（改的是 API 形状），故留 1.0。
  /// 3. makeThumbnail/applyWatermark：2.0 的 async 成员带 @JavaScriptActor
  ///    隔离，await 之后仍在 JS actor 上恢复执行——图像解码/编码/磁盘写会
  ///    落回 JS 线程；本版 core 没有 @JS(.concurrent) 逃生口（更早的 1.0
  ///    AsyncFunction 是整段后台队列）。要保持"JS 线程不跑图像处理"的契约，
  ///    这两个留在 1.0 DSL。
  public func definition() -> ModuleDefinition {
    // ── 灵动岛状态（自由字典负载）──
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

    // ── 后台快照 / 消息计数（自由字典负载）──
    Function("saveBackgroundSnapshot") { (payload: [String: Any]) in
      TiebaBackgroundSync.shared.saveBackgroundSnapshot(payload)
    }

    Function("getNotificationCounts") { (uid: String) -> [String: Any]? in
      TiebaBackgroundSync.shared.getNotificationCounts(uid: uid)
    }

    // ── 图像处理（线程语义，见上方第 3 条）──
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

    // ── 原生视图（2.0 视图支持尚未落地）──

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

  private var supportsLiveActivities: Bool {
    if #available(iOS 16.2, *) {
      return true
    }
    return false
  }
}
