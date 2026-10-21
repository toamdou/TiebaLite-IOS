// 从 TiebaPostRowMetrics.swift 拆出：帖子行帧计划（hero / context / reply 三种阅读角色）。
// 每个 role 的 frame 同时服务测量与绘制；视觉分支只改几何与容器语义，不建立第二套文本排版。

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
  /// Issue #5：多图竖排（设置里的「图片竖排」）。只改多图块的排布，不改单图。
  var imagesVertical: Bool
  var video: TiebaThreadVideo?
  var videoPlaceholder: TiebaPostMediaPlaceholder?
  var audio: (src: String, duration: Double)?
  var toolbar: TiebaPostToolbarModel?
}

struct TiebaPostRowPlan {
  /// 同一套模型/测量器承载三种不同阅读语义：帖子页 hero、固定父楼摘要、conversation 回复。
  enum Role: Equatable {
    case hero
    case context
    case reply
  }

  var role: Role = .hero
  var rowHeight: CGFloat = 0
  var cardFrame: CGRect = .zero
  var titleFrame: CGRect?
  /// 标题实际行盒（AX 下不能只用固定 titleLineHeight；字体行高更大）。
  var titleLineHeight: CGFloat = 0
  var avatarFrame: CGRect = .zero
  var nameFrame: CGRect = .zero
  /// 作者名/metadata 在 AX 下允许换行；视图按这两个上限配置 UILabel。
  var nameMaxLines: Int = 1
  var metaMaxLines: Int = 1
  var levelFrame: CGRect?
  /// 徽标实际渲染的文案（放不下头衔时退成「Lv.N」，见下方测量）。
  var levelRenderText: String?
  var lzFrame: CGRect?
  /// 回复专用楼层胶囊（主贴/父楼摘要不显示）。
  var floorFrame: CGRect?
  /// 高赞回复标记（非楼主、agreeNum 达到阅读权重阈值时出现）。
  var hotFrame: CGRect?
  var metaFrame: CGRect = .zero
  var menuFrame: CGRect = .zero
  var likeFrame: CGRect = .zero
  var likeIconFrame: CGRect = .zero
  var likeCountFrame: CGRect?
  var textFrame: CGRect?
  /// 测量期已经排好的正文 layout；展示期宽度/文本一致时直接贴，避免二次 CoreText。
  var contentLayout: TiebaTextNodeLayout?
  /// 正文 / 楼中楼的行距因子（TextNode 的 lineSpacing；见 TiebaTextLineMetrics）。测量与绘制共用这两个值。
  var contentLineSpacing: CGFloat = 0
  var subPostLineSpacing: CGFloat = 0
  /// 正文最多行数：固定父楼摘要为 0 以外的有限行，hero/回复为 0（不限）。
  var contentMaxLines: Int = 0
  var blockedTipFrame: CGRect?
  var imagesFrame: CGRect?
  var imageItemFrames: [CGRect] = []
  /// 本行多图块是否为竖排（视图据此关掉横滑）。
  var imagesVertical = false
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
    let role: Role = inputs.isMain
      ? (inputs.toolbar == nil ? .context : .hero)
      : .reply
    self.role = role
    let isReply = role == .reply
    let isContext = role == .context
    // 测量可能在后台队列：不读 UIApplication；用行字体实际 pointSize 判断是否进入
    // accessibility 级大字号（AX1 起 nameFont≈25pt；常规极大档仍 <20pt 左右）。
    let isAX = TiebaPostRowLayout.nameFont.pointSize >= 20
    let avatarSide = inputs.isMain ? TiebaPostRowLayout.avatarSideMain : TiebaPostRowLayout.avatarSide
    // 卡片档下回复也是一张独立白卡；扁平档保留通栏行 + 更大底部留白。
    // 帖子页内部固定扁平：动态页可以用卡片，但楼层/楼中楼不再卡片化。
    let isCardAppearance = false
    let replyInset: CGFloat = isCardAppearance ? TiebaPostRowLayout.cardMarginH : 16
    // 帖子页内部固定扁平：主贴不再做悬浮卡面，正文和媒体统一从 16pt 页边距起排。
    let heroInset: CGFloat = 0
    let heroPadding: CGFloat = 16
    let contextPadding: CGFloat = 20
    let cardW: CGFloat
    let contentX: CGFloat
    let contentW: CGFloat
    switch role {
    case .hero:
      cardW = width
      contentX = heroPadding
      contentW = max(cardW - heroPadding * 2, 0)
    case .context:
      cardW = width
      contentX = contextPadding
      contentW = max(width - contextPadding * 2, 0)
    case .reply:
      // 回复：头像列固定在左，作者/正文/媒体共用 body 列。
      if isCardAppearance {
        let pad = TiebaPostRowLayout.cardPadding
        cardW = max(width - TiebaPostRowLayout.cardMarginH * 2, 0)
        contentX = TiebaPostRowLayout.cardMarginH + pad + avatarSide + TiebaPostRowLayout.avatarGap
        contentW = max(cardW - pad * 2 - avatarSide - TiebaPostRowLayout.avatarGap, 0)
      } else {
        cardW = width
        contentX = replyInset + avatarSide + 12
        contentW = max(width - replyInset - contentX, 0)
      }
    }
    let avatarX: CGFloat = if isReply {
      isCardAppearance ? TiebaPostRowLayout.cardMarginH + TiebaPostRowLayout.cardPadding : replyInset
    } else {
      contentX
    }
    contentMaxLines = isContext ? 2 : 0
    // 正文/楼中楼的行距因子：TextNode 不读段落样式的 minimumLineHeight，只能按「基准字体 + 目标行高」反推
    //（唯一换算在 TiebaTextLineMetrics）。字号/行高与 buildContent 同源：主贴 15pt/22pt、楼中楼 14pt/20pt，都乘字号缩放。
    let textScale = CGFloat(inputs.fontScale)
    contentLineSpacing = TiebaTextLineMetrics.lineSpacingFactor(
      for: UIFont.systemFont(ofSize: 17 * textScale, weight: .regular),
      targetLineHeight: 26 * textScale
    )
    subPostLineSpacing = TiebaTextLineMetrics.lineSpacingFactor(
      for: UIFont.systemFont(ofSize: 15 * textScale, weight: .regular),
      targetLineHeight: 23 * textScale
    )

