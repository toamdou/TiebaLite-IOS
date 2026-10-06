// TiebaCAAnimationUtils —— CAAnimation 工具（弹簧/缩放/形变动画与曲线常量）。
//
// 移植自上游 submodules/Display/Source/CAAnimationUtils.swift。
// 本仓改名：kCAMediaTimingFunctionSpring → tiebaCAMediaTimingFunctionSpring、kCAMediaTimingFunctionCustomSpringPrefix → tiebaCAMediaTimingFunctionCustomSpringPrefix —— 公开符号加本仓前缀，避免污染模块全局命名空间
// 本仓改动：1) 移除上游对 ObjC 模块 UIKitRuntimeUtils 的依赖（本移植不引入该模块）；
//       2) 文件顶部内联 4 个上游 helper 的纯 Swift 等价实现（文件私有 + tieba 前缀），
//          见文件内 [移植] 注释块；3) 调用点相应改名。业务逻辑/结构未改动。

import UIKit

// ---------------------------------------------------------------------------
// [移植] 上游 CAAnimationUtils.swift 依赖 ObjC 模块 UIKitRuntimeUtils。本移植不引入该
// 模块（上游 Display 模块 只搬纯 UIKit/Swift 部分），因此把本文件用到的 4 个上游 helper
// 以文件私有的纯 Swift 等价实现内联在此。函数名统一加 tieba 前缀，避免与
// 其他目录可能提供的同名实现冲突。逐条对应关系：
//   * UIView.animationDurationFactor()   <- Display/Source/UIKitUtils.swift
//                                            -> UIKitUtils.m animationDurationFactorImpl()
//   * make26SpringAnimationImpl(_:_:)    <- UIKitUtils.m make26SpringAnimationImpl
//   * makeSpringAnimation(_:duration:)   <- UIKitUtils.m makeSpringAnimationImpl
//   * makeSpringBounceAnimation(_:_:_:)  <- UIKitUtils.m makeSpringBounceAnimationImpl
// 除函数名外，参数、常量、时序与上游 ObjC 实现一一对应。
// ---------------------------------------------------------------------------
private func tiebaAnimationDurationFactor() -> Double {
    // [移植] 上游 UIKitRuntimeUtils/UIKitUtils.m：模拟器返回 UIAnimationDragCoefficient()
    // （私有符号，Swift 不可用），真机恒为 1.0。此处取真机语义。
    return 1.0
}

private func tiebaMake26SpringAnimation(_ keyPath: String, _ duration: Double) -> CABasicAnimation {
    let springAnimation = CASpringAnimation(keyPath: keyPath)
    // iOS 26 系统弹簧（ζ = 1.000 临界阻尼）：值出 TiebaMotionSpec.Spring，见该表 ios26Mass 注释。
    springAnimation.mass = TiebaMotionSpec.Spring.ios26Mass
    springAnimation.stiffness = TiebaMotionSpec.Spring.ios26Stiffness
    springAnimation.damping = TiebaMotionSpec.Spring.ios26Damping
    springAnimation.duration = duration
    springAnimation.timingFunction = CAMediaTimingFunction(name: .linear)
    if #available(iOS 17.0, *) {
        springAnimation.allowsOverdamping = false
    }
    if #available(iOS 15.0, *) {
        springAnimation.setValue(NSNumber(value: 1048619), forKey: "highFrameRateReason")
        springAnimation.preferredFrameRateRange = CAFrameRateRange(minimum: 80.0, maximum: 120.0, preferred: 120.0)
    }
    return springAnimation
}

private func tiebaMakeSpringAnimation(_ keyPath: String, duration: Double) -> CABasicAnimation {
    if #available(iOS 26.0, *) {
        return tiebaMake26SpringAnimation(keyPath, duration)
    }
    let springAnimation = CASpringAnimation(keyPath: keyPath)
    springAnimation.mass = 3.0
    springAnimation.stiffness = 1000.0
    springAnimation.damping = 500.0
    springAnimation.duration = 0.5
    springAnimation.timingFunction = CAMediaTimingFunction(name: .linear)
    return springAnimation
}

private func tiebaMakeSpringBounceAnimation(_ keyPath: String, _ initialVelocity: CGFloat, _ damping: CGFloat) -> CASpringAnimation {
    let springAnimation = CASpringAnimation(keyPath: keyPath)
    springAnimation.mass = 5.0
    springAnimation.stiffness = 900.0
    springAnimation.damping = damping
    // [移植] 上游先 dispatch_once 探测 CASpringAnimation 是否响应 setInitialVelocity:，
    // 现代 iOS 始终响应，这里直接使用。
    springAnimation.initialVelocity = initialVelocity
    springAnimation.duration = springAnimation.settlingDuration
    springAnimation.timingFunction = CAMediaTimingFunction(name: .linear)
    return springAnimation
}


