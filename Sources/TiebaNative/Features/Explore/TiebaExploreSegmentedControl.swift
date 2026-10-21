// 发现页顶部栏：iOS 26 紧凑玻璃分段控件。
// 外框是系统玻璃，选中指示器跟手拖动并用弹簧落位；标题按内容收紧。
import QuartzCore
import UIKit

final class TiebaExploreSegmentedControl: UIControl, UIGestureRecognizerDelegate {
  private enum Metrics {
    static let visualHeight: CGFloat = 36
    static let horizontalInset: CGFloat = 3
    static let verticalInset: CGFloat = 3
    static let minimumSegmentWidth: CGFloat = 62
    static let minimumHitHeight: CGFloat = 44
    static let maximumSegmentPointSize: CGFloat = 26
    static let indicatorDampingRatio: CGFloat = 0.84
  }

  private static let indicatorAnimationKey = "tieba.explore.segment.spring"
  /// 未选中段小字号也必须 ≥4.5:1；Increase Contrast 直接用 label。
  private static let unselectedTextColor = UIColor { trait in
    if trait.accessibilityContrast == .high { return .label }
    return trait.userInterfaceStyle == .dark
      ? UIColor(white: 0.66, alpha: 1)
      : UIColor(red: 0.408, green: 0.408, blue: 0.435, alpha: 1)
  }
  private static let glassTint = UIColor { trait in
    if trait.accessibilityContrast == .high {
      return trait.userInterfaceStyle == .dark
        ? UIColor.white.withAlphaComponent(0.12)
        : UIColor.black.withAlphaComponent(0.08)
    }
    return trait.userInterfaceStyle == .dark
      ? UIColor.white.withAlphaComponent(0.06)
      : UIColor.black.withAlphaComponent(0.035)
  }

  private let buttons: [UIButton]
  private let glassBackdrop: UIVisualEffectView
  private let indicator = UIView()
  private let panGesture = UIPanGestureRecognizer()
  private(set) var selectedSegmentIndex = 0

  private var lastLayoutSize: CGSize = .zero
  private var panStartIndicatorX: CGFloat = 0

  private var panPreviewIndex = 0
  private var isChromeCompact = false
  private var visualFrame: CGRect = .zero
  private var traitRegistration: UITraitChangeRegistration?

