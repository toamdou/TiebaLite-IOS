// Home 可读语义色：小字号正文/图标在 light/dark/Increase Contrast 下都有明确档位。
// 蓝色只保留现有品牌蓝 #2563EB（Increase Contrast 用同色相更深档），不引入第三套蓝色。
import UIKit

enum TiebaHomeAccessibleColor {
  /// 主标题/正文的近黑色：比纯黑柔和，仍远高于正文 4.5:1。
  static let primaryText = UIColor { trait in
    if trait.accessibilityContrast == .high { return .label }
    return trait.userInterfaceStyle == .dark
      ? UIColor(white: 0.92, alpha: 1)
      : UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)
  }

  static let secondaryText = UIColor { trait in
    if trait.accessibilityContrast == .high { return .label }
    if trait.userInterfaceStyle == .dark { return UIColor(white: 0.66, alpha: 1) }
    return UIColor(red: 0.408, green: 0.408, blue: 0.435, alpha: 1)
  }

  static let tertiaryIcon = UIColor { trait in
    if trait.accessibilityContrast == .high { return .label }
    if trait.userInterfaceStyle == .dark { return UIColor(white: 0.60, alpha: 1) }
    return UIColor(red: 0.478, green: 0.478, blue: 0.510, alpha: 1)
  }

  /// 品牌填充：亮/暗都保持 #2563EB，Increase Contrast 用同色相更深档。
  static let brand = UIColor { trait in
    if trait.accessibilityContrast == .high {
      return UIColor(red: 0.02, green: 0.34, blue: 0.80, alpha: 1)
    }
    return UIColor(red: CGFloat(0x0A) / 255, green: CGFloat(0x6C) / 255, blue: 1, alpha: 1)
  }

  /// 品牌色作为小字号前景/链接时必须满足暗色底 4.5:1：暗色用同色相提升明度版。
  static let brandForeground = UIColor { trait in
    if trait.userInterfaceStyle == .dark {
      return trait.accessibilityContrast == .high
        ? UIColor(red: 0.76, green: 0.86, blue: 1, alpha: 1)
        : UIColor(red: 0.39, green: 0.66, blue: 1, alpha: 1)
    }
    return trait.accessibilityContrast == .high
      ? UIColor(red: 0.02, green: 0.27, blue: 0.67, alpha: 1)
      : UIColor(red: CGFloat(0x0A) / 255, green: CGFloat(0x6C) / 255, blue: 1, alpha: 1)
  }

  static let onBrand: UIColor = .white
}
