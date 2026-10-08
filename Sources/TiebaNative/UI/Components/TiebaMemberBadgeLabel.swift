//  吧成员徽标（吧务/等级/头衔一类的小标）。\n//  从 Features/Forum/TiebaForumMembersViewController.swift 拆出：列表页头也用。

import UIKit

final class TiebaMemberBadgeLabel: UILabel {
  var contentInsets = UIEdgeInsets(top: 1.5, left: 7, bottom: 1.5, right: 7)

  override func drawText(in rect: CGRect) {
    super.drawText(in: rect.inset(by: contentInsets))
  }

  override var intrinsicContentSize: CGSize {
    let size = super.intrinsicContentSize
    return CGSize(
      width: size.width + contentInsets.left + contentInsets.right,
      height: size.height + contentInsets.top + contentInsets.bottom
    )
  }
}
