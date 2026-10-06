// 移植自上游: submodules/CheckNode/Sources/CheckNode.swift :1-656
//   （上游类型：CheckNodeTheme / CheckNodeContent / CheckNode / InteractiveCheckNode / CheckLayer）
//
// ⭐ 本文件的核心价值（为什么值得移植）：
//   「参数 → 位图」的无状态绘制范式：所有视觉状态（主题色、勾/数字、展开进度、矩形进度、是否在退场）
//   打包成一个纯值，绘制函数只依赖这个值 + size，不读任何全局/环境。于是同一份绘制代码可以给
//   UIView、CALayer、离屏位图三条路复用，动画只要插值那个值即可（本文件的可动画图层属性就是这个思路）。
//
// 改动（逐条）：
//   1. ASDisplayNode → UIView（TiebaCheckNode），CheckLayer: CALayer 保留为真正的图层（它本来就是 CALayer）。
//      为了不改动画语义，TiebaCheckNode 用 layerClass 指定自己的 backing layer 为 TiebaCheckLayer。
//   2. 类型加 Tieba 前缀：CheckNodeTheme → TiebaCheckNodeTheme、CheckNodeContent → TiebaCheckNodeContent、
//      CheckNode → TiebaCheckNode、CheckLayer → TiebaCheckLayer。
//      （InteractiveCheckNode 与它的 HighlightTrackingControl 子类在本轮零调用方清理中删除：
//        勾选框的交互由调用方页面自己做，本文件只留绘制与图层。）
//   3. `CheckNodeTheme.init(theme: PresentationTheme, style:hasInset:)` 删除 → 主题色改为**构造参数注入**：
//      调用方把已经解析好的 fill/stroke/border 颜色传进成员逐一初始化。本仓没有 PresentationTheme，
//      也不应该在绘制层重新引入主题单例。另提供 `.plain` / `.overlay` 两个静态预设，语义与上游那两个 style 一致。
//   4. POPBasicAnimation（Facebook pop 框架）→ 原生 CALayer 可动画属性：
//      `@NSManaged var animationProgress / rectangleProgress` + `needsDisplay(forKey:)`，
//      用 CABasicAnimation 驱动。这是 CoreAnimation 自己的标准做法（等价于 pop 的
//      POPAnimatableProperty readBlock/writeBlock + threshold），去掉了一整个第三方依赖。
//   5. 上游三次链式 `layer.animateScale(from:to:duration:completion:)`（Display/CAAnimationUtils.swift:401）
//      合成一条 CAKeyframeAnimation：values [1, 0.9, 1.1, 1] / keyTimes 按上游三段时长
//      (0.08 + 0.13 + 0.1) 折算 / timingFunctions [easeOut, easeOut, easeIn]。
//      视觉结果一致，但不需要 CAAnimationDelegate —— Swift 6 下代理回调是非隔离的，
//      在代理里回调主线程闭包要么加 @preconcurrency 要么绕，都不干净（铁律 4）。
//   7. `Font.with(size:design:.round,weight:.medium,traits:[])` → UIFontDescriptor.withDesign(.rounded) 的
//      系统字体（上游就是「圆体 + medium」，这里用系统 API 拼出同一字体，不引入 Font 模块）。
//   8. 依赖注入式改写：`tiebaUIScreenScale`/`tiebaUIScreenPixel`/`floorToScreenPixels` → TiebaDrawingMetrics，
//      `UIColor(rgb:alpha:)` → TiebaDrawingMetrics.rgb，`mixedWith` → TiebaDrawingMetrics.mixed，
//      `withMultipliedAlpha` → withAlphaComponent（语义等价，见下）。
//   9. `generateImage(...)`（Display 的离屏渲染，依赖 ObjC 缓冲）→ 直接实现 `CALayer.draw(in:)`：
//      图层自己画，系统负责位图化，少一次拷贝也少一个依赖。
//  10. 上游 ASDisplayNode 的 `setNeedsDisplay()` → `layer.setNeedsDisplay()`（同一语义）。
//      `touchesBegan/Ended/Cancelled` 三个只调 super 的空覆写删除（上游它们没有任何行为）。
//  11. Swift 6：TiebaCheckNode 是 UIView 子类天然 @MainActor（但**不标 final**，上游 InteractiveCheckNode
//      就是它的子类）；CALayer 不是 @MainActor 类型，所以 TiebaCheckLayer.draw(in:) 是非隔离的 ——
//      纯绘制函数 TiebaCheckDrawing 一律 nonisolated，两个隔离域都能直接调，不加任何绕过。
//  12. 未移植（上游有、本仓无对应物）：`Corner` 的 continuous curve 只在 ImageCorners 里用到，
//      与 CheckNode 无关；`CheckNode.touchesBegan` 等空覆写见第 10 条；没有其它省略。

