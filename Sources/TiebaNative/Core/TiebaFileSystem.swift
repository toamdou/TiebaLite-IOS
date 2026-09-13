// 文件系统（FileManager）——替代 expo-file-system。
//
// 本仓只用到三件事（grep File/Directory/Paths 的全部调用点）：
//   1. 缓存目录下的临时文件：分享/保存图片前下载、诊断日志导出写 txt；
//   2. 整目录清空：设置 → 清除图片缓存 / 定期自动清理（Paths.cache）；
//   3. 远程文件下载到缓存（分享墙/保存到相册）。
// expo-file-system 整包还带 scoped access / 文件选择器 / 上传 / watcher / legacy
// API，全部零调用点，不搬迁。
//
// 目录语义：cache = Library/Caches（系统可回收，放再生数据）；诊断日志本体在
// Application Support/TiebaLogs（tieba-system 模块采集，本模块不碰）。
// Paths.document / Paths.bundle 无调用点，不发明 API。
import Foundation

/// 跨桥抛错的最小错误类型：LocalizedError 的 errorDescription 会成为 JS 侧
/// Error.message（与旧包 reject 的文案同义，调用方的 catch 只做日志/清理）。
struct TiebaFileSystemError: LocalizedError {
  let message: String

  var errorDescription: String? { message }
}

enum TiebaFileSystem {
  /// expo Paths.cache 的原生对应。URLs(for:.cachesDirectory) 在 App 沙盒里恒为
  /// Library/Caches；目录可能被系统回收不存在，写入前由调用方/下载路径兜底建。
  static var cacheDirectory: URL {
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
  }

  /// "file:///..." → URL。非文件 scheme（包含相对路径）直接抛错：调用方给的
  /// uri 全部来自 File/Paths 构造，出现别的 scheme 说明调用方写错了，不能
  /// 静默当相对路径写进当前工作目录。
  static func url(from uri: String) throws -> URL {
    guard let url = URL(string: uri), url.isFileURL else {
      throw TiebaFileSystemError(message: "invalid file uri: \(uri)")
    }
    return url
  }

  /// 写文本（非原子，与 expo File.write 的 `write(to:atomically:false)` 一致）。
  /// 目标父目录不存在时抛错——本仓调用点写的是缓存根，不存在才是异常。
  static func writeText(contents: String, to uri: String) throws {
    let url = try url(from: uri)
    try contents.write(to: url, atomically: false, encoding: .utf8)
  }

  /// 删除文件或目录（递归）。不存在即抛错（与 expo delete() 一致）：
  /// 调用方 deleteBestEffort 自己 catch "已删除"，静默是它的语义，不是这里的。
  static func delete(_ uri: String) throws {
    let url = try url(from: uri)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw TiebaFileSystemError(message: "path does not exist: \(uri)")
    }
    try FileManager.default.removeItem(at: url)
  }

  /// 清空目录内容、保留目录本身。
  /// expo 的 `new Directory(Paths.cache).delete()` 是把 Caches 目录整个删掉；
  /// 根目录被删后 iOS 不会主动重建，后续写入可能 ENOENT（部分写入方会自建、
  /// 部分不会，等于把"目录是否存在"变成隐性契约）。可观察结果相同（空缓存
  /// 目录），但不会把"下一次写入是否失败"留给运气。
  static func clearDirectory(_ uri: String) throws {
    let url = try url(from: uri)
    let fm = FileManager.default
    if fm.fileExists(atPath: url.path) {
      for child in try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
        try fm.removeItem(at: child)
      }
    }
    if !fm.fileExists(atPath: url.path) {
      try fm.createDirectory(at: url, withIntermediateDirectories: true)
    }
  }

  /// 下载远程文件到目标路径（替 File.downloadFileAsync）。
  /// 语义与 expo 对齐：仅 2xx 算成功；目标已存在即抛错（idempotent=false）；
  /// 成功返回目标 uri。下载过程不带自定义头（expo 缺省同样只发裸请求）。
  static func download(from urlString: String, to destinationUri: String) async throws -> String {
    guard let sourceURL = URL(string: urlString) else {
      throw TiebaFileSystemError(message: "invalid url: \(urlString)")
    }
    let destination = try url(from: destinationUri)
    if FileManager.default.fileExists(atPath: destination.path) {
      throw TiebaFileSystemError(message: "destination already exists: \(destinationUri)")
    }
    let (tempURL, response) = try await URLSession.shared.download(from: sourceURL)
    guard let http = response as? HTTPURLResponse else {
      throw TiebaFileSystemError(message: "no response")
    }
    guard (200..<300).contains(http.statusCode) else {
      throw TiebaFileSystemError(message: "response has status \(http.statusCode)")
    }
    // URLSession 的临时文件在 async 返回后随时可能被系统回收，必须先搬走再
    // resolve。父目录兜底创建：目标在缓存根下，正常已存在；这行只为"目录被
    // 系统回收过"的窗口兜底，不让下载成功却因 ENOENT 落不了盘。
    do {
      try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try FileManager.default.moveItem(at: tempURL, to: destination)
    } catch {
      throw TiebaFileSystemError(message: error.localizedDescription)
    }
    return destination.absoluteString
  }
}
