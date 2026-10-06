// 标签选择器：选中/未选中 = **两份预排版的文本**按 fraction 交叉淡化；指示器 = **跨项矩形 lerp**。
//
// 移植自上游 submodules/TabSelectorComponent/Sources/TabSelectorComponent.swift:886-944
//（title / selectedTitle 两个子节点，各按 selectionFraction 设 opacity；:918-921 的选中色回退）
// 与 submodules/HorizontalTabsComponent/Sources/HorizontalTabsComponent.swift:818-833
//（指示器矩形 = 当前项与待选项 frame 的逐分量线性插值，比例 |fraction|）。
//
// 为什么是「两份文本 + 连续 position」而不是「改 textColor + 动画到目标」：
//   ① 颜色动画中途会经过半透明态（压在彩色底上很难看），含 emoji / 自定义表情的文本
//      根本没法做颜色动画；
//   ② 颜色/位置动画只能从头播一遍，**跟不上手势** —— 手指拖到一半，指示器必须也在半路。
//   两份文本**同字体**（只有颜色不同），所以两份的排版矩形逐像素相同，切换时不会跳字。
//
// 系统 chrome 全部沿用（背景材质、圆角、点击命中、无障碍都由 UISegmentedControl 给）：
// 本类只把系统自绘的标题与选中块设成透明（selectedSegmentTintColor / setTitleTextAttributes，
// 全是公开 API），再在同一几何上叠自己的指示器与两份文本。**不碰任何私有子视图层级**。
import UIKit

/// 指示器几何：跨项四分量线性插值（移植自上游 HorizontalTabsComponent.swift:818-833）。
enum TiebaTabIndicator {
  static func lerp(_ from: CGRect, _ to: CGRect, _ fraction: CGFloat) -> CGRect {
    let t = min(max(fraction, 0), 1)
    return CGRect(
      x: from.minX + (to.minX - from.minX) * t,
      y: from.minY + (to.minY - from.minY) * t,
      width: from.width + (to.width - from.width) * t,
      height: from.height + (to.height - from.height) * t
    )
  }
}

final class TiebaTabSelector: UISegmentedControl {
  /// 连续位置：i = 第 i 项完全选中，i+0.5 = i 与 i+1 各半。指示器与两份文本都由它推导。
  private(set) var switchPosition: CGFloat = 0
  /// 点选后指示器滑到目标项的时长。
  var slideDuration: Double = 0.25
  /// 选中项回调（系统 .valueChanged 之后）。
  var onSelect: ((Int) -> Void)?

  /// 指示器（唯一可见的选中底：系统那块被设成透明）。
  private let indicator = UIView()
  private var labels: [(normal: UILabel, selected: UILabel)] = []
  private var positionAnimator: TiebaDisplayLinkAnimator?
  /// 正在滑向的目标项（同一目标重复 select 不重启动画）。
  private var animatingTarget: Int?

  /// 指示器四周内缩（系统选中块与分段边界之间的留白）。
  private let indicatorInset: CGFloat = 2
  /// 选中底：浅色下白、深色下提亮一档（不再有系统玻璃块的默认外观可用，自己给同族色）。
  var indicatorColor: UIColor = UIColor { traits in
    traits.userInterfaceStyle == .dark ? UIColor(white: 1.0, alpha: 0.16) : .white
  } {
    didSet { indicator.backgroundColor = indicatorColor }
  }
  var selectedTextColor: UIColor = .label {
    didSet { for pair in labels { pair.selected.textColor = selectedTextColor } }
  }
  var normalTextColor: UIColor = .secondaryLabel {
    didSet { for pair in labels { pair.normal.textColor = normalTextColor } }
  }

