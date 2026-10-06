// 移植自上游：
//   * submodules/Display/Source/TooltipController.swift（257 行）
//   * submodules/Display/Source/TooltipControllerNode.swift（187 行）
//   * submodules/Display/Source/ContextMenuContainerNode.swift（111 行，气泡外形/箭头遮罩，
//     TooltipControllerNode 的内容物就是它，不一起搬过来气泡就没法画）
//
// 本仓此前没有任何「锚定到具体控件的提示气泡」，这是净新增能力。
//
// 改动（逐条编号，均相对上游）：
//   1. ViewController/ASDisplayNode → UIViewController/UIView。上游靠 Display 的
//      ViewController + presentationArguments + present() 拿到容器尺寸与安全区；
//      本仓没有那套展示基建，改成标准的 `.overFullScreen` 全屏透明控制器
//      （本仓既有弹层同款，见 App/TiebaUpdateDialogViewController.swift:45），
//      容器尺寸取 view.bounds.size、安全区取 view.safeAreaInsets。
//   2. 参数注入：上游把这些全塞在 TooltipController.init 的 12 个参数里，
//      这里收进 TiebaTooltipConfiguration（颜色/字号/内边距/超时/关闭策略），
//      并给一份 .standard 默认值。PresentationTheme 依赖本文件本来就没有。
//   3. SourceAndRect → TiebaTooltipAnchor：上游是 .node/.view 两种闭包 + 一个
//      sourceRectIsGlobal 布尔；本仓没有 ASDisplayNode，故只留 .view，
//      并把「已经是全局坐标」独立成 .globalRect，再补一个 .center（无锚点居中，
//      对应上游 sourceRect == nil 的分支）。三种情形各自显式，不再靠布尔开关。
//   4. TooltipControllerCustomContentNode（ASDisplayNode 协议）→
//      TiebaTooltipCustomContentView（UIView 协议），要求不变：animateIn + updateLayout(size:)。
//   5. ContainerViewLayout.insets(options: [.statusBar, .input]) → view.safeAreaInsets
//      （top 当 statusBar、bottom 当 input）。键盘弹出不在这里跟踪，走上游同款的
//      「尺寸一变就关闭」策略（dismissImmediatelyOnLayoutUpdate）。
//   6. 文本排版：上游用 TextNode（CoreText 自绘 + 断行）。这里用 UILabel 渲染、
//      NSAttributedString.boundingRect(with:options:) 量多行尺寸；上游的
//      balancedTextLayout（均衡断行）由 TextNode 提供，本仓没有对应实现，
//      **因此不提供该开关**——不做静默无效的参数。
//   7. textNode.layer.snapshotContentTree() → TiebaNodesGraphics.snapshotLayer(of:)；
//      layer.animateAlpha → 本仓 UI/Components/TiebaCAAnimationUtils.swift 的 CALayer.animateAlpha；
//      transition.updateFrame(node:frame:) → TiebaNodesTransition.updateFrame。
//   8. SwiftSignalKit.Timer → Timer + RunLoop.main(.common)。用 .common 模式是因为
//      上游那个 Timer 跑在主队列上，不受滚动/手势的 runloop mode 影响；用
//      scheduledTimer 默认的 .default 模式会在列表滚动时被推迟。
//      回调体走 Task { @MainActor }（Timer 的 block 是 @Sendable 的）。
//   9. hitTest：上游拿 sourceRect（全局坐标）直接和节点坐标系的 point 比较，
//      坐标系不一致（锚点不在屏幕原点时判错）。这里把 point 先转成窗口坐标再比。
//  10. 上游 viewWillAppear 与 viewDidAppear 各调一次 animateIn() + beginTimeout()
//      （beginTimeout 内部有 nil 判断所以不会重复起定时器，animateIn 会重复播）。
//      这里只在 viewDidAppear 调一次。
//  11. 去掉 TooltipController.updateContent 里的 isNodeLoaded 判断（没有「节点未加载」
//      这种中间态了）；updateContent 在视图未加载时只记内容，加载时自然用最新内容。
//
// 并发：全部类型 @MainActor（UIViewController/UIView 子类）。定时器回调经
//      Task { @MainActor } 回到主 actor，不用任何 assumeIsolated。

import Foundation
import UIKit
import QuartzCore

// MARK: - 内容与锚点

/// 自定义气泡内容（上游 TooltipControllerCustomContentNode）。
public protocol TiebaTooltipCustomContentView: UIView {
    func animateIn()
    func updateLayout(size: CGSize) -> CGSize
}

/// 气泡内容（上游 TooltipControllerContent）。
public enum TiebaTooltipContent: Equatable {
    case text(String)
    case attributedText(NSAttributedString)
    case iconAndText(UIImage, String)
    case custom(TiebaTooltipCustomContentView)

