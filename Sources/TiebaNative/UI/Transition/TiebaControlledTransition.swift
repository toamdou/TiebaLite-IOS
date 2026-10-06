// TiebaControlledTransition —— 可中断 / 可拖拽 / 可合并的转场（转场内核第二片）
//
// 由 TiebaContainedViewLayoutTransition.swift 拆出（单文件 >1000 行 → 拆分，逐字搬运）。
// 本片是查看器 chrome 显隐续跑（UI/Media/TiebaPhotoBrowserOverlay.swift:64,282）的落点。

import Foundation
import UIKit

// MARK: - ControlledTransition（可中断 / 可拖拽 / 可合并）
// [移植] 改动 6b：动画器的每个方法都要写 CALayer 模型值，协议整体 @MainActor，
// 于是两个实现类也必须在主 actor 上（Swift 6 的协议隔离一致性检查会强制这一点）。
@MainActor
public protocol TiebaControlledTransitionAnimator: AnyObject {
    var duration: Double { get }
    
    func startAnimation()
    func setAnimationProgress(_ progress: CGFloat)
    func finishAnimation()
    
    func updateAlpha(layer: CALayer, alpha: CGFloat, completion: ((Bool) -> Void)?)
    func updateScale(layer: CALayer, scale: CGFloat, completion: ((Bool) -> Void)?)
    func animateScale(layer: CALayer, from fromValue: CGFloat, to toValue: CGFloat, completion: ((Bool) -> Void)?)
    func updatePosition(layer: CALayer, position: CGPoint, completion: ((Bool) -> Void)?)
    func animatePosition(layer: CALayer, from fromValue: CGPoint, to toValue: CGPoint, completion: ((Bool) -> Void)?)
    func updateBounds(layer: CALayer, bounds: CGRect, completion: ((Bool) -> Void)?)
    func updateFrame(layer: CALayer, frame: CGRect, completion: ((Bool) -> Void)?)
    func updateCornerRadius(layer: CALayer, cornerRadius: CGFloat, completion: ((Bool) -> Void)?)
    func updateContentsRect(layer: CALayer, contentsRect: CGRect, completion: ((Bool) -> Void)?)
    func updateTransform(layer: CALayer, transform: CATransform3D, completion: ((Bool) -> Void)?)
    func updateBackgroundColor(layer: CALayer, color: UIColor, completion: ((Bool) -> Void)?)
    func updateShapeLayerPath(layer: CAShapeLayer, path: CGPath, completion: ((Bool) -> Void)?)
}

// [移植] 改动 4：上游 protocol AnyValueProviding。协议与成员都加了前缀——
// 上游的 interpolate(with:fraction:) 与 Display/ListViewAnimation.swift 的 Interpolatable
// 完全同名同签名，同模块并存会重复定义。
// 纯值插值，不碰 UIKit 状态，保持 nonisolated（CGPath/CGColor 的逐元素插值可以在任意隔离域跑）。
protocol TiebaTransitionValueProviding {
    var tiebaAnyValue: TiebaControlledTransitionProperty.AnyValue { get }
}

extension CGFloat: TiebaTransitionValueProviding {
    func tiebaInterpolate(with other: CGFloat, fraction: CGFloat) -> CGFloat {
        let invT = 1.0 - fraction
        let result = other * fraction + self * invT
        return result
    }
    
    var tiebaAnyValue: TiebaControlledTransitionProperty.AnyValue {
        return TiebaControlledTransitionProperty.AnyValue(
            value: self,
            nsValue: self as NSNumber,
            stringValue: { "\(self)" },
            isEqual: { other in
                if let otherValue = other.value as? CGFloat {
                    return self == otherValue
                } else {
                    return false
                }
            },
            interpolate: { other, fraction in
                guard let otherValue = other.value as? CGFloat else {
                    preconditionFailure()
                }
                return self.tiebaInterpolate(with: otherValue, fraction: fraction).tiebaAnyValue
            }
        )
    }
}

