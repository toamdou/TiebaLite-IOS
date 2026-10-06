// 从 TiebaRowMetrics.swift 拆出（H10 千行文件拆分）：行内配色（JS 主题下发）。
// 纯搬运：整类型逐字搬走。

import UIKit

public nonisolated struct TiebaFeedRowPalette: @unchecked Sendable, Equatable {
  public var card: UIColor
  public var borderCard: UIColor
  public var text: UIColor
  public var textSecondary: UIColor
  public var textTertiary: UIColor
  public var primary: UIColor
  public var chip: UIColor
  public var onChip: UIColor
  public var separator: UIColor
  public var liked: UIColor
  public var warning: UIColor
  public var placeholder: UIColor
  public var avatarFallback: UIColor
  /// 应用是否深色（媒体占位底色等由它派生，对齐 MediaPager 的 isDark 分支）。
  public var isNight: Bool

  public static let `default` = TiebaFeedRowPalette(
    card: Self.adaptive(light: 0xFFFFFF, dark: 0x1C1C1E),
    borderCard: UIColor { traits in
      traits.userInterfaceStyle == .dark
        ? UIColor.white.withAlphaComponent(0.08)
        : UIColor.black.withAlphaComponent(0.06)
    },
    text: .label,
    textSecondary: .secondaryLabel,
    textTertiary: .tertiaryLabel,
    primary: Self.adaptive(light: 0x2563EB, dark: 0x60A5FA),
    // 吧名徽章走 UIKit 原生语义填充：强调色留给可点控件，徽章用
    // secondarySystemFill + secondaryLabel（浅深色自适应，不与主色抢眼）。
    chip: .secondarySystemFill,
    onChip: .secondaryLabel,
    separator: .separator,
    liked: Self.adaptive(light: 0xFF2D55, dark: 0xFF375F),
    warning: .systemOrange,
    placeholder: UIColor { traits in
      traits.userInterfaceStyle == .dark
        ? UIColor.white.withAlphaComponent(0.06)
        : UIColor.black.withAlphaComponent(0.04)
    },
    avatarFallback: .secondarySystemBackground,
    isNight: false
  )

  /// JS 主题字典 → 调色板；缺失/解析失败的键保留默认值（旧 JS 不下发时
  /// 行为与迁移前完全一致）。
  public init(dict: [String: Any]) {
    var palette = TiebaFeedRowPalette.default
    func apply(_ key: String, _ assign: (UIColor) -> Void) {
      guard let raw = dict[key] as? String, let color = tiebaColor(from: raw) else { return }
      assign(color)
    }
    apply("card") { palette.card = $0 }
    apply("borderCard") { palette.borderCard = $0 }
    apply("text") { palette.text = $0 }
    apply("textSecondary") { palette.textSecondary = $0 }
    apply("textTertiary") { palette.textTertiary = $0 }
    apply("primary") { palette.primary = $0 }
    apply("chip") { palette.chip = $0 }
    apply("onChip") { palette.onChip = $0 }
    apply("separator") { palette.separator = $0 }
    apply("liked") { palette.liked = $0 }
    apply("warning") { palette.warning = $0 }
    apply("avatarFallback") { palette.avatarFallback = $0 }
    if let isNight = dict["isNight"] as? Bool {
      palette.isNight = isNight
    }
    palette.placeholder = palette.isNight
      ? UIColor.white.withAlphaComponent(0.06)
      : UIColor.black.withAlphaComponent(0.04)
    self = palette
  }

  private init(
    card: UIColor,
    borderCard: UIColor,
    text: UIColor,
    textSecondary: UIColor,
    textTertiary: UIColor,
    primary: UIColor,
    chip: UIColor,
    onChip: UIColor,
    separator: UIColor,
    liked: UIColor,
    warning: UIColor,
    placeholder: UIColor,
    avatarFallback: UIColor,
    isNight: Bool
  ) {
    self.card = card
    self.borderCard = borderCard
    self.text = text
    self.textSecondary = textSecondary
    self.textTertiary = textTertiary
    self.primary = primary
    self.chip = chip
    self.onChip = onChip
    self.separator = separator
    self.liked = liked
    self.warning = warning
    self.placeholder = placeholder
    self.avatarFallback = avatarFallback
    self.isNight = isNight
  }

  private static func adaptive(light: UInt32, dark: UInt32) -> UIColor {
    UIColor { traits in
      traits.userInterfaceStyle == .dark ? color(dark) : color(light)
    }
  }

  private static func color(_ hex: UInt32) -> UIColor {
    UIColor(
      red: CGFloat((hex >> 16) & 0xFF) / 255,
      green: CGFloat((hex >> 8) & 0xFF) / 255,
      blue: CGFloat(hex & 0xFF) / 255,
      alpha: 1
    )
  }
}
