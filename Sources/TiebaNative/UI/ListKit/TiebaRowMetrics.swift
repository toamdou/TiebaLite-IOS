// ============================================================
// TiebaLite — 信息流行模型 / 高度缓存（TiebaRowMetrics）
//
// 唯一形态：原生列表容器（TiebaKindRowPages / TiebaRowPageDriver）在后台线程调
// prepareFeedRowsBlocking 一次性推整页行字典并同步测完（返回即可查）；行视图只拿
// (pageKey, index) 两个原始 prop 从本缓存同步取模型（与测量同一实例，
// NSAttributedString 已在测量期构建，绘制期零重建）。
//
// 缓存约束：
//   - 键 =（pageKey, 0.5pt 量化宽度）：宽度是键的一部分，同屏多个不同宽度的
//     列表互不清页（无全局宽度闸门）；同一页换宽度 = 新条目，旧条目随 LRU 淘汰。
//   - 整页 LRU：最多 maxPages 页，超限从最旧页整页淘汰（不逐行淘汰）。
//   - 逐行复用：prepare 时行字典与上次相同的行直接复用旧模型（点赞/展开重推整页
//     时只有被点的行需要重测富文本与 TextKit）。
//   - 动态字号档变化（UIContentSizeCategory）→ 全部高度作废，由页面重推恢复。
//
// 并发：所有共享状态由 lock 保护；类以 @unchecked Sendable 声明该不变量
//（仓库既有惯例：TiebaBackgroundSync / TiebaProtoRegistry / TiebaBackgroundSnapshot）。
// NSAttributedString / UIFont / NSLayoutManager 的测量在后台线程使用是安全的
//（TextKit 自 iOS 7 起线程安全，绘制只在主线程读取缓存结果）。
// ============================================================

import UIKit

// MARK: - 媒体

/// 行内一张图片（绘制 + 长按菜单的输入）。
public nonisolated struct TiebaFeedRowMedia: Sendable {
  /// 卡片显示档 = smallSrc || src（对齐 MediaPager.tsx:117 的取值），已升级 https。
  public let url: URL?
  /// 原图档（originSrc）：查看器「查看原图」与长按「保存照片/分享照片」用原图
  /// 字节（RN 版 PostImageContextMenu full = originSrc）。旧数据缺 originSrc
  /// 时为 nil，消费方回落显示档（与 RN 的 `originSrc || src` 同语义）。
  public let originURL: URL?
  public let isGif: Bool
  /// height/width > 2.4（MediaPager.tsx:121 LONG_IMAGE_RATIO，右下角「长图」徽标）。
  public let isLong: Bool
  /// 服务端「显示查看原图按钮」（show_original_btn）：查看器长按菜单据此出现
  /// 「查看原图」（GIF 恒为 0，见 TiebaPhotoItem.canViewOriginal）。
  public let showOriginalBtn: Bool
  public let width: Double
  public let height: Double

  /// 宽高比（w/h，异常值按 1）。
  var aspectRatio: CGFloat {
    guard width > 0, height > 0 else { return 1 }
    return CGFloat(width / height)
  }
}

// MARK: - 行模型

