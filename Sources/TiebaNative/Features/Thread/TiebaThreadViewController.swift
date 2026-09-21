// 帖子详情（原 src/app/thread/[id].tsx）：数据 TiebaThreadAPI，列表 = 
// TiebaKindListContentView 的 post 行（TiebaPostRowMetrics/TiebaPostRowView），
// 主贴 + 回复工具栏是第 0 行，浮动胶囊/更多 sheet/跳页全在原生。
//
// 旧页的三个 JS store 均有原生替身：会话/Cookie = TiebaBackgroundSnapshot，
// 楼中楼父帖 = 楼中楼页自行从 pbFloor 响应取（原 parentPostCache 只是跳转前
// 快照），媒体互斥/离屏暂停 = TiebaThreadMediaCoordinator。
import UIKit

final class TiebaThreadViewController: TiebaPostListPageController, TiebaNativeScreen {
  var screenTitle: String? {
    // 列表→详情快照的标题先顶上（原 Stack.Screen options：快照标题 || 帖子标题），
    // 首包返回后由真实标题接管。
    if let title = thread?.title, !title.isEmpty { return title }
    guard let known = knownSnapshot?.title, !known.isEmpty else { return nil }
    return known
  }
  var screenRightBarItems: [UIBarButtonItem]? { forumBarItems() }

  private let threadId: String
  private let postId: String?
  private let fromFavorites: Bool
  private let knownSnapshot: TiebaThreadSnapshot?
  private var knownPostView: TiebaThreadKnownPostView?
  private var seeLz: Bool
  private var reverse: Bool
  private var isCollected: Bool

  private let floatingBar = TiebaThreadFloatingBar()

  private var thread: TiebaThreadInfo?
  /// 回复（不含主贴）。
  private var posts: [TiebaThreadPost] = []
  /// 钉住的主贴（原 JS 的 pinnedMainPost）：正序/倒序、只看楼主、翻页都不动它，
  /// 只有整页跳转/首包才更新；否则"切排序"会把主贴卡一起换掉甚至换没。
  private var mainPost: TiebaThreadPost?
  private var totalPages = 0
  private var recordedVisit = false
  private var moreSignalToken: UUID?
  /// 长帖保留上限（原 MAX_POSTS）：头楼保留，其余丢弃最早追加的尾部之外的头。
  private static let maxPosts = 400
  /// 显示设置（现读偏好；布局路径不重复查 KV）。
  private var showShortcut = true

  override var skeletonVariant: TiebaSkeletonVariant { .post }
  /// 骨架与真行同形态：否则首屏先是卡片、数据落地方变成扁平，会跳一下。
  override var skeletonFlat: Bool { true }
  /// 取消卡片后页面只剩裸楼层：底色随行面色（白/深色行面），楼层靠发际线分层。
  override var pageUsesRowSurface: Bool { true }
  override var skeletonCount: Int { 5 }
  override var skeletonInsetTop: CGFloat { 12 }
  /// Toast.tsx 的 pill 停在 bottom = insets.bottom + 96。
  override var pillBottomInset: CGFloat { 96 }
  override var emptySecondaryText: String { "还没有人回复这个帖子" }

