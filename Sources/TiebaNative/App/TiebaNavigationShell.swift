import UIKit

// 原生导航壳：窗口根一条只做容器的 UINavigationController +
// TiebaMainTabBarController（手机 = 底部 tab 栏，iPad = 可折叠侧边栏）+
// 每屏一个宿主 VC。替掉 react-native-screens 的原生栈与 expo-router 的文件路由。
//
// 结构：
//   window.rootViewController = TiebaRootNavigationController  ← 容器栈，自身不压栈
//     └── [0] TiebaMainTabBarController
//               ├── Tab0 关注 → TiebaRootNavigationController → 宿主(index)
//               ├── Tab1 动态 → 同上 → …(explore)
//               ├── Tab2 消息 → 同上 → …(notifications)
//               └── Tab3 我的 → 同上 → …(profile)
//
// ⚠️ 每个 tab 一条**自己的**导航栈（不再是"全 App 一条根栈、压栈页盖住底栏"）：
// iPad 侧边栏形态下内容区只占侧边栏右侧，压栈页若盖住侧边栏就等于把导航入口
// 一起盖掉。分栈后 push 只换内容区。代价是切 tab 不再共享堆栈——这是 iPad 的
// 常规交互。外层容器栈恒定只有一个 VC，仅为保住 statusBarStyle 链路与顶栏扫描。

/// 主题与状态栏配置：跟随应用内主题，而非系统外观。
/// @unchecked Sendable：UIColor 事实上不可变；这个标记只是让"主线程 hop 里读
/// 主题"在 Swift 6 下不被拦。
public struct TiebaChromeTheme: @unchecked Sendable {
  /// 底栏选中态 / 强调色（原 colors.primary）
  public var tint: UIColor
  /// 导航栏返回箭头与按钮色（原 headerTint：默认 colors.text，可被"工具栏
  /// 使用主色调"改成 primary）
  public var navTint: UIColor
  public var background: UIColor
  public var dark: Bool

  public static let `default` = TiebaChromeTheme(
    tint: .label,
    navTint: .label,
    background: .systemBackground,
    dark: false
  )
}

// MARK: - 根导航栈

/// 根栈。导航栏形态与 expo-router 的 screenOptions 对齐：
/// 透明栏底（内容从栏下滚过）、无分隔线、返回箭头只画 chevron 不带上一屏标题、
/// 交互式返回手势常开、滚动边缘效果交给 TiebaNavBarChrome 统一管理。
public final class TiebaRootNavigationController: UINavigationController {
  public override func viewDidLoad() {
    super.viewDidLoad()
    // 只要箭头，不要"返回"文字（否则会显示上一屏标题，如 "首页"）。
    navigationBar.backIndicatorImage = UIImage(
      systemName: "chevron.backward",
      withConfiguration: UIImage.SymbolConfiguration(weight: .semibold)
    )
    navigationBar.backIndicatorTransitionMaskImage = navigationBar.backIndicatorImage
    navigationBar.tintColor = .label
    interactivePopGestureRecognizer?.isEnabled = true
    interactivePopGestureRecognizer?.delegate = self
    // 栏内按压判定（HDR 高光 + 轻触觉）：挂载点即装好，不必等 chrome 重扫。
    TiebaChrome.installChromePressHaptics(on: navigationBar)
    // 深色模式下栏底是深色液态玻璃，状态栏字色由各屏 preferredStatusBarStyle
    // 决定（Info.plist 是 UIViewControllerBasedStatusBarAppearance=true）。
    setNeedsStatusBarAppearanceUpdate()
  }

  /// 栈内任意一屏的 preferredStatusBarStyle 决定状态栏，而不是栈自己的。
  public override var childForStatusBarStyle: UIViewController? { topViewController }
}

extension TiebaRootNavigationController: UIGestureRecognizerDelegate {
  public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    viewControllers.count > 1
  }
}

// MARK: - 底栏