extension Float: TiebaTransitionValueProviding {
    func tiebaInterpolate(with other: Float, fraction: CGFloat) -> Float {
        let invT = 1.0 - Float(fraction)
        let result = other * Float(fraction) + self * invT
        return result
    }
    
    var tiebaAnyValue: TiebaControlledTransitionProperty.AnyValue {
        return TiebaControlledTransitionProperty.AnyValue(
            value: self,
            nsValue: self as NSNumber,
            stringValue: { "\(self)" },
            isEqual: { other in
                if let otherValue = other.value as? Float {
                    return self == otherValue
                } else {
                    return false
                }
            },
            interpolate: { other, fraction in
                guard let otherValue = other.value as? Float else {
                    preconditionFailure()
                }
                return self.tiebaInterpolate(with: otherValue, fraction: fraction).tiebaAnyValue
            }
        )
    }
}

extension CGPoint: TiebaTransitionValueProviding {
    func tiebaInterpolate(with other: CGPoint, fraction: CGFloat) -> CGPoint {
        return CGPoint(x: self.x.tiebaInterpolate(with: other.x, fraction: fraction), y: self.y.tiebaInterpolate(with: other.y, fraction: fraction))
    }
    
    var tiebaAnyValue: TiebaControlledTransitionProperty.AnyValue {
        return TiebaControlledTransitionProperty.AnyValue(
            value: self,
            nsValue: NSValue(cgPoint: self),
            stringValue: { "\(self)" },
            isEqual: { other in
                if let otherValue = other.value as? CGPoint {
                    return self == otherValue
                } else {
                    return false
                }
            },
            interpolate: { other, fraction in
                guard let otherValue = other.value as? CGPoint else {
                    preconditionFailure()
                }
                return self.tiebaInterpolate(with: otherValue, fraction: fraction).tiebaAnyValue
            }
        )
    }
}

extension CGSize: TiebaTransitionValueProviding {
    func tiebaInterpolate(with other: CGSize, fraction: CGFloat) -> CGSize {
        return CGSize(width: self.width.tiebaInterpolate(with: other.width, fraction: fraction), height: self.height.tiebaInterpolate(with: other.height, fraction: fraction))
    }
    
    var tiebaAnyValue: TiebaControlledTransitionProperty.AnyValue {
        return TiebaControlledTransitionProperty.AnyValue(
            value: self,
            nsValue: NSValue(cgSize: self),
            stringValue: { "\(self)" },
            isEqual: { other in
                if let otherValue = other.value as? CGSize {
                    return self == otherValue
                } else {
                    return false
                }
            },
            interpolate: { other, fraction in
                guard let otherValue = other.value as? CGSize else {
                    preconditionFailure()
                }
                return self.tiebaInterpolate(with: otherValue, fraction: fraction).tiebaAnyValue
            }
        )
    }
}

extension CGRect: TiebaTransitionValueProviding {
    func tiebaInterpolate(with other: CGRect, fraction: CGFloat) -> CGRect {
        return CGRect(origin: self.origin.tiebaInterpolate(with: other.origin, fraction: fraction), size: self.size.tiebaInterpolate(with: other.size, fraction: fraction))
    }
    
    var tiebaAnyValue: TiebaControlledTransitionProperty.AnyValue {
        return TiebaControlledTransitionProperty.AnyValue(
            value: self,
            nsValue: NSValue(cgRect: self),
            stringValue: { "\(self)" },
            isEqual: { other in
                if let otherValue = other.value as? CGRect {
                    return self == otherValue
                } else {
                    return false
                }
            },
            interpolate: { other, fraction in
                guard let otherValue = other.value as? CGRect else {
                    preconditionFailure()
                }
                return self.tiebaInterpolate(with: otherValue, fraction: fraction).tiebaAnyValue
            }
        )
    }
}

