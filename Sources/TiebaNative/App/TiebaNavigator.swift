import Hero
import Nuke
import NukeExtensions
import UIKit

// 导航协调器：把类型化路由（TiebaRoute）翻译成 UIKit 的压栈/切 tab/上推，
// 原 expo-router 的 router.push/back/replace 语义在这里。
//
// 状态只有一份：rootNav 的 viewControllers 就是当前导航栈，tabBar 就是底栏。

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

/// 压栈方式：push（默认）/ replace（换掉栈顶）/ root（先回到栈底再压）。
/// 深链 tiebalite://notifications/N 走 root，其余迁移后的调用点都是 push。
public enum TiebaNavigationMode: Sendable {
  case push
  case replace
  case root
}

/// NSObject 基类不是装饰：UINavigationControllerDelegate 继承自
/// NSObjectProtocol，Swift 里不能给纯 Swift 类声明这个 conformance。
public final class TiebaNavigator: NSObject, @unchecked Sendable {
  public static let shared = TiebaNavigator()

  private weak var window: UIWindow?
  private var rootNav: TiebaRootNavigationController?
  private var tabBar: TiebaMainTabBarController?
  private var theme: TiebaChromeTheme = .default

  /// 当前主题（宿主 VC 画底色要用，保证转场首帧不闪白）。
  var chromeTheme: TiebaChromeTheme { theme }
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

  private override init() {
    super.init()
  }

  // MARK: - 生命周期

  /// 建壳并挂到 window。AppDelegate 在 scene 连接时调用一次。
  @discardableResult
  public func install(in window: UIWindow) -> UIViewController {
    self.window = window

    let tab = TiebaMainTabBarController()
    tab.onReselect = { [weak self] idx in
      // 原生 tab 根屏直接受理（JS 侧 TAB_RESELECT 订阅在页面原生化后消失）。
      MainActor.assumeIsolated {
        guard let self else { return }
        if let host = self.tabRootHosts[idx],
          let screen = host.children.first as? TiebaTabReselectable
        {
          screen.tabReselected()
        }
      }
    }
    tabBar = tab

    var tabVCS: [UIViewController] = []
    for (idx, route) in TiebaRouteTable.tabRoots.enumerated() {
      let host = makeHost(route: route, eager: false)
      tabRootHosts[idx] = host
      host.tabBarItem = Self.makeTabBarItem(index: idx)
      tabVCS.append(host)
    }
    tab.setViewControllers(tabVCS, animated: false)
    tab.applyTheme(theme)

    let nav = TiebaRootNavigationController(rootViewController: tab)
    nav.delegate = self
    nav.setNavigationBarHidden(true, animated: false)
    // Hero 默认关闭，只在"点卡片进帖"那一跳临时开（见 armHero）。
    // ⚠️ 开启会把现有 delegate 存进 previousNavigationDelegate 并转发 willShow/didShow，
    // 而本仓顶栏系统靠 didShow 驱动 ⇒ 必须先设本仓 delegate 再开 Hero（本行之上已设）。
    nav.hero.navigationAnimationType = .auto
    rootNav = nav
    window.rootViewController = nav
    return nav
  }