/// 单行信息流的完整绘制输入。不可变（init 后无写入口），故可安全跨线程共享，
/// 以 @unchecked Sendable 声明（含 NSAttributedString 缓存字段）。
public nonisolated final class TiebaFeedRowModel: @unchecked Sendable {
  // ── 身份与布局输入 ──
  public let pageKey: String
  public let index: Int
  /// 帖子 id（JS 下发）：行复用时区分"同一帖重配"与"换了另一帖"——计数跳动
  /// 只在同一帖的计数变化时播（对齐 RN 的组件复用语义）。
  public let threadId: String
  /// 测量所用容器宽度（= JS 给行的显式宽度）。
  public let containerWidth: CGFloat
  /// 应用内阅读字号倍率（设置→fontScale；缺省 1，仅参与截断启发式，不参与字号）。
  public let fontScale: CGFloat
  /// 整行高度（含卡片外 10pt 左右 / 4pt 上下边距）——JS 直接把它设为行高。
  public let measuredHeight: CGFloat

  // ── 头部（TweetCard.tsx:328-386）──
  public let avatarURL: URL?
  public let avatarInitial: String
  public let displayName: String
  /// 「发帖于 3小时前」/「回复于 …」（JS 可用 timeText 键预解析；否则原生算）。
  /// （「@原始用户名」不再单列：它与时间合成 metaAttributed，见下。）
  public let timeText: String?
  /// 「IP属地：xx」（设置 showIpLocation 默认开）。
  public let ipText: String?
  /// 名字行尾部的元信息 =「@昵称 + 时间」合成**一个** attributed（两段同为 15pt
  /// regular）：合成后每张卡少一个 label、少一次文本布局。两段之间的 4pt 空隙烘进
  /// 前一段最后一个字符的 kern（= RN nameRow 的 gap），所以位置与"两个 label 各占
  /// 一段"逐像素一致；单行尾部截断。
  public let metaAttributed: NSAttributedString?

  // ── 正文（TweetCard.tsx:407-450）──
  public let titleText: String
  /// 标题前缀（精品 →「精品 」）。颜色不写进测量期的串：绘制期按
  /// palette.warning 补（换主题即变，与 primary/liked 同机制）。
  public let titlePrefix: String?
  public let abstractText: String
  /// 长文截断判据（TweetCard.tsx:221 weightedTextLength > 120/fontScale）。
  public let isCollapsible: Bool
  public let showMoreText: String
  public let expanded: Bool
  /// 截断时标题 2 行；展开/不截断为 0（无上限）。
  public let titleLineLimit: Int
  /// 截断时摘要 4 行（COLLAPSE_LINES - 2）。
  public let abstractLineLimit: Int

  // ── 媒体（MediaPager.tsx）──
  public let media: [TiebaFeedRowMedia]
  public let videoPosterURL: URL?
  /// 单图/视频 poster 高度（测量时按宽高比钳制算好；含 1…520 与 260 兜底）。
  public let singleMediaHeight: CGFloat?
  /// 多图带的统一行高（160…340 钳制），仅多图时有值。
  public let stripHeight: CGFloat?
  public let mediaIsStrip: Bool
  public let showsVideoPoster: Bool
  public let showsMedia: Bool

  // ── 转发引用帖（TweetCard.tsx:470-488）──
  public let quoteForumText: String?
  public let quoteTitleText: String?
  public let quoteContentText: String?

  // ── 吧名徽章（TweetCard.tsx ForumChip）──
  public let showsForumChip: Bool
  public let forumName: String
  public let forumAvatarURL: URL?
  public let forumChipInitial: String

  // ── 操作栏（TweetCard.tsx:505-541）──
  public let showsActions: Bool
  public let replyText: String
  public let shareText: String
  public let likeText: String
  public let isLiked: Bool
  /// 原始点赞数（zanNum）：计数跳动的判据（RN numPop 比较的是 count 数值，
  /// 文案格式化后 1.0万→1.0万 的等值档位也要跳，故不能只比文案）。
  public let likeCount: Double

  // ── 置顶横幅（TweetCard.tsx TopBanner；isTop 行整行走横幅）──
  public let isTopBanner: Bool
  public let bannerText: String

  // ── 交互开关（JS 下发，原生不猜业务场景）──
  /// 右上角 ×（屏蔽/举报）菜单项：TweetCard closeMenuOptions 的取值子集
  /// （dislike / block / copy-title）。空数组 = 该行不绘制菜单钮（与
  /// TweetCard 未传 onMenuAction 时一致）；缺 key 同样为空。
  public let menuOptions: [String]
  /// 图片长按菜单（TweetCard imageContextMenu）：保存照片 / 分享照片。
  public let showsImageContextMenu: Bool

  // ── 绘制缓存（internal：仅同模块的 TiebaFeedRowView 消费）──
  let geometry: TiebaFeedRowLayout.Geometry
  let blocks: TiebaFeedRowBlocks
  /// 帧计划：测量期算一次（纯算术，模型不可变；布局期不再重算）。
  let plan: TiebaFeedRowLayoutPlan
  let titleAttributed: NSAttributedString?
  let abstractAttributed: NSAttributedString?
  let quoteForumAttributed: NSAttributedString?
  let quoteTitleAttributed: NSAttributedString?
  let quoteContentAttributed: NSAttributedString?
  let bannerAttributed: NSAttributedString?

  init(pageKey: String, index: Int, raw: [String: Any], containerWidth: CGFloat) {
    let fontScale = min(max(CGFloat(TiebaRowDict.double(raw["fontScale"]) ?? 1), 0.8), 2.0)
    let geometry = TiebaFeedRowLayout.geometry(containerWidth: containerWidth, fontScale: fontScale)
    let fonts = geometry.fonts
    let lineHeights = geometry.lineHeights
    let textWidth = geometry.textColumnWidth

    // ── 头部 ──
    let authorNameShow = TiebaRowDict.nonEmpty(raw["authorNameShow"]) ?? ""
    let authorName = TiebaRowDict.nonEmpty(raw["authorName"]) ?? ""
    let displayName = TiebaRowDict.nonEmpty(raw["displayName"])
      ?? (authorNameShow.isEmpty ? (authorName.isEmpty ? "吧友" : authorName) : authorNameShow)

    var handleText: String? = TiebaRowDict.nonEmpty(raw["handle"]).map {
      $0.hasPrefix("@") ? $0 : "@\($0)"
    }
    if handleText == nil,
       TiebaRowDict.bool(raw["showBothUsername"]) == true,
       !authorName.isEmpty, authorName != displayName {
      handleText = "@\(authorName)"
    }

    var timeText: String? = TiebaRowDict.nonEmpty(raw["timeText"])
    if timeText == nil {
      let timeType = TiebaRowDict.string(raw["timeType"]) ?? "create"
      let rawValue = TiebaRowDict.double(raw["timeValue"])
        ?? TiebaRowDict.double(raw[timeType == "last" ? "lastTime" : "createTime"])
      if let rawValue, rawValue > 0 {
        let style = TiebaRowDict.string(raw["timestampStyle"]) ?? "relative"
        let label = style == "absolute"
          ? TiebaFeedRowParser.absoluteTime(ms: rawValue)
          : TiebaFeedRowParser.relativeTime(ms: rawValue)
        if !label.isEmpty {
          timeText = (timeType == "last" ? "回复于 " : "发帖于 ") + label
        }
      }
    }

    var ipText: String? = TiebaRowDict.nonEmpty(raw["ipText"])
    if ipText == nil,
       TiebaRowDict.bool(raw["showIpLocation"]) != false,
       let ip = TiebaRowDict.nonEmpty(raw["authorIP"]) {
      ipText = "IP属地：\(ip)"
    }

    let portrait = TiebaRowDict.nonEmpty(raw["authorPortrait"]) ?? ""
    let avatarURL = TiebaRowDict.avatarURL(portrait)
    let avatarInitial = displayName.first.map(String.init) ?? "?"

    // ── 正文 ──
    let titleText = TiebaRowDict.string(raw["title"]) ?? ""
    let abstractText = TiebaRowDict.nonEmpty(raw["abstract"]) ?? ""
    let isGood = TiebaRowDict.bool(raw["isGood"]) == true
    let isTop = TiebaRowDict.bool(raw["isTop"]) == true
    let expanded = TiebaRowDict.bool(raw["expanded"]) == true
    let weighted = TiebaFeedRowParser.weightedTextLength(titleText, abstractText)
    // 折叠候选 = JS 判据（显式 collapsible 或字数超阈值）。是否**真**可展开要到
    // 折叠行数下量出截断才知道：只看字数会让阈值内的短卡也长出「显示更多」，
    // 点开没有任何被藏起来的文字（用户报的"点了没反应、按钮还消失了"）。
    let collapseCandidate = TiebaRowDict.bool(raw["collapsible"])
      ?? (weighted > TiebaFeedRowLayout.longTextWeightedChars / max(fontScale, 0.1))
    let collapsed = collapseCandidate && !expanded
    let titleLineLimit = collapsed ? 2 : 0
    let abstractLineLimit = collapsed ? TiebaFeedRowLayout.collapseLines - 2 : 0

    var titleAttributed: NSAttributedString?
    if !titleText.isEmpty {
      // RN 仅在 title 非空时渲染标题行（isGood 前缀随之；title 为空时前缀也不出现）。
      let composed = NSMutableAttributedString()
      if isGood {
        // 前缀色不在这里定：模型不知道主题，绘制期按 palette.warning 覆盖
        // titlePrefix 范围（换主题即变）；测量只吃 font/行高，与色无关。
        composed.append(TiebaFeedRowLayout.makeAttributed(
          text: "精品 ",
          font: fonts.title,
          color: .label,
          lineHeight: lineHeights.title
        ))
      }
      composed.append(TiebaFeedRowLayout.makeAttributed(
        text: titleText,
        font: fonts.title,
        color: .label,
        lineHeight: lineHeights.title
      ))
      titleAttributed = composed
    }
    let titleMeasure = titleAttributed.map {
      TiebaRowText.measure($0, width: textWidth, maxLines: titleLineLimit)
    }
    let titleHeight = titleMeasure?.height

    var abstractAttributed: NSAttributedString?
    if !abstractText.isEmpty {
      abstractAttributed = TiebaFeedRowLayout.makeAttributed(
        text: abstractText,
        font: fonts.abstract,
        color: .secondaryLabel,
        lineHeight: lineHeights.abstract
      )
    }
    let abstractMeasure = abstractAttributed.map {
      TiebaRowText.measure($0, width: textWidth, maxLines: abstractLineLimit)
    }
    let abstractHeight = abstractMeasure?.height

    // 名字行尾部元信息：@昵称 + 时间 合成一个 attributed（见 metaAttributed 注释）。
    var metaAttributed: NSAttributedString?
    if handleText != nil || timeText != nil {
      let composed = NSMutableAttributedString()
      if let handleText {
        composed.append(TiebaFeedRowLayout.makeAttributed(
          text: handleText,
          font: fonts.handle,
          color: .secondaryLabel,
          lineHeight: lineHeights.subhead
        ))
        if timeText != nil, composed.length > 0 {
          // 空隙烘进前一段的最后一个字符（kern 加在字符之后）⇒ 合成串的排版宽度
          // = handleWidth + headerTextGap + timeWidth，与原来两段各排一次完全相等。
          composed.addAttribute(
            .kern,
            value: TiebaFeedRowLayout.headerTextGap,
            range: NSRange(location: composed.length - 1, length: 1)
          )
        }
      }
      if let timeText {
        composed.append(TiebaFeedRowLayout.makeAttributed(
          text: timeText,
          font: fonts.time,
          color: .secondaryLabel,
          lineHeight: lineHeights.subhead
        ))
      }
      metaAttributed = composed
    }

    // 只有真被截断才给「显示更多」：按钮存在与否 = 有没有被藏起来的文字。
    let truncated = (titleMeasure?.truncated ?? false) || (abstractMeasure?.truncated ?? false)
    // 展开态下量的是全文（不限行）判不出截断，沿用候选值；此时行已展开，
    // isCollapsible 不参与任何绘制。
    let isCollapsible = expanded ? collapseCandidate : (collapseCandidate && truncated)
    let showMoreVisible = collapsed && truncated
    let showMoreText = "显示更多"
    let showMoreHeight: CGFloat? = showMoreVisible ? lineHeights.subhead + 4 : nil

    // ── 媒体 ──
    let parsedMedia = TiebaFeedRowParser.parseMedia(raw)
    let videoPosterURL = TiebaFeedRowParser.parseVideoPoster(raw)
    let hideMedia = TiebaRowDict.bool(raw["hideMedia"]) == true
    let media = hideMedia ? [] : parsedMedia
    let poster = hideMedia ? nil : videoPosterURL

    let mediaIsStrip = media.count >= 2
    // MultiImageStrip 先 slice(0, MAX_IMAGES_PER_ROW) 再算行高与单图宽：行高基准
    // 只取挂载上限内的图（第 10 张起只影响 +N 角标）。
    let shownMedia = Array(media.prefix(TiebaFeedRowLayout.maxImagesPerRow))
    var singleMediaHeight: CGFloat?
    var stripHeight: CGFloat?
    if mediaIsStrip {
      stripHeight = TiebaFeedRowLayout.stripHeight(for: shownMedia, columnWidth: textWidth)
    } else if let first = media.first {
      singleMediaHeight = TiebaFeedRowLayout.singleMediaHeight(for: first, columnWidth: textWidth)
    } else if poster != nil {
      // 视频 poster：MediaPager heightOf(0) 在无图时兜底 260（MULTI_MEDIA_HEIGHT）。
      singleMediaHeight = TiebaFeedRowLayout.mediaFallbackHeight
    }
    let mediaHeight = stripHeight ?? singleMediaHeight
    let showsMedia = mediaHeight != nil
    // 图片带每张图宽 = 行高 × w/h（MultiImageStrip itemWidths）。
    let mediaItemWidths: [CGFloat] = {
      guard mediaIsStrip, let stripHeight else { return [] }
      return shownMedia.map { stripHeight * $0.aspectRatio }
    }()

    // ── 转发引用帖 ──
    var quoteForumText: String?
    var quoteTitleText: String?
    var quoteContentText: String?
    if TiebaRowDict.bool(raw["isShareThread"]) == true,
       let origin = TiebaFeedRowParser.dictionary(raw["originThreadInfo"]) {
      quoteForumText = TiebaRowDict.nonEmpty(origin["forumName"])
      quoteTitleText = TiebaRowDict.nonEmpty(origin["title"])
      let content = TiebaFeedRowParser.contentToText(origin["content"])
      quoteContentText = content.isEmpty ? nil : content
    }

    var quoteForumAttributed: NSAttributedString?
    var quoteTitleAttributed: NSAttributedString?
    var quoteContentAttributed: NSAttributedString?
    var quoteForumLineHeight: CGFloat?
    var quoteTitleLineHeight: CGFloat?
    var quoteContentLineHeight: CGFloat?
    var quoteHeight: CGFloat?
    if quoteForumText != nil || quoteTitleText != nil || quoteContentText != nil {
      var stacked = TiebaFeedRowLayout.quotePadding * 2
      var lineCount = 0
      if let quoteForumText {
        quoteForumAttributed = TiebaFeedRowLayout.makeAttributed(
          text: quoteForumText,
          font: fonts.quoteForum,
          color: .secondaryLabel,
          lineHeight: lineHeights.quoteForum
        )
        quoteForumLineHeight = lineHeights.quoteForum
        stacked += lineHeights.quoteForum
        lineCount += 1
      }
      if let quoteTitleText {
        quoteTitleAttributed = TiebaFeedRowLayout.makeAttributed(
          text: quoteTitleText,
          font: fonts.quoteTitle,
          color: .label,
          lineHeight: lineHeights.quoteTitle
        )
        quoteTitleLineHeight = lineHeights.quoteTitle
        stacked += lineHeights.quoteTitle
        lineCount += 1
      }
      if let quoteContentText {
        let content = TiebaFeedRowLayout.makeAttributed(
          text: quoteContentText,
          font: fonts.quoteContent,
          color: .secondaryLabel,
          lineHeight: lineHeights.quoteContent
        )
        quoteContentAttributed = content
        let contentHeight = TiebaRowText.measureHeight(
          content,
          width: geometry.textColumnWidth - TiebaFeedRowLayout.quotePadding * 2,
          maxLines: 2
        )
        quoteContentLineHeight = contentHeight
        stacked += contentHeight
        lineCount += 1
      }
      quoteHeight = stacked + TiebaFeedRowLayout.quoteGap * CGFloat(max(lineCount - 1, 0))
    }

    // ── 吧名徽章 ──
    // 吧名/吧头像逐键兜底（search.ts 与 feed.ts 的 backfillForumAvatars）：
    // 只读 raw["forumName"] 会让「服务端把名字放 forum_name/forumInfo」或
    // 「只下发 forumId」的行整块徽章消失（搜索结果/动态等页实测）。
    let fallback = TiebaFeedRowFallback.resolve(raw)
    let forumName = fallback.name
    let showsForumChip = TiebaRowDict.bool(raw["showForumPill"]) == true && !forumName.isEmpty
    let chipText = forumName.isEmpty ? "" : "\(forumName)吧"
    let chipTextWidth = TiebaRowText.singleLineWidth(chipText, font: fonts.chipText)
    let chipHeight = TiebaFeedRowLayout.chipPadding * 2 + max(TiebaFeedRowLayout.chipAvatarSize, lineHeights.chipText)
    let chipWidth = TiebaFeedRowLayout.chipPadding * 2
      + TiebaFeedRowLayout.chipAvatarSize
      + TiebaFeedRowLayout.chipGap
      + chipTextWidth
      + 4 // chipText 的 marginRight: 4
    let forumAvatarURL = TiebaRowDict.avatarURL(fallback.avatar)
    let forumChipInitial = forumName.replacingOccurrences(of: "吧$", with: "", options: .regularExpression)
      .first.map(String.init) ?? "吧"

    // ── 操作栏 ──
    let showsActions = TiebaRowDict.bool(raw["hideActions"]) != true
    let replyNum = TiebaRowDict.double(raw["replyNum"]) ?? 0
    let shareNum = TiebaRowDict.double(raw["shareNum"]) ?? 0
    let zanNum = TiebaRowDict.double(raw["zanNum"]) ?? 0
    let replyText = TiebaRowDict.nonEmpty(raw["replyText"]) ?? TiebaForumFormat.count(replyNum)
    let shareText = TiebaRowDict.nonEmpty(raw["shareText"])
      ?? (shareNum > 0 ? TiebaForumFormat.count(shareNum) : "分享")
    let likeText = TiebaRowDict.nonEmpty(raw["likeText"])
      ?? (zanNum > 0 ? TiebaForumFormat.count(zanNum) : "赞")
    let isLiked = TiebaRowDict.bool(raw["isLiked"])
      ?? (TiebaRowDict.bool(raw["hasAgree"]) ?? false)

    // ── 交互开关 ──
    // 只认 TweetCard 的三个冻结取值，未知项丢弃（菜单文案与动作在行视图内
    // 映射，非法值不该被静默带进 UI）。
    let menuOptions = (TiebaFeedRowParser.array(raw["closeMenuOptions"]) ?? [])
      .compactMap { TiebaRowDict.string($0) }
      .filter { ["dislike", "block", "copy-title"].contains($0) }
    // 缺 key = 开（只有显式 false 才关）：造行的页面漏传过一次就让整页长按失效
    //（吧页/话题页，2026-09-15），而"少一个菜单"比"多一个菜单"难发现得多。
    let showsImageContextMenu = TiebaRowDict.bool(raw["imageContextMenu"]) != false

    // ── 置顶横幅 ──
    let bannerText: String
    if isTop {
      let base = titleText.isEmpty ? "置顶帖子" : titleText
      bannerText = base.count <= TiebaFeedRowLayout.topTitleMax
        ? base
        : String(base.prefix(TiebaFeedRowLayout.topTitleMax)) + "…"
    } else {
      bannerText = ""
    }

    // ── 高度块（测量一次；plan() 只做算术叠加）──
    let nameRowHeight = lineHeights.subhead
    let ipHeight = fonts.ip.lineHeight
    let headerHeight = max(
      TiebaFeedRowLayout.avatarSize,
      nameRowHeight + (ipText == nil ? 0 : 1 + ipHeight)
    )

    var bodyHeight: CGFloat = 0
    if let titleHeight { bodyHeight += titleHeight }
    if let abstractHeight { bodyHeight += 4 + abstractHeight } // abstract.marginTop: 4
    if let showMoreHeight { bodyHeight += 2 + showMoreHeight } // showMore.marginTop: 2

    let actionHeight: CGFloat? = showsActions
      ? max(TiebaFeedRowLayout.actionRowMinHeight, lineHeights.actionText)
      : nil

    let blocks = TiebaFeedRowBlocks(
      isBanner: isTop,
      showsMenu: !isTop && !menuOptions.isEmpty,
      headerHeight: headerHeight,
      titleHeight: titleHeight,
      abstractHeight: abstractHeight,
      showMoreHeight: showMoreHeight,
      bodyHeight: bodyHeight,
      mediaHeight: mediaHeight,
      mediaIsStrip: mediaIsStrip,
      mediaItemWidths: mediaItemWidths,
      quoteHeight: quoteHeight,
      quoteForumHeight: quoteForumLineHeight,
      quoteTitleHeight: quoteTitleLineHeight,
      quoteContentHeight: quoteContentLineHeight,
      chipHeight: showsForumChip ? chipHeight : nil,
      chipWidth: showsForumChip ? chipWidth : nil,
      actionHeight: actionHeight,
      displayNameWidth: TiebaRowText.singleLineWidth(displayName, font: fonts.displayName),
      handleWidth: handleText.map { TiebaRowText.singleLineWidth($0, font: fonts.handle) },
      timeWidth: timeText.map { TiebaRowText.singleLineWidth($0, font: fonts.time) },
      ipWidth: ipText.map { TiebaRowText.singleLineWidth($0, font: fonts.ip) },
      showMoreWidth: showMoreHeight == nil
        ? nil
        : TiebaRowText.singleLineWidth(showMoreText, font: fonts.showMore),
      replyWidth: TiebaRowText.singleLineWidth(replyText, font: fonts.actionText),
      shareWidth: TiebaRowText.singleLineWidth(shareText, font: fonts.actionText),
      likeWidth: TiebaRowText.singleLineWidth(likeText, font: fonts.actionText),
      bannerHeight: isTop
        ? TiebaFeedRowLayout.bannerPaddingV * 2 + max(
            TiebaFeedRowLayout.bannerIconSize,
            lineHeights.quoteForum + 4,
            lineHeights.bannerText
          )
        : 0,
      bannerBadgeWidth: isTop
        ? TiebaRowText.singleLineWidth("置顶", font: fonts.badge) + 16
        : 0
    )

    // ── 赋值 ──
    self.pageKey = pageKey
    self.index = index
    self.threadId = TiebaRowDict.string(raw["threadId"]) ?? ""
    self.containerWidth = geometry.containerWidth
    self.fontScale = fontScale
    self.avatarURL = avatarURL
    self.avatarInitial = avatarInitial
    self.displayName = displayName
    self.timeText = timeText
    self.ipText = ipText
    self.metaAttributed = metaAttributed
    self.titleText = titleText
    self.titlePrefix = isGood ? "精品 " : nil
    self.abstractText = abstractText
    self.isCollapsible = isCollapsible
    self.showMoreText = showMoreText
    self.expanded = expanded
    self.titleLineLimit = titleLineLimit
    self.abstractLineLimit = abstractLineLimit
    self.media = media
    self.videoPosterURL = poster
    self.singleMediaHeight = singleMediaHeight
    self.stripHeight = stripHeight
    self.mediaIsStrip = mediaIsStrip
    self.showsVideoPoster = !mediaIsStrip && media.isEmpty && poster != nil
    self.showsMedia = showsMedia
    self.quoteForumText = quoteForumText
    self.quoteTitleText = quoteTitleText
    self.quoteContentText = quoteContentText
    self.showsForumChip = showsForumChip
    self.forumName = forumName
    self.forumAvatarURL = forumAvatarURL
    self.forumChipInitial = forumChipInitial
    self.showsActions = showsActions
    self.replyText = replyText
    self.shareText = shareText
    self.likeText = likeText
    self.isLiked = isLiked
    self.likeCount = zanNum
    self.isTopBanner = isTop
    self.bannerText = bannerText
    self.menuOptions = menuOptions
    self.showsImageContextMenu = showsImageContextMenu
    self.geometry = geometry
    self.blocks = blocks
    self.titleAttributed = titleAttributed
    self.abstractAttributed = abstractAttributed
    self.quoteForumAttributed = quoteForumAttributed
    self.quoteTitleAttributed = quoteTitleAttributed
    self.quoteContentAttributed = quoteContentAttributed
    self.bannerAttributed = isTop
      ? TiebaFeedRowLayout.makeAttributed(
          text: bannerText,
          font: fonts.bannerText,
          color: .label,
          lineHeight: lineHeights.bannerText
        )
      : nil
    // 帧计划只算这一次（模型不可变；布局期直接用，不再每次 layoutSubviews 重算）。
    let plan = TiebaFeedRowLayout.plan(blocks: blocks, geometry: geometry)
    self.plan = plan
    self.measuredHeight = plan.rowHeight
  }
}