extension CATransform3D: TiebaTransitionValueProviding {
    func tiebaInterpolate(with other: CATransform3D, fraction: CGFloat) -> CATransform3D {
        return CATransform3D(
            m11: self.m11.tiebaInterpolate(with: other.m11, fraction: fraction),
            m12: self.m12.tiebaInterpolate(with: other.m12, fraction: fraction),
            m13: self.m13.tiebaInterpolate(with: other.m13, fraction: fraction),
            m14: self.m14.tiebaInterpolate(with: other.m14, fraction: fraction),
            m21: self.m21.tiebaInterpolate(with: other.m21, fraction: fraction),
            m22: self.m22.tiebaInterpolate(with: other.m22, fraction: fraction),
            m23: self.m23.tiebaInterpolate(with: other.m23, fraction: fraction),
            m24: self.m24.tiebaInterpolate(with: other.m24, fraction: fraction),
            m31: self.m31.tiebaInterpolate(with: other.m31, fraction: fraction),
            m32: self.m32.tiebaInterpolate(with: other.m32, fraction: fraction),
            m33: self.m33.tiebaInterpolate(with: other.m33, fraction: fraction),
            m34: self.m34.tiebaInterpolate(with: other.m34, fraction: fraction),
            m41: self.m41.tiebaInterpolate(with: other.m41, fraction: fraction),
            m42: self.m42.tiebaInterpolate(with: other.m42, fraction: fraction),
            m43: self.m43.tiebaInterpolate(with: other.m43, fraction: fraction),
            m44: self.m44.tiebaInterpolate(with: other.m44, fraction: fraction)
        )
    }
    
    var tiebaAnyValue: TiebaControlledTransitionProperty.AnyValue {
        return TiebaControlledTransitionProperty.AnyValue(
            value: self,
            nsValue: NSValue(caTransform3D: self),
            stringValue: { "\(self)" },
            isEqual: { other in
                if let otherValue = other.value as? CATransform3D {
                    return CATransform3DEqualToTransform(self, otherValue)
                } else {
                    return false
                }
            },
            interpolate: { other, fraction in
                guard let otherValue = other.value as? CATransform3D else {
                    preconditionFailure()
                }
                return self.tiebaInterpolate(with: otherValue, fraction: fraction).tiebaAnyValue
            }
        )
    }
}

extension CGColor: TiebaTransitionValueProviding {
    func tiebaInterpolate(with other: CGColor, fraction: CGFloat) -> CGColor {
        return UIColor(cgColor: self).mixedWith(UIColor(cgColor: other), alpha: fraction).cgColor
    }
    
    var tiebaAnyValue: TiebaControlledTransitionProperty.AnyValue {
        return TiebaControlledTransitionProperty.AnyValue(
            value: self,
            nsValue: self,
            stringValue: { "\(self)" },
            isEqual: { other in
                if CFGetTypeID(other.value as CFTypeRef) == CGColor.typeID {
                    return self == (other.value as! CGColor)
                } else {
                    return false
                }
            },
            interpolate: { other, fraction in
                guard CFGetTypeID(other.value as CFTypeRef) == CGColor.typeID else {
                    preconditionFailure()
                }
                return self.tiebaInterpolate(with: other.value as! CGColor, fraction: fraction).tiebaAnyValue
            }
        )
    }
}

