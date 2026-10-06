// 移植自上游:
//   submodules/Display/Source/ImageNode.swift    :9-130（ImageCorner / isRoundEqualCorners / ImageCorners）
//   submodules/Display/Source/ImageCorners.swift :1-142（圆角遮罩位图 + addCorners）
//
// 改动（逐条）：
//   1. 类型全部加 Tieba 前缀：ImageCorner → TiebaImageCorner，ImageCorners → TiebaImageCorners。
//      上游用小写开头的 enum case（`.Corner` / `.Tail`），这里改为 Swift 惯例的 `.corner` / `.tail`
//      （同一个模块里将来还要和别的移植件共存，保持一个风格）。
//   2. 上游 ImageNode.swift 里那个手写的 `public func ==(lhs: ImageCorner, rhs: ImageCorner)` 全局运算符
//      改写成 struct/枚举内的静态 ==；语义逐行照搬（半径按 CGFloat.ulpOfOne 容差、Tail 用 === 比图片实例）。
//      【理由】全局 == 重载在 Swift 6 下容易和 Equatable 合成产生歧义，且无法标记 nonisolated。
//   3. 上游用 `Atomic<[Corner: DrawingContext]>`（SwiftSignalKit）做圆角遮罩缓存，本工程零 ObjC、无该依赖。
//      改用 @MainActor 隔离的字典缓存：缓存值 TiebaBitmapContext 持有可变像素缓冲、不是 Sendable，
//      而 Mutex<TiebaBitmapContext> 在 Swift 6 区域隔离下只允许原地改、不允许把它「取出」（编译器实测报
//      inout sending 区域隔离错误）。跨版本写法 TiebaMutex（NSLock 包装，见 Core/TiebaMutex.swift）
//      同样不改变这个判断：取出来的仍是非 Sendable 的像素缓冲，所以如实把「生成圆角遮罩 + 贴圆角」
//      整条链路放到主线程 ——
//      本目录是 UIView 系移植，绘制入口本来就在主线程。相应地 apply(to:arguments:) 标 @MainActor，
//      没有 @unchecked Sendable / nonisolated(unsafe) 之类的绕过。
//   4. DrawingContext → TiebaBitmapContext（见 TiebaDrawingSupport.swift 文件头）。
//   5. `addCorners(_:arguments:)` 改成 `TiebaImageCorners.apply(to:arguments:)`：
//      上游是 `public func addCorners(_ context: DrawingContext, arguments: TransformImageArguments)`，
//      而 TransformImageArguments 已改名 TiebaTransformImageArguments，签名跟着改。
//   6. context.blt(corner, at:) 只用到 .Alpha 模式，所以 TiebaBitmapContext 只实现了 .Alpha（见其文件头）。
//   7. 上游 `.Tail` 分支里 `image.cgImage!` 是强解包；这里改成 guard（图是运行时数据，强解包会崩线上）。
//   8. Swift 6：纯值类型与纯计算全部 nonisolated；只有圆角遮罩缓存与 apply(to:arguments:) 是 @MainActor。

import Foundation
import UIKit
import CoreGraphics

/// 单个角的形状。
/// 上游：ImageNode.swift:9-39
enum TiebaImageCorner: Equatable, Sendable {
    case corner(CGFloat)
    case tail(CGFloat, UIImage)

    /// 圆角之外的额外外扩（气泡尾巴要往左/右多画 4pt）。
    nonisolated var extendedInsets: CGSize {
        switch self {
            case .tail:
                return CGSize(width: 4.0, height: 0.0)
            default:
                return CGSize()
        }
    }

    /// 去掉尾巴、退化成同半径圆角。
    nonisolated var withoutTail: TiebaImageCorner {
        switch self {
            case .corner:
                return self
            case let .tail(radius, _):
                return .corner(radius)
        }
    }

    nonisolated var radius: CGFloat {
        switch self {
            case let .corner(radius):
                return radius
            case let .tail(radius, _):
                return radius
        }
    }

    /// [移植] 上游是全局 `==(lhs:rhs:)`，这里收进类型内（见文件头第 2 条）。
    nonisolated static func == (lhs: TiebaImageCorner, rhs: TiebaImageCorner) -> Bool {
        switch lhs {
            case let .corner(lhsRadius):
                switch rhs {
                    case let .corner(rhsRadius) where abs(lhsRadius - rhsRadius) < CGFloat.ulpOfOne:
                        return true
                    default:
                        return false
                }
            case let .tail(lhsRadius, lhsImage):
                // 尾巴图必须是同一个实例：换图就该重绘，用 === 而不是 isEqual 是上游刻意为之。
                if case let .tail(rhsRadius, rhsImage) = rhs, lhsRadius.isEqual(to: rhsRadius), lhsImage === rhsImage {
                    return true
                } else {
                    return false
                }
        }
    }
}

/// 四角形状集合。上游：ImageNode.swift:59-130
struct TiebaImageCorners: Equatable, Sendable {
    enum Curve: Sendable {
        case circular
        case continuous
    }

