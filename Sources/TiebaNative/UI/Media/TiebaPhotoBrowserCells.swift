// 从 TiebaPhotoBrowser.swift 拆出（H10 千行文件拆分）：浏览器控制器 + 图片格 + 其扩展。
// 纯搬运：整类型逐字搬走。

import JXPhotoBrowser
import Nuke
import UIKit

final class TiebaPhotoBrowserViewController: JXPhotoBrowserViewController {
  var onDismissed: (() -> Void)?
  var onSafeAreaInsetsDidChange: ((UIEdgeInsets) -> Void)?
  /// 进场转场完成（进场黑底的撤除时机）。
  var onDidAppear: (() -> Void)?
  private var didReportDismiss = false

  /// 状态栏：旧查看器经 TiebaNative.setModalStatusBarHidden(true) 隐藏；
  /// 这里 VC 级直接接管（overFullScreen 需显式声明捕获状态栏外观）。
  override var prefersStatusBarHidden: Bool { true }
  override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation { .fade }

  override func viewDidLoad() {
    super.viewDidLoad()
    modalPresentationCapturesStatusBarAppearance = true
    // [按上游调参] 交互式下拉关闭的判据与收尾：Vendor 只留旋钮（它不能反向依赖本模块），
    // 值在这里从 TiebaMotionSpec 注入 —— 全仓手感参数只有一份出处。
    //   判据：速度 > 1000pt/s 或进度 > 0.2（上游 NavigationContainer.swift:285）；
    //   收尾：clamp(0.05…0.2, |距离/速度|)（上游 NavigationTransitionCoordinator.swift:333）；
    //   无速度时的归位弹簧用"关闭档" 5 / 900 / 124（上游 ResizableSheetComponent.swift:641）。
    dismissVelocityThreshold = TiebaMotionSpec.Transition.dismissVelocityThreshold
    dismissProgressThreshold = TiebaMotionSpec.Transition.dismissProgressThreshold
    dismissSettleDurationRange = TiebaMotionSpec.Transition.settleMinDuration ... TiebaMotionSpec.Transition.settleMaxDuration
    dismissSettleSpringDuration = TiebaAnimationDuration.springMass
    dismissSettleMass = TiebaMotionSpec.Spring.closeMass
    dismissSettleStiffness = TiebaMotionSpec.Spring.closeStiffness
    dismissSettleDamping = TiebaMotionSpec.Spring.closeDamping
  }

  override func viewSafeAreaInsetsDidChange() {
    super.viewSafeAreaInsetsDidChange()
    onSafeAreaInsetsDidChange?(view.safeAreaInsets)
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    onDidAppear?()
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    reportDismissIfNeeded()
  }

  override func dismiss(animated flag: Bool, completion: (() -> Void)?) {
    super.dismiss(animated: flag) { [weak self] in
      completion?()
      self?.reportDismissIfNeeded()
    }
  }

  private func reportDismissIfNeeded() {
    guard !didReportDismiss else { return }
    guard isBeingDismissed || presentingViewController == nil else { return }
    didReportDismiss = true
    onDismissed?()
  }
}

// MARK: - Cell（JXZoomImageCell 子类 + Nuke 两级加载 + 长按菜单）

final class TiebaPhotoBrowserImageCell: JXZoomImageCell {
  static let tiebaReuseIdentifier = "TiebaPhotoBrowserImageCell"
  /// 长图阅读模式的缩放上限（fit-width 需要超过默认 3.0；见 applyLongImageFit）。
  private static let longImageMaximumZoom: CGFloat = 12

  var onSingleTap: (() -> Void)?
  var onMenuAction: ((String) -> Void)?
  var onLoadFailed: (() -> Void)?
  var onDismissInteractionChange: ((Bool) -> Void)?

  private let spinner = UIActivityIndicatorView(style: .large)
  private var thumbTask: Task<Void, Never>?
  private var fullTask: Task<Void, Never>?
  private var generation = 0
  private var retryCount = 0
  private var fullImageReady = false
  private var appliedURL: URL?
  /// 当前上屏的是不是「超分辨率结果」这张内存图（非 Nuke 加载）：同一 URL 下也要能识别换图。
  private var appliedOverride: UIImage?
  /// 当前页是否有原图档（决定长按菜单是否展示「保存原图」）。
  private var hasOrigin = false
  /// 当前页是否可切看原图（服务端 showOriginalBtn 且有独立原图档，且不在展示原图）。
  private var hasViewOriginal = false
  private var wantsLongFit = false
  private var longFitApplied = false
  private var isApplyingLongFit = false
  /// 上次长图 fit 对应的容器尺寸（框架在尺寸变化时把缩放回位，长图要按新宽重做）
  private var longFitBoundsSize: CGSize = .zero

