import UIKit

/// 吧成员（原 src/app/forum/[name]/members.tsx）：分段「成员 | 等级排行」。
/// 成员段 = 我的会员卡（isLike && userLevel > 0）+ 分组网格；排行段 = 分页行
/// 列表 + 底部加载更多。数据走 TiebaForumAPI（proto 会员信息 + web 兜底/排行）。
final class TiebaForumMembersViewController: UIViewController {
  private enum Segment: Int {
    case members
    case rank
  }

  private enum LoadState: Equatable {
    case loading
    case empty
    case error(String)
    case content
  }

  private enum Section: Hashable {
    case myCard
    case group(Int)
    case rank
  }

  private enum Item: Hashable {
    case card
    case member(group: Int, index: Int)
    case rank(index: Int)
  }

  private static let headerKind = "members-header"
  private static let footerKind = "members-footer"
  /// 原 usePagedList maxItems：排行驻留上限 200 条（超出丢最旧）。
  private static let maxRankItems = 200

  private let forumName: String
  private let forumId: String

  private let segmented = UISegmentedControl(items: ["成员", "等级排行"])
  private let stateView = UIContentUnavailableView(configuration: .loading())
  /// 首屏骨架：成员段 = card count 6、排行段 = row count 8（原 members.tsx 同判据）
  private let skeletonView = TiebaSkeletonList(variant: .card, count: 6)
  private let refreshControl = UIRefreshControl()
  private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
  private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
  private var sectionKinds: [Section] = []
  /// 页脚由数据源按需创建，状态变化（加载中/到底）要直接回写（diffable 不会
  /// 因 hasMore 变化重配已显示的 supplementary）。
  private weak var rankFooterView: RankFooterView?

  private var groups: [TiebaForumAPI.TiebaForumMembers.Group] = []
  private var myInfo: TiebaForumAPI.TiebaForumMembers.MyInfo?
  private var membersState: LoadState = .loading
  private var loadingMembers = false

  private var rankItems: [TiebaForumAPI.TiebaForumRankUser] = []
  private var rankState: LoadState = .loading
  private var rankPage = 1
  private var rankHasMore = false
  private var rankLoadedOnce = false
  private var loadingRank = false

