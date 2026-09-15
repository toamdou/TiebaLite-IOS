// 发现 tab 的「推荐 / 关注」信息流段（原 src/components/explore/FeedContent.tsx）：
// 数据 TiebaFeedAPI（proto），列表 = TiebaKindListContentView 的 feed 行，
// 点赞/分享/屏蔽作者/不感兴趣/长文展开/图片菜单全在原生。
import UIKit

final class TiebaExploreFeedViewController: UIViewController, TiebaTabReselectable {
  /// 快照键用的分段名（String 原始值：键里要拼进 KV）。
  enum Segment: String {
    case personalized
    case concern
  }

  private let segment: Segment
  private let list = TiebaKindListContentView()
  /// 整页发布驱动（页键 = explore-<rec|concern>-<seq>）：测量在后台，旧页后到
  /// 不覆盖新页。
  private lazy var driver = TiebaRowPageDriver(
    list: list,
    keyPrefix: "explore-\(segment == .personalized ? "rec" : "concern")"
  )
  private let stateView = TiebaStateContentView()
  private let pill = TiebaPhotoBrowserPillView()

  /// FeedItem 形状（{type, threadInfo}），index 与列表行一一对应。
  private var items: [[String: Any]] = []
  private var expandedIds: Set<String> = []
  private var likeMirror: [String: Bool] = [:]
  private var pageTag = ""
  private var page = 1
  private var hasMore = false
  private var isLoading = false
  private var isLoadingMore = false
  private var isUserRefresh = false
  private var lastLoadedAt = Date.distantPast
  private var lastRowSignature = ""
  /// 回顶刷新在途（回顶动画结束才消费，避免无回顶的程序化滚动触发刷新）。
  private var pendingTopRefresh = false
  private nonisolated(unsafe) var prefToken: NSObjectProtocol?

  deinit {
    if let prefToken { NotificationCenter.default.removeObserver(prefToken) }
  }

  private var isLoggedIn: Bool { !TiebaBackgroundSnapshot.shared.bduss.isEmpty }

  init(segment: Segment) {
    self.segment = segment
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  // MARK: - 生命周期

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear
    applyPalette()
    list.isHidden = true
    applyEntrancePreference()
    // 本页实例常驻（explore 三个子页）：设置页改了值不会重走 viewDidLoad，
    // 订阅偏好广播即时生效（token 随 deinit 释放）。
    prefToken = TiebaPreferenceChange.observe(key: "entranceAnimation") { [weak self] in
      MainActor.assumeIsolated { self?.applyEntrancePreference() }
    }
    list.onScrollAnimationEnd = { [weak self] in
      guard let self, self.pendingTopRefresh else { return }
      self.pendingTopRefresh = false
      self.isUserRefresh = true
      self.reload()
    }
    stateView.isHidden = true
    stateView.isDark = TiebaNavigator.shared.chromeTheme.dark
    // 信息流骨架：thread 卡片、半数带图（原 FeedContent.tsx variant="thread" count={8}）
    stateView.skeletonVariant = .thread
    stateView.skeletonInsets = UIEdgeInsets(top: 8, left: 0, bottom: 24, right: 0)
    stateView.onButtonPress = { [weak self] id in self?.handleStateButton(id) }
    list.onListEvent = { [weak self] event in self?.handleEvent(event) }
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
    if let seed = seedItems() {
      items = seed
      publishFresh()
      showList()
    } else {
      showState(.loading)
    }
    reload()
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
    list.contentInsetTop = 0
    list.contentInsetBottom = view.safeAreaInsets.bottom + 16
  }

  private func applyPalette() {
    var palette = TiebaSimpleRowPalette.default
    let tint = TiebaNavigator.shared.chromeTheme.tint
    palette.base.primary = tint
    list.palette = palette
  }

