// 移植自上游 submodules/Display/Source/{UIKitUtils.swift, CAAnimationUtils.swift,
// DisplayLinkAnimator.swift} 中被 UI/Nodes/ 六个组件共用的那一小撮通用件。
//
// 命名空间选择：位图生成/像素对齐这些工具在本仓 UI/Components/ 里已有同名自由函数
// （floorToScreenPixels、generateImage…），直接同名会重复定义，所以统一收进
// TiebaNodesGraphics 命名空间。
//
// 改动（逐条编号，均相对上游）：
//   1. 上游 `generateImage` / `generateFilledCircleImage` / `generateTintedImage` /
//      `floorToScreenPixels` 散落在 Display/Source/UIKitUtils.swift，这里收进
//      TiebaNodesGraphics 命名空间（同名自由函数本仓 UI/Components/TiebaUIKitUtils.swift
//      已有，直接重名会冲突）。
//   2. 位图生成由 UIGraphicsBeginImageContextWithOptions 换成 UIGraphicsImageRenderer
//      （iOS 10+ 的正统 API，自动处理 scale/颜色空间）；`scale` 由调用方传，
//      不再读已废弃的 UIScreen.main。
//   3. `generateTintedImage` 上游走 CoreImage/CGImage mask，这里用
//      「铺色 + destinationIn」的等价画法（无 CoreImage 依赖）。
//   4. 上游 ContainedViewLayoutTransition 本仓从设计上就不做（见 TiebaNative/BUILD.bazel
//      注释），这里只取它真正被用到的三个语义位：isAnimated / duration / curve，
//      做成 TiebaNodesTransition，并提供 updateFrame / updateFrameAdditive /
//      animatePositionAdditive / updateAlpha 四个它在本目录被调用的入口。
//   5. 上游 transition.updateFrame 对 CALayer 直接做 position+bounds 加性动画；这里
//      改成「模型值先落、再补一条 from→to 的非加性动画」——to 就是模型值，动画结束
//      不会回跳，也不需要 beginWithCurrentState 之外的状态。
//   6. **动画与帧驱动不再自带替身（本次接线统一）**：原先本文件自带的
//      TiebaNodesAnimation（CALayer.animate* 的替身）+ 非隔离 CAAnimationDelegate 桥
//      + TiebaNodesDisplayLinkAnimator（CADisplayLink 壳）已全部删除，改用本仓既有件：
//        · CALayer.animate / animateAlpha / animateScale / animatePosition
//          ← UI/Components/TiebaCAAnimationUtils.swift
//        · TiebaConstantDisplayLinkAnimator ← Core/TiebaDisplayLinkAnimator.swift
//      所以本目录不再「可脱离本仓其它文件独立编译」——这是有意的：同一份动画语义
//      在本仓只应有一处实现。
//   7. 未接帧率对齐（Core/TiebaAnimationFrameRate 未在本目录接）：动画都用系统默认档跑。
//
// 并发：本文件所有可变状态都只从主线程访问，类型级 @MainActor 是唯一手段；
//      动画 completion 的 CAAnimationDelegate 桥由 TiebaCAAnimationUtils 提供，
//      非隔离的委托类不在本文件里。

import Foundation
import UIKit
import QuartzCore

// MARK: - 布局过渡

/// 过渡曲线。上游是 ContainedViewLayoutTransitionCurve，这里只保留本目录用得到的四条。
public enum TiebaNodesTransitionCurve: Sendable {
    case linear
    case easeIn
    case easeOut
    case easeInEaseOut

    /// CAMediaTimingFunction 的名字（String 而非 CAMediaTimingFunction，才能让整个
    /// 过渡结构 Sendable）。
    public var timingFunctionName: String {
        switch self {
        case .linear:
            return CAMediaTimingFunctionName.linear.rawValue
        case .easeIn:
            return CAMediaTimingFunctionName.easeIn.rawValue
        case .easeOut:
            return CAMediaTimingFunctionName.easeOut.rawValue
        case .easeInEaseOut:
            return CAMediaTimingFunctionName.easeInEaseOut.rawValue
        }
    }
}

/// ContainedViewLayoutTransition 在本目录的最小替身（见文件头改动 4）。
public struct TiebaNodesTransition: Sendable {
    public let isAnimated: Bool
    public let duration: Double
    public let curve: TiebaNodesTransitionCurve