    let cardTop: CGFloat
    let topPadding: CGFloat
    switch role {
    case .hero:
      cardTop = 0
      topPadding = 16
    case .context:
      cardTop = 0
      topPadding = 18
    case .reply:
      cardTop = isCardAppearance ? TiebaPostRowLayout.cardMarginV : 0
      topPadding = isCardAppearance ? TiebaPostRowLayout.cardPadding : 14
    }
    var y = cardTop + topPadding

    // ── 标题（仅主贴卡）──
    // 卡片顶端第一块，下方留 authorBottom(12) —— 与已知主贴占位卡同尺同距
    //（占位卡 padding 16 / gap 12）：首包落地换卡时标题原地接管，不位移。
    if inputs.isMain, let title = inputs.titleText, title.length > 0 {
      let titleFont = TiebaPostRowLayout.titleFont
      // 标题字号独立于正文；AX 下字体 lineHeight 可能远大于默认 28pt 行盒。
      // 用同一份动态行高测量 + 绘制，避免 AX5 多行标题互相压。
      let titleLineHeight = max(
        TiebaPostRowLayout.titleLineHeight,
        ceil(titleFont.lineHeight)
      )
      self.titleLineHeight = titleLineHeight
      let measuredTitle = TiebaSimpleText.makeAttributed(
        text: title.string,
        font: titleFont,
        lineHeight: titleLineHeight,
        truncating: false
      )
      let height = TiebaSimpleText.measureHeight(
        measuredTitle,
        width: contentW,
        maxLines: TiebaPostRowLayout.titleLineLimit
      )
      titleFrame = CGRect(x: contentX, y: y, width: contentW, height: height)
      y += height + (role == .hero ? 18 : TiebaPostRowLayout.authorBottom)
    }

