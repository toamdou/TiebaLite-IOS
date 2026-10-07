// 从 TiebaPostRowView.swift 拆出（H10 千行文件拆分）：主类之前的独立类型（纯搬运，整类型逐字搬走）。
// 主类留在原文件：它自己的扩展要用到类内 private，同文件才合法。

import AVFoundation
import AVKit
import UIKit
import Nuke
import NukeExtensions

// MARK: - 事件

enum TiebaPostRowEvent: Sendable {
  case avatar
  case agree
  case toggleSeeLz
  /// 排序档位选择（药丸弹菜单，直接选热门/正序/倒序，不再循环）。
  case selectSort(TiebaThreadSort)
  case copyContent
  case share
  case copyLink
  case delete
  case subPosts
  case image(index: Int, rect: CGRect)
  case link(String)
  case user(String)
}

// MARK: - 媒体互斥 / 离屏暂停（原 mediaBusStore 的原生等价）

@MainActor
final class TiebaThreadMediaCoordinator {
  static let shared = TiebaThreadMediaCoordinator()

  private var activeKey: String?
  private var visibleKeys: Set<String>?
  private var pauseHandlers: [String: () -> Void] = [:]
  private var resumeHandlers: [String: () -> Void] = [:]

  private init() {}

  func register(
    key: String,
    pause: @escaping () -> Void,
    resume: (() -> Void)? = nil
  ) {
    pauseHandlers[key] = pause
    if let resume { resumeHandlers[key] = resume }
    // 可见性已上报过后才注册的媒体（行复用时才 configure）：不在可视集就先暂停。
    if let visibleKeys, !visibleKeys.contains(key) { pause() }
  }

  func unregister(key: String) {
    pauseHandlers.removeValue(forKey: key)
    resumeHandlers.removeValue(forKey: key)
    if activeKey == key { activeKey = nil }
  }

  /// 抢占总线（后激活者胜）；旧的 active 立即暂停。
  func activate(key: String) {
    let previous = activeKey
    activeKey = key
    if let previous, previous != key {
      pauseHandlers[previous]?()
    }
  }

  func deactivate(key: String) {
    if activeKey == key { activeKey = nil }
  }

  /// 列表层上报可视媒体 key；null = 未接入可见性（视为全部可见）。
  func setVisibleKeys(_ keys: Set<String>?) {
    visibleKeys = keys
    guard let keys else { return }
    for (key, pause) in pauseHandlers where !keys.contains(key) {
      pause()
    }
    for (key, resume) in resumeHandlers where keys.contains(key) {
      resume()
    }
  }

  /// 自动起播前查可见性：预取/复用的行可能已经上报过可视集且不在其中。
  func isVisible(key: String) -> Bool {
    guard let visibleKeys else { return true }
    return visibleKeys.contains(key)
  }
}

// MARK: - 图片加载（Nuke；options 组装统一走 TiebaNuke.options）

@MainActor
func tiebaPostLoadImage(
  _ url: URL?,
  maxPixel: CGFloat,
  into imageView: UIImageView,
  transition: Bool = false
) {
  guard let url else {
    imageView.image = nil
    return
  }
  loadImage(
    with: TiebaNuke.secureURL(url),
    options: TiebaNuke.options(maxPixel: maxPixel, transition: transition),
    into: imageView
  )
}

/// 显示档取图（aspectFill 视图专用）：位图 = 视图尺寸下的裁切结果，圆角也烘焙在
/// 像素里，所以视图侧不需要 clipsToBounds（省掉每帧一次离屏合成），也不会把长图
/// 解成远超显示尺寸的位图。视图必须已经摆好最终 frame（尺寸即入参来源）。
@MainActor
func tiebaPostLoadDisplayImage(
  _ url: URL?,
  targetSize: CGSize,
  cornerRadius: CGFloat,
  scale: CGFloat,
  into imageView: UIImageView,
  transition: Bool = false
) {
  guard let url, targetSize.width > 1, targetSize.height > 1 else {
    imageView.image = nil
    return
  }
  loadImage(
    with: TiebaNuke.secureURL(url),
    options: TiebaNuke.options(
      processor: TiebaNuke.displayProcessor(
        targetSize: targetSize,
        cornerRadius: cornerRadius,
        scale: scale
      ),
      transition: transition
    ),
    into: imageView
  )
}

/// 单图 fit 显示档（aspectFit 视图专用）：fit 缩放 + 圆角烘焙进位图（见
/// TiebaNuke.fitDisplayProcessor），视图侧不再 clipsToBounds。
@MainActor
func tiebaLoadFitDisplayImage(
  _ url: URL?,
  targetSize: CGSize,
  cornerRadius: CGFloat,
  scale: CGFloat,
  into imageView: UIImageView,
  transition: Bool = false
) {
  guard let url, targetSize.width > 1, targetSize.height > 1 else {
    imageView.image = nil
    return
  }
  loadImage(
    with: TiebaNuke.secureURL(url),
    options: TiebaNuke.options(
      processor: TiebaNuke.fitDisplayProcessor(
        targetSize: targetSize,
        cornerRadius: cornerRadius,
        scale: scale
      ),
      transition: transition
    ),
    into: imageView
  )
}