  init(name: String, forumId: String) {
    self.forumName = name
    self.forumId = forumId
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    // = 旧 colors.background（浅 #F2F2F7 / 深 #000）；卡片用 palette.card 才对比得出来
    view.backgroundColor = .systemGroupedBackground

    segmented.selectedSegmentIndex = Segment.members.rawValue
    segmented.translatesAutoresizingMaskIntoConstraints = false
    segmented.addTarget(self, action: #selector(segmentChanged), for: .valueChanged)

    collectionView.translatesAutoresizingMaskIntoConstraints = false
    collectionView.backgroundColor = .clear
    collectionView.contentInsetAdjustmentBehavior = .never
    collectionView.alwaysBounceVertical = true
    collectionView.refreshControl = refreshControl
    collectionView.delegate = self
    refreshControl.tintColor = TiebaNavigator.shared.chromeTheme.tint
    refreshControl.addTarget(self, action: #selector(handleRefresh), for: .valueChanged)
    registerCells()

    stateView.translatesAutoresizingMaskIntoConstraints = false
    skeletonView.isHidden = true
    view.addSubview(segmented)
    view.addSubview(collectionView)
    view.addSubview(stateView)
    view.addSubview(skeletonView)
    NSLayoutConstraint.activate([
      segmented.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
      segmented.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
      segmented.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
      collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      collectionView.topAnchor.constraint(equalTo: segmented.bottomAnchor, constant: 4),
      collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      stateView.leadingAnchor.constraint(equalTo: collectionView.leadingAnchor),
      stateView.trailingAnchor.constraint(equalTo: collectionView.trailingAnchor),
      stateView.topAnchor.constraint(equalTo: collectionView.topAnchor),
      stateView.bottomAnchor.constraint(equalTo: collectionView.bottomAnchor),
      skeletonView.leadingAnchor.constraint(equalTo: collectionView.leadingAnchor),
      skeletonView.trailingAnchor.constraint(equalTo: collectionView.trailingAnchor),
      skeletonView.topAnchor.constraint(equalTo: collectionView.topAnchor),
      skeletonView.bottomAnchor.constraint(equalTo: collectionView.bottomAnchor),
    ])

    makeDataSource()
    loadMembers()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    collectionView.contentInset.bottom = view.safeAreaInsets.bottom + 24
  }

  private func registerCells() {
    collectionView.register(MemberCardCell.self, forCellWithReuseIdentifier: MemberCardCell.reuseIdentifier)
    collectionView.register(MemberGridCell.self, forCellWithReuseIdentifier: MemberGridCell.reuseIdentifier)
    collectionView.register(RankRowCell.self, forCellWithReuseIdentifier: RankRowCell.reuseIdentifier)
    collectionView.register(
      MemberGroupHeaderView.self,
      forSupplementaryViewOfKind: Self.headerKind,
      withReuseIdentifier: MemberGroupHeaderView.reuseIdentifier
    )
    collectionView.register(
      RankFooterView.self,
      forSupplementaryViewOfKind: Self.footerKind,
      withReuseIdentifier: RankFooterView.reuseIdentifier
    )
  }

  // MARK: - 数据

  /// 成员段：proto getMemberInfo 为主；proto 空/失败时落 web 兜底（解析产物无
  /// uid，点击不跳转）。全链路失败且没有任何「我的会员信息」时才报错（原判据）。
  private func loadMembers() {
    guard !forumId.isEmpty else {
      refreshControl.endRefreshing()
      membersState = .empty
      render()
      return
    }
    guard !loadingMembers else {
      refreshControl.endRefreshing()
      return
    }
    loadingMembers = true
    let wasRefreshing = refreshControl.isRefreshing
    if groups.isEmpty { membersState = .loading }
    render()
    Task { @MainActor in
      var loaded: TiebaForumAPI.TiebaForumMembers?
      do {
        loaded = try await TiebaForumAPI.members(forumId: forumId)
      } catch {
        loaded = nil
      }
      myInfo = loaded?.myInfo
      groups = loaded?.groups ?? []
      if groups.isEmpty {
        do {
          let fallback = try await TiebaForumAPI.memberUsers(forumName: forumName)
          if !fallback.isEmpty {
            groups = [TiebaForumAPI.TiebaForumMembers.Group(type: "member", num: fallback.count, members: fallback)]
          }
          membersState = groups.isEmpty ? .empty : .content
        } catch {
          membersState = (myInfo == nil && groups.isEmpty) ? .error(message(for: error)) : .empty
        }
      } else {
        membersState = .content
      }
      loadingMembers = false
      render()
      if wasRefreshing {
        refreshControl.endRefreshing()
        TiebaSceneHaptics.fire("toggle")
      }
    }
  }

  /// 等级排行：首次切到该段才加载；空页 = 到底（HTML 无 has_more 标记）。
  private func loadRank(page: Int, refresh: Bool = false) {
    guard !loadingRank else {
      refreshControl.endRefreshing()
      return
    }
    loadingRank = true
    let wasRefreshing = refreshControl.isRefreshing
    if rankItems.isEmpty { rankState = .loading }
    render()
    Task { @MainActor in
      do {
        let items = try await TiebaForumAPI.rankUsers(forumName: forumName, pn: page)
        rankItems = refresh
          ? Array(items.prefix(Self.maxRankItems))
          : Array((rankItems + items).suffix(Self.maxRankItems))
        rankPage = page
        rankHasMore = !items.isEmpty
        rankState = rankItems.isEmpty ? .empty : .content
      } catch {
        if rankItems.isEmpty { rankState = .error(message(for: error)) }
      }
      loadingRank = false
      render()
      if wasRefreshing {
        refreshControl.endRefreshing()
        TiebaSceneHaptics.fire("toggle")
      } else {
        loadMoreIfNeeded()
      }
    }
  }

  private func loadMore() {
    guard rankHasMore, !loadingRank, rankItems.count < Self.maxRankItems else { return }
    loadRank(page: rankPage + 1)
  }

  /// 首屏不满一屏时 footer 会一直可见，willDisplay 不再重发——补一次。
  private func loadMoreIfNeeded() {
    guard segmented.selectedSegmentIndex == Segment.rank.rawValue, rankHasMore, !loadingRank else { return }
    collectionView.layoutIfNeeded()
    guard collectionView.collectionViewLayout.collectionViewContentSize.height <= collectionView.bounds.height
    else { return }
    loadMore()
  }

  @objc private func handleRefresh() {
    if segmented.selectedSegmentIndex == Segment.rank.rawValue {
      rankLoadedOnce = true
      loadRank(page: 1, refresh: true)
    } else {
      loadMembers()
    }
  }

  @objc private func segmentChanged() {
    TiebaSceneHaptics.fire("toggle")
    if segmented.selectedSegmentIndex == Segment.rank.rawValue, !rankLoadedOnce {
      rankLoadedOnce = true
      loadRank(page: 1, refresh: true)
      return
    }
    render()
  }

  // MARK: - 渲染

  private func render() {
    let rank = segmented.selectedSegmentIndex == Segment.rank.rawValue
    switch rank ? rankState : membersState {
    case .content:
      stateView.isHidden = true
      collectionView.isHidden = false
      skeletonView.isHidden = true
    case .loading:
      // 首屏加载：排行段 row count 8（16/12 内边距）、成员段 card count 6
      collectionView.isHidden = true
      skeletonView.variant = rank ? .row : .card
      skeletonView.count = rank ? 8 : 6
      skeletonView.contentInsets = rank
        ? UIEdgeInsets(top: 12, left: 16, bottom: 24, right: 16)
        : UIEdgeInsets(top: 0, left: 0, bottom: 24, right: 0)
      skeletonView.isHidden = false
      showState(.loading)
    case .empty:
      collectionView.isHidden = true
      skeletonView.isHidden = true
      showState(rank ? .emptyRank : .emptyMembers)
    case .error(let message):
      collectionView.isHidden = true
      skeletonView.isHidden = true
      showState(.error(message, rank: rank))
    }
    applySnapshot()
  }

  private enum StateKind {
    case loading
    case emptyMembers
    case emptyRank
    case error(String, rank: Bool)
  }

  private func showState(_ kind: StateKind) {
    switch kind {
    case .loading:
      stateView.configuration = UIContentUnavailableConfiguration.loading()
      stateView.isHidden = false
    case .emptyMembers:
      stateView.showEmpty(
        image: "person.3",
        text: "暂无成员信息",
        secondaryText: "这个吧还没有公开成员数据",
        buttonTitle: "重试",
        onButton: { [weak self] in self?.retryMembers() }
      )
    case .emptyRank:
      // 空态下列表被状态视图盖住，下拉刷新够不到——补一个重试入口。
      stateView.showEmpty(
        image: "trophy",
        text: "暂无排行数据",
        secondaryText: "等级排行解析失败，或该吧暂无公开排行",
        buttonTitle: "重试",
        onButton: { [weak self] in self?.retryRank() }
      )
    case .error(let message, let rank):
      stateView.showError(message) { [weak self] in
        if rank {
          self?.retryRank()
        } else {
          self?.retryMembers()
        }
      }
    }
  }

  private func retryMembers() {
    TiebaSceneHaptics.fire("press")
    loadMembers()
  }

  private func retryRank() {
    TiebaSceneHaptics.fire("press")
    loadRank(page: 1, refresh: true)
  }

  private func applySnapshot() {
    var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
    var kinds: [Section] = []
    if segmented.selectedSegmentIndex == Segment.rank.rawValue {
      snapshot.appendSections([.rank])
      kinds.append(.rank)
      snapshot.appendItems((0..<rankItems.count).map { Item.rank(index: $0) }, toSection: .rank)
    } else {
      if let myInfo, myInfo.isLike, myInfo.userLevel > 0 {
        snapshot.appendSections([.myCard])
        kinds.append(.myCard)
        snapshot.appendItems([.card], toSection: .myCard)
      }
      for (index, group) in groups.enumerated() {
        let section = Section.group(index)
        snapshot.appendSections([section])
        kinds.append(section)
        snapshot.appendItems(group.members.indices.map { Item.member(group: index, index: $0) }, toSection: section)
      }
    }
    sectionKinds = kinds
    dataSource.apply(snapshot, animatingDifferences: false)
    rankFooterView?.configure(hasMore: rankHasMore, loading: loadingRank)
    // 段切换可能只有 section 标识变化（分组段 ↔ 排行段都为 1 个 section），
    // 显式失效一次，保证布局按新 section 类型重算。
    collectionView.collectionViewLayout.invalidateLayout()
  }

  private func makeDataSource() {
    dataSource = UICollectionViewDiffableDataSource<Section, Item>(
      collectionView: collectionView
    ) { [weak self] collectionView, indexPath, item in
      guard let self else { return nil }
      switch item {
      case .card:
        let cell = collectionView.dequeueReusableCell(
          withReuseIdentifier: MemberCardCell.reuseIdentifier,
          for: indexPath
        ) as? MemberCardCell
        cell?.configure(info: self.myInfo, forumName: self.forumName)
        return cell
      case .member(let group, let index):
        // apply 是异步落地的：数据可能在上一份快照应用前又变了，越界即跳过。
        guard group < self.groups.count, index < self.groups[group].members.count else { return nil }
        let cell = collectionView.dequeueReusableCell(
          withReuseIdentifier: MemberGridCell.reuseIdentifier,
          for: indexPath
        ) as? MemberGridCell
        cell?.configure(member: self.groups[group].members[index])
        return cell
      case .rank(let index):
        guard index < self.rankItems.count else { return nil }
        let cell = collectionView.dequeueReusableCell(
          withReuseIdentifier: RankRowCell.reuseIdentifier,
          for: indexPath
        ) as? RankRowCell
        cell?.configure(user: self.rankItems[index], rank: index + 1)
        return cell
      }
    }
    dataSource.supplementaryViewProvider = { [weak self] collectionView, kind, indexPath in
      guard let self else { return nil }
      switch kind {
      case Self.headerKind:
        let groupIndex = indexPath.section - self.groupSectionOffset
        guard groupIndex >= 0, groupIndex < self.groups.count else { return nil }
        let view = collectionView.dequeueReusableSupplementaryView(
          ofKind: kind,
          withReuseIdentifier: MemberGroupHeaderView.reuseIdentifier,
          for: indexPath
        ) as? MemberGroupHeaderView
        let group = self.groups[groupIndex]
        view?.configure(title: Self.groupTitle(group.type), count: group.num)
        return view
      case Self.footerKind:
        let view = collectionView.dequeueReusableSupplementaryView(
          ofKind: kind,
          withReuseIdentifier: RankFooterView.reuseIdentifier,
          for: indexPath
        ) as? RankFooterView
        view?.onLoadMore = { [weak self] in self?.loadMore() }
        view?.configure(hasMore: self.rankHasMore, loading: self.loadingRank)
        self.rankFooterView = view
        return view
      default:
        return nil
      }
    }
  }

  /// 网格段前面可能有一个会员卡 section（分组区号要减去它）。
  private var groupSectionOffset: Int {
    myInfo?.isLike == true && (myInfo?.userLevel ?? 0) > 0 ? 1 : 0
  }

  private static func groupTitle(_ type: String) -> String {
    switch type {
    case "manager": return "吧务成员"
    case "god": return "本吧大神"
    case "active": return "活跃成员"
    case "member": return "普通成员"
    case "friend": return "互关好友"
    default: return type.isEmpty ? "成员" : type
    }
  }

  private func message(for error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? "网络错误，请稍后重试"
  }

  // MARK: - 布局

  /// 3 列网格（旧页公式：宽 - 24 / 96，2...6 列）。
  private static func gridColumns(for width: CGFloat) -> Int {
    max(2, min(6, Int((width - 24) / 96)))
  }

  private func makeLayout() -> UICollectionViewCompositionalLayout {
    UICollectionViewCompositionalLayout { [weak self] index, environment in
      guard let self, index < self.sectionKinds.count else { return Self.plainSection() }
      switch self.sectionKinds[index] {
      case .myCard:
        return Self.cardSection()
      case .group:
        return Self.gridSection(width: environment.container.effectiveContentSize.width)
      case .rank:
        return Self.rankSection()
      }
    }
  }

  private static func plainSection() -> NSCollectionLayoutSection {
    let item = NSCollectionLayoutItem(
      layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(1))
    )
    return NSCollectionLayoutSection(
      group: NSCollectionLayoutGroup.horizontal(
        layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(1)),
        subitems: [item]
      )
    )
  }

