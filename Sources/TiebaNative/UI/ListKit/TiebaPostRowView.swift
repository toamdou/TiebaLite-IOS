// 帖子行视图（thread/[id] 的 hero + conversation 回复，以及楼中楼固定父卡）与其内嵌媒体。
//
// 同一个视图按 plan.role 呈现三种阅读语义：hero 编辑式主贴、context 固定上下文摘要、
// reply 头像列 + body 列 + 线程竖线。行高仍由 TiebaPostRowMetrics 预先算好，
// 本视图只按 model.plan 摆 frame（测多少画多少），不在滚动中做实时布局/材质。
// 交互自管（点赞/菜单/头像/楼中楼/图片），只把语义动作经 onEvent 外传；
// 视频/语音的互斥与离屏暂停由 TiebaThreadMediaCoordinator 收敛（原 mediaBusStore）。
import AVFoundation
import AVKit
import UIKit
import Nuke
import NukeExtensions

/// Forum/Thread 阅读面共用的无障碍色与 surface token。
/// 元信息/次级图标不使用 tertiaryLabel（白底约 1.7:1）：默认 62% label，
/// Increase Contrast 提到 82%，两种都满足 4.5:1（小字）与 3:1（图标）。
enum TiebaAccessibleColors {
  static let surfaceRadius: CGFloat = TiebaDesignSystem.Radius.card

  static let metadata: UIColor = UIColor { traits in
    let alpha: CGFloat = traits.accessibilityContrast == .high
      ? 0.88
      : (traits.userInterfaceStyle == .dark ? 0.60 : 0.55)
    return UIColor.label.resolvedColor(with: traits).withAlphaComponent(alpha)
  }

  static let icon: UIColor = metadata

  /// 楼中楼预览的内嵌面：只比页面高一层，不画边、不画线。
  static let nestedSurface: UIColor = UIColor { traits in
    if traits.userInterfaceStyle == .dark {
      return UIColor.white.withAlphaComponent(traits.accessibilityContrast == .high ? 0.10 : 0.055)
    }
    return UIColor(red: 0.968, green: 0.968, blue: 0.976, alpha: 1)
  }

  /// 亮色 = white；暗色 = elevated secondary（Increase Contrast 再上提一档），
  /// 不靠黑底+黑阴影或灰描边制造边界。
  static let elevatedSurface: UIColor = UIColor { traits in
    guard traits.userInterfaceStyle == .dark else {
      return UIColor.systemBackground.resolvedColor(with: traits)
    }
    return traits.accessibilityContrast == .high
      ? UIColor.tertiarySystemBackground.resolvedColor(with: traits)
      : UIColor.secondarySystemBackground.resolvedColor(with: traits)
  }
}

// MARK: - 帖子卡视图
final class TiebaPostRowView: UIView {
  var onEvent: ((TiebaPostRowEvent) -> Void)?

  /// 上一次真正贴上去的模型（身份比较）：同一个实例重复 apply 直接返回（见 apply(model:)）。
  private weak var appliedModel: TiebaPostRowModel?

  /// 上一次贴进正文 TextNode 的 attributed（身份比较，见 loadEmoticonsIfNeeded）。
  private var assignedText: NSAttributedString?

  private let cardView = UIView()
  private var avatarView: TiebaForumAvatarView?
  private let titleLabel = UILabel()
  private let nameLabel = UILabel()
  private let metaLabel = UILabel()
  private let levelLabel = UILabel()
  private let lzLabel = UILabel()
  private let floorLabel = UILabel()
  private let hotLabel = UILabel()
  private let likeIcon = UIImageView()
  private let likeLabel = UILabel()
  private let menuButton = UIButton(type: .system)
  private let avatarControl = TiebaPostHitControl(frame: .zero)
  private let likeControl = UIControl()
  // [显示] 正文 = TextNode 渲染（移植自上游 Display/Source/TextNode.swift 的排版/绘制路径）：
  // 行高/行距/截断/配色全部由 plan 的行距因子 + TextNode 排版决定，逐项与系统排版对拍（见 27 号文档）。
  // 选择、链接按压高亮、无障碍元素都读**同一份 cachedLayout** —— 几何与绘制同源，没有第二套排版。
  private let textNode = TiebaImmediateTextNode()
  /// 选择层（长按选词 / 拖手柄改选 / 编辑菜单）：叠在正文之上，命中与否由它自己的 hitTest 决定。
  private var textSelectionNode: TiebaTextSelectionNode?
  /// 链接按压高亮（跨行连续）：正文之上、选择层之下。
  private let linkHighlightNode = TiebaLinkHighlightingNode(color: .clear)
  /// 链接的无障碍元素容器（与正文同框的透明层；正文本体仍由 textNode 自己作为元素）。
  private let textAccessibilityOverlay = UIView()
  /// 按下中的链接（抬手时据此决定打开；移开手指即取消）。
  private var pressedLink: (url: String, displayText: String)?
  /// 链接按压识别器（delegate 判据要用到它：只按在链接上才成立）。
  private var linkPressRecognizer: UILongPressGestureRecognizer?
  private var selectionMenu: UIMenu?
  private var selectionMenuInteraction: UIEditMenuInteraction?
  private let blockedTipView = UIView()
  private let blockedTipLabel = UILabel()
  private let blockedTipIcon = UIImageView()
  private let imageScrollView = UIScrollView()
  // TiebaGIFImageView：GIF 档由 TiebaGIFPlayer 逐帧渲染，静态档当普通 UIImageView 用。
  private var imageViews: [TiebaGIFImageView] = []
  private var imagePlaceholderViews: [TiebaPostPlaceholderView] = []
  private let videoPlaceholderView = TiebaPostPlaceholderView()
  private let imageBadge = UILabel()
  /// GIF 角标（对齐 Kotlin 版：GIF 图右下角小黑标；.feed 行已有同款）。
  /// [修复④a] **每张图各一个角标**：原来整行共用 `gifBadge` 一个 label，一行多图时后亮的角标会覆盖
  /// 前一个的位置（用户实测的「有的有有的没有」）。改为一图一标，挂在图自己的视图上。
  private var gifBadges: [ObjectIdentifier: UILabel] = [:]
  private var videoView: TiebaInlineVideoView?
  private var audioView: TiebaAudioPillView?
  private let subPostsControl = UIControl()
  /// 楼中楼预览框：浅底圆角矩形，垫在预览文字下面（非交互）。
  private let subPostsBox = UIView()
  // 楼中楼预览同样是 TextNode：两行截断（truncationType = .end，与 UILabel 的 byTruncatingTail 同口径）。
  // 名字不再单独一个 UILabel —— 它与冒号、正文合成同一条富文本（见 TiebaPostRowText.subPostLine），
  // 否则两个排版引擎在同一行盒里的首行基线会差出一两个点。
  private var subPostTextNodes: [TiebaImmediateTextNode] = []
  private let subPostsMoreLabel = UILabel()
  private let toolbarView = UIView()
  private let toolbarReplyLabel = UILabel()
  private let seeLzButton = TiebaPostPillButton(type: .system)
  private let sortButton = TiebaPostPillButton(type: .system)

  private var model: TiebaPostRowModel?
  private var palette: TiebaFeedRowPalette = .default
  /// 上一次真正贴上的互动态：只在状态变化时放飞一只弹簧，首屏/重复 apply 不播。
  private var observedIsAgree: Bool?
  private var observedLikeText = ""
  private var observedToolbarSeeLz: Bool?
  private var observedToolbarSort: TiebaThreadSort?
  /// iPad 指针悬停：只挂在交互控件上，不改变触摸/滚动；强引用交给行视图持有。
  private var pointerInteractions: [TiebaPointerInteraction] = []
  /// 头像视图会按主贴/回复尺寸重建，悬停对象必须跟着更新 customInteractionView。
  private var avatarPointerInteraction: TiebaPointerInteraction?