/// 在途 GIF 请求按**视图身份**登记（P2-5）：不登记就没法取消 —— 复用/换行后请求照跑，
/// 一个 GIF 的下载 + 多帧解码全白做，迟到回调还会去动已经换行的视图。
/// 只登记 Nuke 的 ImageTask（不持有视图，key 是 ObjectIdentifier）；token 用来判断
/// "这一格现在登记的还算不算自己"，避免新请求把旧请求的清理误删。
@MainActor private var tiebaGifLoads: [ObjectIdentifier: (token: UInt64, task: ImageTask)] = [:]
@MainActor private var tiebaGifLoadToken: UInt64 = 0

/// 取消该视图在途的 GIF 请求（复用/换行时调；没有在途请求就是空操作）。
@MainActor
func tiebaCancelGifLoad(_ view: TiebaGIFImageView) {
  tiebaGifLoads.removeValue(forKey: ObjectIdentifier(view))?.task.cancel()
}

/// GIF 播放档（Gifu 逐帧渲染）。GIF 请求必须无处理器：Resize/圆角烘焙都会把
/// 多帧重绘压成首帧（TiebaPhotoBrowser 文件头同结论）。数据源是 Nuke 默认解码器
/// 挂在 container.data 的原始 GIF 字节；到位后先落首帧静态底再异步起帧。
/// 帧按 targetSize×contentMode 重采样（Gifu shouldResizeFrames），缓冲窗
/// frameBufferSize 控内存；targetSize 未布局（≤1pt）时退全尺寸帧。
/// isStale 由调用方持行级身份判断（复用/换行后迟到的 GIF 不回贴）。
@MainActor
func tiebaLoadGifImage(
  _ url: URL,
  targetSize: CGSize,
  contentMode: UIView.ContentMode,
  frameBufferSize: Int,
  into view: TiebaGIFImageView,
  isStale: @escaping @MainActor () -> Bool
) {
  // 换图前释放上一个 GIF 的帧缓冲：play() 内部也会先 recycle()，这里显式再调一次
  // 是为了**换图失败/被取消**的路径也不会留下上一个 GIF 的帧（早退分支不走 play）。
  view.prepareForGIFReuse()
  view.clipsToBounds = true
  let key = ObjectIdentifier(view)
  tiebaGifLoadToken &+= 1
  let token = tiebaGifLoadToken
  // 同一格重复 load 先取消旧请求（与 tiebaLoadRowImage 的 cancelRequest 同纪律：
  // 取消的是 ImageTask 本身，下载/解码真的停，不只是不再 await）。
  tiebaGifLoads[key]?.task.cancel()
  // imageTask.response 给出完整 ImageResponse（container 里才有 GIF 原始字节）；
  // image(for:) 只回已解码的首帧位图。
  //
  // 优先级按"这一格现在在不在屏幕上"分档：UICollectionView 的预取趟会先把屏幕外的
  // cell 建出来（cellForItemAt → apply → layoutImages），它们也会来抢动图档；一帖 25 张
  // 动图合计 51MB（实测），屏幕外那些若按 normal 排队，屏幕上这几张就得排在它们后面
  //（表现："先划到的先播、后划到的迟迟不动"）。低优先级不会被丢，Nuke 只是把它排在后面 ——
  // 划到它时仍在队列里，只是晚一点。
  var request = ImageRequest(url: TiebaNuke.secureURL(url))
  request.priority = view.tiebaIsVisibleInWindow ? .normal : .low
  let imageTask = TiebaNuke.pipeline.imageTask(with: request)
  tiebaGifLoads[key] = (token, imageTask)
  Task { [weak view] in
    defer { if tiebaGifLoads[key]?.token == token { tiebaGifLoads[key] = nil } }
    guard
      let response = try? await imageTask.response,
      let view, !isStale()
    else { return }
    view.image = response.container.image
    guard let data = response.container.data else { return }
    // 首帧静态底已经赋值（上面一行），把它**当第 0 帧交给播放器**：否则播放器会为了
    // 第 0 帧再解一遍（实测 83 帧 / 2.83MB 的真实 GIF：首帧解码+重采样 4~45ms，白做），
    // 而那笔开销原来正好落在主线程上。查看器那条路径早就是这么做的（R3-3）。
    view.gifPlayer.play(
      data: data,
      into: view,
      targetSize: targetSize,
      contentMode: contentMode,
      frameBufferSize: frameBufferSize,
      firstFrame: view.image
    )
  }
}

//
// 行视图不自己实现头像：直接复用 TiebaForumViews 的 TiebaForumAvatarView
// （首字占位 + Nuke 取图）。它是 init 定尺视图（主贴 40 / 回复 36），尺寸变化
// 时由 configureAvatar 重建。

// MARK: - 视频块（poster → 点击后内嵌 AVPlayerViewController，系统控制条）

final class TiebaInlineVideoView: UIView {
  private let posterView = UIImageView()
  private let playIcon = UIImageView()
  /// 首帧未就绪时的缓冲反馈（上游 MediaPlayer 的 buffering 指示）。
  /// 只覆盖"海报还盖着播放器"这一段：首帧出来后由 AVKit 自己的控制条负责卡顿反馈。
  private let waitSpinner = UIActivityIndicatorView(style: .medium)
  private let badgeView = UIView()
  private let badgeLabel = UILabel()

