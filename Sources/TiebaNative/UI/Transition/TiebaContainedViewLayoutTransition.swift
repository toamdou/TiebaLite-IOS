// 移植自上游 submodules/Display/Source/ContainedViewLayoutTransition.swift（上游 2,853 行）
//
// 这是报告 11 §1.5 判定的「本模块性价比第一」的转场引擎：把一次视图/图层布局变化写成
// UIView 动画或 CA 动画（.immediate / .animated(duration:curve:)），另外带两个「皇冠」部件——
//   * 上游 :2033-2343 的 9 种 AnyValueProviding 插值（含 CA 本身不提供的 CGColor 逐分量、
//     CGPath 逐元素插值）：**判据③必留** —— CoreAnimation 不能插值 CGPath（没有 path 插值器），
//     CGColor 的逐分量混合与 CATransform3D 的 16 分量也只能自己做；
//   * 上游 :2344-2853 的 ControlledTransition（可中断 / 可拖拽 / **可合并**的转场引擎）：
//     保留（判据①/③）—— UIViewPropertyAnimator 能中断与反向，但**不能把两条在飞转场合并**
//     （merge），而交互式转场（拖到一半改方向、两次转场叠加）正需要这个能力。
//     NativeAnimator 用 CABasicAnimation(speed=0) 逐帧写值，LegacyAnimator 退化成普通 UIView 动画。
//
// 改动（逐条编号，均相对上游）：
//   1. 删除 30 个 node: ASDisplayNode 重载（上游 :165-188 / :219-253 / :307-323 / :343-361 / :383-409 /
//      :439-... / :643 / :658 / :677 / :703 / :778 / :787 / :796 / :829 / :847 / :965 / :1029 / :1091 /
//      :1228 / :1261 / :1351 / :1355 / :1392 / :1451 / :1460 / :1537 / :1546 / :1594 / :1664 / :1936）。
//      每个 node: 版都有等价的 view:/layer: 版（node 只是把 layer/frame 转发出去），删掉不丢语义。
//   2. import AsyncDisplayKit / import ObjCRuntimeUtils（上游 :3-4）删除：前者只服务于 ASDisplayNode，
//      后者是空 import。现在本文件只依赖 UIKit / QuartzCore / Foundation。
//   3. ASIsCGRectValidForLayout / ASIsCGPositionValidForLayout（上游 :112-115）逐行翻译成文件私有函数
//      （源出 AsyncDisplayKit 的 ASDimension.h 内联函数），不再引入 AS* 符号。
//   4. 公开类型统一加 Tieba 前缀（ContainedViewLayoutTransition(Curve) / CombinedTransition /
//      ControlledTransition(Animator/Property) / AnyValueProviding → TiebaTransitionValueProviding）。
//      系统类型上的扩展成员也一并改名，因为本仓多个目录同样在移植上游 Display，同模块撞名的代价是
//      **整个 app 构建不过**（BUILD 的 srcs 是 glob）：CGRect.center → 文件私有 tiebaTransitionCenter、
//      CGRect.ensuredValid → tiebaEnsuredValid、协议成员 anyValue/interpolate(with:fraction:) →
//      tiebaAnyValue/tiebaInterpolate(with:fraction:)（后者与上游 Interpolatable 完全同名同签名）。
//   5. **CALayer 动画工厂不再自带副本**（判据②：同一上游文件不留两份实现）：本文件所有 animate* /
//      makeAnimation 调用都改调本仓既有件 UI/Components/TiebaCAAnimationUtils.swift
//      （同一上游 CAAnimationUtils.swift 的移植件，符号已 public），本文件只保留「曲线 → 两套 timingFunction」
//      的便捷层 animateCurve。曲线数学（bezier / 两条 ease / spring 解析解）收在同目录
//      TiebaTransitionSupport.swift，消费者还包括 UI/Components/Flow/*。
//   6. Swift 6 严格并发（本批代码里唯一需要动隔离的地方）：
//      a) Curve / Transition 两个叶子枚举的载荷全是 CGFloat/Double，声明真 Sendable —— 它们要穿过
//         UIView.animate / CALayer 动画闭包这些 @Sendable 边界；
//      b) 所有会改 UIView / CALayer 模型值的公开入口标 @MainActor（上游靠「只在主线程调」的口头约定，
//         Swift 6 把这条约定写进类型系统）。CALayer 自身在 SDK 里是非隔离的，所以内部辅助方法保持
//         nonisolated：隔离边界只画在「改视图状态」这一层；
//      c) TiebaControlledTransitionProperty 持有 CALayer 并在 deinit 里摘动画，整类标 @MainActor 后用
//         Swift 6.2 的 isolated deinit（Swift 6.4 实测可用）解决「nonisolated deinit 不能访问非 Sendable
//         存储属性」。不降级 swift 版本、不用 nonisolated(unsafe) / @unchecked Sendable / @preconcurrency。
//      d) 全文件零绕过。
//   7. 本仓从设计上不做容器布局动画，所以这批代码**当前没有调用方**，是用户点名保留的
//      「UIKit 经验学习」资产（报告 11 §1.5 的 P0.5）。转场相关的接线（更新弹窗/Splash/头像高亮）
//      已按判据三问回滚为系统 API，本目录只作为教材与能力储备。

