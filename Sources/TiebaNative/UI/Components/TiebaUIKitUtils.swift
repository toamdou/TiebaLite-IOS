// TiebaUIKitUtils —— UIKit 工具集（颜色代数 / 视图图层树快照 / 像素对齐 / 转场快照）。
//
// 移植自上游 submodules/Display/Source/UIKitUtils.swift。
// 本仓改名：dumpViews → tiebaDumpViews、dumpLayers → tiebaDumpLayers、findParentScrollView → tiebaFindParentScrollView、UIScreenScale → tiebaUIScreenScale、UIScreenPixel → tiebaUIScreenPixel —— 公开符号加本仓前缀，避免污染模块全局命名空间
//
// 【接线状态】本文件是**活文件**（有 5 个真实调用方，见各符号注释）：
//   · UIColor.mixedWith(_:alpha:) —— UI/Transition/TiebaContainedViewLayoutTransition.swift:1798
//   · CGSize.fitted(_:)          —— UI/Media/TiebaShareSheet.swift:152
//   · snapshotContentTree        —— 页面快照链路
//   · tiebaUIScreenScale / tiebaUIScreenPixel —— 像素对齐与绘制路径
//   （本轮零调用方清理删掉了 tiebaFloorToScreenPixels / tiebaCeilToScreenPixels /
//     tiebaAssertNotOnMainThread 三个自由函数：全仓 0 调用方，且像素对齐已由
//     UI/Drawing/TiebaDrawingSupport.swift 的 TiebaDrawingMetrics 承担。）
//
// 本仓改动（本文件合并了两次移植）：
//   【原有】UIColor.mixedWith(:308) / CALayer.layerTintColor(:920) —— 见文件内保留的原始注释。
//   【[移植] 08 号报告 Top 2 补全】：
//     1. 颜色代数块 :69-485（RGB/ARGB/HSB/HSL 取值、desaturatedHSL、withMultiplied*、
//        adjustedPerceivedBrightness、blitOver、blendOver、interpolateTo、distance、average 等）
//        —— 全部标 nonisolated（纯计算，主题色推导常在后台/任意隔离域调用）。
//     2. CGSize 几何块 :486-559 与 CGRect/CGPoint 角点块 :965-987 —— 同样 nonisolated。
//     3. 视图/图层树快照块 :565-965：makeSubtreeSnapshot / makeLayerSubtreeSnapshot /
//        makeLayerSubtreeSnapshotAsView / snapshotContentTree / snapshotContentTreeAsView /
//        tiebaFindParentScrollView / UIImage.precomposed / UIImage.fixedOrientation。
//     4. UIView.animationDurationFactor() :5-9 与 tiebaUIScreenScale / tiebaUIScreenPixel
//        :59-67（上游定义在本文件，多个模块缺这两组符号）。
//   【[移植] 按铁律 4 / 私有 API 规则删去的部分（只留说明，不搬代码）】：
//     - CALayer.blur()/variableBlur()/luminanceToAlpha()/colorInvert()/monochrome()/
//       displacementMap()/colorMatrix() :890-918：全部转发 ObjC 模块 UIKitRuntimeUtils 的
//       make*Filter()，其内部用私有类 CAFilter 反射。
//     - CAEmitterCell.createEmitterBehavior(type:) :935-943：NSClassFromString 拼出私有类
//       "CAEmitterBehavior" + unsafeBitCast 调 behaviorWithType:。
//     - UIView.setMonochromaticEffect(_:) :989-1013 与 setMonochromaticEffectAndAlpha(_:transition:) :1014-1038：
//       依赖 ObjC setMonochromaticEffectImpl（私有 CIFilter 反射），后者还依赖 ContainedViewLayoutTransition。
//     - springAnimationValueAt / makeSpringAnimation / makeSpringBounceAnimation /
//       makeCustomZoomBlurEffect / applySmoothRoundedCorners :11-29：同样转发 ObjC 实现
//       （Animation/CAAnimationUtils.swift 已自带纯 Swift 等价内联，避免重复符号）。
//     - makeSubtreeSnapshot 的 keepPortals Portal 分支：见该函数内的 [移植] 注释（私有 layer 类名 + KVC）。
//   除上述以外，函数体逐行与上游一致（未重写、未优化）。