  private var video: TiebaThreadVideo?
  private var player: AVPlayer?
  private var playerController: AVPlayerViewController?
  // nonisolated(unsafe)：deinit 是 nonisolated，Swift 6 禁止它读非 Sendable 状态；该值只在主线程读写。
  private nonisolated(unsafe) var endObserver: NSObjectProtocol?
  /// 首帧就绪观察（AVPlayerItem.status）：海报盖到首帧可显示为止。
  private var statusObservation: NSKeyValueObservation?
  private var autoplay = false
  private(set) var isPlaying = false
  private var userStarted = false
  private var isVisible = true
  private var mediaKey = ""

  override init(frame: CGRect) {
    super.init(frame: frame)
    clipsToBounds = true
    layer.cornerCurve = .continuous
    posterView.contentMode = .scaleAspectFill
    posterView.clipsToBounds = true
    addSubview(posterView)
    playIcon.image = UIImage(
      systemName: "play.circle.fill",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 44, weight: .regular)
    )
    playIcon.tintColor = UIColor.white.withAlphaComponent(0.9)
    addSubview(playIcon)
    waitSpinner.color = .white
    waitSpinner.hidesWhenStopped = true
    addSubview(waitSpinner)
    badgeView.backgroundColor = UIColor.black.withAlphaComponent(0.5)
    badgeView.layer.cornerRadius = 8
    badgeView.layer.cornerCurve = .continuous
    addSubview(badgeView)
    badgeLabel.text = "视频"
    badgeLabel.font = TiebaSimpleText.font(size: 10, weight: .medium)
    badgeLabel.textColor = .white
    badgeView.addSubview(badgeLabel)
    addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap)))
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  deinit {
    if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
  }

  func configure(video: TiebaThreadVideo, preferences: TiebaPostPreferences) {
    // 点赞等原地重发布会用同一模型重配：同一条视频播放中则保持播放（不重挂海报）。
    if mediaKey == "v:\(video.src)", isPlaying {
      self.video = video
      return
    }
    self.video = video
    self.autoplay = preferences.videoAutoplay
    mediaKey = "v:\(video.src)"
    posterView.alpha = 1
    posterView.isHidden = false
    playIcon.isHidden = false
    badgeView.isHidden = false
    tiebaPostLoadImage(
      TiebaPhotoItem.normalizedURL(video.poster),
      maxPixel: max(bounds.width, 320) * max(traitCollection.displayScale, 1),
      into: posterView
    )
    TiebaThreadMediaCoordinator.shared.register(
      key: mediaKey,
      pause: { [weak self] in self?.pause() },
      resume: { [weak self] in self?.resumeIfNeeded() }
    )
    setNeedsLayout()
    // 预取/复用的行可能已在屏外（可视集已上报）：屏外不起播，否则播放器常驻。
    if autoplay, TiebaThreadMediaCoordinator.shared.isVisible(key: mediaKey) {
      startPlayback()
    }
  }

  func applyPalette(_ palette: TiebaFeedRowPalette) {
    layer.cornerRadius = TiebaPostRowLayout.imageRadius
    backgroundColor = palette.placeholder
  }

  func prepareForReuse() {
    if !mediaKey.isEmpty {
      TiebaThreadMediaCoordinator.shared.unregister(key: mediaKey)
    }
    teardownPlayer()
    mediaKey = ""
    video = nil
    posterView.image = nil
    userStarted = false
    isVisible = true
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    posterView.frame = bounds
    let side: CGFloat = 44
    playIcon.frame = CGRect(
      x: (bounds.width - side) / 2,
      y: (bounds.height - side) / 2,
      width: side,
      height: side
    )
    waitSpinner.center = CGPoint(x: bounds.midX, y: bounds.midY)
    let badgeW: CGFloat = 42, badgeH: CGFloat = 18
    badgeView.frame = CGRect(x: 8, y: bounds.height - badgeH - 8, width: badgeW, height: badgeH)
    badgeLabel.frame = badgeView.bounds.insetBy(dx: 8, dy: 2)
    // 只在播放器视图仍挂在本行时才跟行大小：AVKit 进全屏会把播放器内容挪进新的全屏 VC
    //（AVPlayerViewController.h:403：its content will be presented in a new full screen
    // view controller and perhaps in a new window），由它自己管 frame。
    // 这里若无条件写 frame，转场期间会把全屏播放器压回行内尺寸 —— 表现就是「点全屏按钮没反应」。
    if let controllerView = playerController?.view, controllerView.superview === self {
      controllerView.frame = bounds
    }
  }

  /// AVKit 进出全屏时会把播放器视图在「本行 ↔ 全屏容器」之间搬：搬回来那一下不会再触发布局，
  /// 必须在这里把 frame 收回行内（否则行内会留一个全屏尺寸的播放器视图），
  /// 顺带补做「在全屏里播完」的收尾（见 handlePlaybackEnded）。
  override func didAddSubview(_ subview: UIView) {
    super.didAddSubview(subview)
    guard subview === playerController?.view else { return }
    subview.frame = bounds
    if !isPlaying, player != nil {
      DispatchQueue.main.async { [weak self] in self?.finishPlayback() }
    }
  }

  @objc private func handleTap() {
    TiebaSceneHaptics.fire("press")
    userStarted = true
    startPlayback()
  }

  private func startPlayback() {
    guard !isPlaying, let video else { return }
    guard let url = URL(string: video.src), !video.src.isEmpty else { return }
    isPlaying = true
    // 首帧策略（上游 MediaPlayer：缩略图一直盖到首帧就绪）：海报先**不**藏，改压到播放器视图之上，
    // 等 item readyToPlay 再淡出 —— 否则从点击到首帧之间是一块黑。
    posterView.alpha = 1
    posterView.isHidden = false
    playIcon.isHidden = true
    badgeView.isHidden = true
    // 缓冲反馈照上游的阈值走（ChunkMediaPlayerV2:709-722：缓冲超过 0.3s 才亮指示）：
    // 首帧快时不该闪一个转圈；到点仍未出画才显示（届时海报还盖着播放器）。
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
      guard let self, self.isPlaying, !self.posterView.isHidden else { return }
      self.waitSpinner.startAnimating()
    }
    let item = AVPlayerItem(url: url)
    item.preferredForwardBufferDuration = 5
    let player = AVPlayer(playerItem: item)
    player.isMuted = true
    player.actionAtItemEnd = .pause
    self.player = player
    endObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: item,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.handlePlaybackEnded() }
    }
    let controller = AVPlayerViewController()
    controller.player = player
    controller.showsPlaybackControls = true
    controller.view.backgroundColor = .black
    if let host = TiebaViewHosts.viewController(for: self) {
      host.addChild(controller)
      controller.view.frame = bounds
      controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      addSubview(controller.view)
      // 海报压到播放器之上：未出画时挡住播放器视图（AVKit 控制条在首帧后才需要可见）。
      bringSubviewToFront(posterView)
      bringSubviewToFront(waitSpinner)
      controller.didMove(toParent: host)
      playerController = controller
    }
    observeFirstFrame(item)
    TiebaThreadMediaCoordinator.shared.activate(key: mediaKey)
    player.play()
  }

  // MARK: 首帧 / 封面

  /// 观察 AVPlayerItem.status：readyToPlay → 淡出海报露出首帧；failed → 退回封面态（可再点一次重试）。
  /// KVO 回调不在主线程语义里，统一 Task 回主 actor（同本文件既有的 endObserver 写法）。
  private func observeFirstFrame(_ item: AVPlayerItem) {
    statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
      let status = item.status
      Task { @MainActor in
        guard let self else { return }
        switch status {
        case .readyToPlay: self.revealFirstFrame()
        case .failed: self.handleLoadFailed()
        default: break
        }
      }
    }
  }

  private func revealFirstFrame() {
    guard isPlaying, !posterView.isHidden else { return }
    waitSpinner.stopAnimating()
    UIView.animate(withDuration: 0.15, animations: {
      self.posterView.alpha = 0
    }, completion: { _ in
      guard self.isPlaying else { return }
      self.posterView.isHidden = true
      self.posterView.alpha = 1
    })
  }

  /// 载入失败：回到封面 + 播放键（就地可操作：再点一次即重试），不弹通知。
  private func handleLoadFailed() {
    guard isPlaying else { return }
    isPlaying = false
    teardownPlayer()
    posterView.isHidden = false
    posterView.alpha = 1
    playIcon.isHidden = false
    badgeView.isHidden = false
    TiebaThreadMediaCoordinator.shared.deactivate(key: mediaKey)
  }

  /// 行重配后不再显示视频时调用（隐藏不等于暂停）。
  func stopPlayback() {
    pause()
  }

  private func pause() {
    guard isPlaying else { return }
    player?.pause()
    isPlaying = false
    teardownPlayer()
  }

  private func resumeIfNeeded() {
    guard autoplay, !userStarted, player == nil else { return }
    startPlayback()
  }

  private func handlePlaybackEnded() {
    isPlaying = false
    // 在全屏里播完：先别 teardown —— 那会把播放器视图从全屏 window 里抽走，用户看到全屏突然空掉。
    // 留着播放器让 AVKit 显示「重播」，等视图被放回行内时再由 didAddSubview 收尾。
    if let controllerView = playerController?.view, controllerView.superview !== self {
      TiebaThreadMediaCoordinator.shared.deactivate(key: mediaKey)
      return
    }
    finishPlayback()
  }

  /// 播放结束的收尾（行内）：海报 + 播放键复位、播放器释放。
  private func finishPlayback() {
    teardownPlayer()
    posterView.alpha = 1
    posterView.isHidden = false
    playIcon.isHidden = false
    badgeView.isHidden = false
    TiebaThreadMediaCoordinator.shared.deactivate(key: mediaKey)
  }

  private func teardownPlayer() {
    waitSpinner.stopAnimating()
    statusObservation?.invalidate()
    statusObservation = nil
    if let endObserver {
      NotificationCenter.default.removeObserver(endObserver)
      self.endObserver = nil
    }
    player?.pause()
    playerController?.willMove(toParent: nil)
    playerController?.view.removeFromSuperview()
    playerController?.removeFromParent()
    playerController = nil
    player = nil
  }
}

