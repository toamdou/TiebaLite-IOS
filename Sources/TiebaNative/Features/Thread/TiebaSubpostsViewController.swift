// 楼中楼（原 src/app/thread/[id]/subposts.tsx）：数据 TiebaThreadAPI.floor（pbFloor）。
// 视觉结构 = 固定父楼上下文摘要 + 子回复无连线列表；父楼不再占主列表第 0 行，
// 子回复用 TiebaPostRowView 的 reply role（头像列 + body 列 + 楼层徽标）渲染。
// 分页/点赞/父楼图片查看器/顶栏回顶全在原生；媒体互斥沿用 TiebaThreadMediaCoordinator。
import UIKit

final class TiebaSubpostsViewController: TiebaPostListPageController, TiebaNativeScreen {
  var screenTitle: String? {
    displayFloor.isEmpty ? "楼中楼" : "第\(displayFloor)楼"
  }
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

  /// 父楼作为固定上下文摘要，不参与主列表行排布；子回复才进入 conversation list。
  private let topBackdrop = UIView()
  private let parentHost = UIView()
  private let parentSurface = UIView()
  private let parentRow = TiebaPostRowView()
  private let groupHeaderView = UIView()
  private let contextCountLabel = UILabel()
  private let emptySurface = UIView()
  private let conversationEmptyView = UIContentUnavailableView(configuration: .empty())
  private var parentModel: TiebaPostRowModel?
  private var parentHeightConstraint: NSLayoutConstraint?
  private var parentLeadingConstraint: NSLayoutConstraint?
  private var parentTrailingConstraint: NSLayoutConstraint?
  private var groupHeaderHeightConstraint: NSLayoutConstraint?
  private var emptyLeadingConstraint: NSLayoutConstraint?
  private var emptyTrailingConstraint: NSLayoutConstraint?

  override var reachEndThreshold: CGFloat { 0.5 }
  override var emptySecondaryText: String { "成为第一个加入这场对话的人" }

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

