// 吧页滚动头（原 src/components/forum/{ForumTabHeader,ForumSortBar}.tsx 的原生等价）：
// 吧名片卡片 + 热门/最新/精品分段 + 最新排序行 / 精品分类行，整体挂在列表的
// top boundary 上随列表滚动。交互经 onAction 外传（动作 = TiebaForumHeaderAction，
// 列表发 headerAction 事件；avatar 的测量矩形走 payload，见协议约定）。
import UIKit

/// 吧页头动作（原字符串动作名的类型化）。
public enum TiebaForumHeaderAction {
  case card
  /// 吧头像：转场矩形是视图测量值，走 onAction 的 payload 字典（frameX/Y/W/H）。
  case avatar
  case follow
  case sign
  case segment(index: Int)
  case sort(sortType: Int)
  case clearClassify
  case classifyPicker
}

final class TiebaForumHeaderView: UIView, TiebaKindListHeaderView {
  var onAction: ((TiebaKindListHeaderAction, [String: Any]) -> Void)?

  private var spec: [String: Any] = [:]
  private var palette: TiebaSimpleRowPalette = .default
  private var heightCache: (width: CGFloat, height: CGFloat)?

  // 吧名片（头像 + 标题列 + 关注/签到按钮行 = 与用户主页共用的行几何）
  private let root = UIStackView()
  private let card = UIView()
  private let cardStack = UIStackView()
  private let headerRow = TiebaAvatarHeaderRow(
    avatarSize: 52, avatarSpacing: 12, columnSpacing: 12, titleSpacing: 3
  )
  private let nameLabel = UILabel()
  private let levelBadge = TiebaMemberBadgeLabel()
  private let metaLabel = UILabel()
  private let metaRow = UIStackView()
  private let followButton = UIButton(type: .system)
  private let followedChip = UIButton(type: .system)
  private let signButton = UIButton(type: .system)
  private let signedChip = UIButton(type: .system)
  private let levelRow = UIStackView()
  private let levelTrack = UIView()
  private let levelFill = UIView()
  private let levelLabel = UILabel()
  private let introLabel = UILabel()
  private let introWrap = UIView()
  // 分段 + 排序/分类行
  /// 分段 = TiebaTabSelector：选中/未选中两份预排版文本按 fraction 交叉淡化 + 指示器跨项
  /// 矩形 lerp（见 UI/Components/TiebaTabSelector.swift）。系统 chrome（材质/圆角/命中/无障碍）不变。
  private let segment = TiebaTabSelector(items: ["热门", "最新", "精品"])
  /// 分段的外层中性底：只用来托住系统分段控件，形成“名片 → 分段 → 筛选”的层级；
  /// 不是玻璃，也不在滚动中加材质/阴影。
  private let segmentSurface = UIView()
  private let segmentHitView = UIControl()
  private let axSegmentStack = UIStackView()
  private var axSegmentButtons: [UIButton] = []
  private let axActionStack = UIStackView()
  private let sortRow = UIStackView()
  private let sortSpacer = UIView()
  private let sortButton = UIButton(type: .system)
  private let classifyRow = UIStackView()
  private let classifyChip = UIButton(type: .system)
  private let classifyButton = UIButton(type: .system)
  private let classifySpacer = UIView()
  /// 进度条填充宽约束（按比例；数据变化时重建）。
  private var levelFillWidth: NSLayoutConstraint?
  private var axMetaWidthConstraint: NSLayoutConstraint?

  private var avatar: TiebaForumAvatarView { headerRow.avatarView }
  private var titleColumn: UIStackView { headerRow.titleColumn }
  private var buttonRow: UIStackView { headerRow.actionRow }