extension CGPath: TiebaTransitionValueProviding {
    func tiebaInterpolate(with other: CGPath, fraction: CGFloat) -> CGPath {
        if fraction <= 0.0 {
            return self
        } else if fraction >= 1.0 {
            return other
        }

        enum PathElement {
            case move(to: CGPoint)
            case addLine(to: CGPoint)
            case addQuad(control: CGPoint, to: CGPoint)
            case addCurve(control1: CGPoint, control2: CGPoint, to: CGPoint)
            case close
        }

        func elements(for path: CGPath) -> [PathElement] {
            var elements: [PathElement] = []
            path.applyWithBlock { elementPointer in
                let element = elementPointer.pointee
                let points = element.points
                switch element.type {
                case .moveToPoint:
                    elements.append(.move(to: points[0]))
                case .addLineToPoint:
                    elements.append(.addLine(to: points[0]))
                case .addQuadCurveToPoint:
                    elements.append(.addQuad(control: points[0], to: points[1]))
                case .addCurveToPoint:
                    elements.append(.addCurve(control1: points[0], control2: points[1], to: points[2]))
                case .closeSubpath:
                    elements.append(.close)
                @unknown default:
                    break
                }
            }
            return elements
        }

        let lhsElements = elements(for: self)
        let rhsElements = elements(for: other)

        guard lhsElements.count == rhsElements.count else {
            return fraction < 0.5 ? self : other
        }

        func interpolatedPoint(_ lhs: CGPoint, _ rhs: CGPoint) -> CGPoint {
            return lhs.tiebaInterpolate(with: rhs, fraction: fraction)
        }

        let mutablePath = CGMutablePath()
        for (lhs, rhs) in zip(lhsElements, rhsElements) {
            switch (lhs, rhs) {
            case let (.move(to: lhsPoint), .move(to: rhsPoint)):
                mutablePath.move(to: interpolatedPoint(lhsPoint, rhsPoint))
            case let (.addLine(to: lhsPoint), .addLine(to: rhsPoint)):
                mutablePath.addLine(to: interpolatedPoint(lhsPoint, rhsPoint))
            case let (.addQuad(control: lhsControl, to: lhsPoint), .addQuad(control: rhsControl, to: rhsPoint)):
                mutablePath.addQuadCurve(to: interpolatedPoint(lhsPoint, rhsPoint), control: interpolatedPoint(lhsControl, rhsControl))
            case let (.addCurve(control1: lhsControl1, control2: lhsControl2, to: lhsPoint), .addCurve(control1: rhsControl1, control2: rhsControl2, to: rhsPoint)):
                mutablePath.addCurve(
                    to: interpolatedPoint(lhsPoint, rhsPoint),
                    control1: interpolatedPoint(lhsControl1, rhsControl1),
                    control2: interpolatedPoint(lhsControl2, rhsControl2)
                )
            case (.close, .close):
                mutablePath.closeSubpath()
            default:
                return fraction <= 0.0 ? self : other
            }
        }

        return mutablePath.copy() ?? mutablePath
    }
    
    var tiebaAnyValue: TiebaControlledTransitionProperty.AnyValue {
        return TiebaControlledTransitionProperty.AnyValue(
            value: self,
            nsValue: self,
            stringValue: { "\(self)" },
            isEqual: { other in
                if CFGetTypeID(other.value as CFTypeRef) == CGPath.typeID {
                    return self == (other.value as! CGPath)
                } else {
                    return false
                }
            },
            interpolate: { other, fraction in
                guard CFGetTypeID(other.value as CFTypeRef) == CGPath.typeID else {
                    preconditionFailure()
                }
                return self.tiebaInterpolate(with: other.value as! CGPath, fraction: fraction).tiebaAnyValue
            }
        )
    }
}

// [移植] 改动 6c：本类持有 CALayer、并在 deinit 里摘掉自己的动画。整类 @MainActor 之后
// deinit 会因「nonisolated deinit 不能访问非 Sendable 存储属性」报错，故用 isolated deinit
// （Swift 6.2 起可用，本工程 Swift 6.4 实测通过）——比 nonisolated(unsafe) / @unchecked Sendable 干净。
@MainActor
final class TiebaControlledTransitionProperty {
    final class AnyValue: Equatable, CustomStringConvertible {
        let value: Any
        let nsValue: Any
        let stringValue: () -> String
        let isEqual: (AnyValue) -> Bool
        let interpolate: (AnyValue, CGFloat) -> AnyValue
        
        init(
            value: Any,
            nsValue: Any,
            stringValue: @escaping () -> String,
            isEqual: @escaping (AnyValue) -> Bool,
            interpolate: @escaping (AnyValue, CGFloat) -> AnyValue
        ) {
            self.value = value
            self.nsValue = nsValue
            self.stringValue = stringValue
            self.isEqual = isEqual
            self.interpolate = interpolate
        }
        
        var description: String {
            return self.stringValue()
        }
        
        static func ==(lhs: AnyValue, rhs: AnyValue) -> Bool {
            if lhs.isEqual(rhs) {
                return true
            } else {
                return false
            }
        }
    }
    
