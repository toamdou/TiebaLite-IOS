// 原生顶栏 chrome（v34/v37 定稿实现）。
//
// 职责：栏外观透明化 + 外部写入规范化（setter swizzle）+ 路由门控的滚动边缘
// 模糊（UIScrollEdgeEffect.Style.soft）+ 窗口/导航容器底色与**窗口级深浅**
// （应用主题 ≠ 系统外观的唯一决策落点，setChromeDarkMode）+ 幂等重挂入口。
import Foundation
import ObjectiveC
import UIKit

/// 主线程执行（已在主线程则就地同步执行）。
/// ⚠️ 按裸名 `onMain` 搜索引用，不要写成 `\.onMain(`——曾因此被误判为死代码删除。
func onMain(_ work: @escaping () -> Void) {
  if Thread.isMainThread {
    work()
  } else {
    DispatchQueue.main.async(execute: work)
  }
}

enum TiebaChrome {
  /// chrome 侧可变状态与懒加载钩子。
  enum ChromeState {
    /// 应用实际主题（JS 下发）：nil = 跟随系统，非 nil = 应用手动指定深/浅。
    nonisolated(unsafe) static var darkMode: Bool? = nil
    nonisolated(unsafe) static var scrollHooked = false
    /// 已写过"透明外观"的栏（弱引用，随栏释放自动清理）。
    /// 只写一次：写 appearance 会让 UIKit 重建栏底，周期性重写 = 周期性重建。
    nonisolated(unsafe) static let transparentAppearanceBars = NSHashTable<UINavigationBar>.weakObjects()

    // ── 空转治理（2026-09-12 发热审查）──
    // force 每次要做两趟视图树全量遍历：collectChromeBars 扫所有窗口的
    // 整棵树，边缘效果那两个函数再各扫顶层页面整棵树。改前 1.5s timer
    // 无条件全扫，且 UINavigationBar.layoutSubviews 每次布局也全扫——转场/
    // 滚动期间栏逐帧布局，等于接近每帧两趟遍历（持续发热的真凶之一）。
    // 现在没有周期任务：timer 已删（轮询整棵视图树不是 UIKit 的做法），所有
    // 触发源都是事件（栏/页面级滚动视图挂载、栏结构布局、转场完成、回前台、
    // 主题或路由门控设置），且只在标脏时遍历。
    // 2026-09-12 二轮：布局/挂载钩子不再各自 async force，改为结构指纹过滤
    //（noteBarLayoutIfStructuralChange）+ 单块合并（scheduleChromeTick），
    // 事件仍无周期任务，且任何情况下主队列至多一个待执行 tick 块。
    /// 视图层级已变化（新 bar / 新页面级滚动视图挂载、栏结构布局、回前台、
    /// 转场完成、主题或路由门控），下一次重扫需要全量遍历。
    nonisolated(unsafe) static var needsRescan = true
    /// 上次全量重扫时间（CACurrentMediaTime），节流用。
    nonisolated(unsafe) static var lastScanAt: CFTimeInterval = 0
    /// tick 路径（栏/滚动视图挂载与布局这类高频事件）的最小重扫间隔：挂载事件
    /// 已按"页面级滚动视图"收窄（见 navChromeScrollHooks），但同一转场里仍可能
    /// 连来几拍，合并到 2s 一次（列表挂载 → 顶栏模糊最迟 2s 到位；空闲时零成本）。
    static let tickScanInterval: CFTimeInterval = 2.0
    /// 事件路径（回前台 / 转场完成 / JS 设置）的最小重扫间隔：只用于合并同一
    /// 事件的多次回调，不牺牲"新 bar 首帧就要深色"的时效。
    static let eventScanInterval: CFTimeInterval = 0.1
    /// tick 重扫块是否已排队（单块合并闸门，2026-09-12 二轮空转治理）：改前
    /// 栏每次布局、滚动视图每次挂载都无条件往主队列 async 一个 force 块——
    /// 转场/滚动期间栏逐帧布局、列表回收让滚动件反复挂载，主队列被无界块
    /// 灌满，每帧数趟全树遍历（持续发热的真凶之一）。现在至多一个块在飞，
    /// 重复事件只写 needsRescan 这一个布尔。
    nonisolated(unsafe) static var tickScheduled = false
    /// bar 最近一次布局观察到的结构指纹（弱键，bar 销毁自动清理）。只含窗口
    /// 身份 / bounds / 安全区 / 生效 trait / 隐藏位，**不含 frame**：转场期间
    /// frame 逐帧变化，含它标脏会退化成每帧一次。
    /// nonisolated(unsafe)：NSMapTable 不是 Sendable，但只在主线程读写——唯一
    /// 读写点 noteBarLayoutIfStructuralChange 的两条调用路径都是主线程：
    /// layoutSubviews 钩子调它之前先 guard Thread.isMainThread（见下），
    /// 另一条是 forceNavBarLiquidGlass（入口主线程兜底）。
    nonisolated(unsafe) static let barLayoutSignatures =
      NSMapTable<UINavigationBar, BarLayoutSignatureBox>.weakToStrongObjects()
  }

