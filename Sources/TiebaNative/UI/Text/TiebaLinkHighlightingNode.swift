// 移植自上游: submodules/Display/Source/LinkHighlightingNode.swift（上游 429 行）。
//
// 作用：把一段文字里跨行的链接/搜索命中矩形，缝成一条连续的圆角高亮带（每行矩形共享圆角、行间用连接角过渡），
// 生成一张位图交给一个 UIImageView 显示。上游 ImmediateTextNode 的交互部分用它做链接按压高亮。
//
// 改动清单：
//  1) [基类] 上游 public final class LinkHighlightingNode: ASDisplayNode → UIView；内部 ASImageNode → UIImageView。
//     addSubnode → addSubview；imageNode.frame 赋值保留为 imageView.frame（坐标系一致）。
//     删除 ASDK 专有属性 displaysAsynchronously（本仓无异步节点层）。
//  2) [改名] LinkHighlightingNode → TiebaLinkHighlightingNode；自由函数 generateRectsImage →
//     tiebaLinkGenerateRectsImage（铁律 6：公开 API 加 Tieba 前缀）；文件内私有绘制函数/枚举同样加 tiebaLink 前缀，
//     避免与本仓其他文件重名。
//  3) [依赖内联] 上游此文件用 Display 的两个扩展：CGRect 的四角属性 topLeft/topRight/bottomLeft/bottomRight
//     （UIKitUtils.swift）与 CGPoint.offsetBy(dx:dy:)（同文件 :984）。本仓这两个扩展由其他目录负责（或尚未移植），
//     为避免与他们的声明重复，这里用文件私有、tiebaLink 前缀的同名语义成员内联。调用点相应改名，几何代码逐字保留。
//  4) [位图上下文] 上游走 Display/GenerateImage.swift:115 的 generateImage(_:opaque:scale:rotatedContext:)，
//     其内部 DrawingContext.withContext(:597-606) 会把 CTM 上下翻转（scaleBy(1, -1)），即 rotatedContext 拿到的是
//     UIKit 坐标系（y 向下）。本仓没有 DrawingContext，这里用 UIGraphicsImageRenderer 等价实现——它的 cgContext
//     同样是 y 向下，且 scale 取 UIGraphicsImageRendererFormat.preferred().scale（= 主屏 scale，上游默认 deviceScale）。
//     ⚠️ 注意：不能用裸 CGBitmapContext 直接画（那是 y 向上，会得到上下镜像的高亮带）。
//  5) [Swift 6] 未使用 @preconcurrency / nonisolated(unsafe) / @unchecked Sendable：本类继承 UIView（SDK 已
//     @MainActor），高亮图生成是纯 CoreGraphics 的 nonisolated 函数，两类工作天然分属正确的隔离域。
//  6) 几何算法一行未改（含上游 updateImage() 里"rects 为空只清图不 return"的既有行为，照搬未改）。

import Foundation
import UIKit

// [移植] 上游 Display/Source/UIKitUtils.swift 的 CGRect 四角属性（逐行照搬，只改名字）。
private extension CGRect {
    var tiebaLinkTopLeft: CGPoint {
        return CGPoint(x: self.minX, y: self.minY)
    }
    var tiebaLinkTopRight: CGPoint {
        return CGPoint(x: self.maxX, y: self.minY)
    }
    var tiebaLinkBottomLeft: CGPoint {
        return CGPoint(x: self.minX, y: self.maxY)
    }
    var tiebaLinkBottomRight: CGPoint {
        return CGPoint(x: self.maxX, y: self.maxY)
    }
}

// [移植] 上游 Display/Source/UIKitUtils.swift:984 `CGPoint.offsetBy(dx:dy:)`。
private extension CGPoint {
    func tiebaLinkOffsetBy(dx: CGFloat, dy: CGFloat) -> CGPoint {
        return CGPoint(x: self.x + dx, y: self.y + dy)
    }
}

// [移植] 上游 Display/Source/GenerateImage.swift:115（rotatedContext 变体）。
// 语义等价：size 由调用方保证非零；scale 取主屏 scale；opaque = false；rotatedContext 收到 y 向下的 UIKit 坐标系。
private func tiebaLinkGenerateImage(_ size: CGSize, opaque: Bool = false, scale: CGFloat? = nil, rotatedContext: (CGSize, CGContext) -> Void) -> UIImage? {
    if size.width.isZero || size.height.isZero {
        return nil
    }
    let format = UIGraphicsImageRendererFormat.preferred()
    format.opaque = opaque
    if let scale = scale, scale > 0.0 {
        format.scale = scale
    }
    return UIGraphicsImageRenderer(size: size, format: format).image { rendererContext in
        rotatedContext(size, rendererContext.cgContext)
    }
}

