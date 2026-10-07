// TiebaGlassTouchEffect —— 玻璃的"被捏"形变模型 + 只观察不干扰的触摸手势。
//
// 移植自上游 submodules/GlassBackgroundComponent/Sources/TouchEffect.swift
//   （352 行）。报告 37 A3（形变模型）/ A4（手势模板 + 双弹簧）。
//
// ## A3：为什么是 sublayerTransform，而不是 transform / scale
//   ① 基础态：整体**等比放大一个固定 pt 量**（pressedSizeIncrease = 20），缩放比 = 1 + 20 / min(宽, 高)
//      （:195-201）——"膨胀的绝对量恒定"，小按钮比例大、大面板比例小；普通 scale 做不到这件事。
//   ② 拖动时：位移向量先按**宽高比校正**（adjustedX = x / aspectRatio，:212）—— sublayerTransform
//      在非方形视图上会各向异性失真，不校正就会"往斜里扯"；归一化后按主轴方向
//      **一边拉长、另一边等量压扁**（m11 *= (1 + t·diff) 且 m22 *= 1/(1 + t·diff)，:228-244），
//      面积近似守恒 —— 这就是"液态"而不是"橡皮筋"的区别。
//   ③ 形变幅度用**饱和函数**封顶：k = 1 - 1/((length/viewHeight)/(5·aspectRatio) + 1)（:223），
//      拖得再远也不会超过 1；位移上限 maxOffset = 24（:226）。
//   ④ 动的是 **view.layer.sublayerTransform**（:293/:301/:311）：玻璃的 backdrop 模糊层不会被缩放，
//      只有内容层被捏 —— 否则会"糊上加糊"。
//
// ## A4：两套弹簧 + 纯观察者手势
//   · liftOn（按下）= mass 1.36 / stiffness 568 / damping 39.7：硬而快、几乎不过冲（跟手优先）；
//   · liftOff（松开）= mass 2.0 / stiffness 460 / damping 21.8：软、低阻尼、有回弹（情绪优先）。
//     参数按**状态迁移方向**选（:247-256），不是按"当前是否按下"。
//   · 手势 must-not-compete：canPrevent/canBePrevented 均 false + shouldRecognizeSimultaneously true
//     + cancelsTouchesInView/delaysTouchesBegan/delaysTouchesEnded 三个 false（:20-37）
//     —— 玻璃的触摸反馈必须与它上面的按钮、外层的滚动手势**同时**工作，绝不把触摸从别人手里抢走。
//     状态对象与一次触摸同生命周期：每次 touchesBegan 新建，end/cancel/reset 置 nil（:39-75）。
//   · 径向高亮挂在**外层容器**上（:173-180），这样按钮自己的圆角裁剪不会切掉高亮。
//     出现 0.12s .easeOut、消失 0.22s .easeInEaseOut（出现比消失快）、baseAlpha 0.1（:258-282）。
//
// 本仓差异：
//   1. 上游 highlightContainerView 的坐标直接用触摸点；这里先把点**夹进容器的圆角矩形内**
//      （TiebaRoundedRectGeometry.contains / nearestBoundaryPoint，报告 37 B3 的两个几何函数）——
//      胶囊的圆角处如果直接落点，径向高光的 300pt 圆会明显溢出玻璃形状。
//   2. 上游 TouchEffect 与手势耦合在一个文件里（GlassHighlightGestureRecognizer 持有 TouchEffect）；
//      这里保持同一结构，只改名为 Tieba 前缀。
//
// 并发：UIView/CALayer 层，整类 @MainActor。

import QuartzCore
import UIKit

/// A3 的形变模型（上游 TouchEffect）。
@MainActor
final class TiebaGlassTouchEffect {
    struct SpringParameters {
        var mass: CGFloat
        var stiffness: CGFloat
        var damping: CGFloat
        var initialVelocity: CGFloat
    }

    struct Parameters {
        /// 按下：硬而快（跟手优先）。
        var liftOn = SpringParameters(mass: 1.36, stiffness: 568.0, damping: 39.7, initialVelocity: 0.0)
        /// 松开：软、低阻尼（回弹）。
        var liftOff = SpringParameters(mass: 2.0, stiffness: 460.0, damping: 21.8, initialVelocity: 0.0)
        /// 按下时"膨胀的绝对量"（pt）：小按钮比例大、大面板比例小。
        var pressedSizeIncrease: CGFloat = 20.0
    }

