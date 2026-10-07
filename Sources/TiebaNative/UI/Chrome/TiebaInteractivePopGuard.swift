// 交互式返回手势准入（TiebaInteractivePopGuard）
//
// 移植自上游: submodules/Display/Source/InteractiveTransitionGestureRecognizer.swift:10-39
// 的 `hasHorizontalGestures` 命中链探测（上游沿 superview 链上溯，逐级问"这一层
// 是否要吃横向手势"）。
//
// 为什么需要：本仓有 4 处横滑容器 + 2 个 UIPageViewController（段页/图集），
// 而从屏幕左缘起手的右滑返回与它们的横滑是同一段手势。TiebaNavigationShell 原先
// 只判 `viewControllers.count > 1`，
// 于是"在横滑带上右滑"会同时触发切页与返回。
//
// ⚠️ 本文件**不替换系统 interactivePopGestureRecognizer**：替换会丢掉 iOS 26 的
// 转场联动（Liquid Glass 栏过渡 / rubber-band / transitionCoordinator 绑定）。
// 只在既有的 `gestureRecognizerShouldBegin` 里补一个准入判断 —— 也就是
// 10 号报告建议的"给系统手势加 shouldReceive"做法。

import UIKit

/// 显式声明"本视图区域内的横向手势优先，别触发返回"。
/// 用于自动探测覆盖不到的容器（例如自绘的横滑带）。
@MainActor
protocol TiebaHorizontalGestureHost: AnyObject {}

@MainActor
enum TiebaInteractivePopGuard {
  /// 命中点处是否应屏蔽交互式返回：命中链上任一层声明了横向手势宿主、或它是
  /// **横向可滚动**的 UIScrollView（UIPageViewController 内部就是这种 scrollView，
  /// 自动覆盖）⇒ 屏蔽；其余放行。
  static func shouldBlockInteractivePop(at point: CGPoint, in root: UIView) -> Bool {
    guard let hit = hitTestView(at: point, in: root) else { return false }
    var node: UIView? = hit
    while let current = node {
      if current is TiebaHorizontalGestureHost {
        return true
      }
      if let scrollView = current as? UIScrollView, isHorizontallyScrollable(scrollView) {
        return true
      }
      node = current.superview
    }
    return false
  }

  /// 横向可滚动：内容比视口宽，且横向确实可滚（未被禁用）。
  /// 留 1pt 容差，避免等宽容器（含 0.5pt 舍入）被误判。
  private static func isHorizontallyScrollable(_ scrollView: UIScrollView) -> Bool {
    guard scrollView.isScrollEnabled else { return false }
    let overflow = scrollView.contentSize.width - scrollView.bounds.width
    return overflow > 1
  }

  /// 命中点最深的可交互视图（沿 subviews 下探，跳过 hidden / alpha 0 / 不接收触摸的层）。
  private static func hitTestView(at point: CGPoint, in view: UIView) -> UIView? {
    guard !view.isHidden, view.alpha > 0.01, view.isUserInteractionEnabled else { return nil }
    guard view.bounds.contains(point) else { return nil }
    for subview in view.subviews.reversed() {
      let converted = view.convert(point, to: subview)
      if let hit = hitTestView(at: converted, in: subview) {
        return hit
      }
    }
    return view
  }
}