// MARK: - 测量块

/// 一行的各块高度与单行文本宽度（测量一次；plan() 只用它做算术）。
nonisolated struct TiebaFeedRowBlocks {
  let isBanner: Bool
  /// 右上角 × 菜单钮是否存在（决定名字行可用宽度让位 menuButtonSize + gap，
  /// 与 TweetCard headerRow 里 closeButton 参与 flex 布局同几何）。
  let showsMenu: Bool
  let headerHeight: CGFloat
  let titleHeight: CGFloat?
  let abstractHeight: CGFloat?
  let showMoreHeight: CGFloat?
  let bodyHeight: CGFloat
  let mediaHeight: CGFloat?
  let mediaIsStrip: Bool
  /// 图片带每张图的显示宽（stripHeight × w/h，最多 maxImagesPerRow 张）。
  let mediaItemWidths: [CGFloat]
  let quoteHeight: CGFloat?
  let quoteForumHeight: CGFloat?
  let quoteTitleHeight: CGFloat?
  let quoteContentHeight: CGFloat?
  let chipHeight: CGFloat?
  let chipWidth: CGFloat?
  let actionHeight: CGFloat?
  let displayNameWidth: CGFloat
  let handleWidth: CGFloat?
  let timeWidth: CGFloat?
  let ipWidth: CGFloat?
  let showMoreWidth: CGFloat?
  let replyWidth: CGFloat
  let shareWidth: CGFloat
  let likeWidth: CGFloat
  let bannerHeight: CGFloat
  let bannerBadgeWidth: CGFloat

  var hasBody: Bool { titleHeight != nil || abstractHeight != nil || showMoreHeight != nil }
}