  override init(frame: CGRect) {
    super.init(frame: frame)
    isOpaque = false
    backgroundColor = .clear
    clipsToBounds = true
    buildSubviews()
    // 正文 layout 已是不可变快照；绘制移到后台，主线程只贴 layer.contents。
    textNode.layer.drawsAsynchronously = true
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  // MARK: 配置

  func apply(pageKey: String, index: Int) {
    guard let model = TiebaPostRowMetrics.shared.row(pageKey: pageKey, index: index) else {
      self.model = nil
      appliedModel = nil
      isHidden = true
      return
    }
    isHidden = false
    apply(model: model)
  }

  func apply(model: TiebaPostRowModel) {
    // 同一个模型实例重复 apply（点赞/页脚变化引起的可见行重配）不必重贴：正文重新贴一次
    // 就是一次完整排版（TextNode 的 CoreText 排版），是这行最贵的一笔；主题色变
    // 走 applyPalette 另一条路。换行/换模型/reuse 都会让 token 失配。
    if appliedModel === model { return }
    let previousIsAgree = observedIsAgree
    let previousLikeText = observedLikeText
    appliedModel = model
    let oldRole = self.model?.plan.role
    let paletteChanged = self.palette != model.palette
    self.model = model
    if paletteChanged || oldRole != model.plan.role {
      self.palette = model.palette
      applyPalette(model.palette)
    }
    let plan = model.plan
    // hero 的柔和 elevation 需要越过行边界一点点；回复仍严格裁切，避免线程串层。
    clipsToBounds = plan.role != .hero

    // 进帖转场的目标端配对（只有主贴卡带 id）：首包落地后这张卡接替占位卡，
    // 没有它的话"返回上一级"的缩回动画就找不到目标（见 TiebaHeroTransition）。
    TiebaHeroTransition.mark(cardView, threadId: model.heroThreadId ?? "")
    cardView.frame = plan.cardFrame
    applyPostRowSurface()
    let isHotReply = plan.role == .reply && model.isLz == false && model.post.agreeNum >= 20
    avatarControl.frame = plan.avatarFrame
    titleLabel.isHidden = plan.titleFrame == nil
    if let titleFrame = plan.titleFrame {
      titleLabel.frame = titleFrame
      // 行高与 plan 测量同源；AX 下 titleFont.lineHeight 会随 Dynamic Type 增长，
      // 不能继续用固定的 28pt titleLineHeight 去压多行标题。
      titleLabel.attributedText = model.titleText.map { titleText in
        TiebaSimpleText.makeAttributed(
          text: titleText.string,
          font: TiebaPostRowLayout.titleFont,
          lineHeight: plan.titleLineHeight > 0
            ? plan.titleLineHeight
            : TiebaPostRowLayout.titleLineHeight,
          truncating: false
        )
      }
      titleLabel.textColor = model.palette.text
    } else {
      titleLabel.attributedText = nil
    }
    configureAvatar(model: model, frame: plan.avatarFrame)
    avatarControl.isAccessibilityElement = true
    avatarControl.accessibilityLabel = "查看\(model.nameText)的头像"
    avatarControl.accessibilityTraits = .button
    nameLabel.frame = plan.nameFrame
    nameLabel.font = plan.role == .hero
      ? TiebaPostRowLayout.nameFontMain
      : TiebaPostRowLayout.nameFont
    metaLabel.font = TiebaPostRowLayout.metaFont
    blockedTipLabel.font = TiebaSimpleText.bodyFont(size: 12, weight: .regular)
    levelLabel.font = TiebaPostRowLayout.badgeFont
    lzLabel.font = TiebaPostRowLayout.lzFont
    floorLabel.font = TiebaPostRowLayout.lzFont
    hotLabel.font = TiebaPostRowLayout.lzFont
    likeLabel.font = TiebaPostRowLayout.actionFont
    nameLabel.numberOfLines = plan.nameMaxLines
    nameLabel.lineBreakMode = plan.nameMaxLines == 0
      ? .byWordWrapping
      : .byTruncatingTail
    nameLabel.text = model.nameText
    nameLabel.textColor = model.palette.text
    if model.preferences.showBothUsername, !model.post.authorName.isEmpty, model.post.authorName != model.nameText {
      nameLabel.text = "\(model.nameText) @\(model.post.authorName)"
    }
    metaLabel.frame = plan.metaFrame
    var displayedMeta = model.metaText
    if plan.role == .reply, model.post.floor > 0 {
      // floor 已经是独立浅色胶囊；从轻量 meta 中去重，信息不变但层级更干净。
      let floorToken = "\(model.post.floor)楼"
      displayedMeta = displayedMeta
        .replacingOccurrences(of: " · \(floorToken)", with: "")
        .replacingOccurrences(of: "\(floorToken) · ", with: "")
      if displayedMeta == floorToken { displayedMeta = "" }
    }
    metaLabel.text = displayedMeta
    metaLabel.numberOfLines = plan.metaMaxLines
    metaLabel.lineBreakMode = plan.metaMaxLines == 0
      ? .byWordWrapping
      : .byTruncatingTail
    metaLabel.isHidden = plan.metaFrame.height <= 0
    metaLabel.textColor = TiebaAccessibleColors.metadata

    levelLabel.isHidden = plan.levelFrame == nil
    if let frame = plan.levelFrame {
      levelLabel.frame = frame
      // 文案由 plan 决定（头衔放不下时它已退成「Lv.N」）。
      levelLabel.text = plan.levelRenderText ?? model.levelText
      // 等级不再使用彩虹色；所有等级徽标统一为中性小 chip，只保留楼主为品牌蓝强调。
      levelLabel.textColor = model.palette.text
      levelLabel.backgroundColor = .tertiarySystemFill
    }
    lzLabel.isHidden = plan.lzFrame == nil
    if let frame = plan.lzFrame {
      lzLabel.frame = frame
      lzLabel.textColor = model.palette.primary
      lzLabel.backgroundColor = model.palette.primary.withAlphaComponent(0.10)
    }
    floorLabel.isHidden = plan.floorFrame == nil
    if let frame = plan.floorFrame {
      floorLabel.frame = frame
      floorLabel.text = "\(model.post.floor)楼"
      floorLabel.textColor = model.palette.text
      floorLabel.backgroundColor = .tertiarySystemFill
      floorLabel.accessibilityLabel = "第\(model.post.floor)楼"
    }
    hotLabel.isHidden = plan.hotFrame == nil
    if let frame = plan.hotFrame {
      hotLabel.frame = frame
      hotLabel.textColor = model.palette.text
      hotLabel.backgroundColor = .tertiarySystemFill
      hotLabel.accessibilityLabel = "高赞回复"
    }

    likeIcon.frame = plan.likeIconFrame
    // SF Symbol 走 TiebaSymbols 缓存：每次 apply 现建一张会走 CoreGlyphs（滚动时每行两次）。
    likeIcon.image = TiebaSymbols.image(
      model.post.isAgree ? "heart.fill" : "heart",
      pointSize: 18,
      weight: .regular
    )
    // 高赞回复用主色而非更淡的 tertiary 提示"这条值得先读"，只在未点赞时生效。
    let quietActionColor = isHotReply ? model.palette.primary : TiebaAccessibleColors.icon
    likeIcon.tintColor = model.post.isAgree ? model.palette.liked : quietActionColor
    likeControl.frame = plan.likeFrame
    likeLabel.isHidden = plan.likeCountFrame == nil
    if let frame = plan.likeCountFrame {
      likeLabel.frame = frame
      likeLabel.text = model.likeText
      // 小号操作文字始终走 ≥4.5:1 的 metadata；点赞状态由 heart.fill 与 accessibility 传达。
      likeLabel.textColor = TiebaAccessibleColors.metadata
    }
    likeControl.isAccessibilityElement = true
    likeControl.accessibilityLabel = model.post.isAgree ? "取消点赞" : "点赞"
    likeControl.accessibilityHint = model.post.isAgree ? "双击取消点赞" : "双击点赞"
    likeControl.accessibilityValue = model.likeText.isEmpty ? nil : model.likeText
    likeControl.accessibilityTraits = model.post.isAgree ? [.button, .selected] : .button
    menuButton.frame = plan.menuFrame
    menuButton.setImage(TiebaSymbols.image("ellipsis", pointSize: 18, weight: .bold), for: .normal)
    menuButton.tintColor = TiebaAccessibleColors.icon
    menuButton.accessibilityHint = "复制、分享或复制链接"

    let likeStateChanged = previousIsAgree != nil && previousIsAgree != model.post.isAgree
    let likeCountChanged = previousIsAgree != nil && previousLikeText != model.likeText
    observedIsAgree = model.post.isAgree
    observedLikeText = model.likeText
    if window != nil, likeStateChanged || likeCountChanged {
      TiebaInteractiveMotion.pulse(likeIcon, from: likeStateChanged ? 0.82 : 0.92)
      if likeCountChanged, likeLabel.isHidden == false {
        TiebaInteractiveMotion.pulse(likeLabel, from: 0.92)
      }
    }

    textNode.isHidden = plan.textFrame == nil
    if let frame = plan.textFrame {
      textNode.frame = frame
      assignedText = model.contentText
      textNode.lineSpacing = plan.contentLineSpacing
      textNode.maximumNumberOfLines = plan.contentMaxLines
      textNode.attributedText = model.contentText
      // 测量期已有一份完整 CoreText layout：宽度/文本一致就只贴结果，滚动中不再重排。
      if let layout = model.plan.contentLayout,
        abs(layout.constrainedSize.width - frame.width) < 0.5,
        let text = model.contentText,
        layout.attributedString?.isEqual(to: text) == true
      {
        textNode.apply(cachedLayout: layout)
      } else {
        // 兜底：宽度变化或表情升级后文本变了，才重新排版。
        // 约束高度不参与行数判定：行数只看 maximumNumberOfLines（0 = 不限行），与 measureBody 同口径。
        _ = textNode.updateLayout(CGSize(width: frame.width, height: .greatestFiniteMagnitude))
      }
      installTextAccessibility()
    } else {
      assignedText = nil
      textNode.attributedText = nil
      textAccessibilityOverlay.accessibilityElements = nil
    }
    layoutTextOverlays()

    blockedTipView.isHidden = plan.blockedTipFrame == nil
    if let frame = plan.blockedTipFrame {
      blockedTipView.frame = frame
      blockedTipIcon.frame = CGRect(x: 8, y: (frame.height - 12) / 2, width: 12, height: 12)
      blockedTipLabel.sizeToFit()
      blockedTipLabel.frame = CGRect(
        x: 24,
        y: (frame.height - blockedTipLabel.bounds.height) / 2,
        width: frame.width - 32,
        height: blockedTipLabel.bounds.height
      )
    }

    layoutImages(model: model, plan: plan)
    layoutMedia(model: model, plan: plan)
    videoPlaceholderView.isHidden = plan.videoPlaceholderFrame == nil
    if let frame = plan.videoPlaceholderFrame, let placeholder = model.videoPlaceholder {
      videoPlaceholderView.frame = frame
      videoPlaceholderView.configure(icon: placeholder.icon, text: placeholder.text, palette: model.palette)
    }
    layoutSubPosts(model: model, plan: plan)
    layoutToolbar(model: model, plan: plan)
    loadEmoticonsIfNeeded(model: model)
  }

  func applyPalette(_ palette: TiebaFeedRowPalette) {
    self.palette = palette
    titleLabel.textColor = palette.text
    // 正文颜色烘在 attributed 里（palette.text / 链接 palette.primary + 下划线），与 titleLabel 同法：
    // 换主题由 UITextView 时代的 textColor/linkTextAttributes 改为「随模型重建」，语义不变。
    avatarView?.backgroundColor = palette.avatarFallback
    blockedTipView.backgroundColor = .systemFill
    blockedTipLabel.textColor = TiebaAccessibleColors.metadata
    blockedTipIcon.tintColor = TiebaAccessibleColors.icon
    imageBadge.textColor = .white
    // 与 buildSubviews 里的规范值同源（黑 55%；改前这里是 45%，会把新规范覆盖回旧值）。
    imageBadge.backgroundColor = UIColor.black.withAlphaComponent(0.55)
    // 楼中楼预览是正文内的次级容器：只用低面积系统 fill 分层，
    // 不画深色描边、不叠阴影/材质。
    subPostsBox.backgroundColor = TiebaAccessibleColors.nestedSurface
    subPostsBox.layer.borderWidth = 0
    subPostsBox.layer.borderColor = UIColor.clear.cgColor
    floorLabel.textColor = palette.text
    floorLabel.backgroundColor = .tertiarySystemFill
    hotLabel.textColor = palette.text
    hotLabel.backgroundColor = .tertiarySystemFill
    applyPostRowSurface()
    // 楼中楼正文颜色同样烘在 attributed 里（palette.text），与主贴正文一致。
    subPostsMoreLabel.textColor = palette.primary
    // hero masthead 不是卡：底色透明，只用 typography 分组。
    toolbarView.backgroundColor = .clear
    toolbarView.layer.borderWidth = 0
    toolbarView.layer.borderColor = UIColor.clear.cgColor
    toolbarReplyLabel.textColor = palette.text
    seeLzButton.tintColor = palette.primary
    sortButton.tintColor = palette.primary
    updateToolbarPills(observeState: false)
    videoView?.applyPalette(palette)
    audioView?.applyPalette(palette)
  }

  /// 帖子内部固定扁平：主贴、父楼摘要、楼层回复共用同一条纯内容表面。
  /// 首次配置和换主题都走这里，避免两份 role switch 漂移。
  private func applyPostRowSurface() {
    cardView.backgroundColor = .clear
    cardView.layer.cornerRadius = 0
    cardView.layer.borderWidth = 0
    cardView.layer.borderColor = UIColor.clear.cgColor
    cardView.layer.shadowOpacity = 0
    cardView.layer.shadowPath = nil
  }

  func prepareForReuse() {
    // 复用复位契约（TiebaEntrance 文件头）：只清自持状态、不清 layer 上的在途入场动画，
    // 首屏入场未播完就滚动时，from 值（opacity 0 / y+12）会压住复用后的新楼层。
    TiebaEntrance.cancel(on: self)
    model = nil
    appliedModel = nil
    observedIsAgree = nil
    observedLikeText = ""
    observedToolbarSeeLz = nil
    observedToolbarSort = nil
    let pressControls: [UIControl] = [menuButton, likeControl, subPostsControl, seeLzButton, sortButton]
    for control in pressControls {
      TiebaInteractiveMotion.reset(control)
    }
    TiebaInteractiveMotion.reset(subPostsBox)
    TiebaInteractiveMotion.reset(likeIcon)
    TiebaInteractiveMotion.reset(likeLabel)
    floorLabel.isHidden = true
    hotLabel.isHidden = true
    cardView.layer.shadowOpacity = 0
    cardView.layer.shadowPath = nil
    imageScrollView.contentOffset = .zero
    assignedText = nil
    gifProbeGenerations.removeAll(keepingCapacity: true)
    titleLabel.attributedText = nil
    textNode.maximumNumberOfLines = 0
    textNode.layer.drawsAsynchronously = true
    textNode.attributedText = nil
    textSelectionNode?.cancelSelection()
    clearLinkHighlight()
    for view in imageViews {
      // 在途请求必须取消（与 TiebaFeedRowView.resetContent / TiebaSimpleRows 同纪律，
      // 文件头写明）：否则旧 displayProcessor 请求照常解码并写缓存，位图贴在复用后的
      // 隐藏视图上。GIF 侧必须走 prepareForGIFReuse()：它 = recycle()，
      // 停表 + **真释放帧缓存** + 释放 CGImageSource（老的 Gifu 只暂停 animator，
      // 帧缓冲一个都不放，滚动一遍就把沿途所有 GIF 的整窗帧攒在内存里）。
      cancelRequest(for: view)
      // GIF 的 Nuke ImageTask 是手挂的，不在 NukeExtensions 的视图关联里，得单独取消（P2-5）。
      tiebaCancelGifLoad(view)
      view.prepareForGIFReuse()
      view.image = nil
      view.alpha = 1
      view.clipsToBounds = false
    }
    for view in imagePlaceholderViews { view.isHidden = true }
    for node in subPostTextNodes { node.attributedText = nil }
    videoView?.prepareForReuse()
    audioView?.prepareForReuse()
    videoView?.removeFromSuperview()
    audioView?.removeFromSuperview()
    videoView = nil
    audioView = nil
    imageBadge.isHidden = true
    self.hideGifBadges()
  }

  /// 首屏入场：hero 与 conversation 回复用同一套 timing/key，但 hero 位移更大、
  /// 时长更从容；模型值始终是终态，复用复位仍按 TiebaEntrance.animationKey 清理。
  func playEntrance(index: Int) {
    TiebaEntrance.cancel(on: self)
    layer.opacity = 1
    layer.transform = CATransform3DIdentity
    guard UIAccessibility.isReduceMotionEnabled == false, let model else { return }
    let isHero = model.plan.role == .hero
    let opacity = CABasicAnimation(keyPath: "opacity")
    opacity.fromValue = 0
    opacity.toValue = 1
    let translation = CABasicAnimation(keyPath: "transform.translation.y")
    translation.fromValue = isHero ? 16 : 8
    translation.toValue = 0
    let group = CAAnimationGroup()
    group.animations = [opacity, translation]
    group.duration = isHero
      ? TiebaAnimationDuration.largeSlide
      : TiebaAnimationDuration.tapFeedback
    group.beginTime = CACurrentMediaTime() + TiebaEntrance.delay(forIndex: index)
    group.fillMode = .backwards
    group.timingFunction = CAMediaTimingFunction(name: .easeOut)
    TiebaAnimationFrameRate.align(group, to: self)
    layer.add(group, forKey: TiebaEntrance.animationKey)
  }

  // MARK: 子视图装配

  private func buildSubviews() {
    addSubview(cardView)
    // 主贴卡标题（卡顶第一块，见 TiebaPostRowPlan 的标题块）：行高/行数/截断都在
    // 段落样式里（makeAttributed），这里只管行数与颜色（颜色现取色板，与占位卡同款）。
    titleLabel.numberOfLines = TiebaPostRowLayout.titleLineLimit
    titleLabel.isHidden = true
    titleLabel.accessibilityTraits = .header
    addSubview(titleLabel)
    addSubview(avatarControl)
    avatarControl.addTarget(self, action: #selector(handleAvatar), for: .touchUpInside)
    nameLabel.numberOfLines = 1
    nameLabel.font = TiebaPostRowLayout.nameFont
    addSubview(nameLabel)
    metaLabel.numberOfLines = 2
    metaLabel.font = TiebaPostRowLayout.metaFont
    addSubview(metaLabel)
    for label in [levelLabel, lzLabel, floorLabel, hotLabel] {
      label.textAlignment = .center
      label.layer.cornerRadius = 4
      label.layer.cornerCurve = .continuous
      label.clipsToBounds = true
      addSubview(label)
    }
    levelLabel.font = TiebaPostRowLayout.badgeFont
    lzLabel.font = TiebaPostRowLayout.lzFont
    lzLabel.text = "楼主"
    floorLabel.font = TiebaPostRowLayout.lzFont
    floorLabel.isHidden = true
    hotLabel.font = TiebaPostRowLayout.lzFont
    hotLabel.text = "高赞"
    hotLabel.isHidden = true
    addSubview(likeIcon)
    likeIcon.isAccessibilityElement = false
    likeLabel.font = TiebaPostRowLayout.actionFont
    likeLabel.isAccessibilityElement = false
    addSubview(likeLabel)
    addSubview(likeControl)
    likeControl.addTarget(self, action: #selector(handleAgree), for: .touchUpInside)
    addSubview(menuButton)
    menuButton.addTarget(self, action: #selector(handleMenu), for: .touchUpInside)
    menuButton.accessibilityLabel = "更多操作"

    // 正文四层（自下而上）：TextNode 文本 → 链接按压高亮 → 无障碍元素层 → 选择层。
    // 选择/高亮/无障碍都读 textNode.cachedLayout 的矩形，因此不会与绘制差半像素。
    textNode.maximumNumberOfLines = 0
    textNode.truncationType = .end
    textNode.isUserInteractionEnabled = false
    addSubview(textNode)
    linkHighlightNode.isUserInteractionEnabled = false
    linkHighlightNode.isHidden = true
    addSubview(linkHighlightNode)
    textAccessibilityOverlay.isUserInteractionEnabled = false
    textAccessibilityOverlay.backgroundColor = .clear
    addSubview(textAccessibilityOverlay)

    // 选择层：长按 0.3s 起选、拖手柄改选、抬手弹菜单。选区颜色用系统语义色（随深浅色自适应，
    // 不依赖应用强调色），与系统文本框的选区观感一致。
    let selectionNode = TiebaTextSelectionNode(
      theme: TiebaTextSelectionTheme(
        selection: UIColor.label.withAlphaComponent(0.2),
        knob: .label,
        isDark: traitCollection.userInterfaceStyle == .dark
      ),
      target: TiebaTextSelectionTarget(textNode: textNode),
      updateIsActive: { [weak self] isActive in
        // 起选时收起链接高亮：同一块区域不该同时出现两种高亮。
        if isActive { self?.clearLinkHighlight() }
      },
      rootView: { [weak self] in
        self.flatMap { TiebaViewHosts.viewController(for: $0)?.view }
      },
      presentMenu: { [weak self] anchor, rect, items in
        self?.presentSelectionMenu(on: anchor, rect: rect, items: items)
      },
      dismissMenu: { [weak self] in
        self?.selectionMenuInteraction?.dismissMenu()
      },
      performAction: { [weak self] string, action in
        self?.performSelectionAction(string: string, action: action)
      }
    )
    selectionNode.enableQuote = false
    selectionNode.enableTranslate = false
    selectionNode.canBeginSelection = { [weak self, weak selectionNode] point in
      // 链接上不起选择：否则按住链接会弹出选词菜单，看不见该链接的按压高亮。
      guard let self, let selectionNode else { return false }
      return self.linkAttribute(at: self.textNode.convert(point, from: selectionNode)) == nil
    }
    // 点链接：轻点直接打开；按住 ≥0.1s 出跨行高亮、抬手打开。tap 等 press 失败 ⇒ 两条路互斥，不会开两次。
    let linkPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLinkPress))
    linkPress.minimumPressDuration = 0.1
    linkPress.allowableMovement = 12
    linkPress.cancelsTouchesInView = false
    // 只按在**链接上**才允许开始（见文件末尾 UIGestureRecognizerDelegate 扩展）：它若在 0.1s
    // 无条件 began，UIKit 会取消同一视图上仍在等 0.3s 的选择手势 —— 那是「长按正文弹不出菜单」的第二个原因。
    linkPress.delegate = self
    linkPressRecognizer = linkPress
    let textTap = UITapGestureRecognizer(target: self, action: #selector(handleTextTap))
    textTap.require(toFail: linkPress)
    selectionNode.addGestureRecognizer(linkPress)
    selectionNode.addGestureRecognizer(textTap)
    // 编辑菜单（拷贝/全选/查询…）走系统的 UIEditMenuInteraction：装配期就挂到选择层上，
    // 长按选词时由 presentSelectionMenu 弹出（自绘选择没有系统文本框那套免费菜单，必须自己装这一件）。
    let editMenuInteraction = UIEditMenuInteraction(delegate: self)
    selectionNode.addInteraction(editMenuInteraction)
    selectionMenuInteraction = editMenuInteraction
    addSubview(selectionNode)
    textSelectionNode = selectionNode

    blockedTipView.layer.cornerRadius = 12
    blockedTipView.layer.cornerCurve = .continuous
    blockedTipIcon.image = UIImage(
      systemName: "eye.slash",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .regular)
    )
    blockedTipView.addSubview(blockedTipIcon)
    blockedTipLabel.text = "内容已屏蔽"
    blockedTipLabel.font = TiebaSimpleText.bodyFont(size: 12, weight: .regular)
    blockedTipView.addSubview(blockedTipLabel)
    addSubview(blockedTipView)

    addSubview(videoPlaceholderView)
    videoPlaceholderView.isHidden = true

    imageScrollView.showsHorizontalScrollIndicator = false
    imageScrollView.backgroundColor = .clear
    imageScrollView.isHidden = true
    addSubview(imageScrollView)
    // 改前症状：「+N」角标是 15pt / 黑 45% / 圆角 8，与同图带的 GIF 角标及信息流规范
    //（11pt / 黑 55% / 圆角 10）两套风格，末图同时有 GIF 与 +N 时两个角标不同款。
    // 改后行为：与信息流规范同款（字号/底色/圆角三处对齐，位置由帧计划给、不动）。
    imageBadge.font = TiebaSimpleText.font(size: 11, weight: .semibold)
    imageBadge.textAlignment = .center
    imageBadge.textColor = .white
    imageBadge.backgroundColor = UIColor.black.withAlphaComponent(0.55)
    imageBadge.layer.cornerRadius = 10
    imageBadge.layer.cornerCurve = .continuous
    imageBadge.clipsToBounds = true
    // GIF 角标样式（用户口径：无底纯白字 + 阴影，不要胶囊底）已收进 makeGifBadge()，见文件内。

    subPostsControl.addTarget(self, action: #selector(handleSubPosts), for: .touchUpInside)
    subPostsControl.isAccessibilityElement = true
    subPostsControl.accessibilityLabel = "查看楼中楼"
    subPostsControl.accessibilityHint = "打开这段对话"
    subPostsControl.accessibilityTraits = .button
    // 楼中楼预览框：整段收进一个浅底圆角矩形（取代旧版"逐条上方一条分隔线 +
    // 块顶一条 hairline"）。非交互：只垫在文字下面，点按仍归 subPostsControl。
    subPostsBox.isUserInteractionEnabled = false
    subPostsBox.isHidden = true
    subPostsBox.layer.cornerRadius = TiebaPostRowLayout.subPostBoxRadius
    subPostsBox.layer.cornerCurve = .continuous
    addSubview(subPostsBox)
    addSubview(subPostsControl)
    for _ in 0..<3 {
      let text = TiebaImmediateTextNode()
      // 楼中楼预览**两行截断**：maximumNumberOfLines + truncationType(.end) —— 与 plan 里的
      // measureBody(maxLines: 2) 同一口径（TextNode 自排自量，不再有第二套 TextKit 测量）。
      text.maximumNumberOfLines = 2
      text.truncationType = .end
      text.isUserInteractionEnabled = false
      addSubview(text)
      subPostTextNodes.append(text)
    }
    subPostsMoreLabel.font = TiebaPostRowLayout.moreFont
    subPostsMoreLabel.numberOfLines = 1
    addSubview(subPostsMoreLabel)

    addSubview(toolbarView)
    toolbarView.isHidden = true
    toolbarReplyLabel.font = TiebaPostRowLayout.replyCountFont
    toolbarReplyLabel.accessibilityTraits = .header
    toolbarReplyLabel.numberOfLines = 0
    // 标签与药丸挂在**行视图**上：plan 的 toolbarTextFrame/toolbarSeeLzFrame/
    // toolbarSortFrame 都是行坐标，挂进 toolbarView 会再叠一次 toolbarFrame 的
    // 偏移（整条只剩空底，用户实证"只看楼主那一行显示不出来"）。
    addSubview(toolbarReplyLabel)
    seeLzButton.titleLabel?.font = TiebaPostRowLayout.pillFont
    seeLzButton.layer.cornerCurve = .continuous
    seeLzButton.addTarget(self, action: #selector(handleToggleSeeLz), for: .touchUpInside)
    sortButton.titleLabel?.font = TiebaPostRowLayout.pillFont
    sortButton.layer.cornerCurve = .continuous
    // 排序药丸 = 菜单按钮：点一下弹三档直接选，不再"点好几次"循环（菜单在
    // updateToolbarPills 里按当前档位重建）。
    sortButton.showsMenuAsPrimaryAction = true
    addSubview(seeLzButton)
    addSubview(sortButton)
    installPressFeedback()
    installPointerInteractions()
  }

  private func installPointerInteractions() {
    pointerInteractions.append(TiebaPointerInteraction(
      view: likeControl,
      customInteractionView: likeIcon,
      style: .circle(nil)
    ))
    pointerInteractions.append(TiebaPointerInteraction(
      view: subPostsControl,
      customInteractionView: subPostsBox,
      style: .default
    ))
    let hoverControls: [UIView] = [menuButton, seeLzButton, sortButton]
    for control in hoverControls {
      pointerInteractions.append(TiebaPointerInteraction(view: control, style: .default))
    }
  }

  /// 行内可点击件统一“按下 0.94、松手弹簧收口”。只挂 UIControl 触摸事件，
  /// 不参与滚动路径，也不在 apply/layout 里创建动画。
  private func installPressFeedback() {
    let controls: [UIControl] = [likeControl, subPostsControl, menuButton, seeLzButton, sortButton]
    for control in controls {
      control.addTarget(self, action: #selector(handlePressDown(_:)), for: [.touchDown, .touchDragEnter])
      control.addTarget(
        self,
        action: #selector(handlePressUp(_:)),
        for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit]
      )
    }
  }

  /// 头像尺寸随行角色变化（主贴 40 / 回复 36）：TiebaForumAvatarView 的边长在
  /// init 里定死，尺寸变了只能重建（同一个 cell 复用成另一种行时才会发生）。
  private func configureAvatar(model: TiebaPostRowModel, frame: CGRect) {
    if avatarView?.bounds.width != frame.width {
      avatarView?.removeFromSuperview()
      let view = TiebaForumAvatarView(size: frame.width)
      insertSubview(view, belowSubview: avatarControl)
      avatarView = view
      avatarPointerInteraction = TiebaPointerInteraction(
        view: avatarControl,
        customInteractionView: view,
        style: .circle(nil)
      )
    }
    avatarView?.backgroundColor = model.palette.avatarFallback
    avatarView?.frame = frame
    avatarView?.configure(url: model.avatarURL?.absoluteString ?? "", initial: model.nameText)
  }

  private func layoutImages(model: TiebaPostRowModel, plan: TiebaPostRowPlan) {
    imageScrollView.isHidden = plan.imagesFrame == nil
    layoutImagePlaceholders(model: model, plan: plan)
    guard let frame = plan.imagesFrame, !model.imagesHidden else {
      imageBadge.isHidden = true
      return
    }
    imageScrollView.frame = frame
    // Issue #5：网格模式下这块不再是"横向带"，而是一张固定格子表——必须关掉自身滚动，
    // 否则在 cell 里上下拖图会先被这个内嵌滚动视图吃掉手势（外层列表不动，
    // 用户以为卡住了）。横排保持可滑。
    imageScrollView.isScrollEnabled = !plan.imagesGrid
    // 网格是不可滚的固定格子表：内容偏移必须归零，否则从横排切过来会带着
    // 上一次的偏移，看着像整块被裁掉一截。
    if plan.imagesGrid, imageScrollView.contentOffset != .zero {
      imageScrollView.contentOffset = .zero
    }
    // 挂载上限：网格与固定父楼一样，以**计划里实际排出来的格数**为准
    //（网格自己把上限收到 6，见 TiebaPostRowPlan）。
    let mountedCap = (plan.role == .context || plan.imagesGrid)
      ? max(plan.imageItemFrames.count, 1)
      : TiebaPostRowLayout.maxImages
    let shownCount = min(model.images.count, mountedCap)
    while imageViews.count > shownCount {
      let view = imageViews.removeLast()
      cancelRequest(for: view)
      view.prepareForGIFReuse()
      view.removeFromSuperview()
    }
    while imageViews.count < shownCount {
      let view = TiebaGIFImageView()
      view.contentMode = .scaleAspectFill
      // 圆角由图片管线烘焙进位图（见 tiebaPostLoadDisplayImage）：这里只留
      // cornerRadius 给占位底色，不再 clipsToBounds（否则每帧一次离屏合成）。
      // GIF 档例外：帧不烘焙圆角，tiebaLoadGifImage 里临时开 clipsToBounds。
      view.layer.cornerRadius = TiebaPostRowLayout.imageRadius
      view.layer.cornerCurve = .continuous
      view.isUserInteractionEnabled = true
      view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleImageTap(_:))))
      view.addInteraction(UIContextMenuInteraction(delegate: self))
      imageScrollView.addSubview(view)
      imageViews.append(view)
    }
    let scale = max(traitCollection.displayScale, 1)
    let single = model.images.count == 1
    for (index, view) in imageViews.enumerated() {
      guard index < shownCount else {
        view.isHidden = true
        // 在途请求一并取消（复用纪律，见 prepareForReuse）。
        cancelRequest(for: view)
        // prepareForGIFReuse() = 停表 + 真释放帧缓存 + 清 image：比老的 stopAnimatingGIF()
        // 多做"释放"这一步，而这里的语义正需要释放（视图要隐藏并换图）。
        view.prepareForGIFReuse()
        TiebaHeroTransition.clear(view)
        continue
      }
      view.isHidden = false
      view.frame = single
        ? CGRect(origin: .zero, size: frame.size)
        : (plan.imageItemFrames.indices.contains(index) ? plan.imageItemFrames[index] : .zero)
      view.tag = index
      // 进帖转场：主贴卡的第 1 张图与列表源图配对（其余不配，避免撞 id）。
      // 返回时它也是缩回目标——列表那边配对 id 由行模型驱动，两侧一致。
      if index == 0, let heroThreadId = model.heroThreadId {
        TiebaHeroTransition.markImage(view, threadId: heroThreadId)
      } else {
        TiebaHeroTransition.clear(view)
      }
      let image = model.images[index]
      view.backgroundColor = model.palette.placeholder
      if model.preferences.imageLoadType == "all_no" {
        // 不加载图片：停表 + 释放帧缓存 + 清图（老的 stopAnimatingGIF 只停表，帧还留着）。
        view.prepareForGIFReuse()
      } else {
        // 只**暂停**：新显示档还没到，先让上一帧留在屏幕上，避免中间空一帧闪一下
        // （老的 stopAnimatingGIF 也是这个语义：停表但保留当前帧）。帧缓存等到真正换图
        // （tiebaLoadGifImage / prepareForGIFReuse）时才释放。
        view.gifPlayer.stop()
        // 显示档 = 服务端 cdn_src（对 GIF 即 g=0 静态压缩档，真首帧几十 KB）；
        // 探测到 GIF 再拉 big_cdn_src 动图档起播（见 TiebaNuke「GIF 三档」注）。
        tiebaPostLoadDisplayImage(
          model.preferences.displayURL(for: image),
          targetSize: view.bounds.size,
          cornerRadius: TiebaPostRowLayout.imageRadius,
          scale: scale,
          into: view,
          transition: true
        )
        probeAndPlayGIF(
          candidates: TiebaPostRowText.gifProbeCandidates(image),
          naturalPixelSize: CGSize(width: image.width, height: image.height),
          view: view,
          model: model
        )
      }
      view.alpha = model.preferences.isNight && model.preferences.imageDarkenWhenNight ? 0.6 : 1
    }
    imageScrollView.contentSize = plan.imagesGrid
      ? CGSize(width: frame.width, height: frame.height)
      : CGSize(width: (plan.imageItemFrames.last?.maxX ?? frame.width), height: frame.height)
    // 超出挂载上限时的 +N 角标（末图右下角）；固定父楼只挂 4 格，计数也按 4 格算。
    if model.images.count > mountedCap, let lastFrame = plan.imageItemFrames.last {
      imageBadge.text = "+\(model.images.count - mountedCap)"
      imageBadge.isHidden = false
      if imageBadge.superview == nil { imageScrollView.addSubview(imageBadge) }
      imageBadge.frame = CGRect(x: lastFrame.maxX - 40, y: lastFrame.maxY - 32, width: 32, height: 22)
      imageScrollView.bringSubviewToFront(imageBadge)
    } else {
      imageBadge.isHidden = true
    }
    // GIF 角标由 probeAndPlayGIF 探测到动图后亮起（复用/换行先藏，见下行）。
    self.hideGifBadges()
  }

  /// 帖子页的 GIF 自动播放：HEAD 探测动图档（big_cdn_src，零流量）命中 → 拉
  /// 动图档（Gifu 逐帧）并亮角标。列表卡片（TiebaFeedRowView）同判定但只亮标
  /// 不播——播放入口按用户口径只在进帖与大图查看器。
  /// 帧重采样目标是「视图尺寸 与 源像素/屏幕 scale 取小」：Gifu 的帧位图 =
  /// 目标点尺寸 × 设备 scale，不加上界的话小源（540×960）会被上采样到 3×、
  /// 每帧 6MB+；缓冲窗 8 帧与查看器同口径（内存 = 单帧 × 8）。
  /// 每格一份探测代次（视图身份 → 代次）。
  /// 改前症状：行级单计数器被 layoutImages 循环里每张图各自自增 ⇒ N 图行只有**最后一格**的探测
  /// 回调能通过代次判定，其余格的 GIF 角标不亮、动画不起播。
  /// 改后行为：代次按格（视图）隔离，同格重配才作废旧探测；换行/复用时整表清空。
  private var gifProbeGenerations: [ObjectIdentifier: Int] = [:]

  /// - parameter candidates: GIF 判定候选链（动图档优先，见 TiebaPostRowText.gifProbeCandidates）。
  ///   探测命中的那个 URL 就是**播放源**——判定与播放必须同源：改动前固定拿 animatedURL
  ///   播放，而 animatedURL 在服务端没给动图档时会回落到显示档（对六成动图是静态 JPEG），
  ///   于是"角标亮了却不动"。现在候选链里谁被判定为动图，就播谁。
  private func probeAndPlayGIF(
    candidates: [URL?],
    naturalPixelSize: CGSize,
    view: TiebaGIFImageView,
    model: TiebaPostRowModel
  ) {
    let probeKey = ObjectIdentifier(view)
    let generation = (gifProbeGenerations[probeKey] ?? 0) + 1
    gifProbeGenerations[probeKey] = generation
    Task { [weak self, weak view] in
      guard let playURL = await TiebaNuke.firstGIFURL(among: candidates) else { return }
      // 身份判定用视图**强持有**的 model，不用 appliedModel（weak）：页缓存淘汰/整页重发
      // 会让 weak 引用变 nil，于是"nil !== model"被误判成"这行已经换内容"，
      // 探测结果被丢弃 → 角标不亮、动画不起播，且没有任何日志（本轮查到的静默路径之一）。
      guard let self, self.gifProbeGenerations[probeKey] == generation, self.model === model else { return }
      guard let view else { return }
      self.revealGifBadge(for: view)
      guard self.model?.preferences.imageLoadType != "all_no" else { return }
      let screenScale = view.traitCollection.displayScale > 0 ? view.traitCollection.displayScale : 3
      var target = view.bounds.size
      if naturalPixelSize.width > 1, naturalPixelSize.height > 1 {
        target.width = min(target.width, naturalPixelSize.width / screenScale)
        target.height = min(target.height, naturalPixelSize.height / screenScale)
      }
      tiebaLoadGifImage(
        playURL,
        targetSize: target,
        contentMode: .scaleAspectFill,
        frameBufferSize: 8,
        into: view,
        isStale: { [weak self] in self?.model !== model }
      )
    }
  }

  /// GIF 角标：白字 + 细黑描边，不再使用行内 shadow（本任务只允许 hero/context/chrome 有 elevation）。
  private func makeGifBadge() -> UILabel {
    let badge = UILabel()
    badge.attributedText = NSAttributedString(
      string: "GIF",
      attributes: [
        .font: UIFont.systemFont(ofSize: 11, weight: .semibold),
        .foregroundColor: UIColor.white,
        .strokeColor: UIColor.black.withAlphaComponent(0.55),
        .strokeWidth: -2,
      ]
    )
    badge.textAlignment = .center
    badge.isHidden = true
    return badge
  }

  private func hideGifBadges() {
    for badge in self.gifBadges.values {
      badge.isHidden = true
    }
  }

  /// GIF 角标挂到**该图自己**的右下角（[修复④a]：一图一标，挂在图上而不是行容器的坐标系里 ——
  /// 这样复用/换行/多图都不会互相覆盖，也不需要再 bringSubviewToFront）。
  private func revealGifBadge(for view: TiebaGIFImageView) {
    guard view.bounds.width > 1 else { return }
    let key = ObjectIdentifier(view)
    let badge: UILabel
    if let existing = self.gifBadges[key] {
      badge = existing
    } else {
      badge = self.makeGifBadge()
      self.gifBadges[key] = badge
      view.addSubview(badge)
    }
    badge.sizeToFit()
    badge.frame = CGRect(
      x: view.bounds.width - 8 - badge.bounds.width,
      y: view.bounds.height - 8 - badge.bounds.height,
      width: badge.bounds.width,
      height: badge.bounds.height
    )
    badge.isHidden = false
  }

  private func layoutImagePlaceholders(model: TiebaPostRowModel, plan: TiebaPostRowPlan) {
    while imagePlaceholderViews.count < plan.imagePlaceholderFrames.count {
      let view = TiebaPostPlaceholderView()
      addSubview(view)
      imagePlaceholderViews.append(view)
    }
    for (index, view) in imagePlaceholderViews.enumerated() {
      guard index < plan.imagePlaceholderFrames.count else {
        view.isHidden = true
        continue
      }
      view.isHidden = false
      view.frame = plan.imagePlaceholderFrames[index]
      view.configure(icon: "photo", text: "[图片]", palette: model.palette)
    }
  }

  private func layoutMedia(model: TiebaPostRowModel, plan: TiebaPostRowPlan) {
    if let video = model.video, let frame = plan.videoFrame {
      if videoView == nil {
        videoView = TiebaInlineVideoView()
        addSubview(videoView!)
      }
      videoView?.isHidden = false
      videoView?.frame = frame
      videoView?.configure(video: video, preferences: model.preferences)
      videoView?.applyPalette(model.palette)
    } else if let videoView {
      videoView.isHidden = true
      videoView.stopPlayback()
    }
    if let audio = model.audio, let frame = plan.audioFrame {
      if audioView == nil {
        audioView = TiebaAudioPillView()
        addSubview(audioView!)
      }
      audioView?.isHidden = false
      audioView?.frame = frame
      audioView?.configure(src: audio.src, duration: audio.duration, palette: model.palette)
    } else if let audioView {
      audioView.isHidden = true
      audioView.stopPlayback()
    }
  }

  private func layoutSubPosts(model: TiebaPostRowModel, plan: TiebaPostRowPlan) {
    guard let frame = plan.subPostsFrame else {
      subPostsControl.frame = .zero
      subPostsControl.accessibilityValue = nil
      subPostsBox.isHidden = true
      for node in subPostTextNodes { node.isHidden = true }
      subPostsMoreLabel.isHidden = true
      return
    }
    subPostsBox.isHidden = false
    subPostsBox.frame = plan.subPostsBoxFrame ?? .zero
    subPostsControl.frame = frame
    subPostsControl.accessibilityLabel = "查看楼中楼，共\(model.post.subPostNum)条"
    subPostsControl.accessibilityValue = nil
    subPostsControl.accessibilityHint = "打开这段对话"
    for (index, text) in subPostTextNodes.enumerated() {
      let hasPost = index < model.post.subPosts.count
      text.isHidden = !hasPost
      if hasPost, plan.subPostTextFrames.indices.contains(index) {
        let frame = plan.subPostTextFrames[index]
        text.frame = frame
        text.lineSpacing = plan.subPostLineSpacing
        text.attributedText = model.subPostTexts.indices.contains(index) ? model.subPostTexts[index] : nil
        // 两行截断：行数只看 maximumNumberOfLines = 2（与 measureBody 同口径）。
        _ = text.updateLayout(CGSize(width: frame.width, height: .greatestFiniteMagnitude))
      }
    }
    subPostsMoreLabel.font = TiebaPostRowLayout.moreFont
    subPostsMoreLabel.isHidden = plan.subPostsMoreFrame == nil
    if let moreFrame = plan.subPostsMoreFrame {
      subPostsMoreLabel.frame = moreFrame
      subPostsMoreLabel.text = model.post.subPostNum > model.post.subPosts.count
        ? "查看全部 \(model.post.subPostNum) 条回复"
        : (model.post.subPosts.isEmpty ? "查看 \(model.post.subPostNum) 条回复" : nil)
    }
  }

  private func layoutToolbar(model: TiebaPostRowModel, plan: TiebaPostRowPlan) {
    guard let frame = plan.toolbarFrame, let toolbar = model.toolbar else {
      // 三件内容已不在 toolbarView 里（见 buildSubviews），必须逐个收起：否则
      // 回收成回复行后，它们会留在上一次主贴行时的位置上。
      toolbarView.isHidden = true
      toolbarReplyLabel.isHidden = true
      seeLzButton.isHidden = true
      sortButton.isHidden = true
      return
    }
    toolbarView.isHidden = false
    toolbarReplyLabel.isHidden = false
    seeLzButton.isHidden = false
    sortButton.isHidden = false
    toolbarReplyLabel.font = TiebaPostRowLayout.replyCountFont
    seeLzButton.titleLabel?.font = TiebaPostRowLayout.pillFont
    sortButton.titleLabel?.font = TiebaPostRowLayout.pillFont
    toolbarView.frame = frame
    // hero 底部改为“conversation masthead”：无纸卡、无第二套玻璃，只保留
    // 大号回复计数 + 两枚轻量筛选胶囊；行底的克制 hairline 已完成分组。
    toolbarView.backgroundColor = .clear
    toolbarView.layer.cornerRadius = 0
    toolbarView.layer.cornerCurve = .continuous
    toolbarView.layer.borderWidth = 0
    toolbarView.layer.borderColor = UIColor.clear.cgColor
    if let textFrame = plan.toolbarTextFrame {
      toolbarReplyLabel.frame = textFrame
      let reply = TiebaForumFormat.count(toolbar.replyNum)
      toolbarReplyLabel.attributedText = TiebaPostRowView.toolbarReplyText(
        count: reply,
        pageLabel: toolbar.pageLabel,
        palette: model.palette
      )
      toolbarReplyLabel.accessibilityLabel = "全部回复，共\(toolbar.replyNum)条"
    }
    if let lzFrame = plan.toolbarSeeLzFrame { seeLzButton.frame = lzFrame }
    if let sortFrame = plan.toolbarSortFrame { sortButton.frame = sortFrame }
    updateToolbarPills(animateSelection: true)
  }

  /// 只重贴工具栏（翻页页码变化）：正文/图片/行高都没变，走这条就不用重排一次
  /// CoreText、也不用重新测量（TiebaThreadViewController.rebuild 调用）。
  func refreshToolbar() {
    guard let model else { return }
    layoutToolbar(model: model, plan: model.plan)
  }

  private func updateToolbarPills(
    animateSelection: Bool = false,
    observeState: Bool = true
  ) {
    guard let toolbar = model?.toolbar else { return }
    let previousSeeLz = observeState ? observedToolbarSeeLz : nil
    let previousSort = observeState ? observedToolbarSort : nil
    if observeState {
      observedToolbarSeeLz = toolbar.seeLz
      observedToolbarSort = toolbar.sort
    }
    configurePill(seeLzButton, title: "只看楼主", selected: toolbar.seeLz, palette: palette)
    // 排序药丸：离开默认档（热门）才加亮，箭头表明点开是三档菜单。
    let selected = toolbar.sort != .hot
    let color = selected ? palette.primary : TiebaAccessibleColors.metadata
    let chevron = UIImage(
      systemName: "chevron.down",
      withConfiguration: TiebaPostRowLayout.pillChevronConfig
    )?.withTintColor(color, renderingMode: .alwaysOriginal)
    sortButton.setImage(chevron, for: .normal)
    sortButton.semanticContentAttribute = .forceRightToLeft
    configurePill(sortButton, title: toolbar.sort.title, selected: selected, palette: palette)
    sortButton.menu = UIMenu(children: TiebaThreadSort.allCases.map { option in
      UIAction(title: option.title, state: option == toolbar.sort ? .on : .off) { [weak self] _ in
        self?.onEvent?(.selectSort(option))
      }
    })
    seeLzButton.accessibilityLabel = "只看楼主"
    seeLzButton.accessibilityValue = toolbar.seeLz ? "已开启" : "已关闭"
    seeLzButton.accessibilityTraits = toolbar.seeLz ? [.button, .selected] : .button
    sortButton.accessibilityLabel = "回复排序"
    sortButton.accessibilityValue = toolbar.sort.title
    sortButton.accessibilityHint = "打开热门、正序、倒序菜单"
    guard animateSelection, window != nil else { return }
    if let previousSeeLz, previousSeeLz != toolbar.seeLz {
      TiebaInteractiveMotion.pulse(seeLzButton, from: 0.94)
    }
    if let previousSort, previousSort != toolbar.sort {
      TiebaInteractiveMotion.pulse(sortButton, from: 0.94)
    }
  }

  private func configurePill(_ button: UIButton, title: String, selected: Bool, palette: TiebaFeedRowPalette) {
    button.setTitle(title, for: .normal)
    let titleColor = selected ? palette.primary : TiebaAccessibleColors.metadata
    button.setTitleColor(titleColor, for: .normal)
    button.setTitleColor(titleColor, for: .highlighted)
    button.layer.borderWidth = 0
    button.layer.borderColor = UIColor.clear.cgColor
    let background = selected
      ? palette.primary.withAlphaComponent(0.10)
      : UIColor.quaternarySystemFill
    if let pill = button as? TiebaPostPillButton {
      button.backgroundColor = .clear
      pill.setPill(background: background)
    } else {
      button.backgroundColor = background
    }
  }

  private func loadEmoticonsIfNeeded(model: TiebaPostRowModel) {
    let missing = model.missingEmoticons
    guard !missing.isEmpty else { return }
    let key = model.pageKey
    let index = model.index
    TiebaEmoticonCache.shared.load(missing) { [weak self] in
      guard let self, let current = self.model, current.pageKey == key, current.index == index else { return }
      // 一行有 N 个表情就回调 N 次；模型侧缓存过之后拿到的是同一份对象，
      // 这里按对象身份再挡一次，只重排一次（列表里最贵的一笔就是正文排版）。
      let texts = current.upgradeTexts()
      if self.assignedText !== texts.text {
        self.assignedText = texts.text
        self.textNode.attributedText = texts.text
        // 表情是附件（尺寸由 run delegate 定），换图不改行高，但必须重排一次才会重画。
        if self.textNode.bounds.width > 0 {
          _ = self.textNode.updateLayout(CGSize(width: self.textNode.bounds.width, height: .greatestFiniteMagnitude))
        }
        self.installTextAccessibility()
      }
      for (idx, node) in self.subPostTextNodes.enumerated() where !node.isHidden {
        node.attributedText = texts.subs.indices.contains(idx) ? texts.subs[idx] : nil
        if node.bounds.width > 0 {
          _ = node.updateLayout(CGSize(width: node.bounds.width, height: .greatestFiniteMagnitude))
        }
      }
    }
  }

  // MARK: 交互

  private func pressFeedbackView(for control: UIControl) -> UIView {
    // 透明 UIControl 本体不可见：反馈落在真正可见的图标/预览上。
    if control === subPostsControl { return subPostsBox }
    if control === likeControl { return likeIcon }
    return control
  }

  @objc private func handlePressDown(_ control: UIControl) {
    TiebaInteractiveMotion.press(pressFeedbackView(for: control), pressed: true)
  }

  @objc private func handlePressUp(_ control: UIControl) {
    TiebaInteractiveMotion.press(pressFeedbackView(for: control), pressed: false)
  }

  @objc private func handleAvatar() {
    TiebaSceneHaptics.fire("press")
    onEvent?(.avatar)
  }

  @objc private func handleAgree() {
    TiebaSceneHaptics.fire("like")
    onEvent?(.agree)
  }

  @objc private func handleSubPosts() {
    TiebaSceneHaptics.fire("press")
    onEvent?(.subPosts)
  }

  @objc private func handleToggleSeeLz() {
    TiebaSceneHaptics.fire("toggle")
    onEvent?(.toggleSeeLz)
  }

  @objc private func handleImageTap(_ gesture: UITapGestureRecognizer) {
    guard let view = gesture.view as? UIImageView else { return }
    TiebaSceneHaptics.fire("press")
    emitImageOpen(index: view.tag, rect: view.convert(view.bounds, to: nil))
  }

  /// 图片打开出口（点图与长按预览提交共用）：rect = 该图当前窗口矩形，宿主收到
  /// 后自己开查看器（本行不开）。长按提交在提交当刻取几何、收起动画完成后再发。
  private func emitImageOpen(index: Int, rect: CGRect) {
    onEvent?(.image(index: index, rect: rect))
  }

  // MARK: 图片几何查询（查看器退出重算；本视图仍不装任何额外手势）

  /// 行坐标下第 index 张图的当前可见矩形：frame 在 imageScrollView 内容坐标，
  /// convert 自动吃掉 contentOffset，再与滚动视口求交。nil = 越界/未挂载/
  /// 图片区隐藏/完全滑出视口，调用方据此走框架 Fade。
  func imageRect(at index: Int) -> CGRect? {
    guard let model, !model.imagesHidden, !imageScrollView.isHidden,
          model.images.indices.contains(index),
          imageViews.indices.contains(index) else { return nil }
    let imageView = imageViews[index]
    guard imageView.tag == index, !imageView.isHidden,
          imageView.bounds.width > 1, imageView.bounds.height > 1 else { return nil }
    let rowRect = imageView.convert(imageView.bounds, to: self)
    let viewport = imageScrollView.convert(imageScrollView.bounds, to: self)
    let visible = rowRect.intersection(viewport)
    guard !visible.isNull, visible.width >= 2, visible.height >= 2 else { return nil }
    return visible
  }

  @objc private func handleMenu() {
    TiebaSceneHaptics.fire("sheet-present")
    let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
    sheet.addAction(UIAlertAction(title: "复制内容", style: .default) { [weak self] _ in
      self?.onEvent?(.copyContent)
    })
    sheet.addAction(UIAlertAction(title: "分享", style: .default) { [weak self] _ in
      self?.onEvent?(.share)
    })
    sheet.addAction(UIAlertAction(title: "复制链接", style: .default) { [weak self] _ in
      self?.onEvent?(.copyLink)
    })
    sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
    guard let presenter = TiebaViewHosts.viewController(for: self) else { return }
    if let popover = sheet.popoverPresentationController {
      popover.sourceView = menuButton
      popover.sourceRect = menuButton.bounds
      popover.permittedArrowDirections = .up
    }
    presenter.present(sheet, animated: true)
  }

  // MARK: 工具

  private static func toolbarReplyText(count: String, pageLabel: String?, palette: TiebaFeedRowPalette) -> NSAttributedString {
    let result = NSMutableAttributedString(
      string: "全部回复",
      attributes: [
        .font: TiebaPostRowLayout.replyCountFont,
        .foregroundColor: palette.text,
      ]
    )
    result.append(NSAttributedString(
      string: " · \(count)",
      attributes: [
        .font: TiebaPostRowLayout.replyCountFont,
        .foregroundColor: palette.primary,
      ]
    ))
    if let pageLabel, pageLabel.isEmpty == false {
      result.append(NSAttributedString(
        string: " · \(pageLabel)",
        attributes: [
          .font: TiebaPostRowLayout.metaFont,
          .foregroundColor: TiebaAccessibleColors.metadata,
        ]
      ))
    }
    return result
  }
}

/// 视觉可小于 44 的阅读行控件（头像等）：命中框扩到 44×44，布局帧不变。
final class TiebaPostHitControl: UIControl {
  var minimumHitSide: CGFloat = 44

