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
  /// feed 行在 TiebaRowMetrics 页里的下标（= 这些行在**本页**里的页内下标，升序）。
  /// ⚠️ 是"页内位置"，不是 0…count-1：混合 kind 的页（浏览记录 = 分组标题 simple +
  /// 卡片 feed）里两者不等，写错就会把别的族的行喂进度量页（见 init 注释）。
  let feedIndices: [Int]
  /// simple 行在 TiebaSimpleRowMetrics 页里的下标（同上，= 页内位置）。
  let simpleIndices: [Int]
  /// post 行在 TiebaPostRowMetrics 页里的下标（同上，= 页内位置）。
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
    // 三族的"族内下标 → 页内下标"反向表。各族度量页 = **按页序切片的行子集**
    //（TiebaKindRowPages.prepareBlocking 用 feedIndices 去 rows 里切片），
    // 所以这里必须是"这一族的行各自的页内位置"，不能写成 Array(0..<count)。
    // 改前症状（2026-10-06 用户报「浏览记录不同记录之间大片空白、错位严重」，真机口径）：
    // 浏览记录页 = 1 个分组标题（simple）+ N 张卡片（feed），feedIndices 被算成
    // 0..<N ⇒ 度量页第 0 行装的是"今天"这条标题行、而最后一条记录被挤出切片。
    // 于是：① 行视图按 (页Key, 族内下标) 取到标题行的模型 —— 分组标题被画成一张
    // "吧友 / 今天 / 回复0 分享 赞"的卡片；② 每段少显示一条记录；③ simple 族同样
    // 拿到前 N 行（含 feed 行）⇒ 本该画分组标题的位置画成"只有标题的空白卡"。
    // 收藏页/动态页等**纯一族**的页 feedIndices 恰好等于 0..<count，所以此前没暴露。
    var feedIndices: [Int] = []
    var simpleIndices: [Int] = []
    var postIndices: [Int] = []
    for (index, kind) in kinds.enumerated() {
      let next = counters[kind] ?? 0
      subIndices.append(next)
      counters[kind] = next + 1
      switch kind {
      case .feed: feedIndices.append(index)
      case .simple: simpleIndices.append(index)
      case .post: postIndices.append(index)
      }
    }
    self.subIndices = subIndices
    self.feedIndices = feedIndices
    self.simpleIndices = simpleIndices
    self.postIndices = postIndices
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
    lock.withLock { _ = keys.insert(pageKey) }
  }

  public func unpin(_ pageKey: String) {
    guard !pageKey.isEmpty else { return }
    lock.withLock { _ = keys.remove(pageKey) }
  }

  /// 淘汰前取一次快照（一次加锁，不逐页判）。
  func snapshot() -> Set<String> { lock.withLock { keys } }
}

// MARK: - 行级内容缓存（键 = 内容身份 + 量化宽度）

/// 行级度量缓存的键 =（**行内容身份**, 0.5pt 量化宽度）。
///
/// [精简] 原键 =（pageKey, 0.5pt 量化宽度）：位置进了键，"同一行内容"换个页就是另一份
/// 测量 —— 既重复整页 TextKit 测量（重推、跨屏、跨页各测一遍），又让整页 LRU 一淘汰
/// 就把"内容其实还在别的页/别的屏里"的行一起清掉。那一串补偿（在显页 pin / 缺页自愈 /
/// 节流 / 兜底高）都是为这条链长出来的。
/// 内容身份（TiebaRowDiff.Entry.Identity = 指纹 + 同指纹序号）与位置无关、与宽度无关，
/// 所以同一行内容在**任何页**里都命中同一份测量；宽度仍是键的一部分（高度依赖宽度，
/// 跨宽度复用会按旧帧计划绘制 —— 与列表的宽度闸门同判据）。
public nonisolated struct TiebaRowCacheKey: Hashable, Sendable {
  public let identity: TiebaRowDiff.Entry.Identity
  public let width: CGFloat

  public init(identity: TiebaRowDiff.Entry.Identity, width: CGFloat) {
    self.identity = identity
    self.width = width
  }
}

