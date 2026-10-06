// TiebaImageBlur —— 图片模糊（Accelerate 方框模糊）。
//
// 移植自上游 submodules/ImageBlur/Sources/ImageBlur.swift。
// 本仓改名：blurredImage → tiebaBlurredImage —— 公开符号加本仓前缀，避免污染模块全局命名空间。
// （verticalBlurredImage → tiebaVerticalBlurredImage 已在本轮零调用方清理中删除：本仓只有横向模糊的调用点。）
//
// 11 号清单 §1.3 第 6 项（13-遗漏核对.md §6.3 #6）。
// 依赖：仅 UIKit + Accelerate（上游原样）。
//
// 本仓改动（尽量少，业务代码逐行照搬）：
//   1) 两个公开函数 + 私有 imageBuffer 标 nonisolated —— 纯像素计算，上游在后台线程调用
//      （图片处理队列），默认 MainActor 隔离会让它无法离开主线程。
//   2) 删除一处冗余缩进/空行整理（无语义改动）。
//   3) 未改任何算法：vImageBoxConvolve_ARGB8888 + kvImageEdgeExtend + 迭代交换 in/out buffer 与上游一致。
//
// ⚠️ 上游的一处**既有缺陷照搬未改**（不是本次引入）：iterations 循环里交换了 inBuffer/outBuffer 的
//    data 指针，但 vImageBoxConvolve 的 tempData 是"足够一次卷积"的尺寸，多轮迭代继续复用同一块
//    temp 是合法的；循环结束后 inBuffer.data 指向最后写入的那块内存，随后直接用它建 CGContext —— 与上游一致。

import UIKit
import Accelerate

// MARK: - 可动画的模糊半径（移植自上游 submodules/Settings/WallpaperGalleryScreen/Sources/BlurredImageNode.swift:8-57,107-112）

/// 把「模糊半径」做成**可动画的图层属性**（上游 BlurLayer）。三件套缺一不可：
///   · `@NSManaged var blurRadius` —— 让 CALayer 认这个 key（否则 KVC 直接崩）；
///   · `needsDisplay(forKey:)` 对该 key 返回 true —— 它的每次变化都触发 `display`；
///   · `action(forKey:)` 里**借系统给 opacity 准备的那条 CABasicAnimation 当模板** ——
///     把 keyPath 改成 blurRadius、fromValue 取呈现层的当前值再返回。
/// 于是这个自定义属性自动获得与系统动画**完全一致**的时长/曲线（不用自己猜 0.25s 还是 0.3s），
/// 且动画中途再改半径是从"现在显示到哪"续跑，不是从头跳。
/// 风险（上游同款）：借 opacity 的 action 属于依赖系统既有行为；苹果改了只会退化成
/// "模糊跳变"，不会崩。
public nonisolated final class TiebaBlurLayer: CALayer {
    @NSManaged var blurRadius: CGFloat

    private var fromBlurRadius: CGFloat?

    /// 当前**呈现**半径：动画期间每帧读它，才是真正在变的那一个值（上游 :13-23）。
    var presentationRadius: CGFloat {
        if fromBlurRadius != nil, let presentation = presentation() {
            return presentation.blurRadius
        }
        return blurRadius
    }

    public override class func needsDisplay(forKey key: String) -> Bool {
        if key == "blurRadius" {
            return true
        }
        return super.needsDisplay(forKey: key)
    }

    public override func action(forKey event: String) -> CAAction? {
        if event == "blurRadius" {
            fromBlurRadius = nil
            if let action = super.action(forKey: "opacity") as? CABasicAnimation {
                fromBlurRadius = (presentation() ?? self).blurRadius
                action.keyPath = event
                action.fromValue = fromBlurRadius
                return action
            }
        }
        return super.action(forKey: event)
    }
}

/// 模糊半径可动画的图片视图：`blurRadius` 写在 UIView.animate 块里就会跟着系统曲线补间。
///
/// [本仓改动，相对上游] 上游模糊的是**全尺寸**壁纸，所以必须丢到 userInteractive 队列异步算；
/// 本仓模糊前先把源图降采样到 64pt 宽（`downsampleWidth`），一次模糊是微秒级，
/// 于是可以在 `display` 里**同步**重算 —— 少了跨线程传 UIImage 的 Swift 6 并发问题
/// （UIImage 不是 Sendable，硬传只能上 @unchecked，本仓铁律禁止），逐帧改半径也不掉帧。
/// 观感与上游一致：模糊到一定程度后本来就只剩色块，分辨率无关。
public final class TiebaBlurView: UIView {
    public override class var layerClass: AnyClass {
        TiebaBlurLayer.self
    }