/// 帧计划（卡片坐标 = 行视图坐标；内容坐标仅 mediaItemFrames）。
nonisolated struct TiebaFeedRowLayoutPlan {
  let rowHeight: CGFloat
  let cardFrame: CGRect
  let avatarFrame: CGRect?
  let displayNameFrame: CGRect?
  /// 名字行尾部元信息（@昵称 + 时间）的矩形——一个 label（见 metaAttributed）。
  let metaFrame: CGRect?
  let ipFrame: CGRect?
  let titleFrame: CGRect?
  let abstractFrame: CGRect?
  /// 「显示更多」的**命中**矩形（文本矩形外扩 6pt，等价 TweetCard 的 hitSlop=6；
  /// 命中判定用这个，摆放文本用 showMoreTextFrame）。
  let showMoreFrame: CGRect?
  /// 「显示更多」文本的绘制矩形（无内缩/外扩，行高与命中同源）。
  let showMoreTextFrame: CGRect?
  /// 单图：图片 frame；多图：图片带视口 frame（贴卡片左右边）。
  let mediaFrame: CGRect?
  /// 图片带每张图的 frame（相对 scrollView 内容坐标，含 leadInset）；单图时为空。
  let mediaItemFrames: [CGRect]
  /// 图片带内容宽（含 leadInset 与间距）。
  let mediaContentWidth: CGFloat
  let quoteFrame: CGRect?
  let quoteForumFrame: CGRect?
  let quoteTitleFrame: CGRect?
  let quoteContentFrame: CGRect?
  let chipFrame: CGRect?
  let chipAvatarFrame: CGRect?
  let chipTextFrame: CGRect?
  let actionRowFrame: CGRect?
  let actionButtonFrames: [CGRect]
  let actionIconFrames: [CGRect]
  let actionLabelFrames: [CGRect]
  /// 右上角 26×26 菜单钮（TweetCard styles.closeButton）；无菜单行为 nil。
  let menuButtonFrame: CGRect?
  // 置顶横幅
  let bannerIconFrame: CGRect?
  let bannerBadgeFrame: CGRect?
  let bannerTextFrame: CGRect?
}

// MARK: - 共享布局（测量与绘制的单一几何来源）