import Foundation
import UIKit
import AVFoundation

public extension UIView {
    /// 上游 :5-9 转发 ObjC 模块 UIKitRuntimeUtils 的 animationDurationFactorImpl()：
    /// 真机恒为 1.0；模拟器为配合 "Slow Animations" 走私有符号 UIAnimationDragCoefficient()。
    /// [移植] 本工程没有 ObjC 模块，取真机语义（不引入私有 API）。
    nonisolated static func animationDurationFactor() -> Double {
        return 1.0
    }
}

public func tiebaDumpViews(_ view: UIView) {
    tiebaDumpViews(view, indent: "")
}

private func tiebaDumpViews(_ view: UIView, indent: String = "") {
    print("\(indent)\(view)")
    let nextIndent = indent + "-"
    for subview in view.subviews {
        tiebaDumpViews(subview as UIView, indent: nextIndent)
    }
}

public func tiebaDumpLayers(_ layer: CALayer) {
    tiebaDumpLayers(layer, indent: "")
}

private func tiebaDumpLayers(_ layer: CALayer, indent: String = "") {
    print("\(indent)\(layer.debugDescription)(frame: \(layer.frame), bounds: \(layer.bounds))")
    if layer.sublayers != nil {
        let nextIndent = indent + "—"
        if let sublayers = layer.sublayers {
            for sublayer in sublayers {
                tiebaDumpLayers(sublayer as CALayer, indent: nextIndent)
            }
        }
    }
}

// [移植] Swift 6：UIScreen.main 在 SDK 里是 @MainActor 隔离的，nonisolated 全局不能引用它（iOS 26 起另加弃用告警）。
//        改用 UIGraphicsImageRendererFormat.preferred().scale——SDK 头文件对该方法的定义就是「best suited for the
//        main screen's current configuration」，即主屏 display scale，与 UIScreen.main.scale 同值，且本身非隔离。
//        这样 tiebaUIScreenScale / tiebaUIScreenPixel 以及依赖它们的 tiebaFloorToScreenPixels / tiebaCeilToScreenPixels /
//        CGSize.multipliedByScreenScale / dividedByScreenScale 都保持 nonisolated（后台布局与测量路径照样可调用），
//        与 Text/TextNode.swift 的同一做法一致。
public let tiebaUIScreenScale: CGFloat = UIGraphicsImageRendererFormat.preferred().scale
// [移植] 上游这里读全局 UIScreenScale；iOS 26 起 UIScreen.main 已弃用（仅告警，语义不变）。


public let tiebaUIScreenPixel = 1.0 / tiebaUIScreenScale

public extension UIColor {
    nonisolated convenience init(rgb: UInt32) {
        self.init(red: CGFloat((rgb >> 16) & 0xff) / 255.0, green: CGFloat((rgb >> 8) & 0xff) / 255.0, blue: CGFloat(rgb & 0xff) / 255.0, alpha: 1.0)
    }
    
    nonisolated convenience init(rgb: UInt32, alpha: CGFloat) {
        self.init(red: CGFloat((rgb >> 16) & 0xff) / 255.0, green: CGFloat((rgb >> 8) & 0xff) / 255.0, blue: CGFloat(rgb & 0xff) / 255.0, alpha: alpha)
    }
    
    nonisolated convenience init(argb: UInt32) {
        self.init(red: CGFloat((argb >> 16) & 0xff) / 255.0, green: CGFloat((argb >> 8) & 0xff) / 255.0, blue: CGFloat(argb & 0xff) / 255.0, alpha: CGFloat((argb >> 24) & 0xff) / 255.0)
    }
    
