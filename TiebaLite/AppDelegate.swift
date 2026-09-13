import TiebaNative
import UIKit

/// 纯 Swift 应用入口（无 Expo / 无 RN）：场景生命周期 + 原生导航壳。
@main
class AppDelegate: UIResponder, UIApplicationDelegate, UIWindowSceneDelegate {
  var window: UIWindow?

  /// launch 阶段必须完成的事（BGTask handler 注册、通知中心 delegate）：
  /// 冷启动点通知的响应只在 launch 阶段可达，晚了就整个丢掉。
  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    TiebaAppBootstrap.shared.installLaunchHandlers()
    return true
  }

  // MARK: - UISceneDelegate（iOS 13+ 场景生命周期）

  func application(
    _ application: UIApplication,
    configurationForConnecting connectingSceneSession: UISceneSession,
    options: UIScene.ConnectionOptions
  ) -> UISceneConfiguration {
    let configuration = UISceneConfiguration(
      name: "Default Configuration",
      sessionRole: connectingSceneSession.role)
    configuration.delegateClass = AppDelegate.self
    return configuration
  }

  func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    guard let windowScene = scene as? UIWindowScene else { return }

    let window = UIWindow(windowScene: windowScene)
    self.window = window
    // 导航壳接管根视图：原生栈 + 原生底栏 + 原生页面。
    TiebaNavigator.shared.install(in: window)
    // 纯原生启动路径（主题/启动图/偏好下发）。必须早于 makeKeyAndVisible：
    // 启动图要在首帧前就位。
    TiebaAppBootstrap.shared.start(in: window)
    window.makeKeyAndVisible()

    // 冷启动深链在壳建好之后再派发（原生解析）。
    if let url = connectionOptions.urlContexts.first?.url {
      _ = TiebaNavigator.shared.open(url: url)
    }

    // 通知冷启动：scene 的 connectionOptions.notificationResponse 与
    // UNUserNotificationCenterDelegate 是两条并行投递通道（iOS 13+ scene 应用），
    // 只接后者会丢掉"点通知冷启动"的深链。TiebaNotificationCenter 内部按
    // 通知 id + 投递时刻去重，两条都到也只导航一次。
    if let response = connectionOptions.notificationResponse {
      TiebaNotificationCenter.shared.handle(response: response)
    }
  }

  /// URL 入口之一：scene 通道（另一种是下面的 application 通道）。
  func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    for context in URLContexts {
      _ = TiebaNavigator.shared.open(url: context.url)
    }
  }

  // MARK: - scene 生命周期转发

  /// 前台轮询/触觉引擎统一挂 scene 回调，不再各挂一份 UIApplication 通知
  /// 观察者（来源唯一、顺序确定）。
  func sceneDidBecomeActive(_ scene: UIScene) {
    TiebaAppBootstrap.shared.sceneDidBecomeActive()
  }

  func sceneDidEnterBackground(_ scene: UIScene) {
    TiebaAppBootstrap.shared.sceneDidEnterBackground()
  }

  /// URL 入口之二：application 通道（scene 之外的唤起路径）。两条都进同一张
  /// 原生路由表，不设第二条解析路径。
  func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    TiebaNavigator.shared.open(url: url)
  }
}
