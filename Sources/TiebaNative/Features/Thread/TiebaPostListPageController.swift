// 帖子详情 / 楼中楼两页的共享骨架（TiebaThreadViewController / TiebaSubpostsViewController）：
// 列表（TiebaKindListContentView）+ 首屏骨架 + 状态块 + toast 药丸的装配与约束、
// 生命周期、代际校验下的分页状态、媒体可见性上报、图片查看器入口、登录门卫。
// 数据源（接口 / 行模型 / 行事件）由子类实现——本类不碰任何接口。
//
// ⚠️ 顶栏双击回顶**不在这里**：由 UI/Chrome/TiebaNavDoubleTapToTop.swift 统一安装到
// 每根入窗导航栏（单击武装 + 400ms 判窗，绕开 iOS 27 上 numberOfTapsRequired=2
// "单击即触发"的实证缺陷）。这里原先另挂了一只 numberOfTapsRequired=2，同一根栏上
// 两个识别器互不排斥 → 一次双击触发两次回顶（且踩中上面那个缺陷）。已整层删除。
import UIKit

class TiebaPostListPageController: UIViewController {
  private var contentSizeRegistration: UITraitChangeRegistration?

  override func viewDidLoad() {
    super.viewDidLoad()
    // iOS Settings 里改字号的实时回归：只重排当前行模型/量高，不重建数据源。
    contentSizeRegistration = registerForTraitChanges([
      UITraitPreferredContentSizeCategory.self,
    ]) { (self: TiebaPostListPageController, _: UITraitCollection) in
      TiebaTypography.invalidateForSystemContentSizeCategoryChange()
      self.discardReuseMemoForAppearance()
      self.publish(fresh: true)
    }
  }

  // MARK: - 共享子视图

  let list = TiebaKindListContentView()
  let stateView = UIContentUnavailableView(configuration: .loading())
  let pill = TiebaPhotoBrowserPillView()
  /// 首屏骨架（形状/数量各页不同；首次访问时按子类覆写值创建）。
  private(set) lazy var skeletonView = TiebaSkeletonList(variant: skeletonVariant, count: skeletonCount)

  // MARK: - 共享状态

  /// 发布给列表的行数据（应用 hideBlockedContent 过滤后，与行下标一一对应）。
  var rowPosts: [TiebaThreadPost] = []
  /// 行页驱动：**页键、宽度闸门、发布序号、回主双守卫都归它**。
  /// 子类只负责「造模型 + 整页测量」（帖子行模型带页级上下文，字典还原不出来）。
  ///
  /// 懒建：前缀依赖子类自己的 id（thread-<tid> / subposts-<tid>-<pid>），
  /// 那些属性在 viewDidLoad 之后才确定；driver 自己再追加实例域与发布序号。
  private var _driver: TiebaRowPageDriver?
  var driver: TiebaRowPageDriver {
    if let driver = _driver { return driver }
    let driver = TiebaRowPageDriver(list: list, keyPrefix: driverKeyPrefix)
    _driver = driver
    return driver
  }
  /// 页键命名空间前缀（子类覆写）。
  var driverKeyPrefix: String { "post" }
  /// 当前页键。**只读镜像**：唯一写者是 driver（见 publishPrepared）。
  var pageKey: String { _driver?.pageKey ?? "" }
  var currentPage = 1
  var hasMore = false
  var isLoading = false
  var isLoadingMore = false
  var isUserRefresh = false
  var inFlight: Set<String> = []
  var mediaVisibleKeys: Set<String> = []
  var visibleRange: (start: Int, end: Int)?
  /// 替换式加载（reload / jump）自增的代际号；在途 loadMore 回来时代际不符即丢。
  /// 否则「只看楼主 / 倒序」替换 posts 后，旧排序页仍以 replacing:false 追加并覆盖 currentPage。
  var loadGeneration = 0
  /// 上一次推页时的**外观档世代**（TiebaListAppearance）。.max = 还没推过。
  ///
  /// 为什么需要它：帖子行族的度量缓存（TiebaPostRowMetrics）只按 pageKey 键控 ——
  /// 它**看不见内容身份**，也就看不见外观档。卡片↔扁平切档会改每一行的边距/圆角，
  /// 旧几何在缓存里照样"命中"，从设置页切档回来就会停在旧几何上（静默错位：
  /// 卡还缩着 10pt、发际线没有、行高多 8pt）。判据只能自己记一份。
  private var publishedAppearanceGeneration: UInt64 = .max

  /// 上一次推页时的**正文字号世代**（TiebaTypography.textGeneration）。.max = 还没推过。
  /// 正文滑杆变化会改帖子卡片/正文/回复的行盒，必须整页丢复用重测。
  private var publishedTextGeneration: UInt64 = .max
  /// 上一次推页时的**帖子标题字号世代**（TiebaTypography.titleGeneration）。
  /// 标题滑杆只改主贴标题，但当前帖子页按整页重测；关键是不能把 bodyScale
  /// 一并改掉，也不能因界面字号变化误重推。
  private var publishedTitleGeneration: UInt64 = .max

  /// 上一次推页时的「多图网格」开关（`imageGridLayout`）。nil = 还没推过。
  /// 网格会改多图块的几何（横滑带 ↔ 六宫格，行高完全不同），而模型复用判据只比
  /// 内容指纹与宽度，看不见它 —— 不自己记一份，从设置页开了开关回来整页还是横排。
  private var publishedImageGrid: Bool?

