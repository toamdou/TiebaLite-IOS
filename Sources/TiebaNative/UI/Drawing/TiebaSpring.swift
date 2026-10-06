// 移植自上游: submodules/Display/Source/Spring.swift :1-67
//
// 作用：把 CSS 那套 cubic-bezier(x1,y1,x2,y2) 的**求值**搬到 Swift（牛顿迭代反解 t），
//       本仓做「自定义缓动曲线」时不用再去啃 CAMediaTimingFunction 只能给控制点、取不到值的限制。
//
// 改动（逐条）：
//   1. 全部收进 \`TiebaSpring\` 命名空间（\`bezierPoint\` 单独放全局太容易和别处撞名）。
//      上游 \`public func bezierPoint(_:_:_:_:_:)\` → \`TiebaSpring.bezierPoint(_:_:_:_:_:)\`，参数顺序不变。
//   2. 上游那几个私有辅助函数 a/b/c/calcBezier/calcSlope/getTForX 改成 TiebaSpring 的 private static，
//      函数体逐行照搬（牛顿迭代固定 4 次，与上游一致 —— 加迭代次数收益很小但要改行为，不做）。
//   3. Swift 6：纯函数 + Sendable 值类型，全部 nonisolated。
//      （上游的 ViewportItemSpring 未移植落库：本仓没有 Viewport 子系统，全仓 0 调用方。）

import Foundation
import UIKit
import CoreGraphics


enum TiebaSpring {
    // 上游 :17-40：cubic-bezier 展开成多项式系数。
    private static func a(_ a1: CGFloat, _ a2: CGFloat) -> CGFloat {
        return 1.0 - 3.0 * a2 + 3.0 * a1
    }

    private static func b(_ a1: CGFloat, _ a2: CGFloat) -> CGFloat {
        return 3.0 * a2 - 6.0 * a1
    }

    private static func c(_ a1: CGFloat) -> CGFloat {
        return 3.0 * a1
    }

    private static func calcBezier(_ t: CGFloat, _ a1: CGFloat, _ a2: CGFloat) -> CGFloat {
        return ((a(a1, a2) * t + b(a1, a2)) * t + c(a1)) * t
    }

    private static func calcSlope(_ t: CGFloat, _ a1: CGFloat, _ a2: CGFloat) -> CGFloat {
        return 3.0 * a(a1, a2) * t * t + 2.0 * b(a1, a2) * t + c(a1)
    }

    /// 上游 :42-58：已知 x 反解参数 t（牛顿迭代，固定 4 轮）。
    private static func getTForX(_ x: CGFloat, _ x1: CGFloat, _ x2: CGFloat) -> CGFloat {
        var t = x
        var i = 0
        while i < 4 {
            let currentSlope = calcSlope(t, x1, x2)
            if currentSlope == 0.0 {
                return t
            } else {
                let currentX = calcBezier(t, x1, x2) - x
                t -= currentX / currentSlope
            }

            i += 1
        }

        return t
    }

    /// 上游 :60-67：求 cubic-bezier(x1,y1,x2,y2) 在 x 处的值。
    nonisolated static func bezierPoint(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat, _ x: CGFloat) -> CGFloat {
        var value = calcBezier(getTForX(x, x1, x2), y1, y2)
        // 迭代解在接近 1 时会略微过冲，夹回 1.0（上游同款）。
        if value >= 0.997 {
            value = 1.0
        }
        return value
    }
}