@objc private class CALayerAnimationDelegate: NSObject, CAAnimationDelegate {
    private let keyPath: String?
    var completion: ((Bool) -> Void)?
    
    init(animation: CAAnimation, completion: ((Bool) -> Void)?) {
        if let animation = animation as? CABasicAnimation {
            self.keyPath = animation.keyPath
        } else {
            self.keyPath = nil
        }
        self.completion = completion
        
        super.init()
    }
    
    @objc func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {
        if let anim = anim as? CABasicAnimation {
            if anim.keyPath != self.keyPath {
                return
            }
        }
        if let completion = self.completion {
            completion(flag)
            self.completion = nil
        }
    }
}

private let completionKey = "CAAnimationUtils_completion"

public let tiebaCAMediaTimingFunctionSpring = "CAAnimationUtilsSpringCurve"
public let tiebaCAMediaTimingFunctionCustomSpringPrefix = "CAAnimationUtilsSpringCustomCurve"

public extension CAAnimation {
    var completion: ((Bool) -> Void)? {
        get {
            if let delegate = self.delegate as? CALayerAnimationDelegate {
                return delegate.completion
            } else {
                return nil
            }
        } set(value) {
            if let delegate = self.delegate as? CALayerAnimationDelegate {
                delegate.completion = value
            } else {
                self.delegate = CALayerAnimationDelegate(animation: self, completion: value)
            }
        }
    }
}

private func adjustFrameRate(animation: CAAnimation) {
    if #available(iOS 15.0, *) {
        let maxFps = Float(UIScreen.main.maximumFramesPerSecond)
        if maxFps > 61.0 {
            var preferredFps: Float = maxFps
            if let animation = animation as? CABasicAnimation {
                if animation.keyPath == "opacity" {
                    preferredFps = 60.0
                    return
                }
            }
            animation.preferredFrameRateRange = CAFrameRateRange(minimum: 30.0, maximum: preferredFps, preferred: maxFps)
        }
    }
}

