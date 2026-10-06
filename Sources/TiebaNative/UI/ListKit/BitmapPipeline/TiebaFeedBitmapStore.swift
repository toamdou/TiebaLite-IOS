// ============================================================
// TiebaLite — 异步位图管线 · 位图 LRU（从 TiebaFeedRowView.swift:749-903 原样搬出）
//
// 搬出来的唯一目的是让「缓存」和「画布」解耦：
//   - 后台烘制结果要能进缓存（异步路径），而画布只负责 attach（layer.contents 的单一所有者）；
//   - 预取路径（TiebaKindListView 的 prefetchItemsAt 旁边那条并行调用）只写缓存、不 attach；
//   - 缓存键从「逐字段线性比对」升级为 Hashable（见 TiebaFeedBitmapKey / R1）。
//
// 隔离：**@MainActor**（报告 §6 R4）。原实现就是 private static var entries / useClock，
// 搬到独立文件后不要顺手改成「线程安全」—— 那会引入锁，而所有调用点本来就在主线程。
// 命中/未命中计数供验收判据 2（往回滚一屏命中率 100%）。
//
// 本文件不依赖 TiebaNative 的其他类型（模型只以 AnyObject 弱引用参与身份判定）。
// ============================================================

import UIKit

@MainActor
public final class TiebaFeedBitmapStore {
  public static let shared = TiebaFeedBitmapStore()

  /// 弱引用盒：缓存**不持有**模型，否则会把已被整页 LRU 淘汰的行钉在内存里
  /// （模型的 NSAttributedString 才是大头）。同时也是「ObjectIdentifier 复用」的
  /// 唯一防线：模型一旦释放，这条缓存立刻不可命中（见 image(for:) 的清扫）。
  private final class ModelRef {
    weak var value: AnyObject?
    init(_ value: AnyObject) { self.value = value }
  }

  /// 一张缓存位图 + 它的精确身份。
  private struct Entry {
    let model: ModelRef
    let key: TiebaFeedBitmapKey
    let image: CGImage
    let bytes: Int
    var lastUsed: UInt64
  }

  /// 位图预算（原 TiebaFeedRowView.swift:764，值不动）。典型卡片（370×220pt @3x）
  /// 约 2.9MB/张，24MB ≈ 8 张 ≈ 一屏多一点，覆盖「往回滚一屏」的命中需求。
  /// 调大能覆盖滚更远，代价是常驻内存线性增长（报告 §5 的 M3 实验①就是改这个数）。
  public var byteBudget = 24 * 1024 * 1024
  /// 单张位图上限（原 :767）：展开后的长文卡可以到一千多 pt 高（十几 MB），
  /// 存它会把预算挤空、还把别的卡挤掉。这类卡仍然一次画好，只是不进缓存。
  public var maxEntryBytes = 8 * 1024 * 1024

  private var entries: [Entry] = []
  private var useClock: UInt64 = 0

  /// 命中 / 未命中（验收判据 2）。invalidate() 不清零 —— 主题切换不该抹掉统计。
  public private(set) var hits = 0
  public private(set) var misses = 0
  /// 因超预算被淘汰的张数（诊断用）。
  public private(set) var evictions = 0

  public var count: Int { entries.count }
  public var totalBytes: Int { entries.reduce(0) { $0 + $1.bytes } }

  private init() {}

  // MARK: - 查找

  /// 命中则返回位图并记一次 hit；未命中返回 nil 并记一次 miss。
  public func image(for key: TiebaFeedBitmapKey) -> CGImage? {
    // 逐条扫描时顺带把模型已释放（弱引用空）的条目清出去 —— 原 :862-885 的行为。
    var hit: Int?
    var index = entries.count - 1
    while index >= 0 {
      if entries[index].model.value == nil {
        entries.remove(at: index)   // 模型已释放：这条缓存永远不可能再命中
      } else if hit == nil, entries[index].key == key {
        hit = index
      }
      index -= 1
    }
    guard let hit else {
      misses += 1
      return nil
    }
    useClock &+= 1
    entries[hit].lastUsed = useClock
    hits += 1
    return entries[hit].image
  }

  /// 静默查询（不计命中率）：预取路径用，别把预热算成用户命中。
  public func isCached(_ key: TiebaFeedBitmapKey) -> Bool {
    entries.contains { $0.model.value != nil && $0.key == key }
  }

  // MARK: - 存入

  @discardableResult
  public func insert(_ result: TiebaFeedBitmapResult, model: AnyObject) -> Bool {
    insert(image: result.image, key: result.key, bytes: result.bytes, model: model)
  }

  /// 存入并按预算淘汰最久未用的一张（绝不动刚存进来的这张）。
  /// - Returns: 是否真的进表（超 maxEntryBytes 时只画不存）。
  @discardableResult
  public func insert(image: CGImage, key: TiebaFeedBitmapKey, bytes: Int, model: AnyObject) -> Bool {
    guard bytes <= maxEntryBytes else { return false }
    useClock &+= 1
    let fresh = Entry(model: ModelRef(model), key: key, image: image, bytes: bytes, lastUsed: useClock)
    // 同键重复插入（在途去重漏网 / 预取与画布同时到）：只替换，不叠加。
    if let index = entries.firstIndex(where: { $0.key == key }) {
      entries[index] = fresh
    } else {
      entries.append(fresh)
    }
    evict()
    return true
  }

  /// 整表作废（外观档 / 色板变化时由宿主调用，见 TiebaFeedRowTextCanvas.invalidateCache）。
  /// **不在这里重烘** —— 调用点此刻的属性串可能还是旧色，重烘会把旧色位图存进新键。
  public func invalidate() {
    entries.removeAll()
  }

  public func resetStatistics() {
    hits = 0
    misses = 0
  }

  // MARK: - 预取

  /// 预热一张行位图：**只进 Store，不 attach**（谁拥有 layer.contents 始终是画布）。
  ///
  /// 应在 UICollectionView 的 prefetchItemsAt（TiebaKindListView.swift:1587）旁边并行调用。
  /// job.epoch 必须是 0（纯预取、不发生取消，报告 §5.5）。
  public func prewarm(_ job: TiebaFeedBitmapJob, traits: UITraitCollection, model: AnyObject) {
    guard job.epoch == 0, !isCached(job.key), totalBytes < byteBudget else { return }
    let token = TiebaFeedBitmapModelToken(model)
    TiebaFeedBitmapBaker.shared.submit(
      job,
      traits: traits,
      epochProbe: { 0 }
    ) { [weak self] result in
      guard let result else { return }
      Task { @MainActor in
        self?.insert(result, model: token.model)
      }
    }
  }

  // MARK: - 淘汰

  private func evict() {
    var total = entries.reduce(0) { $0 + $1.bytes }
    while total > byteBudget, entries.count > 1 {
      var oldest = 0
      for index in entries.indices where entries[index].lastUsed < entries[oldest].lastUsed {
        oldest = index
      }
      guard entries[oldest].lastUsed != useClock else { break }
      total -= entries[oldest].bytes
      entries.remove(at: oldest)
      evictions += 1
    }
  }
}
