// 涟漪位移（纯函数）。
//
// 移植自上游 submodules/SpaceWarpView/Sources/SpaceWarpView.swift:110-182 —— **只搬数学**。
// 上游整套效果靠私有 `_UICABackdropLayer` + displacementMap 滤镜（同文件 :28-79 的运行时反射），
// 本仓铁律不引私有 API。但这段公式是纯标量计算，驱动任何**公开**手段都一样
//（粒子 / 图层网格 / CATransform3D 位移），所以按公式整段搬下来，渲染交给调用方。
//
// 三个要点（这也是"涟漪"与"整块缩放"的分界）：
//   1. **到达延迟 = 距离 ÷ 速度**：波前以恒定速度外扩，不是所有点同时动；
//   2. 幅度 = amplitude · sin(frequency · t) · exp(−decay · t)，且取绝对值配符号（波峰波谷对称）；
//   3. 近场（distance < nearRadius）用 smoothstep 把幅度从 minScale 抬到 1 ——
//      圆心附近所有点的方向几乎退化，不补偿就会看到中心"死掉"。
//
// 并发：全部是 nonisolated 纯值计算（调用方可能在显示链接回调里逐帧算）。

import UIKit

/// 涟漪参数（上游 :110-122 的 RippleParams）。
public struct TiebaRippleParams: Sendable {
    /// 位移峰值（pt）。
    public var amplitude: CGFloat
    /// 时间频率（rad/s）。
    public var frequency: CGFloat
    /// 指数衰减系数（1/s）。
    public var decay: CGFloat
    /// 波前速度（pt/s）。
    public var speed: CGFloat

    public init(amplitude: CGFloat, frequency: CGFloat, decay: CGFloat, speed: CGFloat) {
        self.amplitude = amplitude
        self.frequency = frequency
        self.decay = decay
        self.speed = speed
    }
}

private nonisolated func tiebaRippleLength(_ v: CGPoint) -> CGFloat {
    (v.x * v.x + v.y * v.y).squareRoot()
}

/// 给定像素位置、圆心与全局时间，返回该点的**位移**（上游 :129-182 逐行同式）。
///
/// 上游还返回一个 zOffset（给 Metal 的高度图用），本仓没有那一层，故不保留 —— 位移就是全部。
public nonisolated func tiebaRippleOffset(
    position: CGPoint,
    origin: CGPoint,
    time: CGFloat,
    params: TiebaRippleParams
) -> CGPoint {
    let delta = CGPoint(x: position.x - origin.x, y: position.y - origin.y)
    let distance = tiebaRippleLength(delta)

    // 圆心本身没有方向可言（上游 :138-140）。
    if distance < 1.0 {
        return CGPoint()
    }

    // 波前到达该点需要的时间（上游 :142-148）。
    let delay = distance / params.speed
    let localTime = max(0.0, time - delay)

    // 正弦 × 指数衰减，取绝对值配符号（上游 :150-158）。
    var rippleAmount = params.amplitude * sin(params.frequency * localTime) * exp(-params.decay * localTime)
    let absAmount = abs(rippleAmount)
    rippleAmount = rippleAmount < 0.0 ? -absAmount : absAmount

    // 近场补偿：距离越近幅度越小，最小值 minScale（上游 :160-167）。
    let nearRadius: CGFloat = 60.0
    let minScale: CGFloat = 0.3
    if distance < nearRadius {
        let t = max(0.0, min(1.0, distance / nearRadius))
        let smooth = t * t * (3.0 - 2.0 * t)
        rippleAmount *= minScale + (1.0 - minScale) * smooth
    }

    // 沿半径方向、离圆心越近推得越远（上游 :169-181）。
    let normal = CGPoint(x: delta.x / distance, y: delta.y / distance)
    return CGPoint(x: normal.x * -rippleAmount, y: normal.y * -rippleAmount)
}
