// 状态指示器：**状态只描述「画什么」，Context 负责「演算」**。
//
// 移植自上游 submodules/SemanticStatusNode/（SemanticStatusNode.swift 548 行 + 四个 *Context 文件）。
// 搬的是那套范式，不是逐行代码：
//   状态 enum（值类型，等值可比）        —— 只描述「现在该显示什么」
//        ↓ 每次换状态时映射一次
//   Context（引用类型，**带时间轴**）     —— 负责演算：0→1 的勾选描边、进度插值、旋转推进、形变过渡；
//        ↓ drawingState() 产出不可变快照     draw 永远不碰它
//   Drawing（不可变值）                  —— 只会在 CGContext 上画；画的时候没有时间、没有状态
// 这样切分的好处：draw 是纯函数、可重入、可离屏；动画状态只活在主线程的 Context 里，
// 不会出现「画到一半状态变了」。
//
// 与本仓已有两个件的区别（UI/Nodes/TiebaActivityIndicator、UI/Drawing/TiebaCheckNode）：
//   · TiebaActivityIndicator 是**单一职责**的转圈视图（系统 UIActivityIndicatorView 的自绘版）：
//     没有状态机、没有过渡，只服务「加载中」一处；
//   · TiebaCheckNode 是**参数→位图**的无状态绘制（勾选框的选中/高亮），它不认识「进度/图标」；
//   · 本件是**多态状态指示器**：同一块地方在 进度/勾选/图标 之间切换，切换还带过渡。
//     三者不重复：前两个各自把一件事做透，本件负责「同一位置的形态切换」。
//     将来若合并：CheckNode 的绘制可以成为本件的一个 Context 实现（接口形状已经对得上：
//     参数化主题 + 进度值 → 绘制），但那是接线时的事；本轮不合并（合并会动既有件的公开 API）。
//
// 相对上游的改动（逐条）：
//   1. ASDisplayNode + 异步图层 + Display/SwiftSignalKit/RLottieBinding/GZip 依赖全部去掉：
//      换成 UIView + CADisplayLink + draw(_:)。上游把快照算在 drawParameters(forAsyncLayer:) 里、
//      在后台线程画；本移植在主线程算好快照再画（快照纪律不变，只是不再有后台绘制线程）。
//   2. PresentationTheme / 背景图 / cutout（挖洞）/ 前景覆盖层不搬——那是上游聊天列表项的外观体系，
//      本件只留「一个圆心 + 一个前景色」，底色直接用 UIView.backgroundColor。
//   3. secretTimeout（密聊自毁倒计时）不搬：那是上游密聊业务，贴吧没有对应场景；
//      download/play/pause 三个**业务图标 case** 也不搬（见下面 TiebaStatusIcon）：只留 SF Symbols 机制。
//   4. 播/暂停之间的**形变**改为过渡淡入淡出：上游在同一 Context 内插值 SVG 路径，
//      本移植的图标来自 SF Symbols，没有路径可插值。
//   5. 禁用 Swift 6 绕过：本件是 @MainActor 的 UIView 子类，Context 全部 @MainActor；
//      没有 nonisolated(unsafe) / @unchecked Sendable / assumeIsolated。
import UIKit

/// 状态：**只描述画什么**。等值可比，好让调用方幂等设置。
public enum TiebaStatusState: Equatable {
    /// 进度环外观（inset/lineWidth 按 50pt 基准等比缩放，见 Context 的 factor）。
    public struct ProgressAppearance: Equatable, Sendable {
        public var inset: CGFloat
        public var lineWidth: CGFloat
        public init(inset: CGFloat, lineWidth: CGFloat) {
            self.inset = inset
            self.lineWidth = lineWidth
        }
    }

    /// 勾选外观。
    public struct CheckAppearance: Equatable, Sendable {
        public var lineWidth: CGFloat
        public init(lineWidth: CGFloat) {
            self.lineWidth = lineWidth
        }
    }

    case none
    case check(appearance: CheckAppearance?)
    /// value = nil 表示「不确定进度」（自己转圈）；cancelEnabled 时中间叠一个 ×。
    case progress(value: CGFloat?, cancelEnabled: Bool, appearance: ProgressAppearance?, animateRotation: Bool)
    case icon(TiebaStatusIcon)
}