import Foundation
import UIKit
import QuartzCore

// MARK: - 主题（参数注入）

struct TiebaCheckNodeTheme: Equatable {
    var backgroundColor: UIColor
    var strokeColor: UIColor
    var borderColor: UIColor
    var overlayBorder: Bool
    var hasInset: Bool
    var hasShadow: Bool
    var filledBorder: Bool
    var borderWidth: CGFloat?
    var checkmarkLineWidth: CGFloat?
    var isDottedBorder: Bool

    init(backgroundColor: UIColor, strokeColor: UIColor, borderColor: UIColor, overlayBorder: Bool, hasInset: Bool, hasShadow: Bool, filledBorder: Bool = false, borderWidth: CGFloat? = nil, checkmarkLineWidth: CGFloat? = nil, isDottedBorder: Bool = false) {
        self.backgroundColor = backgroundColor
        self.strokeColor = strokeColor
        self.borderColor = borderColor
        self.overlayBorder = overlayBorder
        self.hasInset = hasInset
        self.hasShadow = hasShadow
        self.filledBorder = filledBorder
        self.borderWidth = borderWidth
        self.checkmarkLineWidth = checkmarkLineWidth
        self.isDottedBorder = isDottedBorder
    }
}

extension TiebaCheckNodeTheme {
    /// 上游 `CheckNodeTheme.Style`（CheckNode.swift:35-59）的两个预设。
    /// [移植] 上游这里是从 PresentationTheme.list.itemCheckColors 取色；本仓没有主题单例，
    ///        所以预设只表达「结构差异」（inset / overlay / shadow），具体颜色由调用方注入。
    enum Style {
        case plain
        case overlay
    }

    /// 上游 Style.plain：无叠加边框、无阴影、无内缩。
    static func plain(backgroundColor: UIColor, strokeColor: UIColor, borderColor: UIColor) -> TiebaCheckNodeTheme {
        return TiebaCheckNodeTheme(backgroundColor: backgroundColor, strokeColor: strokeColor, borderColor: borderColor, overlayBorder: false, hasInset: false, hasShadow: false)
    }

    /// 上游 Style.overlay：白色描边 + 内缩 + 叠加边框 + 阴影（用在图片/头像上）。
    static func overlay(backgroundColor: UIColor, strokeColor: UIColor) -> TiebaCheckNodeTheme {
        return TiebaCheckNodeTheme(backgroundColor: backgroundColor, strokeColor: strokeColor, borderColor: UIColor.white, overlayBorder: true, hasInset: true, hasShadow: true)
    }
}

// MARK: - 内容

enum TiebaCheckNodeContent: Equatable {
    /// isRectangle：勾选框是矩形（选中态）还是圆形（未选中态）；矩形进度会在 0.2s 内插值过去。
    case check(isRectangle: Bool)
    /// 多选计数（图上直接画数字）。
    case counter(Int)
}

private extension TiebaCheckNodeContent {
    /// 上游 CheckNodeContent.rectangleProgressValue：矩形 = 1，圆形 = 0。
    var rectangleProgressValue: CGFloat {
        if case .check(isRectangle: true) = self {
            return 1.0
        } else {
            return 0.0
        }
    }
}

// MARK: - 绘制（无状态：只依赖参数 + size）