    public init(isAnimated: Bool, duration: Double, curve: TiebaNodesTransitionCurve) {
        self.isAnimated = isAnimated
        self.duration = duration
        self.curve = curve
    }

    public static let immediate = TiebaNodesTransition(isAnimated: false, duration: 0.0, curve: .easeInEaseOut)

    public static func animated(duration: Double = 0.2, curve: TiebaNodesTransitionCurve = .easeInEaseOut) -> TiebaNodesTransition {
        return TiebaNodesTransition(isAnimated: true, duration: duration, curve: curve)
    }

    /// 与上游 transition.updateFrame(node:frame:) 同义：把 frame 立刻落到模型值上，
    /// 需要动画时再补一条「从旧值到新值」的补间。beginWithCurrentState 为真时起点取
    /// 呈现层当前值（同一帧里连续改两次布局时不会跳）。
    ///
    /// @MainActor：方法是纯值语义，但落 frame / 挂动画都要碰 UIView/CALayer，只能在主 actor 上做。
    @MainActor
    public func updateFrame(_ view: UIView, frame: CGRect, beginWithCurrentState: Bool = false) {
        self.updateFrame(view.layer, frame: frame, beginWithCurrentState: beginWithCurrentState)
    }

    @MainActor
    public func updateFrame(_ layer: CALayer, frame: CGRect, beginWithCurrentState: Bool = false) {
        let previousFrame = layer.frame
        if previousFrame == frame {
            return
        }
        layer.frame = frame
        guard self.isAnimated else {
            return
        }
        var fromFrame = previousFrame
        if beginWithCurrentState, let presentation = layer.presentation() {
            fromFrame = presentation.frame
        }
        if fromFrame == frame {
            return
        }
        let duration = self.duration
        let timingFunction = self.curve.timingFunctionName
        // 动画助手统一走 UI/Components/TiebaCAAnimationUtils.swift 的 CALayer.animate*（见文件头改动 6）。
        layer.animate(from: NSValue(cgPoint: CGPoint(x: fromFrame.midX, y: fromFrame.midY)), to: NSValue(cgPoint: CGPoint(x: frame.midX, y: frame.midY)), keyPath: "position", timingFunction: timingFunction, duration: duration, key: "TiebaNodesTransition.position")
        layer.animate(from: NSValue(cgRect: fromFrame), to: NSValue(cgRect: frame), keyPath: "bounds", timingFunction: timingFunction, duration: duration, key: "TiebaNodesTransition.bounds")
    }

    /// 与上游 transition.updateFrameAdditive(node:frame:) 同义：frame 直接落值，
    /// 动画用「加性 position」表达旧位置到新位置的位移。位数个兄弟节点同时被布局改动时，
    /// 加性动画不会互相覆盖掉对方写进 position 的绝对值。
    @MainActor
    public func updateFrameAdditive(_ view: UIView, frame: CGRect) {
        self.updateFrameAdditive(view.layer, frame: frame)
    }

    @MainActor
    public func updateFrameAdditive(_ layer: CALayer, frame: CGRect) {
        let previousFrame = layer.frame
        if previousFrame == frame {
            return
        }
        layer.frame = frame
        guard self.isAnimated else {
            return
        }
        let offset = CGPoint(x: previousFrame.midX - frame.midX, y: previousFrame.midY - frame.midY)
        if offset == .zero {
            return
        }
        layer.animate(from: NSValue(cgPoint: offset), to: NSValue(cgPoint: .zero), keyPath: "position", timingFunction: self.curve.timingFunctionName, duration: self.duration, additive: true, key: "TiebaNodesTransition.positionAdditive")
    }

    /// 与上游 transition.animatePositionAdditive(node:offset:) 同义：
    /// 「该节点此刻比目标位置偏移了 offset」，动画把它滑回目标位置。
    @MainActor
    public func animatePositionAdditive(_ view: UIView, offset: CGPoint) {
        self.animatePositionAdditive(view.layer, offset: offset)
    }

    @MainActor
    public func animatePositionAdditive(_ layer: CALayer, offset: CGPoint) {
        guard self.isAnimated, offset != .zero else {
            return
        }
        layer.animate(from: NSValue(cgPoint: offset), to: NSValue(cgPoint: .zero), keyPath: "position", timingFunction: self.curve.timingFunctionName, duration: self.duration, additive: true, key: "TiebaNodesTransition.positionAdditive")
    }