  /// 入场动画开关（现读偏好；批次判定在列表内，见 endEntranceBatch）。
  private func applyEntrancePreference() {
    list.entranceAnimationEnabled = TiebaPreferenceSnapshot.bool("entranceAnimation", default: true)
  }

  // MARK: - 外部驱动（tab 根屏）

  /// 聚焦（tab 选中）：stale-while-revalidate，遵循 exploreAutoRefresh 偏好。
  func handleFocus() {
    guard segment != .concern || isLoggedIn else { return }
    let stale = Date().timeIntervalSince(lastLoadedAt) > 300
    if stale, TiebaPreferenceSnapshot.bool("exploreAutoRefresh", default: true) || items.isEmpty {
      reload()
    } else {
      // 偏好（字号/隐藏媒体/时间格式）可能已变：行指纹变了才整页重测。
      republishIfPreferencesChanged()
    }
    if list.isHidden, !items.isEmpty { showList() }
  }

  /// 段被切到前台：页数据可能已被其它列表整页挤出度量缓存，按行数复查。
  func handleBecameVisible() {
    guard !items.isEmpty else { return }
    if TiebaKindRowPages.shared.rowCount(pageKey: driver.pageKey) != items.count {
      publishFresh()
    }
  }

  /// 底栏重复点击：先回顶，回顶动画结束（scrollViewDidEndScrollingAnimation）再
  /// 刷新——不再用 260ms 定时器近似；已在顶部则没有滚动动画可等，直接刷新。
  func tabReselected() {
    guard !list.isAtTop else {
      isUserRefresh = true
      reload()
      return
    }
    pendingTopRefresh = true
    list.scrollToTop(animated: true)
  }

  // MARK: - 状态

  private var emptyState: TiebaState {
    .empty(
      image: "tray",
      text: "暂无内容",
      secondary: segment == .personalized ? "去关注一些贴吧获取推荐" : "暂无关注动态",
      retryTitle: "刷新"
    )
  }

  private func showState(_ state: TiebaState) {
    stateView.state = state
    stateView.isHidden = false
    list.isHidden = true
  }

  private func handleStateButton(_ id: String) {
    if id == "login" {
      TiebaNavigator.shared.navigate(.login)
      return
    }
    reload()
  }

  private func showList() {
    stateView.isHidden = true
    list.isHidden = false
  }

  // MARK: - 数据

  private func reload() {
    guard !isLoading else {
      list.endRefreshing()
      return
    }
    if segment == .concern, !isLoggedIn {
      list.endRefreshing()
      showState(.login(text: "请先登录", secondary: "登录后查看关注动态"))
      return
    }
    isLoading = true
    if items.isEmpty { showState(.loading) }
    Task { @MainActor in
      defer {
        isLoading = false
        isUserRefresh = false
        list.endRefreshing()
      }
      do {
        let result = try await fetch(page: 1)
        pageTag = result.pageTag
        items = result.items
        hasMore = result.hasMore
        page = 2
        lastLoadedAt = Date()
        isLoadingMore = false
        // 首屏成功即写 SWR 快照（下次冷启动首帧就有内容，且是新鲜的——旧实现
        // 只读不写，读到的是几个月前的死数据）。
        TiebaFeedAPI.saveSnapshot(items, segment: segment.rawValue)
        publishFresh()
        if items.isEmpty {
          showState(emptyState)
        } else {
          list.footerState = hasMore ? .more : .none
          showList()
        }
        if isUserRefresh { TiebaSceneHaptics.fire("toggle") }
      } catch {
        if items.isEmpty {
          showState(.error(message: error.localizedDescription))
        } else {
          pill.showResult(success: false, text: "加载失败")
        }
      }
    }
  }

  private func loadMore() {
    guard hasMore, !isLoading, !isLoadingMore, page > 1 else { return }
    isLoadingMore = true
    list.footerState = .loading
    Task { @MainActor in
      defer {
        isLoadingMore = false
        list.footerState = hasMore ? .more : .none
      }
      do {
        let result = try await fetch(page: page)
        page += 1
        hasMore = result.hasMore
        items.append(contentsOf: result.items)
        publishFresh()
      } catch {
        pill.showResult(success: false, text: "加载失败")
      }
    }
  }