  private func installParentContext() {
    // 顶栏/状态栏区域先铺一层不透明页面底色：列表仍可滚到父楼下方，
    // 但绝不会从透明导航栏和父楼卡片上方穿出来。
    topBackdrop.translatesAutoresizingMaskIntoConstraints = false
    topBackdrop.backgroundColor = .systemBackground
    topBackdrop.isUserInteractionEnabled = false
    view.addSubview(topBackdrop)

    parentHost.translatesAutoresizingMaskIntoConstraints = false
    parentHost.isHidden = true
    parentHost.backgroundColor = .systemBackground
    view.addSubview(parentHost)

    parentSurface.translatesAutoresizingMaskIntoConstraints = false
    // 帖子内部固定扁平：父楼只是固定在顶部的上下文，不做悬浮卡面。
    parentSurface.backgroundColor = .clear
    parentSurface.layer.cornerRadius = 0
    parentSurface.layer.cornerCurve = .continuous
    parentSurface.layer.borderWidth = 0
    parentSurface.layer.borderColor = UIColor.clear.cgColor
    parentSurface.clipsToBounds = false
    parentSurface.layer.shadowOpacity = 0
    parentSurface.layer.shadowPath = nil
    parentHost.addSubview(parentSurface)

    parentRow.translatesAutoresizingMaskIntoConstraints = false
    parentRow.onEvent = { [weak self] event in
      self?.handleParentContextEvent(event)
    }
    parentSurface.addSubview(parentRow)

    groupHeaderView.translatesAutoresizingMaskIntoConstraints = false
    groupHeaderView.backgroundColor = .systemBackground
    parentHost.addSubview(groupHeaderView)

    contextCountLabel.font = TiebaPostRowLayout.replyCountFont
    contextCountLabel.textColor = TiebaAccessibleColors.metadata
    contextCountLabel.numberOfLines = 1
    contextCountLabel.accessibilityTraits = [.header, .staticText]
    contextCountLabel.translatesAutoresizingMaskIntoConstraints = false
    groupHeaderView.addSubview(contextCountLabel)

    let height = parentHost.heightAnchor.constraint(
      equalToConstant: groupHeaderHeight + 28
    )
    let leading = parentSurface.leadingAnchor.constraint(
      equalTo: parentHost.leadingAnchor,
      constant: 12
    )
    let trailing = parentSurface.trailingAnchor.constraint(
      equalTo: parentHost.trailingAnchor,
      constant: -12
    )
    parentHeightConstraint = height
    parentLeadingConstraint = leading
    parentTrailingConstraint = trailing
    let headerHeight = groupHeaderView.heightAnchor.constraint(equalToConstant: groupHeaderHeight)
    groupHeaderHeightConstraint = headerHeight
    NSLayoutConstraint.activate([
      topBackdrop.topAnchor.constraint(equalTo: view.topAnchor),
      topBackdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      topBackdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      topBackdrop.bottomAnchor.constraint(equalTo: parentHost.topAnchor),
      parentHost.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      parentHost.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      parentHost.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      height,
      parentSurface.topAnchor.constraint(equalTo: parentHost.topAnchor, constant: 8),
      leading,
      trailing,
      parentRow.leadingAnchor.constraint(equalTo: parentSurface.leadingAnchor),
      parentRow.trailingAnchor.constraint(equalTo: parentSurface.trailingAnchor),
      parentRow.topAnchor.constraint(equalTo: parentSurface.topAnchor),
      parentRow.bottomAnchor.constraint(equalTo: parentSurface.bottomAnchor),
      groupHeaderView.topAnchor.constraint(equalTo: parentSurface.bottomAnchor, constant: 12),
      groupHeaderView.leadingAnchor.constraint(equalTo: parentHost.leadingAnchor),
      groupHeaderView.trailingAnchor.constraint(equalTo: parentHost.trailingAnchor),
      headerHeight,
      groupHeaderView.bottomAnchor.constraint(equalTo: parentHost.bottomAnchor, constant: -8),
      contextCountLabel.leadingAnchor.constraint(equalTo: parentSurface.leadingAnchor, constant: 20),
      contextCountLabel.trailingAnchor.constraint(equalTo: parentSurface.trailingAnchor, constant: -20),
      contextCountLabel.centerYAnchor.constraint(equalTo: groupHeaderView.centerYAnchor),
    ])

    emptySurface.translatesAutoresizingMaskIntoConstraints = false
    // 空态直接读在白底上；宿主保留用于布局，不再画一整块灰/白大容器。
    emptySurface.backgroundColor = .clear
    emptySurface.layer.cornerRadius = 0
    emptySurface.layer.cornerCurve = .continuous
    emptySurface.layer.borderWidth = 0
    emptySurface.layer.borderColor = UIColor.clear.cgColor
    emptySurface.clipsToBounds = false
    emptySurface.isHidden = true
    view.addSubview(emptySurface)

    var empty = UIContentUnavailableConfiguration.empty()
    empty.image = UIImage(systemName: "bubble.left.and.bubble.right")
    empty.text = "还没有楼中楼"
    empty.secondaryText = "成为第一个加入这场对话的人"
    var retry = UIButton.Configuration.filled()
    retry.title = "刷新"
    retry.baseBackgroundColor = UIColor(red: 0x0A / 255, green: 0x6C / 255, blue: 1, alpha: 1)
    retry.baseForegroundColor = .white
    empty.button = retry
    empty.buttonProperties.primaryAction = UIAction { [weak self] _ in
      TiebaSceneHaptics.fire("press")
      self?.reload()
    }
    conversationEmptyView.configuration = empty
    conversationEmptyView.backgroundColor = .clear
    conversationEmptyView.translatesAutoresizingMaskIntoConstraints = false
    emptySurface.addSubview(conversationEmptyView)

    let emptyLeading = emptySurface.leadingAnchor.constraint(
      equalTo: view.leadingAnchor,
      constant: 12
    )
    let emptyTrailing = emptySurface.trailingAnchor.constraint(
      equalTo: view.trailingAnchor,
      constant: -12
    )
    emptyLeadingConstraint = emptyLeading
    emptyTrailingConstraint = emptyTrailing
    let emptyBottom = emptySurface.bottomAnchor.constraint(
      equalTo: view.safeAreaLayoutGuide.bottomAnchor,
      constant: -24
    )
    emptyBottom.priority = .defaultHigh
    let emptyMinHeight = emptySurface.heightAnchor.constraint(greaterThanOrEqualToConstant: 220)
    emptyMinHeight.priority = .defaultHigh
    NSLayoutConstraint.activate([
      emptySurface.topAnchor.constraint(equalTo: parentHost.bottomAnchor, constant: 12),
      emptyLeading,
      emptyTrailing,
      emptyBottom,
      emptyMinHeight,
      conversationEmptyView.leadingAnchor.constraint(equalTo: emptySurface.leadingAnchor),
      conversationEmptyView.trailingAnchor.constraint(equalTo: emptySurface.trailingAnchor),
      conversationEmptyView.topAnchor.constraint(equalTo: emptySurface.topAnchor),
      conversationEmptyView.bottomAnchor.constraint(equalTo: emptySurface.bottomAnchor),
    ])
    // 固定父楼/空态/浮条都是阅读层；toast 必须始终在最上。
    view.bringSubviewToFront(pill)
  }

