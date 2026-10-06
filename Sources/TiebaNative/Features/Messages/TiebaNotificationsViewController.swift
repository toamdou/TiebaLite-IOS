// 「消息」tab 根屏（原 src/app/(tabs)/notifications.tsx）：顶部分段（回复/提到/赞）
// + 三页常驻列表（各自保留滚动位置，横滑跟手切换）+ 聚焦刷新未读计数。
// 未登录/鉴权中走状态视图；深链 tiebalite://notifications/N 选段。
import UIKit

final class TiebaNotificationsViewController: UIViewController, TiebaTabReselectable, TiebaTabRouteParamReceiving {
  /// 分段 = TiebaTabSelector（选中/未选中两份文本交叉淡化 + 指示器跨项 lerp，见 UI/Components）。
  private let segmented = TiebaTabSelector(items: TiebaMessageTab.allCases.map(\.title))
  private let container = UIView()
  private let stateView = TiebaStateContentView()
  /// 三个列表实例常驻（UIPageViewController 装卸的是视图，VC 与滚动位置都在）。
  private lazy var lists: [TiebaMessageListViewController] = TiebaMessageTab.allCases.map {
    TiebaMessageListViewController(category: $0)
  }
  /// 横滑分页器：系统滚动手势跟手（原手写 UISwipeGestureRecognizer 是翻页式）。
  private lazy var pager = UIPageViewController(
    transitionStyle: .scroll,
    navigationOrientation: .horizontal
  )
  private var current: TiebaMessageListViewController?
  private var activeIndex = 0
  /// viewDidLoad 之前到达的深链目标段（宿主先切 tab 再投初始分段）。
  private var pendingIndex: Int?

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = TiebaNavigator.shared.chromeTheme.background
    segmented.select(0, animated: false)
    segmented.onSelect = { [weak self] index in self?.handleSegmentSelect(index) }
    stateView.isDark = TiebaNavigator.shared.chromeTheme.dark
    stateView.isHidden = true
    stateView.onButtonPress = { [weak self] id in
      if id == "login" {
        TiebaNavigator.shared.navigate(.login)
      } else {
        self?.reloadCurrent()
      }
    }
    pager.dataSource = self
    pager.delegate = self
    pager.view.translatesAutoresizingMaskIntoConstraints = false
    addChild(pager)
    container.addSubview(pager.view)
    for subview in [segmented, container, stateView] as [UIView] {
      subview.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(subview)
    }
    NSLayoutConstraint.activate([
      segmented.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
      segmented.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
      segmented.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
      container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      container.topAnchor.constraint(equalTo: segmented.bottomAnchor, constant: 6),
      container.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      pager.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      pager.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      pager.view.topAnchor.constraint(equalTo: container.topAnchor),
      pager.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      stateView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      stateView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      stateView.topAnchor.constraint(equalTo: segmented.bottomAnchor),
      stateView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    pager.didMove(toParent: self)
    // 旁听 pager 的横滑手势（UIPageViewController.gestureRecognizers 是公开 API）：
    // 拖动过程中把连续进度灌回分段，指示器跟手，不再等 didFinishAnimating 才动。
    for gesture in pager.gestureRecognizers {
      (gesture as? UIPanGestureRecognizer)?.addTarget(self, action: #selector(handlePagerPan(_:)))
    }
    pager.setViewControllers([lists[0]], direction: .forward, animated: false)
    current = lists[0]
    applyLoginState()
    if let pendingIndex {
      self.pendingIndex = nil
      requestShow(pendingIndex)
    }
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    TiebaUserAPI.refreshLoginSnapshot()
    applyLoginState()
    if TiebaUserAPI.isLoggedIn { requestShow(activeIndex) }
    refreshCounts()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    // UIPageViewController 的内部横向滚动视图与列表同尺寸且是 DFS 先访问者，会
    // 抢走宿主 primaryScrollView 的唯一名额（底栏滚动收纳 / 状态栏点按回顶）。
    // 宿主在其 viewDidLayoutSubviews 里先写一轮，这里异步后写即最终态：把关联与
    // scrollsToTop 名额交还给当前列表。
    //
    // 主滚动视图解析缓存：trackedScrollView / primaryScrollView 都是无早退的全树
    // DFS，此前每次布局趟最多 3 趟（转场/分段切换期逐帧 = 一次转场约百趟，pager
    // 子树横滑时还覆盖最多三个列表）。缓存放 current 实例上：列表换人（分段切换）
    // 时重解析，其余布局趟零遍历。
    guard let current else { return }
    // 先解析一次把结果缓存到 current 上（下一行的 async 块还要用）；这里只关心"有没有"。
    guard current.resolvedTrackedScrollView() != nil else { return }
    DispatchQueue.main.async { [weak self] in
      guard let self, let scroll = self.current?.resolvedTrackedScrollView() else { return }
      self.setContentScrollView(scroll, for: .top)
      self.setContentScrollView(scroll, for: .bottom)
      scroll.scrollsToTop = true
      // pager 的内部横向滚动视图只在 setViewControllers 换人时变，不逐趟扫。
      if let pagerScroll = self.resolvedPagerScrollView() {
        pagerScroll.scrollsToTop = false
      }
    }
  }

  /// pager 内部横向滚动视图的解析缓存（见 viewDidLayoutSubviews 注释）。
  private weak var cachedPagerScrollView: UIScrollView?
  private func resolvedPagerScrollView() -> UIScrollView? {
    if let cached = cachedPagerScrollView, cached.window != nil { return cached }
    let resolved = pager.view.primaryScrollView()
    cachedPagerScrollView = resolved
    return resolved
  }

  /// 底栏重复点击：当前列表回顶 + 刷新，并刷新未读计数。
  func tabReselected() {
    current?.refreshFromReselect()
    refreshCounts()
  }

  /// 深链 tiebalite://notifications/N —— 选中对应分段（N = 0/1/2）。
  func receiveInitialTab(_ index: Int) {
    guard index >= 0, index < TiebaMessageTab.allCases.count else { return }
    guard isViewLoaded else {
      pendingIndex = index
      return
    }
    requestShow(index)
  }

  // MARK: - 段切换

  /// 结构转场占用位：同时只允许一个「会换页」的转场在跑。
  /// 移植自上游 MinimizedContainer.swift:603-657（canStartMutatingTransition /
  /// requestOrQueueMaximize / drainPendingAction / completeTransition 四处同款）。
  private var structureTransitionInFlight = false
  /// 挂起槽位只有一个：后到的意图覆盖先到的，中间那些就是被丢弃的「陈旧意图」。
  private var pendingShowIndex: Int?

  private func handleSegmentSelect(_ index: Int) {
    guard index >= 0, index < lists.count else { return }
    TiebaSceneHaptics.fire("toggle")
    requestShow(index)
  }

  /// 请求换页：能开就开；开不了只挂起「另一个目标」，正在去同一个目标就直接丢。
  private func requestShow(_ index: Int) {
    guard index >= 0, index < lists.count else { return }
    guard !structureTransitionInFlight else {
      if index != activeIndex { pendingShowIndex = index }
      return
    }
    performShow(index)
  }

  /// 转场落定的**唯一出口**：清占用位 → 排空挂起意图（上游 completeTransition + drain）。
  private func finishStructureTransition() {
    structureTransitionInFlight = false
    guard let pending = pendingShowIndex else { return }
    pendingShowIndex = nil
    requestShow(pending)
  }

  /// 单实例常驻：切换只换视图，子 VC 与其滚动位置/数据都常驻。
  private func performShow(_ index: Int) {
    guard index >= 0, index < lists.count else { return }
    segmented.select(index, animated: true)
    let previous = activeIndex
    activeIndex = index
    guard TiebaUserAPI.isLoggedIn else { return }
    let next = lists[index]
    if next !== current {
      // 手势还在进行中就被换页请求打断：先把系统滚动手势取消掉（上游 :732-735 的三行）。
      TiebaScrollGestureHandoff.cancelInFlightScroll(resolvedPagerScrollView())
      structureTransitionInFlight = true
      pager.setViewControllers(
        [next],
        direction: index >= previous ? .forward : .reverse,
        animated: current != nil
      ) { [weak self] _ in
        self?.finishStructureTransition()
      }
      current = next
    }
    next.loadIfNeeded()
    next.handleBecameVisible()
  }

  /// 手势连续进度 → 指示器（上游 HorizontalTabsComponent.updateTabSwitchFraction，:551-552）：
  /// 手指拖到一半，指示器必须也在半路，而不是松手后才播一段 0.2s。
  @objc private func handlePagerPan(_ gesture: UIPanGestureRecognizer) {
    guard gesture.state == .changed else { return }
    let width = max(view.bounds.width, 1)
    // 手指左移（translation.x < 0）= 去下一页 ⇒ 连续位置 = 当前项 - 位移 / 页宽。
    segmented.setSwitchPosition(
      CGFloat(activeIndex) - gesture.translation(in: view).x / width,
      isDragging: true
    )
  }

  // MARK: - 登录态与计数

  private func applyLoginState() {
    let loggedIn = TiebaUserAPI.isLoggedIn
    stateView.isHidden = loggedIn
    segmented.isHidden = !loggedIn
    container.isHidden = !loggedIn
    guard loggedIn else {
      var buttons: [TiebaStateButton] = []
      stateView.showsSpinner = false
      stateView.imageName = "bell.slash"
      stateView.text = "请先登录"
      stateView.secondaryText = "登录后查看消息通知"
      buttons.append(
        TiebaStateButton(raw: [
          "id": "login",
          "title": "登录百度账号",
          "style": "glassProminent",
          "icon": "person.crop.circle.badge.checkmark",
          "capsule": true,
        ])
      )
      stateView.buttons = buttons
      return
    }
    if current == nil {
      pager.setViewControllers([lists[activeIndex]], direction: .forward, animated: false)
      current = lists[activeIndex]
    }
  }

  private func reloadCurrent() {
    current?.refreshFromReselect()
  }

  /// 在途闸门：viewWillAppear 与 tabReselected 都会触发聚焦刷新，两个 counts() 同时在途时
  /// 先发后到的旧响应会把较新的 markSeen 基线**覆盖回去**（消息 API 自己注释过这个后果），
  /// 表现为已读增量又被提醒一次、角标回跳（R15-3）。
  private var countsInFlight = false

  /// 聚焦刷新未读计数（失败不重置基线——原 loadNotificationCounts 语义）。
  private func refreshCounts() {
    guard TiebaUserAPI.isLoggedIn, !countsInFlight else { return }
    countsInFlight = true
    Task { @MainActor in
      defer { countsInFlight = false }
      guard let counts = try? await TiebaMessageAPI.counts() else { return }
      TiebaMessageAPI.markSeen(counts: counts)
    }
  }
}

// MARK: - 分页器

extension TiebaNotificationsViewController: UIPageViewControllerDataSource {
  func pageViewController(
    _ pageViewController: UIPageViewController,
    viewControllerBefore viewController: UIViewController
  ) -> UIViewController? {
    guard let list = viewController as? TiebaMessageListViewController,
      let index = lists.firstIndex(where: { $0 === list }), index > 0
    else { return nil }
    return lists[index - 1]
  }

  func pageViewController(
    _ pageViewController: UIPageViewController,
    viewControllerAfter viewController: UIViewController
  ) -> UIViewController? {
    guard let list = viewController as? TiebaMessageListViewController,
      let index = lists.firstIndex(where: { $0 === list }), index < lists.count - 1
    else { return nil }
    return lists[index + 1]
  }
}

extension TiebaNotificationsViewController: UIPageViewControllerDelegate {
  /// 手势开始 = 一次结构转场占用（期间的换页请求进挂起槽，不跟手势抢）。
  func pageViewController(
    _ pageViewController: UIPageViewController,
    willTransitionTo pendingViewControllers: [UIViewController]
  ) {
    structureTransitionInFlight = true
  }

  /// 手势翻页落地：同步当前页 → 指示器从「手指拖到的连续位置」滑到最终段 → 排空挂起意图。
  func pageViewController(
    _ pageViewController: UIPageViewController,
    didFinishAnimating finished: Bool,
    previousViewControllers: [UIViewController],
    transitionCompleted completed: Bool
  ) {
    if completed,
      let list = pageViewController.viewControllers?.first as? TiebaMessageListViewController,
      let index = lists.firstIndex(where: { $0 === list }) {
      activeIndex = index
      current = list
      TiebaSceneHaptics.fire("toggle")
      list.loadIfNeeded()
      list.handleBecameVisible()
    }
    // completed = false（没拖过半、松手弹回）时连续位置停在半路，这一句负责滑回原位。
    segmented.select(activeIndex, animated: true)
    finishStructureTransition()
  }
}
