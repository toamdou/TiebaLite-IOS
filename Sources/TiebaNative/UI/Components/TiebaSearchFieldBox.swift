// ============================================================
// 顶栏搜索栏容器（TiebaSearchFieldBox）
//
// 直接 `navigationItem.titleView = searchBar` 会让搜索框与返回键错行：
// UISearchBar 的内在高度（56）大于 iOS 26 顶栏的内容高，且它把搜索框画在自己
// frame 的顶部，于是搜索框整体偏上（真机实证"铺满了但不在一条直线上"）。
// 外面套这层**无内在尺寸**的容器：顶栏会把无内在尺寸的 titleView 拉伸成可用
// 整条（宽度拿满），栏内再按固定高度 + 垂直居中摆搜索框 → 与返回键同一行。
// ============================================================

import UIKit

/// 顶栏搜索栏容器。用法：`host.navigationItem.titleView = box`，之后照常设
/// `box.searchBar.delegate` / placeholder。
public final class TiebaSearchFieldBox: UIView {
  public let searchBar = UISearchBar()

  private let fieldHeight: CGFloat

  /// - Parameter fieldHeight: 搜索框高度（对齐旧页 `TiebaSearchBar` 的 36pt，
  ///   也是系统搜索框的自然高度）。
  public init(fieldHeight: CGFloat = 36) {
    self.fieldHeight = fieldHeight
    super.init(frame: .zero)
    addSubview(searchBar)
    searchBar.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      searchBar.leadingAnchor.constraint(equalTo: leadingAnchor),
      searchBar.trailingAnchor.constraint(equalTo: trailingAnchor),
      searchBar.centerYAnchor.constraint(equalTo: centerYAnchor),
      searchBar.heightAnchor.constraint(equalToConstant: fieldHeight),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// ⚠️ 容器必须自己报出高度：顶栏只拉伸 titleView 的宽度，高度取自视图自身，
  /// 而本容器没有任何决定自身高度的约束/内在尺寸（搜索框只有 centerY + 定高）
  /// → bounds 高 0，搜索框画在 bounds 之外（不裁剪所以看得见、位置也对），
  /// 但 hitTest 只认 bounds → "看得见点不到"（吧内搜索页实证）。
  public override var intrinsicContentSize: CGSize {
    CGSize(width: UIView.noIntrinsicMetric, height: fieldHeight)
  }
}
