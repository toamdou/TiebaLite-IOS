// TiebaShadowImage —— 把阴影"烤"成一张九宫格可拉伸图（报告 37 A5）。
//
// 移植自上游 submodules/GlassBackgroundComponent/Sources/GlassBackgroundComponent.swift
//   :1049-1077（圆角矩形版）、:1079-1102（任意四角版）、:1029-1047（cap 计算）、:825-832（使用方的 frame 放大）。
//
// 做法三步（上游逐行）：
//   ① 画布 = 形状尺寸 + shadowInset × 2；在中间填一个**实心**圆角矩形，同时用
//      context.setShadow(offset:blur:color:) 让它长出阴影；
//   ② setFillColor(clear) + setBlendMode(.copy) 再填同一个形状 —— 把实心部分**抠成透明**，只留阴影；
//   ③ capInsets = shadowInset + cornerRadius（九宫格）⇒ 任意尺寸拉伸而阴影模糊度不变。
//   使用方把这张图放在 bounds.insetBy(dx: -inset, dy: -inset) 的 frame 里。
//
// 为什么值得（改前 → 改后）：
//   · 改前：`layer.shadow*` 每帧一次离屏合成；形状连续变化（胶囊随文案变宽、圆角随尺寸变）时
//     shadowPath 追不上，阴影会"留在旧形状上"；
//   · 改后：阴影是**画出来的**一张图，永远和形状一致，且不进离屏合成通道。
//
// ⚠️ 两条护栏（上游同款）：
//   1. 不要放进每帧 layout 的路径上 —— 换形状就要重画一张位图；参数不变时缓存在调用方
//      （上游 :694-705 用 params 比较挡住重复重建）。
//   2. shadowInset 必须 ≥ blur/2 + |offsetY|，否则阴影会被画布边缘切掉（上游 32 / 40 即此关系）。
//
// 并发：整个 enum @MainActor（UIImage 生成 + UI 尺寸）。

import CoreGraphics
import Foundation
import UIKit

/// 一张烤好的阴影图 + 它要求的放大边距（使用方必须用同一个 inset 摆 frame，否则形状对不上）。
struct TiebaBakedShadow {
    let image: UIImage
    /// 图片相对形状外扩的边距：frame = shapeBounds.insetBy(dx: -inset, dy: -inset)。
    let inset: CGFloat
}

@MainActor
enum TiebaShadowImage {
    /// 默认参数对应"胶囊/卡片"这一档（模糊约 2×CALayer.shadowRadius 的观感）。
    static let defaultInset: CGFloat = 28.0
    static let defaultIntensity: CGFloat = 0.18
    static let defaultBlur: CGFloat = 20.0

    /// 任意四角半径版（上游 :1079-1102 + cap 计算 :1029-1047）。
    static func stretchable(
        cornerRadii: TiebaCornerRadii,
        inset: CGFloat = defaultInset,
        intensity: CGFloat = defaultIntensity,
        blur: CGFloat = defaultBlur,
        offset: CGSize = CGSize(width: 0.0, height: 4.0),
        scale: CGFloat? = nil
    ) -> TiebaBakedShadow? {
        // cap 计算：每一边取"该侧两角的最大半径"（上游 :1030-1033）。
        let leftRadius = ceil(max(cornerRadii.topLeft, cornerRadii.bottomLeft))
        let rightRadius = ceil(max(cornerRadii.topRight, cornerRadii.bottomRight))
        let topRadius = ceil(max(cornerRadii.topLeft, cornerRadii.topRight))
        let bottomRadius = ceil(max(cornerRadii.bottomLeft, cornerRadii.bottomRight))
        let innerSize = CGSize(
            width: max(1.0, leftRadius + rightRadius + 1.0),
            height: max(1.0, topRadius + bottomRadius + 1.0)
        )
        let imageSize = CGSize(width: innerSize.width + inset * 2.0, height: innerSize.height + inset * 2.0)
        let innerRect = CGRect(origin: CGPoint(x: inset, y: inset), size: innerSize)
        // +0.5：实心形状内缩半像素，避免 1px 边缘残留（上游 shadowInnerInset）。
        let shadowRect = innerRect.insetBy(dx: 0.5, dy: 0.5)
        let shadowPath = TiebaRoundedRectGeometry.path(rect: shadowRect, cornerRadii: cornerRadii)

        guard let image = TiebaNodesGraphics.image(size: imageSize, opaque: false, scale: scale, body: { context, size in
            context.clear(CGRect(origin: CGPoint(), size: size))
            context.setFillColor(UIColor.black.cgColor)
            context.setShadow(
                offset: offset,
                blur: blur,
                color: UIColor(white: 0.0, alpha: intensity).cgColor
            )
            context.addPath(shadowPath)
            context.fillPath()
            // ② 把实心抠掉，只留阴影。
            context.setFillColor(UIColor.clear.cgColor)
            context.setBlendMode(.copy)
            context.addPath(shadowPath)
            context.fillPath()
        }) else {
            return nil
        }

        // ③ 九宫格：四角（含阴影）保持原样，中段拉伸。cap 之和 < 图尺寸由上面的构造保证。
        let caps = UIEdgeInsets(
            top: ceil(inset + topRadius),
            left: ceil(inset + leftRadius),
            bottom: ceil(inset + bottomRadius),
            right: ceil(inset + rightRadius)
        )
        return TiebaBakedShadow(image: image.resizableImage(withCapInsets: caps, resizingMode: .stretch), inset: inset)
    }

    /// 四角相同版（胶囊、普通卡片用这一档）。
    static func stretchable(
        cornerRadius: CGFloat,
        inset: CGFloat = defaultInset,
        intensity: CGFloat = defaultIntensity,
        blur: CGFloat = defaultBlur,
        offset: CGSize = CGSize(width: 0.0, height: 4.0),
        scale: CGFloat? = nil
    ) -> TiebaBakedShadow? {
        return stretchable(
            cornerRadii: TiebaCornerRadii(radius: cornerRadius),
            inset: inset,
            intensity: intensity,
            blur: blur,
            offset: offset,
            scale: scale
        )
    }
}