  private static func cardSection() -> NSCollectionLayoutSection {
    let item = NSCollectionLayoutItem(
      layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(76))
    )
    let section = NSCollectionLayoutSection(
      group: NSCollectionLayoutGroup.horizontal(
        layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(76)),
        subitems: [item]
      )
    )
    section.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 16, bottom: 6, trailing: 16)
    return section
  }

  private static func gridSection(width: CGFloat) -> NSCollectionLayoutSection {
    let columns = gridColumns(for: width)
    let item = NSCollectionLayoutItem(
      layoutSize: NSCollectionLayoutSize(
        widthDimension: .fractionalWidth(1),
        heightDimension: .estimated(108)
      )
    )
    let group = NSCollectionLayoutGroup.horizontal(
      layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(108)),
      repeatingSubitem: item,
      count: columns
    )
    group.interItemSpacing = .fixed(8)
    let section = NSCollectionLayoutSection(group: group)
    section.interGroupSpacing = 4
    section.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16)
    section.boundarySupplementaryItems = [
      NSCollectionLayoutBoundarySupplementaryItem(
        layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(40)),
        elementKind: headerKind,
        alignment: .top
      )
    ]
    return section
  }

  private static func rankSection() -> NSCollectionLayoutSection {
    let item = NSCollectionLayoutItem(
      layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(64))
    )
    let group = NSCollectionLayoutGroup.horizontal(
      layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(64)),
      subitems: [item]
    )
    let section = NSCollectionLayoutSection(group: group)
    section.interGroupSpacing = 8
    section.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 18, bottom: 8, trailing: 18)
    section.boundarySupplementaryItems = [
      NSCollectionLayoutBoundarySupplementaryItem(
        layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(44)),
        elementKind: footerKind,
        alignment: .bottom
      )
    ]
    return section
  }
}

