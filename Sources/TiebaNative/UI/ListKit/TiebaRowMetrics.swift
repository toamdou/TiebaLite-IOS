// TiebaLite — 信息流行模型 / 高度缓存（TiebaRowMetrics）
//
// 唯一形态：原生列表容器（TiebaKindRowPages / TiebaRowPageDriver）在后台线程调
// prepareFeedRowsBlocking 一次性推整页行字典并同步测完（返回即可查）；行视图只拿
// (pageKey, index) 两个原始 prop 从本缓存同步取模型（与测量同一实例，
// NSAttributedString 已在测量期构建，绘制期零重建）。
//
// 缓存约束（[精简] 度量缓存键已从 (pageKey, width) 换成 (内容身份, width)）：
//   - **行内容**：键 =（TiebaRowDiff.Entry.Identity, 0.5pt 量化宽度），存 TiebaRowStore
//     （行预算 + 读刷新 LRU）。同一行内容在任何页里命中同一份测量 —— 重推、跨页、跨屏
//     都不重测；位置不再是内容的一部分。
//   - **页索引**：键 =（pageKey, 0.5pt 量化宽度）→ 该页每行的内容键（顺序即行序），仍是
//     整页 LRU + 在显页跳过；只用于位置查询、行数与顺序，不含几何。
//   - 逐行复用：prepare 时**内容键命中**就复用旧模型（点赞/展开重推整页时只有被点的行
//     需要重测富文本与 TextKit；同一行出现在别的页时也不再重测）。
//   - 行内容指纹：**行身份**用 TiebaRowDiff.Entry.Identity（TiebaRowFingerprint 的白名单必须
//     覆盖全部影响渲染的字段，改字段集要 version += 1）。模型自己那份 fingerprint 已删
//     （R4-3：消费方为零，每行白算一遍整行哈希）。
//   - 动态字号档变化（UIContentSizeCategory）→ 内容与索引一起作废，由页面重推恢复。
//
// 并发：所有共享状态由 lock 保护；类以 @unchecked Sendable 声明该不变量
//（仓库既有惯例：TiebaBackgroundSync / TiebaProtoRegistry / TiebaBackgroundSnapshot）。
// NSAttributedString / UIFont / NSLayoutManager 的测量在后台线程使用是安全的
//（TextKit 自 iOS 7 起线程安全，绘制只在主线程读取缓存结果）。
//
// ── 将来做"自绘可交互富文本"时的基座思路（只记录，本文件不落地）──
//   借鉴自上游（早期 vendored 的 Display 模块/Sources/Text/TextNode.swift 的
//   TextNodeLayout / TextNodeLine，:484-560、:283-303；"逐行属性矩形"见 allAttributeRects :1001）：
//   **layout 与视图分离**——测量产出的是一份纯值（可缓存、可后台产出后交主线程），
//   视图只把这套几何画出来并做命中测试；其中"逐行属性矩形"（每行的下划线/删除线/
//   嵌入项等属性的行内 rect）是它比接收方多出来的那一样东西。
//   接收方现状（19 号报告 §2.3 的核对口径）：测量产物是三个标量
//（height / exactHeight / truncated，见 TiebaRowParser.measure），行内片段的矩形没有留下来 ⇒
//   行内命中只能整块近似（如 showMoreFrame 的外扩 6pt）。将来真要做行内可点
//（@ 跳用户页 / 话题跳吧页）或自绘富文本，把"逐行属性矩形"加进这份测量结果即可——测量
//   本来就在后台整页跑、结果按页缓存，是放这份几何的正确位置；渲染仍走 UITextView
//（选择 UI / 无障碍 / iOS 26 系统文本服务都在它身上，换成自绘是净功能回退，见 19 号报告 §2.4）。

import UIKit


// MARK: - 页面级缓存

