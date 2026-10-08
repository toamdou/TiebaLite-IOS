import Hero
import Nuke
import NukeExtensions
import UIKit

// 导航协调器：把类型化路由（TiebaRoute）翻译成 UIKit 的压栈/切 tab/上推，
// 原 expo-router 的 router.push/back/replace 语义在这里。
//
// 状态只有一份：当前 tab 那条栈的 viewControllers 就是当前导航栈，tabBar 就是底栏。
//
// ⚠️ 仍未处理的既有并发标注（改了会连带改 40+ 个调用方文件）：
// 本类仍是 NSObject + @unchecked Sendable，pushRoute/navigate 等非隔离入口里还剩几处
// MainActor.assumeIsolated。正确解法是整类 @MainActor，但那会让 Core/Features 里 40+ 个
// 文件（网络回调、深链入口）的调用点一起需要 hop，留给 Lead 决策
//（见 docs/uikit-migration/22-接线-viewport.md 的「没做到」一节）。

/// 底栏重复点击的**原生**受理面：tab 根屏已是原生 VC 时（不再有 JS 侧
/// TAB_RESELECT 订阅），由壳直接回调，语义与 JS 的 tabReselect 分发一致。
@MainActor
protocol TiebaTabReselectable: UIViewController {
  func tabReselected()
}

/// tab 根屏的路由参数投递面：tab 根屏不入栈（navigate 只切 tab），
/// 深链带的参数（如 tiebalite://notifications/2 的初始分段）由壳转交给
/// 已原生的根屏；没实现的根屏参数照旧丢弃。
@MainActor
protocol TiebaTabRouteParamReceiving: UIViewController {
  func receiveInitialTab(_ index: Int)
}

/// NSObject 基类不是装饰：UINavigationControllerDelegate 继承自
/// NSObjectProtocol，Swift 里不能给纯 Swift 类声明这个 conformance。
public final class TiebaNavigator: NSObject, @unchecked Sendable {
  public static let shared = TiebaNavigator()

  private weak var window: UIWindow?
  /// 每个 tab 一条自己的栈。iPad 侧边栏要求压栈页只占内容区、不能盖住侧边栏，
  /// 所以压栈不再走"包住 tab 的那条根栈"。窗口根 VC 仍是一条只做容器的
  /// TiebaRootNavigationController（不压栈），状态栏链路与栏扫描都不用改。
  private var tabNavs: [Int: TiebaRootNavigationController] = [:]
  /// 根容器栈（window.rootViewController）：手机上二级页压到这条栈，整页盖住
  /// tab 控制器（底栏/玻璃 dock 一并盖住）。iPad 仍用每 tab 独立栈（侧边栏交互）。
  private var shellNav: UINavigationController?
  private var tabBar: TiebaMainTabBarController?
  // 主题不存在这里：TiebaChromeTheme 已下沉到 Core（Core/TiebaChromeTheme.swift），
  // 读者一律走 TiebaChromeTheme.current。
  // 这里也**不存** UITab 数组：UITab 是 iOS 18 起的类型，做存储属性会让整个类在 17 上
  // 不可用。索引一律读壳层的 selectedRouteIndex（18 按 UITab.identifier、17 按
  // tabBarItem.accessibilityIdentifier），见下面的 currentTabIndex。


  /// 当前选中的 tab。读 UIKit 的 selectedTab：用户点底栏/侧边栏与程序化切 tab
  /// 都写这同一个属性，不必再自己记一份。
  private var currentTabIndex: Int {
    // 索引一律走壳层的 selectedRouteIndex：18 按 UITab.identifier、17 按
    // tabBarItem.accessibilityIdentifier 取**路由索引**（与屏幕排列无关，
    // 侧边栏编辑改视觉顺序时 tabIndex / 角标 / 重按回调必须恒定）。
    let index = tabBar?.selectedRouteIndex ?? 0
    return index >= 0 ? index : 0
  }

  private var currentNav: TiebaRootNavigationController? { tabNavs[currentTabIndex] }

  /// "当前这一屏"所在的栈：手机上二级页压在根容器栈上（见 pushRoute），iPad 压在
  /// 每 tab 独立栈上。按"当前屏"语义工作的查询必须走这里，否则两套栈各说各话
  ///（手机上 goBack 会因 tab 栈只有一层而返回 false：返回没反应）。
  private var activeNav: UINavigationController? {
    if let shellNav, shellNav.viewControllers.count > 1 { return shellNav }
    return currentNav
  }

  private var hostCounter = 0
  private var tabRootHosts: [Int: TiebaRouteHostViewController] = [:]
  /// hostId → 宿主：NSMapTable 强键弱值。压栈页 VC（含整棵列表树、Nuke 任务）
  /// 必须随栈释放——原来用 Dictionary 强持有，每个压过的页都活到进程结束。
  /// 键（NSNumber）弱引用会被立刻回收，所以键必须强持有：仅占一个数字，宿主
  /// 出栈后由 pruneHosts 按 hostId 清掉。
  private let hostsById = NSMapTable<NSNumber, TiebaRouteHostViewController>(
    keyOptions: .strongMemory,
    valueOptions: .weakMemory
  )
  /// 当前 pending 的「去重」标记：防止同一路由被连点两次压两屏。
  private var lastPushSignature: String?
  private var lastPushAt: CFTimeInterval = 0

  /// iPad tab chrome 的形态记忆：当前是否在根屏，以及进二级页前侧边栏是否已被
  /// 用户自己折起来（返回时按这个还原，不强制展开）。
  private var tabChromeAtRoot = true
  private var sidebarHiddenBeforePush = false

  private override init() {
    super.init()
  }

  // MARK: - 生命周期

