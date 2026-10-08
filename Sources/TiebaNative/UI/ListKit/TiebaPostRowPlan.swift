// 从 TiebaPostRowMetrics.swift 拆出（H10 千行文件拆分）：帧计划（测量与绘制共用的那份几何）。
// 纯搬运：整类型逐字搬走（不改访问级、不改一行逻辑）。

// MARK: - 帧计划（测量与绘制共用；单位 = 行坐标）

/// plan 的输入快照（模型 init 里在自身未初始化完时传递）。
import UIKit
import Nuke

struct TiebaPostRowPlanInputs {
  var containerWidth: CGFloat
  var isMain: Bool
  var post: TiebaThreadPost
  /// 帖子标题（只有主贴行用；楼中楼父卡不显示标题）。
  var titleText: NSAttributedString?
  var nameText: String
  var levelText: String?
  var levelShortText: String?
  var isLz: Bool
  var metaText: String
  var likeText: String
  var contentText: NSAttributedString?
  var subPostTexts: [NSAttributedString?]
  var showsBlockedTip: Bool
  var hairline: CGFloat
  var fontScale: Double
  var images: [TiebaThreadImage]
  var imagesHidden: Bool
  var video: TiebaThreadVideo?
  var videoPlaceholder: TiebaPostMediaPlaceholder?
  var audio: (src: String, duration: Double)?
  var toolbar: TiebaPostToolbarModel?
}

struct TiebaPostRowPlan {
  var rowHeight: CGFloat = 0
  var cardFrame: CGRect = .zero
  /// 行底**通栏**发际线（只在外观档 = 扁平时有值）：卡片档的行靠卡片间距分隔，
  /// 扁平档的行与行紧贴，必须有一条线把两行分开。
  var rowHairlineFrame: CGRect?
  var titleFrame: CGRect?
  var avatarFrame: CGRect = .zero
  var nameFrame: CGRect = .zero
  var levelFrame: CGRect?
  /// 徽标实际渲染的文案（放不下头衔时退成「Lv.N」，见下方测量）。
  var levelRenderText: String?
  var lzFrame: CGRect?
  var metaFrame: CGRect = .zero
  var menuFrame: CGRect = .zero
  var likeFrame: CGRect = .zero
  var likeIconFrame: CGRect = .zero
  var likeCountFrame: CGRect?
  var textFrame: CGRect?
  /// 正文 / 楼中楼的行距因子（TextNode 的 lineSpacing；见 TiebaTextLineMetrics）。测量与绘制共用这两个值。
  var contentLineSpacing: CGFloat = 0
  var subPostLineSpacing: CGFloat = 0
  var blockedTipFrame: CGRect?
  var imagesFrame: CGRect?
  var imageItemFrames: [CGRect] = []
  var imagePlaceholderFrames: [CGRect] = []
  var videoFrame: CGRect?
  var videoPlaceholderFrame: CGRect?
  var audioFrame: CGRect?
  var subPostsFrame: CGRect?
  /// 楼中楼预览框（浅底圆角矩形；无预览时为 nil）。
  var subPostsBoxFrame: CGRect?

  var subPostTextFrames: [CGRect] = []
  var subPostsMoreFrame: CGRect?
  var toolbarFrame: CGRect?
  var toolbarTextFrame: CGRect?
  var toolbarSeeLzFrame: CGRect?
  var toolbarSortFrame: CGRect?

