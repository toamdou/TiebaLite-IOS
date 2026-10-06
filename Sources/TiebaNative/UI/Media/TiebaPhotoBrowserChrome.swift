// 从 TiebaPhotoBrowser.swift 拆出（H10 千行文件拆分）：动作控制器 + 页码药丸。
// 纯搬运：整类型逐字搬走。

import JXPhotoBrowser
import Nuke
import UIKit

@MainActor
final class TiebaPhotoBrowserActionController {
  /// 胶囊提示宿主（浏览器 view）。weak：会话释放即失效。
  weak var pillHost: UIView?
  /// Alert/分享面板的宿主 VC（浏览器自身）。
  weak var presenter: UIViewController?

  /// 胶囊视图。**不能在存储属性默认值里直接 TiebaPhotoBrowserPillView()**：
  /// Swift 6.4 对"nonisolated 上下文里的 main actor 隔离默认值"是硬错误
  /// （UIView 子类的 init 是 @MainActor，@preconcurrency 也降不了级，见
  /// TiebaNavBarChrome 184 同源问题）。assumeIsolated 成立的依据：本控制器只随
  /// 会话构造，而会话只在主线程建（TiebaPhotoBrowser.present 内部对自己切主，
  /// 见文件头"展示入口全部可从任意线程调用"）——真被后台构造会立刻 trap。
  private let pill = MainActor.assumeIsolated { TiebaPhotoBrowserPillView() }
  private var pillBottomConstraint: NSLayoutConstraint?
  private var isSaving = false
  private var isSharing = false
  /// 动作进行中自持：查看器被关闭（会话释放）时保存/分享不半路丢失。
  private var selfRetain: TiebaPhotoBrowserActionController?