  /// 组头（「全部 N 条回复」）的固定行高：与 `contextCountLabel` 的行盒同一口径，
  /// 只多 6pt 上下呼吸。父楼高度约束按它算，字号档位变化后摘要不会被裁。
  private var groupHeaderHeight: CGFloat {
    ceil(TiebaPostRowLayout.replyCountFont.lineHeight) + 6
  }

  /// 父楼摘要落地：`nil` = 没有父楼（藏宿主并把高度压到 0）。
  ///
  /// 高度 = 8(上留白) + 父楼行高 + 12(间隙) + 组头高 + 8(下留白)，与
  /// `installParentContext` 里那串约束一一对应；只改约束常量、不重建视图，
  /// 所以点赞/主题切换都不会重绑父楼行。
  private func applyParentContext(model: TiebaPostRowModel?) {
    parentModel = model
    guard let model else {
      parentHost.isHidden = true
      parentHeightConstraint?.constant = 0
      return
    }
    parentHost.isHidden = false
    parentRow.apply(model: model)
    parentHeightConstraint?.constant = model.measuredHeight + groupHeaderHeight + 28
    updateGroupHeader(total: max(floorPost?.subPostNum ?? 0, subPosts.count))
  }

  /// 组头文案：服务端回吐的 `subPostNum` 与本地已收条数取大者——
  /// 分页没走完时 `subPostNum` 才是真实总数，走完了两者一致。
  private func updateGroupHeader(total: Int) {
    let text = total > 0 ? "全部 \(total) 条回复" : "暂无回复"
    if contextCountLabel.text != text {
      contextCountLabel.text = text
    }
    contextCountLabel.accessibilityLabel = text
  }

  /// 有父楼但没有楼中楼：父楼摘要继续钉在顶部，只有 conversation 区换空态。
  /// 不走 `showState(.empty)`——那是整页空态，会把父楼一起藏掉。
  private func showEmptyConversation() {
    stateView.isHidden = true
    skeletonView.isHidden = true
    list.isHidden = true
    emptySurface.isHidden = false
    applyChromeVisibility()
  }

  /// 主题变化（含跟随系统时的实时切换）→ 重取主题重刷自绘色（页面底色/列表色板/页头）。
  func screenThemeDidChange() {
    applyPalette()
    // 父楼在 list 之外，主题变化需要重建它的富文本/媒体配色，而不只是换 label 颜色。
    parentModel = nil
    // 宽度闸门与"宽度未就位就暂存"都归 driver，这里只判"已经发布过一页"。
    if pageKey.isEmpty == false {
      publish(fresh: false)
    }
  }

  override func applyPalette() {
    super.applyPalette()
    // 全部回归 systemBackground：父楼是白色 context card，子回复直接在白底
    // conversation canvas 上，层级只靠 hairline / rail / 小面积 tint。
    view.backgroundColor = .systemBackground
    list.backgroundColor = .clear
    parentHost.backgroundColor = .systemBackground
    parentSurface.backgroundColor = .clear
    parentSurface.layer.cornerRadius = 0
    parentSurface.layer.borderWidth = 0
    parentSurface.layer.borderColor = UIColor.clear.cgColor
    parentSurface.layer.shadowOpacity = 0
    parentSurface.layer.shadowPath = nil
    groupHeaderView.backgroundColor = .systemBackground
    emptySurface.backgroundColor = .clear
    emptySurface.layer.borderColor = UIColor.clear.cgColor
    if parentModel != nil {
      updateGroupHeader(total: max(floorPost?.subPostNum ?? 0, subPosts.count))
    }
  }

  // MARK: - 生命周期

  override func viewDidLoad() {
    super.viewDidLoad()
    applyPalette()
    installSharedSubviews()
    installParentContext()
    configureSharedList()
    // conversation 行自带克制 hairline；关闭 list 的卡片档行距缝隙，避免双分隔。
    list.separatorHeight = 0
    reload()
  }

