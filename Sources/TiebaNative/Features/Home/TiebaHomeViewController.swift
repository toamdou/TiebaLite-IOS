// 「关注」tab 根屏（原 src/app/(tabs)/index.tsx）：顶栏（头像/搜索胶囊/一键签到/
// 排序切换）+ 最近访问药丸行 + 关注吧列表（单列/双列、长按取关、下拉刷新）。
// 数据：TiebaFollowedForums（forumGuide）+ 统一 SQLite 的 visit_history；
// 签到走 TiebaSignService（原生批量 msign）。
import UIKit

final class TiebaHomeViewController: UIViewController, TiebaTabReselectable {
  private enum SortMode: String {
    case level
    case name
  }

  /// 排序偏好：共享偏好只读，页面自持一份（JS 侧 forumSortMode 的写入方
  /// index.tsx 已删，本键只剩本页消费）；page-private 键落盘，重启保持。
  private static let sortKey = "@tiebalite:native_home_sort_mode_v1"

  // 顶栏
  private let avatarControl = UIControl()
  private let avatarView = TiebaForumAvatarView(size: 36)
  /// 搜索入口 = 玻璃按钮（放大镜 + 占位文字）：与签到/排序同一形态，不再是
  /// 「平底输入框 + 外层 control」的三层 hack。
  private let searchButton = UIButton(type: .system)
  private let signButton = UIButton(type: .system)
  private let sortButton = UIButton(type: .system)
  // 最近访问
  private let historyHeader = UIView()
  private let historyTitle = UILabel()
  private let historyToggle = UIButton(type: .system)
  private let historyScroll = UIScrollView()
  private let historyStack = UIStackView()
  private var historyHeight: NSLayoutConstraint?
  // 列表
  private let layout = UICollectionViewFlowLayout()
  private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
  private let stateView = TiebaStateContentView()
  private let refreshControl = UIRefreshControl()
  private let pill = TiebaPhotoBrowserPillView()

  private var forums: [TiebaForumInfo] = []
  private var displayedForums: [TiebaForumInfo] = []
  private var recentForums: [RecentForum] = []
  private var historyExpanded = true
  private var sortMode: SortMode = .level
  private var isSingleColumn = true
  private var isLoading = false
  private var isUserRefresh = false
  private var hasLoadedOnce = false
  private var entranceDone = false
  private var entrancePending = false
  private var dataSource: UICollectionViewDiffableDataSource<String, String>?

  private struct RecentForum {
    var forumName = ""
    var forumId = ""
    var avatar = ""
  }

  private var isLoggedIn: Bool { TiebaUserAPI.isLoggedIn }
  /// 观察者是 non-Sendable，deinit 非隔离：与 TiebaPostRowView 同款声明。
  private nonisolated(unsafe) var sessionObserver: NSObjectProtocol?