    private var blurLayer: TiebaBlurLayer {
        layer as! TiebaBlurLayer
    }

    private let downsampleWidth: CGFloat
    private var sampled: UIImage?

    public init(image: UIImage?, downsampleWidth: CGFloat = 64) {
        self.downsampleWidth = downsampleWidth
        super.init(frame: .zero)
        self.isUserInteractionEnabled = false
        self.blurLayer.contentsGravity = .resizeAspectFill
        self.blurLayer.masksToBounds = true
        self.image = image
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public var image: UIImage? {
        didSet {
            self.sampled = Self.downsampled(self.image, width: self.downsampleWidth)
            self.redraw()
        }
    }

    public var blurRadius: CGFloat {
        get { self.blurLayer.blurRadius }
        set { self.blurLayer.blurRadius = newValue }
    }

    /// CA 在模糊半径（或其动画的每一帧）变化时回调这里（上游 :107-112 的 display）。
    public override func display(_ layer: CALayer) {
        self.redraw()
    }

    private func redraw() {
        guard let sampled = self.sampled else {
            self.blurLayer.contents = nil
            return
        }
        let radius = self.blurLayer.presentationRadius
        // radius <= 0 时 tiebaBlurredImage 原样返回，正好是"没模糊"那一档。
        let image = radius > 0.0 ? tiebaBlurredImage(sampled, radius: radius) : sampled
        self.blurLayer.contents = image?.cgImage
        self.blurLayer.contentsScale = sampled.scale
    }

    /// 降采样到指定宽度（保持比例；放大不做）。
    private static func downsampled(_ image: UIImage?, width: CGFloat) -> UIImage? {
        guard let image, image.size.width > 0.0, image.size.height > 0.0, width > 0.0 else {
            return image
        }
        let scale = min(1.0, width / image.size.width)
        let size = CGSize(
            width: max(1.0, floor(image.size.width * scale)),
            height: max(1.0, floor(image.size.height * scale))
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: CGPoint(), size: size))
        }
    }
}

private nonisolated func imageBuffer(from data: UnsafeMutableRawPointer!, width: vImagePixelCount, height: vImagePixelCount, rowBytes: Int) -> vImage_Buffer {
    return vImage_Buffer(data: data, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: rowBytes)
}

// [移植] nonisolated：纯函数，供后台图片管线调用。
public nonisolated func tiebaBlurredImage(_ image: UIImage, radius: CGFloat, iterations: Int = 3) -> UIImage? {
    guard let cgImage = image.cgImage, let providerData = cgImage.dataProvider?.data else {
        return nil
    }

    if image.size.width <= 0.0 || image.size.height <= 0 || radius <= 0 {
        return image
    }

    var boxSize = UInt32(radius)
    if boxSize % 2 == 0 {
        boxSize += 1
    }

    let bytes = cgImage.bytesPerRow * cgImage.height
    let inData = malloc(bytes)
    var inBuffer = imageBuffer(from: inData, width: vImagePixelCount(cgImage.width), height: vImagePixelCount(cgImage.height), rowBytes: cgImage.bytesPerRow)

    let outData = malloc(bytes)
    var outBuffer = imageBuffer(from: outData, width: vImagePixelCount(cgImage.width), height: vImagePixelCount(cgImage.height), rowBytes: cgImage.bytesPerRow)

    let tempSize = vImageBoxConvolve_ARGB8888(&inBuffer, &outBuffer, nil, 0, 0, boxSize, boxSize, nil, vImage_Flags(kvImageEdgeExtend + kvImageGetTempBufferSize))
    let tempData = malloc(tempSize)

    defer {
        free(inData)
        free(outData)
        free(tempData)
    }

    let source = CFDataGetBytePtr(providerData)
    memcpy(inBuffer.data, source, bytes)

    for _ in 0 ..< iterations {
        vImageBoxConvolve_ARGB8888(&inBuffer, &outBuffer, tempData, 0, 0, boxSize, boxSize, nil, vImage_Flags(kvImageEdgeExtend))

        let temp = inBuffer.data
        inBuffer.data = outBuffer.data
        outBuffer.data = temp
    }

    let context = cgImage.colorSpace.flatMap {
        CGContext(data: inBuffer.data, width: cgImage.width, height: cgImage.height, bitsPerComponent: cgImage.bitsPerComponent, bytesPerRow: cgImage.bytesPerRow, space: $0, bitmapInfo: cgImage.bitmapInfo.rawValue)
    }

    let blurredCGImage = context?.makeImage()
    if let blurredCGImage = blurredCGImage {
        return UIImage(cgImage: blurredCGImage, scale: image.scale, orientation: image.imageOrientation)
    } else {
        return nil
    }
}

