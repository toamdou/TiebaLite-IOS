// 导航栏双击回顶手势（判定在原生，见 navDoubleTapped）。
//
// iOS 27β 上 UITapGestureRecognizer(numberOfTapsRequired:2) 在导航栏上偶发
// "单击即触发"（真机 2026-09-01 实证：点一次就回顶），所以识别单击、自己按
// 400ms 窗口判双击。
import Foundation
import ObjectiveC
import UIKit

extension TiebaChrome {
  enum DoubleTapState {
    /// 双击门卫 delegate 的关联对象键（见 installNavDoubleTapToTop）。
    nonisolated(unsafe) static var gateKey: UInt8 = 0
    /// 双击窗口内的首次单击时刻（0 = 未武装）。
    nonisolated(unsafe) static var lastTapAt: CFTimeInterval = 0
  }

  /// 双击判定窗（对齐底栏双击 400ms）。
  static let navDoubleTapWindow: CFTimeInterval = 0.4

  // MARK: - 导航栏双击回顶（搜索/吧页/帖内/楼中楼；开关在设置-浏览）

  /// 安装幂等：chrome 重扫（事件驱动，见 TiebaNavBarChrome 的空转治理）会反复
  /// 走到这里，按手势类型判重。门卫：左右边缘区与栏内 UIControl 不识别——
  /// 回顶只在标题/空白区触发。
  static func installNavDoubleTapToTop(on bar: UINavigationBar) {
    let installed = bar.gestureRecognizers?.contains { $0 is NavDoubleTapGesture } ?? false
    guard !installed else { return }
    // ⚠️ target 必须是**实例**：类对象对实例 selector responds(to:) == false，
    // 手势触发时是 "unrecognized selector sent to class"（崩溃）。自持 target
    // （手势持有自己）保证识别器的这条引用随 bar 一起存亡。
    let tap = NavDoubleTapGesture()
    tap.addTarget(tap, action: #selector(NavDoubleTapGesture.navDoubleTapped(_:)))
    tap.numberOfTapsRequired = 1
    // 必须关闭 touches 延迟（默认 true）！否则栏内所有 UIControl（返回钮/
    // 搜索钮/药丸）的 touch-up 要等双击判定窗口结束才派发——返回按钮点击
    // 后延迟 ~0.3s 才响应、振动落在返回之后（真机实测 2026-08-26）。
    tap.delaysTouchesBegan = false
    tap.delaysTouchesEnded = false
    // 命中栏内 UIControl（返回钮/按钮）时不启动识别：小目标上快速连点会
    // 被误判成双击回顶，页面跳顶后才弹菜单（真机实测反直觉，2026-08-26）。
    // delegate 须强持有：挂到手势的关联对象上随其存亡。
    let gate = NavDoubleTapGate()
    tap.delegate = gate
    objc_setAssociatedObject(tap, &DoubleTapState.gateKey, gate, .OBJC_ASSOCIATION_RETAIN)
    bar.addGestureRecognizer(tap)
  }

}

/// 导航栏单击手势：双击判定在本类（安装幂等判重也按本类型）。
private final class NavDoubleTapGesture: UITapGestureRecognizer {
  /// 单击只武装，窗口内第二击才回顶（见 installNavDoubleTapToTop 头注释）。
  @objc func navDoubleTapped(_ recognizer: UITapGestureRecognizer) {
    let now = CACurrentMediaTime()
    let elapsed = now - TiebaChrome.DoubleTapState.lastTapAt
    TiebaChrome.DoubleTapState.lastTapAt = elapsed < TiebaChrome.navDoubleTapWindow ? 0 : now
    guard elapsed < TiebaChrome.navDoubleTapWindow,
      TiebaPreferenceSnapshot.bool("navBarDoubleTapToTop", default: true)
    else { return }
    TiebaSceneHaptics.fire("press")
    TiebaNavigator.shared.scrollCurrentToTop()
  }
}

// 双击回顶手势的门卫：点击落在 bar 内 UIControl（或其后代）时不开始识别，
// 把快速连点还给按钮本身（见 installNavDoubleTapToTop 注释）。左右边缘区
// （返回钮/右侧按钮群所在，药丸等非 UIControl 宿主也在）同样不识别——
// 用户在小目标周围空白处连点瞄准时不应触发回顶（真机实测反直觉）。
private final class NavDoubleTapGate: NSObject, UIGestureRecognizerDelegate {
  /// 左右边缘不识别区宽度：返回钮 + 右钮群所在的系统 chrome 区域（经验值，
  /// 覆盖两种按钮布局在最窄机型上的宽度）。
  private static let edgeExclusion: CGFloat = 64

  func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
    guard let bar = g.view else { return true }
    let p = g.location(in: bar)
    let edge = Self.edgeExclusion
    if p.x < edge || p.x > bar.bounds.width - edge { return false }
    // 只认栏内（含后代）的 UIControl：白名单外的祖先即使有控件也与本次命中无关。
    if let control = bar.hitTest(p, with: nil)?.nearestAncestor(where: { $0 is UIControl }),
      control.isDescendant(of: bar)
    {
      return false
    }
    return true
  }
}
