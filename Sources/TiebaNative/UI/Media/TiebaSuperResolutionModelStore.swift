// PiperSR_2x 的取用：包内三个原始文件 → 首次编译 → Caches 复用。
//
// 为什么是"运行时编译"（可行性文档 §4 方案 A）：Bazel 的 genrule outs 只能是文件，而
// .mlpackage / .mlmodelc 都是**目录**；把三个原始文件放进 app_resources 是唯一不碰目录产物的路。
// 首次使用前多一次 MLModel.compileModel（本机量级 0.3–2s），编译结果持久化到 Caches，
// 之后冷启动直接 load；若将来改成方案 B（genrule 预编译 + zip 成单文件），把解压出来的
// .mlmodelc 目录塞进包即可 —— 本文件的 resolve 会**优先**用它。
//
// ⚠️ 资源在包内是**扁平**的（rules_apple 按 basename 落盘），所以三个文件进仓库时就带了
// PiperSR_2x_ 前缀改名（Manifest.json 是通用名，扁平化会撞名）；运行期再按 mlpackage 的
// 规范目录结构拼回去 —— Manifest.json 里的 path 是相对 Data/ 的（com.apple.CoreML/model.mlmodel）。

import CoreML
import Foundation

enum TiebaSuperResolutionModelStore {
  /// 模型版本：换权重必须改这个字符串（缓存目录名带它，否则会一直复用旧编译产物）。
  static let modelVersion = "piper-sr-2x-v1"

  /// 可直接交给 `MLModel(contentsOf:configuration:)` 的 .mlmodelc 路径。
  static func compiledModelURL() throws -> URL {
    let fileManager = FileManager.default
    let root = TiebaFileSystem.cacheDirectory
      .appendingPathComponent("sr-models", isDirectory: true)
      .appendingPathComponent(modelVersion, isDirectory: true)
    let compiled = root.appendingPathComponent("PiperSR_2x.mlmodelc", isDirectory: true)
    if fileManager.fileExists(atPath: compiled.path) { return compiled }
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

    // 路径 B：包内已有预编译产物 → 直接拷贝（无需运行时编译）。
    if let bundled = bundledResource("PiperSR_2x", "mlmodelc") {
      try? fileManager.removeItem(at: compiled)
      try fileManager.copyItem(at: bundled, to: compiled)
      return compiled
    }

    // 路径 A：拼出 .mlpackage → 编译 → 搬进 Caches。
    // compileModel 返回的是**临时目录**（系统随时可能回收），必须搬到自己的稳定路径。
    let package = root.appendingPathComponent("PiperSR_2x.mlpackage", isDirectory: true)
    defer { try? fileManager.removeItem(at: package) }
    try assemblePackage(at: package, fileManager: fileManager)
    let temporary = try MLModel.compileModel(at: package)
    try? fileManager.removeItem(at: compiled)
    try fileManager.moveItem(at: temporary, to: compiled)
    return compiled
  }

  /// 按 mlpackage 规范结构拼目录；三个文件都从包内取（缺任何一件都抛错，不做静默降级）。
  private static func assemblePackage(at package: URL, fileManager: FileManager) throws {
    let coreML = package.appendingPathComponent("Data/com.apple.CoreML", isDirectory: true)
    let weights = coreML.appendingPathComponent("weights", isDirectory: true)
    try fileManager.createDirectory(at: weights, withIntermediateDirectories: true)
    try copyBundled("PiperSR_2x_Manifest", "json", to: package.appendingPathComponent("Manifest.json"))
    // 包内是 .bin（不是 .mlmodel）：rules_apple 见到 .mlmodel 会自己跑 coremlc，而扁平落盘时
    // 它找不到同目录的 weights/weight.bin（实测构建失败）；这里拼回规范名再交给 MLModel.compileModel。
    try copyBundled("PiperSR_2x_model", "bin", to: coreML.appendingPathComponent("model.mlmodel"))
    try copyBundled("PiperSR_2x_weight", "bin", to: weights.appendingPathComponent("weight.bin"))
  }

  private static func copyBundled(_ name: String, _ ext: String, to destination: URL) throws {
    guard let source = bundledResource(name, ext) else {
      throw TiebaSuperResolutionError.modelUnavailable("包内缺少 \(name).\(ext)")
    }
    let fileManager = FileManager.default
    try? fileManager.removeItem(at: destination)
    try fileManager.copyItem(at: source, to: destination)
  }

  /// 包内查找：Bazel 落盘是扁平的，但保留一层 piper-sr/ 子目录也能命中（两种打包方式都认）。
  private static func bundledResource(_ name: String, _ ext: String) -> URL? {
    Bundle.main.url(forResource: name, withExtension: ext)
      ?? Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "piper-sr")
  }
}