  private struct FetchResult {
    var items: [[String: Any]] = []
    var hasMore = false
    var pageTag = ""
  }

  private func fetch(page: Int) async throws -> FetchResult {
    let filterAds = TiebaPreferenceSnapshot.bool("filterAdThreads", default: true)
    let loadType = page == 1 ? 1 : 2
    var result = FetchResult()
    switch segment {
    case .personalized:
      let page1 = try await TiebaFeedAPI.personalized(loadType: loadType, page: page)
      result.items = TiebaFeedFilter.visible(page1.items, filterAds: filterAds)
      result.hasMore = page1.hasMore
    case .concern:
      guard isLoggedIn else { return result }
      let page1 = try await TiebaFeedAPI.userLike(
        pageTag: page == 1 ? "" : pageTag,
        loadType: loadType
      )
      result.items = TiebaFeedFilter.visible(page1.items, filterAds: filterAds)
      result.hasMore = page1.hasMore
      result.pageTag = page1.pageTag
    }
    // 行下标必须与 items 一一对应：丢掉没有 threadInfo 的项。
    result.items = result.items.filter { $0["threadInfo"] is [String: Any] }
    return result
  }

  /// 首屏 seed：分段自己的 SWR 快照（推荐/关注各一份、按账号键控；写入侧见
  /// reload 的 page=1 成功分支）。空/过期/解析失败即无 seed。
  private func seedItems() -> [[String: Any]]? {
    let snapshot = TiebaFeedAPI.cachedSnapshot(segment: segment.rawValue)
    guard !snapshot.isEmpty else { return nil }
    let filtered = TiebaFeedFilter.visible(
      snapshot,
      filterAds: TiebaPreferenceSnapshot.bool("filterAdThreads", default: true)
    ).filter { $0["threadInfo"] is [String: Any] }
    return filtered.isEmpty ? nil : filtered
  }

  // MARK: - 发布

  /// 行指纹只含影响测量的偏好（宽度由 driver 自己看守，不再入指纹）。
  private func rowSignature() -> String {
    let options = TiebaFeedRowBuilder.Options.current()
    return "\(options.fontScale)#\(options.hideMedia)#\(options.showIpLocation)"
      + "#\(options.showBothUsername)#\(options.timestampStyle)#\(expandedIds.count)"
  }

  private func republishIfPreferencesChanged() {
    guard !items.isEmpty, rowSignature() != lastRowSignature else { return }
    publishFresh()
  }

  /// 换新页键（数据/展开态变了，整页重测），并记下当时的行指纹。
  private func publishFresh() {
    lastRowSignature = rowSignature()
    driver.publish(fresh: true, makeRows: makeRows)
  }

  /// 同页原地重测（点赞态，不跳滚动位置）。
  private func publishInPlace() {
    driver.publish(fresh: false, makeRows: makeRows)
  }

  private func makeRows() -> [[String: Any]] {
    var options = TiebaFeedRowBuilder.Options.current()
    options.closeMenuOptions = ["dislike", "block", "copy-title"]
    options.imageContextMenu = true
    return items.map { item in
      guard let thread = item["threadInfo"] as? [String: Any] else { return [:] }
      let id = TiebaSimpleRowParser.string(thread["id"]) ?? ""
      return TiebaFeedRowBuilder.make(
        thread: thread,
        options: options,
        expanded: expandedIds.contains(id)
      )
    }
  }

  // MARK: - 事件

