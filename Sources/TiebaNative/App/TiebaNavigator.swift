import Nuke
import NukeExtensions
import UIKit

// 导航协调器：把「JS 说要去 /thread/123」翻译成 UIKit 的压栈/切 tab/上推，
// 并把路由变化回报给 JS。原 expo-router 的 router.push/back/replace 语义在这里。
//
// 状态只有一份：rootNav 的 viewControllers 就是当前导航栈，tabBar 就是底栏。
// JS 侧不再维护自己的栈——它只发指令、收事件。

/// 底栏重复点击的**原生**受理面：tab 根屏已是原生 VC 时（不再有 JS 侧
/// TAB_RESELECT 订阅），由壳直接回调，语义与 JS 的 tabReselect 分发一致。
@MainActor
protocol TiebaTabReselectable: UIViewController {
  func tabReselected()
}

/// tab 根屏的路由参数投递面：tab 根屏不入栈（navigate 只切 tab），
/// 深链带的参数（如 tiebalite://notifications/2 的 initialTab）由壳转交给
/// 已原生的根屏；没实现的根屏参数照旧丢弃。
@MainActor
protocol TiebaTabRouteParamReceiving: UIViewController {
  func receiveTabParams(_ params: [String: String])
}

/// NSObject 基类不是装饰：UINavigationControllerDelegate 继承自
/// NSObjectProtocol，Swift 里不能给纯 Swift 类声明这个 conformance。
public final class TiebaNavigator: NSObject, @unchecked Sendable {
  public static let shared = TiebaNavigator()