    let topLeft: TiebaImageCorner
    let topRight: TiebaImageCorner
    let bottomLeft: TiebaImageCorner
    let bottomRight: TiebaImageCorner
    let curve: Curve

    nonisolated var isEmpty: Bool {
        if self.topLeft != .corner(0.0) {
            return false
        }
        if self.topRight != .corner(0.0) {
            return false
        }
        if self.bottomLeft != .corner(0.0) {
            return false
        }
        if self.bottomRight != .corner(0.0) {
            return false
        }
        return true
    }

    nonisolated init(radius: CGFloat, curve: Curve = .circular) {
        self.topLeft = .corner(radius)
        self.topRight = .corner(radius)
        self.bottomLeft = .corner(radius)
        self.bottomRight = .corner(radius)
        self.curve = curve
    }

    nonisolated init(topLeft: TiebaImageCorner, topRight: TiebaImageCorner, bottomLeft: TiebaImageCorner, bottomRight: TiebaImageCorner, curve: Curve = .circular) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomLeft = bottomLeft
        self.bottomRight = bottomRight
        self.curve = curve
    }

    nonisolated init() {
        self.init(topLeft: .corner(0.0), topRight: .corner(0.0), bottomLeft: .corner(0.0), bottomRight: .corner(0.0), curve: .circular)
    }

    nonisolated var extendedEdges: UIEdgeInsets {
        let left = self.bottomLeft.extendedInsets.width
        let right = self.bottomRight.extendedInsets.width
        return UIEdgeInsets(top: 0.0, left: left, bottom: 0.0, right: right)
    }

}

extension TiebaImageCorners {
    /// 上游 ImageCorners.swift:6-21 的私有 `Corner`：圆角遮罩位图的缓存键。
    fileprivate enum CornerKey: Hashable, Sendable {
        case topLeft(Int), topRight(Int), bottomLeft(Int), bottomRight(Int)

        nonisolated var radius: Int {
            switch self {
                case let .topLeft(radius): return radius
                case let .topRight(radius): return radius
                case let .bottomLeft(radius): return radius
                case let .bottomRight(radius): return radius
            }
        }
    }

    /// 遮罩缓存键 = 角 + **目标位图的 scale**。
    ///
    /// [接线 2026-10-05] 上游只按「角」缓存，因为上游所有目标位图都用设备 scale（DrawingContext 默认值），
    /// 遮罩 scale 与目标 scale 必然相等。本仓新增了非设备 scale 的目标（分享面板的 PDF 预览图标用 2x），
    /// 而 `blt()` 在两边 scale 不等时会 **静默什么都不做**（TiebaBitmapContext.blt 第一行 guard），
    /// 表现为「圆角根本没切」而不是报错 —— 模拟器实测踩到过。所以缓存键必须带上 scale，
    /// 遮罩按目标 scale 生成，调用方才不会因为选了个非设备 scale 就悄悄丢掉圆角。
    fileprivate struct CornerCacheKey: Hashable {
        let corner: CornerKey
        let scale: CGFloat
    }

    /// [移植] 上游 `cachedCorners`（SwiftSignalKit 的 Atomic）→ 主线程字典（见文件头第 3 条）。
    @MainActor private static var cachedCorners: [CornerCacheKey: TiebaBitmapContext] = [:]

    /// 生成/取出某个角的黑白遮罩位图（黑 = 保留，透明 = 切掉），规格与目标位图一致。
    @MainActor private static func cornerContext(_ corner: CornerKey, scale: CGFloat) -> TiebaBitmapContext {
        let key = CornerCacheKey(corner: corner, scale: scale)
        if let cached = Self.cachedCorners[key] {
            return cached
        }

        // 半径取整成整数像素：上游把 key 定义成 Int(radius)，这里保持一致。
        let context = TiebaBitmapContext(size: CGSize(width: CGFloat(corner.radius), height: CGFloat(corner.radius)), scale: scale, clear: true)!
        context.withContext { c in
            c.clear(CGRect(origin: CGPoint(), size: CGSize(width: CGFloat(corner.radius), height: CGFloat(corner.radius))))
            c.setFillColor(UIColor.black.cgColor)
            // 每个角都把「直径 = 2r 的圆」按角的方向摆，只有落在位图里的那一块被画出来。
            switch corner {
                case let .topLeft(radius):
                    c.fillEllipse(in: CGRect(origin: CGPoint(), size: CGSize(width: CGFloat(radius * 2), height: CGFloat(radius * 2))))
                case let .topRight(radius):
                    c.fillEllipse(in: CGRect(origin: CGPoint(x: -CGFloat(radius), y: 0.0), size: CGSize(width: CGFloat(radius * 2), height: CGFloat(radius * 2))))
                case let .bottomLeft(radius):
                    c.fillEllipse(in: CGRect(origin: CGPoint(x: 0.0, y: -CGFloat(radius)), size: CGSize(width: CGFloat(radius * 2), height: CGFloat(radius * 2))))
                case let .bottomRight(radius):
                    c.fillEllipse(in: CGRect(origin: CGPoint(x: -CGFloat(radius), y: -CGFloat(radius)), size: CGSize(width: CGFloat(radius * 2), height: CGFloat(radius * 2))))
            }
        }

        Self.cachedCorners[key] = context
        return context
    }