    private struct State: Equatable {
        var isTracking: Bool
        var stretchVector: CGPoint
        var touchLocation: CGPoint?
    }

    private weak var view: UIView?
    private weak var highlightContainerView: UIView?
    private var state = State(isTracking: false, stretchVector: .zero, touchLocation: nil)
    private var appliedState: State?
    var parameters = Parameters()

    private let radialHighlightLayer: CAGradientLayer = {
        let layer = CAGradientLayer()
        layer.type = .radial
        let baseGradientAlpha: CGFloat = 0.5
        let numSteps = 8
        let firstStep = 1
        let firstLocation: CGFloat = 0.5
        let colors = (0 ..< numSteps).map { index -> UIColor in
            if index < firstStep {
                return UIColor(white: 1.0, alpha: 1.0)
            }
            let step: CGFloat = CGFloat(index - firstStep) / CGFloat(numSteps - firstStep - 1)
            let value: CGFloat = 1.0 - TiebaSpring.bezierPoint(0.42, 0.0, 0.58, 1.0, step)
            return UIColor(white: 1.0, alpha: baseGradientAlpha * value)
        }
        let locations = (0 ..< numSteps).map { index -> CGFloat in
            if index < firstStep {
                return 0.0
            }
            let step: CGFloat = CGFloat(index - firstStep) / CGFloat(numSteps - firstStep - 1)
            return firstLocation + (1.0 - firstLocation) * step
        }
        layer.colors = colors.map(\.cgColor)
        layer.locations = locations.map { $0 as NSNumber }
        layer.startPoint = CGPoint(x: 0.5, y: 0.5)
        layer.endPoint = CGPoint(x: 1.0, y: 1.0)
        layer.opacity = 0.0
        layer.actions = ["position": NSNull(), "bounds": NSNull(), "opacity": NSNull()]
        return layer
    }()

    init(view: UIView, highlightContainerView: UIView?) {
        self.view = view
        self.highlightContainerView = highlightContainerView
        if let highlightContainerView {
            highlightContainerView.layer.addSublayer(self.radialHighlightLayer)
        }
    }

    // Swift 6：nonisolated deinit 不许读 @MainActor 存储属性；isolated deinit 是编译器给的正式写法
    //（本仓先例：UI/Drawing/TiebaPortalSourceView 的 isolated deinit）。
    isolated deinit {
        self.radialHighlightLayer.removeFromSuperlayer()
    }

    // MARK: 状态输入

    func setIsTracking(_ value: Bool, animated: Bool = true) {
        self.state.isTracking = value
        if !value {
            self.state.stretchVector = .zero
        }
        self.applyCurrentTransform(animated: animated)
    }

    func setStretchVector(_ value: CGPoint, animated: Bool) {
        self.state.stretchVector = value
        self.applyCurrentTransform(animated: animated)
    }

    func setTouchLocation(_ value: CGPoint, animated: Bool) {
        self.state.touchLocation = self.clampedHighlightLocation(value)
        self.applyCurrentTransform(animated: animated)
    }

    func setParameters(_ parameters: Parameters, animated: Bool = false) {
        self.parameters = parameters
        self.applyCurrentTransform(animated: animated)
    }

    // MARK: 形变

    /// B3 落点：把触摸点夹进高亮容器的圆角矩形内（胶囊：半径 = 高的一半）。
    private func clampedHighlightLocation(_ point: CGPoint) -> CGPoint {
        guard let container = self.highlightContainerView, container.bounds.width > 0.0, container.bounds.height > 0.0 else {
            return point
        }
        let center = CGPoint(x: container.bounds.midX, y: container.bounds.midY)
        let radius = min(container.bounds.width, container.bounds.height) * 0.5
        if TiebaRoundedRectGeometry.contains(point, rectCenter: center, rectSize: container.bounds.size, cornerRadius: radius) {
            return point
        }
        return TiebaRoundedRectGeometry.nearestBoundaryPoint(
            to: point,
            rectCenter: center,
            rectSize: container.bounds.size,
            cornerRadius: radius
        )
    }

