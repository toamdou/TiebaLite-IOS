// 帖子详情 / 楼中楼两页的共享骨架（TiebaThreadViewController / TiebaSubpostsViewController）：
// 列表（TiebaKindListContentView）+ 首屏骨架 + 状态块 + toast 药丸的装配与约束、
// 生命周期、代际校验下的分页状态、媒体可见性上报、图片查看器入口、登录门卫、
// 顶栏双击回顶。数据源（接口 / 行模型 / 行事件）由子类实现——本类不碰任何接口。
import UIKit

class TiebaPostListPageController: UIViewController, UIGestureRecognizerDelegate {
  // MARK: - 共享子视图

  let list = TiebaKindListContentView()
  let stateView = UIContentUnavailableView(configuration: .loading())
  let pill = TiebaPhotoBrowserPillView()
  /// 首屏骨架（形状/数量各页不同；首次访问时按子类覆写值创建）。
  private(set) lazy var skeletonView = TiebaSkeletonList(
    variant: skeletonVariant, count: skeletonCount, style: skeletonStyle)

  // MARK: - 共享状态

  /// 发布给列表的行数据（应用 hideBlockedContent 过滤后，与行下标一一对应）。
  var rowPosts: [TiebaThreadPost] = []
  var currentPage = 1
  var hasMore = false
  var isLoading = false
  var isLoadingMore = false
  var isUserRefresh = false
  var pageKey = ""
  var pageSeq = 0
  var lastWidth: CGFloat = 0
  var needsPublish = false
  /// 上次"缺页自愈重推"的时刻（节流用）。
  private var lastRepublishAt: TimeInterval = 0
  var inFlight: Set<String> = []
  var mediaVisibleKeys: Set<String> = []
  var visibleRange: (start: Int, end: Int)?
  /// 替换式加载（reload / jump）自增的代际号；在途 loadMore 回来时代际不符即丢。
  /// 否则「只看楼主 / 倒序」替换 posts 后，旧排序页仍以 replacing:false 追加并覆盖 currentPage。
  var loadGeneration = 0

  // MARK: - 子类差异（覆写）

  var skeletonVariant: TiebaSkeletonVariant { .row }
  /// 骨架外壳形态（帖子 / 楼中楼两页覆写成 .elevated；其余页保持卡片）。
  var skeletonStyle: TiebaPostRowStyle { .card }
  /// 页面底色是否改用帖子页底色（浅色纯白 / 深色纯黑；帖子与楼中楼两页为是）。
  var pageUsesPostSurface: Bool { false }
  var skeletonCount: Int { 8 }
  /// 骨架首行内白（原各页 SkeletonList paddingTop：帖子页 12 / 楼中楼 8）。
  var skeletonInsetTop: CGFloat { 8 }
  /// 药丸停靠位（帖子页要让开底部浮动胶囊）。
  var pillBottomInset: CGFloat { 24 }
  /// 触底阈值（楼中楼页 0.5）。
  var reachEndThreshold: CGFloat { 0.3 }
  /// 空态副标题（两页文案不同）。
  var emptySecondaryText: String { "" }