    public var text: String {
        switch self {
        case let .text(text), let .iconAndText(_, text):
            return text
        case let .attributedText(text):
            return text.string
        case .custom:
            return ""
        }
    }

    public var image: UIImage? {
        if case let .iconAndText(image, _) = self {
            return image
        }
        return nil
    }

    public static func == (lhs: TiebaTooltipContent, rhs: TiebaTooltipContent) -> Bool {
        switch lhs {
        case let .text(lhsText):
            if case let .text(rhsText) = rhs {
                return lhsText == rhsText
            }
            return false
        case let .attributedText(lhsText):
            if case let .attributedText(rhsText) = rhs {
                return lhsText.isEqual(to: rhsText)
            }
            return false
        case let .iconAndText(_, lhsText):
            if case let .iconAndText(_, rhsText) = rhs {
                return lhsText == rhsText
            }
            return false
        case let .custom(lhsView):
            if case let .custom(rhsView) = rhs {
                return lhsView === rhsView
            }
            return false
        }
    }
}

/// 气泡锚点（上游 SourceAndRect + sourceRectIsGlobal，见文件头改动 3）。
public enum TiebaTooltipAnchor {
    /// 锚到某个视图内的某个矩形（矩形用该视图的坐标系表达）。
    case view(() -> (UIView, CGRect)?)
    /// 直接给窗口坐标系的矩形（上游 sourceRectIsGlobal = true 的等价物）。
    case globalRect(() -> CGRect?)
    /// 没有锚点：气泡居中（上游 sourceRect == nil 的等价物）。
    case center

    /// 解析成窗口坐标系的矩形；nil 表示居中。
    @MainActor
    func globalRect() -> CGRect? {
        switch self {
        case let .view(provider):
            guard let (sourceView, sourceRect) = provider() else {
                return nil
            }
            return sourceView.convert(sourceRect, to: nil)
        case let .globalRect(provider):
            return provider()
        case .center:
            return nil
        }
    }
}

/// 气泡外观与行为参数（见文件头改动 2）。
public struct TiebaTooltipConfiguration {
    public enum Alignment {
        case center
        case natural
    }

    /// 宿主界面的基准字号；气泡文字 = floor(基准 * 14/17)，与上游同式。
    public var baseFontSize: CGFloat
    public var alignment: Alignment
    public var isBlurred: Bool
    /// 不点也自动消失的秒数。
    public var timeout: Double
    /// 点气泡外任何地方都关。
    public var dismissByTapOutside: Bool
    /// 点锚点之外的地方关（锚点本身不关）。
    public var dismissByTapOutsideSource: Bool
    /// 容器尺寸一变立刻关（键盘弹出等场景）。
    public var dismissImmediatelyOnLayoutUpdate: Bool
    public var arrowOnBottom: Bool
    /// 气泡距屏幕左右边缘的最小留白。
    public var padding: CGFloat
    /// 内容四周的额外内边距。
    public var innerPadding: UIEdgeInsets
    public var textColor: UIColor
    /// 不模糊时的纯色底。
    public var backgroundColor: UIColor
    /// 玻璃底的**深浅档位**（isBlurred 为真时生效）。
    /// 语义未变（.dark* ⇒ 深色底、其余 ⇒ 浅色底），只是材质从 UIBlurEffect 换成 UIGlassEffect
    /// 后用它换算 tintColor —— 全仓最后一块 UIBlurEffect 残留（见 TiebaTooltipBubbleView.init）。
    public var blurEffectStyle: UIBlurEffect.Style
    /// 聚光灯：压暗整屏、在锚点上挖一个洞（反相挖洞遮罩，见 UI/Components/TiebaMaskedContainerView）。
    /// 首次引导这类"指着某个按钮说事"的场景用它，普通提示保持 false。
    public var spotlightsSource: Bool

    public init(baseFontSize: CGFloat, alignment: Alignment = .center, isBlurred: Bool = false, timeout: Double = 2.0, dismissByTapOutside: Bool = false, dismissByTapOutsideSource: Bool = false, dismissImmediatelyOnLayoutUpdate: Bool = false, arrowOnBottom: Bool = true, padding: CGFloat = 8.0, innerPadding: UIEdgeInsets = UIEdgeInsets(), textColor: UIColor = .white, backgroundColor: UIColor = UIColor(white: 0.0, alpha: 0.8), blurEffectStyle: UIBlurEffect.Style = .dark, spotlightsSource: Bool = false) {
        self.baseFontSize = baseFontSize
        self.alignment = alignment
        self.isBlurred = isBlurred
        self.timeout = timeout
        self.dismissByTapOutside = dismissByTapOutside
        self.dismissByTapOutsideSource = dismissByTapOutsideSource
        self.dismissImmediatelyOnLayoutUpdate = dismissImmediatelyOnLayoutUpdate
        self.arrowOnBottom = arrowOnBottom
        self.padding = padding
        self.innerPadding = innerPadding
        self.textColor = textColor
        self.backgroundColor = backgroundColor
        self.blurEffectStyle = blurEffectStyle
        self.spotlightsSource = spotlightsSource
    }