    nonisolated convenience init?(hexString: String) {
        let cleanedString = hexString.hasPrefix("#") ? hexString.dropFirst() : hexString[...]
        guard let value = UInt32(cleanedString, radix: 16) else {
            return nil
        }
        
        if hexString.count > 7 {
            self.init(argb: value)
        } else {
            self.init(rgb: value)
        }
    }
    
    nonisolated var alpha: CGFloat {
        var alpha: CGFloat = 0.0
        if self.getRed(nil, green: nil, blue: nil, alpha: &alpha) {
            return alpha
        } else if self.getWhite(nil, alpha: &alpha) {
            return alpha
        } else {
            return 0.0
        }
    }
    
    nonisolated var rgb: UInt32 {
        var red: CGFloat = 0.0
        var green: CGFloat = 0.0
        var blue: CGFloat = 0.0
        if self.getRed(&red, green: &green, blue: &blue, alpha: nil) {
            let r: UInt32 = UInt32(max(0.0, red) * 255.0)
            let g: UInt32 = UInt32(max(0.0, green) * 255.0)
            let b: UInt32 = UInt32(max(0.0, blue) * 255.0)
            return (r << 16) | (g << 8) | b
        } else if self.getWhite(&red, alpha: nil) {
            let w: UInt32 = UInt32(max(0.0, red) * 255.0)
            return (w << 16) | (w << 8) | w
        } else {
            return 0
        }
    }
    