  override init(frame: CGRect) {
    super.init(frame: frame)
    commonSetup()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    commonSetup()
  }

  private func commonSetup() {
    backgroundColor = .clear
    contentView.backgroundColor = .clear
    spinner.color = .white
    spinner.hidesWhenStopped = true
    spinner.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(spinner)
    NSLayoutConstraint.activate([
      spinner.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
      spinner.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
    ])
    // 长按菜单挂整个 Cell（页面铺满，任意位置长按都出菜单；与旧查看器
    // TiebaPhotoContextMenu(previewEnabled:false) 的交互范围一致）。
    addInteraction(UIContextMenuInteraction(delegate: self))

    // 单击：框架那只 singleTapGesture 是裸 UITapGestureRecognizer（按住多久都算 tap，
    // 长按菜单弹出后抬手会再触发一次 → chrome 闪一下）。这里禁用框架那只，改用
    // TiebaMultiIntentGestureRecognizer 的 .tapOnly 瘦模式（只产 singleTap；双击仍归框架
    // doubleTapGesture 管缩放）；maximumTapDuration 0.15s 就是原来 TiebaUniversalTapRecognizer 的上限。
    // 单击语义不变：handleSingleTap 覆写 → onSingleTap?()（切 chrome 显隐，不是关闭）。
    singleTapGesture.isEnabled = false
    let singleTap = TiebaMultiIntentGestureRecognizer(target: nil, action: nil)
    singleTap.mode = .tapOnly
    singleTap.maximumTapDuration = 0.15
    singleTap.onIntent = { [weak self] intent in
      guard case .singleTap = intent else { return }
      self?.onSingleTap?()
    }
    singleTap.require(toFail: doubleTapGesture)
    scrollView.addGestureRecognizer(singleTap)
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    cancelLoading()
    generation += 1
    appliedURL = nil
    appliedOverride = nil
    retryCount = 0
    fullImageReady = false
    hasOrigin = false
    hasViewOriginal = false
    wantsLongFit = false
    longFitApplied = false
    spinner.stopAnimating()
  }

  // MARK: 配置 / 加载

  /// - Parameter overrideImage: 超分辨率结果（内存图）。非 nil 时直接上屏、**不走 Nuke**；
    ///   nil = 回到按 item.url 正常加载。页面 URL 不变，所以不能再只看 appliedURL 判断"要不要重配"。
  func configure(
    item: TiebaPhotoItem,
    index: Int,
    targetPixelSize: CGSize,
    containerSize: CGSize,
    overrideImage: UIImage? = nil
  ) {
    // 同一 URL 但换了超分结果（或从超分结果切回原档）也必须重配，否则屏幕上会留着上一张。
    guard appliedURL != item.url || appliedOverride !== overrideImage else { return }
    appliedURL = item.url
    appliedOverride = overrideImage
    hasOrigin = item.originUrl != nil
    hasViewOriginal = item.canViewOriginal && item.originUrl != nil
    generation += 1
    let generation = self.generation
    retryCount = 0
    fullImageReady = false
    longFitApplied = false
    thumbTask?.cancel()
    fullTask?.cancel()
    stopGIFPlayback()
    imageView.image = nil
    scrollView.setZoomScale(scrollView.minimumZoomScale, animated: false)
    // 旧查看器缩放域 1~5、双击 3x（parts.tsx useZoomGesture maxScale:5 /
    // doubleTapConfig defaultScale:3）；框架默认上限 3.0，这里对齐旧值。
    scrollView.maximumZoomScale = 5
    doubleTapZoomScale = 3
    wantsLongFit = item.isLongImage(in: containerSize)
    spinner.stopAnimating()

    // 超分结果直接落位（与"大图已就绪"同一路径：停 spinner、套长图 fit），**不发任何网络请求**。
    if let overrideImage {
      imageView.image = overrideImage
      fullImageReady = true
      setNeedsLayout()
      applyLongImageFitIfNeeded()
      return
    }

    if let thumbRequest = TiebaPhotoBrowserImageLoader.thumbRequest(item.thumbUrl, pixelSize: targetPixelSize) {
      thumbTask = Task { [weak self] in
        guard let container = try? await TiebaPhotoBrowserImageLoader.load(thumbRequest, isGif: false) else {
          return
        }
        DispatchQueue.main.async {
          self?.apply(container: container, isThumb: true, isGif: false, generation: generation)
        }
      }
    } else {
      spinner.startAnimating()
    }
    loadFull(
      item: item,
      targetPixelSize: targetPixelSize,
      containerSize: containerSize,
      generation: generation
    )
  }