  /// 事件出口（宿主不需要时保持 nil）。
  public var onEvent: ((TiebaNavEvent) -> Void)?

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
      self?.onEvent?(TiebaNavEvent(kind: .tabReselect, hostId: -1, route: nil, tabIndex: idx))
    }
    tab.onSelect = { [weak self] idx in
      self?.onEvent?(TiebaNavEvent(kind: .tabSelect, hostId: -1, route: nil, tabIndex: idx))
    }
    tabBar = tab

    var tabVCS: [UIViewController] = []
    for (idx, name) in TiebaRouteTable.tabNames.enumerated() {
      let route = TiebaRoute(name: name)
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

  /// 顶栏滚动边缘模糊的路由门控（原 JS 侧按 pathname 判定后调
  /// setNavBarGlassEnabled）。主 tab 页的开：关注/动态/消息/我的的"顶栏"是
  /// RN 自绘的搜索行与页签，原生栏在它们上面是透明空壳，内容滚到那一段被
  /// 模糊没有意义，且会糊住自绘行。规则：不在主 tab 即开——新页面默认拿到
  /// 统一观感（与 JS 侧原实现的"黑名单"语义一致）。
  private func syncNavBarGlass() {
    let top = rootNav?.topViewController
    let isMainTab = (top is TiebaMainTabBarController)
    TiebaChrome.setNavBarRouteEnabled(!isMainTab)
  }

  // MARK: - 指令

  /// 路由入口。mode: "push"（默认）| "replace" | "root"（先回到栈底再压）。
  @discardableResult
  public func navigate(path: String, params: [String: String], mode: String) -> Bool {
    guard let route = resolve(path: path, extraParams: params) else {
      // 未知路由：不静默吞掉（否则深链打错字永远无人发现），落"找不到页面"。
      let fallback = TiebaRoute(name: "+not-found", params: ["path": path])
      pushRoute(fallback, mode: mode)
      return false
    }
    let entry = TiebaRouteTable.entry(named: route.name)
    if let tabIdx = entry?.tabIndex {
      // tab 根屏：语义是"切到那个 tab"，不是压栈。expo-router 里
      // router.push('/(tabs)/notifications') 同样只是切 tab。
      selectTab(tabIdx)
      // 深链参数（notifications/2 → initialTab）交给已原生的根屏；未实现的根屏
      // 无接收方，参数照旧丢弃。与 selectTab 同款：调用点本就在主线程，
      // assumeIsolated 把这条既有契约告诉编译器。
      if !route.params.isEmpty, let host = tabRootHosts[tabIdx] {
        MainActor.assumeIsolated {
          (host.children.first as? TiebaTabRouteParamReceiving)?.receiveTabParams(route.params)
        }
      }
      return true
    }
    pushRoute(route, mode: mode)
    return true
  }

  private func resolve(path: String, extraParams: [String: String]) -> TiebaRoute? {
    if let parsed = TiebaRouteTable.parse(path: path, extraParams: extraParams) {
      return parsed
    }
    return nil
  }

  private func pushRoute(_ route: TiebaRoute, mode: String) {
    guard let rootNav else { return }
    // 连点去重：同一路由 450ms 内只认一次（原 RN 侧靠 Pressable 的按压态挡，
    // 原生栏按钮没有那层，快速双击会压出两屏同样内容）。
    let sig = route.name + "|" + route.params.keys.sorted().map { "\($0)=\(route.params[$0] ?? "")" }.joined()
    let now = CACurrentMediaTime()
    if sig == lastPushSignature, now - lastPushAt < 0.45 { return }
    lastPushSignature = sig
    lastPushAt = now

    let host = makeHost(route: route, eager: true)
    let entry = TiebaRouteTable.entry(named: route.name)

    switch entry?.presentation ?? .push {
    case .push:
      switch mode {
      case "replace":
        var stack = rootNav.viewControllers
        guard !stack.isEmpty else { return }
        stack[stack.count - 1] = host
        rootNav.setViewControllers(stack, animated: true)
        pruneHosts()
      case "root":
        rootNav.setViewControllers([rootNav.viewControllers[0], host], animated: true)
        pruneHosts()
      default:
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
      // 深色模式下表单也是深色（应用主题 ≠ 系统外观）。presented VC 不继承
      // presenter 的 overrideUserInterfaceStyle，必须自己带。
      presentable.overrideUserInterfaceStyle = theme.dark ? .dark : .light
      presenter.present(presentable, animated: true)
    }
    syncNavBarGlass()
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

  /// 某屏的 JS 树挂载完成时调用：如果这一屏此刻确实可见，补发一次 focus。
  /// 必要性：viewDidAppear 可能早于该 surface 的 JS 树挂载（首个 surface 的
  /// JS 还在加载 bundle），那时发出的事件会被 EventEmitter 丢掉，于是
  /// useFocusEffect 的首跑永远不会发生——表现为"进页面不加载数据"。
  func markHostReady(hostId: Int) {
    guard let host = host(hostId), isVisible(host) else { return }
    onEvent?(TiebaNavEvent(kind: .focus, hostId: hostId, route: host.route, tabIndex: -1))
  }

  /// 该宿主屏此刻是否真的在屏幕最前。
  private func isVisible(_ host: TiebaRouteHostViewController) -> Bool {
    guard let rootNav else { return false }
    if let presented = rootNav.presentedViewController {
      return presented === host || (presented as? UINavigationController)?.topViewController === host
    }
    if rootNav.topViewController === host { return true }
    // tab 根屏：rootNav 栈里只剩底栏那屏，且当前选中的就是它
    guard let tabBar, rootNav.viewControllers.count == 1 else { return false }
    let idx = tabBar.viewControllers?.firstIndex(where: { $0 === host }) ?? -1
    return idx >= 0 && idx == tabBar.selectedIndex
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
    // tabSelect 事件由 UITabBarControllerDelegate.didSelect 统一发（程序化改
    // selectedIndex 同样会触发它），这里不再重复发一次。
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

  public func setTitle(hostId: Int, title: String) {
    host(hostId)?.setTitle(title)
  }

  /// 全局状态栏默认字色（JS 按工具栏主色调/状态栏字色偏好算出后下发）。
  /// 逐屏覆盖优先于它。
  private(set) var defaultStatusBarStyle: UIStatusBarStyle = .default

  public func setDefaultStatusBarStyle(_ style: UIStatusBarStyle) {
    guard defaultStatusBarStyle != style else { return }
    defaultStatusBarStyle = style
    for host in liveHosts() { host.refreshStatusBarStyle() }
  }

  public func setStatusBarStyle(hostId: Int, style: UIStatusBarStyle) {
    host(hostId)?.statusBarStyleOverride = style
  }

  /// 导航栏左右按钮（替 headerLeft/headerRight 的 React 节点）。
  /// 描述符：{ kind: "symbol"|"avatar", value: SF Symbol 名或图片 URL,
  ///          action: 回传 JS 的动作名, label: 无障碍标签,
  ///          tint: "primary"|"text"|"textSecondary" 或 #RRGGBB }
  public func setBarItems(hostId: Int, left: [[String: Any]]?, right: [[String: Any]]?) {
    guard let host = host(hostId) else { return }
    // ⚠️ 必须是 `left?.map` 而不是 `left.map`：left 是可选数组，
    // `left.map` 会解析成 Optional.map（闭包参数是**整个数组** [[String:Any]]），
    // 于是报"UIBarButtonItem 不能转成 [UIBarButtonItem]"这种看不懂的错。
    host.navigationItem.leftBarButtonItems = left?.map { makeBarButton($0, hostId: hostId, slot: "left") }
    host.navigationItem.rightBarButtonItems = right?.map { makeBarButton($0, hostId: hostId, slot: "right") }
  }

  private func makeBarButton(_ desc: [String: Any], hostId: Int, slot: String) -> UIBarButtonItem {
    let action = desc["action"] as? String ?? ""
    let label = desc["label"] as? String ?? ""
    let kind = desc["kind"] as? String ?? "symbol"
    let value = desc["value"] as? String ?? ""
    let tint = Self.color(from: desc["tint"] as? String) ?? theme.tint

    if kind == "avatar", let url = URL(string: value), !value.isEmpty {
      let button = TiebaBarAvatarButton(frame: CGRect(x: 0, y: 0, width: 30, height: 30))
      button.accessibilityLabel = label
      button.load(url: url)
      button.onTap = { [weak self] in self?.fireBarAction(action, hostId: hostId, slot: slot) }
      return UIBarButtonItem(customView: button)
    }

    let img = UIImage(systemName: value)
    let item = UIBarButtonItem(image: img, style: .plain, target: nil, action: nil)
    item.accessibilityLabel = label
    item.tintColor = tint
    item.primaryAction = UIAction { [weak self] _ in
      self?.fireBarAction(action, hostId: hostId, slot: slot)
    }
    return item
  }

  private func fireBarAction(_ action: String, hostId: Int, slot: String) {
    guard !action.isEmpty else { return }
    onEvent?(
      TiebaNavEvent(
        kind: .barAction,
        hostId: hostId,
        route: TiebaRoute(name: "__barAction__", params: ["action": action, "slot": slot]),
        tabIndex: -1
      )
    )
  }

  private static func color(from token: String?) -> UIColor? {
    guard let token, !token.isEmpty else { return nil }
    if token.hasPrefix("#") {
      var hex = String(token.dropFirst())
      if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
      guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
      return UIColor(
        red: CGFloat((v >> 16) & 0xFF) / 255,
        green: CGFloat((v >> 8) & 0xFF) / 255,
        blue: CGFloat(v & 0xFF) / 255,
        alpha: 1
      )
    }
    // 语义 token：具体色值由 JS 在主题变化时重新下发，这里只兜底。
    switch token {
    case "primary": return nil
    case "text": return .label
    case "textSecondary": return .secondaryLabel
    default: return nil
    }
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
      // 未登记的路由落 +not-found，绝不空白：路由表与原生登记表必须同步。
      let native = TiebaNativeRouteTable.make(route) ?? TiebaNotFoundViewController()
      return TiebaRouteHostViewController(route: route, hostId: hostId, nativeChild: native)
    }
    hostsById.setObject(host, forKey: NSNumber(value: hostId))
    host.onEvent = { [weak self] event in self?.onEvent?(event) }
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
  @discardableResult
  public func open(url: URL) -> Bool {
    let s = url.absoluteString
    // 应用自有 scheme：tiebalite://notifications/2
    if let m = s.range(of: #"t(ieba)?lite://notifications/(\d+)"#, options: .regularExpression) {
      let digits = s[m].split(separator: "/").last.map(String.init) ?? ""
      navigate(
        path: "notifications",
        params: digits.isEmpty ? [:] : ["initialTab": digits],
        mode: "root"
      )
      return true
    }
    if let tid = Self.extractThreadId(s) {
      navigate(path: "thread/\(tid)", params: [:], mode: "push")
      return true
    }
    // 搜索：tiebalite://search 或 tiebalite://search?q=关键词（q 非空则直接出结果，
    // 供快捷指令/调试直达；空 q 只开搜索页）。
    if s.hasPrefix("tiebalite://search") || s.hasPrefix("tblite://search") {
      let q = URLComponents(string: s)?.queryItems?.first { $0.name == "q" }?.value ?? ""
      navigate(path: "search/index", params: q.isEmpty ? [:] : ["q": q], mode: "push")
      return true
    }
    if let name = Self.extractForumName(s) {
      navigate(path: "forum/\(name)", params: [:], mode: "push")
      return true
    }
    return false
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
    navigationController.setNavigationBarHidden(wantHidden, animated: false)
    syncNavBarGlass()
  }

  public func navigationController(
    _ navigationController: UINavigationController,
    didShow viewController: UIViewController,
    animated: Bool
  ) {
    // 滚动视图的跟踪关联由各宿主 VC 自己在 viewDidLayoutSubviews 里做
    // （setContentScrollView 是子 VC 的职责，容器没有替它设的 API）。
    syncNavBarGlass()
    // 转场完成即重扫（原来监听未公开的 UINavigationControllerDidShowNotification，
    // 2026-09-13 改为走这个公开回调）：push/pop 动画期间 RunLoop 处于 tracking
    // 模式，动画结束后新 bar 已建成但还没被处理（"进帖子页无效果"的 timing 缺口）。
    // syncNavBarGlass 刚写过路由门控，这里紧接着按新路由重挂边缘效果。
    _ = TiebaChrome.forceNavBarLiquidGlass()
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
  /// 每次 makeBarButton 都是新按钮，不存在同视图重复换图的闪烁问题。
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