  init(titles: [String]) {
    if titles.isEmpty { fatalError("分段控件至少需要一个 segment") }
    self.buttons = titles.enumerated().map { index, title in
      Self.makeButton(title: title, index: index)
    }
    self.glassBackdrop = TiebaGlassContainerView.makeEffect(tint: Self.glassTint, clear: true)
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    isAccessibilityElement = false
    backgroundColor = .clear
    setupGlass()
    setupIndicator()
    setupButtons()
    setupPanGesture()
    updateButtonStates()
    traitRegistration = registerForTraitChanges([
      UITraitPreferredContentSizeCategory.self,
      UITraitAccessibilityContrast.self,
    ]) { (control: TiebaExploreSegmentedControl, _: UITraitCollection) in
      control.updateButtonFonts()
      control.updateButtonStates()
      control.invalidateIntrinsicContentSize()
      control.setNeedsLayout()
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override var intrinsicContentSize: CGSize {
    let widest = buttons.reduce(CGFloat(Metrics.minimumSegmentWidth)) { partial, button in
      max(partial, button.intrinsicContentSize.width)
    }
    let buttonHeight = buttons.reduce(CGFloat.zero) { partial, button in
      max(partial, button.intrinsicContentSize.height)
    }
    let visualHeight = max(Metrics.visualHeight, ceil(buttonHeight) + Metrics.verticalInset * 2)
    let width = CGFloat(buttons.count) * widest + Metrics.horizontalInset * 2
    return CGSize(width: ceil(width), height: max(Metrics.minimumHitHeight, visualHeight))
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let buttonHeight = buttons.reduce(CGFloat.zero) { partial, button in
      max(partial, button.intrinsicContentSize.height)
    }
    let preferredVisualHeight = max(
      Metrics.visualHeight,
      ceil(buttonHeight) + Metrics.verticalInset * 2
    )
    let visualHeight = min(bounds.height, preferredVisualHeight)
    visualFrame = CGRect(
      x: 0,
      y: (bounds.height - visualHeight) / 2,
      width: bounds.width,
      height: visualHeight
    )
    glassBackdrop.frame = visualFrame
    glassBackdrop.layer.cornerRadius = visualFrame.height / 2
    let content = visualFrame.insetBy(dx: Metrics.horizontalInset, dy: Metrics.verticalInset)
    guard content.width > 0, content.height > 0, buttons.count > 0 else { return }
    let segmentWidth = content.width / CGFloat(buttons.count)
    for (index, button) in buttons.enumerated() {
      // 段的可点区域用整个 44pt 高控件；玻璃视觉仍是紧凑的 visualFrame。
      button.frame = CGRect(
        x: content.minX + CGFloat(index) * segmentWidth,
        y: 0,
        width: segmentWidth,
        height: bounds.height
      )
    }

    let selectedFrame = indicatorFrame(for: selectedSegmentIndex)
    let sizeChanged = lastLayoutSize != bounds.size
    lastLayoutSize = bounds.size
    if sizeChanged {
      indicator.layer.removeAnimation(forKey: Self.indicatorAnimationKey)
      indicator.frame = selectedFrame
    } else if indicator.layer.animation(forKey: Self.indicatorAnimationKey) == nil {
      // 模型值始终是落位目标；在途弹簧只由 presentation 层承担，不在这里重置。
      indicator.frame = selectedFrame
    }
    indicator.layer.cornerRadius = indicator.bounds.height / 2
    indicator.layer.shadowPath = UIBezierPath(
      roundedRect: indicator.bounds,
      cornerRadius: indicator.bounds.height / 2
    ).cgPath
    updateChromeShadow()
  }

  private func indicatorFrame(for index: Int) -> CGRect {
    guard buttons.indices.contains(index) else { return .zero }
    return CGRect(
      x: buttons[index].frame.minX,
      y: visualFrame.minY + Metrics.verticalInset,
      width: buttons[index].frame.width,
      height: max(visualFrame.height - Metrics.verticalInset * 2, 0)
    )
  }

  private func updateChromeShadow() {
    layer.shadowColor = UIColor.black.cgColor
    layer.shadowOpacity = traitCollection.userInterfaceStyle == .dark ? 0.30 : 0.10
    layer.shadowRadius = 16
    layer.shadowOffset = CGSize(width: 0, height: 5)
    // 浮动 chrome 的阴影必须走 shadowPath，避免离屏 mask / 逐帧重算。
    layer.shadowPath = UIBezierPath(
      roundedRect: visualFrame,
      cornerRadius: visualFrame.height / 2
    ).cgPath
  }

  // MARK: - 外部入口

  func setSelectedSegmentIndex(_ index: Int, animated: Bool, notify: Bool) {
    guard buttons.indices.contains(index) else { return }
    let changed = index != selectedSegmentIndex
    selectedSegmentIndex = index
    updateButtonStates()
    moveIndicator(to: index, animated: animated)
    if changed, notify {
      super.sendActions(for: .valueChanged)
    }
  }

  /// 滚动时只做一次阈值状态切换：缩放/淡化整个 chrome，不改约束、不触发列表布局。
  func setChromeCompact(_ compact: Bool, animated: Bool) {
    guard compact != isChromeCompact else { return }
    isChromeCompact = compact
    let apply = {
      self.transform = compact
        ? CGAffineTransform(translationX: 0, y: -2).scaledBy(x: 0.94, y: 0.94)
        : .identity
      self.alpha = compact ? 0.88 : 1
    }
    guard animated, UIAccessibility.isReduceMotionEnabled == false else {
      apply()
      return
    }
    TiebaAnimation.animate(
      curve: .easeOut,
      duration: TiebaAnimationDuration.stateChange,
      options: [.beginFromCurrentState, .allowUserInteraction],
      animations: apply
    )
  }

  // MARK: - 装配

  private func setupGlass() {
    glassBackdrop.isUserInteractionEnabled = false
    glassBackdrop.layer.cornerRadius = Metrics.visualHeight / 2
    glassBackdrop.layer.cornerCurve = .continuous
    glassBackdrop.clipsToBounds = true
    addSubview(glassBackdrop)
  }

  private func setupIndicator() {
    indicator.isUserInteractionEnabled = false
    indicator.backgroundColor = UIColor { trait in
      if trait.accessibilityContrast == .high {
        return trait.userInterfaceStyle == .dark
          ? UIColor.white.withAlphaComponent(0.28)
          : UIColor.black.withAlphaComponent(0.18)
      }
      if trait.userInterfaceStyle == .dark {
        return UIColor.white.withAlphaComponent(0.18)
      }
      return UIColor.white.withAlphaComponent(0.72)
    }
    indicator.layer.cornerCurve = .continuous
    indicator.layer.shadowColor = UIColor.black.cgColor
    indicator.layer.shadowOpacity = 0.06
    indicator.layer.shadowRadius = 6
    indicator.layer.shadowOffset = CGSize(width: 0, height: 2)
    insertSubview(indicator, aboveSubview: glassBackdrop)
  }

  private func setupButtons() {
    for button in buttons {
      button.addTarget(self, action: #selector(handleButtonTap(_:)), for: .touchUpInside)
      addSubview(button)
    }
  }

  private func setupPanGesture() {
    panGesture.addTarget(self, action: #selector(handlePan(_:)))
    panGesture.delegate = self
    panGesture.cancelsTouchesInView = true
    addGestureRecognizer(panGesture)
  }

  private static func makeButton(title: String, index: Int) -> UIButton {
    var config = UIButton.Configuration.plain()
    config.title = title
    config.image = nil
    config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10)
    config.baseForegroundColor = unselectedTextColor
    config.titleLineBreakMode = .byTruncatingTail
    config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
      var outgoing = incoming
      outgoing.font = Self.segmentFont(weight: .medium)
      return outgoing
    }
    let button = UIButton(type: .system)
    button.configuration = config
    button.tag = index
    button.accessibilityLabel = title
    button.accessibilityHint = "切换动态内容分类"
    button.accessibilityTraits = .button
    button.configurationUpdateHandler = { button in
      let apply = {
        button.alpha = button.isHighlighted ? 0.74 : 1
        button.transform = button.isHighlighted
          ? CGAffineTransform(scaleX: 0.96, y: 0.96)
          : .identity
      }
      guard UIAccessibility.isReduceMotionEnabled == false else {
        apply()
        return
      }
      TiebaAnimation.animate(
        curve: .easeOut,
        duration: TiebaAnimationDuration.microFeedback,
        options: [.beginFromCurrentState, .allowUserInteraction],
        animations: apply
      )
    }
    return button
  }

  private func updateButtonFonts() {
    for (index, button) in buttons.enumerated() {
      let weight: UIFont.Weight = index == selectedSegmentIndex ? .semibold : .medium
      var config = button.configuration
      config?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
        var outgoing = incoming
        outgoing.font = Self.segmentFont(weight: weight)
        return outgoing
      }
      button.configuration = config
    }
  }

  /// 分段标题只承载三个短标签；AX 下保留 Dynamic Type 但封顶，避免三段文字互相挤压/省略。
  private static func segmentFont(weight: UIFont.Weight) -> UIFont {
    let scaled = TiebaSimpleText.font(size: 14, weight: weight)
    guard scaled.pointSize <= Metrics.maximumSegmentPointSize else {
      return UIFont.systemFont(ofSize: Metrics.maximumSegmentPointSize, weight: weight)
    }
    return scaled
  }

  // MARK: - Selection

  @objc private func handleButtonTap(_ sender: UIButton) {
    guard buttons.indices.contains(sender.tag) else { return }
    setSelectedSegmentIndex(sender.tag, animated: true, notify: true)
  }

  private func updateButtonStates(visualIndex: Int? = nil) {
    let effectiveIndex = visualIndex ?? selectedSegmentIndex
    for (index, button) in buttons.enumerated() {
      let isSelected = index == effectiveIndex
      var config = button.configuration
      config?.baseForegroundColor = isSelected ? .label : Self.unselectedTextColor
      config?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
        var outgoing = incoming
        outgoing.font = Self.segmentFont(weight: isSelected ? .semibold : .medium)
        return outgoing
      }
      button.configuration = config
      var traits = button.accessibilityTraits
      if isSelected {
        traits.insert(.selected)
      } else {
        traits.remove(.selected)
      }
      button.accessibilityTraits = traits
    }
  }