  private func handleEvent(_ event: TiebaKindListEvent) {
    switch event {
    case .rowTap(let index, let region, let actionIndex):
      handleRowTap(index: index, region: region, actionIndex: actionIndex)
    case .menuAction(let index, let action):
      handleMenuAction(index: index, action: action)
    case .mediaAction(let index, _, let action, let url, let originURL):
      handleMediaAction(index: index, action: action, url: url, originURL: originURL)
    case .reachEnd, .footerTap:
      loadMore()
    case .refreshRequested:
      isUserRefresh = true
      reload()
    default:
      break
    }
  }

  private func thread(at index: Int) -> [String: Any]? {
    guard items.indices.contains(index) else { return nil }
    return items[index]["threadInfo"] as? [String: Any]
  }

  private func value(_ thread: [String: Any], _ key: String) -> String {
    TiebaSimpleRowParser.string(thread[key]) ?? ""
  }

  private func handleRowTap(index: Int, region: String, actionIndex: Int?) {
    guard let thread = thread(at: index) else { return }
    switch region {
    case "avatar":
      let uid = value(thread, "authorId")
      guard !uid.isEmpty else { return }
      TiebaSceneHaptics.fire("press")
      TiebaNavigator.shared.navigate(.user(uid: uid))
    case "chip":
      let forumName = value(thread, "forumName")
      guard !forumName.isEmpty else { return }
      TiebaSceneHaptics.fire("press")
      TiebaNavigator.shared.navigate(.forum(name: forumName))
    case "showMore":
      let id = value(thread, "id")
      guard !id.isEmpty, expandedIds.insert(id).inserted else { return }
      TiebaSceneHaptics.fire("toggle")
      publishFresh()
    case "action":
      switch actionIndex {
      case 0: openThread(thread)
      case 1: shareThread(thread)
      case 2: toggleLike(thread)
      default: break
      }
    case "media":
      // 真图点击已由原生查看器直开；到这里的只有视频 poster（进帖）。
      guard !hasImageMedia(thread) else { return }
      openThread(thread)
    default:
      openThread(thread)
    }
  }

  private func handleMenuAction(index: Int, action: String) {
    guard let thread = thread(at: index) else { return }
    switch action {
    case "dislike":
      presentDislikeSheet(thread)
    case "block":
      blockAuthor(thread)
    case "copy-title":
      let title = value(thread, "title")
      guard !title.isEmpty else { return }
      TiebaClipboard.setString(title)
    default:
      break
    }
  }

  /// 行内图片长按菜单（保存照片 / 分享照片）：url 优先 originURL（空串按缺省，
  /// 与旧 payload 判读同）。
  private func handleMediaAction(index: Int, action: String, url: String?, originURL: String?) {
    guard let thread = thread(at: index) else { return }
    let source = (originURL.flatMap { $0.isEmpty ? nil : $0 }) ?? url ?? ""
    guard !source.isEmpty else { return }
    let forumName = value(thread, "forumName")
    if action == "save-image" {
      TiebaFeedImageActions.save(url: source, forumName: forumName, presenter: self)
    } else {
      TiebaFeedImageActions.share(
        url: source,
        forumName: forumName,
        presenter: self,
        sourceRect: CGRect(x: view.bounds.midX, y: view.bounds.maxY - 40, width: 1, height: 1)
      )
    }
  }

  // MARK: - 动作

  private func openThread(_ thread: [String: Any]) {
    let id = value(thread, "id")
    guard !id.isEmpty else { return }
    TiebaSceneHaptics.fire("press")
    TiebaNavigator.shared.navigate(.thread(id: id))
  }

