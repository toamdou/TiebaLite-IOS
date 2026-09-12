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

    // ── 空转治理（2026-09-12 发热审查）──
    // force 每次要做两趟视图树全量遍历：collectNavigationBars 扫所有窗口的
    // 整棵树，applyTopScrollEdgeEffect 再扫顶层页面整棵树。改前 1.5s timer
    // 无条件全扫，且 UINavigationBar.layoutSubviews 每次布局也全扫——转场/
    // 滚动期间栏逐帧布局，等于接近每帧两趟遍历（持续发热的真凶之一）。
    // 现在没有周期任务：timer 已删（轮询整棵视图树不是 UIKit 的做法），所有
    // 触发源都是事件（挂载/布局/转场完成/回前台/JS 设置），且只在标脏时遍历。
    /// 视图层级已变化（新 bar / 新滚动视图挂载、栏布局、回前台、转场完成、
    /// JS 改主题或路由门控），下一次重扫需要全量遍历。
    nonisolated(unsafe) static var needsRescan = true
    /// 上次全量重扫时间（CACurrentMediaTime），节流用。
    nonisolated(unsafe) static var lastScanAt: CFTimeInterval = 0
    /// tick 路径（栏/滚动视图挂载与布局这类高频事件）的最小重扫间隔：滚动中
    /// 反复挂载会把脏标记刷成高频，合并到 2s 一次（列表挂载 → 顶栏模糊最迟
    /// 2s 到位；空闲时零成本）。
    static let tickScanInterval: CFTimeInterval = 2.0
    /// 事件路径（回前台 / 转场完成 / JS 设置）的最小重扫间隔：只用于合并同一
    /// 事件的多次回调，不牺牲"新 bar 首帧就要深色"的时效。
    static let eventScanInterval: CFTimeInterval = 0.1
  }

  /// 标记视图层级已变化：下一次 tick / 事件会做一次全量重扫（幂等、零遍历）。
  static func markChromeDirty() { ChromeState.needsRescan = true }

  static func setChromeDarkMode(_ dark: Bool?) { ChromeState.darkMode = dark }

  static func installNavBarChromeHooks() {
    _ = navChromeHooks
    _ = navChromeScrollHooks
  }

  // 顶栏 chrome 的幂等重挂入口（v3 起，2026-08-22；v34 起职责收窄）：窗口/
  // 导航容器底色、栏 trait、栏外观（透明）、双击回顶手势、滚动边缘模糊按
  // 路由幂等重挂。**全事件驱动、无周期任务**（2026-09-12 起）：入口=启动首扫
  // + 回前台（didBecomeActive）+ 转场完成（didShow）+ bar/滚动视图的
  // didMoveToWindow/layoutSubviews + JS 侧主题与路由门控 setter。
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
    // 转场完成重扫（2026-09-02 修复）：push/pop 动画期间 RunLoop 处于 tracking
    // 模式，动画结束后新 bar 已建成但还没被处理（"进帖子页无效果"的 timing
    // 缺口）。didShow 在动画完成时触发 → 主线程立即 force，缺口压到一帧内。
    nc.addObserver(
      forName: Notification.Name("UINavigationControllerDidShowNotification"),
      object: nil,
      queue: .main
    ) { _ in
      DispatchQueue.main.async {
        TiebaNativeModule.forceNavBarLiquidGlass()
      }
    }
    // 兜底重扫：**没有周期性 timer**（2026-09-12 用户质询后删除）。
    // 定时轮询整棵视图树不是 UIKit 的做法——UIKit 的规范是事件驱动：栏/滚动件
    // 挂载与布局、转场完成、回前台、trait 变化各有回调。改前 1.5s 无条件全量
    // 遍历是 v21–v33 自建玻璃层时代的遗留（那时 UIKit 会重建 _UIBarBackground
    // 里的材质视图，只能靠轮询重挂）；v34 起栏外观只写一次且由 setter swizzle
    // 兜住后写，自建层已全部撤除，轮询失去存在理由。
    // 现在的触发源全是事件：本函数注册的通知（回前台 / 转场完成）、
    // navChromeScrollHooks 的 didMoveToWindow/layoutSubviews swizzle、JS 侧
    // setChromeUserInterfaceStyle / setNavBarGlassEnabled。
    return ()
  }()

  static let navChromeScrollHooks: Void = {
    guard !ChromeState.scrollHooked else { return }
    ChromeState.scrollHooked = true
    // 新 bar 挂载即应用：页面 push 瞬间新 UINavigationBar 首次进 window，
    // 若等下一次事件才处理，深色模式下会先渲染系统浅色（真机实测"先白后黑"）。
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
    // layoutSubviews：bar 尺寸/外观变化（外观重写、安全区、旋屏、栏底重建都
    // 会带来一次布局）是"结构可能变了"的事件源——标脏，再由 tick 路径按
    // 最小间隔合并重扫。放在布局结束后执行，避免在布局 pass 内 flush 递归。
    let layoutSelector = #selector(UIView.layoutSubviews)
    if let layoutMethod = class_getInstanceMethod(UINavigationBar.self, layoutSelector) {
      let layoutOriginal = method_getImplementation(layoutMethod)
      typealias LayoutFn = @convention(c) (AnyObject, Selector) -> Void
      let layoutOriginalFn = unsafeBitCast(layoutOriginal, to: LayoutFn.self)
      let layoutBlock: @convention(block) (AnyObject) -> Void = { bar in
        layoutOriginalFn(bar, layoutSelector)
        TiebaNativeModule.markChromeDirty()
        DispatchQueue.main.async {
          _ = TiebaNativeModule.forceNavBarLiquidGlass(tick: true)
        }
      }
      method_setImplementation(layoutMethod, imp_implementationWithBlock(layoutBlock))
    }
    // 滚动视图挂载/卸载即标脏（2026-09-12）：列表在页面 didShow 之后才挂载是
    // 常见路径（骨架 → 列表、加载完成后换数据），事件驱动下必须把这个来源
    // 接上，否则新列表的顶栏模糊要等到下次转场才生效。只写一个布尔，无遍历；
    // 真正的重扫由 tick 路径按最小间隔合并（滚动中反复挂载不会变成每帧遍历）。
    if let scrollMoveMethod = class_getInstanceMethod(UIScrollView.self, moveSelector) {
      let scrollOriginal = method_getImplementation(scrollMoveMethod)
      typealias ScrollMoveFn = @convention(c) (AnyObject, Selector) -> Void
      let scrollOriginalFn = unsafeBitCast(scrollOriginal, to: ScrollMoveFn.self)
      let scrollBlock: @convention(block) (AnyObject) -> Void = { scrollView in
        scrollOriginalFn(scrollView, moveSelector)
        TiebaNativeModule.markChromeDirty()
        DispatchQueue.main.async {
          _ = TiebaNativeModule.forceNavBarLiquidGlass(tick: true)
        }
      }
      method_setImplementation(scrollMoveMethod, imp_implementationWithBlock(scrollBlock))
    }
    // 启动首扫（原 1.5s timer 的第一拍职责）：钩子安装时可能已经有滚动视图/
    // 导航栏挂载过（swizzle 装晚了错过 didMoveToWindow），标脏 + 立即扫一次，
    // 保证首屏状态确定（needsRescan 初值就是 true，这里只是显式化）。
    TiebaNativeModule.markChromeDirty()
    DispatchQueue.main.async {
      _ = TiebaNativeModule.forceNavBarLiquidGlass()
    }
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
  static func forceNavBarLiquidGlass(tick: Bool = false) -> Bool {
    // 全部工作（视图树遍历 + effect/mask 写入）只允许主线程：setEffect:
    // 内部走 NSISEngine，非主线程直接触发 Auto Layout 断言 SIGABRT。
    // 各入口理论都应主线程，这里统一兜底跳转而非崩溃。
    guard Thread.isMainThread else {
      DispatchQueue.main.async { _ = TiebaNativeModule.forceNavBarLiquidGlass(tick: tick) }
      return false
    }
    // 空转治理（2026-09-12）：tick 路径（栏/滚动件挂载与布局这类高频事件）
    // 只有在视图层级被标脏后才真的遍历；事件路径（回前台 / 转场完成 / JS
    // 改主题或路由）先标脏再按 0.1s 合并同一事件的多次回调。两条路径都按
    // 最小间隔节流，被节流跳过时脏标记保留，下一次调用补齐。
    if !tick {
      ChromeState.needsRescan = true
    }
    guard ChromeState.needsRescan else { return false }
    let now = CACurrentMediaTime()
    let minInterval = tick ? ChromeState.tickScanInterval : ChromeState.eventScanInterval
    guard now - ChromeState.lastScanAt >= minInterval else { return false }
    ChromeState.lastScanAt = now
    ChromeState.needsRescan = false
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
      // 双击回顶手势：新 bar 由 didMoveToWindow 钩子标脏后经重扫安装，
      // 这里幂等判重（同一 bar 只装一次）。
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
