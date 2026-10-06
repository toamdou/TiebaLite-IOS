// 状态指示器的三个「演算器」（Context）与它们的不可变快照（Drawing）。
//
// 移植自上游 submodules/SemanticStatusNode/Sources/SemanticStatusNode{Check,Progress,Icon}Context.swift
// （上游还有 SecretTimeoutContext，本仓无对应场景，不搬，见 TiebaStatusNode.swift 文件头）。
// 分工：Context 持有时间轴（起始时刻、插值器），drawingState() 每次被问就吐一个**新值**；
//       Drawing 只认 (CGContext, size, foregroundColor)，没有时间也没有可变状态。
//
// 逐条改动（相对上游）：
//   1. 上游 Context 的 isAnimating 恒为 true（check/progress），本移植按真实需要返回：
//      勾选只在 0→1 描边期间为 true、确定进度只在插值期间为 true，**省掉一个常驻 display link**。
//      这不是行为变化（不影响画出来的东西），是资源纪律。
//   2. 上游的 alpha=0 走 destinationOut（配合 cutout 挖洞）；本移植只有普通合成，
//      统一用 foregroundColor.alpha * transitionFraction。
//   3. 上游 ProgressContext 里 `progress = min(1.0, progress)` 赋值后无人读（死代码），不搬。
//   4. 图标从手写 SVG 路径换成 SF Symbols / 外部 UIImage，见 TiebaStatusNode.swift 改动 3。
import UIKit

/// 把前景色按过渡比例调透明度。
/// 不用 UIColor.alpha（不存在这个属性）：UIColor 没有 alpha 取值口，走 cgColor.alpha——
/// 动态色在 draw 时已解析到当前 trait，取到的是当帧真实 alpha。
private func tiebaStatusAlpha(_ color: UIColor, _ fraction: CGFloat) -> UIColor {
    color.withAlphaComponent(color.cgColor.alpha * fraction)
}

// MARK: - 进度环

/// 进度插值：0.2 秒内从 initialValue 线性走到目标值（上游同款时长与线性插值）。
struct TiebaStatusProgressTransition {
    let beginTime: CFTimeInterval
    let initialValue: CGFloat

    /// 返回 (当前值, 是否已走完)。
    func value(at timestamp: CFTimeInterval, target: CGFloat) -> (value: CGFloat, isCompleted: Bool) {
        let duration: CFTimeInterval = 0.2
        var t = CGFloat((timestamp - beginTime) / duration)
        t = min(1, max(0, t))
        return (t * target + (1 - t) * initialValue, t >= 1 - 0.001)
    }
}

/// 进度环快照。
struct TiebaStatusProgressDrawing: TiebaStatusDrawing {
    let transitionFraction: CGFloat
    /// nil = 不确定进度（自己转）。
    let value: CGFloat?
    let displayCancel: Bool
    let appearance: TiebaStatusState.ProgressAppearance?
    let animateRotation: Bool
    let timestamp: CFTimeInterval

