// ============================================================
// TiebaLite — 异步位图管线 · 烘焙器（在途去重 + 并发上限 + 四级取消的调度侧）
//
// 依据：docs/uikit-migration/07-ObjC++转Swift可行性.md §5.2 / §5.3 / §5.4
//
// 并发三条铁律的第 ② 条在这里：**共享可变状态 = TiebaMutex<State>，不用 actor**。
//   - actor 会多一次 await hop，且「并发上限 + 在途去重」用 actor 反而更绕
//     （要在 await 之间保持不变量）；
//   - Mutex 正好对上 ASDK 的 AS::Mutex 语义（ASThread.h:104-260 不过是把
//     std::mutex / os_unfair_lock 包了一层），并且 withLock 是同步的 ——
//     「查在途 → 占额度 → 入队」必须是原子的。
//
// 与 ASDK 的对应关系：
//   inFlight + active   ←→ _ASAsyncTransaction.mm:206-235 的 _threadCount / maxThreads
//                           与 std::map<dispatch_queue_t, DispatchEntry>
//   limitProvider       ←→ _ASAsyncTransaction.mm:224-228（UITrackingRunLoopMode 时 --maxThreads）
//   renderSync          ←→ _ASDisplayLayer.mm:150-158 的 displayImmediately
//   取消                ←→ ASDisplayNode+AsyncDisplay.mm:341-351（sentinel）+ :216-219（分段）
// 丢弃的：优先级桶（drawingPriority 是「预加载档 vs 可视档」两级需求，接收方只有一个需求档，
// 报告 §2.3 裁决丢弃）。
// ============================================================

import UIKit

public final class TiebaFeedBitmapBaker: Sendable {
  public static let shared = TiebaFeedBitmapBaker()

  /// 诊断计数（验收判据 1 / 2 用；报告 §5.6）。
  public struct Statistics: Sendable {
    /// 提交次数（画布 + 预取）。
    public var submitted = 0
    /// 命中在途去重、只挂了一个等待者的次数。
    public var deduplicated = 0
    /// 真正开跑的烘制次数。
    public var started = 0
    /// 在开跑前 / 绘制中被代次判据放弃的次数。
    public var cancelled = 0
    /// 同步兜底（主线程）次数 —— 滚动中这个数必须为 0。
    public var syncRenders = 0
  }

  /// 一个等待者 = 一次提交（同一份 Job 可能被多处同时需要 → 在途去重后挂多个等待者）。
  private struct Waiter: Sendable {
    let epoch: UInt64
    let probe: @Sendable () -> UInt64
    let completion: @Sendable (TiebaFeedBitmapResult?) -> Void
  }

  /// 在途 / 待跑的一次烘制。
  private struct Entry: Sendable {
    let job: TiebaFeedBitmapJob
    let traits: TiebaFeedTraitSnapshot
    var waiters: [Waiter]
  }

  private struct State: Sendable {
    var entries: [TiebaFeedBitmapKey: Entry] = [:]
    /// 已入队但还没开跑的 key（FIFO；与 ASDK「第一个线程按 FIFO 取」同序，
    /// _ASAsyncTransaction.mm:233-234）。
    var order: [TiebaFeedBitmapKey] = []
    /// 已经在绘制线程上的数量。
    var active = 0
    var statistics = Statistics()
  }

  private let state = TiebaMutex(State())
  /// 并发队列（对应 _ASDisplayLayer.mm:124-135 的 displayQueue）。
  /// 真正的并发上限不是队列给的，是下面 active / limitProvider 给的。
  private let queue = DispatchQueue(
    label: "com.tieba.feed.bitmap.bake",
    qos: .userInitiated,
    attributes: .concurrent
  )
  /// 当前并发上限。默认由 TiebaFeedScrollGate 按滚动状态给出（滚动中 1）。
  /// 用闭包而不是 Int：**排空待跑队列时必须读当下的上限**，否则滚动结束后
  /// 之前被闸门挡下的 Job 会一直躺着。
  private let limitProvider: @Sendable () -> Int

  public init(limitProvider: @escaping @Sendable () -> Int = { TiebaFeedScrollGate.shared.limit }) {
    self.limitProvider = limitProvider
  }

  // MARK: - 提交