import Foundation
import UIKit

// [移植] 改动 3：下面三个函数逐行翻译自 AsyncDisplayKit/Source/PublicHeaders/AsyncDisplayKit/ASDimension.h
//   ASPointsValidForLayout(p)             = (isnormal(p) || p == 0.0) && p >= 0.0 && p < CGFLOAT_MAX / 2.0
//   ASIsCGSizeValidForLayout(s)           = ASPointsValidForLayout(s.width) && ASPointsValidForLayout(s.height)
//   ASIsCGPositionPointsValidForLayout(p) = (isnormal(p) || p == 0.0) && p < 10000000.0
//   ASIsCGPositionValidForLayout(pt)      = ASIsCGPositionPointsValidForLayout(pt.x) && ...(pt.y)
//   ASIsCGRectValidForLayout(r)           = ASIsCGPositionValidForLayout(r.origin) && ASIsCGSizeValidForLayout(r.size)
// 用等价的 Swift 实现替换，不再引入 AS* 符号（private，仅本文件可见）。
private func tiebaTransitionIsCGSizeValidForLayout(_ size: CGSize) -> Bool {
    return (size.width.isNormal || size.width == 0.0) && size.width >= 0.0 && size.width < CGFloat.greatestFiniteMagnitude / 2.0
        && (size.height.isNormal || size.height == 0.0) && size.height >= 0.0 && size.height < CGFloat.greatestFiniteMagnitude / 2.0
}

private func tiebaTransitionIsCGPositionValidForLayout(_ point: CGPoint) -> Bool {
    return ((point.x.isNormal || point.x == 0.0) && point.x < 10000000.0)
        && ((point.y.isNormal || point.y == 0.0) && point.y < 10000000.0)
}

private func tiebaTransitionIsCGRectValidForLayout(_ rect: CGRect) -> Bool {
    return tiebaTransitionIsCGPositionValidForLayout(rect.origin) && tiebaTransitionIsCGSizeValidForLayout(rect.size)
}

// [移植] 改动 4：上游是 extension CGRect { var center }（internal）。这里改名并收成文件私有：
// 本仓 UI/Components、UI/Nodes 等目录同样在移植 Display，同模块再声明一个 CGRect.center
// 就是重复定义（整个 app 构建不过）。
// 放宽为 internal（拆分后 TiebaControlledTransition.swift 也要用它换算中心点）：
// 这是本扩展唯一被跨文件引用的成员，故只放宽这一处（35 号文档 §4 的纪律）。
extension CGRect {
    var tiebaTransitionCenter: CGPoint {
        return CGPoint(x: self.midX, y: self.midY)
    }
}

// [移植] Swift 6：转场参数要跨隔离域传进 @MainActor 的 UIView 动画调用，声明真 Sendable（纯值枚举：
// 载荷全是 CGFloat/Float），从而无需给每个调用方加隔离标注。
public enum TiebaContainedViewLayoutTransitionCurve: Equatable, Hashable, Sendable {
    case linear
    case easeInOut
    case easeIn
    case spring
    case customSpring(mass: CGFloat = 5.0, stiffness: CGFloat = 900.0, damping: CGFloat, initialVelocity: CGFloat)
    case custom(Float, Float, Float, Float)
}

public extension TiebaContainedViewLayoutTransitionCurve {
}

public extension TiebaContainedViewLayoutTransitionCurve {
    var timingFunction: String {
        switch self {
            case .linear:
                return CAMediaTimingFunctionName.linear.rawValue
            case .easeInOut:
                return CAMediaTimingFunctionName.easeInEaseOut.rawValue
            case .easeIn:
                return CAMediaTimingFunctionName.easeIn.rawValue
            case .spring:
                return tiebaCAMediaTimingFunctionSpring
            case let .customSpring(mass, stiffness, damping, initialVelocity):
                return "\(tiebaCAMediaTimingFunctionCustomSpringPrefix)_\(mass)_\(stiffness)_\(damping)_\(initialVelocity)"
            case .custom:
                return CAMediaTimingFunctionName.easeInEaseOut.rawValue
        }
    }
    
    var mediaTimingFunction: CAMediaTimingFunction? {
        switch self {
            case .linear:
                return nil
            case .easeInOut:
                return nil
            case .easeIn:
                return nil
            case .spring:
                return nil
            case .customSpring:
                return nil
            case let .custom(p1, p2, p3, p4):
                return CAMediaTimingFunction(controlPoints: p1, p2, p3, p4)
        }
    }
    
