// 帖子行视图（thread/[id] 原生页：主贴卡 + 回复卡）与其内嵌媒体。
//
// 行高由 TiebaPostRowMetrics 预先算好，本视图只按 model.plan 摆 frame（测多少画多少）。
// 交互自管（点赞/菜单/头像/楼中楼/图片），只把语义动作经 onEvent 外传；
// 视频/语音的互斥与离屏暂停由 TiebaThreadMediaCoordinator 收敛（原 mediaBusStore）。
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
  case toggleSort
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

// MARK: - 头像
//
// 行视图不自己实现头像：直接复用 TiebaForumViews 的 TiebaForumAvatarView
// （首字占位 + Nuke 取图）。它是 init 定尺视图（主贴 40 / 回复 36），尺寸变化
// 时由 configureAvatar 重建。

// MARK: - 视频块（poster → 点击后内嵌 AVPlayerViewController，系统控制条）

final class TiebaInlineVideoView: UIView {
  private let posterView = UIImageView()
  private let playIcon = UIImageView()
  private let badgeView = UIView()
  private let badgeLabel = UILabel()

  private var video: TiebaThreadVideo?
  private var player: AVPlayer?
  private var playerController: AVPlayerViewController?
  // nonisolated(unsafe)：deinit 是 nonisolated，Swift 6 禁止它读非 Sendable 状态；该值只在主线程读写。
  private nonisolated(unsafe) var endObserver: NSObjectProtocol?
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
    let badgeW: CGFloat = 42, badgeH: CGFloat = 18
    badgeView.frame = CGRect(x: 8, y: bounds.height - badgeH - 8, width: badgeW, height: badgeH)
    badgeLabel.frame = badgeView.bounds.insetBy(dx: 8, dy: 2)
    playerController?.view.frame = bounds
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
    posterView.isHidden = true
    playIcon.isHidden = true
    badgeView.isHidden = true
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
      controller.didMove(toParent: host)
      playerController = controller
    }
    TiebaThreadMediaCoordinator.shared.activate(key: mediaKey)
    player.play()
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
    teardownPlayer()
    posterView.isHidden = false
    playIcon.isHidden = false
    badgeView.isHidden = false
    TiebaThreadMediaCoordinator.shared.deactivate(key: mediaKey)
  }

  private func teardownPlayer() {
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

  private func play() {
    guard !src.isEmpty, let url = URL(string: src) else { return }
    if player == nil {
      let player = AVPlayer(url: url)
      self.player = player
      timeObserver = player.addPeriodicTimeObserver(
        forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
        queue: .main
      ) { [weak self] time in
        Task { @MainActor in
          guard let self, let item = self.player?.currentItem else { return }
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

/// 15 根静态柱（AudioSegment.tsx 的 AUDIO_WAVEFORM_BARS 同值），按进度着色。
final class TiebaAudioWaveformBarView: UIView {
  static let bars: [CGFloat] = [12, 18, 8, 22, 14, 20, 10, 24, 16, 6, 19, 13, 21, 9, 17]
  var activeColor: UIColor = .systemBlue { didSet { setNeedsDisplay() } }
  var inactiveColor: UIColor = .secondaryLabel { didSet { setNeedsDisplay() } }
  var progress: Double = 0 { didSet { setNeedsDisplay() } }

  override init(frame: CGRect) {
    super.init(frame: frame)
    isOpaque = false
    backgroundColor = .clear
    isUserInteractionEnabled = false
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  override func draw(_ rect: CGRect) {
    guard bounds.width > 0 else { return }
    let count = Self.bars.count
    let gap: CGFloat = 2
    let barWidth = max((bounds.width - gap * CGFloat(count - 1)) / CGFloat(count), 1)
    let shown = Int((Double(count) * progress).rounded(.up))
    for (index, height) in Self.bars.enumerated() {
      let x = CGFloat(index) * (barWidth + gap)
      let y = (bounds.height - height) / 2
      (index < shown ? activeColor : inactiveColor).setFill()
      UIBezierPath(
        roundedRect: CGRect(x: x, y: y, width: barWidth, height: height),
        cornerRadius: barWidth / 2
      ).fill()
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
    label.font = TiebaSimpleText.font(size: 13, weight: .regular)
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

// MARK: - 帖子卡视图

final class TiebaPostRowView: UIView {
  var onEvent: ((TiebaPostRowEvent) -> Void)?

  /// 上一次真正贴上去的模型（身份比较）：同一个实例重复 apply 直接返回（见 apply(model:)）。
  private weak var appliedModel: TiebaPostRowModel?

  /// 上一次贴进 textView 的正文（身份比较，见 loadEmoticonsIfNeeded）。
  private var assignedText: NSAttributedString?

  private let cardView = UIView()
  /// 扁平形态（帖子页）楼层之间的分隔线：整幅贯穿，卡片形态恒隐藏。
  private let dividerView = UIView()
  /// 楼中楼预览的小卡（浅灰底 + 圆角）：把"三条预览 + 查看全部"框成一块，
  /// 免得它与楼层之间的分隔线混成同一层级。
  private let subPostsBox = UIView()
  private var avatarView: TiebaForumAvatarView?
  private let titleLabel = UILabel()
  private let nameLabel = UILabel()
  private let metaLabel = UILabel()
  private let levelLabel = UILabel()
  private let lzLabel = UILabel()
  private let likeIcon = UIImageView()
  private let likeLabel = UILabel()
  private let menuButton = UIButton(type: .system)
  private let avatarControl = UIControl()
  private let likeControl = UIControl()
  private let textView = UITextView()
  private let blockedTipView = UIView()
  private let blockedTipLabel = UILabel()
  private let blockedTipIcon = UIImageView()
  private let imageScrollView = UIScrollView()
  private var imageViews: [UIImageView] = []
  private var imagePlaceholderViews: [TiebaPostPlaceholderView] = []
  private let videoPlaceholderView = TiebaPostPlaceholderView()
  private let imageBadge = UILabel()
  private var videoView: TiebaInlineVideoView?
  private var audioView: TiebaAudioPillView?
  private let subPostsControl = UIControl()
  private let subPostsHairline = UIView()
  private var subPostNameLabels: [UILabel] = []
  private var subPostTextViews: [UILabel] = []
  private var subPostDividers: [UIView] = []
  private let subPostsMoreLabel = UILabel()
  private let toolbarView = UIView()
  private let toolbarReplyLabel = UILabel()
  private let seeLzButton = UIButton(type: .system)
  private let sortButton = UIButton(type: .system)

  private var model: TiebaPostRowModel?
  private var palette: TiebaFeedRowPalette = .default

  override init(frame: CGRect) {
    super.init(frame: frame)
    isOpaque = false
    backgroundColor = .clear
    clipsToBounds = true
    buildSubviews()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  // MARK: 配置

  func apply(pageKey: String, index: Int) {
    guard let model = TiebaPostRowMetrics.shared.row(pageKey: pageKey, index: index) else {
      self.model = nil
      appliedModel = nil
      isHidden = true
      return
    }
    isHidden = false
    apply(model: model)
  }

  func apply(model: TiebaPostRowModel) {
    // 同一个模型实例重复 apply（点赞/页脚变化引起的可见行重配）不必重贴：正文那个
    // UITextView 一赋 attributedText 就是一次全文排版，是这行最贵的一笔；主题色变
    // 走 applyPalette 另一条路。换行/换模型/reuse 都会让 token 失配。
    if appliedModel === model { return }
    appliedModel = model
    self.model = model
    self.palette = model.palette
    applyPalette(model.palette)
    let plan = model.plan

    // 进帖转场的目标端配对（只有主贴卡带 id）：首包落地后这张卡接替占位卡，
    // 没有它的话"返回上一级"的缩回动画就找不到目标（见 TiebaHeroTransition）。
    TiebaHeroTransition.mark(cardView, threadId: model.heroThreadId ?? "")
    cardView.frame = plan.cardFrame
    cardView.layer.cornerRadius = model.style.radius
    cardView.layer.cornerCurve = .continuous
    // 外壳底色按形态：普通卡片=主题 card、高亮卡片=比页面深一档、平铺=透明。
    cardView.backgroundColor = model.style.shellColor(model.palette)
    cardView.layer.borderWidth =
      model.style.hasShell ? 1 / max(traitCollection.displayScale, 1) : 0
    cardView.layer.borderColor = model.palette.borderCard.cgColor
    // 楼层分隔（只有平铺形态的帖子页有楼层线）：整幅贯穿、1pt，线上下各留
    // floorGap 空白（见 plan）。第 0 行是主贴卡，线上不画。
    // 宽度取 plan 的卡宽（= 行宽，平铺形态 marginH 为 0）：apply 时本视图的 frame
    // 还没被 cell 设好，读 bounds.width 会拿到 0，线就永远看不见。
    dividerView.isHidden = !model.style.hasFloorSeparator || model.index <= 0
    dividerView.backgroundColor = TiebaPostRowLayout.floorSeparator
    dividerView.frame = CGRect(
      x: plan.cardFrame.minX,
      y: 0,
      width: plan.cardFrame.width,
      height: TiebaPostRowLayout.floorSeparatorHeight
    )

    avatarControl.frame = plan.avatarFrame
    titleLabel.isHidden = plan.titleFrame == nil
    if let titleFrame = plan.titleFrame {
      titleLabel.frame = titleFrame
      titleLabel.attributedText = model.titleText
      titleLabel.textColor = model.palette.text
    } else {
      titleLabel.attributedText = nil
    }
    configureAvatar(model: model, frame: plan.avatarFrame)
    nameLabel.frame = plan.nameFrame
    nameLabel.text = model.nameText
    nameLabel.textColor = model.palette.text
    if model.preferences.showBothUsername, !model.post.authorName.isEmpty, model.post.authorName != model.nameText {
      nameLabel.text = "\(model.nameText) @\(model.post.authorName)"
    }
    metaLabel.frame = plan.metaFrame
    metaLabel.text = model.metaText
    metaLabel.textColor = model.palette.textTertiary

    levelLabel.isHidden = plan.levelFrame == nil
    if let frame = plan.levelFrame, let color = model.levelColor {
      levelLabel.frame = frame
      // 文案由 plan 决定（头衔放不下时它已退成「Lv.N」）。
      levelLabel.text = plan.levelRenderText ?? model.levelText
      levelLabel.textColor = color
      levelLabel.backgroundColor = color.withAlphaComponent(0.25)
    }
    lzLabel.isHidden = plan.lzFrame == nil
    if let frame = plan.lzFrame {
      lzLabel.frame = frame
      lzLabel.textColor = model.palette.primary
      lzLabel.backgroundColor = model.palette.primary.withAlphaComponent(0.10)
    }

    likeIcon.frame = plan.likeIconFrame
    // SF Symbol 走 TiebaSymbols 缓存：每次 apply 现建一张会走 CoreGlyphs（滚动时每行两次）。
    likeIcon.image = TiebaSymbols.image(
      model.post.isAgree ? "heart.fill" : "heart",
      pointSize: 18,
      weight: .regular
    )
    likeIcon.tintColor = model.post.isAgree ? model.palette.liked : model.palette.textTertiary
    likeControl.frame = plan.likeFrame
    likeLabel.isHidden = plan.likeCountFrame == nil
    if let frame = plan.likeCountFrame {
      likeLabel.frame = frame
      likeLabel.text = model.likeText
      likeLabel.textColor = model.post.isAgree ? model.palette.liked : model.palette.textTertiary
    }
    menuButton.frame = plan.menuFrame
    menuButton.setImage(TiebaSymbols.image("ellipsis", pointSize: 18, weight: .bold), for: .normal)
    menuButton.tintColor = model.palette.textTertiary

    textView.isHidden = plan.textFrame == nil
    if let frame = plan.textFrame {
      textView.frame = frame
      assignedText = model.contentText
      textView.attributedText = model.contentText
    } else {
      assignedText = nil
      textView.attributedText = nil
    }

    blockedTipView.isHidden = plan.blockedTipFrame == nil
    if let frame = plan.blockedTipFrame {
      blockedTipView.frame = frame
      blockedTipIcon.frame = CGRect(x: 8, y: (frame.height - 12) / 2, width: 12, height: 12)
      blockedTipLabel.sizeToFit()
      blockedTipLabel.frame = CGRect(
        x: 24,
        y: (frame.height - blockedTipLabel.bounds.height) / 2,
        width: frame.width - 32,
        height: blockedTipLabel.bounds.height
      )
    }

    layoutImages(model: model, plan: plan)
    layoutMedia(model: model, plan: plan)
    videoPlaceholderView.isHidden = plan.videoPlaceholderFrame == nil
    if let frame = plan.videoPlaceholderFrame, let placeholder = model.videoPlaceholder {
      videoPlaceholderView.frame = frame
      videoPlaceholderView.configure(icon: placeholder.icon, text: placeholder.text, palette: model.palette)
    }
    layoutSubPosts(model: model, plan: plan)
    layoutToolbar(model: model, plan: plan)
    loadEmoticonsIfNeeded(model: model)
  }

  func applyPalette(_ palette: TiebaFeedRowPalette) {
    self.palette = palette
    titleLabel.textColor = palette.text
    textView.textColor = palette.text
    textView.linkTextAttributes = [
      .foregroundColor: palette.primary,
      .underlineStyle: NSUnderlineStyle.single.rawValue,
    ]
    avatarView?.backgroundColor = palette.avatarFallback
    blockedTipView.backgroundColor = .systemFill
    blockedTipLabel.textColor = palette.textSecondary
    blockedTipIcon.tintColor = palette.textSecondary
    imageBadge.textColor = .white
    imageBadge.backgroundColor = UIColor.black.withAlphaComponent(0.45)
    dividerView.backgroundColor = TiebaPostRowLayout.floorSeparator
    // 预览小卡只在平铺形态出现：卡片形态的整行本来就是一张卡，再套一层会糊。
    // 底色与主贴卡同值（浅色 #F2F2F7 / 深色 0x1C1C1E 档），页面里的"块"是同一种灰。
    subPostsBox.backgroundColor = model?.style == .flat
      ? TiebaPostRowLayout.tintedShell
      : .clear
    subPostsBox.layer.borderWidth = 0
    subPostsHairline.backgroundColor = palette.separator
    for divider in subPostDividers { divider.backgroundColor = palette.separator }
    for label in subPostNameLabels { label.textColor = palette.textSecondary }
    for label in subPostTextViews {
      label.textColor = palette.textSecondary
    }
    subPostsMoreLabel.textColor = palette.primary
    // 工具栏与主贴卡同壳：帖子页主贴卡是深一档的灰块，工具栏跟它同色同描边，两块
    // 才读成一个「主贴区」；平铺形态不画壳（底色透出页面）。
    // 底色 = 主题 surfaceSecondary（原 JS replyToolbar 的 colors.surfaceSecondary）：
    // 只靠 hairline 描边成卡，不用 .systemFill —— 那块灰在浅色下是一整条"脏底"。
    let shell = model?.style ?? .card
    if shell.hasShell {
      toolbarView.backgroundColor = shell == .tinted
        ? TiebaPostRowLayout.tintedShell
        : TiebaSimpleRowPalette.default.surfaceSecondary
      toolbarView.layer.borderWidth = 1 / max(traitCollection.displayScale, 1)
    } else {
      toolbarView.backgroundColor = .clear
      toolbarView.layer.borderWidth = 0
    }
    toolbarView.layer.borderColor = palette.borderCard.cgColor
    toolbarReplyLabel.textColor = palette.text
    seeLzButton.tintColor = palette.primary
    sortButton.tintColor = palette.primary
    updateToolbarPills()
    videoView?.applyPalette(palette)
    audioView?.applyPalette(palette)
  }

  func prepareForReuse() {
    model = nil
    appliedModel = nil
    imageScrollView.contentOffset = .zero
    assignedText = nil
    titleLabel.attributedText = nil
    textView.attributedText = nil
    for view in imageViews {
      view.image = nil
      view.alpha = 1
    }
    for view in imagePlaceholderViews { view.isHidden = true }
    for view in subPostTextViews { view.attributedText = nil }
    videoView?.prepareForReuse()
    audioView?.prepareForReuse()
    videoView?.removeFromSuperview()
    audioView?.removeFromSuperview()
    videoView = nil
    audioView = nil
    imageBadge.isHidden = true
  }

  /// 首屏入场：参数与其余三族共用 TiebaEntrance（原各抄一份时位移是 10pt、
  /// 级联钳到 1.2s，与 JS EntranceRow 的 12pt/min(index,9) 不一致）。
  func playEntrance(index: Int) {
    TiebaEntrance.play(on: self, index: index)
  }

  // MARK: 子视图装配

  private func buildSubviews() {
    addSubview(cardView)
    addSubview(dividerView)
    dividerView.isHidden = true
    subPostsBox.layer.cornerRadius = TiebaPostRowLayout.subPostBoxRadius
    subPostsBox.layer.cornerCurve = .continuous
    subPostsBox.isHidden = true
    addSubview(subPostsBox)
    // 主贴卡标题（卡顶第一块，见 TiebaPostRowPlan 的标题块）：行高/行数/截断都在
    // 段落样式里（makeAttributed），这里只管行数与颜色（颜色现取色板，与占位卡同款）。
    titleLabel.numberOfLines = TiebaPostRowLayout.titleLineLimit
    titleLabel.isHidden = true
    addSubview(titleLabel)
    addSubview(avatarControl)
    avatarControl.addTarget(self, action: #selector(handleAvatar), for: .touchUpInside)
    nameLabel.numberOfLines = 1
    nameLabel.font = TiebaPostRowLayout.nameFont
    addSubview(nameLabel)
    metaLabel.numberOfLines = 1
    metaLabel.font = TiebaPostRowLayout.metaFont
    addSubview(metaLabel)
    for label in [levelLabel, lzLabel] {
      label.textAlignment = .center
      label.layer.cornerRadius = 4
      label.layer.cornerCurve = .continuous
      label.clipsToBounds = true
      addSubview(label)
    }
    levelLabel.font = TiebaPostRowLayout.badgeFont
    lzLabel.font = TiebaPostRowLayout.lzFont
    lzLabel.text = "楼主"
    addSubview(likeIcon)
    likeLabel.font = TiebaPostRowLayout.actionFont
    addSubview(likeLabel)
    addSubview(likeControl)
    likeControl.addTarget(self, action: #selector(handleAgree), for: .touchUpInside)
    addSubview(menuButton)
    menuButton.addTarget(self, action: #selector(handleMenu), for: .touchUpInside)
    menuButton.accessibilityLabel = "更多操作"

    textView.isEditable = false
    textView.isScrollEnabled = false
    textView.isSelectable = true
    textView.backgroundColor = .clear
    textView.textContainerInset = .zero
    textView.textContainer.lineFragmentPadding = 0
    textView.delegate = self
    addSubview(textView)

    blockedTipView.layer.cornerRadius = 12
    blockedTipView.layer.cornerCurve = .continuous
    blockedTipIcon.image = UIImage(
      systemName: "eye.slash",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .regular)
    )
    blockedTipView.addSubview(blockedTipIcon)
    blockedTipLabel.text = "内容已屏蔽"
    blockedTipLabel.font = TiebaSimpleText.font(size: 12, weight: .regular)
    blockedTipView.addSubview(blockedTipLabel)
    addSubview(blockedTipView)

    addSubview(videoPlaceholderView)
    videoPlaceholderView.isHidden = true

    imageScrollView.showsHorizontalScrollIndicator = false
    imageScrollView.backgroundColor = .clear
    imageScrollView.isHidden = true
    addSubview(imageScrollView)
    imageBadge.font = TiebaSimpleText.font(size: 15, weight: .semibold)
    imageBadge.textAlignment = .center
    imageBadge.textColor = .white
    imageBadge.backgroundColor = UIColor.black.withAlphaComponent(0.45)
    imageBadge.layer.cornerRadius = 8
    imageBadge.layer.cornerCurve = .continuous
    imageBadge.clipsToBounds = true

    subPostsControl.addTarget(self, action: #selector(handleSubPosts), for: .touchUpInside)
    addSubview(subPostsHairline)
    addSubview(subPostsBox)
    subPostsControl.backgroundColor = .clear
    addSubview(subPostsControl)
    for _ in 0..<3 {
      let name = UILabel()
      name.numberOfLines = 1
      name.font = TiebaPostRowLayout.subPostNameFont
      addSubview(name)
      subPostNameLabels.append(name)
      let text = UILabel()
      // 楼中楼预览**两行截断**（与 TiebaPostRowPlan 的 measureHeight(maxLines: 2) 同口径）；
      // 非可选非交互，链接色已烘进 attributed，故用 UILabel 而非第二个 UITextView
      //（文本框一赋值就是一趟 TextKit 排版：一行楼中楼预览不值得）。
      text.numberOfLines = 2
      text.lineBreakMode = .byTruncatingTail
      addSubview(text)
      subPostTextViews.append(text)
      let divider = UIView()
      addSubview(divider)
      subPostDividers.append(divider)
    }
    subPostsMoreLabel.font = TiebaPostRowLayout.moreFont
    subPostsMoreLabel.numberOfLines = 1
    addSubview(subPostsMoreLabel)

    addSubview(toolbarView)
    toolbarView.isHidden = true
    toolbarReplyLabel.font = TiebaPostRowLayout.replyCountFont
    // 标签与药丸挂在**行视图**上：plan 的 toolbarTextFrame/toolbarSeeLzFrame/
    // toolbarSortFrame 都是行坐标，挂进 toolbarView 会再叠一次 toolbarFrame 的
    // 偏移（整条只剩空底，用户实证"只看楼主那一行显示不出来"）。
    addSubview(toolbarReplyLabel)
    seeLzButton.titleLabel?.font = TiebaPostRowLayout.pillFont
    seeLzButton.layer.cornerRadius = 15
    seeLzButton.layer.cornerCurve = .continuous
    seeLzButton.addTarget(self, action: #selector(handleToggleSeeLz), for: .touchUpInside)
    sortButton.titleLabel?.font = TiebaPostRowLayout.pillFont
    sortButton.layer.cornerRadius = 15
    sortButton.layer.cornerCurve = .continuous
    sortButton.addTarget(self, action: #selector(handleToggleSort), for: .touchUpInside)
    addSubview(seeLzButton)
    addSubview(sortButton)
  }

  /// 头像尺寸随行角色变化（主贴 40 / 回复 36）：TiebaForumAvatarView 的边长在
  /// init 里定死，尺寸变了只能重建（同一个 cell 复用成另一种行时才会发生）。
  private func configureAvatar(model: TiebaPostRowModel, frame: CGRect) {
    if avatarView?.bounds.width != frame.width {
      avatarView?.removeFromSuperview()
      let view = TiebaForumAvatarView(size: frame.width)
      insertSubview(view, belowSubview: avatarControl)
      avatarView = view
    }
    avatarView?.backgroundColor = model.palette.avatarFallback
    avatarView?.frame = frame
    avatarView?.configure(url: model.avatarURL?.absoluteString ?? "", initial: model.nameText)
  }

  private func layoutImages(model: TiebaPostRowModel, plan: TiebaPostRowPlan) {
    imageScrollView.isHidden = plan.imagesFrame == nil
    layoutImagePlaceholders(model: model, plan: plan)
    guard let frame = plan.imagesFrame, !model.imagesHidden else {
      imageBadge.isHidden = true
      return
    }
    imageScrollView.frame = frame
    let shownCount = min(model.images.count, TiebaPostRowLayout.maxImages)
    while imageViews.count < shownCount {
      let view = UIImageView()
      view.contentMode = .scaleAspectFill
      // 圆角由图片管线烘焙进位图（见 tiebaPostLoadDisplayImage）：这里只留
      // cornerRadius 给占位底色，不再 clipsToBounds（否则每帧一次离屏合成）。
      view.layer.cornerRadius = TiebaPostRowLayout.imageRadius
      view.layer.cornerCurve = .continuous
      view.isUserInteractionEnabled = true
      view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleImageTap(_:))))
      view.addInteraction(UIContextMenuInteraction(delegate: self))
      imageScrollView.addSubview(view)
      imageViews.append(view)
    }
    let scale = max(traitCollection.displayScale, 1)
    let single = model.images.count == 1
    for (index, view) in imageViews.enumerated() {
      guard index < shownCount else {
        view.isHidden = true
        view.image = nil
        TiebaHeroTransition.clear(view)
        continue
      }
      view.isHidden = false
      view.frame = single
        ? CGRect(origin: .zero, size: frame.size)
        : (plan.imageItemFrames.indices.contains(index) ? plan.imageItemFrames[index] : .zero)
      view.tag = index
      // 进帖转场：主贴卡的第 1 张图与列表源图配对（其余不配，避免撞 id）。
      // 返回时它也是缩回目标——列表那边配对 id 由行模型驱动，两侧一致。
      if index == 0, let heroThreadId = model.heroThreadId {
        TiebaHeroTransition.markImage(view, threadId: heroThreadId)
      } else {
        TiebaHeroTransition.clear(view)
      }
      let image = model.images[index]
      view.backgroundColor = model.palette.placeholder
      if model.preferences.imageLoadType == "all_no" {
        view.image = nil
      } else {
        tiebaPostLoadDisplayImage(
          TiebaPostRowText.displayURL(image, preferences: model.preferences),
          targetSize: view.bounds.size,
          cornerRadius: TiebaPostRowLayout.imageRadius,
          scale: scale,
          into: view,
          transition: true
        )
      }
      view.alpha = model.preferences.isNight && model.preferences.imageDarkenWhenNight ? 0.6 : 1
    }
    imageScrollView.contentSize = CGSize(
      width: (plan.imageItemFrames.last?.maxX ?? frame.width),
      height: frame.height
    )
    // 超出挂载上限时的 +N 角标（末图右下角）。
    if model.images.count > TiebaPostRowLayout.maxImages, let lastFrame = plan.imageItemFrames.last {
      imageBadge.text = "+\(model.images.count - TiebaPostRowLayout.maxImages)"
      imageBadge.isHidden = false
      if imageBadge.superview == nil { imageScrollView.addSubview(imageBadge) }
      imageBadge.frame = CGRect(x: lastFrame.maxX - 40, y: lastFrame.maxY - 32, width: 32, height: 22)
      imageScrollView.bringSubviewToFront(imageBadge)
    } else {
      imageBadge.isHidden = true
    }
  }

  private func layoutImagePlaceholders(model: TiebaPostRowModel, plan: TiebaPostRowPlan) {
    while imagePlaceholderViews.count < plan.imagePlaceholderFrames.count {
      let view = TiebaPostPlaceholderView()
      addSubview(view)
      imagePlaceholderViews.append(view)
    }
    for (index, view) in imagePlaceholderViews.enumerated() {
      guard index < plan.imagePlaceholderFrames.count else {
        view.isHidden = true
        continue
      }
      view.isHidden = false
      view.frame = plan.imagePlaceholderFrames[index]
      view.configure(icon: "photo", text: "[图片]", palette: model.palette)
    }
  }

  private func layoutMedia(model: TiebaPostRowModel, plan: TiebaPostRowPlan) {
    if let video = model.video, let frame = plan.videoFrame {
      if videoView == nil {
        videoView = TiebaInlineVideoView()
        addSubview(videoView!)
      }
      videoView?.isHidden = false
      videoView?.frame = frame
      videoView?.configure(video: video, preferences: model.preferences)
      videoView?.applyPalette(model.palette)
    } else if let videoView {
      videoView.isHidden = true
      videoView.stopPlayback()
    }
    if let audio = model.audio, let frame = plan.audioFrame {
      if audioView == nil {
        audioView = TiebaAudioPillView()
        addSubview(audioView!)
      }
      audioView?.isHidden = false
      audioView?.frame = frame
      audioView?.configure(src: audio.src, duration: audio.duration, palette: model.palette)
    } else if let audioView {
      audioView.isHidden = true
      audioView.stopPlayback()
    }
  }

  private func layoutSubPosts(model: TiebaPostRowModel, plan: TiebaPostRowPlan) {
    guard let frame = plan.subPostsFrame else {
      subPostsControl.frame = .zero
      subPostsHairline.isHidden = true
      subPostsBox.isHidden = true
      for label in subPostNameLabels { label.isHidden = true }
      for view in subPostTextViews { view.isHidden = true }
      for divider in subPostDividers { divider.isHidden = true }
      subPostsMoreLabel.isHidden = true
      return
    }
    let contentX = frame.minX + TiebaPostRowLayout.cardPadding
    // 卡片形态保持原样（一条线上沿）；平铺形态用浅灰小卡代替那条线。
    let boxed = model.style == .flat
    subPostsBox.isHidden = !boxed
    subPostsBox.frame = frame
    subPostsHairline.isHidden = boxed
    subPostsHairline.frame = CGRect(x: contentX, y: frame.minY, width: frame.width - TiebaPostRowLayout.cardPadding * 2, height: 1 / max(traitCollection.displayScale, 1))
    subPostsControl.frame = frame
    let cardFrame = plan.cardFrame
    let textWidth = max(cardFrame.width - TiebaPostRowLayout.cardPadding * 2, 0)
    for (index, label) in subPostNameLabels.enumerated() {
      let hasPost = index < model.post.subPosts.count
      label.isHidden = !hasPost
      if hasPost, plan.subPostNameFrames.indices.contains(index) {
        label.frame = plan.subPostNameFrames[index]
        // 与正文文本框共用行盒（见 subPostNameParagraph），否则首行基线对不齐。
        label.attributedText = NSAttributedString(
          string: "\(model.post.subPosts[index].displayName)：",
          attributes: [
            .font: TiebaPostRowLayout.subPostNameFont,
            .foregroundColor: model.palette.textSecondary,
            .paragraphStyle: TiebaPostRowLayout.subPostNameParagraph(
              Double(model.preferences.fontScaleClamped)
            ),
          ]
        )
      }
      let text = subPostTextViews[index]
      text.isHidden = !hasPost
      if hasPost, plan.subPostTextFrames.indices.contains(index) {
        text.frame = plan.subPostTextFrames[index]
        text.attributedText = model.subPostTexts.indices.contains(index) ? model.subPostTexts[index] : nil
      }
      let divider = subPostDividers[index]
      divider.isHidden = true
      _ = textWidth
    }
    for (index, divider) in subPostDividers.enumerated() where index < model.post.subPosts.count {
      if plan.subPostDividerFrames.indices.contains(index) {
        divider.isHidden = false
        divider.frame = plan.subPostDividerFrames[index]
      }
    }
    subPostsMoreLabel.isHidden = plan.subPostsMoreFrame == nil
    if let moreFrame = plan.subPostsMoreFrame {
      subPostsMoreLabel.frame = moreFrame
      subPostsMoreLabel.text = model.post.subPostNum > model.post.subPosts.count
        ? "查看全部 \(model.post.subPostNum) 条回复"
        : (model.post.subPosts.isEmpty ? "查看 \(model.post.subPostNum) 条回复" : nil)
    }
  }

  private func layoutToolbar(model: TiebaPostRowModel, plan: TiebaPostRowPlan) {
    guard let frame = plan.toolbarFrame, let toolbar = model.toolbar else {
      // 三件内容已不在 toolbarView 里（见 buildSubviews），必须逐个收起：否则
      // 回收成回复行后，它们会留在上一次主贴行时的位置上。
      toolbarView.isHidden = true
      toolbarReplyLabel.isHidden = true
      seeLzButton.isHidden = true
      sortButton.isHidden = true
      return
    }
    toolbarView.isHidden = false
    toolbarReplyLabel.isHidden = false
    seeLzButton.isHidden = false
    sortButton.isHidden = false
    toolbarView.frame = frame
    toolbarView.layer.cornerRadius = model.style.radius
    toolbarView.layer.cornerCurve = .continuous    // glassCard 的 hairline 描边：浅色下工具栏底色贴近页面底色，没有描边整条看不出来。
    // 平铺形态不画壳（底色/描边见 applyPalette），这里只管有壳的形态。
    if model.style.hasShell {
      toolbarView.layer.borderWidth = 1 / max(traitCollection.displayScale, 1)
      toolbarView.layer.borderColor = model.palette.borderCard.cgColor
    }
    if let textFrame = plan.toolbarTextFrame {
      toolbarReplyLabel.frame = textFrame
      let reply = TiebaForumFormat.count(toolbar.replyNum)
      toolbarReplyLabel.attributedText = TiebaPostRowView.toolbarReplyText(
        count: reply,
        pageLabel: toolbar.pageLabel,
        palette: model.palette
      )
    }
    if let lzFrame = plan.toolbarSeeLzFrame { seeLzButton.frame = lzFrame }
    if let sortFrame = plan.toolbarSortFrame { sortButton.frame = sortFrame }
    updateToolbarPills()
  }

  private func updateToolbarPills() {
    guard let toolbar = model?.toolbar else { return }
    configurePill(seeLzButton, title: "只看楼主", selected: toolbar.seeLz, palette: palette)
    // 排序是三档循环（热门/正序/倒序）：当前档位加亮，非正序都算"非默认"。
    configurePill(
      sortButton,
      title: toolbar.sort.title,
      selected: toolbar.sort != .asc,
      palette: palette
    )
  }

  private func configurePill(_ button: UIButton, title: String, selected: Bool, palette: TiebaFeedRowPalette) {
    button.setTitle(title, for: .normal)
    button.setTitleColor(selected ? .white : palette.textSecondary, for: .normal)
    button.backgroundColor = selected ? palette.primary : .systemFill
  }

  private func loadEmoticonsIfNeeded(model: TiebaPostRowModel) {
    let missing = model.missingEmoticons
    guard !missing.isEmpty else { return }
    let key = model.pageKey
    let index = model.index
    TiebaEmoticonCache.shared.load(missing) { [weak self] in
      guard let self, let current = self.model, current.pageKey == key, current.index == index else { return }
      // 一行有 N 个表情就回调 N 次；模型侧缓存过之后拿到的是同一份对象，
      // 这里按对象身份再挡一次，只重排一次（列表里最贵的一笔就是正文排版）。
      let texts = current.upgradeTexts()
      if self.assignedText !== texts.text {
        self.assignedText = texts.text
        self.textView.attributedText = texts.text
      }
      for (idx, view) in self.subPostTextViews.enumerated() where !view.isHidden {
        view.attributedText = texts.subs.indices.contains(idx) ? texts.subs[idx] : nil
      }
    }
  }

  // MARK: 交互

  @objc private func handleAvatar() {
    TiebaSceneHaptics.fire("press")
    onEvent?(.avatar)
  }

  @objc private func handleAgree() {
    TiebaSceneHaptics.fire("like")
    onEvent?(.agree)
  }

  @objc private func handleSubPosts() {
    TiebaSceneHaptics.fire("press")
    onEvent?(.subPosts)
  }

  @objc private func handleToggleSeeLz() {
    TiebaSceneHaptics.fire("toggle")
    onEvent?(.toggleSeeLz)
  }

  @objc private func handleToggleSort() {
    TiebaSceneHaptics.fire("toggle")
    onEvent?(.toggleSort)
  }

  @objc private func handleImageTap(_ gesture: UITapGestureRecognizer) {
    guard let view = gesture.view as? UIImageView else { return }
    TiebaSceneHaptics.fire("press")
    emitImageOpen(index: view.tag, rect: view.convert(view.bounds, to: nil))
  }

  /// 图片打开出口（点图与长按预览提交共用）：rect = 该图当前窗口矩形，宿主收到
  /// 后自己开查看器（本行不开）。长按提交在提交当刻取几何、收起动画完成后再发。
  private func emitImageOpen(index: Int, rect: CGRect) {
    onEvent?(.image(index: index, rect: rect))
  }

  // MARK: 图片几何查询（查看器退出重算；本视图仍不装任何额外手势）

  /// 行坐标下第 index 张图的当前可见矩形：frame 在 imageScrollView 内容坐标，
  /// convert 自动吃掉 contentOffset，再与滚动视口求交。nil = 越界/未挂载/
  /// 图片区隐藏/完全滑出视口，调用方据此走框架 Fade。
  func imageRect(at index: Int) -> CGRect? {
    guard let model, !model.imagesHidden, !imageScrollView.isHidden,
          model.images.indices.contains(index),
          imageViews.indices.contains(index) else { return nil }
    let imageView = imageViews[index]
    guard imageView.tag == index, !imageView.isHidden,
          imageView.bounds.width > 1, imageView.bounds.height > 1 else { return nil }
    let rowRect = imageView.convert(imageView.bounds, to: self)
    let viewport = imageScrollView.convert(imageScrollView.bounds, to: self)
    let visible = rowRect.intersection(viewport)
    guard !visible.isNull, visible.width >= 2, visible.height >= 2 else { return nil }
    return visible
  }

  @objc private func handleMenu() {
    TiebaSceneHaptics.fire("sheet-present")
    guard let model else { return }
    let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
    sheet.addAction(UIAlertAction(title: "复制内容", style: .default) { [weak self] _ in
      self?.onEvent?(.copyContent)
    })
    sheet.addAction(UIAlertAction(title: "分享", style: .default) { [weak self] _ in
      self?.onEvent?(.share)
    })
    sheet.addAction(UIAlertAction(title: "复制链接", style: .default) { [weak self] _ in
      self?.onEvent?(.copyLink)
    })
    if model.canDelete {
      sheet.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
        self?.onEvent?(.delete)
      })
    }
    sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
    guard let presenter = TiebaViewHosts.viewController(for: self) else { return }
    if let popover = sheet.popoverPresentationController {
      popover.sourceView = menuButton
      popover.sourceRect = menuButton.bounds
      popover.permittedArrowDirections = .up
    }
    presenter.present(sheet, animated: true)
  }

  // MARK: 工具

  private static func toolbarReplyText(count: String, pageLabel: String?, palette: TiebaFeedRowPalette) -> NSAttributedString {
    let result = NSMutableAttributedString(
      string: "回复 \(count)",
      attributes: [
        .font: TiebaPostRowLayout.replyCountFont,
        .foregroundColor: palette.text,
      ]
    )
    if let pageLabel, !pageLabel.isEmpty {
      result.append(NSAttributedString(
        string: " · \(pageLabel)",
        attributes: [
          .font: TiebaSimpleText.font(size: 12, weight: .medium),
          .foregroundColor: palette.textTertiary,
        ]
      ))
    }
    return result
  }
}

// MARK: - 文本交互（选中 / 链接）

extension TiebaPostRowView: UITextViewDelegate {
  func textView(
    _ textView: UITextView,
    primaryActionFor textItem: UITextItem,
    defaultAction: UIAction
  ) -> UIAction? {
    guard case .link(let url) = textItem.content else { return defaultAction }
    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    let query = { (name: String) -> String in
      components?.queryItems?.first(where: { $0.name == name })?.value ?? ""
    }
    switch components?.host {
    case "user":
      let uid = query("uid")
      guard !uid.isEmpty else { return nil }
      return UIAction(title: defaultAction.title) { [weak self] _ in
        self?.onEvent?(.user(uid))
      }
    case "link":
      let raw = query("url")
      guard !raw.isEmpty else { return nil }
      return UIAction(title: defaultAction.title) { [weak self] _ in
        self?.onEvent?(.link(raw))
      }
    default:
      return UIAction(title: defaultAction.title) { [weak self] _ in
        self?.onEvent?(.link(url.absoluteString))
      }
    }
  }
}

// MARK: - 图片长按菜单（保存照片 / 分享照片，原 PostImageContextMenu）

extension TiebaPostRowView: UIContextMenuInteractionDelegate {
  func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    configurationForMenuAtLocation location: CGPoint
  ) -> UIContextMenuConfiguration? {
    guard let model, let view = interaction.view as? UIImageView,
          model.images.indices.contains(view.tag) else { return nil }
    let image = model.images[view.tag]
    // 保存/分享仍用原图档（originSrc）；预览只显示压缩档（src），产品要求。
    let raw = image.originSrc.isEmpty ? image.src : image.originSrc
    let previewUrl = image.src.isEmpty ? image.originSrc : image.src
    guard !raw.isEmpty, !previewUrl.isEmpty else { return nil }
    // 首帧 = 被长按那格屏上已渲染的位图；无图/空 bounds 就传 nil，由预览控制器
    // 自行按压缩档下载（别拿占位底色当首帧造图）。
    var snapshot: UIImage?
    if view.image != nil, view.bounds.width > 0, view.bounds.height > 0 {
      snapshot = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
        view.drawHierarchy(in: view.bounds, afterScreenUpdates: false)
      }
    }
    let previewProvider: UIContextMenuContentPreviewProvider = {
      TiebaPhotoPreviewViewController(
        initialImage: snapshot,
        fullUrl: previewUrl,
        pixelWidth: image.width,
        pixelHeight: image.height
      )
    }
    return UIContextMenuConfiguration(identifier: nil, previewProvider: previewProvider) { [weak self] _ in
      let save = UIAction(
        title: "保存照片",
        image: UIImage(systemName: "square.and.arrow.down")
      ) { _ in
        TiebaFeedImageActions.save(
          url: raw,
          forumName: model.forumName,
          presenter: self.flatMap { TiebaViewHosts.viewController(for: $0) }
        )
      }
      let share = UIAction(
        title: "分享照片",
        image: UIImage(systemName: "square.and.arrow.up")
      ) { _ in
        guard let self, let presenter = TiebaViewHosts.viewController(for: self) else { return }
        TiebaFeedImageActions.share(
          url: raw,
          forumName: model.forumName,
          presenter: presenter,
          // sourceRect 相对 presenter.view（TiebaShareSheet 的 popover 契约）；
          // 旧写法把图片 bounds 当行坐标转换，多图格锚点会落到行左上角。
          sourceRect: view.convert(view.bounds, to: presenter.view)
        )
      }
      return UIMenu(children: [save, share])
    }
  }

  /// 升起动画锚点 = 被长按的图片格（本行 delegate 是整行，不能用 self，否则提起
  /// 整卡）。方法名一个字都不能简写/错位：简写版编译只警告、系统永远不会调用。
  /// 两个协议名都给（旧名 iOS 16 起标废弃，但 UIKitCore 里新旧选择器都还在被
  /// 引用，真机上只实现一个可能不被调），两个入口落到同一份实现。
  private func tiebaHighlightPreview(_ interaction: UIContextMenuInteraction) -> UITargetedPreview? {
    guard let view = interaction.view as? UIImageView, view.tiebaIsOnScreen else { return nil }
    return UITargetedPreview(view: view)
  }

  func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    configuration: UIContextMenuConfiguration,
    highlightPreviewForItemWithIdentifier identifier: any NSCopying
  ) -> UITargetedPreview? {
    tiebaHighlightPreview(interaction)
  }

  func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    configuration: UIContextMenuConfiguration,
    dismissalPreviewForItemWithIdentifier identifier: any NSCopying
  ) -> UITargetedPreview? {
    nil
  }

  func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    previewForHighlightingMenuWithConfiguration configuration: UIContextMenuConfiguration
  ) -> UITargetedPreview? {
    tiebaHighlightPreview(interaction)
  }

  /// 收起动画不飞回（与信息流一致）。
  func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    previewForDismissingMenuWithConfiguration configuration: UIContextMenuConfiguration
  ) -> UITargetedPreview? {
    nil
  }

  /// 菜单升起瞬间的「弹出大图」触觉（原 RN playImageLiftHaptic，与信息流一致）。
  func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    willDisplayMenuFor configuration: UIContextMenuConfiguration,
    animator: UIContextMenuInteractionAnimating?
  ) {
    TiebaSceneHaptics.playImageLift()
  }

  /// 点长按预览 = 提交：收起动画走完再发图片打开事件（与点图共用 emitImageOpen；
  /// 菜单还在时开查看器会与收起动画时序打架）。几何在提交当刻取，与点图同式。
  func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    willPerformPreviewActionForMenuWith configuration: UIContextMenuConfiguration,
    animator: any UIContextMenuInteractionCommitAnimating
  ) {
    guard let view = interaction.view as? UIImageView else { return }
    let index = view.tag
    let rect = view.convert(view.bounds, to: nil)
    animator.addCompletion { [weak self] in
      self?.emitImageOpen(index: index, rect: rect)
    }
  }
}

// MARK: - 找宿主 VC / 视图

enum TiebaViewHosts {
  @MainActor
  static func viewController(for view: UIView) -> UIViewController? {
    var responder: UIResponder? = view
    while let current = responder {
      if let controller = current as? UIViewController { return controller }
      responder = current.next
    }
    return nil
  }
}