  /// 提交一次烘制。**立即返回**，结果经 completion 回（后台线程回调）。
  ///
  /// - Parameters:
  ///   - epochProbe: 取消判据的读端（画布传自己那个 Atomic 的 probe）。
  ///     产出的 result.epoch 就是本 Job 的 epoch，调用方比对后决定收不收。
  ///   - completion: nil = 被取消 / 绘制失败。**同一 key 的重复提交不会各烘一遍**：
  ///     后来者挂成等待者，一起拿同一张位图（各自的 epoch 不同，各判各的）。
  public func submit(
    _ job: TiebaFeedBitmapJob,
    traits: UITraitCollection,
    epochProbe: @escaping @Sendable () -> UInt64,
    completion: @escaping @Sendable (TiebaFeedBitmapResult?) -> Void
  ) {
    let waiter = Waiter(epoch: job.epoch, probe: epochProbe, completion: completion)
    let snapshot = TiebaFeedTraitSnapshot(traits)
    let cap = limitProvider()
    var starts: [TiebaFeedBitmapKey] = []
    state.withLock { state in
      state.statistics.submitted += 1
      if var existing = state.entries[job.key] {
        // 在途去重：像素输入完全相同（键相等），只需要多挂一个等待者。
        existing.waiters.append(waiter)
        state.entries[job.key] = existing
        state.statistics.deduplicated += 1
        return
      }
      state.entries[job.key] = Entry(job: job, traits: snapshot, waiters: [waiter])
      state.order.append(job.key)
      starts = Self.drain(&state, cap: cap)
    }
    for key in starts { start(key) }
  }

  /// 同步兜底 —— **只在静止 / 首屏**用（对应 _ASDisplayLayer.mm:150-158 的
  /// displayImmediately）。滚动中调它就是本次改造要消灭的那笔主线程开销。
  /// 同步路径不支持取消（同 ASDK：ASDisplayNode+AsyncDisplay.mm:347-351）。
  /// 计数进 statistics().syncRenders：滚动中这个数必须为 0（验收判据 1）。
  public func renderSync(_ job: TiebaFeedBitmapJob, traits: UITraitCollection) -> CGImage? {
    state.withLock { $0.statistics.syncRenders += 1 }
    return TiebaFeedGraphics.render(job, traits: traits, isCancelled: { false })
  }

  public func statistics() -> Statistics {
    state.withLock { $0.statistics }
  }

  public func resetStatistics() {
    state.withLock { $0.statistics = Statistics() }
  }

  // MARK: - 调度

  /// 有空额度就从待跑队列头部取（调用方持锁）。
  private static func drain(_ state: inout State, cap: Int) -> [TiebaFeedBitmapKey] {
    var starts: [TiebaFeedBitmapKey] = []
    while state.active < max(cap, 1), !state.order.isEmpty {
      let key = state.order.removeFirst()
      guard state.entries[key] != nil else { continue }
      state.active += 1
      state.statistics.started += 1
      starts.append(key)
    }
    return starts
  }

  private func start(_ key: TiebaFeedBitmapKey) {
    queue.async {
      let entry = self.state.withLock { $0.entries[key] }
      guard let entry else {
        // 理论上到不了这里（entry 只在 finish 里移除）。防御性收尾，别漏还额度。
        self.finish(key: key, image: nil, bytes: 0)
        return
      }
      let isCancelled = Self.cancellationProbe(for: entry.waiters)
      let image = TiebaFeedGraphics.render(
        entry.job,
        traits: entry.traits.traits,
        isCancelled: isCancelled
      )
      self.finish(key: key, image: image, bytes: entry.job.byteCount)
    }
  }

  /// 收尾：还额度、排空待跑、分发结果。
  private func finish(key: TiebaFeedBitmapKey, image: CGImage?, bytes: Int) {
    let cap = limitProvider()   // 先读闸门（别在自己的锁里取别的锁）
    var starts: [TiebaFeedBitmapKey] = []
    let waiters = state.withLock { state -> [Waiter] in
      let removed = state.entries.removeValue(forKey: key)
      state.active = max(state.active - 1, 0)
      if image == nil { state.statistics.cancelled += 1 }
      starts = Self.drain(&state, cap: cap)
      return removed?.waiters ?? []
    }
    for next in starts { start(next) }
    guard let image else {
      // 取消 / 失败：等待者全部拿 nil（画布保留旧 contents 即可，不要闪白）。
      for waiter in waiters { waiter.completion(nil) }
      return
    }
    for waiter in waiters {
      waiter.completion(
        TiebaFeedBitmapResult(key: key, epoch: waiter.epoch, image: image, bytes: bytes)
      )
    }
  }

  /// 取消判据：**所有「可取消等待者」都过期**才放弃。
  ///   - epoch == 0 的等待者是预取（probe 恒 0），不参与判据 —— 报告 §5.5：预取 Job
  ///     的语义是「没有取消需求」；
  ///   - 只要还有一个等待者背后的画布代次没动，这次烘制就仍然有人要
  ///     （同一 key 可能被画布与预取同时需要）。
  private static func cancellationProbe(for waiters: [Waiter]) -> @Sendable () -> Bool {
    {
      var cancellable = 0
      for waiter in waiters where waiter.epoch != 0 {
        cancellable += 1
        if waiter.probe() == waiter.epoch { return false }
      }
      return cancellable > 0
    }
  }
}