    var viewAnimationOptions: UIView.AnimationOptions {
        switch self {
            case .linear:
                return [.curveLinear]
            case .easeInOut:
                return [.curveEaseInOut]
            case .easeIn:
                return [.curveEaseIn]
            case .spring:
                return UIView.AnimationOptions(rawValue: 7 << 16)
            case .customSpring:
                return UIView.AnimationOptions(rawValue: 7 << 16)
            case .custom:
                return []
        }
    }
}

// [移植] Swift 6：同上，纯值枚举（.immediate / .animated(duration:curve:)），声明真 Sendable。
public enum TiebaContainedViewLayoutTransition: Sendable {
    case immediate
    case animated(duration: Double, curve: TiebaContainedViewLayoutTransitionCurve)
    
    public var isAnimated: Bool {
        if case .immediate = self {
            return false
        } else {
            return true
        }
    }
}

public extension CGRect {
}

// [移植] 曲线版便捷入口（上游 private extension CALayer 里的
// animate(from:to:keyPath:duration:delay:curve:)）：它只是把「曲线 → timingFunction + mediaTimingFunction」
// 这一步收口，真正的动画工厂在本仓 UI/Components/TiebaCAAnimationUtils.swift（同一上游文件的既有移植件）。
// 名字里的 Curve 后缀是为了不与那个公开的 animate(from:to:keyPath:timingFunction:...) 撞签名。
private extension CALayer {
    func animateCurve(from: AnyObject, to: AnyObject, keyPath: String, duration: Double, delay: Double, curve: TiebaContainedViewLayoutTransitionCurve, removeOnCompletion: Bool, additive: Bool, completion: ((Bool) -> Void)? = nil) {
        let timingFunction: String
        let mediaTimingFunction: CAMediaTimingFunction?
        switch curve {
        case .spring, .customSpring:
            timingFunction = curve.timingFunction
            mediaTimingFunction = nil
        default:
            timingFunction = CAMediaTimingFunctionName.easeInEaseOut.rawValue
            mediaTimingFunction = curve.mediaTimingFunction
        }
        
        self.animate(
            from: from,
            to: to,
            keyPath: keyPath,
            timingFunction: timingFunction,
            duration: duration,
            delay: delay,
            mediaTimingFunction: mediaTimingFunction,
            removeOnCompletion: removeOnCompletion,
            additive: additive,
            completion: completion
        )
    }
}

private func bounceParameters(duration: Double) -> (duration: Double, damping: CGFloat, stiffness: CGFloat) {
    return (duration: duration * 1.25, damping: 88.0, stiffness: 750.0)
}

// MARK: - 转场：视图 / 图层入口
// [移植] 改动 6b：下面所有入口都会改 UIView / CALayer 的模型值，统一 @MainActor。
// 上游没有隔离标注（只靠「在主线程调」的口头约定），Swift 6 下不加就是数据竞争。
@MainActor
public extension TiebaContainedViewLayoutTransition {
    /// 弹簧转场：时长取这颗弹簧**自己的 settlingDuration**，速度系数因此为 1。
    ///
    /// 为什么要这个工厂：转场引擎会按 speed = settlingDuration / duration 归一化弹簧速度
    ///（见 TiebaCAAnimationUtils.makeAnimation 的 customSpring 分支）—— 想拿到"和裸
    /// CASpringAnimation 逐帧一样"的弹簧，duration 必须等于同一颗弹簧的 settlingDuration；
    /// 随便传一个时长会让整段弹簧变快或变慢（这是接入时最容易踩的坑）。
    /// settlingDuration 由系统算（公开 API），不自己估。
    static func spring(mass: CGFloat, stiffness: CGFloat, damping: CGFloat, initialVelocity: CGFloat) -> TiebaContainedViewLayoutTransition {
        let probe = CASpringAnimation(keyPath: "position")
        probe.mass = mass
        probe.stiffness = stiffness
        probe.damping = damping
        probe.initialVelocity = initialVelocity
        return .animated(
            duration: probe.settlingDuration,
            curve: .customSpring(mass: mass, stiffness: stiffness, damping: damping, initialVelocity: initialVelocity)
        )
    }

    func animation() -> CABasicAnimation? {
        switch self {
        case .immediate:
            return nil
        case let .animated(duration, curve):
            let animation = CALayer().makeAnimation(from: 0.0 as NSNumber, to: 1.0 as NSNumber, keyPath: "position", timingFunction: curve.timingFunction, duration: duration, delay: 0.0, mediaTimingFunction: curve.mediaTimingFunction, removeOnCompletion: false, additive: false, completion: { _ in })
            return animation as? CABasicAnimation
        }
    }
    
    
    
