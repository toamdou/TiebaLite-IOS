// 楼中楼（原 src/app/thread/[id]/subposts.tsx）：数据 TiebaThreadAPI.floor（pbFloor），
// 列表 = TiebaKindListContentView 的 post 行——父楼（floorPost）是第 0 行，其后是
// 楼中楼回复；行渲染与帖子页共用同一份 TiebaPostRowView/TiebaPostRowMetrics。
// 分页/点赞/删除/图片查看器/顶栏回顶全在原生；媒体互斥 = TiebaThreadMediaCoordinator
// （原 mediaBusStore），会话/Cookie = TiebaBackgroundSnapshot（原 authStore）。
import UIKit

final class TiebaSubpostsViewController: TiebaPostListPageController, TiebaNativeScreen {
  var screenTitle: String? { "第\(displayFloor.isEmpty ? "?" : displayFloor)楼回复" }
  var screenRightBarItems: [UIBarButtonItem]? { openThreadBarItem() }

  private let threadId: String
  private let postId: String
  private let forumId: String
  private let threadAuthorId: String
  private let forumName: String
  private let threadTitle: String

  /// 父楼（pbFloor 的 floorPost；旧页 parentPostCache 的权威替代）。
  private var floorPost: TiebaThreadPost?
  private var subPosts: [TiebaThreadPost] = []
  private var displayFloor = ""

  override var reachEndThreshold: CGFloat { 0.5 }
  override var emptySecondaryText: String { "还没有楼中楼回复" }