  /// 把胶囊挂到宿主 view：底部居中，位置对齐旧查看器
  /// bottom = max(insets.bottom,16)+96（相对屏幕底），最大宽 min(宿主 82%, 浮动条上限)。
  func attach(to host: UIView) {
    pillHost = host
    pill.translatesAutoresizingMaskIntoConstraints = false
    host.addSubview(pill)
    let bottom = pill.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -96)
    pillBottomConstraint = bottom
    NSLayoutConstraint.activate([
      pill.centerXAnchor.constraint(equalTo: host.centerXAnchor),
      bottom,
      pill.widthAnchor.constraint(lessThanOrEqualTo: host.widthAnchor, multiplier: 0.82),
      pill.widthAnchor.constraint(lessThanOrEqualToConstant: TiebaLayout.floatingMaxWidth),
      pill.widthAnchor.constraint(greaterThanOrEqualToConstant: 112),
    ])
    updatePillBottomInset(host.safeAreaInsets.bottom)
  }

  /// 底部避让随安全区更新：目标 = 屏幕底往上 max(insets.bottom,16)+96
  /// （旧查看器公式）；本约束锚在 view 底，故取差值。
  func updatePillBottomInset(_ safeAreaBottom: CGFloat) {
    pillBottomConstraint?.constant = -(max(safeAreaBottom, 16) + 96 - safeAreaBottom)
  }

  /// 执行动作（穷举 switch：新增动作必须在这里落地，不再有 default 静默吞掉）。
  /// save-original 用原图档（originUrl），origin 缺失时菜单不展示该项（对齐旧 JS showOriginalBtn）；
  /// view-original 是视图状态（逐页切档），由调用方先行分流，这里只做兜底。
  func perform(action: TiebaPhotoBrowserAction, item: TiebaPhotoItem) {
    switch action {
    case .save:
      save(url: item.url)
    case .saveOriginal:
      save(url: item.originUrl ?? item.url)
    case .share:
      share(item: item)
    case .viewOriginal:
      break
    }
  }

  /// 瞬时失败提示（图片加载失败等；2.2s 自动消失）。
  func showTransientFailure(_ text: String) {
    pill.showResult(success: false, text: text)
  }

  // MARK: 保存

  private func save(url: URL) {
    guard !isSaving else { return }
    isSaving = true
    retainWhileBusy()
    pill.show(text: "正在保存…", progress: 0)
    TiebaPhotoBrowserImageLoader.data(
      url,
      progress: { [weak self] fraction in
        self?.pill.update(progress: fraction)
      },
      completion: { [weak self] result in
        guard let self else { return }
        switch result {
        case .success(let data):
          self.writeToPhotoLibrary(data: data) { [weak self] result in
            guard let self else { return }
            self.isSaving = false
            self.releaseWhenIdle()
            switch result {
            case .success:
              // 旧查看器 hapticForScene('action-success')。无 view 初始化已标待废弃
              // （UIFeedbackGenerator.h:21）：改挂 pill（控制器持有、必在窗口内），档位/时序不变。
              UINotificationFeedbackGenerator(view: self.pill).notificationOccurred(.success)
              self.pill.showResult(success: true, text: "保存成功")
            case .failure(let error):
              self.pill.hide()
              self.handleSaveFailure(error)
            }
          }
        case .failure(let error):
          self.isSaving = false
          self.releaseWhenIdle()
          self.pill.hide()
          self.handleSaveFailure(error)
        }
      }
    )
  }

  private func handleSaveFailure(_ error: Error) {
    if case TiebaPhotoBrowserError.permissionDenied = error {
      presentAlert(title: "权限不足", message: "请在设置中允许访问相册以保存图片")
      return
    }
    presentAlert(title: "保存失败", message: Self.readableMessage(error) ?? "无法保存图片到相册")
  }

  /// 2026-09-12：写入实现抽到 TiebaPhotoLibrary（JS 侧 saveImageToGallery 退场
  /// expo-media-library 后要与查看器共用同一份 addOnly 授权 + 写入语义）；本方法
  /// 只保留"查看器保存"这个调用点，错误契约不变（permissionDenied → "权限不足"，
  /// completion 恒在主线程回调）。
  private func writeToPhotoLibrary(
    data: Data,
    completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void
  ) {
    TiebaPhotoLibrary.save(data: data, completion: completion)
  }

  // MARK: 分享

  private func share(item: TiebaPhotoItem) {
    guard !isSharing else { return }
    isSharing = true
    retainWhileBusy()
    // 旧查看器 hapticForScene('press')。init(style:) 已标待废弃
    // （UIImpactFeedbackGenerator.h:38）：改挂 pill，档位/时序不变。
    UIImpactFeedbackGenerator(style: .light, view: pill).impactOccurred()
    pill.show(text: "正在准备分享…", progress: 0)
    TiebaPhotoBrowserImageLoader.data(
      item.url,
      progress: { [weak self] fraction in
        self?.pill.update(progress: fraction)
      },
      completion: { [weak self] result in
        guard let self else { return }
        self.isSharing = false
        self.releaseWhenIdle()
        self.pill.hide()
        switch result {
        case .success(let data):
          self.presentShareSheet(data: data, sourceURL: item.url)
        case .failure(let error):
          self.presentAlert(title: "分享失败", message: Self.readableMessage(error) ?? "图片下载失败，请稍后重试")
        }
      }
    )
  }

  /// @MainActor：TiebaShareSheet 是 MainActor 隔离（present 类操作），调用点
  /// （share 的 completion）本来就是 @MainActor 闭包，这里把隔离显式写进签名。
  @MainActor
  private func presentShareSheet(data: Data, sourceURL: URL) {
    guard let presenter, presenter.view.tiebaIsOnScreen else { return }
    do {
      let fileURL = try Self.writeTemporaryFile(data: data, sourceURL: sourceURL)
      // 呈现收敛到 TiebaShareSheet（与 JS 门面 sharePresent 同一份实现）：
      // iPad 锚点/completion 时序只有一处，成功与否由返回值判断（不在窗口上=false）。
      _ = TiebaShareSheet.present(fileURL: fileURL, from: presenter) {
        // 分享结束即清理临时文件（成功/取消/失败都清）。
        try? FileManager.default.removeItem(at: fileURL)
      }
    } catch {
      presentAlert(title: "分享失败", message: Self.readableMessage(error) ?? "无法创建分享文件")
    }
  }

  /// 分享临时文件：文件名按数据魔数定扩展名（GIF 保 .gif，系统按动图分享）。
  private static func writeTemporaryFile(data: Data, sourceURL: URL) throws -> URL {
    let ext = fileExtension(for: data, fallbackURL: sourceURL)
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("tieba_share_\(UUID().uuidString).\(ext)")
    try data.write(to: url, options: .atomic)
    return url
  }

  private static func fileExtension(for data: Data, fallbackURL: URL) -> String {
    if data.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "gif" } // "GIF8"
    if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" } // ‰PNG
    if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" } // JPEG SOI
    if data.starts(with: [0x52, 0x49, 0x46, 0x46]) { return "webp" } // RIFF（图床仅 webp）
    let ext = fallbackURL.pathExtension.lowercased()
    return ext.isEmpty ? "jpg" : ext
  }

  // MARK: 提示

  private func presentAlert(title: String, message: String) {
    guard let presenter, presenter.view.tiebaIsOnScreen,
          presenter.presentedViewController == nil else { return }
    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "好", style: .default))
    presenter.present(alert, animated: true)
  }

  private static func readableMessage(_ error: Error) -> String? {
    if let localized = (error as? LocalizedError)?.errorDescription, !localized.isEmpty {
      return localized
    }
    let message = (error as NSError).localizedDescription
    return message.isEmpty ? nil : message
  }

  private func retainWhileBusy() {
    selfRetain = self
  }

  private func releaseWhenIdle() {
    guard !isSaving, !isSharing else { return }
    selfRetain = nil
  }
}