  deinit {
    if let sessionObserver { NotificationCenter.default.removeObserver(sessionObserver) }
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemGroupedBackground
    sortMode = loadSortMode()
    isSingleColumn = TiebaPreferenceSnapshot.bool("forumListSingle", default: true)
    let topBar = buildTopBar()
    buildHistoryRow(below: topBar)
    buildList()
    TiebaSignService.shared.onStateChange = { [weak self] in self?.applySignButton() }
    TiebaSignService.shared.onFinished = { [weak self] in
      TiebaFollowedForums.invalidate()
      self?.loadFollowedForums(force: true)
    }
    // 登录/登出会清关注吧缓存（TiebaSession.activate/logout → invalidate）：本页必须
    // 跟着重拉。否则登录完成时本页还停在"未登录"的空态，要先去别的 tab 转一圈才出列表
    //（用户实证：登录后切到「关注」还是空白）。
    sessionObserver = NotificationCenter.default.addObserver(
      forName: TiebaSession.didChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      TiebaUserAPI.refreshLoginSnapshot()
      hasLoadedOnce = false
      applyLoginState()
      loadFollowedForums(force: true)
      loadRecentForums()
      applySignButton()
    }
    pill.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(pill)
    NSLayoutConstraint.activate([
      pill.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      pill.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
      pill.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.82),
    ])
    applyLoginState()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    TiebaUserAPI.refreshLoginSnapshot()
    // 每次出现现读偏好（设置页可能刚改过）与登录态。
    isSingleColumn = TiebaPreferenceSnapshot.bool("forumListSingle", default: true)
    updateLayoutMetrics()
    applyLoginState()
    loadFollowedForums()
    loadRecentForums()
    applySignButton()
  }

  /// 底栏重复点击：重拉关注列表（原 TAB_RESELECT_EVENT 'index' 分支）。
  func tabReselected() {
    loadFollowedForums(force: true)
  }

  // MARK: - 顶栏

  @discardableResult
  private func buildTopBar() -> UIStackView {
    avatarView.translatesAutoresizingMaskIntoConstraints = false
    avatarView.isUserInteractionEnabled = false
    avatarControl.addSubview(avatarView)
    avatarControl.addAction(UIAction { [weak self] _ in self?.handleAvatarTap() }, for: .touchUpInside)
    NSLayoutConstraint.activate([
      avatarView.leadingAnchor.constraint(equalTo: avatarControl.leadingAnchor),
      avatarView.trailingAnchor.constraint(equalTo: avatarControl.trailingAnchor),
      avatarView.topAnchor.constraint(equalTo: avatarControl.topAnchor),
      avatarView.bottomAnchor.constraint(equalTo: avatarControl.bottomAnchor),
      avatarControl.widthAnchor.constraint(equalToConstant: 36),
      avatarControl.heightAnchor.constraint(equalToConstant: 36),
    ])

    // 搜索入口：玻璃胶囊按钮，放大镜 + 占位文字左对齐铺满剩余宽度。
    var search = UIButton.Configuration.glass()
    search.image = UIImage(systemName: "magnifyingglass")
    search.title = "搜吧、搜贴、搜人"
    search.baseForegroundColor = .secondaryLabel
    search.cornerStyle = .capsule
    search.imagePadding = 6
    search.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12)
    searchButton.configuration = search
    searchButton.contentHorizontalAlignment = .leading
    searchButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
    searchButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    searchButton.heightAnchor.constraint(equalToConstant: 36).isActive = true
    searchButton.addAction(UIAction { _ in
      TiebaNavigator.shared.navigate(path: "/search/index", params: [:], mode: "push")
    }, for: .touchUpInside)

    for button in [signButton, sortButton] {
      // 原 JS = clear 玻璃圆钮（部署底线 iOS 26，.glass() 恒可用）。
      var config = UIButton.Configuration.glass()
      config.cornerStyle = .capsule
      button.configuration = config
      button.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        button.widthAnchor.constraint(equalToConstant: 36),
        button.heightAnchor.constraint(equalToConstant: 36),
      ])
    }
    signButton.addAction(UIAction { [weak self] _ in self?.handleSignTap() }, for: .touchUpInside)
    sortButton.addAction(UIAction { [weak self] _ in self?.handleSortTap() }, for: .touchUpInside)
    applySignButton()

    let row = UIStackView(arrangedSubviews: [avatarControl, searchButton, signButton, sortButton])
    row.axis = .horizontal
    row.alignment = .center
    row.spacing = 8
    row.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(row)
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
      row.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
      row.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
      row.heightAnchor.constraint(equalToConstant: 36),
    ])
    return row
  }

  private func applySignButton() {
    let signing = TiebaSignService.shared.isSigning
    var sign = signButton.configuration ?? .gray()
    sign.image = UIImage(systemName: signing ? "checkmark.seal.fill" : "checkmark.seal")
    sign.baseForegroundColor = signing ? TiebaNavigator.shared.chromeTheme.tint : .label
    signButton.configuration = sign
    signButton.accessibilityLabel = "一键签到"
    var sort = sortButton.configuration ?? .gray()
    sort.image = UIImage(systemName: sortMode == .level ? "arrow.up.arrow.down" : "textformat.abc")
    sortButton.configuration = sort
    sortButton.isEnabled = isLoggedIn
    sortButton.accessibilityLabel = sortMode == .level ? "按等级排序" : "按名称排序"
  }

  // MARK: - 最近访问

  private func buildHistoryRow(below topBar: UIStackView) {
    historyTitle.text = "最近访问"
    historyTitle.font = UIFontMetrics(forTextStyle: .subheadline)
      .scaledFont(for: .systemFont(ofSize: 15, weight: .semibold))
    var toggle = UIButton.Configuration.plain()
    toggle.image = UIImage(systemName: "chevron.up")
    toggle.imagePadding = 4
    toggle.baseForegroundColor = TiebaNavigator.shared.chromeTheme.tint
    historyToggle.configuration = toggle
    historyToggle.addAction(UIAction { [weak self] _ in self?.toggleHistory() }, for: .touchUpInside)
    let headerStack = UIStackView(arrangedSubviews: [historyTitle, UIView(), historyToggle])
    headerStack.axis = .horizontal
    headerStack.alignment = .center
    headerStack.translatesAutoresizingMaskIntoConstraints = false
    historyHeader.addSubview(headerStack)
    historyHeader.translatesAutoresizingMaskIntoConstraints = false

    historyScroll.translatesAutoresizingMaskIntoConstraints = false
    historyScroll.showsHorizontalScrollIndicator = false
    historyScroll.contentInset = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
    historyStack.axis = .horizontal
    historyStack.spacing = 8
    historyStack.alignment = .center
    historyStack.translatesAutoresizingMaskIntoConstraints = false
    historyScroll.addSubview(historyStack)

    view.addSubview(historyHeader)
    view.addSubview(historyScroll)
    let height = historyScroll.heightAnchor.constraint(equalToConstant: 0)
    historyHeight = height
    NSLayoutConstraint.activate([
      historyHeader.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
      historyHeader.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
      historyHeader.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 4),
      historyHeader.heightAnchor.constraint(equalToConstant: 30),
      headerStack.leadingAnchor.constraint(equalTo: historyHeader.leadingAnchor),
      headerStack.trailingAnchor.constraint(equalTo: historyHeader.trailingAnchor),
      headerStack.topAnchor.constraint(equalTo: historyHeader.topAnchor),
      headerStack.bottomAnchor.constraint(equalTo: historyHeader.bottomAnchor),
      historyScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      historyScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      historyScroll.topAnchor.constraint(equalTo: historyHeader.bottomAnchor),
      height,
      historyStack.leadingAnchor.constraint(equalTo: historyScroll.contentLayoutGuide.leadingAnchor),
      historyStack.trailingAnchor.constraint(equalTo: historyScroll.contentLayoutGuide.trailingAnchor),
      historyStack.topAnchor.constraint(equalTo: historyScroll.contentLayoutGuide.topAnchor),
      historyStack.bottomAnchor.constraint(equalTo: historyScroll.contentLayoutGuide.bottomAnchor),
      historyStack.heightAnchor.constraint(equalTo: historyScroll.frameLayoutGuide.heightAnchor),
    ])
    historyHeader.isHidden = true
    historyScroll.isHidden = true
  }

  private func toggleHistory() {
    historyExpanded.toggle()
    TiebaSceneHaptics.fire("toggle")
    updateHistoryVisibility()
  }

  private func updateHistoryVisibility() {
    let show = TiebaPreferenceSnapshot.bool("homePageShowHistoryForum", default: true)
      && !recentForums.isEmpty
    historyHeader.isHidden = !show
    historyScroll.isHidden = !(show && historyExpanded)
    historyHeight?.constant = (show && historyExpanded) ? 34 : 0
    var toggle = historyToggle.configuration ?? .plain()
    toggle.image = UIImage(systemName: historyExpanded ? "chevron.up" : "chevron.down")
    toggle.title = historyExpanded ? "收起" : "展开"
    historyToggle.configuration = toggle
    view.setNeedsLayout()
  }

  private func loadRecentForums() {
    // 原 JS 只在已登录分支渲染最近访问：未登录态不出药丸行（偏好显式开启也不出）。
    guard isLoggedIn,
      TiebaPreferenceSnapshot.bool("homePageShowHistoryForum", default: true)
    else {
      recentForums = []
      updateHistoryVisibility()
      return
    }
    recentForums = Self.readRecentForums()
    rebuildHistoryPills()
    updateHistoryVisibility()
  }

  private func rebuildHistoryPills() {
    historyStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    for forum in recentForums {
      let control = TiebaHistoryPill()
      control.configure(name: forum.forumName, avatar: forum.avatar)
      control.addAction(UIAction { [weak self] _ in
        TiebaSceneHaptics.fire("press")
        self?.openForum(forum.forumName)
      }, for: .touchUpInside)
      historyStack.addArrangedSubview(control)
    }
  }

  /// 最近访问只读缓存：写入方每加一行都带新时间戳，(MAX(timestamp), COUNT(*))
  /// 不变即表内容仍是上次那份 → 跳过整表读 + 头像 KV 的 JSON 解。
  /// （头像 KV 若在此期间单独变化，最多迟一次出现才反映——记录列本身优先带头像。）
  private static var recentForumsCache: (stamp: Double, count: Int, items: [RecentForum])?
  /// 头像 KV 解析缓存：原文相同直接复用（比较字符串 ≪ 解 JSON）。
  private static var avatarMapCache: (raw: String, map: [String: String])?

  /// 最近访问（visit_history 表，type=forum，时间倒序 + 吧名去重）；头像优先
  /// 记录列，缺失时读全站吧头像磁盘缓存（JS 写的同一份 KV，只读）。
  private static func readRecentForums() -> [RecentForum] {
    let probe = try? TiebaSQLite.shared.queryFirst(
      database: TiebaSQLite.mainDatabase,
      sql: "SELECT MAX(timestamp) AS ts, COUNT(*) AS n FROM visit_history WHERE type = 'forum'",
      params: []
    )
    let stamp = TiebaSimpleRowParser.double(probe?["ts"]) ?? 0
    let count = Int(TiebaSimpleRowParser.double(probe?["n"]) ?? 0)
    if let cache = recentForumsCache, cache.stamp == stamp, cache.count == count {
      return cache.items
    }
    guard let rows = try? TiebaSQLite.shared.query(
      database: TiebaSQLite.mainDatabase,
      sql: "SELECT forum_name, forum_id, avatar FROM visit_history WHERE type = 'forum' ORDER BY timestamp DESC, id DESC",
      params: []
    ) else { return [] }
    var seen = Set<String>()
    var result: [RecentForum] = []
    let cache = forumAvatarCache()
    for row in rows {
      let name = (row["forum_name"] as? String) ?? ""
      guard !name.isEmpty, seen.insert(name).inserted else { continue }
      var item = RecentForum()
      item.forumName = name
      item.forumId = (row["forum_id"] as? String) ?? ""
      item.avatar = (row["avatar"] as? String) ?? ""
      if item.avatar.isEmpty {
        let key = item.forumId.isEmpty || item.forumId == "0" ? "n:\(name)" : item.forumId
        item.avatar = cache[key] ?? ""
      }
      result.append(item)
      if result.count >= 20 { break }
    }
    recentForumsCache = (stamp, count, result)
    return result
  }

  private static func forumAvatarCache() -> [String: String] {
    guard let raw = TiebaKvStore.shared.get(key: "forum_avatars_v1") else { return [:] }
    if let cache = avatarMapCache, cache.raw == raw { return cache.map }
    guard let data = raw.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]]
    else { return [:] }
    var out: [String: String] = [:]
    for (key, value) in object {
      if let avatar = value["avatar"] as? String, !avatar.isEmpty { out[key] = avatar }
    }
    avatarMapCache = (raw, out)
    return out
  }

  // MARK: - 列表

  private func buildList() {
    layout.scrollDirection = .vertical
    layout.minimumLineSpacing = 8
    layout.minimumInteritemSpacing = 4
    layout.sectionInset = UIEdgeInsets(top: 8, left: 16, bottom: 24, right: 16)
    collectionView.translatesAutoresizingMaskIntoConstraints = false
    collectionView.backgroundColor = .clear
    collectionView.alwaysBounceVertical = true
    collectionView.contentInsetAdjustmentBehavior = .never
    collectionView.delegate = self
    collectionView.register(TiebaHomeForumCell.self, forCellWithReuseIdentifier: TiebaHomeForumCell.reuseID)
    collectionView.refreshControl = refreshControl
    refreshControl.addTarget(self, action: #selector(handleRefreshControl), for: .valueChanged)
    stateView.isDark = TiebaNavigator.shared.chromeTheme.dark
    stateView.isHidden = true
    // 首屏骨架：通用列表行（原 index.tsx SkeletonList variant="row" count={8}）
    stateView.skeletonVariant = .row
    stateView.skeletonInsets = UIEdgeInsets(top: 8, left: 16, bottom: 24, right: 16)
    stateView.onButtonPress = { [weak self] id in
      if id == "login" {
        TiebaNavigator.shared.navigate(path: "/login", params: [:], mode: "push")
      } else {
        self?.loadFollowedForums(force: true)
      }
    }
    for subview in [collectionView, stateView] as [UIView] {
      subview.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(subview)
    }
    NSLayoutConstraint.activate([
      collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      collectionView.topAnchor.constraint(equalTo: historyScroll.bottomAnchor),
      collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      stateView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      stateView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      stateView.topAnchor.constraint(equalTo: historyScroll.bottomAnchor),
      stateView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    dataSource = UICollectionViewDiffableDataSource<String, String>(
      collectionView: collectionView
    ) { [weak self] collectionView, indexPath, forumId in
      let cell = collectionView.dequeueReusableCell(
        withReuseIdentifier: TiebaHomeForumCell.reuseID,
        for: indexPath
      ) as? TiebaHomeForumCell
      guard let self, self.displayedForums.indices.contains(indexPath.item) else { return cell }
      let forum = self.displayedForums[indexPath.item]
      cell?.configure(forum: forum)
      cell?.onUnfollow = { [weak self] in self?.confirmUnfollow(forum) }
      if self.entrancePending { cell?.playEntrance(index: indexPath.item) }
      return cell
    }
    collectionView.dataSource = dataSource
    updateLayoutMetrics()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    collectionView.contentInset.bottom = view.safeAreaInsets.bottom + 16
    let size = itemSize(for: view.bounds.width)
    if layout.itemSize != size {
      layout.itemSize = size
      layout.invalidateLayout()
    }
  }

  /// 尺寸变化只失效布局：全量 reloadData 会与 diffable dataSource 的快照应用
  /// 打架（每次出现都整屏重载）。
  private func updateLayoutMetrics() {
    let size = itemSize(for: view.bounds.width)
    guard layout.itemSize != size else { return }
    layout.itemSize = size
    layout.invalidateLayout()
  }

  private func itemSize(for width: CGFloat) -> CGSize {
    let available = max(width - 32, 0)
    if isSingleColumn { return CGSize(width: available, height: 62) }
    return CGSize(width: max((available - 4) / 2, 0), height: 58)
  }

  private func sortedForums() -> [TiebaForumInfo] {
    forums.sorted { lhs, rhs in
      if sortMode == .name {
        return lhs.forumName.localizedStandardCompare(rhs.forumName) == .orderedAscending
      }
      return lhs.levelId > rhs.levelId
    }
  }

  // MARK: - 数据

  /// force = 用户主动刷新/签到后：跳过原生缓存直连服务端。
  private func loadFollowedForums(force: Bool = false) {
    guard !isLoading else {
      refreshControl.endRefreshing()
      return
    }
    guard isLoggedIn else {
      refreshControl.endRefreshing()
      forums = []
      applyList()
      return
    }
    isLoading = true
    if forums.isEmpty, !hasLoadedOnce { showState(.loading) }
    Task { @MainActor in
      defer {
        isLoading = false
        isUserRefresh = false
        refreshControl.endRefreshing()
      }
      do {
        let list = try await TiebaFollowedForums.fetchAll(force: force)
        forums = list
        hasLoadedOnce = true
        if forums.isEmpty {
          showState(.empty(image: "tray", text: "暂无关注的贴吧", secondary: "去发现页探索感兴趣的贴吧吧"))
        } else {
          startEntrance()
          applyList()
          showList()
        }
        if isUserRefresh { TiebaSceneHaptics.fire("toggle") }
      } catch {
        if forums.isEmpty {
          showState(.error(message: error.localizedDescription))
        } else {
          pill.showResult(success: false, text: "加载失败")
        }
      }
    }
  }

  private func applyList() {
    displayedForums = sortedForums()
    var snapshot = NSDiffableDataSourceSnapshot<String, String>()
    snapshot.appendSections(["main"])
    snapshot.appendItems(displayedForums.map(\.forumId), toSection: "main")
    // 同一批 id 时 diff 不重配 cell（签到态/等级更新就看不到）：显式 reload 可见项
    //（替代原来 updateLayoutMetrics 里的全量 reloadData）。
    if !snapshot.itemIdentifiers.isEmpty,
      snapshot.itemIdentifiers == dataSource?.snapshot().itemIdentifiers
    {
      snapshot.reloadItems(snapshot.itemIdentifiers)
    }
    dataSource?.apply(snapshot, animatingDifferences: false)
  }

  private func startEntrance() {
    guard !entranceDone else { return }
    entranceDone = true
    entrancePending = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
      self?.entrancePending = false
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

  /// 未登录：顶栏可见（签到/排序禁用）、列表换成登录引导（旧 HomeScreen 分支）。
  private func applyLoginState() {
    // 未登录也显示首字占位（原 JS：initials = account?.name?.charAt(0) || '?'）。
    let account = TiebaUserAPI.currentAccount()
    avatarView.configure(
      url: TiebaSimpleRowParser.avatarURL(account?.portrait ?? "")?.absoluteString ?? "",
      initial: account?.initials ?? "?"
    )
    guard isLoggedIn else {
      forums = []
      applyList()
      showState(.login(text: "你还未登录", secondary: "登录后查看关注的贴吧动态"))
      return
    }
  }

  private func openForum(_ name: String) {
    guard !name.isEmpty else { return }
    TiebaNavigator.shared.navigate(path: "/forum/\(TiebaRoutePath.segment(name))", params: [:], mode: "push")
  }

  // MARK: - 动作

  private func handleAvatarTap() {
    TiebaSceneHaptics.fire("press")
    TiebaUserAPI.navigateToOwnProfile()
  }

  private func handleSortTap() {
    guard isLoggedIn else { return }
    TiebaSceneHaptics.fire("toggle")
    sortMode = sortMode == .level ? .name : .level
    saveSortMode()
    collectionView.setContentOffset(
      CGPoint(x: 0, y: -collectionView.adjustedContentInset.top),
      animated: true
    )
    applyList()
    applySignButton()
    // 错误/空态下排序不切列表：forums 为空时 showList 会让错误面板消失只剩空白。
    if !forums.isEmpty { showList() }
  }

  private func handleSignTap() {
    guard isLoggedIn else {
      let alert = UIAlertController(title: "提示", message: "签到需要先登录百度账号", preferredStyle: .alert)
      alert.addAction(UIAlertAction(title: "去登录", style: .default) { _ in
        TiebaNavigator.shared.navigate(path: "/login", params: [:], mode: "push")
      })
      alert.addAction(UIAlertAction(title: "取消", style: .cancel))
      present(alert, animated: true)
      return
    }
    guard forums.contains(where: { !$0.isSign }) else {
      pill.showResult(success: true, text: "今天所有关注的吧都已签到过了")
      return
    }
    TiebaSceneHaptics.fire("action-success")
    TiebaSignService.shared.start(presenter: self)
  }

  @objc private func handleRefreshControl() {
    isUserRefresh = true
    loadFollowedForums(force: true)
    loadRecentForums()
  }

  private func confirmUnfollow(_ forum: TiebaForumInfo) {
    let alert = UIAlertController(
      title: "取消关注",
      message: "确定不再关注「\(forum.forumName)吧」吗？",
      preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(title: "取消", style: .cancel))
    alert.addAction(UIAlertAction(title: "取消关注", style: .destructive) { [weak self] _ in
      Task { @MainActor in
        do {
          try await TiebaFollowedForums.unfollow(forumId: forum.forumId, forumName: forum.forumName)
          TiebaSceneHaptics.fire("action-success")
          self?.forums.removeAll { $0.forumId == forum.forumId }
          self?.applyList()
          self?.loadFollowedForums(force: true)
        } catch {
          TiebaSceneHaptics.fire("action-fail")
          self?.pill.showResult(success: false, text: "取消关注失败")
        }
      }
    })
    present(alert, animated: true)
  }

  // MARK: - 排序偏好（page-private 键；共享偏好只读）

  private func loadSortMode() -> SortMode {
    if let raw = TiebaKvStore.shared.get(key: Self.sortKey) {
      return SortMode(rawValue: raw) ?? .level
    }
    return SortMode(rawValue: TiebaPreferenceSnapshot.string("forumSortMode") ?? "level") ?? .level
  }

  private func saveSortMode() {
    try? TiebaKvStore.shared.set(key: Self.sortKey, value: sortMode.rawValue)
  }
}

// MARK: - 列表代理

extension TiebaHomeViewController: UICollectionViewDelegate {
  func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
    collectionView.deselectItem(at: indexPath, animated: false)
    guard displayedForums.indices.contains(indexPath.item) else { return }
    TiebaSceneHaptics.fire("press")
    openForum(displayedForums[indexPath.item].forumName)
  }
}

// MARK: - 吧单元格

final class TiebaHomeForumCell: UICollectionViewCell {
  static let reuseID = "TiebaHomeForumCell"

  var onUnfollow: (() -> Void)?

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
    nameLabel.font = UIFontMetrics(forTextStyle: .subheadline)
      .scaledFont(for: .systemFont(ofSize: 15, weight: .semibold))
    nameLabel.adjustsFontForContentSizeCategory = true
    nameLabel.numberOfLines = 1
    metaLabel.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(for: .systemFont(ofSize: 12))
    metaLabel.textColor = .tertiaryLabel
    levelLabel.font = UIFontMetrics(forTextStyle: .caption1)
      .scaledFont(for: .systemFont(ofSize: 12, weight: .bold))
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
    levelLabel.textColor = tint
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

  /// 首屏入场（原 EntranceRow）：220ms fade + 12pt 上移，35ms 级联。
  func playEntrance(index: Int) {
    guard !playedEntrance else { return }
    playedEntrance = true
    alpha = 0
    transform = CGAffineTransform(translationX: 0, y: 12)
    UIView.animate(
      withDuration: 0.22,
      delay: min(Double(index), 10) * 0.035,
      options: [.curveEaseOut],
      animations: {
        self.alpha = 1
        self.transform = .identity
      }
    )
  }

  override func prepareForReuse() {
    super.prepareForReuse()
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
    label.font = UIFontMetrics(forTextStyle: .footnote)
      .scaledFont(for: .systemFont(ofSize: 13, weight: .medium))
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