    func updateFrameAdditive(layer: CALayer, frame: CGRect, force: Bool = false, completion: ((Bool) -> Void)? = nil) {
        if layer.frame.equalTo(frame) && !force {
            completion?(true)
        } else {
            switch self {
            case .immediate:
                layer.frame = frame
                if let completion = completion {
                    completion(true)
                }
            case .animated:
                let previousFrame = layer.frame
                layer.frame = frame
                self.animatePositionAdditive(layer: layer, offset: CGPoint(x: previousFrame.minX - frame.minX, y: previousFrame.minY - frame.minY))
            }
        }
    }
    
    
    func updateFrameAdditive(view: UIView, frame: CGRect, force: Bool = false, completion: ((Bool) -> Void)? = nil) {
        if view.frame.equalTo(frame) && !force {
            completion?(true)
        } else {
            switch self {
            case .immediate:
                view.frame = frame
                if let completion = completion {
                    completion(true)
                }
            case .animated:
                let previousFrame = view.frame
                view.frame = frame
                self.animatePositionAdditive(layer: view.layer, offset: CGPoint(x: previousFrame.minX - frame.minX, y: previousFrame.minY - frame.minY))
            }
        }
    }
    
    
    
    func updateBounds(layer: CALayer, bounds: CGRect, beginWithCurrentState: Bool = false, force: Bool = false, completion: ((Bool) -> Void)? = nil) {
        if layer.bounds.equalTo(bounds) && !force {
            completion?(true)
        } else {
            switch self {
            case .immediate:
                layer.removeAnimation(forKey: "bounds")
                layer.bounds = bounds
                if let completion = completion {
                    completion(true)
                }
            case let .animated(duration, curve):
                let previousBounds: CGRect
                if beginWithCurrentState, layer.animation(forKey: "bounds") != nil, let presentation = layer.presentation() {
                    previousBounds = presentation.bounds
                } else {
                    previousBounds = layer.bounds
                }
                layer.bounds = bounds
                layer.animateBounds(from: previousBounds, to: bounds, duration: duration, timingFunction: curve.timingFunction, mediaTimingFunction: curve.mediaTimingFunction, force: force, completion: { result in
                    if let completion = completion {
                        completion(result)
                    }
                })
            }
        }
    }
    
    
    func updatePosition(layer: CALayer, position: CGPoint, force: Bool = false, beginFromCurrentState: Bool = false, completion: ((Bool) -> Void)? = nil) {
        if layer.position.equalTo(position) && !force {
            completion?(true)
        } else {
            switch self {
            case .immediate:
                layer.removeAnimation(forKey: "position")
                layer.position = position
                if let completion = completion {
                    completion(true)
                }
            case let .animated(duration, curve):
                let previousPosition: CGPoint
                if beginFromCurrentState, let animationKeys = layer.animationKeys(), animationKeys.contains(where: { key in
                    guard let animation = layer.animation(forKey: key) as? CAPropertyAnimation else {
                        return false
                    }
                    if animation.keyPath == "position" {
                        return true
                    } else {
                        return false
                    }
                }) {
                    previousPosition = layer.presentation()?.position ?? layer.position
                } else {
                    previousPosition = layer.position
                }
                
                layer.position = position
                layer.animatePosition(from: previousPosition, to: position, duration: duration, timingFunction: curve.timingFunction, mediaTimingFunction: curve.mediaTimingFunction, completion: { result in
                    if let completion = completion {
                        completion(result)
                    }
                })
            }
        }
    }
    
    func animatePosition(layer: CALayer, from fromValue: CGPoint, to toValue: CGPoint, removeOnCompletion: Bool = true, additive: Bool = false, completion: ((Bool) -> Void)? = nil) {
        switch self {
        case .immediate:
            if let completion = completion {
                completion(true)
            }
        case let .animated(duration, curve):
            layer.animatePosition(from: fromValue, to: toValue, duration: duration, timingFunction: curve.timingFunction, mediaTimingFunction: curve.mediaTimingFunction, removeOnCompletion: removeOnCompletion, additive: additive, completion: { result in
                if let completion = completion {
                    completion(result)
                }
            })
        }
    }
    
    
    
    

    func animateFrame(layer: CALayer, from frame: CGRect, to toFrame: CGRect? = nil, delay: Double = 0.0, removeOnCompletion: Bool = true, additive: Bool = false, completion: ((Bool) -> Void)? = nil) {
        switch self {
        case .immediate:
            if let completion = completion {
                completion(true)
            }
        case let .animated(duration, curve):
            layer.animateFrame(from: frame, to: toFrame ?? layer.frame, duration: duration, delay: delay, timingFunction: curve.timingFunction, mediaTimingFunction: curve.mediaTimingFunction, removeOnCompletion: removeOnCompletion, additive: additive, completion: { result in
                if let completion = completion {
                    completion(result)
                }
            })
        }
    }
    
