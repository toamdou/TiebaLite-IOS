// 图片长按预览：系统 context menu 的 previewProvider 内容（明亮圆角大图卡片，
// 背景由系统压暗）。首帧用屏上缩略图，原图后台加载后就地淡入替换。
import UIKit
import Nuke
import os

/// 模块日志（全库统一 os.Logger；NSLog 同步无缓冲、口径不一）。
private let photoPreviewLog = Logger(subsystem: "com.tiebalite.app", category: "photo-preview")

final class TiebaPhotoPreviewViewController: UIViewController {
  private let imageView = UIImageView()
  private let fullUrl: String?
  private var loadTask: Task<Void, Never>?

  /// 预览尺寸基准：活动场景里 key window 的 bounds（`UIScreen.main` 自 iOS 26
  /// 起废弃，多场景/外接屏下语义错误）。
  private static func activeWindowBounds() -> CGRect? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let window = scenes.first { $0.activationState == .foregroundActive }?.keyWindow
      ?? scenes.compactMap(\.keyWindow).first
      ?? scenes.first?.windows.first
    return window?.bounds
  }

  init(initialImage: UIImage?, fullUrl: String?, pixelWidth: Double, pixelHeight: Double) {
    self.fullUrl = fullUrl

    // 预览尺寸：宽不超过窗口宽 - 48，高按原图比例并给下方菜单留空间。
    // 无窗口（不可能：本菜单只在屏上创建）时按最窄机型 375pt 保守取值。
    let windowBounds = Self.activeWindowBounds() ?? CGRect(x: 0, y: 0, width: 375, height: 667)
    let maxWidth = windowBounds.width - 48
    let maxHeight = windowBounds.height * 0.62
    let ratio = pixelWidth > 0 && pixelHeight > 0 ? pixelHeight / pixelWidth : 1
    var previewWidth = min(maxWidth, pixelWidth > 0 ? pixelWidth : 260)
    var previewHeight = previewWidth * ratio
    if previewHeight > maxHeight {
      previewHeight = maxHeight
      previewWidth = previewHeight / max(ratio, 0.01)
    }

    super.init(nibName: nil, bundle: nil)

    preferredContentSize = CGSize(width: previewWidth, height: previewHeight)

    imageView.image = initialImage
    imageView.contentMode = .scaleAspectFit
    imageView.clipsToBounds = true
    imageView.layer.cornerRadius = 16
    imageView.layer.cornerCurve = .continuous
    imageView.backgroundColor = .clear

    // 预览容器透明：只呈现图片本身的圆角卡片，不带系统材质底
    view.isOpaque = false
    view.backgroundColor = .clear
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    imageView.frame = view.bounds
    imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    view.addSubview(imageView)
    startLoadingFullImage()
  }

  private func startLoadingFullImage() {
    guard let fullUrl, !fullUrl.isEmpty, let url = URL(string: fullUrl) else { return }
    // 预览卡片的显示尺寸就是 preferredContentSize（init 已算好）：按它 × 屏幕
    // scale 下采样，别让 4000×3000 原图全尺寸解码（约 48MB 位图只服务一张卡片）。
    // fit（aspectFit）与 imageView.contentMode 一致：长图不会按 fill 目标解出
    // 超过卡片框的位图。
    let scale = TiebaPhotoBrowserSession.displayScale(for: view)
    let target = CGSize(
      width: max(preferredContentSize.width, 1) * scale,
      height: max(preferredContentSize.height, 1) * scale
    )
    loadTask = Task { [weak self] in
      do {
        // Task 取消会经 Nuke 的 withTaskCancellationHandler 一并取消在途请求
        // （ImageTask.response）。
        let request = ImageRequest(
          url: TiebaNuke.secureURL(url),
          processors: [TiebaNuke.fitProcessor(targetPixelSize: target)]
        )
        let image = try await TiebaNuke.pipeline.image(for: request)
        guard !Task.isCancelled, let self else { return }
        UIView.transition(
          with: self.imageView,
          duration: 0.25,
          options: [.transitionCrossDissolve, .allowUserInteraction]
        ) {
          self.imageView.image = image
        }
      } catch {
        // 弱网 / 加载失败：保持缩略图首帧，不打断菜单交互（有意的产品行为）。
        // 仍留一条 debug 日志：否则"菜单里一直是缩略图"永远查不到原因。
        #if DEBUG
        photoPreviewLog.debug("full image load failed: \(error.localizedDescription, privacy: .public)")
        #endif
      }
    }
  }

  deinit {
    loadTask?.cancel()
  }
}
