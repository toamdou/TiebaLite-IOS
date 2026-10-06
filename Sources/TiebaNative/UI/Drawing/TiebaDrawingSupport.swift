// 移植自上游:
//   submodules/Display/Source/GenerateImage.swift  :481-814（DrawingContext / DeviceGraphicsContextSettings）
//   submodules/Display/Source/UIKitUtils.swift      :5-9, :59-67（animationDurationFactor / tiebaUIScreenScale / tiebaUIScreenPixel /
//                                                    floorToScreenPixels / ceilToScreenPixels）
//
// 本文件不是上游某个文件的 1:1 搬运，而是把上面两处上游代码里 **本目录（UI/Drawing）真正用到的那一小部分**
// 抽成一个自洽的公共设施文件。逐条列出改动与理由：
//   1. 上游 DrawingContext 依赖 ObjC 模块（ASCGImageBuffer）与 SwiftSignalKit，本工程零 ObjC。
//      这里改用 CGContext(data: nil, bytesPerRow: 0) 让 CoreGraphics 自己分配像素缓冲，
//      generateImage() 走 CGContext.makeImage()（比上游多一次拷贝，换来零 ObjC 依赖）。
//      对外 API 与上游一致：size / scale / withContext / withFlippedContext / colorAt / blt / generateImage。
//   2. 上游用 ASCGImageBuffer 手写行对齐（DeviceGraphicsContextSettings.bytesPerRow），
//      这里交给 CGContext 自算 bytesPerRow；行对齐语义由 CoreGraphics 保证，结果一致。
//   3. 上游按主屏 gamut 在 displayP3 / sRGB 之间选色彩空间，需要 UIScreen.main（iOS 26 已弃用且 @MainActor）。
//      这里固定 sRGB：blt() 是逐字节 UInt32 运算，固定 8bit sRGB 才与「读 UInt32 当 ARGB」的语义自洽。
//   4. 上游 UIScreenScale / UIScreenPixel / floorToScreenPixels / ceilToScreenPixels 是模块级全局符号；
//      本仓 UI/Components/TiebaUIKitUtils.swift 已有同名实现，同模块再声明一次会重复定义，
//      故统一收进 TiebaDrawingMetrics 命名空间（仅本目录使用）。UIScreen.main 换成
//      UIGraphicsImageRendererFormat.preferred().scale（SDK 定义就是「主屏 display scale」，且非隔离），
//      与本仓 TiebaUIKitUtils.swift 采用同一做法，保持 nonisolated，后台测量路径也能调用。
//   5. 上游 UIView.animationDurationFactor() 转发 ObjC 实现（模拟器走私有 UIAnimationDragCoefficient）。
//      本工程无 ObjC 模块，取真机语义恒为 1.0，不引入私有 API。
//   6. 新增 mixed / rgb / argb / aspectFilled / attributedString 等小工具：上游这些是 UIColor/CGSize/
//      NSAttributedString 的公开扩展，本仓同名扩展已存在（TiebaUIKitUtils.swift 等），为避免重复定义
//      同样收进命名空间。数学与上游逐行一致。
//   7. Swift 6：TiebaBitmapContext 持有可变像素缓冲，天然不是 Sendable；它只在创建它的隔离域内使用
//      （不跨 actor 传递），所以既不需要也不允许 @unchecked Sendable / nonisolated(unsafe) 之类的绕过。

import Foundation
import UIKit
import CoreGraphics

/// 屏度量 + 本目录自用的绘制小工具。
///
/// 为什么不直接用本仓的 `floorToScreenPixels` / `tiebaUIScreenScale`：那两个符号定义在
/// UI/Components/TiebaUIKitUtils.swift，同模块重复声明会报 redeclaration；而本目录要求能独立编译验证
/// （见交付说明里的验证命令），所以自带一份收在命名空间里的等价实现。
enum TiebaDrawingMetrics {
    /// 主屏 display scale。
    /// [移植] 上游 UIKitUtils.swift:77 读 `UIScreen.main.scale`：iOS 26 起 UIScreen.main 已弃用且是 @MainActor。
    ///        `UIGraphicsImageRendererFormat.preferred().scale` 的 SDK 语义就是「最适合主屏当前配置的 scale」，
    ///        与 UIScreen.main.scale 同值，且本身非隔离 —— 于是下面所有度量函数都能保持 nonisolated。
    static let screenScale: CGFloat = {
        let scale = UIGraphicsImageRendererFormat.preferred().scale
        // 极端情况下 preferred() 可能给 0（无屏幕上下文），退化成 2x，避免除零把几何算成 NaN。
        return scale > 0.0 ? scale : 2.0
    }()

    /// 一个物理像素对应的点数（上游 UIKitUtils.swift:86）。
    static var screenPixel: CGFloat {
        return 1.0 / self.screenScale
    }

    /// 向下对齐到物理像素（上游 UIKitUtils.swift:79-81）。
    nonisolated static func floorToPixels(_ value: CGFloat) -> CGFloat {
        return floor(value * TiebaDrawingMetrics.screenScale) / TiebaDrawingMetrics.screenScale
    }

