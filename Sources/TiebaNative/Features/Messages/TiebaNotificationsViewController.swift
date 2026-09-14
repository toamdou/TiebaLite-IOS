// 「消息」tab 根屏（原 src/app/(tabs)/notifications.tsx）：顶部分段（回复/提到/赞）
// + 三页常驻列表（各自保留滚动位置，横滑跟手切换）+ 聚焦刷新未读计数。
// 未登录/鉴权中走状态视图；深链 tiebalite://notifications/N 选段。
import UIKit

final class TiebaNotificationsViewController: UIViewController, TiebaTabReselectable, TiebaTabRouteParamReceiving {
  private let segmented = UISegmentedControl(items: TiebaMessageTab.allCases.map(\.title))
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
    segmented.selectedSegmentIndex = 0
    segmented.addTarget(self, action: #selector(handleSegmentChange), for: .valueChanged)
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
    pager.setViewControllers([lists[0]], direction: .forward, animated: false)
    current = lists[0]
    applyLoginState()
    if let pendingIndex {
      self.pendingIndex = nil
      show(pendingIndex)
    }
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    TiebaUserAPI.refreshLoginSnapshot()
    applyLoginState()
    if TiebaUserAPI.isLoggedIn { show(activeIndex) }
    refreshCounts()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    // UIPageViewController 的内部横向滚动视图与列表同尺寸且是 DFS 先访问者，会
    // 抢走宿主 primaryScrollView 的唯一名额（底栏滚动收纳 / 状态栏点按回顶）。
    // 宿主在其 viewDidLayoutSubviews 里先写一轮，这里异步后写即最终态：把关联与
    // scrollsToTop 名额交还给当前列表。
    guard current?.trackedScrollView != nil else { return }
    DispatchQueue.main.async { [weak self] in
      guard let self, let scroll = self.current?.trackedScrollView else { return }
      self.setContentScrollView(scroll, for: .top)
      self.setContentScrollView(scroll, for: .bottom)
      scroll.scrollsToTop = true
      self.pager.view.primaryScrollView()?.scrollsToTop = false
    }
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
    show(index)
  }

  // MARK: - 段切换

  @objc private func handleSegmentChange() {
    let index = segmented.selectedSegmentIndex
    guard index >= 0, index < lists.count else { return }
    TiebaSceneHaptics.fire("toggle")
    show(index)
  }

  /// 单实例常驻：切换只换视图，子 VC 与其滚动位置/数据都常驻。
  private func show(_ index: Int) {
    guard index >= 0, index < lists.count else { return }
    segmented.selectedSegmentIndex = index
    let previous = activeIndex
    activeIndex = index
    guard TiebaUserAPI.isLoggedIn else { return }
    let next = lists[index]
    if next !== current {
      pager.setViewControllers(
        [next],
        direction: index >= previous ? .forward : .reverse,
        animated: current != nil
      )
      current = next
    }
    next.loadIfNeeded()
    next.handleBecameVisible()
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

  /// 聚焦刷新未读计数（失败不重置基线——原 loadNotificationCounts 语义）。
  private func refreshCounts() {
    guard TiebaUserAPI.isLoggedIn else { return }
    Task { @MainActor in
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
  /// 手势翻页落地：同步分段与当前页（分段拖动由本回调与 show 两条路径统一）。
  func pageViewController(
    _ pageViewController: UIPageViewController,
    didFinishAnimating finished: Bool,
    previousViewControllers: [UIViewController],
    transitionCompleted completed: Bool
  ) {
    guard completed,
      let list = pageViewController.viewControllers?.first as? TiebaMessageListViewController,
      let index = lists.firstIndex(where: { $0 === list })
    else { return }
    activeIndex = index
    segmented.selectedSegmentIndex = index
    current = list
    TiebaSceneHaptics.fire("toggle")
    list.loadIfNeeded()
    list.handleBecameVisible()
  }
}
