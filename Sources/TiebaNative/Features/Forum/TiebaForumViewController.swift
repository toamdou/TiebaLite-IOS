// 吧页（原 src/app/forum/[name].tsx）：数据 TiebaForumFeedAPI（frsPage proto +
// 关注/签到表单通道），列表 = TiebaKindListContentView 的 feed 行（与信息流卡片
// 同一份 TiebaRowMetrics/TiebaFeedRowView），吧名片/分段/排序/分类行做进滚动头
// （TiebaForumHeaderView），FAB、分类 sheet、顶栏更多菜单全在原生。
//
// 分页器仍按用户 2026-09-11 的决定去掉：只有当前分段，无横滑（单列表换数据）。
import UIKit

final class TiebaForumViewController: UIViewController, TiebaNativeScreen {
  var screenTitle: String? { "\(forumName)吧" }
  var screenRightBarItems: [UIBarButtonItem]? { barItems() }

  private let forumName: String
  private let routeForumId: String

  private let list = TiebaKindListContentView()
  private let stateView = TiebaStateContentView()
  private let pill = TiebaPhotoBrowserPillView()
  private let stateHeaderHost = UIView()
  private var stateHeader: TiebaForumHeaderView?
  private var stateHeaderHeight: NSLayoutConstraint?
  /// 空态页头宽 = 内容列宽（与列表页头同列同宽，量多少画多少）。
  private var stateHeaderWidth: NSLayoutConstraint?

  // FAB（原 GlassView + HdrPressable 的等价：iOS 26 起原生液态玻璃圆钮）
  private let fab = UIButton(type: .system)

  // ── 数据（原 forumStore 的分桶，按 tab 各一份）──
  private var card: TiebaForumCard?
  private var buckets: [[[String: Any]]] = [[], [], []]
  private var pages = [1, 1, 1]
  private var hasMores = [true, true, true]
  private var currentTab = 0
  private var sortType = 0
  private var classifyId: String?
  private var classifies: [TiebaForumClassify] = []
  private var expandedIds: Set<String> = []
  private var likeMirror: [String: Bool] = [:]
  /// 吧默认排序只播种一次（进新吧会话）。
  private var didSeedSort = false
  private var isLoading = false
  private var isLoadingMore = false
  /// 在途（tab, page）集合：同一份请求不重复发（见 load 的开头守卫）。
  private struct LoadKey: Hashable {
    let tab: Int
    let page: Int
  }
  private var inFlightLoads: Set<LoadKey> = []
  private var isUserRefresh = false
  private var loadSeq = 0
  /// 行页发布（页键守卫 + 整页后台测量都收敛在 driver）。
  private lazy var driver = TiebaRowPageDriver(list: list, keyPrefix: "forum-\(forumName)")
  private var recordedVisit = false
  private var lastScrollY: CGFloat = 0
  private var fabHidden = false
  private var fabFunction = "refresh"

  private var isLoggedIn: Bool { !TiebaBackgroundSnapshot.shared.bduss.isEmpty }

