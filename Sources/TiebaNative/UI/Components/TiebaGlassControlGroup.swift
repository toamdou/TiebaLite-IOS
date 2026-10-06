// TiebaGlassControlGroup —— 一整块交互玻璃胶囊 + N 个等宽图标按钮。
//
// 移植自上游两处（报告 37 C1 + A3/A4 的接线）：
//   · submodules/GlassControls/Sources/GlassControlGroup.swift:229-298
//     —— 外层**只有一块**玻璃（半径 = 高度的一半，isInteractive），内部每个按钮
//        minSize = (availableSize.height, availableSize.height) ⇒ **单个按钮的最小区永远是正方形**，
//        多按钮等宽排布 ⇒ 整组宽度 = 按钮数 × 高度；按钮自己关掉全部默认反馈
//        （animateAlpha / animateScale / animateContents = false），反馈交给外层玻璃的形变；
//   · submodules/ButtonComponent/Sources/ButtonComponent.swift:574-618
//     —— 玻璃按钮的三件套：烤好的阴影图（insertSubview at 0）、高亮宿主容器（clipsToBounds + 圆角）、
//        以及挂在**自己**身上的 GlassHighlightGestureRecognizer。
//
// 改前症状：一排图标各自一块玻璃小方块（各挂各的 UIVisualEffectView）—— 看起来是"一堆按钮"，
//          按下反馈是"整块变暗/缩小"（2013 年的手感）；
// 改后行为：整组是一块胶囊（一块玻璃），按钮是它的等宽分区；任何一处按下都让**整块胶囊**
//          做面积守恒形变 + 按下点径向高光，按钮自己不再变暗。
//
// 形变为什么落在 contentContainer 的 sublayerTransform 上（报告 A3 的关键）：
//   sublayerTransform 只作用于**本层的子层**。把形变挂在内容容器（只装按钮与高光）上，
//   玻璃的 backdrop 渲染层是它的**兄弟**（background 那条分支），因此模糊层一个像素都不会被缩放
//   —— 否则就是"糊上加糊"。这一点必须在层级上保证，不能靠"看起来没事"。
//
// 并发：UIView 子类天然 @MainActor。

import UIKit

final class TiebaGlassControlGroup: UIView {
    /// 一个图标按钮：图标名 + 无障碍标签 + 动作。
    struct Item {
        var symbol: String
        var pointSize: CGFloat = 22.0
        var weight: UIImage.SymbolWeight = .medium
        var accessibilityLabel: String
        var action: () -> Void
    }

    /// 组高（= 单按钮宽度，C1：minItemWidth = availableSize.height）。
    let groupHeight: CGFloat

    /// 唯一一块玻璃（C1）：胶囊半径 = 高度的一半。
    private let background: UIVisualEffectView
    /// 形变作用域：只装按钮与高光，保证 backdrop 不被缩放（见文件头）。
    private let contentContainer = UIView()
    /// 径向高亮宿主：clipsToBounds + 胶囊圆角，插在按钮**下面**（上游 ButtonComponent.swift:597-614）。
    private let highlightContainer = UIView()
    /// A5：阴影是烤好的九宫格图，不进 layer.shadow*（离屏合成）。
    private let shadowView = UIImageView()
    private var bakedShadow: TiebaBakedShadow?

    private var buttons: [Button] = [];
    private let highlightRecognizer: TiebaObservingGlassGestureRecognizer
    /// C3：指针交互实例要自己收着 —— UIPointerInteraction.delegate 是 **weak**，只 addInteraction 留不住委托。
    private var pointerInteractions: [TiebaPointerInteraction] = []

    private final class Button: UIButton {
        /// C1：按钮自身**关掉所有默认反馈**，反馈交给外层胶囊的形变。
        override var isHighlighted: Bool {
            get { return false }
            set {}
        }
    }

    init(items: [Item], height: CGFloat = 40.0, tintColor: UIColor? = nil, glassTintColor: UIColor? = nil) {
        self.groupHeight = height
        let effect = UIGlassEffect(style: .regular)
        effect.tintColor = glassTintColor
        // 系统玻璃自带的触摸形变只在触摸落在玻璃视图自身时生效；本组按钮在 contentView 里，
        // 走的是下面那条自算的路径（报告 A3⑥：形变模型只抄公式），两者不同时开，避免叠加。
        effect.isInteractive = false
        self.background = UIVisualEffectView(effect: effect)
        self.highlightRecognizer = TiebaObservingGlassGestureRecognizer(target: nil, action: nil)
        super.init(frame: .zero)

        self.backgroundColor = .clear

        self.shadowView.isUserInteractionEnabled = false
        self.addSubview(self.shadowView)

        self.background.isUserInteractionEnabled = false
        self.addSubview(self.background)

        self.highlightContainer.isUserInteractionEnabled = false
        self.highlightContainer.clipsToBounds = true
        self.contentContainer.addSubview(self.highlightContainer)
        self.addSubview(self.contentContainer)

        for item in items {
            let button = Button(type: .system)
            var config = UIButton.Configuration.plain()
            config.image = UIImage(
                systemName: item.symbol,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: item.pointSize, weight: item.weight)
            )
            config.baseForegroundColor = tintColor ?? .white
            config.contentInsets = .zero
            button.configuration = config
            button.accessibilityLabel = item.accessibilityLabel
            button.addAction(UIAction { _ in item.action() }, for: .touchUpInside)
            self.buttons.append(button)
            self.contentContainer.addSubview(button)
        }

