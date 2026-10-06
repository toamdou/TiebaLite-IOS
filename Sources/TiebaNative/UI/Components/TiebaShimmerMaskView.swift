// 微光（shimmer）做成**遮罩**：三层白的渐变当内容视图的 mask，对 position.x 加一条
// 无限循环的 additive 动画 —— 于是微光**贴着内容的轮廓**走，圆角/圆/SF Symbol 自动跟随。
//
// 移植自上游 submodules/ShimmeringMask/Sources/ShimmeringMaskView.swift:36-41（三档 alpha）、
// :46（contentView.layer.mask = maskLayer）、:68-81（travelDelta = containerWidth + gradientWidth，
// additive position.x，repeatCount = .infinity）、:104-124（mask 宽度与 locations 由 dipHalfFraction 反推）。
//
// 与"叠一条亮带"的区别（本仓 TiebaSkeletonBoneView 是亮带式）：亮带会溢出到形状之外，
// 想裁进形状就得 masksToBounds —— 而那会把连续曲率/圆角/发光一起切掉，且**盖不住文字、
// 图标、SF Symbol**（它们不是矩形）。mask 式没有这个限制。
import UIKit

final class TiebaShimmerMaskView: UIView {
  /// 被扫过的内容（调用方往里塞任意视图：圆、图标、文字、图片都行）。
  let contentView = UIView()

  private let maskLayer = CAGradientLayer()
  private let baseAlpha: CGFloat
  private let duration: Double
  /// 光带（暗带）宽度。上游由调用方按内容尺寸给，这里按自身宽度取一个比例。
  var gradientWidth: CGFloat = 90 {
    didSet { if gradientWidth != oldValue { setNeedsLayout() } }
  }
  /// 调用方的挂起开关（宿主整块隐藏但没改本视图 isHidden 时用）。
  var isSuspended = false {
    didSet { updateAnimation() }
  }

  /// baseAlpha = 基线不透明度（亮带处恒为 1.0）。上游取 [1, peak, 1]（把亮内容压出一条
  /// **暗带**）；本仓内容是平色占位块/灰图标，暗带读起来像"闪黑"，所以取反：基线压暗一档、
  /// **亮带扫过**才是微光。mask 只能把内容压暗、不能提亮，这是唯一能用 mask 做出亮带的方式。
  init(baseAlpha: CGFloat = 0.5, duration: Double = 1.5) {
    self.baseAlpha = baseAlpha
    self.duration = duration
    super.init(frame: .zero)
    maskLayer.startPoint = CGPoint(x: 0, y: 0.5)
    maskLayer.endPoint = CGPoint(x: 1, y: 0.5)
    maskLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
    maskLayer.colors = [
      UIColor(white: 1.0, alpha: baseAlpha).cgColor,
      UIColor(white: 1.0, alpha: 1.0).cgColor,
      UIColor(white: 1.0, alpha: baseAlpha).cgColor,
    ]
    addSubview(contentView)
    contentView.layer.mask = maskLayer
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func layoutSubviews() {
    super.layoutSubviews()
    contentView.frame = bounds
    let size = bounds.size
    guard size.width > 0, size.height > 0 else { return }
    // 光带完整地从画面外扫到画面外：容器宽 + 光带宽 的两倍余量（上游 :105 同式）。
    let travelDistance = size.width + gradientWidth
    let maskWidth = size.width + 2 * travelDistance
    let dipHalfFraction = maskWidth > 0 ? (gradientWidth * 0.5) / maskWidth : 0
    maskLayer.locations = [
      (0.5 - dipHalfFraction) as NSNumber,
      0.5 as NSNumber,
      (0.5 + dipHalfFraction) as NSNumber,
    ]
    maskLayer.bounds = CGRect(origin: .zero, size: CGSize(width: maskWidth, height: size.height))
    maskLayer.position = CGPoint(x: -gradientWidth * 0.5, y: size.height * 0.5)
    updateAnimation()
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    updateAnimation()
  }

  override var isHidden: Bool {
    didSet { updateAnimation() }
  }

  /// 可见 + 未挂起 + 未开"减弱动态效果"才扫（与骨架屏同一套治理口径，避免后台空转）。
  private func updateAnimation() {
    let shouldRun = window != nil && !isHidden && !isSuspended
      && !UIAccessibility.isReduceMotionEnabled && UIApplication.shared.applicationState == .active
    guard shouldRun else {
      maskLayer.removeAnimation(forKey: "shimmer")
      return
    }
    guard maskLayer.animation(forKey: "shimmer") == nil else { return }
    let travelDelta = bounds.width + gradientWidth
    let animation = CABasicAnimation(keyPath: "position.x")
    animation.fromValue = 0.0
    animation.toValue = travelDelta
    animation.duration = duration
    animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
    animation.isAdditive = true
    animation.repeatCount = .infinity
    maskLayer.add(animation, forKey: "shimmer")
  }
}
