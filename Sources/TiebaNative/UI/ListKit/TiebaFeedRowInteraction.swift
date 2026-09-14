// ============================================================
// TiebaLite RN — 信息流行在原生列表里的命中判定 / 查看器转场（共享实现）
//
// 来由（2026-09-13，LegendList 拆除第 4 批）：这套逻辑（tapRegion /
// browserContextTitle / presentPhotoBrowser 的 items+transition 构造 /
// 揭示移位 revealPlan）原本是 TiebaListView 的 private 实现；那个列表拆除后
// 本文件是**唯一来源**（纯函数 + 纯几何，无状态、无 Expo 依赖）。
//
// 语义逐条对齐 src/hooks/useViewerSourceReveal.ts：
//   · 命中优先级：banner → avatar → chip → showMore → action → media → card；
//   · 图片点击由列表**原生直开**查看器（TiebaPhotoBrowser），不经 JS、不发 rowTap；
//     视频 poster（无 media 数组）不上报图片命中 → 继续走 rowTap 给 JS；
//   · 揭示移位：源图被顶栏（safeAreaTop + NAV_BAR_H）或屏底遮挡时，先算出列表
//     需要滚动的量与移位后的矩形；transition 用移位后矩形（退出飞回已就位处）。
// ============================================================

import UIKit

// MARK: - 查看器展示计划

/// 图片点击 → 查看器所需的全部入参（items / initialIndex / transition / 揭示移位）。
/// items/transition 是值类型（TiebaPhotoItem/TiebaPhotoTransition）：查看器 present
/// 的入参形态，不再有字典编组。
struct TiebaFeedRowBrowserPlan {
  let items: [TiebaPhotoItem]
  let initialIndex: Int
  /// viewer 页号 → 行内 media 下标（url 为 nil 的条目会被过滤，两者会错位）。
  let mediaIndexes: [Int]
  let transition: TiebaPhotoTransition
  /// 非 nil = 查看器展示动画后列表要滚动的量（正 = 内容上移）。
  let scrollDelta: CGFloat?
}

// MARK: - 交互几何

@MainActor
enum TiebaFeedRowInteraction {
  /// 顶栏遮挡判据的高度：对齐 src/constants/layout.ts 的 NAV_BAR_H（66）。
  static let revealNavBarHeight: CGFloat = 66

  /// 命中区域判定：具体区域先判，卡片兜底。媒体区只到这里（"media"），
  /// 带内序号由 cell 的 mediaHit 另行取得。
  static func tapRegion(
    for point: CGPoint,
    row: TiebaFeedRowModel
  ) -> (region: String, actionIndex: Int?) {
    let plan = row.plan
    if row.isTopBanner {
      return ("banner", nil)
    }
    if let frame = plan.avatarFrame, frame.contains(point) {
      return ("avatar", nil)
    }
    if let frame = plan.chipFrame, frame.contains(point) {
      return ("chip", nil)
    }
    if let frame = plan.showMoreFrame, frame.contains(point) {
      return ("showMore", nil)
    }
    for (index, frame) in plan.actionButtonFrames.enumerated() where frame.contains(point) {
      return ("action", index)
    }
    if let frame = plan.mediaFrame, frame.contains(point) {
      return ("media", nil)
    }
    return ("card", nil)
  }

  /// 顶栏上下文标题 = 帖子标题；无标题回落摘要前 30 字（旧查看器同语义）。
  static func browserContextTitle(for row: TiebaFeedRowModel) -> String? {
    let title = row.titleText.trimmingCharacters(in: .whitespacesAndNewlines)
    if !title.isEmpty { return title }
    let abstract = row.abstractText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !abstract.isEmpty else { return nil }
    return String(abstract.prefix(30))
  }