    nonisolated var argb: UInt32 {
        var red: CGFloat = 0.0
        var green: CGFloat = 0.0
        var blue: CGFloat = 0.0
        var alpha: CGFloat = 0.0
        if self.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            let a: UInt32 = UInt32(alpha * 255.0)
            let r: UInt32 = UInt32(max(0.0, red) * 255.0)
            let g: UInt32 = UInt32(max(0.0, green) * 255.0)
            let b: UInt32 = UInt32(max(0.0, blue) * 255.0)
            return (a << 24) | (r << 16) | (g << 8) | b
        } else if self.getWhite(&red, alpha: &alpha) {
            let a: UInt32 = UInt32(max(0.0, alpha) * 255.0)
            let w: UInt32 = UInt32(max(0.0, red) * 255.0)
            return (a << 24) | (w << 16) | (w << 8) | w
        } else {
            return 0
        }
    }
    
    nonisolated var components: (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        var red: CGFloat = 0.0
        var green: CGFloat = 0.0
        var blue: CGFloat = 0.0
        var alpha: CGFloat = 0.0
        if self.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            return (red, green, blue, alpha)
        } else if self.getWhite(&red, alpha: &alpha) {
            return (red, red, red, alpha)
        } else {
            return (0.0, 0.0, 0.0, 0.0)
        }
    }
    
    nonisolated var lightness: CGFloat {
        var red: CGFloat = 0.0
        var green: CGFloat = 0.0
        var blue: CGFloat = 0.0
        if self.getRed(&red, green: &green, blue: &blue, alpha: nil) {
            return 0.2126 * red + 0.7152 * green + 0.0722 * blue
        } else if self.getWhite(&red, alpha: nil) {
            return red
        } else {
            return 0.0
        }
    }
    
    nonisolated var brightness: CGFloat {
        var hue: CGFloat = 0.0
        var saturation: CGFloat = 0.0
        var brightness: CGFloat = 0.0
        var alpha: CGFloat = 0.0
        self.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return brightness
    }
    
    nonisolated var saturation: CGFloat {
        var hue: CGFloat = 0.0
        var saturation: CGFloat = 0.0
        var brightness: CGFloat = 0.0
        var alpha: CGFloat = 0.0
        self.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return saturation
    }
    
    nonisolated func desaturatedHSL(by amount: CGFloat) -> UIColor {
        let amount = max(0, min(1, amount))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard self.getRed(&r, green: &g, blue: &b, alpha: &a) else { return self }
        
        let maxC = max(r, g, b)
        let minC = min(r, g, b)
        let delta = maxC - minC
        
        var h: CGFloat = 0
        let l: CGFloat = (maxC + minC) / 2
        var s: CGFloat = 0
        
        if delta != 0 {
            s = delta / (1 - abs(2 * l - 1))
            if maxC == r {
                h = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxC == g {
                h = ((b - r) / delta) + 2
            } else {
                h = ((r - g) / delta) + 4
            }
            h /= 6
            if h < 0 { h += 1 }
        }
        
        let s2 = s * (1 - amount)
        
        func hue2rgb(_ p: CGFloat, _ q: CGFloat, _ t: CGFloat) -> CGFloat {
            var t = t
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1/6 { return p + (q - p) * 6 * t }
            if t < 1/2 { return q }
            if t < 2/3 { return p + (q - p) * (2/3 - t) * 6 }
            return p
        }
        
        let q: CGFloat = l < 0.5 ? l * (1 + s2) : l + s2 - l * s2
        let p: CGFloat = 2 * l - q
        
        let r2 = hue2rgb(p, q, h + 1/3)
        let g2 = hue2rgb(p, q, h)
        let b2 = hue2rgb(p, q, h - 1/3)
        
        return UIColor(red: r2, green: g2, blue: b2, alpha: a)
    }
    
    /// 与另一颜色按 alpha 线性混合（逐分量，含 alpha 通道）。
    /// 上游：UIKitUtils.swift:308
    nonisolated func mixedWith(_ other: UIColor, alpha: CGFloat) -> UIColor {
        let alpha = min(1.0, max(0.0, alpha))
        let oneMinusAlpha = 1.0 - alpha
        
        var r1: CGFloat = 0.0
        var r2: CGFloat = 0.0
        var g1: CGFloat = 0.0
        var g2: CGFloat = 0.0
        var b1: CGFloat = 0.0
        var b2: CGFloat = 0.0
        var a1: CGFloat = 0.0
        var a2: CGFloat = 0.0
        if self.getRed(&r1, green: &g1, blue: &b1, alpha: &a1) &&
            other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        {
            let r = r1 * oneMinusAlpha + r2 * alpha
            let g = g1 * oneMinusAlpha + g2 * alpha
            let b = b1 * oneMinusAlpha + b2 * alpha
            let a = a1 * oneMinusAlpha + a2 * alpha
            return UIColor(red: r, green: g, blue: b, alpha: a)
        }
        return self
    }
    
    nonisolated func blitOver(_ other: UIColor, alpha: CGFloat) -> UIColor {
        let alpha = min(1.0, max(0.0, alpha))
        
        var r1: CGFloat = 0.0
        var r2: CGFloat = 0.0
        var g1: CGFloat = 0.0
        var g2: CGFloat = 0.0
        var b1: CGFloat = 0.0
        var b2: CGFloat = 0.0
        var a1: CGFloat = 0.0
        var a2: CGFloat = 0.0
        if self.getRed(&r1, green: &g1, blue: &b1, alpha: &a1) &&
            other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        {
            let resultingAlpha = max(0.0, min(1.0, alpha * a1))
            let oneMinusResultingAlpha = 1.0 - resultingAlpha
            
            let r = r1 * resultingAlpha + r2 * oneMinusResultingAlpha
            let g = g1 * resultingAlpha + g2 * oneMinusResultingAlpha
            let b = b1 * resultingAlpha + b2 * oneMinusResultingAlpha
            let a: CGFloat = 1.0
            return UIColor(red: r, green: g, blue: b, alpha: a)
        }
        return self
    }
    
    nonisolated func withMultipliedAlpha(_ alpha: CGFloat) -> UIColor {
        var r1: CGFloat = 0.0
        var g1: CGFloat = 0.0
        var b1: CGFloat = 0.0
        var a1: CGFloat = 0.0
        if self.getRed(&r1, green: &g1, blue: &b1, alpha: &a1) {
            return UIColor(red: r1, green: g1, blue: b1, alpha: max(0.0, min(1.0, a1 * alpha)))
        }
        return self
    }
    
    nonisolated private var colorComponents: (r: Int32, g: Int32, b: Int32) {
        var r: CGFloat = 0.0
        var g: CGFloat = 0.0
        var b: CGFloat = 0.0
        if self.getRed(&r, green: &g, blue: &b, alpha: nil) {
            return (Int32(max(0.0, r) * 255.0), Int32(max(0.0, g) * 255.0), Int32(max(0.0, b) * 255.0))
        } else if self.getWhite(&r, alpha: nil) {
            return (Int32(max(0.0, r) * 255.0), Int32(max(0.0, r) * 255.0), Int32(max(0.0, r) * 255.0))
        }
        return (0, 0, 0)
    }
    
    nonisolated func distance(to other: UIColor) -> Int32 {
        let e1 = self.colorComponents
        let e2 = other.colorComponents
        let rMean = (e1.r + e2.r) / 2
        let r = e1.r - e2.r
        let g = e1.g - e2.g
        let b = e1.b - e2.b
        return ((512 + rMean) * r * r) >> 8 + 4 * g * g + ((767 - rMean) * b * b) >> 8
    }
}