  /// 建壳并挂到 window。AppDelegate 在 scene 连接时调用一次。
  @discardableResult
  public func install(in window: UIWindow) -> UIViewController {
    self.window = window
    // 依赖倒置的注入点：Core / UI 不认本类，只认 TiebaAppHooks（见该文件的说明）。
    // 装壳时把"下层需要的能力"接上；未装壳前这些口子是 no-op，与改前
    // "调用发生在装壳前也一样落空"语义一致。
    TiebaAppHooks.routing = TiebaAppHooks.Routing(
      setTabBadge: { index, text in TiebaNavigator.shared.setTabBadge(index: index, text: text) },
      navigate: { TiebaNavigator.shared.navigate($0) },
      open: { TiebaNavigator.shared.open(url: $0) },
      scrollCurrentToTop: { TiebaNavigator.shared.scrollCurrentToTop() },
      applyTheme: { TiebaNavigator.shared.applyTheme($0) },
      setDefaultStatusBarStyle: { TiebaNavigator.shared.setDefaultStatusBarStyle($0) },
      showSignToast: { text, presenter in TiebaSignToast.show(text, on: presenter) }
    )

    let tab = TiebaMainTabBarController()
    tab.onReselect = { [weak self] idx in
      // 原生 tab 根屏直接受理（JS 侧 TAB_RESELECT 订阅在页面原生化后消失）。
      // onReselect 是 @MainActor 闭包（TiebaNavigationShell.swift），这里本就是主 actor 上下文，
      // 所以直接访问 @MainActor 的宿主/页面即可 —— 原来的 MainActor.assumeIsolated 是多余的绕过标注。
      guard let self else { return }
      if let host = self.tabRootHosts[idx],
        let screen = host.children.first as? TiebaTabReselectable
      {
        screen.tabReselected()
      }
    }
    tabBar = tab

    // 四个 tab 各挂一条自己的导航栈。iOS 18 起用 UITab 描述（tabs 一旦设置，
    // viewControllers 就不再驱动界面），才能拿到 mode = .tabSidebar 的侧边栏形态；
    // iOS 17 没有 UITab/tabs，退回 viewControllers + UITabBarItem（标识写在
    // tabBarItem.accessibilityIdentifier 上）。
    // 降级只换"底栏怎么描述"：选中态/角标/切 tab 全走壳层的
    // selectedRouteIndex / selectRoute / setBadge 同一入口，导航语义一行未动。
    var rootNavs: [UIViewController] = []
    for (idx, route) in TiebaRouteTable.tabRoots.enumerated() {
      let host = makeHost(route: route, eager: false)
      tabRootHosts[idx] = host
      let nav = TiebaRootNavigationController(rootViewController: host)
      nav.delegate = self
      nav.setNavigationBarHidden(true, animated: false)
      // Hero 默认关闭，只在"点卡片进帖"那一跳临时开（见 armHero）。
      // ⚠️ 开启会把现有 delegate 存进 previousNavigationDelegate 并转发 willShow/didShow，
      // 而本仓顶栏系统靠 didShow 驱动 ⇒ 必须先设本仓 delegate 再开 Hero（本行之上已设）。
      nav.hero.navigationAnimationType = .auto
      tabNavs[idx] = nav
      if #unavailable(iOS 18.0) {
        // 降级：iOS 17 用经典 UITabBarItem（无 UITab / preferredPlacement /
        // customizationIdentifier）。选中态实心图在低版本 SDK 上一直是
        // `selectedImage` 构造参数，直接给；标识打在 accessibilityIdentifier 上，
        // 供 index(of:)/selectedRouteIndex/selectRoute/setBadge 按标识回归。
        // （UITab 是 18+ 类型，那一支的底栏项在循环之后统一建，见下。）
        let spec = Self.tabSpec(index: idx)
        let item = UITabBarItem(
          title: spec.title,
          image: UIImage(systemName: spec.normal),
          selectedImage: UIImage(systemName: spec.selected)
        )
        item.accessibilityIdentifier = TiebaRouteTable.tabNames[idx]
        nav.tabBarItem = item
      }
      rootNavs.append(nav)
    }
    if #available(iOS 18.0, *) {
      // UITab 是 iOS 18 起的类型，只能在可用性分支里构造（循环里做不了类型声明）。
      var items: [UITab] = []
      for (idx, nav) in rootNavs.enumerated() {
        let spec = Self.tabSpec(index: idx)
        let item = UITab(
          title: spec.title,
          image: UIImage(systemName: spec.normal),
          identifier: TiebaRouteTable.tabNames[idx]
        ) { _ in nav }
        // 选中态实心变体是原 UITabBarItem 时代的既有观感，不能丢；但 `selectedImage`
        // 的**声明**要 26.6+ 的 SDK 才有（CI 是 SDK 26.5，直接写编译不过），运行时
        // 26.1+ 已支持 ⇒ 按 KVC 落值，缺这个键就跳过。
        if #available(iOS 26.1, *), item.responds(to: NSSelectorFromString("setSelectedImage:")) {
          item.setValue(UIImage(systemName: spec.selected), forKey: "selectedImage")
        }
        // 根 tab 的 automatic placement 解析成 .default（"可增可删"）——侧边栏 Edit
        // 因此允许拖动却落不下来（用户实测"拖完保存顺序不变"）。.movable = 可移不可删，
        // 正好是本 App 要的：四个 tab 是固定功能，只该排序。
        item.preferredPlacement = .movable
        items.append(item)
      }
      // 顺序按上次拖好的标识列表摆放：UIKit 自己的持久化存在系统库里、我们读不到也不可控，
      // 所以顺序的唯一权威是本仓存的这份（见 saveTabOrder / displayOrderDidChangeFor）。
      tab.tabs = Self.orderedForDisplay(items)
      // ⚠️ 不要再试图设 allowsReordering：探针实测根级扁平 tab 的 `parent` 在
      // 赋值后、willAppear、didAppear 三个时刻都是 nil（UIKit 的根分组不对外暴露，
      // UITabSidebarItemRequest 也只给 tab/action），拿不到 UITabGroup 就没这个开关。
      // 根 tab 的"可重排"由 preferredPlacement 决定（见上），顺序落盘见下方 saveTabOrder。
      // 给系统侧的自定义状态一个稳定标识，别落到"系统默认"上（同一 App 只有一个
      // tab bar controller，但显式声明后系统那侧的持久化范围才是确定的）。
      tab.customizationIdentifier = "tieba-main-tabs"
    } else {
      // 降级：iOS 17 由 viewControllers 驱动界面（顺序 = 路由表声明顺序，17 无
      // 侧边栏编辑，故不存在"顺序落盘/回归"这回事）。
      tab.setViewControllers(rootNavs, animated: false)
    }
    tab.configureSidebar()
    tab.applyTheme(TiebaChromeTheme.current)

    let shell = TiebaRootNavigationController(rootViewController: tab)
    shell.delegate = self
    shell.setNavigationBarHidden(true, animated: false)
    window.rootViewController = shell
    shellNav = shell
    return shell
  }

  /// RJ 侧下发主题（跟随应用内主题，不是系统外观）。
  public func applyTheme(_ theme: TiebaChromeTheme) {
    // 单一数据源在 Core（TiebaChromeTheme.current）：本类只是**写**入点。
    // 原来这里是 self.theme = theme、读者绕道 TiebaChromeTheme.current。
    TiebaChromeTheme.current = theme
    tabBar?.applyTheme(theme)
    // 栏按钮色用 navTint 而不是 tint：默认主题下底栏选中是主色、返回箭头是
    // colors.text，两者本来就不是一个颜色（原 headerTint 的语义）。
    for nav in tabNavs.values {
      nav.navigationBar.tintColor = theme.navTint
      nav.view.backgroundColor = theme.background
    }
    // 手机上在展示二级页的是根容器栈（见 activeNav）：它的栏与底色同样要跟上，
    // 否则主题切换时压在上面的页面顶栏还是旧色。
    shellNav?.navigationBar.tintColor = theme.navTint
    shellNav?.view.backgroundColor = theme.background
    // 已建好的宿主底色也要跟上：主题切换时在屏的页面转场首帧不该闪旧色。
    for host in liveHosts() {
      host.viewIfLoaded?.backgroundColor = theme.background
      // 栏按钮建时捕获了当时的主题色，这里重着色。
      for item in (host.navigationItem.leftBarButtonItems ?? [])
        + (host.navigationItem.rightBarButtonItems ?? []) {
        item.tintColor = theme.navTint
      }
      // 原生页面的系统语义色也要跟上（应用内主题 ≠ 系统外观）。
      host.syncNativeScreenChrome()
      // 页面自绘部分（页面底色、列表色板、页头、行内描边）也重刷一遍：跟随系统
      // 模式下系统切深浅走的就是这条路（用户报"卡片变了、页面底色还是白的"）。
      host.refreshScreenTheme()
    }
  }

  /// 底栏滚动收纳开关。
  public func setTabBarMinimizeEnabled(_ enabled: Bool) {
    tabBar?.tabBarMinimizeEnabled = enabled
  }

  /// 底栏角标（未读数）。空串清除。
  /// ⚠️ 只写 `UITab.badgeValue`，不碰 `tabBar.standardAppearance`：任何
  /// bar 级 appearance 写入都会让 UIKit 退出自动 Liquid Glass 渲染管线，
  /// 底栏退化成旧磨砂（实心色带）——v34 起的既有结论。
  public func setTabBadge(index: Int, text: String) {
    guard index >= 0, index < TiebaRouteTable.tabNames.count else { return }
    // 18 写 UITab.badgeValue、17 写 tabBarItem.badgeValue；入口只有这一个。
    tabBar?.setBadge(text.isEmpty ? nil : text, routeIndex: index)
  }

  /// 四个 tab 的图标/标签（与 NativeTabs.Trigger 的声明一致：systemImage 的
  /// 未选中/选中变体、10pt 半粗标签）。
  private static func tabSpec(index: Int) -> (normal: String, selected: String, title: String) {
    let spec: (normal: String, selected: String, title: String)
    switch index {
    case 0: spec = ("house", "house.fill", "关注")
    case 1: spec = ("safari", "safari.fill", "动态")
    case 2: spec = ("bell", "bell.fill", "消息")
    default: spec = ("person", "person.fill", "我的")
    }
    return spec
  }

  /// 侧边栏编辑保存下来的 tab 顺序（Tab 标识以逗号相连）。空 = 还没改过，用声明顺序。
  private static func savedTabOrder() -> [String] {
    let raw = TiebaPreferences.string("tabOrder", default: "")
    guard !raw.isEmpty else { return [] }
    let known = Set(TiebaRouteTable.tabNames)
    // 只认当前仍存在的 tab：版本升级删掉某个 tab 后，旧顺序里的死键不能进列表。
    return raw.split(separator: ",").map(String.init).filter { known.contains($0) }
  }

  /// 按存下的顺序摆放：没记录的 tab 保持声明顺序跟在后面（新增 tab 不会被挤掉）。
  @available(iOS 18.0, *)
  private static func orderedForDisplay(_ items: [UITab]) -> [UITab] {
    let saved = savedTabOrder()
    guard !saved.isEmpty else { return items }
    var rest = items
    var ordered: [UITab] = []
    for identifier in saved {
      guard let index = rest.firstIndex(where: { $0.identifier == identifier }) else { continue }
      ordered.append(rest.remove(at: index))
    }
    return ordered + rest
  }

  /// 编辑保存时落盘（UITabBarControllerDelegate 回调里调）。
  static func saveTabOrder(_ identifiers: [String]) {
    guard !identifiers.isEmpty else { return }
    TiebaPreferences.set("tabOrder", string: identifiers.joined(separator: ","))
  }

  // MARK: - 指令

  /// 路由入口（类型化）。深链先经 TiebaRouteTable.parse 产出同一个类型，再走这里；
  /// 调用点与深链只有这一条构造/压栈路径。
  @discardableResult
  /// H16：原 mode（push/replace/root）里 replace 全仓零调用、root 不可达（notifications 是
  /// tab 根屏，navigate 在 tab 分流就 return），却为不可达路径留了一处无防御下标
  /// targetNav.viewControllers[0]（栈空即崩）——整层已删，行为零变化。
  public func navigate(_ route: TiebaRoute) -> Bool {
    let entry = TiebaRouteTable.entry(named: route.name)
    if let tabIdx = entry?.tabIndex {
      // tab 根屏：语义是"切到那个 tab"，不是压栈。expo-router 里
      // router.push('/(tabs)/notifications') 同样只是切 tab。
      selectTab(tabIdx)
      // 深链参数（notifications/2 → 初始分段）交给已原生的根屏；未实现的根屏
      // 无接收方，参数照旧丢弃。与 selectTab 同款：调用点本就在主线程，
      // assumeIsolated 把这条既有契约告诉编译器。
      if let initialTab = route.initialTab, let host = tabRootHosts[tabIdx] {
        MainActor.assumeIsolated {
          (host.children.first as? TiebaTabRouteParamReceiving)?.receiveInitialTab(initialTab)
        }
      }
      return true
    }
    pushRoute(route)
    return true
  }

  /// 只有"点信息流/吧页卡片进帖"这一跳开 Hero；其余跳转（进吧、进设置…）走系统原生 push。
  /// 判据 = 这一刻有没有该帖的快照（只在列表点卡片时写入）——用 peek 只读，消费权归帖子页。
  ///
  /// 为什么按跳开关：Hero 在没有配对视图时会回落成它自己的 push（整页位移 + 给整棵视图树
  /// 拍快照），明显慢于系统原生（用户实测"进吧/进设置过渡很卡"）。**返回一律系统原生**：
  /// 转场结束即关（见 didShow），所以 pop 不会走 Hero。
  private func armHero(for route: TiebaRoute, target: UINavigationController?) {
    guard let nav = target else { return }
    MainActor.assumeIsolated {
      var fromCard = false
      if case .thread(let id, _, _, let fromFavorites) = route, !fromFavorites {
        fromCard = TiebaThreadSnapshots.peek(id: id) != nil
      }
      // 减弱动态效果下回落系统 push：这是全仓幅度最大的页面级动效，其余动效（查看器转场/
      // 首屏入场/骨架扫光等）都有闸门，唯独这条没有。
      nav.hero.isEnabled = fromCard && !UIAccessibility.isReduceMotionEnabled
    }
  }

  private func pushRoute(_ route: TiebaRoute) {
    guard let nav = currentNav else { return }
    // 连点去重：同一路由 450ms 内只认一次（原 RN 侧靠 Pressable 的按压态挡，
    // 原生栏按钮没有那层，快速双击会压出两屏同样内容）。
    let sig = route.signature
    let now = CACurrentMediaTime()
    if sig == lastPushSignature, now - lastPushAt < 0.45 { return }
    lastPushSignature = sig
    lastPushAt = now

    let isPad = tabBar?.traitCollection.userInterfaceIdiom == .pad
    // 二级页压到哪条栈：iPad 压每 tab 独立栈（侧边栏布局，压栈只换内容区）；
    // 手机压根容器栈——整页盖住 tab 控制器，底栏玻璃 dock 从结构上不可能残留
    //（iOS 26 的私有 dock 视图对一切视图级修补免疫，见 syncTabChrome 注释）。
    let targetNav: UINavigationController = isPad ? nav : (shellNav ?? nav)

    armHero(for: route, target: targetNav)

    let host = makeHost(route: route, eager: true)
    let entry = TiebaRouteTable.entry(named: route.name)

    switch entry?.presentation ?? .push {
    case .push:
      // 降级：iOS 17 没有 setTabBarHidden(_:animated:)（18 起）。那一档用经典的
      // hidesBottomBarWhenPushed：压栈页自带"藏底栏"标记，UIKit 负责布局与安全区，
      // 返回时自动还原（18+ 仍由 syncTabChrome 的三写统一管，见那里的注释）。
      if #unavailable(iOS 18.0) {
        host.hidesBottomBarWhenPushed = true
      }
      targetNav.pushViewController(host, animated: true)
    case .sheet(let detents, let grabber, let cornerRadius):
      // 表单要自带导航栏才能显示标题与 headerRight（登录页有"登录帮助"按钮、
      // 且 headerBackVisible: false —— 只能拖拽关闭，所以标题必现）。
      // headerShown: false 的（thread/[id]/more 自带把手与标题）直接上推。
      let chrome = entry?.chrome ?? .standard
      let presentable: UIViewController
      if chrome == .standard {
        let bar = TiebaRootNavigationController(rootViewController: host)
        bar.setNavigationBarHidden(false, animated: false)
        presentable = bar
      } else {
        presentable = host
      }
      presentable.modalPresentationStyle = .pageSheet
      if let sheet = presentable.sheetPresentationController {
        sheet.detents = detents.map { d in
          // 0.3 / 0.55 / 0.9 这类比例值 → 自定义 detent；1.0 用 .large。
          d >= 0.999 ? .large() : .custom(identifier: .init("tieba-\(d)")) { ctx in d * ctx.maximumDetentValue }
        }
        sheet.prefersGrabberVisible = grabber
        sheet.preferredCornerRadius = cornerRadius
        // 表单内的滑动不该把表单拖下去（登录页有可滚动内容）。
        sheet.prefersScrollingExpandsWhenScrolledToEdge = true
      }
      // 从"当前这一屏"推表单：手机上二级页正压在根容器栈上（见 activeNav），
      // 从被盖住的 tab 根屏推会被压在二级页下面（管理/排序这类页内表单）。
      let presenter = activeNav?.topViewController ?? activeNav ?? nav.topViewController ?? nav
      // 表单深浅不单独写：presented 不继承 presenter 的 override，但**继承窗口**
      // ——窗口级 override（TiebaChrome.setChromeDarkMode）明确覆盖该窗口内的
      // 所有 presentation（UIView.h: set on UIWindow "also affects presentations
      // that happen inside the window"）。
      presenter.present(presentable, animated: true)
    }
  }

  /// 返回上一屏（栈深 > 1）。返回 false = 已在栈底（调用方决定是否切 tab）。
  @discardableResult
  public func goBack() -> Bool {
    guard let nav = activeNav else { return false }
    if nav.presentedViewController != nil {
      nav.dismiss(animated: true)
      pruneHosts()
      return true
    }
    if nav.viewControllers.count > 1 {
      nav.popViewController(animated: true)
      pruneHosts()
      return true
    }
    return false
  }

  /// 关掉当前上推的表单（登录页 / 更多）。
  public func dismissPresented(animated: Bool) {
    activeNav?.presentedViewController?.dismiss(animated: animated)
    pruneHosts()
  }

  /// 能否返回（router.canGoBack）。
  public var canGoBack: Bool {
    guard let nav = activeNav else { return false }
    if nav.presentedViewController != nil { return true }
    return nav.viewControllers.count > 1
  }

  public func selectTab(_ index: Int) {
    guard let tabBar, index >= 0, index < TiebaRouteTable.tabNames.count else { return }
    // 每个 tab 一条自己的栈 ⇒ 切 tab 只换选中的那条，各 tab 保留自己的去处。
    // （单栈时代这里要 pop 回根，否则会停在别的 tab 压出来的页上；分栈后那个
    // 问题不存在了，这也就成了 iPad 的常规交互。）
    // 手机是单条根容器栈、二级页正压在 tab 控制器上面（见 pushRoute）：切 tab 前
    // 必须先收掉它，否则底下换了、屏上还是那个二级页（深链切 tab 会走到这里）。
    if tabBar.traitCollection.userInterfaceIdiom != .pad, let shellNav,
      shellNav.viewControllers.count > 1
    {
      MainActor.assumeIsolated {
        _ = shellNav.popToRootViewController(animated: false)
        self.pruneHosts()
      }
    }
    // 18 写 selectedTab、17 写 selectedIndex；都按**标识**定位，不按屏幕位置。
    tabBar.selectRoute(index)
  }

  /// 让当前这一屏的列表回到顶部（双击顶栏）。
  public func scrollCurrentToTop() {
    let host = currentHost() ?? scrollableTabHost()
    guard let host, let sv = host.scrollViewForSystem() else { return }
    let top = CGPoint(x: 0, y: -sv.adjustedContentInset.top)
    sv.setContentOffset(top, animated: true)
  }

  private func scrollableTabHost() -> TiebaRouteHostViewController? {
    tabRootHosts[currentTabIndex]
  }

  // MARK: - 屏级配置


  /// 全局状态栏默认字色（由工具栏主色调/状态栏字色偏好算出后下发）。
  /// 逐屏覆盖优先于它。
  private(set) var defaultStatusBarStyle: UIStatusBarStyle = .default

  public func setDefaultStatusBarStyle(_ style: UIStatusBarStyle) {
    guard defaultStatusBarStyle != style else { return }
    defaultStatusBarStyle = style
    for host in liveHosts() { host.refreshStatusBarStyle() }
  }


  // MARK: - 宿主

  private func makeHost(route: TiebaRoute, eager: Bool) -> TiebaRouteHostViewController {
    hostCounter += 1
    let hostId = hostCounter
    // TiebaRouteHostViewController 继承 UIViewController（@MainActor），而本类
    // 不是 @MainActor（@unchecked Sendable：状态只允许主线程碰，全部入口收在
    // onMain / AppDelegate 主线程）。assumeIsolated 把"makeHost 只在主线程调用"
    // 这条既有契约显式告诉编译器。
    let host: TiebaRouteHostViewController = MainActor.assumeIsolated {
      // 类型化路由的每个 case 都有页面（make 非可选）：这里没有"未登记就换页"的兜底。
      let native = TiebaNativeRouteTable.make(route)
      return TiebaRouteHostViewController(route: route, hostId: hostId, nativeChild: native)
    }
    hostsById.setObject(host, forKey: NSNumber(value: hostId))
    if eager {
      // 压栈的屏：先让内容视图建好再起转场，否则转场期间是一张空白页。
      host.loadViewIfNeeded()
    }
    return host
  }

  private func currentHost() -> TiebaRouteHostViewController? {
    activeNav?.topViewController as? TiebaRouteHostViewController
  }

  /// hostId → 宿主（弱值，宿主已释放即 nil）。
  private func host(_ hostId: Int) -> TiebaRouteHostViewController? {
    hostsById.object(forKey: NSNumber(value: hostId))
  }

  /// 表里仍活着的宿主（弱值自动置空，枚举天然只返回活对象）。
  private func liveHosts() -> [TiebaRouteHostViewController] {
    guard let enumerator = hostsById.objectEnumerator() else { return [] }
    var result: [TiebaRouteHostViewController] = []
    while let object = enumerator.nextObject() {
      if let host = object as? TiebaRouteHostViewController { result.append(host) }
    }
    return result
  }

  /// 清掉不再挂在栈/底栏/上推链上的宿主条目（pop / replace / root / dismiss 后）。
  /// 弱值本身不持有 VC，这里只回收已出栈的 hostId 键，防止表随压栈无限增长。
  private func pruneHosts() {
    var kept = Set<Int>()
    func collect(_ vc: UIViewController) {
      if let host = vc as? TiebaRouteHostViewController { kept.insert(host.hostId) }
    }
    // 四条 tab 栈都要扫：非当前 tab 停在页面上的宿主也必须留在表里。
    func collect(from nav: UINavigationController) {
      for vc in nav.viewControllers { collect(vc) }
      var presented = nav.presentedViewController
      while let current = presented {
        collect(current)
        if let inner = current as? UINavigationController {
          for vc in inner.viewControllers { collect(vc) }
        }
        presented = current.presentedViewController
      }
    }
    for nav in tabNavs.values { collect(from: nav) }
    // 手机上二级页压在根容器栈上（见 activeNav）：漏扫它 = 在屏页被移出表，
    // 主题/状态栏刷新会跳过它。
    if let shellNav { collect(from: shellNav) }
    let enumerator = hostsById.keyEnumerator()
    var victims: [NSNumber] = []
    while let key = enumerator.nextObject() as? NSNumber, !kept.contains(key.intValue) {
      victims.append(key)
    }
    for key in victims { hostsById.removeObject(forKey: key) }
  }

  // MARK: - 深链

  /// 深链统一入口（UIOpenURLContext / 通知 data.url 都走这里）。
  /// 返回值 = 是否消费掉了这个 URL。
  ///
  /// 内部形态与迁移前逐字相同：各分支先还原成旧 navigate(path:) 收到的那个
  /// 字符串（含 query），再由 TiebaRouteTable.parse 产出类型化路由——深链只有
  /// 这一条解析路径，且解析出的类型与本地跳转共用同一个构造入口。
  @discardableResult
  public func open(url: URL) -> Bool {
    // H17：旧实现三种口径混用（notifications 用未锚定子串正则、search/history 用 hasPrefix、
    // 其余走 URLComponents），结果是 absoluteString 里**含**自有深链子串的外来 URL 也会被吞掉
    // ——例如推送 payload 的 https 链接 query 里塞一段 tblite://thread/456，就会盖过真实路径。
    // 现在统一结构化解析一次，按 scheme/host/path/query 判定；解析不出来就返回 false（不消费）。
    guard let components = URLComponents(string: url.absoluteString) else { return false }
    let scheme = components.scheme?.lowercased() ?? ""
    let host = components.host?.lowercased() ?? ""
    let path = components.path
    // 段切分必须用**未解码**的 percentEncodedPath：components.path 已把 %2F 还原成真斜杠，
    // 含斜杠的吧名会被切成多段（轻则 notFound，重则静默命中别的路由）。
    let encodedPath = components.percentEncodedPath
    let query = { (name: String) -> String? in
      components.queryItems?.first { $0.name == name }?.value
    }

    // 自有 scheme：tiebalite://<host>/<path>（tblite:// 是同一套的短写）。
    if scheme == "tiebalite" || scheme == "tblite" {
      switch host {
      case "notifications":
        // tiebalite://notifications/2 → 初始分段交给 tab 根屏（走 tab 分流，不压栈）。
        let digits = path.split(separator: "/").first.map(String.init) ?? ""
        return navigateDeepLink(digits.isEmpty ? "notifications" : "notifications?initialTab=\(digits)")
      case "thread":
        guard let tid = path.split(separator: "/").first.map(String.init), !tid.isEmpty, tid.allSatisfy({ $0.isNumber }) else {
          break
        }
        return navigateDeepLink("thread/\(tid)")
      case "forum":
        // 吧名可含斜杠转义与百分号编码：切段在 percentEncodedPath 上做（%2F 不会被当成
        // 分隔符），再对**每段各解码一次**——整串解码会把字面量 %252F 二次解码。
        let raw = encodedPath.hasPrefix("/") ? String(encodedPath.dropFirst()) : encodedPath
        guard !raw.isEmpty else { break }
        let name = raw.split(separator: "/", omittingEmptySubsequences: false)
          .map { $0.removingPercentEncoding ?? String($0) }
          .joined(separator: "/")
        return navigateDeepLink("forum/\(name)")
      case "search":
        // 搜索：q 非空则直接出结果（快捷指令/调试直达），空 q 只开搜索页。
        let q = query("q") ?? ""
        return navigateDeepLink(q.isEmpty ? "search/index" : "search/index?q=\(TiebaRoutePath.segment(q))")
      case "history":
        // 浏览记录：tab=forum 时直接开吧历史分段。
        return navigateDeepLink(query("tab") == "forum" ? "history?tab=forum" : "history")
      default:
        break
      }
      return false
    }

    // 百度系 URL（com.baidu.tieba:// / *.tieba.baidu.com）：同样只认结构化字段。
    if let tid = Self.extractThreadId(scheme: scheme, host: host, path: path, query: query) {
      return navigateDeepLink("thread/\(tid)")
    }
    if let name = Self.extractForumName(scheme: scheme, host: host, path: path, query: query) {
      return navigateDeepLink("forum/\(name)")
    }
    return false
  }

  /// 深链字符串 → 类型化路由 → 同一条构造路径。解析不出就落「找不到页面」
  ///（旧行为：打错的深链不静默吞掉，也不空白）。
  @discardableResult
  private func navigateDeepLink(_ path: String) -> Bool {
    navigate(TiebaRouteTable.parse(path: path) ?? .notFound(path: path))
    return true
  }

  /// src/utils/index.ts 的 extractThreadId 原生版（H17：入参是 URLComponents 已解好的结构化字段，
  /// 不再拿 absoluteString 做未锚定子串匹配——理由见 open(url:) 的 H17 注释）。
  static func extractThreadId(scheme: String, host: String, path: String, query: (String) -> String?) -> String? {
    if scheme == "com.baidu.tieba", host == "unidispatch" || path.contains("/unidispatch") {
      if let tid = query("tid") { return tid }
    }
    if Self.isTiebaDomain(host) {
      if path.hasPrefix("/p/") {
        return String(path.dropFirst(3)).split(separator: "/").first.map(String.init)
      }
      if path == "/f" || path == "/mo/q/m" {
        if let kz = query("kz") { return kz }
      }
    }
    return nil
  }

  /// 吧名提取（同样是结构化判定）。吧名可含斜杠转义与百分号编码，由调用方按 path 解出。
  static func extractForumName(scheme: String, host: String, path: String, query: (String) -> String?) -> String? {
    if scheme == "com.baidu.tieba", (host == "unidispatch" || path.contains("/unidispatch")), path.hasSuffix("/frs") {
      return query("kw")
    }
    if Self.isTiebaDomain(host) {
      if path == "/f" || path == "/mo/q/m" {
        return query("kw") ?? query("word")
      }
    }
    return nil
  }

  private static func isTiebaDomain(_ host: String) -> Bool {
    let h = host.lowercased()
    return h == "tieba.baidu.com" || h.hasSuffix(".tieba.baidu.com")
  }
}