private enum TiebaLinkCornerType {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
}

private func tiebaLinkDrawFullCorner(context: CGContext, color: UIColor, at point: CGPoint, type: TiebaLinkCornerType, radius: CGFloat) {
    if radius.isZero {
        return
    }
    context.setFillColor(color.cgColor)
    switch type {
    case .topLeft:
        context.clear(CGRect(origin: point, size: CGSize(width: radius, height: radius)))
        context.fillEllipse(in: CGRect(origin: point, size: CGSize(width: radius * 2.0, height: radius * 2.0)))
    case .topRight:
        context.clear(CGRect(origin: CGPoint(x: point.x - radius, y: point.y), size: CGSize(width: radius, height: radius)))
        context.fillEllipse(in: CGRect(origin: CGPoint(x: point.x - radius * 2.0, y: point.y), size: CGSize(width: radius * 2.0, height: radius * 2.0)))
    case .bottomLeft:
        context.clear(CGRect(origin: CGPoint(x: point.x, y: point.y - radius), size: CGSize(width: radius, height: radius)))
        context.fillEllipse(in: CGRect(origin: CGPoint(x: point.x, y: point.y - radius * 2.0), size: CGSize(width: radius * 2.0, height: radius * 2.0)))
    case .bottomRight:
        context.clear(CGRect(origin: CGPoint(x: point.x - radius, y: point.y - radius), size: CGSize(width: radius, height: radius)))
        context.fillEllipse(in: CGRect(origin: CGPoint(x: point.x - radius * 2.0, y: point.y - radius * 2.0), size: CGSize(width: radius * 2.0, height: radius * 2.0)))
    }
}

