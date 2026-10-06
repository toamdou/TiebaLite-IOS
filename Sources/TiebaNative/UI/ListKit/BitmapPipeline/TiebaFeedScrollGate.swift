// ============================================================
// TiebaLite — 异步位图管线 · 滚动闸门（甩动期降并发）
//
// 依据：docs/uikit-migration/07-ObjC++转Swift可行性.md §3.6
// 上游：_ASAsyncTransaction.mm:221-235
//
//   NSUInteger maxThreads = [NSProcessInfo processInfo].activeProcessorCount * 2;
//   // Bit questionable maybe - we can give main thread more CPU time during tracking.
//   if ([[NSRunLoop mainRunLoop].currentMode isEqualToString:UITrackingRunLoopMode])
//     --maxThreads;
//   if (entry._threadCount < maxThreads) { ... }
//
// 三个必须说清楚的事实（报告原话）：
//   1. 它**只影响「要不要新开一条线程」**：已经开跑的那次不会因此停下来；
//   2. 判据等价于 scrollView.isDragging / isDecelerating；
//   3. ASDK 自己在源码里写了「Bit questionable maybe」——**别把它当主力**。
//      真正省帧的是「不要在主线程排版」（本管线）与「预取提前量」。
//
// 本文件的 isScrolling 有三条判据，**从强到弱**：
//   ① 显式驱动（推荐）：列表在 scrollViewDidScroll / willBeginDragging 里调 update(...)；
//   ② 宿主推断：从画布往上找 UIScrollView 读 isDragging / isDecelerating
//      —— 零接线即可生效（拖拽与惯性都覆盖）；
//   ③ 主 runloop 模式：RunLoop.main.currentMode == .tracking
//      —— 与 ASDK 逐字同款的兜底（非主线程不读）。
// 三条都不成立 = 静止 ⇒ limit 放开（静止期走同步兜底，不进后台）。
// ============================================================

import Synchronization
import UIKit

public final class TiebaFeedScrollGate: Sendable {
  public static let shared = TiebaFeedScrollGate()

  private struct State: Sendable {
    var dragging = false
    var decelerating = false
    /// 整列表不可见（离屏 / 查看器打开）：对应 TiebaKindListView 的 updatePrefetcherPause。
    /// **不降到 0**：0 会让待跑队列积压，而解锁那一刻未必有人来重新驱动画布。
    var paused = false
  }

  private let state = Mutex(State())

  public init() {}

  // MARK: - 驱动（主线程调用）

  /// 显式驱动（推荐接线点：UICollectionView 的 scrollViewDidScroll + willBeginDragging/
  /// didEndDragging，TiebaKindListView.swift:1487-1495 已经在算这个 moving）。
  public func update(isDragging: Bool, isDecelerating: Bool) {
    state.withLock {
      $0.dragging = isDragging
      $0.decelerating = isDecelerating
    }
  }

  // MARK: - 查询

  /// 是否处于滚动中（判据 ① 或 ③）。**可跨线程读**（只碰 Mutex 与主 runloop 模式判定）。
  public var isScrolling: Bool {
    if state.withLock({ $0.dragging || $0.decelerating }) { return true }
    // 判据 ③：主 runloop 模式只能在主线程读；非主线程保守地按「未滚动」处理
    // （未滚动 = 同步兜底 = 旧行为，不会有并发风险）。
    guard Thread.isMainThread else { return false }
    return RunLoop.main.currentMode == .tracking
  }

  /// 判据 ②：从某个视图往上找宿主 UIScrollView 读实时状态。
  /// 只读两个属性、最多几层 superview，纳秒级；由画布在**未命中缓存**那一刻调一次。
  @MainActor
  public func isScrolling(in view: UIView) -> Bool {
    if isScrolling { return true }
    var node: UIView? = view.superview
    while let current = node {
      if let scrollView = current as? UIScrollView {
        return scrollView.isDragging || scrollView.isDecelerating
      }
      node = current.superview
    }
    return false
  }

  /// 后台并发上限：滚动中 1（对应 ASDK 的 --maxThreads），静止放开到 CPU-1（至少 2）。
  public var limit: Int {
    if state.withLock({ $0.paused }) { return 1 }
    if isScrolling { return 1 }
    return max(ProcessInfo.processInfo.activeProcessorCount - 1, 2)
  }
}
