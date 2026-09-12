import BackgroundTasks
import ExpoModulesCore
import UIKit

/// Expo app delegate 订阅者（expo-module.config.json 的 appDelegateSubscribers）：
/// 启动时注册两个 BGTask handler，实际执行体在 TiebaBackgroundSync。
public class TiebaBackgroundAppDelegate: ExpoAppDelegateSubscriber {
  public func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    // F1 隐私遮罩：从 UserDefaults 镜像恢复应用锁开关，早于 JS 启动生效。
    TiebaPrivacyShield.shared.armFromMirror()
    registerHandler(for: TiebaBackgroundSync.notificationTaskIdentifier)
    registerHandler(for: TiebaBackgroundSync.autoSignTaskIdentifier)
    return true
  }

  private func registerHandler(for identifier: String) {
    // 模拟器守卫：BGTaskScheduler 注册在模拟器不可用（同 submit）。
    #if targetEnvironment(simulator)
    return
    #endif
    BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
      TiebaBackgroundSync.shared.handle(task)
    }
  }
}