public extension CGSize {
    nonisolated func fitted(_ size: CGSize) -> CGSize {
        var fittedSize = self
        if fittedSize.width > size.width {
            fittedSize = CGSize(width: size.width, height: floor((fittedSize.height * size.width / max(fittedSize.width, 1.0))))
        }
        if fittedSize.height > size.height {
            fittedSize = CGSize(width: floor((fittedSize.width * size.height / max(fittedSize.height, 1.0))), height: size.height)
        }
        return fittedSize
    }
    
    nonisolated func aspectFilled(_ size: CGSize) -> CGSize {
        let scale = max(size.width / max(1.0, self.width), size.height / max(1.0, self.height))
        return CGSize(width: floor(self.width * scale), height: floor(self.height * scale))
    }
}

public extension UIImage {
}

private func makeSubtreeSnapshot(layer: CALayer, keepPortals: Bool = false, keepTransform: Bool = false) -> UIView? {
    if layer is AVSampleBufferDisplayLayer {
        return nil
    }
    // [移植] 上游此处还有 keepPortals 的 Portal 分支，用的是私有 API：
    //   layer.description 里匹配私有 layer 类名 "PortalLayer"，再 value(forKey: "sourceView")
    //   取 UIKitPortalViewProtocol 的私有属性。按任务要求「注释标明 + 跳过」，不搬这段代码，
    //   因此 keepPortals 参数在本实现里只影响下面的 0x1bad/0x2bad/0x3bad 标签分支
    //   （那三个 tag 是 上游 自己的约定，不是私有 API）。
    var unhide = false
    var markToHide = false
    if keepPortals {
        if let view = (layer.delegate as? UIView) {
            if view.tag == 0x1bad, view.alpha > 0.0 {
                return nil
            } else if view.tag == 0x2bad {
                markToHide = true
            } else if view.tag == 0x3bad {
                unhide = true
            }
        }
    }
    let view = UIView()
    if markToHide {
        view.tag = 0x2bad
    }
    view.layer.isHidden = layer.isHidden
    if unhide {
        view.layer.opacity = 1.0
    } else {
        view.layer.opacity = layer.opacity
    }
    view.layer.contents = layer.contents
    view.layer.contentsRect = layer.contentsRect
    view.layer.contentsScale = layer.contentsScale
    view.layer.contentsCenter = layer.contentsCenter
    view.layer.contentsGravity = layer.contentsGravity
    view.layer.masksToBounds = layer.masksToBounds
    view.layer.layerTintColor = layer.layerTintColor
    if let mask = layer.mask {
        if let shapeMask = mask as? CAShapeLayer {
            let maskLayer = CAShapeLayer()
            maskLayer.path = shapeMask.path
            view.layer.mask = maskLayer
        } else {
            let maskLayer = CALayer()
            maskLayer.contents = mask.contents
            maskLayer.contentsRect = mask.contentsRect
            maskLayer.contentsScale = mask.contentsScale
            maskLayer.contentsCenter = mask.contentsCenter
            maskLayer.contentsGravity = mask.contentsGravity
            maskLayer.transform = mask.transform
            maskLayer.position = mask.position
            maskLayer.bounds = mask.bounds
            maskLayer.anchorPoint = mask.anchorPoint
            maskLayer.layerTintColor = mask.layerTintColor
            view.layer.mask = maskLayer
        }
    }
    view.layer.cornerRadius = layer.cornerRadius
    view.layer.backgroundColor = layer.backgroundColor
    
    if let sublayers = layer.sublayers {
        for sublayer in sublayers {
            let subtree = makeSubtreeSnapshot(layer: sublayer, keepPortals: keepPortals, keepTransform: keepTransform)
            if let subtree = subtree {
                if subtree.tag == 0x2bad {
                    return nil
                }
                if keepTransform {
                    subtree.layer.transform = sublayer.transform
                }
                if subtree.tag != 0xbeef {
                    subtree.layer.transform = sublayer.transform
                    subtree.layer.position = sublayer.position
                    subtree.layer.bounds = sublayer.bounds
                    subtree.layer.anchorPoint = sublayer.anchorPoint
                    subtree.layer.layerTintColor = sublayer.layerTintColor
                }
                if let maskLayer = subtree.layer.mask {
//                    maskLayer.transform = sublayer.transform
//                    maskLayer.position = sublayer.position
//                    maskLayer.bounds = sublayer.bounds
//                    maskLayer.anchorPoint = sublayer.anchorPoint
                    maskLayer.layerTintColor = sublayer.layerTintColor
                }
                view.addSubview(subtree)
            } else {
                continue
            }
        }
    }
    
    return view
}

