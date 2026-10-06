// 移植自上游: submodules/Display/Source/TransformImageArguments.swift :1-67
//
// 改动（逐条）：
//   1. 类型加 Tieba 前缀：TransformImageResizeMode → TiebaTransformImageResizeMode，
//      TransformImageCustomArguments → TiebaTransformImageCustomArguments，
//      TransformImageArguments → TiebaTransformImageArguments。
//   2. 依赖的 ImageCorners → TiebaImageCorners（见 TiebaImageCorners.swift）。
//   3. 上游手写全局 `public func ==` 改写成类型内 static ==，语义逐行照搬：先比几何与 emptyColor，
//      相等再比 custom（custom 走 serialized() 的 isEqual，因为它是 ObjC 侧的表达）。
//   4. 上游 imageRect 的 y 用的是 drawingRect.minX（疑似上游笔误，应为 minY）。**照抄不改**：
//      这个值决定图片在绘制区里的垂直位置，改掉等于悄悄改渲染结果，而本目录不接线、无法回归验证。
//      真要修，应该在上游也修，然后单独提一个 commit。
//   5. Swift 6：全部是 Sendable 值类型；协议约束用 NSArray（ObjC 桥接类型）保持上游签名不变。
//      `nonisolated` 标注保证后台测量路径可用。

import Foundation
import UIKit

enum TiebaTransformImageResizeMode: Equatable, Sendable {
    case fill(UIColor)
    case aspectFill
    case blurBackground
}

/// 上游给 ObjC 侧传自定义参数用的协议（上游 里由 ObjC 类实现）。
/// 本工程零 ObjC，保留协议是为了让 Swift 调用方也能塞自定义参数，不额外加 Sendable 约束
/// （上游实现类是 ObjC 可变对象，强行要求 Sendable 会把桥接方逼进 @unchecked）。
protocol TiebaTransformImageCustomArguments {
    func serialized() -> NSArray
}

/// [移植] 上游没有 Sendable：`custom` 是 ObjC 桥接对象，天然不可 Sendable。
/// 不强行加 `@unchecked Sendable`（铁律 4），需要跨线程传参时由调用方自己拆成值类型。
struct TiebaTransformImageArguments: Equatable {
    var corners: TiebaImageCorners

    var imageSize: CGSize
    var boundingSize: CGSize
    var intrinsicInsets: UIEdgeInsets
    var resizeMode: TiebaTransformImageResizeMode
    var emptyColor: UIColor?
    var custom: (any TiebaTransformImageCustomArguments)?
    var scale: CGFloat?

    nonisolated init(corners: TiebaImageCorners, imageSize: CGSize, boundingSize: CGSize, intrinsicInsets: UIEdgeInsets, resizeMode: TiebaTransformImageResizeMode = .fill(.black), emptyColor: UIColor? = nil, custom: (any TiebaTransformImageCustomArguments)? = nil, scale: CGFloat? = nil) {
        self.corners = corners
        self.imageSize = imageSize
        self.boundingSize = boundingSize
        self.intrinsicInsets = intrinsicInsets
        self.resizeMode = resizeMode
        self.emptyColor = emptyColor
        self.custom = custom
        self.scale = scale
    }

    /// 含圆角外扩与内缩后的实际绘制尺寸。
    nonisolated var drawingSize: CGSize {
        let cornersExtendedEdges = self.corners.extendedEdges
        return CGSize(width: self.boundingSize.width + cornersExtendedEdges.left + cornersExtendedEdges.right + self.intrinsicInsets.left + self.intrinsicInsets.right, height: self.boundingSize.height + cornersExtendedEdges.top + cornersExtendedEdges.bottom + self.intrinsicInsets.top + self.intrinsicInsets.bottom)
    }

    nonisolated var drawingRect: CGRect {
        let cornersExtendedEdges = self.corners.extendedEdges
        return CGRect(x: cornersExtendedEdges.left + self.intrinsicInsets.left, y: cornersExtendedEdges.top + self.intrinsicInsets.top, width: self.boundingSize.width, height: self.boundingSize.height)
    }

    nonisolated var imageRect: CGRect {
        let drawingRect = self.drawingRect
        // y 用 drawingRect.minX 是上游原文（见文件头第 4 条），照抄。
        return CGRect(x: drawingRect.minX + floor((drawingRect.width - self.imageSize.width) / 2.0), y: drawingRect.minX + floor((drawingRect.height - self.imageSize.height) / 2.0), width: self.imageSize.width, height: self.imageSize.height)
    }

    nonisolated var insets: UIEdgeInsets {
        let cornersExtendedEdges = self.corners.extendedEdges
        return UIEdgeInsets(top: cornersExtendedEdges.top + self.intrinsicInsets.top, left: cornersExtendedEdges.left + self.intrinsicInsets.left, bottom: cornersExtendedEdges.bottom + self.intrinsicInsets.bottom, right: cornersExtendedEdges.right + self.intrinsicInsets.right)
    }

    nonisolated static func == (lhs: TiebaTransformImageArguments, rhs: TiebaTransformImageArguments) -> Bool {
        let result = lhs.imageSize == rhs.imageSize && lhs.boundingSize == rhs.boundingSize && lhs.corners == rhs.corners && lhs.emptyColor == rhs.emptyColor
        if result {
            if let lhsCustom = lhs.custom, let rhsCustom = rhs.custom {
                return lhsCustom.serialized().isEqual(rhsCustom.serialized())
            } else {
                return (lhs.custom != nil) == (rhs.custom != nil)
            }
        }
        return result
    }
}
