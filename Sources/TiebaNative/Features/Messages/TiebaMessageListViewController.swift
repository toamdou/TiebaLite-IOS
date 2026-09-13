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
    list.onEvent = { [weak self] name, payload in self?.handleEvent(name, payload) }
    stateView.isHidden = true
    stateView.isDark = TiebaNavigator.shared.chromeTheme.dark
    // 首屏骨架：通用列表行（原 MessageTabList.tsx variant="row" count={8}）
    stateView.skeletonVariant = .row
    stateView.skeletonInsets = UIEdgeInsets(top: 8, left: 16, bottom: 24, right: 16)
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
    ])
    load()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    applyInsets()
    driver.updateWidth(list.bounds.width)
  }

  override func viewSafeAreaInsetsDidChange() {
    super.viewSafeAreaInsetsDidChange()
    applyInsets()
  }

  private func applyInsets() {
    list.contentInsetTop = 6
    list.contentInsetBottom = view.safeAreaInsets.bottom + 16
  }

  private func applyPalette() {
    palette = TiebaChromePalette.listPalette()
    list.palette = palette
  }

  // MARK: - 外部驱动

  /// 本页主滚动视图（宿主系统跟踪用：底栏滚动收纳 / 状态栏点按回顶）。
  /// 分页器场景下容器会把主滚动视图关联交还给当前页（见 Notifications）。
  var trackedScrollView: UIScrollView? { list.primaryScrollView() }

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
  private func applyFilter() {
    let words = TiebaBlockStore.words()
    let users = TiebaBlockStore.users()
    if words.isEmpty, users.isEmpty {
      visibleItems = items
      return
    }
    visibleItems = items.filter { item in
      if blockedContent(item.content, words: words) { return false }
      if !item.fromUserId.isEmpty,
        users.contains(where: { $0.uid == item.fromUserId || (!item.fromUserName.isEmpty && $0.username == item.fromUserName) })
      {
        return false
      }
      return true
    }
  }

  private func blockedContent(_ content: String, words: [TiebaBlockedWord]) -> Bool {
    if words.contains(where: { $0.isWhitelist && matches(content, $0) }) { return false }
    return words.contains { !$0.isWhitelist && matches(content, $0) }
  }

  private func matches(_ content: String, _ word: TiebaBlockedWord) -> Bool {
    guard word.isRegex == true else { return content.contains(word.keyword) }
    guard let regex = try? NSRegularExpression(pattern: word.keyword) else { return false }
    return regex.firstMatch(in: content, range: NSRange(content.startIndex..<content.endIndex, in: content)) != nil
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
      containerWidth: TiebaLayout.quantize(list.bounds.width)
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
    stateView.isHidden = true
    list.isHidden = false
  }

  // MARK: - 事件

  private func handleEvent(_ name: String, _ payload: [String: Any]) {
    switch name {
    case "rowTap":
      handleRowTap(payload)
    case "reachEnd", "footerTap":
      loadMore()
    case "refreshRequested":
      isUserRefresh = true
      reload()
    default:
      break
    }
  }

  private func handleRowTap(_ payload: [String: Any]) {
    guard let index = payload["index"] as? Int, visibleItems.indices.contains(index) else { return }
    let item = visibleItems[index]
    if payload["region"] as? String == "avatar" {
      guard !item.fromUserId.isEmpty else { return }
      TiebaSceneHaptics.fire("press")
      TiebaNavigator.shared.navigate(path: "/user/\(item.fromUserId)", params: [:], mode: "push")
      return
    }
    guard !item.threadId.isEmpty else { return }
    TiebaSceneHaptics.fire("press")
    let path = item.postId.isEmpty ? "/thread/\(item.threadId)" : "/thread/\(item.threadId)?postId=\(item.postId)"
    TiebaNavigator.shared.navigate(path: path, params: [:], mode: "push")
  }
}