    func draw(in context: CGContext, size: CGSize, foregroundColor: UIColor) {
        let diameter = size.width
        // 上游所有尺寸都按 50pt 基准等比缩放，本移植照抄这个基准，换尺寸不换观感。
        // 所有尺寸都折算到 50pt 基准（上游的 factor 约定）：这样同一套几何常量在 16pt 和 44pt 上
        // 观感一致，不需要为每个尺寸调参。**改尺寸时不要改这些常量，改 factor 的基准。**
        let factor = diameter / 50
        context.saveGState()
        let color = tiebaStatusAlpha(foregroundColor, transitionFraction)
        context.setStrokeColor(color.cgColor)
        context.setFillColor(color.cgColor)

        // 12 点钟起笔：进度环从正上方顺时针长（-pi/2 是 UIKit 坐标系里的"上"）
        var startAngle = -CGFloat.pi / 2
        var endAngle: CGFloat
        let rawProgress: CGFloat
        if let value = value {
            rawProgress = animateRotation ? value : 1 - value
        } else {
            // 不确定进度：2 秒一圈的往复（上游用 timestamp 的小数部分做 0→2 的锯齿）
            rawProgress = CGFloat(1 + timestamp.truncatingRemainder(dividingBy: 2))
        }
        var progress = rawProgress
        endAngle = progress * 2 * .pi + startAngle
        if progress > 1 {
            // 进度超过 100%：把弧"折回来"画剩余部分（2 - progress），并交换起止角，
            // 让弧仍然从 12 点方向补满一圈。**这是进度环最容易被写错的一处**：
            // 直接 clamp 到 1.0 会让 120% 和 100% 看起来一样，用户以为卡住了。
            progress = 2 - progress
            swap(&startAngle, &endAngle)
        }

        let lineWidth = appearance?.lineWidth ?? max(1.6, 2.25 * factor)
        let pathDiameter = appearance.map { diameter - $0.lineWidth - $0.inset * 2 } ?? (diameter - lineWidth - 2.5 * 2)

        if animateRotation {
            // 确定进度也带自转：上游把时间折算成角度再整体旋转画布
            var angle = timestamp.truncatingRemainder(dividingBy: .pi * 2)
            angle *= 4
            context.translateBy(x: diameter / 2, y: diameter / 2)
            context.rotate(by: CGFloat(angle.truncatingRemainder(dividingBy: .pi * 2)))
            context.translateBy(x: -diameter / 2, y: -diameter / 2)
        }

        let path = UIBezierPath(
            arcCenter: CGPoint(x: diameter / 2, y: diameter / 2),
            radius: pathDiameter / 2,
            startAngle: startAngle,
            endAngle: endAngle,
            clockwise: animateRotation)
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        path.stroke()
        context.restoreGState()

        guard displayCancel else { return }
        context.saveGState()
        context.setStrokeColor(color.cgColor)
        context.setFillColor(color.cgColor)
        // × 随过渡缩放出现（上游同款）
        context.translateBy(x: size.width / 2, y: size.height / 2)
        context.scaleBy(x: max(0.01, transitionFraction), y: max(0.01, transitionFraction))
        context.translateBy(x: -size.width / 2, y: -size.height / 2)
        context.setLineWidth(max(1.3, 2 * factor))
        context.setLineCap(.round)
        let crossSize = 14 * factor
        context.move(to: CGPoint(x: diameter / 2 - crossSize / 2, y: diameter / 2 - crossSize / 2))
        context.addLine(to: CGPoint(x: diameter / 2 + crossSize / 2, y: diameter / 2 + crossSize / 2))
        context.strokePath()
        context.move(to: CGPoint(x: diameter / 2 + crossSize / 2, y: diameter / 2 - crossSize / 2))
        context.addLine(to: CGPoint(x: diameter / 2 - crossSize / 2, y: diameter / 2 + crossSize / 2))
        context.strokePath()
        context.restoreGState()
    }
}

/// 演算：进度值变化 → 0.2s 插值；不确定进度 → 一直要帧。
@MainActor
final class TiebaStatusProgressContext: TiebaStatusContext {
    private var value: CGFloat?
    let displayCancel: Bool
    private let appearance: TiebaStatusState.ProgressAppearance?
    private let animateRotation: Bool
    private var transition: TiebaStatusProgressTransition?

    var isAnimating: Bool {
        // 不确定进度要一直转；插值期间要按帧；其余静止。
        value == nil || transition != nil
    }

    init(value: CGFloat?, displayCancel: Bool, appearance: TiebaStatusState.ProgressAppearance?, animateRotation: Bool) {
        self.value = value
        self.displayCancel = displayCancel
        self.appearance = appearance
        self.animateRotation = animateRotation
    }

    /// 同类状态的复用入口：值变了不起新动画，只把插值起点挪到"当前算出来的值"。
    func updateValue(_ newValue: CGFloat?) {
        guard newValue != value else { return }
        let previousValue = value
        value = newValue
        let timestamp = CACurrentMediaTime()
        if let _ = newValue, let previousValue = previousValue {
            let current = transition?.value(at: timestamp, target: previousValue).value ?? previousValue
            transition = TiebaStatusProgressTransition(beginTime: timestamp, initialValue: current)
        } else {
            transition = nil
        }
    }