    // ── 作者行 / 元信息 / 操作 ──
    // AX 下不再把 name / badges / meta / actions 硬塞进同一横排：
    // name 可两行 → badges 换行 → meta 可两行 → action 行（44pt 命中框）最后落下。
    // 非 AX 保留紧凑横排；任何 badge 放不下就整体下移一行，不再消失或压在昵称上。
    avatarFrame = CGRect(x: avatarX, y: y, width: avatarSide, height: avatarSide)
    let nameFont = inputs.isMain ? TiebaPostRowLayout.nameFontMain : TiebaPostRowLayout.nameFont
    let nameX = isReply ? contentX : contentX + avatarSide + TiebaPostRowLayout.avatarGap

    let actionFont = TiebaPostRowLayout.actionFont
    let likeText = inputs.likeText
    let likeIconSide: CGFloat = 18
    let likeGap: CGFloat = 4
    let likeTextWidth = likeText.isEmpty
      ? 0
      : TiebaSimpleText.singleLineWidth(likeText, font: actionFont) + 4
    let actionHitHeight = max(44, ceil(actionFont.lineHeight) + 8)
    let menuSide = actionHitHeight
    let likeWidth = max(
      likeIconSide + (likeTextWidth > 0 ? likeGap + likeTextWidth : 0),
      44
    )
    let actionsWidth = menuSide + TiebaPostRowLayout.actionGap + likeWidth
    let actionsRight = contentX + contentW
    let fullNameMaxWidth = max(actionsRight - nameX, 0)
    let inlineNameMaxWidth = max(
      actionsRight - actionsWidth - TiebaPostRowLayout.levelGap - nameX,
      0
    )
    let stackedActions = isAX
    let nameLayoutMaxWidth = stackedActions ? fullNameMaxWidth : inlineNameMaxWidth
    let nameNaturalWidth = TiebaSimpleText.singleLineWidth(inputs.nameText, font: nameFont)
    let nameLineHeight = ceil(nameFont.lineHeight)
    nameMaxLines = isAX ? 0 : 2
    let nameHeight: CGFloat
    let nameFrameWidth: CGFloat
    if isAX {
      // AX 昵称不限行：按真实宽度测高，避免 2 行 cap 再次裁切。
      nameFrameWidth = nameLayoutMaxWidth
      let attributed = TiebaSimpleText.makeAttributed(
        text: inputs.nameText,
        font: nameFont,
        lineHeight: nameLineHeight,
        truncating: false
      )
      let measured = TiebaSimpleText.measureHeight(
        attributed,
        width: max(nameFrameWidth, 1),
        maxLines: 0
      )
      nameHeight = max(measured, nameLineHeight)
    } else {
      nameFrameWidth = min(nameNaturalWidth, nameLayoutMaxWidth)
      let lines = nameNaturalWidth > nameLayoutMaxWidth && nameLayoutMaxWidth > 0
        ? 2
        : 1
      nameHeight = nameLineHeight * CGFloat(lines)
    }
    nameFrame = CGRect(
      x: nameX,
      y: y + 2,
      width: max(nameFrameWidth, 0),
      height: nameHeight
    )