  private func shareThread(_ thread: [String: Any]) {
    let id = value(thread, "id")
    guard !id.isEmpty else { return }
    TiebaSceneHaptics.fire("press")
    let url = "https://tieba.baidu.com/p/\(id)"
    let title = value(thread, "title")
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

  /// 点赞：乐观翻转 + 失败回滚（与帖子页/话题页同一竞态策略，镜像表防连点）。
  private func toggleLike(_ thread: [String: Any]) {
    let id = value(thread, "id")
    guard !id.isEmpty, let index = items.firstIndex(where: {
      TiebaSimpleRowParser.string(($0["threadInfo"] as? [String: Any])?["id"]) == id
    }) else { return }
    guard isLoggedIn else {
      TiebaNavigator.shared.navigate(.login)
      return
    }
    let latest = likeMirror[id] ?? (TiebaSimpleRowParser.bool(thread["hasAgree"]) ?? false)
    let next = !latest
    likeMirror[id] = next
    TiebaSceneHaptics.fire("like")
    applyLike(index, next)

    let threadId = value(thread, "threadId")
    let firstPostId = value(thread, "firstPostId")
    Task { @MainActor in
      do {
        try await TiebaThreadActionAPI.setAgree(
          threadId: threadId.isEmpty ? id : threadId,
          postId: firstPostId.isEmpty ? id : firstPostId,
          agree: next
        )
        TiebaSceneHaptics.fire("action-success")
        pill.showResult(success: true, text: next ? "点赞成功" : "已取消点赞")
      } catch {
        if let vmError = error as? TiebaViewModelError, vmError.message.contains("点过赞") {
          TiebaSceneHaptics.fire("action-success")
          return
        }
        TiebaSceneHaptics.fire("action-fail")
        likeMirror[id] = latest
        applyLike(index, latest)
        pill.showResult(success: false, text: "点赞失败，请稍后重试")
      }
    }
  }

  private func applyLike(_ index: Int, _ liked: Bool) {
    guard items.indices.contains(index), var info = items[index]["threadInfo"] as? [String: Any] else {
      return
    }
    info["hasAgree"] = liked
    let count = TiebaSimpleRowParser.double(info["zanNum"]) ?? 0
    info["zanNum"] = max(0, count + (liked ? 1 : -1))
    items[index]["threadInfo"] = info
    publishInPlace()
  }

  private func blockAuthor(_ thread: [String: Any]) {
    let uid = value(thread, "authorId")
    guard !uid.isEmpty else { return }
    let name = value(thread, "authorNameShow").isEmpty
      ? value(thread, "authorName")
      : value(thread, "authorNameShow")
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
    items.removeAll { item in
      guard let info = item["threadInfo"] as? [String: Any] else { return false }
      return value(info, "authorId") == uid
    }
    if items.isEmpty {
      showState(emptyState)
    } else {
      publishFresh()
    }
  }

  private func hasImageMedia(_ thread: [String: Any]) -> Bool {
    let media = thread["mediaList"] as? [[String: Any]] ?? []
    return media.contains { ($0["type"] as? String ?? "image") == "image" }
  }

  // MARK: - 不感兴趣

  /// 原因面板（原 BottomSheet）：系统 sheet + 多选列表（可多选，提交逗号串）。
  private func presentDislikeSheet(_ thread: [String: Any]) {
    TiebaSceneHaptics.fire("sheet-present")
    let sheet = TiebaDislikeSheetViewController { [weak self] ids in
      self?.submitDislike(thread, ids: ids)
    }
    present(sheet, animated: true)
  }

  private func submitDislike(_ thread: [String: Any], ids: String) {
    let threadId = value(thread, "id")
    guard !threadId.isEmpty else { return }
    let forumId = value(thread, "forumId")
    Task { @MainActor in
      do {
        try await TiebaFeedAPI.submitDislike(threadId: threadId, dislikeIds: ids, forumId: forumId)
        TiebaSceneHaptics.fire("action-success")
        pill.showResult(success: true, text: "已减少此类内容推荐")
        // 先折叠再删数据（原 JS collapsingId + 360ms 兜底同一时序）：动画期间数据
        // 保持在位，下面卡片等新快照落地才补位。
        let index = items.firstIndex {
          TiebaSimpleRowParser.string(($0["threadInfo"] as? [String: Any])?["id"]) == threadId
        }
        guard let index else { return }
        list.collapseRowThen(atIndex: index) { [weak self] in
          guard let self else { return }
          self.items.removeAll {
            TiebaSimpleRowParser.string(($0["threadInfo"] as? [String: Any])?["id"]) == threadId
          }
          if self.items.isEmpty {
            self.showState(self.emptyState)
          } else {
            self.publishFresh()
          }
        }
      } catch {
        TiebaSceneHaptics.fire("action-fail")
        pill.showResult(success: false, text: "提交失败，请稍后重试")
      }
    }
  }
}

// MARK: - 不感兴趣原因面板

/// 多选原因 sheet（原 FeedContent 的 BottomSheet）：系统 insetGrouped 列表 +
/// checkmark 附件 + 提交按钮，detent = medium。
final class TiebaDislikeSheetViewController: UIViewController {
  private struct Reason {
    let id: String
    let title: String
  }