    /// 上游 `addCorners(_:arguments:)`（ImageCorners.swift:78-142）：把四角切出来，带气泡尾巴的可选分支照搬。
    /// [移植] 标 @MainActor：内部要访问 @MainActor 的遮罩缓存（见文件头第 3 条）。
    @MainActor func apply(to context: TiebaBitmapContext, arguments: TiebaTransformImageArguments) {
        let corners = arguments.corners
        let drawingRect = arguments.drawingRect

        if case let .corner(radius) = corners.topLeft, radius > CGFloat.ulpOfOne {
            let corner = Self.cornerContext(.topLeft(Int(radius)), scale: context.scale)
            context.blt(corner, at: CGPoint(x: drawingRect.minX, y: drawingRect.minY))
        }

        if case let .corner(radius) = corners.topRight, radius > CGFloat.ulpOfOne {
            let corner = Self.cornerContext(.topRight(Int(radius)), scale: context.scale)
            context.blt(corner, at: CGPoint(x: drawingRect.maxX - radius, y: drawingRect.minY))
        }

        switch corners.bottomLeft {
            case let .corner(radius):
                if radius > CGFloat.ulpOfOne {
                    let corner = Self.cornerContext(.bottomLeft(Int(radius)), scale: context.scale)
                    context.blt(corner, at: CGPoint(x: drawingRect.minX, y: drawingRect.maxY - radius))
                }
            case let .tail(radius, image):
                if radius > CGFloat.ulpOfOne {
                    self.drawTail(in: context, drawingRect: drawingRect, radius: radius, image: image, isLeft: true)
                }
        }

        switch corners.bottomRight {
            case let .corner(radius):
                if radius > CGFloat.ulpOfOne {
                    let corner = Self.cornerContext(.bottomRight(Int(radius)), scale: context.scale)
                    context.blt(corner, at: CGPoint(x: drawingRect.maxX - radius, y: drawingRect.maxY - radius))
                }
            case let .tail(radius, image):
                if radius > CGFloat.ulpOfOne {
                    self.drawTail(in: context, drawingRect: drawingRect, radius: radius, image: image, isLeft: false)
                }
        }
    }

    /// 上游 .Tail 分支（ImageCorners.swift:97-114 / :123-140）。
    /// 先取底边像素色补一块 4pt 小方块当尾巴，再用 .destinationIn 让尾巴图裁出形状。
    private func drawTail(in context: TiebaBitmapContext, drawingRect: CGRect, radius: CGFloat, image: UIImage, isLeft: Bool) {
        guard let tailImage = image.cgImage else {
            // [移植] 上游这里 `image.cgImage!` 强解包（见文件头第 7 条）。
            return
        }
        let color = context.colorAt(CGPoint(x: isLeft ? drawingRect.minX : drawingRect.maxX - 1.0, y: drawingRect.maxY - 1.0))
        context.withContext { c in
            if isLeft {
                c.clear(CGRect(x: drawingRect.minX - 4.0, y: 0.0, width: 4.0, height: drawingRect.maxY - 6.0))
                c.setFillColor(color.cgColor)
                c.fill(CGRect(x: 0.0, y: drawingRect.maxY - 7.0, width: 4.0, height: 7.0))
                c.setBlendMode(.destinationIn)
                let cornerRect = CGRect(origin: CGPoint(x: drawingRect.minX - 6.0, y: drawingRect.maxY - image.size.height), size: image.size)
                self.drawFlippedVertically(c, image: tailImage, in: cornerRect)
            } else {
                c.clear(CGRect(x: drawingRect.maxX, y: 0.0, width: 4.0, height: drawingRect.maxY - image.size.height))
                c.setFillColor(color.cgColor)
                c.fill(CGRect(x: drawingRect.maxX, y: drawingRect.maxY - 7.0, width: 5.0, height: 7.0))
                c.setBlendMode(.destinationIn)
                let cornerRect = CGRect(origin: CGPoint(x: drawingRect.maxX - image.size.width + 6.0, y: drawingRect.maxY - image.size.height), size: image.size)
                self.drawFlippedVertically(c, image: tailImage, in: cornerRect)
            }
        }
    }

    /// withContext 已经翻过一次 y，上游又原地翻了第二次（抵消成正常方向）——照搬，不改上下方向。
    private func drawFlippedVertically(_ c: CGContext, image: CGImage, in rect: CGRect) {
        c.translateBy(x: rect.midX, y: rect.midY)
        c.scaleBy(x: 1.0, y: -1.0)
        c.translateBy(x: -rect.midX, y: -rect.midY)
        c.draw(image, in: rect)
        c.translateBy(x: rect.midX, y: rect.midY)
        c.scaleBy(x: 1.0, y: -1.0)
        c.translateBy(x: -rect.midX, y: -rect.midY)
    }
}

// [移植] 上游 ImageNode.swift:59-66 的全局 `isRoundEqualCorners(_:)` 已做成
// TiebaImageCorners.isRoundEqualCorners 实例属性，不再重复导出全局函数以避免符号冲突。