  init(spec: [String: Any]) {
    self.spec = spec
    super.init(frame: .zero)
    backgroundColor = .clear
    isOpaque = false
    build()
    applySpec()
    // Reduce Motion 可在页面存活期间切换：选择器式观察者在 dealloc 时自动注销。
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleReduceMotionStatusChange),
      name: UIAccessibility.reduceMotionStatusDidChangeNotification,
      object: nil
    )
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func applyPalette(_ palette: TiebaSimpleRowPalette) {
    guard palette != self.palette else { return }
    self.palette = palette
    applySpec()
  }

  /// 数据落地只更新字段，不换视图（关注/签到后重建会让展开中的菜单被顶掉，
  /// 也白白重跑一次 systemLayoutSizeFitting）。
  func update(spec: [String: Any]) {
    self.spec = spec
    applySpec()
  }

  /// 卡片内文本可用宽 = 页头宽 − root 左右 12 − 卡片内边距 14。
  private static func textWidth(forHeaderWidth width: CGFloat) -> CGFloat {
    max(width - 52, 1)
  }

  /// 页头高 = 该宽度下的自适应内容高（缓存；宽度变化即失效）。
  func headerHeight(forWidth width: CGFloat) -> CGFloat {
    if let cache = heightCache, cache.width == width { return cache.height }
    // 多行标签先钉换行宽度再拟合：拟合趟与最终布局趟的换行宽度不一致时会差一整行
    //（全仓不设 preferredMaxLayoutWidth 时这是默认状态），而宿主会把差额当空白
    // 分给页头里的某一行（用户 2026-09-17 报"按钮/进度条上下很多空白"）。
    introLabel.preferredMaxLayoutWidth = Self.textWidth(forHeaderWidth: width)
    let target = CGSize(width: width, height: UIView.layoutFittingCompressedSize.height)
    let height = ceil(
      systemLayoutSizeFitting(
        target,
        withHorizontalFittingPriority: .required,
        verticalFittingPriority: .fittingSizeLevel
      ).height
    )
    heightCache = (width, height)
    return height
  }

  // MARK: - 构建

  private func build() {
    root.axis = .vertical
    root.spacing = 0
    root.isLayoutMarginsRelativeArrangement = true
    root.layoutMargins = UIEdgeInsets(top: 0, left: 10, bottom: 2, right: 10)
    // 关键：页头挂在全屏列表顶部，"安全区顶部"那段空白由 contentInset.top 承担。
    // 不关这个开关，栈的 layoutMargins.top(0) 会被自动抬进安全区（实测 +59pt），
    // 测量趟与布局趟拿到的安全区不同就出现幻影高度差——差额被 .fill 栈分给某一行，
    // 表现成"排序按钮/等级进度条上下多出一片空白"（用户 2026-09-18 报）。
    root.insetsLayoutMarginsFromSafeArea = false
    root.translatesAutoresizingMaskIntoConstraints = false
    addSubview(root)
    NSLayoutConstraint.activate([
      root.leadingAnchor.constraint(equalTo: leadingAnchor),
      root.trailingAnchor.constraint(equalTo: trailingAnchor),
      root.topAnchor.constraint(equalTo: topAnchor),
      root.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    // ── 吧名片：白色内容卡只用柔和 elevation 分层，没有深色描边 ──
    card.backgroundColor = TiebaAccessibleColors.elevatedSurface
    card.layer.cornerRadius = TiebaAccessibleColors.surfaceRadius
    card.layer.cornerCurve = .continuous
    card.layer.borderWidth = 0
    card.layer.shadowColor = UIColor.black.cgColor
    card.layer.shadowOpacity = 0.095
    card.layer.shadowRadius = 20
    card.layer.shadowOffset = CGSize(width: 0, height: 8)
    cardStack.axis = .vertical
    cardStack.spacing = 0
    cardStack.translatesAutoresizingMaskIntoConstraints = false
    card.addSubview(cardStack)
    NSLayoutConstraint.activate([
      cardStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
      cardStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
      cardStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
      cardStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
    ])
    root.addArrangedSubview(card)
    root.setCustomSpacing(10, after: card)

    avatar.isUserInteractionEnabled = true
    avatar.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleAvatarTap)))
    avatar.setContentHuggingPriority(.required, for: .horizontal)
    avatar.setContentCompressionResistancePriority(.required, for: .horizontal)

    titleColumn.isUserInteractionEnabled = true
    titleColumn.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleCardTap)))
    nameLabel.font = TiebaSimpleText.font(size: 24, weight: .semibold)
    nameLabel.numberOfLines = 1
    nameLabel.lineBreakMode = .byTruncatingTail
    metaLabel.font = TiebaSimpleText.font(size: 13, weight: .medium)
    metaLabel.numberOfLines = 1
    metaLabel.lineBreakMode = .byTruncatingTail
    levelBadge.font = TiebaSimpleText.font(size: 11, weight: .heavy)
    levelBadge.contentInsets = UIEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)
    levelBadge.layer.cornerRadius = 5
    levelBadge.layer.cornerCurve = .continuous
    levelBadge.clipsToBounds = true
    levelBadge.setContentHuggingPriority(.required, for: .horizontal)
    levelBadge.setContentCompressionResistancePriority(.required, for: .horizontal)
    metaRow.addArrangedSubview(levelBadge)
    metaRow.addArrangedSubview(metaLabel)
    metaRow.axis = .horizontal
    metaRow.spacing = 6
    metaRow.alignment = .center
    titleColumn.addArrangedSubview(nameLabel)
    titleColumn.addArrangedSubview(metaRow)

    configureCapsuleButton(followButton, style: .prominent)
    configureCapsuleButton(followedChip, style: .quiet)
    configureCapsuleButton(signButton, style: .quiet)
    configureCapsuleButton(signedChip, style: .quiet)
    // 「已关注」可点 = 取消关注（走同一个 .follow 动作，页面按 card.isLike 分派；
    // 用户报的"点已关注无法取消关注"就是这里原先被禁用且没挂 action）。
    // 「已签到」保持不可点：签到是单向的，没有可撤销的动作。
    signedChip.isUserInteractionEnabled = false
    followButton.addAction(
      UIAction { [weak self] _ in self?.onAction?(.forum(.follow), [:]) },
      for: .touchUpInside
    )
    followedChip.addAction(
      UIAction { [weak self] _ in self?.onAction?(.forum(.follow), [:]) },
      for: .touchUpInside
    )
    signButton.addAction(
      UIAction { [weak self] _ in self?.onAction?(.forum(.sign), [:]) },
      for: .touchUpInside
    )
    for button in [followButton, followedChip, signButton, signedChip] {
      button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
      buttonRow.addArrangedSubview(button)
    }

    cardStack.addArrangedSubview(headerRow)
    axActionStack.axis = .vertical
    axActionStack.alignment = .fill
    axActionStack.spacing = 8
    axActionStack.isHidden = true
    cardStack.addArrangedSubview(axActionStack)
    cardStack.setCustomSpacing(6, after: headerRow)
    cardStack.setCustomSpacing(8, after: axActionStack)

    // 等级进度：有升级阈值画进度条，否则一行"经验 N"（旧页同判据）
    levelTrack.layer.cornerRadius = 3
    levelTrack.clipsToBounds = true
    levelFill.layer.cornerRadius = 3
    levelLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
    levelLabel.setContentHuggingPriority(.required, for: .horizontal)
    levelLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
    levelFill.translatesAutoresizingMaskIntoConstraints = false
    levelTrack.addSubview(levelFill)
    NSLayoutConstraint.activate([
      levelTrack.heightAnchor.constraint(equalToConstant: 6),
      levelFill.heightAnchor.constraint(equalToConstant: 6),
      levelFill.leadingAnchor.constraint(equalTo: levelTrack.leadingAnchor),
      levelFill.topAnchor.constraint(equalTo: levelTrack.topAnchor),
    ])
    levelRow.axis = .horizontal
    levelRow.spacing = 10
    levelRow.alignment = .center
    levelRow.addArrangedSubview(levelTrack)
    levelRow.addArrangedSubview(levelLabel)
    levelRow.isLayoutMarginsRelativeArrangement = true
    levelRow.layoutMargins = UIEdgeInsets(top: 10, left: 0, bottom: 0, right: 0)
    levelRow.insetsLayoutMarginsFromSafeArea = false
    cardStack.addArrangedSubview(levelRow)

    introLabel.font = TiebaSimpleText.font(size: 13, weight: .regular)
    introLabel.numberOfLines = 2
    introLabel.lineBreakMode = .byTruncatingTail
    introLabel.translatesAutoresizingMaskIntoConstraints = false
    introWrap.addSubview(introLabel)
    NSLayoutConstraint.activate([
      introLabel.leadingAnchor.constraint(equalTo: introWrap.leadingAnchor),
      introLabel.trailingAnchor.constraint(equalTo: introWrap.trailingAnchor),
      introLabel.topAnchor.constraint(equalTo: introWrap.topAnchor, constant: 8),
      introLabel.bottomAnchor.constraint(equalTo: introWrap.bottomAnchor),
    ])
    cardStack.addArrangedSubview(introWrap)

    // ── 分段（UIKit 同源组件）──
    segment.select(0, animated: false)
    segment.onSelect = { [weak self] index in
      self?.activateSegment(index: index, fromSystem: true)
    }
    // 去灰：不再用大号 surfaceSecondary 胶囊托底。仅保留透明排版轨道 +
    // TiebaTabSelector 自己的轻 tint 选中胶囊 / 连续指示器。
    segmentSurface.layer.cornerRadius = 0
    segmentSurface.layer.cornerCurve = .continuous
    segmentSurface.layer.borderWidth = 0
    segmentSurface.insetsLayoutMarginsFromSafeArea = false
    segment.backgroundColor = .clear
    for state: UIControl.State in [.normal, .highlighted, .selected, [.selected, .highlighted]] {
      segment.setBackgroundImage(UIImage(), for: state, barMetrics: .default)
    }
    for state: UIControl.State in [.normal, .selected, .highlighted, [.selected, .highlighted]] {
      segment.setDividerImage(
        UIImage(),
        forLeftSegmentState: state,
        rightSegmentState: state,
        barMetrics: .default
      )
    }
    segment.translatesAutoresizingMaskIntoConstraints = false
    segmentSurface.addSubview(segment)
    NSLayoutConstraint.activate([
      segment.leadingAnchor.constraint(equalTo: segmentSurface.leadingAnchor, constant: 2),
      segment.trailingAnchor.constraint(equalTo: segmentSurface.trailingAnchor, constant: -2),
      // 视觉高度由 UISegmentedControl 自身 intrinsic 决定（标准 32pt）；
      // 外层至少 44pt 承载命中，并保证字体变大时上下各有 6pt 呼吸。
      segment.centerYAnchor.constraint(equalTo: segmentSurface.centerYAnchor),
      segment.heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
      segmentSurface.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
      segmentSurface.heightAnchor.constraint(
        greaterThanOrEqualTo: segment.heightAnchor,
        constant: 12
      ),
    ])
    // 44pt 命中层放在透明视觉轨道上；触摸按 x 映射到 tab，VoiceOver 仍走 segment 本身。
    segmentHitView.backgroundColor = .clear
    segmentHitView.isAccessibilityElement = false
    segmentHitView.translatesAutoresizingMaskIntoConstraints = false
    let segmentTap = UITapGestureRecognizer(
      target: self,
      action: #selector(handleSegmentTap(_:))
    )
    segmentTap.cancelsTouchesInView = false
    segmentHitView.addGestureRecognizer(segmentTap)
    segmentHitView.addTarget(self, action: #selector(handleSegmentPressDown(_:)), for: .touchDown)
    segmentHitView.addTarget(
      self,
      action: #selector(handleSegmentPressUp(_:)),
      for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit]
    )
    segmentSurface.addSubview(segmentHitView)
    NSLayoutConstraint.activate([
      segmentHitView.leadingAnchor.constraint(equalTo: segmentSurface.leadingAnchor),
      segmentHitView.trailingAnchor.constraint(equalTo: segmentSurface.trailingAnchor),
      segmentHitView.topAnchor.constraint(equalTo: segmentSurface.topAnchor),
      segmentHitView.bottomAnchor.constraint(equalTo: segmentSurface.bottomAnchor),
    ])
    root.addArrangedSubview(segmentSurface)

    axSegmentStack.axis = .vertical
    axSegmentStack.alignment = .fill
    axSegmentStack.spacing = 4
    axSegmentStack.isHidden = true
    for index in 0..<3 {
      let titles = ["热门", "最新", "精品"]
      let button = UIButton(type: .system)
      var config = UIButton.Configuration.plain()
      config.title = titles[index]
      config.imagePlacement = .leading
      config.imagePadding = 8
      config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)
      config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
        var out = incoming
        out.font = TiebaSimpleText.font(size: 15, weight: .semibold)
        return out
      }
      button.configuration = config
      button.contentHorizontalAlignment = .leading
      button.tag = index
      button.accessibilityLabel = titles[index]
      button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
      button.addAction(UIAction { [weak self] _ in
        self?.activateSegment(index: index, fromSystem: false)
      }, for: .touchUpInside)
      axSegmentButtons.append(button)
      axSegmentStack.addArrangedSubview(button)
    }
    root.addArrangedSubview(axSegmentStack)
    root.setCustomSpacing(4, after: axSegmentStack)
    root.setCustomSpacing(4, after: segmentSurface)

    // ── 排序行（最新 tab；UIMenu 走系统菜单）──
    var sortConfig = UIButton.Configuration.plain()
    sortConfig.image = UIImage(systemName: "arrow.up.arrow.down")
    sortConfig.imagePadding = 6
    sortConfig.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0)
    // 标题恒单行（SDK：非 WordWrapping/CharWrapping 的模式会把标题限制成单行）。
    // 万一真被挤到放不下，宁可截断也不换行——「按回/复时间」两行是错的样子。
    sortConfig.titleLineBreakMode = .byTruncatingTail
    sortButton.configuration = sortConfig
    sortButton.contentHorizontalAlignment = .leading
    sortButton.showsMenuAsPrimaryAction = true
    sortButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
    sortRow.axis = .horizontal
    sortRow.alignment = .center
    sortSpacer.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)
    sortSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    sortRow.addArrangedSubview(sortButton)
    sortRow.addArrangedSubview(sortSpacer)
    root.addArrangedSubview(sortRow)
    root.setCustomSpacing(2, after: sortRow)

    // ── 分类行（精品 tab）──
    classifyChip.addAction(UIAction { [weak self] _ in
      TiebaSceneHaptics.fire("press")
      self?.onAction?(.forum(.clearClassify), [:])
    }, for: .touchUpInside)
    var classifyConfig = UIButton.Configuration.plain()
    classifyConfig.image = UIImage(systemName: "line.3.horizontal.decrease.circle")
    classifyConfig.imagePadding = 4
    classifyConfig.cornerStyle = .capsule
    classifyConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
      var out = incoming
      out.font = TiebaSimpleText.font(size: 13, weight: .medium)
      return out
    }
    classifyButton.configuration = classifyConfig
    classifyButton.contentHorizontalAlignment = .leading
    classifyButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
    classifyChip.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
    classifyButton.addAction(UIAction { [weak self] _ in
      TiebaSceneHaptics.fire("sheet-present")
      self?.onAction?(.forum(.classifyPicker), [:])
    }, for: .touchUpInside)
    classifyRow.axis = .horizontal
    classifyRow.alignment = .center
    classifySpacer.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)
    classifySpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    classifyRow.addArrangedSubview(classifyChip)
    classifyRow.addArrangedSubview(classifySpacer)
    classifyRow.addArrangedSubview(classifyButton)
    root.addArrangedSubview(classifyRow)

    // 兜底吸收器：万一单元格高比内容自然高多出一点（测量口径/缓存不同步），
    // 这点高度落在这里（hugging 1 < 各行的 250），不会被栈分给排序行/等级行——
    // 那两行是 center 对齐的单子控件行，一被拉伸就是"控件上下对称的空白"。
    let tailSpacer = UIView()
    tailSpacer.setContentHuggingPriority(UILayoutPriority(1), for: .vertical)
    root.addArrangedSubview(tailSpacer)
  }

  /// 行内撑开用（横向 stack 里吸收剩余宽度的空视图）。
  /// 横向吸收器：把行的富余宽度全吃掉，让前面的控件保持自然宽。hugging 压到 1
  /// （同下方 tailSpacer 的纵向口径）——默认 .defaultLow(250) 与 UIButton 自身的
  /// hugging 同值，栈的分配就成了并列优先级的模糊局，按钮可能被压窄；而
  /// UIButton.Configuration 的 titleLineBreakMode 默认是 WordWrapping（SDK 原文：
  /// "WordWrapping and CharWrapping both allow for multi-line text"）⇒ 一被压窄
  /// 就换行，中文就是"按回 / 复时间"（用户 2026-09-18 报）。
  private enum CapsuleStyle {
    case prominent
    case tinted
    case quiet
  }

  private func configureCapsuleButton(_ button: UIButton, style: CapsuleStyle) {
    var config: UIButton.Configuration
    switch style {
    case .prominent: config = .filled()
    case .tinted: config = .tinted()
    case .quiet: config = .gray()
    }
    config.cornerStyle = .capsule
    config.contentInsets = NSDirectionalEdgeInsets(
      top: 9, leading: style == .quiet ? 10 : 14, bottom: 9, trailing: style == .quiet ? 10 : 14
    )
    config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
      var out = incoming
      out.font = TiebaSimpleText.font(size: 13, weight: .semibold)
      return out
    }
    config.titleLineBreakMode = .byTruncatingTail
    button.configuration = config
  }

  // MARK: - spec → 视图

  private func applySpec() {
    applyAccessibleLayout()
    let cardSpec = spec["card"] as? [String: Any] ?? [:]
    let tab = Int(TiebaSimpleRowParser.double(spec["tab"]) ?? 0)
    let loggedIn = TiebaSimpleRowParser.bool(spec["loggedIn"]) ?? false
    let isLike = TiebaSimpleRowParser.bool(cardSpec["isLike"]) ?? false
    let isSigned = TiebaSimpleRowParser.bool(cardSpec["isSignIn"]) ?? false
    let contSignNum = Int(TiebaSimpleRowParser.double(cardSpec["contSignNum"]) ?? 0)
    let levelId = Int(TiebaSimpleRowParser.double(cardSpec["levelId"]) ?? 0)
    let curScore = Int(TiebaSimpleRowParser.double(cardSpec["curScore"]) ?? 0)
    let levelupScore = Int(TiebaSimpleRowParser.double(cardSpec["levelupScore"]) ?? 0)

    let darkAppearance = palette.base.isNight || traitCollection.userInterfaceStyle == .dark
    card.backgroundColor = TiebaAccessibleColors.elevatedSurface
    card.layer.cornerRadius = TiebaAccessibleColors.surfaceRadius
    card.layer.borderWidth = 0
    card.layer.borderColor = UIColor.clear.cgColor
    card.layer.shadowColor = UIColor.black.cgColor
    card.layer.shadowOpacity = darkAppearance ? 0.14 : 0.095
    card.layer.shadowRadius = 20
    card.layer.shadowOffset = CGSize(width: 0, height: 8)
    let forumName = TiebaSimpleRowParser.nonEmpty(cardSpec["name"])
      ?? TiebaSimpleRowParser.string(spec["forumName"])
      ?? ""
    nameLabel.text = forumName.isEmpty ? "" : "\(forumName)吧"
    nameLabel.textColor = palette.base.text
    avatar.accessibilityLabel = "查看\(forumName)吧头像"
    // 分段 = 透明排版轨道 + 轻 selected tint；不再铺一块灰色大胶囊。
    // Reduce Motion 下位移时长归零。
    segmentSurface.backgroundColor = .clear
    segmentSurface.layer.borderColor = UIColor.clear.cgColor
    segment.indicatorColor = .tertiarySystemFill
    segment.selectedTextColor = palette.base.text
    segment.normalTextColor = TiebaAccessibleColors.metadata
    updateSegmentMotionDuration()
    metaLabel.textColor = TiebaAccessibleColors.metadata
    metaLabel.text = "会员 \(TiebaForumFormat.count(Int(TiebaSimpleRowParser.double(cardSpec["memberCount"]) ?? 0))) · 帖子 \(TiebaForumFormat.count(Int(TiebaSimpleRowParser.double(cardSpec["threadCount"]) ?? 0)))"
    avatar.configure(url: TiebaSimpleRowParser.string(cardSpec["avatar"]) ?? "", initial: forumName)

    // 等级徽标：登录 + 已关注 + 有等级才显示（旧页 showLevel 判据）
    let levelColor = levelId > 0 ? TiebaPostRowLayout.levelColor(levelId) : nil
    let showsLevel = loggedIn && isLike && levelColor != nil
    levelBadge.isHidden = !showsLevel
    if let levelColor, showsLevel {
      levelBadge.text = "Lv.\(levelId)"
      // 等级色只做小面积 tint 底；文字走 label，保证小字 4.5:1。
      let badgeAlpha: CGFloat = traitCollection.accessibilityContrast == .high ? 0.28 : 0.16
      levelBadge.textColor = palette.base.text
      levelBadge.backgroundColor = levelColor.withAlphaComponent(badgeAlpha)
    }

    // 关注 / 已关注 + 签到 / 已签到
    followButton.isHidden = isLike
    followedChip.isHidden = !isLike
    signButton.isHidden = !isLike || isSigned
    signedChip.isHidden = !isLike || !isSigned
    var followConfig = followButton.configuration
    followConfig?.title = "关注"
    followConfig?.image = UIImage(
      systemName: "plus",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .bold)
    )
    followConfig?.imagePadding = 4
    // 主操作跟随 Tieba 品牌色；页面大面积仍是系统白，不铺蓝灰。
    followConfig?.baseBackgroundColor = palette.base.primary
    followConfig?.baseForegroundColor = .systemBackground
    followButton.configuration = followConfig
    followButton.accessibilityLabel = "关注\(forumName)吧"
    var followedConfig = followedChip.configuration
    followedConfig?.title = "已关注"
    followedConfig?.baseBackgroundColor = palette.base.primary.withAlphaComponent(0.12)
    followedConfig?.baseForegroundColor = TiebaAccessibleColors.metadata
    followedChip.configuration = followedConfig
    followedChip.accessibilityLabel = "取消关注\(forumName)吧"
    var signConfig = signButton.configuration
    signConfig?.title = "签到"
    // 关注是唯一主操作；签到用中性次级底，不再叠一块蓝色 tint。
    signConfig?.baseBackgroundColor = palette.base.primary.withAlphaComponent(0.10)
    signConfig?.baseForegroundColor = TiebaAccessibleColors.metadata
    signButton.configuration = signConfig
    signButton.accessibilityLabel = "签到"
    var signedConfig = signedChip.configuration
    signedConfig?.title = contSignNum > 0 ? "已签到 \(contSignNum)天" : "已签到"
    signedConfig?.baseBackgroundColor = palette.base.primary.withAlphaComponent(0.10)
    signedConfig?.baseForegroundColor = TiebaAccessibleColors.metadata
    signedChip.configuration = signedConfig
    signedChip.accessibilityLabel = "已签到"
    signedChip.accessibilityValue = contSignNum > 0 ? "连续\(contSignNum)天" : nil

    levelRow.isHidden = !showsLevel
    if showsLevel {
      let hasProgress = levelupScore > 0
      levelTrack.isHidden = !hasProgress
      levelLabel.text = hasProgress
        ? "\(min(curScore, levelupScore))/\(levelupScore)"
        : "经验 \(curScore)"
      levelLabel.textColor = TiebaAccessibleColors.metadata
      levelTrack.backgroundColor = palette.surfaceSecondary
      levelFillWidth?.isActive = false
      levelFillWidth = levelFill.widthAnchor.constraint(
        equalTo: levelTrack.widthAnchor,
        multiplier: hasProgress
          ? min(max(Double(curScore) / Double(levelupScore), 0.0001), 1)
          : 0.0001
      )
      levelFillWidth?.isActive = true
      levelFill.backgroundColor = levelColor
    }

    let intro = TiebaSimpleRowParser.string(cardSpec["intro"]) ?? ""
    introWrap.isHidden = intro.isEmpty
    introLabel.text = intro
    introLabel.textColor = TiebaAccessibleColors.metadata

    // 数据驱动（刷新/切排序都会带 tab 回来）：不播滑动，直接就位。
    let selectedTab = max(0, min(tab, segment.numberOfSegments - 1))
    segment.select(selectedTab, animated: false)
    updateAXSegmentSelection(selectedTab)
    sortRow.isHidden = tab != 1
    classifyRow.isHidden = tab != 2
    if tab == 1 {
      let sortType = Int(TiebaSimpleRowParser.double(spec["sortType"]) ?? 0)
      var config = sortButton.configuration
      config?.title = sortType == 1 ? "按发帖时间" : "按回复时间"
      config?.baseForegroundColor = palette.base.text
      sortButton.configuration = config
      sortButton.accessibilityLabel = "帖子排序"
      sortButton.accessibilityValue = sortType == 1 ? "按发帖时间" : "按回复时间"
      sortButton.accessibilityHint = "打开排序菜单"
      sortButton.menu = UIMenu(children: [
        sortAction(title: "按回复时间", value: 0, selected: sortType == 0),
        sortAction(title: "按发帖时间", value: 1, selected: sortType == 1),
      ])
    }
    if tab == 2 {
      let label = TiebaSimpleRowParser.nonEmpty(spec["classifyLabel"]) ?? ""
      var chipConfig = UIButton.Configuration.gray()
      chipConfig.title = label
      chipConfig.image = UIImage(systemName: "xmark")
      chipConfig.imagePlacement = .trailing
      chipConfig.imagePadding = 6
      chipConfig.cornerStyle = .capsule
      chipConfig.buttonSize = .small
      // 同排序按钮：分类名也不许换行（默认 WordWrapping，被挤就折行）。
      chipConfig.titleLineBreakMode = .byTruncatingTail
      chipConfig.baseForegroundColor = palette.base.text
      chipConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
        var out = incoming
        out.font = TiebaSimpleText.font(size: 13, weight: .semibold)
        return out
      }
      classifyChip.configuration = chipConfig
      classifyChip.isHidden = label.isEmpty
      classifyChip.accessibilityLabel = label.isEmpty ? nil : "清除分类"
      classifyButton.isHidden = !(TiebaSimpleRowParser.bool(spec["hasClassifies"]) ?? false)
      classifyButton.accessibilityLabel = "选择分类"
      var config = classifyButton.configuration
      config?.title = "分类"
      config?.baseForegroundColor = palette.base.text
      classifyButton.configuration = config
    }
    heightCache = nil
    invalidateIntrinsicContentSize()
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    // 吧名片是页头唯一 elevation：固定 path，滚动时不重算离屏阴影轮廓。
    card.layer.shadowPath = UIBezierPath(
      roundedRect: card.bounds,
      cornerRadius: card.layer.cornerRadius
    ).cgPath
  }

  private func applyAccessibleLayout() {
    let ax = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
    nameLabel.font = TiebaSimpleText.font(size: 24, weight: .semibold)
    metaLabel.font = TiebaSimpleText.font(size: 13, weight: .medium)
    introLabel.font = TiebaSimpleText.font(size: 13, weight: .regular)
    levelBadge.font = TiebaSimpleText.font(size: 11, weight: .heavy)
    levelLabel.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(
      for: .monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
      compatibleWith: traitCollection
    )
    nameLabel.numberOfLines = ax ? 0 : 1
    metaLabel.numberOfLines = ax ? 0 : 1
    introLabel.numberOfLines = ax ? 0 : 2
    nameLabel.lineBreakMode = ax ? .byWordWrapping : .byTruncatingTail
    metaLabel.lineBreakMode = ax ? .byWordWrapping : .byTruncatingTail
    introLabel.lineBreakMode = ax ? .byWordWrapping : .byTruncatingTail
    metaRow.axis = ax ? .vertical : .horizontal
    metaRow.alignment = ax ? .leading : .center
    metaRow.spacing = ax ? 4 : 6
    if axMetaWidthConstraint == nil {
      axMetaWidthConstraint = metaLabel.widthAnchor.constraint(equalTo: titleColumn.widthAnchor)
    }
    axMetaWidthConstraint?.isActive = ax
    levelRow.axis = ax ? .vertical : .horizontal
    levelRow.alignment = ax ? .fill : .center
    levelRow.spacing = ax ? 4 : 10
    sortRow.axis = ax ? .vertical : .horizontal
    sortRow.alignment = ax ? .fill : .center
    sortSpacer.isHidden = ax
    classifyRow.axis = ax ? .vertical : .horizontal
    classifyRow.alignment = ax ? .fill : .center
    classifySpacer.isHidden = ax
    buttonRow.isHidden = ax
    axActionStack.isHidden = ax == false
    let targetStack = ax ? axActionStack : buttonRow
    for button in [followButton, followedChip, signButton, signedChip] {
      if button.superview !== targetStack {
        button.removeFromSuperview()
        targetStack.addArrangedSubview(button)
      }
    }
    segmentSurface.isHidden = ax
    axSegmentStack.isHidden = ax == false
    updateAXSegmentSelection(segment.selectedSegmentIndex)
    heightCache = nil
    invalidateIntrinsicContentSize()
    setNeedsLayout()
    superview?.setNeedsLayout()
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    applyAccessibleLayout()
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    if previousTraitCollection == nil
      || previousTraitCollection?.preferredContentSizeCategory
        != traitCollection.preferredContentSizeCategory {
      applyAccessibleLayout()
    }
  }

  private func updateAXSegmentSelection(_ selectedIndex: Int) {
    let titles = ["热门", "最新", "精品"]
    for (index, button) in axSegmentButtons.enumerated() {
      var config = button.configuration ?? .plain()
      config.title = titles[index]
      config.image = index == selectedIndex
        ? UIImage(
          systemName: "checkmark",
          withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        )
        : nil
      config.baseForegroundColor = index == selectedIndex
        ? palette.base.text
        : TiebaAccessibleColors.metadata
      button.configuration = config
      button.accessibilityTraits = index == selectedIndex
        ? [.button, .selected]
        : .button
    }
  }

  private func activateSegment(index: Int, fromSystem: Bool) {
    guard index >= 0, index < segment.numberOfSegments else { return }
    let changed = segment.selectedSegmentIndex != index
    segment.select(index, animated: true)
    updateAXSegmentSelection(index)
    if changed == false, fromSystem == false { return }
    TiebaSceneHaptics.fire("toggle")
    onAction?(.forum(.segment(index: index)), [:])
  }

  @objc private func handleSegmentTap(_ gesture: UITapGestureRecognizer) {
    guard isAXLayout == false, segmentHitView.bounds.width > 0 else { return }
    let x = max(0, min(gesture.location(in: segmentHitView).x, segmentHitView.bounds.width - 1))
    let index = min(max(Int(x / (segmentHitView.bounds.width / 3)), 0), 2)
    TiebaInteractiveMotion.press(segmentSurface, pressed: false)
    activateSegment(index: index, fromSystem: false)
  }

  @objc private func handleSegmentPressDown(_ sender: UIControl) {
    TiebaInteractiveMotion.press(segmentSurface, pressed: true)
  }

  @objc private func handleSegmentPressUp(_ sender: UIControl) {
    TiebaInteractiveMotion.press(segmentSurface, pressed: false)
  }

  private var isAXLayout: Bool {
    traitCollection.preferredContentSizeCategory.isAccessibilityCategory
  }

  private func updateSegmentMotionDuration() {
    segment.slideDuration = UIAccessibility.isReduceMotionEnabled
      ? 0
      : TiebaAnimationDuration.overlayAppear
  }

  @objc private func handleReduceMotionStatusChange() {
    updateSegmentMotionDuration()
  }

  private func sortAction(title: String, value: Int, selected: Bool) -> UIAction {
    UIAction(title: title, state: selected ? .on : .off) { [weak self] _ in
      TiebaSceneHaptics.fire("toggle")
      self?.onAction?(.forum(.sort(sortType: value)), [:])
    }
  }

  @objc private func handleAvatarTap() {
    // 源图窗口矩形给查看器转场（原 frameFromPressEvent 同用途）：视图测量值，
    // 走 payload 字典（协议约定的唯一字典通路）。
    let frame = avatar.convert(avatar.bounds, to: nil)
    onAction?(.forum(.avatar), [
      "frameX": Double(frame.minX),
      "frameY": Double(frame.minY),
      "frameW": Double(frame.width),
      "frameH": Double(frame.height),
    ])
  }

  @objc private func handleCardTap() {
    onAction?(.forum(.card), [:])
  }
}