  override init(frame: CGRect) {
    super.init(frame: frame)
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
  }

  var hitFrame: CGRect {
    let dx = max((minimumHitSide - bounds.width) / 2, 0)
    let dy = max((minimumHitSide - bounds.height) / 2, 0)
    return bounds.insetBy(dx: -dx, dy: -dy)
  }

  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    hitFrame.contains(point)
  }
}

/// 工具栏胶囊：frame 是 ≥44pt 的命中框，内部 pill 保持 30pt 视觉高度。
final class TiebaPostPillButton: UIButton {
  private let pill = UIView()

  override init(frame: CGRect) {
    super.init(frame: frame)
    pill.isUserInteractionEnabled = false
    pill.layer.cornerCurve = .continuous
    insertSubview(pill, at: 0)
  }

  convenience init(type: UIButton.ButtonType) {
    self.init(frame: .zero)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  func setPill(background: UIColor) {
    pill.backgroundColor = background
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let fontLine = titleLabel?.font.lineHeight ?? 16
    let visualHeight = min(bounds.height, max(30, ceil(fontLine) + 10))
    pill.frame = CGRect(
      x: 0,
      y: (bounds.height - visualHeight) / 2,
      width: bounds.width,
      height: visualHeight
    )
    pill.layer.cornerRadius = visualHeight / 2
  }
}

// MARK: - 正文交互（链接点击 + 按压高亮 + 伪装链接确认）
//
// 显示 = TextNode（自绘）；交互全在本文件：命中用 layout.attributesAtPoint、高亮矩形用 layout.rangeRects，
// 与绘制读同一份 cachedLayout（不再有「系统排版 + 自绘矩形」的亚像素差）。打开仍走 onEvent（.user / .link），
// 伪装链接确认仍走 TiebaTextLinkSafety —— 与旧 UITextView 路径同一套判据。

extension TiebaPostRowView {
  /// 轻点：命中链接就打开；点在普通文字上什么也不做（选择层自己收选择）。
  @objc private func handleTextTap(_ recognizer: UITapGestureRecognizer) {
    let point = recognizer.location(in: textNode)
    guard let link = linkAttribute(at: point) else { return }
    openLink(url: link.url, displayText: link.displayText)
  }

