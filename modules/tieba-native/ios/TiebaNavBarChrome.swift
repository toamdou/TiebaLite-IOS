// 原生顶栏 chrome——由 TiebaNativeModule.swift 拆出（v34/v37 定稿实现）。
//
// 职责：栏外观透明化 + 外部写入规范化（setter swizzle）+ 路由门控的滚动边缘
// 模糊（UIScrollEdgeEffect.Style.soft）+ 窗口/导航容器底色同步 + 幂等重挂入口。
import ExpoModulesCore
import Foundation
import ObjectiveC
import UIKit

extension TiebaNativeModule {
  /// extension 不能声明存储属性：chrome 侧可变状态与懒加载钩子收进命名空间。
  enum ChromeState {
    nonisolated(unsafe) static var routeEnabled = true
    /// 应用实际主题（JS 下发）：nil = 跟随系统，非 nil = 应用手动指定深/浅。
    nonisolated(unsafe) static var darkMode: Bool? = nil
    nonisolated(unsafe) static var scrollHooked = false
    nonisolated(unsafe) static var appearanceHooked = false
    /// 已按当前路由规范化过外观的 bar（路由切换时清空）。
    static let appearanceBars = NSHashTable<UINavigationBar>.weakObjects()
    /// bar 弱引用缓存：force 扫到的 bar 登记，供 refresh 等按需遍历。
    static let cachedBars = NSHashTable<UINavigationBar>.weakObjects()
  }

  static func setChromeDarkMode(_ dark: Bool?) { ChromeState.darkMode = dark }

  static func installNavBarChromeHooks() {
    _ = navChromeHooks
    _ = navChromeScrollHooks
  }

