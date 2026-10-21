// 发现 tab 根屏：紧凑 iOS 26 玻璃分段（推荐 | 关注 | 热榜）+ 三个常驻子页。
// 分段指示器跟手、切页淡入 + 轻微位移/弹簧收势；子页滚动只在跨阈值时收缩 chrome。
import UIKit

final class TiebaExploreViewController: UIViewController, TiebaTabReselectable, TiebaNativeScreen {
  private let segmented = TiebaExploreSegmentedControl(titles: ["推荐", "关注", "热榜"])
  private let titleLabel = UILabel()
  private let container = UIView()
  private let personalized = TiebaExploreFeedViewController(segment: .personalized)
  private let concern = TiebaExploreFeedViewController(segment: .concern)
  private let hot = TiebaHotListViewController()
  private var segments: [UIViewController] { [personalized, concern, hot] }
  private var activeIndex = 0
  private var current: UIViewController?
  private var chromeIsCompact = false
  private var compactHeaderConstraints: [NSLayoutConstraint] = []
  private var accessibilityHeaderConstraints: [NSLayoutConstraint] = []
  private var headerTraitRegistration: UITraitChangeRegistration?

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = TiebaListAppearance.pageBackground
    configureChromeReporting()
    titleLabel.text = "动态"
    titleLabel.font = TiebaSimpleText.font(size: 28, weight: .semibold)
    titleLabel.adjustsFontForContentSizeCategory = true
    titleLabel.numberOfLines = 1
    titleLabel.textColor = TiebaExploreSurface.readablePrimary
    titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
    titleLabel.accessibilityTraits = .header
    segmented.addTarget(self, action: #selector(handleSegmentChange), for: .valueChanged)
    segmented.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    for subview in [titleLabel, segmented, container] as [UIView] {
      subview.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(subview)
    }
    let safe = view.safeAreaLayoutGuide
    NSLayoutConstraint.activate([
      titleLabel.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 20),
      segmented.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -16),
      container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      container.topAnchor.constraint(equalTo: segmented.bottomAnchor, constant: 8),
      container.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    compactHeaderConstraints = [
      titleLabel.centerYAnchor.constraint(equalTo: segmented.centerYAnchor),
      segmented.topAnchor.constraint(equalTo: safe.topAnchor, constant: 2),
      segmented.leadingAnchor.constraint(
        greaterThanOrEqualTo: titleLabel.trailingAnchor,
        constant: 12
      ),
    ]
    accessibilityHeaderConstraints = [
      titleLabel.topAnchor.constraint(equalTo: safe.topAnchor, constant: 8),
      titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: safe.trailingAnchor, constant: -20),
      segmented.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
      segmented.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 16),
    ]
    updateHeaderLayout(animated: false)
    headerTraitRegistration = registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
      (controller: TiebaExploreViewController, _: UITraitCollection) in
      controller.updateHeaderLayout(animated: true)
      controller.personalized.contentSizeDidChange()
      controller.concern.contentSizeDidChange()
      controller.hot.contentSizeDidChange()
    }
    show(0, animated: false)
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    // 只让当前可见段做零网络的本地回推（不可见段会白发一次）。
    (segments[activeIndex] as? TiebaExploreFeedViewController)?.handleFocus()
    updateChrome(for: activeIndex, animated: false)
    #if DEBUG
    // 无头 UI 冒烟：用 simctl launch 的 env 自动触发一次「底栏重按刷新」，
    // 用于对刷新后的 top anchor 做截图/日志验收。Release 不存在此路径。
    if ProcessInfo.processInfo.environment["TIEBA_UI_AUTO_REFRESH"] == "1" {
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
        self?.tabReselected()
      }
    }
    #endif
  }

  /// 底栏重复点击（tab 根屏）：只有当前可见段响应。
  func tabReselected() {
    (segments[activeIndex] as? TiebaTabReselectable)?.tabReselected()
  }

  func screenThemeDidChange() {
    view.backgroundColor = TiebaListAppearance.pageBackground
  }

  /// AX 下标题与分段改为纵向，分段占满宽度；标准字号保留标题在左、分段在右。
  private func updateHeaderLayout(animated: Bool) {
    let accessibilityLayout = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
    NSLayoutConstraint.deactivate(compactHeaderConstraints)
    NSLayoutConstraint.deactivate(accessibilityHeaderConstraints)
    NSLayoutConstraint.activate(
      accessibilityLayout ? accessibilityHeaderConstraints : compactHeaderConstraints
    )
    titleLabel.font = TiebaSimpleText.font(size: 28, weight: .semibold)
    segmented.invalidateIntrinsicContentSize()
    guard animated, UIAccessibility.isReduceMotionEnabled == false else {
      view.setNeedsLayout()
      return
    }
    TiebaAnimation.animate(
      curve: .easeOut,
      duration: TiebaAnimationDuration.stateChange,
      options: [.beginFromCurrentState, .allowUserInteraction],
      animations: {
        self.view.layoutIfNeeded()
      }
    )
  }

  @objc private func handleSegmentChange() {
    let index = segmented.selectedSegmentIndex
    guard index >= 0, index < segments.count else { return }
    TiebaSceneHaptics.fire("segment")
    show(index, animated: true)
  }

  /// 单实例挂载：切换只换视图，子 VC 与其滚动位置/数据都常驻。
  private func show(_ index: Int, animated: Bool) {
    guard index >= 0, index < segments.count else { return }
    let next = segments[index]
    guard next !== current else { return }
    let old = current
    let direction: CGFloat = index > activeIndex ? 1 : -1
    let shouldAnimate = animated
      && old != nil
      && UIAccessibility.isReduceMotionEnabled == false
      && view.window != nil

    // 快速连点：把上一轮仍在退场的子页清干净，保证容器里最多 old + next 两层。
    for child in children where child !== old {
      detach(child)
    }
    if shouldAnimate == false, let old {
      detach(old)
    }

    attach(next)
    current = next
    activeIndex = index
    if shouldAnimate {
      next.view.alpha = 0
      next.view.transform = CGAffineTransform(translationX: direction * 14, y: 0)
        .scaledBy(x: 0.994, y: 0.994)
    }
    (next as? TiebaExploreFeedViewController)?.handleBecameVisible()
    updateChrome(for: index, animated: false)
    container.layoutIfNeeded()

    guard shouldAnimate, let old else {
      next.view.alpha = 1
      next.view.transform = .identity
      return
    }

    old.view.isUserInteractionEnabled = false
    next.view.isUserInteractionEnabled = false
    UIView.animate(
      withDuration: TiebaAnimationDuration.overlayAppear,
      delay: 0,
      usingSpringWithDamping: Self.pageDampingRatio,
      initialSpringVelocity: 0.12,
      options: [.beginFromCurrentState, .allowUserInteraction],
      animations: {
        next.view.alpha = 1
        next.view.transform = .identity
        old.view.alpha = 0
        old.view.transform = CGAffineTransform(translationX: -direction * 9, y: 0)
      },
      completion: { [weak self] _ in
        guard let self else { return }
        if self.current === next {
          next.view.alpha = 1
          next.view.transform = .identity
          next.view.isUserInteractionEnabled = true
        }
        if self.current !== old {
          self.detach(old)
        }
      }
    )
  }

  // MARK: - 子页装配 / chrome

  private func attach(_ child: UIViewController) {
    addChild(child)
    child.view.translatesAutoresizingMaskIntoConstraints = false
    child.view.isUserInteractionEnabled = true
    container.addSubview(child.view)
    NSLayoutConstraint.activate([
      child.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      child.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      child.view.topAnchor.constraint(equalTo: container.topAnchor),
      child.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
    child.didMove(toParent: self)
  }

  private func detach(_ child: UIViewController) {
    guard child.parent === self else { return }
    child.willMove(toParent: nil)
    child.view.layer.removeAllAnimations()
    child.view.removeFromSuperview()
    child.removeFromParent()
  }

  private func configureChromeReporting() {
    personalized.onChromeScrollChange = { [weak self] offsetY in
      self?.handleChildScroll(offsetY)
    }
    concern.onChromeScrollChange = { [weak self] offsetY in
      self?.handleChildScroll(offsetY)
    }
    hot.onChromeScrollChange = { [weak self] offsetY in
      self?.handleChildScroll(offsetY)
    }
  }

  /// 只跨阈值时改一次 transform / alpha；不在滚动回调里 setNeedsLayout/layoutIfNeeded。
  private func handleChildScroll(_ offsetY: CGFloat) {
    let shouldCompact = chromeIsCompact ? offsetY > 4 : offsetY > 22
    guard shouldCompact != chromeIsCompact else { return }
    chromeIsCompact = shouldCompact
    segmented.setChromeCompact(shouldCompact, animated: true)
  }

  /// 切到新子页时同步它的既有滚动位置：新页若停留在下方，chrome 不会先展开再收。
  private func updateChrome(for index: Int, animated: Bool) {
    let offsetY: CGFloat
    switch index {
    case 0: offsetY = personalized.chromeScrollOffsetY
    case 1: offsetY = concern.chromeScrollOffsetY
    default: offsetY = hot.chromeScrollOffsetY
    }
    let shouldCompact = chromeIsCompact ? offsetY > 4 : offsetY > 22
    guard shouldCompact != chromeIsCompact else { return }
    chromeIsCompact = shouldCompact
    segmented.setChromeCompact(shouldCompact, animated: animated)
  }

  private static var pageDampingRatio: CGFloat {
    let critical = 2 * sqrt(TiebaMotionSpec.Spring.closeStiffness * TiebaMotionSpec.Spring.closeMass)
    return TiebaMotionSpec.Spring.closeDamping / critical
  }
}