    /// 上游 TooltipController.init 的默认值 + 它写死的深色底（0.8 黑 / 深色模糊）。
    public static var standard: TiebaTooltipConfiguration {
        return TiebaTooltipConfiguration(baseFontSize: 17.0)
    }

    /// 气泡文字字号：上游 Font.regular(floor(baseFontSize * 14.0 / 17.0))。
    public var textFontSize: CGFloat {
        return floor(self.baseFontSize * 14.0 / 17.0)
    }
}

// MARK: - 气泡外形

/// 遮罩视图：layerClass 直接是 CAShapeLayer，省掉一层手建图层。
private final class TiebaTooltipMaskView: UIView {
    override class var layerClass: AnyClass {
        return CAShapeLayer.self
    }
}

/// 气泡外形（上游 ContextMenuContainerNode）：圆角矩形 + 一个指向锚点的三角箭头 + 阴影。
public final class TiebaTooltipBubbleView: UIView {
    private struct CachedMaskParams: Equatable {
        let size: CGSize
        let relativeArrowPosition: CGFloat
        let arrowOnBottom: Bool
    }

    /// 气泡本体。背景（纯色或模糊）挂在这里，尺寸同气泡；外面的 self 只负责阴影。
    public let containerView = UIView()

    // 名字不叫 maskView：UIView 自己就有 maskView 属性，重名会被当成「覆写」。
    private let shapeMaskView = TiebaTooltipMaskView()
    private var cachedMaskParams: CachedMaskParams?
    private var effectView: UIVisualEffectView?

    /// (箭头相对气泡左边缘的 x, 箭头是不是在下方)。nil = 箭头居中、朝下。
    public var relativeArrowPosition: (CGFloat, Bool)?

