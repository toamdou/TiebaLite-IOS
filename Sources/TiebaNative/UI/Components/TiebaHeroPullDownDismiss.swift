// 「下拉关闭帖子页」的手势驱动（Hero 交互式转场）。
//
// 对应 Hero 文档 InteractiveTransition 页：Hero 只提供原语，手势要宿主自己接——
//   开始：Hero.shared.setDefaultAnimationForNextTransition(...) + 触发返回
//   过程：Hero.shared.update(progress:)（会接管 Hero 自己的 CADisplayLink）
//   结束：Hero.shared.finish() / cancel()
//
// 为什么不是"挂一个 pan 就开始推"：Hero 的 interactiveTransitioning 返回自己，且
// wantsInteractiveStart = true ⇒ 转场一旦开始就会用 CADisplayLink 自动跑完
// （见 HeroTransition+UIViewControllerTransitioningDelegate.swift:77 与
// HeroProgressRunner.start）。所以必须在**触发返回之前**把手势进度写进
// startingProgress（HeroTransition+Animate.swift:72 的分支），转场才会停在那里等
// 后续 update。这里的做法：手势 .began 时先 update(0)，再触发 pop。
//
// 与既有手势的分工（三条都要让路，否则会互相抢）：
//   1. 列表滚动：只在**贴顶**时接管（下拉超过顶部内白才算，否则是正常滚动/下拉刷新）；
//   2. 系统左滑返回（interactivePopGestureRecognizer）：它只在屏幕左缘起手，
//      本手势要求纵向为主，且用 shouldRecognizeSimultaneously 放行；
//   3. 卡片内横滑图片带：本手势在纵向位移小于横向时直接失败（同查看器的门控）。
//
// ⚠️ 只在"从列表点进来"的帖子页装（有源卡片才好缩回；深链直达没有源，缩回目标
// 会退化成整页淡出——那不是用户要的，所以那种情况不装手势）。
import UIKit
import Hero

@MainActor
final class TiebaHeroPullDownDismiss: NSObject, UIGestureRecognizerDelegate {
  /// 触发关闭的进度阈值（拖过屏高这个比例就关闭，否则回弹）。
  private static let dismissThreshold: CGFloat = 0.28
  /// 触发关闭的速度阈值（pt/s）：快速轻扫即使没拖够也关闭。
  private static let velocityThreshold: CGFloat = 900
  /// 纵向位移必须超过横向这么多倍才认定是"下拉"（避免误吃卡片横滑）。
  private static let directionBias: CGFloat = 1.4

  private weak var viewController: UIViewController?
  private weak var scrollView: UIScrollView?
  private weak var gesture: UIPanGestureRecognizer?
  /// 本次手势是否已经接管了 Hero 转场（.began 时触发返回，成功才置位）。
  private var isDriving = false
  /// 贴顶判定用的顶部内白快照（手势开始时取一次，过程中不重取）。
  private var topInset: CGFloat = 0

  init(viewController: UIViewController, scrollView: UIScrollView) {
    self.viewController = viewController
    self.scrollView = scrollView
    super.init()
    let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
    pan.delegate = self
    // 让路：列表自己的滑动、系统左缘返回、图片带横滑都不能被本手势延迟。
    pan.cancelsTouchesInView = false
    pan.delaysTouchesBegan = false
    pan.delaysTouchesEnded = false
    viewController.view.addGestureRecognizer(pan)
    gesture = pan
  }

  /// 页面销毁时摘掉（gesture 挂在 view 上，view 先走也没关系；这里显式清语义）。
  func detach() {
    if let gesture, let view = viewController?.view {
      view.removeGestureRecognizer(gesture)
    }
    gesture = nil
  }

  // MARK: - 手势

  @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
    guard let host = viewController, let scroll = scrollView, let nav = host.navigationController
    else { return }
    let translation = pan.translation(in: host.view)
    let velocity = pan.velocity(in: host.view)
    let height = max(host.view.bounds.height, 1)

    switch pan.state {
    case .began:
      // 贴顶才算下拉关闭：不在顶部时让列表正常滚（含下拉刷新）。
      let offset = scroll.contentOffset.y + scroll.adjustedContentInset.top
      guard offset <= 1 else {
        pan.state = .failed
        return
      }
      topInset = scroll.adjustedContentInset.top
      // 先把手势进度写进 Hero（update 在非动画态只是记 startingProgress），
      // 再触发返回：转场开始时 Hero 会 update(startingProgress) 停在这里等我们。
      Hero.shared.update(0)
      isDriving = true
      nav.popViewController(animated: true)

    case .changed:
      guard isDriving else { return }
      // 纵向为主才继续（横向是图片带的手势）。
      guard translation.y > abs(translation.x) * Self.directionBias else { return }
      let progress = max(0, translation.y / height)
      Hero.shared.update(progress)
      // 跟手：越往下拖，列表越"让位"（负偏移 = 内容跟着手指下移）。
      scroll.contentOffset.y = -topInset + max(0, translation.y)

    case .ended, .cancelled, .failed:
      guard isDriving else { return }
      isDriving = false
      let projected = translation.y + velocity.y * 0.12
      let shouldDismiss = translation.y > height * Self.dismissThreshold
        || velocity.y > Self.velocityThreshold
        || projected > height * Self.dismissThreshold
      if shouldDismiss {
        Hero.shared.finish()
      } else {
        // 回弹：列表偏移复位由 Hero 的 cancel 动画带着走（转场反向跑回去），
        // 这里只清跟手残留，避免内容停在半空。
        Hero.shared.cancel()
        let inset = topInset
        UIView.animate(withDuration: 0.24, delay: 0, options: [.curveEaseOut]) {
          scroll.contentOffset.y = -inset
        }
      }

    default:
      break
    }
  }

  // MARK: - UIGestureRecognizerDelegate

  /// 与列表滚动、系统左缘返回并存（不抢、不延迟）。
  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
  ) -> Bool {
    true
  }

  /// 只接纵向下拉：横向起手直接判失败，把触摸留给图片带/左滑返回。
  func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    guard let pan = gestureRecognizer as? UIPanGestureRecognizer,
          let host = viewController
    else { return false }
    // 转场进行中不新开（Hero 自己在跑）。
    guard !Hero.shared.isTransitioning else { return false }
    let velocity = pan.velocity(in: host.view)
    return velocity.y > abs(velocity.x) * Self.directionBias
  }
}