    /// 与上游 transition.updateAlpha(layer:alpha:completion:) 同义。
    @MainActor
    public func updateAlpha(_ layer: CALayer, alpha: CGFloat, completion: ((Bool) -> Void)? = nil) {
        let fromAlpha: CGFloat
        if let presentation = layer.presentation() {
            fromAlpha = CGFloat(presentation.opacity)
        } else {
            fromAlpha = CGFloat(layer.opacity)
        }
        layer.opacity = Float(alpha)
        guard self.isAnimated, fromAlpha != alpha else {
            completion?(true)
            return
        }
        layer.animateAlpha(from: fromAlpha, to: alpha, duration: self.duration, timingFunction: self.curve.timingFunctionName, completion: completion)
    }
}

// MARK: - 位图与几何

/// Display/Source/UIKitUtils.swift 里几个生成式工具的替身（见文件头改动 1、2、3）。
@MainActor
public enum TiebaNodesGraphics {
    /// 与上游 generateImage(size:opaque:scale:rotatedContext:) 同义。
    /// rotatedContext 那个变体只是把上下文做了翻转，本目录的调用点都自带
    /// CGContext 坐标语义，故只保留直绘版本。
    public static func image(size: CGSize, opaque: Bool = false, scale: CGFloat? = nil, body: (CGContext, CGSize) -> Void) -> UIImage? {
        if size.width.isZero || size.height.isZero {
            return nil
        }
        let format = UIGraphicsImageRendererFormat()
        format.opaque = opaque
        if let scale = scale, scale > 0.0 {
            format.scale = scale
        }
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            body(context.cgContext, size)
        }
    }

    /// 与上游 generateFilledCircleImage(diameter:color:) 同义。
    public static func filledCircle(diameter: CGFloat, color: UIColor, scale: CGFloat? = nil) -> UIImage? {
        return self.image(size: CGSize(width: diameter, height: diameter), scale: scale) { context, size in
            context.setFillColor(color.cgColor)
            context.fillEllipse(in: CGRect(origin: CGPoint(), size: size))
        }
    }

    /// 与上游 generateTintedImage(image:color:) 同义（画法见文件头改动 3）。
    public static func tinted(_ image: UIImage, color: UIColor) -> UIImage? {
        let size = image.size
        if size.width.isZero || size.height.isZero {
            return nil
        }
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = image.scale
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let rect = CGRect(origin: CGPoint(), size: size)
            color.setFill()
            context.fill(rect)
            // destinationIn：用图片的 alpha 去裁刚铺好的纯色，等价于上游的 mask 画法。
            image.draw(in: rect, blendMode: .destinationIn, alpha: 1.0)
        }
    }

    /// 与上游 floorToScreenPixels 同义：把值对齐到物理像素栅格，避免 1px 细线糊成 2px。
    /// scale 显式传入（不读 UIScreen.main，理由见 Core/TiebaAnimationFrameRate.swift 注释）。
    public static func floorToScreenPixels(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        let scale = scale > 0.0 ? scale : 1.0
        return floor(value * scale) / scale
    }

    /// 视图所在屏幕的像素密度；还没上屏时退回 traitCollection 的值。
    public static func displayScale(for view: UIView) -> CGFloat {
        if let screen = view.window?.screen {
            let scale = screen.traitCollection.displayScale
            if scale > 0.0 {
                return scale
            }
        }
        let scale = view.traitCollection.displayScale
        return scale > 0.0 ? scale : 1.0
    }

    /// 与上游 CALayer.snapshotContentTree() 同义（只做「渲染成一张位图再包成 CALayer」，
    /// 上游的 unhide/keepPortals 等分支本目录用不到）。用于「旧文字层飞出去」这类
    /// 需要保留一份静态副本的动画。
    public static func snapshotLayer(of view: UIView, scale: CGFloat? = nil) -> CALayer? {
        if view.bounds.width.isZero || view.bounds.height.isZero {
            return nil
        }
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = scale ?? view.traitCollection.displayScale
        let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { context in
            view.layer.render(in: context.cgContext)
        }
        guard let cgImage = image.cgImage else {
            return nil
        }
        let layer = CALayer()
        layer.contents = cgImage
        layer.contentsScale = image.scale
        layer.frame = view.frame
        return layer
    }
}