    public init(isBlurred: Bool, backgroundColor: UIColor, blurEffectStyle: UIBlurEffect.Style) {
        super.init(frame: .zero)

        self.isUserInteractionEnabled = false
        self.addSubview(self.containerView)

        if isBlurred {
            // 材质残留修复（报告 37 顺手项）：这里是全仓**唯一**还在用 UIBlurEffect 的地方，
            // 而 iOS 26 的系统语义材质就是 UIGlassEffect（其余 6+ 处玻璃件早已统一）。
            // 深浅语义不变：.dark* 档 ⇒ 深色 tint，其余 ⇒ 浅色 tint；公开 API 形状不动
            //（调用方仍传 blurEffectStyle）。
            let effectView = TiebaGlassContainerView.makeEffect(tint: TiebaTooltipBubbleView.glassTintColor(for: blurEffectStyle))
            self.containerView.addSubview(effectView)
            self.effectView = effectView
        } else {
            self.containerView.backgroundColor = backgroundColor
        }

        self.layer.shadowColor = UIColor.black.cgColor
        self.layer.shadowRadius = 10.0
        self.layer.shadowOpacity = 0.2
        self.layer.shadowOffset = CGSize(width: 0.0, height: 5.0)
        self.layer.allowsGroupOpacity = true

        self.containerView.mask = self.shapeMaskView
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// blurStyle → 玻璃 tint（深色档 = 黑 tint，浅色/自适应档 = 白 tint）。
    private static func glassTintColor(for style: UIBlurEffect.Style) -> UIColor {
        switch style {
        case .dark,
             .systemUltraThinMaterialDark,
             .systemThinMaterialDark,
             .systemMaterialDark,
             .systemThickMaterialDark,
             .systemChromeMaterialDark:
            return UIColor(white: 0.0, alpha: 0.4)
        default:
            return UIColor(white: 1.0, alpha: 0.3)
        }
    }

    /// 上游 ContextMenuContainerNode.updateLayout(transition:)：几何全部写死在这里
    /// （圆角 10 / 纵向内缩 9 / 箭头宽 18），只是形状随 bounds 变。
    public func updateLayout(transition: TiebaNodesTransition) {
        transition.updateFrame(self.containerView, frame: self.bounds)
        self.effectView?.frame = self.bounds

        let maskParams = CachedMaskParams(
            size: self.bounds.size,
            relativeArrowPosition: self.relativeArrowPosition?.0 ?? self.bounds.size.width / 2.0,
            arrowOnBottom: self.relativeArrowPosition?.1 ?? true
        )
        if self.cachedMaskParams == maskParams {
            return
        }
        self.cachedMaskParams = maskParams

        let path = UIBezierPath()
        let cornerRadius: CGFloat = 10.0
        let verticalInset: CGFloat = 9.0
        let arrowWidth: CGFloat = 18.0
        // 箭头不能戳出圆角：在两端各留出一个圆角 + 半个箭头。
        let arrowPosition = max(cornerRadius + arrowWidth / 2.0, min(maskParams.size.width - cornerRadius - arrowWidth / 2.0, maskParams.relativeArrowPosition))
        let arrowOnBottom = maskParams.arrowOnBottom
        // 箭尖 R4 / 箭根 R3：与控制点按 sqrt(2)/2 对齐（移植自上游 TooltipComponent.swift:56-58、:70-90）。
        let arrowTipRadius: CGFloat = 4.0
        let arrowBaseRadius: CGFloat = 3.0
        let sqrt2inv: CGFloat = 1.0 / sqrt(2.0)

        path.move(to: CGPoint(x: 0.0, y: verticalInset + cornerRadius))
        path.addArc(withCenter: CGPoint(x: cornerRadius, y: verticalInset + cornerRadius), radius: cornerRadius, startAngle: CGFloat.pi, endAngle: CGFloat(3.0 * CGFloat.pi / 2.0), clockwise: true)
        if !arrowOnBottom {
            path.addLine(to: CGPoint(x: arrowPosition - arrowWidth / 2.0 - arrowBaseRadius, y: verticalInset))
            path.addQuadCurve(to: CGPoint(x: arrowPosition - arrowWidth / 2.0 + arrowBaseRadius * sqrt2inv, y: verticalInset - arrowBaseRadius * sqrt2inv), controlPoint: CGPoint(x: arrowPosition - arrowWidth / 2.0, y: verticalInset))
            path.addLine(to: CGPoint(x: arrowPosition - arrowTipRadius * sqrt2inv, y: arrowTipRadius * sqrt2inv))
            path.addQuadCurve(to: CGPoint(x: arrowPosition + arrowTipRadius * sqrt2inv, y: arrowTipRadius * sqrt2inv), controlPoint: CGPoint(x: arrowPosition, y: 0.0))
            path.addLine(to: CGPoint(x: arrowPosition + arrowWidth / 2.0 - arrowBaseRadius * sqrt2inv, y: verticalInset - arrowBaseRadius * sqrt2inv))
            path.addQuadCurve(to: CGPoint(x: arrowPosition + arrowWidth / 2.0 + arrowBaseRadius, y: verticalInset), controlPoint: CGPoint(x: arrowPosition + arrowWidth / 2.0, y: verticalInset))
        }
        path.addLine(to: CGPoint(x: maskParams.size.width - cornerRadius, y: verticalInset))
        path.addArc(withCenter: CGPoint(x: maskParams.size.width - cornerRadius, y: verticalInset + cornerRadius), radius: cornerRadius, startAngle: CGFloat(3.0 * CGFloat.pi / 2.0), endAngle: 0.0, clockwise: true)
        path.addLine(to: CGPoint(x: maskParams.size.width, y: maskParams.size.height - cornerRadius - verticalInset))
        path.addArc(withCenter: CGPoint(x: maskParams.size.width - cornerRadius, y: maskParams.size.height - cornerRadius - verticalInset), radius: cornerRadius, startAngle: 0.0, endAngle: CGFloat(CGFloat.pi / 2.0), clockwise: true)
        if arrowOnBottom {
            let arrowBaseY = maskParams.size.height - verticalInset
            let arrowTipY = maskParams.size.height
            path.addLine(to: CGPoint(x: arrowPosition + arrowWidth / 2.0 + arrowBaseRadius, y: arrowBaseY))
            path.addQuadCurve(to: CGPoint(x: arrowPosition + arrowWidth / 2.0 - arrowBaseRadius * sqrt2inv, y: arrowBaseY + arrowBaseRadius * sqrt2inv), controlPoint: CGPoint(x: arrowPosition + arrowWidth / 2.0, y: arrowBaseY))
            path.addLine(to: CGPoint(x: arrowPosition + arrowTipRadius * sqrt2inv, y: arrowTipY - arrowTipRadius * sqrt2inv))
            path.addQuadCurve(to: CGPoint(x: arrowPosition - arrowTipRadius * sqrt2inv, y: arrowTipY - arrowTipRadius * sqrt2inv), controlPoint: CGPoint(x: arrowPosition, y: arrowTipY))
            path.addLine(to: CGPoint(x: arrowPosition - arrowWidth / 2.0 + arrowBaseRadius * sqrt2inv, y: arrowBaseY + arrowBaseRadius * sqrt2inv))
            path.addQuadCurve(to: CGPoint(x: arrowPosition - arrowWidth / 2.0 - arrowBaseRadius, y: arrowBaseY), controlPoint: CGPoint(x: arrowPosition - arrowWidth / 2.0, y: arrowBaseY))
        }
        path.addLine(to: CGPoint(x: cornerRadius, y: maskParams.size.height - verticalInset))
        path.addArc(withCenter: CGPoint(x: cornerRadius, y: maskParams.size.height - cornerRadius - verticalInset), radius: cornerRadius, startAngle: CGFloat(CGFloat.pi / 2.0), endAngle: CGFloat.pi, clockwise: true)
        path.close()

        if let layer = self.shapeMaskView.layer as? CAShapeLayer {
            if transition.isAnimated, let previousPath = layer.path {
                // 形状变化时用一次路径补间（上游同款：animate(from:to:keyPath:"path")）。
                layer.animate(from: previousPath, to: path.cgPath, keyPath: "path", timingFunction: transition.curve.timingFunctionName, duration: transition.duration)
            }
            layer.path = path.cgPath
        }

        if transition.isAnimated, let previousPath = self.layer.shadowPath {
            self.layer.shadowPath = path.cgPath
            self.layer.animate(from: previousPath, to: path.cgPath, keyPath: "shadowPath", timingFunction: transition.curve.timingFunctionName, duration: transition.duration)
        } else {
            self.layer.shadowPath = path.cgPath
        }
    }
}

// MARK: - 气泡内容

/// 气泡内容视图（上游 TooltipControllerNode）。
public final class TiebaTooltipContentView: UIView {
    private let configuration: TiebaTooltipConfiguration
    private let alignment: TiebaTooltipConfiguration.Alignment
    private let dismiss: (Bool) -> Void
    private let dismissByTapOutside: Bool
    private let dismissByTapOutsideSource: Bool

