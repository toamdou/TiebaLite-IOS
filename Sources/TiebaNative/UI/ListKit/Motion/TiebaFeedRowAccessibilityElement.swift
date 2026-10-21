// 从 TiebaFeedRowMotionViews.swift 拆出（按类型分文件，纯搬运、整类型逐字搬走）。

import UIKit

// MARK: - 行内可访问元素

/// 行 accessibility container 的单个元素：正文/标题/操作各自一个 VoiceOver 停靠点，
/// 激活时把动作回送到现有 cell 命中分发，不复制任何业务逻辑。
final class TiebaFeedRowAccessibilityElement: UIAccessibilityElement {
  var onActivate: (() -> Bool)?

  override func accessibilityActivate() -> Bool {
    onActivate?() ?? false
  }
}
