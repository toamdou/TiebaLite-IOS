// 图片水印渲染（保存/分享图片的「贴吧水印」偏好）。没有库等价物：Nuke 只管
// 取图，水印必须在原图像素坐标上重绘后重新编码。输出落临时目录（调用方
// 立即拿去保存/分享，不需要缓存；旧实现在 Library/Caches 下，迁移后不留目录）。
import Foundation
import UIKit

/// 水印错误文案与旧 TiebaImageIOError 对应分支逐字一致（调用方直接展示
/// localizedDescription，不能换措辞）。
enum TiebaImageWatermarkError: LocalizedError {
  case invalidSource
  case decodeFailed
  case encodeFailed
  case writeFailed

  var errorDescription: String? {
    switch self {
    case .invalidSource:
      return "Invalid image source"
    case .decodeFailed:
      return "Image decode failed"
    case .encodeFailed:
      return "Image thumbnail encode failed"
    case .writeFailed:
      return "Image thumbnail write failed"
    }
  }
}

enum TiebaImageWatermark {
  /// 水印**数据入口**：已经拿到字节的调用方（图片查看器保存/分享时手里就是原图数据）直接用它，
  /// 不必再走一次 URL 下载 —— 这正是 H14「保存/分享统一入口」需要的那一半。
  /// 返回编码后的 JPEG 数据，**不落盘**（落盘由调用方决定，查看器直接进相册就不必写临时文件）。
  /// text 为空时仍走完整流程（与旧实现一致）。
  static func applyWatermark(data: Data, text: String) throws -> Data {
    guard let image = UIImage(data: data) else {
      throw TiebaImageWatermarkError.decodeFailed
    }

    // 固定 scale=1：默认 renderer 使用屏幕 scale（3x 设备放大 9 倍位图），
    // 4000×3000 源图在低内存设备上会直接 OOM 被系统强杀。水印按 1x 像素
    // 对齐源图坐标绘制，视觉无差。
    //
    // ⚠️ 为什么这里**没有**收敛到 TiebaBitmapContext（UI/Drawing/TiebaDrawingSupport.swift）：
    // 试过，实测结果不满足「输出逐像素不变」，所以按约定回退了。实测（iPhone 17 / iOS 27 模拟器，
    // 见 docs/uikit-migration/22-接线-drawing-kit.md）：
    //   · 只画源图（text 为空）：新旧逐像素完全一致（sRGB 0 差异；P3 差 45px / 最大 1 LSB，属色彩转换舍入）；
    //   · 画水印文字：文字 bbox 内 1830px 不同、最大通道差 67。排查过三条假设都不成立 ——
    //     关字体平滑（setShouldSmoothFonts(false)）、opaque 上下文、跟随源图色彩空间，三者都无改善：
    //     UIGraphicsImageRenderer 显然还设置了别的上下文状态，成本内无法定位到。
    // 由于本任务是「渲染热路径、显示结果不变」，这里保留原实现（这不是漏做，是有测量的取舍）。
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
    let watermarked = renderer.image { context in
      image.draw(in: CGRect(origin: .zero, size: image.size))
      guard !text.isEmpty else { return }

      let fontSize = max(13, min(22, image.size.width * 0.035))
      let paragraph = NSMutableParagraphStyle()
      paragraph.alignment = .right
      let shadow = NSShadow()
      shadow.shadowColor = UIColor.black.withAlphaComponent(0.6)
      shadow.shadowOffset = CGSize(width: 0, height: 1)
      shadow.shadowBlurRadius = 2
      let attributes: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
        .foregroundColor: UIColor.white.withAlphaComponent(0.9),
        .paragraphStyle: paragraph,
        .shadow: shadow,
      ]
      let nsText = text as NSString
      let textSize = nsText.size(withAttributes: attributes)
      let margin: CGFloat = 12
      let rect = CGRect(
        x: max(margin, image.size.width - textSize.width - margin),
        y: max(margin, image.size.height - textSize.height - margin),
        width: min(textSize.width, image.size.width - margin * 2),
        height: textSize.height
      )
      nsText.draw(in: rect, withAttributes: attributes)
    }

    guard let jpeg = watermarked.jpegData(compressionQuality: 0.92) else {
      throw TiebaImageWatermarkError.encodeFailed
    }
    // 数据入口只负责"渲染"，不落盘 —— 调用方（图片查看器）手里已有字节，
    // 直接把它交给相册写入或分享，省掉一次临时文件往返。
    return jpeg
  }

  /// 兼容入口（信息流/分享路径用它）：读 URL → 调上面的数据入口 → 落盘临时文件并返回 file URL。
  /// **行为与拆分前逐字一致**（同一渲染、同一 0.92 质量、同一临时目录命名）。
  static func applyWatermark(sourceUri: String, text: String) async throws -> String {
    let sourceUri = upgradeToHTTPS(sourceUri)
    guard let url = URL(string: sourceUri), let data = try? Data(contentsOf: url) else {
      throw TiebaImageWatermarkError.invalidSource
    }
    let jpeg = try Self.applyWatermark(data: data, text: text)
    let destination = FileManager.default.temporaryDirectory
      .appendingPathComponent("watermark-\(UUID().uuidString).jpg")
    do {
      try jpeg.write(to: destination, options: .atomic)
    } catch {
      throw TiebaImageWatermarkError.writeFailed
    }
    return destination.absoluteString
  }

  /// ATS 禁止明文 HTTP：老数据里的 http:// 图床统一升级（同 TiebaNuke.secureURL）。
  private static func upgradeToHTTPS(_ uri: String) -> String {
    guard uri.hasPrefix("http://") else { return uri }
    return "https://" + uri.dropFirst("http://".count)
  }
}