  /// 按住链接：出跨行高亮（拖动时跟着换成手指下的那条），抬手才打开；取消/移开立即收高亮。
  @objc private func handleLinkPress(_ recognizer: UILongPressGestureRecognizer) {
    let point = recognizer.location(in: textNode)
    switch recognizer.state {
    case .began, .changed:
      guard let link = linkAttribute(at: point) else {
        clearLinkHighlight()
        return
      }
      pressedLink = (url: link.url, displayText: link.displayText)
      showLinkHighlight(range: link.range)
    case .ended:
      let link = linkAttribute(at: point)
      let pressed = pressedLink
      clearLinkHighlight()
      // 只有「按下时那条」和「抬手时那条」是同一条才打开：滑到别的链接上不该误开。
      if let link, let pressed, link.url == pressed.url {
        openLink(url: link.url, displayText: link.displayText)
      }
    default:
      clearLinkHighlight()
    }
  }

  /// 命中测试：该点上的 .link 属性 → (真实地址, 屏上显示文字, 属性区间)。三样同出一份 layout，
  /// 显示文字就是用户看到的那段 —— 伪装地址检查靠它。
  private func linkAttribute(at point: CGPoint) -> (url: String, displayText: String, range: NSRange)? {
    guard
      let layout = textNode.cachedLayout,
      let string = layout.attributedString,
      let (index, attributes) = layout.attributesAtPoint(point, orNearest: false),
      let value = attributes[.link]
    else { return nil }
    let url = (value as? URL)?.absoluteString ?? (value as? String) ?? ""
    guard !url.isEmpty else { return nil }
    var linkRange: NSRange?
    string.enumerateAttribute(.link, in: NSRange(location: 0, length: string.length), options: []) { value, range, stop in
      guard value != nil, NSLocationInRange(index, range) else { return }
      linkRange = range
      stop.pointee = true
    }
    guard let linkRange else { return nil }
    return (url, (string.string as NSString).substring(with: linkRange), linkRange)
  }

