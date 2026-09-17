// 用户主页滚动头（原 src/components/user/ProfileHeader.tsx + 页内分段栏）：
// 64 头像 + 名字/认证徽章 + @handle、关注/拉黑、简介、Meta 行（性别/UID 复制/
// IP/吧龄）、统计行（关注/粉丝可点）、贴子·回复·关注的吧分段。
//
// 走 TiebaKindListHeaderView 契约（列表只认识"高度 + 主题 + 点击外传"三件事）；
// 点击经 onAction 外传（动作 = TiebaUserProfileHeaderAction；avatar 的测量矩形
// 走 payload 字典，见协议约定）。
// 顶部让位由列表的 contentInsetTop 承担，本视图不含状态栏/导航栏留白。
import UIKit
import Nuke

/// 用户主页页头动作（原字符串动作名的类型化）。
public enum TiebaUserProfileHeaderAction {
  /// 头像：转场矩形是视图测量值，走 onAction 的 payload 字典（frameX/Y/W/H）。
  case avatar
  case follow
  case block
  case copyUid
  case social(mode: String)
  case tab(value: String)
}

private enum ProfileHeaderMetrics {
  static let paddingH: CGFloat = 16
  static let paddingBottom: CGFloat = 12
  static let avatarSize: CGFloat = 64
  static let segmentPadH: CGFloat = 10
  static let segmentPadV: CGFloat = 12
  static let segmentMinHeight: CGFloat = 48
}

public final class TiebaUserProfileHeaderView: UIView, TiebaKindListHeaderView {
  public var onAction: ((TiebaKindListHeaderAction, [String: Any]) -> Void)?

  private var spec: [String: Any] = [:]
  private var palette: TiebaSimpleRowPalette = .default
  private var heightCache: (width: CGFloat, height: CGFloat)?