    func animateBounds(layer: CALayer, from bounds: CGRect, removeOnCompletion: Bool = true, completion: ((Bool) -> Void)? = nil) {
        switch self {
            case .immediate:
                if let completion = completion {
                    completion(true)
                }
            case let .animated(duration, curve):
                layer.animateBounds(from: bounds, to: layer.bounds, duration: duration, timingFunction: curve.timingFunction, mediaTimingFunction: curve.mediaTimingFunction, removeOnCompletion: removeOnCompletion, completion: { result in
                    if let completion = completion {
                        completion(result)
                    }
                })
        }
    }
    
    
    
    
    
    func animatePositionAdditive(layer: CALayer, offset: CGFloat, delay: Double = 0.0, removeOnCompletion: Bool = true, completion: @escaping (Bool) -> Void) {
        switch self {
            case .immediate:
                completion(true)
            case let .animated(duration, curve):
                layer.animatePosition(from: CGPoint(x: 0.0, y: offset), to: CGPoint(), duration: duration, delay: delay, timingFunction: curve.timingFunction, mediaTimingFunction: curve.mediaTimingFunction, removeOnCompletion: removeOnCompletion, additive: true, completion: completion)
        }
    }
    
    
    func animatePositionAdditive(layer: CALayer, offset: CGPoint, to toOffset: CGPoint = CGPoint(), removeOnCompletion: Bool = true, completion: ((Bool) -> Void)? = nil) {
        switch self {
            case .immediate:
                completion?(true)
            case let .animated(duration, curve):
                layer.animatePosition(from: offset, to: toOffset, duration: duration, timingFunction: curve.timingFunction, mediaTimingFunction: curve.mediaTimingFunction, removeOnCompletion: removeOnCompletion, additive: true, completion: { result in
                    completion?(result)
                })
        }
    }
    
    func updateFrame(view: UIView, frame: CGRect, force: Bool = false, beginWithCurrentState: Bool = false, delay: Double = 0.0, completion: ((Bool) -> Void)? = nil) {
        if frame.origin.x.isNaN {
            return
        }
        if frame.origin.y.isNaN {
            return
        }
        if frame.size.width.isNaN {
            return
        }
        if frame.size.width < 0.0 {
            return
        }
        if frame.size.height.isNaN {
            return
        }
        if frame.size.height < 0.0 {
            return
        }
        if !tiebaTransitionIsCGRectValidForLayout(CGRect(origin: CGPoint(), size: frame.size)) {
            return
        }
        if !tiebaTransitionIsCGPositionValidForLayout(frame.origin) {
            return
        }
        
        if view.frame.equalTo(frame) && !force {
            completion?(true)
        } else {
            switch self {
            case .immediate:
                view.frame = frame
                if let completion = completion {
                    completion(true)
                }
            case let .animated(duration, curve):
                let previousFrame: CGRect
                if beginWithCurrentState, (view.layer.animation(forKey: "position") != nil || view.layer.animation(forKey: "bounds") != nil), let presentation = view.layer.presentation() {
                    previousFrame = presentation.frame
                } else {
                    previousFrame = view.frame
                }
                view.frame = frame
                view.layer.animateFrame(from: previousFrame, to: frame, duration: duration, delay: delay, timingFunction: curve.timingFunction, mediaTimingFunction: curve.mediaTimingFunction, force: force, completion: { result in
                    if let completion = completion {
                        completion(result)
                    }
                })
            }
        }
    }