  /// 打开：tieba-native://user → 用户页；tieba-native://link → 外链（先做伪装地址确认）；其余原样外开。
  private func openLink(url: String, displayText: String) {
    guard let parsed = URL(string: url) else { return }
    let components = URLComponents(url: parsed, resolvingAgainstBaseURL: false)
    let query = { (name: String) -> String in
      components?.queryItems?.first(where: { $0.name == name })?.value ?? ""
    }
    switch components?.host {
    case "user":
      let uid = query("uid")
      guard !uid.isEmpty else { return }
      onEvent?(.user(uid))
    case "link":
      let raw = query("url")
      guard !raw.isEmpty else { return }
      // [接线 URL 安全] 显示文字与真实地址不一致就先确认（典型：真实地址里塞 U+202E 双向覆盖，
      // 屏幕上显示成另一个后缀）。一致的链接直接放行，行为与旧路径相同。
      let fullText = textNode.attributedText?.string ?? ""
      if let concealed = TiebaTextLinkSafety.concealedAddress(url: raw, displayText: displayText, fullText: fullText) {
        TiebaTextLinkSafety.confirm(
          address: concealed,
          presenter: TiebaViewHosts.viewController(for: self)
        ) { [weak self] in
          self?.onEvent?(.link(raw))
        }
      } else {
        onEvent?(.link(raw))
      }
    default:
      onEvent?(.link(url))
    }
  }