/// 底栏容器。四个 tab 的图标/标签/顺序与 NativeTabs 声明一致；
/// 配色跟随应用内主题（不是系统外观），否则"应用强制深色 + 系统浅色"
/// 会出现亮色标签配深色内容页的脱节——机制是窗口级 override（见
/// TiebaChrome.setChromeDarkMode），本控制器不再自己写。
public final class TiebaMainTabBarController: UITabBarController {
  /// 已选中 tab 被再次点击时回调（原生直接受理 tabReselected）。
  var onReselect: ((Int) -> Void)?

  private var theme: TiebaChromeTheme = .default

  public override func viewDidLoad() {
    super.viewDidLoad()
    delegate = self
    applyTheme(theme)
    // 分屏 / Slide Over 改宽度不会走 viewWillTransition，尺寸类别要单独观察。
    registerForTraitChanges([UITraitHorizontalSizeClass.self]) { (self: Self, _: UITraitCollection) in
      self.configureSidebar()
    }
    // 底栏不发按压手势：底栏项的视图层级不是公开的 UIControl 保证（栏内 hitTest
    // 找不到 UIControl ⇒ 手势永远不发触觉）。底栏触觉由下面的 delegate 回调发。
  }

  public override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    // 入窗口后 trait 才准（viewDidLoad 时尺寸类别还是默认值），首次形态在这里落定。
    configureSidebar()
  }

  func applyTheme(_ theme: TiebaChromeTheme) {
    self.theme = theme
    tabBar.tintColor = theme.tint
    view.backgroundColor = theme.background
    // ⚠️ 不写 tabBar.standardAppearance / scrollEdgeAppearance：任何 bar 级
    // appearance 写入都会让 UIKit 退出自动 Liquid Glass 渲染管线，底栏退化成
    // 旧磨砂（实心色带）。保持 appearance 原生态，由系统渲染真液态玻璃。
    // 只设 tintColor（选中态图标/文字的主色）。
    // 深浅不在这里写：底栏控制器是 window 根 VC 的子级，窗口级 override
    // （TiebaChrome.setChromeDarkMode，应用主题 ≠ 系统外观的唯一决策点）
    // 覆盖整个窗口的 VC/视图树，bar 材质与 systemName 图标随之深浅。
  }

  /// 底栏 / 侧边栏的形态。按**设备类型**定：只有 iPad 用侧边栏，iPhone 永远是
  /// 底栏——iPhone 横屏（Pro Max 一类）宽度也会到 regular，只按尺寸类别判会让
  /// 手机跑起 iPad 的界面。iPad 分屏 / Slide Over 收窄到 compact 时同样退回底栏。
  ///
  /// iPad（regular 宽度）：`.tabSidebar`——侧边栏与顶栏两态共存，用户可折叠
  /// （折叠按钮与快捷手势由系统提供，本仓不自造一套）。**底栏保留**：侧边栏
  /// 收起时它就是常规底栏，展开时两者是同一组 tab 的两种呈现，选中态由系统同步。
  func configureSidebar() {
    let regular = traitCollection.userInterfaceIdiom == .pad
      && traitCollection.horizontalSizeClass == .regular
    mode = regular ? .tabSidebar : .tabBar
    // 下滑收纳属于底栏：iPad 侧边栏形态下没有这回事，交给系统。
    tabBarMinimizeBehavior = regular
      ? .automatic
      : (tabBarMinimizeEnabled ? .onScrollDown : .never)
    guard regular else { return }
    sidebar.preferredLayout = .tile
    // 默认展开：用户要的是"可折叠"，不是"默认折叠"。
    sidebar.isHidden = false
    if #available(iOS 27.0, *) {
      sidebar.preferredPlacement = .sidebar
    }
  }

  public override func viewWillTransition(
    to size: CGSize,
    with coordinator: UIViewControllerTransitionCoordinator
  ) {
    super.viewWillTransition(to: size, with: coordinator)
    coordinator.animate { _ in } completion: { [weak self] _ in
      MainActor.assumeIsolated { self?.configureSidebar() }
    }
  }

  /// 底栏滚动收纳开关（设置→使用习惯→浏览，默认开）。
  var tabBarMinimizeEnabled: Bool = true {
    didSet {
      guard oldValue != tabBarMinimizeEnabled else { return }
      guard traitCollection.horizontalSizeClass != .regular else { return }
      tabBarMinimizeBehavior = tabBarMinimizeEnabled ? .onScrollDown : .never
    }
  }
}

