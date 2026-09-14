// 搜索页（原 src/app/search/index.tsx）：系统 UISearchBar + 贴/吧/人分段 +
// 排序菜单 + 历史/建议 + 结果列表（贴 = 信息流行，吧/人 = 通用行）。
import UIKit

final class TiebaSearchViewController: UIViewController, TiebaNativeScreen {
  private enum Tab: Int, CaseIterable {
    case thread
    case forum
    case user

    var title: String {
      switch self {
      case .thread: return "贴"
      case .forum: return "吧"
      case .user: return "人"
      }
    }
  }

  /// 不要标题：搜索词在搜索框里，顶栏只留返回键 + 搜索栏（用户反馈）。
  /// 空串（而非 nil）= 显式清掉路由表的默认标题。
  var screenTitle: String? { "" }

  /// 搜索栏走系统 navigationItem.searchController（宿主挂载，外观/玻璃/取消态
  /// 由系统接管），不再手贴约束。
  private let searchController = UISearchController(searchResultsController: nil)
  private var searchBar: UISearchBar { searchController.searchBar }
  private let segmented = UISegmentedControl(items: Tab.allCases.map(\.title))
  private let sortButton = UIButton(type: .system)
  private let sortRow = UIView()
  /// 顶栏两行的链式约束（在 viewDidLoad 里建、在 updateChrome 里折叠）。
  /// 折叠 = 高度与间距一起归零，见 viewDidLoad 的说明。
  private lazy var segmentTop = segmented.topAnchor.constraint(
    equalTo: view.safeAreaLayoutGuide.topAnchor,
    constant: 2
  )
  /// 收起时给分段控件钉一个 0 高度（required 压得过内在高度 750）；展开时停用，
  /// 回到系统内在高度。不给展开态写死常量，免得跟着系统尺寸变。
  private lazy var segmentCollapsed = segmented.heightAnchor.constraint(equalToConstant: 0)
  private lazy var sortTop = sortRow.topAnchor.constraint(
    equalTo: segmented.bottomAnchor,
    constant: 2
  )
  private lazy var sortHeight = sortRow.heightAnchor.constraint(equalToConstant: 34)
  private let historyView = TiebaSearchHistoryView()
  private let list = TiebaKindListContentView()
  private let stateView = TiebaStateContentView()
  private let pill = TiebaPhotoBrowserPillView()

  private var threadHits: [TiebaSearchAPI.ThreadHit] = []
  private var forumHits: [TiebaSearchAPI.ForumHit] = []
  private var userHits: [TiebaSearchAPI.UserHit] = []
  private var history: [TiebaSearchHistory.Item] = []
  private var expandedIds: Set<String> = []
  private var likeMirror: [String: Bool] = [:]
  private var keyword = ""
  /// 深链带进来的初始关键词（只消费一次，见 viewDidAppear）。
  private var initialKeyword: String