    let badgeGap = TiebaPostRowLayout.levelGap
    let maxBadgeWidth = max(fullNameMaxWidth, 44)
    var badgeSpecs: [(kind: String, text: String, width: CGFloat, height: CGFloat)] = []
    if let levelText = inputs.levelText {
      // 头衔先试全串；超过整行可用宽才退成 Lv.N。badge 高度随 Dynamic Type 长。
      var text = levelText
      let font = TiebaPostRowLayout.badgeFont
      var width = TiebaSimpleText.singleLineWidth(text, font: font) + 12
      if width > maxBadgeWidth, let short = inputs.levelShortText {
        let shortWidth = TiebaSimpleText.singleLineWidth(short, font: font) + 12
        if shortWidth <= maxBadgeWidth {
          text = short
          width = shortWidth
        }
      }
      width = min(width, maxBadgeWidth)
      let height = max(18, ceil(font.lineHeight) + 6)
      badgeSpecs.append(("level", text, width, height))
      levelRenderText = text
    }
    if inputs.isLz {
      let font = TiebaPostRowLayout.lzFont
      let text = "楼主"
      badgeSpecs.append((
        "lz",
        text,
        min(TiebaSimpleText.singleLineWidth(text, font: font) + 12, maxBadgeWidth),
        max(18, ceil(font.lineHeight) + 6)
      ))
    }
    if isReply, inputs.isLz == false, inputs.post.agreeNum >= 20 {
      let font = TiebaPostRowLayout.lzFont
      let text = "高赞"
      badgeSpecs.append((
        "hot",
        text,
        min(TiebaSimpleText.singleLineWidth(text, font: font) + 12, maxBadgeWidth),
        max(18, ceil(font.lineHeight) + 6)
      ))
    }
    let floorText = inputs.post.floor > 0 ? "\(inputs.post.floor)楼" : ""
    if isReply, inputs.post.floor > 0, isAX {
      let font = TiebaPostRowLayout.lzFont
      badgeSpecs.append((
        "floor",
        floorText,
        min(TiebaSimpleText.singleLineWidth(floorText, font: font) + 12, maxBadgeWidth),
        max(18, ceil(font.lineHeight) + 6)
      ))
    }

    let inlineBadgeRight = actionsRight - (stackedActions ? 0 : actionsWidth) - 4
    let inlineBadgeStart = nameFrame.maxX + badgeGap
    let totalBadgeWidth = badgeSpecs.reduce(CGFloat(0)) { $0 + $1.width }
      + CGFloat(max(badgeSpecs.count - 1, 0)) * badgeGap
    let badgesInline = stackedActions == false
      && badgeSpecs.isEmpty == false
      && inlineBadgeStart + totalBadgeWidth <= inlineBadgeRight
    var badgeBottom = nameFrame.maxY
    if badgesInline {
      var badgeX = inlineBadgeStart
      for spec in badgeSpecs {
        let frame = CGRect(
          x: badgeX,
          y: y + 2 + max((nameFrame.height - spec.height) / 2, 0),
          width: spec.width,
          height: spec.height
        )
        switch spec.kind {
        case "level": levelFrame = frame
        case "lz": lzFrame = frame
        case "hot": hotFrame = frame
        case "floor": floorFrame = frame
        default: break
        }
        badgeBottom = max(badgeBottom, frame.maxY)
        badgeX += spec.width + badgeGap
      }
    } else if badgeSpecs.isEmpty == false {
      // 回退行也只占 name 可用的列（未堆叠 actions 时给右侧操作组留位）。
      let badgeRowRight = stackedActions ? actionsRight : inlineBadgeRight
      var badgeX = nameX
      var badgeRowY = nameFrame.maxY + 6
      var rowHeight: CGFloat = 0
      for spec in badgeSpecs {
        let width = min(spec.width, max(badgeRowRight - nameX, 0))
        if badgeX > nameX, badgeX + width > badgeRowRight {
          badgeRowY += rowHeight + 4
          badgeX = nameX
          rowHeight = 0
        }
        let frame = CGRect(x: badgeX, y: badgeRowY, width: width, height: spec.height)
        switch spec.kind {
        case "level": levelFrame = frame
        case "lz": lzFrame = frame
        case "hot": hotFrame = frame
        case "floor": floorFrame = frame
        default: break
        }
        rowHeight = max(rowHeight, spec.height)
        badgeX += width + badgeGap
      }
      badgeBottom = badgeRowY + rowHeight
    }