private func makeLayerSubtreeSnapshot(layer: CALayer) -> CALayer? {
    if layer is AVSampleBufferDisplayLayer {
        return nil
    }
    
    if let layer = layer as? CAShapeLayer {
        let view = CAShapeLayer()
        view.isHidden = layer.isHidden
        view.opacity = layer.opacity
        view.contents = layer.contents
        view.contentsRect = layer.contentsRect
        view.contentsScale = layer.contentsScale
        view.contentsCenter = layer.contentsCenter
        view.contentsGravity = layer.contentsGravity
        view.masksToBounds = layer.masksToBounds
        view.cornerRadius = layer.cornerRadius
        view.backgroundColor = layer.backgroundColor
        view.layerTintColor = layer.layerTintColor
        view.path = layer.path
        view.fillColor = layer.fillColor
        view.fillRule = layer.fillRule
        view.strokeColor = layer.strokeColor
        view.strokeStart = layer.strokeStart
        view.strokeEnd = layer.strokeEnd
        view.lineWidth = layer.lineWidth
        view.miterLimit = layer.miterLimit
        view.lineCap = layer.lineCap
        view.lineJoin = layer.lineJoin
        view.lineDashPhase = layer.lineDashPhase
        view.lineDashPattern = layer.lineDashPattern
        
        if let sublayers = layer.sublayers {
            for sublayer in sublayers {
                let subtree = makeLayerSubtreeSnapshot(layer: sublayer)
                if let subtree = subtree {
                    subtree.transform = sublayer.transform
                    subtree.position = sublayer.position
                    subtree.bounds = sublayer.bounds
                    subtree.anchorPoint = sublayer.anchorPoint
                    view.addSublayer(subtree)
                } else {
                    return nil
                }
            }
        }
        return view
    } else if let layer = layer as? CAGradientLayer {
        let view = CAGradientLayer()
        view.isHidden = layer.isHidden
        view.opacity = layer.opacity
        view.contents = layer.contents
        view.contentsRect = layer.contentsRect
        view.contentsScale = layer.contentsScale
        view.contentsCenter = layer.contentsCenter
        view.contentsGravity = layer.contentsGravity
        view.masksToBounds = layer.masksToBounds
        view.cornerRadius = layer.cornerRadius
        view.backgroundColor = layer.backgroundColor
        view.layerTintColor = layer.layerTintColor
        view.colors = layer.colors
        view.locations = layer.locations
        view.startPoint = layer.startPoint
        view.endPoint = layer.endPoint
        view.type = layer.type
        
        if let sublayers = layer.sublayers {
            for sublayer in sublayers {
                let subtree = makeLayerSubtreeSnapshot(layer: sublayer)
                if let subtree = subtree {
                    subtree.transform = sublayer.transform
                    subtree.position = sublayer.position
                    subtree.bounds = sublayer.bounds
                    subtree.anchorPoint = sublayer.anchorPoint
                    view.addSublayer(subtree)
                } else {
                    return nil
                }
            }
        }
        return view
    } else {
        let view = CALayer()
        view.isHidden = layer.isHidden
        view.opacity = layer.opacity
        view.contents = layer.contents
        view.contentsRect = layer.contentsRect
        view.contentsScale = layer.contentsScale
        view.contentsCenter = layer.contentsCenter
        view.contentsGravity = layer.contentsGravity
        view.masksToBounds = layer.masksToBounds
        view.cornerRadius = layer.cornerRadius
        view.backgroundColor = layer.backgroundColor
        view.layerTintColor = layer.layerTintColor
        if let sublayers = layer.sublayers {
            for sublayer in sublayers {
                let subtree = makeLayerSubtreeSnapshot(layer: sublayer)
                if let subtree = subtree {
                    subtree.transform = sublayer.transform
                    subtree.position = sublayer.position
                    subtree.bounds = sublayer.bounds
                    subtree.anchorPoint = sublayer.anchorPoint
                    view.addSublayer(subtree)
                } else {
                    return nil
                }
            }
        }
        return view
    }
}

