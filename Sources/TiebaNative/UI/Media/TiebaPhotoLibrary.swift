// ============================================================
// 相册写入（替 expo-media-library 的保存路径）——查看器保存与 JS
// saveImageToGallery 共用的唯一实现。
//
// 为什么抽出来（2026-09-12）：TiebaPhotoBrowserActionController 里已有一份
// 经过验证的 addOnly 授权 + PHAssetCreationRequest 写入（查看器三种保存动作
// 都走它）。JS 侧 media.ts 的 saveImageToGallery 原走 expo-media-library，包
// 退场时必须复用同一份逻辑，否则"同一次保存"会出现两套授权语义/两套错误文案。
//
// 为什么是 addOnly：app.json 只声明了 NSPhotoLibraryAddUsageDescription
// （添加级）。申请 full 读取（requestPermissionsAsync）会因为缺少
// NSPhotoLibraryUsageDescription 被系统直接终止进程——这正是旧头像网格在
// 真机上的崩溃面（见 TiebaPhotoPicker.swift 的迁移说明）。
//
// 原始字节直写：GIF 动画 / JPEG 质量都保持（不重新编码，与查看器保存一致）。
//
// 错误类型复用 TiebaPhotoBrowserError：它已是本仓相册写入错误的既有定义
// （string 映射 PERMISSION_DENIED，查看器 handleSaveFailure 按它弹"权限不足"，
// JS 侧 catch 也按这个文案分支）。新定义一套等于把同一条错误拆成两种判定。
// ============================================================
import Foundation
import Photos

enum TiebaPhotoLibrary {
  /// 写相册。completion 恒在主线程回调（调用方持有 UI 状态：保存胶囊/提示）。
  /// 授权被拒返回 TiebaPhotoBrowserError.permissionDenied（文案 PERMISSION_DENIED）。
  static func save(
    data: Data,
    completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void
  ) {
    PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
      // limited 在 addOnly 下也算可写（与查看器原判定一致，保持行为不变）。
      guard status == .authorized || status == .limited else {
        DispatchQueue.main.async { completion(.failure(TiebaPhotoBrowserError.permissionDenied)) }
        return
      }
      PHPhotoLibrary.shared().performChanges({
        let request = PHAssetCreationRequest.forAsset()
        // 原始字节直写：GIF 动画/JPEG 质量都保持（不重新编码）。
        request.addResource(with: .photo, data: data, options: nil)
      }, completionHandler: { success, error in
        DispatchQueue.main.async {
          if success {
            completion(.success(()))
          } else {
            completion(.failure(error ?? TiebaPhotoBrowserError.saveFailed))
          }
        }
      })
    }
  }

  /// 把本地文件写进系统相册（替 expo-media-library 的 saveToLibraryAsync）。
  /// 读盘放后台线程：图片可达数 MB，文件 IO 不能压在主线程上。
  static func saveFile(uri: String) async throws {
    let url = try TiebaFileSystem.url(from: uri)
    let data: Data
    do {
      data = try await Task.detached(priority: .utility) {
        try Data(contentsOf: url)
      }.value
    } catch {
      // 文件不存在/不可读：对用户而言与"图片数据无效"同义（调用方按
      // "保存失败"分支展示），不把 Cocoa 的英文错误透到 UI。
      throw TiebaPhotoBrowserError.invalidImageData
    }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      save(data: data) { result in
        continuation.resume(with: result)
      }
    }
  }
}