  /// 列表自带 refreshControl 且 contentInsetAdjustmentBehavior = .never：顶部内白自补。
  override func applyInsets() {
    applyBaseInsets()
    let contextHeight = parentModel == nil ? 0 : (parentHeightConstraint?.constant ?? 0)
    list.contentInsetTop = view.safeAreaInsets.top
      + (contextHeight > 0 ? contextHeight + 8 : 0)
    list.contentInsetBottom = view.safeAreaInsets.bottom + 24
    let inset = list.horizontalInset + 12
    parentLeadingConstraint?.constant = inset
    parentTrailingConstraint?.constant = -inset
    emptyLeadingConstraint?.constant = inset
    emptyTrailingConstraint?.constant = -inset
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    // context 是固定 chrome 之外唯一允许的 tonal elevation；轮廓固定为 path，
    // 不让 Core Animation 每次从圆形内容重推离屏阴影。
    parentSurface.layer.shadowPath = UIBezierPath(
      roundedRect: parentSurface.bounds,
      cornerRadius: parentSurface.layer.cornerRadius
    ).cgPath
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
    if rowPosts.isEmpty {
      emptySurface.isHidden = true
      showState(.loading)
    }
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
        if self.rowPosts.isEmpty, self.parentModel == nil {
          self.emptySurface.isHidden = true
          self.showState(.error(error.localizedDescription))
        } else {
          if self.rowPosts.isEmpty {
            self.showEmptyConversation()
          }
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
      subPosts.append(contentsOf: page.subPosts.filter { existing.contains($0.id) == false })
    }
    currentPage = page.current
    hasMore = page.hasMore
    // 父楼是钉住的：没有父楼才走整页空态；有父楼但没有楼中楼时用固定上下文 +
    // conversation 空态，父楼摘要不能消失。
    if floorPost == nil, subPosts.isEmpty {
      emptySurface.isHidden = true
      parentHost.isHidden = true
      showState(.empty)
      return
    }
    emptySurface.isHidden = true
    list.footerState = subPosts.isEmpty ? .none : (hasMore ? .more : .none)
    // 只有整页替换才换页键；loadMore 同页键追加，避免重绑可见子回复。
    publish(fresh: replacing)
  }

  override var driverKeyPrefix: String { "subposts-\(threadId)-\(postId)" }

  /// 后台测量结果盒：prepare 在 detached 上写、land 在主线程读，同一 Task 内顺序 await。
  private final class PreparedSubpostsPage: @unchecked Sendable {
    var models: [TiebaPostRowModel] = []
    var posts: [TiebaThreadPost] = []
    var parent: TiebaPostRowModel?
    var identities: [TiebaRowDiff.Entry.Identity] = []
  }

  /// 行模型构建：父楼模型单独挂在固定上下文宿主上，主列表只承载子回复。
  ///
  /// 页键 / 宽度闸门 / 发布序号 / 回主守卫归 `TiebaRowPageDriver.publishPrepared`。
  override func publish(fresh: Bool) {
    let source = subPosts
    // 纯追加判据同帖子页：新行以已发布行为前缀（只比 id）⇒ 不换页键 ⇒ 不整页 reload。
    let previousIds = rowPosts.map(\.id)
    let appendOnly =
      !previousIds.isEmpty
      && source.count >= previousIds.count
      && zip(source, previousIds).allSatisfy { $0.id == $1 }
    let parentPost = floorPost
    let authorId = threadAuthorId
    let forum = forumName
    let preferences = TiebaPostPreferences.load()
    let blockFilter = TiebaPostBlockFilter.load()
    let palette = list.palette.base
    let accountUid = TiebaBackgroundSnapshot.shared.uid
    let hideBlocked = TiebaPreferenceSnapshot.bool("hideBlockedContent", default: false)
    let shouldStickToTop = list.isHidden || list.isAtTop
    let existingParent = parentModel
    let box = PreparedSubpostsPage()
    driver.publishPrepared(fresh: fresh, appendOnly: appendOnly) { key, width in
      let parentKey = "\(key)-parent"
      // 父楼模型的重建判据依赖宽度，宽度由驱动传进来。
      let rebuildParent =
        parentPost == nil
        || existingParent == nil
        || (existingParent?.containerWidth == width) == false
        || (existingParent?.post.id == parentPost?.id) == false
      var models: [TiebaPostRowModel] = []
      var kept: [TiebaThreadPost] = []
      var identities: [TiebaRowDiff.Entry.Identity] = []
      for post in source {
        if hideBlocked {
          if blockFilter.isUserBlocked(uid: post.authorId, name: post.authorName) { continue }
          if blockFilter.isContentBlocked(post.plainText) { continue }
        }
        models.append(TiebaPostRowModel(
          pageKey: key,
          index: models.count,
          post: post,
          isMain: false,
          canDelete: accountUid.isEmpty == false && post.authorId == accountUid,
          threadAuthorId: authorId,
          toolbar: nil,
          preferences: preferences,
          blockFilter: blockFilter,
          palette: palette,
          forumName: forum,
          containerWidth: width
        ))
        kept.append(post)
        identities.append(TiebaPostRowIdentity.make(post))
      }
      let parent: TiebaPostRowModel?
      if let parentPost {
        if rebuildParent {
          parent = TiebaPostRowModel(
            pageKey: parentKey,
            index: 0,
            post: parentPost,
            isMain: true,
            canDelete: false,
            threadAuthorId: authorId,
            toolbar: nil,
            preferences: preferences,
            blockFilter: blockFilter,
            palette: palette,
            forumName: forum,
            containerWidth: width,
            title: ""
          )
        } else {
          parent = existingParent
        }
      } else {
        parent = nil
      }
      box.models = models
      box.posts = kept
      box.parent = parent
      box.identities = identities
    } land: { [weak self] key in
      guard let self else { return }
      self.rowPosts = box.posts
      self.applyParentContext(model: box.parent)
      TiebaPostRowMetrics.shared.prepare(pageKey: key, models: box.models)
      if box.models.isEmpty {
        self.showEmptyConversation()
      } else {
        TiebaKindRowPages.shared.publish(
          pageKey: key,
          kinds: Array(repeating: .post, count: box.models.count)
        )
        self.list.setPage(pageKey: key, identities: box.identities)
        self.showList()
      }
      self.applyInsets()
      if shouldStickToTop {
        self.list.scrollToTop(animated: false)
      }
      self.view.setNeedsLayout()
      self.refreshMediaVisibility()
    }
  }