/// 上游 CheckLayer.drawContents / cornerRadius / roundedRectPath（CheckNode.swift:473-655）逐行对应。
/// [移植] 不标 @MainActor：CALayer.draw(in:) 在 Swift 6 里是非隔离的（CALayer 不是 @MainActor 类型），
///        这个函数本来就是纯绘制、不碰任何隔离状态，标 nonisolated 才能被图层直接调用。
private enum TiebaCheckDrawing {
    static func drawContents(
        context: CGContext,
        size: CGSize,
        theme: TiebaCheckNodeTheme,
        content: TiebaCheckNodeContent,
        animationProgress: CGFloat,
        selected: Bool,
        animatingOut: Bool,
        rectangleProgress: CGFloat
    ) {
        context.clear(CGRect(origin: CGPoint(), size: size))

        // 注意上游用的是 size.width 而不是 height（正方形控件，两者相等）。
        let center = CGPoint(x: size.width / 2.0, y: size.width / 2.0)

        var borderWidth: CGFloat = 1.0 + TiebaDrawingMetrics.screenPixel
        if theme.hasInset {
            borderWidth = 1.5
        }
        if let customBorderWidth = theme.borderWidth {
            borderWidth = customBorderWidth
        }

        let checkWidth = theme.checkmarkLineWidth ?? 1.5

        let inset: CGFloat = theme.hasInset ? 2.0 - TiebaDrawingMetrics.screenPixel : 0.0

        let checkProgress: CGFloat

        context.setStrokeColor(theme.borderColor.cgColor)
        context.setLineWidth(borderWidth)

        // 退场（animatingOut）时整体缩小并淡出：只有非 filledBorder 的两条路径会用到。
        let maybeScaleOut = {
            if animatingOut {
                context.translateBy(x: size.width / 2.0, y: size.height / 2.0)
                context.scaleBy(x: animationProgress, y: animationProgress)
                context.translateBy(x: -size.width / 2.0, y: -size.height / 2.0)

                context.setAlpha(animationProgress)
            }
        }

        let rectProgress = rectangleProgress
        let cornerRadius = self.cornerRadius(for: size, progress: rectProgress, minCornerRadius: ceil(size.width * 0.318))
        let innerCornerRadius = self.cornerRadius(for: size, progress: rectProgress, minCornerRadius: ceil(size.width * 0.318) - 1.0)

        if !theme.filledBorder && !theme.hasShadow && !theme.overlayBorder {
            if theme.isDottedBorder {
                // 虚线边框（「待上传」态）。
                checkProgress = 0.0
                let borderInset = borderWidth / 2.0 + inset
                let borderFrame = CGRect(origin: CGPoint(), size: size).insetBy(dx: borderInset, dy: borderInset)
                context.setLineDash(phase: -6.4, lengths: [4.0, 4.0])
                context.addPath(self.roundedRectPath(in: borderFrame, cornerRadius: self.cornerRadius(for: borderFrame.size, progress: rectProgress, minCornerRadius: 7.0)))
                context.strokePath()
            } else {
                checkProgress = animationProgress

                let fillProgress: CGFloat = animationProgress

                // 底色往描边色插值：progress=0 时是纯底色，=1 时是描边色。
                context.setFillColor(TiebaDrawingMetrics.mixed(theme.backgroundColor, theme.borderColor, alpha: 1.0 - fillProgress).cgColor)

                context.addPath(self.roundedRectPath(in: CGRect(origin: .zero, size: size), cornerRadius: cornerRadius))
                context.fillPath()

                // 内圈随 fillProgress 收缩到 0：用 .copy 挖一个透明洞，于是只剩一圈边。
                let innerDiameter: CGFloat = (fillProgress * 0.0) + (1.0 - fillProgress) * (size.width - borderWidth * 2.0)

                context.setBlendMode(.copy)
                context.setFillColor(UIColor.clear.cgColor)

                context.addPath(self.roundedRectPath(in: CGRect(origin: CGPoint(x: (size.width - innerDiameter) * 0.5, y: (size.height - innerDiameter) * 0.5), size: CGSize(width: innerDiameter, height: innerDiameter)), cornerRadius: innerCornerRadius))
                context.fillPath()

                context.setBlendMode(.normal)
            }
        } else {
            checkProgress = animatingOut ? 1.0 : animationProgress

            let fillProgress = animatingOut ? 1.0 : min(1.0, animationProgress * 1.35)

            let borderInset = borderWidth / 2.0 + inset
            let borderProgress: CGFloat = theme.filledBorder ? fillProgress : 1.0
            let borderFrame = CGRect(origin: CGPoint(), size: size).insetBy(dx: borderInset, dy: borderInset)

            if theme.filledBorder {
                maybeScaleOut()
            }

            context.saveGState()
            if theme.hasShadow {
                context.setShadow(offset: CGSize(), blur: 2.5, color: TiebaDrawingMetrics.rgb(0x000000, alpha: 0.22).cgColor)
            }

            let borderRect = borderFrame.insetBy(dx: borderFrame.width * (1.0 - borderProgress), dy: borderFrame.height * (1.0 - borderProgress))
            context.addPath(self.roundedRectPath(in: borderRect, cornerRadius: self.cornerRadius(for: borderRect.size, progress: rectProgress, minCornerRadius: 7.0)))
            context.strokePath()
            context.restoreGState()

            if !theme.filledBorder {
                maybeScaleOut()
            }

            context.setFillColor(theme.backgroundColor.cgColor)

            let fillInset = theme.overlayBorder ? borderWidth + inset : inset
            let fillFrame = CGRect(origin: CGPoint(), size: size).insetBy(dx: fillInset, dy: fillInset)
            let fillRect = fillFrame.insetBy(dx: fillFrame.width * (1.0 - fillProgress), dy: fillFrame.height * (1.0 - fillProgress))
            context.addPath(self.roundedRectPath(in: fillRect, cornerRadius: self.cornerRadius(for: fillRect.size, progress: rectProgress, minCornerRadius: 6.0)))
            context.fillPath()
        }

        switch content {
            case .check:
                // 勾是两段折线，按 checkProgress 逐段画出来（0.33 之前画第一段，之后接第二段）。
                let scale = (size.width - inset) / 18.0
                let firstSegment: CGFloat = max(0.0, min(1.0, checkProgress * 3.0))
                let s = CGPoint(x: center.x - (4.0 - 0.3333) * scale, y: center.y + 0.5 * scale)
                let p1 = CGPoint(x: 2.5 * scale, y: 3.0 * scale)
                let p2 = CGPoint(x: 4.6667 * scale, y: -6.0 * scale)

                if !firstSegment.isZero {
                    if firstSegment < 1.0 {
                        context.move(to: CGPoint(x: s.x + p1.x * firstSegment, y: s.y + p1.y * firstSegment))
                        context.addLine(to: s)
                    } else {
                        let secondSegment = (checkProgress - 0.33) * 1.5
                        context.move(to: CGPoint(x: s.x + p1.x + p2.x * secondSegment, y: s.y + p1.y + p2.y * secondSegment))
                        context.addLine(to: CGPoint(x: s.x + p1.x, y: s.y + p1.y))
                        context.addLine(to: s)
                    }
                }

                context.setStrokeColor(theme.strokeColor.cgColor)
                if theme.strokeColor == .clear {
                    // 描边色是 clear 时用 .clear 混合模式把勾「擦」出来（底色是图，不能只画透明）。
                    context.setBlendMode(.clear)
                }
                context.setLineWidth(checkWidth)
                context.setLineCap(.round)
                context.setLineJoin(.round)
                context.setMiterLimit(10.0)

                context.strokePath()
            case let .counter(number):
                let fontSize: CGFloat
                let string = "\(number)"
                switch string.count {
                case 1:
                    fontSize = 16.0
                case 2:
                    fontSize = 15.0
                default:
                    fontSize = 13.0
                }
                let text = NSAttributedString(
                    string: string,
                    attributes: [
                        .font: self.roundedFont(size: fontSize, weight: .medium),
                        // [移植] 上游 withMultipliedAlpha(animationProgress)：同色、alpha 相乘，withAlphaComponent 等价。
                        .foregroundColor: TiebaDrawingMetrics.multiplyingAlpha(theme.strokeColor, animationProgress)
                    ]
                )
                let textRect = text.boundingRect(with: CGSize(width: 100.0, height: 100.0), options: NSStringDrawingOptions.usesLineFragmentOrigin, context: nil)
                text.draw(at: CGPoint(x: textRect.minX + TiebaDrawingMetrics.floorToPixels((size.width - textRect.width) * 0.5), y: textRect.minY + TiebaDrawingMetrics.floorToPixels((size.height - textRect.height) * 0.5)))
        }
    }

