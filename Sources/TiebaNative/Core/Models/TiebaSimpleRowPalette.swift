import UIKit
import Nuke
import NukeExtensions

/// 通用行色板 = 信息流色板（card/text/textSecondary/textTertiary/primary/
/// avatarFallback/isNight…）+ colors.ts 里本批行用到的额外 token。
/// 默认值 = 应用默认亮/暗语义色（与 colors.ts 的 light/dark 表逐值相同）；
/// JS 经 themeColors 下发实际主题后非默认主题的 primary/divider 等生效。
public nonisolated struct TiebaSimpleRowPalette: @unchecked Sendable, Equatable {
  public var base: TiebaFeedRowPalette
  /// colors.divider：吧务成员行 0.5pt 描边。
  public var divider: UIColor
  /// colors.groupFill：吧务说明卡底色。
  public var groupFill: UIColor
  /// colors.surfaceSecondary：计数 chip 底 / 头像占位底。
  public var surfaceSecondary: UIColor
  /// colors.textDisabled：消息时间行 / 吧务尾随箭头。
  public var textDisabled: UIColor
  /// colors.success：消息"赞"类型图标色。
  public var success: UIColor
  /// colors.textOnPrimary：头像首字母色（Avatar.tsx:117）。
  public var textOnPrimary: UIColor

  public static let `default` = TiebaSimpleRowPalette(
    base: .default,
    divider: TiebaSimpleRowPalette.adaptive(light: 0x3C3C43, lightAlpha: 0.12,
                                            dark: 0x545458, darkAlpha: 0.65),
    groupFill: TiebaSimpleRowPalette.adaptive(light: 0x787880, lightAlpha: 0.08,
                                              dark: 0xFFFFFF, darkAlpha: 0.08),
    surfaceSecondary: TiebaSimpleRowPalette.adaptive(light: 0xF2F2F7, dark: 0x1C1C1E),
    textDisabled: TiebaSimpleRowPalette.adaptive(light: 0x3C3C43, lightAlpha: 0.2,
                                                 dark: 0xEBEBF5, darkAlpha: 0.2),
    success: TiebaSimpleRowPalette.adaptive(light: 0x34C759, dark: 0x30D158),
    textOnPrimary: .white
  )

  /// JS 主题字典 → 色板；缺失/解析失败的键保留默认值（旧 JS 不下发时行为与
  /// 迁移前完全一致）。与 TiebaFeedRowPalette.init(dict:) 同款容错。
  public init(dict: [String: Any]) {
    var palette = TiebaSimpleRowPalette.default
    palette.base = TiebaFeedRowPalette(dict: dict)
    func apply(_ key: String, _ assign: (UIColor) -> Void) {
      guard let raw = dict[key] as? String, let color = tiebaColor(from: raw) else { return }
      assign(color)
    }
    apply("divider") { palette.divider = $0 }
    apply("groupFill") { palette.groupFill = $0 }
    apply("surfaceSecondary") { palette.surfaceSecondary = $0 }
    apply("textDisabled") { palette.textDisabled = $0 }
    apply("success") { palette.success = $0 }
    apply("textOnPrimary") { palette.textOnPrimary = $0 }
    self = palette
  }

  private init(
    base: TiebaFeedRowPalette,
    divider: UIColor,
    groupFill: UIColor,
    surfaceSecondary: UIColor,
    textDisabled: UIColor,
    success: UIColor,
    textOnPrimary: UIColor
  ) {
    self.base = base
    self.divider = divider
    self.groupFill = groupFill
    self.surfaceSecondary = surfaceSecondary
    self.textDisabled = textDisabled
    self.success = success
    self.textOnPrimary = textOnPrimary
  }

  private static func adaptive(light: UInt32, dark: UInt32) -> UIColor {
    adaptive(light: light, lightAlpha: 1, dark: dark, darkAlpha: 1)
  }

  private static func adaptive(
    light: UInt32,
    lightAlpha: CGFloat,
    dark: UInt32,
    darkAlpha: CGFloat
  ) -> UIColor {
    UIColor { traits in
      traits.userInterfaceStyle == .dark
        ? color(dark, alpha: darkAlpha)
        : color(light, alpha: lightAlpha)
    }
  }

  private static func color(_ hex: UInt32, alpha: CGFloat) -> UIColor {
    UIColor(
      red: CGFloat((hex >> 16) & 0xFF) / 255,
      green: CGFloat((hex >> 8) & 0xFF) / 255,
      blue: CGFloat(hex & 0xFF) / 255,
      alpha: alpha
    )
  }
}