// MARK: - 数据源 / 代理

extension TiebaForumMembersViewController: UICollectionViewDelegate {
  func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
    collectionView.deselectItem(at: indexPath, animated: false)
    guard case .member(let group, let index)? = dataSource.itemIdentifier(for: indexPath),
      group < groups.count, index < groups[group].members.count
    else { return }
    let member = groups[group].members[index]
    guard !member.userId.isEmpty else { return }
    TiebaSceneHaptics.fire("press")
    TiebaNavigator.shared.navigate(.user(uid: member.userId))
  }

  func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
    guard case .member(let group, let index)? = dataSource.itemIdentifier(for: indexPath),
      group < groups.count, index < groups[group].members.count
    else { return false }
    return !groups[group].members[index].userId.isEmpty
  }

  func collectionView(
    _ collectionView: UICollectionView,
    willDisplay cell: UICollectionViewCell,
    forItemAt indexPath: IndexPath
  ) {
    if case .rank(let index)? = dataSource.itemIdentifier(for: indexPath), index == rankItems.count - 1 {
      loadMore()
    }
  }

  func collectionView(
    _ collectionView: UICollectionView,
    willDisplaySupplementaryView view: UICollectionReusableView,
    forElementKind elementKind: String,
    at indexPath: IndexPath
  ) {
    if elementKind == Self.footerKind { loadMore() }
  }
}