    let layer: CALayer
    let path: String
    var fromValue: AnyValue
    let toValue: AnyValue
    private let completion: ((Bool) -> Void)?
    
    private lazy var animationKey: String = {
        return "MyCustomAnimation_\(Unmanaged.passUnretained(self).toOpaque())"
    }()
    
    init<T>(layer: CALayer, path: String, fromValue: T, toValue: T, completion: ((Bool) -> Void)?) where T: TiebaTransitionValueProviding {
        self.layer = layer
        self.path = path
        self.fromValue = fromValue.tiebaAnyValue
        self.toValue = toValue.tiebaAnyValue
        self.completion = completion
        
        self.update(at: 0.0)
    }
    
    isolated deinit {
        self.layer.removeAnimation(forKey: self.animationKey)
    }
    
    func update(at fraction: CGFloat) {
        let value = self.fromValue.interpolate(toValue, fraction)
        
        let animation = CABasicAnimation(keyPath: self.path)
        animation.speed = 0.0
        animation.beginTime = CACurrentMediaTime() + 1000.0
        animation.timeOffset = 0.01
        animation.duration = 1.0
        animation.fillMode = .both
        animation.fromValue = value.nsValue
        animation.toValue = value.nsValue
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.isRemovedOnCompletion = false
        self.layer.add(animation, forKey: self.animationKey)
    }
    
    func complete(atEnd: Bool) {
        self.completion?(atEnd)
    }
}

@MainActor
public final class TiebaControlledTransition {
    // [移植] 改动 6b：嵌套类型不继承外围类的全局 actor 隔离（Swift 6.4 实测），显式标注。
    @MainActor
    public final class NativeAnimator: TiebaControlledTransitionAnimator {
        public let duration: Double
        private let curve: TiebaContainedViewLayoutTransitionCurve
        
        private var animations: [TiebaControlledTransitionProperty] = []
        
        init(
            duration: Double,
            curve: TiebaContainedViewLayoutTransitionCurve
        ) {
            self.duration = duration
            self.curve = curve
        }
        
        func merge(with other: NativeAnimator, forceRestart: Bool) {
            var removeAnimationIndices: [Int] = []
            for i in 0 ..< self.animations.count {
                let animation = self.animations[i]
                
                var removeOtherAnimationIndices: [Int] = []
                for j in 0 ..< other.animations.count {
                    let otherAnimation = other.animations[j]
                    
                    if animation.layer === otherAnimation.layer && animation.path == otherAnimation.path {
                        if animation.toValue == otherAnimation.toValue && !forceRestart {
                            removeAnimationIndices.append(i)
                        } else {
                            removeOtherAnimationIndices.append(j)
                        }
                    }
                }
                
                for j in removeOtherAnimationIndices.reversed() {
                    let otherAnimation = other.animations.remove(at: j)
                    otherAnimation.complete(atEnd: false)
                }
            }
            
            for i in Set(removeAnimationIndices).sorted().reversed() {
                self.animations.remove(at: i).complete(atEnd: false)
            }
        }
        
        public func startAnimation() {
        }
        
        public func setAnimationProgress(_ progress: CGFloat) {
            let mappedFraction: CGFloat
            switch self.curve {
            case .spring:
                mappedFraction = TiebaTransitionAnimation.springValue(at: progress)
            case let .custom(c1x, c1y, c2x, c2y):
                mappedFraction = TiebaTransitionAnimation.bezierPoint(CGFloat(c1x), CGFloat(c1y), CGFloat(c2x), CGFloat(c2y), progress)
            default:
                mappedFraction = progress
            }
            
            for animation in self.animations {
                animation.update(at: mappedFraction)
            }
        }
        
        public func finishAnimation() {
            for animation in self.animations {
                animation.update(at: 1.0)
                animation.complete(atEnd: true)
            }
            self.animations.removeAll()
        }
        