public nonisolated final class TiebaRowMetrics: @unchecked Sendable {
  public static let shared = TiebaRowMetrics()

  /// 页索引键 =（pageKey, 0.5pt 量化宽度）：**只剩位置**，每行存的是它的**内容键**。
  /// [精简] 原键直接挂 Page(rows: + raws:)：位置即内容，于是整页一被 LRU 挤掉，这些行
  /// 的测量就跟着没了（→ 缺页自愈 / 兜底高 / 在显页 pin 那一整串补偿）。现在重的是行
  /// 内容（内容键，见 TiebaRowStore），本索引只是"位置 → 内容键"的轻量映射（每行 ~24B）。
  /// 宽度仍是键的一部分：同屏不同宽度的列表互不清页。
  private struct PageKey: Hashable {
    let pageKey: String
    let width: CGFloat
  }

  /// 行内容存储：键 =（内容身份, 量化宽度）—— 同一行内容在任何页里命中同一份测量。
  /// 行预算 512 ≈ 旧整页 LRU(8) × 每页 64 行的量级；内容去重后覆盖的实际屏数更多。
  private let rows = TiebaRowStore<TiebaRowCacheKey, TiebaFeedRowModel>(maxRows: 512)

  /// 内容键 → **原始行字典**（宽度无关）。存在的唯一理由是"单行同步补测"：
  /// 内容键里含宽度 ⇒ 换宽度（旋转/分屏/首帧宽度未定）后旧测量不再命中，
  /// 布局那一趟就会拿不到高度。留着源字典就能当场按新宽度重测，而不是编一个假高度。
  /// 与 rows 同量级的行预算；进列表的原始行字典本来就在内存里（发布方持有），
  /// 这里只是让**列表**也能拿到它。
  private let raws = TiebaRowStore<TiebaRowDiff.Entry.Identity, [String: Any]>(maxRows: 512)

  /// 页索引缓存（LRU + 在显页跳过）：四族度量缓存共用 TiebaPageStore。
  /// [精简] 预算 8 → 32 页：索引不含几何、很轻，而旧预算原本是给"整页模型"定的 ——
  /// 位置查询不该因为别的屏又插了几页就整页查不到。
  private let pages = TiebaPageStore<PageKey, [TiebaRowCacheKey]>(
    maxPages: 32,
    pinKey: { $0.pageKey }
  )

  private init() {
    // 系统内容尺寸档（动态字体）变化 → 已测高度全部失效（UIFontMetrics 随之变）。
    // 通知在主队列投递；清空后 feedRow* 返回 nil，页面重推即恢复。
    NotificationCenter.default.addObserver(
      forName: UIContentSizeCategory.didChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.invalidateAll()
    }
  }

  /// 丢弃全部缓存（外观/字号等全局度量变化时用）。锁内 O(页数)。
  /// [精简] 行内容存储也要清：它是**跨页**共享的，只清页索引会留下"别的页还在引用"
  /// 的旧测量（字号变了却复用旧高度）。
  private func invalidateAll() {
    pages.removeAll()
    rows.removeAll()
  }

  // MARK: - 公共契约

  /// 同步测量整页：调用线程完成解析 + TextKit 测量并发布，返回即可查模型。
  /// 调用线程 = 列表页的后台队列（不得在主线程调用：整页 TextKit 测量）。
  /// - Parameter identities: 每行的内容身份（与 rows 同序）—— **行级缓存键的一半**，
  ///   由发布方（TiebaKindRowPages）传下来；缺省/长度不符时按 TiebaRowDiff 的同一规则现算。
  public func prepareFeedRowsBlocking(
    pageKey: String,
    rows: [[String: Any]],
    containerWidth: CGFloat,
    identities: [TiebaRowDiff.Entry.Identity]? = nil
  ) {
    guard !pageKey.isEmpty, !rows.isEmpty, containerWidth > 0 else { return }
    let width = TiebaLayout.quantize(containerWidth)
    let ids = (identities?.count == rows.count ? identities : nil)
      ?? TiebaRowDiff.entries(for: rows).map(\.identity)
    let index = measureAndIndex(pageKey: pageKey, raws: rows, width: width, identities: ids)
    pages.publish(index, forKey: PageKey(pageKey: pageKey, width: width))
  }

  /// 页内行数（按显式宽度取页；未测量/未知 → 0）：**位置行数**（索引在就算），
  /// 不代表内容还在 —— 要「真能画的行数」用 presentRowCount。
  public func feedRowCount(pageKey: String, containerWidth: CGFloat) -> Int {
    let width = TiebaLayout.quantize(containerWidth)
    return pages.value(forKey: PageKey(pageKey: pageKey, width: width))?.count ?? 0
  }

  /// 本页在本宽度下**真正可渲染**的行数（位置索引在、内容也在）。
  /// [精简] 行级缓存的淘汰粒度是行，「整页行数」给不出这个信息（TiebaKindRowPages
  /// 的 liveRowCount 用它判「度量是否还在」）。
  public func presentRowCount(pageKey: String, containerWidth: CGFloat) -> Int {
    let width = TiebaLayout.quantize(containerWidth)
    guard let index = pages.value(forKey: PageKey(pageKey: pageKey, width: width)) else { return 0 }
    var present = 0
    for key in index where rows.contains(key) { present += 1 }
    return present
  }

  /// 页内行数（该页最新一次 prepare 的宽度条目）。
  public func feedRowCount(pageKey: String) -> Int {
    newestIndex(pageKey: pageKey)?.count ?? 0
  }

  /// 取行模型（与测量时同一实例；越界/未知 → nil）。高度/模型查询必须显式传
  /// 宽度：拿错宽度条目会按旧帧计划绘制（与 TiebaKindListView 的高度闸门同判据）。
  /// 位置只是**入口**：页索引 → 内容键 → 行内容存储（内容本身与页无关）。
  public func feedRow(pageKey: String, containerWidth: CGFloat, index: Int) -> TiebaFeedRowModel? {
    let width = TiebaLayout.quantize(containerWidth)
    guard let keys = pages.value(forKey: PageKey(pageKey: pageKey, width: width)),
          keys.indices.contains(index) else { return nil }
    return rows.value(forKey: keys[index])
  }

  /// 行视图查询（Fabric 只给 (pageKey, index) 两个 prop，不下发行宽）：取该页
  /// 最新一次 prepare 的宽度条目。列表侧高度/预取查询走显式宽度重载。
  public func feedRow(pageKey: String, index: Int) -> TiebaFeedRowModel? {
    guard let keys = newestIndex(pageKey: pageKey), keys.indices.contains(index) else { return nil }
    return rows.value(forKey: keys[index])
  }

  /// **内容键查询**（列表侧用：TiebaKindItem.identity 就是它）：与 pageKey、与页索引的
  /// 整页淘汰都无关 —— 同一行内容在任何页里都命中同一份测量（同一实例）。命中同时刷新该行
  /// 时效，所以正在被列表逐行读取的内容不会被别的屏挤掉。
  public func feedRow(
    identity: TiebaRowDiff.Entry.Identity,
    containerWidth: CGFloat
  ) -> TiebaFeedRowModel? {
    let width = TiebaLayout.quantize(containerWidth)
    return rows.value(forKey: TiebaRowCacheKey(identity: identity, width: width))
  }

  /// **单行同步补测**：见 TiebaRowSyncRemeasure（三族度量共用一份实现，本方法只是它对本族
  /// 存储的绑定）。
  ///
  /// 为什么必须有它：`frameHeight(at:width:)` 原来在"同一内容还没在新宽度下测过"时返回一个
  /// 假高度（160），整行高度与内容对不上——症状是换宽度后可见行高度跳一下，而且这个假高度
  /// 会被布局当成真高度用于滚动定位。补测把"没测过的新宽度"当场变成"已测"，窗口不再存在。
  ///
  /// - Returns: nil = 连源行字典都不在了（这一行确实没有数据）。调用方应触发缺页重推，
  ///   **不要**再退回假高度。
  public func ensureFeedRow(
    identity: TiebaRowDiff.Entry.Identity,
    pageKey: String,
    index: Int,
    containerWidth: CGFloat
  ) -> TiebaFeedRowModel? {
    TiebaRowSyncRemeasure.ensure(
      identity: identity, pageKey: pageKey, index: index, containerWidth: containerWidth,
      rows: rows, raws: raws
    ) { raw, pageKey, index, width in
      TiebaFeedRowModel(pageKey: pageKey, index: index, raw: raw, containerWidth: width)
    }
  }

  // MARK: - 内部

  /// 该 pageKey 最新一次发布（order 最大）的页索引；无 → nil。
  /// 行视图只拿得到 (pageKey, index)，不知道宽度，所以按 pageKey 找最新。
  private func newestIndex(pageKey: String) -> [TiebaRowCacheKey]? {
    pages.newest { $0.pageKey == pageKey }
  }

  /// 整页解析 + TextKit 测量 + **写内容缓存**，返回该页的页索引（位置 → 内容键）。
  /// 顺序有讲究：先保证内容在、再发布索引 —— 索引一旦发布，位置查询就必须取得到内容。
  ///
  /// 逐行复用判据 = **内容键命中**（同页重推、跨页、跨屏都命中），未命中才解析 + 测量。
  /// [精简] 原判据 =「同一页同一宽度的上一份快照里、同下标的行指纹相同」，为此还得把整页
  /// 原始行字典一起缓存成 Page.raws 当比对基准。内容键把这件事降成一次字典查询：不再需要
  /// 页内快照，也不再有「同一行内容换个页就得重测」的重复测量。
  /// 指纹白名单（TiebaRowFingerprint）覆盖全部渲染输入 ⇒ 同指纹 = 同渲染结果，复用安全；
  /// 宽度也在键里 ⇒ 命中必然是同宽测得的那一份。
  private func measureAndIndex(
    pageKey: String,
    raws: [[String: Any]],
    width: CGFloat,
    identities: [TiebaRowDiff.Entry.Identity]
  ) -> [TiebaRowCacheKey] {
    let keys = identities.map { TiebaRowCacheKey(identity: $0, width: width) }
    // 源字典与模型一起留一份（宽度无关的键）：换宽度时才有东西可重测，见 self.raws 的注释。
    for (offset, identity) in identities.enumerated() where offset < raws.count {
      self.raws.insert(raws[offset], forKey: identity)
    }
    _ = rows.resolve(Array(raws.enumerated()), keys: keys) { pair in
      TiebaFeedRowModel(
        pageKey: pageKey,
        // [精简] 位置字段（pageKey/index）在内容键下不再唯一（模型可能是在别的页、别的下标
        // 上测出来的，值身份共享），且全仓无消费方（身份看 fingerprint/threadId）：这里按
        // 本次下标写入，只作备查。
        index: pair.offset,
        raw: pair.element,
        containerWidth: width
      )
    }
    return keys
  }

  // [精简] 原 measureRows（按页内快照逐行复用）与 publish（Page(rows:raws:) 挂 (pageKey,width) 键上）已删除：
  // 复用判据改成内容键命中（见 measureAndIndex），发布拆成 TiebaRowStore（内容键）+ TiebaPageStore（位置索引）。
}