  init(_ inputs: TiebaPostRowPlanInputs) {
    let width = inputs.containerWidth
    let cardW = max(width - TiebaPostRowLayout.cardMarginH * 2, 0)
    let contentX = TiebaPostRowLayout.cardMarginH + TiebaPostRowLayout.cardPadding
    let contentW = max(cardW - TiebaPostRowLayout.cardPadding * 2, 0)
    // 正文/楼中楼的行距因子：TextNode 不读段落样式的 minimumLineHeight，只能按「基准字体 + 目标行高」反推
    //（唯一换算在 TiebaTextLineMetrics）。字号/行高与 buildContent 同源：主贴 15pt/22pt、楼中楼 14pt/20pt，都乘字号缩放。
    let textScale = CGFloat(inputs.fontScale)
    contentLineSpacing = TiebaTextLineMetrics.lineSpacingFactor(
      for: UIFont.systemFont(ofSize: 15 * textScale, weight: .medium),
      targetLineHeight: 22 * textScale
    )
    subPostLineSpacing = TiebaTextLineMetrics.lineSpacingFactor(
      for: UIFont.systemFont(ofSize: 14 * textScale, weight: .medium),
      targetLineHeight: 20 * textScale
    )

    var y = TiebaPostRowLayout.cardMarginV
    let cardTop = y
    y += TiebaPostRowLayout.cardPadding

    // ── 标题（仅主贴卡）──
    // 卡片顶端第一块，下方留 authorBottom(12) —— 与已知主贴占位卡同尺同距
    //（占位卡 padding 16 / gap 12）：首包落地换卡时标题原地接管，不位移。
    if inputs.isMain, let title = inputs.titleText, title.length > 0 {
      let height = TiebaSimpleText.measureHeight(
        title,
        width: contentW,
        maxLines: TiebaPostRowLayout.titleLineLimit
      )
      titleFrame = CGRect(x: contentX, y: y, width: contentW, height: height)
      y += height + TiebaPostRowLayout.authorBottom
    }

    // ── 作者行 ──
    // 右侧操作组（⋮18 + gap12 + 点赞）按内容实测宽度占位，不能写死：固定占位会把
    // meta 行挤窄 →「时间 · 楼层 · IP属地」尾部（IP）被截断（用户报 IP 看不到）。
    let avatarSide = inputs.isMain ? TiebaPostRowLayout.avatarSideMain : TiebaPostRowLayout.avatarSide
    avatarFrame = CGRect(x: contentX, y: y, width: avatarSide, height: avatarSide)
    let nameFont = inputs.isMain ? TiebaPostRowLayout.nameFontMain : TiebaPostRowLayout.nameFont
    let nameX = contentX + avatarSide + TiebaPostRowLayout.avatarGap

    let likeText = inputs.likeText
    let likeIconSide: CGFloat = 18
    let likeGap: CGFloat = 4
    // 文本宽 +4：TextKit 取整会差半像素，不留余量尾字会被裁。
    let likeTextWidth = likeText.isEmpty
      ? 0
      : TiebaSimpleText.singleLineWidth(likeText, font: TiebaPostRowLayout.actionFont) + 4
    let likeWidth = max(likeIconSide + (likeTextWidth > 0 ? likeGap + likeTextWidth : 0), 28)
    let menuSide: CGFloat = 18
    let actionsWidth = menuSide + TiebaPostRowLayout.actionGap + likeWidth
    let actionsRight = contentX + contentW
    let nameMaxWidth = max(actionsRight - actionsWidth - TiebaPostRowLayout.levelGap - nameX, 0)
    let nameWidth = min(TiebaSimpleText.singleLineWidth(inputs.nameText, font: nameFont), nameMaxWidth)
    // [接线 TiebaEmoji] 昵称含 emoji 时，1 行行盒要按 AppleColorEmoji 的行高给：
    // 15pt 系统字体行高 17.9pt，而 emoji 字形行高 24.6pt，按前者排版 emoji 会压到下一行（meta）。
    let emojiLineHeight = UIFont(name: "AppleColorEmoji", size: nameFont.pointSize)?.lineHeight ?? nameFont.lineHeight
    let nameLineHeight = inputs.nameText.containsEmoji
      ? ceil(max(nameFont.lineHeight, emojiLineHeight))
      : ceil(nameFont.lineHeight)
    nameFrame = CGRect(x: nameX, y: y + 2, width: max(nameWidth, 0), height: nameLineHeight)
    let badgeLimit = actionsRight - actionsWidth - 4
    var badgeX = nameFrame.maxX + TiebaPostRowLayout.levelGap
    if let levelText = inputs.levelText {
      // 头衔把徽标撑宽后可能顶到右侧操作组：先试全串，放不下退成「Lv.N」——
      // 挤昵称或整个徽标消失都会让用户少看到东西（用户 2026-09-17 要求接头衔）。
      var text = levelText
      var levelWidth = TiebaSimpleText.singleLineWidth(text, font: TiebaPostRowLayout.badgeFont) + 10
      if badgeX + levelWidth > badgeLimit, let short = inputs.levelShortText {
        let shortWidth = TiebaSimpleText.singleLineWidth(short, font: TiebaPostRowLayout.badgeFont) + 10
        if badgeX + shortWidth <= badgeLimit {
          text = short
          levelWidth = shortWidth
        }
      }
      if badgeX + levelWidth <= badgeLimit {
        levelFrame = CGRect(x: badgeX, y: y + 5, width: levelWidth, height: 15)
        levelRenderText = text
        badgeX += levelWidth + TiebaPostRowLayout.levelGap
      }
    }
    if inputs.isLz {
      let lzWidth = TiebaSimpleText.singleLineWidth("楼主", font: TiebaPostRowLayout.lzFont) + 12
      if badgeX + lzWidth <= badgeLimit {
        lzFrame = CGRect(x: badgeX, y: y + 5, width: lzWidth, height: 15)
      }
    }
    let metaFont = TiebaPostRowLayout.metaFont
    metaFrame = CGRect(
      x: nameX,
      y: y + nameFrame.height + TiebaPostRowLayout.nameRowGap + 2,
      width: nameMaxWidth,
      height: ceil(metaFont.lineHeight)
    )

    // 操作组垂直居中于作者行（PostCard authorRow alignItems: 'center'）；行右缘对齐内容右缘。
    let actionsHeight: CGFloat = 28
    let authorHeight = max(avatarSide, nameFrame.height + TiebaPostRowLayout.nameRowGap + metaFrame.height)
    let actionY = y + max((authorHeight - actionsHeight) / 2, 0)
    let actionsX = actionsRight - actionsWidth
    menuFrame = CGRect(
      x: actionsX,
      y: actionY + (actionsHeight - menuSide) / 2,
      width: menuSide,
      height: menuSide
    )
    likeFrame = CGRect(
      x: actionsX + menuSide + TiebaPostRowLayout.actionGap,
      y: actionY,
      width: likeWidth,
      height: actionsHeight
    )
    likeIconFrame = CGRect(
      x: likeFrame.minX,
      y: actionY + (actionsHeight - likeIconSide) / 2,
      width: likeIconSide,
      height: likeIconSide
    )
    if !likeText.isEmpty {
      let likeLabelHeight = ceil(TiebaPostRowLayout.actionFont.lineHeight)
      likeCountFrame = CGRect(
        x: likeIconFrame.maxX + likeGap,
        y: actionY + (actionsHeight - likeLabelHeight) / 2,
        width: max(likeWidth - likeIconSide - likeGap, 0),
        height: likeLabelHeight
      )
    }

    y = max(avatarFrame.maxY, metaFrame.maxY) + TiebaPostRowLayout.authorBottom

    // 块间距挂在"下一个块的块首"，不再挂在块尾：末尾没有块时那 12pt 会变成正文
    // 最后一行到卡底的多余空白（用户 2026-09-15 报"回复离卡底空白太多"）。
    var gap: CGFloat = 0
    func flushGap() {
      y += gap
      gap = 0
    }

    // ── 正文 / 屏蔽提示 ──
    if inputs.showsBlockedTip {
      flushGap()
      blockedTipFrame = CGRect(x: contentX, y: y, width: 92, height: 24)
      y += 24
      gap = 8
    }
    if let text = inputs.contentText, text.length > 0 {
      flushGap()
      // 正文由 TextNode 绘制 → 高度必须同源（measureBody 就是 TiebaTextNode.calculateLayout）。
      let height = TiebaPostRowText.measureBody(text, width: contentW, maxLines: 0, lineSpacing: contentLineSpacing)
      textFrame = CGRect(x: contentX, y: y, width: contentW, height: height)
      y += height
      gap = TiebaPostRowLayout.mediaGap
    }

    // ── 图片块（hideMedia 时逐个占位条，不挂图）──
    if inputs.imagesHidden, !inputs.images.isEmpty {
      flushGap()
      let count = min(inputs.images.count, TiebaPostRowLayout.maxImages)
      let rowHeight: CGFloat = 40
      let rowSpacing: CGFloat = 6
      var y2 = y
      for _ in 0..<count {
        imagePlaceholderFrames.append(CGRect(x: contentX, y: y2, width: contentW, height: rowHeight))
        y2 += rowHeight + rowSpacing
      }
      imagesFrame = CGRect(x: contentX, y: y, width: contentW, height: max(y2 - rowSpacing - y, 0))
      // 占位条的行距照旧算进下一个块（6+12），只是不再留在卡尾。
      y = y2 - rowSpacing
      gap = TiebaPostRowLayout.mediaGap + rowSpacing
    } else if !inputs.images.isEmpty {
      flushGap()
      if inputs.images.count == 1 {
        let image = inputs.images[0]
        let height = image.isTall
          ? TiebaPostRowLayout.longImageHeight
          : min(contentW / CGFloat(max(image.aspect, 0.01)), TiebaPostRowLayout.singleImageMaxHeight)
        let frame = CGRect(x: contentX, y: y, width: contentW, height: max(height, 1))
        imagesFrame = frame
        imageItemFrames = [CGRect(origin: .zero, size: frame.size)]
      } else {
        var x: CGFloat = 0
        var frames: [CGRect] = []
        for image in inputs.images.prefix(TiebaPostRowLayout.maxImages) {
          let itemWidth = min(max(TiebaPostRowLayout.stripHeight * CGFloat(image.aspect), 56), 300)
          frames.append(CGRect(x: x, y: 0, width: itemWidth, height: TiebaPostRowLayout.stripHeight))
          x += itemWidth + TiebaPostRowLayout.stripSpacing
        }
        imagesFrame = CGRect(x: contentX, y: y, width: contentW, height: TiebaPostRowLayout.stripHeight)
        imageItemFrames = frames
      }
      y += (imagesFrame?.height ?? 0)
      gap = TiebaPostRowLayout.mediaGap
    }

    // ── 视频 ──
    if let video = inputs.video {
      flushGap()
      // 竖版视频按宽高比在宽列上能到上千 pt 高：上限同单图（520），横版 16:9 远在其下。
      let height = min(
        contentW / CGFloat(max(video.aspect, 0.01)),
        TiebaPostRowLayout.singleImageMaxHeight
      )
      videoFrame = CGRect(x: contentX, y: y, width: contentW, height: max(height, 1))
      y += max(height, 1)
      gap = TiebaPostRowLayout.mediaGap
    } else if inputs.videoPlaceholder != nil {
      flushGap()
      videoPlaceholderFrame = CGRect(x: contentX, y: y, width: contentW, height: 40)
      y += 40
      gap = TiebaPostRowLayout.mediaGap
    }

    // ── 语音 ──
    if inputs.audio != nil {
      flushGap()
      audioFrame = CGRect(x: contentX, y: y, width: contentW, height: TiebaPostRowLayout.audioHeight)
      y += TiebaPostRowLayout.audioHeight
      gap = TiebaPostRowLayout.mediaGap
    }

    // ── 楼中楼预览 ──
    let subPosts = inputs.post.subPosts
    if !subPosts.isEmpty || inputs.post.subPostNum > 0 {
      flushGap()
      y += TiebaPostRowLayout.subPostTop
      // 预览整段收进一个浅底圆角框：框自己就是"这段是别人的回复"的分区，旧版
      // 逐条上方的分隔线与块顶那条 hairline 随之取消。内容列（contentX/contentW）
      // 一字不动，框只是左右各外扩 subPostBoxPadding。
      let boxPadding = TiebaPostRowLayout.subPostBoxPadding
      let boxTop = y
      var subY = boxTop + boxPadding
      for (idx, sub) in subPosts.enumerated() {
        if idx > 0 {
          // 行与行之间仍留 2×gap（旧版这两段之间还夹着一条分隔线，框内不再画线）。
          subY += TiebaPostRowLayout.subPostDividerGap * 2
        }
        // 名字与正文在**同一条富文本**里（名字 + 冒号 + 正文，见 TiebaPostRowText.subPostLine）：
        // 一个文本框吃满整行宽，不再有"名字框 + 正文框"两套排版，首行基线不可能错开。
        let nameLine = TiebaPostRowLayout.subPostLineHeight(inputs.fontScale)
        let attributed = inputs.subPostTexts.indices.contains(idx) ? inputs.subPostTexts[idx] : nil
        let height = attributed.map {
          TiebaPostRowText.measureBody($0, width: contentW, maxLines: 2, lineSpacing: subPostLineSpacing)
        } ?? 0
        subPostTextFrames.append(CGRect(x: contentX, y: subY, width: contentW, height: height))
        subY += max(height, nameLine)
      }
      let moreText: String?
      if inputs.post.subPostNum > subPosts.count {
        moreText = "查看全部 \(inputs.post.subPostNum) 条回复"
      } else if subPosts.isEmpty {
        moreText = "查看 \(inputs.post.subPostNum) 条回复"
      } else {
        moreText = nil
      }
      if let moreText {
        subY += 8
        let moreFont = TiebaPostRowLayout.moreFont
        let moreWidth = min(TiebaSimpleText.singleLineWidth(moreText, font: moreFont), contentW)
        subPostsMoreFrame = CGRect(x: contentX, y: subY, width: moreWidth, height: ceil(moreFont.lineHeight))
        subY += subPostsMoreFrame?.height ?? 0
      }
      let boxHeight = max(subY + boxPadding - boxTop, 0)
      subPostsFrame = CGRect(x: TiebaPostRowLayout.cardMarginH, y: boxTop, width: cardW, height: boxHeight)
      subPostsBoxFrame = CGRect(
        x: contentX - boxPadding,
        y: boxTop,
        width: contentW + boxPadding * 2,
        height: boxHeight
      )
      y = boxTop + boxHeight
    }

    let cardBottom = y + TiebaPostRowLayout.cardPadding
    cardFrame = CGRect(
      x: TiebaPostRowLayout.cardMarginH,
      y: cardTop,
      width: cardW,
      height: max(cardBottom - cardTop, 0)
    )

    // ── 主贴回复工具栏（卡外独立一块）──
    var bottom = cardFrame.maxY
    if inputs.toolbar != nil {
      let toolbarY = cardFrame.maxY + 8
      toolbarFrame = CGRect(
        x: TiebaPostRowLayout.cardMarginH,
        y: toolbarY,
        width: cardW,
        height: TiebaPostRowLayout.toolbarHeight
      )
      let pillFont = TiebaPostRowLayout.pillFont
      let pillHeight: CGFloat = 30
      let pillY = toolbarY + (TiebaPostRowLayout.toolbarHeight - pillHeight) / 2
      var pillX = TiebaPostRowLayout.cardMarginH + cardW - TiebaPostRowLayout.cardPadding
      let sortTitle = inputs.toolbar?.sort.title ?? ""
      let sortWidth =
        TiebaSimpleText.singleLineWidth(sortTitle, font: pillFont) + 28
        + TiebaPostRowLayout.pillChevronWidth
      toolbarSortFrame = CGRect(x: pillX - sortWidth, y: pillY, width: sortWidth, height: pillHeight)
      pillX -= sortWidth + 8
      let seeLzWidth = TiebaSimpleText.singleLineWidth("只看楼主", font: pillFont) + 28
      toolbarSeeLzFrame = CGRect(x: pillX - seeLzWidth, y: pillY, width: seeLzWidth, height: pillHeight)
      let textX = TiebaPostRowLayout.cardMarginH + TiebaPostRowLayout.cardPadding
      toolbarTextFrame = CGRect(
        x: textX,
        y: toolbarY,
        width: max((toolbarSeeLzFrame?.minX ?? pillX) - textX - 8, 0),
        height: TiebaPostRowLayout.toolbarHeight
      )
      bottom = toolbarY + TiebaPostRowLayout.toolbarHeight + 8
    }
    rowHeight = bottom + TiebaPostRowLayout.cardMarginV
    // 扁平档的行间分隔：通栏 1 物理像素，贴在行底。**行高不变**——扁平档的
    // cardMarginV 已收到 0，腾出来的位置正好给它，线画在卡面 16pt 内边距的空白里，
    // 不压任何内容。厚度用 inputs.hairline（模型按屏幕 scale 算好的那份），
    // 测量与绘制同源 ⇒ 不会出现半像素灰边。
    if TiebaListAppearance.drawsRowHairline {
      rowHairlineFrame = CGRect(
        x: 0,
        y: max(rowHeight - inputs.hairline, 0),
        width: width,
        height: inputs.hairline
      )
    }
  }
}