/// 行级内容缓存：键见 TiebaRowCacheKey，值 = 该行测好的模型（重：模型 + 富文本）。
///
/// 分工（**页只是"行的集合"**）：
///   - 本类存"行内容"：内容键 + **行预算** + 读刷新 LRU；
///   - 页索引（位置 → 内容键）仍走 TiebaPageStore：轻量（每行 ~24B），只给位置查询、
///     行数与顺序用（diffable 仍按内容身份，不受影响）。
///
/// 淘汰粒度从"页"改成"行"的理由：
///   · 同一内容在多页出现只存一份（首页/吧页/搜索/历史常常同帖），同样的预算覆盖更多屏；
///     重推、跨页、跨屏都命中，不再重测；
///   · **读取刷新时效**（read-touch）：列表逐行读的就是正在显示的内容，它们天然最热；
///     而 TiebaPageStore 按设计"读不刷新时效"，一屏只要不再写就必然第一个被别的屏挤掉。
///
/// 值只在 lock 内读写；@unchecked Sendable（供后台测量队列调用）。
public nonisolated final class TiebaRowStore<Key: Hashable, Value>: @unchecked Sendable {
  /// 行预算（不是页预算）：与旧整页 LRU(8) 同量级（8 页 × 每页行数），内容去重后覆盖的
  /// 实际屏数只会更多。
  private let maxRows: Int
  private let lock = NSLock()
  private var rows: [Key: (value: Value, order: UInt64)] = [:]
  private var orderSeed: UInt64 = 0

  public init(maxRows: Int) {
    self.maxRows = max(1, maxRows)
  }

  /// 命中并**刷新时效**（read-touch）：正在被列表读的行因此不会被别的屏挤掉。
  func value(forKey key: Key) -> Value? {
    lock.withLock {
      guard let entry = rows[key] else { return nil }
      orderSeed &+= 1
      rows[key] = (entry.value, orderSeed)
      return entry.value
    }
  }

  /// 只读探测（**不**刷新时效）：存活行数统计用 —— "数一遍"不等于"用过"。
  func contains(_ key: Key) -> Bool {
    lock.withLock { rows[key] != nil }
  }

  /// 发布一行（同键覆盖）并按行预算淘汰最久未用的行。
  func insert(_ value: Value, forKey key: Key) {
    lock.withLock {
      orderSeed &+= 1
      rows[key] = (value, orderSeed)
      guard rows.count > maxRows else { return }
      var overflow = rows.count - maxRows
      // [R21-5] 原实现每次 insert 都做一次 O(n log n) 全表排序（还要分配等长数组），
      // 只为删 1 行 —— 缓存满后每测一行付一次 512 元素排序。改成逐次 O(n) 找最小 order：
      // 溢出量通常就是 1，总代价 O(n) 且零额外分配。
      while overflow > 0, let oldest = rows.min(by: { $0.value.order < $1.value.order })?.key {
        rows.removeValue(forKey: oldest)
        overflow -= 1
      }
    }
  }

  /// 逐行取用：**内容键命中就复用**（跨页复用也走这条），未命中才 make 现测并写入。
  /// keys 与 inputs 不等长时全部现测且不写缓存（防御性：宁可多测一次，也不能把 A 行的
  /// 测量贴到 B 行上）。
  func resolve<Input>(_ inputs: [Input], keys: [Key], make: (Input) -> Value) -> [Value] {
    guard keys.count == inputs.count else { return inputs.map(make) }
    var result: [Value] = []
    result.reserveCapacity(inputs.count)
    for (index, input) in inputs.enumerated() {
      let key = keys[index]
      if let cached = value(forKey: key) {
        result.append(cached)
        continue
      }
      let value = make(input)
      insert(value, forKey: key)
      result.append(value)
    }
    return result
  }

  var count: Int { lock.withLock { rows.count } }

  func removeAll() {
    lock.withLock { rows.removeAll() }
  }
}

