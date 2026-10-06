// TiebaRoundedRectGeometry —— 每角独立圆角的**钳制 + 路径**，以及圆角矩形的内外判定/最近边界点。
//
// 移植自上游两处（报告 37 A6 / A7 / B3）：
//   · GlassBackgroundComponent.swift:322-357（clampedCornerRadii）、:359-399（generateRoundedRectPath，
//     半径≈0 的退化分支在 :363-370）；
//   · LensTransitionContainer.swift:260-288（isPointInsideRoundedRect）、:290-385（nearestBoundaryPointOnRoundedRect）。
//
// 三条**必须遵守**的规则（都不是风格问题）：
//   ① 同一侧相邻两半径之和 > 该边长时，路径会自交（小尺寸帧上出尖角毛刺/半个角消失）。
//      上游按"四条边各自允许的最大比例取最小值"把**四个半径同乘**这一个比例，而不是逐角截断
//      ——逐角截断会改变角的相对比例，动画中看起来像"角在跳"。A6/①。
//   ② 半径 ≤ 0 的角**必须走两段 addLine**，不能 addArc(radius: 0)：退化弧会缺角。
//      "半径从 0 动画到 N"时，0 那一帧就是最容易崩形状的一帧。A7/②。
//   ③ 圆角矩形的"最近边界点"要分别算 4 条边 + 4 段弧共 8 个候选点再取最近（B3），
//      只按"边"算会在圆角处给出形状外的点（源被"吸"出目标轮廓外）。
//
// 并发：纯值类型 + 纯函数，全部 nonisolated。

import CoreGraphics
import Foundation
import UIKit

/// 四角半径（左上/右上/左下/右下）。A6/上游 CornerRadii。
struct TiebaCornerRadii: Equatable, Sendable {
    var topLeft: CGFloat
    var topRight: CGFloat
    var bottomLeft: CGFloat
    var bottomRight: CGFloat

    init(topLeft: CGFloat, topRight: CGFloat, bottomLeft: CGFloat, bottomRight: CGFloat) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomLeft = bottomLeft
        self.bottomRight = bottomRight
    }

    init(radius: CGFloat) {
        self.init(topLeft: radius, topRight: radius, bottomLeft: radius, bottomRight: radius)
    }

    var maximum: CGFloat {
        return max(max(topLeft, topRight), max(bottomLeft, bottomRight))
    }

    /// 同一比例缩放（A6/①：钳制必须是**等比**的）。
    func scaled(by scale: CGFloat) -> TiebaCornerRadii {
        return TiebaCornerRadii(
            topLeft: topLeft * scale,
            topRight: topRight * scale,
            bottomLeft: bottomLeft * scale,
            bottomRight: bottomRight * scale
        )
    }
}

enum TiebaRoundedRectGeometry {
    /// A6：把四角半径钳到"同一侧相邻两半径之和 ≤ 该边长"（超出则四角**等比**缩小）。
    nonisolated static func clampedCornerRadii(size: CGSize, cornerRadii: TiebaCornerRadii) -> TiebaCornerRadii {
        let size = CGSize(width: max(0.0, size.width), height: max(0.0, size.height))
        let radii = TiebaCornerRadii(
            topLeft: max(0.0, cornerRadii.topLeft),
            topRight: max(0.0, cornerRadii.topRight),
            bottomLeft: max(0.0, cornerRadii.bottomLeft),
            bottomRight: max(0.0, cornerRadii.bottomRight)
        )

        func scaleFor(edgeLength: CGFloat, _ lhs: CGFloat, _ rhs: CGFloat) -> CGFloat {
            let sum = lhs + rhs
            if sum <= edgeLength || sum.isZero {
                return 1.0
            }
            return edgeLength / sum
        }

        let scale = min(
            1.0,
            scaleFor(edgeLength: size.width, radii.topLeft, radii.topRight),
            scaleFor(edgeLength: size.width, radii.bottomLeft, radii.bottomRight),
            scaleFor(edgeLength: size.height, radii.topLeft, radii.bottomLeft),
            scaleFor(edgeLength: size.height, radii.topRight, radii.bottomRight)
        )
        return scale < 1.0 ? radii.scaled(by: scale) : radii
    }