// MARK: - 语音条（AVPlayer + 静态波形 + 倍速 + 长按下载）

final class TiebaAudioPillView: UIView {
  private let actionButton = UIButton(type: .system)
  private let playIcon = UIImageView()
  private let waveform = TiebaAudioWaveformBarView()
  private let timeLabel = UILabel()
  private let rateButton = UIButton(type: .system)

  private var src = ""
  private var fallbackDuration = 0.0
  private var player: AVPlayer?
  // nonisolated(unsafe)：deinit 是 nonisolated，Swift 6 禁止它读非 Sendable 状态；两者只在主线程读写。
  private nonisolated(unsafe) var timeObserver: Any?
  private nonisolated(unsafe) var endObserver: NSObjectProtocol?
  private var rate = 1.0
  private(set) var isActive = false
  private var mediaKey = ""

  // 拖动定位（下滑精调）：移植自上游 AudioWaveformComponent.swift:262-301。
  /// 拖动起点（本视图坐标）、起点处进度、横向灵敏度倍率。
  private var scrubStart: CGPoint?
  private var scrubBaseProgress: Double = 0
  private var scrubMultiplier: Double = 1
  /// 拖动期间冻结 periodicTimeObserver 的进度回写（否则每 0.5s 把手指拖到的位置顶回去）。
  private var isScrubbing = false

