// 发现 tab 的「热榜」段（原 src/components/explore/HotListContent.tsx）：热门话题
// 横向胶囊 + 分类 Tab + 排名帖列表；数据 TiebaFeedAPI.hotThreadList。
import UIKit

final class TiebaHotListViewController: UIViewController, TiebaTabReselectable {
  private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
  private let refreshControl = UIRefreshControl()
  private let stateView = TiebaStateContentView()
  private let pill = TiebaPhotoBrowserPillView()

  private var topics: [TiebaFeedAPI.Hot.Topic] = []
  private var tabs: [TiebaFeedAPI.Hot.Tab] = []
  private var threads: [TiebaFeedAPI.Hot.Thread] = []
  private var activeTab = "all"
  private var isReloading = false
  /// 请求代号：加载中点第二个分类时旧响应必须丢弃（否则列表停在旧 tab）。
  private var requestSeq = 0

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear
    stateView.isDark = TiebaNavigator.shared.chromeTheme.dark
    stateView.onButtonPress = { [weak self] _ in self?.reload() }
    stateView.isHidden = true
    // 热榜骨架：通用列表行（原 HotListContent.tsx variant="row" count={8}）
    stateView.skeletonVariant = .row
    stateView.skeletonInsets = UIEdgeInsets(top: 8, left: 16, bottom: 0, right: 16)
    collectionView.backgroundColor = .clear
    collectionView.dataSource = self
    collectionView.delegate = self
    collectionView.alwaysBounceVertical = true
    collectionView.contentInsetAdjustmentBehavior = .never
    collectionView.register(TiebaHotListCell.self, forCellWithReuseIdentifier: TiebaHotListCell.reuseIdentifier)
    collectionView.register(
      TiebaHotHeaderView.self,
      forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
      withReuseIdentifier: TiebaHotHeaderView.reuseIdentifier
    )
    collectionView.register(
      TiebaHotFooterView.self,
      forSupplementaryViewOfKind: UICollectionView.elementKindSectionFooter,
      withReuseIdentifier: TiebaHotFooterView.reuseIdentifier
    )
    refreshControl.tintColor = TiebaNavigator.shared.chromeTheme.tint
    refreshControl.addTarget(self, action: #selector(handleRefreshControl), for: .valueChanged)
    collectionView.refreshControl = refreshControl
    for subview in [collectionView, stateView, pill] as [UIView] {
      subview.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(subview)
    }
    NSLayoutConstraint.activate([
      collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      collectionView.topAnchor.constraint(equalTo: view.topAnchor),
      collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      stateView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      stateView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      stateView.topAnchor.constraint(equalTo: view.topAnchor),
      stateView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      pill.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      pill.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
      pill.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.82),
    ])
    showState(.loading)
    reload()
  }

  override func viewSafeAreaInsetsDidChange() {
    super.viewSafeAreaInsetsDidChange()
    collectionView.contentInset.bottom = view.safeAreaInsets.bottom + 16
  }

  // MARK: - 布局

  /// 单列自定义卡片段（HotListContent.tsx：卡片自带 10/6 外边距与 16 内白，
  /// 不是 system list 行）——行高/页头/页脚全部自撑（estimated + 各视图的
  /// preferredLayoutAttributesFitting），避免固定高度与内容错位。
  private func makeLayout() -> UICollectionViewCompositionalLayout {
    let configuration = UICollectionViewCompositionalLayoutConfiguration()
    configuration.interSectionSpacing = 0
    return UICollectionViewCompositionalLayout(sectionProvider: { _, _ in
      let itemSize = NSCollectionLayoutSize(
        widthDimension: .fractionalWidth(1),
        heightDimension: .estimated(150)
      )
      let item = NSCollectionLayoutItem(layoutSize: itemSize)
      let group = NSCollectionLayoutGroup.vertical(layoutSize: itemSize, subitems: [item])
      let section = NSCollectionLayoutSection(group: group)
      section.interGroupSpacing = 0
      section.contentInsets = .zero
      section.boundarySupplementaryItems = [
        NSCollectionLayoutBoundarySupplementaryItem(
          layoutSize: NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1),
            heightDimension: .estimated(120)
          ),
          elementKind: UICollectionView.elementKindSectionHeader,
          alignment: .top
        ),
        NSCollectionLayoutBoundarySupplementaryItem(
          layoutSize: NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1),
            heightDimension: .estimated(146)
          ),
          elementKind: UICollectionView.elementKindSectionFooter,
          alignment: .bottom
        ),
      ]
      return section
    }, configuration: configuration)
  }

  // MARK: - 外部驱动（tab 根屏）

  /// 热榜只在底栏重复点击时重拉（与旧页 TAB_RESELECT 判据一致）。
  func tabReselected() {
    collectionView.setContentOffset(
      CGPoint(x: 0, y: -collectionView.adjustedContentInset.top),
      animated: true
    )
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) { [weak self] in
      guard let self, self.view.window != nil else { return }
      self.reload()
    }
  }

  // MARK: - 状态

  private func showState(_ state: TiebaState) {
    stateView.state = state
    stateView.isHidden = false
    collectionView.isHidden = true
  }

  private func showList() {
    stateView.isHidden = true
    collectionView.isHidden = false
  }

  // MARK: - 数据

  @objc private func handleRefreshControl() {
    reload()
  }

  private func reload() {
    requestSeq += 1
    let seq = requestSeq
    let tab = activeTab
    isReloading = !threads.isEmpty
    if threads.isEmpty { showState(.loading) }
    collectionView.reloadData()
    Task { @MainActor in
      defer { refreshControl.endRefreshing() }
      do {
        let hot = try await TiebaFeedAPI.hotThreadList(tabCode: tab)
        // 加载中点第二个分类：旧 tab 的响应一律丢弃。
        guard seq == requestSeq, tab == activeTab else { return }
        topics = hot.topics
        tabs = hot.tabs
        threads = hot.threads
        // 内容已到：先复位重载态再刷新页头，spinner/半透明才不会永久停在页头。
        isReloading = false
        collectionView.reloadData()
        if threads.isEmpty {
          showState(.empty(
            image: "flame",
            text: "暂无热榜内容",
            secondary: "稍后再来看看吧",
            retryTitle: "刷新"
          ))
        } else {
          showList()
          if refreshControl.isRefreshing { TiebaSceneHaptics.fire("toggle") }
        }
      } catch {
        guard seq == requestSeq else { return }
        isReloading = false
        if threads.isEmpty {
          showState(.error(message: error.localizedDescription, retryTitle: "刷新"))
        } else {
          collectionView.reloadData()
          showList()
          pill.showResult(success: false, text: "加载失败")
        }
      }
    }
  }

  private func selectTab(_ code: String) {
    guard code != activeTab else { return }
    TiebaSceneHaptics.fire("press")
    activeTab = code
    reload()
  }

  private func openTopic(_ topic: TiebaFeedAPI.Hot.Topic) {
    TiebaSceneHaptics.fire("press")
    TiebaNavigator.shared.navigate(
      path: "/topic/\(topic.id)",
      params: ["name": topic.name],
      mode: "push"
    )
  }

  private func openThread(_ index: Int) {
    guard threads.indices.contains(index) else { return }
    let id = TiebaSimpleRowParser.string(threads[index].row["id"]) ?? ""
    guard !id.isEmpty else { return }
    TiebaSceneHaptics.fire("press")
    TiebaNavigator.shared.navigate(path: "/thread/\(id)", params: [:], mode: "push")
  }

  private func openForum(_ index: Int) {
    guard threads.indices.contains(index) else { return }
    let name = TiebaFeedRowFallback.resolve(threads[index].row).name
    guard !name.isEmpty else { return }
    TiebaSceneHaptics.fire("press")
    TiebaNavigator.shared.navigate(path: "/forum/\(TiebaRoutePath.segment(name))", params: [:], mode: "push")
  }

  private func openAuthor(_ index: Int) {
    guard threads.indices.contains(index) else { return }
    let uid = TiebaSimpleRowParser.string(threads[index].row["authorId"]) ?? ""
    guard !uid.isEmpty else { return }
    TiebaSceneHaptics.fire("press")
    TiebaNavigator.shared.navigate(path: "/user/\(uid)", params: [:], mode: "push")
  }
}

