internal import Expo
import React
import ReactAppDependencyProvider

@main
class AppDelegate: ExpoAppDelegate, UIWindowSceneDelegate {
  var window: UIWindow?

  var reactNativeDelegate: ExpoReactNativeFactoryDelegate?
  var reactNativeFactory: RCTReactNativeFactory?

  public override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
#if !DEBUG
    // 诊断日志（仅 Release）：运行时查找 tieba-system 模块内的安装器——
    // 不跨 pod import（模块名由 autolinking 生成，硬编码易碎）；类不存在
    // （老二进制/未链接）时静默跳过。安装动作本身 <1ms。
    if let crashReporterClass = NSClassFromString("TiebaSystemCrashReporter") as? NSObject.Type,
       crashReporterClass.responds(to: NSSelectorFromString("install")) {
      _ = crashReporterClass.perform(NSSelectorFromString("install"))
    }
#endif
    // RN 初始化移入 scene(_:willConnectTo:)，这里只转发 super。
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // MARK: - UISceneDelegate（iOS 13+ 场景生命周期）

  public func application(
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

  public func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    guard let windowScene = scene as? UIWindowScene else { return }

    let delegate = ReactNativeDelegate()
    let factory = ExpoReactNativeFactory(delegate: delegate)
    delegate.dependencyProvider = RCTAppDependencyProvider()

    reactNativeDelegate = delegate
    reactNativeFactory = factory

    // 冷启动 deep link：connectionOptions.urlContexts → launchOptions[.url]
    var launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    if let url = connectionOptions.urlContexts.first?.url {
      launchOptions = [.url: url]
    }

    window = UIWindow(windowScene: windowScene)
    factory.startReactNative(
      withModuleName: "main",
      in: window,
      launchOptions: launchOptions)
    window?.makeKeyAndVisible()
  }

  public func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    // 转发到 application 级，保住 RCTLinkingManager / expo-linking。
    for context in URLContexts {
      _ = application(UIApplication.shared, open: context.url, options: [:])
    }
  }

  // Linking API
  public override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    return super.application(app, open: url, options: options) || RCTLinkingManager.application(app, open: url, options: options)
  }

  // Universal Links
  public override func application(
    _ application: UIApplication,
    continue userActivity: NSUserActivity,
    restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void
  ) -> Bool {
    let result = RCTLinkingManager.application(application, continue: userActivity, restorationHandler: restorationHandler)
    return super.application(application, continue: userActivity, restorationHandler: restorationHandler) || result
  }
}

class ReactNativeDelegate: ExpoReactNativeFactoryDelegate {
  // Extension point for config-plugins

  override func sourceURL(for bridge: RCTBridge) -> URL? {
    // needed to return the correct URL for expo-dev-client.
    bridge.bundleURL ?? bundleURL()
  }

  override func bundleURL() -> URL? {
#if DEBUG
    return RCTBundleURLProvider.sharedSettings().jsBundleURL(forBundleRoot: ".expo/.virtual-metro-entry")
#else
    return Bundle.main.url(forResource: "main", withExtension: "jsbundle")
#endif
  }
}
