// 从 TiebaPostRowInline.swift 拆出（按类型分文件，纯搬运、整类型逐字搬走）。

import AVFoundation
import AVKit
import UIKit

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
    let finish = { [weak self] in
      guard let self, self.isPlaying else { return }
      self.posterView.isHidden = true
      self.posterView.alpha = 1
    }
    guard UIAccessibility.isReduceMotionEnabled == false else {
      posterView.alpha = 0
      finish()
      return
    }
    // 纯淡入不接 CA 帧率提升（见 TiebaAnimationFrameRate 的省电判据），
    // 时长仍统一从 TiebaAnimationDuration 取。
    TiebaAnimation.animate(
      duration: TiebaAnimationDuration.fastFade,
      options: [.beginFromCurrentState, .allowUserInteraction]
    ) {
      self.posterView.alpha = 0
    } completion: { _ in
      finish()
    }
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