// MARK: - 列表数据源

extension TiebaHotListViewController: UICollectionViewDataSource, UICollectionViewDelegate {
  func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
    threads.count
  }

  func collectionView(
    _ collectionView: UICollectionView,
    cellForItemAt indexPath: IndexPath
  ) -> UICollectionViewCell {
    let cell = collectionView.dequeueReusableCell(
      withReuseIdentifier: TiebaHotListCell.reuseIdentifier,
      for: indexPath
    )
    (cell as? TiebaHotListCell)?.configure(rank: indexPath.item + 1, thread: threads[indexPath.item])
    return cell
  }

  func collectionView(
    _ collectionView: UICollectionView,
    viewForSupplementaryElementOfKind kind: String,
    at indexPath: IndexPath
  ) -> UICollectionReusableView {
    if kind == UICollectionView.elementKindSectionHeader {
      let header = collectionView.dequeueReusableSupplementaryView(
        ofKind: kind,
        withReuseIdentifier: TiebaHotHeaderView.reuseIdentifier,
        for: indexPath
      )
      (header as? TiebaHotHeaderView)?.configure(
        topics: topics,
        tabs: tabs,
        activeTab: activeTab,
        tint: TiebaNavigator.shared.chromeTheme.tint,
        isReloading: isReloading,
        onTopic: { [weak self] topic in self?.openTopic(topic) },
        onTab: { [weak self] code in self?.selectTab(code) }
      )
      return header
    }
    let footer = collectionView.dequeueReusableSupplementaryView(
      ofKind: kind,
      withReuseIdentifier: TiebaHotFooterView.reuseIdentifier,
      for: indexPath
    )
    // 页脚只在有内容时出现（原 JS hotListFooter 的 threads.length > 0 判据）。
    (footer as? TiebaHotFooterView)?.configure(visible: !threads.isEmpty)
    return footer
  }

  func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
    collectionView.deselectItem(at: indexPath, animated: false)
    openThread(indexPath.item)
  }

  func collectionView(
    _ collectionView: UICollectionView,
    contextMenuConfigurationForItemAt indexPath: IndexPath,
    point: CGPoint
  ) -> UIContextMenuConfiguration? {
    guard threads.indices.contains(indexPath.item) else { return nil }
    return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
      let author = UIAction(title: "查看作者", image: UIImage(systemName: "person.crop.circle")) { _ in
        self?.openAuthor(indexPath.item)
      }
      let forum = UIAction(title: "进入吧", image: UIImage(systemName: "text.bubble")) { _ in
        self?.openForum(indexPath.item)
      }
      return UIMenu(children: [author, forum])
    }
  }
}