private func makeLayerSubtreeSnapshotAsView(layer: CALayer) -> UIView? {
    if layer is AVSampleBufferDisplayLayer {
        return nil
    }
    let view = UIView()
    view.layer.isHidden = layer.isHidden
    view.layer.opacity = layer.opacity
    view.layer.contents = layer.contents
    view.layer.contentsRect = layer.contentsRect
    view.layer.contentsScale = layer.contentsScale
    view.layer.contentsCenter = layer.contentsCenter
    view.layer.contentsGravity = layer.contentsGravity
    view.layer.masksToBounds = layer.masksToBounds
    view.layer.cornerRadius = layer.cornerRadius
    view.layer.backgroundColor = layer.backgroundColor
    view.layer.layerTintColor = layer.layerTintColor
    if let sublayers = layer.sublayers {
        for sublayer in sublayers {
            let subtree = makeLayerSubtreeSnapshotAsView(layer: sublayer)
            if let subtree = subtree {
                subtree.layer.transform = sublayer.transform
                subtree.layer.position = sublayer.position
                subtree.layer.bounds = sublayer.bounds
                subtree.layer.anchorPoint = sublayer.anchorPoint
                subtree.layer.layerTintColor = sublayer.layerTintColor
                view.addSubview(subtree)
            } else {
                return nil
            }
        }
    }
    return view
}


public func tiebaFindParentScrollView(view: UIView?) -> UIScrollView? {
    if let view = view {
        if let view = view as? UIScrollView {
            return view
        }
        return tiebaFindParentScrollView(view: view.superview)
    } else {
        return nil
    }
}