  private func moveIndicator(to index: Int, animated: Bool) {
    guard buttons.indices.contains(index) else { return }
    let targetFrame = indicatorFrame(for: index)
    guard targetFrame.width > 0 else { return }
    let key = Self.indicatorAnimationKey
    if animated == false || UIAccessibility.isReduceMotionEnabled {
      indicator.layer.removeAnimation(forKey: key)
      indicator.frame = targetFrame
      return
    }

    let fromX = indicator.layer.presentation()?.position.x ?? indicator.center.x
    indicator.layer.removeAnimation(forKey: key)
    // 模型值先落到目标：动画期间按钮仍可点，新的弹簧会从 presentation 层接手。
    indicator.frame = targetFrame

    let spring = CASpringAnimation(keyPath: "position.x")
    let mass = TiebaMotionSpec.Spring.ios26Mass
    let stiffness = TiebaMotionSpec.Spring.ios26Stiffness
    spring.mass = mass
    spring.stiffness = stiffness
    spring.damping = 2 * sqrt(stiffness * mass) * Metrics.indicatorDampingRatio
    spring.fromValue = fromX
    spring.toValue = targetFrame.midX
    spring.duration = spring.settlingDuration
    spring.isRemovedOnCompletion = true
    TiebaAnimationFrameRate.align(spring, to: self)
    indicator.layer.add(spring, forKey: key)
  }