  // MARK: - 列表事件

  override func handlePostEvent(_ index: Int, _ event: TiebaPostRowEvent) {
    guard rowPosts.indices.contains(index) else { return }
    let post = rowPosts[index]
    switch event {
    case .avatar:
      guard post.authorId.isEmpty == false else { return }
      TiebaNavigator.shared.navigate(.user(uid: post.authorId))
    case .agree:
      toggleAgree(post, objType: 2)
    case .copyContent:
      copyContent(post)
    case .share:
      share(post: post)
    case .copyLink:
      TiebaClipboard.setString(threadURL(postId: post.id))
      TiebaSceneHaptics.fire("action-success")
      pill.showResult(success: true, text: "已复制")
    case .delete:
      // 只读客户端：保留事件兼容，无写动作。
      break
    case .subPosts:
      break
    case .image(let mediaIndex, let rect):
      openImageBrowser(post: post, index: mediaIndex, rect: rect)
    case .link(let url):
      TiebaLinkOpener.open(url)
    case .user(let uid):
      guard uid.isEmpty == false else { return }
      TiebaNavigator.shared.navigate(.user(uid: uid))
    case .toggleSeeLz, .selectSort:
      break
    }
  }

  /// 固定父楼摘要是独立的阅读上下文，事件仍走同一组语义闭包。
  private func handleParentContextEvent(_ event: TiebaPostRowEvent) {
    guard let post = floorPost else { return }
    switch event {
    case .avatar:
      guard post.authorId.isEmpty == false else { return }
      TiebaNavigator.shared.navigate(.user(uid: post.authorId))
    case .user(let uid):
      guard uid.isEmpty == false else { return }
      TiebaNavigator.shared.navigate(.user(uid: uid))
    case .agree:
      toggleAgree(post, objType: 1)
    case .copyContent:
      copyContent(post)
    case .share:
      share(post: post)
    case .copyLink:
      TiebaClipboard.setString(threadURL(postId: post.id))
      TiebaSceneHaptics.fire("action-success")
      pill.showResult(success: true, text: "已复制")
    case .image(let mediaIndex, let rect):
      openParentImageBrowser(index: mediaIndex, rect: rect)
    case .link(let url):
      TiebaLinkOpener.open(url)
    case .delete, .subPosts, .toggleSeeLz, .selectSort:
      break
    }
  }

  private func copyContent(_ post: TiebaThreadPost) {
    TiebaSceneHaptics.fire("press")
    TiebaClipboard.setString(post.plainText.isEmpty ? "[图片/视频/音频]" : post.plainText)
    TiebaSceneHaptics.fire("action-success")
    pill.showResult(success: true, text: "已复制")
  }

