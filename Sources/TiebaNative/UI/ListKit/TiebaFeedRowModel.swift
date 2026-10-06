// 从 TiebaRowMetrics.swift 拆出（H10 千行文件拆分）：媒体值类型 + 行模型。
// 纯搬运：整类型逐字搬走。

// MARK: - 媒体

/// 行内一张图片（绘制 + 长按菜单的输入）。
import UIKit

public nonisolated struct TiebaFeedRowMedia: Sendable {
  /// 卡片显示档（服务端 big_pic，对 GIF 即 g=0 静态压缩档——CDN 的 sign 绑定
  /// 变换段，客户端改写一律被打回占位图，见 TiebaNuke「GIF 三档」注），已升级 https。
  public let url: URL?
  /// 动图档（服务端 src_pic，无 g 变换）：GIF 即动图字节，静图与显示档近似；
  /// HEAD 探测（判定 GIF 角标）与查看器播放用。缺省 nil = 该图无独立动图档。
  public let animatedURL: URL?
  /// 原图档（originSrc）：查看器「查看原图」与长按「保存照片/分享照片」用原图
  /// 字节（RN 版 PostImageContextMenu full = originSrc）。旧数据缺 originSrc
  /// 时为 nil，消费方回落显示档（与 RN 的 `originSrc || src` 同语义）。
  public let originURL: URL?
  /// height/width > 2.4（MediaPager.tsx:121 LONG_IMAGE_RATIO，右下角「长图」徽标）。
  public let isLong: Bool
  /// 服务端「显示查看原图按钮」（show_original_btn）：查看器长按菜单据此出现
  /// 「查看原图」。
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
  // [R4-3] 原先这里还有一个 `fingerprint: UInt64`（TiebaRowFingerprint.hash(raw:)）。它**消费方为零**：
  // 逐行复用判据与整页差量走的都是 TiebaRowDiff.Entry 自己的指纹/Identity，缓存键用的是
  // Entry.Identity —— 每行白算一遍含三层嵌套字典排序的整行哈希（测量队列上、每页几十次）。
  // 已删除存储与计算；TiebaRowFingerprint 类型本身保留（Entry 侧另用）。
  /// 帖子 id（JS 下发）：行复用时区分"同一帖重配"与"换了另一帖"——计数跳动
  /// 只在同一帖的计数变化时播（对齐 RN 的组件复用语义）。
  public let threadId: String
  /// 测量所用容器宽度（= JS 给行的显式宽度）。
  public let containerWidth: CGFloat
  /// 应用内**正文级**字号倍率（设置→个性化→阅读字号→正文字号；缺省 1，
  /// 仅参与截断启发式，不参与字号）。
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
  /// 引用卡可跳转的原帖 thread id（proto OriginThreadInfo.tid；缺失 = 点击退回整卡）。
  public let quoteThreadId: String?

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
  /// 右上角「更多」菜单项（屏蔽/举报）：TweetCard closeMenuOptions 的取值子集
  /// （dislike / block / copy-title）。空数组 = 该行不绘制菜单钮（与
  /// TweetCard 未传 onMenuAction 时一致）；缺 key 同样为空。
  public let menuOptions: [String]
  /// 图片长按菜单（TweetCard imageContextMenu）：保存照片 / 分享照片。
  public let showsImageContextMenu: Bool
  /// 卡片长按菜单（本仓新增）：分享帖子 / 复制帖子内容 / 不感兴趣 / 屏蔽作者。
  /// **默认关**（与 imageContextMenu 缺省开不同）：四个动作全由页面侧执行，没接线的
  /// 页面挂上就是死按钮——所以只认显式下发的 cardContextMenu（动态流/吧页各一处）。
  public let showsCardContextMenu: Bool

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
    // 钳制域覆盖新字号的整段（12…24pt ⇒ 0.706…1.412）：窄域会把小字号端压平。
    let fontScale = min(max(CGFloat(TiebaRowDict.double(raw["fontScale"]) ?? 1), 0.7), 1.45)
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
          ? TiebaTimeText.absolute(ms: rawValue)
          : TiebaTimeText.relative(ms: rawValue)
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
    // 只有**看得见**的正文才算正文：服务端/上游偶发下发纯空白（"\n"、全角空格）时，
    // 改前 nonEmpty 判为有值 ⇒ 摘要照样占一行高（4 + 22pt）却一个字形都不画，
    // 标题与图片之间就空出那一条（用户 2026-10-06 报「没有正文、只有标题+图片的帖子：
    // 标题与图片之间空白过多」）。判据与渲染一致：画不出字的串 = 没有这一段。
    let titleText = TiebaRowDict.visible(raw["title"])
    let abstractText = TiebaRowDict.visible(raw["abstract"])
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
    // 阶段 0：同一趟测量留下的**未取整**自然高，随 blocks → plan 传给绘制期
    //（绘制期拿它做垂直居中，省掉第二遍排版）。
    let naturalTitleHeight = titleMeasure?.exactHeight

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
    // 同上：摘要的未取整自然高（截断态 = 实排出的那几行；未截断态 = 全文高）。
    let naturalAbstractHeight = abstractMeasure?.exactHeight

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
    // 文案 = 用户口径的「加载更多」（2026-10-06 报「没有加载更多按钮」）：点它原地展开
    // 整段正文，卡片高度跟着正文一起长（行高走「内容身份 → 新测量」的既有通道）。
    let showMoreText = "加载更多"
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
    var quoteThreadId: String?
    if TiebaRowDict.bool(raw["isShareThread"]) == true,
       let origin = TiebaFeedRowParser.dictionary(raw["originThreadInfo"]) {
      quoteForumText = TiebaRowDict.nonEmpty(origin["forumName"])
      quoteTitleText = TiebaRowDict.nonEmpty(origin["title"])
      let content = TiebaFeedRowParser.contentToText(origin["content"])
      quoteContentText = content.isEmpty ? nil : content
      quoteThreadId = TiebaRowDict.nonEmpty(origin["threadId"])
    }

    var quoteForumAttributed: NSAttributedString?
    var quoteTitleAttributed: NSAttributedString?
    var quoteContentAttributed: NSAttributedString?
    var quoteForumLineHeight: CGFloat?
    var quoteTitleLineHeight: CGFloat?
    var quoteContentLineHeight: CGFloat?
    // 阶段 0：引用正文那一趟测量的**未取整**自然高（另起一趟 = 绘制期第二遍排版）。
    var naturalQuoteContentHeight: CGFloat?
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
        // 一趟测量同时产出块高（ceil）与绘制期自然高（未取整）——零额外排版。
        let contentMeasure = TiebaRowText.measure(
          content,
          width: geometry.textColumnWidth - TiebaFeedRowLayout.quotePadding * 2,
          maxLines: 2
        )
        let contentHeight = contentMeasure.height
        quoteContentLineHeight = contentHeight
        naturalQuoteContentHeight = contentMeasure.exactHeight
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
    // 白名单 = 行视图**已有文案、页面已有动作**的取值集合（文案见 TiebaFeedRowView.menuTitle(for:)，
    // 动作见各页 handleMenuAction）。未知项丢弃，非法值不该被静默带进 UI。
    // 改前症状：白名单漏了 block-forum，而动态流（TiebaExploreFeedViewController:342）明确请求它、
    // 视图与页面也都实现了「屏蔽吧」⇒ 该菜单项被静默丢弃成死功能（复检 H15 实锤）。
    // 改后行为：白名单与「生产方请求 + 视图/页面已实现」对齐，四项都可达。
    let menuOptions = (TiebaFeedRowParser.array(raw["closeMenuOptions"]) ?? [])
      .compactMap { TiebaRowDict.string($0) }
      .filter { ["dislike", "block", "block-forum", "copy-title"].contains($0) }
    // 缺 key = 开（只有显式 false 才关）：造行的页面漏传过一次就让整页长按失效
    //（吧页/话题页，2026-09-15），而"少一个菜单"比"多一个菜单"难发现得多。
    let showsImageContextMenu = TiebaRowDict.bool(raw["imageContextMenu"]) != false
    // 缺 key = 关（只有显式 true 才开）：与上面一条相反 —— 图片菜单缺省开是"少一个
    // 菜单难发现"，卡片菜单缺省开则是"多一套长按 + 四个没人接的按钮"。
    let showsCardContextMenu = TiebaRowDict.bool(raw["cardContextMenu"]) == true

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
      naturalTitleHeight: naturalTitleHeight,
      naturalAbstractHeight: naturalAbstractHeight,
      naturalQuoteContentHeight: naturalQuoteContentHeight,
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
    self.quoteThreadId = quoteThreadId
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
    self.showsCardContextMenu = showsCardContextMenu
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
