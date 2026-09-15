// ============================================================
// TiebaLite — 通用列表的"行种类路由"（TiebaKindRowPages）
//
// 页记录 = pageKey → 每行种类（simple/feed/post）+ 该行在自己度量族页里的下标；三族
// 度量仍是唯一测量实现，本文件不复制几何。整页 LRU(8) 与度量缓存同纪律，并发状态
// 由 lock 保护（@unchecked Sendable）；containerWidth 必须是 TiebaLayout 量化值。
// ============================================================

import UIKit

// MARK: - 行种类

/// 行种类（JS 行字典的顶层键 `kind`；缺省 = `.simple`，与既有契约兼容）。
public nonisolated enum TiebaKindRowKind: String, Sendable {
  /// TiebaSimpleRows 的四个变体（user / message / section / summary）。
  case simple
  /// 信息流卡片行（ThreadInfo 形状；TiebaRowMetrics + TiebaFeedRowView）。
  case feed
  /// 帖子行（帖子页主贴/回复；TiebaPostRowMetrics + TiebaPostRowView，
  /// 只由原生页面（thread/[id]）经 publish(pageKey:kinds:) 使用）。
  case post
}

// MARK: - 页记录

/// 一页的行种类表 + 每行在两族度量页里的下标（init 后不可变，跨线程只读）。
public nonisolated final class TiebaKindRowPage: @unchecked Sendable {
  public let pageKey: String
  /// 页内每行的种类（下标与 JS 推入的 rows 一一对应）。
  public let kinds: [TiebaKindRowKind]
  /// feed 行在 TiebaRowMetrics 页里的下标（升序 = JS 行序保序结果）。
  let feedIndices: [Int]
  /// simple 行在 TiebaSimpleRowMetrics 页里的下标。
  let simpleIndices: [Int]
  /// post 行在 TiebaPostRowMetrics 页里的下标。
  let postIndices: [Int]
  /// 页内下标 → 该行在自己族页里的下标。
  private let subIndices: [Int]

  convenience init(pageKey: String, rows: [[String: Any]]) {
    // 只认 "feed"/"post"；缺省/"simple"/未知值都按 simple（variant 解析不了不新增族）。
    let kinds = rows.map { TiebaKindRowKind(rawValue: $0["kind"] as? String ?? "") ?? .simple }
    self.init(pageKey: pageKey, kinds: kinds)
  }

  init(pageKey: String, kinds: [TiebaKindRowKind]) {
    self.pageKey = pageKey
    self.kinds = kinds
    // 各族的"子集页内下标"按出现顺序递增：第 i 行是某族的第 n 行 → 该族页里
    // 下标 n（子集保序推给度量实现，各族各自 0…count-1 连续）。
    var subIndices: [Int] = []
    subIndices.reserveCapacity(kinds.count)
    var counters: [TiebaKindRowKind: Int] = [:]
    for kind in kinds {
      let next = counters[kind] ?? 0
      subIndices.append(next)
      counters[kind] = next + 1
    }
    self.subIndices = subIndices
    self.feedIndices = Array(0..<(counters[.feed] ?? 0))
    self.simpleIndices = Array(0..<(counters[.simple] ?? 0))
    self.postIndices = Array(0..<(counters[.post] ?? 0))
  }

  public var count: Int { kinds.count }

  public func kind(at index: Int) -> TiebaKindRowKind? {
    guard index >= 0, index < kinds.count else { return nil }
    return kinds[index]
  }

  /// 页内下标 → 该行在自己族度量页里的下标（越界 → nil）。
  public func subIndex(at index: Int) -> Int? {
    guard index >= 0, index < subIndices.count else { return nil }
    return subIndices[index]
  }
}

// MARK: - 在显页保活

/// 在显页保活登记表（页记录 + 三族度量四个整页 LRU 共用）。
///
/// 四个存储的淘汰都是"整页 LRU(8) + 纯插入顺序 FIFO"：读不刷新时效，也没有
/// "这一页正在被显示"的概念。而每个屏（信息流两个分段、消息各分类、主页、吧页
/// 各分段、帖子页/楼中楼、收藏/历史/搜索）都往同一个预算里插页——于是**插入最早
/// 的那页必然第一个被别的屏挤掉**，而它往往正是用户从进吧起就在看的那页。
///
/// 页记录被挤掉不报错，只**静默留白**：行内容查不到（`subIndex` → nil，cell 干脆
/// 不配置、保持清空态）、行高查不到（走兜底高）、行数查成 0（快照直接变空）。
/// 用户报的"点进帖子再退回来只剩那张卡、上下全白"就是这条链。
///
/// 所以列表把"当前挂在窗口上、正在显示的页键"登记进来，淘汰时跳过；离窗/换页/
/// 销毁即解绑（条目数被在显列表数限住，不动 LRU 的内存上限）。全部 pinned 时允许
/// 暂时超上限——宁可多留几页，也不能把正在显示的页删掉。缺页的兜底见
/// TiebaKindListContentView.onPageDataMissing（自愈重推）。
public nonisolated final class TiebaRowPagePins: @unchecked Sendable {
  public static let shared = TiebaRowPagePins()
  private let lock = NSLock()
  private var keys: Set<String> = []

  private init() {}

  public func pin(_ pageKey: String) {
    guard !pageKey.isEmpty else { return }
    lock.withLock { keys.insert(pageKey) }
  }

  public func unpin(_ pageKey: String) {
    guard !pageKey.isEmpty else { return }
    lock.withLock { keys.remove(pageKey) }
  }

  /// 淘汰前取一次快照（一次加锁，不逐页判）。
  func snapshot() -> Set<String> { lock.withLock { keys } }
}

// MARK: - 页记录缓存 + 两族测量路由

