// ============================================================
// TiebaSettingsSupport —— 设置群共用的原生偏好读写 + 表单/主题辅助
//
// ⚠️ 落盘必须与 JS preferencesStore 的 persist 层逐字节兼容：逐键
// kv["tiebalite_preferences:<key>"] = 该键的 JSON 字面量；坏值回落默认。
// ============================================================
import UIKit
import os

enum TiebaPreferences {
  private static let storagePrefix = "tiebalite_preferences"
  private static let log = Logger(subsystem: "com.tiebalite.app", category: "preferences")

  // MARK: - 读（缺失/坏值 → fallback，与 JS sanitizePreferenceValue 同语义）

  static func bool(_ key: String, default fallback: Bool) -> Bool {
    switch TiebaPreferenceSnapshot.rawValue(key) {
    case "true": return true
    case "false": return false
    default: return fallback
    }
  }

  static func number(_ key: String, default fallback: Double) -> Double {
    guard let raw = TiebaPreferenceSnapshot.rawValue(key),
      let data = raw.data(using: .utf8),
      let value = try? JSONDecoder().decode(Double.self, from: data),
      value.isFinite
    else { return fallback }
    return value
  }

  static func string(_ key: String, default fallback: String) -> String {
    TiebaPreferenceSnapshot.string(key) ?? fallback
  }

  /// 枚举键白名单兜底：历史脏值不得进入选择器当前值（原 safePick 防线）。
  static func string(_ key: String, allowed: [String], default fallback: String) -> String {
    let value = TiebaPreferenceSnapshot.string(key) ?? fallback
    return allowed.contains(value) ? value : fallback
  }

  // MARK: - 写（返回是否落盘成功：调用方必须据此决定回推/成功提示）

  @discardableResult
  static func set(_ key: String, bool value: Bool) -> Bool {
    write(key, value ? "true" : "false")
  }

  @discardableResult
  static func set(_ key: String, string value: String) -> Bool {
    guard let data = try? JSONEncoder().encode(value),
      let text = String(data: data, encoding: .utf8)
    else { return false }
    return write(key, text)
  }

  @discardableResult
  static func set(_ key: String, number value: Double) -> Bool {
    write(key, Self.numberLiteral(value))
  }

  /// 恢复默认：逐键 + 旧整份 JSON 同在前缀下，一次清掉。
  static func resetAll() throws {
    try TiebaKvStore.shared.clear(prefix: storagePrefix, preserveKeys: [])
  }

  /// JS JSON.stringify 的数字形态：整数不带 ".0"（1 而非 1.0）。
  static func numberLiteral(_ value: Double) -> String {
    value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
  }

  private static func write(_ key: String, _ jsonLiteral: String) -> Bool {
    do {
      try TiebaPreferenceSnapshot.write(key, jsonLiteral: jsonLiteral)
      return true
    } catch {
      log.error("preference write failed \(key, privacy: .public): \(String(describing: error), privacy: .public)")
      return false
    }
  }
}

/// 主题小模型：每个主题一个强调色 + 一个可选底色（其余交给系统语义色）。
/// 取值与 JS getThemeColors 的 primary/background 一致；未知名回落默认主题。
enum TiebaThemePalette {
  static let defaultCustomPrimary = "#4477E0"

  static func accent(themeName: String, customPrimary: String?, isDark: Bool) -> String {
    switch themeName {
    case "blue": return isDark ? "#64A5FF" : "#007AFF"
    case "black": return isDark ? "#E5E5EA" : "#000000"
    case "pink": return isDark ? "#FFB3B7" : "#FF9A9E"
    case "red": return isDark ? "#FF6B62" : "#C51100"
    case "purple": return isDark ? "#B39DDB" : "#512DA8"
    case "blue_dark": return "#64A5FF"
    case "grey_dark": return "#9AA3B2"
    case "amoled_dark": return "#5B9BFF"
    case "dark": return "#60A5FA"
    case "custom":
      let primary = hex(customPrimary) ?? defaultCustomPrimary
      return isDark ? darkAdapted(primary) : primary
    default: return isDark ? "#60A5FA" : "#2563EB"
    }
  }

  /// nil = 不该由页面覆盖（默认主题下用系统背景）。
  static func background(themeName: String, isDark: Bool) -> String? {
    switch themeName {
    case "blue_dark": return "#17212B"
    case "grey_dark": return "#202020"
    case "amoled_dark", "dark": return "#000000"
    default: return isDark ? "#000000" : "#F2F2F7"
    }
  }

  /// 深浅端主题名（与 ThemeProvider 的 lightThemeName/darkThemeName 同判据）。
  static func themeName(dark: Bool) -> String {
    let raw = TiebaPreferences.string(dark ? "darkTheme" : "lightTheme", default: "default")
    return raw
  }

  private static func hex(_ raw: String?) -> String? {
    guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
      text.count == 7, text.hasPrefix("#"),
      UInt32(text.dropFirst(), radix: 16) != nil
    else { return nil }
    return text.uppercased()
  }