  // MARK: 超分辨率（输入 = 当前页正在显示的已加载像素）

  /// 超分输入：当前这一页**已经加载到屏幕上的那版像素**。大图未就绪时就是垫图那版
  /// （仍属"当前展示的像素"，且不会为此多发一次请求）。
  var superResolutionSource: CGImage? {
    imageView.image?.cgImage
  }

  /// 菜单里「超分辨率」能否执行（>4MP 或任一边 < 128 时置灰）。
  var canSuperResolution: Bool {
    guard let source = superResolutionSource else { return false }
    return TiebaSuperResolutionLimits.canUpscale(width: source.width, height: source.height)
  }

  /// 当前可见的那部分图像占整幅的比例（0…1）——渐进式超分据此先算视口内的块。
  /// 取的是 scrollView 的可见矩形与 imageView（含缩放后）的相交部分，因此缩放/平移状态下同样准。
  var visibleImageFraction: CGRect? {
    guard imageView.image != nil, bounds.width > 1, bounds.height > 1 else { return nil }
    let frame = imageView.frame
    guard frame.width > 1, frame.height > 1 else { return nil }
    let visible = CGRect(origin: scrollView.contentOffset, size: scrollView.bounds.size)
    let intersection = visible.intersection(frame)
    guard !intersection.isNull, intersection.width > 1, intersection.height > 1 else { return nil }
    return CGRect(
      x: (intersection.minX - frame.minX) / frame.width,
      y: (intersection.minY - frame.minY) / frame.height,
      width: intersection.width / frame.width,
      height: intersection.height / frame.height
    )
  }

  /// 渐进式超分的中途快照：直接换屏上的图。不重配（不重置缩放/位移），用户看到的是"逐渐变清晰"。
  func updateProgressiveImage(_ image: UIImage) {
    appliedOverride = image
    imageView.image = image
    fullImageReady = true
    spinner.stopAnimating()
    setNeedsLayout()
  }

  func cancelLoading() {
    thumbTask?.cancel()
    fullTask?.cancel()
    thumbTask = nil
    fullTask = nil
    stopGIFPlayback()
  }