// MARK: - 行

/// 热榜卡片（HotListContent.tsx renderHotItem 的 UIKit 直译）：
/// 排名列（38pt 宽、22pt heavy 数字、前三名色底）+ 正文列（paddingLeft 10）：
/// 标题两行 → 作者行（18pt 圆头像 + 昵称 + 吧名 chip）→ 操作行（回复/赞 +
/// 火焰热度）；卡片 margin 10/6、padding 16，高度由 Auto Layout 自撑。
final class TiebaHotListCell: UICollectionViewCell {
  static let reuseIdentifier = "TiebaHotListCell"

  /// 热榜前三名排名色（src/constants/rank.ts HOT_RANK_COLORS）。
  static let topColors: [UIColor] = [
    tiebaColor(from: "#FF3B30") ?? .systemRed,
    tiebaColor(from: "#FF9500") ?? .systemOrange,
    tiebaColor(from: "#FFCC00") ?? .systemYellow,
  ]

  private let cardView = UIView()
  private let rankBadge = UIView()
  private let rankLabel = UILabel()
  private let titleLabel = UILabel()
  /// 18pt 作者头像：复用吧三页的 TiebaForumAvatarView（Nuke + 首字兜底、
  /// 换图取消在途请求）。
  private let avatarView = TiebaForumAvatarView(size: TiebaHotMetrics.avatarSize)
  private let authorLabel = UILabel()
  private let dotLabel = UILabel()
  private let forumChip = UIView()
  private let forumLabel = UILabel()
  private let replyIcon = UIImageView()
  private let replyLabel = UILabel()
  private let agreeIcon = UIImageView()
  private let agreeLabel = UILabel()
  private let flameIcon = UIImageView()
  private let hotLabel = UILabel()

  private var rankColor: UIColor = .tertiaryLabel

  override init(frame: CGRect) {
    super.init(frame: frame)
    isAccessibilityElement = true
    accessibilityTraits = .button
    let palette = TiebaFeedRowPalette.default
    let fonts = TiebaHotMetrics.fonts

    cardView.backgroundColor = palette.card
    cardView.layer.cornerRadius = TiebaHotMetrics.cardRadius // Radius.card
    cardView.layer.cornerCurve = .continuous
    // 1px 卡边框：displayScale 取视图 trait（UIScreen.main 自 iOS 26 废弃）。
    cardView.layer.borderWidth = 1 / traitCollection.displayScale
    cardView.layer.borderColor = palette.borderCard.cgColor

    rankBadge.layer.cornerRadius = 10
    rankBadge.layer.cornerCurve = .continuous
    rankLabel.font = fonts.rank
    rankLabel.textAlignment = .center
    rankLabel.adjustsFontSizeToFitWidth = true
    rankLabel.minimumScaleFactor = 0.7
    rankBadge.addSubview(rankLabel)

    titleLabel.font = fonts.title
    titleLabel.textColor = palette.text
    titleLabel.numberOfLines = 2
    titleLabel.lineBreakMode = .byTruncatingTail

    authorLabel.font = fonts.author
    authorLabel.textColor = palette.textSecondary
    authorLabel.numberOfLines = 1
    authorLabel.lineBreakMode = .byTruncatingTail
    dotLabel.text = "·"
    dotLabel.font = fonts.author
    dotLabel.textColor = palette.textTertiary

    forumChip.backgroundColor = palette.placeholder
    forumChip.layer.cornerRadius = 8
    forumChip.layer.cornerCurve = .continuous
    forumLabel.font = fonts.forum
    forumLabel.textColor = palette.textSecondary
    forumLabel.numberOfLines = 1
    forumLabel.lineBreakMode = .byTruncatingTail
    forumChip.addSubview(forumLabel)

    configureActionIcon(replyIcon, systemImage: "bubble.left")
    configureActionIcon(agreeIcon, systemImage: "hand.thumbsup")
    configureActionIcon(flameIcon, systemImage: "flame")
    replyLabel.font = fonts.action
    agreeLabel.font = fonts.action
    replyLabel.textColor = palette.textTertiary
    agreeLabel.textColor = palette.textTertiary
    hotLabel.font = fonts.hot
    replyIcon.tintColor = palette.textTertiary
    agreeIcon.tintColor = palette.textTertiary

    let metaRow = UIStackView(arrangedSubviews: [avatarView, authorLabel, dotLabel, forumChip])
    metaRow.axis = .horizontal
    metaRow.alignment = .center
    metaRow.spacing = 6
    let spacer = UIView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let actionRow = UIStackView(arrangedSubviews: [
      replyIcon, replyLabel, agreeIcon, agreeLabel, spacer, flameIcon, hotLabel,
    ])
    actionRow.axis = .horizontal
    actionRow.alignment = .center
    actionRow.spacing = 5
    // 计数与下一个图标 17pt（RN: row gap 5 + hotActionText.marginRight 12）、
    // 火焰与热度值 8pt（gap 5 + hotHotNumWrap gap 3）。
    actionRow.setCustomSpacing(17, after: replyLabel)
    actionRow.setCustomSpacing(17, after: agreeLabel)
    actionRow.setCustomSpacing(8, after: flameIcon)

    let body = UIStackView(arrangedSubviews: [titleLabel, metaRow, actionRow])
    body.axis = .vertical
    body.alignment = .fill
    body.spacing = 8 // hotTitle/hotMetaRow 的 marginBottom 8

    for view in [cardView, rankBadge, body, avatarView, forumChip] as [UIView] {
      view.translatesAutoresizingMaskIntoConstraints = false
    }
    for view in [rankLabel, forumLabel] as [UIView] {
      view.translatesAutoresizingMaskIntoConstraints = false
    }
    contentView.addSubview(cardView)
    cardView.addSubview(rankBadge)
    cardView.addSubview(body)

    NSLayoutConstraint.activate([
      // cardWrap marginHorizontal 10 / marginVertical 6
      cardView.leadingAnchor.constraint(
        equalTo: contentView.leadingAnchor, constant: TiebaHotMetrics.hotCardMarginH),
      cardView.trailingAnchor.constraint(
        equalTo: contentView.trailingAnchor, constant: -TiebaHotMetrics.hotCardMarginH),
      cardView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: TiebaHotMetrics.hotCardMarginV),
      cardView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -TiebaHotMetrics.hotCardMarginV),

      // hotRankBadge：宽 38、顶部对齐（paddingTop 2）、圆角 10
      rankBadge.leadingAnchor.constraint(
        equalTo: cardView.leadingAnchor, constant: TiebaHotMetrics.hotCardPadding),
      rankBadge.topAnchor.constraint(equalTo: cardView.topAnchor, constant: TiebaHotMetrics.hotCardPadding),
      rankBadge.widthAnchor.constraint(equalToConstant: TiebaHotMetrics.rankColumnWidth),
      rankLabel.topAnchor.constraint(equalTo: rankBadge.topAnchor, constant: 2),
      rankLabel.leadingAnchor.constraint(equalTo: rankBadge.leadingAnchor),
      rankLabel.trailingAnchor.constraint(equalTo: rankBadge.trailingAnchor),
      rankLabel.bottomAnchor.constraint(equalTo: rankBadge.bottomAnchor),
      rankBadge.bottomAnchor.constraint(
        lessThanOrEqualTo: cardView.bottomAnchor, constant: -TiebaHotMetrics.hotCardPadding),

      // hotCardBody：flex 1 + paddingLeft 10；卡片 padding 16
      body.leadingAnchor.constraint(equalTo: rankBadge.trailingAnchor, constant: TiebaHotMetrics.bodyIndent),
      body.trailingAnchor.constraint(
        equalTo: cardView.trailingAnchor, constant: -TiebaHotMetrics.hotCardPadding),
      body.topAnchor.constraint(equalTo: cardView.topAnchor, constant: TiebaHotMetrics.hotCardPadding),
      body.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -TiebaHotMetrics.hotCardPadding),