  /// 类型化入口：floor = nil 表示楼层未知（显示「第?楼」，首包后由 floorPost.floor 补）。
  init(
    threadId: String,
    postId: String,
    forumId: String,
    floor: Int?,
    threadAuthorId: String,
    forumName: String,
    threadTitle: String
  ) {
    self.threadId = threadId
    self.postId = postId
    self.forumId = forumId
    self.displayFloor = floor.map(String.init) ?? ""
    self.threadAuthorId = threadAuthorId
    self.forumName = forumName
    self.threadTitle = threadTitle
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// 主题变化（含跟随系统时的实时切换）→ 重取主题重刷自绘色（页面底色/列表色板/页头）。
  func screenThemeDidChange() {
    applyPalette()
  }

  // MARK: - 生命周期

  override func viewDidLoad() {
    super.viewDidLoad()
    applyPalette()
    installSharedSubviews()
    configureSharedList()
    reload()
  }

  /// 列表自带 refreshControl 且 contentInsetAdjustmentBehavior = .never：顶部内白自补。
  override func applyInsets() {
    applyBaseInsets()
    list.contentInsetBottom = view.safeAreaInsets.bottom + 24
  }

  // MARK: - 数据

  override func reload() {
    guard !isLoading else {
      list.endRefreshing()
      return
    }
    guard !threadId.isEmpty, !postId.isEmpty else {
      list.endRefreshing()
      showState(.error("缺少帖子或楼层 ID"))
      return
    }
    isLoading = true
    loadGeneration += 1
    let generation = loadGeneration
    if rowPosts.isEmpty { showState(.loading) }
    Task { @MainActor in
      defer {
        self.isLoading = false
        self.isUserRefresh = false
        self.list.endRefreshing()
      }
      do {
        let page = try await TiebaThreadAPI.floor(
          threadId: self.threadId,
          postId: self.postId,
          forumId: self.forumId,
          page: 1
        )
        self.apply(page, replacing: true, generation: generation)
        if generation == self.loadGeneration, self.isUserRefresh {
          TiebaSceneHaptics.fire("toggle")
        }
      } catch {
        guard generation == self.loadGeneration else { return }
        if self.rowPosts.isEmpty {
          self.showState(.error(error.localizedDescription))
        } else {
          self.pill.showResult(success: false, text: "加载失败")
        }
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
        // 代际不符 = 期间已整页替换：footer 交给新代际的 apply。
        if generation == self.loadGeneration {
          self.list.footerState = self.hasMore ? .more : .none
        }
      }
      do {
        let page = try await TiebaThreadAPI.floor(
          threadId: self.threadId,
          postId: self.postId,
          forumId: self.forumId,
          page: self.currentPage + 1
        )
        guard generation == self.loadGeneration else { return }
        self.apply(page, replacing: false, generation: generation)
      } catch {
        guard generation == self.loadGeneration else { return }
        self.pill.showResult(success: false, text: "加载失败")
      }
    }
  }

  private func apply(_ page: TiebaThreadFloorPage, replacing: Bool, generation: Int) {
    guard generation == loadGeneration else { return }
    if replacing {
      floorPost = page.floorPost
      subPosts = page.subPosts
      if displayFloor.isEmpty, let floor = page.floorPost?.floor, floor > 0 {
        displayFloor = String(floor)
        if let host = parent as? TiebaRouteHostViewController { host.syncNativeScreenChrome() }
      }
    } else {
      // 服务端每页会回吐楼层本体：仅在本页缺父楼时补上（按 id 去重回复）。
      if floorPost == nil { floorPost = page.floorPost }
      let existing = Set(subPosts.map(\.id))
      subPosts.append(contentsOf: page.subPosts.filter { !existing.contains($0.id) })
    }
    currentPage = page.current
    hasMore = page.hasMore
    // 父楼是钉住的：没有楼中楼时只在页脚说明，不能整页空态（否则父卡也不见）。
    if subPosts.isEmpty, floorPost == nil {
      showState(.empty)
    } else {
      showList()
      list.footerState = subPosts.isEmpty ? .empty : (hasMore ? .more : .none)
      publish(fresh: true)
    }
  }

  /// 行来源：父楼在前（第 0 行），其后是楼中楼回复。
  private var sourcePosts: [TiebaThreadPost] {
    (floorPost.map { [$0] } ?? []) + subPosts
  }

  /// 行模型构建 + 后台测量（与帖子页同流程：测量 → 发布页记录 → setPage）。
  override func publish(fresh: Bool) {
    if fresh {
      pageSeq += 1
      pageKey = "subposts-\(threadId)-\(postId)-\(pageSeq)"
    }
    guard !pageKey.isEmpty else { return }
    guard lastWidth > 0 else {
      needsPublish = true
      return
    }
    let key = pageKey
    let width = lastWidth
    let source = sourcePosts
    let parentId = floorPost?.id
    let authorId = threadAuthorId
    let forum = forumName
    let preferences = TiebaPostPreferences.load()
    let blockFilter = TiebaPostBlockFilter.load()
    let palette = list.palette.base
    // 楼中楼页的两级视觉（原 SubpostViews.tsx）：父楼 = 卡片（JS ParentReplyCard
    // 走 secondarySystemGroupedBackground），楼中楼行 = **无卡片**（JS 楼中楼行容器
    // 去底色/圆角，只靠行距分隔）。两边都画白卡时就分不出主回复与楼中楼（用户反馈）。
    let flatPalette: TiebaFeedRowPalette = {
      var flat = palette
      flat.card = TiebaNavigator.shared.chromeTheme.background
      flat.borderCard = .clear
      return flat
    }()
    let accountUid = TiebaBackgroundSnapshot.shared.uid
    let hideBlocked = TiebaPreferenceSnapshot.bool("hideBlockedContent", default: false)

    Task { @MainActor in
      let box = await Task.detached(priority: .userInitiated) { () -> (models: [TiebaPostRowModel], posts: [TiebaThreadPost]) in
        var models: [TiebaPostRowModel] = []
        var kept: [TiebaThreadPost] = []
        for post in source {
          let isParent = parentId != nil && post.id == parentId
          if hideBlocked, !isParent {
            if blockFilter.isUserBlocked(uid: post.authorId, name: post.authorName) { continue }
            if blockFilter.isContentBlocked(post.plainText) { continue }
          }
          models.append(TiebaPostRowModel(
            pageKey: key,
            index: models.count,
            post: post,
            isMain: isParent,
            // 旧页父卡无删除入口；回复的删除仅在本人时提供。
            canDelete: !isParent && !accountUid.isEmpty && post.authorId == accountUid,
            threadAuthorId: authorId,
            toolbar: nil,
            preferences: preferences,
            blockFilter: blockFilter,
            palette: isParent ? palette : flatPalette,
            forumName: forum,
            containerWidth: width
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

  // MARK: - 列表事件

  override func handlePostEvent(_ index: Int, _ event: TiebaPostRowEvent) {
    guard rowPosts.indices.contains(index) else { return }
    let post = rowPosts[index]
    let isParent = index == 0 && floorPost?.id == post.id
    switch event {
    case .avatar:
      guard !post.authorId.isEmpty else { return }
      TiebaNavigator.shared.navigate(.user(uid: post.authorId))
    case .agree:
      toggleAgree(post, objType: isParent ? 1 : 2)
    case .copyContent:
      TiebaSceneHaptics.fire("press")
      TiebaClipboard.setString(post.plainText.isEmpty ? "[图片/视频/音频]" : post.plainText)
      TiebaSceneHaptics.fire("action-success")
      pill.showResult(success: true, text: "已复制")
    case .share:
      share(post: post)
    case .copyLink:
      TiebaClipboard.setString(threadURL(postId: post.id))
      TiebaSceneHaptics.fire("action-success")
      pill.showResult(success: true, text: "已复制")
    case .delete:
      guard !isParent else { return }
      confirmDelete(post)
    case .subPosts:
      break // 已在楼中楼页：父楼的预览行不再跳转。
    case .image(let mediaIndex, let rect):
      openImageBrowser(post: post, index: mediaIndex, rect: rect, isParent: isParent)
    case .link(let url):
      TiebaLinkOpener.open(url)
    case .user(let uid):
      guard !uid.isEmpty else { return }
      TiebaNavigator.shared.navigate(.user(uid: uid))
    case .toggleSeeLz, .selectSort:
      break
    }
  }

  // MARK: - 动作

  /// 点赞：乐观翻转 + 失败回滚（旧页 agreeInFlightRef 的在途守卫同义）。
  private func toggleAgree(_ post: TiebaThreadPost, objType: Int) {
    guard requireLogin(), runOnce("agree:\(post.id)") else { return }
    let next = !post.isAgree
    patchPost(post.id) {
      $0.isAgree = next
      $0.agreeNum = max(0, $0.agreeNum + (next ? 1 : -1))
    }
    publish(fresh: false)
    Task { @MainActor in
      defer { finishOnce("agree:\(post.id)") }
      do {
        try await TiebaThreadActionAPI.setAgree(
          threadId: threadId,
          postId: post.id,
          agree: next,
          objType: objType
        )
        TiebaSceneHaptics.fire("action-success")
        pill.showResult(success: true, text: next ? "点赞成功" : "已取消点赞")
      } catch {
        // 回滚仅当当前态仍等于本次乐观写入（期间的刷新/其它路径改写过就跳过）。
        if let current = subPosts.first(where: { $0.id == post.id }), current.isAgree == next {
          patchPost(post.id) {
            $0.isAgree = !next
            $0.agreeNum = max(0, $0.agreeNum + (next ? -1 : 1))
          }
          publish(fresh: false)
        }
        TiebaSceneHaptics.fire("action-fail")
        pill.showResult(success: false, text: "点赞失败，请稍后重试")
      }
    }
  }

  private func patchPost(_ postId: String, _ patch: (inout TiebaThreadPost) -> Void) {
    if let index = subPosts.firstIndex(where: { $0.id == postId }) {
      patch(&subPosts[index])
    } else if var parent = floorPost, parent.id == postId {
      patch(&parent)
      floorPost = parent
    }
  }

  private func confirmDelete(_ post: TiebaThreadPost) {
    let alert = UIAlertController(title: "删除回复", message: "确定要删除这条回复吗？", preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "取消", style: .cancel))
    alert.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
      self?.performDelete(post)
    })
    presenterViewController.present(alert, animated: true)
  }

  private func performDelete(_ post: TiebaThreadPost) {
    guard requireLogin(), runOnce("delete:\(post.id)") else { return }
    Task { @MainActor in
      defer { finishOnce("delete:\(post.id)") }
      do {
        try await TiebaThreadActionAPI.deleteReply(
          threadId: threadId,
          forumId: forumId,
          forumName: forumName,
          postId: post.id
        )
        subPosts.removeAll { $0.id == post.id }
        TiebaSceneHaptics.fire("action-success")
        publish(fresh: true)
      } catch {
        TiebaSceneHaptics.fire("action-fail")
        let alert = UIAlertController(title: "错误", message: "删除失败", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        presenterViewController.present(alert, animated: true)
      }
    }
  }

  private func share(post: TiebaThreadPost) {
    TiebaSceneHaptics.fire("press")
    let url = threadURL(postId: post.id)
    let content = threadTitle.isEmpty ? url : "\(threadTitle)\n\(url)"
    TiebaShareSheet.present(text: content, from: presenterViewController)
  }

  private func threadURL(postId: String) -> String {
    postId.isEmpty
      ? "https://tieba.baidu.com/p/\(threadId)"
      : "https://tieba.baidu.com/p/\(threadId)?pid=\(postId)"
  }

  private func openImageBrowser(post: TiebaThreadPost, index: Int, rect: CGRect, isParent: Bool) {
    let contextTitle = isParent && !threadTitle.isEmpty
      ? threadTitle
      : Self.floorSummary(post)
    presentImageBrowser(post: post, index: index, rect: rect, contextTitle: contextTitle)
  }

  private func openThread() {
    guard !threadId.isEmpty else { return }
    TiebaSceneHaptics.fire("press")
    TiebaNavigator.shared.navigate(.thread(id: threadId))
  }

  // MARK: - 顶栏

  private func openThreadBarItem() -> [UIBarButtonItem]? {
    guard !threadId.isEmpty else { return nil }
    let item = UIBarButtonItem(
      image: UIImage(systemName: "doc.text"),
      style: .plain,
      target: nil,
      action: nil
    )
    item.accessibilityLabel = "打开原帖"
    item.primaryAction = UIAction { [weak self] _ in self?.openThread() }
    item.tintColor = TiebaNavigator.shared.chromeTheme.navTint
    return [item]
  }
}