    func updateFrame(layer: CALayer, frame: CGRect, beginWithCurrentState: Bool = false, delay: Double = 0.0, completion: ((Bool) -> Void)? = nil) {
        if layer.frame.equalTo(frame) {
            completion?(true)
        } else {
            switch self {
            case .immediate:
                layer.removeAnimation(forKey: "position")
                layer.removeAnimation(forKey: "bounds")
                if let view = layer.delegate as? UIView {
                    view.frame = frame
                } else {
                    layer.frame = frame
                }
                if let completion = completion {
                    completion(true)
                }
            case let .animated(duration, curve):
                let previousFrame: CGRect
                if beginWithCurrentState, (layer.animation(forKey: "position") != nil || layer.animation(forKey: "bounds") != nil), let presentation = layer.presentation() {
                    previousFrame = presentation.frame
                } else {
                    previousFrame = layer.frame
                }
                layer.frame = frame
                layer.animateFrame(from: previousFrame, to: frame, duration: duration, delay: delay, timingFunction: curve.timingFunction, mediaTimingFunction: curve.mediaTimingFunction, completion: { result in
                    if let completion = completion {
                        completion(result)
                    }
                })
            }
        }
    }
    
    
    func updateAlpha(layer: CALayer, alpha: CGFloat, beginWithCurrentState: Bool = false, completion: ((Bool) -> Void)? = nil) {
        if layer.opacity.isEqual(to: Float(alpha)) {
            if let completion = completion {
                completion(true)
            }
            return
        }
        
        switch self {
        case .immediate:
            layer.opacity = Float(alpha)
            if let completion = completion {
                completion(true)
            }
        case let .animated(duration, curve):
            let previousAlpha: Float
            if beginWithCurrentState, let presentation = layer.presentation() {
                previousAlpha = presentation.opacity
            } else {
                previousAlpha = layer.opacity
            }
            layer.opacity = Float(alpha)
            layer.animateAlpha(from: CGFloat(previousAlpha), to: alpha, duration: duration, timingFunction: curve.timingFunction, mediaTimingFunction: curve.mediaTimingFunction, completion: { result in
                if let completion = completion {
                    completion(result)
                }
            })
        }
    }
    
    
    func updateBackgroundColor(layer: CALayer, color: UIColor, completion: ((Bool) -> Void)? = nil) {
        if let nodeColor = layer.backgroundColor, nodeColor == color.cgColor {
            if let completion = completion {
                completion(true)
            }
            return
        }
        
        switch self {
        case .immediate:
            layer.backgroundColor = color.cgColor
            if let completion = completion {
                completion(true)
            }
        case let .animated(duration, curve):
            if let nodeColor = layer.backgroundColor {
                layer.backgroundColor = color.cgColor
                layer.animate(from: nodeColor, to: color.cgColor, keyPath: "backgroundColor", timingFunction: curve.timingFunction, duration: duration, mediaTimingFunction: curve.mediaTimingFunction, completion: { result in
                    if let completion = completion {
                        completion(result)
                    }
                })
            } else {
                layer.backgroundColor = color.cgColor
                if let completion = completion {
                    completion(true)
                }
            }
        }
    }
    
    
    func updateCornerRadius(layer: CALayer, cornerRadius: CGFloat, completion: ((Bool) -> Void)? = nil) {
        if layer.cornerRadius.isEqual(to: cornerRadius) {
            if let completion = completion {
                completion(true)
            }
            return
        }
        
        switch self {
        case .immediate:
            layer.removeAnimation(forKey: "cornerRadius")
            layer.cornerRadius = cornerRadius
            if let completion = completion {
                completion(true)
            }
        case let .animated(duration, curve):
            let previousCornerRadius = layer.cornerRadius
            layer.cornerRadius = cornerRadius
            layer.animate(from: NSNumber(value: Float(previousCornerRadius)), to: NSNumber(value: Float(cornerRadius)), keyPath: "cornerRadius", timingFunction: curve.timingFunction, duration: duration, mediaTimingFunction: curve.mediaTimingFunction, completion: { result in
                if let completion = completion {
                    completion(result)
                }
            })
        }
    }
    
    // [移植] 改动 9：上游这里的 updateTintColor(layer:) / updateTintColor(view:) 依赖
    // Display/Source/UIKitUtils.swift:920 的 CALayer.layerTintColor，而后者是用私有 KVC 键
    // "consentsMultiplyColor" 之外的写法不可行 —— 具体见 docs/ 上游-uikit-migration/12-落地记录.md
    // 「私有 API 一处」的记录：它读写的是私有键 contentsMultiplyColor。
    // 本目录按「不引入私有 API」的既有裁决整体删除这两个入口（不是漏搬）：
    // 需要给视图染色时用公开的 UIView.tintColor，图层着色用 layer.backgroundColor / 内容图重绘表达。
    func updateContentsRect(layer: CALayer, contentsRect: CGRect, completion: ((Bool) -> Void)? = nil) {
        if layer.contentsRect == contentsRect {
            if let completion = completion {
                completion(true)
            }
            return
        }
        
        switch self {
        case .immediate:
            layer.contentsRect = contentsRect
            if let completion = completion {
                completion(true)
            }
        case let .animated(duration, curve):
            let previousContentsRect = layer.contentsRect
            layer.contentsRect = contentsRect
            layer.animate(from: NSValue(cgRect: previousContentsRect), to: NSValue(cgRect: contentsRect), keyPath: "contentsRect", timingFunction: curve.timingFunction, duration: duration, mediaTimingFunction: curve.mediaTimingFunction, completion: { result in
                if let completion = completion {
                    completion(result)
                }
            })
        }
    }
    