// MARK: - 单元格

/// 带内边距的等级徽标（chip 形态；未设背景色时就是普通文字标签）。
final class TiebaMemberBadgeLabel: UILabel {
  var contentInsets = UIEdgeInsets(top: 1.5, left: 7, bottom: 1.5, right: 7)

  override func drawText(in rect: CGRect) {
    super.drawText(in: rect.inset(by: contentInsets))
  }

  override var intrinsicContentSize: CGSize {
    let size = super.intrinsicContentSize
    return CGSize(
      width: size.width + contentInsets.left + contentInsets.right,
      height: size.height + contentInsets.top + contentInsets.bottom
    )
  }
}

/// 「我的会员卡」：Lv 徽标 + 我在吧名 + 等级/进度 + 星标。
final class MemberCardCell: UICollectionViewCell {
  static let reuseIdentifier = "members-card"

  private let badge = TiebaMemberBadgeLabel()
  private let titleLabel = UILabel()
  private let subtitleLabel = UILabel()
  private let starView = UIImageView()
  private let progress = UIProgressView(progressViewStyle: .default)
  private let card = UIView()

  override init(frame: CGRect) {
    super.init(frame: frame)
    card.translatesAutoresizingMaskIntoConstraints = false
    card.layer.cornerRadius = 20
    card.layer.cornerCurve = .continuous
    // 卡片底 = 旧 colors.groupFill（自适应浅/深；.secondarySystemBackground
    // 在浅色下与页面背景同色，卡片会消失）。
    card.backgroundColor = TiebaSimpleRowPalette.default.groupFill
    contentView.addSubview(card)

    badge.font = .systemFont(ofSize: 12, weight: .bold)
    badge.layer.cornerRadius = 8
    badge.layer.masksToBounds = true
    badge.setContentHuggingPriority(.required, for: .horizontal)

    titleLabel.font = .preferredFont(forTextStyle: .subheadline)
    titleLabel.adjustsFontForContentSizeCategory = true
    titleLabel.textColor = .label
    subtitleLabel.font = .preferredFont(forTextStyle: .caption1)
    subtitleLabel.adjustsFontForContentSizeCategory = true
    subtitleLabel.textColor = .tertiaryLabel

    starView.image = UIImage(
      systemName: "star.fill",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .regular)
    )
    starView.tintColor = .systemOrange
    starView.setContentHuggingPriority(.required, for: .horizontal)

