// 话题详情（原 src/app/topic/[id].tsx）：数据 TiebaTopicAPI，列表 = TiebaKindListContentView
// 的 feed 行（与信息流卡片同一份 TiebaRowMetrics/TiebaFeedRowView），页头走 headerSpec
// （相关吧胶囊），点赞/分享/屏蔽作者/长文展开全在原生。
import UIKit

final class TiebaTopicViewController: UIViewController, TiebaNativeScreen {
  var screenTitle: String? { topicName }

  private let topicId: String
  private let topicName: String

  private let list = TiebaKindListContentView()
  /// 整页发布驱动（页键 = topic-<id>-<seq>）：测量在后台，旧页后到不覆盖新页。
  private lazy var driver = TiebaRowPageDriver(list: list, keyPrefix: "topic-\(topicId)")
  private let stateView = TiebaStateContentView()
  /// 空结果时列表 section 无行、不挂 boundary item，页头改由这份独立宿主承载。
  private let stateHeaderHost = UIView()
  private var stateHeader: (any TiebaKindListHeaderView)?
  private var stateHeaderHeight: NSLayoutConstraint?
  /// 空态页头宽 = 内容列宽（与列表页头同列同宽，量多少画多少）。
  private var stateHeaderWidth: NSLayoutConstraint?
  private let pill = TiebaPhotoBrowserPillView()

  /// mapProtoThread 输出（行字典来源；点赞/屏蔽直接改这份）。
  private var threads: [[String: Any]] = []
  private var detail: TiebaTopicDetail?
  private var expandedIds: Set<String> = []
  private var likeMirror: [String: Bool] = [:]
  private var page = 1
  private var hasMore = false
  private var isLoading = false
  private var isLoadingMore = false
  private var isUserRefresh = false