    func animateTransformScale(layer: CALayer, from fromScale: CGPoint, completion: ((Bool) -> Void)? = nil) {
        switch self {
        case .immediate:
            if let completion = completion {
                completion(true)
            }
        case let .animated(duration, curve):
            let calculatedFrom: CGPoint
            let calculatedTo: CGPoint

            calculatedFrom = fromScale
            calculatedTo = CGPoint(x: 1.0, y: 1.0)

            layer.animateScaleX(from: calculatedFrom.x, to: calculatedTo.x, duration: duration, timingFunction: curve.timingFunction, mediaTimingFunction: curve.mediaTimingFunction, completion: { result in
                if let completion = completion {
                    completion(result)
                }
            })
            layer.animateScaleY(from: calculatedFrom.y, to: calculatedTo.y, duration: duration, timingFunction: curve.timingFunction, mediaTimingFunction: curve.mediaTimingFunction)
        }
    }
    
    func animateTransformScale(layer: CALayer, from fromScale: CGPoint, to toScale: CGPoint, completion: ((Bool) -> Void)? = nil) {
        switch self {
        case .immediate:
            if let completion = completion {
                completion(true)
            }
        case let .animated(duration, curve):
            let calculatedFrom: CGPoint
            let calculatedTo: CGPoint

            calculatedFrom = fromScale
            calculatedTo = toScale

            layer.animateScaleX(from: calculatedFrom.x, to: calculatedTo.x, duration: duration, timingFunction: curve.timingFunction, mediaTimingFunction: curve.mediaTimingFunction, completion: { result in
                if let completion = completion {
                    completion(result)
                }
            })
            layer.animateScaleY(from: calculatedFrom.y, to: calculatedTo.y, duration: duration, timingFunction: curve.timingFunction, mediaTimingFunction: curve.mediaTimingFunction)
        }
    }
    
    func animateTransformScale(view: UIView, from fromScale: CGFloat, completion: ((Bool) -> Void)? = nil) {
        let t = view.layer.transform
        let currentScale = sqrt((t.m11 * t.m11) + (t.m12 * t.m12) + (t.m13 * t.m13))
        if currentScale.isEqual(to: fromScale) {
            if let completion = completion {
                completion(true)
            }
            return
        }
        
        switch self {
        case .immediate:
            if let completion = completion {
                completion(true)
            }
        case let .animated(duration, curve):
            view.layer.animateScale(from: fromScale, to: currentScale, duration: duration, timingFunction: curve.timingFunction, mediaTimingFunction: curve.mediaTimingFunction, completion: { result in
                if let completion = completion {
                    completion(result)
                }
            })
        }
    }

    
    
    func updateTransform(layer: CALayer, transform: CATransform3D, beginWithCurrentState: Bool = false, delay: Double = 0.0, completion: ((Bool) -> Void)? = nil) {
        if CATransform3DEqualToTransform(layer.transform, transform) {
            if let completion = completion {
                completion(true)
            }
            return
        }

        switch self {
        case .immediate:
            layer.transform = transform
            if let completion = completion {
                completion(true)
            }
        case let .animated(duration, curve):
            let previousTransform: CATransform3D
            if beginWithCurrentState, let presentation = layer.presentation() {
                previousTransform = presentation.transform
            } else {
                previousTransform = layer.transform
            }
            layer.transform = transform
            layer.animate(from: NSValue(caTransform3D: previousTransform), to: NSValue(caTransform3D: transform), keyPath: "transform", timingFunction: curve.timingFunction, duration: duration, delay: delay, mediaTimingFunction: curve.mediaTimingFunction, completion: { value in
                completion?(value)
            })
        }
    }
        
    func updateTransform(layer: CALayer, transform: CGAffineTransform, beginWithCurrentState: Bool = false, delay: Double = 0.0, completion: ((Bool) -> Void)? = nil) {
        let transform = CATransform3DMakeAffineTransform(transform)
        self.updateTransform(layer: layer, transform: transform, beginWithCurrentState: beginWithCurrentState, delay: delay, completion: completion)
    }
    
    
    func updateTransformScale(layer: CALayer, scale: CGFloat, completion: ((Bool) -> Void)? = nil) {
        let t = layer.transform
        let currentScale = sqrt((t.m11 * t.m11) + (t.m12 * t.m12) + (t.m13 * t.m13))
        if currentScale.isEqual(to: scale) {
            if let completion = completion {
                completion(true)
            }
            return
        }
        
        switch self {
        case .immediate:
            layer.transform = CATransform3DMakeScale(scale, scale, 1.0)
            if let completion = completion {
                completion(true)
            }
        case let .animated(duration, curve):
            layer.transform = CATransform3DMakeScale(scale, scale, 1.0)
            layer.animateScale(from: currentScale, to: scale, duration: duration, timingFunction: curve.timingFunction, mediaTimingFunction: curve.mediaTimingFunction, completion: { result in
                if let completion = completion {
                    completion(result)
                }
            })
        }
    }
    
    // [移植] 该重载的 !isNodeLoaded 快捷路径写 node.subnodeTransform（即 layer.sublayerTransform）：节点未
    //        加载时其 CALayer 尚不存在；逻辑并入 layer: 版——CALayer 版始终直接写 layer.sublayerTransform，
    //        与节点加载后走 layer: 路径语义一致，故删除无语义损失。
    