      // hotUserName 的 maxWidth: 80（超出截断，把空间让给吧名 chip）
      authorLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 80),

      // hotForumChip：paddingH 8 / paddingV 3
      forumLabel.leadingAnchor.constraint(equalTo: forumChip.leadingAnchor, constant: 8),
      forumLabel.trailingAnchor.constraint(equalTo: forumChip.trailingAnchor, constant: -8),
      forumLabel.topAnchor.constraint(equalTo: forumChip.topAnchor, constant: 3),
      forumLabel.bottomAnchor.constraint(equalTo: forumChip.bottomAnchor, constant: -3),
      forumChip.widthAnchor.constraint(lessThanOrEqualToConstant: 140),

      replyIcon.widthAnchor.constraint(equalToConstant: TiebaHotMetrics.iconSize),
      replyIcon.heightAnchor.constraint(equalToConstant: TiebaHotMetrics.iconSize),
      agreeIcon.widthAnchor.constraint(equalToConstant: TiebaHotMetrics.iconSize),
      agreeIcon.heightAnchor.constraint(equalToConstant: TiebaHotMetrics.iconSize),
      flameIcon.widthAnchor.constraint(equalToConstant: TiebaHotMetrics.iconSize),
      flameIcon.heightAnchor.constraint(equalToConstant: TiebaHotMetrics.iconSize),
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  override func prepareForReuse() {
    super.prepareForReuse()
    titleLabel.text = nil
    authorLabel.text = nil
    forumLabel.text = nil
    isHighlighted = false
  }

  func configure(rank: Int, thread: TiebaFeedAPI.Hot.Thread) {
    let palette = TiebaFeedRowPalette.default
    let row = thread.row
    rankColor = rank <= 3 ? Self.topColors[rank - 1] : palette.textTertiary
    rankLabel.text = "\(rank)"
    rankLabel.textColor = rankColor
    rankBadge.backgroundColor = rank <= 3 ? rankColor.withAlphaComponent(0.08) : .clear

    titleLabel.text = TiebaSimpleRowParser.string(row["title"]) ?? ""
    let author = TiebaSimpleRowParser.string(row["authorNameShow"])
      ?? TiebaSimpleRowParser.string(row["authorName"]) ?? ""
    authorLabel.text = author.isEmpty ? "吧友" : author
    avatarView.configure(
      url: TiebaSimpleRowParser.avatarURL(TiebaSimpleRowParser.string(row["authorPortrait"]) ?? "")?
        .absoluteString ?? "",
      initial: author.isEmpty ? "吧" : author
    )
    // 吧名/吧头像兜底（同一份 TiebaFeedRowFallback：服务端热榜行同样可能缺名/缺图）。
    let forum = TiebaFeedRowFallback.resolve(row)
    forumLabel.text = forum.name
    forumChip.isHidden = forum.name.isEmpty
    forumChip.backgroundColor = palette.placeholder

    replyLabel.text = TiebaForumFormat.count(Int(TiebaSimpleRowParser.double(row["replyNum"]) ?? 0))
    agreeLabel.text = TiebaForumFormat.count(Int(thread.agreeNum))
    hotLabel.text = TiebaForumFormat.count(Int(thread.hotNum))
    hotLabel.textColor = rankColor
    flameIcon.tintColor = rankColor

    accessibilityLabel = [
      "第\(rank)名", titleLabel.text ?? "", authorLabel.text ?? "",
      forum.name.isEmpty ? "" : "\(forum.name)吧",
      "回复\(replyLabel.text ?? "")", "赞\(agreeLabel.text ?? "")",
      "热度\(hotLabel.text ?? "")",
    ].filter { !$0.isEmpty }.joined(separator: "，")
  }

  /// 按压态（JS pressed：opacity 0.9 + scale 0.98）。
  override var isHighlighted: Bool {
    didSet {
      cardView.alpha = isHighlighted ? 0.9 : 1
      cardView.transform = isHighlighted
        ? CGAffineTransform(scaleX: 0.98, y: 0.98)
        : .identity
    }
  }

  override func preferredLayoutAttributesFitting(
    _ layoutAttributes: UICollectionViewLayoutAttributes
  ) -> UICollectionViewLayoutAttributes {
    let width = layoutAttributes.size.width
    let size = contentView.systemLayoutSizeFitting(
      CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
      withHorizontalFittingPriority: .required,
      verticalFittingPriority: .fittingSizeLevel
    )
    layoutAttributes.size = CGSize(width: width, height: ceil(size.height))
    return layoutAttributes
  }

  private func configureActionIcon(_ imageView: UIImageView, systemImage: String) {
    imageView.image = UIImage(
      systemName: systemImage,
      withConfiguration: UIImage.SymbolConfiguration(pointSize: TiebaHotMetrics.iconSize, weight: .regular)
    )
    imageView.contentMode = .scaleAspectFit
  }
}

