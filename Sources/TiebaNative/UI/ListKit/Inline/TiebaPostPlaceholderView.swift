// 从 TiebaPostRowInline.swift 拆出（按类型分文件，纯搬运、整类型逐字搬走）。

import UIKit

// MARK: - 媒体占位条（hideMedia / blockVideo）

final class TiebaPostPlaceholderView: UIView {
  private let iconView = UIImageView()
  private let label = UILabel()

  override init(frame: CGRect) {
    super.init(frame: frame)
    layer.cornerRadius = 10
    layer.cornerCurve = .continuous
    iconView.contentMode = .scaleAspectFit
    addSubview(iconView)
    // 帖内媒体占位条（"[图片]"/"[视频已屏蔽]"）：属于帖子卡片内容，走正文级。
    label.font = TiebaSimpleText.bodyFont(size: 13, weight: .regular)
    addSubview(label)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  func configure(icon: String, text: String, palette: TiebaFeedRowPalette) {
    backgroundColor = palette.chip
    layer.borderWidth = 0
    layer.borderColor = UIColor.clear.cgColor
    iconView.image = TiebaSymbols.image(icon, pointSize: 14, weight: .regular)
    iconView.tintColor = palette.textSecondary
    label.text = text
    label.textColor = palette.textSecondary
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    iconView.frame = CGRect(x: 10, y: (bounds.height - 16) / 2, width: 16, height: 16)
    label.sizeToFit()
    label.frame = CGRect(
      x: 32,
      y: (bounds.height - label.bounds.height) / 2,
      width: max(bounds.width - 42, 0),
      height: label.bounds.height
    )
  }
}
