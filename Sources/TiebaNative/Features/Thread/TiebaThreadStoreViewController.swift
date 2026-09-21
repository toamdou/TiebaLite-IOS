// 我的收藏（原 src/app/threadstore.tsx）：登录引导 + 收藏信息流卡片列表 +
// 左滑「取消收藏」+ 撤销；封面缩略图用收藏时的本地快照（服务端 store_list 不带图）。
//
// 数据 TiebaProfileAPI.favorites / removeFavorite；行渲染 TiebaKindListContentView
// 的 feed 行（与吧页/历史同款卡片）。每次出现的刷新 = 重拉列表 + 重读图片快照。
import UIKit

final class TiebaThreadStoreViewController: UIViewController, TiebaNativeScreen {
  var screenTitle: String? { "我的收藏" }

  private let list = TiebaKindListContentView()
  private let stateView = UIContentUnavailableView(configuration: .loading())
  /// 首屏收藏骨架（原 threadstore.tsx SkeletonList variant="thread" count={6}）
  private let skeletonView = TiebaSkeletonList(variant: .thread, count: 6)
  private let pill = TiebaPhotoBrowserPillView()
  private let undoBar = TiebaThreadStoreUndoBar()

  private var rows: [[String: Any]] = []
  private var page = 1
  private var hasMore = false
  private var isLoading = false
  private var isLoadingMore = false
  private var loadSeq = 0
  private var appeared = false
  private var removed: (row: [String: Any], index: Int)?
  /// 行页发布（页键守卫 + 整页后台测量都收敛在 driver）。
  private lazy var driver = TiebaRowPageDriver(list: list, keyPrefix: "threadstore")