  /// 图片命中 → 查看器展示计划。
  ///
  /// - items：行模型 media 数组值类型直构（url = 卡片显示档 smallSrc||src，
  ///   thumbUrl 同 URL——TiebaPhotoItem 去重成单级加载；originUrl = 原图档）；
  /// - mediaIndexes：viewer 页号 → 行内 media 下标（退出时重算源图矩形用）；
  /// - transition：被点图片的窗口矩形（mediaHit 已换算）+ 垫图 + 顶栏上下文标题；
  /// - 揭示移位：源图被顶栏/屏底遮挡时给出 scrollDelta（调用方在展示动画后滚动）。
  /// - Returns: nil = 未受理（无 URL / 下标越界 / 无宿主窗口）。
  static func browserPlan(
    row: TiebaFeedRowModel,
    tappedMediaIndex: Int,
    windowRect: CGRect,
    in window: UIWindow?,
    contentOffset: CGFloat,
    contentSize: CGSize,
    adjustedContentInset: UIEdgeInsets
  ) -> TiebaFeedRowBrowserPlan? {
    guard tappedMediaIndex >= 0, tappedMediaIndex < row.media.count,
          row.media[tappedMediaIndex].url != nil else { return nil }
    var items: [TiebaPhotoItem] = []
    var mediaIndexes: [Int] = []
    var initialIndex = 0
    for (offset, entry) in row.media.enumerated() {
      guard let url = entry.url else { continue }
      if offset == tappedMediaIndex { initialIndex = items.count }
      mediaIndexes.append(offset)
      items.append(
        TiebaPhotoItem(
          url: url,
          thumbUrl: url,
          originUrl: entry.originURL,
          isGif: entry.isGif,
          isLong: entry.isLong,
          width: entry.width,
          height: entry.height
        )
      )
    }
    guard !items.isEmpty else { return nil }

    let reveal = revealPlan(
      for: windowRect,
      in: window,
      contentOffset: contentOffset,
      contentSize: contentSize,
      adjustedContentInset: adjustedContentInset
    )
    return TiebaFeedRowBrowserPlan(
      items: items,
      initialIndex: initialIndex,
      mediaIndexes: mediaIndexes,
      transition: TiebaPhotoTransition(
        frame: reveal.frame,
        contextTitle: browserContextTitle(for: row)
      ),
      scrollDelta: reveal.scrollDelta
    )
  }

  /// 揭示移位计划：源图被顶栏（safeAreaTop + NAV_BAR_H）或屏底
  /// （safeAreaBottom + 16pt 内的安全区）遮挡时，算出列表需要滚动的量与
  /// 移位后的矩形；未遮挡 → scrollDelta = nil（不滚动，矩形原样）。
  /// 几何与 useViewerSourceReveal.ts 的 guardTop/guardBottom 同源。
  static func revealPlan(
    for windowRect: CGRect,
    in window: UIWindow?,
    contentOffset: CGFloat,
    contentSize: CGSize,
    adjustedContentInset: UIEdgeInsets
  ) -> (frame: CGRect, scrollDelta: CGFloat?) {
    guard let window else { return (windowRect, nil) }
    let insets = window.safeAreaInsets
    let guardTop = insets.top + revealNavBarHeight
    let guardBottom = window.bounds.height - max(insets.bottom, 16)
    let clipTop = windowRect.minY < guardTop
    let clipBottom = windowRect.maxY > guardBottom
    guard clipTop || clipBottom else { return (windowRect, nil) }
    // 目标位移：正 = 内容上移（下一屏），与滚动方向一致。
    let desired = clipTop
      ? windowRect.minY - guardTop
      : windowRect.maxY - guardBottom
    let minOffset = -adjustedContentInset.top
    let maxOffset = max(
      contentSize.height + adjustedContentInset.bottom - window.bounds.height,
      minOffset
    )
    let targetOffset = min(max(contentOffset + desired, minOffset), maxOffset)
    let actual = targetOffset - contentOffset
    guard abs(actual) > 0.5 else { return (windowRect, nil) }
    return (windowRect.offsetBy(dx: 0, dy: -actual), actual)
  }
}
