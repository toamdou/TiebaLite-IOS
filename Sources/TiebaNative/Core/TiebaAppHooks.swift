import UIKit

// 下层（Core / UI）需要上层（App）能力时的**注入点** —— 依赖倒置的落点。
//
// ── 问题 ──
//   Core 与 UI 原先直接调 TiebaNavigator.shared.*：
//     · Core/Networking/TiebaUserAPI        跳登录 / 账号页（3 处）
//     · Core/Networking/TiebaMessageAPI     消息角标（1 处）
//     · Core/TiebaForegroundNotifier        角标清零 / 回前台补角标（2 处）
//     · Core/TiebaNotificationCenter        通知点击走深链（1 处）
//     · UI/Chrome/TiebaNavDoubleTapToTop    双击回顶（1 处）
//     · UI/Components/TiebaSettingsSupport  换主题 / 状态栏样式 / 设置行压栈（3 处）
//   导航器住在 App 层 ⇒ 下层反向依赖上层（实测 11 个调用点 / 6 个能力），
//   Core 与 UI 就永远不可能单独成库（拆 swift_library 的前提就是这张图无环）。
//
// ── 做法 ──
//   把**下层需要的能力**声明在**下层**（本文件），由上层在 install 时注入实现。
//   口子只按实际调用点开：6 个能力。导航器另外 20+ 个方法仍然只对 App/Features 可见
//   —— 不是把导航器整个抬进 Core 的可见面（那样只是把耦合换了条路走）。
//
// ── 未注入时的语义 ──
//   全部 no-op。单元测试、预览、以及“壳还没装好”的极早期调用都不该崩；语义与
//   “当时没有导航壳可操作”一致（改前这些调用在装壳前也一样落空）。
//
// ── 并发 ──
//   调用点横跨主 actor（UI 回调）与非隔离的后台网络回调（角标、深链），所以快照
//   走 TiebaMutex 而不是 actor 隔离；闭包全部 @Sendable，跨域可传。

nonisolated enum TiebaAppHooks {

  /// 导航器提供的宿主能力（App 层在 TiebaNavigator.install(in:) 里填）。
  struct Routing: Sendable {
    var setTabBadge: (@Sendable (_ index: Int, _ text: String) -> Void)?
    var navigate: (@Sendable (TiebaRoute) -> Bool)?
    var open: (@Sendable (URL) -> Bool)?
    var scrollCurrentToTop: (@Sendable () -> Void)?
    var applyTheme: (@Sendable (TiebaChromeTheme) -> Void)?
    var setDefaultStatusBarStyle: (@Sendable (UIStatusBarStyle) -> Void)?
    /// 签到结果提示。闭包是 @MainActor（提示要碰视图），故这里不收 Sendable 闭包：
    /// @MainActor 的函数类型本身就是 Sendable，参数里的 UIViewController 不必再 Sendable。
    var showSignToast: (@MainActor (String, UIViewController) -> Void)?
  }

  private static let box = TiebaMutex<Routing>(Routing())

  static var routing: Routing {
    get { box.withLock { $0 } }
    set { box.withLock { $0 = newValue } }
  }

  // MARK: - 调用糖（下层只写这些，不直接读 routing）

  static func setTabBadge(index: Int, text: String) { routing.setTabBadge?(index, text) }

  @discardableResult
  static func navigate(_ route: TiebaRoute) -> Bool { routing.navigate?(route) ?? false }

  @discardableResult
  static func open(url: URL) -> Bool { routing.open?(url) ?? false }

  static func scrollCurrentToTop() { routing.scrollCurrentToTop?() }

  static func applyTheme(_ theme: TiebaChromeTheme) { routing.applyTheme?(theme) }

  static func setDefaultStatusBarStyle(_ style: UIStatusBarStyle) {
    routing.setDefaultStatusBarStyle?(style)
  }

  /// 签到结果提示：实现由 UI 层给（UI/Overlay/TiebaSignToast.swift），未装壳前静默。
  @MainActor
  static func showSignToast(_ text: String, on presenter: UIViewController) {
    routing.showSignToast?(text, presenter)
  }
}