  private func loadFull(
    item: TiebaPhotoItem,
    targetPixelSize: CGSize,
    containerSize: CGSize,
    generation: Int
  ) {
    fullTask = Task { [weak self] in
      do {
        // [修复③] GIF 判定必须放在**加载之前**：`item.isGif` 在"由帖子图构造"的路径上恒为 false，
        // 一旦按 false 走非 GIF 分支，Resize 处理器会把多帧压成首帧、容器里既没有 .gif 类型也没有原始字节，
        // 事后的 isGIFContainer 兜底必然失败 → 查看器只剩静态首帧（用户实测的回归①）。
        // probeGIF 是 HEAD 探测（零 body、会话级缓存），对 Nuke 内存缓存命中的第二次进入同样有效。
        // [修复 2026-10-06] 但**探测目标**原来是 item.url = 显示档（cdn_src 的 g=0 档）：
        // 线上取证（p/11060036651 全量 29 图 / 25 动图）该档对其中 15 张返回静态 JPEG，
        // 于是那 15 张点开永远是静图。改成候选链：动图档 big_cdn_src → 原图档（见 gifProbeCandidates）。
        if let gifURL = await TiebaNuke.firstGIFURL(
          among: TiebaPhotoBrowserImageLoader.gifProbeCandidates(item)
        ) {
          // 动图档通常不是屏幕上那张（列表/转场用的是显示档）：先把显示档当垫图上屏，
          // 与改动前"先出显示档"的视觉一致，不让 2.5MB 动图下载期间白屏。
          // 只有**确认显示档不是动图**（g=0 静态首帧，通常几 KB）才垫：同一张 GIF 的
          // 显示档有四成本身就是 2.5MB 动图字节（线上取证 10/25），那种情况再下一遍
          // 就是纯浪费流量与等待（HEAD 结论按 URL 会话级缓存，重复进页零成本）。
          let displayURL = TiebaNuke.secureURL(item.url)
          if gifURL != displayURL, await TiebaNuke.probeGIF(displayURL) != true {
            let base = TiebaPhotoBrowserImageLoader.request(
              item,
              pixelSize: targetPixelSize,
              containerSize: containerSize
            )
            if let baseContainer = try? await TiebaPhotoBrowserImageLoader.load(base, isGif: false) {
              DispatchQueue.main.async {
                self?.apply(container: baseContainer, isThumb: true, isGif: false, generation: generation)
              }
            }
          }
          // 播放档必须**无处理器**下载：处理器只换首帧位图（多帧仍在原始字节里，见 load 的约束）。
          let gifContainer = try await TiebaPhotoBrowserImageLoader.load(
            ImageRequest(url: gifURL),
            isGif: true
          )
          DispatchQueue.main.async {
            self?.apply(container: gifContainer, isThumb: false, isGif: true, generation: generation)
          }
          return
        }
        // 展示请求走唯一工厂（与预取同一个）：处理器按 item 比例 + 展示框算 —— 普通图 fit、
        // 长图 fill（见 N1 修复注释），两边同参数 ⇒ 内存缓存同键，预取才真的省下一次解码。
        let request = TiebaPhotoBrowserImageLoader.request(
          item,
          pixelSize: targetPixelSize,
          containerSize: containerSize
        )
        let container = try await TiebaPhotoBrowserImageLoader.load(request, isGif: false)
        DispatchQueue.main.async {
          self?.apply(container: container, isThumb: false, isGif: false, generation: generation)
        }
      } catch {
        DispatchQueue.main.async {
          self?.handleFullImageFailure(
            item: item,
            targetPixelSize: targetPixelSize,
            containerSize: containerSize,
            generation: generation
          )
        }
      }
    }
  }

  /// 失败自动重试 2 次（旧查看器 useImageLoadRetry：600ms 后退避重试，
  /// 大图档首次进查看器缓存 miss + 弱网是主要失败面）。
  private func handleFullImageFailure(
    item: TiebaPhotoItem,
    targetPixelSize: CGSize,
    containerSize: CGSize,
    generation: Int
  ) {
    guard generation == self.generation else { return }
    retryCount += 1
    guard retryCount <= 2 else {
      spinner.stopAnimating()
      onLoadFailed?()
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
      guard let self, generation == self.generation else { return }
      self.loadFull(
        item: item,
        targetPixelSize: targetPixelSize,
        containerSize: containerSize,
        generation: generation
      )
    }
  }

  // MARK: GIF 播放（原生 ImageIO 播放器；图片浏览器已不认识 GIF，播放职责在宿主这里）

  /// 逐帧播放器。每个查看页一个实例：换页/取消时 recycle() **真释放**帧缓存。
  private let gifPlayer = TiebaGIFPlayer()

