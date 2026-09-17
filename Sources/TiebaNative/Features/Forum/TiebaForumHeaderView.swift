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
  private let card = UIView()
  private let headerRow = TiebaAvatarHeaderRow(
    avatarSize: 52, avatarSpacing: 12, columnSpacing: 12, titleSpacing: 3
  )
  private let nameLabel = UILabel()
  private let levelBadge = TiebaMemberBadgeLabel()
  private let metaLabel = UILabel()
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
  private let segment = UISegmentedControl(items: ["热门", "最新", "精品"])
  private let sortRow = UIStackView()
  private let sortButton = UIButton(type: .system)
  private let classifyRow = UIStackView()
  private let classifyChip = UIButton(type: .system)
  private let classifyButton = UIButton(type: .system)
  /// 进度条填充宽约束（按比例；数据变化时重建）。
  private var levelFillWidth: NSLayoutConstraint?

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

  /// 卡片内文本可用宽 = 页头宽 − root 左右 10 − 卡片内边距 14。
  private static func textWidth(forHeaderWidth width: CGFloat) -> CGFloat {
    max(width - 48, 1)
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
    let root = UIStackView()
    root.axis = .vertical
    root.spacing = 0
    root.isLayoutMarginsRelativeArrangement = true
    root.layoutMargins = UIEdgeInsets(top: 0, left: 10, bottom: 2, right: 10)
    root.translatesAutoresizingMaskIntoConstraints = false
    addSubview(root)
    NSLayoutConstraint.activate([
      root.leadingAnchor.constraint(equalTo: leadingAnchor),
      root.trailingAnchor.constraint(equalTo: trailingAnchor),
      root.topAnchor.constraint(equalTo: topAnchor),
      root.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    // ── 吧名片 ──
    card.layer.cornerRadius = 20
    card.layer.cornerCurve = .continuous
    // 1px 卡边框：displayScale 取视图 trait（UIScreen.main 自 iOS 26 废弃）。
    card.layer.borderWidth = 1 / max(traitCollection.displayScale, 1)
    let cardStack = UIStackView()
    cardStack.axis = .vertical
    cardStack.spacing = 0
    cardStack.translatesAutoresizingMaskIntoConstraints = false
    card.addSubview(cardStack)
    NSLayoutConstraint.activate([
      cardStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
      cardStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
      cardStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
      cardStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
    ])
    root.addArrangedSubview(card)
    root.setCustomSpacing(8, after: card)

    avatar.isUserInteractionEnabled = true
    avatar.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleAvatarTap)))
    avatar.setContentHuggingPriority(.required, for: .horizontal)
    avatar.setContentCompressionResistancePriority(.required, for: .horizontal)

    titleColumn.isUserInteractionEnabled = true
    titleColumn.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleCardTap)))
    nameLabel.font = .systemFont(ofSize: 20, weight: .heavy)
    nameLabel.numberOfLines = 1
    nameLabel.lineBreakMode = .byTruncatingTail
    metaLabel.font = .systemFont(ofSize: 12, weight: .medium)
    metaLabel.numberOfLines = 1
    metaLabel.lineBreakMode = .byTruncatingTail
    levelBadge.font = .systemFont(ofSize: 11, weight: .heavy)
    levelBadge.contentInsets = UIEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)
    levelBadge.layer.cornerRadius = 5
    levelBadge.layer.cornerCurve = .continuous
    levelBadge.clipsToBounds = true
    levelBadge.setContentHuggingPriority(.required, for: .horizontal)
    levelBadge.setContentCompressionResistancePriority(.required, for: .horizontal)
    let metaRow = UIStackView(arrangedSubviews: [levelBadge, metaLabel])
    metaRow.axis = .horizontal
    metaRow.spacing = 6
    metaRow.alignment = .center
    titleColumn.addArrangedSubview(nameLabel)
    titleColumn.addArrangedSubview(metaRow)

    configureCapsuleButton(followButton, filled: true)
    configureCapsuleButton(followedChip, filled: false)
    configureCapsuleButton(signButton, filled: true)
    configureCapsuleButton(signedChip, filled: false)
    followedChip.isUserInteractionEnabled = false
    signedChip.isUserInteractionEnabled = false
    followButton.addAction(
      UIAction { [weak self] _ in self?.onAction?(.forum(.follow), [:]) },
      for: .touchUpInside
    )
    signButton.addAction(
      UIAction { [weak self] _ in self?.onAction?(.forum(.sign), [:]) },
      for: .touchUpInside
    )
    for button in [followButton, followedChip, signButton, signedChip] {
      buttonRow.addArrangedSubview(button)
    }

    cardStack.addArrangedSubview(headerRow)

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
    levelRow.layoutMargins = UIEdgeInsets(top: 12, left: 0, bottom: 0, right: 0)
    cardStack.addArrangedSubview(levelRow)

    introLabel.font = .systemFont(ofSize: 13, weight: .regular)
    introLabel.numberOfLines = 2
    introLabel.lineBreakMode = .byTruncatingTail
    introLabel.translatesAutoresizingMaskIntoConstraints = false
    introWrap.addSubview(introLabel)
    NSLayoutConstraint.activate([
      introLabel.leadingAnchor.constraint(equalTo: introWrap.leadingAnchor),
      introLabel.trailingAnchor.constraint(equalTo: introWrap.trailingAnchor),
      introLabel.topAnchor.constraint(equalTo: introWrap.topAnchor, constant: 10),
      introLabel.bottomAnchor.constraint(equalTo: introWrap.bottomAnchor),
    ])
    cardStack.addArrangedSubview(introWrap)

    // ── 分段（UIKit 同源组件）──
    segment.selectedSegmentIndex = 0
    segment.addTarget(self, action: #selector(handleSegmentChange), for: .valueChanged)
    segment.translatesAutoresizingMaskIntoConstraints = false
    let segmentWrap = UIView()
    segmentWrap.addSubview(segment)
    NSLayoutConstraint.activate([
      segment.leadingAnchor.constraint(equalTo: segmentWrap.leadingAnchor),
      segment.trailingAnchor.constraint(equalTo: segmentWrap.trailingAnchor),
      segment.centerYAnchor.constraint(equalTo: segmentWrap.centerYAnchor),
      segmentWrap.heightAnchor.constraint(equalToConstant: 32),
    ])
    root.addArrangedSubview(segmentWrap)
    root.setCustomSpacing(6, after: segmentWrap)

    // ── 排序行（最新 tab；UIMenu 走系统菜单）──
    var sortConfig = UIButton.Configuration.plain()
    sortConfig.image = UIImage(systemName: "arrow.up.arrow.down")
    sortConfig.imagePadding = 6
    sortConfig.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0)
    sortButton.configuration = sortConfig
    sortButton.showsMenuAsPrimaryAction = true
    sortRow.axis = .horizontal
    sortRow.alignment = .center
    sortRow.addArrangedSubview(sortButton)
    sortRow.addArrangedSubview(makeSpacer())
    root.addArrangedSubview(sortRow)
    root.setCustomSpacing(2, after: sortRow)

    // ── 分类行（精品 tab）──
    classifyChip.addAction(UIAction { [weak self] _ in
      TiebaSceneHaptics.fire("press")
      self?.onAction?(.forum(.clearClassify), [:])
    }, for: .touchUpInside)
    var classifyConfig = UIButton.Configuration.tinted()
    classifyConfig.image = UIImage(systemName: "line.3.horizontal.decrease.circle")
    classifyConfig.imagePadding = 4
    classifyConfig.cornerStyle = .capsule
    classifyConfig.buttonSize = .small
    classifyConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
      var out = incoming
      out.font = .systemFont(ofSize: 13, weight: .medium)
      return out
    }
    classifyButton.configuration = classifyConfig
    classifyButton.addAction(UIAction { [weak self] _ in
      TiebaSceneHaptics.fire("sheet-present")
      self?.onAction?(.forum(.classifyPicker), [:])
    }, for: .touchUpInside)
    classifyRow.axis = .horizontal
    classifyRow.alignment = .center
    classifyRow.addArrangedSubview(classifyChip)
    classifyRow.addArrangedSubview(makeSpacer())
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
  private func makeSpacer() -> UIView {
    let spacer = UIView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return spacer
  }

  private func configureCapsuleButton(_ button: UIButton, filled: Bool) {
    var config = filled ? UIButton.Configuration.filled() : UIButton.Configuration.gray()
    config.cornerStyle = .capsule
    config.contentInsets = NSDirectionalEdgeInsets(
      top: 9, leading: filled ? 14 : 10, bottom: 9, trailing: filled ? 14 : 10
    )
    config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
      var out = incoming
      out.font = .systemFont(ofSize: 13, weight: .semibold)
      return out
    }
    config.titleLineBreakMode = .byTruncatingTail
    button.configuration = config
  }

  // MARK: - spec → 视图

  private func applySpec() {
    let cardSpec = spec["card"] as? [String: Any] ?? [:]
    let tab = Int(TiebaSimpleRowParser.double(spec["tab"]) ?? 0)
    let loggedIn = TiebaSimpleRowParser.bool(spec["loggedIn"]) ?? false
    let isLike = TiebaSimpleRowParser.bool(cardSpec["isLike"]) ?? false
    let isSigned = TiebaSimpleRowParser.bool(cardSpec["isSignIn"]) ?? false
    let contSignNum = Int(TiebaSimpleRowParser.double(cardSpec["contSignNum"]) ?? 0)
    let levelId = Int(TiebaSimpleRowParser.double(cardSpec["levelId"]) ?? 0)
    let curScore = Int(TiebaSimpleRowParser.double(cardSpec["curScore"]) ?? 0)
    let levelupScore = Int(TiebaSimpleRowParser.double(cardSpec["levelupScore"]) ?? 0)

    let secondary = palette.base.textSecondary
    let tertiary = palette.base.textTertiary
    card.backgroundColor = palette.base.card
    card.layer.borderColor = palette.base.borderCard.cgColor
    let forumName = TiebaSimpleRowParser.nonEmpty(cardSpec["name"])
      ?? TiebaSimpleRowParser.string(spec["forumName"])
      ?? ""
    nameLabel.text = forumName.isEmpty ? "" : "\(forumName)吧"
    nameLabel.textColor = palette.base.text
    metaLabel.textColor = tertiary
    metaLabel.text = "会员 \(TiebaForumFormat.count(Int(TiebaSimpleRowParser.double(cardSpec["memberCount"]) ?? 0))) · 帖子 \(TiebaForumFormat.count(Int(TiebaSimpleRowParser.double(cardSpec["threadCount"]) ?? 0)))"
    avatar.configure(url: TiebaSimpleRowParser.string(cardSpec["avatar"]) ?? "", initial: forumName)

    // 等级徽标：登录 + 已关注 + 有等级才显示（旧页 showLevel 判据）
    let levelColor = levelId > 0 ? TiebaPostRowLayout.levelColor(levelId) : nil
    let showsLevel = loggedIn && isLike && levelColor != nil
    levelBadge.isHidden = !showsLevel
    if let levelColor, showsLevel {
      levelBadge.text = "Lv.\(levelId)"
      levelBadge.textColor = levelColor
      levelBadge.backgroundColor = levelColor.withAlphaComponent(0.25)
    }

    // 关注 / 已关注 + 签到 / 已签到
    followButton.isHidden = isLike
    followedChip.isHidden = !isLike
    signButton.isHidden = !isLike || isSigned
    signedChip.isHidden = !isLike || !isSigned
    var followConfig = followButton.configuration
    followConfig?.title = "关注"
    followConfig?.baseBackgroundColor = palette.base.primary
    followConfig?.baseForegroundColor = palette.textOnPrimary
    followButton.configuration = followConfig
    var followedConfig = followedChip.configuration
    followedConfig?.title = "已关注"
    followedConfig?.baseBackgroundColor = palette.surfaceSecondary
    followedConfig?.baseForegroundColor = secondary
    followedChip.configuration = followedConfig
    var signConfig = signButton.configuration
    signConfig?.title = "签到"
    signConfig?.baseBackgroundColor = palette.base.primary
    signConfig?.baseForegroundColor = palette.textOnPrimary
    signButton.configuration = signConfig
    var signedConfig = signedChip.configuration
    signedConfig?.title = contSignNum > 0 ? "已签到 \(contSignNum)天" : "已签到"
    signedConfig?.baseBackgroundColor = palette.surfaceSecondary
    signedConfig?.baseForegroundColor = secondary
    signedChip.configuration = signedConfig

    levelRow.isHidden = !showsLevel
    if showsLevel {
      let hasProgress = levelupScore > 0
      levelTrack.isHidden = !hasProgress
      levelLabel.text = hasProgress
        ? "\(min(curScore, levelupScore))/\(levelupScore)"
        : "经验 \(curScore)"
      levelLabel.textColor = tertiary
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
    introLabel.textColor = secondary

    segment.selectedSegmentIndex = max(0, min(tab, segment.numberOfSegments - 1))
    sortRow.isHidden = tab != 1
    classifyRow.isHidden = tab != 2
    if tab == 1 {
      let sortType = Int(TiebaSimpleRowParser.double(spec["sortType"]) ?? 0)
      var config = sortButton.configuration
      config?.title = sortType == 1 ? "按发帖时间" : "按回复时间"
      config?.baseForegroundColor = palette.base.primary
      sortButton.configuration = config
      sortButton.menu = UIMenu(children: [
        sortAction(title: "按回复时间", value: 0, selected: sortType == 0),
        sortAction(title: "按发帖时间", value: 1, selected: sortType == 1),
      ])
    }
    if tab == 2 {
      let label = TiebaSimpleRowParser.nonEmpty(spec["classifyLabel"]) ?? ""
      var chipConfig = UIButton.Configuration.tinted()
      chipConfig.title = label
      chipConfig.image = UIImage(systemName: "xmark")
      chipConfig.imagePlacement = .trailing
      chipConfig.imagePadding = 6
      chipConfig.cornerStyle = .capsule
      chipConfig.buttonSize = .small
      chipConfig.baseForegroundColor = palette.base.primary
      chipConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
        var out = incoming
        out.font = .systemFont(ofSize: 13, weight: .semibold)
        return out
      }
      classifyChip.configuration = chipConfig
      classifyChip.isHidden = label.isEmpty
      classifyButton.isHidden = !(TiebaSimpleRowParser.bool(spec["hasClassifies"]) ?? false)
      var config = classifyButton.configuration
      config?.title = "分类"
      config?.baseForegroundColor = palette.base.primary
      classifyButton.configuration = config
    }
    heightCache = nil
    invalidateIntrinsicContentSize()
    setNeedsLayout()
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

  @objc private func handleSegmentChange() {
    TiebaSceneHaptics.fire("toggle")
    onAction?(.forum(.segment(index: segment.selectedSegmentIndex)), [:])
  }
}
