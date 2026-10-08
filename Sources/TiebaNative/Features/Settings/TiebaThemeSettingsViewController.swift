// TiebaThemeSettingsViewController —— 个性化（原 src/app/settings/theme.tsx）
// 主题类偏好改动后立刻重刷原生壳；⚠️ JS ThemeContext 的内存副本要到下次启动
// 才看到原生写入（过渡期，见批次报告）。
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
  /// 字号偏好的行 id（与偏好键同名；正文/界面两级 + 跟随开关）。
  private static let bodySizeRow = TiebaTypography.bodySizeKey
  private static let uiSizeRow = TiebaTypography.uiSizeKey
  private static let followsRow = TiebaTypography.followsBodyKey

  /// 本页展示的全部偏好键（在屏时被别处改写要即时回推行值，不再只靠出现重读）。
  private static let preferenceKeys = [
    "lightTheme", "darkTheme", "customPrimaryColor", "followSystemDarkMode", "darkMode",
    "toolbarPrimaryColor", "statusBarFontDark", "entranceAnimation",
    TiebaTypography.bodySizeKey, TiebaTypography.uiSizeKey, TiebaTypography.followsBodyKey,
    TiebaListAppearance.key,
    // 旧键仍观察：本页的正文滑杆会把倍率镜像写回它（兼容未改造的读取方）。
    TiebaTypography.legacyScaleKey,
  ]

  /// 行结构缓存：这两行按偏好增删，「有无」变化是唯一需要整表重建的情形。
  private var showsCustomPrimaryRow = false
  private var showsStatusBarFontRow = false
  /// 界面字号滑杆当前是否展开（跟随关闭时才展开）。
  private var showsUIFontSliderRow = false

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
    // 滑杆实时示例的字体**由本页给**：表单层不认识字号体系（正文级/界面级），
    // 示例字号 = "滑杆当前值这么多 pt"——拖动中逐帧现算，不等落库。
    form.slidePreviewFont = { _, value in
      // 示例字号 = 滑杆当前值这么多 pt：size 已经是要显示的字号，scale 再乘一遍就成了二次增长
      //（24 档会显示约 33.9pt、12 档约 8.5pt，只有默认档 17pt 碰巧正确）。
      TiebaSimpleText.scaledFont(size: CGFloat(value), weight: .regular, scale: 1)
    }
    // 「深色模式」行在跟随系统时 = 当前外观档：系统深浅切换要重算行值。
    styleRegistration = registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
      (controller: TiebaThemeSettingsViewController, _) in
      controller.refreshDisplayedValues()
    }
  }

  override func makeSections(dark: Bool) -> [TiebaFormSection] {
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
    // 两级字号：快照读的是**已迁移**的值（老用户的 fontScale 倍率在这里被平滑
    // 换算成新的正文字号 pt，见 TiebaTypography）。
    let typography = TiebaTypography.snapshot()
    let followsBody = typography.followsBody
    showsUIFontSliderRow = !followsBody
    let bodyValue = TiebaPreferences.numberLiteral(typography.bodySize)
    let uiValue = TiebaPreferences.numberLiteral(typography.uiSize)
    let minSize = TiebaTypography.sizeRange.lowerBound
    let maxSize = TiebaTypography.sizeRange.upperBound
    let step = TiebaTypography.sizeStep

    var themeRows = [
      TiebaFormRow(
        id: "lightTheme",
        kind: .picker,
        title: "浅色主题",
        value: lightTheme,
        options: options(Self.lightThemes)
      ),
      TiebaFormRow(
        id: "darkTheme",
        kind: .picker,
        title: "深色主题",
        value: darkTheme,
        options: options(Self.darkThemes)
      ),
    ]
    if lightTheme == "custom" || darkTheme == "custom" {
      themeRows.append(TiebaFormRow(
        id: "customPrimaryColor",
        kind: .color,
        title: "自定义主色",
        value: customPrimary
      ))
      showsCustomPrimaryRow = true
    } else {
      showsCustomPrimaryRow = false
    }

    var toolbarRows = [
      TiebaFormRow(
        id: "toolbarPrimaryColor",
        kind: .toggle,
        title: "导航栏使用主色调",
        subtitle: "将导航栏标题与图标着色为主色调，并联动状态栏样式",
        icon: "paintpalette.fill",
        value: toolbarPrimary ? "1" : "0"
      )
    ]
    showsStatusBarFontRow = toolbarPrimary
    if toolbarPrimary {
      toolbarRows.append(TiebaFormRow(
        id: "statusBarFontDark",
        kind: .toggle,
        title: "状态栏深色字体",
        icon: "textformat",
        value: TiebaPreferences.bool("statusBarFontDark", default: false) ? "1" : "0"
      ))
    }

    return [
      TiebaFormSection(
        title: "主题",
        footer: "「默认」= 初始内置配色，设置页行图标保持五颜六色；选任一具体主题后图标与强调色统一跟随主色。分组卡片、底栏与顶栏使用系统材质，不随主题变化。深色端可选「纯黑」（AMOLED）。",
        rows: themeRows
      ),
      TiebaFormSection(
        title: "外观",
        footer: "「深色模式」在跟随系统时随系统自动同步；手动切换后即退出跟随。",
        rows: [
          TiebaFormRow(
            id: "darkMode",
            kind: .toggle,
            title: "深色模式",
            subtitle: "黑底白字；系统变深色时自动跟随开启",
            icon: "moon.fill",
            value: (followSystem ? isDarkNow : darkMode) ? "1" : "0"
          ),
          TiebaFormRow(
            id: "followSystemDarkMode",
            kind: .toggle,
            title: "跟随系统外观",
            subtitle: "界面颜色自动跟随系统浅色 / 深色设置",
            icon: "iphone",
            value: followSystem ? "1" : "0"
          ),
          TiebaFormRow(
            id: TiebaListAppearance.key,
            kind: .picker,
            title: "设计风格",
            subtitle: "扁平：通栏、行间发际线、亮色纯白底；卡片：圆角白卡浮在分组灰底上",
            icon: "rectangle.split.1x2",
            value: TiebaListAppearance.style().rawValue,
            options: options(
              TiebaListAppearance.Style.allCases.map { (value: $0.rawValue, label: $0.title) })
          ),
        ]
      ),
      TiebaFormSection(
        title: "阅读字号",
        footer: "滑杆左右拖动 = 无级调节，下方示例实时跟随。正文字号管帖子卡片与帖内正文/回复/楼中楼；界面字号管其余全部界面（导航栏、按钮、设置页、列表标题、时间与徽章）。",
        rows: uiFontRows(
          bodyValue: bodyValue,
          uiValue: uiValue,
          followsBody: followsBody,
          minSize: minSize,
          maxSize: maxSize,
          step: step
        )
      ),
      TiebaFormSection(
        title: "动效",
        footer: "入场动画：信息流与帖内首屏的级联渐入。系统「减弱动态效果」开启时自动停用。",
        rows: [
          TiebaFormRow(
            id: "entranceAnimation",
            kind: .toggle,
            title: "入场动画",
            icon: "sparkles",
            value: TiebaPreferences.bool("entranceAnimation", default: true) ? "1" : "0"
          )
        ]
      ),
      TiebaFormSection(
        title: "工具栏选项",
        rows: toolbarRows
      ),
    ]
  }

  /// 整份重建（主题/结构变化）会把隐藏行一起复原：重建后按当前跟随态重新收起
  /// 界面字号滑杆。无动画——重建本身就是一次硬切，这里再叠动画只会打架。
  override func reload() {
    super.reload()
    form.setHidden(
      id: Self.uiSizeRow,
      hidden: TiebaTypography.snapshot().followsBody,
      animated: false
    )
  }

  /// 「阅读字号」分组的行：正文滑杆 + 界面滑杆 + 跟随开关。
  ///
  /// 顺序按用户口径：两个调节部分在前，按钮在后；开关**打开时界面字号滑杆
  /// 收起**（收起/展开走 TiebaFormListView.setHidden 的插入/删除动画，不是瞬切）。
  private func uiFontRows(
    bodyValue: String,
    uiValue: String,
    followsBody: Bool,
    minSize: Double,
    maxSize: Double,
    step: Double
  ) -> [TiebaFormRow] {
    var rows = [
      TiebaFormRow(
        id: Self.bodySizeRow,
        kind: .slider,
        title: "正文字号",
        icon: "textformat.size",
        value: bodyValue,
        minValue: minSize,
        maxValue: maxSize,
        step: step,
        previewText: followsBody
          ? "正文示例：贴吧的帖子正文、回复与楼中楼。界面字号正跟随此档。"
          : "正文示例：贴吧的帖子正文、回复与楼中楼。",
        // 「重置」目标 = 该档的默认字号（基准 17pt）。
        defaultValue: TiebaTypography.defaultBodySize
      )
    ]
    // 这一行**恒在 sections 里**：显隐交给 TiebaFormListView.setHidden 做数据源级
    // 增删（这样才有插入/删除的高度动画）。跟随打开时它在重建后立刻被收起。
    rows.append(TiebaFormRow(
      id: Self.uiSizeRow,
      kind: .slider,
      title: "界面字号",
      icon: "textformat",
      value: uiValue,
      minValue: minSize,
      maxValue: maxSize,
      step: step,
      previewText: "界面示例：导航栏、按钮、设置页与列表标题。",
      defaultValue: TiebaTypography.defaultUISize
    ))
    rows.append(TiebaFormRow(
      id: Self.followsRow,
      kind: .toggle,
      title: "界面字号跟随正文字号",
      subtitle: "开启后界面字号与正文字号一致，界面字号调节杆收起",
      icon: "textformat.size.larger",
      value: followsBody ? "1" : "0"
    ))
    return rows
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
      // 整份重建会把隐藏行一起复原：重建后按当前跟随态重新收起界面字号滑杆。
      reload()
      form.setHidden(
        id: Self.uiSizeRow, hidden: TiebaTypography.snapshot().followsBody, animated: false)
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
    form.setValue(id: TiebaListAppearance.key, value: TiebaListAppearance.style().rawValue)
    // 跟随系统时「深色模式」行的显示值是当前外观档（跟随语义），不是落库的 darkMode。
    let darkMode = followSystem ? formIsDark : TiebaPreferences.bool("darkMode", default: false)
    form.setValue(id: "darkMode", value: darkMode ? "1" : "0")
    form.setValue(id: "toolbarPrimaryColor", value: toolbarPrimary ? "1" : "0")
    if showsStatusBarFontRow {
      form.setValue(
        id: "statusBarFontDark",
        value: TiebaPreferences.bool("statusBarFontDark", default: false) ? "1" : "0")
    }
    // 两级字号：快照读的是已迁移的值（旧 fontScale 倍率由 TiebaTypography 换算）。
    let typography = TiebaTypography.snapshot()
    form.setValue(id: Self.bodySizeRow, value: TiebaPreferences.numberLiteral(typography.bodySize))
    if !typography.followsBody {
      form.setValue(id: Self.uiSizeRow, value: TiebaPreferences.numberLiteral(typography.uiSize))
    }
    form.setValue(id: Self.followsRow, value: typography.followsBody ? "1" : "0")
    // 跟随开关决定界面字号滑杆在不在表里：走 setHidden 的插入/删除动画（用户
    // 明确要求显隐要有动画）。幂等：值没变时 setHidden 直接返回。
    if showsUIFontSliderRow != !typography.followsBody {
      showsUIFontSliderRow = !typography.followsBody
      form.setHidden(id: Self.uiSizeRow, hidden: typography.followsBody, animated: true)
    }
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
    case .slide(let id, let value):
      handleSlide(id, value)
    default:
      break
    }
  }

  private func handleToggle(_ id: String, _ value: Bool) {
    switch id {
    case "darkMode":
      // 触觉由行内控件层统一发（cell.toggleChanged），页面层不补发（同帧双发手感发糊）。
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
    case TiebaTypography.followsBodyKey:
      TiebaSceneHaptics.fire("toggle")
      // 写库 → TiebaTypography 快照重解析（世代 +1，全仓度量缓存随之失效）→
      // 广播回本页 → refreshDisplayedValues 里收起/展开界面字号滑杆（带动画）。
      // 关闭跟随时先落一次当前生效的界面字号，避免"关掉后界面突然跳档"。
      guard write(id, bool: value) else { return }
      if value {
        form.setHidden(id: Self.uiSizeRow, hidden: true, animated: true)
      } else {
        // 首次关闭跟随：界面字号没有历史值就取当前生效档（= 正文字号）作初值，
        // 否则用户会看到界面"突然跳一下"。
        if TiebaPreferenceSnapshot.number(TiebaTypography.uiSizeKey) == nil {
          _ = write(TiebaTypography.uiSizeKey, number: TiebaTypography.snapshot().bodySize)
        }
        form.setHidden(id: Self.uiSizeRow, hidden: false, animated: true)
      }
      scheduleTypographyRefresh()
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

  // MARK: - 无级滑杆

  /// 拖动期间待落库的最后一格（前沿 + 尾沿节流，见 handleSlide）。
  private var pendingSlide: (id: String, value: Double)?
  private var slideWriteScheduled = false
  private var lastSlideWriteAt: CFAbsoluteTime = 0
  /// 字号落库后的整表重排（延迟到拖动停下再做，见 scheduleTypographyRefresh）。
  private var typographyRefresh: DispatchWorkItem?

  /// 滑杆每次变化都会到这里（UISlider 连续事件，拖动时每秒几十次）。
  ///
  /// **为什么不能逐次落库**：每次写偏好 = 一次 SQLite upsert + 一次全仓广播，
  /// 几十 Hz 地写会让拖动掉帧。这里做"前沿 + 尾沿"节流：距上次落库 ≥80ms 就
  /// 立刻写，否则只记下最后一格、80ms 后补写——松手前的那一格一定落库。
  /// 示例文字不受影响：它是 cell 自己按滑杆现值现算的，逐帧都跟手。
  private func handleSlide(_ id: String, _ value: Double) {
    pendingSlide = (id, value)
    let now = CFAbsoluteTimeGetCurrent()
    if now - lastSlideWriteAt >= 0.08 {
      commitPendingSlide()
    } else if !slideWriteScheduled {
      slideWriteScheduled = true
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
        self?.slideWriteScheduled = false
        self?.commitPendingSlide()
      }
    }
    scheduleTypographyRefresh()
  }

  private func commitPendingSlide() {
    guard let pending = pendingSlide else { return }
    pendingSlide = nil
    lastSlideWriteAt = CFAbsoluteTimeGetCurrent()
    // 无级但落盘值量化到 0.1pt：避免 17.030000000000001 这种脏值进 KV。
    let size = TiebaTypography.quantize(pending.value)
    switch pending.id {
    case Self.bodySizeRow:
      _ = write(Self.bodySizeRow, number: size)
      // 兼容镜像：旧键 fontScale（倍率）同步写回，尚未改造的读取方仍拿到正确字号。
      // 它也是老用户设置的迁移来源（TiebaTypography.readBodySize）。
      _ = TiebaPreferences.set(
        TiebaTypography.legacyScaleKey, number: size / TiebaTypography.referenceSize)
    case Self.uiSizeRow:
      _ = write(Self.uiSizeRow, number: size)
    default:
      break
    }
  }

  /// 字号落库后**延迟**整表重排：拖动中 reloadData 会把手指正按着的滑杆一起
  /// 重建（拖动当场断掉），所以等 0.35s 没有新事件再做。字体与行高都由 cell
  /// 现算，reload 之后整页（含离屏行）就是新字号。
  private func scheduleTypographyRefresh() {
    typographyRefresh?.cancel()
    let item = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.form.refreshTypography()
      // 全仓度量缓存由字号世代失效（TiebaRowDiff 指纹），这里只需让 UI 也重排。
      self.view.setNeedsLayout()
    }
    typographyRefresh = item
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: item)
  }

  private func handlePick(_ id: String, _ value: String) {
    switch id {
    case TiebaListAppearance.key:
      TiebaSceneHaptics.fire("toggle")
      // 写库 → TiebaListAppearance 快照重解析（世代 +1，全仓度量缓存随之失效）→
      // 广播回本页与关注页/帖子页。外观档不是结构性变化（不增删行），走 setValue 回推。
      guard let style = TiebaListAppearance.Style(rawValue: value) else { return }
      write(id, string: style.rawValue)
    case "lightTheme", "darkTheme":
      TiebaSceneHaptics.fire("toggle")
      guard write(id, string: value) else { return }
      applyChrome()
      // 「自定义」主题会增删主色行 → 结构性变化走整份重建。
      reload()
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