    /// 向上对齐到物理像素（上游 UIKitUtils.swift:82-84）。
    nonisolated static func ceilToPixels(_ value: CGFloat) -> CGFloat {
        return ceil(value * TiebaDrawingMetrics.screenScale) / TiebaDrawingMetrics.screenScale
    }

    /// 上游 UIView.animationDurationFactor()：真机恒为 1.0；模拟器「Slow Animations」下小于 1。
    /// [移植] 上游转发 ObjC 实现，本工程无 ObjC 模块，取真机语义。
    nonisolated static func animationDurationFactor() -> Double {
        return 1.0
    }

    /// 上游 UIColor(rgb:) —— 0xRRGGBB。
    nonisolated static func rgb(_ value: UInt32, alpha: CGFloat = 1.0) -> UIColor {
        return UIColor(
            red: CGFloat((value >> 16) & 0xff) / 255.0,
            green: CGFloat((value >> 8) & 0xff) / 255.0,
            blue: CGFloat(value & 0xff) / 255.0,
            alpha: alpha
        )
    }

    /// 上游 UIColor(argb:) —— 0xAARRGGBB。
    nonisolated static func argb(_ value: UInt32) -> UIColor {
        return UIColor(
            red: CGFloat((value >> 16) & 0xff) / 255.0,
            green: CGFloat((value >> 8) & 0xff) / 255.0,
            blue: CGFloat(value & 0xff) / 255.0,
            alpha: CGFloat((value >> 24) & 0xff) / 255.0
        )
    }

    /// 上游 UIColor.mixedWith(_:alpha:)（UIKitUtils.swift:329-351）—— 逐分量（含 alpha）线性混合。
    nonisolated static func mixed(_ color: UIColor, _ other: UIColor, alpha: CGFloat) -> UIColor {
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
        if color.getRed(&r1, green: &g1, blue: &b1, alpha: &a1), other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2) {
            return UIColor(
                red: r1 * oneMinusAlpha + r2 * alpha,
                green: g1 * oneMinusAlpha + g2 * alpha,
                blue: b1 * oneMinusAlpha + b2 * alpha,
                alpha: a1 * oneMinusAlpha + a2 * alpha
            )
        }
        return color
    }

    /// 上游 UIColor.withMultipliedAlpha(_:)（UIKitUtils.swift:428-437）：同色，alpha 相乘。
    nonisolated static func multiplyingAlpha(_ color: UIColor, _ factor: CGFloat) -> UIColor {
        var red: CGFloat = 0.0
        var green: CGFloat = 0.0
        var blue: CGFloat = 0.0
        var alpha: CGFloat = 0.0
        if color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            return UIColor(red: red, green: green, blue: blue, alpha: max(0.0, min(1.0, alpha * factor)))
        }
        return color
    }

    /// 上游 CGSize.aspectFilled(_:)（UIKitUtils.swift:533-536）。
    nonisolated static func aspectFilled(_ size: CGSize, in boundingSize: CGSize) -> CGSize {
        let scale = max(boundingSize.width / max(1.0, size.width), boundingSize.height / max(1.0, size.height))
        return CGSize(width: floor(size.width * scale), height: floor(size.height * scale))
    }

    /// 上游 NSAttributedString(string:font:textColor:)：本仓同名便利构造器可能已存在，故收进命名空间。
    nonisolated static func attributedString(_ string: String, font: UIFont, color: UIColor) -> NSAttributedString {
        return NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
    }
}

/// 上游 DrawingContext（GenerateImage.swift:583-814）的无 ObjC 版本：一块可绘制的位图 + 逐像素访问。
///
/// 与上游的差异见文件头 1/2/3 条。所有方法都 nonisolated —— 本类型不持有跨隔离域的状态，
/// 调用方在哪个域创建就在哪个域用完即可（PDF 预览、图片透明探测都在后台路径上被调用过）。
final class TiebaBitmapContext {
    let size: CGSize
    let scale: CGFloat
    let scaledSize: CGSize
    let bytesPerRow: Int
    let length: Int

    private let context: CGContext

    /// 位图首字节。**只在 generateImage() 之前有效**（makeImage() 之后 CoreGraphics 可能改写内部缓冲）。
    var bytes: UnsafeMutableRawPointer {
        return self.context.data!
    }