// MARK: - 导航栏可见性（逐屏）

extension TiebaNavigator: UINavigationControllerDelegate {
  /// 每屏的导航栏形态不同（tab 根屏 / webview / 更多 无栏，其余有栏）。
  /// 必须在 willShow 里无动画设置——放到 viewWillAppear 里会跟着转场一起滑，
  /// 表现为"栏从上面压下来"。
  public func navigationController(
    _ navigationController: UINavigationController,
    willShow viewController: UIViewController,
    animated: Bool
  ) {
    applyBarVisibility(shouldHideBar(in: viewController), to: navigationController)
    syncTabChrome(for: navigationController)
  }

  public func navigationController(
    _ navigationController: UINavigationController,
    didShow viewController: UIViewController,
    animated: Bool
  ) {
    // 转场落定后按**实际栈顶**再校一次：右滑中途松手（转场取消）时栈顶仍是原页，
    // willShow 已按目标页隐过栏，这里把栏还给仍在上面的那一屏。
    applyBarVisibility(shouldHideBar(in: viewController), to: navigationController)
    syncTabChrome(for: navigationController)
    // 滚动视图的跟踪关联由各宿主 VC 自己在 viewDidLayoutSubviews 里做
    // （setContentScrollView 是子 VC 的职责，容器没有替它设的 API）。
    // 转场完成即重扫（原来监听未公开的 UINavigationControllerDidShowNotification，
    // 2026-09-13 改为走这个公开回调）：push/pop 动画期间 RunLoop 处于 tracking
    // 模式，动画结束后新 bar 已建成但还没被处理（"进帖子页无效果"的 timing 缺口）。
    _ = TiebaChrome.forceNavBarLiquidGlass()
    // 转场一结束就关 Hero：这样"进入"用魔改，**返回与后续跳转全走系统原生**
    //（Hero 只在 push 那一刻被读，pop 时已关 ⇒ 系统 push/pop 动画）。
    // 这里是 UINavigationControllerDelegate 的回调（协议方法本身就在主 actor），
    // 直接写即可 —— 原来的 MainActor.assumeIsolated 是多余的。
    if navigationController.hero.isEnabled { navigationController.hero.isEnabled = false }
  }