    // meta 文本（回复在非 AX 时仍把 floor 放在 meta 行首；AX 时 floor 已进入 badge 行）。
    var metaString = inputs.metaText
    if isReply, inputs.post.floor > 0 {
      let token = "\(inputs.post.floor)楼"
      metaString = metaString
        .replacingOccurrences(of: " · \(token)", with: "")
        .replacingOccurrences(of: "\(token) · ", with: "")
      if metaString == token { metaString = "" }
    }
    let metaFont = TiebaPostRowLayout.metaFont
    let metaLineHeight = ceil(metaFont.lineHeight)
    let maxMetaLines = isAX ? 0 : 2
    metaMaxLines = maxMetaLines
    let metaStartY = max(nameFrame.maxY + TiebaPostRowLayout.nameRowGap + 2, badgeBottom + 4)
    var metaX = nameX
    var metaWidth = stackedActions ? fullNameMaxWidth : inlineNameMaxWidth
    var floorHeight: CGFloat = 0
    if isReply, inputs.post.floor > 0, isAX == false {
      let floorFont = TiebaPostRowLayout.lzFont
      let floorW = min(
        TiebaSimpleText.singleLineWidth(floorText, font: floorFont) + 12,
        max(metaWidth, 0)
      )
      floorHeight = max(ceil(floorFont.lineHeight) + 4, metaLineHeight)
      floorFrame = CGRect(x: metaX, y: metaStartY, width: floorW, height: floorHeight)
      metaX += floorW + 4
      metaWidth = max(metaWidth - floorW - 4, 0)
    }
    var metaHeight: CGFloat = 0
    if metaString.isEmpty == false, metaWidth > 0 {
      let attributed = TiebaSimpleText.makeAttributed(
        text: metaString,
        font: metaFont,
        lineHeight: metaLineHeight,
        truncating: metaMaxLines > 0
      )
      metaHeight = TiebaSimpleText.measureHeight(
        attributed,
        width: metaWidth,
        maxLines: metaMaxLines
      )
    }
    metaFrame = CGRect(
      x: metaX,
      y: metaStartY,
      width: max(metaWidth, 0),
      height: max(metaHeight, floorHeight)
    )

    // 操作组：AX 下独占一行；普通字号仍在作者行右侧，但控件自身为 ≥44pt 命中框。
    let actionY = stackedActions
      ? metaFrame.maxY + 8
      : max(y + nameFrame.height / 2 - actionHitHeight / 2, 0)
    let actionsX = actionsRight - actionsWidth
    menuFrame = CGRect(
      x: actionsX,
      y: actionY,
      width: menuSide,
      height: actionHitHeight
    )
    likeFrame = CGRect(
      x: actionsX + menuSide + TiebaPostRowLayout.actionGap,
      y: actionY,
      width: likeWidth,
      height: actionHitHeight
    )
    let likeContentWidth = likeIconSide + (likeTextWidth > 0 ? likeGap + likeTextWidth : 0)
    let likeContentX = likeFrame.minX + (likeWidth - likeContentWidth) / 2
    likeIconFrame = CGRect(
      x: likeContentX,
      y: actionY + (actionHitHeight - likeIconSide) / 2,
      width: likeIconSide,
      height: likeIconSide
    )
    if likeText.isEmpty == false {
      let likeLabelHeight = ceil(actionFont.lineHeight)
      likeCountFrame = CGRect(
        x: likeIconFrame.maxX + likeGap,
        y: actionY + (actionHitHeight - likeLabelHeight) / 2,
        width: max(likeTextWidth, 0),
        height: likeLabelHeight
      )
    }