    private let bubbleView: TiebaTooltipBubbleView
    /// 聚光灯（configuration.spotlightsSource 为真时才有）。
    private var spotlightView: TiebaMaskedContainerView?
    private let imageView = UIImageView()
    private let textLabel = UILabel()
    private var customContentView: TiebaTooltipCustomContentView?

    /// 锚点矩形（窗口坐标系）；nil = 居中。
    public var sourceRect: CGRect?
    public var arrowOnBottom: Bool = true
    public var padding: CGFloat = 8.0
    public var innerPadding: UIEdgeInsets = UIEdgeInsets()

    private var dismissedByTouchOutside = false

    init(configuration: TiebaTooltipConfiguration, content: TiebaTooltipContent, dismiss: @escaping (Bool) -> Void) {
        self.configuration = configuration
        self.alignment = configuration.alignment
        self.dismiss = dismiss
        self.dismissByTapOutside = configuration.dismissByTapOutside
        self.dismissByTapOutsideSource = configuration.dismissByTapOutsideSource

        self.bubbleView = TiebaTooltipBubbleView(
            isBlurred: configuration.isBlurred,
            backgroundColor: configuration.backgroundColor,
            blurEffectStyle: configuration.blurEffectStyle
        )

        super.init(frame: .zero)

        self.backgroundColor = .clear

        self.padding = configuration.padding
        self.innerPadding = configuration.innerPadding
        self.arrowOnBottom = configuration.arrowOnBottom

        self.imageView.contentMode = .scaleToFill
        self.imageView.image = content.image

        self.textLabel.numberOfLines = 0
        self.textLabel.isUserInteractionEnabled = false
        self.textLabel.backgroundColor = .clear
        if case let .attributedText(text) = content {
            self.textLabel.attributedText = text
        } else {
            self.textLabel.attributedText = Self.attributedText(
                string: content.text,
                fontSize: configuration.textFontSize,
                textColor: configuration.textColor,
                alignment: configuration.alignment
            )
        }

        if case let .custom(customContent) = content {
            self.customContentView = customContent
        }

        // 上游把 image/text/自定义内容都挂在 ContextMenuContainerNode 的 containerNode 上
        // （箭头那圈留白靠 containerView 的边界，内容不会被遮罩裁掉）。
        self.bubbleView.containerView.addSubview(self.imageView)
        self.bubbleView.containerView.addSubview(self.textLabel)
        if let customContentView = self.customContentView {
            self.bubbleView.containerView.addSubview(customContentView)
        }
        // 聚光灯：整屏压暗 + 锚点处挖洞。先加 ⇒ 压在气泡之下；不吃触摸
        //（外部点击的语义仍由下面的 hitTest 决定，见 :525-553）。
        if configuration.spotlightsSource {
            let spotlight = TiebaMaskedContainerView()
            spotlight.isUserInteractionEnabled = false
            spotlight.contentView.backgroundColor = UIColor(white: 0.0, alpha: 0.45)
            self.addSubview(spotlight)
            self.spotlightView = spotlight
        }
        self.addSubview(self.bubbleView)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static func attributedText(string: String, fontSize: CGFloat, textColor: UIColor, alignment: TiebaTooltipConfiguration.Alignment) -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = alignment == .center ? .center : .natural
        return NSAttributedString(string: string, attributes: [
            .font: UIFont.systemFont(ofSize: fontSize),
            .foregroundColor: textColor,
            .paragraphStyle: paragraphStyle
        ])
    }

