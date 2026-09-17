// 浏览记录（原 src/app/history.tsx）：分段（贴子记录 / 经过贴吧）+ 清除全部 +
// 日期分组（今天/昨天/更早）的 feed 行列表；左滑删除走系统
// UISwipeActionsConfiguration，图片长按菜单（保存/分享照片）+ 原生查看器。
//
// 数据 = 全 App 唯一 SQLite 的 visit_history 表（TiebaVisitHistoryStore）；
// 帖记录的多图 / 作者信息按可见区间懒回填（pbPage），只补空字段写回 DB。
import UIKit

final class TiebaHistoryViewController: UIViewController, TiebaNativeScreen {
  var screenTitle: String? { "浏览记录" }

  private let list = TiebaKindListContentView()
  private let topBar = UIView()
  private let segmented = UISegmentedControl(items: ["贴子记录", "经过贴吧"])
  private let clearButton = UIButton(type: .system)
  private let stateView = UIContentUnavailableView(configuration: .loading())
  /// 首屏浏览记录骨架（原 history.tsx SkeletonList variant="thread" count={6}）
  private let skeletonView = TiebaSkeletonList(variant: .thread, count: 6)

  /// "thread" | "forum"
  private var activeTab: String
  private var entries: [TiebaHistoryEntry] = []
  /// 页面行 = 行字典 + 该行指向的条目（分组标题行/占位行为 nil）。单一数组，
  /// 下标与 rows 一一对应，不再维护平行数组（两处更新漏一处会错位半屏）。
  private struct PageRow {
    let row: [String: Any]
    let entry: TiebaHistoryEntry?
  }
  private var pageRows: [PageRow] = []
  private var expandedKeys: Set<String> = []
  private var backfillExtra: [String: [String: Any]] = [:]
  private var backfillBusy: Set<String> = []
  private var backfillFailedAt: [String: Int] = [:]
  private var loadSeq = 0
  /// 行页发布（页键守卫 + 整页后台测量都收敛在 driver）。
  private lazy var driver = TiebaRowPageDriver(list: list, keyPrefix: "history")
  private var isLoadingRows = true

  /// 左滑删除（系统 UISwipeActionsConfiguration；视觉 = 原手写版）。
  private static let swipeActions: [[String: Any]] = [[
    "action": "delete", "title": "删除", "icon": "trash",
    "destructive": true, "backgroundColor": "#FF3B30",
  ]]

