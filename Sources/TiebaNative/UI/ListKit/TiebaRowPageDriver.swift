// ============================================================
// TiebaLite — 行页发布驱动（TiebaRowPageDriver）
//
// 通用列表页共用的「造行 → 后台整页测量 → 回主线程换页」流程：publish 在主线程
// 取行，Task.detached 跑 TiebaKindRowPages.prepareBlocking，回主后只在 pageKey
// 仍是本次发布的页时才 setPage——旧页测量后到不得覆盖新页（唯一竞态修复点）。
// ============================================================

import Foundation

@MainActor
public final class TiebaRowPageDriver {
  private let list: TiebaKindListContentView
  private let keyPrefix: String
  private var pageSeq = 0
  private var lastWidth: CGFloat = 0
  /// 上次的造行闭包：宽度变化（旋转/分屏）时用它以同页键重推。
  /// 调用方必须传 `[weak self]` 闭包，否则 page → driver → 闭包 → page 成环。
  private var lastMakeRows: (() -> [[String: Any]])?

  /// 上次发布的整页行字典（判"追加"用，见 publish）。每屏一份、只留最近一页。
  private var lastRows: [[String: Any]] = []

  /// 当前页键（fresh 发布时 = "\(keyPrefix)-\(pageSeq)"；未发布 = ""）。
  public private(set) var pageKey = ""

  /// 上次"缺页自愈重推"的时刻（节流用）。
  private var lastRepublishAt: CFTimeInterval = 0

  public init(list: TiebaKindListContentView, keyPrefix: String) {
    self.list = list
    self.keyPrefix = keyPrefix
    // 缺页自愈：列表发现当前页被别的屏的整页 LRU 挤掉时回调这里（列表侧已按
    // 0.5s 节流）。没有这一步，被挤掉的页就是**静默留白**——行查不到内容就不
    // 配置、cell 保持清空态，用户看到的正是"列表突然一片空白"。
    list.onPageDataMissing = { [weak self] in
      self?.republishCurrentPage()
    }
  }

  /// 用同一页键重推当前页：数据仍在宿主手里（`lastMakeRows` 读的就是宿主数据
  /// 源），代价只有一次后台整页测量。列表侧已节流，这里再兜一道防重推风暴。
  public func republishCurrentPage() {
    guard !pageKey.isEmpty, let makeRows = lastMakeRows else { return }
    // 单调时钟（本文件只 import Foundation，不引 QuartzCore）。
    let now = ProcessInfo.processInfo.systemUptime
    guard now - lastRepublishAt >= 0.5 else { return }
    lastRepublishAt = now
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
  /// 就是"每加载一页卡一下、图还要重贴一遍"。旧行逐字未变（= 新行以旧行为前缀）
  /// 时保持页键，只把新增的尾部 insert 进去，既有 cell 原样留着；任何一行变了
  /// （点赞/换排序/首屏换数据/偏好变更）前缀就不成立，照旧换键整页 reload。
  /// 无宽度时先记 pending，等 updateWidth 补发。makeRows 在宽度变化时会被再次
  /// 调用，因此是 @escaping；调用方用 `[weak self]` 闭包，避免成环。
  public func publish(fresh: Bool, makeRows: @escaping () -> [[String: Any]]) {
    let rows = makeRows()
    if fresh, !isAppend(rows) {
      pageSeq += 1
      pageKey = "\(keyPrefix)-\(pageSeq)"
    }
    guard !pageKey.isEmpty else { return }
    lastMakeRows = makeRows
    guard lastWidth > 0 else {
      lastRows = rows   // 宽度未就位：补发时也要能判出这是不是追加
      return
    }
    let key = pageKey
    let width = lastWidth
    let box = RowsBox(rows: rows)
    Task { @MainActor [weak self] in
      await Task.detached(priority: .userInitiated) {
        TiebaKindRowPages.shared.prepareBlocking(
          pageKey: key,
          rows: box.rows,
          containerWidth: width
        )
      }.value
      guard let self, self.pageKey == key else { return }
      self.lastRows = box.rows
      self.list.setPage(pageKey: key)
    }
  }

  /// 新行是否只是"旧行的尾部追加"。逐行早期退出：换排序/换数据在第 0 行就退，
  /// 只有真追加才走满（一次发布一次，不在滚动路径上）。
  private func isAppend(_ rows: [[String: Any]]) -> Bool {
    guard !lastRows.isEmpty, lastRows.count <= rows.count else { return false }
    for index in lastRows.indices
    where !(lastRows[index] as NSDictionary).isEqual(to: rows[index]) {
      return false
    }
    return true
  }

  private struct RowsBox: @unchecked Sendable {
    let rows: [[String: Any]]
  }
}
