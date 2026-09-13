// 发现 tab 根屏（原 src/app/(tabs)/explore.tsx）：顶部分段（推荐 | 关注 | 热榜）
// + 三个常驻子页（各自保留滚动位置）；底栏重复点击 → 当前段回顶 + 刷新。
import UIKit

final class TiebaExploreViewController: UIViewController, TiebaTabReselectable {
  private let segmented = UISegmentedControl(items: ["推荐", "关注", "热榜"])
  private let container = UIView()
  private let personalized = TiebaExploreFeedViewController(segment: .personalized)
  private let concern = TiebaExploreFeedViewController(segment: .concern)
  private let hot = TiebaHotListViewController()
  private var segments: [UIViewController] { [personalized, concern, hot] }
  private var activeIndex = 0
  private var current: UIViewController?

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = TiebaNavigator.shared.chromeTheme.background
    segmented.selectedSegmentIndex = 0
    segmented.addTarget(self, action: #selector(handleSegmentChange), for: .valueChanged)
    for subview in [segmented, container] as [UIView] {
      subview.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(subview)
    }
    NSLayoutConstraint.activate([
      segmented.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
      segmented.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
      segmented.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6),
      container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      container.topAnchor.constraint(equalTo: segmented.bottomAnchor, constant: 6),
      container.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    show(0)
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    // 聚焦自动刷新：只刷当前可见段（不可见段 handleFocus 会白发一次请求）；
    // 热榜只在重选时拉，与旧页一致。
    (segments[activeIndex] as? TiebaExploreFeedViewController)?.handleFocus()
  }

  /// 底栏重复点击（tab 根屏）：只有当前可见段响应。
  func tabReselected() {
    (segments[activeIndex] as? TiebaTabReselectable)?.tabReselected()
  }

  @objc private func handleSegmentChange() {
    let index = segmented.selectedSegmentIndex
    guard index >= 0, index < segments.count else { return }
    TiebaSceneHaptics.fire("toggle")
    show(index)
  }

  /// 单实例挂载：切换只换视图，子 VC 与其滚动位置/数据都常驻
  /// （滚出层级是必须的——宿主按"面积最大的滚动视图"给系统找跟踪对象）。
  private func show(_ index: Int) {
    guard index >= 0, index < segments.count else { return }
    let next = segments[index]
    guard next !== current else { return }
    if let current {
      current.willMove(toParent: nil)
      current.view.removeFromSuperview()
      current.removeFromParent()
    }
    addChild(next)
    next.view.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(next.view)
    NSLayoutConstraint.activate([
      next.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      next.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      next.view.topAnchor.constraint(equalTo: container.topAnchor),
      next.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
    next.didMove(toParent: self)
    current = next
    activeIndex = index
    (next as? TiebaExploreFeedViewController)?.handleBecameVisible()
  }
}