/// 热榜行/页头共用的几何与字号（对齐 HotListContent.tsx 的字号档与 18pt 头像）。
private enum TiebaHotMetrics {
  static let cardRadius: CGFloat = 20
  static let avatarSize: CGFloat = 18
  static let iconSize: CGFloat = 13
  static let hotCardMarginH: CGFloat = 10
  static let hotCardMarginV: CGFloat = 6
  static let hotCardPadding: CGFloat = 16
  static let rankColumnWidth: CGFloat = 38
  static let bodyIndent: CGFloat = 10

  static let fonts = Fonts()

  static func font(_ size: CGFloat, _ weight: UIFont.Weight, _ style: UIFont.TextStyle) -> UIFont {
    UIFontMetrics(forTextStyle: style).scaledFont(for: UIFont.systemFont(ofSize: size, weight: weight))
  }

  struct Fonts {
    let rank = TiebaHotMetrics.font(22, .heavy, .title2)
    let title = TiebaHotMetrics.font(17, .semibold, .headline)
    let author = TiebaHotMetrics.font(13, .medium, .footnote)
    let forum = TiebaHotMetrics.font(12, .medium, .caption1)
    let action = TiebaHotMetrics.font(13, .regular, .footnote)
    let hot = TiebaHotMetrics.font(13, .bold, .footnote)
  }
}


// MARK: - 页头（热门话题 + 分类）

/// 热榜页头（HotListContent.tsx 的 ListHeader：重载行 → 热门话题 →
/// 分类 Tab → 「排名按热度计算」提示）。JS 侧横向滚动区各自带 14pt 内白与
/// 16pt 标题内白，这里逐项复刻；容器自撑高度（preferredLayoutAttributesFitting）。
final class TiebaHotHeaderView: UICollectionReusableView {
  static let reuseIdentifier = "TiebaHotHeaderView"

  private let spinnerRow = UIView()
  private let spinner = UIActivityIndicatorView(style: .medium)
  private let contentStack = UIStackView()
  private let topicsContainer = UIView()
  private let topicsHeader = UIStackView()
  private let topicsTitle = UILabel()
  private let topicScroll = UIScrollView()
  private let topicRow = UIStackView()
  private let tabsContainer = UIView()
  private let tabScroll = UIScrollView()
  private let tabRow = UIStackView()
  private let tipContainer = UIView()
  private let tipLabel = UILabel()

