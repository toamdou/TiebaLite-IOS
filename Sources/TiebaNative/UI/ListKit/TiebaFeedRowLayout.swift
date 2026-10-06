// 从 TiebaRowMetrics.swift 拆出（H10 千行文件拆分）：测量块 / 帧计划 / 共享布局几何。
// 纯搬运：整类型逐字搬走。

// MARK: - 测量块

/// 一行的各块高度与单行文本宽度（测量一次；plan() 只用它做算术）。
import UIKit

nonisolated struct TiebaFeedRowBlocks {
  let isBanner: Bool
  /// 右上角「更多」钮是否存在（决定名字行可用宽度让位 menuButtonSize + gap，
  /// 与 TweetCard headerRow 里 closeButton 参与 flex 布局同几何）。
  let showsMenu: Bool
  let headerHeight: CGFloat
  let titleHeight: CGFloat?
  let abstractHeight: CGFloat?
  let showMoreHeight: CGFloat?
  /// 阶段 0：三段多行文本在测量期排出来的**未取整**自然高（usedRect 高，与各自的
  /// frame 高同源、不额外排版）。绘制期垂直居中直接取用，不再回落「有界量高」
  ///（= 第二遍 CoreText 排版）。nil = 该段不存在（判据同 titleHeight 等）。
  let naturalTitleHeight: CGFloat?
  let naturalAbstractHeight: CGFloat?
  let naturalQuoteContentHeight: CGFloat?
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
  /// 阶段 0：title / abstract / quoteContent 三段的**未取整**自然高（测量期与 frame
  /// 同源，见 TiebaFeedRowBlocks）。绘制期由此做垂直居中 ⇒ 不再跑有界量高
  ///（第二遍排版）。nil = 该段没接上，绘制期回落旧行为（结果不变，只是多一趟排版）。
  let naturalTitleHeight: CGFloat?
  let naturalAbstractHeight: CGFloat?
  let naturalQuoteContentHeight: CGFloat?
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
  /// 左右边距 16：与首页关注吧网格（sectionInset 16）、最近访问条一致，
  /// 也是系统 inset 列表的标准档。原 10 与页面其余部分对不齐（2026-09-19）。
  static let cardMarginH: CGFloat = 16
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

  // ── 排版缓存 ──
  // 每个行模型 init 都经 geometry() 重建 Fonts(14 属性)+LineHeights(9 属性)，
  // 每次 scaledFont/scaledValue 都是一次 UIFontMetrics descriptor 匹配；而
  // fontScale 取值域极小（偏好 0.8–2.0，通常恒 1）——一页 20 行 ≈ 280 次重复
  // 解析。按 fontScale 缓存，系统字号档变化整体失效（UIFont 不可变、CGFloat
  // 值线程安全；测量在后台队列，访问走锁）。
  private static let typographyLock = NSLock()
  nonisolated(unsafe) private static var fontsCache: [CGFloat: Fonts] = [:]
  nonisolated(unsafe) private static var lineHeightsCache: [CGFloat: LineHeights] = [:]

  private static let typographyCacheReset: Void = {
    NotificationCenter.default.addObserver(
      forName: UIContentSizeCategory.didChangeNotification,
      object: nil,
      queue: .main
    ) { _ in
      typographyLock.withLock {
        fontsCache.removeAll()
        lineHeightsCache.removeAll()
      }
    }
    return ()
  }()

  static func geometry(containerWidth: CGFloat, fontScale: CGFloat) -> Geometry {
    _ = typographyCacheReset
    let width = max(containerWidth, 0)
    let cardWidth = max(width - cardMarginH * 2, 0)
    let contentWidth = max(cardWidth - cardPaddingX * 2, 0)
    let textColumnWidth = max(contentWidth - contentIndent, 0)
    let typography = cachedTypography(fontScale: fontScale)
    return Geometry(
      containerWidth: width,
      cardWidth: cardWidth,
      contentWidth: contentWidth,
      textColumnWidth: textColumnWidth,
      stripViewportWidth: cardWidth,
      stripLeadInset: cardPaddingX + contentIndent,
      fontScale: fontScale,
      fonts: typography.fonts,
      lineHeights: typography.lineHeights
    )
  }

  private static func cachedTypography(fontScale: CGFloat) -> (fonts: Fonts, lineHeights: LineHeights) {
    typographyLock.withLock {
      let fonts: Fonts
      if let cached = fontsCache[fontScale] {
        fonts = cached
      } else {
        fonts = Fonts(fontScale: fontScale)
        fontsCache[fontScale] = fonts
      }
      let lineHeights: LineHeights
      if let cached = lineHeightsCache[fontScale] {
        lineHeights = cached
      } else {
        lineHeights = LineHeights(fontScale: fontScale)
        lineHeightsCache[fontScale] = lineHeights
      }
      return (fonts, lineHeights)
    }
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
        naturalTitleHeight: nil,
        naturalAbstractHeight: nil,
        naturalQuoteContentHeight: nil,
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
    // 右上角「更多」钮在 headerRow 里参与 flex 布局（26pt +
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
      naturalTitleHeight: blocks.naturalTitleHeight,
      naturalAbstractHeight: blocks.naturalAbstractHeight,
      naturalQuoteContentHeight: blocks.naturalQuoteContentHeight,
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