  /// 该屏是否无栏（tab 根屏 / webview / thread/[id]/more）。
  ///
  /// ⚠️ 根容器栈的底屏是 tab 控制器，它的栏必须隐——漏了这一支，容器栈每次
  /// willShow/didShow（delegate 已挂）都会把一条**透明**栏摆到状态栏下方：
  /// 看不见，但实打实占掉 54pt 安全区，表现为 tab 根屏顶部一大片空白
  ///（用户报「动态页分段栏离状态栏很远」，lldb 实证 barHidden=false barH=54）。
  private func shouldHideBar(in viewController: UIViewController) -> Bool {
    if viewController is TiebaMainTabBarController { return true }
    guard let host = viewController as? TiebaRouteHostViewController else { return false }
    return (TiebaRouteTable.entry(named: host.route.name)?.chrome ?? .standard) == .hidden
  }

  /// tab chrome（手机底栏 / iPad 侧边栏 + 折叠后顶部的 tab 横幅）只属于 tab 根屏：
  /// 压进吧页、帖子页、搜索页等二级页后整套收起，宽度全给内容，返回走栏内返回箭头；
  /// 回到根屏再还原（iPad 还原的是用户当时的折叠状态，不是强制展开）。
  ///
  /// 底栏三写（缺一不可，均每次转场重写）：
  /// 1. `setTabBarHidden`（iOS 18 起）：布局与安全区（内容让位、返回时还原）；
  /// 2. `isHidden`：把 UITabBar 视图整个拿掉；
  /// 3. `removeAllAnimations()`：**真正的元凶**——系统会在底栏 layer 上挂透明度动画
  ///    （下滑收纳的淡出、转场透明度都算），有动画在，layer 的渲染就不理会
  ///    hidden/alpha=0 的模型值，玻璃以半透明残留在屏底：整条栏状态剩一条与底栏
  ///    等宽等高的模糊带、收纳状态剩一个圆（lldb 视图树实证：
  ///    `UITabBar … alpha=0; hidden=YES; animations={opacity=CABasicAnimation}`）。
  /// iOS 17 没有 setTabBarHidden：那一档退回 push 时的 hidesBottomBarWhenPushed
  ///（经典底栏上行为正确，见 pushRoute）。
  private func isAtRoot(of navigationController: UINavigationController) -> Bool {
    navigationController.viewControllers.count <= 1
  }