    func drawingState(transitionFraction: CGFloat) -> TiebaStatusDrawing {
        let timestamp = CACurrentMediaTime()
        var resolved = value
        if let target = value, let transition = transition {
            let result = transition.value(at: timestamp, target: target)
            resolved = result.value
            if result.isCompleted { self.transition = nil }
        }
        return TiebaStatusProgressDrawing(
            transitionFraction: transitionFraction,
            value: resolved,
            displayCancel: displayCancel,
            appearance: appearance,
            animateRotation: animateRotation,
            timestamp: timestamp)
    }
}
// MARK: - 勾选

/// 勾选快照：两段折线按 value（0→1）逐段画出来。
struct TiebaStatusCheckDrawing: TiebaStatusDrawing {
    let transitionFraction: CGFloat
    let value: CGFloat
    let appearance: TiebaStatusState.CheckAppearance?

    func draw(in context: CGContext, size: CGSize, foregroundColor: UIColor) {
        let diameter = size.width
        let factor = diameter / 50
        context.saveGState()
        let color = tiebaStatusAlpha(foregroundColor, transitionFraction)
        context.setStrokeColor(color.cgColor)
        context.setFillColor(color.cgColor)
        let center = CGPoint(x: diameter / 2, y: diameter / 2)
        let lineWidth = appearance?.lineWidth ?? max(1.6, 2.25 * factor)
        context.setLineWidth(max(1.7, lineWidth * factor))
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setMiterLimit(10)

        // 勾的起笔点 s、第一段位移 p1、第二段位移 p2（上游的几何常量，逐字照搬）。
        // 两段式的原因：value 在 0→1 之间时先画短边（s→p1 方向），过了 1/3 再画长边（p1→p1+p2），
        // 这样"勾"是**写出来**的，而不是整体淡入——手势/下载完成时的那点仪式感就来自这里。
        let firstSegment = max(0, min(1, value * 3))
        var s = CGPoint(x: center.x - 10 * factor, y: center.y + 1 * factor)
        var p1 = CGPoint(x: 7 * factor, y: 7 * factor)
        var p2 = CGPoint(x: 13 * factor, y: -15 * factor)
        if diameter < 36 {
            // 小尺寸下勾要收一点：同一条勾在 20pt 圆里会顶到边，视觉上变"胖"。
            // 这不是随便写的阈值，是上游在 16/22/30pt 三档上试出来的分界。
            // 小尺寸下勾更小一点，否则视觉上顶满圆
            s = CGPoint(x: center.x - 7 * factor, y: center.y + 1 * factor)
            p1 = CGPoint(x: 4.5 * factor, y: 4.5 * factor)
            p2 = CGPoint(x: 10 * factor, y: -11 * factor)
        }

        if !firstSegment.isZero {
            if firstSegment < 1 {
                // 第一段还在长：从 s 往 p1 方向伸出 firstSegment 比例
                context.move(to: CGPoint(x: s.x + p1.x * firstSegment, y: s.y + p1.y * firstSegment))
                context.addLine(to: s)
            } else {
                // 第二段：从 p1+p2 方向收回
                let secondSegment = (value - 0.33) * 1.5
                context.move(to: CGPoint(x: s.x + p1.x + p2.x * secondSegment, y: s.y + p1.y + p2.y * secondSegment))
                context.addLine(to: CGPoint(x: s.x + p1.x, y: s.y + p1.y))
                context.addLine(to: s)
            }
        }
        context.strokePath()
        context.restoreGState()
    }
}

/// 演算：出现时把 value 从 0 推到 1（0.2s），推完就静止。
@MainActor
final class TiebaStatusCheckContext: TiebaStatusContext {
    private var value: CGFloat
    private let appearance: TiebaStatusState.CheckAppearance?
    private var reveal: TiebaStatusProgressTransition?

    var isAnimating: Bool { reveal != nil }

    init(appearance: TiebaStatusState.CheckAppearance?) {
        self.appearance = appearance
        self.value = 1
        // 上游在 init 里就起动画：check 一出现就是"从 0 描到 1"
        self.reveal = TiebaStatusProgressTransition(beginTime: CACurrentMediaTime(), initialValue: 0)
    }