  // MARK: - 子类差异（覆写）

  var skeletonVariant: TiebaSkeletonVariant { .row }
  var skeletonCount: Int { 8 }
  /// 骨架首行内白（原各页 SkeletonList paddingTop：帖子页 12 / 楼中楼 8）。
  var skeletonInsetTop: CGFloat { 8 }
  /// 药丸停靠位（帖子页要让开底部浮动胶囊）。
  var pillBottomInset: CGFloat { 24 }
  /// 触底阈值（楼中楼页 0.5）。
  var reachEndThreshold: CGFloat { 0.3 }
  /// 空态副标题（两页文案不同）。
  var emptySecondaryText: String { "" }

  /// 外观档切档后、重推**之前**：子类在这里丢掉"上一轮模型"的复用备忘。
  /// 复用判据比的是内容指纹与宽度，看不见几何 —— 不清掉，新几何会被旧模型顶回去。
  func discardReuseMemoForAppearance() {}

  // MARK: - 生命周期

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    let textGeneration = TiebaTypography.textGeneration
    let titleGeneration = TiebaTypography.titleGeneration
    let typographyChanged =
      publishedTextGeneration != textGeneration
      || publishedTitleGeneration != titleGeneration
    let firstTypographyAppearance =
      publishedTextGeneration == .max || publishedTitleGeneration == .max
    publishedTextGeneration = textGeneration
    publishedTitleGeneration = titleGeneration

    let appearanceGeneration = TiebaListAppearance.generation
    let appearanceChanged = publishedAppearanceGeneration != appearanceGeneration
    let firstAppearance = publishedAppearanceGeneration == .max
    publishedAppearanceGeneration = appearanceGeneration

    // 首次出现只登记世代；返回本页时若外观/正文字号/标题字号/多图网格任一生效值
    // 变化，抛弃上一轮模型复用并按新测量链整页重推。
    let imageGrid = TiebaPreferenceSnapshot.bool("imageGridLayout", default: false)
    let gridChanged = publishedImageGrid != nil && publishedImageGrid != imageGrid
    publishedImageGrid = imageGrid
    if (firstAppearance == false && appearanceChanged)
      || (firstTypographyAppearance == false && typographyChanged)
      || gridChanged
    {
      discardReuseMemoForAppearance()
      publish(fresh: true)
    }
    // 偏好/主题可能在本屏离开期间被改（设置页）：每次出现现读。
    refreshPreferences()
    applyPalette()
    applyInsets()
    // inset 已按新偏好缩了，浮动栏/胶囊的显隐也必须跟着——它此前只在 showState/showList
    // 两个数据落地路径里同步过，从设置页返回时胶囊会压住末行（反向则留一条死带）。
    applyChromeVisibility()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    TiebaThreadMediaCoordinator.shared.setVisibleKeys(nil)
    if let host = parent as? TiebaRouteHostViewController { host.syncNativeScreenChrome() }
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    TiebaThreadMediaCoordinator.shared.setVisibleKeys([])
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    applyInsets()
    // 行宽契约 = 列表宽 − 2×horizontalInset（内缩含内容列居中留白）。
    let width = TiebaLayout.quantize(list.bounds.width - list.horizontalInset * 2)
    // 宽度变化（旋转/分屏）必须按新宽度重测重推：行高按精确宽度键控，旧宽度的度量
    // 会被宽度闸门拒绝（新宽度下只有可见窗口能当场同步补测，其余行等本轮重推落地）。
    // 宽度闸门与"宽度未就位就暂存"都归 driver：这里只把量化宽度交给它。
    driver.updateWidth(width)
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
    // 行间距：卡片档靠这 1pt 空隙把上下两张白卡分开；扁平档行底**自画**发际线
    //（TiebaPostRowPlan.rowHairlineFrame），再留空隙只会露出一条 1pt 页面底色的灰缝。
    list.separatorHeight = TiebaListAppearance.isFlat ? 0 : 1
    list.reachEndThreshold = reachEndThreshold
    // 缺页自愈的接线归 driver（它在 init 里装 onPageDataMissing，并用同一页键重推）。
    // 这里**不要**再装一次：后装的会顶掉 driver 那份，重推就退回"手动 publish"。
  }

  /// 同页键重推（缺页自愈出口）现在归 driver：`republishCurrentPage()` 会用它上次
  /// 存下的 prepare/land 以同页键重跑一遍。页面侧不再自己兜第二道节流 ——
  /// 列表侧的 notifyPageDataMissing 已经按同一套自适应节流（0.5s 起步、离屏取最大间隔）。

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

  /// 页面底色 + 主题色板。卡片档下楼层的边界靠"白卡浮在灰底上"，所以页面底色
  /// 必须是主题 background（#F2F2F7/黑）——.systemBackground 浅色下与卡片同白，
  /// 楼层边界会糊成一片。**扁平档反过来**：行没有卡、边界靠发际线，页面底色必须
  /// 与行同色（浅色纯白），否则行与行之间/行左右会露出一圈灰底。
  func applyPalette() {
    skeletonView.isDark = TiebaChromeTheme.current.dark
    view.backgroundColor = TiebaListAppearance.pageBackground
    var palette = TiebaSimpleRowPalette.default
    let tint = TiebaChromeTheme.current.tint
    palette.base.primary = tint
    palette.base.chip = tint.withAlphaComponent(0.12)
    palette.base.onChip = tint
    list.palette = palette
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