    let authorBottom = max(
      max(avatarFrame.maxY, metaFrame.maxY),
      max(badgeBottom, actionY + actionHitHeight)
    )
    y = authorBottom + (role == .hero ? 18 : TiebaPostRowLayout.authorBottom)

    // 块间距挂在"下一个块的块首"，不再挂在块尾：末尾没有块时那 12pt 会变成正文
    // 最后一行到卡底的多余空白（用户 2026-09-15 报"回复离卡底空白太多"）。
    let blockGap = role == .hero
      ? TiebaPostRowLayout.mediaGap + 4
      : TiebaPostRowLayout.mediaGap
    var gap: CGFloat = 0
    func flushGap() {
      y += gap
      gap = 0
    }

    // ── 正文 / 屏蔽提示 ──
    if inputs.showsBlockedTip {
      flushGap()
      let tipFont = TiebaSimpleText.bodyFont(size: 12, weight: .regular)
      let tipHeight = max(24, ceil(tipFont.lineHeight) + 8)
      let tipWidth = min(
        max(TiebaSimpleText.singleLineWidth("内容已屏蔽", font: tipFont) + 34, 92),
        contentW
      )
      blockedTipFrame = CGRect(x: contentX, y: y, width: tipWidth, height: tipHeight)
      y += tipHeight
      gap = 8
    }
    if let text = inputs.contentText, text.length > 0 {
      flushGap()
      // 正文由 TextNode 绘制：测量期保存完整 layout，展示期只贴结果。
      let layout = TiebaPostRowText.measureBodyLayout(
        text,
        width: contentW,
        maxLines: contentMaxLines,
        lineSpacing: contentLineSpacing
      )
      contentLayout = layout
      let height = layout?.size.height ?? 0
      textFrame = CGRect(x: contentX, y: y, width: contentW, height: height)
      y += height
      gap = blockGap
    }