  /// 链接按压高亮：矩形取自 layout.rangeRects(in:) —— 跨行链接会给多段矩形，高亮带因此连续。
  private func showLinkHighlight(range: NSRange) {
    guard let rects = textNode.cachedLayout?.rangeRects(in: range)?.rects, !rects.isEmpty else { return }
    linkHighlightNode.updateRects(rects, color: palette.primary.withAlphaComponent(0.12))
    linkHighlightNode.isHidden = false
  }

  private func clearLinkHighlight() {
    pressedLink = nil
    linkHighlightNode.isHidden = true
  }

  /// 选择菜单：交给系统的 UIEditMenuInteraction 呈现（与系统文本框同一套观感），菜单项由选择层给。
  private func presentSelectionMenu(on anchor: UIView, rect: CGRect, items: [TiebaTextSelectionMenuItem]) {
    selectionMenu = UIMenu(children: items.map { item in
      UIAction(title: item.title) { _ in item.action() }
    })
    // anchor 就是交互挂在的选择层；交互在装配期已 add（见 buildSubviews），这里只负责弹。
    // 矩形 rect 也在选择层坐标里（的选择高亮矩形），present 时才 add 有注册时序风险。
    selectionMenuInteraction?.presentEditMenu(
      with: UIEditMenuConfiguration(identifier: nil, sourcePoint: CGPoint(x: rect.midX, y: rect.midY))
    )
  }

