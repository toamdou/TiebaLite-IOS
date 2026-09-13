// Chrome HDR 按压高光（返回钮 / 导航栏右钮 / 底栏钮）。
//
// 判定挂在系统栏自身（UINavigationBar / UITabBar）的 0 秒长按手势上：触摸按下即
// began，命中点用 hitTest 在栏内找 UIControl。栏外内容（列表、行内控件）按构造
// 不参与命中——不再 swizzle UIView/UIControl 的 touchesBegan（全 App 每次触摸都
// 走那条路是热路径浪费）。
import Foundation
import UIKit

extension TiebaChrome {
  enum HapticsState {
    /// 同控件去重：pop 转场期间 UIKit 会重放一次按压，连按也从两次降至一次。
    nonisolated(unsafe) static var lastChromeControl: UIControl?
    nonisolated(unsafe) static var lastChromeAt: TimeInterval = 0
  }

  /// 触觉总开关转发：真相源在 TiebaHaptics 引擎层（见 TiebaHaptics.isEnabled），
  /// chrome 文件不再持有第二份 enabled。
  static var hapticChromeHapticsEnabled: Bool { TiebaHaptics.isEnabled }

  static func setHapticChromeHapticsEnabled(_ enabled: Bool) { TiebaHaptics.setEnabled(enabled) }

  /// 安装入口（保留原调用点）。按压判定不 swizzle、不需要安装期工作：手势按栏
  /// 挂载（TiebaRootNavigationController / TiebaMainTabBarController 的 viewDidLoad），
  /// chrome 重扫也会给扫到的每一根栏补齐（见 forceNavBarLiquidGlass）。这里只
  /// 保证启动后有一次重扫兜底。
  static func installChromeHapticsHooks() {
    markChromeDirty()
    scheduleChromeTick()
  }

  // MARK: - Chrome HDR 按压高光（返回钮 / 导航栏右钮 / 底栏钮）

  /// 栏上的按压判定手势（幂等：同一栏只挂一个；栏重建会带来新栏，需重挂）。
  /// 系统 chrome 按钮（返回箭头、headerRight 原生钮、底栏项）是 UIControl，命中
  /// 的往往是按钮内部的子视图（chevron imageView），所以判定从 hitTest 结果向上
  /// 找最近 UIControl，并要求它仍在栏内（栏外祖先的控件与本次命中无关）。
  static func installChromePressHaptics(on bar: UIView) {
    let installed = bar.gestureRecognizers?.contains { $0 is ChromePressGesture } ?? false
    guard !installed else { return }
    // ⚠️ target 必须是**实例**（同 NavDoubleTapGesture）：传类对象时实例 selector
    // 不响应，手势触发即 "unrecognized selector sent to class"。自持 target。
    let press = ChromePressGesture(target: nil, action: nil)
    press.minimumPressDuration = 0
    press.addTarget(press, action: #selector(ChromePressGesture.chromePressed(_:)))
    // 不动栏内按钮自己的触摸链路：识别器只做判定，不消费也不延迟触摸。
    press.cancelsTouchesInView = false
    press.delaysTouchesBegan = false
    press.delaysTouchesEnded = false
    // 0 秒长按在触摸按下即 .began；默认它会"阻止"同栏其它识别器（bar 上还挂着
    // 双击回顶的单击手势），这里显式允许并存。
    press.delegate = press
    bar.addGestureRecognizer(press)
  }

  /// 一次栏内按压的反馈（判定源见 ChromePressGesture；栏外与空白区不反馈）。
  static func applyChromePress(on bar: UIView, at point: CGPoint) {
    let hit = bar.hitTest(point, with: nil)
    guard
      let target = (hit as? UIControl)
        ?? (hit?.nearestAncestor(where: { $0 is UIControl }) as? UIControl),
      target.isDescendant(of: bar),
      target.bounds.width > 0, target.bounds.height > 0,
      // 栏内可能混坐着非按钮控件（titleView 的分段控件/搜索框）：它们自带系统
      // 按压态，不给 chrome 高光。按类型判（公开 API），不按私有类名字符串嗅探。
      !isNonButtonControl(target)
    else { return }
    // 双通道与重放去重：同一控件 800ms 内只反馈一次。返回键曾被实测「点击一次
    // 振两次」：pop 转场期间 UIKit 向原按钮重放一次按压（约 150-400ms 后，250ms
    // 去重窗之外），第二次振动恰落在「返回上一级之后」（2026-08-27 真机复现）。
    let now = ProcessInfo.processInfo.systemUptime
    if target === HapticsState.lastChromeControl, now - HapticsState.lastChromeAt < 0.8 { return }
    HapticsState.lastChromeControl = target
    HapticsState.lastChromeAt = now
    // 底栏项：临时关闸只放行 HdrChromeFlash 的光效（内嵌触觉读的就是引擎层闸门，
    // 同步读、同步发，关闸窗口内没有第二条触觉路径）。底栏触觉归
    // TiebaMainTabBarController 的场景表（segment / 重按 press），否则同一次
    // 点击亮两下且绕过设置的力度/静音。
    let gate = TiebaHaptics.isEnabled
    if bar is UITabBar { TiebaHaptics.setEnabled(false) }
    HdrChromeFlash.play(on: target)
    TiebaHaptics.setEnabled(gate)
  }

  /// 非按钮类控件（自带系统按压态，不叠 chrome 高光）。只列公开类型，不用类名。
  private static func isNonButtonControl(_ control: UIControl) -> Bool {
    control is UISegmentedControl || control is UITextField || control is UISwitch
      || control is UISlider || control is UIStepper || control is UIPageControl
  }
}

/// 系统栏上的按压判定：0 秒长按 = 触摸按下即 began（等同 touchesBegan 时机），
/// 抬手/失败不做事。挂在栏上而不是全视图树，命中范围天然收在栏内。
///
/// delegate = 自己（手势持有自己；delegate 是弱引用，手势活着它就活着）：
/// 0 秒长按默认会阻止同栏的其它识别器，双击回顶的单击手势就在同一根栏上，
/// 必须放行共存。
private final class ChromePressGesture: UILongPressGestureRecognizer, UIGestureRecognizerDelegate {
  @objc func chromePressed(_ recognizer: UILongPressGestureRecognizer) {
    guard recognizer.state == .began, let bar = recognizer.view else { return }
    TiebaChrome.applyChromePress(on: bar, at: recognizer.location(in: bar))
  }

  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
  ) -> Bool {
    true
  }
}
