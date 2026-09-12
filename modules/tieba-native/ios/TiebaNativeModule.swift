// TiebaNative 模块的注册表：这里只保留 definition() 的 Function/View/Events
// 声明与薄桥接；具体实现按职责拆到同目录的扩展文件——
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
      Self.retainEventModule(self)
      Self.installNavBarChromeHooks()
      Self.adoptStatusBarManager()
      Self.installChromeHapticsHooks()
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
      TiebaNativeModule.setHapticChromeHapticsEnabled(enabled)
    }

    // 应用实际主题→原生顶栏 chrome（导航栏/搜索栏材质 trait）：Appearance.
    // setColorScheme 只覆盖 RN 窗口，原生栏仍随系统——"深色常驻+系统浅色"
    // 时顶栏一片白（真机实测 2026-08-26）。force 幂等重挂时顺带改写。
    // 2026-09-02：参数改 Optional——null=跟随系统（自动切换模式），
    // override 还原 unspecified + 窗口底色动态随系统，防"应用手动深色
    // + 系统自动切换"双锁死。
    Function("setChromeUserInterfaceStyle") { (dark: Bool?) in
      TiebaNativeModule.setChromeDarkMode(dark)
      DispatchQueue.main.async {
        TiebaNativeModule.forceNavBarLiquidGlass()
      }
    }

    // v31 路由门控：四个主 tab（关注/动态/消息/我的）顶栏是 RN 自绘搜索行/
    // 页签，栏材质会把它们糊掉（用户实测"无差别模糊"）——JS 按路由开关。
    // v34（2026-09-11）：开=系统默认栏背景（UIKit 原生材质），关=透明；
    // 路由切换即清空"已规范化"标记，让 force 按新路由重写一遍外观。
    Function("setNavBarGlassEnabled") { (enabled: Bool) in
      TiebaNativeModule.setNavBarRouteEnabled(enabled)
      DispatchQueue.main.async {
        TiebaNativeModule.resetBarAppearanceCache()
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

  private var supportsLiveActivities: Bool {
    if #available(iOS 16.2, *) {
      return true
    }
    return false
  }
}