  // MARK: - 生命周期

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    // 偏好/主题可能在本屏离开期间被改（设置页）：每次出现现读。
    refreshPreferences()
    applyPalette()
    applyInsets()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    installNavDoubleTapToTop()
    TiebaThreadMediaCoordinator.shared.setVisibleKeys(nil)
    if let host = parent as? TiebaRouteHostViewController { host.syncNativeScreenChrome() }
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    removeNavDoubleTapToTop()
    TiebaThreadMediaCoordinator.shared.setVisibleKeys([])
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    applyInsets()
    // 行宽契约 = 列表宽 − 2×horizontalInset（内缩含内容列居中留白）。
    let width = TiebaLayout.quantize(list.bounds.width - list.horizontalInset * 2)
    // 宽度变化（旋转/分屏）必须按新宽度重测重推：行高按精确宽度键控，旧宽度的度量
    // 会被宽度闸门拒绝、整列表退回兜底高。
    let resized = width != lastWidth && lastWidth > 0
    lastWidth = width
    if width > 0, resized || needsPublish {
      needsPublish = false
      publish(fresh: false)
    }
  }

  override func viewSafeAreaInsetsDidChange() {
    super.viewSafeAreaInsetsDidChange()
    applyInsets()
  }

  // MARK: - 装配（子类在 viewDidLoad 里调用）

  /// 共享子视图 + 约束（list/state/skeleton 全出血；pill 居中停靠）。
  func installSharedSubviews() {
    list.isHidden = true
    stateView.isHidden = true
    skeletonView.isHidden = true
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
      // Toast.tsx 的 pill 停在 bottom = insets.bottom + pillBottomInset：帖子页必须
      // 让开浮动胶囊（safeAreaBottom − 56），否则提示条会压在底栏上叠成一大块。
      pill.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -pillBottomInset),
      pill.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.82),
      pill.widthAnchor.constraint(lessThanOrEqualToConstant: TiebaLayout.floatingMaxWidth),
    ])
  }

  /// 列表事件/入场动画等两页同款的装配（子类可再补 onScroll 等）。
  func configureSharedList() {
    list.onListEvent = { [weak self] event in self?.handleListEvent(event) }
    list.onPostEvent = { [weak self] index, event in self?.handlePostEvent(index, event) }
    list.entranceAnimationEnabled = TiebaPreferenceSnapshot.bool("entranceAnimation", default: true)
    list.separatorHeight = 1
    list.reachEndThreshold = reachEndThreshold
    // 缺页自愈：本页的页记录/度量被别的屏的整页 LRU 挤掉时用同一页键重推一次
    //（数据仍在 rowPosts 里）。不重推的后果是行取不到模型——TiebaPostRowView
    // 会直接 isHidden，整行消失，看起来就是"帖子突然空白"。
    list.onPageDataMissing = { [weak self] in self?.republishCurrentPage() }
  }

  /// 同页键重推（缺页自愈出口）。列表侧已按 0.5s 节流，这里再兜一道。
  private func republishCurrentPage() {
    guard !pageKey.isEmpty, lastWidth > 0 else { return }
    let now = ProcessInfo.processInfo.systemUptime
    guard now - lastRepublishAt >= 0.5 else { return }
    lastRepublishAt = now
    publish(fresh: false)
  }

  /// 列表自带 refreshControl 且 contentInsetAdjustmentBehavior = .never：顶部内白自补。
  /// 底部内缩各页不同，由子类在 applyInsets() 里补。
  func applyBaseInsets() {
    list.contentInsetTop = view.safeAreaInsets.top
    skeletonView.contentInsets = UIEdgeInsets(
      top: view.safeAreaInsets.top + skeletonInsetTop,
      left: 0,
      bottom: 24,
      right: 0
    )
  }

  /// 页面底色 + 主题色板。卡片页底色必须用主题 background（JS colors.background
  /// #F2F2F7/黑）——.systemBackground 浅色下与卡片同白，楼层边界会糊成一片。
  /// 帖子 / 楼中楼两页反过来要**极值底色**（浅色纯白、深色纯黑）：这两页的楼层是白卡
  /// ——同一档灰的话卡与页面糊成一片，阴影也就浮不起来了。
  func applyPalette() {
    skeletonView.isDark = TiebaNavigator.shared.chromeTheme.dark
    var palette = TiebaSimpleRowPalette.default
    let tint = TiebaNavigator.shared.chromeTheme.tint
    palette.base.primary = tint
    palette.base.chip = tint.withAlphaComponent(0.12)
    palette.base.onChip = tint
    list.palette = palette
    view.backgroundColor = pageUsesPostSurface
      ? TiebaPostRowLayout.postPageSurface
      : TiebaNavigator.shared.chromeTheme.background
  }

  // MARK: - 列表事件（两页同款）

  func handleListEvent(_ event: TiebaKindListEvent) {
    switch event {
    case .reachEnd, .footerTap:
      loadMore()
    case .refreshRequested:
      isUserRefresh = true
      reload()
    case .visibleRangeChange(let start, let end, _):
      visibleRange = (start, end)
      refreshMediaVisibility()
    default:
      break
    }
  }

  /// 离屏音视频暂停（原 mediaBusStore 的 viewability 路径；两页行模型同构）。
  func refreshMediaVisibility() {
    var keys: Set<String> = []
    let range = visibleRange ?? (0, max(rowPosts.count - 1, 0))
    let indices = rowPosts.indices.filter { $0 >= range.start && $0 <= range.end }
    for model in indices.compactMap({ TiebaPostRowMetrics.shared.row(pageKey: pageKey, index: $0) }) {
      if let video = model.video, !video.src.isEmpty { keys.insert("v:\(video.src)") }
      if let audio = model.audio, !audio.src.isEmpty { keys.insert("a:\(audio.src)") }
    }
    guard keys != mediaVisibleKeys else { return }
    mediaVisibleKeys = keys
    TiebaThreadMediaCoordinator.shared.setVisibleKeys(keys)
  }

  // MARK: - 门卫 / 工具

  var isLoggedIn: Bool { !TiebaBackgroundSnapshot.shared.bduss.isEmpty }

  func requireLogin() -> Bool {
    guard isLoggedIn else {
      pill.showResult(success: false, text: "请先登录")
      TiebaNavigator.shared.navigate(.login)
      return false
    }
    return true
  }

  func runOnce(_ key: String) -> Bool {
    guard !inFlight.contains(key) else { return false }
    inFlight.insert(key)
    return true
  }

  func finishOnce(_ key: String) {
    inFlight.remove(key)
  }

  var presenterViewController: UIViewController { parent ?? self }

  /// 查看器顶栏标题：回复文字前 30 字（与旧页同规则）。
  static func floorSummary(_ post: TiebaThreadPost) -> String {
    let text = post.plainText
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return text.count > 30 ? "\(text.prefix(30))…" : text
  }

  /// 图片查看器（行模型图片值类型直构；transition 起点 = 触发图 rect）。
  func presentImageBrowser(post: TiebaThreadPost, index: Int, rect: CGRect, contextTitle: String) {
    guard let rowIndex = rowPosts.firstIndex(where: { $0.id == post.id }),
          let model = TiebaPostRowMetrics.shared.row(pageKey: pageKey, index: rowIndex)
    else { return }
    let items = model.images.compactMap {
      TiebaPhotoItem(image: $0, preferences: model.preferences)
    }
    guard !items.isEmpty else { return }
    // 页号 == 行内图片下标（仅 url 非法的条目被丢弃）；退出时按当前页现算矩形
    // （行不可见/滑出视口 → nil，框架 Fade 收尾）。
    let sourceProvider: TiebaPhotoBrowser.SourceFrameProvider = { [weak self] pageIndex in
      self?.list.postImageWindowRect(rowIndex: rowIndex, imageIndex: pageIndex)
    }
    TiebaPhotoBrowser.present(
      items: items,
      initialIndex: index,
      transition: TiebaPhotoTransition(frame: rect, contextTitle: contextTitle),
      sourceFrameProvider: sourceProvider
    )
  }

  // MARK: - 状态视图

  enum State {
    case loading
    case empty
    case error(String)
  }

  func showState(_ state: State) {
    var showsLoadingSkeleton = false
    switch state {
    case .loading:
      // 首次加载且无行：骨架（原 loading && rows.length === 0 分支）
      showsLoadingSkeleton = true
      stateView.configuration = UIContentUnavailableConfiguration.loading()
    case .empty:
      var config = UIContentUnavailableConfiguration.empty()
      config.image = UIImage(systemName: "bubble.left")
      config.text = "暂无回复"
      config.secondaryText = emptySecondaryText
      stateView.configuration = config
    case .error(let message):
      var config = UIContentUnavailableConfiguration.empty()
      config.image = UIImage(systemName: "exclamationmark.triangle")
      config.text = "加载失败"
      config.secondaryText = message
      var button = UIButton.Configuration.borderedProminent()
      button.title = "重试"
      config.button = button
      config.buttonProperties.primaryAction = UIAction { [weak self] _ in
        TiebaSceneHaptics.fire("press")
        self?.reload()
      }
      stateView.configuration = config
    }
    stateView.isHidden = showsLoadingSkeleton
    skeletonView.isHidden = !showsLoadingSkeleton
    list.isHidden = true
    applyChromeVisibility()
  }

  func showList() {
    // 行还没测量落地时不让位：整页测量在后台跑，数据到手 ≠ 行能画；提前让位就是
    // 页头/页脚先画出来、正文一片空白（用户报的"楼中楼只显示没有更多了、等一会
    // 才出内容"）。
    list.revealWhenReady { [weak self] in
      self?.stateView.isHidden = true
      self?.skeletonView.isHidden = true
      self?.list.isHidden = false
      self?.applyChromeVisibility()
    }
  }

  // MARK: - 顶栏双击回顶（设置-浏览可关）

  private weak var navDoubleTap: UITapGestureRecognizer?

  func installNavDoubleTapToTop() {
    guard navDoubleTap == nil,
          TiebaPreferenceSnapshot.bool("navBarDoubleTapToTop", default: true),
          let bar = parent?.navigationController?.navigationBar
    else { return }
    let tap = UITapGestureRecognizer(target: self, action: #selector(handleNavDoubleTap))
    tap.numberOfTapsRequired = 2
    tap.delaysTouchesBegan = false
    tap.delaysTouchesEnded = false
    tap.delegate = self
    bar.addGestureRecognizer(tap)
    navDoubleTap = tap
  }

  func removeNavDoubleTapToTop() {
    if let navDoubleTap { navDoubleTap.view?.removeGestureRecognizer(navDoubleTap) }
    navDoubleTap = nil
  }

  @objc private func handleNavDoubleTap() {
    list.scrollToTop(animated: true)
  }

  /// 顶栏双击门卫（栏内控件/左右边缘不识别）。
  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
    guard let bar = gestureRecognizer.view else { return true }
    let point = touch.location(in: bar)
    if point.x < 64 || point.x > bar.bounds.width - 64 { return false }
    var hit = bar.hitTest(point, with: nil)
    while let current = hit, current !== bar {
      if current is UIControl { return false }
      hit = current.superview
    }
    return true
  }

  // MARK: - 子类实现（本类不做数据访问）

  /// 每次出现现读偏好（如帖子页的 showShortcut）。
  func refreshPreferences() {}
  /// 各页自己的内白（底部内缩）。
  func applyInsets() {}
  func reload() {}
  func loadMore() {}
  func publish(fresh: Bool) {}
  func handlePostEvent(_ index: Int, _ event: TiebaPostRowEvent) {}
  /// 状态视图/列表切换后同步各页自己的 chrome（帖子页的浮动栏靠它显隐）。
  func applyChromeVisibility() {}
}
