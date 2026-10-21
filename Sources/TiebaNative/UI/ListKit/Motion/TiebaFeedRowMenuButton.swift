// 从 TiebaFeedRowMotionViews.swift 拆出（按类型分文件，纯搬运、整类型逐字搬走）。

import UIKit

// MARK: - 右上角菜单钮（UIButton.Configuration + 44pt 命中区）

/// 卡片右上角「更多」钮：26×26 槽位、ellipsis、textTertiary（与帖子页的更多钮同形）。
/// 原设计是 xmark（RN closeButton 直译），但它的动作是弹出「不感兴趣/屏蔽/复制标题」
/// 菜单、并非关闭卡片，iOS 信息流此处惯例也是省略号（2026-09-19 改）。
// 访问级 private → internal（H10 拆分，Lead 裁决 B）：final 被留在 TiebaFeedRowView.swift 的主类 TiebaFeedRowView 引用，
// 拆分后跨文件 private 不可见；只放宽这一处，其余成员访问级不动。
final class TiebaFeedRowMenuButton: UIButton {
  /// 命中区下限（RN hitSlop=8 等价；26 视觉 + 两侧 9 = 44pt，行内布局仍按 26）。
  private static let minHitSide: CGFloat = 44

  /// 命中矩形：bounds 之外外扩到 ≥44pt（不改变视觉尺寸与帧计划占位）。
  var hitFrame: CGRect {
    let dx = max((Self.minHitSide - bounds.width) / 2, 0)
    let dy = max((Self.minHitSide - bounds.height) / 2, 0)
    return bounds.insetBy(dx: -dx, dy: -dy)
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    var config = UIButton.Configuration.plain()
    config.image = UIImage(
      systemName: "ellipsis",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
    )
    config.contentInsets = .zero
    configuration = config
    isAccessibilityElement = true
    accessibilityLabel = "更多操作"
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  func configure(tint: UIColor) {
    var config = configuration ?? .plain()
    config.baseForegroundColor = tint
    configuration = config
  }

  /// hitSlop 等价：bounds 外的触摸也归本控件（cell 的整卡点击靠
  /// TiebaFeedRowView.ownsInteraction 的同一 hitFrame 让位）。
  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    hitFrame.contains(point)
  }
}