  /// 标记视图层级已变化：下一次 tick / 事件会做一次全量重扫（幂等、零遍历）。
  static func markChromeDirty() { ChromeState.needsRescan = true }

  /// 合并排一次 tick 重扫（2026-09-12 二轮空转治理）：改前每个布局/挂载事件都
  /// 各自 async 一个 force 块，快滚时主队列被无界块灌满（每帧数趟全树遍历）。
  /// 现在至多一个块在飞，且按 tickScanInterval 补齐到上次重扫之后触发：
  /// 行为 2（骨架 → 列表、数据换新，新列表不等转场就要拿到顶栏模糊）最迟一个
  /// tick 间隔内落地；命中节流（块排队期间事件路径刚扫过）就补排一次，不让
  /// 脏标记干等下一个无关事件。脏标记为 false 时块执行即空转返回（空闲零成本）。
  static func scheduleChromeTick() {
    guard !ChromeState.tickScheduled else { return }
    ChromeState.tickScheduled = true
    let elapsed = CACurrentMediaTime() - ChromeState.lastScanAt
    let delay = max(0, ChromeState.tickScanInterval - elapsed)
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
      ChromeState.tickScheduled = false
      _ = TiebaChrome.forceNavBarLiquidGlass(tick: true)
      if ChromeState.needsRescan {
        TiebaChrome.scheduleChromeTick()
      }
    }
  }

  /// 栏布局的结构指纹比较（2026-09-12 二轮空转治理）：让 layoutSubviews 钩子从
  /// "每次布局无条件标脏 + 排重扫"变成"只有结构真变了才标脏"。读取全是 O(1)
  /// 属性、零遍历；窗口身份进指纹用于捕捉 bar 进/出窗口（层级变化）。栏底被
  /// UIKit 重建（行为 4 的原始动因）不改这些字段，但 v34 起栏外观已交还系统
  /// 且只写一次，重建后的栏底自动继承当前 appearance/trait，无需重挂；真正
  /// 需要重扫的新 bar 由 didMoveToWindow（行为 1）+ didShow 事件覆盖。
  private static func noteBarLayoutIfStructuralChange(_ bar: UINavigationBar) -> Bool {
    let signature = BarLayoutSignature(
      windowID: bar.window.map { ObjectIdentifier($0) },
      bounds: bar.bounds,
      safeAreaInsets: bar.safeAreaInsets,
      effectiveStyle: bar.traitCollection.userInterfaceStyle,
      isHidden: bar.isHidden
    )
    if let box = ChromeState.barLayoutSignatures.object(forKey: bar),
      box.signature == signature
    {
      return false
    }
    ChromeState.barLayoutSignatures.setObject(BarLayoutSignatureBox(signature), forKey: bar)
    return true
  }

  /// 栏布局观察值（见 noteBarLayoutIfStructuralChange）。
  /// 不能是 private：ChromeState.barLayoutSignatures 是 internal 的 static，
  /// 而 Swift 要求属性可见性与所持私有类型匹配（否则报 "property must be
  /// declared private because its type uses a private type"）。
  struct BarLayoutSignature: Equatable {
    var windowID: ObjectIdentifier?
    var bounds: CGRect
    var safeAreaInsets: UIEdgeInsets
    var effectiveStyle: UIUserInterfaceStyle
    var isHidden: Bool
  }

  /// 不能是 private：理由同 BarLayoutSignature。
  final class BarLayoutSignatureBox: NSObject {
    let signature: BarLayoutSignature
    init(_ signature: BarLayoutSignature) { self.signature = signature }
  }

  /// 应用主题 → 窗口 trait（窗口级是**唯一决策点**的落点）：nil = 跟随系统
  /// （.unspecified，不锁窗口），非 nil = 应用手动深浅。窗口 override 覆盖整棵
  /// VC/视图树与该窗口内的所有 presented（UIView.h：set on UIWindow "affects the
  /// rootViewController and thus the entire view controller and view hierarchy. It
  /// also affects presentations that happen inside the window."）——因此栏/底栏/
  /// 宿主/表单不再各自写 override。必须同步写：等重扫（节流 0.1–2s）会让主题
  /// 切换瞬间的界面停在旧档（逐处 override 已删，没有第二层兜底）。
  static func setChromeDarkMode(_ dark: Bool?) {
    ChromeState.darkMode = dark
    onMain { TiebaChrome.applyWindowUserInterfaceStyle() }
  }

  /// 把当前决定写进主窗口（.normal 级窗口，未 key 也算：启动期主题在
  /// makeKeyAndVisible 之前落地，只有 isKeyWindow 的旧写点会漏掉首帧）。
  /// 只写 style：窗口/容器底色仍归重扫（那里同时管非 key 窗口的兜底与背景色）。
  private static func applyWindowUserInterfaceStyle() {
    let style = chromeUserInterfaceStyle
    for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
      for window in scene.windows where window.windowLevel == .normal {
        if window.overrideUserInterfaceStyle != style {
          window.overrideUserInterfaceStyle = style
        }
      }
    }
  }

  static func installNavBarChromeHooks() {
    _ = navChromeHooks
    _ = navChromeScrollHooks
  }

  // 顶栏 chrome 的幂等重挂入口（v3 起，2026-08-22；v34 起职责收窄）：窗口
  // 底色/窗口 trait、导航容器底色、栏外观（透明）、双击回顶手势、滚动边缘模糊
  // 按路由幂等重挂。**全事件驱动、无周期任务**（2026-09-12 起）：入口=启动首扫
  // + 回前台（didBecomeActive）+ 转场完成（didShow）+ bar/滚动视图的
  // didMoveToWindow/layoutSubviews + JS 侧主题与路由门控 setter。
  //
  // 历史（勿再回头）：v3–v33 曾在渲染层直接操作 _UIBarBackground 里的
  // UIVisualEffectView（设 systemMaterial/ultraThin + 渐变 mask）自建磨砂——
  // iOS 27 上栏底材质会被 UIKit 按 appearance 重建（双图层感/矩形磨砂），
  // v34 起全部撤除；2026-09-16 定案为"两态 appearance + 系统滚动边缘效果"
  //（见 applyBarAppearance），不再自建任何材质层。
  static let navChromeHooks: Void = {
    let nc = NotificationCenter.default
    nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        TiebaChrome.forceNavBarLiquidGlass()
      }
    }
    // 转场完成重扫（2026-09-02 修复）：push/pop 动画期间 RunLoop 处于 tracking
    // 模式，动画结束后新 bar 已建成但还没被处理（"进帖子页无效果"的 timing
    // 缺口）。转场完成走 TiebaNavigator 的 UINavigationControllerDelegate.didShow
    //（:588 的公开回调，函数末尾 force）——2026-09-13 起不再监听
    // "UINavigationControllerDidShowNotification"：该名在 iOS 27 SDK 头文件里
    // 不存在（未公开通知），监听它等于依赖私有实现。
    // 兜底重扫：**没有周期性 timer**（2026-09-12 用户质询后删除）。
    // 定时轮询整棵视图树不是 UIKit 的做法——UIKit 的规范是事件驱动：栏/滚动件
    // 挂载、栏结构布局、转场完成、回前台各有回调。改前 1.5s 无条件全量遍历是
    // v21–v33 自建玻璃层时代的遗留（那时 UIKit 会重建 _UIBarBackground 里的
    // 材质视图，只能靠轮询重挂）；v34 起栏外观在挂载时一次写好、不再重写，
    // 自建层已全部撤除，轮询失去存在理由。
    // 现在的触发源全是事件：本函数注册的通知（回前台 / 转场完成见上）、
    // navChromeScrollHooks 的 didMoveToWindow/layoutSubviews、主题或路由门控设置。
    return ()
  }()

  static let navChromeScrollHooks: Void = {
    guard !ChromeState.scrollHooked else { return }
    ChromeState.scrollHooked = true
    // 新 bar 挂载即应用：页面 push 瞬间新 UINavigationBar 首次进 window，
    // 若等下一次事件才处理，深色模式下会先渲染系统浅色（真机实测"先白后黑"）。
    // didMoveToWindow 必在主线程；外观/双击回顶/按压判定在这里同步直写
    // （bar 未入 window 时 collectChromeBars 扫不到、force 会早退），其余交给
    // 标脏 + 合并 tick。**栏的深浅不在这里写**：窗口级 override 已覆盖整棵树
    // （setChromeDarkMode），bar 入窗即继承应用深浅、首帧就是深色。
    let moveSelector = #selector(UIView.didMoveToWindow)
    if let moveMethod = class_getInstanceMethod(UINavigationBar.self, moveSelector) {
      let moveOriginal = method_getImplementation(moveMethod)
      typealias MoveFn = @convention(c) (AnyObject, Selector) -> Void
      let moveOriginalFn = unsafeBitCast(moveOriginal, to: MoveFn.self)
      let moveBlock: @convention(block) (AnyObject) -> Void = { bar in
        moveOriginalFn(bar, moveSelector)
        guard let navBar = bar as? UINavigationBar else { return }
        // 下面的 appearance / 手势安装写的都是 @MainActor 状态，而这里是非隔离的
        // ObjC block：必须 assumeIsolated 才能通过 Swift 6.4 的检查。契约成立
        // 的原因：didMoveToWindow 由 UIKit 在主线程调用（本块是该方法的
        // swizzle 实现）。用 assumeIsolated 而不是派主队列——外观必须在返回前
        // 同步写入，否则"首帧即深色"失效（先白后黑回归）；若哪天真被后台触达，
        // 会立刻 trap 而不是带病写栏状态（响亮失败优于隐性竞争）。
        MainActor.assumeIsolated {
          // 栏入窗即写一次"两态外观"（见 applyBarAppearance），另外装两个手势：
          // 双击回顶、栏内按压触觉。
          TiebaChrome.ensureBarAppearance(for: navBar)
          TiebaChrome.installNavDoubleTapToTop(on: navBar)
          TiebaChrome.installChromePressHaptics(on: navBar)
          // 其余（滚动边缘效果、窗口/导航容器底色、底栏）由重扫负责：标脏 + 合并
          // 排一次 tick，等本层级变更走完再做全量遍历。
          TiebaChrome.markChromeDirty()
          TiebaChrome.scheduleChromeTick()
        }
      }
      method_setImplementation(moveMethod, imp_implementationWithBlock(moveBlock))
    }
    // layoutSubviews：bar 尺寸/外观变化（外观重写、安全区、旋屏、栏底重建都
    // 会带来一次布局）是"结构可能变了"的事件源。放在布局结束后执行，避免在
    // 布局 pass 内 flush 递归。2026-09-12 二轮空转治理：标脏前先过结构指纹
    // （noteBarLayoutIfStructuralChange），重复布局不再放大成重复重扫。
    let layoutSelector = #selector(UIView.layoutSubviews)
    if let layoutMethod = class_getInstanceMethod(UINavigationBar.self, layoutSelector) {
      let layoutOriginal = method_getImplementation(layoutMethod)
      typealias LayoutFn = @convention(c) (AnyObject, Selector) -> Void
      let layoutOriginalFn = unsafeBitCast(layoutOriginal, to: LayoutFn.self)
      let layoutBlock: @convention(block) (AnyObject) -> Void = { bar in
        layoutOriginalFn(bar, layoutSelector)
        guard let navBar = bar as? UINavigationBar else { return }
        // 布局必在主线程；万一被后台触达只标脏（不碰任何 UIKit 状态），保底不崩。
        guard Thread.isMainThread else {
          TiebaChrome.markChromeDirty()
          return
        }
        // 2026-09-12 二轮空转治理：改前这里每次布局都标脏 + 无条件 async 一个
        // force——转场/滚动期间栏逐帧布局＝每帧一个块、每帧两趟全树遍历。
        // 现在先用结构指纹过滤重复布局，只有真的变了才标脏，重扫交给至多一个
        // 合并 tick。行为 4（栏底重建）仍由下一次结构布局捕捉；行为 1 由上面的
        // didMoveToWindow 同步写 trait/外观/手势独立保证，不依赖本钩子。
        guard TiebaChrome.noteBarLayoutIfStructuralChange(navBar) else { return }
        TiebaChrome.markChromeDirty()
        TiebaChrome.scheduleChromeTick()
      }
      method_setImplementation(layoutMethod, imp_implementationWithBlock(layoutBlock))
    }
    // 滚动视图挂载即标脏（2026-09-12）：列表在页面 didShow 之后才挂载是常见
    // 路径（骨架 → 列表、加载完成后换数据），事件驱动下必须把这个来源接上，
    // 否则新列表的顶栏模糊要等到下次转场才生效（行为 2）。
    // 2026-09-13 收紧（发热审查）：改前**无条件**标脏——行内横滑条/图片条是
    // 列表的后代，快滚回收时反复挂载/卸载，脏标记在快滚期间永远为真，自续期的
    // tick 链于是每 2s 跑三趟全树遍历。现在只认"页面级"滚动视图：挂在窗口上、
    // 可滚动、可见、且自身没有 UIScrollView 祖先（列表内部的行内滚动件全部
    // 排除，它们只需就地关掉 scrollsToTop——见下）。页面级挂载是每屏几次的
    // 事件，绝不会被滚动放大。
    if let scrollMoveMethod = class_getInstanceMethod(UIScrollView.self, moveSelector) {
      let scrollOriginal = method_getImplementation(scrollMoveMethod)
      typealias ScrollMoveFn = @convention(c) (AnyObject, Selector) -> Void
      let scrollOriginalFn = unsafeBitCast(scrollOriginal, to: ScrollMoveFn.self)
      let scrollBlock: @convention(block) (AnyObject) -> Void = { scrollView in
        scrollOriginalFn(scrollView, moveSelector)
        guard let scroll = scrollView as? UIScrollView else { return }
        // 下面读写的 superview/isScrollEnabled/scrollsToTop 都是 @MainActor 状态，
        // 非隔离块里直接碰会让整个立即调用闭包被推断成 @MainActor（属性初始化即
        // 报 "main actor-isolated default value in a nonisolated context"）。
        // 必须 assumeIsolated：didMoveToWindow 由 UIKit 在主线程调用是本块的契约；
        // 不派主队列，是因为"页面级滚动视图"的判定要落在挂载当拍。
        MainActor.assumeIsolated {
          // 卸载（superview 已 nil）不标脏：移除不会让任何既有配置失效。
          guard scroll.superview != nil, scroll.isScrollEnabled, !scroll.isHidden,
            scroll.alpha > 0.01
          else { return }
          guard scroll.nearestAncestor(where: { $0 is UIScrollView }) == nil else {
            // 嵌套滚动件（行内横滑条、页内表格…）永远不是"点状态栏回顶"的对象：
            // 系统只认屏上唯一一个 scrollsToTop，它们默认 true 会把主滚动视图的
            // 唯一名额顶掉（SDK 原文：多于一个则整个手势不生效）。这里按挂载点
            // 就地关掉，不必等状态栏手势真被点到。
            scroll.scrollsToTop = false
            return
          }
          TiebaChrome.markChromeDirty()
          TiebaChrome.scheduleChromeTick()
        }
      }
      method_setImplementation(scrollMoveMethod, imp_implementationWithBlock(scrollBlock))
    }
    // 启动首扫（原 1.5s timer 的第一拍职责）：钩子安装时可能已经有滚动视图/
    // 导航栏挂载过（swizzle 装晚了错过 didMoveToWindow），标脏 + 立即扫一次，
    // 保证首屏状态确定（needsRescan 初值就是 true，这里只是显式化）。
    TiebaChrome.markChromeDirty()
    DispatchQueue.main.async {
      _ = TiebaChrome.forceNavBarLiquidGlass()
    }
    return ()
  }()

  // ── 原生顶栏（2026-09-11 用户定调，2026-09-16 定案）──
  // 用户要求："顶栏完全使用 UIKit，并遵循 iOS 26 之后的 UIKit 设计规范"。
  //
  // 定案一句话：**一个字节的栏级 appearance 都不写**，顶栏（含那层模糊）完全由
  // UIKit 自动渲染。铁律与底栏同源（见 TiebaMainTabBarController.applyTheme）：
  // 任何 bar 级 appearance 写入都会让 UIKit 退出**自动 Liquid Glass 渲染管线**，
  // 栏就退化成旧磨砂（实心色带 / 四边硬的矩形）——那正是用户逐轮否掉的那几版。
  //
  // 走过的几条错路（别再回去）：
  //   · 栏外观置透明（configureWithTransparentBackground）：栏底彻底没有材质，
  //     只剩系统滚动边缘效果，而它只铺状态栏那一条 ⇒ 用户报"只有状态栏区域有模糊"；
  //   · 栏自带系统材质（appearance.backgroundEffect = UIBlurEffect(...)）：那是
  //     旧世界的磨砂，四边是硬的 ⇒ "顶栏模糊退化成最差的版本"；
  //   · 自建 UIVisualEffectView + CAGradientLayer 渐变 mask（手写溶解带）：能做出
  //     软边，但不是系统渲染的玻璃，观感与 Liquid Glass 不同、栏底还会留一条亮边
  //     ⇒ "非常拉跨，根本不是 iOS 26 里 UIKit 实现模糊的接口"。
  //
  // 定案（2026-09-16，最终）：**两态 appearance + 系统的滚动边缘效果**，不自建层。
  //   · standard/compact = `configureWithDefaultBackground()`：内容滚到栏下时用系统
  //     自己的材质（iOS 26 的 Liquid Glass；随深浅/背景自适应，不会偏亮）；
  //   · scrollEdge = `configureWithTransparentBackground()`：停在顶部时栏底留白，
  //     那一段由 `UIScrollEdgeEffect`（软边 = 无边界渐变）承担；
  //   · 四态都 `shadowColor = .clear`（用户不要那条分隔线/亮边）；
  //   · 顶边**不写**边缘效果（强行写 soft = 每个滚动视图每帧多渲一层模糊，
  //     用户实测删掉后滑动变好）；底边显式关（用户不要那块糊）。
  // 反面清单（都试过、都被否）：四态全透明（栏永远没材质 ⇒ "只有状态栏有模糊"）、
  // 自塞 UIBlurEffect（"矩形硬边、最差版本"）、自建 UIGlassEffect 玻璃层盖满顶部
  // （"顶栏偏亮、与背景不协调" + 退出页面后残留一秒）、UIBlurEffect + 渐变 mask
  //（"非常拉跨、栏底一条亮边"）。

  // ── 原生顶栏（2026-09-11 用户定调，2026-09-16 定案）──
  // 用户要求："顶栏完全使用 UIKit，并遵循 iOS 26 之后的 UIKit 设计规范"。
  //
  // 定案一句话：**一个字节的栏级 appearance 都不写**，顶栏（含那层模糊）完全由
  // UIKit 自动渲染。铁律与底栏同源（见 TiebaMainTabBarController.applyTheme）：
  // 任何 bar 级 appearance 写入都会让 UIKit 退出**自动 Liquid Glass 渲染管线**，
  // 栏就退化成旧磨砂（实心色带 / 四边硬的矩形）——那正是用户逐轮否掉的那几版。
  //
  // 走过的几条错路（别再回去）：
  //   · 栏外观置透明（configureWithTransparentBackground）：栏底彻底没有材质，
  //     只剩系统滚动边缘效果，而它只铺状态栏那一条 ⇒ 用户报"只有状态栏区域有模糊"；
  //   · 栏自带系统材质（appearance.backgroundEffect = UIBlurEffect(...)）：那是
  //     旧世界的磨砂，四边是硬的 ⇒ "顶栏模糊退化成最差的版本"；
  //   · 自建 UIVisualEffectView + CAGradientLayer 渐变 mask（手写溶解带）：能做出
  //     软边，但不是系统渲染的玻璃，观感与 Liquid Glass 不同、栏底还会留一条亮边
  //     ⇒ "非常拉跨，根本不是 iOS 26 里 UIKit 实现模糊的接口"。
  //
  // 定案（2026-09-16）：顶栏玻璃 = **UIGlassEffect**（iOS 26 的玻璃接口，仓库既有配方，
  // 见 applyNavGlassLayer），栏自身 appearance 置透明，玻璃只由这一个提供者画。
  // 此外本文件对栏只做：装手势（双击回顶、栏内按压触觉）、底边滚动边缘效果关掉。
  // 顶边滚动边缘效果**不写**——它渲出来的那一层被玻璃层盖住，只会白花每帧的 GPU。
  // **不手写材质、不挂渐变 mask**（UIBlurEffect + mask 那版用户评价"非常拉跨、栏底一条亮边"）。
  /// 栏外观 = **两态**（这是最终定案，见文件头"原生顶栏"节）：
  ///   · standard / compact：`configureWithDefaultBackground()` —— 内容滚到栏下时用
  ///     系统自己的材质（iOS 26 的 Liquid Glass，材质随深浅与背景自适应，不会偏亮）；
  ///   · scrollEdge / compactScrollEdge：`configureWithTransparentBackground()` —— 内容
  ///     停在顶部时栏底留白，那一段的渐隐由系统的滚动边缘效果承担
  ///     （`UIScrollEdgeEffect`，软边 = 无边界）。
  /// `shadowColor = .clear` 四个态都写：用户点名不要那条分隔线/亮边。
  ///
  /// 为什么必须是"两态"而不是全透明：`UINavigationBar.h` 的 scrollEdgeAppearance
  /// 说明「未设时用 modified standardAppearance」，`UIViewController.h` 的
  /// setContentScrollView 段又说栏底背景模糊由被跟踪的滚动视图决定、跟踪不到就
  /// **透明**。之前把四个态全写透明 ⇒ 栏永远拿不到材质，只剩滚动边缘效果那一条
  /// ⇒ 用户报"只有状态栏区域有模糊"。
  private static func applyBarAppearance(to bar: UINavigationBar) {
    ChromeState.transparentAppearanceBars.add(bar)
    let standard = UINavigationBarAppearance()
    standard.configureWithDefaultBackground()
    standard.shadowColor = .clear
    let scrollEdge = UINavigationBarAppearance()
    scrollEdge.configureWithTransparentBackground()
    scrollEdge.shadowColor = .clear
    bar.standardAppearance = standard
    bar.compactAppearance = standard
    bar.scrollEdgeAppearance = scrollEdge
    bar.compactScrollEdgeAppearance = scrollEdge
    // item 级外观优先于栏级：置 nil 继承栏级（历史上 RNScreens 写的就是这一层）。
    if let item = bar.topItem {
      if item.standardAppearance != nil { item.standardAppearance = nil }
      if item.scrollEdgeAppearance != nil { item.scrollEdgeAppearance = nil }
      if item.compactAppearance != nil { item.compactAppearance = nil }
      if item.compactScrollEdgeAppearance != nil { item.compactScrollEdgeAppearance = nil }
    }
  }

  /// 幂等补写：新栏（挂载/启动首扫时已经存在的那些）写一次，写过的不再碰。
  @discardableResult
  private static func ensureBarAppearance(for bar: UINavigationBar) -> Bool {
    guard !ChromeState.transparentAppearanceBars.contains(bar) else { return false }
    applyBarAppearance(to: bar)
    return true
  }

  /// 顶层可见页面视图（presented 链 → 导航栈顶）：底边边缘效果的作用域。
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

  /// 底边边缘效果一律显式关掉（用户 2026-09-14 报"底栏区域带模糊"要删；底栏是
  /// 悬浮药丸玻璃，内容从它下面穿过就是系统原生观感）。iOS 26 特有；17 无此层，跳过。
  ///
  /// effect 的 `hidden` 默认 false = 系统 automatic，所以要写才关得掉。判据用
  /// **effect 自身状态**而不是"写过没写过"的记账：这样即使它被 UIKit 重建复位，
  /// 下一轮也会被纠回来（自愈），而稳态下（已 hidden）一次都不写——写边缘效果会走
  /// NSISEngine，每轮都写就是周期性触发布局引擎操作。
  ///
  /// ⚠️ 写它会连带把另一条边（顶边）复位成系统默认——顶边我们不写了（自动态即
  /// 目标态），所以这个副作用无害；但**不要**再回头去"重申顶边"，那等于给每个滚动
  /// 视图每帧多渲一层被玻璃层盖住的模糊。
  @discardableResult
  private static func hideBottomScrollEdgeEffects() -> Bool {
    guard let screen = topScreenView(), screen.bounds.height > 0 else { return false }
    var changed = false
    screen.forEachSubviewRecursively { view in
      guard let scroll = view as? UIScrollView else { return }
      if hideEdgeEffect(scroll) { changed = true }
    }
    return changed
  }

  /// 幂等隐藏一个滚动视图的底边边缘效果（目标状态只有一个：hidden）。
  /// iOS 26 才有 UIScrollEdgeEffect；17 上根本没有这层模糊，直接返回 false（什么都没改）。
  @discardableResult
  private static func hideEdgeEffect(_ scroll: UIScrollView) -> Bool {
    if #available(iOS 26.0, *) {
      let effect = scroll.bottomEdgeEffect
      guard !effect.isHidden else { return false }
      effect.isHidden = true
      return true
    }
    return false
  }

  @discardableResult
  static func forceNavBarLiquidGlass(tick: Bool = false) -> Bool {
    // 全部工作（视图树遍历 + effect/mask 写入）只允许主线程：setEffect:
    // 内部走 NSISEngine，非主线程直接触发 Auto Layout 断言 SIGABRT。
    // 各入口理论都应主线程，这里统一兜底跳转而非崩溃。
    guard Thread.isMainThread else {
      DispatchQueue.main.async { _ = TiebaChrome.forceNavBarLiquidGlass(tick: tick) }
      return false
    }
    // 空转治理（2026-09-12）：tick 路径（栏/滚动件挂载与布局这类高频事件）
    // 只有在视图层级被标脏后才真的遍历；事件路径（回前台 / 转场完成 / JS
    // 改主题或路由）先标脏再按 0.1s 合并同一事件的多次回调。两条路径都按
    // 最小间隔节流，被节流跳过时脏标记保留并补排一次 tick（见下），不会丢。
    if !tick {
      ChromeState.needsRescan = true
    }
    guard ChromeState.needsRescan else { return false }
    let now = CACurrentMediaTime()
    let minInterval = tick ? ChromeState.tickScanInterval : ChromeState.eventScanInterval
    guard now - ChromeState.lastScanAt >= minInterval else {
      // 被节流跳过：脏标记保留（上面已置位），补排一次 tick 保证一定会被消化
      // ——事件路径的调用方是"转场完成/回前台"这类一次性回调，不会自己再来。
      TiebaChrome.scheduleChromeTick()
      return false
    }
    ChromeState.lastScanAt = now
    ChromeState.needsRescan = false
    let chromeBars = collectChromeBars()
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
        if window.backgroundColor != TiebaChrome.chromeWindowColor {
          window.backgroundColor = TiebaChrome.chromeWindowColor
        }
      }
    }
    // 窗口 trait 幂等重申（决策结果是 setChromeDarkMode 时同步写的）：2026-09-02
    // 修复"右滑退出漏白"——pop/push 转场容器（UITransitionView）背景跟随 window
    // 的 trait 而非 backgroundColor，手动深色 + 系统浅色时容器按系统渲染成白，
    // 页面移开露出白底（真机实测）。跟随系统时是 .unspecified，不锁窗口。
    applyWindowUserInterfaceStyle()
    // 2026-09-02 修复"用力回弹漏白"：UIScrollView 回弹露出的是导航栈容器
    // （UINavigationController.view）——iOS 27 其默认背景跟随系统 trait，
    // 手动深色 + 系统浅色/居中系统时按浅色 systemBackground 渲染成白。
    // 与 window 同源同步应用主题底色（幂等比较，不破坏系统默认 nil 语义）。
    // 覆盖全部嵌套导航容器（非仅 rootViewController 层级）。
    let navContainerBG = TiebaChrome.chromeWindowColor
    for navView in TiebaChrome.collectNavigationContainerViews() {
      if navView.backgroundColor != navContainerBG {
        navView.backgroundColor = navContainerBG
      }
    }
    guard !chromeBars.navBars.isEmpty || !chromeBars.tabBars.isEmpty else { return false }
    var applied = false
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for navBar in chromeBars.navBars {
      // 栏内按压判定（HDR 高光 + 轻触觉）与双击回顶手势：两者在 bar 挂载钩子里
      // 已装好（见 navChromeScrollHooks.didMoveToWindow），这里幂等补齐
      // （钩子安装晚于某根栏挂载时的漏网，判重零成本）。
      installNavDoubleTapToTop(on: navBar)
      installChromePressHaptics(on: navBar)
      if ensureBarAppearance(for: navBar) { applied = true }
      // 栏 trait 不再逐栏写：深色常驻+系统浅色时原生栏材质（含 UISearchBar）
      // 曾按系统渲染成浅色，现在由窗口级 override 一次覆盖整棵树
      //（setChromeDarkMode，含 presented 里的栏）；导航容器的漏白底色已在上面的
      // collectNavigationContainerViews 循环同步。栏外观一个字节都不写（见文件头
      // "原生顶栏"节）：交给 UIKit 的自动 Liquid Glass 管线。
    }
    // 底栏不装按压手势：底栏项的视图层级不是公开的 UIControl 保证（栏内 hitTest
    // 找不到 UIControl ⇒ 手势永远不发触觉）；底栏触觉走 UITabBarControllerDelegate。
    // 只关底边（用户明确不要那块糊）。顶边**不写**：栏在滚动边缘态是透明的，
    // 那一段的渐隐交给系统的滚动边缘效果（automatic）；我们曾强行写过 soft，
    // 每个滚动视图每帧多渲一层模糊，用户实测"删掉它滑动变好"（2026-09-16）。
    if hideBottomScrollEdgeEffects() {
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

  /// 扫描全部窗口的视图树，一次凑齐 chrome 关心的两种系统栏。两者来自同一次
  /// 遍历（导航栏要挂双击回顶 + 按压判定，底栏要挂按压判定；分两次扫等于白扫
  /// 第二趟）。
  private static func collectChromeBars() -> (navBars: [UINavigationBar], tabBars: [UITabBar]) {
    var navBars: [UINavigationBar] = []
    var tabBars: [UITabBar] = []
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    for scene in scenes {
      for window in scene.windows {
        window.forEachSubviewRecursively { view in
          if let bar = view as? UINavigationBar {
            navBars.append(bar)
          } else if let tabBar = view as? UITabBar {
            tabBars.append(tabBar)
          }
        }
      }
    }
    return (navBars, tabBars)
  }

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

  /// 应用主题 → 窗口/chrome trait：nil 还原 .unspecified（跟随系统，不锁窗口）。
  /// 唯一消费者是窗口级 override（见 applyWindowUserInterfaceStyle）。
  static var chromeUserInterfaceStyle: UIUserInterfaceStyle {
    guard let dark = ChromeState.darkMode else { return .unspecified }
    return dark ? .dark : .light
  }
}
