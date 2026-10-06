// TiebaBakedKeyframes —— 把缓动"烘"进关键帧数组，播放端一律 .linear。
//
// 移植自上游 submodules/LensTransition/Sources/LensTransitionContainer.swift
//   :961-1015（前进）/ :1347-1420（后退）：那些 CAKeyframeAnimation **全都不写曲线**，
//   一律 timingFunction = .linear，缓动在**生成采样数组时**就应用掉了。
//
// 为什么必须这样（报告 37 B1）：
//   CAKeyframeAnimation 只有**一个** timingFunction，它作用在整条 keyframe 序列上
//   （keyTimes 之间是线性插值）。所以"尺寸先快后慢、位置先慢后快、透明度最后 20% 才收尾"
//   用单一曲线做不到；把缓动烘进采样点，就能给每条属性配自己的节奏，同时所有属性
//   共享同一个 duration —— 这正是转场"高级感"的来源（各属性不同步）。
//
// 本仓调用形态（三步，播放端复用 TiebaCAAnimationUtils 的 animateKeyframes，默认已是 linear）：
//   let values = TiebaBakedKeyframes.sizes(from: a, to: b, easing: .easeOutStrong)
//   layer.animateKeyframes(values: values, duration: d, keyPath: "bounds.size")
//   多条属性各生成各的数组、同一个 duration —— 就是"属性家族"各走各的节奏。
//
// 数学复用 UI/Drawing/TiebaSpring.swift 的 cubic-bezier 求值（判据③：不留第二套牛顿迭代）。
// 并发：纯值类型 + 纯函数，全部 nonisolated。

import CoreGraphics
import Foundation
import QuartzCore

/// 一条缓动曲线（cubic-bezier 控制点，与 CAMediaTimingFunction(controlPoints:) 同参）。
struct TiebaBakedEasing: Sendable {
    let x1: CGFloat
    let y1: CGFloat
    let x2: CGFloat
    let y2: CGFloat

    init(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) {
        self.x1 = x1
        self.y1 = y1
        self.x2 = x2
        self.y2 = y2
    }

    /// 与 CAMediaTimingFunctionName 同名档位的控制点（UIKit 文档给出的那三组）。
    static let linear = TiebaBakedEasing(0.0, 0.0, 1.0, 1.0)
    static let easeIn = TiebaBakedEasing(0.42, 0.0, 1.0, 1.0)
    static let easeOut = TiebaBakedEasing(0.0, 0.0, 0.58, 1.0)
    static let easeInEaseOut = TiebaBakedEasing(0.42, 0.0, 0.58, 1.0)
    /// 几何专用强出场曲线（上游 36 号报告同族控制点 0.32/0.72/0/1）。
    static let easeOutStrong = TiebaBakedEasing(0.32, 0.72, 0.0, 1.0)

    /// 归一化进度 → 缓动后的值。
    func value(at fraction: CGFloat) -> CGFloat {
        let t = min(max(fraction, 0.0), 1.0)
        return TiebaSpring.bezierPoint(x1, y1, x2, y2, t)
    }

    /// 采样 count 个点（含两端）的**缓动后进度**：第 i 点 = value(at: i / (count - 1))。
    func progress(count: Int) -> [CGFloat] {
        let count = max(count, 2)
        return (0 ..< count).map { index in
            self.value(at: CGFloat(index) / CGFloat(count - 1))
        }
    }
}

/// 关键帧数组生成（报告 37 B1）。count 默认 30 —— 上游 LensTransition 的采样点数；
/// 0.2s 级的短动画用 8–12 个点即可（keyTimes 之间是线性插值，误差随点距平方衰减）。
enum TiebaBakedKeyframes {
    static let defaultCount = 30

    static func numbers(from: CGFloat, to: CGFloat, count: Int = defaultCount, easing: TiebaBakedEasing) -> [NSNumber] {
        return easing.progress(count: count).map { NSNumber(value: Double(from + (to - from) * $0)) }
    }

    /// 给"本来就是一组值"的属性用（例如模糊半径 8 → 0，中途要按曲线落到 0）。
    static func numbers(_ values: [CGFloat], easing: TiebaBakedEasing) -> [NSNumber] {
        let progress = easing.progress(count: max(values.count, 2))
        guard values.count > 1 else {
            return values.map { NSNumber(value: Double($0)) }
        }
        return progress.map { fraction in
            let position = fraction * CGFloat(values.count - 1)
            let lower = Int(floor(position))
            let upper = min(lower + 1, values.count - 1)
            let local = position - CGFloat(lower)
            return NSNumber(value: Double(values[lower] + (values[upper] - values[lower]) * local))
        }
    }

    static func points(from: CGPoint, to: CGPoint, count: Int = defaultCount, easing: TiebaBakedEasing) -> [NSValue] {
        return easing.progress(count: count).map { fraction in
            NSValue(cgPoint: CGPoint(x: from.x + (to.x - from.x) * fraction, y: from.y + (to.y - from.y) * fraction))
        }
    }

    static func sizes(from: CGSize, to: CGSize, count: Int = defaultCount, easing: TiebaBakedEasing) -> [NSValue] {
        return easing.progress(count: count).map { fraction in
            NSValue(cgSize: CGSize(width: from.width + (to.width - from.width) * fraction, height: from.height + (to.height - from.height) * fraction))
        }
    }

    static func rects(from: CGRect, to: CGRect, count: Int = defaultCount, easing: TiebaBakedEasing) -> [NSValue] {
        return easing.progress(count: count).map { fraction in
            NSValue(cgRect: CGRect(
                x: from.origin.x + (to.origin.x - from.origin.x) * fraction,
                y: from.origin.y + (to.origin.y - from.origin.y) * fraction,
                width: from.width + (to.width - from.width) * fraction,
                height: from.height + (to.height - from.height) * fraction
            ))
        }
    }
}