    /// 换文案并重排（上游 TooltipControllerNode.updateText(_:transition:)）。
    /// 动起来时旧文字先拷一层淡出、新文字淡入，避免换字时的生硬跳变。
    public func updateText(_ text: String, transition: TiebaNodesTransition) {
        if transition.isAnimated, let snapshot = TiebaNodesGraphics.snapshotLayer(of: self.textLabel, scale: self.traitCollection.displayScale) {
            self.layer.addSublayer(snapshot)
            transition.updateAlpha(snapshot, alpha: 0.0, completion: { [weak snapshot] _ in
                snapshot?.removeFromSuperlayer()
            })
            // [按上游归位] 0.12 → TiebaAnimationDuration.microFeedback（上游 0.12 档，值逐字不变）：
            // 上游这一档就是"换数/换字"的微动效。
            self.textLabel.layer.animateAlpha(from: 0.0, to: 1.0, duration: TiebaAnimationDuration.microFeedback)
        }
        self.textLabel.attributedText = Self.attributedText(
            string: text,
            fontSize: self.configuration.textFontSize,
            textColor: self.configuration.textColor,
            alignment: self.alignment
        )
        self.setNeedsLayout()
    }

    /// 布局（上游 TooltipControllerNode.containerLayoutUpdated(_:transition:)）。
    /// size 是容器尺寸，insets 是容器安全区。
    public func updateLayout(size: CGSize, insets: UIEdgeInsets, transition: TiebaNodesTransition) {
        let maxWidth = size.width - 20.0 - self.padding * 2.0

        let contentSize: CGSize

        if let customContentView = self.customContentView {
            contentSize = customContentView.updateLayout(size: size)
            customContentView.frame = CGRect(origin: CGPoint(), size: contentSize)
        } else {
            var imageSize = CGSize()
            var imageSizeWithInset = CGSize()
            if let image = self.imageView.image {
                imageSize = image.size
                imageSizeWithInset = CGSize(width: image.size.width + 12.0, height: image.size.height)
            }

            var textSize = Self.measure(self.textLabel.attributedText, maximumWidth: maxWidth)
            // 取偶数：气泡宽度抖动时文字不会因为半像素而反复重排（上游同款）。
            textSize.width = ceil(textSize.width / 2.0) * 2.0
            textSize.height = ceil(textSize.height / 2.0) * 2.0

            contentSize = CGSize(
                width: imageSizeWithInset.width + textSize.width + 12.0 + self.innerPadding.left + self.innerPadding.right,
                height: textSize.height + 34.0 + self.innerPadding.top + self.innerPadding.bottom
            )

            let textFrame = CGRect(origin: CGPoint(x: 6.0 + self.innerPadding.left + imageSizeWithInset.width, y: 17.0 + self.innerPadding.top), size: textSize)
            if transition.isAnimated, textFrame.size != self.textLabel.frame.size {
                // 文字变宽变窄时从原位滑过去，而不是直接跳。
                transition.animatePositionAdditive(self.textLabel, offset: CGPoint(x: textFrame.minX - self.textLabel.frame.minX, y: 0.0))
            }

            let imageFrame = CGRect(origin: CGPoint(x: self.innerPadding.left + 10.0, y: floor((contentSize.height - imageSize.height) / 2.0)), size: imageSize)
            self.imageView.frame = imageFrame
            self.textLabel.frame = textFrame
        }

        let sourceRect: CGRect = self.sourceRect ?? CGRect(origin: CGPoint(x: size.width / 2.0, y: size.height / 2.0), size: CGSize())

        let verticalOrigin: CGFloat
        var arrowOnBottom = true
        if sourceRect.minY - 54.0 > insets.top {
            // 锚点上方放得下：气泡浮在锚点上面，箭头朝下。
            verticalOrigin = sourceRect.minY - contentSize.height
        } else {
            verticalOrigin = min(size.height - insets.bottom - contentSize.height, sourceRect.maxY)
            arrowOnBottom = false
        }
        self.arrowOnBottom = arrowOnBottom

        let horizontalOrigin: CGFloat = floor(min(max(self.padding, sourceRect.midX - contentSize.width / 2.0), size.width - contentSize.width - self.padding))

        transition.updateFrame(self.bubbleView, frame: CGRect(origin: CGPoint(x: horizontalOrigin, y: verticalOrigin), size: contentSize))
        self.bubbleView.relativeArrowPosition = (sourceRect.midX - horizontalOrigin, arrowOnBottom)
        self.bubbleView.updateLayout(transition: transition)

        // 聚光灯：洞 = 锚点矩形外扩 8pt（按钮本体之外留一圈亮边）。
        if let spotlightView, let anchorRect = self.sourceRect {
            transition.updateFrame(spotlightView, frame: self.bounds)
            spotlightView.update(
                size: self.bounds.size,
                items: [
                    TiebaMaskedContainerView.Item(
                        frame: self.convert(anchorRect, from: nil).insetBy(dx: -8.0, dy: -8.0),
                        shape: .roundedRect(cornerRadius: 14.0)
                    ),
                ],
                isInverted: true
            )
        }
    }