        // A4：纯观察者手势 —— 与按钮、外层滚动同时工作，绝不抢触摸。
        self.highlightRecognizer.touchEffectView = self.contentContainer
        self.highlightRecognizer.highlightContainerView = self.highlightContainer
        self.addGestureRecognizer(self.highlightRecognizer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TiebaGlassControlGroup 只支持代码创建")
    }

    /// C1：整组宽度 = 按钮数 × 高度。
    override var intrinsicContentSize: CGSize {
        return CGSize(width: self.groupHeight * CGFloat(max(self.buttons.count, 1)), height: self.groupHeight)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let bounds = self.bounds
        let radius = bounds.height * 0.5

        // A5：阴影图只在圆角变化时重画（上游用参数比较挡住重复重建）。
        if self.bakedShadow == nil {
            self.bakedShadow = TiebaShadowImage.stretchable(cornerRadius: radius)
            self.shadowView.image = self.bakedShadow?.image
        }
        if let bakedShadow = self.bakedShadow {
            self.shadowView.frame = bounds.insetBy(dx: -bakedShadow.inset, dy: -bakedShadow.inset)
        }

        self.background.frame = bounds
        self.contentContainer.frame = bounds
        self.highlightContainer.frame = self.contentContainer.bounds
        self.highlightContainer.layer.cornerRadius = radius

        guard !self.buttons.isEmpty else { return }
        let itemWidth = bounds.width / CGFloat(self.buttons.count)
        for (index, button) in self.buttons.enumerated() {
            button.frame = CGRect(x: itemWidth * CGFloat(index), y: 0.0, width: itemWidth, height: bounds.height)
        }
    }

    /// C3：给每颗按钮装指针高亮（iPad + 触控板/鼠标）。默认圆形 —— 单按钮最小区就是正方形，
    /// 圆形高亮与"永远是个圆"的视觉一致。
    func installPointerInteractions(style: TiebaPointerStyle = .circle(nil)) {
        guard self.pointerInteractions.isEmpty else { return }
        for button in self.buttons {
            self.pointerInteractions.append(
                TiebaPointerInteraction(view: button, customInteractionView: button, style: style)
            )
        }
    }

    /// C5 的落地形态（报告 C5 明确"不要为它引私有 CAFilter"⇒ 用报告给的 scale + alpha 近似）：
    /// 整组出现时，几何（scale）与材质（alpha）**各走各的节奏** —— 这正是 B1 的"缓动烘进关键帧数组"
    /// 在本仓的第一个真实调用点：两组 CAKeyframeAnimation 共用同一个 duration、全部 .linear 播放，
    /// 各自的曲线在生成数组时就烘好了。
    func playEntrance() {
        guard !UIAccessibility.isReduceMotionEnabled else {
            for button in self.buttons { button.layer.removeAnimation(forKey: "tieba.glassControl.entrance") }
            return
        }
        let duration = TiebaAnimationDuration.overlayAppear
        let count = 12
        for (index, button) in self.buttons.enumerated() {
            let delay = 0.03 * Double(index)
            // 材质：透明度先到位（在时间轴的 60% 就收敛）。
            let opacity = TiebaBakedKeyframes.numbers(from: 0.0, to: 1.0, count: count, easing: .easeOutStrong)
            // 几何：缩放后收尾（曲线更慢，最后 20% 才落定）—— 两条属性不同步。
            let scale = TiebaBakedKeyframes.numbers(from: 0.92, to: 1.0, count: count, easing: .easeOut)
            let group = CAAnimationGroup()
            let opacityAnimation = CAKeyframeAnimation(keyPath: "opacity")
            opacityAnimation.values = opacity
            let scaleAnimation = CAKeyframeAnimation(keyPath: "transform.scale")
            scaleAnimation.values = scale
            group.animations = [opacityAnimation, scaleAnimation]
            group.duration = duration
            group.beginTime = CACurrentMediaTime() + delay
            group.fillMode = .backwards
            // 播放端一律 linear：缓动已经在数组里了（上游 LensTransitionContainer.swift:961-1015 同款）。
            group.timingFunction = CAMediaTimingFunction(name: .linear)
            TiebaAnimationFrameRate.align(group, to: button)
            button.layer.removeAnimation(forKey: "tieba.glassControl.entrance")
            button.layer.add(group, forKey: "tieba.glassControl.entrance")
        }
    }
}