        private func add(animation: TiebaControlledTransitionProperty) {
            for i in 0 ..< self.animations.count {
                let otherAnimation = self.animations[i]
                if otherAnimation.layer === animation.layer && otherAnimation.path == animation.path {
                    let currentAnimation = self.animations[i]
                    currentAnimation.complete(atEnd: false)
                    self.animations.remove(at: i)
                    break
                }
            }
            self.animations.append(animation)
        }
        
        public func updateAlpha(layer: CALayer, alpha: CGFloat, completion: ((Bool) -> Void)?) {
            if layer.opacity == Float(alpha) {
                return
            }
            let fromValue = layer.presentation()?.opacity ?? layer.opacity
            layer.opacity = Float(alpha)
            self.add(animation: TiebaControlledTransitionProperty(
                layer: layer,
                path: "opacity",
                fromValue: fromValue,
                toValue: Float(alpha),
                completion: completion
            ))
        }
        
        public func updateScale(layer: CALayer, scale: CGFloat, completion: ((Bool) -> Void)?) {
            let t = layer.presentation()?.transform ?? layer.transform
            let currentScale = sqrt((t.m11 * t.m11) + (t.m12 * t.m12) + (t.m13 * t.m13))
            
            if currentScale == scale {
                return
            }
            layer.transform = CATransform3DMakeScale(scale, scale, 1.0)
            self.add(animation: TiebaControlledTransitionProperty(
                layer: layer,
                path: "transform.scale",
                fromValue: currentScale,
                toValue: scale,
                completion: completion
            ))
        }
        
        public func animateScale(layer: CALayer, from fromValue: CGFloat, to toValue: CGFloat, completion: ((Bool) -> Void)?) {
            self.add(animation: TiebaControlledTransitionProperty(
                layer: layer,
                path: "transform.scale",
                fromValue: fromValue,
                toValue: toValue,
                completion: completion
            ))
        }
        
        public func animatePosition(layer: CALayer, from fromValue: CGPoint, to toValue: CGPoint, completion: ((Bool) -> Void)?) {
            self.add(animation: TiebaControlledTransitionProperty(
                layer: layer,
                path: "position",
                fromValue: fromValue,
                toValue: toValue,
                completion: completion
            ))
        }
        
        public func updatePosition(layer: CALayer, position: CGPoint, completion: ((Bool) -> Void)?) {
            if layer.position == position {
                return
            }
            let fromValue = layer.presentation()?.position ?? layer.position
            layer.position = position
            self.add(animation: TiebaControlledTransitionProperty(
                layer: layer,
                path: "position",
                fromValue: fromValue,
                toValue: position,
                completion: completion
            ))
        }
        
        public func updateBounds(layer: CALayer, bounds: CGRect, completion: ((Bool) -> Void)?) {
            if layer.bounds == bounds {
                return
            }
            let fromValue: CGRect
            if let animationKeys = layer.animationKeys(), animationKeys.contains(where: { key in
                guard let animation = layer.animation(forKey: key) as? CAPropertyAnimation else {
                    return false
                }
                if animation.keyPath == "bounds" {
                    return true
                } else {
                    return false
                }
            }) {
                fromValue = layer.presentation()?.bounds ?? layer.bounds
            } else {
                fromValue = layer.bounds
            }
            layer.bounds = bounds
            self.add(animation: TiebaControlledTransitionProperty(
                layer: layer,
                path: "bounds",
                fromValue: fromValue,
                toValue: bounds,
                completion: completion
            ))
        }
        
        public func updateFrame(layer: CALayer, frame: CGRect, completion: ((Bool) -> Void)?) {
            self.updatePosition(layer: layer, position: frame.tiebaTransitionCenter, completion: completion)
            self.updateBounds(layer: layer, bounds: CGRect(origin: CGPoint(), size: frame.size), completion: nil)
        }
        