/// 与 TweetCard.tsx / MediaPager.tsx 常量逐一对齐；测量与绘制都必须经这里取
/// 几何，禁止在行视图里另算一套（文本列宽不一致是"截断/超高"类 bug 的根源）。
nonisolated enum TiebaFeedRowLayout {
  // TweetCard.tsx 常量
  static let cardMarginH: CGFloat = 10
  static let cardMarginV: CGFloat = 4
  static let cardPaddingX: CGFloat = 12
  static let cardPaddingTop: CGFloat = 12
  static let cardPaddingBottom: CGFloat = 8
  static let avatarSize: CGFloat = 44
  static let avatarGap: CGFloat = 10
  static let contentIndent: CGFloat = avatarSize + avatarGap // 54
  static let contentColumnGap: CGFloat = 6
  static let contentColumnTopOffset: CGFloat = -6
  static let collapseLines = 6
  static let longTextWeightedChars: CGFloat = 120
  static let topTitleMax = 28
  static let actionRowMinHeight: CGFloat = 32
  static let actionIconSize: CGFloat = 17
  static let actionIconGap: CGFloat = 6
  static let quotePadding: CGFloat = 10
  static let quoteGap: CGFloat = 3
  static let chipPadding: CGFloat = 4
  static let chipAvatarSize: CGFloat = 20
  static let chipGap: CGFloat = 8
  static let headerTextGap: CGFloat = 4
  /// 右上角菜单钮（TweetCard styles.closeButton width/height 26）。
  static let menuButtonSize: CGFloat = 26
  static let bannerPaddingH: CGFloat = 16
  static let bannerPaddingV: CGFloat = 11
  static let bannerIconSize: CGFloat = 15
  static let bannerGap: CGFloat = 8
  // MediaPager.tsx 常量
  static let mediaHeightMax: CGFloat = 520
  static let mediaFallbackHeight: CGFloat = 260
  static let stripHeightMin: CGFloat = 160
  static let stripHeightMax: CGFloat = 340
  static let stripGap: CGFloat = 4
  static let longImageRatio: CGFloat = 2.4
  static let maxImagesPerRow = 9

  /// Dynamic Type 字体组（UIFontMetrics 跟随系统内容尺寸档；fontScale 为
  /// 应用内阅读字号倍率，RN 侧以 fontSize×fontScale 消费）。
  struct Fonts {
    let displayName: UIFont
    let handle: UIFont
    let time: UIFont
    let ip: UIFont
    let title: UIFont
    let abstract: UIFont
    let showMore: UIFont
    let quoteForum: UIFont
    let quoteTitle: UIFont
    let quoteContent: UIFont
    let chipText: UIFont
    let actionText: UIFont
    let bannerText: UIFont
    let badge: UIFont

    init(fontScale: CGFloat) {
      displayName = Self.scaled(size: 15, weight: .semibold, style: .subheadline, scale: fontScale)
      handle = Self.scaled(size: 15, weight: .regular, style: .subheadline, scale: fontScale)
      time = Self.scaled(size: 15, weight: .regular, style: .subheadline, scale: fontScale)
      ip = Self.scaled(size: 11, weight: .regular, style: .caption2, scale: fontScale)
      title = Self.scaled(size: 17, weight: .medium, style: .headline, scale: fontScale)
      abstract = Self.scaled(size: 15, weight: .regular, style: .subheadline, scale: fontScale)
      showMore = Self.scaled(size: 15, weight: .semibold, style: .subheadline, scale: fontScale)
      quoteForum = Self.scaled(size: 12, weight: .semibold, style: .caption1, scale: fontScale)
      quoteTitle = Self.scaled(size: 13, weight: .semibold, style: .footnote, scale: fontScale)
      quoteContent = Self.scaled(size: 13, weight: .regular, style: .footnote, scale: fontScale)
      chipText = Self.scaled(size: 12, weight: .regular, style: .caption1, scale: fontScale)
      actionText = Self.scaled(size: 13, weight: .medium, style: .footnote, scale: fontScale)
      bannerText = Self.scaled(size: 13, weight: .medium, style: .footnote, scale: fontScale)
      badge = Self.scaled(size: 12, weight: .semibold, style: .caption1, scale: fontScale)
    }

    private static func scaled(
      size: CGFloat,
      weight: UIFont.Weight,
      style: UIFont.TextStyle,
      scale: CGFloat
    ) -> UIFont {
      let base = UIFont.systemFont(ofSize: size * max(scale, 0.1), weight: weight)
      return UIFontMetrics(forTextStyle: style).scaledFont(for: base)
    }
  }

  /// 与 typographyStyles 的显式 lineHeight 对齐（×fontScale 后过 UIFontMetrics）。
  struct LineHeights {
    let subhead: CGFloat
    let title: CGFloat
    let abstract: CGFloat
    let quoteForum: CGFloat
    let quoteTitle: CGFloat
    let quoteContent: CGFloat
    let chipText: CGFloat
    let actionText: CGFloat
    let bannerText: CGFloat

    init(fontScale: CGFloat) {
      subhead = Self.scaled(20, style: .subheadline, scale: fontScale)
      title = Self.scaled(22, style: .headline, scale: fontScale)
      abstract = Self.scaled(22, style: .subheadline, scale: fontScale)
      quoteForum = Self.scaled(16, style: .caption1, scale: fontScale)
      quoteTitle = Self.scaled(18, style: .footnote, scale: fontScale)
      quoteContent = Self.scaled(18, style: .footnote, scale: fontScale)
      chipText = Self.scaled(16, style: .caption1, scale: fontScale)
      actionText = Self.scaled(18, style: .footnote, scale: fontScale)
      bannerText = Self.scaled(18, style: .footnote, scale: fontScale)
    }

    private static func scaled(_ height: CGFloat, style: UIFont.TextStyle, scale: CGFloat) -> CGFloat {
      ceil(UIFontMetrics(forTextStyle: style).scaledValue(for: height * max(scale, 0.1)))
    }
  }

  /// 一行绘制所需的全部几何。测量与绘制各自调用一次，结果必须完全一致
  ///（同一容器宽度 + 同一 fontScale → 纯函数）。
  struct Geometry {
    let containerWidth: CGFloat
    let cardWidth: CGFloat
    /// 卡片内容区宽（cardWidth - 左右 padding）。
    let contentWidth: CGFloat
    /// 文本列宽 W_c（= 内容区宽 - 头像缩进）：标题/摘要/引用/单图/图片带宽的单一来源。
    let textColumnWidth: CGFloat
    /// 图片带视口宽（= 卡片盒宽，贴卡片左右边）。
    let stripViewportWidth: CGFloat
    /// 图片带内容左内边距（首图对齐文本列）。
    let stripLeadInset: CGFloat
    let fontScale: CGFloat
    let fonts: Fonts
    let lineHeights: LineHeights
  }

  static func geometry(containerWidth: CGFloat, fontScale: CGFloat) -> Geometry {
    let width = max(containerWidth, 0)
    let cardWidth = max(width - cardMarginH * 2, 0)
    let contentWidth = max(cardWidth - cardPaddingX * 2, 0)
    let textColumnWidth = max(contentWidth - contentIndent, 0)
    return Geometry(
      containerWidth: width,
      cardWidth: cardWidth,
      contentWidth: contentWidth,
      textColumnWidth: textColumnWidth,
      stripViewportWidth: cardWidth,
      stripLeadInset: cardPaddingX + contentIndent,
      fontScale: fontScale,
      fonts: Fonts(fontScale: fontScale),
      lineHeights: LineHeights(fontScale: fontScale)
    )
  }

  /// 文本可用宽度（唯一的宽度换算入口）。
  static func textColumnWidth(containerWidth: CGFloat) -> CGFloat {
    max(max(containerWidth - cardMarginH * 2, 0) - cardPaddingX * 2 - contentIndent, 0)
  }

  /// 单图高度：round(clamp(W_c × h/w, 1, 520))（MediaPager heightOf）。
  static func singleMediaHeight(for media: TiebaFeedRowMedia, columnWidth: CGFloat) -> CGFloat {
    let ratio = media.height > 0 && media.width > 0 ? CGFloat(media.height / media.width) : 1
    let width = columnWidth > 0 ? columnWidth : 300
    return (min(max(width * max(ratio, 0.01), 1), mediaHeightMax)).rounded()
  }

  /// 多图带行高：round(clamp(min(W_c / rᵢ), 160, 340))（MultiImageStrip）。
  static func stripHeight(for media: [TiebaFeedRowMedia], columnWidth: CGFloat) -> CGFloat {
    let width = columnWidth > 0 ? columnWidth : 300
    let natural = media.map { width / max($0.aspectRatio, 0.01) }
    let base = natural.min() ?? mediaFallbackHeight
    return min(max(base, stripHeightMin), stripHeightMax).rounded()
  }

  /// 单行文本宽度（仅用于排版定位；不改行高）。
  static func makeAttributed(
    text: String,
    font: UIFont,
    color: UIColor,
    lineHeight: CGFloat
  ) -> NSAttributedString {
    let paragraph = NSMutableParagraphStyle()
    paragraph.minimumLineHeight = lineHeight
    paragraph.maximumLineHeight = lineHeight
    paragraph.lineBreakMode = .byTruncatingTail
    return NSAttributedString(
      string: text,
      attributes: [
        .font: font,
        .foregroundColor: color,
        .paragraphStyle: paragraph,
      ]
    )
  }

  /// 帧计划（纯算术）。测量期用它算总高，绘制期用它摆子视图 —— 同一函数，
  /// 保证"测多少、画多少"。
  static func plan(blocks: TiebaFeedRowBlocks, geometry: Geometry) -> TiebaFeedRowLayoutPlan {
    let cardX = cardMarginH
    let cardY = cardMarginV
    let innerX = cardX + cardPaddingX
    let contentX = innerX + contentIndent
    let contentW = geometry.textColumnWidth
    let cardW = geometry.cardWidth

    if blocks.isBanner {
      let height = blocks.bannerHeight
      // TopBanner.marginVertical = 2（与卡片行不同，勿共用 cardMarginV）。
      let frame = CGRect(x: 0, y: 2, width: geometry.containerWidth, height: height)
      let midY = frame.midY
      let iconX = bannerPaddingH
      let iconFrame = CGRect(
        x: iconX,
        y: midY - bannerIconSize / 2,
        width: bannerIconSize,
        height: bannerIconSize
      )
      let badgeWidth = blocks.bannerBadgeWidth
      let badgeHeight = geometry.lineHeights.quoteForum + 4
      let badgeFrame = CGRect(
        x: iconFrame.maxX + bannerGap,
        y: midY - badgeHeight / 2,
        width: badgeWidth,
        height: badgeHeight
      )
      let textX = badgeFrame.maxX + bannerGap
      let textFrame = CGRect(
        x: textX,
        y: frame.minY,
        width: max(frame.maxX - bannerPaddingH - textX, 0),
        height: height
      )
      return TiebaFeedRowLayoutPlan(
        rowHeight: height + 4,
        cardFrame: frame,
        avatarFrame: nil,
        displayNameFrame: nil,
        metaFrame: nil,
        ipFrame: nil,
        titleFrame: nil,
        abstractFrame: nil,
        showMoreFrame: nil,
        showMoreTextFrame: nil,
        mediaFrame: nil,
        mediaItemFrames: [],
        mediaContentWidth: 0,
        quoteFrame: nil,
        quoteForumFrame: nil,
        quoteTitleFrame: nil,
        quoteContentFrame: nil,
        chipFrame: nil,
        chipAvatarFrame: nil,
        chipTextFrame: nil,
        actionRowFrame: nil,
        actionButtonFrames: [],
        actionIconFrames: [],
        actionLabelFrames: [],
        menuButtonFrame: nil,
        bannerIconFrame: iconFrame,
        bannerBadgeFrame: badgeFrame,
        bannerTextFrame: textFrame
      )
    }

    // ── 头部 ──
    let headerTop = cardY + cardPaddingTop
    let avatarFrame = CGRect(x: innerX, y: headerTop, width: avatarSize, height: avatarSize)
    let nameContentHeight = geometry.lineHeights.subhead
      + (blocks.ipWidth == nil ? 0 : 1 + geometry.fonts.ip.lineHeight)
    let nameTop = headerTop + max((blocks.headerHeight - nameContentHeight) / 2, 0)
    let nameRowHeight = geometry.lineHeights.subhead
    // 右上角 × 在 headerRow 里参与 flex 布局（TweetCard closeButton 26pt +
    // headerRow gap 10），名字行可用宽度必须让位，否则长名会压到按钮下面。
    let menuButtonFrame: CGRect? = blocks.showsMenu
      ? CGRect(
          x: innerX + geometry.contentWidth - menuButtonSize,
          y: headerTop,
          width: menuButtonSize,
          height: menuButtonSize
        )
      : nil
    let availableNameWidth = max(
      contentW - (blocks.showsMenu ? menuButtonSize + headerTextGap : 0),
      0
    )

    let displayNameWidth = min(blocks.displayNameWidth, availableNameWidth)
    let displayNameFrame = CGRect(x: contentX, y: nameTop, width: displayNameWidth, height: nameRowHeight)
    // 名字行的硬右界 = contentX + availableNameWidth（让位 × 钮后与 RN 的
    // nameCol 宽一致）；handle/time 依次排在 displayName 之后、超宽即截断。
    let nameRowRight = contentX + availableNameWidth
    var nameCursor = displayNameFrame.maxX
    // 元信息（@昵称 + 时间）是**一个** label：宽度 = 两段自然宽 + 段间 4pt（段间空隙
    // 由模型侧烘进 kern，见 metaAttributed）。只有一段时不含段间空隙。
    var metaFrame: CGRect?
    let handleWidth = blocks.handleWidth ?? 0
    let timeWidth = blocks.timeWidth ?? 0
    if blocks.handleWidth != nil || blocks.timeWidth != nil {
      let x = nameCursor + headerTextGap
      let gapBetween = (blocks.handleWidth != nil && blocks.timeWidth != nil) ? headerTextGap : 0
      let width = max(min(handleWidth + gapBetween + timeWidth, nameRowRight - x), 0)
      metaFrame = CGRect(x: x, y: nameTop, width: width, height: nameRowHeight)
      nameCursor = x + width
    }
    var ipFrame: CGRect?
    if blocks.ipWidth != nil {
      ipFrame = CGRect(
        x: contentX,
        y: nameTop + nameRowHeight + 1,
        width: contentW,
        height: geometry.fonts.ip.lineHeight
      )
    }

    // ── 内容列（顺序与 TweetCard contentCol 子节点一致：正文 → 媒体 → 引用 → chip → 操作栏）──
    var cursor = headerTop + blocks.headerHeight + contentColumnTopOffset
    var placedAny = false
    func nextChildY() -> CGFloat {
      if placedAny { cursor += contentColumnGap }
      placedAny = true
      return cursor
    }

    var titleFrame: CGRect?
    var abstractFrame: CGRect?
    var showMoreFrame: CGRect?
    var showMoreTextFrame: CGRect?
    if blocks.hasBody {
      var bodyY = nextChildY()
      if let titleHeight = blocks.titleHeight {
        titleFrame = CGRect(x: contentX, y: bodyY, width: contentW, height: titleHeight)
        bodyY += titleHeight
      }
      if let abstractHeight = blocks.abstractHeight {
        abstractFrame = CGRect(x: contentX, y: bodyY + 4, width: contentW, height: abstractHeight)
        bodyY += 4 + abstractHeight
      }
      if let showMoreHeight = blocks.showMoreHeight {
        let width = min(blocks.showMoreWidth ?? contentW, contentW)
        // 文本矩形 + 命中外扩（RN showMore 的 hitSlop=6）：命中框不得越出文本
        // 上下相邻块（上为摘要、下为 chip/操作栏，两侧各 6pt 的既有间距），
        // 故外扩 6 后按卡片左右界裁剪。
        let textFrame = CGRect(x: contentX, y: bodyY + 2, width: width, height: showMoreHeight)
        showMoreTextFrame = textFrame
        let slop: CGFloat = 6
        let clip = CGRect(
          x: innerX, y: textFrame.minY - slop,
          width: geometry.contentWidth, height: textFrame.height + slop * 2
        )
        showMoreFrame = textFrame.insetBy(dx: -slop, dy: -slop).intersection(clip)
        bodyY += 2 + showMoreHeight
      }
      cursor += blocks.bodyHeight
    }

    var mediaFrame: CGRect?
    var mediaItemFrames: [CGRect] = []
    var mediaContentWidth: CGFloat = 0
    if let mediaHeight = blocks.mediaHeight {
      let y = nextChildY()
      if blocks.mediaIsStrip {
        // 多图带：视口贴卡片左右边（可滑入头像列空白区，卡片 overflow 裁切）；
        // 内容左内边距 = leadInset，首图与文本列左界对齐。
        mediaFrame = CGRect(x: cardX, y: y, width: cardW, height: mediaHeight)
        var x = geometry.stripLeadInset
        for itemWidth in blocks.mediaItemWidths {
          mediaItemFrames.append(CGRect(x: x, y: 0, width: itemWidth, height: mediaHeight))
          x += itemWidth + stripGap
        }
        mediaContentWidth = mediaItemFrames.isEmpty
          ? 0
          : x - stripGap // 末图后无间距
      } else {
        // 单图 / 视频 poster：贴文本列，绘制侧给圆角。
        mediaFrame = CGRect(x: contentX, y: y, width: contentW, height: mediaHeight)
      }
      cursor += mediaHeight
    }

    var quoteFrame: CGRect?
    var quoteForumFrame: CGRect?
    var quoteTitleFrame: CGRect?
    var quoteContentFrame: CGRect?
    if let quoteHeight = blocks.quoteHeight {
      let y = nextChildY()
      quoteFrame = CGRect(x: contentX, y: y, width: contentW, height: quoteHeight)
      let innerWidth = max(contentW - quotePadding * 2, 0)
      var lineY = y + quotePadding
      if blocks.quoteForumHeight != nil {
        quoteForumFrame = CGRect(
          x: contentX + quotePadding,
          y: lineY,
          width: innerWidth,
          height: geometry.lineHeights.quoteForum
        )
        lineY += geometry.lineHeights.quoteForum + quoteGap
      }
      if blocks.quoteTitleHeight != nil {
        quoteTitleFrame = CGRect(
          x: contentX + quotePadding,
          y: lineY,
          width: innerWidth,
          height: geometry.lineHeights.quoteTitle
        )
        lineY += geometry.lineHeights.quoteTitle + quoteGap
      }
      if let contentHeight = blocks.quoteContentHeight {
        quoteContentFrame = CGRect(
          x: contentX + quotePadding,
          y: lineY,
          width: innerWidth,
          height: contentHeight
        )
      }
      cursor += quoteHeight
    }

    var chipFrame: CGRect?
    var chipAvatarFrame: CGRect?
    var chipTextFrame: CGRect?
    if let chipHeight = blocks.chipHeight, let chipWidth = blocks.chipWidth {
      let y = nextChildY()
      chipFrame = CGRect(x: contentX, y: y, width: chipWidth, height: chipHeight)
      let avatarY = y + (chipHeight - chipAvatarSize) / 2
      chipAvatarFrame = CGRect(x: contentX + chipPadding, y: avatarY, width: chipAvatarSize, height: chipAvatarSize)
      chipTextFrame = CGRect(
        x: chipAvatarFrame!.maxX + chipGap,
        y: y + (chipHeight - geometry.lineHeights.chipText) / 2,
        width: max(chipWidth - chipPadding * 2 - chipAvatarSize - chipGap - 4, 0) + 4,
        height: geometry.lineHeights.chipText
      )
      cursor += chipHeight
    }

    var actionRowFrame: CGRect?
    var actionButtonFrames: [CGRect] = []
    var actionIconFrames: [CGRect] = []
    var actionLabelFrames: [CGRect] = []
    if let actionHeight = blocks.actionHeight {
      let y = nextChildY() + 2 // actionRow.marginTop: 2（叠加 contentCol gap）
      actionRowFrame = CGRect(x: contentX, y: y, width: contentW, height: actionHeight)
      let buttonWidth = contentW / 3
      let textWidths = [blocks.replyWidth, blocks.shareWidth, blocks.likeWidth]
      for i in 0..<3 {
        let button = CGRect(
          x: contentX + buttonWidth * CGFloat(i),
          y: y,
          width: buttonWidth,
          height: actionHeight
        )
        actionButtonFrames.append(button)
        let pairWidth = actionIconSize + actionIconGap + textWidths[i]
        let startX = button.minX + (button.width - pairWidth) / 2
        actionIconFrames.append(CGRect(
          x: startX,
          y: button.midY - actionIconSize / 2,
          width: actionIconSize,
          height: actionIconSize
        ))
        actionLabelFrames.append(CGRect(
          x: startX + actionIconSize + actionIconGap,
          y: button.minY,
          width: textWidths[i],
          height: actionHeight
        ))
      }
      cursor += actionHeight + 2
    }

    let cardHeight = cursor + cardPaddingBottom - cardY
    return TiebaFeedRowLayoutPlan(
      rowHeight: cardHeight + cardMarginV * 2,
      cardFrame: CGRect(x: cardX, y: cardY, width: cardW, height: cardHeight),
      avatarFrame: avatarFrame,
      displayNameFrame: displayNameFrame,
      metaFrame: metaFrame,
      ipFrame: ipFrame,
      titleFrame: titleFrame,
      abstractFrame: abstractFrame,
      showMoreFrame: showMoreFrame,
      showMoreTextFrame: showMoreTextFrame,
      mediaFrame: mediaFrame,
      mediaItemFrames: mediaItemFrames,
      mediaContentWidth: mediaContentWidth,
      quoteFrame: quoteFrame,
      quoteForumFrame: quoteForumFrame,
      quoteTitleFrame: quoteTitleFrame,
      quoteContentFrame: quoteContentFrame,
      chipFrame: chipFrame,
      chipAvatarFrame: chipAvatarFrame,
      chipTextFrame: chipTextFrame,
      actionRowFrame: actionRowFrame,
      actionButtonFrames: actionButtonFrames,
      actionIconFrames: actionIconFrames,
      actionLabelFrames: actionLabelFrames,
      menuButtonFrame: menuButtonFrame,
      bannerIconFrame: nil,
      bannerBadgeFrame: nil,
      bannerTextFrame: nil
    )
  }
}

