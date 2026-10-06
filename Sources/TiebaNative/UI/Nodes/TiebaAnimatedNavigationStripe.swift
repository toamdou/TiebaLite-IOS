// 移植自上游 submodules/AnimatedNavigationStripeNode/Sources/AnimatedNavigationStripeNode.swift
//
// 分段导航条纹：右侧一条 2pt 宽的竖向刻度条，亮格跟随当前分段，
// 上下端用渐变遮罩淡出，非当前分段处用「椭圆补偿」在遮罩上开窗。
//
// 改动（逐条编号，均相对上游）：
//   1. ASDisplayNode 外壳全部换成裸 CALayer（本组件里每个部件都只是一张图 +
//      一个 frame，没有视图语义）：addSubnode/removeFromSupernode → addSublayer/
//      removeFromSuperlayer，insertSubnode(_:belowSubnode:) → insertSublayer(_:below:)。
//   2. import Display 去掉：generateImage / generateFilledCircleImage →
//      TiebaNodesGraphics 同族；floorToScreenPixels → TiebaNodesGraphics.floorToScreenPixels
//      （scale 显式传，不读 UIScreen.main）；ContainedViewLayoutTransition →
//      TiebaNodesTransition（见 TiebaNodeSupport.swift）。
//   3. **图像改为「按目标高度直接生成」**：上游是「2pt 的实心圆 → resizableImage
//      (capInsets: top 1 / bottom 1, .stretch)」再用 ASImageNode 拉长；但 2pt 高的源图
//      上下各留 1pt 帽之后，可拉伸区高度正好是 0（capInsets 之和 ≥ 图像尺寸时 UIKit
//      不做拉伸），拉不长。这里把「圆头胶囊」按目标高度直接画出来 —— 与上游拉长后的
//      预期形状一致，且不依赖 UIKit 对退化帽的处理。clearBackground 那张带椭圆补偿的图
//      同理：上游绘制代码里底部椭圆本来就以 size.height 定位，直接按目标高度生成
//      与「拉伸中段」等价。图像按 (高度, 颜色) 缓存，重建时机与上游一致（换色或换高）。
//   4. 上游 maskContainerNode 同时是 self 的子节点、又是 self.layer 的 mask；
//      这里 mask 容器**不进视图树**（只做 mask），避免同一个 layer 既当子层又当遮罩。
//      容器保留 clipsToBounds = true（ASDisplayNode 的默认值就是裁剪），遮罩不会超出条纹范围。
//   5. 阴影渐变：上游把 locations 写成 [1.0, 0.0]（递减，CGGradient 要求递增），
//      这里按「上端淡出 / 下端淡出」的语义写成递增的 [0.0, 1.0]，顶阴影 clear→white、
//      底阴影 white→clear；底阴影上游走 rotatedContext 翻转画布，等价于这次调换两端颜色。
//   6. 分段数 <= 0 或高度 <= 0 直接返回：上游没防这一步，会除出 inf 尺寸。
//   7. 颜色/尺寸/索引全部由调用方经 Colors/Configuration 传入（上游本文件也不依赖
//      PresentationTheme，只是它拿了 Display 的图像工具）。
//
// 并发：整类 @MainActor（UIView 子类），全部动画都是 CAAnimation，不用 CADisplayLink。

import Foundation
import UIKit
import QuartzCore

/// 竖向分段导航条纹（上游 AnimatedNavigationStripeNode）。
public final class TiebaAnimatedNavigationStripe: UIView {
    /// 三种颜色：亮格 / 暗格 / 遮罩开窗处要露出的底色。
    public struct Colors: Equatable {
        public var foreground: UIColor
        public var background: UIColor
        public var clearBackground: UIColor

        public init(foreground: UIColor, background: UIColor, clearBackground: UIColor) {
            self.foreground = foreground
            self.background = background
            self.clearBackground = clearBackground
        }

        public static func == (lhs: Colors, rhs: Colors) -> Bool {
            return lhs.foreground.isEqual(rhs.foreground)
                && lhs.background.isEqual(rhs.background)
                && lhs.clearBackground.isEqual(rhs.clearBackground)
        }
    }

    /// 高度 / 当前分段 / 分段总数。
    public struct Configuration: Equatable {
        public var height: CGFloat
        public var index: Int
        public var count: Int

        public init(height: CGFloat, index: Int, count: Int) {
            self.height = height
            self.index = index
            self.count = count
        }
    }

    /// 一格「暗格」= 线层 + 开窗层（上游 BackgroundLineNode）。
    private final class BackgroundLine {
        let lineLayer = CALayer()
        let overlayLayer = CALayer()
    }