    /// 上游 `Font.with(size:design:.round,weight:.medium,traits:[])` 的系统 API 等价物。
    private static func roundedFont(size: CGFloat, weight: UIFont.Weight) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded) else {
            return base
        }
        return UIFont(descriptor: descriptor, size: size)
    }

    /// 上游 CheckLayer.cornerRadius(for:progress:minCornerRadius:)（CheckNode.swift:621-625）。
    private static func cornerRadius(for size: CGSize, progress: CGFloat, minCornerRadius: CGFloat) -> CGFloat {
        let maxCornerRadius = min(size.width, size.height) / 2.0
        let minCornerRadius = min(minCornerRadius, maxCornerRadius)
        return maxCornerRadius - (maxCornerRadius - minCornerRadius) * progress
    }

    /// 上游 CheckLayer.roundedRectPath(in:cornerRadius:)（CheckNode.swift:627-655），逐行照搬。
    private static func roundedRectPath(in rect: CGRect, cornerRadius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        guard !rect.isEmpty else {
            return path
        }

        let radius = min(max(cornerRadius, 0.0), min(rect.width, rect.height) / 2.0)
        if radius <= 0.0 {
            path.addRect(rect)
            return path
        }

        let minX = rect.minX
        let maxX = rect.maxX
        let minY = rect.minY
        let maxY = rect.maxY

        path.move(to: CGPoint(x: minX + radius, y: minY))
        path.addLine(to: CGPoint(x: maxX - radius, y: minY))
        path.addArc(center: CGPoint(x: maxX - radius, y: minY + radius), radius: radius, startAngle: -.pi / 2.0, endAngle: 0.0, clockwise: false)
        path.addLine(to: CGPoint(x: maxX, y: maxY - radius))
        path.addArc(center: CGPoint(x: maxX - radius, y: maxY - radius), radius: radius, startAngle: 0.0, endAngle: .pi / 2.0, clockwise: false)
        path.addLine(to: CGPoint(x: minX + radius, y: maxY))
        path.addArc(center: CGPoint(x: minX + radius, y: maxY - radius), radius: radius, startAngle: .pi / 2.0, endAngle: .pi, clockwise: false)
        path.addLine(to: CGPoint(x: minX, y: minY + radius))
        path.addArc(center: CGPoint(x: minX + radius, y: minY + radius), radius: radius, startAngle: .pi, endAngle: 3.0 * .pi / 2.0, clockwise: false)
        path.closeSubpath()
        return path
    }
}