    func drawingState(transitionFraction: CGFloat) -> TiebaStatusDrawing {
        let timestamp = CACurrentMediaTime()
        var resolved = value
        if let reveal = reveal {
            let result = reveal.value(at: timestamp, target: value)
            resolved = result.value
            if result.isCompleted { self.reveal = nil }
        }
        return TiebaStatusCheckDrawing(transitionFraction: transitionFraction, value: resolved, appearance: appearance)
    }
}

// MARK: - 图标

/// 图标快照。template 图按前景色染，original 图（调用方自己带色）原样画。
///
/// 这里**故意不用** CGContext.clip(to:mask:) 直接画 CGImage（上游走的是那条路：先 scaleBy(1, -1)
/// 把坐标系翻过来，再 clip + fill）：CGContext 原点在左下、y 轴向上，而 CGImage 的像素行是从上往下存的，
/// 不翻 y 就会上下颠倒——这是 CoreGraphics 最经典的坑，上游用一次"翻转-裁剪-填充"绕开它。
/// 本移植改成 UIImage.draw(in:)：UIKit 已经把 orientation 吃掉了，同样的活少一次坐标系变换，
/// 少一个出错点。代价是失去 clip 的裁切能力——但图标按自身尺寸居中绘制，本来就不需要裁。
struct TiebaStatusIconDrawing: TiebaStatusDrawing {
    let image: UIImage?
    let isTemplate: Bool
    let transitionFraction: CGFloat

    func draw(in context: CGContext, size: CGSize, foregroundColor: UIColor) {
        guard let image = image else { return }
        let side = min(size.width, size.height) * 0.62
        let rect = CGRect(
            x: (size.width - side) / 2,
            y: (size.height - side) / 2,
            width: side,
            height: side)
        context.saveGState()
        // 透明度走 CGContext：UIImage 没有 withAlphaComponent，而模板图染色后再取 alpha 会丢动态色。
        context.setAlpha(transitionFraction)
        // 随过渡从 1% 缩到 100%（上游 IconContext 同款）：**只淡入不缩放，图标会像"凭空出现"**；
        // 缩放的锚点必须是画布中心，所以先平移到中心、缩放、再平移回去——直接 scaleBy 会以左下角为锚，
        // 图标会从角落飞进来。
        let transitionScale = max(0.01, transitionFraction)
        context.translateBy(x: size.width / 2, y: size.height / 2)
        context.scaleBy(x: transitionScale, y: transitionScale)
        context.translateBy(x: -size.width / 2, y: -size.height / 2)
        if isTemplate {
            image
                .withTintColor(foregroundColor, renderingMode: .alwaysOriginal)
                .draw(in: rect)
        } else {
            image.draw(in: rect)
        }
        context.restoreGState()
    }
}

/// 演算：图标是静止的（不需要按帧重算），过渡由节点的 transitionFraction 负责。
@MainActor
final class TiebaStatusIconContext: TiebaStatusContext {
    let icon: TiebaStatusIcon
    private let image: UIImage?
    private let isTemplate: Bool

    var isAnimating: Bool { false }

    init(icon: TiebaStatusIcon) {
        self.icon = icon
        switch icon {
        case .none:
            self.image = nil
            self.isTemplate = true
        // 上游的 download/play/pause 是它自己播放器/下载的业务图标，本仓不搬这三个 case：
        case .systemImage(let name):
            self.image = UIImage(systemName: name)
            self.isTemplate = true
        case .image(let image):
            // 调用方给的图当原图用：它多半自带颜色，强行染色会改语义
            self.image = image
            self.isTemplate = image.renderingMode == .alwaysTemplate
        }
    }

    func drawingState(transitionFraction: CGFloat) -> TiebaStatusDrawing {
        TiebaStatusIconDrawing(image: image, isTemplate: isTemplate, transitionFraction: transitionFraction)
    }
}

// MARK: - 状态 → Context

