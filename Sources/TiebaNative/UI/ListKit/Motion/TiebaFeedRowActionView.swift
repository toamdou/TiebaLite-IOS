// 从 TiebaFeedRowMotionViews.swift 拆出（按类型分文件，纯搬运、整类型逐字搬走）。

import UIKit

// MARK: - 操作栏单元（图标 + 计数）

/// UIControl 跟踪（不是手势）：滚动开始时 UIScrollView 会 cancel 子视图
/// tracking，不抢 scroll pan、也不会留悬挂的按压状态。
// 访问级 private → internal（H10 拆分，Lead 裁决 B）：final 被留在 TiebaFeedRowView.swift 的主类 TiebaFeedRowView 引用，
// 拆分后跨文件 private 不可见；只放宽这一处，其余成员访问级不动。
final class TiebaFeedRowActionView: UIControl {
  private let iconView = UIImageView()
  private let label = UILabel()

  override init(frame: CGRect) {
    super.init(frame: frame)
    isAccessibilityElement = false
    iconView.contentMode = .scaleAspectFit
    iconView.isAccessibilityElement = false
    label.textAlignment = .left
    label.lineBreakMode = .byTruncatingTail
    label.numberOfLines = 1
    label.adjustsFontSizeToFitWidth = true
    label.minimumScaleFactor = 0.7
    label.isAccessibilityElement = false
    addSubview(iconView)
    addSubview(label)
  }

  /// UIControl 的视觉可随行窄化，但可点区域不小于 44pt。
  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    let dx = max((44 - bounds.width) / 2, 0)
    let dy = max((44 - bounds.height) / 2, 0)
    return bounds.insetBy(dx: -dx, dy: -dy).contains(point)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  func configure(systemImage: String, text: String, tint: UIColor, font: UIFont) {
    iconView.image = TiebaSymbols.image(systemImage, pointSize: 17, weight: .regular)
    iconView.tintColor = tint
    label.text = text
    label.font = font
    label.textColor = tint
  }

  /// 由行的帧计划直接摆放（frame 为按钮局部坐标）。
  /// AX 大字号下 icon+count 可能超过单键宽度：先夹在控件内，再由 label 的最小缩放收住。
  func layout(iconFrame: CGRect, labelFrame: CGRect) {
    let iconWidth = min(max(iconFrame.width, 0), bounds.width)
    let iconX = min(max(iconFrame.minX, 2), max(bounds.width - iconWidth - 2, 2))
    iconView.frame = CGRect(x: iconX, y: iconFrame.minY, width: iconWidth, height: iconFrame.height)
    let labelX = min(max(labelFrame.minX, iconX + iconWidth + 4), bounds.width)
    label.frame = CGRect(
      x: labelX,
      y: labelFrame.minY,
      width: max(bounds.width - labelX - 2, 0),
      height: labelFrame.height
    )
  }

  /// 点赞 pop / 计数跳动的动画载体（RN 的两层 Animated.View）。
  var iconLayer: CALayer { iconView.layer }
  var labelLayer: CALayer { label.layer }
}