  /// 菜单动作：拷贝走 TiebaClipboard、分享走 TiebaShareSheet、查询走系统词典 —— 全是系统件。
  private func performSelectionAction(string: NSAttributedString, action: TiebaTextSelectionAction) {
    switch action {
    case .copy:
      TiebaClipboard.setString(string.string)
    case .share:
      guard let presenter = TiebaViewHosts.viewController(for: self) else { return }
      TiebaShareSheet.present(text: string.string, from: presenter)
    case .lookup:
      guard let presenter = TiebaViewHosts.viewController(for: self), !string.string.isEmpty else { return }
      presenter.present(UIReferenceLibraryViewController(term: string.string), animated: true)
    case .translate, .quote:
      // 这两项在选择层里没开（buildSubviews 的 enableTranslate / enableQuote = false），不会到达。
      break
    }
  }

  /// 覆盖层与正文同框；换模型/换宽后旧选择矩形已过期 → 一并收掉选择与高亮。
  private func layoutTextOverlays() {
    // 改前症状：三个覆盖层用的是 textNode.**bounds**（原点 0,0）而不是它在行里的 frame ⇒
    // 选择层/链接高亮层/无障碍层全部贴在行左上角：正文上长按打不到选择层（弹不出编辑菜单）、
    // 链接点不到、高亮画在错位置。
    // 改后行为：与正文**同框**（覆盖层局部坐标 = 正文局部坐标，选择矩形正是按它算的）。
    linkHighlightNode.frame = textNode.frame
    textAccessibilityOverlay.frame = textNode.frame
    textSelectionNode?.frame = textNode.frame
    textSelectionNode?.cancelSelection()
    clearLinkHighlight()
  }

