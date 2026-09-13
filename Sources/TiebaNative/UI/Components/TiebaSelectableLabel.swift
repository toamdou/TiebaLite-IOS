import UIKit

/// 可选中的自撑高文本（原 RN `<Text selectable>`）。
///
/// 系统实现就是只读 `UITextView`：`isEditable = false` 关编辑、`isSelectable = true`
/// 给系统选择菜单（长按选词/全选/拷贝），`isScrollEnabled = false` 让高度随内容长。
/// 不手写选择逻辑——那正是要避免的重造。
final class TiebaSelectableLabel: UITextView {
  private var measuredWidth: CGFloat = 0

  init(font: UIFont, color: UIColor, alignment: NSTextAlignment = .natural) {
    super.init(frame: .zero, textContainer: nil)
    self.font = font
    textColor = color
    textAlignment = alignment
    isEditable = false
    isSelectable = true
    isScrollEnabled = false
    backgroundColor = .clear
    textContainerInset = .zero
    textContainer.lineFragmentPadding = 0
    adjustsFontForContentSizeCategory = true
    setContentCompressionResistancePriority(.required, for: .vertical)
    // 宽度由容器（栈/单元格）给，别拿文字固有宽度去撑布局。
    setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// 宽度变了要手动作废一次：UITextView 不会因 frame 宽度变化自动重报高度，
  /// 换行行数变了还按旧高度布局 → 截断/吞行。
  override func layoutSubviews() {
    super.layoutSubviews()
    guard bounds.width != measuredWidth else { return }
    measuredWidth = bounds.width
    invalidateIntrinsicContentSize()
  }
}
