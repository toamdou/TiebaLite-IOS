// 用户主页（原 src/app/user/[uid].tsx）：资料卡 + 分段（贴子/回复/关注的吧）+
// 信息流卡片行 / 吧行；关注、拉黑、UID 复制、主页分享、粉丝关注列表全原生。
//
// 数据 TiebaProfileAPI；行渲染 TiebaKindListContentView（feed 行复用
// TiebaFeedRowView/TiebaRowMetrics，吧行走 TiebaSimpleRows 的 user 变体），
// 资料卡 = TiebaUserProfileHeaderView（滚动头，挂 headerSpec 的 userProfile）。
import UIKit

final class TiebaUserProfileViewController: UIViewController, TiebaNativeScreen {
  var screenTitle: String? { detail?.displayName }
  var screenRightBarItems: [UIBarButtonItem]? { shareBarItem() }

  private let uid: String
  private let list = TiebaKindListContentView()
  private let stateView = UIContentUnavailableView(configuration: .loading())
  /// 首屏资料骨架（原 user/[uid].tsx SkeletonList variant="row" count={8}）
  private let skeletonView = TiebaSkeletonList(variant: .row, count: 8)
  private let pill = TiebaPhotoBrowserPillView()

  private var detail: TiebaProfileDetail?
  private var isFollowing = false
  private var isBlocked = false
  private var isOwn = false
  private var activeTab: String
  private var rows: [[String: Any]] = []
  private var page = 1
  private var hasMore = false
  private var isLoading = false
  private var isLoadingMore = false
  private var isUserRefresh = false
  private var loadSeq = 0
  /// 行页发布（页键守卫 + 整页后台测量都收敛在 driver）。
  private lazy var driver = TiebaRowPageDriver(list: list, keyPrefix: "user-\(uid)")
  private var expandedKeys: Set<String> = []
  private var likeMirror: [String: Bool] = [:]

  private static let tabs: [(label: String, value: String)] = [
    ("贴子", "threads"), ("回复", "replies"), ("关注的吧", "forums"),
  ]