    private func currentTransform(for state: State, view: UIView) -> CATransform3D {
        let referenceView = self.highlightContainerView ?? view
        let viewWidth = max(1.0, referenceView.bounds.width)
        let viewHeight = max(1.0, referenceView.bounds.height)
        let aspectRatio = viewWidth / viewHeight

        let baseScaleX: CGFloat
        let baseScaleY: CGFloat
        if state.isTracking {
            if viewWidth < viewHeight {
                baseScaleY = 1.0 + self.parameters.pressedSizeIncrease / viewHeight
                baseScaleX = baseScaleY
            } else {
                baseScaleX = 1.0 + self.parameters.pressedSizeIncrease / viewWidth
                baseScaleY = baseScaleX
            }
        } else {
            baseScaleX = 1.0
            baseScaleY = 1.0
        }

        guard state.isTracking else {
            return CATransform3DScale(CATransform3DIdentity, baseScaleX, baseScaleY, 1.0)
        }

        let stretchVector = state.stretchVector
        let adjustedX = stretchVector.x / aspectRatio
        let length = sqrt(pow(adjustedX, 2) + pow(stretchVector.y, 2))
        guard length != 0.0 else {
            return CATransform3DScale(CATransform3DIdentity, baseScaleX, baseScaleY, 1.0)
        }

        let normal = CGPoint(x: adjustedX / length, y: stretchVector.y / length)
        // 饱和函数：拖得再远也不超过 1。
        let k: CGFloat = -1.0 / ((length / viewHeight) / (5.0 * aspectRatio) + 1.0) + 1.0
        let additionalMaxScale = (viewHeight + 16.0 / aspectRatio) / viewHeight - 1.0
        let t = additionalMaxScale * k * aspectRatio
        let maxOffset: CGFloat = 24.0

        // 一边拉长、另一边等量压扁（面积近似守恒）。
        if abs(normal.x) > abs(normal.y) {
            let diff = abs(normal.x) - abs(normal.y)
            var transform = CATransform3DIdentity
            transform.m11 = baseScaleX * (1.0 + t * diff)
            transform.m22 = baseScaleY * (1.0 / (1.0 + t * diff))
            transform.m41 = normal.x * maxOffset * k
            transform.m42 = normal.y * maxOffset * k
            return transform
        } else {
            let diff = abs(normal.y) - abs(normal.x)
            var transform = CATransform3DIdentity
            transform.m11 = baseScaleX * (1.0 / (1.0 + t * diff))
            transform.m22 = baseScaleY * (1.0 + t * diff)
            transform.m41 = normal.x * maxOffset * k
            transform.m42 = normal.y * maxOffset * k
            return transform
        }
    }

    /// 双弹簧：按**状态迁移方向**选参数（按下用 liftOn，松开用 liftOff）。
    private func currentSpringParameters(from previousState: State?, to state: State) -> SpringParameters {
        guard let previousState, previousState != state else {
            return state.isTracking ? self.parameters.liftOn : self.parameters.liftOff
        }
        if !previousState.isTracking && state.isTracking {
            return self.parameters.liftOn
        } else {
            return self.parameters.liftOff
        }
    }

    private func updateRadialHighlight(animated: Bool) {
        guard self.highlightContainerView != nil else {
            return
        }
        let baseAlpha: Float = 0.1
        let targetOpacity: Float = self.state.isTracking ? baseAlpha : 0.0
        let size = CGSize(width: 300.0, height: 300.0)
        if let touchLocation = self.state.touchLocation {
            self.radialHighlightLayer.bounds = CGRect(origin: CGPoint(), size: size)
            self.radialHighlightLayer.position = touchLocation
        }
        if animated {
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = self.radialHighlightLayer.presentation()?.opacity ?? self.radialHighlightLayer.opacity
            self.radialHighlightLayer.opacity = targetOpacity
            animation.toValue = targetOpacity
            // 出现 0.12s（easeOut）比消失 0.22s（easeInEaseOut）快 —— 不对称是手感的关键。
            animation.duration = self.state.isTracking ? 0.12 : 0.22
            animation.timingFunction = CAMediaTimingFunction(name: self.state.isTracking ? .easeOut : .easeInEaseOut)
            self.radialHighlightLayer.add(animation, forKey: "opacity")
        } else {
            self.radialHighlightLayer.opacity = targetOpacity
        }
    }