// MARK: - 底部胶囊提示（保存进度/结果；样式对齐旧查看器 styles.savePill）

/// 旧查看器底部"保存成功"药丸：rgba(28,28,30,.88) / 圆角 18 / 白 14pt medium /
/// 阴影 / 2.2s 自动消失。这里加一个 3pt 确定进度条（保存/下载进度），
/// 并进行中文案（"正在保存…"/"正在准备分享…"）；底走系统液态玻璃
/// （部署底线 iOS 26，UIGlassEffect 恒可用，不再有低版本分档）。
final class TiebaPhotoBrowserPillView: UIView {
  private static let horizontalPadding: CGFloat = 16
  private static let verticalPadding: CGFloat = 9
  private static let contentGap: CGFloat = 6
  private static let indicatorSize: CGFloat = 18
  private static let progressHeight: CGFloat = 3
  private static let cornerRadius: CGFloat = 18

  /// 玻璃底（部署底线 iOS 26，恒可用）。
  private let glassBackground: UIVisualEffectView = {
    let effect = UIGlassEffect(style: .regular)
    effect.tintColor = UIColor(red: 28 / 255, green: 28 / 255, blue: 30 / 255, alpha: 0.55)
    return UIVisualEffectView(effect: effect)
  }()

  /// A5：阴影烤成一张九宫格拉伸图，**不进 layer.shadow*** —— 后者会给每个玻璃面板带来一次
  /// 离屏合成，而且本视图宽度随文案变、高度随进度条变，shadowPath 追不上形状。
  private let shadowView = UIImageView()
  private var bakedShadow: TiebaBakedShadow?
  /// B1 进场动画的键（hide / 复用前要摘掉，否则会带着在途动画）。
  private static let entranceKey = "tieba.pill.entrance"

  /// [接线 UI/Nodes/TiebaStatusNode] 改前这里是两个控件：UIActivityIndicatorView 转圈 +
  /// 一张静态结果图（checkmark.circle.fill / exclamationmark.circle.fill）。进度只有底部那条
  /// 3pt 线性条，转圈与结果之间也没有过渡。
  /// 改后合成一个状态指示器：进行中是**确定进度环**（有 fraction 就画弧、没有就不确定转圈），
  /// 结果态是 0→1 的勾选描边（失败走 icon 态）。尺寸槽仍是 18pt，布局不变。
  private let statusNode = TiebaStatusNode(foregroundColor: .white)
  private let label = UILabel()
  private let progressTrack = UIView()
  private let progressFill = UIView()
  private var progressFraction: Double?
  private var hideWorkItem: DispatchWorkItem?