/// 页级缓存（键控 + 整页 LRU 淘汰）——四族度量缓存的唯一实现：
/// 行度量（TiebaRowMetrics）/ 帖行度量（TiebaPostRowMetrics）/ 通用行度量
/// （TiebaSimpleRowMetrics）/ 页记录（TiebaKindRowPages）。
///
/// 四条纪律原先在四个文件里各抄一遍（连注释都近似），任何一份漏掉 pinned 判断
/// 都会复现"点进帖子退回来只剩一张卡"的静默留白，所以收敛到一处：
///   - 整页淘汰，不逐行（半个页面的高度缺失比多留几页更糟）；
///   - **在显页跳过**（用户正在看的页被挤掉 = 行内容静默留白，见 TiebaRowPagePins）；
///   - 全部 pinned 时允许暂时超上限（宁可多留，不可删在显页）；
///   - maxPages = 8（上一页 + 当前页 + 预取页）。
///
/// Value 由调用方定形（行模型数组 / 页记录 / 原始字典都行），order 由本类维护。
/// @unchecked Sendable：值只在 lock 内读写；nonisolated 供后台测量队列调用。
public nonisolated final class TiebaPageStore<Key: Hashable, Value>: @unchecked Sendable {
  /// key → 在显页键（TiebaRowPagePins 里的字符串形式）；多数调用方就是键本身。
  private let pinKey: @Sendable (Key) -> String
  private let maxPages: Int
  private let lock = NSLock()
  private var pages: [Key: (value: Value, order: UInt64)] = [:]
  private var orderSeed: UInt64 = 0

  public init(maxPages: Int = 8, pinKey: @escaping @Sendable (Key) -> String) {
    self.maxPages = maxPages
    self.pinKey = pinKey
  }

  /// 发布一页（覆盖同键）并做一次整页淘汰。
  func publish(_ value: Value, forKey key: Key) {
    lock.withLock {
      orderSeed &+= 1
      pages[key] = (value, orderSeed)
      guard pages.count > maxPages else { return }
      let pinned = TiebaRowPagePins.shared.snapshot()
      var overflow = pages.count - maxPages
      for entry in pages.sorted(by: { $0.value.order < $1.value.order }) {
        guard overflow > 0 else { break }
        guard !pinned.contains(pinKey(entry.key)) else { continue }
        pages.removeValue(forKey: entry.key)
        overflow -= 1
      }
    }
  }

  func value(forKey key: Key) -> Value? {
    lock.withLock { pages[key]?.value }
  }

  /// 匹配（同 pageKey 可能有多条不同宽度的键）里**最新发布**的那条；无 → nil。
  /// 行视图查询用：它只拿得到 (pageKey, index)，不知道宽度。
  func newest(where matches: @Sendable (Key) -> Bool) -> Value? {
    lock.withLock {
      var newest: (value: Value, order: UInt64)?
      for (key, entry) in pages where matches(key) {
        if newest == nil || entry.order > newest!.order { newest = entry }
      }
      return newest?.value
    }
  }

  /// 就地改一页（如单行替换）。块内改的是副本；返回 false = 键不存在（不改动）。
  @discardableResult
  func mutate(_ key: Key, _ body: (inout Value) -> Void) -> Bool {
    lock.withLock {
      guard var entry = pages[key] else { return false }
      body(&entry.value)
      // order 保持不变：就地改内容不算"最近使用"（同旧实现用 var Page 直接写回）。
      pages[key] = entry
      return true
    }
  }

  func removeAll() {
    lock.withLock { pages.removeAll() }
  }

  var count: Int { lock.withLock { pages.count } }
}

// MARK: - 页记录缓存 + 两族测量路由