  /// 播放当前页的 GIF。帧尺寸**只降不升**（资源纪律）：目标 = min(展示像素, 源像素)。
  /// 源像素就是显示分辨率上限，重采样到更大只是白占内存；大图 GIF 随之按屏幕尺寸降采样。
  /// 缓冲窗 8 → 峰值内存 = 单帧 × 8。播放期间打开 suppressImageChangeForAnimation，
  /// 挡住每帧 image 赋值触发的布局重算。
  ///
  /// [修复 2026-10-06] 目标尺寸的单位是**像素**，不是点：TiebaGIFSource.resizedFrame 用
  /// format.scale = 1 出图（帧位图的像素数 = targetSize，见 TiebaGIFPlayer 里那条同名注释）。
  /// 这里原来传的是视图**点数**、再被 cg.width / scale 砍一刀 ⇒ 帧位图只有屏幕像素密度的
  /// 1/3（实测：240×240 的动图被解成 80×80，再铺满 1179px 宽的屏幕 = 14.7 倍放大），
  /// 而同位置的静态首帧是原生的 240×240（Nuke 不套处理器、不放大 = 4.9 倍放大）——
  /// 用户报的「点进去大图模式很糊」就是这 3 倍线性差（Gifu 时代查看器 shouldResizeFrames
  /// = false 走原生帧，换自研播放器时按点渲染才引入）。静态图解码档一字未动。
  /// 改后：目标 = 展示像素（视图点数 × 屏幕 scale），上界仍是源像素（只降不升）。
  private func startGIFPlayback(data: Data) {
    let view = self.imageView
    let scale = self.traitCollection.displayScale > 0 ? self.traitCollection.displayScale : 3
    var target = CGSize(width: view.bounds.width * scale, height: view.bounds.height * scale)
    if let cg = view.image?.cgImage, cg.width > 1, cg.height > 1 {
      target.width = min(target.width, CGFloat(cg.width))
      target.height = min(target.height, CGFloat(cg.height))
    }
    // 只有真的播起来了才抑制回调：数据不是 GIF 时保持正常布局链路。
    self.suppressImageChangeForAnimation = self.gifPlayer.play(
      data: data,
      into: view,
      targetSize: target,
      contentMode: .scaleAspectFit,
      frameBufferSize: 8,
      // [修复 R3-3] 这一帧刚由 Nuke 解好并上屏（见 apply 里 imageView.image = container.image），
      // 传给播放器当第 0 帧：省掉对同一张 GIF 的第二次首帧解码（大图首帧可达数百毫秒）。
      firstFrame: view.image
    )
  }

  /// 停止播放并真释放帧缓存、恢复布局钩子（换页/取消/复用共用）。
  private func stopGIFPlayback() {
    self.suppressImageChangeForAnimation = false
    self.gifPlayer.recycle()
  }

  private func apply(container: ImageContainer, isThumb: Bool, isGif: Bool, generation: Int) {
    guard generation == self.generation else { return }
    // 大图已到后缩略图任务迟到：不覆盖（保持清晰）。
    if isThumb && fullImageReady { return }
    // 首帧静态底走正常赋值（触发一次 JX 布局，长图 fit 依赖首帧尺寸）；
    // 随后的动画帧由 TiebaGIFPlayer 逐帧写入 imageView，播放期间由
    // suppressImageChangeForAnimation 挡住每帧一次的布局重算。
    imageView.image = container.image
    if isThumb { return }
    fullImageReady = true
    spinner.stopAnimating()
    // [修复] 不再只看 isGif 标志：字节嗅探才是权威判定（服务端对 GIF 无元数据标记）。
    if (isGif || TiebaNuke.isGIFContainer(container)), let data = container.data {
      startGIFPlayback(data: data)
    }
    // 大图落位后再套长图阅读模式（需要真实像素比例算 fit-width）。
    setNeedsLayout()
    applyLongImageFitIfNeeded()
  }

  // MARK: 长图阅读模式

  /// 长图 = 进入即 fit-width（旧 LongImageView：宽=屏宽、单指上下读完）。
  /// 框架 cell 的基础布局是长边铺满（aspectFit），长图会缩成一条；这里在
  /// 大图落位后把 scrollView 程序化放大到 fit-width（只用公开 API：提高
  /// maximumZoomScale + setZoomScale，未改框架）。副作用：zoomScale >
  /// minimum 后框架的关闭手势守卫判定为"已缩放" → 长图页下拉/上滑都不退出，
  /// 用关闭按钮退出；旧查看器长图页也只在贴顶/贴底才移交退出（见文件头缺口 4）。
  private func applyLongImageFitIfNeeded() {
    guard wantsLongFit, !longFitApplied, !isApplyingLongFit,
          let image = imageView.image, image.size.width > 1, image.size.height > 1,
          bounds.width > 1, bounds.height > 1 else { return }
    longFitApplied = true
    isApplyingLongFit = true
    defer { isApplyingLongFit = false }

    let fitScale = min(bounds.width / image.size.width, bounds.height / image.size.height)
    let contentWidth = max(image.size.width * fitScale, 1)
    let neededZoom = bounds.width / contentWidth
    guard neededZoom > 1.02 else { return }
    scrollView.minimumZoomScale = 1
    scrollView.maximumZoomScale = min(max(5, neededZoom), Self.longImageMaximumZoom)
    scrollView.setZoomScale(neededZoom, animated: false)
    scrollView.contentOffset = CGPoint(x: 0, y: 0)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    // 旋转 / 分屏改宽后容器尺寸变了：框架把缩放回位到 fit，长图要按新宽重做 fit-width，
    // 否则会退回长边铺满（1024pt 宽的页面上长图缩成一条）。
    if bounds.size != longFitBoundsSize {
      longFitBoundsSize = bounds.size
      longFitApplied = false
    }
    if wantsLongFit && !longFitApplied {
      applyLongImageFitIfNeeded()
    }
  }

