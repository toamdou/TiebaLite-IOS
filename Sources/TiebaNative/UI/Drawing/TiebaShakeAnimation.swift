// 移植自上游: submodules/Display/Source/ShakeAnimation.swift :1-88
//
// 作用：两个 CALayer 扩展 —— 输入框报错的左右抖动（addShakeAnimation），
//       列表拖拽重排时那种「轻微持续摇晃」（addReorderingShaking）。
//
// 改动（逐条）：
//   1. 删除上游的 \`private final class LinkHelperClass: NSObject\`。
//      上游注释写明它存在的唯一理由是「文件里至少有一个 ObjC 类，否则会被链接器整文件剥掉」——
//      那是 ObjC 运行时的符号剥离规则。本工程纯 Swift + Bazel swift_library，没有这个问题。
//   2. \`UIView.animationDurationFactor()\` → \`TiebaDrawingMetrics.animationDurationFactor()\`
//      （本仓同模块已有该扩展方法，避免重复定义；本工程取真机语义恒为 1.0，
//       所以 \`speed\` 那两段分支实际永远走 k == 1 的路径，代码保留以对齐上游）。
//   3. 扩展方法与上游**同名**（addShakeAnimation / addReorderingShaking）：这是本目录交付的 API 面，
//      改名会让调用方无法和上游对照；且本仓全库没有同名符号（已核对），不会重名。
//   4. \`arc4random()\` 保持：它是不需要显式播种的 CSPRNG，上游用它给每个图层的抖动相位加随机偏移，
//      避免所有 cell 同相位一起晃。语义上不需要换成 SystemRandomNumberGenerator。
//   5. Swift 6：两个方法都在主线程使用（CALayer 操作），但 CALayer 不是 @MainActor 类型，
//      所以方法保持 nonisolated —— 与上游可用性一致，也没有任何绕过标注。

import Foundation
import UIKit
import QuartzCore

extension CALayer {
    /// 上游 ShakeAnimation.swift:9-42：左右抖动。
    /// - Parameters:
    ///   - amplitude: 振幅（pt）
    ///   - duration: 总时长
    ///   - count: 抖动次数（正负交替）
    ///   - decay: 是否逐次衰减（1/i），报错抖动一般不开，拖拽提示一般开着
    func addShakeAnimation(amplitude: CGFloat = 3.0, duration: Double = 0.3, count: Int = 4, decay: Bool = false) {
        let k = Float(TiebaDrawingMetrics.animationDurationFactor())
        var speed: Float = 1.0
        if k != 0 && k != 1 {
            // 系统开了「减弱动态效果」/模拟器 Slow Animations 时把动画调慢。
            speed = Float(1.0) / k
        }

        let animation = CAKeyframeAnimation(keyPath: "position.x")
        var values: [CGFloat] = []
        values.append(0.0)
        for i in 0 ..< count {
            let sign: CGFloat = (i % 2 == 0) ? 1.0 : -1.0
            let multiplier = decay ? 1.0 / CGFloat(i + 1) : 1.0
            values.append(amplitude * sign * multiplier)
        }
        values.append(0.0)
        animation.values = values.map { ($0 as NSNumber) as AnyObject }
        var keyTimes: [NSNumber] = []
        for i in 0 ..< values.count {
            if i == 0 {
                keyTimes.append(0.0)
            } else if i == values.count - 1 {
                keyTimes.append(1.0)
            } else {
                keyTimes.append((Double(i) / Double(values.count - 1)) as NSNumber)
            }
        }
        animation.keyTimes = keyTimes
        animation.speed = speed
        animation.duration = duration
        // isAdditive：叠加在当前 position 上，不去改模型值（动画结束自动还原）。
        animation.isAdditive = true

        self.add(animation, forKey: "shake")
    }

    /// 上游 ShakeAnimation.swift:44-87：持续轻微摇晃（列表重排提示）。
    /// 两条动画都设了 repeatCount = greatestFiniteMagnitude 且 isRemovedOnCompletion = false，
    /// 所以是「一直晃到调用方主动 removeAnimation(forKey:) 为止」。
    func addReorderingShaking() {
        func degreesToRadians(_ x: CGFloat) -> CGFloat {
            return .pi * x / 180.0
        }

        let duration: Double = 0.4
        let displacement: CGFloat = 1.0
        let degreesRotation: CGFloat = 2.0

        let negativeDisplacement = -1.0 * displacement
        let position = CAKeyframeAnimation.init(keyPath: "position")
        position.beginTime = 0.8
        position.duration = duration
        position.values = [
            NSValue(cgPoint: CGPoint(x: negativeDisplacement, y: negativeDisplacement)),
            NSValue(cgPoint: CGPoint(x: 0, y: 0)),
            NSValue(cgPoint: CGPoint(x: negativeDisplacement, y: 0)),
            NSValue(cgPoint: CGPoint(x: 0, y: negativeDisplacement)),
            NSValue(cgPoint: CGPoint(x: negativeDisplacement, y: negativeDisplacement))
        ]
        position.calculationMode = .linear
        position.isRemovedOnCompletion = false
        position.repeatCount = Float.greatestFiniteMagnitude
        // 相位随机：不然一屏 cell 会整齐划一地晃（上游同款写法）。
        position.beginTime = CFTimeInterval(Float(arc4random()).truncatingRemainder(dividingBy: Float(25)) / Float(100))
        position.isAdditive = true

        let transform = CAKeyframeAnimation.init(keyPath: "transform")
        transform.beginTime = 2.6
        transform.duration = 0.3
        transform.valueFunction = CAValueFunction(name: CAValueFunctionName.rotateZ)
        transform.values = [
            degreesToRadians(-1.0 * degreesRotation),
            degreesToRadians(degreesRotation),
            degreesToRadians(-1.0 * degreesRotation)
        ]
        transform.calculationMode = .linear
        transform.isRemovedOnCompletion = false
        transform.repeatCount = Float.greatestFiniteMagnitude
        transform.isAdditive = true
        transform.beginTime = CFTimeInterval(Float(arc4random()).truncatingRemainder(dividingBy: Float(25)) / Float(100))

        self.add(position, forKey: "shaking_position")
        self.add(transform, forKey: "shaking_rotation")
    }
}