  override init(frame: CGRect) {
    super.init(frame: frame)
    layer.cornerRadius = 10
    layer.cornerCurve = .continuous
    layer.borderWidth = 1
    // 播放/暂停与下载合并到一个铺满的 UIButton：点按走 touchUpInside，长按弹
    // UIMenu（系统菜单，不再自绘手势 + 确认弹窗）。
    actionButton.addTarget(self, action: #selector(handleTap), for: .touchUpInside)
    actionButton.menu = UIMenu(children: [
      UIAction(
        title: "下载音频",
        image: UIImage(systemName: "square.and.arrow.down")
      ) { [weak self] _ in
        self?.download()
      },
    ])
    addSubview(actionButton)
    playIcon.contentMode = .scaleAspectFit
    addSubview(playIcon)
    addSubview(waveform)
    // 手势挂在整条上（波形与播放键都算进度带）；cancelsTouchesInView 保持默认 true，
    // 于是"横向拖动"一旦成立就会取消按钮的 touchUpInside，不会拖完又顺手切播放态。
    let scrub = UIPanGestureRecognizer(target: self, action: #selector(handleScrub(_:)))
    scrub.delegate = self
    addGestureRecognizer(scrub)
    timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    addSubview(timeLabel)
    rateButton.titleLabel?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
    rateButton.layer.cornerRadius = 8
    rateButton.layer.cornerCurve = .continuous
    rateButton.clipsToBounds = true
    // 点按直接展开倍速菜单（1x / 1.5x），不再手写 1↔1.5 循环。
    rateButton.showsMenuAsPrimaryAction = true
    addSubview(rateButton)
    updateRate()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  deinit {
    if let timeObserver { player?.removeTimeObserver(timeObserver) }
    if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
  }

  func configure(src: String, duration: Double, palette: TiebaFeedRowPalette) {
    // 同一条语音播放中：只更新配色，不复位进度（原地重发布不打断播放）。
    if self.src == src, mediaKey == "a:\(src)", isActive {
      fallbackDuration = duration
      applyPalette(palette)
      return
    }
    self.src = src
    fallbackDuration = duration
    mediaKey = "a:\(src)"
    applyPalette(palette)
    update(time: 0, duration: duration)
    TiebaThreadMediaCoordinator.shared.register(
      key: mediaKey,
      pause: { [weak self] in self?.pause() }
    )
    TiebaAudioSession.register(
      id: mediaKey,
      isPlaying: { [weak self] in self?.isActive ?? false },
      pause: { [weak self] in self?.pause() },
      resume: { [weak self] in self?.play() }
    )
    setNeedsLayout()
  }

  func applyPalette(_ palette: TiebaFeedRowPalette) {
    backgroundColor = palette.chip
    layer.borderColor = palette.separator.cgColor
    playIcon.tintColor = palette.primary
    waveform.activeColor = palette.primary
    waveform.inactiveColor = palette.textSecondary
    timeLabel.textColor = palette.textSecondary
    rateButton.setTitleColor(palette.textSecondary, for: .normal)
    rateButton.backgroundColor = .systemFill
    updatePlayIcon(playing: isActive)
  }

  func prepareForReuse() {
    if !mediaKey.isEmpty { TiebaThreadMediaCoordinator.shared.unregister(key: mediaKey) }
    TiebaAudioSession.unregister(id: mediaKey)
    teardown()
    src = ""
    mediaKey = ""
    isActive = false
    rate = 1
    scrubStart = nil
    scrubMultiplier = 1
    isScrubbing = false
    updateRate()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    actionButton.frame = bounds
    playIcon.frame = CGRect(x: 10, y: (bounds.height - 28) / 2, width: 28, height: 28)
    let rateW: CGFloat = isActive ? 34 : 0
    timeLabel.sizeToFit()
    let timeW = timeLabel.bounds.width
    timeLabel.frame = CGRect(
      x: bounds.width - 10 - timeW,
      y: (bounds.height - timeLabel.bounds.height) / 2,
      width: timeW,
      height: timeLabel.bounds.height
    )
    rateButton.frame = CGRect(
      x: bounds.width - 10 - timeW - 8 - rateW,
      y: (bounds.height - 22) / 2,
      width: rateW,
      height: 22
    )
    let waveX = playIcon.frame.maxX + 10
    let waveRight = (isActive ? rateButton.frame.minX : timeLabel.frame.minX) - 10
    waveform.frame = CGRect(x: waveX, y: 10, width: max(waveRight - waveX, 0), height: bounds.height - 20)
    waveform.isHidden = waveform.frame.width < 24
    rateButton.isHidden = !isActive
  }

  @objc private func handleTap() {
    TiebaSceneHaptics.fire("toggle")
    if isActive {
      pause()
    } else {
      play()
    }
  }

  // MARK: - 拖动定位（下滑精调）

  /// 横向拖 = 定位到某一秒；**手指往下偏一点，横向灵敏度就成倍降低**（1 → 0.5 → 0.25 → 0.01），
  /// 于是"粗调到位 → 下滑 → 微调"能在 4 分钟音频上对准秒。倍率一变就把当前 x 设为新起点，
  /// 从这一刻起按新倍率累积（移植自上游 AudioWaveformComponent.swift:274-291）。
  @objc private func handleScrub(_ recognizer: UIPanGestureRecognizer) {
    let location = recognizer.location(in: self)
    switch recognizer.state {
    case .began:
      scrubStart = location
      scrubBaseProgress = waveform.progress
      scrubMultiplier = 1
      isScrubbing = true
    case .changed:
      guard let start = scrubStart else { return }
      var multiplier: Double = 1
      var skipUpdate = false
      if location.y > start.y {
        let verticalDelta = abs(location.y - start.y)
        if verticalDelta > 150 {
          multiplier = 0.01
        } else if verticalDelta > 100 {
          multiplier = 0.25
        } else if verticalDelta > 50 {
          multiplier = 0.5
        }
        if multiplier != scrubMultiplier {
          skipUpdate = true
          scrubMultiplier = multiplier
          scrubBaseProgress = waveform.progress
          scrubStart = CGPoint(x: location.x, y: start.y)
          // 换挡给一次触觉：手指不看也知道"现在进入精调了"。
          TiebaSceneHaptics.fire("toggle")
        }
      }
      if !skipUpdate {
        applyScrub(deltaX: location.x - start.x, multiplier: multiplier)
      }
    case .ended, .cancelled:
      guard let start = scrubStart else { return }
      scrubStart = nil
      if recognizer.state == .ended {
        applyScrub(deltaX: location.x - start.x, multiplier: scrubMultiplier)
        commitScrub()
      } else {
        // 被系统打断（来电/转场等）：进度显示退回播放器真实位置，别把预览留在半路。
        resyncProgress()
      }
      isScrubbing = false
      scrubMultiplier = 1
    default:
      break
    }
  }

  /// 把累计的「横向位移 ÷ 波形宽 × 倍率」写进进度（上游 :295-301 的同式）。
  private func applyScrub(deltaX: CGFloat, multiplier: Double) {
    let width = max(waveform.bounds.width, 1)
    let fraction = min(max(scrubBaseProgress + Double(deltaX / width * CGFloat(multiplier)), 0), 1)
    let total = player?.currentItem?.duration.isNumeric == true
      ? (player?.currentItem?.duration.seconds ?? fallbackDuration)
      : fallbackDuration
    guard total > 0 else { return }
    update(time: fraction * total, duration: total)
  }

  /// 拖动被打断时把进度显示退回播放器真实位置。
  private func resyncProgress() {
    guard let player, let item = player.currentItem else { return }
    let total = item.duration.isNumeric ? item.duration.seconds : fallbackDuration
    guard total > 0 else { return }
    update(time: player.currentTime().seconds, duration: total)
  }

  /// 抬手落点：没播过也能定位（先建播放器再 seek）。
  private func commitScrub() {
    guard !src.isEmpty, let url = URL(string: src) else { return }
    ensurePlayer(url: url)
    guard let player else { return }
    let total = player.currentItem?.duration.isNumeric == true
      ? (player.currentItem?.duration.seconds ?? fallbackDuration)
      : fallbackDuration
    guard total > 0 else { return }
    player.seek(to: CMTime(seconds: waveform.progress * total, preferredTimescale: 600))
  }

  /// 倍速落点（1x / 1.5x）+ 菜单勾选态刷新。
  private func updateRate() {
    rateButton.setTitle(rate == 1 ? "1x" : "1.5x", for: .normal)
    rateButton.menu = UIMenu(
      title: "播放速度",
      options: .singleSelection,
      children: [
        UIAction(title: "1x", state: rate == 1 ? .on : .off) { [weak self] _ in self?.setRate(1) },
        UIAction(title: "1.5x", state: rate == 1.5 ? .on : .off) { [weak self] _ in self?.setRate(1.5) },
      ]
    )
  }

  private func setRate(_ value: Double) {
    guard rate != value else { return }
    TiebaSceneHaptics.fire("toggle")
    rate = value
    updateRate()
    if isActive { player?.rate = Float(rate) }
    setNeedsLayout()
  }

  /// 建播放器与两个观察者：首次播放、或首次拖动定位（没播过也能拖到某一秒）都会走这里。
  private func ensurePlayer(url: URL) {
    guard player == nil else { return }
    let player = AVPlayer(url: url)
    self.player = player
    timeObserver = player.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
      queue: .main
    ) { [weak self] time in
      Task { @MainActor in
        guard let self, let item = self.player?.currentItem, !self.isScrubbing else { return }
        let total = item.duration.isNumeric ? item.duration.seconds : self.fallbackDuration
        self.update(time: time.seconds, duration: total)
      }
    }
    endObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: player.currentItem,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.handleEnded() }
    }
  }