  /// 类型化入口：参数由 TiebaNativeRouteTable 从 TiebaRoute.thread 解好，
  /// 页面不再自己从字符串读回。
  init(threadId: String, postId: String?, seeLz: Bool, fromFavorites: Bool) {
    self.threadId = threadId
    // 快照只在首帧消费一次（一次性交付）：未命中/深链进来都返回 nil。
    self.knownSnapshot = TiebaThreadSnapshots.consume(id: threadId)
    self.postId = postId
    self.fromFavorites = fromFavorites
    let collectSeeLz = TiebaPreferenceSnapshot.bool("collectSeeLz", default: true)
    let collectDescSort = TiebaPreferenceSnapshot.bool("collectDescSort", default: false)
    self.seeLz = seeLz || (fromFavorites && collectSeeLz)
    self.reverse = fromFavorites && collectDescSort
    self.isCollected = fromFavorites
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  deinit {
    if let moreSignalToken {
      Task { @MainActor in TiebaThreadMoreSignal.shared.remove(moreSignalToken) }
    }
  }

  // MARK: - 生命周期

  override func viewDidLoad() {
    super.viewDidLoad()
    applyPalette()
    installSharedSubviews()
    // 主贴预加载占位（原 KnownPostHeader）：只挂在骨架里，首包落地后随骨架一起
    // 被真实主贴卡替换。
    if let knownSnapshot {
      let known = TiebaThreadKnownPostView(snapshot: knownSnapshot)
      known.applyPalette(list.palette.base)
      skeletonView.headerView = known
      knownPostView = known
    }
    configureSharedList()
    // 转场期给整页轻微压暗（Hero 的 beginWith overlay）：让放大的卡片从背景里浮出来。
    // 只在本页是"配对目标"（有快照 = 从列表点进来的）时加——深链直达没有源卡片，
    // 压暗只会让首帧凭空暗一下。
    if knownSnapshot != nil {
      TiebaHeroTransition.markBackdrop(view)
    }
    // 有已知主贴卡时不放入场动画：那张卡就是列表里被点的那一行，首包落地应当是
    // 「原地换内容」，而不是行从下往上滑 10pt（用户报的"加载完突然往上瞬移"）。
    if knownSnapshot != nil { list.entranceAnimationEnabled = false }
    list.onScroll = { [weak self] scrollView in self?.handleScroll(scrollView) }
    floatingBar.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(floatingBar)
    // 手机维持屏宽 72%（iPhone 375 → 270）；iPad 上 72% 会到 737pt（四个 184pt
    // 空槽），故 72% 降为高位、再由浮动条上限收窄（360 ≈ 四个图标按钮的舒适宽）。
    let barWidth = floatingBar.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.72)
    barWidth.priority = .defaultHigh
    NSLayoutConstraint.activate([
      floatingBar.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      floatingBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -2),
      barWidth,
      floatingBar.widthAnchor.constraint(lessThanOrEqualToConstant: TiebaLayout.floatingMaxWidth),
      floatingBar.heightAnchor.constraint(equalToConstant: 54),
    ])
    floatingBar.onAction = { [weak self] action in self?.handleBarAction(action) }
    moreSignalToken = TiebaThreadMoreSignal.shared.observe { [weak self] threadId, action in
      guard let self, threadId.isEmpty || threadId == self.threadId else { return }
      // sheet 在自身 viewDidDisappear（收起转场结束）后才会发动作，这里直接执行。
      self.handleMoreAction(action)
    }
    showShortcut = TiebaPreferenceSnapshot.bool("showShortcutInThread", default: true)
    floatingBar.isHidden = !showShortcut
    reload()
  }

  /// 偏好/主题可能在本屏离开期间被改（设置页）：每次出现现读。
  override func refreshPreferences() {
    showShortcut = TiebaPreferenceSnapshot.bool("showShortcutInThread", default: true)
  }

  /// 主题色板（基类实现）+ 已知主贴占位同色（骨架期可见，必须一起换色）。
  /// 主题变化（含跟随系统时的实时切换）→ 重取主题重刷自绘色（页面底色/列表色板/页头）。
  func screenThemeDidChange() {
    applyPalette()
  }

  override func applyPalette() {
    super.applyPalette()
    knownPostView?.applyPalette(list.palette.base)
  }

  /// 已知主贴卡的落位与真实主贴卡对齐：真实卡 = 内容顶 + 行内 cardMarginV(4)，
  /// 骨架的默认内白是 +12 —— 不对齐的话首包落地时整块会往上跳一次（用户实证
  /// "刚开始位置在正确位置靠下，加载完突然往上顺移"）。
  override func applyBaseInsets() {
    super.applyBaseInsets()
    guard knownPostView != nil else { return }
    skeletonView.contentInsets.top = view.safeAreaInsets.top + TiebaPostRowLayout.cardMarginV
  }

  /// 列表自带 refreshControl 且 contentInsetAdjustmentBehavior = .never：顶部内白自补。
  /// 底部让位浮动胶囊（旧页 paddingBottom = insets.bottom + 80/12 同值）。
  override func applyInsets() {
    applyBaseInsets()
    list.contentInsetBottom = view.safeAreaInsets.bottom + (showShortcut ? 78 : 12)
  }

  /// 状态视图/列表切换后同步浮动胶囊（隐藏时也要跟着藏，避免压在状态块上）。
  override func applyChromeVisibility() {
    floatingBar.isHidden = list.isHidden || !showShortcut
  }

  // MARK: - 数据

  override func reload() {
    guard !isLoading else {
      list.endRefreshing()
      return
    }
    guard !threadId.isEmpty else {
      list.endRefreshing()
      showState(.error("缺少帖子 ID"))
      return
    }
    isLoading = true
    loadGeneration += 1
    let generation = loadGeneration
    if posts.isEmpty { showState(.loading) }
    Task { @MainActor in
      defer {
        self.isLoading = false
        self.isUserRefresh = false
        self.list.endRefreshing()
      }
      do {
        let page = try await TiebaThreadAPI.page(
          threadId: self.threadId,
          page: 1,
          postId: self.postId,
          seeLz: self.seeLz,
          reverse: self.reverse
        )
        self.apply(page, replacing: true, generation: generation)
        if generation == self.loadGeneration, self.isUserRefresh {
          TiebaSceneHaptics.fire("toggle")
        }
      } catch {
        guard generation == self.loadGeneration else { return }
        if self.posts.isEmpty {
          self.showState(.error(error.localizedDescription))
        } else {
          self.pill.showResult(success: false, text: "加载失败")
        }
      }
    }
  }

  /// 只看楼主 / 正序倒序：只重取回复（主贴卡与工具栏整块不动，也不出现骨架）。
  /// 与 reload() 的区别只有两点：keepMain（不覆盖钉住的主贴）与不换页键。
  private func reloadReplies() {
    guard !isLoading else { return }
    isLoading = true
    loadGeneration += 1
    let generation = loadGeneration
    Task { @MainActor in
      defer {
        self.isLoading = false
        self.isUserRefresh = false
        self.list.endRefreshing()
      }
      do {
        let page = try await TiebaThreadAPI.page(
          threadId: self.threadId,
          page: 1,
          postId: nil,
          seeLz: self.seeLz,
          reverse: self.reverse
        )
        self.apply(page, replacing: true, generation: generation, keepMain: true)
      } catch {
        guard generation == self.loadGeneration else { return }
        self.pill.showResult(success: false, text: "加载失败")
      }
    }
  }

  override func loadMore() {
    guard hasMore, !isLoading, !isLoadingMore, currentPage > 0 else { return }
    isLoadingMore = true
    list.footerState = .loading
    let generation = loadGeneration
    Task { @MainActor in
      defer {
        self.isLoadingMore = false
        // 代际不符 = 期间已整页替换（只看楼主/倒序/跳页）：footer 交给新代际的 apply。
        if generation == self.loadGeneration {
          self.list.footerState = self.hasMore ? .more : .none
        }
      }
      do {
        let page = try await TiebaThreadAPI.page(
          threadId: self.threadId,
          page: self.currentPage + 1,
          postId: nil,
          seeLz: self.seeLz,
          reverse: self.reverse
        )
        guard generation == self.loadGeneration else { return }
        self.apply(page, replacing: false, generation: generation)
      } catch {
        guard generation == self.loadGeneration else { return }
        self.pill.showResult(success: false, text: "加载失败")
      }
    }
  }

  private func jump(to page: Int) {
    guard !isLoading else { return }
    isLoading = true
    loadGeneration += 1
    let generation = loadGeneration
    Task { @MainActor in
      defer { self.isLoading = false }
      do {
        let result = try await TiebaThreadAPI.page(
          threadId: self.threadId,
          page: page,
          postId: nil,
          seeLz: self.seeLz,
          reverse: self.reverse
        )
        guard generation == self.loadGeneration else { return }
        self.apply(result, replacing: true, generation: generation)
        if result.current == page {
          self.list.scrollToTop(animated: true)
        } else {
          self.pill.showResult(success: false, text: "跳转失败")
        }
      } catch {
        guard generation == self.loadGeneration else { return }
        self.pill.showResult(success: false, text: "跳转失败")
      }
    }
  }

  /// keepMain = 只看楼主/正序倒序的"只换回复"：主贴引用与页键都不动（换页键会让
  /// 列表走整页 reload，观感像整页重新加载了一遍——用户实证）。
  private func apply(
    _ page: TiebaThreadPage,
    replacing: Bool,
    generation: Int,
    keepMain: Bool = false
  ) {
    guard generation == loadGeneration else { return }
    if replacing {
      thread = page.thread ?? thread
      // 楼主楼恒按 floor == 1 定位；倒序/只看楼主时服务端可能整页都不回吐楼主楼，
      // 那就保留上一份钉住的主贴（换掉 = 主贴卡整块消失，用户实证"切排序主贴没了"）。
      if !keepMain,
        let op = page.posts.first(where: { $0.floor == 1 }) ?? (postId == nil ? page.posts.first : nil)
      {
        mainPost = op
      }
      posts = page.posts.filter { $0.id != mainPost?.id }
    } else {
      thread = page.thread ?? thread
      // 服务端每页都会回吐楼主楼层：按 id 去重（主贴单独钉着，不进回复数组）。
      let existing = Set(posts.map(\.id))
      posts.append(contentsOf: page.posts.filter { !existing.contains($0.id) && $0.id != mainPost?.id })
      if posts.count > Self.maxPosts {
        posts = Array(posts.suffix(Self.maxPosts))
      }
    }
    currentPage = page.current
    totalPages = page.total
    hasMore = page.hasMore
    if posts.isEmpty, page.hasMore {
      hasMore = true
    }
    // 主贴是钉住的：没有回复时不能走整页空态（那会把主贴卡一起藏起来——用户
    // 实证"点只看楼主后整页变暂无回复、连主贴都没了"），只在页脚说明。
    if posts.isEmpty, mainPost == nil {
      showState(.empty)
    } else {
      showList()
      list.footerState = posts.isEmpty ? .empty : (hasMore ? .more : .none)
      publish(fresh: !keepMain)
    }
    floatingBar.configure(
      hasAgree: thread?.hasAgree ?? false,
      zanNum: thread?.zanNum ?? 0,
      isCollected: isCollected,
      palette: list.palette.base
    )
    recordVisitIfNeeded()
    if let host = parent as? TiebaRouteHostViewController { host.syncNativeScreenChrome() }
  }

  /// 行模型构建 + 两族度量（与 topic 页同流程：后台测量 → 发布页记录 → setPage）。
  override func publish(fresh: Bool) {
    if fresh {
      pageSeq += 1
      pageKey = "thread-\(threadId)-\(pageSeq)"
    }
    guard !pageKey.isEmpty else { return }
    guard lastWidth > 0 else {
      needsPublish = true
      return
    }
    let key = pageKey
    let width = lastWidth
    // 行来源 = 钉住的主贴（第 0 行）+ 回复；主贴卡与回复工具栏只挂在第 0 行上。
    let source = (mainPost.map { [$0] } ?? []) + posts
    let threadAuthorId = thread?.authorId ?? ""
    let forumName = thread?.forumName ?? ""
    let threadTitle = thread?.title ?? ""
    let mainId = mainPost?.id
    // 进帖转场的配对 id 在跨域之前算好（detached 块里不读 self）。
    let heroThreadId = threadId
    let toolbar = toolbarModel()
    let preferences = TiebaPostPreferences.load()
    let blockFilter = TiebaPostBlockFilter.load()
    let palette = list.palette.base
    let accountUid = TiebaBackgroundSnapshot.shared.uid
    let hideBlocked = TiebaPreferenceSnapshot.bool("hideBlockedContent", default: false)

    Task { @MainActor in
      let box = await Task.detached(priority: .userInitiated) { () -> (models: [TiebaPostRowModel], posts: [TiebaThreadPost]) in
        var models: [TiebaPostRowModel] = []
        var kept: [TiebaThreadPost] = []
        for (index, post) in source.enumerated() {
          let isMain = mainId.map { $0 == post.id } ?? (index == 0)
          if hideBlocked, !isMain {
            if blockFilter.isUserBlocked(uid: post.authorId, name: post.authorName) { continue }
            if blockFilter.isContentBlocked(post.plainText) { continue }
          }
          models.append(TiebaPostRowModel(
            pageKey: key,
            index: models.count,
            post: post,
            isMain: isMain,
            canDelete: !accountUid.isEmpty && post.authorId == accountUid,
            threadAuthorId: threadAuthorId,
            toolbar: isMain ? toolbar : nil,
            preferences: preferences,
            blockFilter: blockFilter,
            palette: palette,
            forumName: forumName,
            containerWidth: width,
            // 帖子页全面取消卡片：楼层靠发际线分层，横向留白全给内容。
            style: .flat,
            title: threadTitle,
            // 进帖转场的目标端：只有主贴卡参与配对（回复卡不配对，避免与
            // 列表里的行抢同一个 id）。
            heroThreadId: isMain ? heroThreadId : nil
          ))
          kept.append(post)
        }
        return (models, kept)
      }.value
      guard self.pageKey == key else { return }
      self.rowPosts = box.posts
      TiebaPostRowMetrics.shared.prepare(pageKey: key, models: box.models)
      TiebaKindRowPages.shared.publish(pageKey: key, kinds: Array(repeating: .post, count: box.models.count))
      self.list.setPage(pageKey: key)
      self.refreshMediaVisibility()
    }
  }

  private func toolbarModel() -> TiebaPostToolbarModel {
    TiebaPostToolbarModel(
      replyNum: thread?.replyNum ?? 0,
      pageLabel: totalPages > 0 ? "\(max(currentPage, 1))/\(totalPages)页" : nil,
      seeLz: seeLz,
      reverse: reverse
    )
  }

  // MARK: - 列表事件

  private func handleScroll(_ scrollView: UIScrollView) {
    floatingBar.handleScroll(scrollView)
  }

  override func handlePostEvent(_ index: Int, _ event: TiebaPostRowEvent) {
    guard rowPosts.indices.contains(index) else { return }
    let post = rowPosts[index]
    switch event {
    case .avatar:
      guard !post.authorId.isEmpty else { return }
      TiebaNavigator.shared.navigate(.user(uid: post.authorId))
    case .agree:
      toggleAgree(post)
    case .copyContent:
      TiebaSceneHaptics.fire("press")
      TiebaClipboard.setString(post.plainText.isEmpty ? "[图片/视频/音频]" : post.plainText)
      TiebaSceneHaptics.fire("action-success")
      pill.showResult(success: true, text: "已复制")
    case .share:
      share(post: post)
    case .copyLink:
      copyLink(postId: post.id)
    case .delete:
      confirmDelete(post: post)
    case .subPosts:
      openSubPosts(post)
    case .image(let mediaIndex, let rect):
      openImageBrowser(post: post, index: mediaIndex, rect: rect)
    case .link(let url):
      TiebaLinkOpener.open(url)
    case .user(let uid):
      guard !uid.isEmpty else { return }
      TiebaNavigator.shared.navigate(.user(uid: uid))
    case .toggleSeeLz:
      seeLz.toggle()
      reloadReplies()
    case .toggleSort:
      reverse.toggle()
      reloadReplies()
    }
  }

  private func handleBarAction(_ action: TiebaThreadFloatingBar.Action) {
    switch action {
    case .copyLink:
      TiebaSceneHaptics.fire("press")
      copyLink(postId: nil)
    case .agree:
      guard let thread else { return }
      agreeThread(thread)
    case .collect:
      TiebaSceneHaptics.fire("favorite")
      toggleCollect()
    case .more:
      TiebaSceneHaptics.fire("sheet-present")
      // title/forumId/forumName/isCollected 在迁移前也只是随路由携带、sheet 从未读取，
      // 类型化后不再传（sheet 实际消费的只有这四项）。
      TiebaNavigator.shared.navigate(
        .threadMore(
          id: threadId,
          canDelete: thread?.authorId == TiebaBackgroundSnapshot.shared.uid,
          seeLz: seeLz,
          reverse: reverse
        )
      )
    }
  }

  private func handleMoreAction(_ action: TiebaThreadMoreSignal.Action) {
    switch action {
    case .seeLz:
      seeLz.toggle()
      TiebaSceneHaptics.fire("toggle")
      reloadReplies()
    case .sort:
      reverse.toggle()
      TiebaSceneHaptics.fire("toggle")
      reloadReplies()
    case .jump:
      presentJumpDialog()
    case .share:
      share(post: nil)
    case .delete:
      confirmDelete(post: nil)
    }
  }

  // MARK: - 动作

  /// 收藏/取消（乐观态在服务端成功后再翻转；图片快照写收藏页缩略图 KV）。
  private func toggleCollect() {
    guard requireLogin(), runOnce("collect") else { return }
    let wasCollected = isCollected
    let firstPostId = thread?.firstPostId ?? mainPost?.id ?? threadId
    Task { @MainActor in
      defer { finishOnce("collect") }
      do {
        try await TiebaThreadActionAPI.setStore(
          threadId: threadId,
          firstPostId: firstPostId,
          store: !wasCollected
        )
        if wasCollected {
          removeFavoriteImages(threadId: threadId)
        } else {
          saveFavoriteImages(threadId: threadId)
        }
        isCollected.toggle()
        floatingBar.configure(
          hasAgree: thread?.hasAgree ?? false,
          zanNum: thread?.zanNum ?? 0,
          isCollected: isCollected,
          palette: list.palette.base
        )
        TiebaSceneHaptics.fire("action-success")
        pill.showResult(success: true, text: wasCollected ? "已取消收藏" : "已收藏")
      } catch {
        TiebaSceneHaptics.fire("action-fail")
        // 透出真实原因：LocalizedError 的文案优先；网络层错误（超时/断连）不是
        // LocalizedError，只有 localizedDescription 有内容——只读前者会让失败一律
        // 退化成兜底的"收藏失败"，查不到真因（用户 2026-09-19 复报）。
        let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let fallback = wasCollected ? "取消收藏失败" : "收藏失败"
        pill.showResult(success: false, text: detail.isEmpty ? fallback : detail)
      }
    }
  }

  private func toggleAgree(_ post: TiebaThreadPost) {
    guard requireLogin(), runOnce("agree:\(post.id)") else { return }
    let next = !post.isAgree
    patchPost(post.id) {
      $0.isAgree = next
      $0.agreeNum = max(0, $0.agreeNum + (next ? 1 : -1))
    }
    republishRow(postId: post.id)
    Task { @MainActor in
      defer { finishOnce("agree:\(post.id)") }
      do {
        try await TiebaThreadActionAPI.setAgree(
          threadId: threadId,
          postId: post.id,
          agree: next,
          objType: 1
        )
        TiebaSceneHaptics.fire("action-success")
        pill.showResult(success: true, text: next ? "点赞成功" : "已取消点赞")
      } catch {
        patchPost(post.id) {
          $0.isAgree = !next
          $0.agreeNum = max(0, $0.agreeNum + (next ? -1 : 1))
        }
        republishRow(postId: post.id)
        TiebaSceneHaptics.fire("action-fail")
        pill.showResult(success: false, text: "点赞失败，请稍后重试")
      }
    }
  }

  /// 点赞的单行重建（乐观态与失败回滚同路径）：整页 publish 会把每层楼的富文本
  /// 装配与 TextKit 测量全部重跑一遍，而点赞只改本行的 isAgree/agreeNum。
  private func republishRow(postId: String) {
    guard let index = rowPosts.firstIndex(where: { $0.id == postId }),
          let current = TiebaPostRowMetrics.shared.row(pageKey: pageKey, index: index),
          let updated = posts.first(where: { $0.id == postId })
    else { return }
    rowPosts[index] = updated
    let key = pageKey
    Task { @MainActor in
      let model = await Task.detached(priority: .userInitiated) {
        TiebaPostRowModel(replacing: current, post: updated)
      }.value
      guard self.pageKey == key else { return }
      TiebaPostRowMetrics.shared.replace(pageKey: key, index: index, model: model)
      self.list.setPage(pageKey: key)
    }
  }

  private func agreeThread(_ thread: TiebaThreadInfo) {
    guard requireLogin(), runOnce("threadAgree") else { return }
    let next = !thread.hasAgree
    var updated = thread
    updated.hasAgree = next
    updated.zanNum = max(0, updated.zanNum + (next ? 1 : -1))
    self.thread = updated
    floatingBar.configure(
      hasAgree: updated.hasAgree,
      zanNum: updated.zanNum,
      isCollected: isCollected,
      palette: list.palette.base
    )
    publish(fresh: false)
    Task { @MainActor in
      defer { finishOnce("threadAgree") }
      do {
        TiebaSceneHaptics.fire("like")
        try await TiebaThreadActionAPI.setAgree(
          threadId: threadId,
          postId: thread.firstPostId.isEmpty ? threadId : thread.firstPostId,
          agree: next,
          objType: 3
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
        var rollback = thread
        rollback.hasAgree = !next
        rollback.zanNum = max(0, rollback.zanNum + (next ? -1 : 1))
        self.thread = rollback
        floatingBar.configure(
          hasAgree: rollback.hasAgree,
          zanNum: rollback.zanNum,
          isCollected: isCollected,
          palette: list.palette.base
        )
        publish(fresh: false)
        TiebaSceneHaptics.fire("action-fail")
        pill.showResult(success: false, text: "点赞失败，请稍后重试")
      }
    }
  }

  private func patchPost(_ postId: String, _ patch: (inout TiebaThreadPost) -> Void) {
    if let index = posts.firstIndex(where: { $0.id == postId }) {
      patch(&posts[index])
    }
  }

  private func share(post: TiebaThreadPost?) {
    TiebaSceneHaptics.fire("press")
    let url = post.map { buildThreadUrl(postId: $0.id) } ?? buildThreadUrl(postId: nil)
    let content = thread?.title.isEmpty == false ? "\(thread?.title ?? "")\n\(url)" : url
    TiebaShareSheet.present(text: content, from: presenterViewController)
  }

  private func copyLink(postId: String?) {
    TiebaClipboard.setString(buildThreadUrl(postId: postId))
    TiebaSceneHaptics.fire("action-success")
    pill.showResult(success: true, text: "已复制")
  }

  private func buildThreadUrl(postId: String?) -> String {
    guard let postId, !postId.isEmpty else { return "https://tieba.baidu.com/p/\(threadId)" }
    return "https://tieba.baidu.com/p/\(threadId)?pid=\(postId)\(seeLz ? "&see_lz=1" : "")"
  }

  private func confirmDelete(post: TiebaThreadPost?) {
    let deletingThread = post == nil || post?.id == threadId || post?.id == mainPost?.id
    let alert = UIAlertController(
      title: deletingThread ? "删除帖子" : "删除回复",
      message: deletingThread ? "确定要删除这条帖子吗？" : "确定要删除这条回复吗？",
      preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(title: "取消", style: .cancel))
    alert.addAction(UIAlertAction(title: "确定", style: .destructive) { [weak self] _ in
      self?.performDelete(post: post, deletingThread: deletingThread)
    })
    presenterViewController.present(alert, animated: true)
  }

  private func performDelete(post: TiebaThreadPost?, deletingThread: Bool) {
    guard requireLogin(), runOnce("delete") else { return }
    Task { @MainActor in
      defer { finishOnce("delete") }
      do {
        try await TiebaThreadActionAPI.delete(
          threadId: threadId,
          forumId: thread?.forumId ?? "",
          forumName: thread?.forumName ?? "",
          postId: deletingThread ? nil : post?.id
        )
        TiebaSceneHaptics.fire("action-success")
        if deletingThread {
          TiebaNavigator.shared.goBack()
        } else if let post {
          posts.removeAll { $0.id == post.id }
          publish(fresh: true)
        }
      } catch {
        TiebaSceneHaptics.fire("action-fail")
        let alert = UIAlertController(title: "错误", message: "删除失败", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        presenterViewController.present(alert, animated: true)
      }
    }
  }

  private func openSubPosts(_ post: TiebaThreadPost) {
    guard !post.id.isEmpty else { return }
    TiebaNavigator.shared.navigate(
      .subposts(
        threadId: threadId,
        postId: post.id,
        forumId: thread?.forumId ?? "",
        floor: post.floor,
        threadAuthorId: thread?.authorId ?? "",
        forumName: thread?.forumName ?? "",
        threadTitle: thread?.title ?? ""
      )
    )
  }

  private func openImageBrowser(post: TiebaThreadPost, index: Int, rect: CGRect) {
    let contextTitle = post.id == mainPost?.id
      ? (thread?.title ?? "")
      : Self.floorSummary(post)
    presentImageBrowser(post: post, index: index, rect: rect, contextTitle: contextTitle)
  }

  // MARK: - 弹窗 / 顶栏

  private func presentJumpDialog() {
    let alert = UIAlertController(title: "跳转页面", message: nil, preferredStyle: .alert)
    alert.addTextField { field in
      field.keyboardType = .numberPad
      field.placeholder = self.totalPages > 0 ? "1-\(self.totalPages)" : "页码"
      field.text = String(max(self.currentPage, 1))
    }
    alert.addAction(UIAlertAction(title: "取消", style: .cancel))
    alert.addAction(UIAlertAction(title: "跳转", style: .default) { [weak self, weak alert] _ in
      guard let self else { return }
      let raw = alert?.textFields?.first?.text ?? ""
      guard let page = Int(raw.trimmingCharacters(in: .whitespaces)), page >= 1,
            self.totalPages == 0 || page <= self.totalPages
      else {
        self.pill.showResult(
          success: false,
          text: self.totalPages > 0 ? "请输入 1-\(self.totalPages) 之间的页码" : "请输入有效的页码"
        )
        return
      }
      guard page != self.currentPage else { return }
      self.jump(to: page)
    })
    presenterViewController.present(alert, animated: true)
  }

  private func forumBarItems() -> [UIBarButtonItem]? {
    guard let thread, !thread.forumName.isEmpty else { return nil }
    let label = "进入\(thread.forumName)吧"
    guard !thread.forumAvatar.isEmpty, let url = URL(string: thread.forumAvatar) else {
      // 缺吧头像：退化成通用头像符号（与原 headerRight 的 symbolItem 分支同语义）。
      let item = UIBarButtonItem(
        image: UIImage(systemName: "person.crop.circle"),
        style: .plain,
        target: nil,
        action: nil
      )
      item.accessibilityLabel = label
      item.primaryAction = UIAction { [weak self] _ in self?.openForum() }
      item.tintColor = TiebaNavigator.shared.chromeTheme.navTint
      return [item]
    }
    let item = TiebaThreadForumAvatarItem(frame: CGRect(x: 0, y: 0, width: 30, height: 30))
    let button = item.button
    button.accessibilityLabel = label
    button.load(url: url)
    button.onTap = { [weak self] in self?.openForum() }
    return [UIBarButtonItem(customView: item)]
  }

  private func openForum() {
    guard let name = thread?.forumName, !name.isEmpty else { return }
    TiebaSceneHaptics.fire("press")
    TiebaNavigator.shared.navigate(.forum(name: name, forumId: thread?.forumId ?? ""))
  }

  // MARK: - 浏览记录 / 收藏图片快照（原生 KV / SQLite，与 JS 同一份存储）

  private func recordVisitIfNeeded() {
    guard !recordedVisit, let thread, !thread.id.isEmpty else { return }
    guard !TiebaPreferenceSnapshot.bool("incognitoMode", default: false) else { return }
    recordedVisit = true
    let now = Int(Date().timeIntervalSince1970 * 1000)
    let values: [[String: Any]] = [
      ["v": "thread"], ["v": thread.id], ["v": thread.forumId],
      ["v": thread.forumName], ["v": ""], ["v": thread.title],
      ["v": thread.authorName], ["v": thread.authorPortrait], ["v": now],
    ]
    Task.detached(priority: .utility) {
      let database = TiebaSQLite.mainDatabase
      _ = try? TiebaSQLite.shared.run(
        database: database,
        sql: "DELETE FROM visit_history WHERE type = ? AND thread_id = ?",
        params: [["v": "thread"], ["v": thread.id]]
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

  private static let favoriteImagesKey = "@tiebalite:favorite_images_v1"

  private func saveFavoriteImages(threadId: String) {
    let images = (mainPost?.images ?? [])
      .map { $0.src.isEmpty ? $0.originSrc : $0.src }
      .filter { !$0.isEmpty }
      .prefix(6)
    guard !images.isEmpty else { return }
    var map = favoriteImagesMap()
    map[threadId] = Array(images)
    if map.count > 200 {
      for key in map.keys.prefix(map.count - 200) { map.removeValue(forKey: key) }
    }
    guard let data = try? JSONSerialization.data(withJSONObject: map),
          let text = String(data: data, encoding: .utf8) else { return }
    try? TiebaKvStore.shared.set(key: Self.favoriteImagesKey, value: text)
  }

  private func removeFavoriteImages(threadId: String) {
    var map = favoriteImagesMap()
    guard map[threadId] != nil else { return }
    map.removeValue(forKey: threadId)
    guard let data = try? JSONSerialization.data(withJSONObject: map),
          let text = String(data: data, encoding: .utf8) else { return }
    try? TiebaKvStore.shared.set(key: Self.favoriteImagesKey, value: text)
  }

  private func favoriteImagesMap() -> [String: [String]] {
    guard let raw = TiebaKvStore.shared.get(key: Self.favoriteImagesKey),
          let data = raw.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: [String]]
    else { return [:] }
    return object
  }
}

// MARK: - 顶栏吧头像（方形外壳：customView 被系统按条形拉伸时头像也不会变胶囊）

/// TiebaBarAvatarButton 的圆角按 init 尺寸（30/2）一次算好，栏内 customView 在
/// iOS 26 会被拉伸（宽 > 高）→ 圆角 15 < 宽/2 即药丸。外壳自己可被拉伸，但把按钮
/// 恒钉在 30×30 正方里，头像永远是正圆。
private final class TiebaThreadForumAvatarItem: UIView {
  let button = TiebaBarAvatarButton(frame: CGRect(x: 0, y: 0, width: 30, height: 30))

  override init(frame: CGRect) {
    super.init(frame: frame)
    addSubview(button)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override var intrinsicContentSize: CGSize { CGSize(width: 30, height: 30) }

  override func layoutSubviews() {
    super.layoutSubviews()
    let side: CGFloat = 30
    button.frame = CGRect(
      x: (bounds.width - side) / 2,
      y: (bounds.height - side) / 2,
      width: side,
      height: side
    )
  }
}

// MARK: - 底部浮动胶囊（原 ThreadFloatingBar：复制链接 / 帖点赞 / 收藏 / 更多）

final class TiebaThreadFloatingBar: UIView {
  enum Action {
    case copyLink
    case agree
    case collect
    case more
  }

  var onAction: ((Action) -> Void)?

  private let background = UIVisualEffectView(effect: TiebaThreadFloatingBar.makeEffect())
  private let copyButton = TiebaThreadFloatingBar.makeButton("link")
  // 点赞图标与计数分开摆（计数在图标正上方，不再画进按钮里当角标）。
  private let agreeButton = TiebaThreadFloatingBar.makeButton(nil)
  private let agreeIcon = UIImageView()
  private let agreeCount = UILabel()
  private let collectButton = TiebaThreadFloatingBar.makeButton("star")
  private let moreButton = TiebaThreadFloatingBar.makeButton("ellipsis")
  private let buttonStack = UIStackView()
  private var palette: TiebaFeedRowPalette = .default

  private var barHidden = false

  override init(frame: CGRect) {
    super.init(frame: frame)
    clipsToBounds = true
    layer.cornerRadius = 27
    layer.cornerCurve = .continuous
    background.layer.cornerRadius = 27
    background.layer.cornerCurve = .continuous
    background.clipsToBounds = true
    addSubview(background)
    // 四个按钮等宽排布（原手摆 frame 的等价）：fillEqually 的槽心 = 原 itemWidth 槽心，
    // 高度锁 44 后垂直居中，图标位置与手摆完全一致。
    buttonStack.axis = .horizontal
    buttonStack.distribution = .fillEqually
    buttonStack.alignment = .center
    for button in [copyButton, agreeButton, collectButton, moreButton] {
      button.heightAnchor.constraint(equalToConstant: 44).isActive = true
      buttonStack.addArrangedSubview(button)
    }
    addSubview(buttonStack)
    agreeIcon.contentMode = .scaleAspectFit
    agreeIcon.isUserInteractionEnabled = false
    addSubview(agreeIcon)
    agreeCount.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
    agreeCount.textAlignment = .center
    agreeCount.isUserInteractionEnabled = false
    addSubview(agreeCount)
    copyButton.addTarget(self, action: #selector(handleCopy), for: .touchUpInside)
    agreeButton.addTarget(self, action: #selector(handleAgree), for: .touchUpInside)
    collectButton.addTarget(self, action: #selector(handleCollect), for: .touchUpInside)
    moreButton.addTarget(self, action: #selector(handleMore), for: .touchUpInside)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  func configure(hasAgree: Bool, zanNum: Int, isCollected: Bool, palette: TiebaFeedRowPalette) {
    self.palette = palette
    agreeIcon.image = UIImage(
      systemName: hasAgree ? "heart.fill" : "heart",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)
    )
    agreeIcon.tintColor = hasAgree ? palette.liked : palette.text
    collectButton.setImage(UIImage(systemName: isCollected ? "star.fill" : "star"), for: .normal)
    collectButton.tintColor = isCollected ? UIColor.systemYellow : palette.text
    copyButton.tintColor = palette.text
    moreButton.tintColor = palette.text
    agreeCount.text = zanNum > 0 ? TiebaForumFormat.count(zanNum) : ""
    agreeCount.textColor = hasAgree ? palette.liked : palette.textSecondary
    setNeedsLayout()
  }

  /// 滚动自动隐藏（原 useFloatingBarAutoHide 的上下阈值 ±0.3）。
  ///
  /// ⚠️ 方向按**手指**判，而 pan 手势的 velocity 与 contentOffset 增量符号相反：
  /// 手指上滑（翻看后面的楼）⇒ velocity.y < 0，此时收起；手指下滑（往回翻）⇒
  /// velocity.y > 0，此时露出。旧 JS 判的是 contentOffset 增量（上滑为正），
  /// 原生照抄阈值时用了 pan 速度却没翻符号，方向正好是反的（2026-09-17 修）。
  func handleScroll(_ scrollView: UIScrollView) {
    let y = scrollView.contentOffset.y
    let threshold = max(scrollView.adjustedContentInset.top, 0) + 10
    if y < threshold {
      if barHidden { setBarHidden(false) }
      return
    }
    let velocity = scrollView.panGestureRecognizer.velocity(in: scrollView).y
    if velocity < -0.3, !barHidden {
      setBarHidden(true)
    } else if velocity > 0.3, barHidden {
      setBarHidden(false)
    }
  }

  private func setBarHidden(_ value: Bool) {
    barHidden = value
    let offset: CGFloat = value ? 120 : 0
    if UIAccessibility.isReduceMotionEnabled {
      transform = CGAffineTransform(translationX: 0, y: offset)
      return
    }
    UIView.animate(
      withDuration: value ? 0.18 : 0.22,
      delay: 0,
      options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction]
    ) {
      self.transform = CGAffineTransform(translationX: 0, y: offset)
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    background.frame = bounds
    // 先让 stack 落位：下面 layoutAgreeContent 读的是 agreeButton.frame（箭头/计数）。
    buttonStack.frame = bounds
    buttonStack.layoutIfNeeded()
    layoutAgreeContent()
  }

  /// 点赞计数居中在图标正上方（ThreadFloatingBar 同排布的正上方版；原为按钮右上角角标）。
  private func layoutAgreeContent() {
    let iconSide: CGFloat = 20
    let hasCount = !(agreeCount.text ?? "").isEmpty
    let countHeight = hasCount ? ceil(agreeCount.font.lineHeight) : 0
    let gap: CGFloat = hasCount ? 2 : 0
    let stackHeight = countHeight + gap + iconSide
    let top = agreeButton.frame.minY + max((agreeButton.frame.height - stackHeight) / 2, 0)
    let iconFrame = hasCount
      ? CGRect(x: agreeButton.frame.midX - iconSide / 2, y: top + countHeight + gap, width: iconSide, height: iconSide)
      : CGRect(x: agreeButton.frame.midX - iconSide / 2, y: agreeButton.frame.midY - iconSide / 2, width: iconSide, height: iconSide)
    agreeIcon.frame = iconFrame.integral
    agreeCount.isHidden = !hasCount
    if hasCount {
      agreeCount.sizeToFit()
      let width = ceil(agreeCount.bounds.width) + 2
      agreeCount.frame = CGRect(
        x: agreeButton.frame.midX - width / 2,
        y: top,
        width: width,
        height: countHeight
      )
    }
  }

  @objc private func handleCopy() { onAction?(.copyLink) }
  @objc private func handleAgree() { onAction?(.agree) }
  @objc private func handleCollect() { onAction?(.collect) }
  @objc private func handleMore() { onAction?(.more) }

  private static func makeButton(_ symbol: String?) -> UIButton {
    let button = UIButton(type: .system)
    if let symbol {
      button.setImage(
        UIImage(
          systemName: symbol,
          withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        ),
        for: .normal
      )
    }
    return button
  }

  /// 系统材质（.clear：JS 侧 glassEffectStyle="clear" 同材质；.regular 会厚
  /// 一层、胶囊显大）。iOS 26 = 液态玻璃；17 退回经典超薄材质模糊（无 tint 可挂）。
  private static func makeEffect() -> UIVisualEffect {
    if #available(iOS 26.0, *) {
      let effect = UIGlassEffect(style: .clear)
      effect.tintColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
          ? UIColor(red: 28 / 255, green: 28 / 255, blue: 30 / 255, alpha: 0.15)
          : UIColor(white: 1, alpha: 0.15)
      }
      return effect
    }
    return UIBlurEffect(style: .systemUltraThinMaterial)
  }
}