private func tiebaLinkDrawRectsImageContent(size: CGSize, context: CGContext, color: UIColor, rects: [CGRect], inset: CGFloat, outerRadius: CGFloat, innerRadius: CGFloat, stroke: Bool, strokeWidth: CGFloat, useModernPathCalculation: Bool, topLeft: CGPoint) {
    context.clear(CGRect(origin: CGPoint(), size: size))
    context.setFillColor(color.cgColor)

    context.setBlendMode(.copy)

    if useModernPathCalculation {
        if rects.count == 1 {
            let path = UIBezierPath(roundedRect: rects[0].offsetBy(dx: -topLeft.x, dy: -topLeft.y), cornerRadius: outerRadius).cgPath
            context.addPath(path)

            if stroke {
                context.setStrokeColor(color.cgColor)
                context.setLineWidth(strokeWidth)
                context.strokePath()
            } else {
                context.fillPath()
            }
            return
        }

        var combinedRects: [[CGRect]] = []
        var currentRects: [CGRect] = []
        for rect in rects {
            if rect.width.isZero {
                if !currentRects.isEmpty {
                    combinedRects.append(currentRects)
                }
                currentRects.removeAll()
            } else {
                // The path-stitching loop below assumes consecutive rects in a group
                // are adjacent (overlapping or sharing an edge). When they're disjoint
                // — vertical gap, vertical inversion, or horizontal gap on the same
                // line — it bridges them with a polygon perimeter that renders as a
                // diagonal bridge across empty space. Split groups whenever the next
                // rect doesn't intersect the last one (1pt slop in both axes matches
                // the snap loop's adjacency test).
                if let last = currentRects.last, !last.insetBy(dx: -1.0, dy: -1.0).intersects(rect) {
                    combinedRects.append(currentRects)
                    currentRects.removeAll()
                }
                currentRects.append(rect)
            }
        }
        if !currentRects.isEmpty {
            combinedRects.append(currentRects)
        }

        for rects in combinedRects {
            var rects = rects.map { $0.insetBy(dx: -inset, dy: -inset).offsetBy(dx: -topLeft.x, dy: -topLeft.y) }

            let minRadius: CGFloat = 2.0

            for _ in 0 ..< rects.count * rects.count {
                var hadChanges = false
                for i in 0 ..< rects.count - 1 {
                    if rects[i].maxY > rects[i + 1].minY {
                        let midY = floor((rects[i].maxY + rects[i + 1].minY) * 0.5)
                        rects[i].size.height = midY - rects[i].minY
                        rects[i + 1].origin.y = midY
                        rects[i + 1].size.height = rects[i + 1].maxY - midY
                        hadChanges = true
                    }
                    if rects[i].maxY >= rects[i + 1].minY && rects[i].insetBy(dx: 0.0, dy: -1.0).intersects(rects[i + 1]) {
                        if abs(rects[i].minX - rects[i + 1].minX) < minRadius {
                            let commonMinX = min(rects[i].origin.x, rects[i + 1].origin.x)
                            if rects[i].origin.x != commonMinX {
                                rects[i].origin.x = commonMinX
                                hadChanges = true
                            }
                            if rects[i + 1].origin.x != commonMinX {
                                rects[i + 1].origin.x = commonMinX
                                hadChanges = true
                            }
                        }
                        if abs(rects[i].maxX - rects[i + 1].maxX) < minRadius {
                            let commonMaxX = max(rects[i].maxX, rects[i + 1].maxX)
                            if rects[i].maxX != commonMaxX {
                                rects[i].size.width = commonMaxX - rects[i].minX
                                hadChanges = true
                            }
                            if rects[i + 1].maxX != commonMaxX {
                                rects[i + 1].size.width = commonMaxX - rects[i + 1].minX
                                hadChanges = true
                            }
                        }
                    }
                }
                if !hadChanges {
                    break
                }
            }

            context.move(to: CGPoint(x: rects[0].midX, y: rects[0].minY))
            context.addLine(to: CGPoint(x: rects[0].maxX - outerRadius, y: rects[0].minY))
            context.addArc(tangent1End: rects[0].tiebaLinkTopRight, tangent2End: CGPoint(x: rects[0].maxX, y: rects[0].minY + outerRadius), radius: outerRadius)
            context.addLine(to: CGPoint(x: rects[0].maxX, y: rects[0].midY))

            for i in 0 ..< rects.count - 1 {
                let rect = rects[i]
                let next = rects[i + 1]

                if rect.maxX == next.maxX {
                    context.addLine(to: CGPoint(x: next.maxX, y: next.midY))
                } else {
                    let nextRadius = min(outerRadius, ceil(abs(rect.maxX - next.maxX) * 0.5))
                    context.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - nextRadius))
                    if next.maxX > rect.maxX {
                        context.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX + nextRadius, y: rect.maxY), radius: nextRadius)
                        context.addLine(to: CGPoint(x: next.maxX - nextRadius, y: next.minY))
                    } else {
                        context.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX - nextRadius, y: rect.maxY), radius: nextRadius)
                        context.addLine(to: CGPoint(x: next.maxX + nextRadius, y: next.minY))
                    }
                    context.addArc(tangent1End: next.tiebaLinkTopRight, tangent2End: CGPoint(x: next.maxX, y: next.minY + nextRadius), radius: nextRadius)
                    context.addLine(to: CGPoint(x: next.maxX, y: next.midY))
                }
            }

            let last = rects[rects.count - 1]
            context.addLine(to: CGPoint(x: last.maxX, y: last.maxY - outerRadius))
            context.addArc(tangent1End: last.tiebaLinkBottomRight, tangent2End: CGPoint(x: last.maxX - outerRadius, y: last.maxY), radius: outerRadius)
            context.addLine(to: CGPoint(x: last.minX + outerRadius, y: last.maxY))
            context.addArc(tangent1End: last.tiebaLinkBottomLeft, tangent2End: CGPoint(x: last.minX, y: last.maxY - outerRadius), radius: outerRadius)

            for i in (1 ..< rects.count).reversed() {
                let rect = rects[i]
                let prev = rects[i - 1]

                if rect.minX == prev.minX {
                    context.addLine(to: CGPoint(x: prev.minX, y: prev.midY))
                } else {
                    let prevRadius = min(outerRadius, ceil(abs(rect.minX - prev.minX) * 0.5))
                    context.addLine(to: CGPoint(x: rect.minX, y: rect.minY + prevRadius))
                    if rect.minX < prev.minX {
                        context.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX + prevRadius, y: rect.minY), radius: prevRadius)
                        context.addLine(to: CGPoint(x: prev.minX - prevRadius, y: prev.maxY))
                    } else {
                        context.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX - prevRadius, y: rect.minY), radius: prevRadius)
                        context.addLine(to: CGPoint(x: prev.minX + prevRadius, y: prev.maxY))
                    }
                    context.addArc(tangent1End: prev.tiebaLinkBottomLeft, tangent2End: CGPoint(x: prev.minX, y: prev.maxY - prevRadius), radius: prevRadius)
                    context.addLine(to: CGPoint(x: prev.minX, y: prev.midY))
                }
            }

            context.addLine(to: CGPoint(x: rects[0].minX, y: rects[0].minY + outerRadius))
            context.addArc(tangent1End: rects[0].tiebaLinkTopLeft, tangent2End: CGPoint(x: rects[0].minX + outerRadius, y: rects[0].minY), radius: outerRadius)
            context.addLine(to: CGPoint(x: rects[0].midX, y: rects[0].minY))

            if stroke {
                context.setStrokeColor(color.cgColor)
                context.setLineWidth(strokeWidth)
                context.strokePath()
            } else {
                context.fillPath()
            }
        }
        return
    }

    for i in 0 ..< rects.count {
        let rect = rects[i].insetBy(dx: -inset, dy: -inset)
        context.fill(rect.offsetBy(dx: -topLeft.x, dy: -topLeft.y))
    }

    for i in 0 ..< rects.count {
        let rect = rects[i].insetBy(dx: -inset, dy: -inset).offsetBy(dx: -topLeft.x, dy: -topLeft.y)

        var previous: CGRect?
        if i != 0 {
            previous = rects[i - 1].insetBy(dx: -inset, dy: -inset).offsetBy(dx: -topLeft.x, dy: -topLeft.y)
        }

        var next: CGRect?
        if i != rects.count - 1 {
            next = rects[i + 1].insetBy(dx: -inset, dy: -inset).offsetBy(dx: -topLeft.x, dy: -topLeft.y)
        }

        if let previous = previous {
            if previous.contains(rect.tiebaLinkTopLeft) {
                if abs(rect.tiebaLinkTopLeft.x - previous.minX) >= innerRadius {
                    var radius = innerRadius
                    if let next = next {
                        radius = min(radius, floor((next.minY - previous.maxY) / 2.0))
                    }
                    tiebaLinkDrawConnectingCorner(context: context, color: color, at: CGPoint(x: rect.tiebaLinkTopLeft.x, y: previous.maxY), type: .topLeft, radius: radius)
                }
            } else {
                tiebaLinkDrawFullCorner(context: context, color: color, at: rect.tiebaLinkTopLeft, type: .topLeft, radius: outerRadius)
            }
            if previous.contains(rect.tiebaLinkTopRight.tiebaLinkOffsetBy(dx: -1.0, dy: 0.0)) {
                if abs(rect.tiebaLinkTopRight.x - previous.maxX) >= innerRadius {
                    var radius = innerRadius
                    if let next = next {
                        radius = min(radius, floor((next.minY - previous.maxY) / 2.0))
                    }
                    tiebaLinkDrawConnectingCorner(context: context, color: color, at: CGPoint(x: rect.tiebaLinkTopRight.x, y: previous.maxY), type: .topRight, radius: radius)
                }
            } else {
                tiebaLinkDrawFullCorner(context: context, color: color, at: rect.tiebaLinkTopRight, type: .topRight, radius: outerRadius)
            }
        } else {
            tiebaLinkDrawFullCorner(context: context, color: color, at: rect.tiebaLinkTopLeft, type: .topLeft, radius: outerRadius)
            tiebaLinkDrawFullCorner(context: context, color: color, at: rect.tiebaLinkTopRight, type: .topRight, radius: outerRadius)
        }

        if let next = next {
            if next.contains(rect.tiebaLinkBottomLeft) {
                if abs(rect.tiebaLinkBottomRight.x - next.maxX) >= innerRadius {
                    var radius = innerRadius
                    if let previous = previous {
                        radius = min(radius, floor((next.minY - previous.maxY) / 2.0))
                    }
                    tiebaLinkDrawConnectingCorner(context: context, color: color, at: CGPoint(x: rect.tiebaLinkBottomLeft.x, y: next.minY), type: .bottomLeft, radius: radius)
                }
            } else {
                tiebaLinkDrawFullCorner(context: context, color: color, at: rect.tiebaLinkBottomLeft, type: .bottomLeft, radius: outerRadius)
            }
            if next.contains(rect.tiebaLinkBottomRight.tiebaLinkOffsetBy(dx: -1.0, dy: 0.0)) {
                if abs(rect.tiebaLinkBottomRight.x - next.maxX) >= innerRadius {
                    var radius = innerRadius
                    if let previous = previous {
                        radius = min(radius, floor((next.minY - previous.maxY) / 2.0))
                    }
                    tiebaLinkDrawConnectingCorner(context: context, color: color, at: CGPoint(x: rect.tiebaLinkBottomRight.x, y: next.minY), type: .bottomRight, radius: radius)
                }
            } else {
                tiebaLinkDrawFullCorner(context: context, color: color, at: rect.tiebaLinkBottomRight, type: .bottomRight, radius: outerRadius)
            }
        } else {
            tiebaLinkDrawFullCorner(context: context, color: color, at: rect.tiebaLinkBottomLeft, type: .bottomLeft, radius: outerRadius)
            tiebaLinkDrawFullCorner(context: context, color: color, at: rect.tiebaLinkBottomRight, type: .bottomRight, radius: outerRadius)
        }
    }
}