  public init(spec: [String: Any]) {
    self.spec = spec
    super.init(frame: .zero)
    backgroundColor = .clear
    isOpaque = false
    buildSubviews()
    applySpec()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  public func applyPalette(_ palette: TiebaSimpleRowPalette) {
    guard palette != self.palette else { return }
    self.palette = palette
    applySpec()
  }

  /// 高度 = 内容自适应高（Auto Layout 单次测量，按宽度缓存）。
  public func headerHeight(forWidth width: CGFloat) -> CGFloat {
    if let cache = heightCache, cache.width == width { return cache.height }
    // 多行简介先钉换行宽度：拟合趟与最终布局趟宽度不一致会差一整行，而宿主会把
    // 差额当空白分给页头里的某一行（与 TiebaForumHeaderView 同款处理）。
    introLabel.preferredMaxLayoutWidth = max(width - ProfileHeaderMetrics.paddingH * 2, 1)
    let target = CGSize(width: max(width, 1), height: UIView.layoutFittingCompressedSize.height)
    let size = systemLayoutSizeFitting(
      target,
      withHorizontalFittingPriority: .required,
      verticalFittingPriority: .fittingSizeLevel
    )
    let height = ceil(size.height)
    heightCache = (width, height)
    return height
  }

  // MARK: - 子视图

  private let headerRow = TiebaAvatarHeaderRow(
    avatarSize: ProfileHeaderMetrics.avatarSize,
    avatarSpacing: 14,
    columnSpacing: 8
  )
  private let nameLabel = UILabel()
  private let handleLabel = UILabel()
  private let badgeRow = UIStackView()
  private let followButton = TiebaProfileActionButton()
  private let blockButton = TiebaProfileActionButton()
  private let introLabel = UILabel()
  private let metaRow = UIStackView()
  private let genderItem = TiebaProfileMetaItem()
  private let uidItem = TiebaProfileMetaItem()
  private let ipItem = TiebaProfileMetaItem()
  private let ageItem = TiebaProfileMetaItem()
  private let statsRow = UIStackView()
  private let followsStat = TiebaStatColumnView(
    axis: .horizontal,
    valueFont: TiebaSimpleText.font(size: 16, weight: .bold),
    labelFont: TiebaSimpleText.font(size: 13, weight: .medium),
    spacing: 4
  )
  private let fansStat = TiebaStatColumnView(
    axis: .horizontal,
    valueFont: TiebaSimpleText.font(size: 16, weight: .bold),
    labelFont: TiebaSimpleText.font(size: 13, weight: .medium),
    spacing: 4
  )
  private let agreeStat = TiebaStatColumnView(
    axis: .horizontal,
    valueFont: TiebaSimpleText.font(size: 16, weight: .bold),
    labelFont: TiebaSimpleText.font(size: 13, weight: .medium),
    spacing: 4
  )
  private let segment = UISegmentedControl()

  /// 段：标签给显示、值给回传（数据 tab 名，页头不许把标签当值用）。
  private var tabs: [(label: String, value: String)] = []
  /// 当前分段标题（判重：重装分段会重置选中态）。
  private var segmentTitles: [String] = []

  private func buildSubviews() {
    let titleRow = headerRow
    let titleColumn = headerRow.titleColumn
    let actionRow = headerRow.actionRow

    let nameLine = UIView()
    nameLabel.numberOfLines = 1
    nameLabel.lineBreakMode = .byTruncatingTail
    nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    badgeRow.axis = .horizontal
    badgeRow.spacing = 8
    badgeRow.alignment = .center

    handleLabel.numberOfLines = 1
    handleLabel.lineBreakMode = .byTruncatingTail

    titleColumn.addArrangedSubview(nameLine)
    titleColumn.addArrangedSubview(handleLabel)
    titleColumn.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    actionRow.axis = .horizontal
    actionRow.spacing = 6
    actionRow.alignment = .center
    followButton.addTarget(self, action: #selector(handleFollow), for: .touchUpInside)
    blockButton.addTarget(self, action: #selector(handleBlock), for: .touchUpInside)
    actionRow.addArrangedSubview(followButton)
    actionRow.addArrangedSubview(blockButton)
    actionRow.setContentHuggingPriority(.required, for: .horizontal)

    introLabel.numberOfLines = 3
    introLabel.lineBreakMode = .byTruncatingTail

    metaRow.axis = .horizontal
    metaRow.spacing = 14
    metaRow.alignment = .center
    uidItem.addTarget(self, action: #selector(handleCopyUid), for: .touchUpInside)
    for item in [genderItem, uidItem, ipItem, ageItem] { metaRow.addArrangedSubview(item) }

    statsRow.axis = .horizontal
    statsRow.spacing = 20
    statsRow.alignment = .center
    followsStat.addTarget(self, action: #selector(handleOpenFollows), for: .touchUpInside)
    fansStat.addTarget(self, action: #selector(handleOpenFans), for: .touchUpInside)
    for stat in [followsStat, fansStat, agreeStat] { statsRow.addArrangedSubview(stat) }

    segment.addTarget(self, action: #selector(handleSegmentChange), for: .valueChanged)
    segment.selectedSegmentIndex = 0

    let segmentSlot = UIView()
    segmentSlot.addSubview(segment)
    segment.translatesAutoresizingMaskIntoConstraints = false

    for subview in [titleRow, introLabel, metaRow, statsRow, segmentSlot] {
      subview.translatesAutoresizingMaskIntoConstraints = false
      addSubview(subview)
      subview.setContentHuggingPriority(.required, for: .vertical)
    }
    nameLabel.translatesAutoresizingMaskIntoConstraints = false
    badgeRow.translatesAutoresizingMaskIntoConstraints = false
    nameLine.addSubview(nameLabel)
    nameLine.addSubview(badgeRow)

    let pad = ProfileHeaderMetrics.paddingH
    NSLayoutConstraint.activate([
      titleRow.topAnchor.constraint(equalTo: topAnchor),
      titleRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
      titleRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),

      nameLine.widthAnchor.constraint(equalTo: titleColumn.widthAnchor),
      nameLabel.leadingAnchor.constraint(equalTo: nameLine.leadingAnchor),
      // 行高必须由名字与徽章**共同**决定：原来只挂 centerY，徽章（比 22pt 名字矮）
      // 单独定行高 → 名字上下溢出，底端压到下一行的 @handle（用户实证重合）。
      nameLabel.topAnchor.constraint(equalTo: nameLine.topAnchor),
      nameLabel.bottomAnchor.constraint(equalTo: nameLine.bottomAnchor),
      badgeRow.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 8),
      badgeRow.trailingAnchor.constraint(lessThanOrEqualTo: nameLine.trailingAnchor),
      badgeRow.topAnchor.constraint(equalTo: nameLine.topAnchor),
      badgeRow.bottomAnchor.constraint(equalTo: nameLine.bottomAnchor),
      nameLine.heightAnchor.constraint(greaterThanOrEqualTo: badgeRow.heightAnchor),

      introLabel.topAnchor.constraint(equalTo: titleRow.bottomAnchor, constant: 14),
      introLabel.leadingAnchor.constraint(equalTo: titleRow.leadingAnchor),
      introLabel.trailingAnchor.constraint(equalTo: titleRow.trailingAnchor),

      metaRow.topAnchor.constraint(equalTo: introLabel.bottomAnchor, constant: 10),
      metaRow.leadingAnchor.constraint(equalTo: titleRow.leadingAnchor),
      metaRow.trailingAnchor.constraint(lessThanOrEqualTo: titleRow.trailingAnchor),

      statsRow.topAnchor.constraint(equalTo: metaRow.bottomAnchor, constant: 14),
      statsRow.leadingAnchor.constraint(equalTo: titleRow.leadingAnchor),
      statsRow.trailingAnchor.constraint(lessThanOrEqualTo: titleRow.trailingAnchor),

      segmentSlot.topAnchor.constraint(equalTo: statsRow.bottomAnchor),
      segmentSlot.leadingAnchor.constraint(equalTo: leadingAnchor),
      segmentSlot.trailingAnchor.constraint(equalTo: trailingAnchor),
      segmentSlot.bottomAnchor.constraint(
        equalTo: bottomAnchor, constant: -ProfileHeaderMetrics.paddingBottom
      ),
      segmentSlot.heightAnchor.constraint(
        greaterThanOrEqualToConstant: ProfileHeaderMetrics.segmentMinHeight
      ),
      segment.leadingAnchor.constraint(
        equalTo: segmentSlot.leadingAnchor, constant: ProfileHeaderMetrics.segmentPadH
      ),
      segment.trailingAnchor.constraint(
        equalTo: segmentSlot.trailingAnchor, constant: -ProfileHeaderMetrics.segmentPadH
      ),
      segment.topAnchor.constraint(
        equalTo: segmentSlot.topAnchor, constant: ProfileHeaderMetrics.segmentPadV
      ),
      segment.bottomAnchor.constraint(
        equalTo: segmentSlot.bottomAnchor, constant: -ProfileHeaderMetrics.segmentPadV
      ),
    ])

    let tap = UITapGestureRecognizer(target: self, action: #selector(handleAvatarTap))
    headerRow.avatarView.addGestureRecognizer(tap)
    headerRow.avatarView.isUserInteractionEnabled = true
    headerRow.avatarView.isAccessibilityElement = true
    headerRow.avatarView.accessibilityTraits = .button
  }

  // MARK: - 数据

  private func applySpec() {
    let text = palette.base.text
    let secondary = palette.base.textSecondary
    let tertiary = palette.base.textTertiary
    let tint = palette.base.primary

    let name = TiebaSimpleRowParser.nonEmpty(spec["name"]) ?? ""
    let nameShow = TiebaSimpleRowParser.nonEmpty(spec["nameShow"]) ?? name
    let portrait = TiebaSimpleRowParser.string(spec["portrait"]) ?? ""
    let intro = TiebaSimpleRowParser.nonEmpty(spec["intro"]) ?? "这个人很懒，什么都没留下"
    let uidText = TiebaSimpleRowParser.string(spec["uidText"]) ?? ""
    let ip = TiebaSimpleRowParser.nonEmpty(spec["ip"]) ?? ""
    let tbAge = TiebaSimpleRowParser.nonEmpty(spec["tbAge"]) ?? ""
    let sex = Int(TiebaSimpleRowParser.double(spec["sex"]) ?? 0)
    let showsIp = (spec["showIp"] as? Bool) ?? true
    let isOwn = (spec["own"] as? Bool) ?? false
    let isLoggedIn = (spec["loggedIn"] as? Bool) ?? false
    let isFollowing = (spec["following"] as? Bool) ?? false
    let isBlocked = (spec["blocked"] as? Bool) ?? false

    nameLabel.text = nameShow.isEmpty ? "用户" : nameShow
    nameLabel.font = TiebaSimpleText.font(size: 22, weight: .heavy)
    nameLabel.textColor = text
    handleLabel.text = name.isEmpty ? "贴吧UID：\(uidText)" : "@\(name)"
    handleLabel.font = TiebaSimpleText.font(size: 15, weight: .regular)
    handleLabel.textColor = tertiary

    applyBadges(tint: tint)
    applyMeta(
      sex: sex, uidText: uidText, ip: showsIp ? ip : "", tbAge: tbAge,
      text: secondary, tertiary: tertiary, tint: tint
    )

    introLabel.text = intro
    introLabel.font = TiebaSimpleText.font(size: 15, weight: .regular)
    introLabel.textColor = secondary

    let showActions = isLoggedIn && !isOwn
    headerRow.actionRow.isHidden = !showActions
    if showActions {
      followButton.configure(
        title: isFollowing ? "已关注" : "关注",
        systemImage: isFollowing ? "person.badge.minus" : "person.badge.plus",
        prominent: !isFollowing,
        tint: tint
      )
      blockButton.configure(
        title: isBlocked ? "已拉黑" : "拉黑",
        systemImage: "nosign",
        prominent: false,
        tint: tint
      )
    }

    followsStat.configure(
      value: TiebaForumFormat.count(TiebaSimpleRowParser.double(spec["concernNum"]) ?? 0),
      label: "关注", valueColor: text, labelColor: tertiary
    )
    fansStat.configure(
      value: TiebaForumFormat.count(TiebaSimpleRowParser.double(spec["fansNum"]) ?? 0),
      label: "粉丝", valueColor: text, labelColor: tertiary
    )
    agreeStat.configure(
      value: TiebaForumFormat.count(TiebaSimpleRowParser.double(spec["agreeNum"]) ?? 0),
      label: "获赞", valueColor: text, labelColor: tertiary
    )

    // 分段：标签/值成对，选中项按 value 反查（下标会随过滤错位；标签与值不同名）。
    let labels = (spec["tabs"] as? [String]) ?? []
    let values = (spec["tabValues"] as? [String]) ?? []
    tabs = zip(labels, values).map { (label: $0.0, value: $0.1) }
    if tabs.map(\.label) != segmentTitles {
      segmentTitles = tabs.map(\.label)
      segment.removeAllSegments()
      for (index, tab) in tabs.enumerated() {
        segment.insertSegment(withTitle: tab.label, at: index, animated: false)
      }
    }
    if let value = TiebaSimpleRowParser.nonEmpty(spec["tabValue"]),
      let index = tabs.firstIndex(where: { $0.value == value }) {
      segment.selectedSegmentIndex = index
    }

    headerRow.avatarView.configure(
      url: portrait.isEmpty ? "" : TiebaSimpleRowParser.avatarURL(portrait)?.absoluteString ?? portrait,
      initial: nameShow.isEmpty ? "?" : String(nameShow.prefix(2))
    )
    heightCache = nil
    setNeedsLayout()
  }

  private func applyBadges(tint: UIColor) {
    let bazhu = TiebaSimpleRowParser.nonEmpty(spec["bazhuDesc"])
    let god = TiebaSimpleRowParser.nonEmpty(spec["godField"])
    for view in badgeRow.arrangedSubviews {
      badgeRow.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
    if let bazhu {
      badgeRow.addArrangedSubview(TiebaProfileBadgeView(icon: "checkmark.seal.fill", text: bazhu, tint: tint))
    }
    if let god {
      badgeRow.addArrangedSubview(TiebaProfileBadgeView(icon: "rosette", text: god, tint: tint))
    }
  }

  private func applyMeta(
    sex: Int,
    uidText: String,
    ip: String,
    tbAge: String,
    text: UIColor,
    tertiary: UIColor,
    tint: UIColor
  ) {
    // 性别文案/配色（旧页：男 = tint，女 = danger，其余不显示）。
    switch sex {
    case 1:
      genderItem.configure(icon: "person.fill", text: "男", color: tint)
      genderItem.isHidden = false
    case 2:
      genderItem.configure(icon: "person.fill", text: "女", color: .systemPink)
      genderItem.isHidden = false
    default:
      genderItem.isHidden = true
    }
    if uidText.isEmpty {
      uidItem.isHidden = true
    } else {
      uidItem.configure(icon: "doc.on.doc", text: "UID \(uidText)", color: tertiary)
      uidItem.isHidden = false
      uidItem.accessibilityLabel = "复制贴吧UID \(uidText)"
    }
    ipItem.isHidden = ip.isEmpty
    if !ip.isEmpty { ipItem.configure(icon: "location.fill", text: "IP \(ip)", color: tertiary) }
    ageItem.isHidden = tbAge.isEmpty
    if !tbAge.isEmpty { ageItem.configure(icon: "hourglass", text: "\(tbAge)年吧龄", color: tertiary) }
  }

  // MARK: - 事件

  @objc private func handleAvatarTap() {
    TiebaSceneHaptics.fire("press")
    onAction?(.userProfile(.avatar), avatarPayload())
  }

  /// 头像窗口矩形（原生查看器转场起点；64pt 方图）：视图测量值 → payload 字典。
  private func avatarPayload() -> [String: Any] {
    let avatar = headerRow.avatarView
    let frame = avatar.convert(avatar.bounds, to: nil)
    return [
      "frameX": frame.minX, "frameY": frame.minY,
      "frameW": frame.width, "frameH": frame.height,
    ]
  }

  @objc private func handleFollow() {
    TiebaSceneHaptics.fire("press")
    onAction?(.userProfile(.follow), [:])
  }
  @objc private func handleBlock() {
    TiebaSceneHaptics.fire("destructive")
    onAction?(.userProfile(.block), [:])
  }
  @objc private func handleCopyUid() {
    TiebaSceneHaptics.fire("press")
    onAction?(.userProfile(.copyUid), [:])
  }
  @objc private func handleOpenFollows() {
    TiebaSceneHaptics.fire("press")
    onAction?(.userProfile(.social(mode: "follows")), [:])
  }
  @objc private func handleOpenFans() {
    TiebaSceneHaptics.fire("press")
    onAction?(.userProfile(.social(mode: "fans")), [:])
  }

  @objc private func handleSegmentChange() {
    TiebaSceneHaptics.fire("segment")
    let index = segment.selectedSegmentIndex
    guard index >= 0, index < tabs.count else { return }
    onAction?(.userProfile(.tab(value: tabs[index].value)), [:])
  }
}

// MARK: - 小件

/// 认证徽章（图标 + 文案，底 = 主色 12%）。
private final class TiebaProfileBadgeView: UIView {
  init(icon: String, text: String, tint: UIColor) {
    super.init(frame: .zero)
    let iconView = UIImageView(
      image: UIImage(
        systemName: icon,
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .regular)
      )
    )
    iconView.tintColor = tint
    let label = UILabel()
    label.text = text
    label.font = TiebaSimpleText.font(size: 11, weight: .semibold)
    label.textColor = tint
    label.numberOfLines = 1
    let stack = UIStackView(arrangedSubviews: [iconView, label])
    stack.axis = .horizontal
    stack.spacing = 4
    stack.alignment = .center
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      stack.topAnchor.constraint(equalTo: topAnchor, constant: 3),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
    ])
    backgroundColor = tint.withAlphaComponent(0.12)
    layer.cornerRadius = 8
    layer.cornerCurve = .continuous
    clipsToBounds = true
    isAccessibilityElement = true
    accessibilityLabel = text
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Meta 行的一项（图标 + 13/500 文案）；UID 项可点（复制）。
private final class TiebaProfileMetaItem: UIControl {
  private let iconView = UIImageView()
  private let label = UILabel()

  override init(frame: CGRect) {
    super.init(frame: frame)
    iconView.contentMode = .scaleAspectFit
    label.numberOfLines = 1
    label.lineBreakMode = .byTruncatingTail
    let stack = UIStackView(arrangedSubviews: [iconView, label])
    stack.axis = .horizontal
    stack.spacing = 4
    stack.alignment = .center
    stack.isUserInteractionEnabled = false
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(icon: String, text: String, color: UIColor) {
    iconView.image = UIImage(
      systemName: icon,
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .regular)
    )
    iconView.tintColor = color
    label.text = text
    label.font = TiebaSimpleText.font(size: 13, weight: .medium)
    label.textColor = color
  }
}

/// 关注 / 拉黑按钮（小尺寸胶囊；关注=Filled、已关注=Gray、拉黑=Gray）。
private final class TiebaProfileActionButton: UIButton {
  func configure(title: String, systemImage: String, prominent: Bool, tint: UIColor) {
    var config = prominent
      ? UIButton.Configuration.filled()
      : UIButton.Configuration.gray()
    config.title = title
    config.image = UIImage(
      systemName: systemImage,
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
    )
    config.imagePadding = 4
    config.buttonSize = .small
    config.cornerStyle = .capsule
    if prominent { config.baseBackgroundColor = tint }
    configuration = config
    accessibilityLabel = title
  }
}
