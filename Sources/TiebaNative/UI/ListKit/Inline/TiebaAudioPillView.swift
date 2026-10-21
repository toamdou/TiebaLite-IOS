// 从 TiebaPostRowInline.swift 拆出（按类型分文件，纯搬运、整类型逐字搬走）。

import AVFoundation
import UIKit

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
    layer.borderWidth = 0
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