  private func syncTabChrome(for navigationController: UINavigationController) {
    guard let tabBar else { return }
    let atRoot = navigationController.viewControllers.count <= 1
    // 侧边栏只在"根屏 ↔ 二级页"翻转时动：它要记住用户当时的折叠状态。
    if atRoot != tabChromeAtRoot {
      tabChromeAtRoot = atRoot
      // 降级：侧边栏（tabBar.sidebar）是 iOS 18 起的形态；17 只有底栏，
      // 没有可折叠的 sidebar，这一段整体跳过。
      if #available(iOS 18.0, *), tabBar.traitCollection.userInterfaceIdiom == .pad {
        if atRoot {
          tabBar.sidebar.isHidden = sidebarHiddenBeforePush
        } else {
          sidebarHiddenBeforePush = tabBar.sidebar.isHidden
          tabBar.sidebar.isHidden = true
        }
      }
    }
    // 底栏可见性**每次转场都重写**：转场期间可能有别的东西动过它（Hero 收尾、
    // 系统收纳动画），只写一次就会漏。
    // 降级：setTabBarHidden(_:animated:) 是 iOS 18 起的 API（同时管布局与安全区）；
    // 17 上跳过这一写，由下面的 isHidden + removeAllAnimations 两写接管，压栈页
    // 另有 hidesBottomBarWhenPushed（见 pushRoute）补上安全区那一半。
    if #available(iOS 18.0, *) {
      tabBar.setTabBarHidden(!atRoot, animated: false)
    }
    // isHidden 写在 UITabBar 视图上：把整条栏（含液态玻璃背景、收纳态的圆）从屏上拿掉。
    tabBar.tabBar.isHidden = !atRoot
    // 挂在 layer 上的透明度动画不清掉，前两写的模型值就不生效（见上注释）。
    tabBar.tabBar.layer.removeAllAnimations()
    // iOS 26 的悬浮底栏玻璃 dock 是独立私有视图（_UIBottomTabBarGroupView，
    // lldb 视图树实证：与 UITabBar 平级、整棵子树含 4 个 tab 按钮），上面三写
    // 全部作用在 UITabBar 上管不到它——必须找到它一起藏，残留才会消失。
    hideFloatingTabDock(in: tabBar.view, hidden: !atRoot)
    if let window = tabBar.view.window {
      hideFloatingTabDock(in: window, hidden: !atRoot)
    }
    // 转场收尾/悬浮容器重排会在我们写完之后把 dock 重新亮出来（实证）：落定后
    // 再补几次重申，确保压栈期间它一直是收起的。
    for delay in [0.15, 0.5, 1.2] {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
        guard let self, let tabBar = self.tabBar, !self.isAtRoot(of: navigationController) else { return }
        tabBar.tabBar.isHidden = true
        self.hideFloatingTabDock(in: tabBar.view, hidden: true)
        if let window = tabBar.view.window {
          self.hideFloatingTabDock(in: window, hidden: true)
        }
      }
    }
  }

  /// 在 tab 控制器的视图树里找玻璃 dock 并设置可见性。
  /// ⚠️ 只能按类名匹配：UIKit 没有公开 API 能拿到 iOS 26 的悬浮底栏玻璃 dock
  /// （_UIBottomTabBarGroupView 与 UITabBar 平级）。这个字符串依赖是**已知且刻意**的取舍，
  /// 不是疏漏：它随 iOS 版本失效时表现为"压栈期间底部残留一条玻璃"，不影响功能。
  /// （原实现在命中时还写一个 accessibilityIdentifier 作调试标记，全仓无人读取 → 已删。）
  private func hideFloatingTabDock(in view: UIView, hidden: Bool) {
    for subview in view.subviews {
      if NSStringFromClass(type(of: subview)).contains("_UIBottomTabBarGroupView") {
        subview.isHidden = hidden
      }
      hideFloatingTabDock(in: subview, hidden: hidden)
    }
  }

  /// 立即落定栏的可见性（**含返回，不许延到转场结束**），并把 alpha 一起归零/还原。
  ///
  /// ⚠️ 为什么不能延后隐：栏的可见性会进入目标页的安全区。返回过程里目标页若按"有栏"
  /// 布局，它顶部的 picker 就被顶下去，转场结束栏一隐再弹回原位（用户 2026-09-19 报的
  /// "picker 被顶下来然后瞬间位移"）。立即隐 ⇒ 目标页从第一帧就是正确布局。
  /// ⚠️ 为什么还要动 alpha：交互式转场里 UIKit 会把隐栏推迟落地、只留一个栏背景在屏上
  ///（用户报的"返回按钮没了、只剩顶栏背景"）。归零 alpha 消掉这个中间态。
  private func applyBarVisibility(_ hidden: Bool, to navigationController: UINavigationController) {
    navigationController.navigationBar.alpha = hidden ? 0 : 1
    if navigationController.isNavigationBarHidden != hidden {
      navigationController.setNavigationBarHidden(hidden, animated: false)
    }
  }
}