  override init(frame: CGRect) {
    super.init(frame: frame)
    let palette = TiebaFeedRowPalette.default

    spinner.hidesWhenStopped = true
    spinner.color = palette.primary

    let flame = UIImageView(image: UIImage(
      systemName: "flame.fill",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)
    ))
    flame.tintColor = .systemRed
    flame.contentMode = .scaleAspectFit
    topicsTitle.text = "热门话题"
    topicsTitle.font = TiebaHotMetrics.font(22, .semibold, .title2)
    topicsTitle.textColor = palette.text
    topicsHeader.axis = .horizontal
    topicsHeader.spacing = 6
    topicsHeader.alignment = .center
    topicsHeader.addArrangedSubview(flame)
    topicsHeader.addArrangedSubview(topicsTitle)

    configureScroll(topicScroll, row: topicRow, spacing: 10, horizontalInset: 14, height: 40)
    configureScroll(tabScroll, row: tabRow, spacing: 8, horizontalInset: 14, height: 36)

    tipLabel.text = "排名按热度计算 · 实时更新"
    tipLabel.font = TiebaHotMetrics.font(12, .regular, .caption1)
    tipLabel.textColor = palette.textTertiary

    spinnerRow.addSubview(spinner)
    topicsContainer.addSubview(topicsHeader)
    topicsContainer.addSubview(topicScroll)
    tabsContainer.addSubview(tabScroll)
    tipContainer.addSubview(tipLabel)
    contentStack.axis = .vertical
    contentStack.spacing = 0
    contentStack.alignment = .fill
    for view in [spinnerRow, topicsContainer, tabsContainer, tipContainer] as [UIView] {
      contentStack.addArrangedSubview(view)
    }
    for view in [
      contentStack, spinnerRow, topicsContainer, tabsContainer, tipContainer,
      spinner, topicsHeader, tipLabel,
    ] as [UIView] {
      view.translatesAutoresizingMaskIntoConstraints = false
    }
    addSubview(contentStack)

    NSLayoutConstraint.activate([
      contentStack.leadingAnchor.constraint(equalTo: leadingAnchor),
      contentStack.trailingAnchor.constraint(equalTo: trailingAnchor),
      contentStack.topAnchor.constraint(equalTo: topAnchor),
      contentStack.bottomAnchor.constraint(equalTo: bottomAnchor),

      // 重载行：paddingVertical 12 的居中 spinner（stale-while-revalidate）。
      spinner.centerXAnchor.constraint(equalTo: spinnerRow.centerXAnchor),
      spinner.topAnchor.constraint(equalTo: spinnerRow.topAnchor, constant: 12),
      spinner.bottomAnchor.constraint(equalTo: spinnerRow.bottomAnchor, constant: -12),

      // 热门话题：section paddingTop 16 / paddingBottom 6；标题行 paddingH 16、
      // 与话题滚动区间距 12；滚动区 paddingH 14。
      topicsHeader.leadingAnchor.constraint(equalTo: topicsContainer.leadingAnchor, constant: 16),
      topicsHeader.trailingAnchor.constraint(lessThanOrEqualTo: topicsContainer.trailingAnchor, constant: -16),
      topicsHeader.topAnchor.constraint(equalTo: topicsContainer.topAnchor, constant: 16),
      topicScroll.leadingAnchor.constraint(equalTo: topicsContainer.leadingAnchor),
      topicScroll.trailingAnchor.constraint(equalTo: topicsContainer.trailingAnchor),
      topicScroll.topAnchor.constraint(equalTo: topicsHeader.bottomAnchor, constant: 12),
      topicScroll.bottomAnchor.constraint(equalTo: topicsContainer.bottomAnchor, constant: -6),

      // 分类 Tab：paddingTop 14 / paddingBottom 8 / paddingH 14。
      tabScroll.leadingAnchor.constraint(equalTo: tabsContainer.leadingAnchor),
      tabScroll.trailingAnchor.constraint(equalTo: tabsContainer.trailingAnchor),
      tabScroll.topAnchor.constraint(equalTo: tabsContainer.topAnchor, constant: 14),
      tabScroll.bottomAnchor.constraint(equalTo: tabsContainer.bottomAnchor, constant: -8),

      // rankTip：paddingH 16 / paddingTop 10 / paddingBottom 8。
      tipLabel.leadingAnchor.constraint(equalTo: tipContainer.leadingAnchor, constant: 16),
      tipLabel.trailingAnchor.constraint(lessThanOrEqualTo: tipContainer.trailingAnchor, constant: -16),
      tipLabel.topAnchor.constraint(equalTo: tipContainer.topAnchor, constant: 10),
      tipLabel.bottomAnchor.constraint(equalTo: tipContainer.bottomAnchor, constant: -8),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(
    topics: [TiebaFeedAPI.Hot.Topic],
    tabs: [TiebaFeedAPI.Hot.Tab],
    activeTab: String,
    tint: UIColor,
    isReloading: Bool,
    onTopic: @escaping (TiebaFeedAPI.Hot.Topic) -> Void,
    onTab: @escaping (String) -> Void
  ) {
    spinnerRow.isHidden = !isReloading
    if isReloading { spinner.startAnimating() } else { spinner.stopAnimating() }
    // stale-while-revalidate：换 tab 期间旧内容半透明（JS 的 opacity 0.5）。
    for container in [topicsContainer, tabsContainer, tipContainer] {
      container.alpha = isReloading ? 0.5 : 1
    }

    clear(topicRow)
    topicsContainer.isHidden = topics.isEmpty
    for (index, topic) in topics.prefix(8).enumerated() {
      let chip = TiebaHotTopicChip(index: index, title: topic.name)
      chip.onTap = { onTopic(topic) }
      topicRow.addArrangedSubview(chip)
    }

    clear(tabRow)
    tabsContainer.isHidden = tabs.isEmpty
    if !tabs.isEmpty {
      let all = TiebaHotTabChip(title: "全部", tint: tint)
      all.isSelected = activeTab == "all"
      all.onTap = { onTab("all") }
      tabRow.addArrangedSubview(all)
      // 分类只展示前 6 个（与旧页 slice(0, 6) 同）。
      for tab in tabs.prefix(6) {
        let chip = TiebaHotTabChip(title: tab.name, tint: tint)
        chip.isSelected = activeTab == tab.code
        chip.onTap = { onTab(tab.code) }
        tabRow.addArrangedSubview(chip)
      }
    }
  }

  /// 横向滚动区：内容行贴 contentLayoutGuide，左右内白 + 固定行高 + 间距。
  private func configureScroll(
    _ scroll: UIScrollView,
    row: UIStackView,
    spacing: CGFloat,
    horizontalInset: CGFloat,
    height: CGFloat
  ) {
    scroll.translatesAutoresizingMaskIntoConstraints = false
    row.translatesAutoresizingMaskIntoConstraints = false
    scroll.showsHorizontalScrollIndicator = false
    scroll.alwaysBounceHorizontal = true
    row.axis = .horizontal
    row.spacing = spacing
    row.alignment = .fill
    scroll.addSubview(row)
    NSLayoutConstraint.activate([
      scroll.heightAnchor.constraint(equalToConstant: height),
      row.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: horizontalInset),
      row.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -horizontalInset),
      row.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
      row.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
      row.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
    ])
  }

