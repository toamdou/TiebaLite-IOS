import Foundation
import ImageIO
import os
import UIKit

enum TiebaImageIOError: LocalizedError {
  case invalidSource
  case downloadFailed
  case decodeFailed
  case encodeFailed
  case writeFailed
  case watermarkFailed

  var errorDescription: String? {
    switch self {
    case .invalidSource:
      return "Invalid image source"
    case .downloadFailed:
      return "Image download failed"
    case .decodeFailed:
      return "Image decode failed"
    case .encodeFailed:
      return "Image thumbnail encode failed"
    case .writeFailed:
      return "Image thumbnail write failed"
    case .watermarkFailed:
      return "Image watermark render failed"
    }
  }
}

final class TiebaImageIO {
  static let shared = TiebaImageIO()

  private let fileManager = FileManager.default
  private let cacheDirectory: URL
  // Disk budget cap (default ~200MB). Exceeding it evicts least-recently-used
  // files. Settable at runtime from JS (设置 → 最大缓存大小).
  // ⚠️ 跨线程读写（Swift 6 严格并发下是 data race，本轮不做并发改造，仅声明
  // 契约）：JS 桥 setThumbnailCacheLimit 在 RN 调用线程写；enforceDiskLimit
  // 在磁盘写入后的后台队列读（evictionLock 只护目录遍历，不护本属性）。写入
  // 是 8 字节对齐的 Int64 赋值，实际不会撕裂；后续若做并发迁移，给本属性
  // 加锁或改 @MainActor + 后台侧经锁读取。
  var diskLimitBytes: Int64 = 200 * 1024 * 1024
  private let evictionLock = NSLock()
  // Bump when the on-disk key encoding changes: files written under the old
  // scheme can never be found again, so purge them once on launch instead of
  // letting up to the full disk budget of orphans wait for LRU eviction.
  private let cacheVersion = 2
  private let cacheVersionKey = "TiebaImageIO.cacheVersion"

  /// 关键错误点日志（逐出失败/清缓存失败等，低频，不刷屏）。
  private static let log = Logger(
    subsystem: "com.tiebalite.app",
    category: "image-io"
  )

  private init() {
    let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? fileManager.temporaryDirectory
    cacheDirectory = base.appendingPathComponent("TiebaImageIO", isDirectory: true)
    try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    purgeIfKeyEncodingChanged()
  }

  /// ATS 禁止明文 HTTP：贴吧图床常下发 http:// URL，URLSession 同样受 ATS
  /// 约束会直接失败。百度静态 CDN 全部支持 TLS，这里统一升级协议。
  private static func upgradeToHTTPS(_ uri: String) -> String {
    guard uri.hasPrefix("http://") else { return uri }
    return "https://" + uri.dropFirst("http://".count)
  }

