import UIKit

// 原生导航壳：UINavigationController（根栈）+ UITabBarController（底栏）+
// 每屏一个宿主 VC。替掉 react-native-screens 的原生栈与 expo-router 的文件路由。
//
// 结构（与原 expo-router 的 _layout 完全同构，行为不变）：
//   window.rootViewController = TiebaRootNavigationController
//     └── [0] TiebaMainTabBarController          根栈最底屏（导航栏隐藏）
//               ├── Tab0 关注    → TiebaRouteHostViewController(index)
//               ├── Tab1 动态    → TiebaRouteHostViewController(explore)
//               ├── Tab2 消息    → TiebaRouteHostViewController(notifications)
//               └── Tab3 我的    → TiebaRouteHostViewController(profile)
//     └── [n] TiebaRouteHostViewController(…)   压栈页，天然盖住底栏
//
// ⚠️ 只有**一个**栈：原 expo-router 的根 Stack 里 (tabs) 与 forum/[name]、
// thread/[id] 是兄弟屏，所以进帖/进吧会盖住底栏。四个 tab 各自没有内部栈
// （(tabs)/ 下只有四个屏，没有嵌套 _layout）。因此每个 tab 根屏必须挂在
// 同一个 UITabBarController 下，压栈统一走根栈——不要给每个 tab 套一层
// UINavigationController，那会变成"底栏常驻"的另一种交互。

/// 导航事件（原生 → JS）。纯 Swift 结构。
public struct TiebaNavEvent {
  public enum Kind: String {
    case focus
    case blur
    /// 底栏重复点击（双击语义由 JS 判定，这里只上报"又一次点了已选中的 tab"）
    case tabReselect
    /// tab 选择变化
    case tabSelect
    /// 导航栏左右按钮被按下（action 名在 route.params["action"]）
    case barAction
  }

  public var kind: Kind
  public var hostId: Int
  public var route: TiebaRoute?
  public var tabIndex: Int
}

/// 主题与状态栏配置：由 JS 下发（跟随应用内主题，而非系统外观）。
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
/// 会出现亮色标签配深色内容页的脱节。
public final class TiebaMainTabBarController: UITabBarController {
  /// 已选中 tab 被再次点击时回调（双击判定在 JS 侧，这里只上报原始点击）。
  var onReselect: ((Int) -> Void)?
  var onSelect: ((Int) -> Void)?

  private var theme: TiebaChromeTheme = .default
  /// shouldSelect 时刻的旧选中下标：didSelect 用它区分"真切换"（segment）与
  /// "重按已选中 tab"（press 已在 shouldSelect 发过，不重复）。
  private var indexBeforeTap = 0

  public override func viewDidLoad() {
    super.viewDidLoad()
    delegate = self
    applyTheme(theme)
    // 底栏项的按压判定（光效；触觉归本控制器的场景表）：挂载点即装好。
    TiebaChrome.installChromePressHaptics(on: tabBar)
  }

  func applyTheme(_ theme: TiebaChromeTheme) {
    self.theme = theme
    tabBar.tintColor = theme.tint
    view.backgroundColor = theme.background
    // ⚠️ 不写 tabBar.standardAppearance / scrollEdgeAppearance：任何 bar 级
    // appearance 写入都会让 UIKit 退出自动 Liquid Glass 渲染管线，底栏退化成
    // 旧磨砂（实心色带）。保持 appearance 原生态，由系统渲染真液态玻璃。
    // 只设 tintColor（选中态图标/文字的主色）。
    if #available(iOS 26.0, *) {
      // 下滑收纳 / 上滑恢复，动画由 UIKit 原生药丸收纳控制。
      // 开关（设置→使用习惯→浏览）由 JS 下发；关闭时 never = 底栏常驻。
      tabBarMinimizeBehavior = tabBarMinimizeEnabled ? .onScrollDown : .never
    }
    // 深色/浅色：UIImage(systemName:) 默认跟随 trait，这里把整个底栏
    // 覆盖成应用主题对应的用户界面风格，避免系统浅色时底栏亮、内容暗。
    overrideUserInterfaceStyle = theme.dark ? .dark : .light
  }

  /// 底栏滚动收纳开关（设置→使用习惯→浏览，默认开）。
  var tabBarMinimizeEnabled: Bool = true {
    didSet {
      guard oldValue != tabBarMinimizeEnabled else { return }
      if #available(iOS 26.0, *) {
        tabBarMinimizeBehavior = tabBarMinimizeEnabled ? .onScrollDown : .never
      }
    }
  }
}

extension TiebaMainTabBarController: UITabBarControllerDelegate {
  public func tabBarController(
    _ tabBarController: UITabBarController,
    shouldSelect viewController: UIViewController
  ) -> Bool {
    let tapped = viewControllers?.firstIndex(of: viewController) ?? -1
    indexBeforeTap = selectedIndex
    if tapped == selectedIndex, tapped >= 0 {
      // 重按已选中 tab（回顶/刷新由各 tab 根屏的 tabReselected 受理），档位
      // 对齐原 JS handleTabReselect 的 'press'。触觉只在这里发：didSelect 对
      // 同一 tab 也会回调一次，放那边会重复。
      TiebaSceneHaptics.fire("press")
      onReselect?(tapped)
    }
    return true
  }

  public func tabBarController(
    _ tabBarController: UITabBarController,
    didSelect viewController: UIViewController
  ) {
    let idx = viewControllers?.firstIndex(of: viewController) ?? -1
    guard idx >= 0 else { return }
    // 只有选中真的变化才播 'segment'（原 JS 仅 tab→tab 的 pathname 变化才播：
    // 首挂载、深链直达、重按已选中 tab 都不震）。程序化切换（深链/启动默认页）
    // 不触发 didSelect，天然与 JS 的"首挂载不震"一致。
    if idx != indexBeforeTap {
      TiebaSceneHaptics.fire("segment")
    }
    onSelect?(idx)
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

  /// 事件回调（focus/blur 上报给 JS，供 useFocusEffect / useIsFocused 使用）。
  var onEvent: ((TiebaNavEvent) -> Void)?

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

  /// 屏幕标题（JS 可覆盖，如吧页标题要等吧名解析出来）。
  func setTitle(_ title: String) {
    navigationItem.title = title
  }

  /// 把原生子页声明的标题/状态栏字色落到宿主上，并把应用主题的深浅强制进它的
  /// 视图树。主题变化时由 TiebaNavigator.applyTheme 再调一次。
  ///
  /// 为什么标题要转一手：压进导航栈的是宿主，UINavigationController 只认宿主的
  /// navigationItem，子 VC 的会被忽略。
  ///
  /// 为什么要强制 trait：原生页面用系统语义色，而应用内主题 ≠ 系统外观（深色
  /// 主题 + 系统浅色是很常见的组合），得靠 overrideUserInterfaceStyle。
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

  public override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    onEvent?(TiebaNavEvent(kind: .focus, hostId: hostId, route: route, tabIndex: -1))
  }

  public override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    onEvent?(TiebaNavEvent(kind: .blur, hostId: hostId, route: route, tabIndex: -1))
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
