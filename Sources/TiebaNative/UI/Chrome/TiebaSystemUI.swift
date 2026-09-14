// ============================================================
// TiebaSystemUI —— 窗口 / 根视图底色（替代 expo-system-ui 的 setBackgroundColorAsync）
//
// 逐项对照 expo-system-ui/ios/ExpoSystemUIModule.swift（2026-09-13 核对）：
//   - 同一个作用对象：window.backgroundColor **加上** window.rootViewController.view
//     .backgroundColor（expo 注释明写：不设 window 底色时原生 stack 的 modal 会露出
//     错色——本仓 login 是原生 formSheet，同一条约束成立）；
//   - 同一个色值通道：JS 传 processColor 后的 32 位 ARGB（expo 的 setBackgroundColorAsync
//     收的也是 Int?，iOS 侧 EXUtilities.uiColor 按 ARGB 解）；
//   - color == nil（'transparent'）：还原 window 底色为 nil + 根视图按当前
//     traitCollection 取黑/白——expo 原样保留。
//
// 不做 UserDefaults 镜像（expo 有）：它的唯一用途是"下次冷启动 OnCreate 时补一次
// 底色"，而本仓 JS 在 bundle 求值期就下发一次启动底色（useAppBootstrap 顶部），
// 启动到那一刻之间屏幕由 SplashScreen.storyboard 占据——镜像只会变成第二份状态。
//
// 线程：UIWindow/UIViewController 都是 UIKit 对象，只在主线程碰。@JS 同步
// 成员可能从任意线程调用，所以原生
// 入口经 onMain 收束。
// ============================================================
import UIKit

/// 根视图底色。线程契约：**只在主线程读写**（UIWindow/UIViewController 都是
/// UIKit 对象）。入口自带线程守卫，不标 @MainActor——调用点 onMain 的闭包是
/// nonisolated，标了反而编译不过；这里的"主线程纪律"由守卫兜底。
enum TiebaSystemUI {
  static func setBackgroundColor(_ color: UIColor?) {
    guard Thread.isMainThread else {
      DispatchQueue.main.async { setBackgroundColor(color) }
      return
    }
    guard let window = keyWindow() else { return }
    guard let color else {
      window.backgroundColor = nil
      let isDark = window.traitCollection.userInterfaceStyle == .dark
      window.rootViewController?.view.backgroundColor = isDark ? .black : .white
      return
    }
    window.backgroundColor = color
    window.rootViewController?.view.backgroundColor = color
  }

  /// 本 App 的 key window：场景化 App（UIApplicationSceneManifest 已声明），
  /// 优先前台活跃场景的 keyWindow，退而取任一场景的首窗（UIScreen.main 在
  /// iOS 26 已废弃，不能再用）。
  private static func keyWindow() -> UIWindow? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    guard let scene else { return nil }
    return scene.windows.first { $0.isKeyWindow } ?? scene.windows.first
  }

}

/// 应用版本（替代 expo-constants 的 Constants.expoConfig.version）。
///
/// releaseService.currentAppVersion() 取的就是"构建产物的版本号"：expo prebuild
/// 把 app.json 的 version 写进 Info.plist 的 CFBundleShortVersionString，所以读
/// bundle 与读 expoConfig.version 是同一个值；拿不到（测试宿主/未打戳）时回空串，
/// JS 侧沿用既有的 APP_VERSION 常量兜底（旧代码 `?? APP_VERSION` 的分支不变）。
enum TiebaAppInfo {
  static func appVersion() -> String {
    let info = Bundle.main.infoDictionary
    if let short = info?["CFBundleShortVersionString"] as? String, !short.isEmpty {
      return short
    }
    return info?["CFBundleVersion"] as? String ?? ""
  }
}