  init(uid: String, tab: String) {
    self.uid = uid
    self.activeTab = ["threads", "replies", "forums"].contains(tab) ? tab : "threads"
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = TiebaNavigator.shared.chromeTheme.background
    applyPalette()
    list.onListEvent = { [weak self] event in self?.handleEvent(event) }
    list.isHidden = true
    stateView.isHidden = true
    skeletonView.isHidden = true
    registerBlockedState()
    for subview in [list, stateView, skeletonView, pill] as [UIView] {
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
      skeletonView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      skeletonView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      skeletonView.topAnchor.constraint(equalTo: view.topAnchor),
      skeletonView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      pill.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      pill.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
    ])
    reload()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    applyInsets()
    // 行宽契约 = 列表宽 − 2×horizontalInset（吧 tab 的 list 有 10pt 内缩）。
    driver.updateWidth(list.bounds.width - list.horizontalInset * 2)
  }

  override func viewSafeAreaInsetsDidChange() {
    super.viewSafeAreaInsetsDidChange()
    applyInsets()
  }

  private func applyInsets() {
    // 顶部让位 = 状态栏 + 导航栏 + 12（资料卡自身留白，与旧页同值）。
    list.contentInsetTop = view.safeAreaInsets.top + 12
    list.contentInsetBottom = view.safeAreaInsets.bottom + 24
    // 骨架同起点；左右 16（原 skeletonWrap paddingHorizontal Spacing.lg）
    skeletonView.contentInsets = UIEdgeInsets(
      top: view.safeAreaInsets.top + 12, left: 16, bottom: 24, right: 16
    )
  }

  // MARK: - 数据

  @objc private func reload() {
    guard !isLoading else {
      list.endRefreshing()
      return
    }
    guard !uid.isEmpty else {
      list.endRefreshing()
      showState(.error("缺少用户 ID"))
      return
    }
    isLoading = true
    if detail == nil { showState(.loading) }
    Task { @MainActor in
      defer {
        isLoading = false
        isUserRefresh = false
        list.endRefreshing()
      }
      do {
        let result = try await TiebaProfileAPI.profile(uid: uid)
        detail = result
        isFollowing = result.isConcerned
        isOwn = result.uid == TiebaBackgroundSnapshot.shared.uid
        // 回复 tab 只在本人主页存在：别人的主页被指到 replies 时回落贴子（旧页同判据）。
        if !isOwn, activeTab == "replies" { activeTab = "threads" }
        stateView.isHidden = true
        skeletonView.isHidden = true
        list.isHidden = false
        syncHeader()
        // 标题来自资料卡（路由表标题为空），到数据后让壳重刷一次。
        (parent as? TiebaRouteHostViewController)?.syncNativeScreenChrome()
        await loadList(reset: true)
        if isUserRefresh { TiebaSceneHaptics.fire("toggle") }
      } catch {
        if detail == nil {
          showState(.error(error.localizedDescription))
        } else {
          pill.showResult(success: false, text: "主页信息刷新失败")
        }
      }
    }
  }

  /// 列表加载（reset = 回第 1 页；否则追加下一页）。
  private func loadList(reset: Bool) async {
    let seq = reset ? (loadSeq + 1) : loadSeq
    if reset { loadSeq += 1 }
    let tab = activeTab
    if reset { page = 1 }
    let targetPage = reset ? 1 : page + 1
    do {
      let result = try await fetch(tab: tab, page: targetPage)
      guard seq == loadSeq, tab == activeTab else { return }
      if reset {
        rows = result.rows
        page = 1
        expandedKeys.removeAll()
      } else {
        rows.append(contentsOf: result.rows)
        page = targetPage
      }
      hasMore = result.hasMore
      rowItems = result.items
      // 分页同页键重推（换页键会整页重测）；刷新/切 tab 才换页键。
      publish(fresh: reset)
    } catch {
      guard seq == loadSeq, tab == activeTab else { return }
      if reset {
        rows = []
        rowItems = []
        hasMore = false
        page = 1
        publish(fresh: true)
        pill.showResult(success: false, text: error.localizedDescription)
      } else {
        pill.showResult(success: false, text: "加载失败")
      }
    }
    list.footerState = hasMore ? .more : .none
  }

  private struct FetchResult {
    var rows: [[String: Any]]
    var items: [Any]
    var hasMore: Bool
  }

  /// 行源数据（与 rows 同序，用于点击定位；吧 tab 为 nil 占位）。
  private var rowItems: [Any] = []

  private func fetch(tab: String, page: Int) async throws -> FetchResult {
    switch tab {
    case "forums":
      let result = try await TiebaProfileAPI.likedForums(uid: uid, page: page)
      return FetchResult(
        rows: result.items.map(forumRow),
        items: result.items,
        hasMore: result.hasMore
      )
    default:
      let result = try await TiebaProfileAPI.posts(
        uid: uid,
        page: page,
        isThread: tab == "threads",
        detail: detail
      )
      let prepared = result.rows.map { row -> [String: Any] in
        var next = row
        next["kind"] = TiebaKindRowKind.feed.rawValue
        next["timeType"] = "create"
        next["showForumPill"] = true
        next["expanded"] = expandedKeys.contains(rowKey(row))
        next["closeMenuOptions"] = ["block", "copy-title"]
        next["imageContextMenu"] = true
        next.merge(TiebaFeedRowPreferences.current()) { _, new in new }
        return next
      }
      return FetchResult(rows: prepared, items: result.rows, hasMore: result.hasMore)
    }
  }

  private func rowKey(_ row: [String: Any]) -> String {
    "\(TiebaSimpleRowParser.string(row["threadId"]) ?? "")-\(TiebaSimpleRowParser.string(row["firstPostId"]) ?? "")"
  }

  private func forumRow(_ forum: TiebaProfileForum) -> [String: Any] {
    var row: [String: Any] = [
      "kind": TiebaKindRowKind.simple.rawValue,
      "variant": "user",
      "a11y": "\(forum.forumName)吧",
      "avatar": forum.avatar,
      "avatarInitial": String(forum.forumName.prefix(2)),
      "avatarSize": 36,
      "title": "\(forum.forumName)吧",
      "titleSize": 14,
      "titleWeight": 600,
      "subtitle": forum.levelName,
      "subtitleSize": 11,
      "subtitleWeight": 400,
      "subtitleMarginTop": 2,
      "chevron": true,
      "marginH": 10,
      "marginV": 4,
      "paddingH": 12,
      "paddingV": 12,
      "gap": 10,
      "radius": 20,
    ]
    row.merge(TiebaRowTheme.colors()) { _, new in new }
    return row
  }

  // MARK: - 发布

  private func publish(fresh: Bool) {
    // 吧 tab 的列表有 10pt 左右内缩：先落内缩再量宽（行宽契约 = 宽 − 2×内缩）。
    list.horizontalInset = activeTab == "forums" ? 10 : 0
    driver.updateWidth(list.bounds.width - list.horizontalInset * 2)
    driver.publish(fresh: fresh) { [weak self] in
      guard let self else { return [] }
      return rows.isEmpty ? emptyRows() : rows
    }
  }

  /// 空 tab 的占位行（列表头仍在，滚动不塌）。
  private func emptyRows() -> [[String: Any]] {
    let description: String
    switch activeTab {
    case "replies": description = "还没有回复"
    case "forums": description = "还没有关注的吧"
    default: description = "还没有发过贴子"
    }
    return [
      TiebaEmptyPlaceholderRow.make(
        a11y: "暂无内容",
        icon: "tray",
        title: "暂无内容",
        subtitle: description
      )
    ]
  }

  /// 滚动头：资料卡 + 分段（数据/关注态/选中段变化时同步）。
  private func syncHeader() {
    guard let detail else {
      list.headerSpec = nil
      return
    }
    var spec: [String: Any] = [
      "kind": "userProfile",
      "name": detail.name,
      "nameShow": detail.nameShow,
      "portrait": detail.portrait,
      "intro": detail.intro,
      "uidText": detail.uidText,
      "sex": detail.sex,
      "ip": detail.ipLocation,
      "tbAge": detail.tbAge,
      "showIp": TiebaPreferenceSnapshot.bool("showIpLocation", default: true),
      "concernNum": detail.concernNum,
      "fansNum": detail.fansNum,
      "agreeNum": detail.totalAgreeNum,
      "following": isFollowing,
      "blocked": isBlocked,
      "own": isOwn,
      "loggedIn": !TiebaBackgroundSnapshot.shared.bduss.isEmpty,
      "tabs": Self.tabs.map(\.label),
      // 传 value 不传下标：页头会把 replies 过滤掉（非本人主页），下标会错位。
      "tabValue": activeTab,
      "colors": TiebaRowTheme.colors(),
    ]
    if !detail.bazhuDesc.isEmpty { spec["bazhuDesc"] = detail.bazhuDesc }
    if detail.godStatus != 0 {
      spec["godField"] = detail.godFieldName.isEmpty ? "大神认证" : detail.godFieldName
    }
    list.headerSpec = spec
  }

  // MARK: - 状态

  private enum State {
    case loading
    case error(String)
  }

  private func showState(_ state: State) {
    switch state {
    case .loading:
      // 首次加载且无资料：骨架（原 loadingProfile && !user 分支）
      stateView.configuration = UIContentUnavailableConfiguration.loading()
      stateView.isHidden = true
      skeletonView.isHidden = false
    case .error(let message):
      stateView.showError(message) { [weak self] in self?.reload() }
      skeletonView.isHidden = true
    }
    list.isHidden = true
  }

  /// 拉黑本页用户后网络层会把作者内容过滤掉：本地屏蔽表里有它即提示（不猜服务端）。
  private func registerBlockedState() {
    isBlocked = TiebaBlockStore.users().contains { $0.uid == uid }
  }

  // MARK: - 顶栏

  private func shareBarItem() -> [UIBarButtonItem]? {
    let item = UIBarButtonItem(
      image: UIImage(systemName: "square.and.arrow.up"),
      style: .plain,
      target: nil,
      action: nil
    )
    item.accessibilityLabel = "分享主页"
    item.tintColor = TiebaNavigator.shared.chromeTheme.navTint
    item.primaryAction = UIAction { [weak self] _ in self?.shareProfile() }
    return [item]
  }

  private func shareProfile() {
    guard let detail else { return }
    let id = detail.portrait.isEmpty ? uid : detail.portrait
    let link = "https://tieba.baidu.com/home/main?id=\(id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? id)"
    TiebaClipboard.setString(link)
    TiebaSceneHaptics.fire("action-success")
    pill.showResult(success: true, text: "已复制用户主页链接")
  }

  // MARK: - 事件

  private func handleEvent(_ event: TiebaKindListEvent) {
    switch event {
    case .headerAction(let action, let payload):
      handleHeaderAction(action: action, payload: payload)
    case .rowTap(let index, let region, let actionIndex):
      handleRowTap(index: index, region: region, actionIndex: actionIndex)
    case .reachEnd, .footerTap:
      loadMore()
    case .refreshRequested:
      isUserRefresh = true
      reload()
    default:
      break
    }
  }

  /// 页头动作（本页页头 = TiebaUserProfileHeaderAction；payload 只带 avatar 的测量矩形）。
  private func handleHeaderAction(action: TiebaKindListHeaderAction, payload: [String: Any]) {
    guard case .userProfile(let headerAction) = action else { return }
    switch headerAction {
    case .avatar:
      openAvatarPreview(payload)
    case .follow:
      toggleFollow()
    case .block:
      toggleBlock()
    case .copyUid:
      copyUid()
    case .social(let mode):
      presentSocial(mode: mode)
    case .tab(let value):
      switchTab(value)
    }
  }

  private func openAvatarPreview(_ payload: [String: Any]) {
    guard let detail, !detail.portrait.isEmpty,
      let url = TiebaSimpleRowParser.avatarURL(detail.portrait)
    else { return }
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
        contextTitle: nil
      )
    )
  }

  private func switchTab(_ value: String) {
    guard value != activeTab else { return }
    TiebaSceneHaptics.fire("toggle")
    activeTab = value
    list.scrollToTop(animated: false)
    syncHeader()
    // 换 tab = 同一个列表换数据：先清空（空态占位行），避免旧 tab 数据残留。
    rows = []
    rowItems = []
    publish(fresh: true)
    Task { @MainActor in await loadList(reset: true) }
  }

  private func loadMore() {
    guard hasMore, !isLoading, !isLoadingMore else { return }
    isLoadingMore = true
    list.footerState = .loading
    Task { @MainActor in
      await loadList(reset: false)
      isLoadingMore = false
    }
  }

  private func handleRowTap(index: Int, region: String, actionIndex: Int?) {
    guard rows.indices.contains(index) else { return }
    let row = rows[index]
    if activeTab == "forums" {
      guard let forum = rowItems[safe: index] as? TiebaProfileForum else { return }
      openForum(forum.forumName)
      return
    }
    switch region {
    case "chip":
      openForum(TiebaSimpleRowParser.string(row["forumName"]) ?? "")
    case "avatar":
      openUser(TiebaSimpleRowParser.string(row["authorId"]) ?? "")
    case "showMore":
      let key = rowKey(row)
      guard expandedKeys.insert(key).inserted else { return }
      TiebaSceneHaptics.fire("toggle")
      // publish(fresh: false) 复用已存的 rows：必须就地写入 expanded 才会被重新量高。
      rows[index]["expanded"] = true
      publish(fresh: false)
    case "action":
      switch actionIndex {
      case 1: shareThread(row)
      case 2: toggleLike(index)
      default: openThread(row)
      }
    default:
      openThread(row)
    }
  }

  private func openThread(_ row: [String: Any]) {
    let id = TiebaSimpleRowParser.string(row["threadId"]) ?? ""
    guard !id.isEmpty else { return }
    TiebaSceneHaptics.fire("press")
    TiebaNavigator.shared.navigate(.thread(id: id))
  }

  private func openForum(_ name: String) {
    guard !name.isEmpty else { return }
    TiebaSceneHaptics.fire("press")
    TiebaNavigator.shared.navigate(.forum(name: name))
  }

  private func openUser(_ uid: String) {
    guard !uid.isEmpty, uid != self.uid else { return }
    TiebaSceneHaptics.fire("press")
    TiebaNavigator.shared.navigate(.user(uid: uid))
  }

  private func shareThread(_ row: [String: Any]) {
    let id = TiebaSimpleRowParser.string(row["threadId"]) ?? ""
    guard !id.isEmpty else { return }
    TiebaSceneHaptics.fire("press")
    let url = "https://tieba.baidu.com/p/\(id)"
    let title = TiebaSimpleRowParser.string(row["title"]) ?? ""
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

  /// 点赞：乐观翻转 + 失败回滚（镜像表防连点）。
  private func toggleLike(_ index: Int) {
    guard rows.indices.contains(index) else { return }
    let row = rows[index]
    let id = TiebaSimpleRowParser.string(row["threadId"]) ?? ""
    guard !id.isEmpty else { return }
    guard !TiebaBackgroundSnapshot.shared.bduss.isEmpty else {
      TiebaNavigator.shared.navigate(.login)
      return
    }
    let latest = likeMirror[id] ?? (TiebaSimpleRowParser.bool(row["hasAgree"]) ?? false)
    let next = !latest
    likeMirror[id] = next
    TiebaSceneHaptics.fire("like")
    applyLike(index, next)
    let postId = TiebaSimpleRowParser.string(row["firstPostId"]) ?? ""
    Task { @MainActor in
      do {
        try await TiebaThreadActionAPI.setAgree(
          threadId: id,
          postId: postId.isEmpty ? id : postId,
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
        if let current = rows.firstIndex(where: { (TiebaSimpleRowParser.string($0["threadId"]) ?? "") == id }) {
          applyLike(current, latest)
        }
        pill.showResult(success: false, text: "点赞失败，请稍后重试")
      }
    }
  }

  private func applyLike(_ index: Int, _ liked: Bool) {
    guard rows.indices.contains(index) else { return }
    rows[index]["hasAgree"] = liked
    let count = TiebaSimpleRowParser.double(rows[index]["zanNum"]) ?? 0
    rows[index]["zanNum"] = max(0, count + (liked ? 1 : -1))
    publish(fresh: false)
  }

  // MARK: - 动作

  private func toggleFollow() {
    guard let detail else { return }
    guard !TiebaBackgroundSnapshot.shared.bduss.isEmpty else {
      showLoginPrompt()
      return
    }
    let portrait = detail.portrait
    let next = !isFollowing
    isFollowing = next
    syncHeader()
    Task { @MainActor in
      do {
        try await TiebaProfileAPI.follow(portrait: portrait, follow: next)
        TiebaSceneHaptics.fire("action-success")
        pill.showResult(success: true, text: next ? "已关注" : "已取消关注")
      } catch {
        isFollowing = !next
        syncHeader()
        TiebaSceneHaptics.fire("action-fail")
        showAlert(title: "错误", message: error.localizedDescription)
      }
    }
  }

  private func toggleBlock() {
    guard let detail else { return }
    guard !TiebaBackgroundSnapshot.shared.bduss.isEmpty else {
      showLoginPrompt()
      return
    }
    let next = !isBlocked
    Task { @MainActor in
      do {
        try await TiebaProfileAPI.setBlack(uid: uid, black: next)
        if next {
          try? TiebaBlockStore.add(user: TiebaBlockedUser(
            id: String(Int(Date().timeIntervalSince1970 * 1000)),
            uid: uid,
            username: detail.displayName
          ))
        } else {
          try? TiebaBlockStore.removeUser(uid: uid)
        }
        isBlocked = next
        syncHeader()
        TiebaSceneHaptics.fire(next ? "action-success" : "toggle")
        showAlert(title: next ? "已拉黑" : "已取消拉黑", message: next ? "该用户已被拉黑" : "该用户已恢复访问")
      } catch {
        TiebaSceneHaptics.fire("action-fail")
        showAlert(title: "错误", message: next ? "拉黑失败" : "取消拉黑失败")
      }
    }
  }

  private func copyUid() {
    guard let detail else { return }
    TiebaClipboard.setString(detail.uidText)
    TiebaSceneHaptics.fire("action-success")
    showAlert(title: "已复制", message: "贴吧UID: \(detail.uidText)")
  }

  private func presentSocial(mode: String) {
    guard !uid.isEmpty else { return }
    TiebaSceneHaptics.fire("press")
    let controller = TiebaUserSocialViewController(uid: uid, fans: mode != "follows")
    let nav = UINavigationController(rootViewController: controller)
    if let sheet = nav.sheetPresentationController {
      sheet.detents = [.large()]
      sheet.prefersGrabberVisible = true
    }
    present(nav, animated: true)
  }

  private func showLoginPrompt() {
    let alert = UIAlertController(title: "提示", message: "请先登录", preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "取消", style: .cancel))
    alert.addAction(UIAlertAction(title: "去登录", style: .default) { _ in
      TiebaNavigator.shared.navigate(.login)
    })
    present(alert, animated: true)
  }

  private func showAlert(title: String, message: String) {
    guard presentedViewController == nil else { return }
    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "好", style: .default))
    present(alert, animated: true)
  }

  /// 列表色板跟导航壳主题（自定义主题的强调色与底栏一致；其余为默认语义色）。
  private func applyPalette() {
    list.palette = TiebaChromePalette.listPalette()
    skeletonView.isDark = TiebaNavigator.shared.chromeTheme.dark
  }
}

private extension Array {
  subscript(safe index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}