  init(items: [String]) {
    super.init(items: items)
    // 系统自绘的标题与选中块透明掉（公开 API；见文件头）。
    selectedSegmentTintColor = .clear
    let clear: [NSAttributedString.Key: Any] = [.foregroundColor: UIColor.clear]
    for state: UIControl.State in [.normal, .selected, .highlighted, [.selected, .highlighted]] {
      setTitleTextAttributes(clear, for: state)
    }
    indicator.isUserInteractionEnabled = false
    indicator.backgroundColor = indicatorColor
    indicator.layer.cornerCurve = .continuous
    // 压在系统背景之上（系统的选中块已被设成透明），后面的两份文本再压在它之上。
    addSubview(indicator)
    // 两份文本同字体（只有颜色不同）：排版矩形一致，交叉淡化时不跳字。
    let font = TiebaSimpleText.font(size: 13, weight: .medium)
    for title in items {
      let normal = makeLabel(title: title, font: font, color: normalTextColor)
      let selected = makeLabel(title: title, font: font, color: selectedTextColor)
      selected.alpha = 0
      labels.append((normal, selected))
      addSubview(normal)
      addSubview(selected)
    }
    addTarget(self, action: #selector(handleValueChanged), for: .valueChanged)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private func makeLabel(title: String, font: UIFont, color: UIColor) -> UILabel {
    let label = UILabel()
    label.text = title
    label.font = font
    label.textColor = color
    label.textAlignment = .center
    label.numberOfLines = 1
    label.lineBreakMode = .byTruncatingTail
    label.isUserInteractionEnabled = false
    return label
  }

  // MARK: - 对外

  /// 点选/程序化选中。animated = true 时指示器从**当前连续位置**滑过去（不瞬移、不二段式）。
  func select(_ index: Int, animated: Bool) {
    guard index >= 0, index < numberOfSegments else { return }
    // 已在滑向同一目标：不打断（点选路径里调用方会回灌一次 select）。
    guard animatingTarget != index else { return }
    selectedSegmentIndex = index
    positionAnimator?.invalidate()
    positionAnimator = nil
    let from = switchPosition
    let to = CGFloat(index)
    guard animated, from != to else {
      animatingTarget = nil
      switchPosition = to
      applyPosition()
      return
    }
    animatingTarget = index
    positionAnimator = TiebaDisplayLinkAnimator(
      duration: slideDuration,
      from: 0,
      to: 1,
      update: { [weak self] t in
        guard let self else { return }
        // 缓出（起步快、贴到目标前慢下来）：与上游指示器的弹簧同族的手感。
        let eased = 1 - pow(1 - t, 3)
        self.switchPosition = from + (to - from) * eased
        self.applyPosition()
      },
      completion: { [weak self] in
        self?.positionAnimator = nil
        self?.animatingTarget = nil
        self?.switchPosition = to
        self?.applyPosition()
      }
    )
  }

  /// 手势驱动：把「页面切换进度」直接灌进来，指示器与两份文本连续跟随。
  /// position 是连续位置（i → i+1 之间取小数）；isDragging = false 时顺带对齐系统选中态。
  func setSwitchPosition(_ position: CGFloat, isDragging: Bool) {
    positionAnimator?.invalidate()
    positionAnimator = nil
    animatingTarget = nil
    switchPosition = min(max(position, 0), CGFloat(max(numberOfSegments - 1, 0)))
    if !isDragging {
      let rounded = Int(switchPosition.rounded())
      if rounded != selectedSegmentIndex { selectedSegmentIndex = rounded }
    }
    applyPosition()
  }

  // MARK: - 几何

  override func layoutSubviews() {
    super.layoutSubviews()
    let count = numberOfSegments
    guard count > 0, bounds.width > 0 else { return }
    let each = bounds.width / CGFloat(count)
    for (index, pair) in labels.enumerated() {
      let rect = CGRect(x: CGFloat(index) * each, y: 0, width: each, height: bounds.height)
      pair.normal.frame = rect
      pair.selected.frame = rect
    }
    // 系统在选中态变化时会插自己的子视图：每趟布局把指示器与两份文本重新提到最上
    //（只调自己加的这三个视图的 z 序，不碰系统的层级结构）。
    bringSubviewToFront(indicator)
    for pair in labels {
      bringSubviewToFront(pair.normal)
      bringSubviewToFront(pair.selected)
    }
    applyPosition()
  }

  private func segmentRect(_ index: Int) -> CGRect {
    let each = bounds.width / CGFloat(max(numberOfSegments, 1))
    return CGRect(
      x: CGFloat(index) * each + indicatorInset,
      y: indicatorInset,
      width: max(each - indicatorInset * 2, 0),
      height: max(bounds.height - indicatorInset * 2, 0)
    )
  }

  /// 全部视觉由这一次调用推导：指示器矩形（跨项 lerp）+ 每项两份文本的互补 alpha。
  private func applyPosition() {
    let count = numberOfSegments
    guard count > 0, bounds.width > 0 else { return }
    let position = min(max(switchPosition, 0), CGFloat(count - 1))
    let lower = Int(position.rounded(.down))
    let upper = min(lower + 1, count - 1)
    let rect = TiebaTabIndicator.lerp(segmentRect(lower), segmentRect(upper), position - CGFloat(lower))
    indicator.frame = rect
    indicator.layer.cornerRadius = rect.height / 2
    for (index, pair) in labels.enumerated() {
      // 选中权重 = 1 - |position - i|（上游 selectionFraction = 1 - |transitionFraction| 同式）。
      let selected = max(0, 1 - abs(position - CGFloat(index)))
      pair.selected.alpha = selected
      pair.normal.alpha = 1 - selected
    }
  }

  @objc private func handleValueChanged() {
    let index = selectedSegmentIndex
    guard index >= 0, index < numberOfSegments else { return }
    select(index, animated: true)
    onSelect?(index)
  }
}