  private func play() {
    guard !src.isEmpty, let url = URL(string: src) else { return }
    ensurePlayer(url: url)
    TiebaAudioSession.activate()
    player?.playImmediately(atRate: Float(rate))
    isActive = true
    updatePlayIcon(playing: true)
    TiebaThreadMediaCoordinator.shared.activate(key: mediaKey)
    setNeedsLayout()
  }

  /// 行重配后不再显示语音时调用（隐藏不等于暂停）。
  func stopPlayback() {
    pause()
  }

  private func pause() {
    player?.pause()
    isActive = false
    updatePlayIcon(playing: false)
    TiebaThreadMediaCoordinator.shared.deactivate(key: mediaKey)
    TiebaAudioSession.deactivateIfIdle()
    setNeedsLayout()
  }

  private func handleEnded() {
    player?.seek(to: .zero)
    pause()
    update(time: 0, duration: fallbackDuration)
  }

  private func teardown() {
    if let timeObserver {
      player?.removeTimeObserver(timeObserver)
      self.timeObserver = nil
    }
    if let endObserver {
      NotificationCenter.default.removeObserver(endObserver)
      self.endObserver = nil
    }
    player?.pause()
    player = nil
  }

  private func updatePlayIcon(playing: Bool) {
    playIcon.image = UIImage(
      systemName: playing ? "pause.circle.fill" : "play.circle.fill",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 28, weight: .regular)
    )
    // 无障碍落在真正可点的 actionButton 上（容器不再是 a11y 元素）。
    actionButton.accessibilityLabel = playing ? "暂停音频" : "播放音频"
  }

  private func update(time: Double, duration: Double) {
    let total = duration > 0 ? duration : fallbackDuration
    waveform.progress = total > 0 ? min(max(time / total, 0), 1) : 0
    timeLabel.text = "\(TiebaAudioPillView.format(time)) / \(TiebaAudioPillView.format(total))"
    setNeedsLayout()
  }

  private func download() {
    guard let url = URL(string: src) else { return }
    Task { @MainActor in
      do {
        let (data, _) = try await URLSession.shared.data(from: url)
        let temp = FileManager.default.temporaryDirectory
          .appendingPathComponent("tieba-audio-\(UUID().uuidString).mp3")
        try data.write(to: temp, options: .atomic)
        guard let presenter = TiebaViewHosts.viewController(for: self) else { return }
        TiebaShareSheet.present(
          fileURL: temp,
          dialogTitle: "保存音频",
          from: presenter,
          sourceRect: convert(bounds, to: presenter.view)
        )
      }
      catch {
        TiebaSceneHaptics.fire("action-fail")
      }
    }
  }

  static func format(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded(.down)))
    return "\(total / 60):\(String(format: "%02d", total % 60))"
  }
}