  /// RJ 侧下发主题（跟随应用内主题，不是系统外观）。
  public func applyTheme(_ theme: TiebaChromeTheme) {
    self.theme = theme
    tabBar?.applyTheme(theme)
    // 栏按钮色用 navTint 而不是 tint：默认主题下底栏选中是主色、返回箭头是
    // colors.text，两者本来就不是一个颜色（原 headerTint 的语义）。
    rootNav?.navigationBar.tintColor = theme.navTint
    rootNav?.view.backgroundColor = theme.background
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
  /// ⚠️ 只写 `tabBarItem.badgeValue`，不碰 `tabBar.standardAppearance`：任何
  /// bar 级 appearance 写入都会让 UIKit 退出自动 Liquid Glass 渲染管线，
  /// 底栏退化成旧磨砂（实心色带）——v34 起的既有结论。
  public func setTabBadge(index: Int, text: String) {
    guard let vcs = tabBar?.viewControllers, index >= 0, index < vcs.count else { return }
    vcs[index].tabBarItem.badgeValue = text.isEmpty ? nil : text
  }

  /// 四个 tab 的图标/标签（与 NativeTabs.Trigger 的声明一致：systemImage 的
  /// 未选中/选中变体、10pt 半粗标签）。
  private static func makeTabBarItem(index: Int) -> UITabBarItem {
    let spec: (normal: String, selected: String, title: String)
    switch index {
    case 0: spec = ("house", "house.fill", "关注")
    case 1: spec = ("safari", "safari.fill", "动态")
    case 2: spec = ("bell", "bell.fill", "消息")
    default: spec = ("person", "person.fill", "我的")
    }
    let item = UITabBarItem(
      title: spec.title,
      image: UIImage(systemName: spec.normal),
      selectedImage: UIImage(systemName: spec.selected)
    )
    item.accessibilityIdentifier = TiebaRouteTable.tabNames[index]
    return item
  }

  // MARK: - 指令

  /// 路由入口（类型化）。深链先经 TiebaRouteTable.parse 产出同一个类型，再走这里；
  /// 调用点与深链只有这一条构造/压栈路径。
  @discardableResult
  public func navigate(_ route: TiebaRoute, mode: TiebaNavigationMode = .push) -> Bool {
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
    pushRoute(route, mode: mode)
    return true
  }

  /// 只有"点信息流/吧页卡片进帖"这一跳开 Hero；其余跳转（进吧、进设置…）走系统原生 push。
  /// 判据 = 这一刻有没有该帖的快照（只在列表点卡片时写入）——用 peek 只读，消费权归帖子页。
  ///
  /// 为什么按跳开关：Hero 在没有配对视图时会回落成它自己的 push（整页位移 + 给整棵视图树
  /// 拍快照），明显慢于系统原生（用户实测"进吧/进设置过渡很卡"）。**返回一律系统原生**：
  /// 转场结束即关（见 didShow），所以 pop 不会走 Hero。
  private func armHero(for route: TiebaRoute) {
    guard let rootNav else { return }
    MainActor.assumeIsolated {
      var fromCard = false
      if case .thread(let id, _, _, let fromFavorites) = route, !fromFavorites {
        fromCard = TiebaThreadSnapshots.peek(id: id) != nil
      }
      rootNav.hero.isEnabled = fromCard
    }
  }

  private func pushRoute(_ route: TiebaRoute, mode: TiebaNavigationMode) {
    guard let rootNav else { return }
    // 连点去重：同一路由 450ms 内只认一次（原 RN 侧靠 Pressable 的按压态挡，
    // 原生栏按钮没有那层，快速双击会压出两屏同样内容）。
    let sig = route.signature
    let now = CACurrentMediaTime()
    if sig == lastPushSignature, now - lastPushAt < 0.45 { return }
    lastPushSignature = sig
    lastPushAt = now

    armHero(for: route)

    let host = makeHost(route: route, eager: true)
    let entry = TiebaRouteTable.entry(named: route.name)

    switch entry?.presentation ?? .push {
    case .push:
      switch mode {
      case .replace:
        var stack = rootNav.viewControllers
        guard !stack.isEmpty else { return }
        stack[stack.count - 1] = host
        rootNav.setViewControllers(stack, animated: true)
        pruneHosts()
      case .root:
        rootNav.setViewControllers([rootNav.viewControllers[0], host], animated: true)
        pruneHosts()
      case .push:
        rootNav.pushViewController(host, animated: true)
      }
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
      let presenter = rootNav.topViewController ?? rootNav
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
    guard let rootNav else { return false }
    if rootNav.presentedViewController != nil {
      rootNav.dismiss(animated: true)
      pruneHosts()
      return true
    }
    if rootNav.viewControllers.count > 1 {
      rootNav.popViewController(animated: true)
      pruneHosts()
      return true
    }
    return false
  }

  /// 回到栈底（双击底栏 tab / 双击顶栏回顶时用）。
  public func popToRoot() {
    guard let rootNav else { return }
    if rootNav.presentedViewController != nil {
      rootNav.dismiss(animated: true)
      return
    }
    guard rootNav.viewControllers.count > 1 else { return }
    // popToRootViewController 的 [UIViewController]? 是 non-Sendable：就算 discard，
    // 结果仍要从主 actor 方法"返回"到非隔离上下文，Swift 6.4 依旧判 RegionIsolation。
    // 改经 @unchecked Sendable 的 self 读 rootNav（同一对象），在 assumeIsolated 内
    // 调用并就地丢弃结果——同 actor 调用，不产生跨域结果。
    MainActor.assumeIsolated {
      _ = self.rootNav?.popToRootViewController(animated: true)
      self.pruneHosts()
    }
  }

  /// 关掉当前上推的表单（登录页 / 更多）。
  public func dismissPresented(animated: Bool) {
    rootNav?.presentedViewController?.dismiss(animated: animated)
    pruneHosts()
  }

  /// 能否返回（router.canGoBack）。
  public var canGoBack: Bool {
    guard let rootNav else { return false }
    if rootNav.presentedViewController != nil { return true }
    return rootNav.viewControllers.count > 1
  }

  public func selectTab(_ index: Int) {
    guard let tabBar, let vcs = tabBar.viewControllers, index >= 0, index < vcs.count else { return }
    // 切 tab 前先收敛栈：从"动态"里进过帖子页再点"关注"，应该回到根屏而不是
    // 停在帖子页（expo-router 的 NativeTabs 同样是这个行为）。
    if let rootNav, rootNav.viewControllers.count > 1 {
      // 同 popToRoot：结果在 assumeIsolated 内就地丢弃，不经非隔离上下文返回。
      MainActor.assumeIsolated {
        _ = self.rootNav?.popToRootViewController(animated: false)
        self.pruneHosts()
      }
    }
    // 改 selectedIndex 就是切 tab 的全部动作；didSelect 那边已无事件要分发。
    tabBar.selectedIndex = index
  }

  /// 让某个 tab 的列表回到顶部（双击底栏 tab）。切 tab 时底栏会把当前 tab
  /// 的滚动视图交给系统跟踪，这里直接用那个视图。
  public func scrollTabToTop(_ index: Int) {
    guard let host = tabRootHosts[index], let sv = host.scrollViewForSystem() else { return }
    let top = CGPoint(x: 0, y: -sv.adjustedContentInset.top)
    sv.setContentOffset(top, animated: true)
  }

  /// 让当前这一屏的列表回到顶部（双击顶栏）。
  public func scrollCurrentToTop() {
    let host = currentHost() ?? scrollableTabHost()
    guard let host, let sv = host.scrollViewForSystem() else { return }
    let top = CGPoint(x: 0, y: -sv.adjustedContentInset.top)
    sv.setContentOffset(top, animated: true)
  }

  private func scrollableTabHost() -> TiebaRouteHostViewController? {
    guard let idx = tabBar?.selectedIndex else { return nil }
    return tabRootHosts[idx]
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
    rootNav?.topViewController as? TiebaRouteHostViewController
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
    if let rootNav {
      func collect(_ vc: UIViewController) {
        if let host = vc as? TiebaRouteHostViewController { kept.insert(host.hostId) }
      }
      for vc in rootNav.viewControllers { collect(vc) }
      var presented = rootNav.presentedViewController
      while let current = presented {
        collect(current)
        if let nav = current as? UINavigationController {
          for vc in nav.viewControllers { collect(vc) }
        }
        presented = current.presentedViewController
      }
    }
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
    let s = url.absoluteString
    // 应用自有 scheme：tiebalite://notifications/2
    if let m = s.range(of: #"t(ieba)?lite://notifications/(\d+)"#, options: .regularExpression) {
      let digits = s[m].split(separator: "/").last.map(String.init) ?? ""
      return navigateDeepLink(
        digits.isEmpty ? "notifications" : "notifications?initialTab=\(digits)",
        mode: .root
      )
    }
    if let tid = Self.extractThreadId(s) {
      return navigateDeepLink("thread/\(tid)")
    }
    // 搜索：tiebalite://search 或 tiebalite://search?q=关键词（q 非空则直接出结果，
    // 供快捷指令/调试直达；空 q 只开搜索页）。
    if s.hasPrefix("tiebalite://search") || s.hasPrefix("tblite://search") {
      let q = URLComponents(string: s)?.queryItems?.first { $0.name == "q" }?.value ?? ""
      // q 走查询串（原走 extraParams，这里百分号编码后由解析器解回，值不变）。
      return navigateDeepLink(
        q.isEmpty ? "search/index" : "search/index?q=\(TiebaRoutePath.segment(q))"
      )
    }
    if let name = Self.extractForumName(s) {
      return navigateDeepLink("forum/\(name)")
    }
    return false
  }

  /// 深链字符串 → 类型化路由 → 同一条构造路径。解析不出就落「找不到页面」
  ///（旧行为：打错的深链不静默吞掉，也不空白）。
  @discardableResult
  private func navigateDeepLink(_ path: String, mode: TiebaNavigationMode = .push) -> Bool {
    navigate(TiebaRouteTable.parse(path: path) ?? .notFound(path: path), mode: mode)
    return true
  }

  /// src/utils/index.ts 的 extractThreadId 原生版。两处必须同时改（或只此一处
  /// ——迁移完成后 JS 那份会随 utils 一起删掉）。
  static func extractThreadId(_ url: String) -> String? {
    if let r = url.range(of: #"tblite://thread/(\d+)"#, options: .regularExpression) {
      let digits = url[r].split(separator: "/").last.map(String.init) ?? ""
      return digits.isEmpty ? nil : digits
    }
    guard let u = URLComponents(string: url) else { return nil }
    let scheme = u.scheme?.lowercased() ?? ""
    let host = u.host?.lowercased() ?? ""
    let path = u.path
    let query = { (k: String) -> String? in
      u.queryItems?.first(where: { $0.name == k })?.value
    }
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

  static func extractForumName(_ url: String) -> String? {
    // tblite://forum/某吧 —— 取 // 之后的全部（吧名可含斜杠转义与百分号编码）
    if let r = url.range(of: "tblite://forum/") {
      let raw = String(url[r.upperBound...])
      guard !raw.isEmpty else { return nil }
      return raw.removingPercentEncoding ?? raw
    }
    guard let u = URLComponents(string: url) else { return nil }
    let scheme = u.scheme?.lowercased() ?? ""
    let host = u.host?.lowercased() ?? ""
    let path = u.path
    let query = { (k: String) -> String? in
      u.queryItems?.first(where: { $0.name == k })?.value
    }
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
    let wantHidden: Bool
    if viewController is TiebaMainTabBarController {
      wantHidden = true
    } else if let host = viewController as? TiebaRouteHostViewController {
      wantHidden = (TiebaRouteTable.entry(named: host.route.name)?.chrome ?? .standard) == .hidden
    } else {
      wantHidden = false
    }
    // 返回（pop）到无栏页时**延到转场结束再隐栏**：立刻隐会让 UIKit 把栏内容与目标页的
    // 空 item 交叉淡入，表现为"返回按钮与标题全没了、只剩栏背景"（且转场期间离场页还在
    // 屏幕上，看起来就是它丢了顶栏）。push 仍立即生效——新页首帧不能闪栏。
    if wantHidden, isPopTransition(of: viewController, in: navigationController) {
      navigationController.transitionCoordinator?.animate(alongsideTransition: nil) { context in
        // 手势取消（右滑中途松手回原页）时不能隐——那一页是要栏的。
        guard !context.isCancelled else { return }
        navigationController.setNavigationBarHidden(true, animated: false)
      }
    } else {
      navigationController.setNavigationBarHidden(wantHidden, animated: false)
    }
  }

  /// 本次 willShow 是不是"返回"：转场来源页在开始时就已出栈 ⇒ pop；仍在栈内 ⇒ push。
  private func isPopTransition(
    of viewController: UIViewController,
    in navigationController: UINavigationController
  ) -> Bool {
    guard let from = navigationController.transitionCoordinator?.viewController(forKey: .from)
    else { return false }
    return !navigationController.viewControllers.contains(from)
  }

  public func navigationController(
    _ navigationController: UINavigationController,
    didShow viewController: UIViewController,
    animated: Bool
  ) {
    // 滚动视图的跟踪关联由各宿主 VC 自己在 viewDidLayoutSubviews 里做
    // （setContentScrollView 是子 VC 的职责，容器没有替它设的 API）。
    // 转场完成即重扫（原来监听未公开的 UINavigationControllerDidShowNotification，
    // 2026-09-13 改为走这个公开回调）：push/pop 动画期间 RunLoop 处于 tracking
    // 模式，动画结束后新 bar 已建成但还没被处理（"进帖子页无效果"的 timing 缺口）。
    _ = TiebaChrome.forceNavBarLiquidGlass()
    // 转场一结束就关 Hero：这样"进入"用魔改，**返回与后续跳转全走系统原生**
    //（Hero 只在 push 那一刻被读，pop 时已关 ⇒ 系统 push/pop 动画）。
    MainActor.assumeIsolated {
      if rootNav?.hero.isEnabled == true { rootNav?.hero.isEnabled = false }
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

  @objc private func handleDown() {
    UIView.animate(withDuration: 0.08) { self.flash.alpha = 1 }
  }

  @objc private func handleUp() {
    UIView.animate(withDuration: 0.18) { self.flash.alpha = 0 }
  }
}