public extension CALayer {
    func makeAnimation(from: Any?, to: Any, keyPath: String, timingFunction: String, duration: Double, delay: Double = 0.0, mediaTimingFunction: CAMediaTimingFunction? = nil, removeOnCompletion: Bool = true, additive: Bool = false, completion: ((Bool) -> Void)? = nil) -> CAAnimation {
        if timingFunction.hasPrefix(tiebaCAMediaTimingFunctionCustomSpringPrefix) {
            let components = timingFunction.components(separatedBy: "_")
            let mass: Float
            let stiffness: Float
            let damping: Float
            let initialVelocity: Float
            if components.count >= 5 {
                mass = Float(components[1]) ?? 5.0
                stiffness = Float(components[2]) ?? 900.0
                damping = Float(components[3]) ?? 100.0
                initialVelocity = Float(components[4]) ?? 0.0
            } else {
                mass = 5.0
                stiffness = 900.0
                damping = components.count > 1 ? (Float(components[1]) ?? 100.0) : 100.0
                initialVelocity = components.count > 2 ? (Float(components[2]) ?? 0.0) : 0.0
            }
            
            let animation = CASpringAnimation(keyPath: keyPath)
            animation.fromValue = from
            animation.toValue = to
            animation.isRemovedOnCompletion = removeOnCompletion
            animation.fillMode = .forwards
            if let completion = completion {
                animation.delegate = CALayerAnimationDelegate(animation: animation, completion: completion)
            }
            animation.mass = CGFloat(mass)
            animation.stiffness = CGFloat(stiffness)
            animation.damping = CGFloat(damping)
            animation.initialVelocity = CGFloat(initialVelocity)
            animation.duration = animation.settlingDuration
            animation.timingFunction = CAMediaTimingFunction.init(name: .linear)
            let k = Float(tiebaAnimationDurationFactor())
            var speed: Float = 1.0
            if k != 0 && k != 1 {
                speed = Float(1.0) / k
            }
            animation.speed = speed * Float(animation.duration / duration)
            animation.isAdditive = additive
            if !delay.isZero {
                animation.beginTime = self.convertTime(CACurrentMediaTime(), from: nil) + delay * tiebaAnimationDurationFactor()
                animation.fillMode = .both
            }
            adjustFrameRate(animation: animation)
            
            return animation
        } else if timingFunction == tiebaCAMediaTimingFunctionSpring {
            // 0.3832 = 系统签名时长（上游三处互证，见 TiebaMotionSpec.Spring.signatureDuration）：
            // 请求时长落在这个数上 → 说明发起方就是在跟系统动画同拍，改用 iOS 26 弹簧而不是贝塞尔回退。
            if #available(iOS 26.0, *), abs(duration - TiebaMotionSpec.Spring.signatureDuration) <= 0.0001 {
                let animation = tiebaMake26SpringAnimation(keyPath, duration)
                animation.fromValue = from
                animation.toValue = to
                animation.isRemovedOnCompletion = removeOnCompletion
                animation.fillMode = .forwards
                if let completion {
                    animation.delegate = CALayerAnimationDelegate(animation: animation, completion: completion)
                }
                
                let k = Float(tiebaAnimationDurationFactor())
                var speed: Float = 1.0
                if k != 0 && k != 1 {
                    speed = Float(1.0) / k
                }
                
                animation.speed = speed * Float(animation.duration / duration)
                animation.isAdditive = additive
                
                if !delay.isZero {
                    animation.beginTime = self.convertTime(CACurrentMediaTime(), from: nil) + delay * tiebaAnimationDurationFactor()
                    animation.fillMode = .both
                }
                
                adjustFrameRate(animation: animation)
                
                return animation
            } else if duration == 0.5 {
                let animation = tiebaMakeSpringAnimation(keyPath, duration: duration)
                animation.fromValue = from
                animation.toValue = to
                animation.isRemovedOnCompletion = removeOnCompletion
                animation.fillMode = .forwards
                if let completion = completion {
                    animation.delegate = CALayerAnimationDelegate(animation: animation, completion: completion)
                }
                
                let k = Float(tiebaAnimationDurationFactor())
                var speed: Float = 1.0
                if k != 0 && k != 1 {
                    speed = Float(1.0) / k
                }
                
                animation.speed = speed * Float(animation.duration / duration)
                animation.isAdditive = additive
                
                if !delay.isZero {
                    animation.beginTime = self.convertTime(CACurrentMediaTime(), from: nil) + delay * tiebaAnimationDurationFactor()
                    animation.fillMode = .both
                }
                
                adjustFrameRate(animation: animation)
                
                return animation
            } else {
                let k = Float(tiebaAnimationDurationFactor())
                var speed: Float = 1.0
                if k != 0 && k != 1 {
                    speed = Float(1.0) / k
                }
                
                let animation = CABasicAnimation(keyPath: keyPath)
                animation.fromValue = from
                animation.toValue = to
                animation.duration = duration
                
                animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.380, 0.700, 0.125, 1.000)
                
                animation.isRemovedOnCompletion = removeOnCompletion
                animation.fillMode = .forwards
                animation.speed = speed
                animation.isAdditive = additive
                if let completion = completion {
                    animation.delegate = CALayerAnimationDelegate(animation: animation, completion: completion)
                }
                
                if !delay.isZero {
                    animation.beginTime = self.convertTime(CACurrentMediaTime(), from: nil) + delay * tiebaAnimationDurationFactor()
                    animation.fillMode = .both
                }
                
                adjustFrameRate(animation: animation)
                
                return animation
            }
        } else {
            let k = Float(tiebaAnimationDurationFactor())
            var speed: Float = 1.0
            if k != 0 && k != 1 {
                speed = Float(1.0) / k
            }
            
            let animation = CABasicAnimation(keyPath: keyPath)
            animation.fromValue = from
            animation.toValue = to
            animation.duration = duration
            if let mediaTimingFunction = mediaTimingFunction {
                animation.timingFunction = mediaTimingFunction
            } else {
                switch timingFunction {
                case CAMediaTimingFunctionName.linear.rawValue, CAMediaTimingFunctionName.easeIn.rawValue, CAMediaTimingFunctionName.easeOut.rawValue, CAMediaTimingFunctionName.easeInEaseOut.rawValue, CAMediaTimingFunctionName.default.rawValue:
                    animation.timingFunction = CAMediaTimingFunction(name: CAMediaTimingFunctionName(rawValue: timingFunction))
                default:
                    animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                }
                
            }
            animation.isRemovedOnCompletion = removeOnCompletion
            animation.fillMode = .forwards
            animation.speed = speed
            animation.isAdditive = additive
            if let completion = completion {
                animation.delegate = CALayerAnimationDelegate(animation: animation, completion: completion)
            }
            
            if !delay.isZero {
                animation.beginTime = self.convertTime(CACurrentMediaTime(), from: nil) + delay * tiebaAnimationDurationFactor()
                animation.fillMode = .both
            }
            
            adjustFrameRate(animation: animation)
            
            return animation
        }
    }
    
    func animate(from: Any?, to: Any, keyPath: String, timingFunction: String, duration: Double, delay: Double = 0.0, mediaTimingFunction: CAMediaTimingFunction? = nil, removeOnCompletion: Bool = true, additive: Bool = false, completion: ((Bool) -> Void)? = nil, key: String? = nil) {
        let animation = self.makeAnimation(from: from, to: to, keyPath: keyPath, timingFunction: timingFunction, duration: duration, delay: delay, mediaTimingFunction: mediaTimingFunction, removeOnCompletion: removeOnCompletion, additive: additive, completion: completion)
        self.add(animation, forKey: key ?? (additive ? nil : keyPath))
    }
    
    func animateGroup(_ animations: [CAAnimation], key: String, completion: ((Bool) -> Void)? = nil) {
        let animationGroup = CAAnimationGroup()
        var timeOffset = 0.0
        for animation in animations {
            animation.beginTime = self.convertTime(animation.beginTime, from: nil) + timeOffset
            timeOffset += animation.duration / Double(animation.speed)
        }
        animationGroup.animations = animations
        animationGroup.duration = timeOffset
        if let completion = completion {
            animationGroup.delegate = CALayerAnimationDelegate(animation: animationGroup, completion: completion)
        }
        
        adjustFrameRate(animation: animationGroup)
        
        self.add(animationGroup, forKey: key)
    }
    
    func animateKeyframes(values: [AnyObject], keyTimes: [NSNumber]? = nil, duration: Double, keyPath: String, timingFunction: String = CAMediaTimingFunctionName.linear.rawValue, mediaTimingFunction: CAMediaTimingFunction? = nil, removeOnCompletion: Bool = true, additive: Bool = false, completion: ((Bool) -> Void)? = nil) {
        let k = Float(tiebaAnimationDurationFactor())
        var speed: Float = 1.0
        if k != 0 && k != 1 {
            speed = Float(1.0) / k
        }
        
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        var effectiveKeyTimes: [NSNumber] = []
        if let keyTimes {
            effectiveKeyTimes = keyTimes
        } else {
            for i in 0 ..< values.count {
                if i == 0 {
                    effectiveKeyTimes.append(0.0)
                } else if i == values.count - 1 {
                    effectiveKeyTimes.append(1.0)
                } else {
                    effectiveKeyTimes.append((Double(i) / Double(values.count - 1)) as NSNumber)
                }
            }
        }
        animation.keyTimes = effectiveKeyTimes
        animation.speed = speed
        animation.duration = duration
        animation.isAdditive = additive
        animation.calculationMode = .linear
        if let mediaTimingFunction = mediaTimingFunction {
            animation.timingFunction = mediaTimingFunction
        } else {
            animation.timingFunction = CAMediaTimingFunction(name: CAMediaTimingFunctionName(rawValue: timingFunction))
        }
        animation.isRemovedOnCompletion = removeOnCompletion
        if let completion = completion {
            animation.delegate = CALayerAnimationDelegate(animation: animation, completion: completion)
        }
        
        adjustFrameRate(animation: animation)
        
        self.add(animation, forKey: keyPath)
    }
    
    func springAnimation(from: AnyObject, to: AnyObject, keyPath: String, duration: Double, delay: Double = 0.0, initialVelocity: CGFloat = 0.0, damping: CGFloat = 88.0, removeOnCompletion: Bool = true, additive: Bool = false) -> CABasicAnimation {
        let animation = tiebaMakeSpringBounceAnimation(keyPath, initialVelocity, damping)
        animation.fromValue = from
        animation.toValue = to
        animation.isRemovedOnCompletion = removeOnCompletion
        animation.fillMode = .forwards
        
        let k = Float(tiebaAnimationDurationFactor())
        var speed: Float = 1.0
        if k != 0 && k != 1 {
            speed = Float(1.0) / k
        }
        
        if !delay.isZero {
            animation.beginTime = self.convertTime(CACurrentMediaTime(), from: nil) + delay * tiebaAnimationDurationFactor()
            animation.fillMode = .both
        }
        
        animation.speed = speed * Float(animation.duration / duration)
        animation.isAdditive = additive
        
        adjustFrameRate(animation: animation)
        
        return animation
    }

    func animateSpring(from: Any, to: Any, keyPath: String, duration: Double, delay: Double = 0.0, initialVelocity: CGFloat = 0.0, stiffness: CGFloat = 900.0, damping: CGFloat = 88.0, removeOnCompletion: Bool = true, additive: Bool = false, completion: ((Bool) -> Void)? = nil, key: String? = nil) {
        let animation = tiebaMakeSpringBounceAnimation(keyPath, initialVelocity, damping)
        animation.stiffness = stiffness
        animation.fromValue = from
        animation.toValue = to
        animation.isRemovedOnCompletion = removeOnCompletion
        animation.fillMode = .forwards
        if let completion = completion {
            animation.delegate = CALayerAnimationDelegate(animation: animation, completion: completion)
        }
        
        let k = Float(tiebaAnimationDurationFactor())
        var speed: Float = 1.0
        if k != 0 && k != 1 {
            speed = Float(1.0) / k
        }
        
        if !delay.isZero {
            animation.beginTime = self.convertTime(CACurrentMediaTime(), from: nil) + delay * tiebaAnimationDurationFactor()
            animation.fillMode = .both
        }
        
        animation.speed = speed * Float(animation.duration / duration)
        animation.isAdditive = additive
        
        adjustFrameRate(animation: animation)
        
        self.add(animation, forKey: additive ? key : (key ?? keyPath))
    }
    
    func animateAdditive(from: NSValue, to: NSValue, keyPath: String, key: String, timingFunction: String, mediaTimingFunction: CAMediaTimingFunction? = nil, duration: Double, removeOnCompletion: Bool = true, completion: ((Bool) -> Void)? = nil) {
        let k = Float(tiebaAnimationDurationFactor())
        var speed: Float = 1.0
        if k != 0 && k != 1 {
            speed = Float(1.0) / k
        }
        
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        if let mediaTimingFunction = mediaTimingFunction {
            animation.timingFunction = mediaTimingFunction
        } else {
            animation.timingFunction = CAMediaTimingFunction(name: CAMediaTimingFunctionName(rawValue: timingFunction))
        }
        animation.isRemovedOnCompletion = removeOnCompletion
        animation.fillMode = .forwards
        animation.speed = speed
        animation.isAdditive = true
        if let completion = completion {
            animation.delegate = CALayerAnimationDelegate(animation: animation, completion: completion)
        }
        
        adjustFrameRate(animation: animation)
        
        self.add(animation, forKey: key)
    }
    
    func animateAlpha(from: CGFloat, to: CGFloat, duration: Double, delay: Double = 0.0, timingFunction: String = CAMediaTimingFunctionName.easeInEaseOut.rawValue, mediaTimingFunction: CAMediaTimingFunction? = nil, removeOnCompletion: Bool = true, completion: ((Bool) -> ())? = nil) {
        self.animate(from: NSNumber(value: Float(from)), to: NSNumber(value: Float(to)), keyPath: "opacity", timingFunction: timingFunction, duration: duration, delay: delay, mediaTimingFunction: mediaTimingFunction, removeOnCompletion: removeOnCompletion, completion: completion)
    }
    
    func animateScale(from: CGFloat, to: CGFloat, duration: Double, delay: Double = 0.0, timingFunction: String = CAMediaTimingFunctionName.easeInEaseOut.rawValue, mediaTimingFunction: CAMediaTimingFunction? = nil, removeOnCompletion: Bool = true, additive: Bool = false, completion: ((Bool) -> Void)? = nil) {
        self.animate(from: NSNumber(value: Float(from)), to: NSNumber(value: Float(to)), keyPath: "transform.scale", timingFunction: timingFunction, duration: duration, delay: delay, mediaTimingFunction: mediaTimingFunction, removeOnCompletion: removeOnCompletion, additive: additive, completion: completion)
    }
    
    func animateSublayerScale(from: CGFloat, to: CGFloat, duration: Double, delay: Double = 0.0, timingFunction: String = CAMediaTimingFunctionName.easeInEaseOut.rawValue, mediaTimingFunction: CAMediaTimingFunction? = nil, removeOnCompletion: Bool = true, additive: Bool = false, completion: ((Bool) -> Void)? = nil) {
        self.animate(from: NSNumber(value: Float(from)), to: NSNumber(value: Float(to)), keyPath: "sublayerTransform.scale", timingFunction: timingFunction, duration: duration, delay: delay, mediaTimingFunction: mediaTimingFunction, removeOnCompletion: removeOnCompletion, additive: additive, completion: completion)
    }

    func animateScaleX(from: CGFloat, to: CGFloat, duration: Double, delay: Double = 0.0, timingFunction: String = CAMediaTimingFunctionName.easeInEaseOut.rawValue, mediaTimingFunction: CAMediaTimingFunction? = nil, removeOnCompletion: Bool = true, completion: ((Bool) -> Void)? = nil) {
        self.animate(from: NSNumber(value: Float(from)), to: NSNumber(value: Float(to)), keyPath: "transform.scale.x", timingFunction: timingFunction, duration: duration, delay: delay, mediaTimingFunction: mediaTimingFunction, removeOnCompletion: removeOnCompletion, completion: completion)
    }
    
    func animateScaleY(from: CGFloat, to: CGFloat, duration: Double, delay: Double = 0.0, timingFunction: String = CAMediaTimingFunctionName.easeInEaseOut.rawValue, mediaTimingFunction: CAMediaTimingFunction? = nil, removeOnCompletion: Bool = true, completion: ((Bool) -> Void)? = nil) {
        self.animate(from: NSNumber(value: Float(from)), to: NSNumber(value: Float(to)), keyPath: "transform.scale.y", timingFunction: timingFunction, duration: duration, delay: delay, mediaTimingFunction: mediaTimingFunction, removeOnCompletion: removeOnCompletion, completion: completion)
    }
    
    func animateRotation(from: CGFloat, to: CGFloat, duration: Double, delay: Double = 0.0, timingFunction: String = CAMediaTimingFunctionName.easeInEaseOut.rawValue, mediaTimingFunction: CAMediaTimingFunction? = nil, removeOnCompletion: Bool = true, completion: ((Bool) -> Void)? = nil) {
        self.animate(from: NSNumber(value: Float(from)), to: NSNumber(value: Float(to)), keyPath: "transform.rotation.z", timingFunction: timingFunction, duration: duration, delay: delay, mediaTimingFunction: mediaTimingFunction, removeOnCompletion: removeOnCompletion, completion: completion)
    }
    
    func animatePosition(from: CGPoint, to: CGPoint, duration: Double, delay: Double = 0.0, timingFunction: String = CAMediaTimingFunctionName.easeInEaseOut.rawValue, mediaTimingFunction: CAMediaTimingFunction? = nil, removeOnCompletion: Bool = true, additive: Bool = false, force: Bool = false, completion: ((Bool) -> Void)? = nil) {
        if from == to && !force {
            if let completion = completion {
                completion(true)
            }
            return
        }
        self.animate(from: NSValue(cgPoint: from), to: NSValue(cgPoint: to), keyPath: "position", timingFunction: timingFunction, duration: duration, delay: delay, mediaTimingFunction: mediaTimingFunction, removeOnCompletion: removeOnCompletion, additive: additive, completion: completion)
    }
    
    func animateAnchorPoint(from: CGPoint, to: CGPoint, duration: Double, delay: Double = 0.0, timingFunction: String = CAMediaTimingFunctionName.easeInEaseOut.rawValue, mediaTimingFunction: CAMediaTimingFunction? = nil, removeOnCompletion: Bool = true, additive: Bool = false, force: Bool = false, completion: ((Bool) -> Void)? = nil) {
        if from == to && !force {
            if let completion = completion {
                completion(true)
            }
            return
        }
        self.animate(from: NSValue(cgPoint: from), to: NSValue(cgPoint: to), keyPath: "anchorPoint", timingFunction: timingFunction, duration: duration, delay: delay, mediaTimingFunction: mediaTimingFunction, removeOnCompletion: removeOnCompletion, additive: additive, completion: completion)
    }
    
    func animateBounds(from: CGRect, to: CGRect, duration: Double, delay: Double = 0.0, timingFunction: String, mediaTimingFunction: CAMediaTimingFunction? = nil, removeOnCompletion: Bool = true, additive: Bool = false, force: Bool = false, completion: ((Bool) -> Void)? = nil) {
        if from == to && !force {
            if let completion = completion {
                completion(true)
            }
            return
        }
        self.animate(from: NSValue(cgRect: from), to: NSValue(cgRect: to), keyPath: "bounds", timingFunction: timingFunction, duration: duration, delay: delay, mediaTimingFunction: mediaTimingFunction, removeOnCompletion: removeOnCompletion, additive: additive, completion: completion)
    }

    func animateWidth(from: CGFloat, to: CGFloat, duration: Double, delay: Double = 0.0, timingFunction: String, mediaTimingFunction: CAMediaTimingFunction? = nil, removeOnCompletion: Bool = true, additive: Bool = false, force: Bool = false, completion: ((Bool) -> Void)? = nil) {
        if from == to && !force {
            if let completion = completion {
                completion(true)
            }
            return
        }
        self.animate(from: from as NSNumber, to: to as NSNumber, keyPath: "bounds.size.width", timingFunction: timingFunction, duration: duration, delay: delay, mediaTimingFunction: mediaTimingFunction, removeOnCompletion: removeOnCompletion, additive: additive, completion: completion)
    }

    func animateHeight(from: CGFloat, to: CGFloat, duration: Double, delay: Double = 0.0, timingFunction: String, mediaTimingFunction: CAMediaTimingFunction? = nil, removeOnCompletion: Bool = true, additive: Bool = false, force: Bool = false, completion: ((Bool) -> Void)? = nil) {
        if from == to && !force {
            if let completion = completion {
                completion(true)
            }
            return
        }
        self.animate(from: from as NSNumber, to: to as NSNumber, keyPath: "bounds.size.height", timingFunction: timingFunction, duration: duration, delay: delay, mediaTimingFunction: mediaTimingFunction, removeOnCompletion: removeOnCompletion, additive: additive, completion: completion)
    }
    
    func animateBoundsOriginXAdditive(from: CGFloat, to: CGFloat, duration: Double, delay: Double = 0.0, timingFunction: String = CAMediaTimingFunctionName.easeInEaseOut.rawValue, mediaTimingFunction: CAMediaTimingFunction? = nil, removeOnCompletion: Bool = true, completion: ((Bool) -> Void)? = nil) {
        self.animate(from: from as NSNumber, to: to as NSNumber, keyPath: "bounds.origin.x", timingFunction: timingFunction, duration: duration, delay: delay, mediaTimingFunction: mediaTimingFunction, removeOnCompletion: removeOnCompletion, additive: true, completion: completion)
    }
    
    func animateBoundsOriginYAdditive(from: CGFloat, to: CGFloat, duration: Double, timingFunction: String = CAMediaTimingFunctionName.easeInEaseOut.rawValue, mediaTimingFunction: CAMediaTimingFunction? = nil, removeOnCompletion: Bool = true, completion: ((Bool) -> Void)? = nil) {
        self.animate(from: from as NSNumber, to: to as NSNumber, keyPath: "bounds.origin.y", timingFunction: timingFunction, duration: duration, mediaTimingFunction: mediaTimingFunction, removeOnCompletion: removeOnCompletion, additive: true, completion: completion)
    }
    
    func animateBoundsOriginXAdditive(from: CGFloat, to: CGFloat, duration: Double, mediaTimingFunction: CAMediaTimingFunction) {
        self.animate(from: from as NSNumber, to: to as NSNumber, keyPath: "bounds.origin.x", timingFunction: CAMediaTimingFunctionName.easeInEaseOut.rawValue, duration: duration, mediaTimingFunction: mediaTimingFunction, additive: true)
    }
    
    func animateBoundsOriginYAdditive(from: CGFloat, to: CGFloat, duration: Double, mediaTimingFunction: CAMediaTimingFunction) {
        self.animate(from: from as NSNumber, to: to as NSNumber, keyPath: "bounds.origin.y", timingFunction: CAMediaTimingFunctionName.easeInEaseOut.rawValue, duration: duration, mediaTimingFunction: mediaTimingFunction, additive: true)
    }
    
    func animateBoundsOriginAdditive(from: CGPoint, to: CGPoint, duration: Double, mediaTimingFunction: CAMediaTimingFunction) {
        self.animate(from: NSValue(cgPoint: from), to: NSValue(cgPoint: to), keyPath: "bounds.origin", timingFunction: CAMediaTimingFunctionName.easeInEaseOut.rawValue, duration: duration, mediaTimingFunction: mediaTimingFunction, additive: true)
    }
    
    func animateBoundsOriginAdditive(from: CGPoint, to: CGPoint, duration: Double, timingFunction: String = CAMediaTimingFunctionName.easeInEaseOut.rawValue, mediaTimingFunction: CAMediaTimingFunction? = nil) {
        self.animate(from: NSValue(cgPoint: from), to: NSValue(cgPoint: to), keyPath: "bounds.origin", timingFunction: timingFunction, duration: duration, mediaTimingFunction: mediaTimingFunction, additive: true)
    }
    
    func animateShapeLineWidth(from: CGFloat, to: CGFloat, duration: Double, delay: Double = 0.0, timingFunction: String = CAMediaTimingFunctionName.easeInEaseOut.rawValue, mediaTimingFunction: CAMediaTimingFunction? = nil, removeOnCompletion: Bool = true, additive: Bool = false, completion: ((Bool) -> Void)? = nil) {
        self.animate(from: NSNumber(value: Float(from)), to: NSNumber(value: Float(to)), keyPath: "lineWidth", timingFunction: timingFunction, duration: duration, delay: delay, mediaTimingFunction: mediaTimingFunction, removeOnCompletion: removeOnCompletion, additive: additive, completion: completion)
    }
    
    func animatePositionKeyframes(values: [CGPoint], duration: Double, removeOnCompletion: Bool = true, completion: ((Bool) -> Void)? = nil) {
        self.animateKeyframes(values: values.map { NSValue(cgPoint: $0) }, duration: duration, keyPath: "position")
    }
    
    func animateFrame(from: CGRect, to: CGRect, duration: Double, delay: Double = 0.0, timingFunction: String = CAMediaTimingFunctionName.easeInEaseOut.rawValue, mediaTimingFunction: CAMediaTimingFunction? = nil, removeOnCompletion: Bool = true, additive: Bool = false, force: Bool = false, completion: ((Bool) -> Void)? = nil) {
        if from == to && !force {
            if let completion = completion {
                completion(true)
            }
            return
        }
        var interrupted = false
        var completedPosition = false
        var completedBounds = false
        let partialCompletion: () -> Void = {
            if interrupted || (completedPosition && completedBounds) {
                if let completion = completion {
                    completion(!interrupted)
                }
            }
        }
        
        var fromPosition = CGPoint(x: from.midX, y: from.midY)
        var toPosition = CGPoint(x: to.midX, y: to.midY)
        
        var fromBounds = CGRect(origin: self.bounds.origin, size: from.size)
        var toBounds = CGRect(origin: self.bounds.origin, size: to.size)
        
        if additive {
            fromPosition.x = -(toPosition.x - fromPosition.x)
            fromPosition.y = -(toPosition.y - fromPosition.y)
            toPosition = CGPoint()
            
            fromBounds.size.width = -(toBounds.width - fromBounds.width)
            fromBounds.size.height = -(toBounds.height - fromBounds.height)
            toBounds = CGRect()
        }
        
        self.animatePosition(from: fromPosition, to: toPosition, duration: duration, delay: delay, timingFunction: timingFunction, mediaTimingFunction: mediaTimingFunction, removeOnCompletion: removeOnCompletion, additive: additive, force: force, completion: { value in
            if !value {
                interrupted = true
            }
            completedPosition = true
            partialCompletion()
        })
        self.animateBounds(from: fromBounds, to: toBounds, duration: duration, delay: delay, timingFunction: timingFunction, mediaTimingFunction: mediaTimingFunction, removeOnCompletion: removeOnCompletion, additive: additive, force: force, completion: { value in
            if !value {
                interrupted = true
            }
            completedBounds = true
            partialCompletion()
        })
    }
    
    func cancelAnimationsRecursive(key: String) {
        self.removeAnimation(forKey: key)
        if let sublayers = self.sublayers {
            for layer in sublayers {
                layer.cancelAnimationsRecursive(key: key)
            }
        }
    }
}

