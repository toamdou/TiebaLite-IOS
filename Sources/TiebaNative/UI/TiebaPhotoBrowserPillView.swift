//  查看器/列表共用的胶囊文本件（页码、提示）。
//  从 UI/Media/TiebaPhotoBrowserChrome.swift 拆出：UI/Components 的设置页也要用它。

import JXPhotoBrowser
import Nuke
import UIKit

final class TiebaPhotoBrowserPillView: UIView {
  private static let horizontalPadding: CGFloat = 16
  private static let verticalPadding: CGFloat = 9
  private static let contentGap: CGFloat = 6
  private static let indicatorSize: CGFloat = 18
  private static let progressHeight: CGFloat = 3
  private static let cornerRadius: CGFloat = 18

  /// 玻璃底（部署底线 iOS 26，恒可用）。
  private let glassBackground: UIVisualEffectView = {
    return TiebaGlassContainerView.makeEffect(tint: UIColor(red: 28 / 255, green: 28 / 255, blue: 30 / 255, alpha: 0.55))
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