// MARK: - 拖动定位的准入（下滑精调）

extension TiebaAudioPillView: UIGestureRecognizerDelegate {
  /// 只认横向拖动：竖向留给列表滚动（否则在列表里从语音条起手就滚不动列表）。
  /// override：UIView 自己就有这个方法（给挂在它身上的手势用），不是纯协议实现。
  ///
  /// [按上游改判据] 改前判**速度比大小** `|vx| > |vy|`（1:1）—— 斜着拖（比如 50°）也满足，
  /// 于是"想滚列表却在语音条上起手"会被语音条抢走。
  /// 改后照抄上游 DirectionalPanGestureRecognizer.swift:55-69 的**方向锁定**判据：
  ///   · 交叉轴 `|y| > 4.0 且 |y| > 2|x|` → 失败（这是竖向滚，别抢）；
  ///   · 主轴 `|x| > 2.0 且 2|y| < |x|` → 成立（这是横向拖，接管）。
  /// 关键差别是**比例从 1:1 收紧到 2:1**：45° 附近上下不确定时宁可失败。
  /// 手感变化：语音条的拖动定位**更"专一"** —— 只有横向意图明显时才吃手势，
  /// 斜向拖动回到列表滚动。（UIKit 的 pan 起判本身带 ~10pt 死区，所以这两个 2/4pt
  /// 下界在 shouldBegin 里恒满足，真正生效的是那条 2:1 比例 —— 行为与上游同向。）
  override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
    let translation = pan.translation(in: self)
    let absX = abs(translation.x)
    let absY = abs(translation.y)
    let axis = TiebaMotionSpec.Gesture.directionLockAxisThreshold
    let cross = TiebaMotionSpec.Gesture.directionLockCrossThreshold
    if absY > cross, absY > absX * 2.0 { return false }
    return absX > axis && absY * 2.0 < absX
  }

  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
  ) -> Bool {
    return true
  }
}