/// 图标状态。上游的 download/play/pause 是自写 SVG 路径，这里用系统符号或外部图片。
public enum TiebaStatusIcon: Equatable {
    case none
    /// SF Symbols 名（例如 arrow.down.circle / play.fill / pause.fill）。
    /// 上游把 download/play/pause 写成三个独立 case 并配自绘 SVG，那是它播放器/下载的业务图标；
    /// 本仓只留「给个符号名」这一个机制，业务语义归调用方（要播就传 play.fill）。
    case systemImage(String)
    case image(UIImage)
}

/// 快照：Context 算完的、**不可变**的「这一帧画什么」。draw 只认它。
protocol TiebaStatusDrawing {
    func draw(in context: CGContext, size: CGSize, foregroundColor: UIColor)
}

/// 演算器：把「状态 + 时间」算成快照。实现在 TiebaStatusNodeContexts.swift。
@MainActor
protocol TiebaStatusContext: AnyObject {
    /// 是否需要继续按帧重算（转圈、0→1 描边时为 true）。
    var isAnimating: Bool { get }
    /// transitionFraction：本状态淡入的进度（0…1），过渡期由节点传入。
    func drawingState(transitionFraction: CGFloat) -> TiebaStatusDrawing
}

/// 多态状态指示器。UIView 本身已受 MainActor 隔离，这里不再叠一层标注。
///
/// 用法：
///   let node = TiebaStatusNode(foregroundColor: .white)
///   node.setState(.progress(value: 0.4, cancelEnabled: true, appearance: nil, animateRotation: false))
/// 尺寸由调用方给（默认 24×24 只是 intrinsicContentSize），绘制按 size.width 等比缩放。
public final class TiebaStatusNode: UIView {
    /// 当前状态。幂等：设成同一个状态不会重启动画。
    public private(set) var state: TiebaStatusState = .none

    /// 前景色（环/勾/图标都吃它）。背景色走 UIView.backgroundColor。
    public var foregroundColor: UIColor = .white {
        didSet {
            guard foregroundColor != oldValue else { return }
            refreshSnapshot()
            setNeedsDisplay()
        }
    }

    public override var intrinsicContentSize: CGSize { CGSize(width: 24, height: 24) }

    /// 演算器（带时间轴）。
    private var stateContext: TiebaStatusContext
    /// 换状态时的过渡：旧 Context 在 duration 内淡出。
    private var transition: Transition?
    /// 当前帧的快照与上一状态的快照（**draw 只读这两个不可变值**）。
    private var snapshot: TiebaStatusDrawing
    private var previousSnapshot: TiebaStatusDrawing?
    private var pendingCompletion: (() -> Void)?

    private var displayLink: CADisplayLink?
    private let linkProxy = TiebaStatusLinkProxy()

    private struct Transition {
        let start: CFTimeInterval
        let duration: CFTimeInterval
        let previous: TiebaStatusContext
    }

    /// 过渡时长与上游一致（0.18s）。
    private static let transitionDuration: CFTimeInterval = 0.18

    public init(foregroundColor: UIColor = .white) {
        self.foregroundColor = foregroundColor
        let context = TiebaStatusState.none.makeContext(current: nil)
        self.stateContext = context
        self.snapshot = context.drawingState(transitionFraction: 1)
        super.init(frame: .zero)
        self.backgroundColor = .clear
        self.isOpaque = false
        self.contentMode = .redraw   // 帧率由 display link 控制，交给系统按需重绘
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("TiebaStatusNode 只支持代码创建")
    }

    /// 换状态。animated 时旧状态淡出、新状态淡入；同一状态重复设置是空操作。
    public func setState(_ newState: TiebaStatusState, animated: Bool = true, completion: (() -> Void)? = nil) {
        guard newState != state else {
            completion?()
            return
        }
        let previous = stateContext
        state = newState
        stateContext = newState.makeContext(current: previous)
        if animated && previous !== stateContext {
            transition = Transition(start: CACurrentMediaTime(), duration: Self.transitionDuration, previous: previous)
            pendingCompletion = completion
        } else {
            transition = nil
            pendingCompletion = nil
            completion?()
        }
        updateAnimations()
    }

    // MARK: - 演算驱动