  init(tab: String) {
    self.activeTab = tab == "forum" ? "forum" : "thread"
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = TiebaNavigator.shared.chromeTheme.background
    applyPalette()
    buildTopBar()
    list.onListEvent = { [weak self] event in self?.handleEvent(event) }
    list.swipeActions = Self.swipeActions
    stateView.isHidden = true
    skeletonView.isHidden = true
    for subview in [topBar, list, stateView, skeletonView] as [UIView] {
      subview.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(subview)
    }
    NSLayoutConstraint.activate([
      topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      list.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      list.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      list.topAnchor.constraint(equalTo: topBar.bottomAnchor),
      list.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      stateView.leadingAnchor.constraint(equalTo: list.leadingAnchor),
      stateView.trailingAnchor.constraint(equalTo: list.trailingAnchor),
      stateView.topAnchor.constraint(equalTo: list.topAnchor),
      stateView.bottomAnchor.constraint(equalTo: list.bottomAnchor),
      skeletonView.leadingAnchor.constraint(equalTo: list.leadingAnchor),
      skeletonView.trailingAnchor.constraint(equalTo: list.trailingAnchor),
      skeletonView.topAnchor.constraint(equalTo: list.topAnchor),
      skeletonView.bottomAnchor.constraint(equalTo: list.bottomAnchor),
    ])
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

  /// 顶部内白 = 原 history.tsx 的 listContent.paddingTop(2)（列表已在顶栏之下，
  /// 不再叠加安全区）；底部 = insets.bottom + Spacing.lg(16)，与该页同值。
  private func applyInsets() {
    list.contentInsetTop = 2
    list.contentInsetBottom = view.safeAreaInsets.bottom + 16
    // 骨架与首行同起点（原 skeletonWrap paddingTop 2）
    skeletonView.contentInsets = UIEdgeInsets(top: 2, left: 0, bottom: 16, right: 0)
  }

  private func buildTopBar() {
    segmented.selectedSegmentIndex = activeTab == "forum" ? 1 : 0
    segmented.addTarget(self, action: #selector(handleSegmentChange), for: .valueChanged)
    var config = UIButton.Configuration.gray()
    config.title = "清除全部"
    config.image = UIImage(
      systemName: "trash",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .medium)
    )
    config.imagePadding = 5
    config.cornerStyle = .capsule
    config.buttonSize = .small
    config.baseForegroundColor = .secondaryLabel
    clearButton.configuration = config
    clearButton.accessibilityLabel = "清除全部记录"
    clearButton.addTarget(self, action: #selector(handleClearAll), for: .touchUpInside)
    clearButton.setContentHuggingPriority(.required, for: .horizontal)
    clearButton.setContentCompressionResistancePriority(.required, for: .horizontal)

    let row = UIStackView(arrangedSubviews: [segmented, clearButton])
    row.axis = .horizontal
    row.spacing = 10
    row.alignment = .center
    row.translatesAutoresizingMaskIntoConstraints = false
    topBar.addSubview(row)
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 16),
      row.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -16),
      row.topAnchor.constraint(equalTo: topBar.topAnchor, constant: 6),
      row.bottomAnchor.constraint(equalTo: topBar.bottomAnchor, constant: -6),
    ])
  }

  // MARK: - 数据

  @objc private func reload() {
    loadSeq += 1
    let seq = loadSeq
    isLoadingRows = entries.isEmpty
    if isLoadingRows {
      // 首次加载且无记录：骨架（原 loading && history.length === 0 分支）
      list.isHidden = true
      stateView.isHidden = true
      skeletonView.isHidden = false
    } else {
      rebuildRows()
      publish(fresh: driver.pageKey.isEmpty)
    }
    Task { @MainActor in
      do {
        let items = try await TiebaVisitHistoryStore.list(type: activeTab)
        guard seq == self.loadSeq else { return }
        self.entries = items
        self.isLoadingRows = false
        self.skeletonView.isHidden = true
        self.stateView.isHidden = true
        self.list.isHidden = false
        self.list.endRefreshing()
        self.rebuildRows()
        self.publish(fresh: true)
        self.ensureAvatars()
      } catch {
        guard seq == self.loadSeq else { return }
        self.isLoadingRows = false
        self.skeletonView.isHidden = true
        self.list.endRefreshing()
        // 已有数据时保留列表（原页 error 只在 history.length === 0 时整屏显示）；
        // 空态由 schema 自愈后的空行承担，不把整屏顶成"加载失败"。
        if self.entries.isEmpty {
          self.showErrorState(error.localizedDescription)
        }
      }
    }
  }

  /// 条目 → 页面行（分组标题行 + 数据行，同一数组里各自带条目引用）。
  private func rebuildRows() {
    var built: [PageRow] = []
    for section in grouped(entries) {
      built.append(PageRow(row: sectionRow(section.title), entry: nil))
      for entry in section.items {
        built.append(PageRow(row: entryRow(entry), entry: entry))
      }
    }
    if built.isEmpty {
      built = [PageRow(row: emptyRow(), entry: nil)]
    }
    pageRows = built
  }

  private func grouped(_ items: [TiebaHistoryEntry]) -> [(title: String, items: [TiebaHistoryEntry])] {
    let calendar = Calendar.current
    let todayStart = calendar.startOfDay(for: Date()).timeIntervalSince1970 * 1000
    let yesterdayStart = todayStart - 86_400_000
    var today: [TiebaHistoryEntry] = []
    var yesterday: [TiebaHistoryEntry] = []
    var earlier: [TiebaHistoryEntry] = []
    for item in items {
      if item.timestamp >= todayStart {
        today.append(item)
      } else if item.timestamp >= yesterdayStart {
        yesterday.append(item)
      } else {
        earlier.append(item)
      }
    }
    return [("今天", today), ("昨天", yesterday), ("更早", earlier)]
      .filter { !$0.1.isEmpty }
      .map { (title: $0.0, items: $0.1) }
  }

  /// 分组标题行（原 styles.sectionHeader：13/600/18、左右 10、上 6 下 4、无色条）。
  private func sectionRow(_ title: String) -> [String: Any] {
    [
      "variant": "section",
      "a11y": title,
      "title": title,
      "titleSize": 13,
      "titleWeight": 600,
      "titleLineHeight": 18,
      "marginH": 10,
      "marginTop": 6,
      "marginBottom": 4,
      "dotWidth": 0,
      "dotHeight": 0,
      "dotSpacing": 0,
    ]
  }

  private func emptyRow() -> [String: Any] {
    let title = isLoadingRows ? "加载中…" : "暂无记录"
    return TiebaEmptyPlaceholderRow.make(
      a11y: title,
      icon: "clock.arrow.circlepath",
      title: title,
      subtitle: isLoadingRows ? "" : (activeTab == "thread" ? "还没有浏览过贴子" : "还没有浏览过贴吧")
    )
  }

  /// 帖记录 / 吧记录 → 信息流卡片行（原 historyThreadToThreadInfo /
  /// historyForumToThreadInfo：历史只落标题+作者+时间，计数全缺置 0）。
  private func entryRow(_ entry: TiebaHistoryEntry) -> [String: Any] {
    let extra = entry.threadId.isEmpty ? nil : backfillExtra[entry.threadId]
    let media = (extra?["mediaList"] as? [[String: Any]]) ?? []
    let cachedAvatar = TiebaForumAvatarCache.shared.cached(
      key: TiebaForumAvatarCache.key(forumId: entry.forumId, forumName: entry.forumName) ?? ""
    )
    let isForumRow = entry.type == "forum"
    var row: [String: Any] = [
      "kind": TiebaKindRowKind.feed.rawValue,
      "id": isForumRow ? "forum-\(entry.id)" : entry.id,
      "threadId": isForumRow ? "" : entry.threadId,
      "title": isForumRow ? "" : entry.title,
      "forumId": entry.forumId,
      "forumName": isForumRow ? "" : entry.forumName,
      "forumAvatar": isForumRow ? "" : ((extra?["forumAvatar"] as? String) ?? cachedAvatar),
      "authorId": "",
      "authorName": isForumRow
        ? (entry.forumName.isEmpty ? "未知" : entry.forumName)
        : entry.authorName,
      "authorNameShow": "",
      "authorPortrait": isForumRow
        ? (entry.avatar.isEmpty ? cachedAvatar : entry.avatar)
        : entry.authorPortrait,
      "authorIP": "",
      "replyNum": 0,
      "viewNum": 0,
      "zanNum": 0,
      "shareNum": 0,
      "hasAgree": false,
      "lastTime": entry.timestamp,
      "createTime": isForumRow ? 0 : entry.timestamp,
      "isVideo": media.contains { (TiebaSimpleRowParser.string($0["type"]) ?? "image") == "video" },
      "mediaList": media,
      "abstract": isForumRow ? "浏览过这个吧" : "",
      "expanded": expandedKeys.contains(entryKey(entry)),
      "isShareThread": false,
      "timeType": "create",
      "showForumPill": !isForumRow,
      "hideActions": true,
      "imageContextMenu": !isForumRow,
      // 原 TweetCard 未传 onMenuAction → 不渲染右上角 ×。
      "closeMenuOptions": [] as [String],
    ]
    row.merge(TiebaFeedRowPreferences.current()) { _, new in new }
    return row
  }

  private func entryKey(_ entry: TiebaHistoryEntry) -> String {
    "\(entry.type)-\(entry.threadId.isEmpty ? entry.forumName : entry.threadId)-\(Int(entry.timestamp))"
  }

  /// fresh = 换页键（数据集合变了）；false = 同页重推（展开态/回填/换色，保留滚动位置）。
  private func publish(fresh: Bool) {
    driver.publish(fresh: fresh) { [weak self] in
      self?.pageRows.map(\.row) ?? []
    }
  }

  /// 吧头像补齐（全站统一缓存；拉到新头像后原位重推行）。
  private func ensureAvatars() {
    var seen = Set<String>()
    var pending: [(key: String, name: String)] = []
    for entry in entries {
      guard let key = TiebaForumAvatarCache.key(forumId: entry.forumId, forumName: entry.forumName),
        seen.insert(key).inserted
      else { continue }
      pending.append((key: key, name: entry.forumName))
    }
    guard !pending.isEmpty else { return }
    TiebaForumAvatarCache.shared.ensure(entries: pending) { [weak self] in
      guard let self, !self.entries.isEmpty else { return }
      self.rebuildRows()
      self.publish(fresh: false)
    }
  }

  // MARK: - 回填（可见区间懒拉 pbPage：作者名/头像/吧名写回 DB，media 只存内存）

  private func backfillVisible(start: Int, end: Int) {
    let lower = max(start, 0)
    let upper = min(end, pageRows.count - 1)
    guard lower <= upper else { return }
    for index in lower...upper {
      guard let entry = pageRows[index].entry, entry.type == "thread", !entry.threadId.isEmpty else {
        continue
      }
      backfill(entry)
    }
  }

  private func backfill(_ entry: TiebaHistoryEntry) {
    let threadId = entry.threadId
    guard backfillExtra[threadId] == nil, !backfillBusy.contains(threadId) else { return }
    let now = Int(Date().timeIntervalSince1970 * 1000)
    guard now - (backfillFailedAt[threadId] ?? 0) >= 30_000 else { return }
    backfillBusy.insert(threadId)
    Task { @MainActor in
      defer { backfillBusy.remove(threadId) }
      do {
        let page = try await TiebaThreadAPI.page(
          threadId: threadId, page: 1, postId: nil, seeLz: false, reverse: false
        )
        guard let thread = page.thread else { return }
        let images = (page.posts.first?.images ?? []).map { image -> [String: Any] in
          [
            "type": "image", "src": image.src, "originSrc": image.originSrc,
            "smallSrc": image.src, "width": image.width, "height": image.height,
            "isGif": image.isGif,
          ]
        }
        backfillExtra[threadId] = ["mediaList": images, "forumAvatar": thread.forumAvatar]
        backfillFailedAt[threadId] = nil
        await TiebaVisitHistoryStore.updateAuthorInfo(
          threadId: threadId,
          authorName: thread.authorName,
          authorPortrait: thread.authorPortrait,
          forumName: thread.forumName
        )
        // DB 只补空字段：内存条目同步同一规则（行渲染立刻能看到补上的作者）。
        entries = entries.map { item in
          guard item.type == "thread", item.threadId == threadId else { return item }
          var next = item
          if next.authorName.isEmpty { next.authorName = thread.authorName }
          if next.authorPortrait.isEmpty { next.authorPortrait = thread.authorPortrait }
          if next.forumName.isEmpty { next.forumName = thread.forumName }
          return next
        }
        rebuildRows()
        publish(fresh: false)
      } catch {
        backfillFailedAt[threadId] = Int(Date().timeIntervalSince1970 * 1000)
      }
    }
  }

  // MARK: - 事件

  private func handleEvent(_ event: TiebaKindListEvent) {
    switch event {
    case .refreshRequested:
      TiebaSceneHaptics.fire("toggle")
      reload()
    case .rowTap(let index, let region, _):
      handleRowTap(index: index, region: region)
    case .swipeAction(let index, let action):
      guard action == "delete",
        pageRows.indices.contains(index), let entry = pageRows[index].entry
      else { return }
      TiebaSceneHaptics.fire("destructive")
      delete(entry)
    case .mediaAction(let index, _, let action, let url, let originURL):
      handleMediaAction(index: index, action: action, url: url, originURL: originURL)
    case .visibleRangeChange(let start, let end, _):
      backfillVisible(start: start, end: end)
    default:
      break
    }
  }

  private func handleRowTap(index: Int, region: String) {
    guard pageRows.indices.contains(index), let entry = pageRows[index].entry else { return }
    if entry.type == "forum" {
      openForum(entry.forumName)
      return
    }
    switch region {
    case "chip":
      openForum(entry.forumName)
    case "showMore":
      let key = entryKey(entry)
      guard expandedKeys.insert(key).inserted else { return }
      TiebaSceneHaptics.fire("toggle")
      rebuildRows()
      publish(fresh: false)
    default:
      openThread(entry)
    }
  }

  /// 行内图片长按菜单（保存照片 / 分享照片）：url 优先 originURL（空串按缺省，
  /// 与旧 payload 判读同）。
  private func handleMediaAction(index: Int, action: String, url: String?, originURL: String?) {
    let source = TiebaSimpleRowParser.string(originURL)
      ?? TiebaSimpleRowParser.string(url) ?? ""
    guard !source.isEmpty else { return }
    guard pageRows.indices.contains(index) else { return }
    let forumName = pageRows[index].entry?.forumName ?? ""
    switch action {
    case "save-image":
      TiebaFeedImageActions.save(url: source, forumName: forumName, presenter: self)
    case "share-image":
      TiebaFeedImageActions.share(
        url: source, forumName: forumName, presenter: self,
        sourceRect: CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
      )
    default:
      break
    }
  }

  private func openThread(_ entry: TiebaHistoryEntry) {
    let id = entry.threadId.isEmpty ? entry.id : entry.threadId
    guard !id.isEmpty else { return }
    TiebaSceneHaptics.fire("press")
    TiebaNavigator.shared.navigate(.thread(id: id))
  }

  private func openForum(_ name: String) {
    guard !name.isEmpty else { return }
    TiebaSceneHaptics.fire("press")
    TiebaNavigator.shared.navigate(.forum(name: name))
  }

  // MARK: - 删除 / 清空 / 分段

  private func delete(_ entry: TiebaHistoryEntry) {
    Task { @MainActor in
      do {
        try await TiebaVisitHistoryStore.remove(rowIds: [entry.rowId])
        entries.removeAll { $0.rowId == entry.rowId }
        // 已发布页仍持有被删项 → 必须换页键重推（同页键只重配可见行）。
        rebuildRows()
        publish(fresh: true)
        TiebaSceneHaptics.fire("action-success")
      } catch {
        showError("删除失败")
        reload()
      }
    }
  }

  @objc private func handleSegmentChange() {
    TiebaSceneHaptics.fire("toggle")
    activeTab = segmented.selectedSegmentIndex == 1 ? "forum" : "thread"
    list.scrollToTop(animated: false)
    entries = []
    rebuildRows()
    publish(fresh: true)
    reload()
  }

  @objc private func handleClearAll() {
    TiebaSceneHaptics.fire("destructive")
    let alert = UIAlertController(
      title: "清空记录",
      message: "确定要清空所有\(activeTab == "thread" ? "贴子" : "贴吧")记录吗？此操作不可恢复。",
      preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(title: "取消", style: .cancel))
    alert.addAction(UIAlertAction(title: "清空", style: .destructive) { [weak self] _ in
      guard let self else { return }
      Task { @MainActor in
        do {
          try await TiebaVisitHistoryStore.clear(type: self.activeTab)
          self.entries = []
          self.rebuildRows()
          self.publish(fresh: true)
          TiebaSceneHaptics.fire("action-success")
        } catch {
          self.showError("清空失败")
        }
      }
    })
    present(alert, animated: true)
  }

  private func showErrorState(_ message: String) {
    list.isHidden = true
    skeletonView.isHidden = true
    stateView.showError(message) { [weak self] in self?.reload() }
  }

  private func showError(_ message: String) {
    guard presentedViewController == nil else { return }
    let alert = UIAlertController(title: "错误", message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "好", style: .default))
    present(alert, animated: true)
  }

  /// 列表色板跟导航壳主题（自定义主题的强调色与底栏一致；其余为默认语义色）。
  /// 主题变化（含跟随系统时的实时切换）→ 重取主题重刷自绘色（页面底色/列表色板/页头）。
  func screenThemeDidChange() {
    applyPalette()
  }

  private func applyPalette() {
    list.palette = TiebaChromePalette.listPalette()
    skeletonView.isDark = TiebaNavigator.shared.chromeTheme.dark
  }

}