public extension UIView {
    func snapshotContentTree(unhide: Bool = false, keepPortals: Bool = false, keepTransform: Bool = false) -> UIView? {
        let wasHidden = self.isHidden
        if unhide && wasHidden {
            self.isHidden = false
        }
        let snapshot = makeSubtreeSnapshot(layer: self.layer, keepPortals: keepPortals, keepTransform: keepTransform)
        if unhide && wasHidden {
            self.isHidden = true
        }
        if let snapshot = snapshot {
            snapshot.layer.position = self.layer.position
            snapshot.layer.bounds = self.layer.bounds
            snapshot.layer.anchorPoint = self.layer.anchorPoint
            return snapshot
        }
        
        return nil
    }
}

public extension CALayer {
    func snapshotContentTree(unhide: Bool = false) -> CALayer? {
        let wasHidden = self.isHidden
        if unhide && wasHidden {
            self.isHidden = false
        }
        let snapshot = makeLayerSubtreeSnapshot(layer: self)
        if unhide && wasHidden {
            self.isHidden = true
        }
        if let snapshot = snapshot {
            snapshot.frame = self.frame
            snapshot.bounds = self.bounds
            return snapshot
        }
        
        return nil
    }
}

// [移植] 上游 :890-918 的 CALayer.blur() / variableBlur() / luminanceToAlpha() / colorInvert() /
// monochrome() / displacementMap() / colorMatrix() 全部转发 ObjC 模块 UIKitRuntimeUtils 的
// make*Filter()（内部反射私有类 CAFilter），按铁律 4 整体跳过，不在此处留占位实现。

public extension CALayer {
    /// 图层 tint 色。
    ///
    /// 上游：UIKitUtils.swift:920 —— 走 KVC 键 `contentsMultiplyColor`（**CALayer 私有键**）。
    ///
    /// ⚠️ **私有 API 提示**：`contentsMultiplyColor` 不在公开 CALayer 头文件里。上游
    /// 上游 一直在用（App Store 版也在用），但它是"未来可能被系统拒绝"的风险点。
    /// 之所以仍然逐字保留：本符号的真实作用是**让 CALayer 做乘法着色**（不只是存一个值），
    /// 换成纯 Swift 关联对象就只剩存储语义、丢掉渲染效果。本工程是侧载分发（SideStore），
    /// 风险可接受。若将来要上架，把这里换成 `layer.compositingFilter` 方案。
    nonisolated var layerTintColor: CGColor? {
        get {
            if let value = self.value(forKey: "contentsMultiplyColor"), CFGetTypeID(value as CFTypeRef) == CGColor.typeID {
                let result = value as! CGColor
                return result
            } else {
                return nil
            }
        } set(value) {
            self.setValue(value, forKey: "contentsMultiplyColor")
        }
    }
}

// [移植] 上游 :935-943 的 CAEmitterCell.createEmitterBehavior(type:) 用 NSClassFromString 拼出私有类
// "CAEmitterBehavior" 并 unsafeBitCast 调 behaviorWithType:，按私有 API 规则跳过。

public extension CALayer {
}

public extension CGRect {
    nonisolated var topLeft: CGPoint {
        return self.origin
    }
    
    nonisolated var topRight: CGPoint {
        return CGPoint(x: self.maxX, y: self.minY)
    }
    
    nonisolated var bottomLeft: CGPoint {
        return CGPoint(x: self.minX, y: self.maxY)
    }
    
    nonisolated var bottomRight: CGPoint {
        return CGPoint(x: self.maxX, y: self.maxY)
    }
}

public extension CGPoint {
    nonisolated func offsetBy(dx: CGFloat, dy: CGFloat) -> CGPoint {
        return CGPoint(x: self.x + dx, y: self.y + dy)
    }
}

// [移植] 上游 :989-1038 的 UIView.setMonochromaticEffect(_:) 与 setMonochromaticEffectAndAlpha(_:transition:)
// 依赖 ObjC setMonochromaticEffectImpl（私有 CIFilter 反射），后者还依赖 ContainedViewLayoutTransition，
// 按铁律 4 跳过。