public nonisolated final class TiebaKindRowPages: @unchecked Sendable {
  public static let shared = TiebaKindRowPages()

  private struct Entry {
    let page: TiebaKindRowPage
    let order: UInt64
  }

  /// prepareBlocking 的入参快照盒：行字典非 Sendable，投递后调用方不再持有/改写
  ///（与 TiebaRowMetrics 的 SendableRows 同约定）。
  private struct SendableRows: @unchecked Sendable {
    let rows: [[String: Any]]
  }

  /// 整页上限：与两族度量缓存的 maxPages 同值（上一页 + 当前页 + 预取页）。
  private let maxPages = 8
  private let lock = NSLock()
  private var pages: [String: Entry] = [:]
  private var orderSeed: UInt64 = 0

  private init() {}

  /// 0.5pt 量化统一走 TiebaLayout（全仓唯一实现）。
  static func quantize(_ width: CGFloat) -> CGFloat {
    TiebaLayout.quantize(width)
  }

  // MARK: - 公共契约

  /// 整页发布 + 两族分别整页同步测量。调用线程 = 后台（不得在主线程调用：整页
  /// TextKit 测量）。返回即可查行数与两族模型。
  public func prepareBlocking(pageKey: String, rows: [[String: Any]], containerWidth: CGFloat) {
    guard !pageKey.isEmpty, !rows.isEmpty, containerWidth > 0 else { return }
    let page = TiebaKindRowPage(pageKey: pageKey, rows: rows)
    let box = SendableRows(rows: rows)
    publish(page)
    // 两族各自整页测量（各自的度量实现是唯一来源：本文件不测任何几何）。
    if !page.feedIndices.isEmpty {
      TiebaRowMetrics.shared.prepareFeedRowsBlocking(
        pageKey: pageKey,
        rows: page.feedIndices.map { box.rows[$0] },
        containerWidth: containerWidth
      )
    }
    if !page.simpleIndices.isEmpty {
      TiebaSimpleRowMetrics.shared.prepareRowsBlocking(
        pageKey: pageKey,
        rows: page.simpleIndices.map { box.rows[$0] },
        containerWidth: containerWidth
      )
    }
  }

  /// 原生页面直接推入整页行种类（帖子页：post 行；数据由 TiebaPostRowMetrics
  /// 在调用前自行 prepare，本方法只发布页记录）。
  public func publish(pageKey: String, kinds: [TiebaKindRowKind]) {
    guard !pageKey.isEmpty, !kinds.isEmpty else { return }
    publish(TiebaKindRowPage(pageKey: pageKey, kinds: kinds))
  }

  /// 页内行数（页记录未发布 → 0）。行数来自页记录本身：行高缺失（被 LRU 淘汰）
  /// 时列表仍要画出等量占位行，不能靠度量缓存的行数。
  public func rowCount(pageKey: String) -> Int {
    lock.withLock { pages[pageKey]?.page.count ?? 0 }
  }

  /// 页存活行数 = 各度量族完成度的最小值（任一族被淘汰/换了宽度 → 小于行数）；
  /// 调用方据此重推当前页（liveRowCount < rowCount = 度量不在，别画等量兜底行）。
  public func liveRowCount(pageKey: String, containerWidth: CGFloat) -> Int {
    guard let page = lock.withLock({ pages[pageKey]?.page }) else { return 0 }
    let width = TiebaKindRowPages.quantize(containerWidth)
    var counts: [Int] = []
    if !page.simpleIndices.isEmpty {
      counts.append(
        TiebaSimpleRowMetrics.shared.rowCount(pageKey: pageKey, containerWidth: width)
      )
    }
    if !page.feedIndices.isEmpty {
      // TiebaRowMetrics 的宽度闸门是全局 activeWidth（没有显式宽度入参）：
      // 取首行核对 containerWidth，对不上说明本页已被别的宽度清掉 → 报 0。
      let first = TiebaRowMetrics.shared.feedRow(pageKey: pageKey, index: 0)
      if let first, first.containerWidth == width {
        counts.append(TiebaRowMetrics.shared.feedRowCount(pageKey: pageKey))
      } else {
        counts.append(0)
      }
    }
    if !page.postIndices.isEmpty {
      let first = TiebaPostRowMetrics.shared.row(pageKey: pageKey, index: 0)
      if let first, first.containerWidth == width {
        counts.append(TiebaPostRowMetrics.shared.rowCount(pageKey: pageKey))
      } else {
        counts.append(0)
      }
    }
    return counts.min() ?? page.count
  }

  public func kind(pageKey: String, index: Int) -> TiebaKindRowKind? {
    lock.withLock { pages[pageKey]?.page.kind(at: index) }
  }

  public func subIndex(pageKey: String, index: Int) -> Int? {
    lock.withLock { pages[pageKey]?.page.subIndex(at: index) }
  }

  // MARK: - 内部

  private func publish(_ page: TiebaKindRowPage) {
    lock.withLock {
      orderSeed &+= 1
      pages[page.pageKey] = Entry(page: page, order: orderSeed)
      guard pages.count > maxPages else { return }
      // 整页淘汰：最旧 order 先出（与两族度量缓存的淘汰纪律一致），**在显页跳过**
      // ——正在显示的页被挤掉就是行内容静默留白（见 TiebaRowPagePins）。
      let pinned = TiebaRowPagePins.shared.snapshot()
      var overflow = pages.count - maxPages
      for entry in pages.sorted(by: { $0.value.order < $1.value.order }) {
        guard overflow > 0 else { break }
        guard !pinned.contains(entry.key) else { continue }
        pages.removeValue(forKey: entry.key)
        overflow -= 1
      }
    }
  }
}