        public func updateTransform(layer: CALayer, transform: CATransform3D, completion: ((Bool) -> Void)?) {
            if CATransform3DEqualToTransform(layer.transform, transform) {
                return
            }
            let fromValue: CATransform3D
            if let animationKeys = layer.animationKeys(), animationKeys.contains(where: { key in
                guard let animation = layer.animation(forKey: key) as? CAPropertyAnimation else {
                    return false
                }
                if animation.keyPath == "transform" {
                    return true
                } else {
                    return false
                }
            }) {
                fromValue = layer.presentation()?.transform ?? layer.transform
            } else {
                fromValue = layer.transform
            }
            layer.transform = transform
            self.add(animation: TiebaControlledTransitionProperty(
                layer: layer,
                path: "transform",
                fromValue: fromValue,
                toValue: transform,
                completion: completion
            ))
        }
        
        public func updateBackgroundColor(layer: CALayer, color: UIColor, completion: ((Bool) -> Void)?) {
            if let currentColor = layer.backgroundColor, currentColor == color.cgColor {
                if let completion = completion {
                    completion(true)
                }
                return
            }
            
            let fromValue: CGColor?
            if let animationKeys = layer.animationKeys(), animationKeys.contains(where: { key in
                guard let animation = layer.animation(forKey: key) as? CAPropertyAnimation else {
                    return false
                }
                if animation.keyPath == "backgroundColor" {
                    return true
                } else {
                    return false
                }
            }) {
                fromValue = layer.presentation()?.backgroundColor ?? layer.backgroundColor
            } else {
                fromValue = layer.backgroundColor
            }
            
            var mappedFromValue: UIColor
            if let fromValue {
                mappedFromValue = UIColor(cgColor: fromValue)
            } else {
                mappedFromValue = .clear
            }
            
            layer.backgroundColor = color.cgColor
            self.add(animation: TiebaControlledTransitionProperty(
                layer: layer,
                path: "backgroundColor",
                fromValue: mappedFromValue.cgColor,
                toValue: color.cgColor,
                completion: completion
            ))
        }
        
        public func updateShapeLayerPath(layer: CAShapeLayer, path: CGPath, completion: ((Bool) -> Void)?) {
            if let currentPath = layer.path, currentPath == path {
                if let completion = completion {
                    completion(true)
                }
                return
            }
            
            let fromValue: CGPath?
            if let animationKeys = layer.animationKeys(), animationKeys.contains(where: { key in
                guard let animation = layer.animation(forKey: key) as? CAPropertyAnimation else {
                    return false
                }
                if animation.keyPath == "path" {
                    return true
                } else {
                    return false
                }
            }) {
                fromValue = layer.presentation()?.path ?? layer.path
            } else {
                fromValue = layer.path
            }
            
            var mappedFromValue: CGPath
            if let fromValue {
                mappedFromValue = fromValue
            } else {
                mappedFromValue = CGMutablePath()
            }
            
            layer.path = path
            self.add(animation: TiebaControlledTransitionProperty(
                layer: layer,
                path: "path",
                fromValue: mappedFromValue,
                toValue: path,
                completion: completion
            ))
        }
        
        public func updateCornerRadius(layer: CALayer, cornerRadius: CGFloat, completion: ((Bool) -> Void)?) {
            if layer.cornerRadius == cornerRadius {
                return
            }
            let fromValue = layer.presentation()?.cornerRadius ?? layer.cornerRadius
            layer.cornerRadius = cornerRadius
            self.add(animation: TiebaControlledTransitionProperty(
                layer: layer,
                path: "cornerRadius",
                fromValue: fromValue,
                toValue: cornerRadius,
                completion: completion
            ))
        }
        
        public func updateContentsRect(layer: CALayer, contentsRect: CGRect, completion: ((Bool) -> Void)?) {
            if layer.contentsRect == contentsRect {
                return
            }
            let fromValue = layer.presentation()?.contentsRect ?? layer.contentsRect
            layer.contentsRect = contentsRect
            self.add(animation: TiebaControlledTransitionProperty(
                layer: layer,
                path: "contentsRect",
                fromValue: fromValue,
                toValue: contentsRect,
                completion: completion
            ))
        }
    }

    @MainActor
    public final class LegacyAnimator: TiebaControlledTransitionAnimator {
        public let duration: Double
        public let transition: TiebaContainedViewLayoutTransition
        