// MARK: - 隐藏复杂视图：先快照淡出

public extension UIView {
    /// 要隐藏一个复杂视图（多个子视图/自绘内容）时，先给它拍一张快照放在原位淡出，**再**隐藏真身。
    /// 移植自上游 submodules/ChatListTitleView/Sources/ChatListTitleView.swift:97-111（代理图标）
    /// 与 :120-133（锁图标）：直接 `isHidden = true` 会因为子视图被先行移除而"闪一下"。
    ///
    /// **护栏**：只在可见性真的翻转时才拍（上游 :98 的 `proxyIsHidden != previousProxyIsHidden`
    /// 同款判据）—— 否则每次 layout 都会拍一张图。
    func tiebaSetHidden(_ hidden: Bool, animated: Bool, duration: Double = 0.15) {
        guard isHidden != hidden else { return }
        if hidden {
            if animated, window != nil, bounds.width > 0, bounds.height > 0,
               let snapshot = snapshotView(afterScreenUpdates: false) {
                // 快照要挂在**不受栈布局管辖**的祖先上：直接插进 UIStackView 会被它当子视图
                // 重新摆位（arrangedSubviews 之外的子视图栈不管，但坐标口径会错）。
                var host = superview
                while let current = host, current is UIStackView {
                    host = current.superview
                }
                if let host {
                    snapshot.frame = host.convert(bounds, from: self)
                    host.addSubview(snapshot)
                    snapshot.layer.animateAlpha(from: 1.0, to: 0.0, duration: duration, removeOnCompletion: false, completion: { [weak snapshot] _ in
                        snapshot?.removeFromSuperview()
                    })
                }
            }
            isHidden = true
        } else {
            isHidden = false
            if animated {
                alpha = 0.0
                layer.animateAlpha(from: 0.0, to: 1.0, duration: duration)
                alpha = 1.0
            }
        }
    }
}