  init() {
    super.init(frame: .zero)
    glassBackground.isUserInteractionEnabled = false
    glassBackground.layer.cornerRadius = Self.cornerRadius
    glassBackground.layer.cornerCurve = .continuous
    glassBackground.clipsToBounds = true
    addSubview(glassBackground)
    layer.cornerRadius = Self.cornerRadius
    layer.cornerCurve = .continuous
    // A5：改前 = layer.shadow*（opacity 0.18 / radius 10 / offset (0,4)）—— 形状一变阴影就追不上；
    // 改后 = 同一组观感参数（blur ≈ 2×radius）烤成一张九宫格图，任意尺寸拉伸而模糊度不变。
    shadowView.isUserInteractionEnabled = false
    insertSubview(shadowView, at: 0)
    let bakedShadow = TiebaShadowImage.stretchable(
      cornerRadius: Self.cornerRadius,
      intensity: 0.18,
      blur: 20.0,
      offset: CGSize(width: 0, height: 4)
    )
    self.bakedShadow = bakedShadow
    shadowView.image = bakedShadow?.image
    isUserInteractionEnabled = false
    isHidden = true
    alpha = 0

    statusNode.isHidden = true
    addSubview(statusNode)

    label.textColor = .white
    label.font = .systemFont(ofSize: 14, weight: .medium)
    label.textAlignment = .center
    label.lineBreakMode = .byTruncatingTail
    addSubview(label)

    progressTrack.backgroundColor = UIColor.white.withAlphaComponent(0.18)
    progressTrack.layer.cornerRadius = 1.5
    progressTrack.clipsToBounds = true
    progressTrack.isHidden = true
    progressTrack.addSubview(progressFill)
    progressFill.backgroundColor = .white
    addSubview(progressTrack)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override var intrinsicContentSize: CGSize {
    let labelSize = label.sizeThatFits(
      CGSize(width: 300, height: CGFloat.greatestFiniteMagnitude)
    )
    var width = Self.horizontalPadding * 2 + min(labelSize.width, 300)
    if !statusNode.isHidden {
      width += Self.indicatorSize + Self.contentGap
    }
    let progressExtra: CGFloat = progressFraction != nil ? Self.progressHeight + 2 : 0
    return CGSize(
      width: ceil(width),
      height: max(labelSize.height, Self.indicatorSize) + Self.verticalPadding * 2 + progressExtra
    )
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    glassBackground.frame = bounds
    if let bakedShadow {
      shadowView.frame = bounds.insetBy(dx: -bakedShadow.inset, dy: -bakedShadow.inset)
    }
    let progressExtra = progressFraction != nil ? Self.progressHeight + 2 : 0
    var x = Self.horizontalPadding
    let contentHeight = max(bounds.height - Self.verticalPadding * 2 - progressExtra, 0)
    let indicatorY = Self.verticalPadding + (contentHeight - Self.indicatorSize) / 2
    if !statusNode.isHidden {
      statusNode.frame = CGRect(x: x, y: indicatorY, width: Self.indicatorSize, height: Self.indicatorSize)
      x += Self.indicatorSize + Self.contentGap
    }
    label.frame = CGRect(
      x: x,
      y: Self.verticalPadding,
      width: max(bounds.width - x - Self.horizontalPadding, 0),
      height: contentHeight
    )
    guard progressFraction != nil else { return }
    let track = CGRect(
      x: Self.horizontalPadding,
      y: bounds.height - Self.verticalPadding - Self.progressHeight,
      width: max(bounds.width - Self.horizontalPadding * 2, 0),
      height: Self.progressHeight
    )
    progressTrack.frame = track
    progressFill.frame = CGRect(
      x: 0,
      y: 0,
      width: track.width * CGFloat(min(max(progressFraction ?? 0, 0), 1)),
      height: track.height
    )
  }

  /// 进行中态。progress = nil 时不显示进度条。
  func show(text: String, progress: Double?) {
    hideWorkItem?.cancel()
    hideWorkItem = nil
    label.text = text
    statusNode.isHidden = false
    // nil = 不确定进度（准备分享这类拿不到 fraction 的阶段）→ 自己转圈。
    statusNode.setState(.progress(
      value: progress.map { CGFloat(min(max($0, 0), 1)) },
      cancelEnabled: false,
      appearance: nil,
      animateRotation: true
    ))
    progressFraction = progress
    progressTrack.isHidden = (progress == nil)
    isHidden = false
    setNeedsLayout()
    invalidateIntrinsicContentSize()
    playEntrance()
  }

  /// B1 落地：进场不再是一条 0.18s 的纯淡入（所有属性一根曲线 —— 看起来像"贴纸"），
  /// 而是**三条属性各走各的节奏**：透明度先到位、位移先快后慢、缩放最后收尾；
  /// 三者共用同一个 duration，全部 .linear 播放（缓动在生成数组时就烘好了）。
  /// 模型值保持终态（alpha 1 / identity），动画只作用于 presentation —— 与 TiebaEntrance 同一约定。
  private func playEntrance() {
    alpha = 1
    layer.removeAnimation(forKey: Self.entranceKey)
    guard !UIAccessibility.isReduceMotionEnabled else { return }
    let duration = TiebaAnimationDuration.stateChange
    let count = 10
    let group = CAAnimationGroup()
    let opacity = CAKeyframeAnimation(keyPath: "opacity")
    opacity.values = TiebaBakedKeyframes.numbers(from: 0.0, to: 1.0, count: count, easing: .easeOutStrong)
    let translation = CAKeyframeAnimation(keyPath: "transform.translation.y")
    translation.values = TiebaBakedKeyframes.numbers(from: 8.0, to: 0.0, count: count, easing: .easeOut)
    let scale = CAKeyframeAnimation(keyPath: "transform.scale")
    scale.values = TiebaBakedKeyframes.numbers(from: 0.94, to: 1.0, count: count, easing: .easeInEaseOut)
    group.animations = [opacity, translation, scale]
    group.duration = duration
    // 模型值已经是终态，动画起播前用 backwards 填首帧 —— 避免"第一帧闪一下终态"。
    group.fillMode = .backwards
    group.timingFunction = CAMediaTimingFunction(name: .linear)
    TiebaAnimationFrameRate.align(group, to: self)
    layer.add(group, forKey: Self.entranceKey)
  }

  func update(progress: Double) {
    progressFraction = min(max(progress, 0), 1)
    progressTrack.isHidden = false
    // 环与底部线性条同一个值：环给"还要多久"的直观量，条保留原有观感（M 级进度口径不变）。
    statusNode.setState(.progress(
      value: CGFloat(progressFraction ?? 0),
      cancelEnabled: false,
      appearance: nil,
      animateRotation: true
    ))
    setNeedsLayout()
    invalidateIntrinsicContentSize()
  }

  /// 结果态：图标 + 文案，2.2s 后自动淡出（旧查看器 2200ms）。
  func showResult(success: Bool, text: String) {
    // 成功 = 0→1 的勾选描边（TiebaStatusCheckContext 在 init 里就起描边）；失败 = 感叹号图标。
    statusNode.setState(success
      ? .check(appearance: nil)
      : .icon(.systemImage("exclamationmark.circle.fill")))
    statusNode.isHidden = false
    label.text = text
    progressFraction = nil
    progressTrack.isHidden = true
    isHidden = false
    setNeedsLayout()
    invalidateIntrinsicContentSize()
    playEntrance()
    hideWorkItem?.cancel()
    let item = DispatchWorkItem { [weak self] in self?.hide() }
    hideWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: item)
  }

  func hide() {
    hideWorkItem?.cancel()
    hideWorkItem = nil
    // 在途的进场关键帧必须先摘：否则淡出期间它还按自己的曲线写 opacity，会把淡出拉回去。
    layer.removeAnimation(forKey: Self.entranceKey)
    TiebaAnimation.animate(duration: 0.18, animations: { self.alpha = 0 }) { _ in
      self.isHidden = true
    }
  }
}

// MARK: - 浏览器 VC 子类（关闭上报 / 状态栏 / 安全区）