  // MARK: - 动作

  /// 单行重发（点赞用）：只重建这一行的模型并替换页内那一条，**不整页 publish**。
  /// 改前点赞走 publish(fresh: false)：整页行会被重新测量一遍（几十行 TextKit），
  /// 而这次改动只有红心与计数两个字段。与帖子页 republishRow 同一通道。
  private func republishChildRow(postId: String) {
    guard let visibleIndex = rowPosts.firstIndex(where: { $0.id == postId }),
      let current = TiebaPostRowMetrics.shared.row(pageKey: pageKey, index: visibleIndex),
      let updated = subPosts.first(where: { $0.id == postId })
    else { return }
    let key = pageKey
    Task { @MainActor in
      let model = await Task.detached(priority: .userInitiated) {
        TiebaPostRowModel(replacing: current, post: updated)
      }.value
      guard self.pageKey == key else { return }
      if self.rowPosts.indices.contains(visibleIndex) {
        self.rowPosts[visibleIndex] = updated
      }
      TiebaPostRowMetrics.shared.replace(pageKey: key, index: visibleIndex, model: model)
      self.list.setPage(
        pageKey: key,
        identities: self.rowPosts.map { TiebaPostRowIdentity.make($0) }
      )
    }
  }

  private func republishParentRow() {
    guard let current = parentModel, let updated = floorPost else { return }
    let key = pageKey
    Task { @MainActor in
      let model = await Task.detached(priority: .userInitiated) {
        TiebaPostRowModel(replacing: current, post: updated)
      }.value
      guard self.pageKey == key, self.floorPost?.id == updated.id else { return }
      self.applyParentContext(model: model)
      self.applyInsets()
      self.view.setNeedsLayout()
    }
  }

  private func refreshRow(postId: String) {
    if floorPost?.id == postId {
      republishParentRow()
    } else {
      republishChildRow(postId: postId)
    }
  }

  private func currentPost(id: String) -> TiebaThreadPost? {
    if let child = subPosts.first(where: { $0.id == id }) { return child }
    if let parent = floorPost, parent.id == id { return parent }
    return nil
  }

  /// 点赞：乐观翻转 + 失败回滚。父楼与子回复共用网络路径，但分别刷新固定摘要
  /// 与 conversation 行，避免父楼重建时连带重绑整页子回复。
  private func toggleAgree(_ post: TiebaThreadPost, objType: Int) {
    guard requireLogin(), runOnce("agree:\(post.id)") else { return }
    let next = post.isAgree == false
    patchPost(post.id) {
      $0.isAgree = next
      $0.agreeNum = max(0, $0.agreeNum + (next ? 1 : -1))
    }
    refreshRow(postId: post.id)
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
        if let current = self.currentPost(id: post.id), current.isAgree == next {
          self.patchPost(post.id) {
            $0.isAgree = next == false
            $0.agreeNum = max(0, $0.agreeNum + (next ? -1 : 1))
          }
          self.refreshRow(postId: post.id)
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

  private func openImageBrowser(post: TiebaThreadPost, index: Int, rect: CGRect) {
    presentImageBrowser(
      post: post,
      index: index,
      rect: rect,
      contextTitle: Self.floorSummary(post)
    )
  }

  /// 固定父楼不在 list 里，查看器来源几何直接问父楼行视图；退出时仍按该行现算。
  private func openParentImageBrowser(index: Int, rect: CGRect) {
    guard let post = floorPost, let model = parentModel else { return }
    let items = model.images.compactMap {
      TiebaPhotoItem(image: $0, preferences: model.preferences)
    }
    guard items.isEmpty == false else { return }
    let contextTitle = threadTitle.isEmpty ? Self.floorSummary(post) : threadTitle
    let source: TiebaPhotoBrowser.SourceFrameProvider = { [weak self] pageIndex in
      guard let self, let local = self.parentRow.imageRect(at: pageIndex) else { return nil }
      return self.parentRow.convert(local, to: nil)
    }
    TiebaPhotoBrowser.present(
      items: items,
      initialIndex: index,
      transition: TiebaPhotoTransition(frame: rect, contextTitle: contextTitle),
      sourceFrameProvider: source
    )
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
    item.accessibilityHint = "返回帖子详情上下文"
    item.primaryAction = UIAction { [weak self] _ in self?.openThread() }
    item.tintColor = TiebaChromeTheme.current.navTint
    return [item]
  }
}
