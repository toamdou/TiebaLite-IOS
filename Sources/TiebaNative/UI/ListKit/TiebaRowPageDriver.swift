// ============================================================
// TiebaLite — 行页发布驱动（TiebaRowPageDriver）
//
// 通用列表页共用的「造行 → 后台整页测量 → 回主线程换页」流程：publish 在主线程
// 取行，Task.detached 跑 TiebaKindRowPages.prepareBlocking，回主后只在 pageKey
// 仍是本次发布的页时才 setPage——旧页测量后到不得覆盖新页（唯一竞态修复点）。
//
// 行的身份 = **内容指纹**（TiebaRowDiff）：判"纯追加"从"逐行 NSDictionary 递归深比较"
// 换成整数比较（旧行指纹随 lastRows 缓存，不重算）；变了的时候用 vendored
// 上游 Support 模块 的 tiebaMergeListsStableWithUpdates(isLess:isEqual:getId:) 算出
// 并随页把**内容身份**（TiebaRowDiff.Entry.identity）交给列表（setPage(pageKey:identities:)）：
// 列表的 TiebaKindItem 以内容身份为标识，diffable 据此自己算增量，
// 因此同页重推不再需要"可见行全量重配"。
// ============================================================

import Foundation
import Synchronization

@MainActor
public final class TiebaRowPageDriver {
  private let list: TiebaKindListContentView
  private let keyPrefix: String
  private var pageSeq = 0
  private var lastWidth: CGFloat = 0
  /// 上次的造行闭包：宽度变化（旋转/分屏）时用它以同页键重推。
  /// 调用方必须传 `[weak self]` 闭包，否则 page → driver → 闭包 → page 成环。
  private var lastMakeRows: (() -> [[String: Any]])?

  /// 发布序号（单调递增）。**回主守卫必须同时比它**：纯追加（loadMore）与 fresh:false
  /// （乐观点赞）都不换页键，只比 pageKey 时两次在途测量的完成闭包会互相覆盖 ——
  /// 晚到的旧快照把新状态拨回去（N9：刚加载出的行消失 / 红心被翻回去）。
  private var publishSeq = 0
  /// 已落地的最大序号：只有更新的发布才允许覆盖状态。
  private var landedSeq = 0

  /// 上次发布的整页行——每行带**内容指纹**（TiebaRowDiff.Entry）：判"追加"与算差量都读它，
  /// 旧行指纹因此只算一次、不重算。每屏一份、只留最近一页。
  /// 并发纪律与原来一致（唯一写点没变）：只在主线程写，且只在 publish 的回主闭包里、
  /// `self.pageKey == key` 成立时才落盘——旧页测量后到不得覆盖新页。
  /// 行与指纹同存同换（同一个数组，天然不会不同步）。
  private var lastRows: [TiebaRowDiff.Entry] = []

  /// 上次发布算出的行差量（删除 / 插入 / 更新三元组，定义见 TiebaRowDiff.Change）。
  /// 基准是上一次**已生效**的发布（lastRows 只在回主换页时落盘）。
  ///
  /// **只算不接**：本步的产出是"算得出差量"，不是"已经用上差量"。将来接的时候
  /// （不要在本文件里改 TiebaKindListView，那是另一个改动面）：
  ///   1. 行标识现在是 pageKey#index（位置身份）。差量要生效，列表侧得支持"不换页键就地
  ///      增删改"；纯追加（removals / updates 为空）与既有"保页键 + 尾部 insert"同路，
  ///      可以先只接这一条，风险最低；
  ///   2. 有删 / 有改时页键必须换（今天的行为），差量只能用来做动画 / 避免闪白，
  ///      不能省掉整页重建；
  ///   3. 下标语义：removals 是**旧页**下标（倒序删）；insertions / updates 的下标是
  ///      "删完 + 应用了前面若干插入"之后的当前页下标；previousIndex 是这行内容在旧页的位置。
  // [收敛] 原 `lastRowDiff: TiebaRowDiff.Change?` 已删除（2026-10-05）。
  // 它每次 publish 都要在主线程算一遍整页差量，却**始终没有消费方**；
  // 而它的用途（按内容做增量更新）现在由"行内容身份 + diffable"承担 ——
  // 列表侧 TiebaKindItem.identity 让 diffable 自己算出增删，不需要命令式差量。
  // `TiebaRowDiff.make` / `tailAppend` 作为**库 API** 保留（有 selfCheck 覆盖），
  // 将来若要做插入/删除动画（需要 previousIndex）可直接调用。