// MARK: - 行内配色（JS 主题下发）

/// JS 颜色串（'#RRGGBB' / '#RRGGBBAA' / 'rgb()' / 'rgba()'，即 colors.ts 的
/// 全部字面形态）→ UIColor。解析失败返回 nil（调用方保留既有默认值）。
public nonisolated func tiebaColor(from raw: String) -> UIColor? {
  let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  if value.hasPrefix("#") {
    var hex = String(value.dropFirst())
    if hex.count == 3 {
      hex = hex.map { "\($0)\($0)" }.joined()
    }
    guard hex.count == 6 || hex.count == 8, let number = UInt64(hex, radix: 16) else {
      return nil
    }
    let hasAlpha = hex.count == 8
    let r = CGFloat((number >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
    let g = CGFloat((number >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
    let b = CGFloat((number >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
    let a = hasAlpha ? CGFloat(number & 0xFF) / 255 : 1
    return UIColor(red: r, green: g, blue: b, alpha: a)
  }
  guard value.hasPrefix("rgb") else { return nil }
  guard let open = value.firstIndex(of: "("), let close = value.lastIndex(of: ")") else {
    return nil
  }
  let parts = value[value.index(after: open)..<close]
    .split(separator: ",")
    .map { $0.trimmingCharacters(in: .whitespaces) }
  guard parts.count == 3 || parts.count == 4 else { return nil }
  func channel(_ text: String) -> CGFloat? {
    guard let number = Double(text) else { return nil }
    return CGFloat(min(max(number, 0), 255)) / 255
  }
  guard let r = channel(parts[0]), let g = channel(parts[1]), let b = channel(parts[2]) else {
    return nil
  }
  let a = parts.count == 4 ? CGFloat(Double(parts[3]) ?? 1) : 1
  return UIColor(red: r, green: g, blue: b, alpha: min(max(a, 0), 1))
}

/// 行视图的语义色。默认值 = 应用默认亮/暗语义色板（与 TiebaFeedRowView 原
/// 静态常量逐一相同，跟随系统外观）；JS 经 TiebaListView 的 themeColors prop
/// 下发实际主题（colors.ts 的 SemanticColors 子集），非默认主题的主色派生
/// token（primary/chip/onChip）由此真正生效——此前行内恒用默认蓝色。
public nonisolated struct TiebaFeedRowPalette: @unchecked Sendable, Equatable {
  public var card: UIColor
  public var borderCard: UIColor
  public var text: UIColor
  public var textSecondary: UIColor
  public var textTertiary: UIColor
  public var primary: UIColor
  public var chip: UIColor
  public var onChip: UIColor
  public var separator: UIColor
  public var liked: UIColor
  public var warning: UIColor
  public var placeholder: UIColor
  public var avatarFallback: UIColor
  /// 应用是否深色（媒体占位底色等由它派生，对齐 MediaPager 的 isDark 分支）。
  public var isNight: Bool

  public static let `default` = TiebaFeedRowPalette(
    card: Self.adaptive(light: 0xFFFFFF, dark: 0x1C1C1E),
    borderCard: UIColor { traits in
      traits.userInterfaceStyle == .dark
        ? UIColor.white.withAlphaComponent(0.08)
        : UIColor.black.withAlphaComponent(0.06)
    },
    text: .label,
    textSecondary: .secondaryLabel,
    textTertiary: .tertiaryLabel,
    primary: Self.adaptive(light: 0x2563EB, dark: 0x60A5FA),
    // 吧名徽章走 UIKit 原生语义填充：强调色留给可点控件，徽章用
    // secondarySystemFill + secondaryLabel（浅深色自适应，不与主色抢眼）。
    chip: .secondarySystemFill,
    onChip: .secondaryLabel,
    separator: .separator,
    liked: Self.adaptive(light: 0xFF2D55, dark: 0xFF375F),
    warning: .systemOrange,
    placeholder: UIColor { traits in
      traits.userInterfaceStyle == .dark
        ? UIColor.white.withAlphaComponent(0.06)
        : UIColor.black.withAlphaComponent(0.04)
    },
    avatarFallback: .secondarySystemBackground,
    isNight: false
  )

  /// JS 主题字典 → 调色板；缺失/解析失败的键保留默认值（旧 JS 不下发时
  /// 行为与迁移前完全一致）。
  public init(dict: [String: Any]) {
    var palette = TiebaFeedRowPalette.default
    func apply(_ key: String, _ assign: (UIColor) -> Void) {
      guard let raw = dict[key] as? String, let color = tiebaColor(from: raw) else { return }
      assign(color)
    }
    apply("card") { palette.card = $0 }
    apply("borderCard") { palette.borderCard = $0 }
    apply("text") { palette.text = $0 }
    apply("textSecondary") { palette.textSecondary = $0 }
    apply("textTertiary") { palette.textTertiary = $0 }
    apply("primary") { palette.primary = $0 }
    apply("chip") { palette.chip = $0 }
    apply("onChip") { palette.onChip = $0 }
    apply("separator") { palette.separator = $0 }
    apply("liked") { palette.liked = $0 }
    apply("warning") { palette.warning = $0 }
    apply("avatarFallback") { palette.avatarFallback = $0 }
    if let isNight = dict["isNight"] as? Bool {
      palette.isNight = isNight
    }
    palette.placeholder = palette.isNight
      ? UIColor.white.withAlphaComponent(0.06)
      : UIColor.black.withAlphaComponent(0.04)
    self = palette
  }

  private init(
    card: UIColor,
    borderCard: UIColor,
    text: UIColor,
    textSecondary: UIColor,
    textTertiary: UIColor,
    primary: UIColor,
    chip: UIColor,
    onChip: UIColor,
    separator: UIColor,
    liked: UIColor,
    warning: UIColor,
    placeholder: UIColor,
    avatarFallback: UIColor,
    isNight: Bool
  ) {
    self.card = card
    self.borderCard = borderCard
    self.text = text
    self.textSecondary = textSecondary
    self.textTertiary = textTertiary
    self.primary = primary
    self.chip = chip
    self.onChip = onChip
    self.separator = separator
    self.liked = liked
    self.warning = warning
    self.placeholder = placeholder
    self.avatarFallback = avatarFallback
    self.isNight = isNight
  }

  private static func adaptive(light: UInt32, dark: UInt32) -> UIColor {
    UIColor { traits in
      traits.userInterfaceStyle == .dark ? color(dark) : color(light)
    }
  }

  private static func color(_ hex: UInt32) -> UIColor {
    UIColor(
      red: CGFloat((hex >> 16) & 0xFF) / 255,
      green: CGFloat((hex >> 8) & 0xFF) / 255,
      blue: CGFloat(hex & 0xFF) / 255,
      alpha: 1
    )
  }
}

// MARK: - 页面级缓存

public nonisolated final class TiebaRowMetrics: @unchecked Sendable {
  public static let shared = TiebaRowMetrics()

  /// 缓存键 =（pageKey, 0.5pt 量化宽度）：宽度是键的一部分，同屏不同宽度的
  /// 列表互不清页（无全局宽度闸门）。
  private struct PageKey: Hashable {
    let pageKey: String
    let width: CGFloat
  }

  private struct Page {
    let rows: [TiebaFeedRowModel]
    /// 与 rows 同下标的原始行字典：下一次 prepare 的逐行复用判据。
    let raws: [[String: Any]]
  }

  /// 整页缓存（LRU + 在显页跳过）：四族度量缓存共用 TiebaPageStore。
  private let pages = TiebaPageStore<PageKey, Page>(pinKey: { $0.pageKey })

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
  private func invalidateAll() {
    pages.removeAll()
  }

  // MARK: - 公共契约

  /// 同步测量整页：调用线程完成解析 + TextKit 测量并发布，返回即可查模型。
  /// 调用线程 = 列表页的后台队列（不得在主线程调用：整页 TextKit 测量）。
  public func prepareFeedRowsBlocking(pageKey: String, rows: [[String: Any]], containerWidth: CGFloat) {
    guard !pageKey.isEmpty, !rows.isEmpty, containerWidth > 0 else { return }
    let width = TiebaLayout.quantize(containerWidth)
    // 旧页快照（同页同宽才命中）作逐行复用判据；锁内只取引用，O(1)。
    let previous = pages.value(forKey: PageKey(pageKey: pageKey, width: width))
    publish(
      pageKey: pageKey,
      width: width,
      rows: Self.measureRows(pageKey: pageKey, rows: rows, width: width, previous: previous),
      raws: rows
    )
  }

  /// 页内行数（按显式宽度取页；未测量/未知 → 0）。
  public func feedRowCount(pageKey: String, containerWidth: CGFloat) -> Int {
    let width = TiebaLayout.quantize(containerWidth)
    return pages.value(forKey: PageKey(pageKey: pageKey, width: width))?.rows.count ?? 0
  }

  /// 页内行数（该页最新一次 prepare 的宽度条目）。
  public func feedRowCount(pageKey: String) -> Int {
    newestPage(pageKey: pageKey)?.rows.count ?? 0
  }

  /// 取行模型（与测量时同一实例；越界/未知 → nil）。高度/模型查询必须显式传
  /// 宽度：拿错宽度条目会按旧帧计划绘制（与 TiebaKindListView 的高度闸门同判据）。
  public func feedRow(pageKey: String, containerWidth: CGFloat, index: Int) -> TiebaFeedRowModel? {
    let width = TiebaLayout.quantize(containerWidth)
    guard let page = pages.value(forKey: PageKey(pageKey: pageKey, width: width)),
          page.rows.indices.contains(index) else { return nil }
    return page.rows[index]
  }

  /// 行视图查询（Fabric 只给 (pageKey, index) 两个 prop，不下发行宽）：取该页
  /// 最新一次 prepare 的宽度条目。列表侧高度/预取查询走显式宽度重载。
  public func feedRow(pageKey: String, index: Int) -> TiebaFeedRowModel? {
    guard let page = newestPage(pageKey: pageKey),
          page.rows.indices.contains(index) else { return nil }
    return page.rows[index]
  }

  // MARK: - 内部

  /// 该 pageKey 最新一次发布（order 最大）的页；无 → nil。
  /// 行视图只拿得到 (pageKey, index)，不知道宽度，所以按 pageKey 找最新。
  private func newestPage(pageKey: String) -> Page? {
    pages.newest { $0.pageKey == pageKey }
  }

  /// 整页解析 + TextKit 测量：行字典与上次完全相同的行直接复用旧模型（点赞/
  /// 展开重推整页时只有被点的行需要重测富文本与 TextKit）。
  private static func measureRows(
    pageKey: String,
    rows: [[String: Any]],
    width: CGFloat,
    previous: Page?
  ) -> [TiebaFeedRowModel] {
    var measured: [TiebaFeedRowModel] = []
    measured.reserveCapacity(rows.count)
    for (index, raw) in rows.enumerated() {
      if let previous,
         previous.rows.indices.contains(index),
         previous.raws.indices.contains(index),
         Self.isSameRaw(previous.raws[index], raw) {
        measured.append(previous.rows[index])
        continue
      }
      measured.append(
        TiebaFeedRowModel(pageKey: pageKey, index: index, raw: raw, containerWidth: width)
      )
    }
    return measured
  }

  /// 行字典深比较（NSDictionary.isEqual 递归比较嵌套字典/数组/数值）。
  private static func isSameRaw(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
    (lhs as NSDictionary).isEqual(rhs as NSDictionary)
  }

  private func publish(
    pageKey: String,
    width: CGFloat,
    rows: [TiebaFeedRowModel],
    raws: [[String: Any]]
  ) {
    pages.publish(Page(rows: rows, raws: raws), forKey: PageKey(pageKey: pageKey, width: width))
  }
}

// MARK: - 行级共享工具（TextKit 测量 / 字典取值，全仓唯一实现）

/// 行文本测量：TextKit 单次测量 + 单行宽度。TiebaFeedRowLayout / TiebaSimpleText
/// 的同类实现都收敛到这里（此前两处逐字重复；改一处不再漏另一处）。
nonisolated enum TiebaRowText {
  /// 调用方保证在测量队列上；maxLines = 0 表示不限行数（NSTextContainer 语义）。
  static func measureHeight(_ attributed: NSAttributedString, width: CGFloat, maxLines: Int) -> CGFloat {
    measure(attributed, width: width, maxLines: maxLines).height
  }

  /// 高度 + 是否真被 maxLines 截断（同一趟布局里判：截断时可见字形范围盖不到
  /// 末字形）。折叠判据必须用"真截断"，不能只比字数。
  static func measure(
    _ attributed: NSAttributedString,
    width: CGFloat,
    maxLines: Int
  ) -> (height: CGFloat, truncated: Bool) {
    guard attributed.length > 0, width > 0 else { return (0, false) }
    let storage = NSTextStorage(attributedString: attributed)
    let layoutManager = NSLayoutManager()
    let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
    container.lineFragmentPadding = 0
    container.maximumNumberOfLines = maxLines
    container.lineBreakMode = .byTruncatingTail
    storage.addLayoutManager(layoutManager)
    layoutManager.addTextContainer(container)
    layoutManager.ensureLayout(for: container)
    let visible = layoutManager.glyphRange(for: container)
    // ceil：避免 22.0001 → 22 后 UILabel 最后一行被裁掉半像素。
    let height = ceil(layoutManager.usedRect(for: container).height)
    let truncated = maxLines > 0 && visible.upperBound < layoutManager.numberOfGlyphs
    return (height, truncated)
  }

  /// 单行文本宽（徽章内联定位用；不改行高）。
  static func singleLineWidth(_ text: String, font: UIFont) -> CGFloat {
    guard !text.isEmpty else { return 0 }
    return ceil((text as NSString).size(withAttributes: [.font: font]).width)
  }
}

/// 行字典取值（JS 桥字典的宽容读取 + 头像/URL 规整）：TiebaFeedRowParser 与
/// TiebaSimpleRowParser 都转发到这里，规则只有这一份。
nonisolated enum TiebaRowDict {
  static func string(_ value: Any?) -> String? {
    guard let value, !(value is NSNull) else { return nil }
    if let string = value as? String { return string }
    if let number = value as? NSNumber {
      if CFGetTypeID(number) == CFBooleanGetTypeID() {
        return number.boolValue ? "true" : "false"
      }
      return number.stringValue
    }
    return nil
  }

  static func nonEmpty(_ value: Any?) -> String? {
    guard let string = string(value), !string.isEmpty else { return nil }
    return string
  }

  static func double(_ value: Any?) -> Double? {
    guard let value, !(value is NSNull) else { return nil }
    if let number = value as? NSNumber { return number.doubleValue }
    if let string = value as? String { return Double(string) }
    return nil
  }

  static func bool(_ value: Any?) -> Bool? {
    guard let value, !(value is NSNull) else { return nil }
    if let bool = value as? Bool { return bool }
    if let number = value as? NSNumber { return number.boolValue }
    if let string = value as? String { return (string as NSString).boolValue }
    return nil
  }

  /// http / 协议相对 → https（ATS 禁明文；thumbnailUrl 同语义），并建 URL。
  /// URL(string:) 拒绝非 ASCII：失败时按 percent-encoding 兜底。
  static func sanitizedURL(_ raw: String) -> URL? {
    guard !raw.isEmpty else { return nil }
    var value = raw
    if value.hasPrefix("//") {
      value = "https:" + value
    } else if value.hasPrefix("http://") {
      value = "https://" + value.dropFirst("http://".count)
    }
    if let url = URL(string: value) { return url }
    guard let encoded = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
      return nil
    }
    return URL(string: encoded)
  }

  /// getAvatarUrl（src/utils/index.ts:115）：完整 URL 直通；本地 URI 直通；
  /// portrait id 拼 himg.bdimg.com 前缀。
  static func avatarURL(_ portrait: String) -> URL? {
    guard !portrait.isEmpty else { return nil }
    if portrait.hasPrefix("file://") || portrait.hasPrefix("ph://") {
      return URL(string: portrait)
    }
    if portrait.hasPrefix("http://") || portrait.hasPrefix("https://") {
      return sanitizedURL(portrait)
    }
    return sanitizedURL("https://himg.bdimg.com/sys/portrait/item/\(portrait)")
  }
}

// MARK: - 字典解析（JS 视图模型 → 行模型）

/// 输入 = mapProtoThread / mapFeedThreadItems 的输出字典（helpers.ts），
/// 键名与 src/types/index.ts ThreadInfo 一致。所有字段都可缺省，缺失走与
/// TweetCard 相同的兜底值。通用取值/测量在 TiebaRowDict / TiebaRowText。
private nonisolated enum TiebaFeedRowParser {
  static func dictionary(_ value: Any?) -> [String: Any]? {
    guard let value, !(value is NSNull) else { return nil }
    return value as? [String: Any]
  }

  static func array(_ value: Any?) -> [Any]? {
    guard let value, !(value is NSNull) else { return nil }
    return value as? [Any]
  }

  /// JS weightedTextLength（TweetCard.tsx:88）：CJK 记 1、其余记 0.5。
  static func weightedTextLength(_ parts: String?...) -> CGFloat {
    var total: CGFloat = 0
    for part in parts {
      guard let part else { continue }
      for scalar in part.unicodeScalars {
        total += scalar.value > 0xFF ? 1 : 0.5
      }
    }
    return total
  }

  /// JS relativeTime（src/utils/index.ts:59）。
  static func relativeTime(ms: Double) -> String {
    guard ms > 0, ms >= 946_684_800_000 else { return "" }
    let nowMs = Date().timeIntervalSince1970 * 1000
    let diff = max(0, nowMs - ms)
    let minute = 60_000.0
    let hour = 60 * minute
    let day = 24 * hour
    if diff < minute { return "刚刚" }
    if diff < hour { return "\(Int(diff / minute))分钟前" }
    if diff < day { return "\(Int(diff / hour))小时前" }
    let date = Date(timeIntervalSince1970: ms / 1000)
    let calendar = Calendar.current
    let startOfToday = calendar.startOfDay(for: Date())
    let startOfThen = calendar.startOfDay(for: date)
    if let yesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday),
       calendar.isDate(startOfThen, inSameDayAs: yesterday) {
      return "昨天 \(clockFormatter.string(from: date))"
    }
    if diff < 7 * day { return "\(Int(diff / day))天前" }
    return dayOnlyFormatter.string(from: date)
  }

  /// JS absoluteTime（src/utils/index.ts:81）。
  static func absoluteTime(ms: Double) -> String {
    guard ms > 0, ms >= 946_684_800_000 else { return "" }
    return absoluteTimeFormatter.string(from: Date(timeIntervalSince1970: ms / 1000))
  }

  // 三个格式化档按需缓存（与 TiebaPostRowMetrics 同款）。
  // DateFormatter 的构造要解析 locale/历法/时区，是重对象；而行模型是**逐行**构造的，
  // 现建现用等于每页几十次纯浪费（且测量跑在 .userInitiated 的后台任务上，与滚动抢 CPU）。
  // 线程安全依据（SDK 原文）：NSDateFormatter.h:158 "On iOS 7 and later NSDateFormatter is
  // thread safe"，且该类型标了 NS_SWIFT_SENDABLE —— 建好后只调 string(from:)、不再改动。
  // 地区/历法固定，避免佛历等脏输出。
  private static let clockFormatter = timeFormatter("HH:mm")
  private static let dayOnlyFormatter = timeFormatter("yyyy-MM-dd")
  private static let absoluteTimeFormatter = timeFormatter("yyyy-MM-dd HH:mm")

  private static func timeFormatter(_ format: String) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.dateFormat = format
    return formatter
  }

  /// mediaList → 图片数组（type=="image"，卡片显示档 = smallSrc || src）。
  static func parseMedia(_ raw: [String: Any]) -> [TiebaFeedRowMedia] {
    guard let list = array(raw["mediaList"]) else { return [] }
    var result: [TiebaFeedRowMedia] = []
    for element in list {
      guard let item = dictionary(element) else { continue }
      let type = TiebaRowDict.string(item["type"]) ?? "image"
      guard type == "image" else { continue }
      let small = TiebaRowDict.nonEmpty(item["smallSrc"]) ?? ""
      let display = small.isEmpty
        ? (TiebaRowDict.nonEmpty(item["src"]) ?? TiebaRowDict.nonEmpty(item["originSrc"]) ?? "")
        : small
      guard !display.isEmpty else { continue }
      let width = TiebaRowDict.double(item["width"]) ?? 0
      let height = TiebaRowDict.double(item["height"]) ?? 0
      let resolvedWidth = width > 0 ? width : 300
      let resolvedHeight = height > 0 ? height : 300
      let isLong = resolvedHeight / resolvedWidth > Double(TiebaFeedRowLayout.longImageRatio)
      // originSrc 单独保留（不参与显示档兜底链）：只有它是真正的原图；
      // src 在无 smallSrc 时就是显示档本身（RN 同判据）。
      result.append(TiebaFeedRowMedia(
        url: TiebaRowDict.sanitizedURL(display),
        originURL: TiebaRowDict.nonEmpty(item["originSrc"]).flatMap(TiebaRowDict.sanitizedURL),
        isGif: TiebaRowDict.bool(item["isGif"]) == true,
        isLong: isLong,
        // 服务端「显示查看原图按钮」标记（Media.show_original_btn，proto 字段 20；
        // GIF 恒为 0）。true 且当前未显示原图时查看器菜单才出现「查看原图」。
        showOriginalBtn: TiebaRowDict.bool(item["showOriginalBtn"]) == true,
        width: resolvedWidth,
        height: resolvedHeight
      ))
    }
    return result
  }

  /// 视频 poster（MediaPager 的 videoPoster 分支），仅图片数为 0 时绘制。
  static func parseVideoPoster(_ raw: [String: Any]) -> URL? {
    guard let list = array(raw["mediaList"]) else { return nil }
    for element in list {
      guard let item = dictionary(element),
            TiebaRowDict.string(item["type"]) == "video" else { continue }
      if let poster = TiebaRowDict.nonEmpty(item["poster"]) {
        return TiebaRowDict.sanitizedURL(poster)
      }
      if let src = TiebaRowDict.nonEmpty(item["src"]) {
        return TiebaRowDict.sanitizedURL(src)
      }
    }
    return nil
  }

  /// contentToText（src/utils/index.ts:17）：富文本 runs → 纯文本。
  static func contentToText(_ value: Any?) -> String {
    if let string = value as? String { return string }
    guard let segments = array(value) else { return "" }
    var text = ""
    for segment in segments {
      guard let item = dictionary(segment) else { continue }
      let kind = TiebaRowDict.string(item["type"]) ?? ""
      switch kind {
      case "at":
        text += "@" + (TiebaRowDict.string(item["text"]) ?? "")
      case "link", "topic", "emoticon", "text", "emoji":
        text += TiebaRowDict.string(item["text"]) ?? ""
      default:
        break
      }
    }
    return text
  }
}

/// 吧名/吧头像回填（原 search.ts 的 `forum_name ?? forumInfo?.forum_name` +
/// feed.ts:97-118 backfillForumAvatars 的唯一落点）：各页行字典的吧名键位不同、
/// 服务端 personalized/动态流恒不下发吧头像，缺名会让度量判据
/// （showForumPill && !forumName.isEmpty）把整块徽章判为不渲染。
/// 头像回填只读全站缓存 KV（forum_avatars_v1，无网络副作用），已有值不覆盖。
nonisolated enum TiebaFeedRowFallback {
  struct Resolved {
    var name = ""
    var avatar = ""
  }

  static func resolve(_ row: [String: Any]) -> Resolved {
    let name = forumName(row)
    return Resolved(name: name, avatar: forumAvatar(row, forumName: name))
  }

  /// 吧名逐键兜底（含 mapProtoThread 的 fname / forumInfo.name / forum.name 变体）。
  static func forumName(_ row: [String: Any]) -> String {
    let forumInfo = row["forumInfo"] as? [String: Any]
    let forumInfoSnake = row["forum_info"] as? [String: Any]
    let forum = row["forum"] as? [String: Any]
    let candidates: [Any?] = [
      row["forumName"], row["forum_name"], row["fname"],
      forumInfo?["forum_name"], forumInfo?["forumName"], forumInfo?["name"],
      forumInfoSnake?["forum_name"], forumInfoSnake?["forumName"], forumInfoSnake?["name"],
      forum?["forumName"], forum?["forum_name"], forum?["name"],
    ]
    for candidate in candidates {
      if let text = TiebaRowDict.nonEmpty(candidate) { return text }
    }
    return ""
  }

  /// 吧头像：行内已有值直通；缺失按 forumId 优先、退 `n:<吧名>` 读 KV 缓存。
  static func forumAvatar(_ row: [String: Any], forumName: String) -> String {
    let forumInfo = row["forumInfo"] as? [String: Any]
    let forumInfoSnake = row["forum_info"] as? [String: Any]
    let forum = row["forum"] as? [String: Any]
    let candidates: [Any?] = [
      row["forumAvatar"], row["forum_avatar"],
      forumInfo?["avatar"], forumInfoSnake?["avatar"], forum?["avatar"],
    ]
    for candidate in candidates {
      if let text = TiebaRowDict.nonEmpty(candidate) { return text }
    }
    let forumId = TiebaRowDict.string(row["forumId"] ?? row["forum_id"] ?? row["fid"]) ?? ""
    guard !forumId.isEmpty || !forumName.isEmpty,
          let key = TiebaForumAvatarCache.key(forumId: forumId, forumName: forumName)
    else { return "" }
    return TiebaForumAvatarCache.shared.cached(key: key)
  }
}