  // 顶栏 chrome 的幂等重挂入口（v3 起，2026-08-22；v34 起职责收窄）：窗口/
  // 导航容器底色、栏 trait、栏外观（透明）、双击回顶手势、滚动边缘模糊按
  // 路由幂等重挂。入口=启动 + 回前台 + 转场完成（didShow）+ 1.5s timer +
  // bar 的 didMoveToWindow/layoutSubviews。
  //
  // 历史（勿再回头）：v3–v33 曾在渲染层直接操作 _UIBarBackground 里的
  // UIVisualEffectView（设 systemMaterial/ultraThin + 渐变 mask）自建磨砂——
  // iOS 27 上栏底材质会被 UIKit 按 appearance 重建（双图层感/矩形磨砂），
  // v34 起全部撤除，模糊改由系统的滚动边缘效果承担（softStyle）。
  static let navChromeHooks: Void = {
    let nc = NotificationCenter.default
    nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        TiebaNativeModule.forceNavBarLiquidGlass()
      }
    }
    // 转场完成兜底（2026-09-02 代码修复）：push/pop 动画期间 RunLoop 处于
    // tracking 模式，1.5s timer 被跳过；_UIBarBackground 在转场中重建，
    // 新 bar 的材质要等 timer 恢复才挂（"进帖子页无效果"的 timing 缺口）。
    // didShow 在动画完成时触发 → 主线程强制 force，重建窗口压到一帧内。
    nc.addObserver(
      forName: Notification.Name("UINavigationControllerDidShowNotification"),
      object: nil,
      queue: .main
    ) { _ in
      DispatchQueue.main.async {
        TiebaNativeModule.forceNavBarLiquidGlass()
      }
    }
    // 持续幂等重挂：KVO 覆盖"effect 被系统改动"，timer 兜底 "_UIBarBackground
    // 整个重建（新 bar 无人接管材质）。1.5s 一次成本可忽略。
    // 必须用非调度构造器再显式挂主 run loop：本静态初始化在 JS 线程触发
    // （protoInitialize），scheduledTimer 会把 timer 挂上 JS run loop，
    // 之后 RunLoop.main.add 无法迁移——每 1.5s 在 JS 线程执行视图写入
    // 触发 Auto Layout 仅主线程断言 SIGABRT（进二级页面必崩，2026-08-26）。
    // 用默认模式而非 .common：tracking 期间（滚动、系统手势动画）不打断主
    // 线程；布局完成事件由 navGlassScrollDump 的 didMoveToWindow/layout
    // Subviews swizzle 兜底（v21 起玻璃层自建、不受系统重置，无需滚动恢复）。
    let timer = Timer(timeInterval: 1.5, repeats: true) { _ in
      TiebaNativeModule.forceNavBarLiquidGlass()
    }
    RunLoop.main.add(timer, forMode: .default)
    // 新 bar 挂载/布局即 force：didMoveToWindow 首帧深色防"先白后黑"、
    // layoutSubviews 收尾材质视图建成/布局变化后的时机缺口。
    _ = navChromeScrollHooks
    return ()
  }()

  static let navChromeScrollHooks: Void = {
    guard !ChromeState.scrollHooked else { return }
    ChromeState.scrollHooked = true
    // 新 bar 挂载即应用：页面 push 瞬间新 UINavigationBar 首次进 window，
    // 等 1.5s 兜底扫描的话深色模式下会先渲染系统浅色（真机实测"先白后黑"）。
    // didMoveToWindow 必在主线程；这里同步直写 override（不必等 force 扫描
    // ——bar 未入 window 时 collectNavigationBars 扫不到、force 会早退，
    // trait 一旦写入，UIKit 自带的初始渲染就是深色），再补一轮 force。
    let moveSelector = #selector(UIView.didMoveToWindow)
    if let moveMethod = class_getInstanceMethod(UINavigationBar.self, moveSelector) {
      let moveOriginal = method_getImplementation(moveMethod)
      typealias MoveFn = @convention(c) (AnyObject, Selector) -> Void
      let moveOriginalFn = unsafeBitCast(moveOriginal, to: MoveFn.self)
      let moveBlock: @convention(block) (AnyObject) -> Void = { bar in
        moveOriginalFn(bar, moveSelector)
        guard let navBar = bar as? UINavigationBar else { return }
        let wantedStyle: UIUserInterfaceStyle = TiebaNativeModule.chromeUserInterfaceStyle
        navBar.overrideUserInterfaceStyle = wantedStyle
        // 时机补齐：didMoveToWindow 时 _UIBarBackground 往往还没建成，
        // force 扫描不到材质视图（真机实测此时 force 早退）→ 补一次延迟
        // 重挂，首帧即深色玻璃（"先白后黑"修复，2026-08-27）。
        _ = TiebaNativeModule.forceNavBarLiquidGlass()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
          _ = TiebaNativeModule.forceNavBarLiquidGlass()
        }
      }
      method_setImplementation(moveMethod, imp_implementationWithBlock(moveBlock))
    }
    // layoutSubviews 兜底：bar 每次布局（含 _UIBarBackground 建成）后异步
    // 重挂。放在布局结束后执行，避免在布局 pass 内 flush 引起递归。
    let layoutSelector = #selector(UIView.layoutSubviews)
    if let layoutMethod = class_getInstanceMethod(UINavigationBar.self, layoutSelector) {
      let layoutOriginal = method_getImplementation(layoutMethod)
      typealias LayoutFn = @convention(c) (AnyObject, Selector) -> Void
      let layoutOriginalFn = unsafeBitCast(layoutOriginal, to: LayoutFn.self)
      let layoutBlock: @convention(block) (AnyObject) -> Void = { bar in
        layoutOriginalFn(bar, layoutSelector)
        DispatchQueue.main.async {
          _ = TiebaNativeModule.forceNavBarLiquidGlass()
        }
      }
      method_setImplementation(layoutMethod, imp_implementationWithBlock(layoutBlock))
    }
    // v21 说明：不再有 setContentOffset swizzle/滚动恢复——自建玻璃层不属
    // 系统材质管理，系统不会重置它；滚动中玻璃层持续存在（layoutSubviews
    // 兜底 force 收尾布局变化）。
    return ()
  }()

  // ── v34 原生顶栏（2026-09-11 用户定调）──
  // 用户要求："顶栏完全使用 UIKit，并遵循 iOS 26 之后的 UIKit 设计规范"，
  // 且点名要 iOS 26 的"无边界"模糊（当前系统 iOS 27 的默认观感是矩形硬边磨砂）。
  //
  // 结论（SDK 原文）：iOS 26 起顶栏的模糊由滚动边缘效果承担——
  // UIScrollEdgeEffect.Style.soft = "A soft-edged scroll edge effect"
  //（无边界渐进模糊，内容滚到栏下才出现，看得清背后内容）；
  // .hard = "hard cutoff and dividing line"（矩形硬边+分隔线，用户嫌的那种）。
  // 因此 v19–v33 的自建磨砂层（自建 UIVisualEffectView + CAGradientLayer 渐变
  // mask）、系统材质清空（clearBarEffects）、发丝隐藏（hideBarHairlines）、
  // 三套 appearance 置透明/置默认（v30/v30b）全部撤除：栏底不画任何材质，
  // 模糊交还 UIKit 的 UIScrollView.topEdgeEffect（见 applyTopScrollEdgeEffect）。
  //
  // 栏外观只保留"透明"这一个决定，并由 setter swizzle 拦住 RNScreens 按
  // headerTransparent/headerBlurEffect 的写入（它会把旧材质/默认栏底写回来，
  // 垫出一块矩形磨砂）。
  // v31 路由门控（setNavBarGlassEnabled）：主 tab 页关、吧页/帖子页开——
  // v34 起门控的对象是滚动边缘模糊（栏底材质已全应用撤除）。
  static func setNavBarRouteEnabled(_ enabled: Bool) { ChromeState.routeEnabled = enabled }

  /// 已按当前路由规范化过外观的 bar（路由切换时清空）。外观只在"该 bar 还没
  /// 规范化"时写一次——重写会让 UIKit 重建栏底，每 1.5s 重写就是滚动闪烁源。
    /// 路由切换即清空"已规范化"标记（让 force 按新路由重写一遍外观）。
  static func resetBarAppearanceCache() { ChromeState.appearanceBars.removeAllObjects() }

  /// 栏外观：一律透明（栏底材质=矩形磨砂，用户点名不要；模糊由边缘效果承担）。
  /// 三套外观槽（standard / compact / scrollEdge）同值：滚动全程同一观感。
  private static func applyNativeBarAppearance(to bar: UINavigationBar) {
    let appearance = makeNativeBarAppearance()
    bar.standardAppearance = appearance
    bar.compactAppearance = appearance
    bar.scrollEdgeAppearance = appearance
    // item 级外观优先于栏级：RNScreens 的 headerTransparent / headerBlurEffect
    // 写的就是这一层，留着会把栏级外观整个盖掉（v30b 同源结论）→ 置 nil
    // 继承栏级。
    if let item = bar.topItem {
      if item.standardAppearance != nil { item.standardAppearance = nil }
      if item.scrollEdgeAppearance != nil { item.scrollEdgeAppearance = nil }
      if item.compactAppearance != nil { item.compactAppearance = nil }
    }
  }

  private static func makeNativeBarAppearance() -> UINavigationBarAppearance {
    let appearance = UINavigationBarAppearance()
    appearance.configureWithTransparentBackground()
    return appearance
  }

  /// 外部 appearance 写入的规范化：保留写入方的标题/按钮排版属性，背景一律
  /// 归一成透明（headerBlurEffect 的旧材质、系统默认栏底都不作数）。
  fileprivate static func normalizedBarAppearance(
    _ incoming: UINavigationBarAppearance?
  ) -> UINavigationBarAppearance {
    let appearance = (incoming?.copy() as? UINavigationBarAppearance) ?? UINavigationBarAppearance()
    appearance.configureWithTransparentBackground()
    return appearance
  }

  /// 外部栏外观写入拦截：RNScreens 应用 screen options 时直接写 standard /
  /// compact / scrollEdge（headerTransparent → 透明底，headerBlurEffect →
  /// 旧材质），会把系统原生材质覆盖掉。拦下每次写入做背景规范化后落库——
  /// 既不必周期性重写 appearance，也不怕 RN 侧后写覆盖。
  
  static let appearanceSwizzle: Void = {
    guard !ChromeState.appearanceHooked else { return }
    ChromeState.appearanceHooked = true
    let selectors = [
      NSSelectorFromString("setStandardAppearance:"),
      NSSelectorFromString("setCompactAppearance:"),
      NSSelectorFromString("setScrollEdgeAppearance:"),
    ]
    for selector in selectors {
      guard let method = class_getInstanceMethod(UINavigationBar.self, selector) else { continue }
      let original = method_getImplementation(method)
      typealias SetAppearanceFn = @convention(c) (UINavigationBar, Selector, UINavigationBarAppearance?) -> Void
      let originalFn = unsafeBitCast(original, to: SetAppearanceFn.self)
      let block: @convention(block) (UINavigationBar, UINavigationBarAppearance?) -> Void = { bar, incoming in
        originalFn(bar, selector, TiebaNativeModule.normalizedBarAppearance(incoming))
      }
      method_setImplementation(method, imp_implementationWithBlock(block))
    }
    return ()
  }()

  /// 顶层可见页面视图（presented 链 → 导航栈顶）：顶栏模糊的作用域。
  private static func topScreenView() -> UIView? {
    let windows = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
    let keyWindow = windows.first { $0.isKeyWindow && $0.windowLevel == .normal } ?? windows.first
    guard let window = keyWindow, var vc = window.rootViewController else { return nil }
    while let presented = vc.presentedViewController { vc = presented }
    if let nav = vc as? UINavigationController, let top = nav.topViewController { vc = top }
    return vc.view
  }

  /// 顶栏模糊 = 系统的滚动边缘效果（iOS 26 规范形态）。给顶层页面里"顶边贴着
  /// 屏幕顶"的滚动视图打开 topEdgeEffect 的 soft 样式：内容滚到栏下时由 UIKit
  /// 做渐进模糊——无边界、无硬切边、看得清背后内容。hard 样式（"hard cutoff
  /// and dividing line"，即用户嫌的矩形硬边）与栏底材质一律不用。
  ///
  /// 路由链：内容页（吧页/帖子页/用户主页/搜索/设置…）全开 soft；主 tab
  ///（RN 自绘顶栏，无原生栏）显式关 hidden。关的一侧必须自己写，不能靠
  /// RNScreens 的 scrollEdgeEffects prop——那个 prop 用
  /// findScrollViewInFirstDescendantChainFrom（沿 subviews[0] 逐层下沉）定位，
  /// 命中谁不可控，漏配的滚动视图会落到系统默认样式（iOS 27 = hard 矩形硬边）。
  ///
  /// 只有"**整屏竖向列表**"配 soft：栏下真正滚动的是它。其余顶边贴屏幕顶的
  /// 滚动视图（吧页分段页的原生 pager=横向分页、行内横滑条…）一律显式关掉：
  /// effect 的 hidden 默认是 false，不写就是系统 automatic 样式（iOS 27 上解析成
  /// hard 矩形磨砂+分隔线），而 pager 的顶边同样在栏下、又盖在列表之上，
  /// 于是 hard 叠 soft，用户看到的就是"矩形磨砂 + 明显底边"。
  /// 反过来给 pager 也开 soft 更糟（2026-09-11 v36 实测）：两层软模糊叠在一起，
  /// 滑动时栏下内容被糊死。幂等：已是目标状态时不写（写会打断进行中的模糊动画）。
  @discardableResult
  private static func applyTopScrollEdgeEffect(glass: Bool) -> Bool {
    guard #available(iOS 26.0, *) else { return false }
    guard let screen = topScreenView(), screen.bounds.height > 0 else { return false }
    var changed = false
    func configure(_ scroll: UIScrollView) {
      let frameInScreen = scroll.convert(scroll.bounds, to: screen)
      let vertical = scroll.contentSize.width <= scroll.bounds.width + 1
      // 横向可见性：分页器并排放着各段页面，屏幕外的页面也有列表，只有当前
      // 可见那一屏的列表才算候选（否则会把栏交给一个看不见的列表）。
      let onScreenX = frameInScreen.minX >= -1
        && frameInScreen.maxX <= screen.bounds.width + 1
      let isList = vertical && !scroll.isPagingEnabled && onScreenX
        && frameInScreen.height > screen.bounds.height * 0.4
      let qualifies = frameInScreen.minY <= 1 && frameInScreen.height > 80
        && !scroll.isHidden && scroll.alpha > 0.01
      guard qualifies else { return }
      if glass && isList {
        if scroll.topEdgeEffect.isHidden {
          scroll.topEdgeEffect.isHidden = false
          changed = true
        }
        if scroll.topEdgeEffect.style !== UIScrollEdgeEffect.Style.soft {
          scroll.topEdgeEffect.style = .soft
          changed = true
        }
      } else if !scroll.topEdgeEffect.isHidden {
        // 顶边同样贴屏幕顶但不是"整屏竖向列表"的（分页器 pager、横滑条…）
        // 一律显式关掉：effect 的 hidden 默认是 false，不写就落到系统
        // automatic 样式（iOS 27 上解析成 hard 矩形磨砂+分隔线）。
        scroll.topEdgeEffect.isHidden = true
        changed = true
      }
    }
    func scan(_ view: UIView) {
      if let scroll = view as? UIScrollView { configure(scroll) }
      for sub in view.subviews { scan(sub) }
    }
    scan(screen)
    return changed
  }

  // 导航栏弱引用缓存：force 扫到的 bar 登记，供 refresh 等按需遍历。

  @discardableResult
  static func forceNavBarLiquidGlass() -> Bool {
    // 全部工作（视图树遍历 + effect/mask 写入）只允许主线程：setEffect:
    // 内部走 NSISEngine，非主线程直接触发 Auto Layout 断言 SIGABRT。
    // timer/KVO/通知各入口理论都应主线程，这里统一兜底跳转而非崩溃。
    guard Thread.isMainThread else {
      DispatchQueue.main.async { TiebaNativeModule.forceNavBarLiquidGlass() }
      return false
    }
    let bars = collectNavigationBars()
    // 无导航栏（splash/首帧前）直接短路：不碰 CATransaction。此前每 1.5s
    // 无条件 CATransaction.flush() 会反复强制主线程完成挂起布局，打断
    // 首帧渲染事务，splash（原生首帧自动隐藏）被拖住数秒。
    // 窗口底色同步（幂等比较，零成本）：深色模式下 push 转场窗口透底不发白。
    // 只写主窗口（key 且 .normal）：系统临时浮层（上下文菜单等）被刷成不透明
    // 底色后，菜单收起时残留窗口会把整屏盖成纯色——长按图片退出后"整个画面
    // 一片空白"的真根因（2026-08-27 真机两次复现；该浮层非 key、level 更高）。
    for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
      for window in scene.windows
      where window.isKeyWindow && window.windowLevel == .normal {
        if window.backgroundColor != TiebaNativeModule.chromeWindowColor {
          window.backgroundColor = TiebaNativeModule.chromeWindowColor
        }
        // 2026-09-02 修复"右滑退出漏白"：pop/push 转场容器（UITransitionView）
        // 背景跟随 window 的 trait 而非 backgroundColor——手动深色 + 系统浅色时
        // 容器按系统渲染成白，页面移开露出白底（真机实测）。窗口 trait 同步
        // 应用主题，转场容器随之深色；nil 跟随系统时不锁（自动切换）。
        let windowStyle = TiebaNativeModule.chromeUserInterfaceStyle
        if window.overrideUserInterfaceStyle != windowStyle {
          window.overrideUserInterfaceStyle = windowStyle
        }
      }
    }
    // 2026-09-02 修复"用力回弹漏白"：UIScrollView 回弹露出的是导航栈容器
    // （UINavigationController.view）——iOS 27 其默认背景跟随系统 trait，
    // 手动深色 + 系统浅色/居中系统时按浅色 systemBackground 渲染成白。
    // 与 window 同源同步应用主题底色（幂等比较，不破坏系统默认 nil 语义）。
    // 覆盖全部嵌套导航容器（非仅 rootViewController 层级）。
    let navContainerBG = TiebaNativeModule.chromeWindowColor
    for navView in TiebaNativeModule.collectNavigationContainerViews() {
      if navView.backgroundColor != navContainerBG {
        navView.backgroundColor = navContainerBG
      }
    }
    guard !bars.isEmpty else { return false }
    var applied = false
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for navBar in bars {
      ChromeState.cachedBars.add(navBar)
      // 双击回顶手势：随 force 的 timer/KVO 扫描覆盖新建的 bar（≤1.5s 延迟）。
      installNavDoubleTapToTop(on: navBar)
      // 回弹/转场漏白（2026-09-02 二轮）：页面实际所在的是导航容器
      // （UINavigationController.view，可能嵌套非 window.rootViewController），
      // iOS 27 其背景默认跟随系统 trait——手动深色+系统浅色时按浅色
      // systemBackground 渲染成白，用力甩列表（bounce）即漏出。每个 bar
      // 所在的导航容器同步应用主题底色（幂等）。
      // 应用主题→栏 trait：深色常驻+系统浅色时原生栏材质（含 UISearchBar）
      // 会跟系统渲染成浅色（真机实测一片白），override 拉回应用主题。
      let wantedStyle: UIUserInterfaceStyle = TiebaNativeModule.chromeUserInterfaceStyle
      if navBar.overrideUserInterfaceStyle != wantedStyle {
        navBar.overrideUserInterfaceStyle = wantedStyle
        applied = true
      }
      // bar 自带底保持系统默认（透明）：不透明底垫在 _UIBarBackground 材质
      // 之下被一并模糊，整条 bar 变成纯色带而非玻璃——"返回按钮栏有背景色"
      // 根因（2026-08-27 真机实测）。材质落地前的白闪由 didMoveToWindow
      // 立即写 trait + layoutSubviews force + 主窗口底色兜底覆盖。
      // v34（2026-09-11）：栏外观整体交还 UIKit——不再清材质、不再隐藏发丝
      // 线、不再写透明 appearance，由 applyNativeBarAppearance 按路由写系统
      // 默认/透明外观，其余（材质、分隔、滚动行为）全部按 iOS 26 规范由系统
      // 自渲染。只在"该 bar 还没按当前路由规范化"时写一次（重写会触发 UIKit
      // 重建栏底，周期性重写即滚动闪烁源）；外部后写由 setter swizzle 兜住。
      if !ChromeState.appearanceBars.contains(navBar) {
        _ = appearanceSwizzle
        TiebaNativeModule.applyNativeBarAppearance(to: navBar)
        ChromeState.appearanceBars.add(navBar)
        applied = true
      }
    }
    // v34：顶栏模糊 = 系统滚动边缘效果（soft，iOS 26 规范形态），按路由门控
    //（吧页/帖子页开，其余页面显式关）。随 force 的节奏幂等重挂：push 新页、
    // 分段切换、列表重建都会带来新的滚动视图。
    if TiebaNativeModule.applyTopScrollEdgeEffect(glass: ChromeState.routeEnabled) {
      applied = true
    }
    CATransaction.commit()
    // Fabric 的 JS 线程会在任意时刻 flush CA transaction：若导航栏仍带 dirty
    // layout，会在 JS 线程执行 Auto Layout（UIKit 限制仅主线程）→ SIGABRT。
    // 这里在主线程强制完成布局，把脏标记消化掉。仅在真写了材质时才 flush：
    // 空转轮询每 1.5s 强制同步布局本身就会干扰滚动/系统动画（实测卡顿源）。
    if applied {
      CATransaction.flush()
    }
    return applied
  }

  /// 扫描全部窗口的 VC 层级找 UINavigationController（可能嵌套）的 view：
  /// 回弹/转场漏白底色同步对象（2026-09-02）。UINavigationBar 无
  /// navigationController 属性，从 VC 树直接遍历最可靠。
  private static func collectNavigationContainerViews() -> [UIView] {
    var views: [UIView] = []
    func scan(_ vc: UIViewController?) {
      guard let vc else { return }
      if let nav = vc as? UINavigationController {
        views.append(nav.view)
        // 嵌套子栈（presented/child）一并覆盖
        for child in nav.viewControllers { scan(child) }
      }
      for child in vc.children { scan(child) }
      scan(vc.presentedViewController)
    }
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    for scene in scenes {
      for window in scene.windows {
        scan(window.rootViewController)
      }
    }
    return views
  }

  private static func collectNavigationBars() -> [UINavigationBar] {
    var bars: [UINavigationBar] = []
    func scan(_ view: UIView) {
      if let bar = view as? UINavigationBar {
        bars.append(bar)
      }
      for subview in view.subviews {
        scan(subview)
      }
    }
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    for scene in scenes {
      for window in scene.windows {
        scan(window)
      }
    }
    return bars
  }

  /// 回弹漏白诊断一次性旗标（2026-09-02 临时，验完即删）
  /// 应用主题对应的窗口底色：push 转场期间新屏内容未渲染、透出窗口背景时
  /// 不发白的兜底（深色模式"先白后黑"的最后一环，2026-08-26）。
  /// nil 随系统：动态色跟随系统 trait（自动切换模式下不锁应用值，
  /// 系统切深/浅时转场底色同步变化——2026-09-02 修复）。
  static var chromeWindowColor: UIColor {
    guard let dark = ChromeState.darkMode else {
      return UIColor { trait in
        trait.userInterfaceStyle == .dark
          ? UIColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1)
          : .white
      }
    }
    return dark ? UIColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1) : .white
  }

  /// 应用主题 → 顶栏 chrome trait（wantedStyle）：nil 还原 unspecified（跟随系统）。
  static var chromeUserInterfaceStyle: UIUserInterfaceStyle {
    guard let dark = ChromeState.darkMode else { return .unspecified }
    return dark ? .dark : .light
  }
}