    private var currentColors: Colors?
    private var currentConfiguration: Configuration?

    private let foregroundLineLayer = CALayer()
    private var backgroundLines: [Int: BackgroundLine] = [:]
    private var removingBackgroundLines: [BackgroundLine] = []

    /// 只作遮罩用，不在视图树里（见文件头改动 4）。
    private let maskContainerView = UIView()
    private let topShadowLayer = CALayer()
    private let bottomShadowLayer = CALayer()
    private let middleShadowLayer = CALayer()

    /// 已生成的图像及其对应的段高（换色或换高时重建）。
    private var imageKey: (segmentHeight: CGFloat, overlayHeight: CGFloat)?
    private var foregroundImage: (image: CGImage, scale: CGFloat)?
    private var backgroundImage: (image: CGImage, scale: CGFloat)?
    private var clearBackgroundImage: (image: CGImage, scale: CGFloat)?

    private var segmentSpacing: CGFloat = 2.0

    public override init(frame: CGRect) {
        super.init(frame: frame)

        self.isUserInteractionEnabled = false
        self.backgroundColor = .clear
        // 上游 self.clipsToBounds = true。
        self.clipsToBounds = true

        self.layer.addSublayer(self.foregroundLineLayer)

        self.maskContainerView.backgroundColor = .clear
        self.maskContainerView.clipsToBounds = true
        self.maskContainerView.layer.addSublayer(self.topShadowLayer)
        self.maskContainerView.layer.addSublayer(self.bottomShadowLayer)
        self.middleShadowLayer.backgroundColor = UIColor.white.cgColor
        self.maskContainerView.layer.addSublayer(self.middleShadowLayer)
        self.layer.mask = self.maskContainerView.layer
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 更新颜色与分段配置（上游 update(colors:configuration:transition:)）。
    public func update(colors: Colors, configuration: Configuration, transition: TiebaNodesTransition) {
        // 见文件头改动 6：上游没防这两个退化输入，会在下面除出 inf。
        guard configuration.count > 0, configuration.height > 0.0 else {
            return
        }

        var transition = transition

        let colorsChanged = self.currentColors != colors
        let configurationChanged = self.currentConfiguration != configuration

        // 上游：首次布局（还没有 currentConfiguration）时强制不带动画。
        if self.currentConfiguration == nil {
            transition = .immediate
        }
        if !colorsChanged && !configurationChanged {
            return
        }

        // 环路跳变：从最后一段跳回第一段（或反之）时给一个「抖一下」的提示。
        var isCycledJump = false
        if let currentConfiguration = self.currentConfiguration,
           currentConfiguration.count == configuration.count,
           currentConfiguration.index == 0,
           currentConfiguration.count > 4,
           configuration.index == configuration.count - 1 {
            isCycledJump = true
        }

        self.currentColors = colors
        self.currentConfiguration = configuration

        let segmentSpacing = self.segmentSpacing
        let defaultVerticalInset: CGFloat = 7.0
        let minSegmentHeight: CGFloat = 8.0

        let availableVerticalHeight: CGFloat = configuration.height - defaultVerticalInset * 2.0
        let proposedSegmentHeight: CGFloat = (availableVerticalHeight - segmentSpacing * CGFloat(configuration.count) + segmentSpacing) / CGFloat(configuration.count)
        let segmentHeight = max(proposedSegmentHeight, minSegmentHeight)

        let overlayHeight = segmentHeight + (1.0 + segmentSpacing) * 2.0
        self.ensureImages(colors: colors, segmentHeight: segmentHeight, overlayHeight: overlayHeight)

        if configurationChanged {
            self.layoutSegments(configuration: configuration, segmentHeight: segmentHeight, defaultVerticalInset: defaultVerticalInset, transition: transition, isCycledJump: isCycledJump)
        }
    }

    // MARK: - 图像

    private func ensureImages(colors: Colors, segmentHeight: CGFloat, overlayHeight: CGFloat) {
        if let key = self.imageKey, key.segmentHeight == segmentHeight, key.overlayHeight == overlayHeight {
            return
        }
        self.imageKey = (segmentHeight, overlayHeight)

        let scale = TiebaNodesGraphics.displayScale(for: self)
        self.foregroundImage = Self.makeLineImage(color: colors.foreground, height: segmentHeight, scale: scale)
        self.backgroundImage = Self.makeLineImage(color: colors.background, height: segmentHeight, scale: scale)
        self.clearBackgroundImage = Self.makeOverlayImage(color: colors.clearBackground, height: overlayHeight, segmentSpacing: self.segmentSpacing, scale: scale)

        self.applyImages()
        self.ensureShadowImages(scale: scale)
    }

    private func applyImages() {
        Self.apply(self.foregroundImage, to: self.foregroundLineLayer)
        for (_, item) in self.backgroundLines {
            Self.apply(self.backgroundImage, to: item.lineLayer)
            Self.apply(self.clearBackgroundImage, to: item.overlayLayer)
        }
    }

    private static func apply(_ image: (image: CGImage, scale: CGFloat)?, to layer: CALayer) {
        guard let image = image else {
            return
        }
        layer.contents = image.image
        layer.contentsScale = image.scale
        layer.contentsGravity = .resize
    }

    private func ensureShadowImages(scale: CGFloat) {
        if self.topShadowLayer.contents != nil {
            return
        }
        Self.apply(Self.makeShadowImage(fadesOutAtTop: true, scale: scale), to: self.topShadowLayer)
        Self.apply(Self.makeShadowImage(fadesOutAtTop: false, scale: scale), to: self.bottomShadowLayer)
    }

    /// 圆头胶囊（见文件头改动 3）：上游是 2pt 实心圆纵向拉伸的预期结果。
    private static func makeLineImage(color: UIColor, height: CGFloat, scale: CGFloat) -> (image: CGImage, scale: CGFloat)? {
        let size = CGSize(width: 2.0, height: height)
        guard let image = TiebaNodesGraphics.image(size: size, scale: scale, body: { context, size in
            context.setFillColor(color.cgColor)
            let path = UIBezierPath(roundedRect: CGRect(origin: CGPoint(), size: size), cornerRadius: min(1.0, size.height / 2.0))
            context.addPath(path.cgPath)
            context.fillPath()
        }), let cgImage = image.cgImage else {
            return nil
        }
        return (cgImage, image.scale)
    }

    /// 上游的 clearBackground 图（含椭圆补偿，见文件头改动 3）：整体铺底色，
    /// 再用 copy 混合模式「挖」出一段上下带椭圆的透明窗口。
    /// 椭圆的 x 各外扩 ellipseFudge，去掉纵向拉伸时左右两列像素的半透明边。
    private static func makeOverlayImage(color: UIColor, height: CGFloat, segmentSpacing: CGFloat, scale: CGFloat) -> (image: CGImage, scale: CGFloat)? {
        let size = CGSize(width: 2.0, height: height)
        guard let image = TiebaNodesGraphics.image(size: size, scale: scale, body: { context, size in
            context.setFillColor(color.cgColor)
            context.fill(CGRect(origin: CGPoint(), size: size))

            context.setFillColor(UIColor.clear.cgColor)
            context.setBlendMode(.copy)

            let ellipseFudge: CGFloat = 0.02

            let topEllipse = CGRect(origin: CGPoint(x: -ellipseFudge, y: 1.0 + segmentSpacing), size: CGSize(width: 2.0 + ellipseFudge * 2.0, height: 2.0))
            let bottomEllipse = CGRect(origin: CGPoint(x: -ellipseFudge, y: size.height - (1.0 + segmentSpacing) - 2.0), size: CGSize(width: 2.0 + ellipseFudge * 2.0, height: 2.0))

            context.fillEllipse(in: topEllipse)
            context.fillEllipse(in: bottomEllipse)

            context.fill(CGRect(origin: CGPoint(x: 0.0, y: topEllipse.midY), size: CGSize(width: 2.0, height: bottomEllipse.midY - topEllipse.midY)))

            // 上下各再挖掉 1pt，留出与相邻格之间的间距。
            context.fillEllipse(in: CGRect(origin: CGPoint(x: 0.0, y: -1.0), size: CGSize(width: 2.0, height: 2.0)))
            context.fillEllipse(in: CGRect(origin: CGPoint(x: 0.0, y: size.height - 1.0), size: CGSize(width: 2.0, height: 2.0)))
        }), let cgImage = image.cgImage else {
            return nil
        }
        return (cgImage, image.scale)
    }

    /// 2×7 的白色渐变（遮罩用，只跟 alpha 有关，与 Colors 无关）。见文件头改动 5。
    private static func makeShadowImage(fadesOutAtTop: Bool, scale: CGFloat) -> (image: CGImage, scale: CGFloat)? {
        let size = CGSize(width: 2.0, height: 7.0)
        guard let image = TiebaNodesGraphics.image(size: size, scale: scale, body: { context, size in
            context.clear(CGRect(origin: CGPoint(), size: size))

            let locations: [CGFloat] = [0.0, 1.0]
            let colors: [CGColor] = fadesOutAtTop
                ? [UIColor.white.withAlphaComponent(0.0).cgColor, UIColor.white.cgColor]
                : [UIColor.white.cgColor, UIColor.white.withAlphaComponent(0.0).cgColor]

            let colorSpace = CGColorSpaceCreateDeviceRGB()
            guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: locations) else {
                return
            }

            context.drawLinearGradient(gradient, start: CGPoint(x: 0.0, y: 0.0), end: CGPoint(x: 0.0, y: size.height), options: CGGradientDrawingOptions())
        }), let cgImage = image.cgImage else {
            return nil
        }
        return (cgImage, image.scale)
    }

