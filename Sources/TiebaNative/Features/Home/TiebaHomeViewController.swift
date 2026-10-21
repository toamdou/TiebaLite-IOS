// 动效接线：签到完成 → UI/Nodes/TiebaConfettiView 彩带（见 handleSignStateChange）；
// 加载/空/错态一律走 TiebaStateContentView，转圈是系统 UIActivityIndicatorView；
// 2026-10-05（报告 32 §1.1）：状态不再用「藏列表 + 显示 stateView」两套视图轮流占位，
//   改成列表里的一个 item（TiebaHomeStateCell 承载），列表始终可见 ⇒ 空/错态下也能下拉刷新。
//
// 「关注」tab 根屏（原 src/app/(tabs)/index.tsx）：顶栏（头像/搜索胶囊/一键签到/
// 排序切换）+ 最近访问药丸行 + 关注吧列表（单列/双列、长按取关、下拉刷新）。
// 数据：TiebaFollowedForums（forumGuide）+ 统一 SQLite 的 visit_history；
// 签到走 TiebaSignService（原生批量 msign）。
import UIKit

final class TiebaHomeViewController: UIViewController, TiebaTabReselectable {
  enum SortMode: String {
    case level
    case name
  }

  /// 排序偏好：共享偏好只读，页面自持一份（JS 侧 forumSortMode 的写入方
  /// index.tsx 已删，本键只剩本页消费）；page-private 键落盘，重启保持。
  static let sortKey = "@tiebalite:native_home_sort_mode_v1"

  // 顶栏
  private let avatarControl = UIControl()
  private let avatarView = TiebaForumAvatarView(size: 38)
  private let signedOutAvatarGlyph = UIImageView()
  /// 搜索入口 = 玻璃按钮（放大镜 + 占位文字）：与签到/排序同一形态，不再是
  /// 「平底输入框 + 外层 control」的三层 hack。
  private let searchButton = UIButton(type: .system)
  private let signButton = UIButton(type: .system)
  private let sortButton = UIButton(type: .system)
  /// C3（报告 37）：顶栏三块玻璃的 iPad 指针高亮 —— 实例必须强引用（UIPointerInteraction.delegate 是 weak）。
  private var topBarPointers: [TiebaPointerInteraction] = []
  private var topBarTraitRegistration: UITraitChangeRegistration?
  // 最近访问
  private let historyHeader = UIView()
  private let historyTitle = UILabel()
  private let historyToggle = UIButton(type: .system)
  private let historyScroll = UIScrollView()
  private let historyStack = UIStackView()
  private var historyHeight: NSLayoutConstraint?
  private var historyHeaderHeight: NSLayoutConstraint?
  // 列表
  let layout = UICollectionViewFlowLayout()
  private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
  private let stateView = TiebaStateContentView()
  private let welcomeView = TiebaHomeWelcomeView()
  /// 空/加载/错误/未登录都做成**列表里的一项**（报告 31 §一-1）：列表因此始终可见，
  /// 下拉刷新、滚动回弹、键盘 inset 与有内容时共用同一条管线，不再靠隐藏列表切换。
  static let stateItemID = "__tieba_home_state__"
  private var activeState: TiebaState?
  private let refreshControl = UIRefreshControl()
  private let pill = TiebaPhotoBrowserPillView()

  private var forums: [TiebaForumInfo] = []
  var displayedForums: [TiebaForumInfo] = []
  private var recentForums: [RecentForum] = []
  private var historyExpanded = true
  var sortMode: SortMode = .level  // 放宽：拆分后 TiebaHomeViewController+Part.swift 也要读写它（35 号 §4 纪律：只放宽被跨文件引用的那一处）
  private var isSingleColumn = true
  private var isLoading = false
  private var isUserRefresh = false
  private var hasLoadedOnce = false
  /// 上次成功拉列表所属的签到自然日：跨天后即使本页一直活着也要重拉（见
  /// TiebaFollowedForums.today —— 勾号与"全部已签到"都按天失效）。
  private var loadedDay = ""
  private var entranceDone = false
  var entrancePending = false
  /// 首个布局趟的清标志已排程（入场批次边界，见 willDisplay）。
  var entranceClearScheduled = false
  var dataSource: UICollectionViewDiffableDataSource<String, String>?
  /// 签到成功的彩带（UI/Nodes/TiebaConfettiView）：播完自己 removeFromSuperview。
  private var signConfetti: TiebaConfettiView?
  /// 上一拍是否在签到中：只抓「进行中 → 结束」这一拍撒彩带。
  private var wasSigning = false
  /// 本次签到是否已经庆祝过（取消/重试的重复回调在这里去重）。
  private var didCelebrateSign = false
  /// B5（报告 37）：签到飞行体 —— 每个签成功的吧把它的吧头像从列表行吸进顶栏签到圆钮。
  /// 源在 cell 里（受裁剪/会复用）、目标在顶栏玻璃容器里，两边都住不下飞行体，
  /// 所以它跑在 window 级的穿透覆盖容器上（见 UI/Overlay/TiebaFlightTransition.swift）。
  private var signFlights: [TiebaFlightTransition] = []
  /// 已经飞过的吧：进度回调每个吧都会来一次，靠这张账只飞一次；一轮签到结束清账。
  private var flownSignForumIds: Set<String> = []
  /// B6①：列表内容位移的差分基准（scrollViewDidScroll 逐帧用）。
  var lastListOffsetY: CGFloat = 0
  /// B6②：列表容器在 window 里的原点基准（"最近访问"展开/收起会整体挪它）。
  private var lastListWindowOrigin: CGPoint?
  /// C4（报告 37）：栏的"额外高度" = **分数 × 内容高度**，不是 isHidden 两态开关。
  /// 载体 = 本仓既有的 TiebaApparentHeight（视觉高度/布局高度解耦，与 TiebaFeedRowView 的
  /// 折叠同一条约定）：布局高度恒等于最近访问区的内容高度，视觉高度由 0..1 的分数派生；
  /// 动画期间药丸行**按完整高度摆好**、超出部分由滚动视图裁掉（内容不重排）。
  private var historyContentHeight: CGFloat {
    let labelLine = ceil(TiebaSimpleText.font(size: 13, weight: .medium).lineHeight)
    return max(44, labelLine + 8)
  }
  private var historyApparentHeight = TiebaApparentHeight(layoutHeight: 44)
  private var historyStackHeightConstraint: NSLayoutConstraint?
  private var historyFraction: CGFloat = 0
  private var historyAnimator: TiebaDisplayLinkAnimator?
  private var lastAppliedLoginState: Bool?
  /// 首个同步**不播动画**（首屏数据落地时的高度与改前逐值相同，只是此后不再是硬切）。
  private var historyFractionSynced = false

  private struct RecentForum {
    var forumName = ""
    var forumId = ""
    var avatar = ""
  }

