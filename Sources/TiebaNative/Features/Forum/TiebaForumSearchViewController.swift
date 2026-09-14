// 吧内搜索（原 src/app/forum/[name]/search.tsx）：系统 UISearchBar + 排序/筛选
// 菜单（UIMenu）+ 吧维度历史 + 结果（消息行；带 pid 的直达楼中楼）。
import UIKit

final class TiebaForumSearchViewController: UIViewController, TiebaNativeScreen {
  private let forumName: String
  private let forumId: String

  /// 不要标题：搜索词在搜索框里，顶栏只留返回键 + 搜索栏（用户反馈）。
  /// 空串（而非 nil）= 显式清掉路由表的默认标题。
  var screenTitle: String? { "" }

  /// 裸 UISearchBar 挂宿主 navigationItem.titleView（占满返回键与尾随项之间的
  /// 整条；外观/键盘/清空钮由系统承担）。
  /// ⚠️ 不用 UISearchController：iOS 26 的 .integrated 把搜索栏摆到**尾随边**
  ///（SDK 原文 "on the trailing edge"），顶栏中间空一大片（真机实证）。
  private let searchBar = UISearchBar()
  private let toolRow = UIStackView()
  private let sortButton = UIButton(type: .system)
  private let filterButton = UIButton(type: .system)
  private let historyView = TiebaSearchHistoryView()
  private let list = TiebaKindListContentView()
  /// 整页发布驱动（页键 = forum-search-<seq>）：测量在后台，旧页后到不覆盖新页。
  private lazy var driver = TiebaRowPageDriver(list: list, keyPrefix: "forum-search")
  private let stateView = TiebaStateContentView()
  private let pill = TiebaPhotoBrowserPillView()

  private var hits: [TiebaSearchAPI.PostHit] = []
  private var history: [TiebaSearchHistory.Item] = []
  private var keyword = ""
  private var hasSearched = false
  private var sortType = 1
  private var filterType = 2
  private var page = 1
  private var hasMore = false
  private var isLoading = false
  private var requestSeq = 0
  private var isUserRefresh = false
  private var historyExpanded = true

  private static let maxHistory = 10