  private func clear(_ stack: UIStackView) {
    for view in stack.arrangedSubviews {
      stack.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
  }

  override func preferredLayoutAttributesFitting(
    _ layoutAttributes: UICollectionViewLayoutAttributes
  ) -> UICollectionViewLayoutAttributes {
    let width = layoutAttributes.size.width
    let size = systemLayoutSizeFitting(
      CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
      withHorizontalFittingPriority: .required,
      verticalFittingPriority: .fittingSizeLevel
    )
    layoutAttributes.size = CGSize(width: width, height: ceil(size.height))
    return layoutAttributes
  }
}

/// 热门话题 chip（HotListContent.tsx topicChip）：胶囊 + 20pt 排名圆标 + 8 色轮换
/// （src/constants/rank.ts TOPIC_CHIP_COLORS，bg 12%、border 30%）。圆角/描边/按压
/// 态交给 UIButton.Configuration（不再手写 UIControl + layoutSubviews 解析描边色）。
final class TiebaHotTopicChip: UIButton {
  var onTap: (() -> Void)?

  init(index: Int, title: String) {
    let colors = TiebaHotTopicChip.palette[index % TiebaHotTopicChip.palette.count]
    super.init(frame: .zero)
    var config = UIButton.Configuration.plain()
    config.image = Self.badgeImage(index: index, color: colors.rank)
    config.title = title
    config.imagePadding = 8   // rank badge 与文字 gap 8
    config.cornerStyle = .capsule
    config.titleLineBreakMode = .byTruncatingTail
    config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
      var out = incoming
      out.font = TiebaHotMetrics.font(14, .semibold, .subheadline)
      return out
    }
    // paddingH 14 / paddingV 10（badge 20 + 上下各 10 = 40 高）。
    config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14)
    config.background.backgroundColor = colors.background
    config.background.strokeColor = colors.border
    config.background.strokeWidth = 1
    config.baseForegroundColor = TiebaFeedRowPalette.default.text
    configuration = config
    configurationUpdateHandler = { button in
      // JS pressed：opacity 0.8 + scale 0.95。
      button.alpha = button.isHighlighted ? 0.8 : 1
      button.transform = button.isHighlighted ? CGAffineTransform(scaleX: 0.95, y: 0.95) : .identity
    }
    // 标题区 maxWidth 130（原 titleLabel ≤ 130）+ badge 20 + gap 8 + padding 28。
    setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    widthAnchor.constraint(lessThanOrEqualToConstant: 186).isActive = true
    addAction(UIAction { [weak self] _ in self?.onTap?() }, for: .touchUpInside)
    accessibilityLabel = "第\(index + 1)名 \(title)"
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// 20pt 排名圆标：数字 + 圆底合成一张图，按钮里不再塞子视图。
  private static func badgeImage(index: Int, color: UIColor) -> UIImage {
    let size = CGSize(width: 20, height: 20)
    let image = UIGraphicsImageRenderer(size: size).image { context in
      color.setFill()
      context.cgContext.fillEllipse(in: CGRect(origin: .zero, size: size))
      let text = "\(index + 1)" as NSString
      let attributes: [NSAttributedString.Key: Any] = [
        .font: TiebaHotMetrics.font(11, .heavy, .caption2),
        .foregroundColor: UIColor.white,
      ]
      let textSize = text.size(withAttributes: attributes)
      text.draw(
        at: CGPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2),
        withAttributes: attributes
      )
    }
    return image.withRenderingMode(.alwaysOriginal)
  }

  private static let palette: [(background: UIColor, rank: UIColor, border: UIColor)] = [
    ("#FF3B3012", "#FF3B30", "#FF3B3030"),
    ("#FF950012", "#FF9500", "#FF950030"),
    ("#FFCC0012", "#CC9900", "#FFCC0030"),
    ("#34C75912", "#34C759", "#34C75930"),
    ("#5AC8FA12", "#5AC8FA", "#5AC8FA30"),
    ("#007AFF12", "#007AFF", "#007AFF30"),
    ("#5856D612", "#5856D6", "#5856D630"),
    ("#AF52DE12", "#AF52DE", "#AF52DE30"),
  ].map { entry in
    (
      tiebaColor(from: entry.0) ?? .clear,
      tiebaColor(from: entry.1) ?? .clear,
      tiebaColor(from: entry.2) ?? .clear
    )
  }
}