public nonisolated final class TiebaKindRowPages: @unchecked Sendable {
  public static let shared = TiebaKindRowPages()

  private struct Entry {
    let page: TiebaKindRowPage
  }

  /// prepareBlocking 的入参快照盒：行字典非 Sendable，投递后调用方不再持有/改写
  ///（与 TiebaRowMetrics 的 SendableRows 同约定）。
  private struct SendableRows: @unchecked Sendable {
    let rows: [[String: Any]]
  }

  /// 整页缓存（LRU + 在显页跳过）：与其余三族度量缓存共用 TiebaPageStore。
  private let pages = TiebaPageStore<String, Entry>(pinKey: { $0 })

  private init() {}

  /// 0.5pt 量化统一走 TiebaLayout（全仓唯一实现）。
  static func quantize(_ width: CGFloat) -> CGFloat {
    TiebaLayout.quantize(width)
  }

  // MARK: - 公共契约

  /// 整页发布 + 两族分别整页同步测量。调用线程 = 后台（不得在主线程调用：整页
  /// TextKit 测量）。返回即可查行数与两族模型。
  /// - Parameter identities: 每行的**内容身份**（与 rows 同序）。[精简] 新增（默认 nil，
  ///   既有调用点不变）：它正是行级度量缓存的键，由发布方一次算好传下来 —— 度量侧不再
  ///   为同一批行重算一遍指纹；缺省时本方法按 TiebaRowDiff.entries 的同一规则现算
  ///   （与列表拿到的那份逐位一致）。
  public func prepareBlocking(
    pageKey: String,
    rows: [[String: Any]],
    containerWidth: CGFloat,
    identities: [TiebaRowDiff.Entry.Identity]? = nil
  ) {
    guard !pageKey.isEmpty, !rows.isEmpty, containerWidth > 0 else { return }
    let page = TiebaKindRowPage(pageKey: pageKey, rows: rows)
    let box = SendableRows(rows: rows)
    // 身份与行必须同序同长；对不上（长度不符）时按同一规则现算，绝不按错位使用。
    let ids = (identities?.count == rows.count ? identities : nil)
      ?? TiebaRowDiff.entries(for: rows).map(\.identity)
    // ⚠️ 顺序：**先测量、后发布**（Q6-6）。发布是"这一页可用了"的信号，而列表在
    // rowCount>0 时就会去取度量；两步之间任何一次主线程布局趟都会读到"有行数、没模型"，
    // 画出一帧兜底高占位并触发一次缺页自愈重推（又一次完整后台测量）。
    // 对调安全：两族测量只吃下方 rows 数组切片，不回读页记录。
    // 族内下标把**整页身份**切片传下去：度量缓存键因此与列表的 TiebaKindItem.identity
    // 完全同一个数（同一行内容在页面记录、列表身份、度量缓存三处同键）。
    if !page.feedIndices.isEmpty {
      TiebaRowMetrics.shared.prepareFeedRowsBlocking(
        pageKey: pageKey,
        rows: page.feedIndices.map { box.rows[$0] },
        containerWidth: containerWidth,
        identities: page.feedIndices.map { ids[$0] }
      )
    }
    if !page.simpleIndices.isEmpty {
      TiebaSimpleRowMetrics.shared.prepareRowsBlocking(
        pageKey: pageKey,
        rows: page.simpleIndices.map { box.rows[$0] },
        containerWidth: containerWidth,
        identities: page.simpleIndices.map { ids[$0] }
      )
    }
    // 两族都测完才发布（见上方顺序说明）：发布之后调用方读到的行数一定配得上模型。
    publish(page)
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
    pages.value(forKey: pageKey)?.page.count ?? 0
  }

  /// 页存活行数 = 各度量族完成度的最小值（任一族被淘汰/换了宽度 → 小于行数）；
  /// 调用方据此重推当前页（liveRowCount < rowCount = 度量不在，别画等量兜底行）。
  public func liveRowCount(pageKey: String, containerWidth: CGFloat) -> Int {
    guard let page = pages.value(forKey: pageKey)?.page else { return 0 }
    let width = TiebaKindRowPages.quantize(containerWidth)
    var counts: [Int] = []
    // [精简] 改成数"索引在、内容也在"的行（presentRowCount）：行级缓存的淘汰粒度是行，
    // 页索引还在但内容被行预算挤掉时，旧的"整页行数"会把缺行报成完好（等于骗过自愈）。
    if !page.simpleIndices.isEmpty {
      counts.append(
        TiebaSimpleRowMetrics.shared.presentRowCount(pageKey: pageKey, containerWidth: width)
      )
    }
    if !page.feedIndices.isEmpty {
      counts.append(
        TiebaRowMetrics.shared.presentRowCount(pageKey: pageKey, containerWidth: width)
      )
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

  /// 页记录对象（**调用方可持有**）：列表把当前页记录挂在实例上，共享存储的整页 LRU
  /// 便挤不掉"正在显示的那一页"的种类/顺序/行数 —— [精简] 与在显页 pin 互为冗余的
  /// 第二道保险，零成本（页记录很小：每行 kinds + 族内下标）。
  public func page(pageKey: String) -> TiebaKindRowPage? {
    pages.value(forKey: pageKey)?.page
  }

  public func kind(pageKey: String, index: Int) -> TiebaKindRowKind? {
    pages.value(forKey: pageKey)?.page.kind(at: index)
  }

  public func subIndex(pageKey: String, index: Int) -> Int? {
    pages.value(forKey: pageKey)?.page.subIndex(at: index)
  }

  // MARK: - 内部

  private func publish(_ page: TiebaKindRowPage) {
    pages.publish(Entry(page: page), forKey: page.pageKey)
  }
}