  /// 链接的无障碍元素：VoiceOver 逐个聚焦、读出屏上文字、双击走同一条打开路径（含伪装地址确认）。
  /// 正文本体由 textNode 自己作为元素（label = 全文），链接挂在与它同框的透明层上。
  private func installTextAccessibility() {
    guard let layout = textNode.cachedLayout else { return }
    textNode.isAccessibilityElement = true
    textNode.accessibilityLabel = textNode.attributedText?.string
    textNode.accessibilityTraits = .staticText
    TiebaTextAccessibility.install(on: textAccessibilityOverlay, layout: layout) { [weak self] url, displayText in
      self?.openLink(url: url, displayText: displayText)
    }
  }
}

extension TiebaPostRowView: UIGestureRecognizerDelegate {
  /// 链接按压「只按在链接上」才成立：不在链接上直接判失败。
  /// 改前症状：`UILongPressGestureRecognizer(minimumPressDuration: 0.1)` 在任何位置都会 began，
  /// UIKit 的默认裁决随即取消同一视图上仍是 .possible 的选择手势（touchesCancelled）⇒
  /// 长按正文永远走不到 0.3s 的选词，编辑菜单弹不出来。
  /// 改后行为：非链接处该识别器失败，选择手势照常计时；链接处仍按原语义出高亮 + 抬手打开。
  // `UIView` 自己就声明了 `gestureRecognizerShouldBegin`（UIKit 给的默认实现），
  // 子类扩展里再声明同名方法必须写 `override`，否则 Swift 6 直接报错。
  override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
    guard recognizer === linkPressRecognizer else { return true }
    return linkAttribute(at: recognizer.location(in: textNode)) != nil
  }
}

extension TiebaPostRowView: @MainActor UIEditMenuInteractionDelegate {
  func editMenuInteraction(
    _ interaction: UIEditMenuInteraction,
    menuFor configuration: UIEditMenuConfiguration,
    suggestedActions: [UIMenuElement]
  ) -> UIMenu? {
    selectionMenu ?? UIMenu(children: suggestedActions)
  }
}
//
// 正文与楼中楼现在都由 TextNode 渲染（textNode / subPostTextNodes），系统 UITextView / UILabel 退场。
// 四层的接法见 buildSubviews：文本 → 链接按压高亮（TiebaLinkHighlightingNode）→ 无障碍元素层
//（TiebaTextAccessibility）→ 选择层（TiebaTextSelectionNode：长按选词 / 拖手柄 / 编辑菜单）。
// 三者都读 textNode.cachedLayout，几何与绘制同源。
// MARK: - 图片长按菜单（保存照片 / 分享照片，原 PostImageContextMenu）

extension TiebaPostRowView: UIContextMenuInteractionDelegate {
  func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    configurationForMenuAtLocation location: CGPoint
  ) -> UIContextMenuConfiguration? {
    // [移植 P0] 惯性滚动中长按一律不成立。
    // 本仓列表是页级 reload + 翻页模型：减速中手指压在 A 行，但 cell 可能已被
    // 复用/换页成 B 行 → 菜单会落到错的楼层。移植自上游
    // ContextUI/Sources/PeekControllerGestureRecognizer.swift:14-25，
    // 见 TiebaDecelerationGuard.swift。
    if let host = interaction.view,
       !TiebaDecelerationGuard.shouldAllowLongPress(at: location, in: host) {
      return nil
    }
    guard let model, let view = interaction.view as? UIImageView,
          model.images.indices.contains(view.tag) else { return nil }
    let image = model.images[view.tag]
    // 保存/分享仍用原图档（originSrc）；预览只显示压缩档（src），产品要求。
    let raw = image.originSrc.isEmpty ? image.src : image.originSrc
    let previewUrl = image.src.isEmpty ? image.originSrc : image.src
    guard !raw.isEmpty, !previewUrl.isEmpty else { return nil }
    // 首帧 = 被长按那格屏上已渲染的位图；无图/空 bounds 就传 nil，由预览控制器
    // 自行按压缩档下载（别拿占位底色当首帧造图）。
    var snapshot: UIImage?
    if view.image != nil, view.bounds.width > 0, view.bounds.height > 0 {
      snapshot = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
        view.drawHierarchy(in: view.bounds, afterScreenUpdates: false)
      }
    }
    let previewProvider: UIContextMenuContentPreviewProvider = {
      TiebaPhotoPreviewViewController(
        initialImage: snapshot,
        fullUrl: previewUrl,
        pixelWidth: image.width,
        pixelHeight: image.height
      )
    }
    return UIContextMenuConfiguration(identifier: nil, previewProvider: previewProvider) { [weak self] _ in
      let save = UIAction(
        title: "保存照片",
        image: UIImage(systemName: "square.and.arrow.down")
      ) { _ in
        TiebaFeedImageActions.save(
          url: raw,
          forumName: model.forumName,
          presenter: self.flatMap { TiebaViewHosts.viewController(for: $0) }
        )
      }
      let share = UIAction(
        title: "分享照片",
        image: UIImage(systemName: "square.and.arrow.up")
      ) { _ in
        guard let self, let presenter = TiebaViewHosts.viewController(for: self) else { return }
        TiebaFeedImageActions.share(
          url: raw,
          forumName: model.forumName,
          presenter: presenter,
          // sourceRect 相对 presenter.view（TiebaShareSheet 的 popover 契约）；
          // 旧写法把图片 bounds 当行坐标转换，多图格锚点会落到行左上角。
          sourceRect: view.convert(view.bounds, to: presenter.view)
        )
      }
      return UIMenu(children: [save, share])
    }
  }

  /// 升起动画锚点 = 被长按的图片格（本行 delegate 是整行，不能用 self，否则提起
  /// 整卡）。方法名一个字都不能简写/错位：简写版编译只警告、系统永远不会调用。
  /// 两个协议名都给（旧名 iOS 16 起标废弃，但 UIKitCore 里新旧选择器都还在被
  /// 引用，真机上只实现一个可能不被调），两个入口落到同一份实现。
  private func tiebaHighlightPreview(_ interaction: UIContextMenuInteraction) -> UITargetedPreview? {
    guard let view = interaction.view as? UIImageView, view.tiebaIsOnScreen else { return nil }
    return UITargetedPreview(view: view)
  }

  func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    configuration: UIContextMenuConfiguration,
    highlightPreviewForItemWithIdentifier identifier: any NSCopying
  ) -> UITargetedPreview? {
    tiebaHighlightPreview(interaction)
  }

  func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    configuration: UIContextMenuConfiguration,
    dismissalPreviewForItemWithIdentifier identifier: any NSCopying
  ) -> UITargetedPreview? {
    nil
  }

  func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    previewForHighlightingMenuWithConfiguration configuration: UIContextMenuConfiguration
  ) -> UITargetedPreview? {
    tiebaHighlightPreview(interaction)
  }

  /// 收起动画不飞回（与信息流一致）。
  func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    previewForDismissingMenuWithConfiguration configuration: UIContextMenuConfiguration
  ) -> UITargetedPreview? {
    nil
  }

  /// 菜单升起瞬间的「弹出大图」触觉（原 RN playImageLiftHaptic，与信息流一致）。
  func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    willDisplayMenuFor configuration: UIContextMenuConfiguration,
    animator: UIContextMenuInteractionAnimating?
  ) {
    TiebaSceneHaptics.playImageLift()
  }

  /// 点长按预览 = 提交：收起动画走完再发图片打开事件（与点图共用 emitImageOpen；
  /// 菜单还在时开查看器会与收起动画时序打架）。几何在提交当刻取，与点图同式。
  func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    willPerformPreviewActionForMenuWith configuration: UIContextMenuConfiguration,
    animator: any UIContextMenuInteractionCommitAnimating
  ) {
    guard let view = interaction.view as? UIImageView else { return }
    let index = view.tag
    let rect = view.convert(view.bounds, to: nil)
    animator.addCompletion { [weak self] in
      self?.emitImageOpen(index: index, rect: rect)
    }
  }
}

// MARK: - 找宿主 VC / 视图

enum TiebaViewHosts {
  @MainActor
  static func viewController(for view: UIView) -> UIViewController? {
    var responder: UIResponder? = view
    while let current = responder {
      if let controller = current as? UIViewController { return controller }
      responder = current.next
    }
    return nil
  }
}