  func makeThumbnail(
    sourceUri: String,
    width: Double,
    height: Double,
    cacheKey: String,
    referer: String?,
    targetWidth: Double? = nil
  ) async throws -> String {
    let sourceUri = Self.upgradeToHTTPS(sourceUri)
    let baseKey = cacheKey.isEmpty
      ? UUID().uuidString
      : makeSafeCacheKey(cacheKey)
    // Different target widths produce different files; suffix the key so a
    // list thumbnail and a full image never collide. nil keeps legacy names.
    let suffix = targetWidth.map { $0 > 0 ? "-w\(Int($0))" : "" } ?? ""
    let safeKey = "\(baseKey)\(suffix)"
    let destination = cacheDirectory.appendingPathComponent("\(safeKey).jpg")

    // 1) Disk cache: hot list scrolls only cost a cached-file read.
    if fileManager.fileExists(atPath: destination.path) {
      touch(destination)
      return destination.absoluteString
    }

    // 2) Miss: download / decode / encode / persist.
    let imageData: Data
    if sourceUri.hasPrefix("file://"), let localUrl = URL(string: sourceUri) {
      guard let data = try? Data(contentsOf: localUrl) else {
        throw TiebaImageIOError.invalidSource
      }
      imageData = data
    } else if let remoteUrl = URL(string: sourceUri) {
      imageData = try await download(remoteUrl, referer: referer)
    } else {
      throw TiebaImageIOError.invalidSource
    }

    guard let source = CGImageSourceCreateWithData(imageData as CFData, nil) else {
      throw TiebaImageIOError.decodeFailed
    }
    let maxPixel: Double
    if let targetWidth, targetWidth > 0 {
      maxPixel = targetWidth
    } else {
      maxPixel = max(width, height)
    }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixel
    ]
    guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
      throw TiebaImageIOError.decodeFailed
    }

    let image = UIImage(cgImage: thumbnail)
    guard let jpeg = image.jpegData(compressionQuality: 0.85) else {
      throw TiebaImageIOError.encodeFailed
    }
    try writeAtomically(jpeg, to: destination)
    touch(destination)
    enforceDiskLimit()
    return destination.absoluteString
  }

  /// 按 URL 取图：磁盘缓存命中直接读，未命中下载后持久化，返回解码后的
  /// UIImage。供原生图片预览（长按上下文菜单）使用——与缩略图共用磁盘
  /// 预算与 LRU，原图数据不做重编码（保持原质量）。http:// 一律升级 https。
  func loadImage(_ uri: String, referer: String? = nil) async throws -> UIImage {
    let uri = Self.upgradeToHTTPS(uri)
    guard let url = URL(string: uri) else {
      throw TiebaImageIOError.invalidSource
    }
    let destination = cacheDirectory.appendingPathComponent("\(makeSafeCacheKey(uri)).full")
    if fileManager.fileExists(atPath: destination.path) {
      touch(destination)
      if let data = try? Data(contentsOf: destination), let image = UIImage(data: data) {
        return image
      }
    }
    let data = try await download(url, referer: referer)
    guard let image = UIImage(data: data) else {
      throw TiebaImageIOError.decodeFailed
    }
    try? writeAtomically(data, to: destination)
    touch(destination)
    enforceDiskLimit()
    return image
  }

  func clearCache() throws {
    let contents = try fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)
    for url in contents {
      do {
        try fileManager.removeItem(at: url)
      } catch {
        // 单个文件删除失败不阻断清缓存，但记日志便于排查（权限/占用等）。
        Self.log.error("clearCache remove failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
      }
    }
  }

  /// Filesystem-safe, collision-free cache key derived from the raw cacheKey.
  ///
  /// The previous scheme collapsed every non-alphanumeric character into "-",
  /// which is NOT injective: "https://x.com/a-b" and "https://x.com/a/b" both
  /// sanitize to "https---x-com-a-b" (the split segments are identical, so a
  /// per-segment length prefix alone would not help either), and the two
  /// thumbnails overwrote each other in memory and on disk. We keep the
  /// readable sanitized prefix for debuggability and append a stable 64-bit
  /// digest of the ORIGINAL key so two distinct keys can no longer collide.
  /// The digest is only used for namespace disambiguation, not security.
  private func makeSafeCacheKey(_ cacheKey: String) -> String {
    let readable = cacheKey.components(separatedBy: CharacterSet.alphanumerics.inverted)
      .joined(separator: "-")
    return "\(readable)-\(stableDigest64(cacheKey))"
  }

  /// djb2 variant (64-bit) over the Unicode scalars of the input. Pure
  /// integer arithmetic, so the value is deterministic across launches and
  /// platforms; URLs that differ only in separator characters always produce
  /// different digests.
  private func stableDigest64(_ input: String) -> String {
    var hash: UInt64 = 5381
    for scalar in input.unicodeScalars {
      hash = (hash &* 33) &+ UInt64(scalar.value)
    }
    return String(hash, radix: 16)
  }

  /// One-shot migration: when the cache-key encoding version changes, drop
  /// every file written by the previous encoding. Old keys can never be
  /// resolved again, so leaving them would only waste the disk budget.
  private func purgeIfKeyEncodingChanged() {
    let defaults = UserDefaults.standard
    guard defaults.integer(forKey: cacheVersionKey) != cacheVersion else { return }
    if let contents = try? fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil) {
      for url in contents {
        try? fileManager.removeItem(at: url)
      }
    }
    defaults.set(cacheVersion, forKey: cacheVersionKey)
  }

  // Bump the file mtime on every hit so eviction naturally picks the oldest.
  private func touch(_ url: URL) {
    try? fileManager.setAttributes(
      [.modificationDate: Date()],
      ofItemAtPath: url.path
    )
  }

  // Simple LRU sweep: when the directory exceeds the disk budget, delete the
  // least-recently-used files until back under it. Runs on the calling
  // (background) queue after a write.
  private func enforceDiskLimit() {
    evictionLock.lock()
    defer { evictionLock.unlock() }
    do {
      let contents = try fileManager.contentsOfDirectory(
        at: cacheDirectory,
        includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
      )
      // 每个文件的 size + mtime 一次 resourceValues 读取（旧实现
      // fileSize()/modificationDate() 各跑一次 resourceValues，等于每文件
      // 两次 stat 系统调用）。
      let entries: [(url: URL, size: Int64, date: Date)] = contents.compactMap { url in
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else {
          return nil
        }
        return (url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
      }
      let total = entries.reduce(Int64(0)) { $0 + $1.size }
      guard total > diskLimitBytes else { return }

      let sorted = entries.sorted { $0.date < $1.date }
      var freed: Int64 = 0
      for entry in sorted {
        guard total - freed > diskLimitBytes else { break }
        if (try? fileManager.removeItem(at: entry.url)) != nil {
          freed += entry.size
        }
      }
    } catch {}
  }

  private func writeAtomically(_ data: Data, to url: URL) throws {
    do {
      try data.write(to: url, options: .atomic)
    } catch {
      throw TiebaImageIOError.writeFailed
    }
  }

  func applyWatermark(sourceUri: String, text: String) async throws -> String {
    let sourceUri = Self.upgradeToHTTPS(sourceUri)
    guard let url = URL(string: sourceUri), let data = try? Data(contentsOf: url) else {
      throw TiebaImageIOError.invalidSource
    }
    guard let image = UIImage(data: data) else {
      throw TiebaImageIOError.decodeFailed
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
      throw TiebaImageIOError.encodeFailed
    }
    let destination = cacheDirectory.appendingPathComponent("watermark-\(UUID().uuidString).jpg")
    try writeAtomically(jpeg, to: destination)
    return destination.absoluteString
  }

  private func download(_ url: URL, referer: String?) async throws -> Data {
    var request = URLRequest(url: url)
    request.timeoutInterval = 30
    if let referer, !referer.isEmpty {
      request.setValue(referer, forHTTPHeaderField: "Referer")
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw TiebaImageIOError.downloadFailed
    }
    return data
  }
}