    // MARK: - 布局

    private func layoutSegments(configuration: Configuration, segmentHeight: CGFloat, defaultVerticalInset: CGFloat, transition: TiebaNodesTransition, isCycledJump: Bool) {
        let segmentSpacing = self.segmentSpacing

        transition.updateFrame(self.topShadowLayer, frame: CGRect(origin: CGPoint(), size: CGSize(width: 2.0, height: defaultVerticalInset)))
        transition.updateFrame(self.bottomShadowLayer, frame: CGRect(origin: CGPoint(x: 0.0, y: configuration.height - defaultVerticalInset), size: CGSize(width: 2.0, height: defaultVerticalInset)))
        transition.updateFrame(self.middleShadowLayer, frame: CGRect(origin: CGPoint(x: 0.0, y: defaultVerticalInset), size: CGSize(width: 2.0, height: configuration.height - defaultVerticalInset * 2.0)))
        transition.updateFrame(self.maskContainerView, frame: CGRect(origin: CGPoint(), size: CGSize(width: 2.0, height: configuration.height)))

        let availableVerticalHeight: CGFloat = configuration.height - defaultVerticalInset * 2.0

        let allItemsHeight = CGFloat(configuration.count) * segmentHeight + max(0.0, CGFloat(configuration.count - 1)) * segmentSpacing

        var verticalInset = defaultVerticalInset
        if allItemsHeight > availableVerticalHeight && allItemsHeight - 2.0 <= availableVerticalHeight {
            verticalInset -= 2.0
        }

        let topItemsHeight = CGFloat(configuration.index) * (segmentHeight + segmentSpacing)
        let bottomItemsHeight = allItemsHeight - topItemsHeight - segmentHeight

        // 像素对齐，否则 2pt 宽的细线会糊。
        var itemScreenOffset = TiebaNodesGraphics.floorToScreenPixels((configuration.height - segmentHeight) / 2.0, scale: TiebaNodesGraphics.displayScale(for: self))

        if itemScreenOffset - topItemsHeight > verticalInset {
            itemScreenOffset = topItemsHeight + verticalInset
        }
        if itemScreenOffset + segmentHeight + bottomItemsHeight < configuration.height - verticalInset {
            itemScreenOffset = configuration.height - verticalInset - (segmentHeight + bottomItemsHeight)
        }

        var backgroundLinesToOffset: [BackgroundLine] = []
        var resolvedOffset: CGFloat = 0.0

        // 局部函数捕获的是这两个 Sendable 标量，而不是整个 Configuration：
        // 更严的编译器把"任务隔离的结构体被主 actor 闭包捕获"判成 data race 错误
        //（region-based isolation：闭包里的主 actor 使用可能与之后的 nonisolated 使用竞争）。
        // 这两个值在本函数内是常量，取出来不改变任何行为。
        let containerHeight = configuration.height
        let currentIndex = configuration.index

        // 把某一格摆到它该在的位置；返回 false 表示这一格已经完全在可视区外（可以停止向两侧扩散）。
        func updateBackgroundLine(index: Int) -> Bool {
            let indexDifference = index - currentIndex
            let offsetDistance = CGFloat(indexDifference) * (segmentHeight + segmentSpacing)

            let itemFrame = CGRect(origin: CGPoint(x: 0.0, y: itemScreenOffset + offsetDistance), size: CGSize(width: 2.0, height: segmentHeight))

            if itemFrame.maxY <= 0.0 || itemFrame.minY > containerHeight {
                return false
            }

            var itemTransition = transition
            let item: BackgroundLine
            if let current = self.backgroundLines[index] {
                item = current
                // 新旧位置之差，取绝对值最大的那个作为「本轮整体位移」，用来给新出现的格做入场偏移。
                let offset = itemFrame.minY - item.lineLayer.frame.minY
                if abs(offset) > abs(resolvedOffset) {
                    resolvedOffset = offset
                }
            } else {
                itemTransition = .immediate
                item = BackgroundLine()
                Self.apply(self.backgroundImage, to: item.lineLayer)
                Self.apply(self.clearBackgroundImage, to: item.overlayLayer)
                self.backgroundLines[index] = item
                self.layer.insertSublayer(item.lineLayer, below: self.foregroundLineLayer)
                self.maskContainerView.layer.insertSublayer(item.overlayLayer, below: self.topShadowLayer)
                backgroundLinesToOffset.append(item)
            }
            // beginWithCurrentState：同一帧里连续布局时，动画起点取呈现层的当前位置。
            itemTransition.updateFrame(item.lineLayer, frame: itemFrame, beginWithCurrentState: true)
            itemTransition.updateFrame(item.overlayLayer, frame: itemFrame.insetBy(dx: 0.0, dy: -(1.0 + segmentSpacing)), beginWithCurrentState: true)

            return true
        }

        var validIndices = Set<Int>()
        if configuration.index >= 0 {
            for i in (0 ... configuration.index).reversed() {
                if updateBackgroundLine(index: i) {
                    validIndices.insert(i)
                } else {
                    break
                }
            }
        }
        if configuration.index < configuration.count {
            for i in configuration.index + 1 ..< configuration.count {
                if updateBackgroundLine(index: i) {
                    validIndices.insert(i)
                } else {
                    break
                }
            }
        }

        if !resolvedOffset.isZero {
            // 新出现的格：从「旧位置」滑到位（加性位移，不影响其它动画写进去的 position）。
            for item in backgroundLinesToOffset {
                transition.animatePositionAdditive(item.lineLayer, offset: CGPoint(x: 0.0, y: -resolvedOffset))
                transition.animatePositionAdditive(item.overlayLayer, offset: CGPoint(x: 0.0, y: -resolvedOffset))
            }
            // 正在退场的格：跟着一起滑走。
            for item in self.removingBackgroundLines {
                item.lineLayer.animatePosition(from: CGPoint(), to: CGPoint(x: 0.0, y: resolvedOffset), duration: transition.duration, timingFunction: transition.curve.timingFunctionName, removeOnCompletion: false, additive: true)
                item.overlayLayer.animatePosition(from: CGPoint(), to: CGPoint(x: 0.0, y: resolvedOffset), duration: transition.duration, timingFunction: transition.curve.timingFunctionName, removeOnCompletion: false, additive: true)
            }
        }

        var removeIndices: [Int] = []
        for (index, item) in self.backgroundLines {
            if !validIndices.contains(index) {
                removeIndices.append(index)

                if transition.isAnimated {
                    self.removingBackgroundLines.append(item)
                    item.overlayLayer.animatePosition(from: CGPoint(), to: CGPoint(x: 0.0, y: resolvedOffset), duration: transition.duration, timingFunction: transition.curve.timingFunctionName, removeOnCompletion: false, additive: true)
                    item.lineLayer.animatePosition(from: CGPoint(), to: CGPoint(x: 0.0, y: resolvedOffset), duration: transition.duration, timingFunction: transition.curve.timingFunctionName, removeOnCompletion: false, additive: true, completion: { [weak self, weak item] _ in
                        guard let self, let item else {
                            return
                        }
                        self.removingBackgroundLines.removeAll(where: { $0 === item })
                        item.lineLayer.removeFromSuperlayer()
                        item.overlayLayer.removeFromSuperlayer()
                    })
                } else {
                    item.lineLayer.removeFromSuperlayer()
                    item.overlayLayer.removeFromSuperlayer()
                }
            }
        }
        for index in removeIndices {
            self.backgroundLines.removeValue(forKey: index)
        }

        transition.updateFrame(self.foregroundLineLayer, frame: CGRect(origin: CGPoint(x: 0.0, y: itemScreenOffset), size: CGSize(width: 2.0, height: segmentHeight)), beginWithCurrentState: true)

        if transition.isAnimated && isCycledJump {
            // 环路跳变：先把整条条纹往下顶 8pt 再弹回来，提示「绕回去了」。
            let duration: Double = 0.18
            let maxOffset: CGFloat = -8.0
            self.layer.animate(from: 0.0, to: maxOffset, keyPath: "bounds.origin.y", timingFunction: CAMediaTimingFunctionName.linear.rawValue, duration: duration / 2.0, removeOnCompletion: false, additive: true, completion: { [weak self] _ in
                guard let self else {
                    return
                }
                self.layer.animate(from: maxOffset, to: 0.0, keyPath: "bounds.origin.y", timingFunction: CAMediaTimingFunctionName.linear.rawValue, duration: duration / 2.0, additive: true, key: "cycleShake")
            }, key: "cycleShake")
        }
    }
}