  private static let swipeActions: [[String: Any]] = [[
    "action": "uncollect", "title": "取消收藏", "icon": "star.slash",
    "destructive": true, "backgroundColor": "#FF3B30",
  ]]

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = TiebaNavigator.shared.chromeTheme.background
    applyPalette()
    list.onListEvent = { [weak self] event in self?.handleEvent(event) }
    list.swipeActions = Self.swipeActions
    list.reachEndThreshold = 0.3
    stateView.isHidden = true
    skeletonView.isHidden = true
    undoBar.isHidden = true
    undoBar.onUndo = { [weak self] in self?.undoRemoval() }
    for subview in [list, stateView, skeletonView, pill, undoBar] as [UIView] {
      subview.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(subview)
    }
    let undoFullWidth = undoBar.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -24)
    undoFullWidth.priority = .defaultHigh
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
      pill.widthAnchor.constraint(lessThanOrEqualToConstant: TiebaLayout.floatingMaxWidth),
      // 撤销条：手机 = 屏宽 − 24（351pt，左右各 12）；iPad 由浮动上限收窄，
      // 否则"已取消收藏 / 撤销"会被摊到屏宽两端。
      undoBar.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      undoBar.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 12),
      undoBar.widthAnchor.constraint(lessThanOrEqualToConstant: TiebaLayout.floatingMaxWidth),
      undoBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
      undoFullWidth,
    ])
    reload()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    // 从帖子页取消收藏/重新收藏后返回本页：每次出现重拉（首次由 viewDidLoad 负责）。
    if appeared { reload() }
    appeared = true
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    list.contentInsetTop = view.safeAreaInsets.top + 8
    list.contentInsetBottom = view.safeAreaInsets.bottom + 24
    // 骨架与首行同起点（原 skeletonWrap paddingTop Spacing.sm）
    skeletonView.contentInsets = UIEdgeInsets(top: view.safeAreaInsets.top + 8, left: 0, bottom: 24, right: 0)
    // 行宽契约 = 列表宽 − 2×horizontalInset（内缩含内容列居中留白）。
    driver.updateWidth(list.bounds.width - list.horizontalInset * 2)
  }

  // MARK: - 数据

  private func reload() {
    guard !TiebaBackgroundSnapshot.shared.bduss.isEmpty else {
      rows = []
      showLoginState()
      return
    }
    guard !isLoading else {
      list.endRefreshing()
      return
    }
    isLoading = true
    loadSeq += 1
    let seq = loadSeq
    if rows.isEmpty { showState(.loading) }
    Task { @MainActor in
      defer {
        isLoading = false
        list.endRefreshing()
      }
      do {
        let result = try await TiebaProfileAPI.favorites(page: 1)
        guard seq == loadSeq else { return }
        rows = decorate(result.rows)
        page = 1
        hasMore = result.hasMore
        // 数据到手 ≠ 行能画：整页测量在后台跑，提前让位就是状态视图先消失、正文空白。
        list.revealWhenReady { [weak self] in
          self?.stateView.isHidden = true
          self?.skeletonView.isHidden = true
          self?.list.isHidden = false
        }
        list.footerState = hasMore ? .more : .none
        publish(fresh: true)
        ensureAvatars()
      } catch {
        guard seq == loadSeq else { return }
        if rows.isEmpty {
          showState(.error(error.localizedDescription))
        } else {
          pill.showResult(success: false, text: "刷新失败")
        }
      }
    }
  }

  private func loadMore() {
    guard hasMore, !isLoading, !isLoadingMore else { return }
    isLoadingMore = true
    list.footerState = .loading
    // 分页不碰 loadSeq：否则并发 reload 的结果会被这里的 seq 判丢。
    Task { @MainActor in
      defer {
        isLoadingMore = false
        list.footerState = hasMore ? .more : .none
      }
      do {
        let target = page + 1
        let result = try await TiebaProfileAPI.favorites(page: target)
        page = target
        hasMore = result.hasMore
        rows.append(contentsOf: decorate(result.rows))
        // 分页同页键重推（换页键会整页重测）。
        publish(fresh: false)
        ensureAvatars()
      } catch {
        pill.showResult(success: false, text: "加载失败")
      }
    }
  }

  /// 行补充：本地图片快照（服务端不带图）+ 吧头像（全站统一缓存）。
  private func decorate(_ items: [[String: Any]]) -> [[String: Any]] {
    let images = TiebaVisitHistoryStore.favoriteImagesMap()
    return items.map { item in
      var row = item
      let tid = TiebaSimpleRowParser.string(row["threadId"]) ?? ""
      row["mediaList"] = (images[tid] ?? []).enumerated().map { index, src in
        ["type": "image", "src": src, "originSrc": src, "index": index] as [String: Any]
      }
      let forumId = TiebaSimpleRowParser.string(row["forumId"]) ?? ""
      let forumName = TiebaSimpleRowParser.string(row["forumName"]) ?? ""
      if let key = TiebaForumAvatarCache.key(forumId: forumId, forumName: forumName) {
        row["forumAvatar"] = TiebaForumAvatarCache.shared.cached(key: key)
      }
      return row
    }
  }

  private func ensureAvatars() {
    let pending = TiebaForumAvatarCache.entries(
      from: rows.map {
        (
          forumId: TiebaSimpleRowParser.string($0["forumId"]) ?? "",
          forumName: TiebaSimpleRowParser.string($0["forumName"]) ?? ""
        )
      }
    )
    guard !pending.isEmpty else { return }
    TiebaForumAvatarCache.shared.ensure(entries: pending) { [weak self] in
      guard let self, !self.rows.isEmpty else { return }
      self.rows = self.decorate(self.rows)
      self.publish(fresh: false)
    }
  }

  // MARK: - 发布

  private func publish(fresh: Bool) {
    driver.publish(fresh: fresh) { [weak self] in
      guard let self else { return [] }
      return rows.isEmpty ? emptyRows() : rows
    }
  }

  private func emptyRows() -> [[String: Any]] {
    [
      TiebaEmptyPlaceholderRow.make(
        a11y: "暂无收藏",
        icon: "star.fill",
        title: "暂无收藏",
        subtitle: "浏览帖子时点击收藏即可添加到此处"
      )
    ]
  }

  // MARK: - 状态

  private enum State {
    case loading
    case error(String)
  }

  private func showState(_ state: State) {
    list.isHidden = true
    switch state {
    case .loading:
      // 首次加载且无收藏：骨架（原 loading && items.length === 0 分支）
      skeletonView.isHidden = false
      stateView.isHidden = true
      stateView.configuration = UIContentUnavailableConfiguration.loading()
    case .error(let message):
      skeletonView.isHidden = true
      stateView.showError(message) { [weak self] in self?.reload() }
    }
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

  private func showLoginState() {
    list.isHidden = true
    skeletonView.isHidden = true
    stateView.showEmpty(
      image: "person.crop.circle.badge.questionmark",
      text: "需要登录",
      secondaryText: "登录后才能查看收藏的贴子",
      buttonTitle: "登录百度账号",
      buttonImage: "person.crop.circle.badge.checkmark",
      onButton: {
        TiebaNavigator.shared.navigate(.login)
      }
    )
  }

  // MARK: - 事件

  private func handleEvent(_ event: TiebaKindListEvent) {
    switch event {
    case .refreshRequested:
      reload()
    case .reachEnd, .footerTap:
      loadMore()
    case .rowTap(let index, _, _):
      guard rows.indices.contains(index) else { return }
      openThread(rows[index])
    case .swipeAction(let index, let action):
      guard action == "uncollect", rows.indices.contains(index) else { return }
      TiebaSceneHaptics.fire("destructive")
      uncollect(rows[index])
    case .mediaAction(let index, _, let action, let url, let originURL):
      handleMediaAction(index: index, action: action, url: url, originURL: originURL)
    default:
      break
    }
  }

  /// 行内图片长按菜单（保存照片 / 分享照片）：url 优先 originURL（空串按缺省，
  /// 与旧 payload 判读同）。
  private func handleMediaAction(index: Int, action: String, url: String?, originURL: String?) {
    let source = TiebaSimpleRowParser.string(originURL)
      ?? TiebaSimpleRowParser.string(url) ?? ""
    guard !source.isEmpty else { return }
    guard rows.indices.contains(index) else { return }
    let forumName = TiebaSimpleRowParser.string(rows[index]["forumName"]) ?? ""
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

  private func openThread(_ row: [String: Any]) {
    let id = TiebaSimpleRowParser.string(row["threadId"]) ?? ""
    guard !id.isEmpty else { return }
    TiebaSceneHaptics.fire("press")
    TiebaNavigator.shared.navigate(.thread(id: id, fromFavorites: true))
  }

  // MARK: - 取消收藏 / 撤销

  private func uncollect(_ row: [String: Any]) {
    let tid = TiebaSimpleRowParser.string(row["threadId"]) ?? ""
    guard !tid.isEmpty else { return }
    let index = rows.firstIndex { (TiebaSimpleRowParser.string($0["threadId"]) ?? "") == tid }
    rows.removeAll { (TiebaSimpleRowParser.string($0["threadId"]) ?? "") == tid }
    publish(fresh: true)
    removed = (row, index ?? rows.count)
    undoBar.show(text: "已取消收藏")
    Task { @MainActor in
      do {
        try await TiebaProfileAPI.removeFavorite(tid: tid)
        TiebaVisitHistoryStore.removeFavoriteImages(tid: tid)
        TiebaSceneHaptics.fire("action-success")
      } catch {
        // 回滚：按原下标插回（防重复行）。
        if !rows.contains(where: { (TiebaSimpleRowParser.string($0["threadId"]) ?? "") == tid }) {
          let target = min(max(removed?.index ?? rows.count, 0), rows.count)
          rows.insert(row, at: target)
        }
        publish(fresh: true)
        TiebaSceneHaptics.fire("action-fail")
        pill.showResult(success: false, text: "取消收藏失败")
      }
    }
  }

  private func undoRemoval() {
    guard let pending = removed else { return }
    let tid = TiebaSimpleRowParser.string(pending.row["threadId"]) ?? ""
    guard !tid.isEmpty else { return }
    removed = nil
    undoBar.hide()
    if !rows.contains(where: { (TiebaSimpleRowParser.string($0["threadId"]) ?? "") == tid }) {
      let target = min(max(pending.index, 0), rows.count)
      rows.insert(pending.row, at: target)
      publish(fresh: true)
    }
    TiebaSceneHaptics.fire("action-success")
    // 撤销 = 重新收藏（旧页只做本地插回，服务端仍是取消态；这里补上真实回写）。
    // post_id 拿不到就传空（服务端按 0 收）——传帖子 id 会被当"楼层不存在"（见
    // TiebaThreadViewController.firstFloorPostId 的说明）。
    let postId = TiebaSimpleRowParser.string(pending.row["firstPostId"]) ?? ""
    let safePostId = postId == tid ? "" : postId
    Task { @MainActor in
      do {
        try await TiebaThreadActionAPI.setStore(threadId: tid, firstPostId: safePostId, store: true)
      } catch {
        pill.showResult(success: false, text: "恢复收藏失败")
      }
    }
  }
}

// MARK: - 撤销条

/// 底部撤销条（原位插回入口；6 秒后自动收起，避免死状态常驻）。
private final class TiebaThreadStoreUndoBar: UIView {
  var onUndo: (() -> Void)?
  private let label = UILabel()
  private let button = UIButton(type: .system)

  /// 底材质：iOS 26 液态玻璃；17 退回经典超薄材质模糊（不重建玻璃观感）。
  private static func makeBackdropEffect() -> UIVisualEffect {
    if #available(iOS 26.0, *) { UIGlassEffect() } else { UIBlurEffect(style: .systemUltraThinMaterial) }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    layer.cornerRadius = 20
    layer.cornerCurve = .continuous
    clipsToBounds = true
    // 底材质与同批 FAB 的 .glass() 同源（iOS 26 玻璃 / 17 超薄材质模糊）。
    let glass = UIVisualEffectView(effect: TiebaThreadStoreUndoBar.makeBackdropEffect())
    glass.translatesAutoresizingMaskIntoConstraints = false
    addSubview(glass)
    NSLayoutConstraint.activate([
      glass.leadingAnchor.constraint(equalTo: leadingAnchor),
      glass.trailingAnchor.constraint(equalTo: trailingAnchor),
      glass.topAnchor.constraint(equalTo: topAnchor),
      glass.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
    label.text = "已取消收藏"
    label.font = .preferredFont(forTextStyle: .footnote)
    label.textColor = .label
    button.setTitle("撤销", for: .normal)
    button.titleLabel?.font = .preferredFont(forTextStyle: .footnote)
    button.addTarget(self, action: #selector(handleUndo), for: .touchUpInside)
    let stack = UIStackView(arrangedSubviews: [label, button])
    stack.axis = .horizontal
    stack.alignment = .center
    stack.distribution = .equalSpacing
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
      stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func show(text: String) {
    label.text = text
    isHidden = false
    NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(hide), object: nil)
    perform(#selector(hide), with: nil, afterDelay: 6)
  }

  @objc func hide() {
    isHidden = true
  }

  @objc private func handleUndo() {
    onUndo?()
  }


}
