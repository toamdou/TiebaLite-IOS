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

  /// - Parameter fieldHeight: 搜索框高度（对齐旧页 `TiebaSearchBar` 的 36pt，
  ///   也是系统搜索框的自然高度）。
  public init(fieldHeight: CGFloat = 36) {
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
}
