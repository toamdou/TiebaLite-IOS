// 帖子行模型 + 高度缓存（thread/[id] 原生页）：与 TiebaRowMetrics 同架构——
// 原生 VC 在后台队列一次性测量整页，行视图按 (pageKey, index) 同步取模型。
//
// 行高只在这里算一次；TiebaPostRowView 只按 model.plan 摆 frame（测多少画多少）。
// 页面数据是原生类型（TiebaThreadPost），不经过 JS 字典。
import UIKit
import Nuke


// MARK: - 测量缓存

/// [精简] 评估结论：**本族保留整页键（pageKey），不改成内容键**（不是漏改）。
///   · 行内容的**身份在这里拿不到**：帖子行由调用方（TiebaThreadViewController 等）先建好
///     [TiebaPostRowModel] 再 prepare，本类看不到原始行字典，也没有 TiebaRowDiff 的 Entry
///     （指纹算法只对 JS 行字典定义）。给 TiebaPostRowModel 现造一个「帧计划输入指纹」等于
///     把测量输入重新枚举一遍，漏一个字段就是「内容换了却复用旧几何」的静默错画 —— 不值得赌。
///   · 帖子页是「一屏一页、整页重发」：同一条回复不会跨页重复出现，内容键本来也省不下多少重测。
///   · 它的淘汰窗口仍由在显页 pin + 缺页自愈（TiebaPostListPageController）覆盖。
/// 键里仍只有 pageKey（不含宽度）：帖子行模型自带 containerWidth，列表侧另有宽度闸门。
final class TiebaPostRowMetrics: @unchecked Sendable {
  static let shared = TiebaPostRowMetrics()

  private struct Page {
    var models: [TiebaPostRowModel]
  }

  /// 整页缓存（LRU + 在显页跳过）：四族度量缓存共用 TiebaPageStore。
  private let pages = TiebaPageStore<String, Page>(pinKey: { $0 })

  private init() {}

  /// 整页发布（调用方在后台队列执行；返回后 row/rowCount 立即可查）。
  func prepare(pageKey: String, models: [TiebaPostRowModel]) {
    guard !pageKey.isEmpty else { return }
    pages.publish(Page(models: models), forKey: pageKey)
  }

  func row(pageKey: String, index: Int) -> TiebaPostRowModel? {
    guard let page = pages.value(forKey: pageKey), page.models.indices.contains(index) else {
      return nil
    }
    return page.models[index]
  }

  /// **单行同步补测**（列表的宽度闸门未命中时调用）：用同一份输入在当前宽度重测并替换
  /// 页内那一行，返回新模型。
  ///
  /// 为什么必须有它：帖子行模型自带 containerWidth，列表侧另有宽度闸门；换宽度后
  /// （旋转/分屏/首帧宽度未定）旧模型不再命中，`frameHeight(at:width:)` 原来就返回假高度
  /// （160）——症状是换宽度后可见楼层高度跳一下、滚动定位跟着错。补测把这一行当场按新宽度
  /// 测好写回，窗口不再存在。
  ///
  /// - Returns: nil = 页记录里没有这一行（确实没数据），调用方应触发重推，不要退回假高度。
  func ensureRow(pageKey: String, index: Int, containerWidth: CGFloat) -> TiebaPostRowModel? {
    guard let existing = row(pageKey: pageKey, index: index) else { return nil }
    let width = TiebaLayout.quantize(containerWidth)
    guard width > 0, existing.containerWidth != width else { return existing }
    let remeasured = existing.remeasured(containerWidth: width)
    replace(pageKey: pageKey, index: index, model: remeasured)
    return remeasured
  }

  /// 单行替换（点赞等只重建本行；行数不变，调用方随后 setPage 重配可见行）。
  func replace(pageKey: String, index: Int, model: TiebaPostRowModel) {
    pages.mutate(pageKey) { page in
      guard page.models.indices.contains(index) else { return }
      page.models[index] = model
    }
  }

  func rowCount(pageKey: String) -> Int {
    pages.value(forKey: pageKey)?.models.count ?? 0
  }
}

