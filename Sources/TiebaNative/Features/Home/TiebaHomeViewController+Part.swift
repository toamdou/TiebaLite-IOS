// TiebaHomeViewController 的第二片（由 TiebaHomeViewController.swift 拆出，逐字搬运；成员跨文件可见性只在确实被引用的那一处放宽）。

import UIKit

extension TiebaHomeViewController {
  func saveSortMode() {
    try? TiebaKvStore.shared.set(key: Self.sortKey, value: sortMode.rawValue)
  }
}

// MARK: - 列表代理

extension TiebaHomeViewController: UICollectionViewDelegate {
  /// B6①：列表滚动 = 内容位移。只做差分转发（无飞行体时一行就返回，不进热路径的重活）。
  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    let y = scrollView.contentOffset.y
    let delta = y - lastListOffsetY
    lastListOffsetY = y
    applyListShift(CGPoint(x: 0, y: -delta), isExternal: false)
  }

  func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
    collectionView.deselectItem(at: indexPath, animated: false)
    guard displayedForums.indices.contains(indexPath.item) else { return }
    TiebaSceneHaptics.fire("press")
    openForum(displayedForums[indexPath.item].forumName)
  }

  /// 首屏入场批次边界：首个布局趟里所有 willDisplay 走完（下个 runloop 清标志），
  /// 之后滚动回填的 cell 不再播入场。
  func collectionView(
    _ collectionView: UICollectionView,
    willDisplay cell: UICollectionViewCell,
    forItemAt indexPath: IndexPath
  ) {
    guard entrancePending, !entranceClearScheduled else { return }
    entranceClearScheduled = true
    DispatchQueue.main.async { [weak self] in
      self?.entrancePending = false
    }
  }
}

// MARK: - 吧单元格

final class TiebaHomeForumCell: UICollectionViewCell {
  static let reuseID = "TiebaHomeForumCell"

  var onUnfollow: (() -> Void)?

  /// B5（报告 37）：签到飞行体的源视图 = 本行的吧头像。源在 cell 里 ⇒ 飞行体不能在源里
  /// （cell 裁剪 + 复用），必须跑在 window 级的穿透覆盖容器上（见 TiebaFlightTransition）。
  var signFlightSourceView: UIView { avatar }

  private let card = UIView()
  private let avatar = TiebaForumAvatarView(size: 38)
  private let nameLabel = UILabel()
  private let metaLabel = UILabel()
  private let chip = UIView()
  private let chipStack = UIStackView()
  private let levelLabel = UILabel()
  private let checkIcon = UIImageView()
  private var playedEntrance = false

  override init(frame: CGRect) {
    super.init(frame: frame)
    card.layer.cornerRadius = 20
    card.layer.cornerCurve = .continuous
    card.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(card)
    nameLabel.font = TiebaSimpleText.font(size: 15, weight: .semibold)
    nameLabel.adjustsFontForContentSizeCategory = true
    nameLabel.numberOfLines = 1
    metaLabel.font = TiebaSimpleText.font(size: 12, weight: .regular)
    metaLabel.textColor = .tertiaryLabel
    levelLabel.font = TiebaSimpleText.font(size: 12, weight: .bold)
    checkIcon.contentMode = .center
    let textColumn = UIStackView(arrangedSubviews: [nameLabel, metaLabel])
    textColumn.axis = .vertical
    textColumn.spacing = 2
    textColumn.translatesAutoresizingMaskIntoConstraints = false
    chip.layer.cornerRadius = 4
    chip.layer.cornerCurve = .continuous
    chip.translatesAutoresizingMaskIntoConstraints = false
    chipStack.axis = .horizontal
    chipStack.spacing = 4
    chipStack.alignment = .center
    chipStack.translatesAutoresizingMaskIntoConstraints = false
    chipStack.addArrangedSubview(levelLabel)
    chipStack.addArrangedSubview(checkIcon)
    chip.addSubview(chipStack)
    avatar.translatesAutoresizingMaskIntoConstraints = false
    card.addSubview(avatar)
    card.addSubview(textColumn)
    card.addSubview(chip)
    NSLayoutConstraint.activate([
      card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      card.topAnchor.constraint(equalTo: contentView.topAnchor),
      card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
      avatar.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
      avatar.centerYAnchor.constraint(equalTo: card.centerYAnchor),
      textColumn.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 10),
      textColumn.centerYAnchor.constraint(equalTo: card.centerYAnchor),
      textColumn.trailingAnchor.constraint(lessThanOrEqualTo: chip.leadingAnchor, constant: -8),
      chip.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
      chip.centerYAnchor.constraint(equalTo: card.centerYAnchor),
      chipStack.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 6),
      chipStack.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -6),
      chipStack.topAnchor.constraint(equalTo: chip.topAnchor, constant: 4),
      chipStack.bottomAnchor.constraint(equalTo: chip.bottomAnchor, constant: -4),
    ])
    card.addInteraction(UIContextMenuInteraction(delegate: self))
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(forum: TiebaForumInfo) {
    card.backgroundColor = .secondarySystemGroupedBackground
    let tint = TiebaNavigator.shared.chromeTheme.tint
    avatar.configure(
      url: TiebaSimpleRowParser.avatarURL(forum.avatar)?.absoluteString ?? "",
      initial: forum.displayName.isEmpty ? "吧" : String(forum.displayName.prefix(1))
    )
    nameLabel.text = "\(forum.displayName)吧"
    metaLabel.text = forum.memberCount > 0 ? "\(TiebaForumFormat.count(forum.memberCount)) 关注" : nil
    metaLabel.isHidden = forum.memberCount <= 0
    levelLabel.text = forum.levelId > 0 ? "Lv.\(forum.levelId)" : nil
    // 等级色与帖子行同一套（Kotlin getIconColorByLevel）：不同等级不同颜色，
    // 不再统一用主题色（用户 2026-09-17 要求）。
    levelLabel.textColor = TiebaPostRowLayout.levelColor(forum.levelId) ?? tint
    checkIcon.image = UIImage(
      systemName: "checkmark",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .bold)
    )
    checkIcon.tintColor = tint
    checkIcon.isHidden = !forum.isSign
    chip.isHidden = forum.levelId <= 0 && !forum.isSign
    chip.backgroundColor = .tertiarySystemFill
    accessibilityLabel = "\(forum.displayName)吧"
  }

  /// 首屏入场（原 EntranceRow）：参数与其余三族共用 TiebaEntrance。
  func playEntrance(index: Int) {
    guard !playedEntrance else { return }
    playedEntrance = true
    TiebaEntrance.play(on: self, index: index)
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    // 复用复位是 TiebaEntrance 的明写契约：只清标记不清 layer 上的在途动画的话，
    // 首屏入场后立刻滚动，旧动画的 from 值（opacity 0 / y+12）会压住新行的内容。
    TiebaEntrance.cancel(on: self)
    playedEntrance = false
    alpha = 1
    transform = .identity
    onUnfollow = nil
  }
}