    // [移植] 该重载的 !isNodeLoaded 快捷路径写 node.subnodeTransform（即 layer.sublayerTransform）：节点未
    //        加载时其 CALayer 尚不存在；逻辑并入 layer: 版——CALayer 版始终直接写 layer.sublayerTransform，
    //        与节点加载后走 layer: 路径语义一致，故删除无语义损失。
    
    // [移植] 该重载的 !isNodeLoaded 快捷路径写 node.subnodeTransform（即 layer.sublayerTransform）：节点未
    //        加载时其 CALayer 尚不存在；逻辑并入 layer: 版——CALayer 版始终直接写 layer.sublayerTransform，
    //        与节点加载后走 layer: 路径语义一致，故删除无语义损失。
    
    // [移植] 该重载的 !isNodeLoaded 快捷路径写 node.subnodeTransform（即 layer.sublayerTransform）：节点未
    //        加载时其 CALayer 尚不存在；逻辑并入 layer: 版——CALayer 版始终直接写 layer.sublayerTransform，
    //        与节点加载后走 layer: 路径语义一致，故删除无语义损失。
    
    // [移植] 该重载的 !isNodeLoaded 快捷路径写 node.subnodeTransform（即 layer.sublayerTransform）：节点未
    //        加载时其 CALayer 尚不存在；逻辑并入 layer: 版——CALayer 版始终直接写 layer.sublayerTransform，
    //        与节点加载后走 layer: 路径语义一致，故删除无语义损失。

    func updateTransformScale(layer: CALayer, scale: CGPoint, completion: ((Bool) -> Void)? = nil) {
        let t = layer.transform
        let currentScaleX = sqrt((t.m11 * t.m11) + (t.m12 * t.m12) + (t.m13 * t.m13))
        var currentScaleY = sqrt((t.m21 * t.m21) + (t.m22 * t.m22) + (t.m23 * t.m23))
        if t.m22 < 0.0 {
            currentScaleY = -currentScaleY
        }
        if CGPoint(x: currentScaleX, y: currentScaleY) == scale {
            if let completion = completion {
                completion(true)
            }
            return
        }

        switch self {
            case .immediate:
                layer.removeAnimation(forKey: "transform")
                layer.transform = CATransform3DMakeScale(scale.x, scale.y, 1.0)
                if let completion = completion {
                    completion(true)
                }
            case let .animated(duration, curve):
                layer.transform = CATransform3DMakeScale(scale.x, scale.y, 1.0)
                layer.animate(from: NSValue(caTransform3D: t), to: NSValue(caTransform3D: layer.transform), keyPath: "transform", timingFunction: curve.timingFunction, duration: duration, delay: 0.0, mediaTimingFunction: curve.mediaTimingFunction, removeOnCompletion: true, additive: false, completion: {
                    result in
                    if let completion = completion {
                        completion(result)
                    }
                })
        }
    }
    
    
    func updatePath(layer: CAShapeLayer, path: CGPath, delay: Double = 0.0, completion: ((Bool) -> Void)? = nil) {
        if layer.path == path {
            completion?(true)
            return
        }
        
        switch self {
        case .immediate:
            layer.removeAnimation(forKey: "path")
            layer.path = path
            if let completion = completion {
                completion(true)
            }
        case let .animated(duration, curve):
            let fromPath = layer.path
            layer.path = path
            layer.animate(from: fromPath, to: path, keyPath: "path", timingFunction: curve.timingFunction, duration: duration, delay: delay, mediaTimingFunction: curve.mediaTimingFunction, removeOnCompletion: true, additive: false, completion: {
                result in
                if let completion = completion {
                    completion(result)
                }
            })
        }
    }
}

    
public extension TiebaContainedViewLayoutTransition {
    // [移植] Swift 6：UIView.animate(...) 是 @MainActor 隔离的，传入的 f/completion 闭包会被送进主 actor；
    //        非隔离上下文调用会触发 ActorIsolatedCall 警告 + SendingRisksDataRace 错误。
    //        转场动画本来就只在主线程执行（调用方均为 UI 层），故标 @MainActor——显式化既有事实，行为不变。
    @MainActor func animateView(allowUserInteraction: Bool = false, delay: Double = 0.0, _ f: @escaping () -> Void, completion: ((Bool) -> Void)? = nil) {
        switch self {
        case .immediate:
            f()
            completion?(true)
        case let .animated(duration, curve):
            var options = curve.viewAnimationOptions
            if allowUserInteraction {
                options.insert(.allowUserInteraction)
            }
            UIView.animate(withDuration: duration, delay: delay, options: options, animations: {
                f()
            }, completion: completion)
        }
    }
}