  private var isLoggedIn: Bool { TiebaUserAPI.isLoggedIn }
  /// 通知观察者 token 是非 Sendable，而 deinit 默认非隔离 —— 这里用 isolated deinit
  ///（编译器保证 deinit 跑在主 actor 上），所以不需要 nonisolated(unsafe) 去绕过检查。
  private var sessionObserver: NSObjectProtocol?
  /// 偏好广播订阅（设置页改在屏键即时生效，见 viewDidLoad）。
  private var prefToken: NSObjectProtocol?

  isolated deinit {
    if let sessionObserver { NotificationCenter.default.removeObserver(sessionObserver) }
    if let prefToken { NotificationCenter.default.removeObserver(prefToken) }
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    // 页面底一律 systemBackground：扁平档直接成白色信息流；卡片档也只有
    // systemBackground 卡 + hairline，不再用分组灰铺底。
    view.backgroundColor = .systemBackground
    sortMode = loadSortMode()
    isSingleColumn = TiebaPreferenceSnapshot.bool("forumListSingle", default: true)
    let topBar = buildTopBar()
    buildHistoryRow(below: topBar)
    buildList()
    TiebaSignService.shared.onStateChange = { [weak self] in
      guard let self else { return }
      self.applySignButton()
      self.handleSignStateChange()
    }
    TiebaSignService.shared.onFinished = { [weak self] in
      guard let self else { return }
      // 签到结果已经写进 store 的内存列表（TiebaSignService 末尾的 markSigned）：
      // 就地换一份，**别再 invalidate + force 全量重拉** —— 那是一次签到最多 20 个
      // forumGuide 请求 + 一次整表重编码，而勾号本来就是本地已知的。等级/经验这类
      // 服务端增量，交给下一次下拉刷新或内存 TTL 到期后的自然刷新。
      if let list = TiebaFollowedForums.currentSnapshot() {
        self.forums = list
        self.loadedDay = TiebaFollowedForums.today()
        self.applyList()
      } else {
        self.loadFollowedForums(force: true)
      }
    }
    // 登录/登出会清关注吧缓存（TiebaSession.activate/logout → invalidate）：本页必须
    // 跟着重拉。否则登录完成时本页还停在"未登录"的空态，要先去别的 tab 转一圈才出列表
    //（用户实证：登录后切到「关注」还是空白）。
    sessionObserver = NotificationCenter.default.addObserver(
      forName: TiebaSession.didChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      TiebaUserAPI.refreshLoginSnapshot()
      hasLoadedOnce = false
      applyLoginState(animated: true)
      loadFollowedForums(force: true)
      loadRecentForums()
      applySignButton()
    }
    // 设置页改这两个键时本页可能就在屏/在栈里：订阅广播即时生效（列表列数、
    // 历史吧行不等到下次 viewWillAppear）。
    prefToken = TiebaPreferenceChange.observe(
      keys: ["forumListSingle", "homePageShowHistoryForum", TiebaListAppearance.key]
    ) { [weak self] in
      // 这个闭包本身就在主 actor 隔离域里（非 Sendable 闭包继承外层隔离），
      // broadcast 又是 queue: .main 投递的，所以不需要 assumeIsolated 断言。
      guard let self else { return }
      self.isSingleColumn = TiebaPreferenceSnapshot.bool("forumListSingle", default: true)
      // 外观档（设置 → 个性化 → 设计风格）切换：底色 / 外边距 / 行距 / 行底发际线
      // 一起换，换档不做跨档动画（直接整表重配，见 48 号 §3.3）。
      self.applyAppearance()
      self.loadRecentForums()
    }
    pill.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(pill)
    NSLayoutConstraint.activate([
      pill.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      pill.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
      pill.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.82),
      pill.widthAnchor.constraint(lessThanOrEqualToConstant: TiebaLayout.floatingMaxWidth),
    ])
    applyLoginState()
    topBarTraitRegistration = registerForTraitChanges([
      UITraitPreferredContentSizeCategory.self,
      UITraitAccessibilityContrast.self,
    ]) {
      (controller: TiebaHomeViewController, _: UITraitCollection) in
      controller.updateTopBarTypography()
      controller.updateHistoryMetricsForContentSize()
      controller.updateLayoutMetrics()
      controller.applyList()
      controller.collectionView.collectionViewLayout.invalidateLayout()
    }
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    TiebaUserAPI.refreshLoginSnapshot()
    // 每次出现现读偏好（设置页可能刚改过）与登录态。
    isSingleColumn = TiebaPreferenceSnapshot.bool("forumListSingle", default: true)
    updateLayoutMetrics()
    applyLoginState()
    // 跨天（昨天挂后台、今天回来）：强制重拉，别让昨天的勾号活到今天。
    let dayChanged = TiebaFollowedForums.today() != loadedDay
    loadFollowedForums(force: dayChanged)
    loadRecentForums()
    applySignButton()
  }

  /// 底栏重复点击：重拉关注列表（原 TAB_RESELECT_EVENT 'index' 分支）。
  func tabReselected() {
    loadFollowedForums(force: true)
  }

  // MARK: - 顶栏

  /// 玻璃按钮的极轻着色：透明材质在纯白底上仍能看出边界与层次。
  private static let glassSurfaceTint = UIColor { trait in
    if trait.accessibilityContrast == .high {
      return trait.userInterfaceStyle == .dark
        ? UIColor.white.withAlphaComponent(0.14)
        : UIColor.black.withAlphaComponent(0.08)
    }
    return trait.userInterfaceStyle == .dark
      ? UIColor.white.withAlphaComponent(0.07)
      : UIColor.black.withAlphaComponent(0.035)
  }

  @discardableResult
  private func buildTopBar() -> UIStackView {
    avatarView.translatesAutoresizingMaskIntoConstraints = false
    avatarView.isUserInteractionEnabled = false
    avatarControl.addSubview(avatarView)
    signedOutAvatarGlyph.image = UIImage(
      systemName: "person.crop.circle",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 25, weight: .regular)
    )
    signedOutAvatarGlyph.tintColor = TiebaHomeAccessibleColor.secondaryText
    signedOutAvatarGlyph.contentMode = .scaleAspectFit
    signedOutAvatarGlyph.isUserInteractionEnabled = false
    signedOutAvatarGlyph.translatesAutoresizingMaskIntoConstraints = false
    avatarControl.addSubview(signedOutAvatarGlyph)
    avatarControl.isAccessibilityElement = true
    avatarControl.accessibilityTraits = .button
    avatarControl.addAction(UIAction { [weak self] _ in self?.handleAvatarTap() }, for: .touchUpInside)
    NSLayoutConstraint.activate([
      avatarView.centerXAnchor.constraint(equalTo: avatarControl.centerXAnchor),
      avatarView.centerYAnchor.constraint(equalTo: avatarControl.centerYAnchor),
      avatarView.widthAnchor.constraint(equalToConstant: 38),
      avatarView.heightAnchor.constraint(equalToConstant: 38),
      signedOutAvatarGlyph.centerXAnchor.constraint(equalTo: avatarControl.centerXAnchor),
      signedOutAvatarGlyph.centerYAnchor.constraint(equalTo: avatarControl.centerYAnchor),
      signedOutAvatarGlyph.widthAnchor.constraint(equalToConstant: 28),
      signedOutAvatarGlyph.heightAnchor.constraint(equalToConstant: 28),
      avatarControl.widthAnchor.constraint(equalToConstant: 44),
      avatarControl.heightAnchor.constraint(equalToConstant: 44),
    ])

    // 搜索入口：玻璃胶囊按钮，放大镜 + 占位文字左对齐铺满剩余宽度。
    // iOS 26 玻璃；17 退回经典 gray（其余属性逐项不变）。
    var search: UIButton.Configuration = if #available(iOS 26.0, *) { .glass() } else { .gray() }
    search.image = UIImage(
      systemName: "magnifyingglass",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)
    )
    search.title = "搜吧、搜贴、搜人"
    search.baseForegroundColor = TiebaHomeAccessibleColor.secondaryText
    search.cornerStyle = .capsule
    search.background.backgroundColor = Self.glassSurfaceTint
    search.imagePadding = 8
    search.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 12)
    search.titleLineBreakMode = .byTruncatingTail
    search.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
      var outgoing = incoming
      outgoing.font = TiebaSimpleText.font(size: 14, weight: .regular)
      return outgoing
    }
    searchButton.configuration = search
    searchButton.contentHorizontalAlignment = .leading
    searchButton.accessibilityLabel = "搜索贴吧、帖子或用户"
    searchButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
    searchButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    searchButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
    searchButton.addAction(UIAction { _ in
      TiebaSceneHaptics.fire("press")
      TiebaNavigator.shared.navigate(.search())
    }, for: .touchUpInside)

    for button in [signButton, sortButton] {
      // 原 JS = clear 玻璃圆钮：iOS 26 玻璃；17 退回经典 gray（圆钮/尺寸不变）。
      var config: UIButton.Configuration = if #available(iOS 26.0, *) { .glass() } else { .gray() }
      config.cornerStyle = .capsule
      config.background.backgroundColor = Self.glassSurfaceTint
      button.configuration = config
      button.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        button.widthAnchor.constraint(equalToConstant: 44),
        button.heightAnchor.constraint(equalToConstant: 44),
      ])
    }
    signButton.addAction(UIAction { [weak self] _ in self?.handleSignTap() }, for: .touchUpInside)
    sortButton.addAction(UIAction { [weak self] _ in self?.handleSortTap() }, for: .touchUpInside)
    // 玻璃件的高光边与极轻投影：纯白底上仍能看见材质边界，但不加灰色描边。
    for button in [searchButton, signButton, sortButton] {
      button.layer.cornerRadius = 22
      button.layer.cornerCurve = .continuous
      button.layer.borderWidth = 0.5
      button.layer.borderColor = UIColor.white.withAlphaComponent(0.34).cgColor
      button.layer.shadowColor = UIColor.black.cgColor
      button.layer.shadowOpacity = 0.055
      button.layer.shadowRadius = 10
      button.layer.shadowOffset = CGSize(width: 0, height: 4)
    }
    for control in [avatarControl, searchButton, signButton, sortButton] as [UIControl] {
      installPressFeedback(on: control)
    }
    applySignButton()

    // C3（报告 37）：iPad + 触控板/妙控鼠标悬停时给这三块玻璃一圈高亮（与吧页 FAB、查看器圆钮
    // 同一档）。搜索胶囊是宽的 ⇒ 用 .default 的「命中区外扩」档；两颗圆钮取长边 ⇒ .circle(nil)。
    // 报告 40 的第 4 个落点（列表段头按钮 TiebaListSectionHeaderNode）已随零调用方清理删除，
    // 这里换成**每次进 App 必达**的顶栏重建。
    topBarPointers = [
      TiebaPointerInteraction(view: searchButton),
      TiebaPointerInteraction(view: signButton, style: .circle(nil)),
      TiebaPointerInteraction(view: sortButton, style: .circle(nil)),
    ]

    updateTopBarTypography()
    let row = UIStackView(arrangedSubviews: [avatarControl, searchButton, signButton, sortButton])
    row.axis = .horizontal
    row.alignment = .center
    row.spacing = 10
    row.translatesAutoresizingMaskIntoConstraints = false

    // A1（报告 37 第一优先）：这一行里有**三块各自独立**的玻璃（搜索胶囊 + 签到圆钮 + 排序圆钮，
    // 间距 8pt），改前各挂各的 ⇒ 永远是几块分开的矩形，靠近也不互相牵引。
    // 改后放进同一个 UIGlassContainerEffect 容器：容器自己没有材质、不参与渲染，
    // spacing 取上游默认 7.0 < 8pt 间距 ⇒ **稳态观感一字不变**，只有它们靠近到 7pt 以内
    //（动画中、布局挤压时）才开始"液态融合"。整行几何与改前完全一致（同一组约束值）。
    let glassHost = TiebaGlassContainerView()
    glassHost.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(glassHost)
    glassHost.contentView.addSubview(row)
    NSLayoutConstraint.activate([
      glassHost.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
      glassHost.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
      glassHost.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6),
      glassHost.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
      // 行**钉在容器上**（不是 contentView）：contentView 的 frame 由 UIVisualEffectView 自己管，
      // 引用它的 anchor 会把行宽绑到 UIKit 的内部布局上；钉容器则与改前的几何逐值相同。
      row.leadingAnchor.constraint(equalTo: glassHost.leadingAnchor),
      row.trailingAnchor.constraint(equalTo: glassHost.trailingAnchor),
      row.topAnchor.constraint(equalTo: glassHost.topAnchor),
      row.bottomAnchor.constraint(equalTo: glassHost.bottomAnchor),
    ])
    return row
  }

  private func applySignButton() {
    let signing = TiebaSignService.shared.isSigning
    var sign = signButton.configuration ?? .gray()
    sign.image = UIImage(
      systemName: signing ? "checkmark.seal.fill" : "checkmark.seal",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)
    )
    sign.baseForegroundColor = signing ? TiebaChromeTheme.current.tint : TiebaHomeAccessibleColor.secondaryText
    signButton.configuration = sign
    signButton.accessibilityLabel = "一键签到"
    var sort = sortButton.configuration ?? .gray()
    sort.image = UIImage(
      systemName: sortMode == .level ? "arrow.up.arrow.down" : "textformat.abc",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)
    )
    sort.baseForegroundColor = TiebaHomeAccessibleColor.secondaryText
    sortButton.configuration = sort
    sortButton.isEnabled = isLoggedIn
    sortButton.accessibilityLabel = sortMode == .level ? "按等级排序" : "按名称排序"
  }

  private func installPressFeedback(on control: UIControl) {
    control.addAction(UIAction { [weak self, weak control] _ in
      self?.setControlPressed(control, pressed: true)
    }, for: .touchDown)
    for event in [UIControl.Event.touchUpInside, .touchUpOutside, .touchCancel] {
      control.addAction(UIAction { [weak self, weak control] _ in
        self?.setControlPressed(control, pressed: false)
      }, for: event)
    }
  }

  private func setControlPressed(_ control: UIControl?, pressed: Bool) {
    guard let control else { return }
    let apply = {
      control.transform = pressed ? CGAffineTransform(scaleX: 0.94, y: 0.94) : .identity
    }
    guard UIAccessibility.isReduceMotionEnabled == false else {
      apply()
      return
    }
    TiebaAnimation.animate(
      curve: .easeOut,
      duration: TiebaAnimationDuration.microFeedback,
      options: [.beginFromCurrentState, .allowUserInteraction],
      animations: apply
    )
  }

  /// 顶栏文字/命中区随 AX 字号切换：标准字号保留完整搜索占位，AX 用短标签避免固定高度裁切。
  /// 所有按钮的实际命中高度 ≥44；搜索按钮与玻璃容器由 intrinsic height 自然增高。
  private func updateTopBarTypography() {
    let accessibility = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
    let fallbackConfiguration: UIButton.Configuration =
      if #available(iOS 26.0, *) { .glass() } else { .gray() }
    var search = searchButton.configuration ?? fallbackConfiguration
    search.title = accessibility ? "搜索" : "搜吧、搜贴、搜人"
    search.image = accessibility
      ? nil
      : UIImage(
          systemName: "magnifyingglass",
          withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        )
    search.titleLineBreakMode = .byTruncatingTail
    search.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
      var outgoing = incoming
      outgoing.font = TiebaSimpleText.font(size: 14, weight: .regular)
      return outgoing
    }
    searchButton.configuration = search
    searchButton.invalidateIntrinsicContentSize()
    applySignButton()
    view.setNeedsLayout()
  }

  private func updateHistoryMetricsForContentSize() {
    historyTitle.font = TiebaSimpleText.font(size: 15, weight: .semibold)
    historyHeaderHeight?.constant = historyHeader.isHidden ? 0 : historyHeaderTargetHeight
    var toggle = historyToggle.configuration ?? .plain()
    toggle.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
      var outgoing = incoming
      outgoing.font = TiebaSimpleText.font(size: 15, weight: .semibold)
      return outgoing
    }
    historyToggle.configuration = toggle
    let newHeight = historyContentHeight
    historyStackHeightConstraint?.constant = newHeight
    historyApparentHeight.setLayoutHeight(newHeight)
    applyHistoryFraction(historyFraction)
    view.setNeedsLayout()
  }

  // MARK: - 最近访问

  private func buildHistoryRow(below topBar: UIStackView) {
    historyTitle.text = "最近访问"
    historyTitle.font = TiebaSimpleText.font(size: 15, weight: .semibold)
    historyTitle.adjustsFontForContentSizeCategory = true
    historyTitle.numberOfLines = 1
    var toggle = UIButton.Configuration.plain()
    toggle.image = UIImage(systemName: "chevron.up")
    toggle.imagePadding = 4
    toggle.baseForegroundColor = TiebaHomeAccessibleColor.brandForeground
    toggle.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 8, bottom: 10, trailing: 8)
    toggle.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
      var outgoing = incoming
      outgoing.font = TiebaSimpleText.font(size: 15, weight: .semibold)
      return outgoing
    }
    historyToggle.configuration = toggle
    historyToggle.addAction(UIAction { [weak self] _ in self?.toggleHistory() }, for: .touchUpInside)
    let headerStack = UIStackView(arrangedSubviews: [historyTitle, UIView(), historyToggle])
    headerStack.axis = .horizontal
    headerStack.alignment = .center
    headerStack.translatesAutoresizingMaskIntoConstraints = false
    historyHeader.addSubview(headerStack)
    historyHeader.translatesAutoresizingMaskIntoConstraints = false

    historyScroll.translatesAutoresizingMaskIntoConstraints = false
    historyScroll.showsHorizontalScrollIndicator = false
    historyScroll.contentInset = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
    historyStack.axis = .horizontal
    historyStack.spacing = 8
    historyStack.alignment = .center
    historyStack.translatesAutoresizingMaskIntoConstraints = false
    historyScroll.addSubview(historyStack)

    view.addSubview(historyHeader)
    view.addSubview(historyScroll)
    let height = historyScroll.heightAnchor.constraint(equalToConstant: 0)
    historyHeight = height
    let headerHeight = historyHeader.heightAnchor.constraint(equalToConstant: 0)
    historyHeaderHeight = headerHeight
    let stackHeight = historyStack.heightAnchor.constraint(equalToConstant: historyContentHeight)
    historyStackHeightConstraint = stackHeight
    NSLayoutConstraint.activate([
      historyHeader.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
      historyHeader.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
      historyHeader.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 4),
      headerHeight,
      headerStack.leadingAnchor.constraint(equalTo: historyHeader.leadingAnchor),
      headerStack.trailingAnchor.constraint(equalTo: historyHeader.trailingAnchor),
      headerStack.topAnchor.constraint(equalTo: historyHeader.topAnchor),
      headerStack.bottomAnchor.constraint(equalTo: historyHeader.bottomAnchor),
      historyScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      historyScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      historyScroll.topAnchor.constraint(equalTo: historyHeader.bottomAnchor),
      height,
      historyStack.leadingAnchor.constraint(equalTo: historyScroll.contentLayoutGuide.leadingAnchor),
      historyStack.trailingAnchor.constraint(equalTo: historyScroll.contentLayoutGuide.trailingAnchor),
      historyStack.topAnchor.constraint(equalTo: historyScroll.contentLayoutGuide.topAnchor),
      historyStack.bottomAnchor.constraint(equalTo: historyScroll.contentLayoutGuide.bottomAnchor),
      // C4：内容按**完整高度**摆好（不跟动画中的容器高度走）⇒ 动画期间药丸行不重排、不被压扁。
      stackHeight,
      historyToggle.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
    ])
    historyHeader.isHidden = true
    historyScroll.isHidden = true
  }

  private func toggleHistory() {
    historyExpanded.toggle()
    TiebaSceneHaptics.fire("toggle")
    updateHistoryVisibility()
  }

  private var historyHeaderTargetHeight: CGFloat {
    max(44, ceil(historyTitle.font.lineHeight) + 24)
  }

  private func updateHistoryVisibility() {
    let show = TiebaPreferenceSnapshot.bool("homePageShowHistoryForum", default: true)
      && recentForums.isEmpty == false
    historyHeader.isHidden = show == false
    historyHeaderHeight?.constant = show ? historyHeaderTargetHeight : 0
    // C4：容器高度由**一个分数**派生（show && historyExpanded → 1/0），不再写死 34/0 两态。
    animateHistoryFraction(to: (show && historyExpanded) ? 1 : 0)
    updateHistoryToggle()
  }

  private func updateHistoryToggle() {
    let apply = {
      var toggle = self.historyToggle.configuration ?? .plain()
      toggle.image = UIImage(systemName: self.historyExpanded ? "chevron.up" : "chevron.down")
      toggle.title = self.historyExpanded ? "收起" : "展开"
      self.historyToggle.configuration = toggle
    }
    guard view.window != nil, UIAccessibility.isReduceMotionEnabled == false else {
      apply()
      return
    }
    UIView.transition(
      with: historyToggle,
      duration: TiebaAnimationDuration.stateChange,
      options: [.transitionCrossDissolve, .allowUserInteraction],
      animations: apply
    )
  }

  /// C4：把 0..1 的分数动画到目标值（逐帧回调走本仓唯一的 CADisplayLink 驱动）。
  /// 分数是**唯一**输入：容器高度、内容可见性都由它派生 —— 与上游导航栏
  /// `secondaryContentNodeDisplayFraction` 的四项测量同构。
  private func animateHistoryFraction(to target: CGFloat) {
    historyAnimator?.invalidate()
    historyAnimator = nil
    let target = min(max(target, 0), 1)
    guard historyFractionSynced else {
      historyFractionSynced = true
      applyHistoryFraction(target)
      return
    }
    guard target != historyFraction else {
      applyHistoryFraction(target)
      return
    }
    guard UIAccessibility.isReduceMotionEnabled == false else {
      applyHistoryFraction(target)
      return
    }
    let start = historyFraction
    historyApparentHeight.beginTransition(to: historyContentHeight)
    // DisplayLink 只给 0..1 时间进度；这里再映射到仓库既有 close 弹簧阻尼曲线。
    historyAnimator = TiebaDisplayLinkAnimator(
      duration: TiebaAnimationDuration.springMass,
      from: 0,
      to: 1,
      update: { [weak self] progress in
        guard let self else { return }
        let eased = Self.historyDampedProgress(progress)
        self.applyHistoryFraction(start + (target - start) * eased)
      },
      completion: { [weak self] in
        guard let self else { return }
        self.historyAnimator = nil
        self.applyHistoryFraction(target)
        self.historyApparentHeight.finishTransition()
      }
    )
  }

  /// 分数 → 额外高度；内容同步做交叉淡入与 3pt 上移，展开/收起都不硬切。
  private func applyHistoryFraction(_ fraction: CGFloat) {
    let clamped = min(max(fraction, 0), 1)
    historyFraction = clamped
    historyApparentHeight.setLayoutHeight(historyContentHeight)
    historyApparentHeight.setApparentHeight(historyContentHeight * clamped)
    historyHeight?.constant = historyApparentHeight.apparentHeight
    let fade = min(max(clamped / 0.72, 0), 1)
    let smooth = fade * fade * (3 - 2 * fade)
    let hidden = clamped <= 0.001
    historyScroll.isHidden = hidden
    historyScroll.alpha = hidden ? 0 : smooth
    historyScroll.transform = CGAffineTransform(translationX: 0, y: hidden ? 3 : (1 - smooth) * 3)
    view.setNeedsLayout()
  }

  private static func historyDampedProgress(_ progress: CGFloat) -> CGFloat {
    let mass = Double(TiebaMotionSpec.Spring.closeMass)
    let stiffness = Double(TiebaMotionSpec.Spring.closeStiffness)
    let damping = Double(TiebaMotionSpec.Spring.closeDamping)
    let zeta = damping / (2 * sqrt(stiffness * mass))
    let omega0 = sqrt(stiffness / mass)
    let omegaD = omega0 * sqrt(1 - zeta * zeta)
    let t = Double(min(max(progress, 0), 1)) * TiebaAnimationDuration.springMass
    let oscillation = cos(omegaD * t) + (zeta * omega0 / omegaD) * sin(omegaD * t)
    let value = 1 - exp(-zeta * omega0 * t) * oscillation
    return CGFloat(min(max(value, 0), 1))
  }

  private func loadRecentForums() {
    // 原 JS 只在已登录分支渲染最近访问：未登录态不出药丸行（偏好显式开启也不出）。
    guard isLoggedIn,
      TiebaPreferenceSnapshot.bool("homePageShowHistoryForum", default: true)
    else {
      recentForums = []
      updateHistoryVisibility()
      return
    }
    recentForums = Self.readRecentForums()
    rebuildHistoryPills()
    updateHistoryVisibility()
  }

  private func rebuildHistoryPills() {
    historyStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    for forum in recentForums {
      let control = TiebaHistoryPill()
      control.configure(name: forum.forumName, avatar: forum.avatar)
      control.addAction(UIAction { [weak self] _ in
        TiebaSceneHaptics.fire("press")
        self?.openForum(forum.forumName)
      }, for: .touchUpInside)
      control.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
      historyStack.addArrangedSubview(control)
    }
  }

  /// 最近访问只读缓存：写入方每加一行都带新时间戳，(MAX(timestamp), COUNT(*))
  /// 不变即表内容仍是上次那份 → 跳过整表读 + 头像 KV 的 JSON 解。
  /// （头像 KV 若在此期间单独变化，最多迟一次出现才反映——记录列本身优先带头像。）
  private static var recentForumsCache: (stamp: Double, count: Int, items: [RecentForum])?
  /// 头像 KV 解析缓存：原文相同直接复用（比较字符串 ≪ 解 JSON）。
  private static var avatarMapCache: (raw: String, map: [String: String])?

  /// 最近访问（visit_history 表，type=forum，时间倒序 + 吧名去重）；头像优先
  /// 记录列，缺失时读全站吧头像磁盘缓存（JS 写的同一份 KV，只读）。
  private static func readRecentForums() -> [RecentForum] {
    let probe = try? TiebaSQLite.shared.queryFirst(
      database: TiebaSQLite.mainDatabase,
      sql: "SELECT MAX(timestamp) AS ts, COUNT(*) AS n FROM visit_history WHERE type = 'forum'",
      params: []
    )
    let stamp = TiebaSimpleRowParser.double(probe?["ts"]) ?? 0
    let count = Int(TiebaSimpleRowParser.double(probe?["n"]) ?? 0)
    if let cache = recentForumsCache, cache.stamp == stamp, cache.count == count {
      return cache.items
    }
    guard let rows = try? TiebaSQLite.shared.query(
      database: TiebaSQLite.mainDatabase,
      // LIMIT：这是主线程上的整表扫描 + 排序，历史表随使用无限增长（同仓 store 同款查询
      // 也加了 LIMIT 并留了这条纪律）。ORDER BY 已保证取到的是最新几条。
      sql: "SELECT forum_name, forum_id, avatar FROM visit_history WHERE type = 'forum' ORDER BY timestamp DESC, id DESC LIMIT 60",
      params: []
    ) else { return [] }
    var seen = Set<String>()
    var result: [RecentForum] = []
    let cache = forumAvatarCache()
    for row in rows {
      let name = (row["forum_name"] as? String) ?? ""
      guard !name.isEmpty, seen.insert(name).inserted else { continue }
      var item = RecentForum()
      item.forumName = name
      item.forumId = (row["forum_id"] as? String) ?? ""
      item.avatar = (row["avatar"] as? String) ?? ""
      if item.avatar.isEmpty {
        let key = item.forumId.isEmpty || item.forumId == "0" ? "n:\(name)" : item.forumId
        item.avatar = cache[key] ?? ""
      }
      result.append(item)
      if result.count >= 20 { break }
    }
    recentForumsCache = (stamp, count, result)
    return result
  }

  private static func forumAvatarCache() -> [String: String] {
    guard let raw = TiebaKvStore.shared.get(key: "forum_avatars_v1") else { return [:] }
    if let cache = avatarMapCache, cache.raw == raw { return cache.map }
    guard let data = raw.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]]
    else { return [:] }
    var out: [String: String] = [:]
    for (key, value) in object {
      if let avatar = value["avatar"] as? String, !avatar.isEmpty { out[key] = avatar }
    }
    avatarMapCache = (raw, out)
    return out
  }

  // MARK: - 列表

  private func buildList() {
    layout.scrollDirection = .vertical
    // 外边距 / 行距都是外观档的函数：卡片档 = 16 + 8（卡片浮在分组灰底上），
    // 扁平档 = 0 + 0（**通栏**，行紧贴、由行底发际线分隔）。
    layout.minimumLineSpacing = listLineSpacing
    layout.minimumInteritemSpacing = 4
    layout.sectionInset = UIEdgeInsets(
      top: TiebaListAppearance.isFlat ? 0 : 8,
      left: listHorizontalInset,
      bottom: 24,
      right: listHorizontalInset
    )
    collectionView.translatesAutoresizingMaskIntoConstraints = false
    collectionView.backgroundColor = .clear
    collectionView.alwaysBounceVertical = true
    collectionView.contentInsetAdjustmentBehavior = .never
    collectionView.decelerationRate = TiebaMotionSpec.Scroll.systemDecelerationRate
    collectionView.delegate = self
    collectionView.register(TiebaHomeForumCell.self, forCellWithReuseIdentifier: TiebaHomeForumCell.reuseID)
    collectionView.register(TiebaHomeStateCell.self, forCellWithReuseIdentifier: TiebaHomeStateCell.reuseID)
    refreshControl.tintColor = TiebaChromeTheme.current.tint
    collectionView.refreshControl = refreshControl
    refreshControl.addTarget(self, action: #selector(handleRefreshControl), for: .valueChanged)
    stateView.isDark = TiebaChromeTheme.current.dark
    stateView.tintColor = TiebaHomeAccessibleColor.brand
    // 首屏骨架：通用列表行（原 index.tsx SkeletonList variant="row" count={8}）
    stateView.skeletonVariant = .row
    stateView.skeletonInsets = UIEdgeInsets(top: 8, left: 16, bottom: 24, right: 16)
    stateView.onButtonPress = { [weak self] id in
      if id == "login" {
        TiebaNavigator.shared.navigate(.login)
      } else {
        self?.loadFollowedForums(force: true)
      }
    }
    welcomeView.onLogin = {
      TiebaNavigator.shared.navigate(.login)
    }
    welcomeView.onExplore = {
      TiebaNavigator.shared.selectTab(1)
    }
    collectionView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(collectionView)
    NSLayoutConstraint.activate([
      collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      collectionView.topAnchor.constraint(equalTo: historyScroll.bottomAnchor),
      collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    dataSource = UICollectionViewDiffableDataSource<String, String>(
      collectionView: collectionView
    ) { [weak self] collectionView, indexPath, forumId in
      if forumId == Self.stateItemID {
        let cell = collectionView.dequeueReusableCell(
          withReuseIdentifier: TiebaHomeStateCell.reuseID,
          for: indexPath
        ) as? TiebaHomeStateCell
        if let self {
          cell?.host(self.isLoggedIn ? self.stateView : self.welcomeView)
        }
        return cell
      }
      let cell = collectionView.dequeueReusableCell(
        withReuseIdentifier: TiebaHomeForumCell.reuseID,
        for: indexPath
      ) as? TiebaHomeForumCell
      guard let self, self.displayedForums.indices.contains(indexPath.item) else { return cell }
      let forum = self.displayedForums[indexPath.item]
      cell?.configure(
        forum: forum,
        showsHairline: self.usesSingleColumnLayout && TiebaListAppearance.isFlat
      )
      cell?.onUnfollow = { [weak self] in self?.confirmUnfollow(forum) }
      if self.entrancePending { cell?.playEntrance(index: indexPath.item) }
      return cell
    }
    collectionView.dataSource = dataSource
    updateLayoutMetrics()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    // B6②：列表容器（不是内容）在 window 里挪了 ⇒ 外部位移，飞行体跟着挪同一份。
    let origin = collectionView.convert(CGPoint.zero, to: view.window)
    if let last = lastListWindowOrigin {
      applyListShift(CGPoint(x: origin.x - last.x, y: origin.y - last.y), isExternal: true)
    }
    lastListWindowOrigin = origin
    let desiredInset = UIEdgeInsets(top: 8, left: 0, bottom: view.safeAreaInsets.bottom + 20, right: 0)
    if collectionView.contentInset != desiredInset {
      collectionView.contentInset = desiredInset
    }
    let size = itemSize(for: view.bounds.width)
    if layout.itemSize != size {
      layout.itemSize = size
      layout.invalidateLayout()
    }
  }

  /// 尺寸变化只失效布局：全量 reloadData 会与 diffable dataSource 的快照应用
  /// 打架（每次出现都整屏重载）。
  private func updateLayoutMetrics() {
    let size = itemSize(for: view.bounds.width)
    guard layout.itemSize != size else { return }
    layout.itemSize = size
    layout.invalidateLayout()
  }

  /// 列表左右外边距：卡片档 16（卡片浮在分组灰底上），扁平档 0（通栏）。
  private var listHorizontalInset: CGFloat { TiebaListAppearance.isFlat ? 0 : 16 }
  /// 行间距：卡片档 8（卡与卡之间留缝），扁平档 0（行紧贴，由行底发际线分隔）。
  private var listLineSpacing: CGFloat { TiebaListAppearance.isFlat ? 0 : 8 }

  /// AX 大字号强制单列：两列时名字/关注数没有足够宽度，会互相挤压。
  private var usesSingleColumnLayout: Bool {
    isSingleColumn || traitCollection.preferredContentSizeCategory.isAccessibilityCategory
  }

  private func itemSize(for width: CGFloat) -> CGSize {
    let available = max(width - listHorizontalInset * 2, 0)
    let nameLine = ceil(TiebaSimpleText.font(size: 15, weight: .semibold).lineHeight)
    let metaLine = ceil(TiebaSimpleText.font(size: 12, weight: .regular).lineHeight)
    let nameLines: CGFloat = traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? 2 : 1
    let textHeight = nameLine * nameLines + 2 + metaLine
    if usesSingleColumnLayout {
      return CGSize(width: available, height: max(62, textHeight + 24))
    }
    return CGSize(width: max((available - 4) / 2, 0), height: max(58, textHeight + 20))
  }

  private func sortedForums() -> [TiebaForumInfo] {
    forums.sorted { lhs, rhs in
      if sortMode == .name {
        return lhs.forumName.localizedStandardCompare(rhs.forumName) == .orderedAscending
      }
      return lhs.levelId > rhs.levelId
    }
  }

  // MARK: - 数据

  /// force = 用户主动刷新/签到后：跳过原生缓存直连服务端。
  private func loadFollowedForums(force: Bool = false) {
    guard !isLoading else {
      refreshControl.endRefreshing()
      return
    }
    guard isLoggedIn else {
      refreshControl.endRefreshing()
      forums = []
      showState(compactLoginState)
      return
    }
    isLoading = true
    if forums.isEmpty, !hasLoadedOnce { showState(.loading) }
    Task { @MainActor in
      defer {
        isLoading = false
        isUserRefresh = false
        refreshControl.endRefreshing()
      }
      do {
        let list = try await TiebaFollowedForums.fetchAll(force: force)
        forums = list
        loadedDay = TiebaFollowedForums.today()
        hasLoadedOnce = true
        if forums.isEmpty {
          showState(compactState(
            image: "tray",
            text: "还没有关注的贴吧",
            secondary: "去动态页发现感兴趣的贴吧",
            buttonID: "retry",
            buttonTitle: "刷新",
            buttonIcon: "arrow.clockwise"
          ), animated: true)
        } else {
          startEntrance()
          showList(animated: true)
        }
        if isUserRefresh { TiebaSceneHaptics.fire("action-success") }
      } catch {
        if forums.isEmpty {
          showState(compactState(
            image: "wifi.exclamationmark",
            text: "加载失败",
            secondary: error.localizedDescription,
            buttonID: "retry",
            buttonTitle: "重试",
            buttonIcon: "arrow.clockwise"
          ), animated: true)
        } else {
          pill.showResult(success: false, text: "加载失败")
        }
        if isUserRefresh { TiebaSceneHaptics.fire("action-fail") }
      }
    }
  }

  /// 外观档落地：纯 systemBackground 页面 + 列表外边距 / 行距 + 整表重配。
  /// 幂等，可重复调用。
  private func applyAppearance() {
    view.backgroundColor = .systemBackground
    layout.minimumLineSpacing = listLineSpacing
    layout.sectionInset = UIEdgeInsets(
      top: TiebaListAppearance.isFlat ? 0 : 8,
      left: listHorizontalInset,
      bottom: 24,
      right: listHorizontalInset
    )
    updateLayoutMetrics()
    applyList()
  }

  private func applyList(animated: Bool = false) {
    displayedForums = sortedForums()
    var snapshot = NSDiffableDataSourceSnapshot<String, String>()
    snapshot.appendSections(["main"])
    if activeState != nil {
      // 有状态就是"列表里只有状态这一项"：列表保持可见（下拉刷新因此始终可达）。
      snapshot.appendItems([Self.stateItemID], toSection: "main")
    } else {
      snapshot.appendItems(displayedForums.map(\.forumId), toSection: "main")
      if snapshot.itemIdentifiers.isEmpty == false,
        snapshot.itemIdentifiers == dataSource?.snapshot().itemIdentifiers
      {
        snapshot.reloadItems(snapshot.itemIdentifiers)
      }
    }
    let shouldAnimate = animated
      && UIAccessibility.isReduceMotionEnabled == false
      && view.window != nil
      && entrancePending == false
    if shouldAnimate {
      UIView.transition(
        with: collectionView,
        duration: TiebaAnimationDuration.stateChange,
        options: [.transitionCrossDissolve, .allowUserInteraction],
        animations: {
          _ = self.dataSource?.apply(snapshot, animatingDifferences: false)
        }
      )
    } else {
      dataSource?.apply(snapshot, animatingDifferences: false)
    }
  }

  /// 首屏入场：只由首批 cell 界定（原 0.6s 时间窗口已删）——批次边界 =
  /// 首个布局趟的 willDisplay 全部走完（下个 runloop 清标志）。
  private func startEntrance() {
    guard !entranceDone else { return }
    entranceDone = true
    entrancePending = true
  }

  // MARK: - 状态

  /// 状态 = 列表的一项（改前：stateView 显示 + collectionView 隐藏，两套视图轮流占位；
  /// 空态下下拉刷新不可达，只能靠状态块里的「刷新」按钮兜底）。
  private func showState(_ state: TiebaState, animated: Bool = false) {
    let wasShowingContent = activeState == nil
    activeState = state
    stateView.isHidden = false
    let applyState = {
      self.stateView.state = state
      if case .loading = state { return }
      // 系统 ContentUnavailableView 层级 + 更小的符号；避开大图与大阴影 CTA。
      self.stateView.imageSize = 30
      self.stateView.imageColor = TiebaHomeAccessibleColor.tertiaryIcon
      self.stateView.textStyle = "headline"
      self.stateView.textWeight = "semibold"
      self.stateView.secondaryStyle = "subheadline"
      self.stateView.secondaryColor = TiebaHomeAccessibleColor.secondaryText
    }
    if animated, wasShowingContent == false,
      UIAccessibility.isReduceMotionEnabled == false,
      view.window != nil
    {
      UIView.transition(
        with: stateView,
        duration: TiebaAnimationDuration.stateChange,
        options: [.transitionCrossDissolve, .allowUserInteraction],
        animations: applyState
      )
    } else {
      applyState()
    }
    applyList(animated: animated && wasShowingContent)
  }

  private func showList(animated: Bool = false) {
    let hadState = activeState != nil
    activeState = nil
    applyList(animated: animated && hadState)
  }

  private func compactState(
    image: String,
    text: String,
    secondary: String?,
    buttonID: String,
    buttonTitle: String,
    buttonIcon: String?
  ) -> TiebaState {
    var raw: [String: Any] = [
      "id": buttonID,
      "title": buttonTitle,
      "style": "bordered",
      "capsule": true,
    ]
    if let buttonIcon { raw["icon"] = buttonIcon }
    return .custom(
      image: image,
      text: text,
      secondary: secondary,
      buttons: [TiebaStateButton(raw: raw)]
    )
  }

  private var compactLoginState: TiebaState {
    compactState(
      image: "person.crop.circle",
      text: "尚未登录",
      secondary: "登录后查看关注的贴吧和最新动态",
      buttonID: "login",
      buttonTitle: "登录百度账号",
      buttonIcon: "person.crop.circle.badge.checkmark"
    )
  }

  /// 未登录：头像用克制的 SF 占位；列表换成紧凑、玻璃 CTA 的登录引导。
  private func applyLoginState(animated: Bool = false) {
    let loggedIn = isLoggedIn
    let previousState = lastAppliedLoginState
    lastAppliedLoginState = loggedIn
    let account = TiebaUserAPI.currentAccount()
    avatarView.isHidden = loggedIn == false
    signedOutAvatarGlyph.isHidden = loggedIn
    if loggedIn {
      avatarView.configure(
        url: TiebaSimpleRowParser.avatarURL(account?.portrait ?? "")?.absoluteString ?? "",
        initial: account?.initials ?? "吧"
      )
    } else {
      avatarView.configure(url: "", initial: "")
    }
    avatarControl.accessibilityLabel = loggedIn ? "个人中心" : "登录百度账号"
    avatarControl.accessibilityHint = loggedIn ? "打开我的主页" : "前往登录"
    guard loggedIn else {
      forums = []
      showState(compactLoginState, animated: animated)
      if previousState == true, animated {
        TiebaSceneHaptics.fire("toggle")
      }
      return
    }
    if previousState == false, animated {
      TiebaSceneHaptics.fire("action-success")
    }
  }

  func openForum(_ name: String) {
    guard !name.isEmpty else { return }
    TiebaNavigator.shared.navigate(.forum(name: name))
  }

  // MARK: - 动作

  private func handleAvatarTap() {
    TiebaSceneHaptics.fire("press")
    TiebaUserAPI.navigateToOwnProfile()
  }

  private func handleSortTap() {
    guard isLoggedIn else { return }
    TiebaSceneHaptics.fire("toggle")
    sortMode = sortMode == .level ? .name : .level
    saveSortMode()
    collectionView.setContentOffset(
      CGPoint(x: 0, y: -collectionView.adjustedContentInset.top),
      animated: UIAccessibility.isReduceMotionEnabled == false
    )
    applySignButton()
    if forums.isEmpty == false {
      activeState = nil
    }
    applyList(animated: true)
  }

  /// 离开本页：在途飞行体立刻收束（覆盖容器挂在 window 上，不主动摘会留在别人页面上）。
  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    guard !signFlights.isEmpty else { return }
    let flights = signFlights
    signFlights.removeAll()
    for flight in flights { flight.cancel() }
  }

  /// 签到「进行中 → 结束」这一拍：成功就撒一次彩带（失败/取消/无事可做都不撒）。
  private func handleSignStateChange() {
    let service = TiebaSignService.shared
    let signing = service.isSigning
    // 逐吧飞行体：签成功一个就飞一个（不等到整轮结束——"动作落地"的兑现感就在这一拍）。
    if signing {
      flySignedForums(service)
    } else if wasSigning {
      flownSignForumIds.removeAll()
    }
    defer {
      wasSigning = signing
      if signing { didCelebrateSign = false }
    }
    guard wasSigning, !signing else { return }
    guard service.lastError == nil, service.progressSuccess > 0, !didCelebrateSign else { return }
    // 本页不在屏上时不撒（签到可能是从设置页发起的）：省掉一次 3 秒的全屏动画。
    guard view.window != nil else { return }
    didCelebrateSign = true
    TiebaSceneHaptics.fire("action-success")
    signConfetti?.removeFromSuperview()
    let confetti = TiebaConfettiView(frame: view.bounds)
    confetti.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    // D3：涟漪从**刚点的那个签到按钮**起波（同一坐标系 = 本页 view）。
    confetti.rippleOrigin = signButton.convert(
      CGPoint(x: signButton.bounds.midX, y: signButton.bounds.midY),
      to: view
    )
    view.addSubview(confetti)
    signConfetti = confetti
  }

  // MARK: - B5 签到飞行体（报告 37 B3/B4/B5/B6）

  /// 把「刚签成功的吧」从它的列表行吸进顶栏签到圆钮。只在源行可见时才飞（看不见的源没有落点），
  /// 同屏最多 4 个（20 个吧连飞会糊成一片）。
  private func flySignedForums(_ service: TiebaSignService) {
    guard view.window != nil else { return }
    for item in service.progressItems where item.status == "success" {
      guard !item.forumId.isEmpty, flownSignForumIds.insert(item.forumId).inserted else { continue }
      guard signFlights.count < 4, let source = visibleAvatarView(forumId: item.forumId) else { continue }
      startSignFlight(from: source)
    }
  }

  /// 某个吧当前可见行里的吧头像（不可见 = nil，不飞）。
  private func visibleAvatarView(forumId: String) -> UIView? {
    for cell in collectionView.visibleCells {
      guard let indexPath = collectionView.indexPath(for: cell),
        displayedForums.indices.contains(indexPath.item),
        displayedForums[indexPath.item].forumId == forumId,
        let forumCell = cell as? TiebaHomeForumCell
      else { continue }
      return forumCell.signFlightSourceView
    }
    return nil
  }

  private func startSignFlight(from source: UIView) {
    guard let window = view.window,
      let flight = TiebaFlightTransition(source: source, target: signButton, in: window)
    else { return }
    signFlights.append(flight)
    flight.onFinish = { [weak self, weak flight] in
      guard let self, let flight else { return }
      self.signFlights.removeAll { $0 === flight }
    }
    flight.start()
  }

  /// B6①：列表滚动 = 内容位移（源行跟着走，飞行体也要跟）。
  /// B6②：列表容器自身挪动 = 外部位移（"最近访问"展开/收起、字号档变化）。
  func applyListShift(_ offset: CGPoint, isExternal: Bool) {
    guard !signFlights.isEmpty, abs(offset.x) > 0.01 || abs(offset.y) > 0.01 else { return }
    for flight in signFlights {
      if isExternal {
        flight.addExternalOffset(offset)
      } else {
        flight.addContentOffset(offset)
      }
    }
  }

  private func handleSignTap() {
    guard isLoggedIn else {
      let alert = UIAlertController(title: "提示", message: "签到需要先登录百度账号", preferredStyle: .alert)
      alert.addAction(UIAlertAction(title: "去登录", style: .default) { _ in
        TiebaNavigator.shared.navigate(.login)
      })
      alert.addAction(UIAlertAction(title: "取消", style: .cancel))
      present(alert, animated: true)
      return
    }
    // 空列表 = 还在加载或加载失败，不能当成「全部已签到」：contains 恒 false 会把这个快捷检查
    // 变成提前 return，真实签到流程根本不启动。列表为空时放行，让服务端自己判断。
    if !forums.isEmpty, !forums.contains(where: { !$0.isSign }) {
      pill.showResult(success: true, text: "今天所有关注的吧都已签到过了")
      return
    }
    TiebaSceneHaptics.fire("action-success")
    TiebaSignService.shared.start(presenter: self)
  }

  @objc private func handleRefreshControl() {
    TiebaSceneHaptics.fire("press")
    isUserRefresh = true
    loadFollowedForums(force: true)
    loadRecentForums()
  }

  private func confirmUnfollow(_ forum: TiebaForumInfo) {
    let alert = UIAlertController(
      title: "取消关注",
      message: "确定不再关注「\(forum.forumName)吧」吗？",
      preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(title: "取消", style: .cancel))
    alert.addAction(UIAlertAction(title: "取消关注", style: .destructive) { [weak self] _ in
      Task { @MainActor in
        do {
          try await TiebaFollowedForums.unfollow(forumId: forum.forumId, forumName: forum.forumName)
          TiebaSceneHaptics.fire("action-success")
          self?.forums.removeAll { $0.forumId == forum.forumId }
          self?.applyList()
          self?.loadFollowedForums(force: true)
        } catch {
          TiebaSceneHaptics.fire("action-fail")
          self?.pill.showResult(success: false, text: "取消关注失败")
        }
      }
    })
    present(alert, animated: true)
  }

  // MARK: - 排序偏好（page-private 键；共享偏好只读）

  private func loadSortMode() -> SortMode {
    if let raw = TiebaKvStore.shared.get(key: Self.sortKey) {
      return SortMode(rawValue: raw) ?? .level
    }
    return SortMode(rawValue: TiebaPreferenceSnapshot.string("forumSortMode") ?? "level") ?? .level
  }
}