  init(topicId: String, name: String) {
    self.topicId = topicId
    self.topicName = name.isEmpty ? "话题" : name
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    applyPalette()
    list.onListEvent = { [weak self] event in self?.handleEvent(event) }
    list.isHidden = true
    stateView.isDark = TiebaNavigator.shared.chromeTheme.dark
    stateView.onButtonPress = { [weak self] _ in self?.reload() }
    stateView.isHidden = true
    stateHeaderHost.isHidden = true
    for subview in [list, stateHeaderHost, stateView, pill] as [UIView] {
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
      pill.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      pill.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
      pill.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.82),
      pill.widthAnchor.constraint(lessThanOrEqualToConstant: TiebaLayout.floatingMaxWidth),
    ])
    reload()
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

  /// 列表自带 refreshControl 且 contentInsetAdjustmentBehavior = .never：顶部内白自补。
  private func applyInsets() {
    list.contentInsetTop = view.safeAreaInsets.top
    list.contentInsetBottom = view.safeAreaInsets.bottom + 24
  }

  /// 主色跟导航壳的主题（自定义主题的强调色与底栏一致；其余为默认语义色）。
  /// 主题变化（含跟随系统时的实时切换）→ 重取主题重刷自绘色（页面底色/列表色板/页头）。
  func screenThemeDidChange() {
    applyPalette()
  }

  private func applyPalette() {
    var palette = TiebaSimpleRowPalette.default
    let tint = TiebaNavigator.shared.chromeTheme.tint
    palette.base.primary = tint
    list.palette = palette
  }

  // MARK: - 数据

  @objc private func reload() {
    guard !isLoading else {
      list.endRefreshing()
      return
    }
    guard !topicId.isEmpty else {
      list.endRefreshing()
      showError("缺少话题 ID")
      return
    }
    isLoading = true
    if threads.isEmpty { showState(.loading) }
    Task { @MainActor in
      defer {
        isLoading = false
        isUserRefresh = false
        list.endRefreshing()
      }
      do {
        let result = try await TiebaTopicAPI.detail(topicId: topicId, topicName: topicName, page: 1)
        detail = result
        threads = result.threads
        hasMore = result.hasMore
        page = 2
        isLoadingMore = false
        list.headerSpec = headerSpec(for: result)
        driver.publish(fresh: true, makeRows: makeRows)
        if threads.isEmpty {
          showEmpty()
        } else {
          list.footerState = hasMore ? .more : .none
          showList()
        }
        if isUserRefresh { TiebaSceneHaptics.fire("toggle") }
      } catch {
        if threads.isEmpty {
          showError(error.localizedDescription)
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
        let result = try await TiebaTopicAPI.detail(topicId: topicId, topicName: topicName, page: page)
        page += 1
        hasMore = result.hasMore
        threads.append(contentsOf: result.threads)
        driver.publish(fresh: true, makeRows: makeRows)
      } catch {
        pill.showResult(success: false, text: "加载失败")
      }
    }
  }

  private func makeRows() -> [[String: Any]] {
    let hideMedia = TiebaPreferenceSnapshot.bool("hideMedia", default: false)
    let showIp = TiebaPreferenceSnapshot.bool("showIpLocation", default: true)
    let fontScale = Double(TiebaPreferenceSnapshot.string("fontScale") ?? "") ?? 1
    return threads.map { thread in
      var row = thread
      row["kind"] = TiebaKindRowKind.feed.rawValue
      // 话题页按发帖时间排序；长文展开态由本页持有（原生行无行内状态）。
      row["timeType"] = "create"
      row["expanded"] = expandedIds.contains(TiebaSimpleRowParser.string(thread["id"]) ?? "")
      row["hideMedia"] = hideMedia
      row["showIpLocation"] = showIp
      row["fontScale"] = fontScale
      // 原 TweetCard 未传 closeMenuOptions → 默认只有「屏蔽作者」。
      row["closeMenuOptions"] = ["block"]
      return row
    }
  }

  private func headerSpec(for detail: TiebaTopicDetail) -> [String: Any] {
    guard detail.hasInfo else {
      return ["kind": "topicCentered", "title": "#\(topicName)#"]
    }
    var spec: [String: Any] = ["kind": "topic", "title": "#\(topicName)#"]
    if let discuss = detail.discussNum { spec["discuss"] = discuss }
    if let desc = detail.desc { spec["desc"] = desc }
    if !detail.forums.isEmpty {
      spec["forums"] = detail.forums.map { ["name": $0.name, "avatar": $0.avatar] }
    }
    return spec
  }

  // MARK: - 状态

  /// 只有"已拿到话题信息但没有帖子"的空态才画页头（与旧页 ListHeaderComponent +
  /// EmptyState 同形；列表 0 行时不挂 boundary item）。
  private func showState(_ state: TiebaState) {
    stateView.state = state
    stateView.isHidden = false
    list.isHidden = true
    if case .empty = state, detail?.hasInfo == true {
      installStateHeader()
      stateHeaderHost.isHidden = false
    } else {
      clearStateHeader()
    }
  }

  private func showEmpty() {
    showState(.empty(image: "text.bubble", text: "暂无讨论", secondary: "这个话题下还没有内容"))
  }

  private func showError(_ message: String) {
    showState(.error(message: message, image: "exclamationmark.triangle"))
  }

  private func showList() {
    stateView.isHidden = true
    list.isHidden = false
    clearStateHeader()
  }

  private func installStateHeader() {
    guard let detail else { return }
    if stateHeader == nil, let header = TiebaKindListHeaderFactory.make(spec: headerSpec(for: detail)) {
      header.onAction = { [weak self] action, _ in
        self?.handleHeaderAction(action)
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
  }

  private func clearStateHeader() {
    stateHeaderHost.isHidden = true
    guard stateHeader != nil else { return }
    stateHeader?.removeFromSuperview()
    stateHeader = nil
    stateHeaderHeight?.constant = 0
  }

  // MARK: - 事件

  private func handleEvent(_ event: TiebaKindListEvent) {
    switch event {
    case .rowTap(let index, let region, let actionIndex):
      handleRowTap(index: index, region: region, actionIndex: actionIndex)
    case .menuAction(let index, let action):
      handleMenuAction(index: index, action: action)
    case .headerAction(let action, _):
      handleHeaderAction(action)
    case .reachEnd, .footerTap:
      loadMore()
    case .refreshRequested:
      isUserRefresh = true
      reload()
    default:
      break
    }
  }

  /// 页头动作（本页页头 = TiebaTopicHeaderAction）。
  private func handleHeaderAction(_ action: TiebaKindListHeaderAction) {
    guard case .topic(.forum(let name)) = action, !name.isEmpty else { return }
    TiebaSceneHaptics.fire("press")
    TiebaNavigator.shared.navigate(.forum(name: name))
  }

  private func handleRowTap(index: Int, region: String, actionIndex: Int?) {
    guard threads.indices.contains(index) else { return }
    switch region {
    case "avatar":
      let uid = value(index, "authorId")
      guard !uid.isEmpty else { return }
      TiebaSceneHaptics.fire("press")
      TiebaNavigator.shared.navigate(.user(uid: uid))
    case "chip":
      let forumName = value(index, "forumName")
      guard !forumName.isEmpty else { return }
      TiebaSceneHaptics.fire("press")
      TiebaNavigator.shared.navigate(.forum(name: forumName))
    case "showMore":
      let id = value(index, "id")
      guard !id.isEmpty, expandedIds.insert(id).inserted else { return }
      TiebaSceneHaptics.fire("toggle")
      driver.publish(fresh: false, makeRows: makeRows)
    case "action":
      switch actionIndex {
      case 0: openThread(index)
      case 1: shareThread(index)
      case 2: toggleLike(index)
      default: break
      }
    case "media":
      // 真图点击已由原生查看器直开；到这里的只有视频 poster（进帖）。
      guard !hasImageMedia(index) else { return }
      openThread(index)
    default:
      openThread(index)
    }
  }

  private func handleMenuAction(index: Int, action: String) {
    guard threads.indices.contains(index) else { return }
    switch action {
    case "copy-title":
      let title = value(index, "title")
      guard !title.isEmpty else { return }
      TiebaClipboard.setString(title)
    case "block":
      blockAuthor(index)
    default:
      break
    }
  }

  // MARK: - 动作

  private func openThread(_ index: Int) {
    let id = value(index, "id")
    guard !id.isEmpty else { return }
    TiebaSceneHaptics.fire("press")
    TiebaNavigator.shared.navigate(.thread(id: id))
  }

  private func shareThread(_ index: Int) {
    let id = value(index, "id")
    guard !id.isEmpty else { return }
    TiebaSceneHaptics.fire("press")
    let url = "https://tieba.baidu.com/p/\(id)"
    let title = value(index, "title")
    let text = title.isEmpty ? url : "\(title)\n\(url)"
    TiebaShareSheet.present(text: text, from: self)
  }

  /// 点赞：乐观翻转 + 失败回滚（与 useFeedCardActions 同一竞态策略，镜像表防连点）。
  private func toggleLike(_ index: Int) {
    let id = value(index, "id")
    guard !id.isEmpty else { return }
    guard !TiebaBackgroundSnapshot.shared.bduss.isEmpty else {
      TiebaNavigator.shared.navigate(.login)
      return
    }
    let latest = likeMirror[id] ?? (TiebaSimpleRowParser.bool(threads[index]["hasAgree"]) ?? false)
    let next = !latest
    likeMirror[id] = next
    TiebaSceneHaptics.fire("like")
    applyLike(index, next)

    let threadId = value(index, "threadId")
    let firstPostId = value(index, "firstPostId")
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
        // 「已经点过赞了」= 目标态已达成（幂等翻转）：保持乐观态不回滚。
        if let vmError = error as? TiebaViewModelError, vmError.message.contains("点过赞") {
          TiebaSceneHaptics.fire("action-success")
          pill.showResult(success: true, text: next ? "点赞成功" : "已取消点赞")
          return
        }
        TiebaSceneHaptics.fire("action-fail")
        likeMirror[id] = latest
        if let current = threads.firstIndex(where: { TiebaSimpleRowParser.string($0["id"]) == id }) {
          applyLike(current, latest)
        }
        pill.showResult(success: false, text: "点赞失败，请稍后重试")
      }
    }
  }

  private func applyLike(_ index: Int, _ liked: Bool) {
    guard threads.indices.contains(index) else { return }
    threads[index]["hasAgree"] = liked
    let count = TiebaSimpleRowParser.double(threads[index]["zanNum"]) ?? 0
    threads[index]["zanNum"] = max(0, count + (liked ? 1 : -1))
    driver.publish(fresh: false, makeRows: makeRows)
  }

  /// 屏蔽作者：走 BlockManager 逐 uid 键（同键同形状，顺带按 uid 去重）。
  private func blockAuthor(_ index: Int) {
    let uid = value(index, "authorId")
    guard !uid.isEmpty else { return }
    let name = value(index, "authorNameShow").isEmpty
      ? value(index, "authorName")
      : value(index, "authorNameShow")
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
    threads.removeAll { value($0, "authorId") == uid }
    if threads.isEmpty {
      showEmpty()
    } else {
      driver.publish(fresh: true, makeRows: makeRows)
    }
  }

  // MARK: - 取值

  private func value(_ index: Int, _ key: String) -> String {
    guard threads.indices.contains(index) else { return "" }
    return value(threads[index], key)
  }

  private func value(_ thread: [String: Any], _ key: String) -> String {
    TiebaSimpleRowParser.string(thread[key]) ?? ""
  }

  private func hasImageMedia(_ index: Int) -> Bool {
    guard threads.indices.contains(index) else { return false }
    let media = threads[index]["mediaList"] as? [[String: Any]] ?? []
    return media.contains { ($0["type"] as? String ?? "image") == "image" }
  }
}