  /// 对齐 Kotlin DislikeReason；接口未透出 dislikeResource 时的兜底列表。
  private static let reasons: [Reason] = [
    Reason(id: "1", title: "内容质量差"),
    Reason(id: "2", title: "标题党"),
    Reason(id: "3", title: "重复推荐"),
    Reason(id: "4", title: "内容不适"),
    Reason(id: "5", title: "广告太多"),
    Reason(id: "7", title: "不想看这个吧"),
  ]

  private let onSubmit: (String) -> Void
  private let table = UITableView(frame: .zero, style: .insetGrouped)
  private let submitButton = UIButton(type: .system)
  private var selected: Set<String> = []

  init(onSubmit: @escaping (String) -> Void) {
    self.onSubmit = onSubmit
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
    table.dataSource = self
    table.delegate = self
    table.backgroundColor = .clear
    table.register(UITableViewCell.self, forCellReuseIdentifier: "reason")
    var config: UIButton.Configuration = .prominentGlass()
    config.title = "提交"
    config.image = UIImage(systemName: "hand.thumbsdown.fill")
    config.imagePadding = 8
    config.cornerStyle = .capsule
    config.buttonSize = .large
    submitButton.configuration = config
    submitButton.addAction(UIAction { [weak self] _ in
      guard let self else { return }
      TiebaSceneHaptics.fire("action-success")
      onSubmit(selected.isEmpty ? "1" : selected.sorted().joined(separator: ","))
      dismiss(animated: true)
    }, for: .touchUpInside)
    let header = UILabel()
    header.text = "我们会减少这类内容的推荐"
    header.font = .preferredFont(forTextStyle: .footnote)
    header.textColor = .secondaryLabel
    header.textAlignment = .center
    header.frame = CGRect(x: 0, y: 0, width: 0, height: 44)
    table.tableHeaderView = header
    for subview in [table, submitButton] as [UIView] {
      subview.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(subview)
    }
    NSLayoutConstraint.activate([
      table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      table.topAnchor.constraint(equalTo: view.topAnchor),
      table.bottomAnchor.constraint(equalTo: submitButton.topAnchor, constant: -8),
      submitButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
      submitButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
      submitButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
    ])
    title = "不感兴趣"
  }
}

extension TiebaDislikeSheetViewController: UITableViewDataSource, UITableViewDelegate {
  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    Self.reasons.count
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "reason", for: indexPath)
    let reason = Self.reasons[indexPath.row]
    var content = cell.defaultContentConfiguration()
    content.text = reason.title
    cell.contentConfiguration = content
    cell.accessoryType = selected.contains(reason.id) ? .checkmark : .none
    cell.tintColor = TiebaNavigator.shared.chromeTheme.tint
    return cell
  }

  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: false)
    let reason = Self.reasons[indexPath.row]
    if !selected.insert(reason.id).inserted { selected.remove(reason.id) }
    TiebaSceneHaptics.fire("toggle")
    tableView.reloadRows(at: [indexPath], with: .none)
  }
}
