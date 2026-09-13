// ============================================================
// 头像选择（替 edit-profile.tsx 的自建相册网格 + expo-media-library 读取路径）。
//
// 为什么是 PHPickerViewController（而不是"原生网格 + PHPhotoLibrary 全量读"）：
//   1) 系统支持的正解：PHPicker 是 Apple 14 起推荐的选图入口，选择行为在系统
//      进程完成，app 只拿到用户选中的那一张；
//   2) **零权限**：不需要任何相册权限，不会弹权限框。原先的自建网格走
//      MediaLibrary.requestPermissionsAsync()（full 读取）——但 app.json 只声明
//      了 NSPhotoLibraryAddUsageDescription（添加级），真机上申请读取权限会被
//      系统直接终止进程（missing NSPhotoLibraryUsageDescription）；
//   3) 平台组件自带搜索/相簿切换/多选 UI/无障碍/大图预览，手写网格 48 张
//      缩略图逐张 getAssetInfoAsync 的加载链（旧实现）全部不需要了。
//   注：旧网格是"最近 48 张 + 点击即传"，PHPicker 是系统选择器，交互路径
//   不同——这是有意的产品取舍，见本次迁移报告。
//
// 输出：缓存目录里的 JPEG（file:// uri）。为什么转码而不是拷原始字节：
// 头像上传（uploadPortrait）以 FormData 声明 image/jpeg 上传原文件，而相册
// 原图可能是 HEIC——旧链路把 HEIC 当 jpg 传，服务端收不收全凭运气。UIImage
// 转码后 mime 与字节一致，EXIF 方向也被归一（jpegData 重绘）。
//
// 线程：present 必须在主线程（宿主调用经
// onMain 收束）；结果经 completion 回主线程（续体 resume 线程无关，统一走
// 主线程便于推理）。
// ============================================================
import PhotosUI
import UIKit

enum TiebaPhotoPickerError: LocalizedError {
  /// 已经有选择器在展示（JS 侧同时只应有一个入口，防御并发调用）。
  case alreadyPresenting
  /// 找不到宿主 VC（原生壳未就绪）。
  case noPresenter
  /// 选中的资源无法解码为图片。
  case loadFailed
  /// JPEG 编码失败（理论上不发生，防御）。
  case encodeFailed

  var errorDescription: String? {
    switch self {
    case .alreadyPresenting: return "相册选择器已在展示"
    case .noPresenter: return "无法打开相册选择器"
    case .loadFailed: return "无法读取所选照片"
    case .encodeFailed: return "无法处理所选照片"
    }
  }
}

/// PHPicker 的 delegate（UIKit 弱持有 delegate，展示期间必须由 TiebaPhotoPicker
/// 强持有）。@unchecked Sendable：与 TiebaAudioPlayerBox 同款声明——纪律是
/// "只碰自己的状态"，completion 本身是 Sendable 的。
final class TiebaPhotoPickerDelegate: NSObject, PHPickerViewControllerDelegate, @unchecked Sendable {
  /// 结果回调：String = 缓存目录里的 JPEG file:// uri；取消 = 空串（正常路径）。
  /// `@MainActor @Sendable`：delegate 回调线程不确定（loadObject 的完成回调在
  /// 任意队列），统一回主线程调用（与 TiebaPhotoBrowser 的 writeToPhotoLibrary
  /// 同一约定）。
  private var completion: (@MainActor @Sendable (Result<String, Error>) -> Void)?

  init(completion: @escaping @MainActor @Sendable (Result<String, Error>) -> Void) {
    self.completion = completion
  }

  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)
    guard let completion else { return }
    self.completion = nil
    guard let provider = results.first?.itemProvider else {
      // 空结果 = 用户取消/下滑关闭（PHPicker 的取消语义）：不是错误。
      DispatchQueue.main.async { completion(.success("")) }
      return
    }
    provider.loadObject(ofClass: UIImage.self) { object, error in
      guard let image = object as? UIImage else {
        DispatchQueue.main.async {
          completion(.failure(error ?? TiebaPhotoPickerError.loadFailed))
        }
        return
      }
      // 转码 + 落盘留在回调线程（JPEG 编码是纯 CPU 活），只把结果送回主线程。
      // Data/URL 都是 Sendable，跨线程的只有结果值。
      let result: Result<String, Error>
      do {
        guard let data = image.jpegData(compressionQuality: 0.9) else {
          throw TiebaPhotoPickerError.encodeFailed
        }
        let url = TiebaPhotoPicker.outputURL()
        try data.write(to: url, options: .atomic)
        result = .success(url.absoluteString)
      } catch {
        result = .failure(error)
      }
      DispatchQueue.main.async {
        completion(result)
      }
    }
  }
}

enum TiebaPhotoPicker {
  /// 展示中的 delegate（强持有，见 TiebaPhotoPickerDelegate 注释）。
  nonisolated(unsafe) private static var activeDelegate: TiebaPhotoPickerDelegate?

  /// 展示单图选择器。completion 在主线程回调；取消回空串。
  ///
  /// completion 是 `@MainActor`，而本函数本身 nonisolated（静态状态 + present
  /// 的前置条件是"在主线程调用"，见文件头"线程"）。唯一调用点
  /// 经 onMain 收束，所以两条
  /// 早退路径用 assumeIsolated 把这条既有契约显式化：不满足即 crash，而不是
  /// 静默跨线程回调（与 TiebaPhotoBrowser.swift:611 同一约定）。
  static func presentSingleImage(
    completion: @escaping @MainActor @Sendable (Result<String, Error>) -> Void
  ) {
    guard activeDelegate == nil else {
      MainActor.assumeIsolated { completion(.failure(TiebaPhotoPickerError.alreadyPresenting)) }
      return
    }
    guard let host = TiebaTopViewController.find() else {
      MainActor.assumeIsolated { completion(.failure(TiebaPhotoPickerError.noPresenter)) }
      return
    }
    // 独立配置（不传 photoLibrary:）——完全不需要相册权限，也不需要 asset
    // identifier；传 .shared() 才会把 app 与相册读取权限绑在一起。
    var configuration = PHPickerConfiguration()
    configuration.filter = .images
    configuration.selectionLimit = 1
    // .current：系统不做格式转换，转码统一在落盘时做（见文件头）。
    configuration.preferredAssetRepresentationMode = .current

    let picker = PHPickerViewController(configuration: configuration)
    let delegate = TiebaPhotoPickerDelegate { result in
      // 延后一拍释放 delegate：这个回调还在 delegate 的方法栈上，立即置 nil
      // 会在执行中释放 self。activeDelegate 是静态强引用，晚一拍清无副作用。
      DispatchQueue.main.async { activeDelegate = nil }
      completion(result)
    }
    picker.delegate = delegate
    activeDelegate = delegate
    host.present(picker, animated: true)
  }

  /// 输出路径：缓存目录 portrait_<毫秒>.jpg。上传成功后即可被系统回收，不进
  /// 文档目录（旧实现直接用相册 localUri，本仓改为落一份上传副本）。
  static func outputURL() -> URL {
    TiebaFileSystem.cacheDirectory
      .appendingPathComponent("portrait_\(Int(Date().timeIntervalSince1970 * 1000)).jpg")
  }
}