        init(
            duration: Double,
            curve: TiebaContainedViewLayoutTransitionCurve
        ) {
            self.duration = duration
            
            if duration.isZero {
                self.transition = .immediate
            } else {
                self.transition = .animated(duration: duration, curve: curve)
            }
        }
        
        public func startAnimation() {
        }
        
        public func setAnimationProgress(_ progress: CGFloat) {
        }
        
        public func finishAnimation() {
        }
        
        public func updateAlpha(layer: CALayer, alpha: CGFloat, completion: ((Bool) -> Void)?) {
            self.transition.updateAlpha(layer: layer, alpha: alpha, completion: completion)
        }
        
        public func updateScale(layer: CALayer, scale: CGFloat, completion: ((Bool) -> Void)?) {
            self.transition.updateTransformScale(layer: layer, scale: scale, completion: completion)
        }
        
        public func animateScale(layer: CALayer, from fromValue: CGFloat, to toValue: CGFloat, completion: ((Bool) -> Void)?) {
            self.transition.animateTransformScale(layer: layer, from: CGPoint(x: fromValue, y: fromValue), to: CGPoint(x: toValue, y: toValue), completion: completion)
        }
        
        public func updatePosition(layer: CALayer, position: CGPoint, completion: ((Bool) -> Void)?) {
            self.transition.updatePosition(layer: layer, position: position, beginFromCurrentState: true, completion: completion)
        }
        
        public func updateTransform(layer: CALayer, transform: CATransform3D, completion: ((Bool) -> Void)?) {
            self.transition.updateTransform(layer: layer, transform: CATransform3DGetAffineTransform(transform), completion: completion)
        }
        
        public func updateBackgroundColor(layer: CALayer, color: UIColor, completion: ((Bool) -> Void)?) {
            self.transition.updateBackgroundColor(layer: layer, color: color, completion: completion)
        }
        
        public func updateShapeLayerPath(layer: CAShapeLayer, path: CGPath, completion: ((Bool) -> Void)?) {
            self.transition.updatePath(layer: layer, path: path, completion: completion)
        }
        
        public func animatePosition(layer: CALayer, from fromValue: CGPoint, to toValue: CGPoint, completion: ((Bool) -> Void)?) {
            self.transition.animatePosition(layer: layer, from: fromValue, to: toValue, completion: completion)
        }
        
        public func updateBounds(layer: CALayer, bounds: CGRect, completion: ((Bool) -> Void)?) {
            self.transition.updateBounds(layer: layer, bounds: bounds, beginWithCurrentState: true, completion: completion)
        }
        
        public func updateFrame(layer: CALayer, frame: CGRect, completion: ((Bool) -> Void)?) {
            self.transition.updateFrame(layer: layer, frame: frame, beginWithCurrentState: true, completion: completion)
        }
        
        public func updateCornerRadius(layer: CALayer, cornerRadius: CGFloat, completion: ((Bool) -> Void)?) {
            self.transition.updateCornerRadius(layer: layer, cornerRadius: cornerRadius, completion: completion)
        }
        
        public func updateContentsRect(layer: CALayer, contentsRect: CGRect, completion: ((Bool) -> Void)?) {
            self.transition.updateContentsRect(layer: layer, contentsRect: contentsRect, completion: completion)
        }
    }
    
    public let animator: TiebaControlledTransitionAnimator
    public let legacyAnimator: LegacyAnimator
    
    public init(
        duration: Double,
        curve: TiebaContainedViewLayoutTransitionCurve,
        interactive: Bool
    ) {
        self.legacyAnimator = LegacyAnimator(
            duration: duration,
            curve: curve
        )
        if interactive {
            self.animator = NativeAnimator(
                duration: duration,
                curve: curve
            )
        } else {
            self.animator = self.legacyAnimator
        }
    }
    
    public func merge(with other: TiebaControlledTransition, forceRestart: Bool) {
        if let animator = self.animator as? NativeAnimator, let otherAnimator = other.animator as? NativeAnimator {
            animator.merge(with: otherAnimator, forceRestart: forceRestart)
        }
    }
}