    /// A7/②：半径 ≤ 0 的角走两段直线（addArc(radius: 0) 会产生退化弧 → 缺角）。
    /// 半径在生成前统一过一遍 A6 的钳制（上游 :360 同款）。
    nonisolated static func path(rect: CGRect, cornerRadii: TiebaCornerRadii) -> CGPath {
        let radii = clampedCornerRadii(size: rect.size, cornerRadii: cornerRadii)
        let path = CGMutablePath()

        func addCorner(tangent1End: CGPoint, tangent2End: CGPoint, radius: CGFloat) {
            if radius > CGFloat.ulpOfOne {
                path.addArc(tangent1End: tangent1End, tangent2End: tangent2End, radius: radius)
            } else {
                path.addLine(to: tangent1End)
                path.addLine(to: tangent2End)
            }
        }

        path.move(to: CGPoint(x: rect.minX, y: rect.minY + radii.topLeft))
        addCorner(
            tangent1End: CGPoint(x: rect.minX, y: rect.minY),
            tangent2End: CGPoint(x: rect.minX + radii.topLeft, y: rect.minY),
            radius: radii.topLeft
        )
        path.addLine(to: CGPoint(x: rect.maxX - radii.topRight, y: rect.minY))
        addCorner(
            tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
            tangent2End: CGPoint(x: rect.maxX, y: rect.minY + radii.topRight),
            radius: radii.topRight
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radii.bottomRight))
        addCorner(
            tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
            tangent2End: CGPoint(x: rect.maxX - radii.bottomRight, y: rect.maxY),
            radius: radii.bottomRight
        )
        path.addLine(to: CGPoint(x: rect.minX + radii.bottomLeft, y: rect.maxY))
        addCorner(
            tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
            tangent2End: CGPoint(x: rect.minX, y: rect.maxY - radii.bottomLeft),
            radius: radii.bottomLeft
        )
        path.closeSubpath()
        return path
    }

    nonisolated static func path(size: CGSize, cornerRadii: TiebaCornerRadii) -> CGPath {
        return path(rect: CGRect(origin: CGPoint(), size: size), cornerRadii: cornerRadii)
    }

    nonisolated static func path(rect: CGRect, cornerRadius: CGFloat) -> CGPath {
        return path(rect: rect, cornerRadii: TiebaCornerRadii(radius: cornerRadius))
    }

    // MARK: - B3：圆角矩形的内外判定与最近边界点

    /// 上游 LensTransitionContainer.swift:260-288。rectCenter 是矩形中心（不是原点）。
    nonisolated static func contains(_ point: CGPoint, rectCenter: CGPoint, rectSize: CGSize, cornerRadius: CGFloat) -> Bool {
        let halfWidth = rectSize.width * 0.5
        let halfHeight = rectSize.height * 0.5
        if halfWidth <= 0.0 || halfHeight <= 0.0 {
            return false
        }
        let radius = max(0.0, min(cornerRadius, min(halfWidth, halfHeight)))
        let localX = point.x - rectCenter.x
        let localY = point.y - rectCenter.y
        let absX = abs(localX)
        let absY = abs(localY)
        if absX > halfWidth || absY > halfHeight {
            return false
        }
        if absX <= halfWidth - radius || absY <= halfHeight - radius {
            return true
        }
        let cornerCenter = CGPoint(
            x: (halfWidth - radius) * (localX >= 0.0 ? 1.0 : -1.0),
            y: (halfHeight - radius) * (localY >= 0.0 ? 1.0 : -1.0)
        )
        let dx = localX - cornerCenter.x
        let dy = localY - cornerCenter.y
        return dx * dx + dy * dy <= radius * radius
    }

    /// B3：矩形上离 point 最近的边界点（4 条边 + 4 段圆角弧共 8 个候选，取最近）。
    /// 上游 LensTransitionContainer.swift:290-385。"源被吸入目标"这类转场用它决定每个采样点
    /// 该往目标的哪条边走；只算直边会在圆角处给出形状外的点。
    nonisolated static func nearestBoundaryPoint(
        to point: CGPoint,
        rectCenter: CGPoint,
        rectSize: CGSize,
        cornerRadius: CGFloat
    ) -> CGPoint {
        func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
            return max(lower, min(upper, value))
        }
        func normalizedAngle(_ angle: CGFloat) -> CGFloat {
            let twoPi = CGFloat.pi * 2.0
            var value = angle.truncatingRemainder(dividingBy: twoPi)
            if value < 0.0 {
                value += twoPi
            }
            return value
        }
        func clampedRangeValue(_ value: CGFloat, _ a: CGFloat, _ b: CGFloat) -> CGFloat {
            return a <= b ? clamp(value, a, b) : (a + b) * 0.5
        }
        func dist2(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
            let dx = a.x - b.x
            let dy = a.y - b.y
            return dx * dx + dy * dy
        }

        let halfWidth = rectSize.width * 0.5
        let halfHeight = rectSize.height * 0.5
        if halfWidth <= 0.0 || halfHeight <= 0.0 {
            return rectCenter
        }
        let radius = max(0.0, min(cornerRadius, min(halfWidth, halfHeight)))
        let localPoint = CGPoint(x: point.x - rectCenter.x, y: point.y - rectCenter.y)

        var candidates: [CGPoint] = []
        candidates.reserveCapacity(radius > 0.0 ? 8 : 4)
        let minX = -halfWidth
        let maxX = halfWidth
        let minY = -halfHeight
        let maxY = halfHeight

        candidates.append(CGPoint(x: clampedRangeValue(localPoint.x, minX + radius, maxX - radius), y: minY))
        candidates.append(CGPoint(x: clampedRangeValue(localPoint.x, minX + radius, maxX - radius), y: maxY))
        candidates.append(CGPoint(x: minX, y: clampedRangeValue(localPoint.y, minY + radius, maxY - radius)))
        candidates.append(CGPoint(x: maxX, y: clampedRangeValue(localPoint.y, minY + radius, maxY - radius)))

        if radius > 0.0 {
            typealias Arc = (center: CGPoint, start: CGFloat, end: CGFloat)
            let arcs: [Arc] = [
                (CGPoint(x: minX + radius, y: minY + radius), .pi, .pi * 1.5),
                (CGPoint(x: maxX - radius, y: minY + radius), .pi * 1.5, .pi * 2.0),
                (CGPoint(x: maxX - radius, y: maxY - radius), 0.0, .pi * 0.5),
                (CGPoint(x: minX + radius, y: maxY - radius), .pi * 0.5, .pi),
            ]
            for arc in arcs {
                let vx = localPoint.x - arc.center.x
                let vy = localPoint.y - arc.center.y
                let rawAngle: CGFloat = (abs(vx) <= 1e-6 && abs(vy) <= 1e-6) ? arc.start : normalizedAngle(atan2(vy, vx))
                var angle = rawAngle
                if arc.end >= (.pi * 2.0) - 1e-6 && angle < arc.start {
                    angle += .pi * 2.0
                }
                let clampedAngle = clamp(angle, arc.start, arc.end)
                candidates.append(CGPoint(
                    x: arc.center.x + cos(clampedAngle) * radius,
                    y: arc.center.y + sin(clampedAngle) * radius
                ))
            }
        }

        guard let nearestLocal = candidates.min(by: { dist2($0, localPoint) < dist2($1, localPoint) }) else {
            return rectCenter
        }
        return CGPoint(x: rectCenter.x + nearestLocal.x, y: rectCenter.y + nearestLocal.y)
    }
}
