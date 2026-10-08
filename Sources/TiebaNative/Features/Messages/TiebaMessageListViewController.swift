// 消息 tab 的单页列表（原 src/components/notifications/MessageTabList.tsx）：
// 数据 TiebaMessageAPI（replyme/atme/agreeme），行 = TiebaSimpleRows 的 message
// 变体（与旧 MessageRow 同字号/色板），列表 = TiebaKindListContentView。
import UIKit

final class TiebaMessageListViewController: UIViewController {
  let category: TiebaMessageTab

  private let list = TiebaKindListContentView()
  private let stateView = TiebaStateContentView()
  private let pill = TiebaPhotoBrowserPillView()

  private var items: [TiebaMessageItem] = []
  private var visibleItems: [TiebaMessageItem] = []
  private var pn = 0
  private var hasMore = true
  private var isLoading = false
  private var isLoadingMore = false
  private var isUserRefresh = false
  private var lastLoadedAt = Date.distantPast
  /// 行页发布（页键守卫 + 整页后台测量都收敛在 driver）。
  private lazy var driver = TiebaRowPageDriver(list: list, keyPrefix: "msg-\(category.rawValue)")

  private var palette: TiebaSimpleRowPalette = .default

  init(category: TiebaMessageTab) {
    self.category = category
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear
    applyPalette()
    list.isHidden = true
    list.onListEvent = { [weak self] event in self?.handleEvent(event) }
    stateView.isHidden = true
    stateView.isDark = TiebaChromeTheme.current.dark
    // 首屏骨架：通用列表行（原 MessageTabList.tsx variant="row" count={8}）
    stateView.skeletonVariant = .row
    stateView.skeletonInsets = UIEdgeInsets(top: 8, left: 16, bottom: 24, right: 16)
    // 评审 H9：消息行是 radius 20 的卡片，必须与同页骨架（上面 left/right 16）及全 App 卡片内缩口径一致。
    // 改前症状：行字典不传 marginH、这里也没设 horizontalInset ⇒ 卡片 x=0、宽=整屏，20pt 圆角被屏幕两缘切成
    // 楔形缺口；加载完成瞬间头像列从 x=16 跳到 12、卡片由内缩变满幅（全 App 唯一满幅贴边的卡列表）。
    // 改后行为：左右各内缩 16，与骨架无缝衔接；行宽契约（updateWidth 里的 −2×horizontalInset）随之生效。
    list.horizontalInset = 16
    stateView.onButtonPress = { [weak self] _ in self?.reload() }
    for subview in [list, stateView, pill] as [UIView] {
      subview.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(subview)
    }
    NSLayoutConstraint.activate([
      list.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      list.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      list.topAnchor.constraint(equalTo: view.topAnchor),
      list.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      stateView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      stateView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      stateView.topAnchor.constraint(equalTo: view.topAnchor),
      stateView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      pill.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      pill.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
      pill.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.82),
      pill.widthAnchor.constraint(lessThanOrEqualToConstant: TiebaLayout.floatingMaxWidth),
    ])
    load()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    applyInsets()
    // 行宽契约 = 列表宽 − 2×horizontalInset（内缩含内容列居中留白）。
    driver.updateWidth(list.bounds.width - list.horizontalInset * 2)
  }

  override func viewSafeAreaInsetsDidChange() {
    super.viewSafeAreaInsetsDidChange()
    applyInsets()
  }

  private func applyInsets() {
    list.contentInsetTop = 6
    list.contentInsetBottom = view.safeAreaInsets.bottom + 16
  }

  /// 主题变化（含跟随系统时的实时切换）→ 重取主题重刷自绘色（页面底色/列表色板/页头）。
  func screenThemeDidChange() {
    applyPalette()
    // 行字典里的颜色（卡片底 / @赞图标等）是发布期按当时档解析成 hex 烘进去的，内容指纹
    // 含这些 hex：只重刷列表色板不重推，行内会停在旧档（白卡贴深色页）。同页键重推一次
    // 即可（fresh: false：指纹变化自动作废旧模型，滚动位置不跳）。
    guard !visibleItems.isEmpty else { return }
    publish(fresh: false)
  }

  private func applyPalette() {
    palette = TiebaChromePalette.listPalette()
    list.palette = palette
  }

  // MARK: - 外部驱动

  /// trackedScrollView 的解析缓存：primaryScrollView 是无早退的全树 DFS，而消息
  /// 根屏每次布局趟都会来问（见 TiebaNotificationsViewController）。列表结构换人
  /// （骨架 → 列表、reload 换容器）时旧实例离开窗口即失效，其余布局趟零遍历。
  private weak var cachedTrackedScrollView: UIScrollView?
  func resolvedTrackedScrollView() -> UIScrollView? {
    if let cached = cachedTrackedScrollView, cached.window != nil { return cached }
    let resolved = list.primaryScrollView()
    cachedTrackedScrollView = resolved
    return resolved
  }

  /// 首次加载 / 段切回前台时补拉。
  func loadIfNeeded() {
    if items.isEmpty, !isLoading { load() }
  }

  /// 底栏重复点击 / tab 重按：回顶并刷新（旧页 refreshSignal 语义）。
  func refreshFromReselect() {
    list.scrollToTop(animated: true)
    isUserRefresh = true
    reload()
  }

  /// 段切到前台：5 分钟陈旧判断 + 页度量被整页 LRU 挤出时重推（原
  /// ensurePageAlive；挤出后不重推会整列表退回兜底行高）。
  func handleBecameVisible() {
    guard !items.isEmpty else { return }
    if Date().timeIntervalSince(lastLoadedAt) > 300 {
      reload()
      return
    }
    republishIfEvicted()
  }

  // MARK: - 数据

  private func load() {
    guard !isLoading else {
      list.endRefreshing()
      return
    }
    // 未登录由容器整屏接管（列表不在层级里），这里只兜底不发请求。
    guard TiebaUserAPI.isLoggedIn else {
      list.endRefreshing()
      return
    }
    isLoading = true
    if items.isEmpty { showState(.loading) }
    let target = pn
    Task { @MainActor in
      defer {
        isLoading = false
        isUserRefresh = false
        list.endRefreshing()
      }
      do {
        let result = try await TiebaMessageAPI.list(tab: category, pn: target)
        items = result.items
        hasMore = result.hasMore
        pn = target + 1
        lastLoadedAt = Date()
        isLoadingMore = false
        applyFilter()
        publish(fresh: true)
        if visibleItems.isEmpty {
          showState(.empty)
        } else {
          list.footerState = hasMore ? .more : .none
          showList()
        }
        if isUserRefresh { TiebaSceneHaptics.fire("toggle") }
      } catch {
        if items.isEmpty {
          showState(.error(error.localizedDescription))
        } else {
          pill.showResult(success: false, text: "加载失败")
        }
      }
    }
  }

  private func reload() {
    pn = 0
    hasMore = true
    load()
  }

  private func loadMore() {
    guard hasMore, !isLoading, !isLoadingMore, pn > 0 else { return }
    isLoadingMore = true
    list.footerState = .loading
    Task { @MainActor in
      defer {
        isLoadingMore = false
        list.footerState = hasMore ? .more : .none
      }
      do {
        let result = try await TiebaMessageAPI.list(tab: category, pn: pn)
        pn += 1
        hasMore = result.hasMore
        items.append(contentsOf: result.items)
        applyFilter()
        // 分页同页键重推：换页键会整页重测（旧行的度量缓存全白做）。
        publish(fresh: false)
      } catch {
        pill.showResult(success: false, text: "加载失败")
      }
    }
  }

  /// 屏蔽词/屏蔽用户过滤（原 useBlockFilter + BlockManager 判据）。
  ///
  /// [算法审查 40 §4.E] 判据收敛：本页原来自己实现了一份「白名单放行 / 黑名单屏蔽 + 屏蔽用户」，
  /// 现在直接用 TiebaPostBlockFilter —— 与帖子行测量（最热路径）、Explore 页同一张表、同一份实现；
  /// 字面量词合成一条交替正则也由它统一负责（[算法审查 40] 的 27.8× 就在那一处）。
  private func applyFilter() {
    let filter = TiebaPostBlockFilter.load()
    if filter.isEmpty, filter.users.isEmpty {
      visibleItems = items
      return
    }
    visibleItems = items.filter { item in
      if filter.isContentBlocked(item.content) { return false }
      if !item.fromUserId.isEmpty,
        filter.isUserBlocked(uid: item.fromUserId, name: item.fromUserName)
      {
        return false
      }
      return true
    }
  }

  // MARK: - 发布

  private func publish(fresh: Bool) {
    driver.publish(fresh: fresh) { [weak self] in
      guard let self else { return [] }
      return visibleItems.map { TiebaMessageAPI.row(for: $0, palette: palette) }
    }
  }

  /// 页度量被 LRU 挤出（liveRowCount 小于行数）时整页重测（同页键，保滚动位）。
  private func republishIfEvicted() {
    guard !driver.pageKey.isEmpty, !visibleItems.isEmpty, list.bounds.width > 0 else { return }
    let live = TiebaKindRowPages.shared.liveRowCount(
      pageKey: driver.pageKey,
      // 宽度口径 = 行宽契约（与 driver 推页同一式；内缩含内容列居中留白）。
      containerWidth: TiebaLayout.quantize(list.bounds.width - list.horizontalInset * 2)
    )
    guard live < visibleItems.count else { return }
    publish(fresh: false)
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
        .empty(
          image: "bell",
          title: category.emptyTitle,
          subtitle: category.emptyDescription,
          refresh: true
        )
      )
    case .error(let message):
      stateView.applyListState(.error(message))
    }
    stateView.isHidden = false
    list.isHidden = true
  }

  private func showList() {
    // 数据到手 ≠ 行能画：整页测量在后台跑，提前让位就是状态视图先消失、正文空白。
    list.revealWhenReady { [weak self] in
      self?.stateView.isHidden = true
      self?.list.isHidden = false
    }
  }

  // MARK: - 事件

  private func handleEvent(_ event: TiebaKindListEvent) {
    switch event {
    case .rowTap(let index, let region, _):
      handleRowTap(index: index, region: region)
    case .reachEnd, .footerTap:
      loadMore()
    case .refreshRequested:
      isUserRefresh = true
      reload()
    default:
      break
    }
  }

  private func handleRowTap(index: Int, region: String) {
    guard visibleItems.indices.contains(index) else { return }
    let item = visibleItems[index]
    if region == "avatar" {
      guard !item.fromUserId.isEmpty else { return }
      TiebaSceneHaptics.fire("press")
      TiebaNavigator.shared.navigate(.user(uid: item.fromUserId))
      return
    }
    guard !item.threadId.isEmpty else { return }
    TiebaSceneHaptics.fire("press")
    // postId 空 = 只进主帖（原 ?postId= 查询串的类型化等价）。
    TiebaNavigator.shared.navigate(
      .thread(id: item.threadId, postId: item.postId.isEmpty ? nil : item.postId)
    )
  }
}
