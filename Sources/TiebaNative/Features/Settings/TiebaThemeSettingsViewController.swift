// ============================================================
// TiebaThemeSettingsViewController —— 个性化（原 src/app/settings/theme.tsx）
// 主题类偏好改动后立刻重刷原生壳；⚠️ JS ThemeContext 的内存副本要到下次启动
// 才看到原生写入（过渡期，见批次报告）。
// ============================================================
import UIKit

final class TiebaThemeSettingsViewController: TiebaFormPageController {
  private static let lightThemes: [(value: String, label: String)] = [
    ("default", "默认"), ("tieba", "贴吧蓝"), ("blue", "系统蓝"), ("black", "经典黑"),
    ("pink", "粉色"), ("red", "红色"), ("purple", "紫色"), ("custom", "自定义"),
  ]
  private static let darkThemes: [(value: String, label: String)] = [
    ("default", "默认"), ("dark", "暗夜"), ("blue_dark", "暗夜蓝"),
    ("grey_dark", "暗夜灰"), ("amoled_dark", "纯黑"),
  ]
  private static let fontScales: [(value: String, label: String)] = [
    ("0.9", "小"), ("1", "标准"), ("1.15", "大"), ("1.3", "特大"),
  ]

  /// 本页展示的全部偏好键（在屏时被别处改写要即时回推行值，不再只靠出现重读）。
  private static let preferenceKeys = [
    "lightTheme", "darkTheme", "customPrimaryColor", "followSystemDarkMode", "darkMode",
    "toolbarPrimaryColor", "statusBarFontDark", "fontScale", "entranceAnimation",
  ]

  /// 行结构缓存：这两行按偏好增删，「有无」变化是唯一需要整表重建的情形。
  private var showsCustomPrimaryRow = false
  private var showsStatusBarFontRow = false

  /// 观察者是 non-Sendable，deinit 非隔离：与 TiebaHomeViewController 同款声明。
  private nonisolated(unsafe) var prefToken: NSObjectProtocol?
  /// 外观档变化登记（registerForTraitChanges；traitCollectionDidChange 已废弃）。
  private var styleRegistration: UITraitChangeRegistration?