extension TiebaMainTabBarController: UITabBarControllerDelegate {
  /// iOS 18 起 UIKit 有两套「将要选中」回调：viewController 版与 UITab 版。
  /// 系统在真机上到底调哪一套（甚至是否两套都调）随版本与栏的配置方式而变，
  /// 只实现一套就可能一次都收不到 —— 「底栏点了没振动」的根因就在这（2026-09-15
  /// 用户复报）。两套都接、落到同一个处理函数，用 50ms 去重保证不双发。
  public func tabBarController(
    _ tabBarController: UITabBarController,
    shouldSelect viewController: UIViewController
  ) -> Bool {
    handleTabSelection(index(of: viewController))
    return true
  }

  public func tabBarController(
    _ tabBarController: UITabBarController,
    shouldSelectTab tab: UITab
  ) -> Bool {
    handleTabSelection(index(of: tab))
    return true
  }

  /// UITab 与 UITabBarItem 两条回调都从 UITab 反查序号：tabs 一旦设置，
  /// viewControllers 就不再是权威来源。
  private func index(of tab: UITab) -> Int {
    tabs.firstIndex { $0 === tab } ?? -1
  }

  /// 回调给的是 tab 承载的 VC——本仓每个 tab 挂一条自己的导航栈，
  /// 所以要沿 parent 链上溯到那个栈。
  private func index(of viewController: UIViewController) -> Int {
    var cursor: UIViewController? = viewController
    while let current = cursor {
      if let tab = tabs.first(where: { ($0.viewController as? UIViewController) === current }) {
        return index(of: tab)
      }
      cursor = current.parent
    }
    return -1
  }

  /// 底栏一次选中的全部动作（触觉 + 重按回调）。dedupWindow 内同一 tab 只处理一次：
  /// 两套 UIKit 回调可能在同一次点击里各来一发。
  private func handleTabSelection(_ index: Int) {
    guard index >= 0 else { return }
    let now = ProcessInfo.processInfo.systemUptime
    let state = TiebaChrome.HapticsState.self
    if index == state.lastTabIndex, now - state.lastTabAt < 0.05 { return }
    state.lastTabIndex = index
    state.lastTabAt = now
    let selected = selectedTab == nil ? -1 : indexOfSelected
    if index == selected {
      // 重按已选中 tab（回顶/刷新由各 tab 根屏的 tabReselected 受理），档位
      // 对齐原 JS handleTabReselect 的 'press'。
      TiebaSceneHaptics.fire("press")
      onReselect?(index)
    } else {
      // 换 tab：档位对齐原 JS 底栏按钮的 'segment'。程序化赋值 selectedTab
      // 不触发本回调，深链切 tab 不会误振。
      TiebaSceneHaptics.fire("segment")
    }
  }

  private var indexOfSelected: Int {
    guard let sel = selectedTab else { return -1 }
    return index(of: sel)
  }

  /// 在视图树里找"主滚动视图"，返回面积最大的那个。
  ///
  /// 实现唯一一份在 UIView.primaryScrollView（TiebaTopViewController.swift）；
  /// 为什么是"面积最大"而不是"第一个"（横向药丸行/分页器会骗过系统栏的跟踪）
  /// 见该处注释。这里保留本方法作为底栏侧的入口名。
  func primaryScrollView(in vc: UIViewController) -> UIScrollView? {
    vc.view.primaryScrollView()
  }
}

// MARK: - 单屏宿主

/// 一屏一个宿主 VC，视图体由原生页面（TiebaNativeRouteTable 登记）提供。
public final class TiebaRouteHostViewController: UIViewController {
  public let route: TiebaRoute
  public let hostId: Int