  /// 当前页键（fresh 发布时 = "\(keyPrefix)-\(pageSeq)"；未发布 = ""）。
  public private(set) var pageKey = ""

  /// 进程内实例域：页键命名空间原先只由宿主的 keyPrefix 决定，而多个宿主用的是
  /// **常量前缀**（forum-search / history / …）—— 两个存活实例（吧 A 搜索 → 点帖 →
  /// 帖内跳吧 B → 吧 B 搜索）pageSeq 追平即同键：后发布者覆写共享页记录与度量页索引，
  /// 两屏还会互相 pin/unpin（一屏 pop 摘掉另一屏在显页的 pin → 整页 LRU 挤掉在显页 =
  /// "点进帖子退回来只剩那张卡、上下全白"的静默留白重演）。
  /// 在 driver 里追加实例域：**一处修复覆盖全部调用方**，宿主给的 keyPrefix 语义不变。
  /// 用自增序号而不是对象地址：地址会被复用，进程级页记录里可能留着上一实例的同键条目。
  private static let instanceDomain = Mutex<Int>(0)

  public init(list: TiebaKindListContentView, keyPrefix: String) {
    self.list = list
    self.keyPrefix = keyPrefix + "-" + String(Self.instanceDomain.withLock { domain in
      domain += 1
      return domain
    })
    // 缺页自愈：列表发现**行内容确实没有测**（全局度量失效 / 换了宽度还没测完 /
    // 页面发布晚到）时回调这里重推（列表侧已按 0.5s 自适应节流）。
    // [精简] 触发面已收窄：页记录不再靠共享存储（列表自持 currentPage），行内容是
    // 内容键 + 跨页复用，所以"被别的屏挤掉就静默留白"那条链不再成立；留下的都是
    // 内容真不在的情况 —— 那类只有重推能救，且重推现在是内容全命中的廉价操作。
    list.onPageDataMissing = { [weak self] in
      self?.republishCurrentPage()
    }
  }

  /// 用同一页键重推当前页：数据仍在宿主手里（`lastMakeRows` 读的就是宿主数据源），
  /// 代价只有一次后台整页测量。
  ///
  /// [精简] 删掉本类里的第二道 TiebaAdaptiveThrottle（机制本身没删，见列表侧
  /// TiebaKindListContentView.pageMissingThrottle）：本方法的唯一调用方是列表的
  /// onPageDataMissing，而列表侧 notifyPageDataMissing 已经用**同一个类、同样的输入**
  /// （now / isOffScreen）做过 0.5s 起步的自适应节流 —— 同一条路上串两个同参数节流器，
  /// 只会把间隔变成两者之积，防不住任何它单独防不住的场景。
  /// 而且重推现在**很便宜**：行级度量缓存键 = 内容身份，重推是"内容全命中 + 重建页索引"，
  /// 不再是整页 TextKit 重测 —— 这正是这道重复保险可以撤掉的直接原因。
  public func republishCurrentPage() {
    guard !pageKey.isEmpty, let makeRows = lastMakeRows else { return }
    publish(fresh: false, makeRows: makeRows)
  }

  /// 宿主 viewDidLayoutSubviews 调用。宽度量化后与上次不同才重推（同页键）：
  /// 首次拿到宽度时把 publish 早期暂存的请求补发。
  public func updateWidth(_ width: CGFloat) {
    let quantized = TiebaLayout.quantize(width)
    guard quantized != lastWidth else { return }
    lastWidth = quantized
    guard !pageKey.isEmpty, let makeRows = lastMakeRows else { return }
    publish(fresh: false, makeRows: makeRows)
  }