  // MARK: 手势回调（覆写框架行为，保持旧查看器交互）

  /// 单击 = 显隐 chrome（旧查看器 toggleUI）；框架默认是关闭浏览器，
  /// 这里按"保持现有交互"覆写。如需回到框架默认（iOS Photos 单击关闭），
  /// 删掉本覆写即可。
  override func handleSingleTap(_ gesture: UITapGestureRecognizer) {
    onSingleTap?()
  }

  /// 长图阅读模式（fit-width）允许"缩放态 + 贴顶下拉"退出：那一页整图就是"读"，贴顶下拉除了退出
  /// 没有别的含义。框架守卫默认对缩放态一律拒绝（JXPhotoBrowserViewController 的 isZoomed 分支），
  /// 于是长图只能点关闭按钮退出（文件头缺口 4）。普通图恒 false（继承默认）：缩放态拖拽应当平移已放大的图。
  /// 取的是**配置意图** wantsLongFit（configure 时按长宽比算出的），不是"是否已应用 fit"，首帧守卫即正确。
  /// ⚠️ 必须在 Cell 上覆写：框架读的是 photoCell（JXZoomImageCell），不是 VC。
  override var allowsDismissWhileZoomed: Bool { self.wantsLongFit }

  override func photoBrowserDismissInteractionDidChange(isInteracting: Bool) {
    super.photoBrowserDismissInteractionDidChange(isInteracting: isInteracting)
    onDismissInteractionChange?(isInteracting)
  }
}

// MARK: - 长按菜单（UIContextMenuInteraction + UIMenu，同 TiebaPhotoContextMenuView）

extension TiebaPhotoBrowserImageCell: UIContextMenuInteractionDelegate {
  func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    configurationForMenuAtLocation location: CGPoint
  ) -> UIContextMenuConfiguration? {
    UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
      // 原图档缺失时不展示「保存原图」；「查看原图」还要服务端 showOriginalBtn
      // 且该页当前没在展示原图（已在展示时切档会把该项摘掉，对齐旧 JS）。
      let showsOrigin = self?.hasOrigin ?? false
      let showsViewOriginal = self?.hasViewOriginal ?? false
      // 「超分辨率」恒展示，但当前这版像素不适合超分时置灰（>4MP / 任一边 < 128 / 像素还没加载出来）。
      let canSuperResolve = self?.canSuperResolution ?? false
      let children = TiebaPhotoBrowserSession.menuActions
        .filter { spec in
          switch spec.action {
          case .saveOriginal: return showsOrigin
          case .viewOriginal: return showsViewOriginal
          case .save, .share, .superResolution: return true
          }
        }
        .map { spec in
          let disabled = (spec.action == .superResolution) && !canSuperResolve
          return UIAction(
            title: spec.title,
            image: UIImage(systemName: spec.icon),
            attributes: disabled ? .disabled : []
          ) { [weak self] _ in
            self?.onMenuAction?(spec.action.rawValue)
          }
        }
      return UIMenu(children: children)
    }
  }

  /// 无预览：页面本身已是大图（同 TiebaPhotoContextMenuView previewEnabled=false
  /// 的分支）；返回 nil 让系统把菜单直接弹在长按位置。
  /// ⚠️ iOS 16 起旧名 previewForHighlightingMenuWithConfiguration 已废弃并
  /// 换成 configuration:highlightPreview… 形态（UIContextMenuInteraction.h:123/
  /// 132/167/179）：只实现旧名会静默不生效（连带 TiebaPhotoContextMenuView.swift
  /// :112-118 的同名旧实现同样没被系统调用，属既有隐患）。
  func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    configuration: UIContextMenuConfiguration,
    highlightPreviewForItemWithIdentifier identifier: any NSCopying
  ) -> UITargetedPreview? {
    nil
  }

  func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    configuration: UIContextMenuConfiguration,
    dismissalPreviewForItemWithIdentifier identifier: any NSCopying
  ) -> UITargetedPreview? {
    nil
  }
}