    // ── 图片块（固定父楼只留一条紧凑上下文缩略带；hero / 回复沿用原媒体节奏）──
    if isContext, inputs.images.isEmpty == false {
      flushGap()
      let side: CGFloat = 64
      let spacing: CGFloat = 6
      if inputs.imagesHidden {
        imagePlaceholderFrames = [
          CGRect(x: contentX, y: y, width: contentW, height: 40)
        ]
        imagesFrame = CGRect(x: contentX, y: y, width: contentW, height: 40)
        y += 40
      } else {
        var x: CGFloat = 0
        for image in inputs.images.prefix(4) {
          let itemWidth = min(max(side * CGFloat(image.aspect), 56), 96)
          imageItemFrames.append(CGRect(x: x, y: 0, width: itemWidth, height: side))
          x += itemWidth + spacing
        }
        imagesFrame = CGRect(
          x: contentX,
          y: y,
          width: min(max(x - spacing, 1), contentW),
          height: side
        )
        y += side
      }
      gap = blockGap
    } else if inputs.imagesHidden, inputs.images.isEmpty == false {
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
      y = y2 - rowSpacing
      gap = blockGap + rowSpacing
    } else if inputs.images.isEmpty == false {
      flushGap()
      if inputs.images.count == 1 {
        let image = inputs.images[0]
        let height = image.isTall
          ? TiebaPostRowLayout.longImageHeight
          : min(contentW / CGFloat(max(image.aspect, 0.01)), TiebaPostRowLayout.singleImageMaxHeight)
        let frame = CGRect(x: contentX, y: y, width: contentW, height: max(height, 1))
        imagesFrame = frame
        imageItemFrames = [CGRect(origin: .zero, size: frame.size)]
      } else if inputs.imagesVertical {
        // Issue #5：竖排。每张按自身比例铺满内容宽，高度钳在 [80, 260]：
        //   · 下限 80 让超宽图（长图横切）不至于压成一条线；
        //   · 上限 260 是因为竖排会把 N 张的高度**相加**进行高 —— 不封顶时
        //     9 张长图能顶出 3000pt 的行，单个 cell 就吃掉整屏，列表虚拟化失效。
        // 张数上限单独收窄到 3（横排是 9）：竖排本来就是"想看大一点"，超过 3 张
        // 用末图 +N 角标提示进大图查看器更合适，也把行高钉在 ~800pt 以内。
        var y2: CGFloat = 0
        var frames: [CGRect] = []
        for image in inputs.images.prefix(TiebaPostRowLayout.verticalMaxImages) {
          let height = min(
            max(contentW / CGFloat(max(image.aspect, 0.01)), TiebaPostRowLayout.verticalImageMinHeight),
            TiebaPostRowLayout.verticalImageMaxHeight
          )
          frames.append(CGRect(x: 0, y: y2, width: contentW, height: height))
          y2 += height + TiebaPostRowLayout.stripSpacing
        }
        imagesFrame = CGRect(
          x: contentX,
          y: y,
          width: contentW,
          height: max(y2 - TiebaPostRowLayout.stripSpacing, 1)
        )
        imageItemFrames = frames
        imagesVertical = true
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
      gap = blockGap
    }

    // ── 视频 ──
    if isContext == false, let video = inputs.video {
      flushGap()
      // 竖版视频按宽高比在宽列上能到上千 pt 高：上限同单图（520），横版 16:9 远在其下。
      let height = min(
        contentW / CGFloat(max(video.aspect, 0.01)),
        TiebaPostRowLayout.singleImageMaxHeight
      )
      videoFrame = CGRect(x: contentX, y: y, width: contentW, height: max(height, 1))
      y += max(height, 1)
      gap = blockGap
    } else if isContext == false, inputs.videoPlaceholder != nil {
      flushGap()
      videoPlaceholderFrame = CGRect(x: contentX, y: y, width: contentW, height: 40)
      y += 40
      gap = blockGap
    }

    // ── 语音 ──
    if isContext == false, inputs.audio != nil {
      flushGap()
      audioFrame = CGRect(x: contentX, y: y, width: contentW, height: TiebaPostRowLayout.audioHeight)
      y += TiebaPostRowLayout.audioHeight
      gap = blockGap
    }

    // ── 楼中楼预览 ──
    let subPosts = inputs.post.subPosts
    if isContext == false, !subPosts.isEmpty || inputs.post.subPostNum > 0 {
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
      subPostsBoxFrame = CGRect(
        x: contentX - boxPadding,
        y: boxTop,
        width: contentW + boxPadding * 2,
        height: boxHeight
      )
      // 回复的楼中楼预览跟随 conversation body 列；hero 仍可吃满整张主贴卡。
      if isReply {
        subPostsFrame = subPostsBoxFrame
      } else {
        subPostsFrame = CGRect(
          x: role == .hero ? heroInset : TiebaPostRowLayout.cardMarginH,
          y: boxTop,
          width: cardW,
          height: boxHeight
        )
      }
      y = boxTop + boxHeight
    }

    let cardBottomPadding: CGFloat
    switch role {
    case .hero: cardBottomPadding = 18
    case .context: cardBottomPadding = 18
    case .reply: cardBottomPadding = isCardAppearance ? TiebaPostRowLayout.cardPadding : 20
    }
    let cardBottom = y + cardBottomPadding
    cardFrame = CGRect(
      x: role == .hero ? heroInset : (isReply && isCardAppearance ? TiebaPostRowLayout.cardMarginH : 0),
      y: cardTop,
      width: cardW,
      height: max(cardBottom - cardTop, 0)
    )

    // ── hero → 回复之间的 section divider + masthead ──
    var bottom = cardFrame.maxY
    if role == .hero, inputs.toolbar != nil {
      // 不用横线分隔主贴和回复工具栏：留白 + 字重层级已经足够。
      let toolbarY = cardFrame.maxY + 18
      let pillFont = TiebaPostRowLayout.pillFont
      let replyCountFont = TiebaPostRowLayout.replyCountFont
      let pillHitHeight = max(44, ceil(pillFont.lineHeight) + 12)
      let titleLineHeight = ceil(replyCountFont.lineHeight)
      let availableWidth = max(cardW - heroPadding * 2, 0)
      let sortTitle = inputs.toolbar?.sort.title ?? ""
      let sortWidth =
        TiebaSimpleText.singleLineWidth(sortTitle, font: pillFont) + 28
        + TiebaPostRowLayout.pillChevronWidth
      let seeLzWidth = TiebaSimpleText.singleLineWidth("只看楼主", font: pillFont) + 28
      let pageLabel = inputs.toolbar?.pageLabel ?? ""
      let titleText = pageLabel.isEmpty
        ? "全部回复 · \(inputs.toolbar?.replyNum ?? 0)"
        : "全部回复 · \(inputs.toolbar?.replyNum ?? 0) · \(pageLabel)"
      let titleWidth = TiebaSimpleText.singleLineWidth(titleText, font: replyCountFont)
      let titleLines = max(
        Int(ceil(titleWidth / max(availableWidth, 1))),
        1
      )
      let titleHeight = titleLineHeight * CGFloat(titleLines)
      let pillsWidth = seeLzWidth + 8 + sortWidth
      // AX 或常规字号下横向已放不下：masthead 改为纵向，绝不把 tab/标题压成省略号。
      let verticalToolbar = isAX || pillsWidth + titleWidth + 24 > availableWidth
      if verticalToolbar {
        var cursorY = toolbarY
        toolbarTextFrame = CGRect(
          x: contentX,
          y: cursorY,
          width: availableWidth,
          height: titleHeight
        )
        cursorY += titleHeight + 8
        let buttonWidth = min(max(max(seeLzWidth, sortWidth), 160), availableWidth)
        toolbarSeeLzFrame = CGRect(
          x: contentX,
          y: cursorY,
          width: buttonWidth,
          height: pillHitHeight
        )
        cursorY += pillHitHeight + 8
        toolbarSortFrame = CGRect(
          x: contentX,
          y: cursorY,
          width: buttonWidth,
          height: pillHitHeight
        )
        cursorY += pillHitHeight
        toolbarFrame = CGRect(
          x: heroInset,
          y: toolbarY,
          width: cardW,
          height: max(cursorY - toolbarY + 4, pillHitHeight)
        )
      } else {
        let toolbarHeight = max(
          TiebaPostRowLayout.toolbarHeight,
          titleLineHeight + 20,
          pillHitHeight + 10
        )
        let pillY = toolbarY + (toolbarHeight - pillHitHeight) / 2
        var pillX = heroInset + cardW - heroPadding
        toolbarSortFrame = CGRect(
          x: pillX - sortWidth,
          y: pillY,
          width: sortWidth,
          height: pillHitHeight
        )
        pillX -= sortWidth + 8
        toolbarSeeLzFrame = CGRect(
          x: pillX - seeLzWidth,
          y: pillY,
          width: seeLzWidth,
          height: pillHitHeight
        )
        toolbarTextFrame = CGRect(
          x: contentX,
          y: toolbarY,
          width: max(pillX - contentX - 10, 0),
          height: toolbarHeight
        )
        toolbarFrame = CGRect(
          x: heroInset,
          y: toolbarY,
          width: cardW,
          height: toolbarHeight
        )
      }
      bottom = toolbarFrame?.maxY ?? 0
      bottom += 4
    }
    rowHeight = if isReply {
      cardFrame.maxY + (isCardAppearance ? TiebaPostRowLayout.cardMarginV : 0)
    } else if isContext {
      cardFrame.maxY
    } else {
      bottom
    }
    // 回复/楼中楼不画 conversation rail、section rule 或行底发丝线。
    // 层级由头像列、楼主/楼层、正文和楼中楼预览框承担，不制造任何跨行连线。
  }
}