  /// 发布整页：fresh=true 表示"数据集合变了"。**但"追加下一页"不该换页键**——
  /// 页键进了行标识（pageKey#index），换键 = 所有行的标识全变 ⇒ 集合视图整页
  /// reload（可见 cell 全部销毁重建），而那正是用户滚到底触发加载的那一刻，表现
  /// 就是"每加载一页卡一下、图还要重贴一遍"。旧行逐行未变（= 新行以旧行为前缀）
  /// 时保持页键，只把新增的尾部 insert 进去，既有 cell 原样留着；任何一行变了
  /// （点赞/换排序/首屏换数据/偏好变更）前缀就不成立，照旧换键整页 reload——此时
  /// 该判据只用于**页键决策**（纯追加 → 保页键）；内容增量由列表的身份 diffable 负责。
  /// 无宽度时先记 pending，等 updateWidth 补发。makeRows 在宽度变化时会被再次
  /// 调用，因此是 @escaping；调用方用 `[weak self]` 闭包，避免成环。
  public func publish(fresh: Bool, makeRows: @escaping () -> [[String: Any]]) {
    publishSeq += 1
    let seq = publishSeq
    let rows = makeRows()
    // 整页内容指纹算一次（O(行数)）：判"追加"与算差量共用同一份，不重复求哈希。
    let entries = TiebaRowDiff.entries(for: rows)
    let appendOnly = isAppend(entries)
    if fresh, !appendOnly {
      pageSeq += 1
      pageKey = "\(keyPrefix)-\(pageSeq)"
    }
    // [收敛] 这里原本每 publish 都算一次整页差量（tailAppend / MergeLists）并存入
    // lastRowDiff，但**无消费方**，纯属主线程浪费 —— 已删除。
    // 差量的作用（按内容做增量更新）由 TiebaRowDiff.Entry.identity 承担：
    // 身份随行传给列表，diffable 据此自己算增删改。
    guard !pageKey.isEmpty else { return }
    lastMakeRows = makeRows
    guard lastWidth > 0 else {
      lastRows = entries   // 宽度未就位：补发时也要能判出这是不是追加
      return
    }
    let key = pageKey
    let width = lastWidth
    let box = RowsBox(rows: rows, entries: entries)
    // 屏在窗上（含首屏加载期）用 userInitiated；已上过屏但现在离屏（被 push 盖住）
    // 降到 utility——测出来也是给离屏的那一屏用，不该和滚动抢 CPU。
    let offscreen = list.isOffScreen
    Task { @MainActor [weak self] in
      await Task.detached(priority: offscreen ? .utility : .userInitiated) {
        TiebaKindRowPages.shared.prepareBlocking(
          pageKey: key,
          rows: box.rows,
          containerWidth: width,
          // [精简] 把本驱动**已经算好**的整页内容身份一起传下去：它正是行级度量缓存的键，
          // 度量侧因此不再对同一批行重算一遍指纹（一次 O(行数) 的哈希），而且三处同键：
          // 页面记录（族内下标）、列表身份（TiebaKindItem.identity）、度量缓存。
          identities: box.entries.map(\.identity)
        )
      }.value
      // 双重守卫：页键（换页整页重载）**+ 发布序号**（同键也要比 —— 追加/乐观点赞都不换键）。
      guard let self, self.pageKey == key, seq > self.landedSeq else { return }
      self.landedSeq = seq
      self.lastRows = box.entries
      // [采用] 把**内容身份**随页一起交给列表：diffable 据此按内容增量更新，
      // 不再需要"同页重推就把可见行全部重配"（见 TiebaKindListView.setPage）。
      self.list.setPage(pageKey: key, identities: box.entries.map(\.identity))
    }
  }

  /// 新行是否只是"旧行的尾部追加"（旧行逐行未变，新行更长或等长）——**基于指纹的快速路径**。
  ///
  /// 判据 = 内容指纹 + 同指纹序号（TiebaRowDiff.isPrefix）：只比 UInt64，不再对每行做
  /// `(row as NSDictionary).isEqual(to:)` 的整页递归深比较；旧行指纹是上次发布时算好的
  /// （lastRows），这里不重新求哈希；第一处不同立即返回 false（换数据 / 换排序在第 0 行
  /// 就退，与旧实现同样的早期退出）。
  ///
  /// 外部语义与旧实现逐字一致：lastRows 为空（首次发布）不算追加、行数变少不算追加、
  /// 判据仍是"整行内容逐字段相同"（不是"渲染输入相同"——后者会改变页键决策，见
  /// TiebaRowDiff 文件头）。
  private func isAppend(_ entries: [TiebaRowDiff.Entry]) -> Bool {
    guard !lastRows.isEmpty else { return false }
    return TiebaRowDiff.isPrefix(left: lastRows, right: entries)
  }

  /// 跨线程投递的入参快照盒：行字典与内容指纹都含非 Sendable 的 `[String: Any]`，
  /// 投递后调用方不再持有 / 改写（与 TiebaKindRowPages 的 SendableRows 同约定）。
  private struct RowsBox: @unchecked Sendable {
    let rows: [[String: Any]]
    let entries: [TiebaRowDiff.Entry]
  }
}