  /// 深色端把自定义主色提亮（mix 白 45%/25%，同 darkAdapted）。
  private static func darkAdapted(_ hex: String) -> String {
    guard let value = UInt32(hex.dropFirst(), radix: 16) else { return hex }
    let r = Double((value >> 16) & 0xFF) / 255
    let g = Double((value >> 8) & 0xFF) / 255
    let b = Double(value & 0xFF) / 255
    let luminance = 0.299 * r + 0.587 * g + 0.114 * b
    let amount = luminance < 0.4 ? 0.45 : 0.25
    func mix(_ channel: Double) -> Int { Int(((channel + (1 - channel) * amount) * 255).rounded()) }
    return String(format: "#%02X%02X%02X", mix(r), mix(g), mix(b))
  }
}

@MainActor
enum TiebaSettingsForm {
  /// useFormTintHex() 的原生同义：「默认」主题不染色（行图标五彩），
  /// 其余主题取当前深浅端的强调色。
  static func tintHex(dark: Bool) -> String? {
    let name = TiebaThemePalette.themeName(dark: dark)
    guard name != "default" else { return nil }
    let custom = TiebaPreferenceSnapshot.string("customPrimaryColor")
    return TiebaThemePalette.accent(themeName: name, customPrimary: custom, isDark: dark)
  }

  static func isDark(systemIsDark: Bool) -> Bool {
    if TiebaPreferences.bool("followSystemDarkMode", default: true) { return systemIsDark }
    return TiebaPreferences.bool("darkMode", default: false)
  }

  static func isDark(in viewController: UIViewController) -> Bool {
    isDark(systemIsDark: viewController.traitCollection.userInterfaceStyle == .dark)
  }

  static func push(_ path: String) {
    TiebaSceneHaptics.fire("press")
    _ = TiebaNavigator.shared.navigate(path: path, params: [:], mode: "push")
  }

  static func makeForm() -> TiebaFormListView {
    let form = TiebaFormListView(frame: .zero)
    form.translatesAutoresizingMaskIntoConstraints = false
    return form
  }

  static func pin(_ form: TiebaFormListView, in view: UIView) {
    NSLayoutConstraint.activate([
      form.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      form.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      form.topAnchor.constraint(equalTo: view.topAnchor),
      form.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
  }

  static func reload(_ form: TiebaFormListView, isDark: Bool) {
    form.tintHex = tintHex(dark: isDark)
    form.isDark = isDark
  }

  /// 主题/工具栏偏好变更后重刷原生壳（导航栏、底栏、状态栏、窗口底色）。
  /// ⚠️ JS 侧内存副本不随之更新（过渡期，见批次报告）。
  static func applyTheme(dark: Bool, accentHex: String) {
    let accent = TiebaFormColor.hex(accentHex) ?? .tintColor
    let toolbarPrimary = TiebaPreferences.bool("toolbarPrimaryColor", default: false)
    let statusBarFontDark = TiebaPreferences.bool("statusBarFontDark", default: false)
    let navTint: UIColor = toolbarPrimary
      ? (dark ? .white : (statusBarFontDark ? .black : .white))
      : .label
    let themeName = TiebaThemePalette.themeName(dark: dark)
    let backgroundHex = TiebaThemePalette.background(themeName: themeName, isDark: dark)
    let background = backgroundHex.flatMap { TiebaFormColor.hex($0) } ?? .systemBackground
    TiebaNavigator.shared.applyTheme(
      TiebaChromeTheme(tint: accent, navTint: navTint, background: background, dark: dark)
    )
    let lightStatusBar = toolbarPrimary
      ? (dark ? true : !statusBarFontDark)
      : dark
    TiebaNavigator.shared.setDefaultStatusBarStyle(lightStatusBar ? .lightContent : .darkContent)
    TiebaSystemUI.setBackgroundColor(argb: argb(from: background))
  }

  private static func argb(from color: UIColor) -> Double {
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return 0 }
    func part(_ value: CGFloat) -> UInt32 { UInt32((min(max(value, 0), 1) * 255).rounded()) }
    return Double((part(a) << 24) | (part(r) << 16) | (part(g) << 8) | part(b))
  }
}

/// 轻量 Toast（原 RN Toast 的 pill 形态；TiebaPhotoBrowserPillView 是既有的原生实现）。
@MainActor
enum TiebaToast {
  static func show(_ text: String, success: Bool = true) {
    guard let host = TiebaTopViewController.find() else { return }
    let pill = TiebaPhotoBrowserPillView()
    pill.translatesAutoresizingMaskIntoConstraints = false
    host.view.addSubview(pill)
    NSLayoutConstraint.activate([
      pill.centerXAnchor.constraint(equalTo: host.view.centerXAnchor),
      pill.bottomAnchor.constraint(
        equalTo: host.view.safeAreaLayoutGuide.bottomAnchor,
        constant: -24
      ),
    ])
    pill.showResult(success: success, text: text)
  }
}
