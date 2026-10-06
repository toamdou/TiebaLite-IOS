// ============================================================
// 惯性滚动守卫（TiebaDecelerationGuard）
//
// 移植自上游: submodules/ContextUI/Sources/PeekControllerGestureRecognizer.swift:14-25
// 用法见该文件 :127-139 —— touchesBegan 里命中即把手势置为 .failed。
//
// 为什么需要：本仓列表是**页级 reload + 翻页**模型（TiebaKindListView 的
// applySnapshotUsingReloadData），惯性滚动中长按 → 手指压在 A 行，但 cell 已被
// 复用/换页成 B 行 → 菜单或操作落在**错的楼层**上。
//
// 规则：**手指落下那一刻，只要它下方的滚动视图还在减速，长按一律不成立。**
// 递归下探是为了处理嵌套滚动容器（行内横滑带、楼中楼、图片带）。
//
// 与 TiebaKindListView.swift:679 / :1508 既有 isDecelerating 用法的区别：
// 那两处是"程序化收尾"和"甩动闸门"，都不是长按入口的准入判断。
// ============================================================

import UIKit

@MainActor
enum TiebaDecelerationGuard {
  /// 命中点下方（含嵌套）是否有正在减速的 UIScrollView。
  ///
  /// 上游实现逐字保留；`point` 使用**宿主视图坐标系**。
  static func isDeceleratingScrollView(at point: CGPoint, in view: UIView) -> Bool {
    if view.bounds.contains(point), let scrollView = view as? UIScrollView, scrollView.isDecelerating {
      return true
    }
    for subview in view.subviews {
      if isDeceleratingScrollView(at: view.convert(point, to: subview), in: subview) {
        return true
      }
    }
    return false
  }

  /// 长按准入：惯性滚动中拒绝（供 UIContextMenuInteraction /
  /// UILongPressGestureRecognizer 的入口首行调用）。
  static func shouldAllowLongPress(at point: CGPoint, in view: UIView) -> Bool {
    !isDeceleratingScrollView(at: point, in: view)
  }
}