  // MARK: - 跟手拖动

  override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
    let velocity = pan.velocity(in: self)
    return abs(velocity.x) > abs(velocity.y)
  }

  @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
    switch gesture.state {
    case .began:
      panStartIndicatorX = indicator.layer.presentation()?.position.x ?? indicator.center.x
      panPreviewIndex = selectedSegmentIndex
      indicator.layer.removeAnimation(forKey: Self.indicatorAnimationKey)
    case .changed:
      guard let first = buttons.first, let last = buttons.last else { return }
      let proposedX = panStartIndicatorX + gesture.translation(in: self).x
      let x = min(max(proposedX, first.frame.midX), last.frame.midX)
      indicator.center = CGPoint(x: x, y: indicator.center.y)
      let preview = nearestIndex(to: x)
      if preview != panPreviewIndex {
        panPreviewIndex = preview
        updateButtonStates(visualIndex: preview)
      }
    case .ended:
      let projectedX = indicator.center.x + gesture.velocity(in: self).x * 0.08
      let target = nearestIndex(to: projectedX)
      let previous = selectedSegmentIndex
      selectedSegmentIndex = target
      updateButtonStates()
      moveIndicator(to: target, animated: true)
      if target != previous {
        sendActions(for: .valueChanged)
      }
    case .cancelled, .failed:
      updateButtonStates()
      moveIndicator(to: selectedSegmentIndex, animated: true)
    default:
      break
    }
  }

  private func nearestIndex(to x: CGFloat) -> Int {
    guard buttons.count > 0 else { return 0 }
    var result = 0
    var minDistance = CGFloat.greatestFiniteMagnitude
    for (index, button) in buttons.enumerated() {
      let distance = abs(button.frame.midX - x)
      if distance < minDistance {
        minDistance = distance
        result = index
      }
    }
    return result
  }
}