    let textStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
    textStack.axis = .vertical
    textStack.spacing = 1
    textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)

    let topRow = UIStackView(arrangedSubviews: [badge, textStack, starView])
    topRow.axis = .horizontal
    topRow.alignment = .center
    topRow.spacing = 10

    progress.progressTintColor = .tintColor
    progress.trackTintColor = TiebaSimpleRowPalette.default.surfaceSecondary
    progress.translatesAutoresizingMaskIntoConstraints = false

    let stack = UIStackView(arrangedSubviews: [topRow, progress])
    stack.axis = .vertical
    stack.spacing = 11
    stack.translatesAutoresizingMaskIntoConstraints = false
    card.addSubview(stack)

    NSLayoutConstraint.activate([
      card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      card.topAnchor.constraint(equalTo: contentView.topAnchor),
      card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
      stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
      stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
      stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 13),
      stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -13),
      progress.heightAnchor.constraint(equalToConstant: 4),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(info: TiebaForumAPI.TiebaForumMembers.MyInfo?, forumName: String) {
    guard let info else { return }
    let tint = TiebaNavigator.shared.chromeTheme.tint
    progress.progressTintColor = tint
    badge.textColor = tint
    badge.backgroundColor = tint.withAlphaComponent(0.15)
    badge.text = "Lv.\(info.userLevel)"
    titleLabel.text = "我在\(forumName)吧"
    var subtitle = info.levelName.isEmpty ? " " : info.levelName
    if info.levelupScore > 0 {
      subtitle += "  ·  \(info.curScore)/\(info.levelupScore)"
    }
    subtitleLabel.text = subtitle
    let showsProgress = info.levelupScore > 0
    progress.isHidden = !showsProgress
    progress.setProgress(Float(info.progress), animated: false)
  }
}

/// 成员网格单元：头像 + 昵称 + 等级徽标/等级名。
final class MemberGridCell: UICollectionViewCell {
  static let reuseIdentifier = "members-grid"

  private let avatar = TiebaForumAvatarView(size: 58)
  private let nameLabel = UILabel()
  private let levelNameLabel = UILabel()
  private let levelBadge = TiebaMemberBadgeLabel()

  override init(frame: CGRect) {
    super.init(frame: frame)
    nameLabel.font = .preferredFont(forTextStyle: .footnote)
    nameLabel.adjustsFontForContentSizeCategory = true
    nameLabel.textColor = .label
    nameLabel.textAlignment = .center
    nameLabel.numberOfLines = 1
    levelNameLabel.font = .preferredFont(forTextStyle: .caption2)
    levelNameLabel.textColor = .tertiaryLabel
    levelNameLabel.textAlignment = .center
    levelNameLabel.numberOfLines = 1
    levelBadge.font = .systemFont(ofSize: 10, weight: .bold)
    levelBadge.layer.cornerRadius = 8
    levelBadge.layer.masksToBounds = true

    let stack = UIStackView(arrangedSubviews: [avatar, nameLabel, levelBadge, levelNameLabel])
    stack.axis = .vertical
    stack.alignment = .center
    stack.spacing = 5
    stack.setCustomSpacing(8, after: avatar)
    stack.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
      stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
      stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -10),
      stack.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 4),
      stack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -4),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(member: TiebaForumAPI.TiebaForumMembers.Member) {
    let displayName = member.displayName
    avatar.configure(url: member.portrait, initial: displayName)
    nameLabel.text = displayName
    let hasLevel = member.userLevel > 0
    levelBadge.isHidden = !hasLevel
    levelNameLabel.isHidden = hasLevel
    if hasLevel {
      let tint = TiebaNavigator.shared.chromeTheme.tint
      levelBadge.text = "Lv.\(member.userLevel)"
      levelBadge.textColor = tint
      levelBadge.backgroundColor = tint.withAlphaComponent(0.15)
    } else {
      levelNameLabel.text = member.levelName.isEmpty ? " " : member.levelName
    }
    isAccessibilityElement = true
    accessibilityLabel = displayName
    accessibilityTraits = .button
  }
}