private func tiebaLinkDrawConnectingCorner(context: CGContext, color: UIColor, at point: CGPoint, type: TiebaLinkCornerType, radius: CGFloat) {
    context.setFillColor(color.cgColor)
    switch type {
    case .topLeft:
        context.fill(CGRect(origin: CGPoint(x: point.x - radius, y: point.y), size: CGSize(width: radius, height: radius)))
        context.setFillColor(UIColor.clear.cgColor)
        context.fillEllipse(in: CGRect(origin: CGPoint(x: point.x - radius * 2.0, y: point.y), size: CGSize(width: radius * 2.0, height: radius * 2.0)))
    case .topRight:
        context.fill(CGRect(origin: CGPoint(x: point.x, y: point.y), size: CGSize(width: radius, height: radius)))
        context.setFillColor(UIColor.clear.cgColor)
        context.fillEllipse(in: CGRect(origin: CGPoint(x: point.x, y: point.y), size: CGSize(width: radius * 2.0, height: radius * 2.0)))
    case .bottomLeft:
        context.fill(CGRect(origin: CGPoint(x: point.x - radius, y: point.y - radius), size: CGSize(width: radius, height: radius)))
        context.setFillColor(UIColor.clear.cgColor)
        context.fillEllipse(in: CGRect(origin: CGPoint(x: point.x - radius * 2.0, y: point.y - radius * 2.0), size: CGSize(width: radius * 2.0, height: radius * 2.0)))
    case .bottomRight:
        context.fill(CGRect(origin: CGPoint(x: point.x, y: point.y - radius), size: CGSize(width: radius, height: radius)))
        context.setFillColor(UIColor.clear.cgColor)
        context.fillEllipse(in: CGRect(origin: CGPoint(x: point.x, y: point.y - radius * 2.0), size: CGSize(width: radius * 2.0, height: radius * 2.0)))
    }
}