    func applyCurrentTransform(animated: Bool = true) {
        guard let view = self.view else {
            return
        }
        let targetTransform = self.currentTransform(for: self.state, view: view)

        if !animated {
            view.layer.removeAnimation(forKey: "sublayerTransform")
            view.layer.sublayerTransform = targetTransform
            self.updateRadialHighlight(animated: false)
            self.appliedState = self.state
            return
        }

        let springParameters = self.currentSpringParameters(from: self.appliedState, to: self.state)
        let animation = CASpringAnimation(keyPath: "sublayerTransform")
        // 起播值必须取 presentation()：否则打断时的形变会从模型值跳一下。
        animation.fromValue = NSValue(caTransform3D: view.layer.presentation()?.sublayerTransform ?? view.layer.sublayerTransform)
        animation.toValue = NSValue(caTransform3D: targetTransform)
        animation.mass = springParameters.mass
        animation.stiffness = springParameters.stiffness
        animation.damping = springParameters.damping
        animation.initialVelocity = springParameters.initialVelocity
        animation.duration = animation.settlingDuration
        animation.fillMode = .both
        animation.isRemovedOnCompletion = false

        view.layer.sublayerTransform = targetTransform
        view.layer.add(animation, forKey: "sublayerTransform")
        self.updateRadialHighlight(animated: true)
        self.appliedState = self.state
    }
}

/// A4：**纯观察者**触摸手势。它自己不产生任何行为，只把一次触摸的生命周期翻译成形变。
///
/// 三连（上游 TouchEffect.swift:27-37、:20-24）：
///   canPrevent = false / canBePrevented = false / shouldRecognizeSimultaneously = true
///   cancelsTouchesInView = false / delaysTouchesBegan = false / delaysTouchesEnded = false
/// 外加 requiresExclusiveTouchType = false。
/// 目的：玻璃的触摸反馈与它上面的按钮、外层的滚动手势**同时**工作，绝不把触摸从别人手里抢走。
final class TiebaObservingGlassGestureRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    /// 形变作用在哪个视图上（默认 = 手势挂载的视图）。
    weak var touchEffectView: UIView?
    /// 径向高亮的宿主：**外层容器**，这样按钮自己的圆角裁剪不会切掉高亮（上游 :173-180）。
    weak var highlightContainerView: UIView?

    private var touchEffect: TiebaGlassTouchEffect?
    private var initialTouchLocation: CGPoint?
    /// 形变参数（默认 = 上游双弹簧 + 20pt 膨胀）。
    var parameters = TiebaGlassTouchEffect.Parameters()

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        self.delegate = self
        self.cancelsTouchesInView = false
        self.delaysTouchesBegan = false
        self.delaysTouchesEnded = false
        self.requiresExclusiveTouchType = false
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
        return false
    }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
        return false
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }

    /// 状态对象与一次触摸同生命周期（上游 :39-75）。
    override func reset() {
        if let touchEffect = self.touchEffect {
            touchEffect.setIsTracking(false)
        }
        self.touchEffect = nil
        self.initialTouchLocation = nil
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let view = self.touchEffectView ?? self.view, let touch = touches.first else {
            return
        }
        let touchEffect = TiebaGlassTouchEffect(view: view, highlightContainerView: self.highlightContainerView)
        touchEffect.setParameters(self.parameters, animated: false)
        if let highlightContainerView = self.highlightContainerView {
            touchEffect.setTouchLocation(touch.location(in: highlightContainerView), animated: false)
        }
        touchEffect.setStretchVector(.zero, animated: false)
        self.touchEffect = touchEffect
        self.initialTouchLocation = touch.location(in: view)
        touchEffect.setIsTracking(true)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touchEffect = self.touchEffect,
              let view = self.touchEffectView ?? self.view,
              let touch = touches.first,
              let initialTouchLocation = self.initialTouchLocation else {
            return
        }
        let touchLocation = touch.location(in: view)
        if let highlightContainerView = self.highlightContainerView {
            touchEffect.setTouchLocation(touch.location(in: highlightContainerView), animated: false)
        }
        touchEffect.setStretchVector(
            CGPoint(x: touchLocation.x - initialTouchLocation.x, y: touchLocation.y - initialTouchLocation.y),
            animated: false
        )
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        self.touchEffect?.setIsTracking(false)
        self.touchEffect = nil
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        self.touchEffect?.setIsTracking(false)
        self.touchEffect = nil
    }
}