extension TiebaStatusState {
    /// **状态机只描述画什么**：映射规则全在这一处。同状态复用同一 Context，动画进度不会被打回 0。
    @MainActor
    func makeContext(current: TiebaStatusContext?) -> TiebaStatusContext {
        switch self {
        case .none:
            if let current = current as? TiebaStatusIconContext { return current }
            return TiebaStatusIconContext(icon: .none)
        case .icon(let icon):
            if let current = current as? TiebaStatusIconContext, current.icon == icon { return current }
            // 图标不同就换新 Context：本移植靠节点的过渡淡入淡出，不做路径形变（见文件头改动 4）。
            return TiebaStatusIconContext(icon: icon)
        case .check(let appearance):
            if let current = current as? TiebaStatusCheckContext { return current }
            return TiebaStatusCheckContext(appearance: appearance)
        case .progress(let value, let cancelEnabled, let appearance, let animateRotation):
            // 只有 cancelEnabled 变化才换 Context —— 与上游判定一致（× 的有无是结构性差异）。
            if let current = current as? TiebaStatusProgressContext, current.displayCancel == cancelEnabled {
                current.updateValue(value)
                return current
            }
            return TiebaStatusProgressContext(
                value: value, displayCancel: cancelEnabled, appearance: appearance, animateRotation: animateRotation)
        }
    }
}

#if DEBUG
    extension TiebaStatusState {
        /// 自检：状态→Context 的映射不变式（不需要视图，纯映射逻辑）。
        /// **当前无人调用**（本轮不接线），验收时手工跑。
        @MainActor
        static func debugSelfCheck() {
            let start = TiebaStatusState.progress(value: 0.1, cancelEnabled: false, appearance: nil, animateRotation: false)
            let first = start.makeContext(current: nil)
            let second = TiebaStatusState.progress(value: 0.9, cancelEnabled: false, appearance: nil, animateRotation: false)
                .makeContext(current: first)
            assert(first === second, "同 cancelEnabled 的进度状态必须复用 Context（否则动画被打回 0）")
            // 值 0.1→0.9 是"真实变化"，必须起一段插值（不能直接跳到 0.9）
            assert(first.isAnimating, "进度值变化要起插值");
            // 而一个静止的确定进度不该常驻按帧（上游这里恒 true，本移植按真实需要返回）
            let idle = TiebaStatusState.progress(value: 0.5, cancelEnabled: false, appearance: nil, animateRotation: false)
                .makeContext(current: nil)
            assert(!idle.isAnimating, "确定进度、无插值时不该常驻按帧")

            let cancelled = TiebaStatusState.progress(value: 0.9, cancelEnabled: true, appearance: nil, animateRotation: false)
                .makeContext(current: second)
            assert(cancelled !== second, "cancelEnabled 变了是结构性差异，必须换 Context")

            let spinning = TiebaStatusState.progress(value: nil, cancelEnabled: false, appearance: nil, animateRotation: true)
                .makeContext(current: nil)
            assert(spinning.isAnimating, "不确定进度要一直转")

            let iconFirst = TiebaStatusState.icon(.systemImage("play.fill")).makeContext(current: nil)
            let iconSame = TiebaStatusState.icon(.systemImage("play.fill")).makeContext(current: iconFirst)
            assert(iconFirst === iconSame, "同图标复用 Context")
            let iconOther = TiebaStatusState.icon(.systemImage("pause.fill")).makeContext(current: iconSame)
            assert(iconOther !== iconSame, "换图标换 Context（过渡由节点负责）")

            let check = TiebaStatusState.check(appearance: nil).makeContext(current: nil)
            assert(check.isAnimating, "勾选一出现就在描边，要按帧")
            let checkDrawing = check.drawingState(transitionFraction: 1)
            assert(checkDrawing is TiebaStatusCheckDrawing)

            let iconDrawing = TiebaStatusIconContext(icon: .systemImage("play.fill")).drawingState(transitionFraction: 1)
            assert((iconDrawing as? TiebaStatusIconDrawing)?.image != nil, "SF Symbol 名要能解析成图")
            let emptyDrawing = TiebaStatusIconContext(icon: .none).drawingState(transitionFraction: 1)
            assert((emptyDrawing as? TiebaStatusIconDrawing)?.image == nil)

            // 进度插值：0.2s 线性；走完后 isCompleted
            let transition = TiebaStatusProgressTransition(beginTime: 100, initialValue: 0)
            assert(transition.value(at: 100, target: 1).value == 0)
            assert(abs(transition.value(at: 100.1, target: 1).value - 0.5) < 0.0001)
            assert(transition.value(at: 100.2, target: 1).isCompleted)
        }
    }
#endif