    init?(size: CGSize, scale: CGFloat = 0.0, opaque: Bool = false, clear: Bool = false) {
        if size.width <= 0.0 || size.height <= 0.0 {
            return nil
        }
        // 与上游一致：0 尺寸退化成 1pt，避免创建 0 宽位图。
        let size = CGSize(width: max(1.0, size.width), height: max(1.0, size.height))
        let actualScale = scale.isZero ? TiebaDrawingMetrics.screenScale : scale

        self.size = size
        self.scale = actualScale
        self.scaledSize = CGSize(width: size.width * actualScale, height: size.height * actualScale)

        // premultipliedFirst + byteOrder32Little = 内存里 BGRA，按 UInt32 小端读出即 0xAARRGGBB，
        // 这正是 colorAt()/blt() 期望的布局（上游 transparentBitmapInfo 同款）。
        let alphaInfo: CGImageAlphaInfo = opaque ? .noneSkipFirst : .premultipliedFirst
        let bitmapInfo = alphaInfo.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

        guard let context = CGContext(
            data: nil,
            width: Int(self.scaledSize.width),
            height: Int(self.scaledSize.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }
        self.context = context
        // 与上游一致：先按 scale 放大 CTM，之后所有绘制坐标都是「点」。
        self.context.scaleBy(x: actualScale, y: actualScale)
        self.bytesPerRow = context.bytesPerRow
        self.length = context.bytesPerRow * Int(self.scaledSize.height)

        if clear {
            // CGContext(data: nil) 分配的缓冲不保证清零，上游这里是 memset，照做。
            memset(self.bytes, 0, self.length)
        }
    }

    /// 上游 withContext(_:)：把 y 轴翻转成「左上原点」，回调返回后还原，避免调用方漏还原导致后续绘制错位。
    func withContext(_ f: (CGContext) -> Void) {
        let context = self.context
        context.translateBy(x: self.size.width / 2.0, y: self.size.height / 2.0)
        context.scaleBy(x: 1.0, y: -1.0)
        context.translateBy(x: -self.size.width / 2.0, y: -self.size.height / 2.0)

        f(context)

        context.translateBy(x: self.size.width / 2.0, y: self.size.height / 2.0)
        context.scaleBy(x: 1.0, y: -1.0)
        context.translateBy(x: -self.size.width / 2.0, y: -self.size.height / 2.0)
    }

    /// 上游 withFlippedContext(_:)：不做翻转，直接用 CGContext 原生（左下原点）坐标。
    func withFlippedContext(_ f: (CGContext) -> Void) {
        f(self.context)
    }

    /// 上游 generateImage()：这里走 makeImage()，比上游多一次像素拷贝（见文件头第 1 条）。
    func generateImage() -> UIImage? {
        if self.scaledSize.width.isZero || self.scaledSize.height.isZero {
            return nil
        }
        guard let cgImage = self.context.makeImage() else {
            return nil
        }
        return UIImage(cgImage: cgImage, scale: self.scale, orientation: .up)
    }

    /// 上游 colorAt(_:)（GenerateImage.swift:723-734）：按点坐标取像素，越界返回 clear。
    func colorAt(_ point: CGPoint) -> UIColor {
        let x = Int(point.x * self.scale)
        let y = Int(point.y * self.scale)
        if x >= 0 && x < Int(self.scaledSize.width) && y >= 0 && y < Int(self.scaledSize.height) {
            // 行首按 UInt32 寻址；byteOrder32Little + premultipliedFirst 下读出来就是 0xAARRGGBB。
            let srcLine = self.bytes.advanced(by: y * self.bytesPerRow).assumingMemoryBound(to: UInt32.self)
            let colorValue = (srcLine + x).pointee
            return TiebaDrawingMetrics.argb(colorValue)
        } else {
            return .clear
        }
    }

    /// 上游 blt(_:at:mode:)（GenerateImage.swift:736-813）：仅 .Alpha 模式被本目录用到，逐行照搬。
    ///
    /// 语义：以 other 的 alpha 为遮罩，把 self 的已有像素「乘」一下（min(baseAlpha, srcAlpha) 且 RGB 同步预乘）。
    /// 圆角遮罩就是靠这个把矩形图切成圆角。
    func blt(_ other: TiebaBitmapContext, at: CGPoint) {
        guard abs(other.scale - self.scale) < CGFloat.ulpOfOne else {
            return
        }
        let srcX = 0
        var srcY = 0
        let dstX = Int(at.x * self.scale)
        var dstY = Int(at.y * self.scale)
        if dstX < 0 || dstY < 0 {
            return
        }

        let width = min(Int(self.size.width * self.scale) - dstX, Int(other.size.width * other.scale))
        let height = min(Int(self.size.height * self.scale) - dstY, Int(other.size.height * other.scale))

        let maxDstX = dstX + width
        let maxDstY = dstY + height

        while dstY < maxDstY {
            let srcLine = other.bytes.advanced(by: max(0, srcY) * other.bytesPerRow).assumingMemoryBound(to: UInt32.self)
            let dstLine = self.bytes.advanced(by: max(0, dstY) * self.bytesPerRow).assumingMemoryBound(to: UInt32.self)

            var dx = dstX
            var sx = srcX
            while dx < maxDstX {
                let srcPixel = srcLine + sx
                let dstPixel = dstLine + dx

                let baseColor = dstPixel.pointee
                let baseAlpha = (baseColor >> 24) & 0xff
                let baseR = (baseColor >> 16) & 0xff
                let baseG = (baseColor >> 8) & 0xff
                let baseB = baseColor & 0xff

                let alpha = min(baseAlpha, srcPixel.pointee >> 24)

                let r = (baseR * alpha) / 255
                let g = (baseG * alpha) / 255
                let b = (baseB * alpha) / 255

                dstPixel.pointee = (alpha << 24) | (r << 16) | (g << 8) | b

                dx += 1
                sx += 1
            }

            dstY += 1
            srcY += 1
        }
    }
}