// MARK: - 行级共享工具（TextKit 测量 / 字典取值，全仓唯一实现）

/// **单行同步补测**的公共实现：三族度量（feed / simple / post 的宽度闸门失配）共用同一套
/// 判定与写回顺序，不再各写一遍（原来 feed 与 simple 两份逐行相同）。
///
/// 它存在的理由：内容键里含宽度 ⇒ 换宽度（旋转/分屏/首帧宽度未定）后旧测量不再命中。
/// 留着源行字典就能当场按新宽度重测，而不是让布局拿一个与这一行无关的假高度。
nonisolated enum TiebaRowSyncRemeasure {
  /// - Returns: nil = 源行字典也不在了（这一行确实没数据）→ 调用方应触发重推，不要编高度。
  static func ensure<Model>(
    identity: TiebaRowDiff.Entry.Identity,
    pageKey: String,
    index: Int,
    containerWidth: CGFloat,
    rows: TiebaRowStore<TiebaRowCacheKey, Model>,
    raws: TiebaRowStore<TiebaRowDiff.Entry.Identity, [String: Any]>,
    make: ([String: Any], String, Int, CGFloat) -> Model
  ) -> Model? {
    let width = TiebaLayout.quantize(containerWidth)
    guard width > 0 else { return nil }
    let key = TiebaRowCacheKey(identity: identity, width: width)
    if let cached = rows.value(forKey: key) { return cached }
    guard let raw = raws.value(forKey: identity) else { return nil }
    let model = make(raw, pageKey, index, width)
    rows.insert(model, forKey: key)
    return model
  }
}

/// 行文本测量：TextKit 单次测量 + 单行宽度。TiebaFeedRowLayout / TiebaSimpleText
/// 的同类实现都收敛到这里（此前两处逐字重复；改一处不再漏另一处）。
