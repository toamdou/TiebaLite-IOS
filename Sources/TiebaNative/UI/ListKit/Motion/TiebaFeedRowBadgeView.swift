// 从 TiebaFeedRowMotionViews.swift 拆出（按类型分文件，纯搬运、整类型逐字搬走）。

import UIKit

// MARK: - 深色小角标（长图 / GIF / 计数）

// 访问级 private → internal（H10 拆分续）：类型原为文件级 private，被同文件的
// TiebaFeedRowMediaItemView 使用，拆到独立文件后必须放宽到 internal。
// 角标底色常量 tiebaBadgeBackground 留在 TiebaFeedRowMotionViews.swift（TiebaFeedRowView 也用它）。
final class TiebaFeedRowBadgeView: UIView {
  private let label = UILabel()
  private let iconView = UIImageView()
  private let iconWidth: CGFloat
  /// 无底模式（用户口径，GIF 角标专用）：不要胶囊底，纯白字 + 阴影压住亮图。
  private let backgroundless: Bool

  init(text: String, systemImage: String?, backgroundless: Bool = false) {
    self.backgroundless = backgroundless
    iconWidth = systemImage == nil ? 0 : 10
    super.init(frame: .zero)
    if backgroundless {
      backgroundColor = .clear
      // 阴影挂在 label 的层上：无底时白色文字需要暗描边才在浅图上可读
      //（容器层加阴影会连同透明背景一起被过滤掉，只能逐字描）。
      label.layer.shadowColor = UIColor.black.cgColor
      label.layer.shadowOpacity = 0.8
      label.layer.shadowRadius = 1.5
      label.layer.shadowOffset = CGSize(width: 0, height: 0.5)
    } else {
      backgroundColor = tiebaBadgeBackground
    }
    label.text = text
    label.font = .systemFont(ofSize: 11, weight: .semibold)
    label.textColor = .white
    addSubview(label)
    iconView.tintColor = .white
    iconView.contentMode = .scaleAspectFit
    if let systemImage {
      iconView.image = UIImage(
        systemName: systemImage,
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
      )
    }
    if iconWidth > 0 { addSubview(iconView) }
    isHidden = true
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override func sizeThatFits(_ size: CGSize) -> CGSize {
    let labelSize = label.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
    let gap: CGFloat = iconWidth > 0 ? 3 : 0
    let padding: CGFloat = backgroundless ? 0 : 14
    let vertical: CGFloat = backgroundless ? 0 : 6
    let height = max(iconWidth, labelSize.height) + vertical
    // A7（移植自上游 submodules/TextBadgeComponent/Sources/TextBadgeComponent.swift:139）：
    // 徽章底"至少是个圆" —— 单字符（"1"、"图"）算出来比高还窄时把宽撑到与高相等，
    // 否则是一个竖椭圆。多字符徽章本来就更宽，这一项不改变它们。
    return CGSize(
      width: max(iconWidth + gap + labelSize.width + padding, height),
      height: height
    )
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    // A7（上游 :154 的 generateStretchableFilledCircleImage + template tint）：圆角按**当前**
    // 高度取半，而不是钉死 10 —— 纯色填充下这与"可拉伸圆头图"逐像素等价，字号/内边距变了
    // 也仍是胶囊（固定半径在高度变大时会退化成圆角矩形）。无底模式没有底。
    if !backgroundless {
      layer.cornerRadius = bounds.height / 2
    }
    let gap: CGFloat = iconWidth > 0 ? 3 : 0
    let horizontal: CGFloat = backgroundless ? 0 : 7
    iconView.frame = CGRect(x: horizontal, y: (bounds.height - iconWidth) / 2, width: iconWidth, height: iconWidth)
    label.frame = CGRect(
      x: horizontal + iconWidth + gap,
      y: 0,
      width: max(bounds.width - horizontal * 2 - iconWidth - gap, 0),
      height: bounds.height
    )
  }
}