/// 分类 Tab chip（HotListContent.tsx tabItem）：paddingH 18 / paddingV 9 / 胶囊；
/// 选中 = primary 底 + 白字，未选中 = surfaceSecondary 底 + 次要字（isSelected 驱动
/// configurationUpdateHandler，选中/按压态不再手写 backgroundColor）。
final class TiebaHotTabChip: UIButton {
  private let tint: UIColor
  var onTap: (() -> Void)?

  init(title: String, tint: UIColor) {
    self.tint = tint
    super.init(frame: .zero)
    var config = UIButton.Configuration.plain()
    config.title = title
    config.cornerStyle = .capsule
    config.titleLineBreakMode = .byTruncatingTail
    config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
      var out = incoming
      out.font = TiebaHotMetrics.font(14, .semibold, .subheadline)
      return out
    }
    config.contentInsets = NSDirectionalEdgeInsets(top: 9, leading: 18, bottom: 9, trailing: 18)
    configuration = config
    configurationUpdateHandler = { [weak self] button in
      guard let self else { return }
      let palette = TiebaFeedRowPalette.default
      var config = button.configuration
      config?.background.backgroundColor = button.isSelected ? self.tint : palette.placeholder
      config?.baseForegroundColor = button.isSelected ? .white : palette.textSecondary
      button.configuration = config
      button.accessibilityValue = button.isSelected ? "已选中" : nil
      // JS pressed：opacity 0.8 + scale 0.95。
      button.alpha = button.isHighlighted ? 0.8 : 1
      button.transform = button.isHighlighted ? CGAffineTransform(scaleX: 0.95, y: 0.95) : .identity
    }
    setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    addAction(UIAction { [weak self] _ in self?.onTap?() }, for: .touchUpInside)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// MARK: - 页脚

/// 「到底卡」（HotListContent.tsx hotFooter）：内容全展示后压在列表底部，
/// 130pt 高、radius.card；无内容时整块收起（JS 的 hotListFooter 返回 null）。
final class TiebaHotFooterView: UICollectionReusableView {
  static let reuseIdentifier = "TiebaHotFooterView"

  private let card = UIView()
  private let titleLabel = UILabel()
  private let hintLabel = UILabel()
  private var cardHeight: NSLayoutConstraint!
  private var topInset: NSLayoutConstraint!

  override init(frame: CGRect) {
    super.init(frame: frame)
    // 与热榜卡片同一份色板（深色/自定义主题下不再两套底色）。
    let palette = TiebaFeedRowPalette.default
    card.backgroundColor = palette.card
    card.layer.cornerRadius = 20
    card.layer.cornerCurve = .continuous
    titleLabel.text = "— 已展示全部热榜内容 —"
    titleLabel.font = TiebaHotMetrics.font(13, .semibold, .footnote)
    titleLabel.textColor = palette.textTertiary
    hintLabel.text = "下拉刷新看看有没有新内容"
    hintLabel.font = TiebaHotMetrics.font(12, .regular, .caption1)
    hintLabel.textColor = palette.textTertiary
    let stack = UIStackView(arrangedSubviews: [titleLabel, hintLabel])
    stack.axis = .vertical
    stack.alignment = .center
    stack.spacing = 6
    for view in [card, stack] as [UIView] {
      view.translatesAutoresizingMaskIntoConstraints = false
    }
    addSubview(card)
    card.addSubview(stack)
    cardHeight = card.heightAnchor.constraint(equalToConstant: 130)
    topInset = card.topAnchor.constraint(equalTo: topAnchor, constant: 16)
    NSLayoutConstraint.activate([
      card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
      topInset,
      card.bottomAnchor.constraint(equalTo: bottomAnchor),
      cardHeight,
      stack.centerXAnchor.constraint(equalTo: card.centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: card.centerYAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(visible: Bool) {
    card.isHidden = !visible
    cardHeight.constant = visible ? 130 : 0
    topInset.constant = visible ? 16 : 0
  }

  override func preferredLayoutAttributesFitting(
    _ layoutAttributes: UICollectionViewLayoutAttributes
  ) -> UICollectionViewLayoutAttributes {
    let width = layoutAttributes.size.width
    let size = systemLayoutSizeFitting(
      CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
      withHorizontalFittingPriority: .required,
      verticalFittingPriority: .fittingSizeLevel
    )
    layoutAttributes.size = CGSize(width: width, height: ceil(size.height))
    return layoutAttributes
  }
}