/// 15 根柱（原 AudioSegment.tsx 的 AUDIO_WAVEFORM_BARS 同值），按进度着色。
/// 渲染算法移植自上游 submodules/AudioWaveformNode/Sources/AudioWaveformNode.swift:121-232。
final class TiebaAudioWaveformBarView: UIView {
  /// 兜底波形：没有样本、或样本是坏数据时画它，而不是留空。上游 :162-170 生成**随机**
  /// 假样本；本仓改用固定 15 根手工柱，保证同一个波形宽度下观感稳定（也正是原有外观）。
  static let fallbackHeights: [CGFloat] = [12, 18, 8, 22, 14, 20, 10, 24, 16, 6, 19, 13, 21, 9, 17]

  var activeColor: UIColor = .systemBlue { didSet { setNeedsDisplay() } }
  var inactiveColor: UIColor = .secondaryLabel { didSet { setNeedsDisplay() } }
  var progress: Double = 0 { didSet { setNeedsDisplay() } }
  override init(frame: CGRect) {
    super.init(frame: frame)
    isOpaque = false
    backgroundColor = .clear
    // 保持不吃触摸：拖动定位的手势挂在**整个语音条**上（见 TiebaAudioPillView），
    // 波形这一段一旦 interactive，铺满的 actionButton 就收不到点击/长按了。
    isUserInteractionEnabled = false
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  /// 每根柱的高度：本仓恒用兜底表。
  /// 为什么没有"真实样本"这条路径（算法审查 §4 点名的 samples 从未赋值）：
  /// 贴吧接口只给语音的 src + duration，**没有波形字段**；唯一真实数据源是音频字节本身，
  /// 要 `AVAssetReader` 全量解码 —— 列表里每一行语音都解一遍 = 滚动掉帧。
  /// 按「不许造假数据」的要求，这里删掉了 samples/bucketPeaks/isDegenerate 那条从未被喂过数据的分支，
  /// 只保留固定 15 根柱（= 本仓一直以来的外观）。将来若接口下发波形，再从本注释处接回。
  private func resolvedHeights() -> [CGFloat] {
    Self.fallbackHeights
  }

  override func draw(_ rect: CGRect) {
    guard bounds.width > 0 else { return }
    let heights = resolvedHeights()
    let count = heights.count
    let gap: CGFloat = 2
    let barWidth = max((bounds.width - gap * CGFloat(count - 1)) / CGFloat(count), 1)
    let shown = Int((Double(count) * progress).rounded(.up))
    for (index, height) in heights.enumerated() {
      let x = CGFloat(index) * (barWidth + gap)
      let y = (bounds.height - height) / 2
      let color = index < shown ? activeColor : inactiveColor
      color.setFill()
      // 圆头柱 = 一个矩形 + 上下各一个圆（移植自上游 :211-225）：比
      // UIBezierPath(roundedRect:) 便宜得多，像素结果一样（圆角半径 = 半宽）。
      let radius = barWidth / 2
      let barHeight = max(height, barWidth)
      UIBezierPath(rect: CGRect(x: x, y: y + radius, width: barWidth, height: barHeight - barWidth)).fill()
      for centerY in [y + radius, y + barHeight - radius] {
        UIBezierPath(ovalIn: CGRect(x: x, y: centerY - radius, width: barWidth, height: barWidth)).fill()
      }
    }
  }
}


// MARK: - 媒体占位条（hideMedia / blockVideo）

final class TiebaPostPlaceholderView: UIView {
  private let iconView = UIImageView()
  private let label = UILabel()

  override init(frame: CGRect) {
    super.init(frame: frame)
    layer.cornerRadius = 10
    layer.cornerCurve = .continuous
    iconView.contentMode = .scaleAspectFit
    addSubview(iconView)
    // 帖内媒体占位条（"[图片]"/"[视频已屏蔽]"）：属于帖子卡片内容，走正文级。
    label.font = TiebaSimpleText.bodyFont(size: 13, weight: .regular)
    addSubview(label)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  func configure(icon: String, text: String, palette: TiebaFeedRowPalette) {
    backgroundColor = palette.chip
    layer.borderWidth = 1 / max(traitCollection.displayScale, 1)
    layer.borderColor = palette.separator.cgColor
    iconView.image = TiebaSymbols.image(icon, pointSize: 14, weight: .regular)
    iconView.tintColor = palette.textSecondary
    label.text = text
    label.textColor = palette.textSecondary
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    iconView.frame = CGRect(x: 10, y: (bounds.height - 16) / 2, width: 16, height: 16)
    label.sizeToFit()
    label.frame = CGRect(
      x: 32,
      y: (bounds.height - label.bounds.height) / 2,
      width: max(bounds.width - 42, 0),
      height: label.bounds.height
    )
  }
}