/// 等级排行行：名次 + 头像 + 昵称/贡献 + 等级徽标。
final class RankRowCell: UICollectionViewCell {
  static let reuseIdentifier = "members-rank"

  private static let hotColors: [UIColor] = [.systemRed, .systemOrange, .systemYellow]

  private let card = UIView()
  private let rankLabel = UILabel()
  private let avatar = TiebaForumAvatarView(size: 40)
  private let nameLabel = UILabel()
  private let crownView = UIImageView()
  private let subtitleLabel = UILabel()
  private let levelBadge = TiebaMemberBadgeLabel()
  private let placeholderSlot = UIImageView()

  override init(frame: CGRect) {
    super.init(frame: frame)
    card.translatesAutoresizingMaskIntoConstraints = false
    card.layer.cornerRadius = 20
    card.layer.cornerCurve = .continuous
    card.backgroundColor = TiebaSimpleRowPalette.default.base.card
    contentView.addSubview(card)

    rankLabel.font = .systemFont(ofSize: 17, weight: .heavy)
    rankLabel.textAlignment = .center
    rankLabel.setContentHuggingPriority(.required, for: .horizontal)

    nameLabel.font = .preferredFont(forTextStyle: .subheadline)
    nameLabel.adjustsFontForContentSizeCategory = true
    nameLabel.textColor = .label
    nameLabel.lineBreakMode = .byTruncatingTail
    subtitleLabel.font = .preferredFont(forTextStyle: .caption1)
    subtitleLabel.adjustsFontForContentSizeCategory = true
    subtitleLabel.textColor = .tertiaryLabel

    crownView.image = UIImage(
      systemName: "crown.fill",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .regular)
    )
    crownView.tintColor = .systemOrange
    crownView.setContentHuggingPriority(.required, for: .horizontal)

    levelBadge.font = .systemFont(ofSize: 11, weight: .bold)
    levelBadge.layer.cornerRadius = 8
    levelBadge.layer.masksToBounds = true

    placeholderSlot.image = UIImage(
      systemName: "person.fill",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .regular)
    )
    placeholderSlot.tintColor = .tertiaryLabel
    placeholderSlot.contentMode = .center
    placeholderSlot.setContentHuggingPriority(.required, for: .horizontal)

    let nameRow = UIStackView(arrangedSubviews: [nameLabel, crownView])
    nameRow.axis = .horizontal
    nameRow.alignment = .center
    nameRow.spacing = 6
    let textStack = UIStackView(arrangedSubviews: [nameRow, subtitleLabel])
    textStack.axis = .vertical
    textStack.spacing = 2
    textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)

    let row = UIStackView(arrangedSubviews: [rankLabel, avatar, textStack, levelBadge, placeholderSlot])
    row.axis = .horizontal
    row.alignment = .center
    row.spacing = 10
    row.translatesAutoresizingMaskIntoConstraints = false
    card.addSubview(row)

    NSLayoutConstraint.activate([
      card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      card.topAnchor.constraint(equalTo: contentView.topAnchor),
      card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
      rankLabel.widthAnchor.constraint(equalToConstant: 26),
      levelBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 48),
      placeholderSlot.widthAnchor.constraint(greaterThanOrEqualToConstant: 48),
      row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
      row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
      row.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
      row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(user: TiebaForumAPI.TiebaForumRankUser, rank: Int) {
    rankLabel.text = String(rank)
    rankLabel.textColor = rank <= 3 ? Self.hotColors[rank - 1] : .tertiaryLabel
    let displayName = user.userName.isEmpty ? "未知用户" : user.userName
    avatar.configure(url: "", initial: displayName)
    nameLabel.text = displayName
    crownView.isHidden = !user.isVip
    subtitleLabel.text = user.exp > 0 ? "贡献值 \(TiebaForumFormat.count(user.exp))" : (user.level > 0 ? "本吧等级成员" : "本吧吧友")
    let hasLevel = user.level > 0
    levelBadge.isHidden = !hasLevel
    placeholderSlot.isHidden = hasLevel
    if hasLevel {
      let tint = TiebaNavigator.shared.chromeTheme.tint
      levelBadge.text = "Lv.\(user.level)"
      levelBadge.textColor = tint
      levelBadge.backgroundColor = tint.withAlphaComponent(0.15)
    }
    isAccessibilityElement = true
    accessibilityLabel = "第\(rank)名 \(displayName)"
  }
}