public func tiebaLinkGenerateRectsImage(color: UIColor, rects: [CGRect], inset: CGFloat, outerRadius: CGFloat, innerRadius: CGFloat, stroke: Bool = false, strokeWidth: CGFloat = 2.0, useModernPathCalculation: Bool) -> (CGPoint, UIImage?) {
    if rects.isEmpty {
        return (CGPoint(), nil)
    }
    
    var topLeft = rects[0].origin
    var bottomRight = CGPoint(x: rects[0].maxX, y: rects[0].maxY)
    for i in 1 ..< rects.count {
        topLeft.x = min(topLeft.x, rects[i].origin.x)
        topLeft.y = min(topLeft.y, rects[i].origin.y)
        bottomRight.x = max(bottomRight.x, rects[i].maxX)
        bottomRight.y = max(bottomRight.y, rects[i].maxY)
    }
    
    var drawingInset = inset
    if stroke {
        drawingInset += 2.0
    }
    
    topLeft.x -= drawingInset
    topLeft.y -= drawingInset
    bottomRight.x += drawingInset * 2.0
    bottomRight.y += drawingInset * 2.0
    
    let capturedTopLeft = topLeft
    // B3（移植自上游 submodules/DynamicCornerRadiusView/Sources/DynamicCornerRadiusView.swift:9-12）：
    // 半径 0 会让 CoreGraphics 的 addArc(tangent1End:) 生成**退化路径**（缺角/断裂）——
    // 同一条路径上 UIBezierPath(cornerRadius: 0) 是合法的，所以"传 0 = 不要圆角"这种调用
    // 只在 CG 那一段炸。统一把下限抬到 0.01（0.01pt 肉眼不可见，但路径不退化）。
    return (topLeft, tiebaLinkGenerateImage(CGSize(width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y), rotatedContext: { size, context in
        tiebaLinkDrawRectsImageContent(size: size, context: context, color: color, rects: rects, inset: inset, outerRadius: max(0.01, outerRadius), innerRadius: max(0.01, innerRadius), stroke: stroke, strokeWidth: strokeWidth, useModernPathCalculation: useModernPathCalculation, topLeft: capturedTopLeft)
    }))
}

