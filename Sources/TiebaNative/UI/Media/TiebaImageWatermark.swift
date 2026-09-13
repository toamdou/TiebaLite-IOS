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
  /// 给 `sourceUri`（远程 http(s) 或本地 file URL）渲染 `text` 水印，返回
  /// 落盘后的 file URL 字符串。text 为空时仍走完整流程（与旧实现一致）。
  static func applyWatermark(sourceUri: String, text: String) async throws -> String {
    let sourceUri = upgradeToHTTPS(sourceUri)
    guard let url = URL(string: sourceUri), let data = try? Data(contentsOf: url) else {
      throw TiebaImageWatermarkError.invalidSource
    }
    guard let image = UIImage(data: data) else {
      throw TiebaImageWatermarkError.decodeFailed
    }

    // 固定 scale=1：默认 renderer 使用屏幕 scale（3x 设备放大 9 倍位图），
    // 4000×3000 源图在低内存设备上会直接 OOM 被系统强杀。水印按 1x 像素
    // 对齐源图坐标绘制，视觉无差。
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
