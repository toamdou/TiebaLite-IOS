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
import UIKit

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

// ============================================================
// 图片「保存到相册 / 分享」的**唯一入口**（H14：原先定义在 Core/Networking/TiebaFeedAPI.swift，
// 与 UI/Media 的相册写入分居两处，看图器只能另写一套）。现在整条链路 —— 水印 → 相册 / 分享 —— 收在这里，
// 与 TiebaPhotoLibrary 的底层写入、TiebaImageWatermark 的渲染、TiebaShareSheet 的面板同目录。
// 调用方（6 个页面共 12 处）只认 TiebaFeedImageActions，换文件不改任何调用点。
// ============================================================
/// 信息流图片的「保存照片 / 分享照片」（原 JS PostImageContextMenu 的水印 + 相册 + 分享）。
@MainActor
enum TiebaFeedImageActions {
  static func save(url: String, forumName: String?, presenter: UIViewController?) {
    Task { @MainActor in
      do {
        let file = try await prepare(url: url, forumName: forumName)
        try await TiebaPhotoLibrary.saveFile(uri: file.absoluteString)
        TiebaSceneHaptics.fire("action-success")
        showToast("保存成功", on: presenter)
      } catch {
        TiebaSceneHaptics.fire("action-fail")
        showAlert(title: "保存失败", message: error.localizedDescription, on: presenter)
      }
    }
  }

  static func share(url: String, forumName: String?, presenter: UIViewController?, sourceRect: CGRect) {
    Task { @MainActor in
      do {
        let file = try await prepare(url: url, forumName: forumName)
        guard let presenter else { return }
        TiebaShareSheet.present(
          fileURL: file,
          dialogTitle: watermarkText(forumName: forumName).isEmpty
            ? "分享图片" : "分享图片 — \(watermarkText(forumName: forumName))",
          from: presenter,
          sourceRect: sourceRect
        )
      } catch {
        TiebaSceneHaptics.fire("action-fail")
        showAlert(title: "分享失败", message: error.localizedDescription, on: presenter)
      }
    }
  }

  /// 源图落到临时文件；有水印偏好时渲染水印（TiebaImageWatermark）。
  private static func prepare(url: String, forumName: String?) async throws -> URL {
    guard let target = URL(string: url) else { throw TiebaPhotoBrowserError.invalidImageData }
    // 走 TiebaPhotoBrowser 暴露的 Nuke 取数入口：Referer 注入 + DataCache 与
    // 查看器同一条管线；不要手写 URLSession（贴吧图床防盗链，且会分裂缓存）。
    let data = try await TiebaPhotoBrowserImageLoader.data(target)
    let temp = FileManager.default.temporaryDirectory
      .appendingPathComponent("feed-image-\(UUID().uuidString).jpg")
    try data.write(to: temp, options: .atomic)
    let text = watermarkText(forumName: forumName)
    guard !text.isEmpty else { return temp }
    let output = try await TiebaImageWatermark.applyWatermark(sourceUri: temp.absoluteString, text: text)
    guard let url = URL(string: output) else { return temp }
    return url
  }

  /// 与 JS resolveWatermarkText 同判据：username = 当前账号昵称，forum_name = 吧名。
  static func watermarkText(forumName: String?) -> String {
    guard TiebaPreferenceSnapshot.bool("imageWatermarkEnabled", default: false) else { return "" }
    switch TiebaPreferenceSnapshot.string("imageWatermark") ?? "none" {
    case "username": return accountName()
    case "forum_name": return forumName ?? ""
    default: return ""
    }
  }

  /// 账号昵称：冷启动档案缓存（AuthSecureStorage 的无凭据缓存，与 JS 同一份 KV）。
  private static func accountName() -> String {
    guard let raw = TiebaKvStore.shared.get(key: "@tiebalite:account_profile_cache_v1"),
      let data = raw.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return "" }
    return object["name"] as? String ?? object["nameShow"] as? String ?? ""
  }

  private static func showToast(_ text: String, on presenter: UIViewController?) {
    guard let presenter else { return }
    let pill = TiebaPhotoBrowserPillView()
    presenter.view.addSubview(pill)
    pill.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      pill.centerXAnchor.constraint(equalTo: presenter.view.centerXAnchor),
      pill.bottomAnchor.constraint(
        equalTo: presenter.view.safeAreaLayoutGuide.bottomAnchor,
        constant: -24
      ),
    ])
    pill.showResult(success: true, text: text)
  }

  private static func showAlert(title: String, message: String, on presenter: UIViewController?) {
    guard let presenter, presenter.presentedViewController == nil else { return }
    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "好", style: .default))
    presenter.present(alert, animated: true)
  }
}
