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
    let apply = {
      window.backgroundColor = color
      window.rootViewController?.view.backgroundColor = color
    }
    // 换底色时**在旧、新两份背景之间插值**，而不是瞬切（报告 31 §二-3「克隆出向背景」的思路）：
    // backgroundColor 是 UIView.animate 的可动画属性，隐式动画只补间这两个底色，内容本身
    // 仍由动态色按 trait 立即解析 —— 等价于上游「留一份旧背景与新的插值」，但不需要自己留节点。
    // 三种情况仍走瞬切：窗口还没有底色（启动首帧，见文件头：JS 在 bundle 求值期就下发一次）、
    // 不在前台（回前台补写不值得补间）、开了减弱动态效果（HIG：颜色位移同样属于动态效果）。
    let previous = window.backgroundColor
    let shouldAnimate = previous != nil && previous != color
      && window.windowScene?.activationState == .foregroundActive
      && !UIAccessibility.isReduceMotionEnabled
    if shouldAnimate {
      UIView.animate(
        withDuration: 0.25,
        delay: 0,
        options: [.beginFromCurrentState, .allowUserInteraction],
        animations: apply
      )
    } else {
      apply()
    }
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