// MARK: - 顶栏头像按钮

/// 导航栏右侧的吧头像按钮（替 ThreadHeader / ForumAvatarWithHdr 的 React 节点）。
/// 自带 App Store 风格按压高光（按下瞬间白色斜向扫光），与 HdrPressable 一致。
final class TiebaBarAvatarButton: UIControl {
  var onTap: (() -> Void)?
  private let imageView = UIImageView()
  private let flash = UIView()

  override init(frame: CGRect) {
    super.init(frame: frame)
    imageView.contentMode = .scaleAspectFill
    imageView.clipsToBounds = true
    imageView.layer.cornerRadius = frame.width / 2
    imageView.layer.borderWidth = 0.5
    imageView.layer.borderColor = UIColor.separator.cgColor
    imageView.translatesAutoresizingMaskIntoConstraints = false
    flash.backgroundColor = UIColor.white.withAlphaComponent(0.28)
    flash.alpha = 0
    flash.isUserInteractionEnabled = false
    flash.translatesAutoresizingMaskIntoConstraints = false
    flash.layer.cornerRadius = frame.width / 2
    flash.clipsToBounds = true
    addSubview(imageView)
    addSubview(flash)
    NSLayoutConstraint.activate([
      imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
      imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
      imageView.topAnchor.constraint(equalTo: topAnchor),
      imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
      flash.leadingAnchor.constraint(equalTo: leadingAnchor),
      flash.trailingAnchor.constraint(equalTo: trailingAnchor),
      flash.topAnchor.constraint(equalTo: topAnchor),
      flash.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
    addTarget(self, action: #selector(handleTap), for: .touchUpInside)
    addTarget(self, action: #selector(handleDown), for: [.touchDown, .touchDragEnter])
    addTarget(self, action: #selector(handleUp), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override var intrinsicContentSize: CGSize { CGSize(width: 30, height: 30) }

  /// 头像（30pt @2x/3x → 60px 目标）：走共享管线，取消/换图由 NukeExtensions 负责。
  /// 按钮随栏一次性建好，不存在同视图重复换图的闪烁问题。
  func load(url: URL) {
    var options = ImageLoadingOptions()
    options.pipeline = TiebaNuke.pipeline
    options.isProgressiveRenderingEnabled = false
    options.processors = [TiebaNuke.resizeProcessor(targetPixelSize: CGSize(width: 60, height: 60))]
    loadImage(with: TiebaNuke.secureURL(url), options: options, into: imageView)
  }

  @objc private func handleTap() { onTap?() }

  // 按压高光就是两段几十毫秒的淡入淡出：系统 UIView.animate 更简洁，也不需要可中断/可拖拽
  // （判据③：系统接口更优的就不动）。
  @objc private func handleDown() {
    TiebaAnimation.animate(duration: 0.08) { self.flash.alpha = 1 }
  }

  @objc private func handleUp() {
    TiebaAnimation.animate(duration: 0.18) { self.flash.alpha = 0 }
  }
}