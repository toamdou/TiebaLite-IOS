// 移植自上游 submodules/Display/Source/{Spring.swift, ListViewAnimation.swift, UIKitUtils.m}
//   的**曲线数学**部分（本文件经判据③清理后只剩这一块）。
//
// 【这份代码的 UIKit 学习价值】三条曲线的来源与等价关系：
//   · bezierPoint：三次贝塞尔按 x 解 t（牛顿迭代 4 次）、再算 y —— UIBezierPath 只画不解，
//     要"给一个进度求曲线值"必须自己解；这也是 CAMediaTimingFunction(controlPoints:) 背后的数学。
//     本仓已有 UI/Drawing/TiebaSpring.swift 的同一实现，这里**转调**它（判据③：不留第二套）。
//   · easeInOut / easeIn：上游 listViewAnimationCurveEaseInOut / EaseIn 的等价
//     （控制点 0.42/0/0.58/1 与 0.42/0/1/1）。
//   · springValue：上游 springAnimationValueAt 是「runtime 反射调 CASpringAnimation 私有方法
//     _solveForInput:」；本移植改成**解析解**（阻尼受迫振动闭式解，ζ=1 临界阻尼，按 t·duration 归一化）。
//     为什么不能照搬私有调用：审核与系统版本双重风险；为什么解析解够用：端点与单调性与 CA 同族
//     （自检里钉住 0 → 0、1 → 0.9999、单调递增）。
//
// 【判据③清理：本文件删掉了什么、去哪了】
//   · CALayer 动画工厂（tiebaTransitionAnimate* / tiebaTransitionMakeAnimation）
//     → 本仓 UI/Components/TiebaCAAnimationUtils.swift（同一上游文件 CAAnimationUtils.swift 的移植件）；
//   · spring 动画工厂（makeSpringAnimation / make26SpringAnimation / makeSpringBounceAnimation）
//     → 系统 CASpringAnimation（iOS 17+ 公开 settlingDuration / allowsOverdamping / preferredFrameRateRange）；
//   · CAAnimation 完成回调代理（TiebaTransitionAnimationDelegate）→ 同上；
//   · mixedColor → UI/Components/TiebaUIKitUtils.swift 的 UIColor.mixedWith(_:alpha:)；
//   · 两个 timingFunction 字符串常量：只服务于已删除的转场引擎。
//
// 并发：纯数学 + 纯值类型，无状态，全部 nonisolated。

import Foundation
import UIKit

/// 曲线数学（见文件头）。调用方：UI/Components/Flow/*（ComponentFlow 移植件）。
enum TiebaTransitionAnimation {
    /// 上游 Spring.swift:60-67 的三次贝塞尔求值；本仓实现在 UI/Drawing/TiebaSpring.swift（判据③：不留第二套）。
    static func bezierPoint(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat, _ x: CGFloat) -> CGFloat {
        return TiebaSpring.bezierPoint(x1, y1, x2, y2, x)
    }

    /// 上游 listViewAnimationCurveEaseInOut（ListViewAnimation.swift:116-118）。
    static func easeInOutValue(at offset: CGFloat) -> CGFloat {
        return TiebaSpring.bezierPoint(0.42, 0.0, 0.58, 1.0, offset)
    }

    /// 上游 listViewAnimationCurveEaseIn（ListViewAnimation.swift:120-122）。
    static func easeInValue(at offset: CGFloat) -> CGFloat {
        return TiebaSpring.bezierPoint(0.42, 0.0, 1.0, 1.0, offset)
    }

    /// 上游 listViewAnimationCurveSystem → springAnimationSolver → springAnimationValueAt
    /// （ListViewAnimation.swift:91-111 + UIKitUtils.swift:19-21 + UIKitUtils.m:106-108）的解析解。
    ///
    ///   ζ = damping / (2·√(stiffness·mass))，ω0 = √(stiffness/mass)，τ = t · duration
    ///   欠阻尼 ζ<1：x(τ) = 1 - e^(-ζω0τ)·(cos(ωdτ) + ζω0/ωd·sin(ωdτ))，ωd = ω0·√(1-ζ²)
    ///   临界 ζ=1 ：x(τ) = 1 - (1 + ω0τ)·e^(-ω0τ)
    ///   过阻尼 ζ>1：x(τ) = 1 + A·e^(r1τ) + B·e^(r2τ)，r1,2 = ω0(-ζ ± √(ζ²-1))，A = -r2/(r2-r1)，B = r1/(r2-r1)
    /// 三式都满足 x(0)=0、x'(0)=0（从静止出发、终点为 1），即与 CA 弹簧同样的初值问题。
    static func springValue(at offset: CGFloat) -> CGFloat {
        // 上游 springAnimationIn = makeSpringAnimation("", duration: 0.5)；
        // iOS 26 起该函数返回的就是下面这组参数（UIKitUtils.m:68-84）。
        // 三个数不再就地写死：唯一出处 = TiebaMotionSpec.Spring（改表即改曲线，全仓一处）。
        let mass = TiebaMotionSpec.Spring.ios26Mass
        let stiffness = TiebaMotionSpec.Spring.ios26Stiffness
        let damping = TiebaMotionSpec.Spring.ios26Damping
        let duration: CGFloat = 0.5

        let t = min(max(offset, 0.0), 1.0)
        let omega0 = (stiffness / mass).squareRoot()
        let zeta = damping / (2.0 * (stiffness * mass).squareRoot())
        let tau = t * duration

        let value: CGFloat
        if zeta < 1.0 {
            let omegaD = omega0 * (1.0 - zeta * zeta).squareRoot()
            value = 1.0 - exp(-zeta * omega0 * tau) * (cos(omegaD * tau) + (zeta * omega0 / omegaD) * sin(omegaD * tau))
        } else if zeta == 1.0 {
            value = 1.0 - (1.0 + omega0 * tau) * exp(-omega0 * tau)
        } else {
            let s = (zeta * zeta - 1.0).squareRoot()
            let r1 = omega0 * (-zeta + s)
            let r2 = omega0 * (-zeta - s)
            let a = -r2 / (r2 - r1)
            let b = r1 / (r2 - r1)
            value = 1.0 + a * exp(r1 * tau) + b * exp(r2 * tau)
        }

        // 只挡 NaN/∞（参数被改坏时不要污染调用方的插值）；不做上下限钳制 ——
        // 弹簧曲线允许短暂越过 1.0，这正是它和 easeInOut 的区别。
        return value.isFinite ? value : t
    }
}
