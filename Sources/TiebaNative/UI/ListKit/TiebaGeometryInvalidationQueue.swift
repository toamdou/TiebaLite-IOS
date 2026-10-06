// ============================================================
// 几何失效事务队（TiebaGeometryInvalidationQueue）
//
// 把散落在列表视图各处的 layout 失效收成一条队：同一次 runloop 内的 N 次请求只落成
// 一次真正的失效（入队去重）。移植口径见
// docs/uikit-migration/00-总览与结论.md §4.1 第 3 点（上游 上游：
// Display/Source/ListViewTransactionQueue.swift:14-66 +
// ListView.swift:4607-4631 的 enqueueUpdateVisibleItems 去重）。
//
// 为什么用 DispatchQueue.main.async，而不是 CFRunLoopObserver(.beforeWaiting)：
// 1. 入队本身就是一次唤醒源（主队列的 mach port 被 signal）。观察者是"搭车"型：
//    在 runloop 已经走完 beforeWaiting 之后才 AddObserver（典型 = 在 layoutSubviews
//    里入队，此刻正处在 CA 的 commit 观察者内部）既不唤醒 runloop、本轮也不会再跑
//    观察者，失效得等下一次无关事件才落地，中间那帧就是旧几何；主队列入队则保证
//    下一轮循环立刻开始。
// 2. 主队列 drain 发生在 runloop 的 source 段，早于 CA 的 commit 观察者
//    （order 2000000）：合并后的失效仍落在当帧——一次变更 = 一次真失效，不多一帧。
// 3. 没有 observer 的生命周期问题：CFRunLoopAddObserver 会让 runloop 强持有
//    observer，队列先释放时必须 Invalidate（deinit 里做还要跨隔离），而主队列 block
//    用 [weak self] 天然安全。
// ============================================================

import Foundation

/// 轻量几何失效队：同一次 runloop 内的多次请求合并成一次 `apply`。
///
/// - 主线程专属（几何失效只可能发生在主线程，故整类标 @MainActor）。
/// - `invalidate()` = 弱失效（`invalidateLayout()` 即可，几何真变了才重建）；
///   `invalidateAndRebuild()` = 强失效（清掉布局的输入快照，属性必须重建）。
///   同一批里只要出现过一次强失效，合并后的那一次就走强失效——强失效是弱失效的超集。
@MainActor
final class TiebaGeometryInvalidationQueue {
  /// 合并后的那一次真正执行（rebuild = 这一批里是否出现过强失效请求）。
  private let apply: (_ rebuild: Bool) -> Void

  /// 这一批里是否出现过强失效请求。
  private var needsRebuild = false
  /// 已排队、尚未执行。
  private var isScheduled = false

  /// debug：入队请求次数（去重前）。
  private(set) var requestCount = 0
  /// debug：真正执行的失效次数（一次数据变更应当只 +1）。
  private(set) var flushCount = 0

  init(apply: @escaping (_ rebuild: Bool) -> Void) {
    self.apply = apply
  }

  /// 请求一次几何失效（弱）：同一 runloop 内重复调用只排一次队。
  func invalidate() {
    enqueue(rebuild: false)
  }

  /// 请求一次几何失效（强）：布局属性必须重建（TiebaRowListLayout.invalidateAndRebuild）。
  func invalidateAndRebuild() {
    enqueue(rebuild: true)
  }

  private func enqueue(rebuild: Bool) {
    requestCount += 1
    if rebuild {
      needsRebuild = true
    }
    guard !isScheduled else { return }
    isScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.isScheduled = false
      let rebuild = self.needsRebuild
      self.needsRebuild = false
      self.flushCount += 1
      self.apply(rebuild)
    }
  }
}