    /// 多行尺寸：UILabel 走 TextKit，这里用同一套 attributed string 直接问
    /// boundingRect（见文件头改动 6）。
    private static func measure(_ attributedText: NSAttributedString?, maximumWidth: CGFloat) -> CGSize {
        guard let attributedText = attributedText, attributedText.length > 0 else {
            return CGSize()
        }
        let boundingRect = attributedText.boundingRect(
            with: CGSize(width: max(1.0, maximumWidth), height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        return CGSize(width: ceil(boundingRect.width), height: ceil(boundingRect.height))
    }

    public func animateIn() {
        self.bubbleView.alpha = 1.0
        self.bubbleView.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.25)
        if let spotlightView {
            spotlightView.alpha = 1.0
            spotlightView.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.25)
        }
        self.customContentView?.animateIn()
    }

    public func animateOut(completion: @escaping () -> Void) {
        if let spotlightView {
            spotlightView.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.3, removeOnCompletion: false)
        }
        self.bubbleView.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.3, removeOnCompletion: false, completion: { _ in
            completion()
        })
    }

    public func hide() {
        self.bubbleView.alpha = 0.0
        self.spotlightView?.alpha = 0.0
    }

    /// 上游 TooltipControllerNode.hitTest 的三条语义（点气泡内 / 点气泡外 / 点锚点外）
    /// 一字未改，只是坐标系对齐了一下（见文件头改动 9）。返回 nil = 不吃这个事件，
    /// 让它落到下层界面上（所以点气泡外既能关掉提示、又能点到下面的按钮）。
    public override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let pointInside = self.bubbleView.frame.contains(point)

        if let event {
            let eventIsPresses = event.type == .presses
            if event.type == .touches || eventIsPresses {
                if self.bubbleView.frame.contains(point) || self.dismissByTapOutside {
                    if !self.dismissedByTouchOutside {
                        self.dismissedByTouchOutside = true
                        self.dismiss(pointInside)
                    }
                } else if self.dismissByTapOutsideSource, let sourceRect = self.sourceRect {
                    let globalPoint = self.convert(point, to: nil)
                    if !sourceRect.contains(globalPoint) {
                        if !self.dismissedByTouchOutside {
                            self.dismissedByTouchOutside = true
                            self.dismiss(false)
                        }
                    }
                }
                return nil
            }
        }
        if pointInside {
            return super.hitTest(point, with: event)
        } else {
            return nil
        }
    }
}

// MARK: - 控制器

/// 锚定气泡控制器（上游 TooltipController）。
///
/// 用法：
///     let tooltip = TiebaTooltipController(content: .text("..."), anchor: .view { [weak button] in
///         button.map { ($0, $0.bounds) }
///     })
///     tooltip.present(on: self)   // 内部就是 .overFullScreen + animated: false
public final class TiebaTooltipController: UIViewController {
    public typealias Alignment = TiebaTooltipConfiguration.Alignment

    private let configuration: TiebaTooltipConfiguration
    private let anchor: TiebaTooltipAnchor

    public private(set) var content: TiebaTooltipContent

    /// 关闭回调，参数是「是不是点在气泡里」。
    public var dismissed: ((Bool) -> Void)?

    private var timeoutTimer: Timer?
    private var hasLaidOutOnce = false
    private var lastLayoutSize: CGSize?