// MARK: - 上游 :322-429（LinkHighlightingNode 类）

// [移植] 上游 public final class LinkHighlightingNode: ASDisplayNode → UIView。
public final class TiebaLinkHighlightingNode: UIView {
    public private(set) var rects: [CGRect] = []
    // [移植] 上游是 public let imageNode: ASImageNode；UIView 世界里就是承载位图的子视图。
    public let imageView: UIImageView

    public var innerRadius: CGFloat = 4.0
    public var outerRadius: CGFloat = 4.0
    public var inset: CGFloat = 2.0
    public var useModernPathCalculation: Bool = false
    public var borderOnly: Bool = false
    public var strokeWidth: CGFloat = 1.0

    private var _color: UIColor
    public var color: UIColor {
        get {
            return self._color
        } set(value) {
            self._color = value
            if !self.rects.isEmpty {
                self.updateImage()
            }
        }
    }

    public init(color: UIColor) {
        self._color = color

        self.imageView = UIImageView()
        self.imageView.isUserInteractionEnabled = false
        // [移植] 上游 imageNode.displaysAsynchronously = false（ASDK 属性）删除：UIView 直接同步绘制。

        // [移植] ASDisplayNode.super.init() → UIView.super.init(frame:)。
        super.init(frame: .zero)

        self.addSubview(self.imageView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func updateRects(_ rects: [CGRect], color: UIColor? = nil) {
        var updated = false
        if self.rects != rects {
            updated = true
            self.rects = rects
        }

        if let color = color, !color.isEqual(self.color) {
            updated = true
            self.color = color
        }

        if updated {
            self.updateImage()
        }
    }

    private func updateImage() {
        if self.rects.isEmpty {
            self.imageView.image = nil
        }
        let (offset, image) = tiebaLinkGenerateRectsImage(color: self.color, rects: self.rects, inset: self.inset, outerRadius: self.outerRadius, innerRadius: self.innerRadius, stroke: self.borderOnly, strokeWidth: self.strokeWidth, useModernPathCalculation: self.useModernPathCalculation)

        if let image = image {
            self.imageView.image = image
            self.imageView.frame = CGRect(origin: offset, size: image.size)
        }
    }

    public static func generateImage(color: UIColor, inset: CGFloat, innerRadius: CGFloat, outerRadius: CGFloat, rects: [CGRect], useModernPathCalculation: Bool) -> (CGPoint, UIImage)? {
        if rects.isEmpty {
            return nil
        }
        let (offset, image) = tiebaLinkGenerateRectsImage(color: color, rects: rects, inset: inset, outerRadius: outerRadius, innerRadius: innerRadius, useModernPathCalculation: useModernPathCalculation)

        if let image = image {
            return (offset, image)
        } else {
            return nil
        }
    }

    public func asyncLayout() -> (UIColor, [CGRect], CGFloat, CGFloat, CGFloat) -> () -> Void {
        let currentRects = self.rects
        let currentColor = self._color
        let currentInnerRadius = self.innerRadius
        let currentOuterRadius = self.outerRadius
        let currentInset = self.inset
        let useModernPathCalculation = self.useModernPathCalculation

        return { [weak self] color, rects, innerRadius, outerRadius, inset in
            var updatedImage: (CGPoint, UIImage?)?
            if currentRects != rects || !currentColor.isEqual(color) || currentInnerRadius != innerRadius || currentOuterRadius != outerRadius || currentInset != inset {
                updatedImage = tiebaLinkGenerateRectsImage(color: color, rects: rects, inset: inset, outerRadius: outerRadius, innerRadius: innerRadius, useModernPathCalculation: useModernPathCalculation)
            }

            return {
                if let strongSelf = self {
                    strongSelf._color = color
                    strongSelf.rects = rects
                    strongSelf.innerRadius = innerRadius
                    strongSelf.outerRadius = outerRadius
                    strongSelf.inset = inset

                    if let (offset, maybeImage) = updatedImage, let image = maybeImage {
                        strongSelf.imageView.image = image
                        strongSelf.imageView.frame = CGRect(origin: offset, size: image.size)
                    }
                }
            }
        }
    }
}
