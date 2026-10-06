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
  /// 回复排序（三档：热门/正序/倒序）。默认热门——服务端三档里热门是"按热度看帖"
  /// 最常用的入口，正/倒序是浏览顺序。
  private var sort: TiebaThreadSort = .hot
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
  /// 上一轮 publish 的模型 + 行指纹（键 = post id）：行内容未变的行直接复用
  /// 模型实例——feed 族有 isSameRaw 逐行复用，post 族此前每次 publish 都全量
  /// 重造整页（触底加载 400 楼全部重测，后台数百 ms 与滚动抢 CPU）。
  private var lastPublishedModels: [TiebaPostRowModel] = []
  private var lastPublishedFingerprints: [String: String] = [:]
  private var lastPublishedWidth: CGFloat = 0
  private var lastPublishedToolbar = ""
  /// 显示设置（现读偏好；布局路径不重复查 KV）。
  private var showShortcut = true

  override var skeletonVariant: TiebaSkeletonVariant { .post }
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
    self.sort = (fromFavorites && collectDescSort) ? .desc : .hot
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
    // C1：松手落点若停在"顶部静止位往下 8pt"之内，直接落到静止位。
    // 移植自上游 submodules/ScrollComponent/Sources/ScrollComponent.swift:100-105（contentOffsetWillCommit）：
    // 本页两处判据都是"是否已在顶部"——浮动栏的 y < contentInset.top + 10 与回顶刷新的
    // isAtTop——落点差几 pt 就会"内容看着到顶了、状态却没到"。8pt 是吸合带宽，只朝顶部生效。
    list.contentOffsetWillCommit = { scrollView, target in
      let top = -scrollView.adjustedContentInset.top
      if target.y > top, target.y - top <= 8 {
        target.y = top
      }
    }
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
        // 期间被更新的代际（切排序/切只看楼主）接管：它自己收尾 isLoading。
        if generation == self.loadGeneration { self.isLoading = false }
        self.isUserRefresh = false
        self.list.endRefreshing()
      }
      do {
        let page = try await TiebaThreadAPI.page(
          threadId: self.threadId,
          page: 1,
          postId: self.postId,
          seeLz: self.seeLz,
          sort: self.sort
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

  /// 只看楼主 / 排序：只重取回复（主贴卡与工具栏整块不动，也不出现骨架）。
  /// 与 reload() 的区别只有两点：keepMain（不覆盖钉住的主贴）与不换页键。
  private func reloadReplies() {
    // 点了就换：作废在飞的旧请求（代际自增）而不是被 isLoading 挡回去——挡回去的话
    // 药丸已显示新档位、列表还是上一次的内容（用户实证"残留切换前的内容"）。
    loadGeneration += 1
    let generation = loadGeneration
    isLoading = true
    // 换档要等一次服务端往返（~1.3s）：期间挂个 spinner 药丸，否则点完界面毫无反应
    //（用户实证"没有加载动画"）。
    pill.show(text: "正在加载", progress: nil)
    Task { @MainActor in
      defer {
        if generation == self.loadGeneration { self.isLoading = false }
        self.isUserRefresh = false
        self.list.endRefreshing()
      }
      do {
        let page = try await TiebaThreadAPI.page(
          threadId: self.threadId,
          page: 1,
          postId: nil,
          seeLz: self.seeLz,
          sort: self.sort
        )
        self.apply(page, replacing: true, generation: generation, keepMain: true)
        if generation == self.loadGeneration { self.pill.hide() }
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
          sort: self.sort
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
      defer {
        if generation == self.loadGeneration { self.isLoading = false }
      }
      do {
        let result = try await TiebaThreadAPI.page(
          threadId: self.threadId,
          page: page,
          postId: nil,
          seeLz: self.seeLz,
          sort: self.sort
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
    var trimmed = false
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
        // 裁尾丢头会整体前移既有行下标，而快照标识是位置身份 (pageKey#index)：必须视同
        // 整页替换（换页键重测），否则屏上 cell 还显旧楼、行内事件已指向别的楼。
        trimmed = true
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
      // ⚠️ 只有"整页替换"才换页键。loadMore 是**追加**：换键 = 快照里所有
      // item 标识 (pageKey#index) 全变 → TiebaKindListView 走 applySnapshotUsingReloadData，
      // 可见楼层 cell 全部回收重建（每行 UITextView 全文重排 10-30ms、图片请求重发、
      // 可见 GIF 从第 0 帧重播、滚动位置可能弹动）。
      // 同页键 + 行数变化走的是另一条路（TiebaKindListView.setPage 的 isSamePage 分支）：
      // diff 追加 + 可见行重配 → 页码等行内内容照样刷新，但 cell 不重建。
      publish(fresh: (replacing && !keepMain) || trimmed)
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
    // 行复用输入：上一轮模型/指纹 + 宽度/工具栏（变化即全量重造）。
    // 工具栏指纹**不含页码**：翻页只刷工具栏，见下面 toolbarFingerprint 的注释。
    let previousById = Dictionary(
      lastPublishedModels.map { ($0.post.id, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    let previousFingerprints = lastPublishedFingerprints
    let previousWidth = lastPublishedWidth
    let previousToolbar = lastPublishedToolbar
    // 页码**不进**指纹：翻页只改工具栏那行文案，主贴行的行高/plan/正文都不变。
    // 进了指纹就是每翻一页把主贴卡重建 + 重测一次（正文一次完整 CoreText 排版）。
    let toolbarFingerprint = "\(toolbar.replyNum)|\(toolbar.seeLz)|\(toolbar.sort.rawValue)"

    Task { @MainActor in
      // 离屏（被 push 盖住 / 还没上屏）时降档 .utility：与 TiebaRowPageDriver 同判据——
      // 用户看不见的页没必要和滚动抢 CPU（改前一律 .userInitiated）。
      let measurementPriority: TaskPriority = view.window == nil ? .utility : .userInitiated
      let box = await Task.detached(priority: measurementPriority) { () -> (models: [TiebaPostRowModel], posts: [TiebaThreadPost]) in
        var models: [TiebaPostRowModel] = []
        var kept: [TiebaThreadPost] = []
        for (index, post) in source.enumerated() {
          let isMain = mainId.map { $0 == post.id } ?? (index == 0)
          if hideBlocked, !isMain {
            if blockFilter.isUserBlocked(uid: post.authorId, name: post.authorName) { continue }
            if blockFilter.isContentBlocked(post.plainText) { continue }
          }
          // 未变行复用：同一 id、行指纹相同、宽度与主贴工具栏未变 → 上一份模型
          // 原样复用（emoji 升级缓存/plan/测量全部继承，零重测）。
          if width == previousWidth,
             let prev = previousById[post.id],
             previousFingerprints[post.id] == Self.postFingerprint(post),
             (!isMain || toolbarFingerprint == previousToolbar)
          {
            models.append(prev)
            kept.append(post)
            continue
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
      self.lastPublishedModels = box.models
      self.lastPublishedFingerprints = Dictionary(
        uniqueKeysWithValues: box.posts.map { ($0.id, Self.postFingerprint($0)) }
      )
      self.lastPublishedWidth = width
      self.lastPublishedToolbar = toolbarFingerprint
      // 复用主贴行时把新页码就地写回模型：主贴行沿用同一实例，行视图的 apply 会按身份
      // 提前返回，页码只能走「就地更新 + 只刷工具栏」；写回放在 MainActor 上，
      // 避免后台测量线程去动行视图已经持有的模型。
      if let main = box.models.first(where: { $0.isMain }) { main.updateToolbar(toolbar) }
      TiebaPostRowMetrics.shared.prepare(pageKey: key, models: box.models)
      TiebaKindRowPages.shared.publish(pageKey: key, kinds: Array(repeating: .post, count: box.models.count))
      self.list.setPage(pageKey: key)
      // 主贴行（下标 0）的模型实例没换，重配时 apply 直接返回 —— 页码必须显式只刷工具栏，
      // 否则翻页后工具栏还停在上一个页码。
      self.list.refreshToolbar(index: 0)
      self.refreshMediaVisibility()
    }
  }

  /// 行模型输入指纹：作者族 + 计数 + 内容段数/纯文本/图片档。不逐字段 Equatable
  /// （content 枚举带关联值），这些键覆盖行视图消费的一切。
  nonisolated private static func postFingerprint(_ post: TiebaThreadPost) -> String {
    var images = ""
    for segment in post.content {
      if case .image(let img) = segment {
        images += "|\(img.src)|\(img.bigSrc)|\(img.originSrc)|\(img.width)|\(img.height)"
      }
    }
    return "\(post.id)|\(post.floor)|\(post.authorId)|\(post.authorName)|\(post.authorNameShow)|\(post.authorPortrait)|\(post.authorLevel)|\(post.authorLevelName)|\(post.ipLocation)|\(post.createTimeMs)|\(post.agreeNum)|\(post.isAgree)|\(post.subPostNum)|\(post.content.count)|\(images)|\(post.plainText)"
  }

  private func toolbarModel() -> TiebaPostToolbarModel {
    TiebaPostToolbarModel(
      replyNum: thread?.replyNum ?? 0,
      pageLabel: totalPages > 0 ? "\(max(currentPage, 1))/\(totalPages)页" : nil,
      seeLz: seeLz,
      sort: sort
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
    case .selectSort(let next):
      guard next != sort else { return }
      sort = next
      TiebaSceneHaptics.fire("toggle")
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
          sort: sort
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
    case .selectSort(let next):
      guard next != sort else { return }
      sort = next
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

  /// 帖级写操作的 post_id（帖级点赞 / 收藏的锚点）：**必须是首楼的 post id，不能是
  /// 帖子 id**。`thread.firstPostId` 不可信——服务端不回 ThreadInfo.first_post_id(40)
  /// 时映射层会拿**帖子 id** 顶上（TiebaThreadAPI 的兜底），拿它当 post_id 发出去
  /// 服务端按"该楼层不存在"回错，表现就是"点收藏永远失败"（旧 JS/Kotlin 传的都是
  /// 首楼 id：旧页 firstPostId = pinnedMainPost.id，Kotlin = 可见楼 id）。
  private var firstFloorPostId: String {
    if let id = mainPost?.id, !id.isEmpty { return id }
    let fromThread = thread?.firstPostId ?? ""
    // 与帖子 id 相同即可断定那是映射层的兜底值，不是真首楼 id。
    return (fromThread.isEmpty || fromThread == threadId) ? "" : fromThread
  }

  /// 收藏/取消：**乐观翻转 + 失败回滚**（先翻星标、先弹提示，不等网络）。
  /// 图片快照（收藏页缩略图 KV）仍在服务端确认后才写——那写的是本地缓存，
  /// 失败时留在里面等于把"没收藏成功"的帖子塞进收藏页。
  private func toggleCollect() {
    guard requireLogin(), runOnce("collect") else { return }
    let wasCollected = isCollected
    let next = !wasCollected
    applyCollectedState(next)
    pill.showResult(success: true, text: next ? "已收藏" : "已取消收藏")
    Task { @MainActor in
      defer { finishOnce("collect") }
      do {
        try await TiebaThreadActionAPI.setStore(
          threadId: threadId,
          firstPostId: firstFloorPostId,
          store: next
        )
        if next {
          saveFavoriteImages(threadId: threadId)
        } else {
          removeFavoriteImages(threadId: threadId)
        }
        TiebaSceneHaptics.fire("action-success")
      } catch {
        applyCollectedState(wasCollected)
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

  /// 收藏态落 UI（乐观写入与失败回滚**同一份**）：isCollected + 浮条星标。
  private func applyCollectedState(_ value: Bool) {
    isCollected = value
    floatingBar.configure(
      hasAgree: thread?.hasAgree ?? false,
      zanNum: thread?.zanNum ?? 0,
      isCollected: value,
      palette: list.palette.base
    )
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
          let updated = sourcePost(id: postId)
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
    // 触觉在**触摸回调里同步发**（改前在下面的 Task 体内：主 actor 调度一跳才振，
    // 且排在乐观更新之后——主线程正忙时这一跳就是可感的延迟）。
    TiebaSceneHaptics.fire("like")
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
    // 行内容不读 thread.hasAgree/zanNum（浮条是唯一显示面，已在上面 configure），
    // 此前这里的 publish 会触发整页重发布：可见行逐行重贴 attributedText（每个
    // UITextView 一次全文排版，主线程 10-30ms 一卡）——两处 publish 全删。
    Task { @MainActor in
      defer { finishOnce("threadAgree") }
      do {
        try await TiebaThreadActionAPI.setAgree(
          threadId: threadId,
          // 拿不到首楼 id 时退回帖子 id（旧 JS 同判据 `firstPostId || id`；帖子页
          // 几乎恒有 mainPost，这条只是兜底）。
          postId: firstFloorPostId.isEmpty ? threadId : firstFloorPostId,
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
        TiebaSceneHaptics.fire("action-fail")
        pill.showResult(success: false, text: "点赞失败，请稍后重试")
      }
    }
  }

  /// 按 id 取当前楼：主贴钉在 mainPost、回复在 posts。
  /// 主贴被排除出 posts（第 0 行单独发布），只查一个集合会让主贴的乐观更新、
  /// 失败回滚、单行重建三条链路一起空转（点红心不动、失败也不回滚）。
  private func sourcePost(id: String) -> TiebaThreadPost? {
    if let parent = mainPost, parent.id == id { return parent }
    return posts.first { $0.id == id }
  }

  private func patchPost(_ postId: String, _ patch: (inout TiebaThreadPost) -> Void) {
    if let index = posts.firstIndex(where: { $0.id == postId }) {
      patch(&posts[index])
    } else if var parent = mainPost, parent.id == postId {
      patch(&parent)
      mainPost = parent
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
        // 热门档服务端不回楼层号（floor=0）：传 nil 让楼中楼页显示"第?楼"，
        // 首包后由 floorPost.floor 补——传 0 会顶栏固定成"第0楼回复"（用户实证）。
        floor: post.floor > 0 ? post.floor : nil,
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
    // 数据没落地时用快照（点卡片进帖必写）：否则首包前右侧是空的，首包一到吧按钮
    // 才"突然"出现（用户实证）。深链无快照时仍等首包。
    let forumName = thread?.forumName ?? knownSnapshot?.forumName ?? ""
    guard !forumName.isEmpty else { return nil }
    let label = "进入\(forumName)吧"
    let avatar = thread?.forumAvatar ?? knownSnapshot?.forumAvatarURL?.absoluteString ?? ""
    guard !avatar.isEmpty, let url = URL(string: avatar) else {
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
    let name = thread?.forumName ?? knownSnapshot?.forumName ?? ""
    guard !name.isEmpty else { return }
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

  /// 浮动栏底色：纯色卡片色 + 一点阴影（原 JS 的液态玻璃 .clear 太花，用户要求
  /// 照系统浮动条的观感来：实底、轻微投影）。
  private let background = UIView()
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
  /// 滚动方向门：累积 ΔY > 14pt 才翻转（上游 ListView.swift:1023-1029），见 TiebaScrollDirectionGate。
  private var scrollDirectionGate = TiebaScrollDirectionGate()

  override init(frame: CGRect) {
    super.init(frame: frame)
    // 不自裁：投影画在本层，圆角由 background 自己裁（子视图都在界内）。
    clipsToBounds = false
    layer.cornerRadius = 27
    layer.cornerCurve = .continuous
    layer.shadowColor = UIColor.black.cgColor
    layer.shadowOpacity = 0.10
    layer.shadowRadius = 8
    layer.shadowOffset = CGSize(width: 0, height: 2)
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
    // 帖子详情的点赞数（正文级）：等宽数字保留，字号随正文字号走。
    agreeCount.font = TiebaFont.with(
      size: 11 * TiebaTypography.bodyScale(), weight: .semibold, traits: .monospacedNumbers)
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
    background.backgroundColor = palette.card
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
  ///
  /// [按上游改判据] 改前是**瞬时 pan 速度 ±0.3pt/s** —— 0.3pt/s 等于"凡动必判"，
  /// 手指抖一下浮条就翻一次（0.3 这个数只起了"非零"的作用）。
  /// 改后走上游的**累积位移**判据：带符号 ΔY 累加，越过 14.0pt 才翻方向
  ///（submodules/Display/Source/ListView.swift:1023-1029，见 TiebaScrollDirectionGate）。
  /// 手感变化：显隐**更稳、更可预期** —— 轻轻抖不再切换；真的要往下看/往回翻时才收放，
  /// 且同方向连读滚动只翻转一次（累加清零），不再每帧重判。
  func handleScroll(_ scrollView: UIScrollView) {
    let y = scrollView.contentOffset.y
    let threshold = max(scrollView.adjustedContentInset.top, 0) + 10
    if y < threshold {
      if barHidden { setBarHidden(false) }
      // 回顶 = 位置被外力重置，累加量作废（否则回顶那一大段位移会被算成一次翻转）。
      scrollDirectionGate.reset()
      return
    }
    guard let direction = scrollDirectionGate.update(contentOffsetY: y) else { return }
    switch direction {
    case .forward:
      if !barHidden { setBarHidden(true) }
    case .backward:
      if barHidden { setBarHidden(false) }
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
    // 投影轮廓按实际尺寸给（没有它 Core Animation 每帧从图层内容算轮廓）。
    layer.shadowPath = UIBezierPath(
      roundedRect: bounds,
      cornerRadius: layer.cornerRadius
    ).cgPath
    // 先让 stack 落位：下面 layoutAgreeContent 读的是 agreeButton.frame（箭头/计数）。
    buttonStack.frame = bounds
    buttonStack.layoutIfNeeded()
    layoutAgreeContent()
  }

  /// 点赞计数绝对定位在图标正上方；图标**恒钉按钮垂直中心**。
  /// 改前症状：计数+图标整组垂直居中 ⇒ 计数从无到有使组高变化，心形图标被往下推约 7.5pt
  ///（首楼点赞 0→1 的瞬间像误触抖动）。
  /// 改后行为：图标位置与计数有无无关（与同排其它三键一致），计数固定在图标上方 2pt，只做显隐。
  private func layoutAgreeContent() {
    let iconSide: CGFloat = 20
    let hasCount = !(agreeCount.text ?? "").isEmpty
    agreeIcon.frame = CGRect(
      x: agreeButton.frame.midX - iconSide / 2,
      y: agreeButton.frame.midY - iconSide / 2,
      width: iconSide,
      height: iconSide
    ).integral
    agreeCount.isHidden = !hasCount
    if hasCount {
      agreeCount.sizeToFit()
      let countHeight = ceil(agreeCount.font.lineHeight)
      let width = ceil(agreeCount.bounds.width) + 2
      agreeCount.frame = CGRect(
        x: agreeButton.frame.midX - width / 2,
        y: agreeIcon.frame.minY - 2 - countHeight,
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
}