  init(name: String, forumId: String) {
    self.forumName = name
    self.forumId = forumId.isEmpty ? name : forumId
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = TiebaNavigator.shared.chromeTheme.background
    setupSearchBar()
    setupToolButtons()
    historyView.onSelect = { [weak self] text in self?.commit(text) }
    historyView.onDelete = { [weak self] text in self?.confirmDeleteHistory(text) }
    historyView.onClear = { [weak self] in self?.clearHistory() }
    historyView.onToggleExpand = { [weak self] in
      guard let self else { return }
      historyExpanded.toggle()
      refreshHistory()
    }
    stateView.isDark = TiebaNavigator.shared.chromeTheme.dark
    stateView.onButtonPress = { [weak self] _ in self?.runSearch(reset: true) }
    // 吧内搜索骨架：thread 卡片（原 forum/[name]/search.tsx count={6} variant="thread"）
    stateView.skeletonVariant = .thread
    stateView.skeletonCount = 6
    list.onEvent = { [weak self] name, payload in self?.handleEvent(name, payload) }

    for subview in [toolRow, historyView, list, stateView, pill] as [UIView] {
      subview.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(subview)
    }
    toolRow.axis = .horizontal
    toolRow.spacing = 12
    toolRow.alignment = .center
    toolRow.addArrangedSubview(sortButton)
    toolRow.addArrangedSubview(filterButton)
    toolRow.addArrangedSubview(UIView())
    NSLayoutConstraint.activate([
      toolRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
      toolRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
      toolRow.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 2),
      toolRow.heightAnchor.constraint(equalToConstant: 34),
      historyView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      historyView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      historyView.topAnchor.constraint(equalTo: toolRow.bottomAnchor),
      historyView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      list.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      list.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      list.topAnchor.constraint(equalTo: toolRow.bottomAnchor),
      list.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      stateView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      stateView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      stateView.topAnchor.constraint(equalTo: toolRow.bottomAnchor),
      stateView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      pill.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      pill.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
      pill.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.82),
    ])
    list.isHidden = true
    stateView.isHidden = true
    refreshHistory()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    driver.updateWidth(list.bounds.width)
    list.contentInsetBottom = view.safeAreaInsets.bottom + 16
  }

  // MARK: - 顶部控件

  /// 搜索栏挂宿主 navigationItem.titleView（本屏 chrome = .standard，宿主即栈里那屏）。
  private func setupSearchBar() {
    searchBar.delegate = self
    searchBar.placeholder = "搜索吧内帖子..."
    searchBar.returnKeyType = .search
    searchBar.autocorrectionType = .no
    guard let host = parent as? TiebaRouteHostViewController else {
      preconditionFailure("吧内搜索必须挂在 TiebaRouteHostViewController 下")
    }
    host.navigationItem.titleView = searchBar
  }

  private func setupToolButtons() {
    for button in [sortButton, filterButton] {
      var config = UIButton.Configuration.tinted()
      config.image = UIImage(systemName: "chevron.down")
      config.imagePlacement = .trailing
      config.imagePadding = 4
      config.cornerStyle = .capsule
      config.buttonSize = .small
      button.configuration = config
      button.showsMenuAsPrimaryAction = true
    }
    rebuildMenus()
  }

  private func rebuildMenus() {
    let sorts: [(value: Int, title: String)] = [(1, "按时间"), (2, "按相关性")]
    let filters: [(value: Int, title: String)] = [(2, "全部"), (1, "仅主题贴")]
    sortButton.menu = UIMenu(children: sorts.map { option in
      UIAction(title: option.title, state: sortType == option.value ? .on : .off) { [weak self] _ in
        guard let self, sortType != option.value else { return }
        sortType = option.value
        rebuildMenus()
        if hasSearched { runSearch(reset: true) }
      }
    })
    filterButton.menu = UIMenu(children: filters.map { option in
      UIAction(title: option.title, state: filterType == option.value ? .on : .off) { [weak self] _ in
        guard let self, filterType != option.value else { return }
        filterType = option.value
        rebuildMenus()
        if hasSearched { runSearch(reset: true) }
      }
    })
    var sortConfig = sortButton.configuration
    sortConfig?.title = sorts.first { $0.value == sortType }?.title ?? "排序"
    sortConfig?.image = UIImage(systemName: "arrow.up.arrow.down")
    sortButton.configuration = sortConfig
    var filterConfig = filterButton.configuration
    filterConfig?.title = filters.first { $0.value == filterType }?.title ?? "筛选"
    // 先取值再写回：同一 Optional 存储的读写重叠会触发独占访问错误（Swift 5/6 都报）。
    let filterTitle = filterConfig?.title
    filterConfig?.image = filterTitle == nil ? nil : UIImage(systemName: "line.3.horizontal.decrease.circle")
    filterButton.configuration = filterConfig
  }

  // MARK: - 历史

  private func refreshHistory() {
    history = TiebaSearchHistory.load(forumId: forumId, limit: Self.maxHistory)
    historyView.configure(
      suggestions: [],
      history: history,
      expanded: historyExpanded
    )
  }

  private func confirmDeleteHistory(_ text: String) {
    let alert = UIAlertController(
      title: "删除搜索历史",
      message: "确定删除“\(text)”？",
      preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(title: "取消", style: .cancel))
    alert.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
      guard let self else { return }
      history = TiebaSearchHistory.remove(keyword: text, forumId: forumId, limit: Self.maxHistory)
      refreshHistory()
    })
    present(alert, animated: true)
  }

  private func clearHistory() {
    TiebaSceneHaptics.fire("press")
    TiebaSearchHistory.clear(forumId: forumId)
    refreshHistory()
  }

  // MARK: - 搜索

  private func commit(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    searchBar.text = trimmed
    searchBar.resignFirstResponder()
    keyword = trimmed
    hasSearched = true
    historyView.isHidden = true
    list.isHidden = true
    stateView.isHidden = true
    (parent as? TiebaRouteHostViewController)?.syncNativeScreenChrome()
    runSearch(reset: true)
    // 历史写盘（3 条写 + 重读）不在主线程同步跑；回来后只更内存副本。
    Task { @MainActor in
      history = await TiebaSearchHistory.append(keyword: trimmed, forumId: forumId, limit: Self.maxHistory)
    }
  }

  private func showState(_ state: TiebaState) {
    stateView.state = state
    stateView.isHidden = false
    list.isHidden = true
  }

  private func showList() {
    stateView.isHidden = true
    list.isHidden = false
  }

  private func runSearch(reset: Bool) {
    guard !keyword.isEmpty, !forumName.isEmpty else { return }
    // 下一页页码只在成功后提交：失败不回退就会跳过一页（page 保持原值可重试）。
    let requestPage = reset ? 1 : page + 1
    if reset { page = 1 }
    requestSeq += 1
    let seq = requestSeq
    isLoading = true
    if reset {
      hits = []
      driver.publish(fresh: true, makeRows: makeRows)
      showState(.loading)
    }
    Task { @MainActor in
      defer {
        if seq == requestSeq {
          isLoading = false
          list.endRefreshing()
          isUserRefresh = false
        }
      }
      do {
        let result = try await TiebaSearchAPI.posts(
          keyword: keyword,
          forumName: forumName,
          page: requestPage,
          sortType: sortType,
          filterType: filterType
        )
        guard seq == requestSeq else { return }
        if reset {
          hits = result.hits
        } else {
          hits.append(contentsOf: result.hits)
        }
        page = requestPage
        hasMore = result.hasMore
        driver.publish(fresh: true, makeRows: makeRows)
        if hits.isEmpty {
          showState(.empty(
            image: "doc.text.magnifyingglass",
            text: "未找到相关内容",
            secondary: "换个关键词试试吧"
          ))
        } else {
          list.footerState = hasMore ? .more : .none
          showList()
          if isUserRefresh { TiebaSceneHaptics.fire("toggle") }
        }
      } catch {
        guard seq == requestSeq else { return }
        if hits.isEmpty {
          showState(.error(message: error.localizedDescription))
        } else {
          pill.showResult(success: false, text: "加载失败")
        }
      }
    }
  }

  private func loadMore() {
    guard hasMore, !isLoading else { return }
    list.footerState = .loading
    runSearch(reset: false)
  }

  // MARK: - 发布行

  private func makeRows() -> [[String: Any]] {
    // 通用行的主题色在发布时注入（深色/自定义主题下卡片底与描边才正确）。
    let colors = TiebaRowTheme.colors()
    return hits.map { hit in
      var row = hit.row
      row["colors"] = colors
      return row
    }
  }

  // MARK: - 事件

  private func handleEvent(_ name: String, _ payload: [String: Any]) {
    switch name {
    case "rowTap":
      guard let index = payload["index"] as? Int, hits.indices.contains(index) else { return }
      openPost(hits[index])
    case "reachEnd", "footerTap":
      loadMore()
    case "refreshRequested":
      isUserRefresh = true
      runSearch(reset: true)
    default:
      break
    }
  }

  /// 带 pid 的结果直达楼中楼；无 pid 退化进主帖。
  /// 「上一级回复」卡由楼中楼自身的 floorPost 提供（服务端随响应下发），
  /// 不再需要旧 JS 的 parentPostCache 快照。
  private func openPost(_ hit: TiebaSearchAPI.PostHit) {
    guard !hit.threadId.isEmpty else { return }
    TiebaSceneHaptics.fire("press")
    if hit.postId.isEmpty {
      TiebaNavigator.shared.navigate(path: "/thread/\(hit.threadId)", params: [:], mode: "push")
      return
    }
    TiebaNavigator.shared.navigate(
      path: "/thread/\(hit.threadId)/subposts",
      params: [
        "id": hit.threadId,
        "postId": hit.postId,
        "threadId": hit.threadId,
        "floor": hit.floor > 0 ? String(hit.floor) : "",
        "forumId": forumId,
        "forumName": forumName,
      ],
      mode: "push"
    )
  }
}

// MARK: - UISearchBarDelegate

extension TiebaForumSearchViewController: UISearchBarDelegate {
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
  }
}