/// 分组标题：色条 + 标题 + 人数 chip。
final class MemberGroupHeaderView: UICollectionReusableView {
  static let reuseIdentifier = "members-header"

  private let dot = UIView()
  private let titleLabel = UILabel()
  private let countChip = TiebaMemberBadgeLabel()

  override init(frame: CGRect) {
    super.init(frame: frame)
    dot.layer.cornerRadius = 2
    dot.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.font = .systemFont(ofSize: 15, weight: .bold)
    titleLabel.textColor = .label
    countChip.font = .systemFont(ofSize: 11, weight: .bold)
    countChip.textColor = .tertiaryLabel
    countChip.backgroundColor = TiebaSimpleRowPalette.default.surfaceSecondary
    countChip.layer.cornerRadius = 8
    countChip.layer.masksToBounds = true

    let spacer = UIView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let row = UIStackView(arrangedSubviews: [dot, titleLabel, spacer, countChip])
    row.axis = .horizontal
    row.alignment = .center
    row.spacing = 7
    row.translatesAutoresizingMaskIntoConstraints = false
    addSubview(row)
    NSLayoutConstraint.activate([
      dot.widthAnchor.constraint(equalToConstant: 4),
      dot.heightAnchor.constraint(equalToConstant: 14),
      row.leadingAnchor.constraint(equalTo: leadingAnchor),
      row.trailingAnchor.constraint(equalTo: trailingAnchor),
      row.topAnchor.constraint(equalTo: topAnchor, constant: 12),
      row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(title: String, count: Int) {
    dot.backgroundColor = TiebaNavigator.shared.chromeTheme.tint
    titleLabel.text = title
    countChip.text = count > 0 ? "\(count)人" : ""
    countChip.isHidden = count <= 0
  }
}

/// 排行页脚：加载中 / 加载更多（可点）/ 没有更多了（原 LoadMoreFooter 三态）。
final class RankFooterView: UICollectionReusableView {
  static let reuseIdentifier = "members-footer"

  private let spinner = UIActivityIndicatorView(style: .medium)
  private let button = UIButton(type: .system)
  var onLoadMore: (() -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    spinner.hidesWhenStopped = false
    button.addTarget(self, action: #selector(loadMoreTapped), for: .touchUpInside)
    let stack = UIStackView(arrangedSubviews: [spinner, button])
    stack.axis = .horizontal
    stack.alignment = .center
    stack.spacing = 6
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: centerYAnchor),
      stack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 6),
      stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -6),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(hasMore: Bool, loading: Bool) {
    spinner.color = TiebaNavigator.shared.chromeTheme.tint
    var config = UIButton.Configuration.plain()
    config.baseForegroundColor = .tertiaryLabel
    if loading {
      config.title = "加载中..."
      spinner.startAnimating()
      button.isEnabled = false
    } else if hasMore {
      config.title = "加载更多"
      config.baseForegroundColor = TiebaNavigator.shared.chromeTheme.tint
      spinner.stopAnimating()
      button.isEnabled = true
    } else {
      config.title = "没有更多了"
      spinner.stopAnimating()
      button.isEnabled = false
    }
    button.configuration = config
  }

  @objc private func loadMoreTapped() {
    TiebaSceneHaptics.fire("press")
    onLoadMore?()
  }
}
