// 启动画面控制——替代 expo-splash-screen。
//
// 机制选择：expo 的方案是把 storyboard 的 view 挂到 RN root view 的
// loadingView 上（依赖 RCTSurfaceHostingProxyRootView 的内部字段，expo 自己的
// 源码注释都写明"新架构下 customizeRootView 的 cast 不再可靠"）。这里改用
// 独立的全屏子 VC：把 SplashScreen.storyboard 的初始 VC 作为 child 盖在导航壳
// 根 VC 上，hide 时淡出移除——与 RN 版本/内部结构完全解耦。
//
// storyboard 本体仍是 ios/tiebalite/SplashScreen.storyboard（launchScreen=YES），
// 其中的 named color / image asset 按系统亮暗自动取图，深浅色启动不闪白。
//
// 时序：preventAutoHide 由 JS 在 bundle 求值期调用（早于首帧提交），因此
// "系统撤掉 launch storyboard"的那一帧里我们的 splash 已经盖在 window 上，
// 不会露出中间内容帧。若 JS 从未调 hide（bundle 崩溃），splash 会一直盖着——
// 与 expo preventAutoHide 的语义一致，不做超时自动撤销（会把崩溃伪装成正常）。
//
// ------------------------------------------------------------
// 本次接线（task-12，落地说明见 docs/uikit-migration/22-接线-viewport.md）：
//   1) 淡出仍走系统 UIView.animate（判据③：系统接口更优就别动；本处不需要可中断/可拖拽）。
//   2) 并发：原来靠 @unchecked Sendable 把线程安全交给"约定"（入口先查 isMainThread 再 hop）。
//      本类是单例、会被 JS 桥从任意线程调，所以可变状态收进 TiebaMutex<State>（TiebaMutex shim：iOS 18 的 Synchronization.Mutex 在 iOS 17 不可用，见 Core/TiebaMutex.swift），
//      类型改成真 Sendable —— 没有 nonisolated(unsafe) / @unchecked Sendable / assumeIsolated。
//      视图操作仍然只在主线程做：入口的 isMainThread 检查与 hop 原样保留。
// ============================================================
import UIKit
import os

final class TiebaSplashController: Sendable {
  static let shared = TiebaSplashController()
  private static let log = Logger(subsystem: "com.tiebalite.app", category: "splash")

  /// 可变状态（见文件头改动 2）。三个字段都在锁里读写：
  ///   fade / duration ← JS setOptions 下发（任意线程）
  ///   splashViewController ← preventAutoHide/hide 里挂上与摘下的那个覆盖 VC（只在主线程动）
  private struct State {
    var fade = true
    var duration: TimeInterval = 0.28
    var splashViewController: UIViewController?
  }

  private let state = TiebaMutex(State())

  private init() {}

  func setOptions(fade: Bool, durationMs: Double) {
    // 淡出参数（duration 毫秒口径与 JS setOptions({duration}) 一致）。
    // 默认 280ms 与本仓原 SplashScreen.setOptions 的下发值一致。
    state.withLock {
      $0.fade = fade
      $0.duration = max(0, durationMs / 1000)
    }
  }

  /// 挂上 splash（幂等）。JS 的 preventAutoHideAsync 走这里。
  func preventAutoHide() {
    guard Thread.isMainThread else {
      DispatchQueue.main.async { self.preventAutoHide() }
      return
    }
    guard state.withLock({ $0.splashViewController }) == nil else { return }
    guard let host = Self.rootViewController() else {
      // JS 调 preventAutoHide 时导航壳必已 install，走到这里说明启动顺序被改坏。
      // 记日志而不是静默：splash 不生效表现为用户可见的启动闪烁。
      Self.log.error("no root view controller yet; splash not attached")
      return
    }
    guard let splash = Self.makeSplashViewController() else { return }
    // 覆盖层必须盖满整屏（含安全区），所以这里仍取宿主视图的 bounds，
    // 覆盖层盖满整屏，不套用页面内容的安全区语义。
    splash.view.frame = host.view.bounds
    splash.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    // 只做视图覆盖，不能建立 VC 容器关系：host 是 UINavigationController，
    // 对它 addChild 会被当成一次 push（启动屏进栈 → 导航栏显形且 removeFromParent
    // 移不掉，表现为白屏 + 返回键）。
    host.view.addSubview(splash.view)
    state.withLock { $0.splashViewController = splash }
  }

  /// 淡出并移除（幂等）。JS 的 hideAsync 走这里；preventAutoHide 未调用时是
  /// no-op（此时由系统 launch storyboard 自己管显隐，不应凭空造一个 splash）。
  func hide() {
    guard Thread.isMainThread else {
      DispatchQueue.main.async { self.hide() }
      return
    }
    let (splash, fade, duration) = state.withLock {
      let splash = $0.splashViewController
      let fade = $0.fade
      let duration = $0.duration
      $0.splashViewController = nil
      return (splash, fade, duration)
    }
    guard let splash else { return }
    // 淡出用系统 UIView.animate：判据③的直接例子 —— 转场引擎那套包装在这里没有任何额外能力
    // （不可中断、不可拖拽），只是更绕。
    let remove = {
      splash.view.removeFromSuperview()
    }
    if fade && duration > 0 {
      // [修复] 此处保留裸 UIView.animate：该调用点在 nonisolated 上下文，而统一入口是 @MainActor
      // （@MainActor 是必需的 —— 它要转发非 Sendable 闭包，见 TiebaAnimation 文件头）。
      // 按「只换入口」的边界不做 MainActor 化改造，时长与曲线原样保留。
      UIView.animate(withDuration: duration, animations: {
        splash.view.alpha = 0
      }, completion: { _ in remove() })
    } else {
      remove()
    }
  }

  // MARK: - 宿主 / storyboard

  /// key window 的 rootViewController。启动期 window 可能还没 key，
  /// 退到该 scene 的第一个 window（install 已把壳设成 rootViewController）。
  private static func rootViewController() -> UIViewController? {
    for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
      if let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first {
        return window.rootViewController
      }
    }
    return nil
  }

  /// storyboard 名与 expo 同款查找：Info.plist 的 UILaunchStoryboardName，
  /// 缺省 "SplashScreen"（本仓 ios/tiebalite/SplashScreen.storyboard）。
  private static func makeSplashViewController() -> UIViewController? {
    let name = Bundle.main.object(forInfoDictionaryKey: "UILaunchStoryboardName") as? String
      ?? "SplashScreen"
    guard Bundle.main.path(forResource: name, ofType: "storyboardc") != nil else {
      log.error("launch storyboard \(name, privacy: .public) missing from bundle; splash control disabled")
      return nil
    }
    return UIStoryboard(name: name, bundle: nil).instantiateInitialViewController()
  }
}