  /// 原生页面。用 addChild 承载而不是取其 view 直接 addSubview——页面要拿得到
  /// viewDidLoad/viewWillAppear 这些正常生命周期。
  private let nativeChild: UIViewController
  private var content: UIView?

  public init(route: TiebaRoute, hostId: Int, nativeChild: UIViewController) {
    self.route = route
    self.hostId = hostId
    self.nativeChild = nativeChild
    super.init(nibName: nil, bundle: nil)
    applyRouteChrome()
    syncNativeScreenChrome()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  public override func loadView() {
    let root = UIView()
    // 底色用应用主题（不是 .systemBackground）：深色主题 + 系统浅色时，
    // .systemBackground 是白的，push 转场的第一帧会闪一下白。
    root.backgroundColor = TiebaNavigator.shared.chromeTheme.background
    let child = nativeChild
    addChild(child)
    let content: UIView = child.view
    child.didMove(toParent: self)
    self.content = content
    content.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(content)
    NSLayoutConstraint.activate([
      content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      content.topAnchor.constraint(equalTo: root.topAnchor),
      content.bottomAnchor.constraint(equalTo: root.bottomAnchor)
    ])
    view = root
    // 原生子页的标题/状态栏/trait 要用它自己的声明（子 VC 的 navigationItem 会被
    // 导航控制器忽略，必须由宿主落到自己的 navigationItem 上）。
    syncNativeScreenChrome()
  }

  private func applyRouteChrome() {
    let entry = TiebaRouteTable.entry(named: route.name)
    switch entry?.chrome ?? .standard {
    case .hidden:
      navigationItem.title = ""
      // 栏隐藏由 TiebaNavigator 在 push 时逐屏设置（UINavigationController
      // 的 setNavigationBarHidden 是整条栈级别的，不能按屏声明）。
      break
    case .standard:
      navigationItem.title = entry?.title ?? ""
      // 只要箭头：上一屏标题不进返回按钮（'minimal' 语义）。
      navigationItem.backButtonDisplayMode = .minimal
    }
  }

  /// 屏幕标题（可被外部覆盖，如吧页标题要等吧名解析出来）。
  func setTitle(_ title: String) {
    navigationItem.title = title
  }

  /// 把原生子页声明的标题/状态栏字色落到宿主上，并把应用主题的深浅强制进它的
  /// 视图树。主题变化时由 TiebaNavigator.applyTheme 再调一次。
  ///
  /// 为什么标题要转一手：压进导航栈的是宿主，UINavigationController 只认宿主的
  /// navigationItem，子 VC 的会被忽略。
  ///
  /// 为什么子页这处 override **不能**随 window 继承（其余逐处写入已删）：压栈前
  /// 的 loadViewIfNeeded 会在页面**未入窗口**时把整棵树建好（见 TiebaNavigator
  /// 的 eager host），此时窗口 trait 不可达，页面里"动态色 → CGColor"的取值
  /// （骨架描边、已知主贴卡描边等）会按默认档解析成浅色。宿主是这棵离屏树的
  /// trait 源；值仍取自 navigator 的同一主题决定，不新增判据。
  func syncNativeScreenChrome() {
    let child = nativeChild
    child.overrideUserInterfaceStyle = TiebaNavigator.shared.chromeTheme.dark ? .dark : .light
    guard let screen = child as? TiebaNativeScreen else { return }
    if let title = screen.screenTitle { navigationItem.title = title }
    if let style = screen.preferredScreenStatusBarStyle { statusBarStyleOverride = style }
    navigationItem.rightBarButtonItems = screen.screenRightBarItems
    // nil = 保留系统返回箭头（只替换显式声明左侧按钮的屏，如登录页的 xmark）。
    if let left = screen.screenLeftBarItems { navigationItem.leftBarButtonItems = left }
  }

  /// 主题变化 → 转给子页（含分段容器里的常驻子页，所以递归整棵子 VC 树）。
  func refreshScreenTheme() {
    func visit(_ vc: UIViewController) {
      (vc as? TiebaNativeScreen)?.screenThemeDidChange()
      for child in vc.children { visit(child) }
    }
    visit(nativeChild)
  }

  public override var preferredStatusBarStyle: UIStatusBarStyle {
    // 逐屏覆盖优先，否则用全局默认（由 JS 按"工具栏主色调 / 状态栏字色"
    // 偏好算出后下发）。应用内主题 ≠ 系统外观，所以不能交给 UIKit 自己判。
    statusBarStyleOverride ?? TiebaNavigator.shared.defaultStatusBarStyle
  }

  /// 逐屏覆盖（JS 显式下发 statusBarStyle 时才有值）。
  var statusBarStyleOverride: UIStatusBarStyle? {
    didSet { setNeedsStatusBarAppearanceUpdate() }
  }

  /// 全局默认变了 → 没有逐屏覆盖的屏要重新取值。
  func refreshStatusBarStyle() {
    guard statusBarStyleOverride == nil else { return }
    setNeedsStatusBarAppearanceUpdate()
  }

  /// 供底栏/顶栏找滚动视图用。
  func scrollViewForSystem() -> UIScrollView? {
    view.primaryScrollView()
  }

  /// 把本屏的主滚动视图交给系统跟踪（栏边缘模糊 + 底栏收纳都靠这个关联）。
  ///
  /// ⚠️ 机制是 **子 VC 自己** 调 `setContentScrollView(_:forEdge:)`，不是
  /// 父容器替它设——UITabBarController 上并没有 setContentScrollView:for: 这个
  /// 方法（只有 tvOS 废弃的 tabBarObservedScrollView 属性）。文档语义：
  /// "a containing UINavigationController, UITabBarController, or both will
  /// observe the UIScrollView instance ... to determine the background blur for
  /// the bars and to update contentInset adjustments"。
  ///
  /// ⚠️ 必须反复同步而不是挂载时设一次：滚动容器会随页面状态重建（如列表从
  /// 骨架换成真列表），首次布局时目标实例可能还不存在。所以放在
  /// viewDidLayoutSubviews 里按实例比对。
  private func syncContentScrollView() {
    guard let sv = scrollViewForSystem() else { return }
    if sv !== trackedContentScrollView {
      trackedContentScrollView = sv
      // Swift 侧名字是 setContentScrollView(_:for:)（ObjC 选择子是
      // setContentScrollView:forEdge:，SDK 做了 NS_SWIFT_NAME 重命名）。
      setContentScrollView(sv, for: .top)
      setContentScrollView(sv, for: .bottom)
      normalizeScrollsToTop(primary: sv)
      // 主滚动视图换人 = chrome 相关结构变化（骨架 → 列表、加载完成换数据）：
      // 标脏让重扫把顶/底边效果挂到新列表上。放在这里而不是靠滚动件挂载事件，
      // 是因为挂载事件只认"页面级"滚动视图（见 TiebaNavBarChrome 的收紧）。
      TiebaChrome.markChromeDirty()
      TiebaChrome.scheduleChromeTick()
    } else if !sv.scrollsToTop {
      // 唯一名额被后压的屏抢走后本屏重新可见（pop 回来）：收回给自己。
      normalizeScrollsToTop(primary: sv)
    }
  }

  /// 状态栏点按回顶：系统只在"屏上恰好一个 scrollsToTop == YES"时执行手势
  ///（SDK 原文；UIScrollView 默认 YES，行内横滑条/页内滚动件都会占掉唯一名额，
  /// 导致点状态栏毫无反应）——所以按窗口收敛成唯一一个。主实例不变时只在被
  /// 抢走（变 false）才重做，正常布局路径零扫描。
  private func normalizeScrollsToTop(primary: UIScrollView) {
    let root: UIView = primary.window ?? view
    root.forEachSubviewRecursively { candidate in
      guard let scroll = candidate as? UIScrollView else { return }
      let wanted = scroll === primary
      if scroll.scrollsToTop != wanted { scroll.scrollsToTop = wanted }
    }
  }

  private weak var trackedContentScrollView: UIScrollView?

  public override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    syncContentScrollView()
  }
}