// MARK: - 图层

/// 上游 CheckLayer（CheckNode.swift:306-656）。
final class TiebaCheckLayer: CALayer {
    /// 勾的展开进度。@NSManaged + needsDisplayForKey 是 CoreAnimation 原生的可动画属性写法，
    /// 对应上游 pop 的 POPAnimatableProperty("progress")（见文件头第 4 条）。
    @NSManaged var animationProgress: CGFloat
    /// 圆角 ↔ 矩形的插值进度。
    @NSManaged var rectangleProgress: CGFloat

    var theme: TiebaCheckNodeTheme = .plain(backgroundColor: .white, strokeColor: .blue, borderColor: .white) {
        didSet {
            self.setNeedsDisplay()
        }
    }

    var selected = false
    var animatingOut = false
    /// 选中时的缩放回弹开关（上游 CheckLayer.animateScale）。
    var animateScale = true

    private var contentValue: TiebaCheckNodeContent = .check(isRectangle: false)

    override init() {
        super.init()
        self.isOpaque = false
        self.rasterizationScale = TiebaDrawingMetrics.screenScale
        // bounds 变化必须重画：勾的几何完全由 size 决定。
        self.needsDisplayOnBoundsChange = true
    }

    /// CA 在生成呈现副本/动画副本时会走这个初始化器，非 @NSManaged 的自定义状态必须在这里带过去，
    /// 否则动画期间的副本会退回默认主题（这是自绘图层最容易踩的坑）。
    override init(layer: Any) {
        if let layer = layer as? TiebaCheckLayer {
            self.theme = layer.theme
            self.contentValue = layer.contentValue
            self.selected = layer.selected
            self.animatingOut = layer.animatingOut
            self.animateScale = layer.animateScale
        }
        super.init(layer: layer)
        self.isOpaque = false
        self.rasterizationScale = TiebaDrawingMetrics.screenScale
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var content: TiebaCheckNodeContent {
        get {
            return self.contentValue
        }
        set {
            if self.contentValue == newValue {
                return
            }
            let oldValue = self.contentValue
            self.contentValue = newValue

            let targetProgress = newValue.rectangleProgressValue
            if oldValue.rectangleProgressValue != targetProgress {
                self.addRectangleProgressAnimation(to: targetProgress)
            } else {
                self.removeAnimation(forKey: "rectangleProgress")
                self.rectangleProgress = targetProgress
                self.setNeedsDisplay()
            }
        }
    }

    /// 上游用 POPBasicAnimation(keyPath: "rectangleProgress", duration 0.2, easeInEaseOut)，
    /// 这里换成同参数的原生 CABasicAnimation。
    private func addRectangleProgressAnimation(to targetProgress: CGFloat) {
        let animation = CABasicAnimation(keyPath: "rectangleProgress")
        animation.fromValue = NSNumber(value: Double(self.rectangleProgress))
        animation.toValue = NSNumber(value: Double(targetProgress))
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.duration = 0.2
        // 上游 pop 会把最终值写回模型；CABasicAnimation 默认不回写，所以显式设置 + fillMode。
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        self.rectangleProgress = targetProgress
        self.add(animation, forKey: "rectangleProgress")
    }

    /// 上游 CheckLayer.setSelected(_:animated:)（CheckNode.swift:399-454）。
    func setSelected(_ selected: Bool, animated: Bool = false) {
        guard self.selected != selected else {
            return
        }
        self.selected = selected

        if animated {
            self.animatingOut = !selected

            let animation = CABasicAnimation(keyPath: "animationProgress")
            animation.fromValue = NSNumber(value: Double(selected ? 0.0 : 1.0))
            animation.toValue = NSNumber(value: Double(selected ? 1.0 : 0.0))
            animation.timingFunction = CAMediaTimingFunction(name: selected ? .easeOut : .easeIn)
            animation.duration = selected ? 0.21 : 0.15
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = false
            self.animationProgress = selected ? 1.0 : 0.0
            self.add(animation, forKey: "animationProgress")

            if self.animateScale {
                self.addScaleBounce(selected: selected)
            }
        } else {
            self.removeAnimation(forKey: "animationProgress")
            self.animatingOut = false
            self.animationProgress = selected ? 1.0 : 0.0
            self.setNeedsDisplay()
        }
    }

    /// 上游选中/取消选中时的三段链式缩放（见文件头第 5 条）：合成一条关键帧动画。
    private func addScaleBounce(selected: Bool) {
        let animation = CAKeyframeAnimation(keyPath: "transform.scale")
        if selected {
            // 上游：1.0→0.9 (0.08, easeOut) →1.1 (0.13, easeOut) →1.0 (0.1, easeIn)，总时长 0.31s。
            animation.values = [1.0 as NSNumber, 0.9 as NSNumber, 1.1 as NSNumber, 1.0 as NSNumber]
            animation.keyTimes = [0.0 as NSNumber, 0.258 as NSNumber, 0.677 as NSNumber, 1.0 as NSNumber]
            animation.timingFunctions = [
                CAMediaTimingFunction(name: .easeOut),
                CAMediaTimingFunction(name: .easeOut),
                CAMediaTimingFunction(name: .easeIn)
            ]
        } else {
            // 上游：1.0→0.9 (0.08, easeOut) →1.0 (0.13, easeOut)，总时长 0.21s。
            animation.values = [1.0 as NSNumber, 0.9 as NSNumber, 1.0 as NSNumber]
            animation.keyTimes = [0.0 as NSNumber, 0.381 as NSNumber, 1.0 as NSNumber]
            animation.timingFunctions = [
                CAMediaTimingFunction(name: .easeOut),
                CAMediaTimingFunction(name: .easeOut)
            ]
        }
        animation.duration = selected ? 0.31 : 0.21
        self.add(animation, forKey: "scaleBounce")
    }

    /// 上游 CheckLayer 里 setHighlighted 是空实现（保留签名，方便调用方无脑转发）。
    func setHighlighted(_ highlighted: Bool, animated: Bool = false) {
    }

    override class func needsDisplay(forKey key: String) -> Bool {
        if key == "animationProgress" || key == "rectangleProgress" {
            return true
        }
        return super.needsDisplay(forKey: key)
    }

    /// 上游 CheckLayer.action(forKey:) 返回 nullAction：禁止隐式动画（属性一变就动画会跟 pop 打架）。
    override func action(forKey event: String) -> CAAction? {
        return NSNull()
    }

    /// 上游 CheckLayer.display() 走 generateImage 离屏渲染；这里让图层自己画（见文件头第 9 条）。
    override func draw(in ctx: CGContext) {
        if self.bounds.isEmpty {
            return
        }
        TiebaCheckDrawing.drawContents(
            context: ctx,
            size: self.bounds.size,
            theme: self.theme,
            content: self.contentValue,
            animationProgress: self.animationProgress,
            selected: self.selected,
            animatingOut: self.animatingOut,
            rectangleProgress: self.rectangleProgress
        )
    }
}

// MARK: - 视图

/// 上游 CheckNode（CheckNode.swift:115-260）。
/// [移植] 不能标 final：上游 InteractiveCheckNode 就是它的子类（见文件末尾）。
class TiebaCheckNode: UIView {
    override class var layerClass: AnyClass {
        return TiebaCheckLayer.self
    }