    /// 只在"过渡中 或 Context 说要动"时开 display link，其余立刻停（上游的 ConstantDisplayLinkAnimator 同义）。
    ///
    /// 为什么要停：CADisplayLink 不停就是每秒 60 次回调 + 每秒 60 次 setNeedsDisplay，
    /// 一个静止的勾选图标不该让 CPU/GPU 一直转。上游的 Context.isAnimating 恒为 true（它另有节奏控制），
    /// 本移植让 Context 如实回答，这里就能真的停下来。
    private func updateAnimations() {
        let animating = transition != nil || stateContext.isAnimating
        if animating {
            startDisplayLink()
        } else {
            stopDisplayLink()
        }
        refreshSnapshot()
        setNeedsDisplay()
    }

    /// 算这一帧的快照。**只有这里碰时间与 Context**，draw 只消费结果。
    ///
    /// 为什么要把"算"和"画"分开：UIKit 的 draw(_:) 可能在任意时机被调用（setNeedsDisplay 合并、
    /// 离屏渲染、快照），如果 draw 里现算进度，同一帧里"状态"可能已经被 setState 换掉一半——
    /// 轻则闪一帧旧值，重则读到正在被改的 Context 造成撕裂。上游在 ASDisplayNode 里把这段放在
    /// drawParameters(forAsyncLayer:)（主线程）而 draw 在后台线程，本移植没有后台绘制线程，
    /// 但纪律一样：**draw 里只有不可变值**。
    private func refreshSnapshot() {
        let timestamp = CACurrentMediaTime()
        var fraction: CGFloat = 1
        if let transition = transition {
            var t = CGFloat((timestamp - transition.start) / transition.duration)
            t = min(1, max(0, t))
            fraction = t
            if t >= 1 {
                self.transition = nil
                previousSnapshot = nil
                // 过渡结束再回调：调用方拿到的时机与"画完"一致
                let completion = pendingCompletion
                pendingCompletion = nil
                completion?()
            } else {
                previousSnapshot = transition.previous.drawingState(transitionFraction: 1 - t)
            }
        } else {
            previousSnapshot = nil
        }
        snapshot = stateContext.drawingState(transitionFraction: fraction)
    }

    fileprivate func displayTick() {
        updateAnimations()
    }

    private func startDisplayLink() {
        if let displayLink = displayLink {
            displayLink.isPaused = false
            return
        }
        linkProxy.node = self
        // CADisplayLink 会**强引用** target；直接 target: self 就是 node ⇄ link 的循环引用，
        // 页面走了视图也释放不掉（而且 link 还会继续回调一个已经不该活的视图）。
        // 所以中间加一个只持弱引用的转发对象——这也是 UIKit 里最常见的破环手法。
        let link = CADisplayLink(target: linkProxy, selector: #selector(TiebaStatusLinkProxy.tick(_:)))
        // 用 .common 而不是 .default：滚动/手势期间 runloop 会切到 tracking mode，
        // .default 下动画会"卡住不动"（列表里最常见的"转圈停了"就是这个）。
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        // 离屏不烧 CPU；回到屏幕再按需要恢复。
        // 不做这件事的后果：一个已经滚出屏幕的进度环会一直在跑 display link，
        // 而它每一帧都在触发 setNeedsDisplay —— 滚动列表时这是实打实的掉帧来源。
        if window == nil {
            stopDisplayLink()
        } else {
            updateAnimations()
        }
    }

    // MARK: - 绘制（纯消费快照）

    public override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), bounds.width > 0, bounds.height > 0 else { return }
        if let background = backgroundColor, background.cgColor.alpha > 0 {
            context.setFillColor(background.cgColor)
            context.fillEllipse(in: bounds)
        }
        // 先旧后新：与上游一致（旧状态淡出、新状态叠在上面的位置）
        previousSnapshot?.draw(in: context, size: bounds.size, foregroundColor: foregroundColor)
        snapshot.draw(in: context, size: bounds.size, foregroundColor: foregroundColor)
    }
}

/// CADisplayLink 强引用 target，直接用 self 会与 node 成环；这里只持弱引用转发。
/// node 先没了的那个 tick 顺手把 link 摘掉，不留空转。
@MainActor
private final class TiebaStatusLinkProxy: NSObject {
    weak var node: TiebaStatusNode?

    @objc func tick(_ link: CADisplayLink) {
        guard let node = node else {
            link.invalidate()
            return
        }
        node.displayTick()
    }
}