  init(name: String, forumId: String) {
    self.forumName = name
    self.routeForumId = forumId
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  // MARK: - 生命周期

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = TiebaNavigator.shared.chromeTheme.background
    applyPalette()
    fabFunction = TiebaPreferenceSnapshot.string("forumFabFunction") ?? "refresh"
    list.isHidden = true
    list.onListEvent = { [weak self] event in self?.handleListEvent(event) }
    list.onScroll = { [weak self] scrollView in self?.handleScroll(scrollView) }
    list.onPageApplied = { [weak self] in self?.flushPendingReveal() }
    stateView.isHidden = true
    stateView.isDark = TiebaNavigator.shared.chromeTheme.dark
    // 吧页骨架：thread 卡片（原 forum/[name].tsx SkeletonList count={6} variant="thread"）
    stateView.skeletonVariant = .thread
    stateView.skeletonCount = 6
    stateView.onButtonPress = { [weak self] _ in self?.load(tab: self?.currentTab ?? 0, page: 1) }
    stateHeaderHost.isHidden = true
    fab.tintColor = TiebaSimpleRowPalette.default.base.text
    for subview in [list, stateHeaderHost, stateView, fab, pill] as [UIView] {
      subview.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(subview)
    }
    let headerHeight = stateHeaderHost.heightAnchor.constraint(equalToConstant: 0)
    stateHeaderHeight = headerHeight
    // 空态页头与列表里的页头同列：宿主居中且等于内容列宽（宽随布局趟改写）。
    let headerWidth = stateHeaderHost.widthAnchor.constraint(equalToConstant: 0)
    stateHeaderWidth = headerWidth
    NSLayoutConstraint.activate([
      list.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      list.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      list.topAnchor.constraint(equalTo: view.topAnchor),
      list.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      stateHeaderHost.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      stateHeaderHost.topAnchor.constraint(equalTo: view.topAnchor),
      headerWidth,
      headerHeight,
      stateView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      stateView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      stateView.topAnchor.constraint(equalTo: stateHeaderHost.bottomAnchor),
      stateView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      fab.widthAnchor.constraint(equalToConstant: 52),
      fab.heightAnchor.constraint(equalToConstant: 52),
      fab.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
      fab.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
      pill.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      pill.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
      pill.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.82),
      pill.widthAnchor.constraint(lessThanOrEqualToConstant: TiebaLayout.floatingMaxWidth),
    ])
    setupFab()
    applyPreferences()
    showState(.loading)
    load(tab: 0, page: 1)
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    // 偏好可能在本屏离开期间被改（设置页）：每次出现现读。
    applyPreferences()
    applyInsets()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    (parent as? TiebaRouteHostViewController)?.syncNativeScreenChrome()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    applyInsets()
    // 行宽契约 = 列表宽 − 2×horizontalInset（内缩含内容列居中留白）。
    let columnWidth = list.bounds.width - list.horizontalInset * 2
    driver.updateWidth(columnWidth)
    if let stateHeader, columnWidth > 0 {
      if let stateHeaderWidth, abs(stateHeaderWidth.constant - columnWidth) > 0.5 {
        stateHeaderWidth.constant = columnWidth
      }
      let height = stateHeader.headerHeight(forWidth: columnWidth)
      if let stateHeaderHeight, abs(stateHeaderHeight.constant - height) > 0.5 {
        stateHeaderHeight.constant = height
        view.layoutIfNeeded()
      }
    }
  }

  override func viewSafeAreaInsetsDidChange() {
    super.viewSafeAreaInsetsDidChange()
    applyInsets()
  }

  private func applyInsets() {
    list.contentInsetTop = view.safeAreaInsets.top
    list.contentInsetBottom = view.safeAreaInsets.bottom + 20
  }

  /// 主色跟导航壳的主题（自定义主题的强调色与底栏一致；其余为默认语义色）。
  /// 主题变化（含跟随系统时的实时切换）→ 重取主题重刷自绘色（页面底色/列表色板/页头）。
  func screenThemeDidChange() {
    applyPalette()
  }

  private func applyPalette() {
    list.palette = TiebaChromePalette.listPalette()
  }

  /// 页面级偏好（原生只读，见 docs/native-migration-plan.md「过渡期共享偏好」）。
  private func applyPreferences() {
    fabFunction = TiebaPreferenceSnapshot.string("forumFabFunction") ?? "refresh"
    let hidesFab = fabFunction == "hide"
    fab.isHidden = hidesFab
    list.entranceAnimationEnabled = TiebaPreferenceSnapshot.bool("entranceAnimation", default: true)
  }

  // MARK: - 顶栏

  /// 栏按钮建一次：数据落地只换更多菜单内容（重建 UIBarButtonItem 会把展开中的
  /// 菜单顶掉；见 updateHeader）。
  private lazy var searchItem: UIBarButtonItem = {
    let item = UIBarButtonItem(
      image: UIImage(systemName: "magnifyingglass"),
      style: .plain,
      target: nil,
      action: nil
    )
    item.accessibilityLabel = "吧内搜索"
    item.primaryAction = UIAction { [weak self] _ in self?.openSearch() }
    return item
  }()

  private lazy var moreItem: UIBarButtonItem = {
    let item = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: moreMenu())
    item.accessibilityLabel = "更多"
    return item
  }()

  private func barItems() -> [UIBarButtonItem]? {
    // UIKit 语义：下标 0 在最右——视觉从左到右是 [搜索][更多]（与旧页一致）。
    [moreItem, searchItem]
  }

  private func refreshMoreMenu() {
    moreItem.menu = moreMenu()
  }

  private func moreMenu() -> UIMenu {
    var actions: [UIAction] = [
      UIAction(title: "分享", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
        self?.shareForum()
      },
      UIAction(title: "复制链接", image: UIImage(systemName: "link")) { [weak self] _ in
        TiebaClipboard.setString(TiebaForumLink.forum(self?.forumName ?? ""))
        TiebaSceneHaptics.fire("action-success")
        self?.pill.showResult(success: true, text: "吧链接已复制到剪贴板")
      },
    ]
    if isLoggedIn, card?.isLike == true {
      actions.append(
        UIAction(
          title: "取消关注",
          image: UIImage(systemName: "heart.slash"),
          attributes: .destructive
        ) { [weak self] _ in self?.handleFollow() }
      )
    }
    return UIMenu(children: actions)
  }

  private func openSearch() {
    guard !forumName.isEmpty else { return }
    TiebaSceneHaptics.fire("press")
    TiebaNavigator.shared.navigate(
      .forumSearch(name: forumName, forumId: card?.forumId ?? routeForumId)
    )
  }

  private func shareForum() {
    let text = "\(forumName)吧\n\(TiebaForumLink.forum(forumName))"
    TiebaShareSheet.present(text: text, from: presenterViewController)
  }

  private var presenterViewController: UIViewController { parent ?? self }

  // MARK: - 数据

  /// tab → (sort_type, isGood, timeType)：热门/精品走吧默认列表 -1，最新用用户排序。
  private func semantics(_ tab: Int) -> (sort: Int, isGood: Bool, timeType: String) {
    let sort = tab == 0 || tab == 2 ? -1 : (sortType == 1 ? 1 : 0)
    let timeType = tab == 0 ? "last" : (sortType == 1 ? "create" : "last")
    return (sort, tab == 2, timeType)
  }

  private func load(tab: Int, page: Int) {
    guard !forumName.isEmpty else {
      showState(.error("缺少吧名"))
      return
    }
    // 同 (tab, page) 已有在途请求就别再发：连点刷新/切分段回来时原来会整串重发，
    // 只有 loadSeq 在事后丢旧响应（网络与解析白做一遍）。旧响应仍由 loadSeq 兜底。
    let loadKey = LoadKey(tab: tab, page: page)
    guard !inFlightLoads.contains(loadKey) else {
      list.endRefreshing()
      return
    }
    inFlightLoads.insert(loadKey)
    loadSeq += 1
    let seq = loadSeq
    let semantics = semantics(tab)
    if page == 1, buckets[tab].isEmpty, tab == currentTab {
      isLoading = true
      showState(.loading)
    }
    Task { @MainActor in
      defer {
        self.inFlightLoads.remove(loadKey)
        if seq == self.loadSeq {
          self.isLoading = false
          self.isUserRefresh = false
          self.list.endRefreshing()
        }
      }
      do {
        let result = try await TiebaForumFeedAPI.page(
          forumName: self.forumName,
          page: page,
          sortType: semantics.sort,
          isGood: semantics.isGood,
          classifyId: tab == 2 ? self.classifyId : nil
        )
        guard seq == self.loadSeq else { return }
        self.apply(result, tab: tab, page: page, timeType: semantics.timeType)
      } catch {
        guard seq == self.loadSeq else { return }
        if page == 1, self.buckets[tab].isEmpty {
          self.recordVisitIfNeeded()
          self.showState(.error(self.message(from: error)))
        } else if page > 1 {
          self.pill.showResult(success: false, text: "加载失败")
        }
      }
    }
  }

  private func apply(_ result: TiebaForumFeedPage, tab: Int, page: Int, timeType: String) {
    if let card = result.card {
      self.card = card
      if !card.tbs.isEmpty { TiebaBackgroundSnapshot.shared.tbs = card.tbs }
      if !result.classifies.isEmpty { classifies = result.classifies }
    }
    if page == 1 {
      buckets[tab] = result.threads
      pages[tab] = 1
    } else {
      // 上限 200 条（原 MAX_THREADS_PER_LIST，长翻页不无限增长）。
      buckets[tab] = Array((buckets[tab] + result.threads).suffix(200))
      pages[tab] = page
    }
    hasMores[tab] = result.hasMore
    // 用户主动刷新（下拉/FAB）成功才有触觉；首次载入/切 tab 静默（原 refreshTab 同）。
    if page == 1, isUserRefresh { TiebaSceneHaptics.fire("toggle") }
    recordVisitIfNeeded()
    // 首屏载入时播种吧默认排序（preferences.defaultSortType，只影响最新 tab）
    if !didSeedSort {
      didSeedSort = true
      if TiebaPreferenceSnapshot.string("defaultSortType") == "1" {
        sortType = 1
      }
    }
    list.headerSpec = headerSpec()
    refreshMoreMenu()
    if makeRows().isEmpty {
      publish(fresh: page == 1)
      showState(.empty)
    } else {
      list.footerState = hasMores[tab] ? .more : .none
      // 分页只看同页键重推（pageSeq 只在刷新/切 tab 的 fresh 发布里动），
      // 否则每次加载更多都换页键整页重测。
      publish(fresh: page == 1)
      showList()
    }
  }

  private func loadMore() {
    guard !isLoading, !isLoadingMore, hasMores[currentTab], !buckets[currentTab].isEmpty else { return }
    isLoadingMore = true
    list.footerState = .loading
    let tab = currentTab
    let next = pages[tab] + 1
    Task { @MainActor in
      defer {
        self.isLoadingMore = false
        // 页脚是所有 tab 共享的：请求期间切了 tab 就别拿旧 tab 的 hasMore 覆写它
        //（会把有更多内容的新 tab 置成"没有更多了"，按钮消失，只剩触底自动加载）。
        if tab == self.currentTab {
          self.list.footerState = self.hasMores[tab] ? .more : .none
        }
      }
      do {
        let semantics = self.semantics(tab)
        let result = try await TiebaForumFeedAPI.page(
          forumName: self.forumName,
          page: next,
          sortType: semantics.sort,
          isGood: semantics.isGood,
          classifyId: tab == 2 ? self.classifyId : nil
        )
        guard tab == self.currentTab else { return }
        self.apply(result, tab: tab, page: next, timeType: semantics.timeType)
      } catch {
        self.pill.showResult(success: false, text: "加载失败")
      }
    }
  }

  // MARK: - 行数据

  /// 置顶帖跨桶按 id 去重（原 topThreads：热门/最新/精品都可能带同一批）。
  private func pinnedThreads() -> [[String: Any]] {
    var seen = Set<String>()
    var result: [[String: Any]] = []
    for bucket in [buckets[1], buckets[0], buckets[2]] {
      for thread in bucket where TiebaSimpleRowParser.bool(thread["isTop"]) == true {
        let id = TiebaSimpleRowParser.string(thread["id"]) ?? ""
        guard !id.isEmpty, seen.insert(id).inserted else { continue }
        result.append(thread)
      }
    }
    return result
  }

  private func makeRows() -> [[String: Any]] {
    let hideMedia = TiebaPreferenceSnapshot.bool("hideMedia", default: false)
    let showIp = TiebaPreferenceSnapshot.bool("showIpLocation", default: true)
    let fontScale = Double(TiebaPreferenceSnapshot.string("fontScale") ?? "") ?? 1
    let blockFilter = TiebaPostBlockFilter.load()
    let timeType = semantics(currentTab).timeType
    var rows: [[String: Any]] = []
    for thread in pinnedThreads() {
      if let row = row(thread, timeType: "last", hideMedia: hideMedia, showIp: showIp,
                       fontScale: fontScale, blockFilter: blockFilter) {
        rows.append(row)
      }
    }
    for thread in buckets[currentTab] {
      guard TiebaSimpleRowParser.bool(thread["isTop"]) != true else { continue }
      if let row = row(thread, timeType: timeType, hideMedia: hideMedia, showIp: showIp,
                       fontScale: fontScale, blockFilter: blockFilter) {
        rows.append(row)
      }
    }
    return rows
  }

  /// 行字典 = 投影字典 + feed 行契约键（屏蔽词/用户命中返回 nil）。
  private func row(
    _ thread: [String: Any],
    timeType: String,
    hideMedia: Bool,
    showIp: Bool,
    fontScale: Double,
    blockFilter: TiebaPostBlockFilter
  ) -> [String: Any]? {
    let text = "\(TiebaSimpleRowParser.string(thread["title"]) ?? "") \(TiebaSimpleRowParser.string(thread["abstract"]) ?? "")"
    if blockFilter.isContentBlocked(text) { return nil }
    if blockFilter.isUserBlocked(
      uid: TiebaSimpleRowParser.string(thread["authorId"]) ?? "",
      name: TiebaSimpleRowParser.string(thread["authorName"]) ?? ""
    ) { return nil }
    var row = thread
    row["kind"] = TiebaKindRowKind.feed.rawValue
    row["timeType"] = timeType
    row["expanded"] = expandedIds.contains(TiebaSimpleRowParser.string(thread["id"]) ?? "")
    row["hideMedia"] = hideMedia
    row["showIpLocation"] = showIp
    row["fontScale"] = fontScale
    // 原 TweetCard 未传 closeMenuOptions → 默认只有「屏蔽作者」；不感兴趣按用户要求
    // 与动态流对齐（同一原因面板 + submitDislike + 折叠退场）。
    row["closeMenuOptions"] = ["dislike", "block"]
    return row
  }

  private func publish(fresh: Bool) {
    driver.publish(fresh: fresh) { [weak self] in
      self?.makeRows() ?? []
    }
  }

  // MARK: - 列表头

  private func headerSpec() -> [String: Any] {
    var spec: [String: Any] = [
      "kind": "forum",
      "forumName": forumName,
      "tab": currentTab,
      "loggedIn": isLoggedIn,
      "sortType": sortType,
      "hasClassifies": !classifies.isEmpty,
    ]
    if let card {
      var cardSpec: [String: Any] = [
        "name": card.name.isEmpty ? forumName : card.name,
        "avatar": card.avatar,
        "memberCount": card.memberCount,
        "threadCount": card.threadCount,
        "isLike": card.isLike,
        "isSignIn": card.isSignIn,
        "contSignNum": card.contSignNum,
        "intro": card.intro,
        "curScore": card.curScore,
        "levelupScore": card.levelupScore,
      ]
      if card.levelId > 0 { cardSpec["levelId"] = card.levelId }
      spec["card"] = cardSpec
    }
    if let label = selectedClassifyLabel { spec["classifyLabel"] = label }
    return spec
  }

  private var selectedClassifyLabel: String? {
    guard let classifyId else { return nil }
    return classifies.first { $0.id == classifyId }?.name
  }

  /// 吧名片状态变化（关注/签到/等级）：只刷页头，不动列表行。
  private func updateHeader() {
    let spec = headerSpec()
    list.headerSpec = spec
    stateHeader?.update(spec: spec)
    // 页头高可能随字段变化（会员数/等级文案），重新量一次。
    view.setNeedsLayout()
    refreshMoreMenu()
  }

  // MARK: - 列表事件

  private func handleListEvent(_ event: TiebaKindListEvent) {
    switch event {
    case .rowTap(let index, let region, let actionIndex):
      handleRowTap(index: index, region: region, actionIndex: actionIndex)
    case .menuAction(let index, let action):
      handleMenuAction(index: index, action: action)
    case .mediaAction(let index, _, let action, let url, let originURL):
      handleMediaAction(index: index, action: action, url: url, originURL: originURL)
    case .headerAction(let action, let payload):
      handleHeaderAction(action, payload)
    case .reachEnd, .footerTap:
      loadMore()
    case .refreshRequested:
      isUserRefresh = true
      load(tab: currentTab, page: 1)
    default:
      break
    }
  }

  /// 页头动作（本页页头 = TiebaForumHeaderAction；payload 只带 avatar 的测量矩形）。
  private func handleHeaderAction(_ action: TiebaKindListHeaderAction, _ payload: [String: Any]) {
    guard case .forum(let headerAction) = action else { return }
    switch headerAction {
    case .avatar:
      openAvatarViewer(payload)
    case .card:
      openForumDetail()
    case .follow:
      handleFollow()
    case .sign:
      handleSign()
    case .segment(let index):
      switchTab(index)
    case .sort(let value):
      guard value != sortType else { return }
      sortType = value
      buckets[1] = []
      pages[1] = 1
      hasMores[1] = true
      list.headerSpec = headerSpec()
      load(tab: 1, page: 1)
    case .clearClassify:
      setClassify(nil)
    case .classifyPicker:
      openClassifyPicker()
    }
  }

  private func switchTab(_ tab: Int) {
    guard tab >= 0, tab <= 2, tab != currentTab else { return }
    currentTab = tab
    list.headerSpec = headerSpec()
    publish(fresh: true)
    list.scrollToTop(animated: false)
    if buckets[tab].isEmpty {
      load(tab: tab, page: 1)
    } else {
      list.footerState = hasMores[tab] ? .more : .none
      showList()
    }
  }

  private func handleRowTap(index: Int, region: String, actionIndex: Int?) {
    let rows = makeRows()
    guard rows.indices.contains(index) else { return }
    let row = rows[index]
    func value(_ key: String) -> String { TiebaSimpleRowParser.string(row[key]) ?? "" }
    switch region {
    case "avatar":
      let uid = value("authorId")
      guard !uid.isEmpty else { return }
      TiebaSceneHaptics.fire("press")
      TiebaNavigator.shared.navigate(.user(uid: uid))
    case "chip":
      let forum = value("forumName")
      guard !forum.isEmpty else { return }
      TiebaSceneHaptics.fire("press")
      TiebaNavigator.shared.navigate(.forum(name: forum))
    case "showMore":
      let id = value("id")
      guard !id.isEmpty, expandedIds.insert(id).inserted else { return }
      TiebaSceneHaptics.fire("toggle")
      publish(fresh: false)
    case "action":
      switch actionIndex {
      case 0: openThread(row)
      case 1: shareThread(row)
      case 2: toggleLike(row)
      default: break
      }
    case "media":
      // 真图点击已由原生查看器直开；到这里的只有视频 poster（进帖）。
      openThread(row)
    default:
      openThread(row)
    }
  }

  private func handleMenuAction(index: Int, action: String) {
    let rows = makeRows()
    guard rows.indices.contains(index) else { return }
    let row = rows[index]
    switch action {
    case "block":
      blockAuthor(row)
    case "dislike":
      presentDislikeSheet(row, index: index)
    case "copy-title":
      let title = TiebaSimpleRowParser.string(row["title"]) ?? ""
      guard !title.isEmpty else { return }
      TiebaClipboard.setString(title)
    default:
      break
    }
  }

  /// 行内图片长按菜单（保存照片 / 分享照片）：url 优先 originURL（空串按缺省，
  /// 与旧 payload 判读同）。
  private func handleMediaAction(index: Int, action: String, url: String?, originURL: String?) {
    let rows = makeRows()
    guard rows.indices.contains(index) else { return }
    let row = rows[index]
    let source = TiebaSimpleRowParser.nonEmpty(originURL)
      ?? TiebaSimpleRowParser.string(url) ?? ""
    guard !source.isEmpty else { return }
    let forum = TiebaSimpleRowParser.string(row["forumName"])
    if action == "save-image" {
      TiebaFeedImageActions.save(url: source, forumName: forum, presenter: presenterViewController)
    } else {
      TiebaFeedImageActions.share(
        url: source,
        forumName: forum,
        presenter: presenterViewController,
        sourceRect: CGRect(x: view.bounds.midX, y: view.bounds.maxY - 40, width: 1, height: 1)
      )
    }
  }

  // MARK: - 行动作

  /// 不感兴趣：原因面板 → 上报 → 折叠退场（与动态流同一面板类/上报接口）。
  private func presentDislikeSheet(_ row: [String: Any], index: Int) {
    TiebaSceneHaptics.fire("sheet-present")
    let sheet = TiebaDislikeSheetViewController { [weak self] ids in
      self?.submitDislike(row, index: index, ids: ids)
    }
    present(sheet, animated: true)
  }

  private func submitDislike(_ row: [String: Any], index: Int, ids: String) {
    let threadId = TiebaSimpleRowParser.string(row["id"]) ?? ""
    guard !threadId.isEmpty else { return }
    Task { @MainActor in
      do {
        try await TiebaFeedAPI.submitDislike(
          threadId: threadId,
          dislikeIds: ids,
          forumId: card?.forumId ?? ""
        )
        TiebaSceneHaptics.fire("action-success")
        // 先折叠再删（原 JS collapsingId + 360ms 兜底）：三个桶一起摘，下面卡片补位。
        list.collapseRowThen(atIndex: index) { [weak self] in
          guard let self else { return }
          for tab in 0..<3 {
            buckets[tab].removeAll { TiebaSimpleRowParser.string($0["id"]) == threadId }
          }
          publish(fresh: true)
          if makeRows().isEmpty { showState(.empty) }
        }
      } catch {
        TiebaSceneHaptics.fire("action-fail")
        pill.showResult(success: false, text: "提交失败，请稍后重试")
      }
    }
  }

  private func openThread(_ row: [String: Any]) {
    let id = TiebaSimpleRowParser.string(row["id"]) ?? ""
    guard !id.isEmpty else { return }
    TiebaSceneHaptics.fire("press")
    TiebaNavigator.shared.navigate(.thread(id: id))
  }

  private func shareThread(_ row: [String: Any]) {
    let id = TiebaSimpleRowParser.string(row["id"]) ?? ""
    guard !id.isEmpty else { return }
    TiebaSceneHaptics.fire("press")
    let url = "https://tieba.baidu.com/p/\(id)"
    let title = TiebaSimpleRowParser.string(row["title"]) ?? ""
    TiebaShareSheet.present(
      text: title.isEmpty ? url : "\(title)\n\(url)",
      from: presenterViewController
    )
  }

  /// 点赞：乐观翻转 + 失败回滚（原 useFeedCardActions 的三桶更新收成本页）。
  private func toggleLike(_ row: [String: Any]) {
    let id = TiebaSimpleRowParser.string(row["id"]) ?? ""
    guard !id.isEmpty else { return }
    guard isLoggedIn else {
      promptLogin("请先登录后再操作")
      return
    }
    let latest = likeMirror[id] ?? (TiebaSimpleRowParser.bool(row["hasAgree"]) ?? false)
    let next = !latest
    likeMirror[id] = next
    TiebaSceneHaptics.fire("like")
    applyLike(id: id, liked: next)
    let threadId = TiebaSimpleRowParser.string(row["threadId"]) ?? ""
    let firstPostId = TiebaSimpleRowParser.string(row["firstPostId"]) ?? ""
    Task { @MainActor in
      do {
        try await TiebaThreadActionAPI.setAgree(
          threadId: threadId.isEmpty ? id : threadId,
          postId: firstPostId.isEmpty ? id : firstPostId,
          agree: next
        )
        TiebaSceneHaptics.fire("action-success")
        self.pill.showResult(success: true, text: next ? "点赞成功" : "已取消点赞")
      } catch {
        // 「已经点过赞了」= 目标态已达成（幂等翻转）：保持乐观态不回滚。
        if let vmError = error as? TiebaViewModelError, vmError.message.contains("点过赞") {
          TiebaSceneHaptics.fire("action-success")
          self.pill.showResult(success: true, text: next ? "点赞成功" : "已取消点赞")
          return
        }
        TiebaSceneHaptics.fire("action-fail")
        self.likeMirror[id] = latest
        self.applyLike(id: id, liked: latest)
        self.pill.showResult(success: false, text: "点赞失败，请稍后重试")
      }
    }
  }

  /// 三桶 + 置顶行统一改（原 updateAllBuckets）。
  private func applyLike(id: String, liked: Bool) {
    for tab in 0..<3 {
      for index in buckets[tab].indices
      where TiebaSimpleRowParser.string(buckets[tab][index]["id"]) == id {
        buckets[tab][index]["hasAgree"] = liked
        let count = TiebaSimpleRowParser.double(buckets[tab][index]["zanNum"]) ?? 0
        buckets[tab][index]["zanNum"] = max(0, count + (liked ? 1 : -1))
      }
    }
    publish(fresh: false)
  }

  /// 屏蔽作者：只写逐 uid 键（不整表重写，避免与 JS 内存副本互相覆盖），并移除其行。
  private func blockAuthor(_ row: [String: Any]) {
    let uid = TiebaSimpleRowParser.string(row["authorId"]) ?? ""
    guard !uid.isEmpty else { return }
    let name = TiebaSimpleRowParser.nonEmpty(row["authorNameShow"])
      ?? TiebaSimpleRowParser.string(row["authorName"]) ?? ""
    do {
      try TiebaBlockStore.add(
        user: TiebaBlockedUser(id: uid, uid: uid, username: name.isEmpty ? nil : name)
      )
    } catch {
      TiebaSceneHaptics.fire("action-fail")
      return
    }
    TiebaSceneHaptics.fire("action-success")
    for tab in 0..<3 {
      buckets[tab].removeAll { TiebaSimpleRowParser.string($0["authorId"]) == uid }
    }
    publish(fresh: true)
    if makeRows().isEmpty { showState(.empty) }
  }

  // MARK: - 关注 / 签到

  private func handleFollow() {
    guard isLoggedIn else {
      promptLogin("请先登录后再操作")
      return
    }
    guard let card else { return }
    TiebaSceneHaptics.fire("favorite")
    Task { @MainActor in
      // 卡片带的 tbs 优先；否则现取（缺失会向 /c/s/login 续期，对齐原 JS requireTbs）
      let tbs = card.tbs.isEmpty ? ((try? await TiebaSession.requireTbs()) ?? "") : card.tbs
      do {
        if card.isLike {
          try await TiebaForumFeedAPI.unlike(forumId: card.forumId, forumName: self.forumName, tbs: tbs)
          self.card?.isLike = false
          self.updateHeader()
          self.pill.showResult(success: true, text: "取消关注成功")
        } else {
          let result = try await TiebaForumFeedAPI.like(
            forumId: card.forumId,
            forumName: self.forumName,
            tbs: tbs
          )
          self.card?.isLike = true
          if let levelId = result.levelId, levelId > 0 { self.card?.levelId = levelId }
          if let levelName = result.levelName, !levelName.isEmpty { self.card?.levelName = levelName }
          if let curScore = result.curScore { self.card?.curScore = curScore }
          if let levelupScore = result.levelupScore { self.card?.levelupScore = levelupScore }
          if let memberSum = result.memberSum, memberSum > 0 { self.card?.memberCount = memberSum }
          self.updateHeader()
          let text = (result.memberSum ?? 0) > 0
            ? "关注成功，本吧会员\(TiebaForumFormat.count(result.memberSum ?? 0))人"
            : "关注成功"
          self.pill.showResult(success: true, text: text)
        }
        (self.parent as? TiebaRouteHostViewController)?.syncNativeScreenChrome()
        self.refreshMoreMenu()
      } catch {
        TiebaSceneHaptics.fire("action-fail")
        let message = (error as? TiebaViewModelError)?.message ?? "网络错误，请稍后重试"
        self.pill.showResult(success: false, text: message)
      }
    }
  }

  private func handleSign() {
    guard isLoggedIn else {
      promptLogin("请先登录")
      return
    }
    guard let card else { return }
    if card.isSignIn {
      pill.showResult(success: true, text: "今天已经签到过了")
      return
    }
    TiebaSceneHaptics.fire("action-success")
    Task { @MainActor in
      // 卡片带的 tbs 优先；否则现取（缺失会向 /c/s/login 续期，对齐原 JS requireTbs）
      let tbs = card.tbs.isEmpty ? ((try? await TiebaSession.requireTbs()) ?? "") : card.tbs
      do {
        let result = try await TiebaForumFeedAPI.sign(
          forumName: self.forumName,
          tbs: tbs,
          forumId: card.forumId
        )
        if result.isSuccess {
          self.markSigned(exp: result.exp)
          self.pill.showResult(
            success: true,
            text: result.exp > 0 ? "签到成功，经验+\(result.exp)" : "签到成功"
          )
        } else if result.errorCode == 1101 {
          self.markSigned(exp: result.exp)
          self.pill.showResult(success: true, text: "今天已经签到过了")
        } else {
          self.pill.showResult(
            success: false,
            text: result.errorMessage.isEmpty ? "签到失败，请稍后重试" : result.errorMessage
          )
        }
      } catch {
        self.pill.showResult(success: false, text: "签到失败，请稍后重试")
      }
    }
  }

  /// 原 markForumSigned：签到态立即上卡，经验直接加进进度（否则要等下次加载）。
  private func markSigned(exp: Int) {
    card?.isSignIn = true
    // 先读后写：`card?.x = (card?.x ?? 0) + n` 的读写重叠会触发独占访问错误。
    let contSign = (card?.contSignNum ?? 0) + 1
    card?.contSignNum = contSign
    if exp > 0 {
      let curScore = (card?.curScore ?? 0) + exp
      card?.curScore = curScore
    }
    updateHeader()
  }

  private func promptLogin(_ message: String) {
    let alert = UIAlertController(title: "提示", message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "取消", style: .cancel))
    alert.addAction(UIAlertAction(title: "去登录", style: .default) { _ in
      TiebaNavigator.shared.navigate(.login)
    })
    presenterViewController.present(alert, animated: true)
  }

  // MARK: - 吧名片动作

  private func openAvatarViewer(_ payload: [String: Any]) {
    guard let card, let url = TiebaSimpleRowParser.avatarURL(card.avatar), !card.avatar.isEmpty else {
      return
    }
    TiebaSceneHaptics.fire("press")
    // payload 只带页头测量的头像矩形（协议约定的唯一字典通路）→ 转场取测量值。
    TiebaPhotoBrowser.present(
      items: [
        TiebaPhotoItem(
          url: url,
          thumbUrl: url,
          isGif: false,
          isLong: false,
          width: 0,
          height: 0
        )
      ],
      initialIndex: 0,
      transition: TiebaPhotoTransition(
        frame: TiebaPhotoTransition.measuredFrame(in: payload),
        contextTitle: "\(forumName)吧"
      )
    )
  }

  private func openForumDetail() {
    guard !forumName.isEmpty else { return }
    TiebaSceneHaptics.fire("press")
    TiebaNavigator.shared.navigate(
      .forumDetail(name: forumName, forumId: card?.forumId ?? routeForumId)
    )
  }

  private func setClassify(_ id: String?) {
    guard id != classifyId else { return }
    TiebaSceneHaptics.fire("toggle")
    classifyId = id
    buckets[2] = []
    pages[2] = 1
    hasMores[2] = true
    list.headerSpec = headerSpec()
    if currentTab == 2 { load(tab: 2, page: 1) }
  }

  private func openClassifyPicker() {
    let sheet = TiebaForumClassifySheetViewController(classifies: classifies, selectedId: classifyId) {
      [weak self] id in
      self?.setClassify(id)
    }
    presenterViewController.present(sheet, animated: true)
  }

  // MARK: - 状态

  private enum State {
    case loading
    case empty
    case error(String)
  }

  private func showState(_ state: State) {
    switch state {
    case .loading:
      stateView.applyListState(.loading)
    case .empty:
      stateView.applyListState(
        .empty(image: "tray", title: "暂无帖子", subtitle: "这个吧还没有帖子", refresh: false)
      )
    case .error(let message):
      stateView.applyListState(.error(message))
    }
    stateView.isHidden = false
    list.isHidden = true
    // 空态仍要看到吧名片/分段（旧页 ListHeaderComponent + EmptyState 同形）。
    if case .empty = state {
      installStateHeader()
    } else {
      removeStateHeader()
    }
  }

  private func showList() {
    // 行还没测量落地时不让位：整页测量在后台跑，数据到手 ≠ 行能画；提前让位就是
    // 吧名片（列表头）先画出来、下面正文一片空白（用户报的现象）。等 setPage
    // 落地再显（回调见 viewDidLoad 的 onPageApplied）。
    guard list.hasRows else {
      awaitingReveal = true
      return
    }
    awaitingReveal = false
    stateView.isHidden = true
    list.isHidden = false
    removeStateHeader()
  }

  /// 页记录落地 → 补上被推迟的让位。
  private func flushPendingReveal() {
    guard awaitingReveal else { return }
    showList()
  }

  private var awaitingReveal = false

  private func installStateHeader() {
    if stateHeader == nil {
      let header = TiebaForumHeaderView(spec: headerSpec())
      header.onAction = { [weak self] action, payload in
        self?.handleHeaderAction(action, payload)
      }
      header.translatesAutoresizingMaskIntoConstraints = false
      stateHeaderHost.addSubview(header)
      NSLayoutConstraint.activate([
        header.leadingAnchor.constraint(equalTo: stateHeaderHost.leadingAnchor),
        header.trailingAnchor.constraint(equalTo: stateHeaderHost.trailingAnchor),
        header.topAnchor.constraint(equalTo: stateHeaderHost.topAnchor),
        header.bottomAnchor.constraint(equalTo: stateHeaderHost.bottomAnchor),
      ])
      stateHeader = header
      view.setNeedsLayout()
    }
    stateHeader?.applyPalette(list.palette)
    stateHeaderHost.isHidden = false
  }

  private func removeStateHeader() {
    stateHeaderHost.isHidden = true
    guard stateHeader != nil else { return }
    stateHeader?.removeFromSuperview()
    stateHeader = nil
    stateHeaderHeight?.constant = 0
  }

  private func message(from error: Error) -> String {
    if let apiError = error as? TiebaForumAPIError, let description = apiError.errorDescription {
      return description
    }
    if let vmError = error as? TiebaViewModelError, !vmError.message.isEmpty {
      return vmError.message
    }
    return error.localizedDescription
  }

  // MARK: - FAB

  private func setupFab() {
    // 原 GlassView（clear 玻璃）的 UIKit 对位：系统液态玻璃圆钮
    // （部署底线 iOS 26，.glass() 恒可用）。
    var config: UIButton.Configuration = .glass()
    config.cornerStyle = .capsule
    config.image = UIImage(
      systemName: fabFunction == "back_to_top" ? "arrow.up" : "arrow.clockwise",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
    )
    config.baseForegroundColor = TiebaSimpleRowPalette.default.base.text
    fab.configuration = config
    fab.accessibilityLabel = fabFunction == "back_to_top" ? "回到顶部" : "刷新"
    fab.addAction(UIAction { [weak self] _ in self?.handleFabPress() }, for: .touchUpInside)
    fab.addTarget(self, action: #selector(fabTouchDown), for: [.touchDown, .touchDragEnter])
    fab.addTarget(
      self,
      action: #selector(fabTouchUp),
      for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit]
    )
  }

  private func handleFabPress() {
    TiebaSceneHaptics.fire("press")
    switch fabFunction {
    case "back_to_top":
      fabHidden = false
      animateFab(translate: 0)
      list.scrollToTop(animated: true)
    default:
      refreshFromFab()
    }
  }

  /// FAB 刷新：回顶 + 重拉当前分段（原实现还伪造 -60 偏移强拉刷新控件，原生不必）。
  private func refreshFromFab() {
    if lastScrollY > 1 { list.scrollToTop(animated: true) }
    fabHidden = false
    animateFab(translate: 0)
    isUserRefresh = true
    load(tab: currentTab, page: 1)
  }

  @objc private func fabTouchDown() {
    UIView.animate(withDuration: 0.12) {
      self.fab.transform = CGAffineTransform(scaleX: 0.85, y: 0.85)
    }
  }

  @objc private func fabTouchUp() {
    UIView.animate(
      withDuration: 0.35,
      delay: 0,
      usingSpringWithDamping: 0.6,
      initialSpringVelocity: 0.4
    ) {
      self.fab.transform = .identity
    }
  }

  /// 位移 + 缩放合并成一次动画（FAB 只在这两处被驱动）。
  private func animateFab(translate: CGFloat, scale: CGFloat = 1) {
    UIView.animate(
      withDuration: 0.35,
      delay: 0,
      usingSpringWithDamping: 0.8,
      initialSpringVelocity: 0.5
    ) {
      self.fab.transform = CGAffineTransform(scaleX: scale, y: scale)
        .translatedBy(x: 0, y: translate)
    }
  }

  private func handleScroll(_ scrollView: UIScrollView) {
    let y = scrollView.contentOffset.y
    let delta = y - lastScrollY
    lastScrollY = y
    if y <= 1, fabHidden {
      fabHidden = false
      animateFab(translate: 0)
    }
    guard abs(delta) > 8, fabFunction != "hide" else { return }
    if delta > 0, !fabHidden {
      fabHidden = true
      animateFab(translate: 120)
    } else if delta < 0, fabHidden {
      fabHidden = false
      animateFab(translate: 0)
    }
  }

  // MARK: - 浏览记录（原 recordForumVisit；incognitoMode 下不记）

  private func recordVisitIfNeeded() {
    guard !recordedVisit, !forumName.isEmpty else { return }
    guard !TiebaPreferenceSnapshot.bool("incognitoMode", default: false) else { return }
    recordedVisit = true
    let forumId = card?.forumId ?? routeForumId
    let avatar = card?.avatar ?? ""
    let name = forumName
    let values: [[String: Any]] = [
      ["v": "forum"], ["v": ""], ["v": forumId], ["v": name],
      ["v": avatar], ["v": "\(name)吧"], ["v": ""], ["v": ""],
      ["v": Int(Date().timeIntervalSince1970 * 1000)],
    ]
    Task.detached(priority: .utility) {
      let database = TiebaSQLite.mainDatabase
      _ = try? TiebaSQLite.shared.run(
        database: database,
        sql: "DELETE FROM visit_history WHERE type = ? AND forum_name = ?",
        params: [["v": "forum"], ["v": name]]
      )
      _ = try? TiebaSQLite.shared.run(
        database: database,
        sql: """
          INSERT INTO visit_history (
            type, thread_id, forum_id, forum_name, avatar, title, author_name, author_portrait, timestamp
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
        params: values
      )
      _ = try? TiebaSQLite.shared.run(
        database: database,
        sql: """
          DELETE FROM visit_history WHERE id NOT IN (
            SELECT id FROM visit_history ORDER BY timestamp DESC, id DESC LIMIT ?
          )
          """,
        params: [["v": 200]]
      )
    }
  }
}

// MARK: - 精品分类选择 sheet（原 ClassifyPickerSheet：系统 insetGrouped 列表 + 勾选）

final class TiebaForumClassifySheetViewController: UIViewController {
  private let classifies: [TiebaForumClassify]
  private let selectedId: String?
  private let onSelect: (String?) -> Void
  private let table = UITableView(frame: .zero, style: .insetGrouped)

  init(classifies: [TiebaForumClassify], selectedId: String?, onSelect: @escaping (String?) -> Void) {
    self.classifies = classifies
    self.selectedId = selectedId
    self.onSelect = onSelect
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .pageSheet
    if let sheet = sheetPresentationController {
      sheet.detents = [.medium()]
      sheet.prefersGrabberVisible = true
      sheet.preferredCornerRadius = 28
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemGroupedBackground
    title = "选择分类"
    table.dataSource = self
    table.delegate = self
    table.backgroundColor = .clear
    table.register(UITableViewCell.self, forCellReuseIdentifier: "classify")
    table.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(table)
    NSLayoutConstraint.activate([
      table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      table.topAnchor.constraint(equalTo: view.topAnchor),
      table.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
  }
}

extension TiebaForumClassifySheetViewController: UITableViewDataSource, UITableViewDelegate {
  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    classifies.count + 1
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "classify", for: indexPath)
    let isAll = indexPath.row == 0
    var content = cell.defaultContentConfiguration()
    content.text = isAll ? "全部" : classifies[indexPath.row - 1].name
    cell.contentConfiguration = content
    let isSelected = isAll ? selectedId == nil : classifies[indexPath.row - 1].id == selectedId
    cell.accessoryType = isSelected ? .checkmark : .none
    cell.tintColor = TiebaNavigator.shared.chromeTheme.tint
    return cell
  }

  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: false)
    TiebaSceneHaptics.fire("toggle")
    onSelect(indexPath.row == 0 ? nil : classifies[indexPath.row - 1].id)
    dismiss(animated: true)
  }
}

// MARK: - 链接

enum TiebaForumLink {
  /// 原 utils/index.ts buildForumUrl。
  static func forum(_ name: String) -> String {
    let allowed = CharacterSet(
      charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()"
    )
    let encoded = name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name
    return "https://tieba.baidu.com/f?kw=\(encoded)"
  }
}