    private var checkLayer: TiebaCheckLayer {
        // layerClass 已经保证了类型；万一被替换（例如被别的组件接管）时退化成临时图层，不崩。
        // 直接强转：layerClass 覆盖已经保证 backing layer 就是这个类型，这是本类的不变式。
        // [2026-10-05] 原来这里是 “as? ... ?? TiebaCheckLayer()” 兜底 —— 那是**静默失败**：不变式一旦被破坏
        // （例如有人换掉了 layer），所有设置会写到一个临时图层上、界面什么都不显示，而调用方毫无察觉。
        // 按「不留 fallback」的要求删掉，让不变式被破坏时立刻暴露。
        return self.layer as! TiebaCheckLayer
    }

    var checkLayerIfLoaded: TiebaCheckLayer? {
        return self.layer as? TiebaCheckLayer
    }

    var theme: TiebaCheckNodeTheme {
        didSet {
            self.checkLayer.theme = self.theme
        }
    }

    var content: TiebaCheckNodeContent {
        didSet {
            self.checkLayer.content = self.content
        }
    }

    /// 上游 CheckNode.selected：只读给外部，改要用 setSelected(_:animated:)。
    private(set) var selected = false

    init(theme: TiebaCheckNodeTheme, content: TiebaCheckNodeContent = .check(isRectangle: false)) {
        self.theme = theme
        self.content = content

        super.init(frame: CGRect())

        self.isOpaque = false
        self.backgroundColor = .clear
        self.checkLayer.theme = theme
        self.checkLayer.content = content
        self.checkLayer.rectangleProgress = content.rectangleProgressValue
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 上游 CheckNode.setSelected(_:animated:)（CheckNode.swift:169-222）。
    func setSelected(_ selected: Bool, animated: Bool = false) {
        guard self.selected != selected else {
            return
        }
        self.selected = selected
        self.checkLayer.setSelected(selected, animated: animated)
    }

    func setHighlighted(_ highlighted: Bool, animated: Bool = false) {
        self.checkLayer.setHighlighted(highlighted, animated: animated)
    }
}