  deinit {
    if let prefToken { NotificationCenter.default.removeObserver(prefToken) }
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    // 页面在屏时偏好改了（本页写入也经广播回环）就地回推，不整表重建。
    prefToken = TiebaPreferenceChange.observe(keys: Self.preferenceKeys) { [weak self] in
      self?.refreshDisplayedValues()
    }
    // 「深色模式」行在跟随系统时 = 当前外观档：系统深浅切换要重算行值。
    styleRegistration = registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
      (controller: TiebaThemeSettingsViewController, _) in
      controller.refreshDisplayedValues()
    }
  }

  override func makeSections(dark: Bool) -> [[String: Any]] {
    let lightTheme = TiebaPreferences.string(
      "lightTheme", allowed: Self.lightThemes.map(\.value), default: "default")
    let darkTheme = TiebaPreferences.string(
      "darkTheme", allowed: Self.darkThemes.map(\.value), default: "default")
    let customPrimary = TiebaPreferences.string(
      "customPrimaryColor", default: TiebaThemePalette.defaultCustomPrimary)
    let followSystem = TiebaPreferences.bool("followSystemDarkMode", default: true)
    let darkMode = TiebaPreferences.bool("darkMode", default: false)
    // 跟随系统时以宿主 trait 为准（JS 已把应用内深浅下发到窗口）。
    let isDarkNow = dark
    let toolbarPrimary = TiebaPreferences.bool("toolbarPrimaryColor", default: false)
    let fontScale = TiebaPreferences.number("fontScale", default: 1)
    let fontValue = TiebaPreferences.numberLiteral(fontScale)

    var themeRows: [[String: Any]] = [
      [
        "id": "lightTheme", "kind": "picker", "title": "浅色主题",
        "value": lightTheme, "options": options(Self.lightThemes),
      ],
      [
        "id": "darkTheme", "kind": "picker", "title": "深色主题",
        "value": darkTheme, "options": options(Self.darkThemes),
      ],
    ]
    if lightTheme == "custom" || darkTheme == "custom" {
      themeRows.append([
        "id": "customPrimaryColor", "kind": "color", "title": "自定义主色",
        "value": customPrimary,
      ])
      showsCustomPrimaryRow = true
    } else {
      showsCustomPrimaryRow = false
    }

    var toolbarRows: [[String: Any]] = [
      [
        "id": "toolbarPrimaryColor", "kind": "toggle", "title": "导航栏使用主色调",
        "subtitle": "将导航栏标题与图标着色为主色调，并联动状态栏样式",
        "icon": "paintpalette.fill", "value": toolbarPrimary ? "1" : "0",
      ]
    ]
    showsStatusBarFontRow = toolbarPrimary
    if toolbarPrimary {
      toolbarRows.append([
        "id": "statusBarFontDark", "kind": "toggle", "title": "状态栏深色字体",
        "icon": "textformat",
        "value": TiebaPreferences.bool("statusBarFontDark", default: false) ? "1" : "0",
      ])
    }

    return [
      [
        "title": "主题",
        "footer": "「默认」= 初始内置配色，设置页行图标保持五颜六色；选任一具体主题后图标与强调色统一跟随主色。分组卡片、底栏与顶栏使用系统材质，不随主题变化。深色端可选「纯黑」（AMOLED）。",
        "rows": themeRows,
      ],
      [
        "title": "外观",
        "footer": "「深色模式」在跟随系统时随系统自动同步；手动切换后即退出跟随。",
        "rows": [
          [
            "id": "darkMode", "kind": "toggle", "title": "深色模式",
            "subtitle": "黑底白字；系统变深色时自动跟随开启", "icon": "moon.fill",
            "value": (followSystem ? isDarkNow : darkMode) ? "1" : "0",
          ],
          [
            "id": "followSystemDarkMode", "kind": "toggle", "title": "跟随系统外观",
            "subtitle": "界面颜色自动跟随系统浅色 / 深色设置", "icon": "iphone",
            "value": followSystem ? "1" : "0",
          ],
        ],
      ],
      [
        "title": "阅读字号",
        "footer": "调整帖子正文与回复的字号，即时生效。",
        "rows": [
          [
            "id": "fontScale", "kind": "picker", "title": "正文字号", "icon": "textformat.size",
            "value": fontValue, "options": options(Self.fontScales),
          ]
        ],
      ],
      [
        "title": "动效",
        "footer": "入场动画：信息流与帖内首屏的级联渐入。系统「减弱动态效果」开启时自动停用。",
        "rows": [
          [
            "id": "entranceAnimation", "kind": "toggle", "title": "入场动画", "icon": "sparkles",
            "value": TiebaPreferences.bool("entranceAnimation", default: true) ? "1" : "0",
          ]
        ],
      ],
      [
        "title": "工具栏选项",
        "rows": toolbarRows,
      ],
    ]
  }

  // MARK: - 偏好回推

  /// 偏好变更（含系统外观变化）后就地重算本页行值：只有增删行（自定义主色 /
  /// 状态栏字体）才整表重建，其余一律 setValue —— 写入回环也走这里，幂等。
  private func refreshDisplayedValues() {
    let lightTheme = TiebaPreferences.string(
      "lightTheme", allowed: Self.lightThemes.map(\.value), default: "default")
    let darkTheme = TiebaPreferences.string(
      "darkTheme", allowed: Self.darkThemes.map(\.value), default: "default")
    let followSystem = TiebaPreferences.bool("followSystemDarkMode", default: true)
    let toolbarPrimary = TiebaPreferences.bool("toolbarPrimaryColor", default: false)
    guard (lightTheme == "custom" || darkTheme == "custom") == showsCustomPrimaryRow,
      toolbarPrimary == showsStatusBarFontRow
    else {
      reload()
      return
    }
    // 主题/主色/深浅都会影响表单染色：不重建行，但染色与深浅要跟着重算。
    form.tintHex = formTintHex
    form.isDark = formIsDark
    form.setValue(id: "lightTheme", value: lightTheme)
    form.setValue(id: "darkTheme", value: darkTheme)
    if showsCustomPrimaryRow {
      form.setValue(
        id: "customPrimaryColor",
        value: TiebaPreferences.string(
          "customPrimaryColor", default: TiebaThemePalette.defaultCustomPrimary))
    }
    form.setValue(id: "followSystemDarkMode", value: followSystem ? "1" : "0")
    // 跟随系统时「深色模式」行的显示值是当前外观档（跟随语义），不是落库的 darkMode。
    let darkMode = followSystem ? formIsDark : TiebaPreferences.bool("darkMode", default: false)
    form.setValue(id: "darkMode", value: darkMode ? "1" : "0")
    form.setValue(id: "toolbarPrimaryColor", value: toolbarPrimary ? "1" : "0")
    if showsStatusBarFontRow {
      form.setValue(
        id: "statusBarFontDark",
        value: TiebaPreferences.bool("statusBarFontDark", default: false) ? "1" : "0")
    }
    form.setValue(
      id: "fontScale",
      value: TiebaPreferences.numberLiteral(TiebaPreferences.number("fontScale", default: 1)))
    form.setValue(
      id: "entranceAnimation",
      value: TiebaPreferences.bool("entranceAnimation", default: true) ? "1" : "0")
  }

  // MARK: - 动作

  override func handle(_ event: TiebaFormEvent) {
    switch event {
    case .toggle(let id, let value):
      handleToggle(id, value)
    case .pick(let id, let value):
      handlePick(id, value)
    case .color(_, let value):
      handleColor(value)
    default:
      break
    }
  }

  private func handleToggle(_ id: String, _ value: Bool) {
    switch id {
    case "darkMode":
      TiebaSceneHaptics.fire("toggle")
      guard write("darkMode", bool: value) else { return }
      if TiebaPreferences.bool("followSystemDarkMode", default: true) {
        guard write("followSystemDarkMode", bool: false) else { return }
      }
      applyChrome()
    case "followSystemDarkMode":
      TiebaSceneHaptics.fire("toggle")
      guard write("followSystemDarkMode", bool: value) else { return }
      if value {
        // 跟随打开：深色模式行的显示值 = 当前系统外观（跟随语义）。
        form.setValue(
          id: "darkMode", value: TiebaSettingsForm.isDark(in: self) ? "1" : "0")
      } else {
        // 关掉跟随时以当前系统外观作手动初值，避免白/黑跳变。
        guard write("darkMode", bool: traitCollection.userInterfaceStyle == .dark) else { return }
      }
      applyChrome()
    case "entranceAnimation":
      TiebaSceneHaptics.fire("toggle")
      write(id, bool: value)
    case "toolbarPrimaryColor", "statusBarFontDark":
      TiebaSceneHaptics.fire("toggle")
      guard write(id, bool: value) else { return }
      applyChrome()
      // 「导航栏使用主色调」会增删下面的状态栏字体行 → 结构性变化走整份重建；
      // 状态栏字体行只是改值，已由 write 就地回推。
      if id == "toolbarPrimaryColor" { reload() }
    default:
      break
    }
  }

  private func handlePick(_ id: String, _ value: String) {
    switch id {
    case "lightTheme", "darkTheme":
      TiebaSceneHaptics.fire("toggle")
      guard write(id, string: value) else { return }
      applyChrome()
      // 「自定义」主题会增删主色行 → 结构性变化走整份重建。
      reload()
    case "fontScale":
      TiebaSceneHaptics.fire("toggle")
      guard let scale = Double(value), scale > 0 else { return }
      write("fontScale", number: scale)
    default:
      break
    }
  }

  /// 系统取色器回调恒为 #RRGGBB；归一为大写后落库（坏值静默丢弃）。
  private func handleColor(_ value: String) {
    let upper = value.uppercased()
    guard upper.count == 7, upper.hasPrefix("#"), UInt32(upper.dropFirst(), radix: 16) != nil else {
      return
    }
    guard write("customPrimaryColor", string: upper) else { return }
    applyChrome()
  }

  private func applyChrome() {
    let dark = TiebaSettingsForm.isDark(in: self)
    let themeName = TiebaThemePalette.themeName(dark: dark)
    let accent = TiebaThemePalette.accent(
      themeName: themeName,
      customPrimary: TiebaPreferenceSnapshot.string("customPrimaryColor"),
      isDark: dark
    )
    TiebaSettingsForm.applyTheme(dark: dark, accentHex: accent)
    // 跟随模式必须下发 nil：具体值会锁死窗口 trait，之后系统深浅切换应用不再跟
    // （用户实证"开了跟随系统外观，系统切了应用不变"）。判据与 TiebaAppBootstrap
    // 的启动路径逐字一致。
    TiebaChrome.setChromeDarkMode(
      TiebaPreferences.bool("followSystemDarkMode", default: true) ? nil : dark
    )
    // 整树重扫（栏/滚动件遍历 + 材质写入）是这条链路里最贵的一步，放在开关自己
    // 那 0.25s 动画的同一帧里就会把动画卡住（真机反馈"开关动画很不流畅"）。
    // 配色与栏外观上面已经改完，这里只把重扫挪到动画之后。
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
      _ = TiebaChrome.forceNavBarLiquidGlass()
    }
  }
}