extension TiebaHomeForumCell: UIContextMenuInteractionDelegate {
  func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    configurationForMenuAtLocation location: CGPoint
  ) -> UIContextMenuConfiguration? {
    UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
      UIMenu(children: [
        UIAction(
          title: "取消关注",
          image: UIImage(systemName: "person.badge.minus"),
          attributes: .destructive
        ) { _ in self?.onUnfollow?() }
      ])
    }
  }
}

// MARK: - 最近访问药丸

final class TiebaHistoryPill: UIControl {
  private let avatar = TiebaForumAvatarView(size: 22)
  private let label = UILabel()

  override init(frame: CGRect) {
    super.init(frame: frame)
    layer.cornerRadius = 15
    layer.cornerCurve = .continuous
    backgroundColor = .tertiarySystemFill
    label.font = TiebaSimpleText.font(size: 13, weight: .medium)
    label.adjustsFontForContentSizeCategory = true
    label.numberOfLines = 1
    let stack = UIStackView(arrangedSubviews: [avatar, label])
    stack.axis = .horizontal
    stack.alignment = .center
    stack.spacing = 6
    stack.isUserInteractionEnabled = false
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
      stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
      label.widthAnchor.constraint(lessThanOrEqualToConstant: 140),
    ])
    isAccessibilityElement = true
    accessibilityTraits = .button
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(name: String, avatar portrait: String) {
    label.text = name
    avatar.configure(
      url: TiebaSimpleRowParser.avatarURL(portrait)?.absoluteString ?? "",
      initial: name.isEmpty ? "吧" : String(name.prefix(1))
    )
    accessibilityLabel = "进入\(name)吧"
  }

  override var isHighlighted: Bool {
    didSet { alpha = isHighlighted ? 0.7 : 1 }
  }
}

// MARK: - 状态列表项

/// 把 TiebaStateContentView 装成列表项的宿主 cell（报告 31 §一-1：空态/加载态是"列表里的一项"）。
/// 页面同时只存在一个状态项，所以状态视图实例由页面持有、这里只负责挂进来。
final class TiebaHomeStateCell: UICollectionViewCell {
  static let reuseID = "TiebaHomeStateCell"

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    contentView.backgroundColor = .clear
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func host(_ stateView: TiebaStateContentView?) {
    guard let stateView, stateView.superview !== contentView else { return }
    stateView.removeFromSuperview()
    stateView.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(stateView)
    NSLayoutConstraint.activate([
      stateView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      stateView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      stateView.topAnchor.constraint(equalTo: contentView.topAnchor),
      stateView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
    ])
  }
}

extension TiebaHomeViewController: UICollectionViewDelegateFlowLayout {
  /// 状态项高度 = 列表可见区高度（状态块因此在可见区居中，且列表仍可下拉刷新）；
  /// 吧卡片仍用 viewDidLayoutSubviews 算出的 itemSize。
  func collectionView(
    _ collectionView: UICollectionView,
    layout collectionViewLayout: UICollectionViewLayout,
    sizeForItemAt indexPath: IndexPath
  ) -> CGSize {
    guard dataSource?.itemIdentifier(for: indexPath) == Self.stateItemID else {
      return layout.itemSize
    }
    let inset = collectionView.adjustedContentInset
    return CGSize(
      width: max(collectionView.bounds.width - layout.sectionInset.left - layout.sectionInset.right, 0),
      height: max(collectionView.bounds.height - inset.top - inset.bottom, 320)
    )
  }
}