  init(initialKeyword: String = "") {
    self.initialKeyword = initialKeyword
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  private var hasSearched = false
  private var activeTab: Tab = .thread
  /// 当前关键词已出结果的 tab（JS useSearchController.searchedTabsRef 同义）：
  /// 切回已搜 tab 直接显示自己的桶，未搜 tab 才发请求并进加载态。
  private var searchedTabs: Set<Tab> = []
  private var order = 5
  private var page = 1
  private var hasMore = false
  private var isLoading = false
  private var requestSeq = 0
  private var pageKey = ""
  private var pageSeq = 0
  private var lastWidth: CGFloat = 0
  private var needsPublish = false
  private var needsReveal = false
  private var suggestions: [String] = []

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = TiebaNavigator.shared.chromeTheme.background
    setupSearchController()
    setupSortButton()
    historyView.onSelect = { [weak self] text in self?.commit(text) }
    historyView.onDelete = { [weak self] text in self?.deleteHistory(text) }
    historyView.onClear = { [weak self] in self?.clearHistory() }
    historyView.onToggleExpand = { [weak self] in
      guard let self else { return }
      historyViewExpanded.toggle()
      refreshHistory()
    }
    stateView.isDark = TiebaNavigator.shared.chromeTheme.dark
    stateView.onButtonPress = { [weak self] _ in self?.runSearch(reset: true) }
    // 搜索骨架：贴 tab = thread、吧/人 tab = row（原 SearchResultList.tsx count 6）
    stateView.skeletonVariant = .thread
    stateView.skeletonCount = 6
    list.onEvent = { [weak self] name, payload in self?.handleEvent(name, payload) }
    segmented.selectedSegmentIndex = Tab.thread.rawValue
    segmented.addTarget(self, action: #selector(handleTabChange), for: .valueChanged)

    // ⚠️ 顶栏两行的折叠必须靠「高度 + 前后间距一起归零」，不能用竖向栈：裸 isHidden
    // 不撤销约束会白占约 70pt，而栈在「三个内容区同时隐藏」的那一帧（切 tab 时
    // stateView 先藏、列表还没 reveal）会把剩余高度全分给分段行，UISegmentedControl
    // 被拉成整屏椭圆、内容区被挤成 0 高（真机截图实证）。扁平绝对约束没有这个歧义。
    sortRow.addSubview(sortButton)
    for subview in [segmented, sortRow, historyView, list, stateView, pill] as [UIView] {
      subview.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(subview)
    }
    sortButton.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      segmented.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
      segmented.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
      segmentTop,
      sortRow.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      sortRow.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      sortTop,
      sortHeight,
      sortButton.leadingAnchor.constraint(equalTo: sortRow.leadingAnchor, constant: 16),
      sortButton.centerYAnchor.constraint(equalTo: sortRow.centerYAnchor),
      historyView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      historyView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      historyView.topAnchor.constraint(equalTo: sortRow.bottomAnchor),
      historyView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      list.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      list.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      list.topAnchor.constraint(equalTo: sortRow.bottomAnchor),
      list.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      stateView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      stateView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      stateView.topAnchor.constraint(equalTo: sortRow.bottomAnchor),
      stateView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      pill.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      pill.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
      pill.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.82),
    ])
    list.isHidden = true
    stateView.isHidden = true
    refreshHistory()
    updateChrome()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    // 出现动画落定后才做行测量/设页：转场期间 publish 会在推入动画里做整页测量 +
    // 快照 apply，直接表现成搜索栏弹出时掉帧（真机反馈）。
    if needsPublish, lastWidth > 0 {
      needsPublish = false
      let reveal = needsReveal
      needsReveal = false
      publish(fresh: false, reveal: reveal)
    }
    // 深链带关键词（tiebalite://search?q=…）：出现后直接出结果，不再抢焦点。
    if !initialKeyword.isEmpty, !hasSearched {
      let keyword = initialKeyword
      initialKeyword = ""
      commit(keyword)
    }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    // 页键发布保留本页实现（reveal 需要 setPage 完成回调，driver 无该钩子）；
    // 宽度量化仍走全仓唯一实现。
    lastWidth = TiebaLayout.quantize(list.bounds.width)
    // 转场未结束时只记账（见 viewDidAppear）：transitionCoordinator 非 nil 期间
    // 布局每次变化都会走这里，就地 publish 会把测量压进推入动画。
    if lastWidth > 0, transitionCoordinator == nil, needsPublish {
      needsPublish = false
      let reveal = needsReveal
      needsReveal = false
      publish(fresh: false, reveal: reveal)
    }
    list.contentInsetBottom = view.safeAreaInsets.bottom + 16
  }

  // MARK: - 顶部控件

  /// 搜索栏挂宿主 navigationItem（本屏 chrome = .standard，宿主即栈里那屏）。
  private func setupSearchController() {
    searchBar.delegate = self
    searchBar.placeholder = "搜吧、搜贴、搜人"
    searchBar.returnKeyType = .search
    searchBar.autocorrectionType = .no
    searchBar.autocapitalizationType = .none
    // 结果是本页自己的列表：激活时不让系统压暗/遮挡内容。
    searchController.obscuresBackgroundDuringPresentation = false
    guard let host = parent as? TiebaRouteHostViewController else {
      preconditionFailure("搜索页必须挂在 TiebaRouteHostViewController 下")
    }
    // ⚠️ iOS 26 默认会把搜索栏"整合进底部工具栏"（UINavigationItemSearchBarPlacement
    // Integrated 的注释原文）——页面顶部于是空成一片。点名 .integrated 让搜索栏
    // 留在顶栏内联（原生 Mail/信息 的形态），并把工具栏整合关掉，否则 iPhone 上
    // 仍会被系统挪到底部；也不用 .stacked：那会撑出大标题那一圈高度，页面顶部留白。
    // iOS 26 默认会把搜索栏整合进底部工具栏（UINavigationItemSearchBarPlacement
    // Integrated 的注释原文），页面顶部于是空成一片：点名 .integrated 让它留在
    // 顶栏内联（原生 Mail/信息 形态），并关掉工具栏整合，否则仍会被挪到底部。
    // .stacked 也不要用——那会撑出大标题那一圈高度，顶栏下方空一大段。
    host.navigationItem.preferredSearchBarPlacement = .integrated
    host.navigationItem.searchBarPlacementAllowsToolbarIntegration = false
    host.navigationItem.searchController = searchController
    host.navigationItem.hidesSearchBarWhenScrolling = false
  }

  private func setupSortButton() {
    var config = UIButton.Configuration.plain()
    config.image = UIImage(systemName: "chevron.down")
    config.imagePlacement = .trailing
    config.imagePadding = 4
    config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4)
    sortButton.configuration = config
    sortButton.showsMenuAsPrimaryAction = true
    rebuildSortMenu()
  }

  private func rebuildSortMenu() {
    let options: [(value: Int, title: String)] = [(5, "按时间"), (2, "按相关性")]
    let actions = options.map { option in
      UIAction(
        title: option.title,
        state: order == option.value ? .on : .off
      ) { [weak self] _ in
        guard let self, order != option.value else { return }
        order = option.value
        rebuildSortMenu()
        if !keyword.isEmpty { runSearch(reset: true) }
      }
    }
    sortButton.menu = UIMenu(children: actions)
    var config = sortButton.configuration
    config?.title = options.first { $0.value == order }?.title ?? "按时间"
    sortButton.configuration = config
  }

  private var historyViewExpanded = false

  private func updateChrome() {
    // 编辑态（聚焦且清空）也回历史/建议区；否则首次搜索后 historyView 再也出不来，
    // suggestions 成死代码。
    let editing = searchBar.isFirstResponder && (searchBar.text ?? "").isEmpty
    let showHistory = !hasSearched || editing
    let showSegment = hasSearched
    let showSort = hasSearched && activeTab == .thread
    segmented.isHidden = !showSegment
    sortRow.isHidden = !showSort
    // 高度与间距一起归零才算真收起（内容区是绝对约束，跟着 sortRow 底边走）。
    segmentTop.constant = showSegment ? 2 : 0
    segmentCollapsed.isActive = !showSegment
    sortTop.constant = showSort ? 2 : 0
    sortHeight.constant = showSort ? 34 : 0
    historyView.isHidden = !showHistory
    if showHistory {
      list.isHidden = true
      stateView.isHidden = true
    } else if let currentState {
      // 退出编辑态要把结果区按原状态放回来：只藏不还原（清空后又输入）会剩下
      // 整块空白——historyView 藏了、列表还被关着。
      showState(currentState)
    } else {
      showList()
    }
  }

  // MARK: - 历史

  private func refreshHistory() {
    history = TiebaSearchHistory.load(forumId: nil, limit: 20)
    suggestions = currentSuggestions()
    historyView.configure(
      suggestions: suggestions,
      history: history,
      expanded: historyViewExpanded
    )
  }

  private func currentSuggestions() -> [String] {
    let text = (searchBar.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return [] }
    return history.map(\.keyword).filter { $0.hasPrefix(text) }.prefix(5).map { $0 }
  }

  private func deleteHistory(_ text: String) {
    history = TiebaSearchHistory.remove(keyword: text, forumId: nil, limit: 20)
    refreshHistory()
  }

  private func clearHistory() {
    TiebaSceneHaptics.fire("destructive")
    TiebaSearchHistory.clear(forumId: nil)
    refreshHistory()
  }

  // MARK: - 搜索

  @objc private func handleTabChange() {
    guard let next = Tab(rawValue: segmented.selectedSegmentIndex), next != activeTab else { return }
    TiebaSceneHaptics.fire("segment")
    activeTab = next
    updateChrome()
    guard hasSearched, !keyword.isEmpty else { return }
    // JS selectTab：已搜过的 tab 直接显示自己的桶（零请求），未搜的才发起。
    // 旧实现按 currentCount 传 silent 重搜 → 列表页仍挂在上一 tab，切过去
    // 看不到加载态、只看到旧 tab 结果（用户反馈）。
    if searchedTabs.contains(next) {
      showCurrentTabContent()
    } else {
      runSearch(reset: true)
    }
  }

  /// 切回已搜 tab：立即上该 tab 自己的桶（空桶 = 空态，有行 = 列表）。
  private func showCurrentTabContent() {
    if currentCount == 0 {
      showState(.empty(image: "doc.text.magnifyingglass", text: emptyText, retryTitle: "重试"))
      return
    }
    list.footerState = activeTab == .thread && hasMore ? .more : .none
    // 行测量 + 设页完成后才显示（reveal）：否则上一 tab 的旧页会多停一帧。
    stateView.isHidden = true
    publish(fresh: true, reveal: true)
  }

  private func commit(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    searchBar.text = trimmed
    searchBar.resignFirstResponder()
    suggestions = []
    // 历史写盘（3 条写 + 重读）不在主线程同步跑；回来后只更内存副本。
    Task { @MainActor in
      history = await TiebaSearchHistory.append(keyword: trimmed, forumId: nil, limit: 20)
    }
    if trimmed == keyword, hasSearched { return }
    keyword = trimmed
    hasSearched = true
    // 新关键词：三桶全清 + 已搜集合只剩当前 tab（JS commitKeyword 同）。
    threadHits = []
    forumHits = []
    userHits = []
    searchedTabs = [activeTab]
    expandedIds = []
    updateChrome()
    runSearch(reset: true)
  }

  /// 结果区当前在显示什么（nil = 列表）：退出编辑态时按它还原（见 updateChrome）。
  private var currentState: TiebaState?

  private func showState(_ state: TiebaState) {
    if case .loading = state {
      // 贴 tab 的真实行是 TweetCard → thread 同形；吧/人 = 通用行
      stateView.skeletonVariant = activeTab == .thread ? .thread : .row
    }
    currentState = state
    stateView.state = state
    stateView.isHidden = false
    list.isHidden = true
  }

  private func showList() {
    currentState = nil
    stateView.isHidden = true
    list.isHidden = false
  }

  private func runSearch(reset: Bool) {
    guard !keyword.isEmpty else { return }
    // 下一页页码只在成功后提交：失败不回退就会跳过一页（page 保持原值可重试）。
    let requestPage = reset ? 1 : page + 1
    if reset { page = 1 }
    requestSeq += 1
    let seq = requestSeq
    let target = activeTab
    isLoading = true
    if reset {
      // 只清当前桶：切 tab / 换排序重搜时其它桶的已有结果保留（与旧页同）。
      switch target {
      case .thread: threadHits = []
      case .forum: forumHits = []
      case .user: userHits = []
      }
      expandedIds = []
      publish(fresh: true)
      // 桶已清空 → 立即加载态（不再沿用上一 tab 留在屏上的列表页）。
      showState(.loading)
    }
    Task { @MainActor in
      defer {
        if seq == requestSeq { isLoading = false }
      }
      do {
        switch target {
        case .thread:
          let result = try await TiebaSearchAPI.threads(keyword: keyword, page: requestPage, order: order)
          guard seq == requestSeq else { return }
          if reset {
            threadHits = result.hits
          } else {
            threadHits.append(contentsOf: result.hits)
          }
          page = requestPage
          hasMore = result.hasMore
        case .forum:
          let hits = try await TiebaSearchAPI.forums(keyword: keyword)
          guard seq == requestSeq else { return }
          forumHits = hits
          hasMore = false
        case .user:
          let hits = try await TiebaSearchAPI.users(keyword: keyword)
          guard seq == requestSeq else { return }
          userHits = hits
          hasMore = false
        }
        searchedTabs.insert(target)
        // 只有目标 tab 还是当前 tab 才动 UI：切到已缓存 tab 期间到达的响应
        // 只落桶，屏上显示的是新 activeTab 自己的内容。
        if target == activeTab {
          if currentCount == 0 {
            showState(.empty(image: "doc.text.magnifyingglass", text: emptyText, retryTitle: "重试"))
          } else {
            list.footerState = target == .thread && hasMore ? .more : .none
            // 设页完成后再显示：新页落位前不露出上一 tab 的旧页。
            publish(fresh: true, reveal: true)
          }
          if reset, isUserRefresh { TiebaSceneHaptics.fire("toggle") }
        }
      } catch {
        guard seq == requestSeq else { return }
        if target == activeTab, currentCount == 0 {
          showState(.error(message: error.localizedDescription))
        } else if target == activeTab {
          // 已有结果时静默失败：底部 loadMore 态要复位，否则 spinner 卡住。
          list.footerState = target == .thread && hasMore ? .more : .none
          pill.showResult(success: false, text: "加载失败")
        }
      }
      isUserRefresh = false
      list.endRefreshing()
    }
  }

  private var isUserRefresh = false

  private var currentCount: Int {
    switch activeTab {
    case .thread: return threadHits.count
    case .forum: return forumHits.count
    case .user: return userHits.count
    }
  }

  private var emptyText: String {
    switch activeTab {
    case .thread: return "未找到相关贴子"
    case .forum: return "未找到相关贴吧"
    case .user: return "未找到相关用户"
    }
  }

  private func loadMore() {
    guard activeTab == .thread, hasMore, !isLoading else { return }
    list.footerState = .loading
    runSearch(reset: false)
  }

  // MARK: - 发布行

  private func publish(fresh: Bool, reveal: Bool = false) {
    if fresh {
      pageSeq += 1
      pageKey = "search-\(activeTab.rawValue)-\(pageSeq)"
    }
    guard !pageKey.isEmpty else { return }
    guard lastWidth > 0 else {
      needsPublish = true
      needsReveal = needsReveal || reveal
      return
    }
    let key = pageKey
    let width = lastWidth
    let box = RowsBox(rows: makeRows())
    Task { @MainActor in
      await Task.detached(priority: .userInitiated) {
        TiebaKindRowPages.shared.prepareBlocking(pageKey: key, rows: box.rows, containerWidth: width)
      }.value
      // 晚到的旧页不得覆盖新页：页键已换代（含切 tab，pageKey 前缀带 tab）就丢弃。
      guard key == self.pageKey else { return }
      self.list.setPage(pageKey: key)
      if reveal { self.showList() }
    }
  }

  private struct RowsBox: @unchecked Sendable {
    let rows: [[String: Any]]
  }

  private func makeRows() -> [[String: Any]] {
    switch activeTab {
    case .thread:
      return threadHits.map { hit in
        var row = hit.row
        row["expanded"] = expandedIds.contains(hit.id)
        return row
      }
    case .forum:
      return forumHits.map { themed($0.row) }
    case .user:
      return userHits.map { themed($0.row) }
    }
  }

  /// 通用行的主题色（发布时注入：深色/自定义主题下卡片底与描边才正确）。
  private func themed(_ row: [String: Any]) -> [String: Any] {
    var row = row
    row["colors"] = TiebaRowTheme.colors()
    return row
  }

  // MARK: - 事件

  private func handleEvent(_ name: String, _ payload: [String: Any]) {
    switch name {
    case "rowTap":
      handleRowTap(payload)
    case "menuAction":
      handleMenuAction(payload)
    case "reachEnd", "footerTap":
      loadMore()
    case "refreshRequested":
      isUserRefresh = true
      runSearch(reset: true)
    default:
      break
    }
  }

  private func handleRowTap(_ payload: [String: Any]) {
    guard let index = payload["index"] as? Int else { return }
    switch activeTab {
    case .thread:
      guard threadHits.indices.contains(index) else { return }
      let thread = threadHits[index]
      switch payload["region"] as? String ?? "card" {
      case "chip":
        let forumName = TiebaSimpleRowParser.string(thread.row["forumName"]) ?? ""
        guard !forumName.isEmpty else { return }
        TiebaNavigator.shared.navigate(path: "/forum/\(TiebaRoutePath.segment(forumName))", params: [:], mode: "push")
      case "action":
        switch payload["actionIndex"] as? Int {
        case 1: shareThread(thread)
        case 2: toggleLike(thread, index: index)
        default: openThread(thread)
        }
      case "showMore":
        guard !thread.id.isEmpty, expandedIds.insert(thread.id).inserted else { return }
        TiebaSceneHaptics.fire("toggle")
        publish(fresh: true)
      default:
        openThread(thread)
      }
    case .forum:
      guard forumHits.indices.contains(index) else { return }
      let name = forumHits[index].name
      guard !name.isEmpty else { return }
      TiebaSceneHaptics.fire("press")
      TiebaNavigator.shared.navigate(path: "/forum/\(TiebaRoutePath.segment(name))", params: [:], mode: "push")
    case .user:
      guard userHits.indices.contains(index) else { return }
      let uid = userHits[index].uid
      guard !uid.isEmpty else { return }
      TiebaSceneHaptics.fire("press")
      TiebaNavigator.shared.navigate(path: "/user/\(uid)", params: [:], mode: "push")
    }
  }

  private func handleMenuAction(_ payload: [String: Any]) {
    guard activeTab == .thread,
      let index = payload["index"] as? Int,
      threadHits.indices.contains(index)
    else { return }
    let thread = threadHits[index]
    switch payload["action"] as? String {
    case "block":
      blockAuthor(thread)
    case "dislike":
      presentDislikeSheet(thread, index: index)
    case "copy-title":
      let title = TiebaSimpleRowParser.string(thread.row["title"]) ?? ""
      guard !title.isEmpty else { return }
      TiebaClipboard.setString(title)
    case "save-image", "share-image":
      let url = (payload["originUrl"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        ?? payload["url"] as? String ?? ""
      guard !url.isEmpty else { return }
      let forumName = TiebaSimpleRowParser.string(thread.row["forumName"]) ?? ""
      if (payload["action"] as? String) == "save-image" {
        TiebaFeedImageActions.save(url: url, forumName: forumName, presenter: self)
      } else {
        TiebaFeedImageActions.share(
          url: url,
          forumName: forumName,
          presenter: self,
          sourceRect: CGRect(x: view.bounds.midX, y: view.bounds.maxY - 40, width: 1, height: 1)
        )
      }
    default:
      break
    }
  }

  /// 不感兴趣：原因面板 → 上报 → 折叠退场（与动态流同一面板类/上报接口）。
  private func presentDislikeSheet(_ hit: TiebaSearchAPI.ThreadHit, index: Int) {
    TiebaSceneHaptics.fire("sheet-present")
    let sheet = TiebaDislikeSheetViewController { [weak self] ids in
      self?.submitDislike(hit, index: index, ids: ids)
    }
    present(sheet, animated: true)
  }

  private func submitDislike(_ hit: TiebaSearchAPI.ThreadHit, index: Int, ids: String) {
    guard !hit.id.isEmpty else { return }
    let forumId = TiebaSimpleRowParser.string(hit.row["forumId"]) ?? ""
    Task { @MainActor in
      do {
        try await TiebaFeedAPI.submitDislike(
          threadId: hit.id,
          dislikeIds: ids,
          forumId: forumId
        )
        TiebaSceneHaptics.fire("action-success")
        // 先折叠再删（原 JS collapsingId + 360ms 兜底）：下面卡片等新快照补位。
        list.collapseRowThen(atIndex: index) { [weak self] in
          guard let self else { return }
          threadHits.removeAll { $0.id == hit.id }
          if threadHits.isEmpty {
            showState(.empty(image: "doc.text.magnifyingglass", text: emptyText, retryTitle: "重试"))
          } else {
            publish(fresh: true)
          }
        }
      } catch {
        TiebaSceneHaptics.fire("action-fail")
        pill.showResult(success: false, text: "提交失败，请稍后重试")
      }
    }
  }

  private func openThread(_ hit: TiebaSearchAPI.ThreadHit) {
    guard !hit.id.isEmpty else { return }
    TiebaSceneHaptics.fire("press")
    TiebaNavigator.shared.navigate(path: "/thread/\(hit.id)", params: [:], mode: "push")
  }

  private func shareThread(_ hit: TiebaSearchAPI.ThreadHit) {
    let url = "https://tieba.baidu.com/p/\(hit.id)"
    let title = TiebaSimpleRowParser.string(hit.row["title"]) ?? ""
    let controller = UIActivityViewController(
      activityItems: [title.isEmpty ? url : "\(title)\n\(url)"],
      applicationActivities: nil
    )
    if let popover = controller.popoverPresentationController {
      popover.sourceView = view
      popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.maxY - 44, width: 1, height: 1)
      popover.permittedArrowDirections = []
    }
    present(controller, animated: true)
  }

  private func toggleLike(_ hit: TiebaSearchAPI.ThreadHit, index: Int) {
    guard !hit.id.isEmpty else { return }
    guard !TiebaBackgroundSnapshot.shared.bduss.isEmpty else {
      TiebaNavigator.shared.navigate(path: "/login", params: [:], mode: "push")
      return
    }
    let latest = likeMirror[hit.id] ?? (TiebaSimpleRowParser.bool(hit.row["hasAgree"]) ?? false)
    let next = !latest
    likeMirror[hit.id] = next
    TiebaSceneHaptics.fire("like")
    applyLike(index, next)
    Task { @MainActor in
      do {
        try await TiebaThreadActionAPI.setAgree(threadId: hit.id, postId: hit.id, agree: next)
        TiebaSceneHaptics.fire("action-success")
        pill.showResult(success: true, text: next ? "点赞成功" : "已取消点赞")
      } catch {
        if let vmError = error as? TiebaViewModelError, vmError.message.contains("点过赞") {
          TiebaSceneHaptics.fire("action-success")
          return
        }
        TiebaSceneHaptics.fire("action-fail")
        likeMirror[hit.id] = latest
        applyLike(index, latest)
        pill.showResult(success: false, text: "点赞失败，请稍后重试")
      }
    }
  }

  private func applyLike(_ index: Int, _ liked: Bool) {
    guard threadHits.indices.contains(index) else { return }
    var row = threadHits[index].row
    row["hasAgree"] = liked
    let count = TiebaSimpleRowParser.double(row["zanNum"]) ?? 0
    row["zanNum"] = max(0, count + (liked ? 1 : -1))
    threadHits[index].row = row
    publish(fresh: false)
  }

  private func blockAuthor(_ hit: TiebaSearchAPI.ThreadHit) {
    let uid = TiebaSimpleRowParser.string(hit.row["authorId"]) ?? ""
    guard !uid.isEmpty else { return }
    let name = TiebaSimpleRowParser.string(hit.row["authorName"]) ?? ""
    let user = TiebaBlockedUser(
      id: String(Int(Date().timeIntervalSince1970 * 1000)),
      uid: uid,
      username: name.isEmpty ? nil : name
    )
    do {
      try TiebaBlockStore.add(user: user)
    } catch {
      TiebaSceneHaptics.fire("action-fail")
      return
    }
    TiebaSceneHaptics.fire("action-success")
    threadHits.removeAll { $0.id == hit.id }
    if threadHits.isEmpty {
      showState(.empty(image: "doc.text.magnifyingglass", text: emptyText, retryTitle: "重试"))
    } else {
      publish(fresh: true)
    }
  }
}

// MARK: - UISearchBarDelegate

extension TiebaSearchViewController: UISearchBarDelegate {
  func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
    // 编辑态决定历史/建议区可见性（清空回到建议，重新输入回结果）。
    updateChrome()
    suggestions = currentSuggestions()
    historyView.configure(
      suggestions: suggestions,
      history: history,
      expanded: historyViewExpanded
    )
  }

  func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
    searchBar.resignFirstResponder()
    commit(searchBar.text ?? "")
  }

  func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
    searchBar.resignFirstResponder()
    if (searchBar.text ?? "").isEmpty {
      TiebaNavigator.shared.goBack()
      return
    }
    searchBar.text = ""
    refreshHistory()
  }
}