    public init(content: TiebaTooltipContent, configuration: TiebaTooltipConfiguration = .standard, anchor: TiebaTooltipAnchor = .center) {
        self.content = content
        self.configuration = configuration
        self.anchor = anchor
        super.init(nibName: nil, bundle: nil)

        self.modalPresentationStyle = .overFullScreen
        self.modalTransitionStyle = .crossDissolve
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    isolated deinit {
        self.timeoutTimer?.invalidate()
    }

    private var tooltipView: TiebaTooltipContentView {
        // loadView 保证根视图就是这个类型。
        return self.view as! TiebaTooltipContentView
    }

    public override func loadView() {
        self.view = TiebaTooltipContentView(configuration: self.configuration, content: self.content, dismiss: { [weak self] tappedInside in
            self?.handleDismiss(tappedInside: tappedInside)
        })
    }

    /// 换内容（上游 updateContent(_:animated:extendTimer:arrowOnBottom:)）。
    /// 内容没变就什么都不做；extendTimer 为真时重新开始倒计时。
    public func updateContent(_ content: TiebaTooltipContent, animated: Bool, extendTimer: Bool, arrowOnBottom: Bool = true) {
        if self.content == content {
            return
        }
        self.content = content
        if self.isViewLoaded {
            self.tooltipView.updateText(content.text, transition: animated ? .animated(duration: 0.25) : .immediate)
            self.tooltipView.arrowOnBottom = arrowOnBottom
            if extendTimer, self.timeoutTimer != nil {
                self.timeoutTimer?.invalidate()
                self.timeoutTimer = nil
                self.beginTimeout()
            }
        }
    }

    /// 便利入口：按本仓惯例以 .overFullScreen 呈现（animated 交给气泡自己的淡入）。
    public func present(on presenter: UIViewController) {
        presenter.present(self, animated: false)
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        self.tooltipView.animateIn()
        self.beginTimeout()
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        let size = self.view.bounds.size
        if let lastLayoutSize = self.lastLayoutSize, lastLayoutSize != size {
            // 上游同款：容器尺寸变了就关（键盘弹出、旋转、分屏）。
            if self.configuration.dismissImmediatelyOnLayoutUpdate {
                self.dismissImmediately()
            } else {
                self.dismissTooltip(animated: true)
            }
            return
        }
        self.lastLayoutSize = size

        let transition: TiebaNodesTransition = self.hasLaidOutOnce ? .animated(duration: 0.2) : .immediate
        self.hasLaidOutOnce = true

        self.tooltipView.sourceRect = self.anchor.globalRect()
        self.tooltipView.updateLayout(size: size, insets: self.view.safeAreaInsets, transition: transition)
    }

    // MARK: - 关闭

    private func beginTimeout() {
        if self.timeoutTimer != nil {
            return
        }
        // 见文件头改动 8：手工建 Timer 并挂到 .common 模式。
        let timer = Timer(timeInterval: self.configuration.timeout, repeats: false, block: { [weak self] _ in
            Task { @MainActor in
                self?.handleTimeout()
            }
        })
        RunLoop.main.add(timer, forMode: .common)
        self.timeoutTimer = timer
    }

    private func handleTimeout() {
        self.timeoutTimer = nil
        self.dismissed?(false)
        self.tooltipView.animateOut { [weak self] in
            self?.dismiss(animated: false)
        }
    }

    private func handleDismiss(tappedInside: Bool) {
        self.dismissTooltipInternal(tappedInside: tappedInside, completion: nil)
    }

    private func dismissTooltipInternal(tappedInside: Bool, completion: (() -> Void)?) {
        self.timeoutTimer?.invalidate()
        self.timeoutTimer = nil
        self.dismissed?(tappedInside)
        self.tooltipView.animateOut { [weak self] in
            self?.dismiss(animated: false)
            completion?()
        }
    }

    /// 上游 open func dismiss(completion:)（名字让给 UIViewController.dismiss(animated:completion:)）。
    public func dismissTooltip(animated: Bool = true, completion: (() -> Void)? = nil) {
        if animated {
            self.dismissTooltipInternal(tappedInside: false, completion: completion)
        } else {
            self.timeoutTimer?.invalidate()
            self.timeoutTimer = nil
            self.dismissed?(false)
            self.tooltipView.hide()
            self.dismiss(animated: false, completion: completion)
        }
    }

    /// 上游 open func dismissImmediately()。
    public func dismissImmediately() {
        self.timeoutTimer?.invalidate()
        self.timeoutTimer = nil
        self.dismissed?(false)
        self.tooltipView.hide()
        self.dismiss(animated: false)
    }
}
