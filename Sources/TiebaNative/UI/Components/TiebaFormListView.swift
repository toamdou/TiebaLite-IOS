// ============================================================
// TiebaLite — 原生设置表单（TiebaFormListView）
//
// 纯 UIKit 视图，可被原生 UIViewController 直接使用。
//
// 设置页群（settings/*、thread/[id]/more）原先的 SwiftUI 托管形态已整体换掉：
// 每个 Host 一次 UIHostingController + 一次跨桥下发，且 Form 在二级托管下
// 有过触摸断链/测量塌缩的前科（见 TiebaSegmentedControlView 头注释）。本视图
// 改用 UIKit 的 UITableView(.insetGrouped) 直接画同一份分组列表：分组圆角、
// 卡片底色、分隔线内缩、行高、表头/脚字体全部由 UIKit 给——SwiftUI 的 Form
// 在 iOS 16+ 本身就是同一套列表渲染，所以观感是「同一个系统表单」，只是不再
// 经过 SwiftUI 托管层。系统控件优先：UIListContentConfiguration（行内容/
// 度量/值对齐）、UISwitch（开关）、UICellAccessory.popUpMenu（选择器菜单）、
// UIAlertController（确认弹窗）、UIColorWell（取色）、UIListContentConfiguration
// .groupedHeader/.groupedFooter（表头脚）——唯一合成图形是行首色块图标（见
// TiebaFormRowCell.squareIconImage，用系统绘图 API 合成，不引图片资源）。
//
// 与页面 JS 的分工（原生化只换渲染层，行为不变）：
//   - 数据**声明式**：调用方算好的 sections/rows 一次性下发，视图不做业务判断
//     （偏好读写、触觉、Toast、跳转、Alert 全留在调用方）。
//   - 事件**受控**语义：开关/选择器不在视图内改模型，只上报用户意图；调用方写库
//     成功后用 setValue(id:value:) 就地回推（不整表 reload），失败就不回推、开关
//     停回原值。这与 @expo/ui 的受控 Toggle 一致：授权/写库失败时不会出现
//     开关已开、状态仍关的分裂。
//   - 颜色不抄色板：主色由调用方以 #RRGGBB 下发（tint），「默认」主题下发 nil =
//     控件保持系统默认色（开关绿、按钮/图标系统蓝）——与 useFormTint() 的语义
//     逐字对应（含「Picker 选中值」也随 tint 染色）。
//   - 深浅不锁在本视图：宿主子页 / 窗口级 override（TiebaChrome.setChromeDarkMode）
//     已把应用主题下发给整棵树，表单与 cell 全用系统语义色，trait 一变自己跟
//     上——调用方仍会按旧签名下发 isDark，但写入不再需要（见属性注释）。
//
// 行种类与可见形态（与迁移前的 @expo/ui 组件一一对应）：
//   link    ListItem：色块图标 + 标题 + 副标题（**无 chevron** —— ListItem 的
//           iOS 实现是 plain Button + HStack，不画 disclosure）
//   toggle  Toggle：systemImage 图标 + 标题 +（子 Text = 副标题）+ UISwitch
//   picker  Picker(.menu)：标题 + 当前值 + UICellAccessory.popUpMenu（系统自带
//           上下箭头，点行内任意处弹 UIMenu，与 SwiftUI 菜单选择器同一系统交互）
//   button  Button：着色 SF 图标 + 着色标题（Form 内 Button 的默认形态）
//   confirm ConfirmationDialog：形态同 button，点按弹 UIAlertController.actionSheet
//           （title/message/确认/取消），确认后才回调
//   text    Text：整行文字（body/subheadline/footnote/caption/headline/title）
//   hero    居中图文块（关于页：应用图标 + 名称 + 版本）
//   color   ColorPicker：标题 + 右侧色环（系统 UIColorWell：自带色井外观、
//           点击弹系统取色器、.valueChanged 回调用户选色）
//
// 2026-09-13 第二批（非列表页原生化：account / block / edit-profile / oksign /
// (tabs)/profile）新增，仍然全是系统控件：
//   textField       TextField：UITextField（单行）/ UITextView（axis=vertical），
//                   placeholder / maxLength / 受控 value（编辑中只上报，落点由 JS
//                   下一次下发决定）。多行占位用 UILabel 叠层——UIKit 的
//                   UITextView 没有 placeholder 槽（系统也没给），这是唯一自绘处。
//   segmented       Picker(.segmented)：UISegmentedControl（等宽分档）
//   option          Picker(.inline) 的一档：标题 + 选中打勾（accessoryType=.checkmark）。
//                   同一 group 的多行共用 id（= group），选中/回调都按 group。
//   menu            行尾 ellipsis UIMenu（account 每行「移除账号」）：行本身可点
//                   （onRowPress），ellipsis 弹 UIMenu（onPick(id, menuItemId)）
//   avatar          头像行：复用 TiebaForumAvatarView（Nuke 圆头像 + 失败首字）+
//                    标题/副标题 + 可选尾部按钮（UIButton，含 busy 转圈）或尾部
//                    说明文字（黑名单/屏蔽吧）
//   prominentButton Form 内系统按钮：UIButton.Configuration
//                   .borderedProminent / .bordered / .glass / .plain（可 capsule /
//                   large），整行宽度（oksign 的「一键签到」）
//   progress        线性进度：UIProgressView（tint 随主色）
//   status          图标 + 数值簇（可带标题 / 尾部说明 / 尾部转圈）：
//                   oksign 的签到统计与逐吧进度行
//   spinner         居中 UIActivityIndicatorView（加载行）
//   datePicker      DatePicker(hourAndMinute)：UIDatePicker(.compact, .time)
//   empty           区块内空态：UIContentUnavailableView（系统空态排版）
//
// 新增事件：onTextChange { id, value }（textField 每次编辑；其余事件语义不变）。
// 颜色键（color / iconTint / trailingColor）除 #RRGGBB 外还接受系统语义 token：
// label / secondaryLabel / tertiaryLabel / systemRed / systemGreen / systemOrange /
// systemBlue / systemGray（JS 侧主题色板里 textSecondary 等是 rgba，转不成 hex）。
// ============================================================

import UIKit

// MARK: - 颜色

/// 十六进制 → UIColor。本文件保持零 Expo 依赖，可被原生 UIViewController 直接用。
enum TiebaFormColor {
  static func hex(_ raw: String?) -> UIColor? {
    guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), s.hasPrefix("#") else {
      return nil
    }
    s.removeFirst()
    if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
    guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
    return UIColor(
      red: CGFloat((v >> 16) & 0xFF) / 255,
      green: CGFloat((v >> 8) & 0xFF) / 255,
      blue: CGFloat(v & 0xFF) / 255,
      alpha: 1
    )
  }

  /// 颜色键解析：#RRGGBB/#RGB 或系统语义 token。
  ///
  /// 为什么需要 token：JS 主题色板里次级/三级文字是 `rgba(...)`（如
  /// colors.textSecondary = 'rgba(60,60,67,0.6)'），解析成 hex 会丢掉 alpha 且
  /// 无法表达"跟随深浅色"；直接给系统语义色则与迁移前 SwiftUI 的
  /// `.foregroundStyle(.secondary)` / `.tint` 同源。未知 token 一律 nil（保持
  /// 系统默认色），不猜。
  static func resolve(_ raw: String?) -> UIColor? {
    guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
      return nil
    }
    switch raw {
    case "label": return .label
    case "secondaryLabel": return .secondaryLabel
    case "tertiaryLabel": return .tertiaryLabel
    case "placeholderText": return .placeholderText
    case "systemRed": return .systemRed
    case "systemGreen": return .systemGreen
    case "systemOrange": return .systemOrange
    case "systemBlue": return .systemBlue
    case "systemGray": return .systemGray
    default: return hex(raw)
    }
  }
}

// MARK: - 行模型

/// 选择器的一档：value 落库、label 显示。
struct TiebaFormOption {
  let value: String
  let label: String
}

/// 行尾 UIMenu 的一项（account 行的「移除账号」；原生画成 UIAction）。
struct TiebaFormMenuItem {
  let id: String
  let title: String
  let icon: String?
  let destructive: Bool
}

/// status 行里的一簇「图标 + 数值」（oksign 的成功/失败计数、逐吧 +经验）。
struct TiebaFormStatusItem {
  let icon: String
  let text: String
  let color: UIColor?
  /// medium/semibold/bold 覆盖（默认 regular）
  let weight: String
}

/// 一行。解析失败的行直接丢弃：宁可少画一行，也不要在表格里留半行空白
/// （JS 侧类型已收窄，这里是最后的防御）。
struct TiebaFormRow {
  enum Kind: String {
    case link
    case toggle
    case picker
    case button
    case confirm
    case text
    case hero
    case color
    case textField
    case segmented
    case option
    case menu
    case avatar
    case prominentButton
    case progress
    case status
    case spinner
    case datePicker
    case empty

    /// 行内容由 UIListContentConfiguration 画的种类（其余走专用 cell）。
    var usesContentConfiguration: Bool {
      switch self {
      case .link, .toggle, .picker, .button, .confirm, .text, .color, .option, .menu:
        return true
      default:
        return false
      }
    }
  }

  let id: String
  let kind: Kind
  let title: String
  let subtitle: String?
  let icon: String?
  let iconTint: UIColor?
  /// 当前值。唯一可变字段：受控回推（setValue）就地在模型里改它，避免整表重解析。
  var value: String?
  let options: [TiebaFormOption]
  let destructive: Bool
  let disabled: Bool
  /// 文本/图标覆盖色（button/text 行；如「崩溃与卡顿日志」的橙、错误行的次级灰）
  let override: UIColor?
  /// SwiftUI textStyle 名：body / subheadline / footnote / caption / headline / title
  let textStyle: String
  /// hero 行的打包图（Bundle 相对路径，见 TiebaFormHeroCell）
  let imageName: String?
  let confirmTitle: String?
  let confirmMessage: String?
  let confirmLabel: String?
  /// 点行内任意处是否等价于拨开关。SwiftUI 的 `Toggle` 行是（true），
  /// 而 ListItem + trailing Switch（设置首页那几行）不是——那一行没有 onPress，
  /// 点行不该动开关。默认 true（Toggle 形态更常见）。
  let switchRowTap: Bool
  /// 只禁用开关、不灰整行文字（异步授权/写库挂起期间就是这状态：ListItem 的
  /// 标题/副标题保持正常色，只有 Switch 变灰不可点）。
  let switchDisabled: Bool

  // ── 第二批（textField / segmented / option / menu / avatar / prominentButton /
  //    progress / status / spinner / datePicker / empty）──
  /// textField：占位文案（多行时由占位 UILabel 承担）
  let placeholder: String?
  /// textField：最大字符数（0 = 不限；超长在编辑回调里截断）
  let maxLength: Int
  /// textField：多行（SwiftUI axis=vertical）
  let multiline: Bool
  /// option / menu：当前是否选中（打勾）
  let selected: Bool
  /// menu：菜单项
  let menuItems: [TiebaFormMenuItem]
  /// segmented：分档标题（options 复用 value/label）
  /// avatar：头像图 URL（空 = 首字占位）
  let avatarURL: String?
  /// avatar：首字占位（无图/加载失败时）
  let initials: String?
  /// avatar：头像直径（默认 40）
  let avatarSize: Double
  /// avatar：尾部形态："" / "button" / "text"
  let trailingStyle: String
  /// avatar：尾部按钮标题或尾部说明文字
  let trailingTitle: String?
  /// avatar：尾部按钮图标（SF Symbol）
  let trailingIcon: String?
  /// avatar：尾部颜色（按钮着色 / 说明文字色；支持语义 token）
  let trailingColor: UIColor?
  /// avatar：尾部按钮 busy（转圈 + 禁用）
  let trailingBusy: Bool
  /// avatar：尾部按钮禁用
  let trailingDisabled: Bool
  /// prominentButton：borderedProminent / bordered / glass / plain
  let buttonStyle: String
  /// prominentButton：controlSize large
  let buttonLarge: Bool
  /// prominentButton：capsule 圆角
  let buttonCapsule: Bool
  /// progress：0...1
  let progress: Double
  /// status：图标 + 数值簇
  let statusItems: [TiebaFormStatusItem]
  /// status：尾部说明文字（如「等待中」「+12 经验」）
  let trailingText: String?
  /// status：尾部文字色（支持语义 token）
  let trailingTextColor: UIColor?
  /// status：标题字重 regular / medium / semibold（默认 regular）
  let titleWeight: String
  /// status：尾部转圈（「签到中」的行）
  let showsSpinner: Bool

  init?(raw: [String: Any], fallbackID: String) {
    guard let kindRaw = raw["kind"] as? String, let kind = Kind(rawValue: kindRaw) else { return nil }
    let rawID = raw["id"] as? String
    self.id = (rawID?.isEmpty == false) ? (rawID ?? fallbackID) : fallbackID
    self.kind = kind
    self.title = raw["title"] as? String ?? ""
    self.subtitle = raw["subtitle"] as? String
    self.icon = raw["icon"] as? String
    self.iconTint = TiebaFormColor.resolve(raw["iconTint"] as? String)
    self.value = raw["value"] as? String
    self.options = (raw["options"] as? [[String: Any]] ?? []).compactMap { option in
      guard let value = option["value"] as? String else { return nil }
      return TiebaFormOption(value: value, label: option["label"] as? String ?? value)
    }
    self.destructive = raw["destructive"] as? Bool ?? false
    self.disabled = raw["disabled"] as? Bool ?? false
    self.override = TiebaFormColor.resolve(raw["color"] as? String)
    let style = raw["textStyle"] as? String ?? "body"
    self.textStyle = style
    self.imageName = raw["imageName"] as? String
    self.confirmTitle = raw["confirmTitle"] as? String
    self.confirmMessage = raw["confirmMessage"] as? String
    self.confirmLabel = raw["confirmLabel"] as? String
    self.switchRowTap = raw["switchRowTap"] as? Bool ?? true
    self.switchDisabled = raw["switchDisabled"] as? Bool ?? false

    self.placeholder = raw["placeholder"] as? String
    // NSNumber 中转：JS 数字过来是 NSNumber(double)，直接 as? Int 在非整值上会失败。
    self.maxLength = (raw["maxLength"] as? NSNumber)?.intValue ?? 0
    self.multiline = raw["multiline"] as? Bool ?? false
    self.selected = raw["selected"] as? Bool ?? false
    self.menuItems = (raw["menuItems"] as? [[String: Any]] ?? []).compactMap { item in
      guard let id = item["id"] as? String, let title = item["title"] as? String else { return nil }
      return TiebaFormMenuItem(
        id: id,
        title: title,
        icon: item["icon"] as? String,
        destructive: item["destructive"] as? Bool ?? false
      )
    }
    self.avatarURL = raw["avatarURL"] as? String
    self.initials = raw["initials"] as? String
    self.avatarSize = (raw["avatarSize"] as? NSNumber)?.doubleValue ?? 40
    self.trailingStyle = raw["trailingStyle"] as? String ?? ""
    self.trailingTitle = raw["trailingTitle"] as? String
    self.trailingIcon = raw["trailingIcon"] as? String
    self.trailingColor = TiebaFormColor.resolve(raw["trailingColor"] as? String)
    self.trailingBusy = raw["trailingBusy"] as? Bool ?? false
    self.trailingDisabled = raw["trailingDisabled"] as? Bool ?? false
    self.buttonStyle = raw["buttonStyle"] as? String ?? "prominent"
    self.buttonLarge = raw["buttonLarge"] as? Bool ?? false
    self.buttonCapsule = raw["buttonCapsule"] as? Bool ?? false
    self.progress = (raw["progress"] as? NSNumber)?.doubleValue ?? 0
    self.statusItems = (raw["statusItems"] as? [[String: Any]] ?? []).compactMap { item in
      guard let icon = item["icon"] as? String, let text = item["text"] as? String else { return nil }
      return TiebaFormStatusItem(
        icon: icon,
        text: text,
        color: TiebaFormColor.resolve(item["color"] as? String),
        weight: item["weight"] as? String ?? "regular"
      )
    }
    self.trailingText = raw["trailingText"] as? String
    self.trailingTextColor = TiebaFormColor.resolve(raw["trailingTextColor"] as? String)
    self.titleWeight = raw["titleWeight"] as? String ?? "regular"
    self.showsSpinner = raw["showsSpinner"] as? Bool ?? false
  }

  /// 行内文字字体（SwiftUI textStyle 名 → 系统动态字体，跟随 Dynamic Type）。
  var font: UIFont {
    switch textStyle {
    case "subheadline": return UIFont.preferredFont(forTextStyle: .subheadline)
    case "footnote": return UIFont.preferredFont(forTextStyle: .footnote)
    case "caption": return UIFont.preferredFont(forTextStyle: .caption1)
    case "headline": return UIFont.preferredFont(forTextStyle: .headline)
    case "title": return UIFont.systemFont(ofSize: 28, weight: .bold)
    default: return UIFont.preferredFont(forTextStyle: .body)
    }
  }

  /// 标题字重（status 行 / prominentButton 用）。
  var resolvedTitleWeight: UIFont.Weight {
    switch titleWeight {
    case "medium": return .medium
    case "semibold": return .semibold
    case "bold": return .bold
    default: return .regular
    }
  }
}

/// 字体叠加字重（Dynamic Type 档位 + trait 覆盖；text 行的 `font({weight:})` 对位）。
extension UIFont {
  static func tiebaFormFont(_ base: UIFont, weight: UIFont.Weight) -> UIFont {
    guard weight != .regular else { return base }
    let descriptor = base.fontDescriptor.addingAttributes([
      .traits: [UIFontDescriptor.TraitKey.weight: weight],
    ])
    return UIFont(descriptor: descriptor, size: 0)
  }
}

// MARK: - 原生表单视图

final class TiebaFormListView: UIView {
  // MARK: - 数据

  /// 整份替换 → 重解析 + reload。结构性变化（增删行/换分组）才走这里；
  /// 单纯改值走 setValue(id:value:)。
  /// [{ title?, footer?, rows: [row] }, …]
  var sections: [[String: Any]] = [] {
    didSet { rebuild() }
  }

  /// 主题主色 #RRGGBB；nil = 「默认」主题（控件保持系统默认色）。
  var tintHex: String? {
    didSet {
      let next = tintHex.flatMap { TiebaFormColor.hex($0) }
      guard next != accent else { return }
      accent = next
      // 颜色只烙进可见行的配置里：局部 reconfigure 即可，不整表 reload。
      reconfigureVisibleRows()
    }
  }

  /// 应用内深浅（调用方语义输入）。**不再写 overrideUserInterfaceStyle**：深浅
  /// 由窗口级 override（TiebaChrome.setChromeDarkMode）+ 宿主子页的 trait 下发
  /// 到整棵树（含 presented 表单），表单全用系统语义色，trait 一变自己就跟上；
  /// 属性保留是因为页面仍按旧签名下发它（文件外的调用点，写入无副作用）。
  var isDark: Bool = false

  // MARK: - 回调（纯闭包：不依赖 Expo 的 EventDispatcher，原生 VC 也能直接接）

  /// 可点行（link/button）被按下
  var onRowPress: ((String) -> Void)?
  /// 开关被拨动（受控：视图不改模型，等调用方下发新值）
  var onToggle: ((String, Bool) -> Void)?
  /// 选择器选中新档
  var onPick: ((String, String) -> Void)?
  /// 确认弹窗点了确认
  var onConfirm: ((String) -> Void)?
  /// 取色器选了颜色（#RRGGBB 大写）；调用方写库后同样用 setValue 回推
  var onColorChange: ((String, String) -> Void)?
  /// 输入框每次编辑（textField 行；受控：视图不改真值，等调用方下发回来）
  var onTextChange: ((String, String) -> Void)?

  // MARK: - Private

  private let tableView = UITableView(frame: .zero, style: .insetGrouped)
  private var model: [[TiebaFormRow]] = []
  /// 主色（nil = 系统默认，见 tintHex）
  private var accent: UIColor?

  override init(frame: CGRect) {
    super.init(frame: frame)
    setUp()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private func setUp() {
    tableView.translatesAutoresizingMaskIntoConstraints = false
    tableView.dataSource = self
    tableView.delegate = self
    tableView.rowHeight = UITableView.automaticDimension
    tableView.estimatedRowHeight = 44
    // 行自撑高（多行副标题 / hero 块）；表头/脚用系统 grouped 配置，字体与
    // 左右边距与系统表单一致。
    tableView.sectionHeaderHeight = UITableView.automaticDimension
    tableView.estimatedSectionHeaderHeight = 28
    tableView.sectionFooterHeight = UITableView.automaticDimension
    tableView.estimatedSectionFooterHeight = 28
    // 卡片底 = 系统分组底（= SwiftUI Form 的滚动内容背景），卡片 = 次级分组底。
    tableView.backgroundColor = .systemGroupedBackground
    for id in TiebaFormCellRegistry.allReuseIDs {
      tableView.register(TiebaFormCellRegistry.cellClass(for: id), forCellReuseIdentifier: id)
    }
    tableView.register(TiebaFormHeroCell.self, forCellReuseIdentifier: TiebaFormHeroCell.reuseID)
    addSubview(tableView)
    // 安全区自适应（.automatic）：内容自动从导航栏下方开始、可滚到栏下，
    // 与迁移前 SwiftUI Form 在 RN surface 里的行为一致。
    tableView.contentInsetAdjustmentBehavior = .automatic
    NSLayoutConstraint.activate([
      tableView.leadingAnchor.constraint(equalTo: leadingAnchor),
      tableView.trailingAnchor.constraint(equalTo: trailingAnchor),
      tableView.topAnchor.constraint(equalTo: topAnchor),
      tableView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  private func rebuild() {
    model = sections.enumerated().map { sectionIndex, section in
      let rows = section["rows"] as? [[String: Any]] ?? []
      return rows.enumerated().compactMap { rowIndex, raw in
        TiebaFormRow(raw: raw, fallbackID: "s\(sectionIndex)r\(rowIndex)")
      }
    }
    tableView.reloadData()
  }

  /// 受控回推：把某行 id 的 value 就地在模型里改掉，并只 reconfigure 这一行
  /// （不整表 reload）。找不到该 id 返回 false——结构性变化（增删行）仍要走
  /// sections 整份替换。
  @discardableResult
  func setValue(id: String, value: String) -> Bool {
    for sectionIndex in model.indices {
      guard let rowIndex = model[sectionIndex].firstIndex(where: { $0.id == id }) else { continue }
      guard model[sectionIndex][rowIndex].value != value else { return true }
      model[sectionIndex][rowIndex].value = value
      let indexPath = IndexPath(row: rowIndex, section: sectionIndex)
      if tableView.indexPathsForVisibleRows?.contains(indexPath) == true {
        tableView.reconfigureRows(at: [indexPath])
      }
      return true
    }
    return false
  }

  /// 主色变化后重配可见行（离屏行出队时本来就会按新主色配置）。
  private func reconfigureVisibleRows() {
    guard let indexPaths = tableView.indexPathsForVisibleRows, !indexPaths.isEmpty else { return }
    tableView.reconfigureRows(at: indexPaths)
  }

  /// 行内控件的着色：有 tint 用主题主色，否则跟随系统 tint（= 系统蓝，
  /// 与迁移前未染色的 SwiftUI 控件同色）。
  var controlTint: UIColor { accent ?? .tintColor }

  /// 主色是否由调用方显式下发（非「默认」主题）。决定 picker 值/图标是否染色。
  var hasExplicitTint: Bool { accent != nil }

  // MARK: - 行动作

  private func row(at indexPath: IndexPath) -> TiebaFormRow? {
    guard indexPath.section < model.count, indexPath.row < model[indexPath.section].count else {
      return nil
    }
    return model[indexPath.section][indexPath.row]
  }

  private func handleRowPress(_ row: TiebaFormRow) {
    guard !row.disabled else { return }
    switch row.kind {
    case .confirm:
      presentConfirm(for: row)
    default:
      onRowPress?(row.id)
    }
  }

  private func presentConfirm(for row: TiebaFormRow) {
    // ConfirmationDialog 在 iPhone 上就是 UIAlertController.actionSheet
    // （标题/正文/破坏性确认/取消），文案由 JS 给，确认后才回 JS。
    guard let presenter = TiebaTopViewController.find() else { return }
    TiebaSceneHaptics.fire("sheet-present")
    let sheet = UIAlertController(
      title: row.confirmTitle ?? row.title,
      message: row.confirmMessage,
      preferredStyle: .actionSheet
    )
    sheet.addAction(UIAlertAction(title: row.confirmLabel ?? "确定", style: .destructive, handler: { [weak self] _ in
      TiebaSceneHaptics.fire("destructive")
      self?.onConfirm?(row.id)
    }))
    sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
    if let pop = sheet.popoverPresentationController {
      pop.sourceView = self
      pop.sourceRect = CGRect(x: bounds.midX, y: bounds.midY, width: 0, height: 0)
    }
    presenter.present(sheet, animated: true)
  }

  /// UIColor → "#RRGGBB"（大写；取色器给 sRGB 分量，越界钳制兜底）。
  static func hexString(from color: UIColor) -> String {
    var r: CGFloat = 0
    var g: CGFloat = 0
    var b: CGFloat = 0
    var a: CGFloat = 0
    guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return "#000000" }
    func part(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
    return String(format: "#%02X%02X%02X", part(r), part(g), part(b))
  }
}

// MARK: - 数据源 / 代理

extension TiebaFormListView: UITableViewDataSource, UITableViewDelegate {
  public func numberOfSections(in tableView: UITableView) -> Int {
    model.count
  }

  public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    section < model.count ? model[section].count : 0
  }

  public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    guard let row = row(at: indexPath) else { return UITableViewCell() }
    if row.kind == .hero {
      let cell = tableView.dequeueReusableCell(withIdentifier: TiebaFormHeroCell.reuseID, for: indexPath)
      (cell as? TiebaFormHeroCell)?.apply(row)
      return cell
    }
    let reuseID = TiebaFormCellRegistry.reuseID(for: row.kind)
    let cell = tableView.dequeueReusableCell(withIdentifier: reuseID, for: indexPath)
    // 上下文：主色 / 是否显式染色 / 受控与事件回调（cell 不认识业务，只上报意图）。
    let context = TiebaFormCellContext(
      tint: controlTint,
      explicitTint: hasExplicitTint,
      rowDisabled: row.disabled,
      onToggle: { [weak self] value in self?.onToggle?(row.id, value) },
      onPick: { [weak self] value in self?.onPick?(row.id, value) },
      onRowPress: { [weak self] in self?.onRowPress?(row.id) },
      onMenuPick: { [weak self] menuID in self?.onPick?(row.id, menuID) },
      onTextChange: { [weak self] text in self?.onTextChange?(row.id, text) },
      onColorChange: { [weak self] hex in self?.onColorChange?(row.id, hex) }
    )
    switch cell {
    case let cell as TiebaFormRowCell:
      cell.apply(row, context: context)
    case let cell as TiebaFormInputCell:
      cell.apply(row, context: context)
    case let cell as TiebaFormSegmentedCell:
      cell.apply(row, context: context)
    case let cell as TiebaFormAvatarCell:
      cell.apply(row, context: context)
    case let cell as TiebaFormActionCell:
      cell.apply(row, context: context)
    case let cell as TiebaFormProgressCell:
      cell.apply(row, context: context)
    case let cell as TiebaFormStatusCell:
      cell.apply(row, context: context)
    case let cell as TiebaFormSpinnerCell:
      cell.apply(row, context: context)
    case let cell as TiebaFormDateCell:
      cell.apply(row, context: context)
    case let cell as TiebaFormEmptyCell:
      cell.apply(row, context: context)
    default:
      break
    }
    return cell
  }

  public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    guard let row = row(at: indexPath), !row.disabled else { return }
    TiebaSceneHaptics.fire("press")
    switch row.kind {
    case .toggle:
      // SwiftUI 的 Toggle 行点行内任意处都可切换（不是只能点开关）；
      // ListItem + trailing Switch 的行不是（switchRowTap = false）。
      guard row.switchRowTap else { return }
      guard let cell = tableView.cellForRow(at: indexPath) as? TiebaFormRowCell else { return }
      cell.flipToggle()
    case .link, .button, .confirm, .menu, .prominentButton:
      handleRowPress(row)
    case .option:
      // Picker(.inline) 的一档：点行即选中（id 即 group，见头注释）。
      onPick?(row.id, row.value ?? "")
    default:
      break
    }
  }

  /// 分组尾部的空白让位高度（profile 页底栏让位：FieldGroup.SectionFooter 里的
  /// 定高 View）。仅在**没有** footer 文案时生效；有文案时走系统 footer 排版。
  public func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
    guard section < sections.count else { return UITableView.automaticDimension }
    let footer = sections[section]["footer"] as? String
    if footer?.isEmpty == false { return UITableView.automaticDimension }
    if let spacer = (sections[section]["footerSpacer"] as? NSNumber)?.doubleValue {
      return CGFloat(spacer)
    }
    return UITableView.automaticDimension
  }

  public func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
    guard section < sections.count, let title = sections[section]["title"] as? String, !title.isEmpty else {
      return nil
    }
    let view = headerFooter(tableView: tableView)
    var config = UIListContentConfiguration.groupedHeader()
    config.text = title
    view.contentConfiguration = config
    return view
  }

  public func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
    guard section < sections.count, let footer = sections[section]["footer"] as? String, !footer.isEmpty else {
      // 无 footer 文案但声明了 footerSpacer：给一个空 view，高度由
      // heightForFooterInSection 给（否则 UITableView 可能把这段空白吃掉）。
      if section < sections.count, sections[section]["footerSpacer"] != nil {
        let view = headerFooter(tableView: tableView)
        view.contentConfiguration = nil
        return view
      }
      return nil
    }
    let view = headerFooter(tableView: tableView)
    var config = UIListContentConfiguration.groupedFooter()
    config.text = footer
    view.contentConfiguration = config
    return view
  }

  /// 表头/脚视图（系统 grouped 配置的字体与左右边距；固定复用 id，省掉每次新建）。
  private func headerFooter(tableView: UITableView) -> UITableViewHeaderFooterView {
    tableView.dequeueReusableHeaderFooterView(withIdentifier: "TiebaFormHeaderFooter")
      ?? UITableViewHeaderFooterView(reuseIdentifier: "TiebaFormHeaderFooter")
  }
}

// MARK: - 行 cell

/// cell 的配置上下文：cell 只认这几个输入，业务（跳转/落库/触觉）全在调用方。
/// 事件闭包按"用户意图"上报，闭包内部已经把行 id 绑好（cell 不认识 id）。
struct TiebaFormCellContext {
  /// 主题主色（nil 主题时是系统 tint）
  let tint: UIColor
  /// 主色是否由 JS 显式下发（「默认」主题下开关保持系统绿、Picker 值保持次级灰）
  let explicitTint: Bool
  /// 整行禁用（灰化）
  let rowDisabled: Bool
  let onToggle: (Bool) -> Void
  let onPick: (String) -> Void
  /// 行本体被按下（link/button/confirm/color/menu/prominentButton；
  /// avatar 行 = 尾部按钮按下）
  let onRowPress: () -> Void
  /// menu 行选中了某一项（参数 = menuItems[].id）
  let onMenuPick: (String) -> Void
  /// textField 每次编辑（参数 = 当前文本）
  let onTextChange: (String) -> Void
  /// color 行选了颜色（参数 = #RRGGBB 大写）
  let onColorChange: (String) -> Void
}

/// 行种类 → cell 类 / 复用 id。集中在注册表里，tableView 注册与 cellForRow 共用一份。
/// @MainActor：cell 类的 reuseID 是主 actor 隔离的（UIKit 类），注册表跟着隔离。
@MainActor
enum TiebaFormCellRegistry {
  static let allReuseIDs: [String] = [
    TiebaFormRowCell.reuseID,
    TiebaFormInputCell.reuseID,
    TiebaFormSegmentedCell.reuseID,
    TiebaFormAvatarCell.reuseID,
    TiebaFormActionCell.reuseID,
    TiebaFormProgressCell.reuseID,
    TiebaFormStatusCell.reuseID,
    TiebaFormSpinnerCell.reuseID,
    TiebaFormDateCell.reuseID,
    TiebaFormEmptyCell.reuseID,
  ]

  static func cellClass(for reuseID: String) -> UITableViewCell.Type {
    switch reuseID {
    case TiebaFormInputCell.reuseID: return TiebaFormInputCell.self
    case TiebaFormSegmentedCell.reuseID: return TiebaFormSegmentedCell.self
    case TiebaFormAvatarCell.reuseID: return TiebaFormAvatarCell.self
    case TiebaFormActionCell.reuseID: return TiebaFormActionCell.self
    case TiebaFormProgressCell.reuseID: return TiebaFormProgressCell.self
    case TiebaFormStatusCell.reuseID: return TiebaFormStatusCell.self
    case TiebaFormSpinnerCell.reuseID: return TiebaFormSpinnerCell.self
    case TiebaFormDateCell.reuseID: return TiebaFormDateCell.self
    case TiebaFormEmptyCell.reuseID: return TiebaFormEmptyCell.self
    default: return TiebaFormRowCell.self
    }
  }

  /// 行种类 → 复用 id。
  static func reuseID(for kind: TiebaFormRow.Kind) -> String {
    switch kind {
    case .textField: return TiebaFormInputCell.reuseID
    case .segmented: return TiebaFormSegmentedCell.reuseID
    case .avatar: return TiebaFormAvatarCell.reuseID
    case .prominentButton: return TiebaFormActionCell.reuseID
    case .progress: return TiebaFormProgressCell.reuseID
    case .status: return TiebaFormStatusCell.reuseID
    case .spinner: return TiebaFormSpinnerCell.reuseID
    case .datePicker: return TiebaFormDateCell.reuseID
    case .empty: return TiebaFormEmptyCell.reuseID
    default: return TiebaFormRowCell.reuseID
    }
  }
}

/// 系统表单行的共用底座：卡片底色 + 内容视图透明 + 行高下限 44
/// （Dynamic Type 放大时内容更高、自然被撑开——行高仍由内容/系统给）。
class TiebaFormBaseCell: UITableViewCell {
  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    selectionStyle = .none
    backgroundColor = .secondarySystemGroupedBackground
    contentView.backgroundColor = .clear
    let minHeight = contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
    minHeight.priority = .required
    minHeight.isActive = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// 系统表单行内容的左右内边距 —— 取自系统内容配置自己的度量，不猜数字
  /// （Form 行的内容起点与系统设置页一致）。
  static var rowMargins: NSDirectionalEdgeInsets {
    UIListContentConfiguration.cell().directionalLayoutMargins
  }
}


/// 单行 cell。内容交给系统的 **UIListContentConfiguration**（行高、内边距、字体、
/// 值对齐、分隔线规则全部由 UIKit 给——与系统设置页/表单同源），本类只做三件事：
///   1. 把行模型翻译成配置（.cell / .subtitleCell / .valueCell 三选一）；
///   2. 附件：UISwitch、UICellAccessory.popUpMenu（选择器）、UIColorWell（取色）——
///      都是系统控件；
///   3. 序列：系统菜单（选择器）与受控开关的回弹。
/// 行图标（RowIcon 形态）是唯一的合成图形：UIListContentConfiguration 的 image
/// 槽不支持"底色 + 符号"的富图标，而 RN 侧 RowIcon 就是色块+白符号的合成视图，
/// 所以用系统绘图 API（UIGraphicsImageRenderer + UIImage(systemName:)）合成一张
/// 30x30 的图交给 image 槽，按 (symbol, 色) 缓存。不引入任何图片资源。
final class TiebaFormRowCell: UITableViewCell {
  static let reuseID = "TiebaFormRowCell"

  /// 系统表单行的最小行高（与 SwiftUI List 行一致；系统对分组行也是 44 起）。
  static let minimumHeight: CGFloat = 44

  /// (symbol|色) → 合成图。主 actor 隔离（cell 只在主线程配置），滚动时不重绘。
  private static var iconCache: [String: UIImage] = [:]

  private let toggle = UISwitch()
  /// picker 行的系统菜单按钮：**铺满整行**（点行内任意处都弹菜单，与系统设置一致），
  /// 箭头靠配置右对齐画在尾随边。
  /// ⚠️ 不再当 `accessoryView`：真机上它被画到了行首、半掩在卡片圆角外，命中区
  /// 也跟着跑偏 —— 整页 picker 都点不动（用户实证）。覆盖层的 frame 由我们说了算。
  private let pickerMenuButton = UIButton(type: .system)
  /// 取色行的系统色井（自带色环外观与取色浮层，点击回调 .valueChanged）
  private let colorWell = UIColorWell()

  private var onToggle: ((Bool) -> Void)?
  private var onPick: ((String) -> Void)?
  private var onMenuPick: ((String) -> Void)?
  private var onColorChange: ((String) -> Void)?
  /// 模型值（受控回弹的落点）
  private var modelToggleValue = false
  /// apply 算好的分隔线内缩（nil = 不动，保持系统默认）。系统会在布局时重置
  /// separatorInset，所以留到 layoutSubviews 重申一次——不再翻视图树量 label。
  private var resolvedSeparatorInset: UIEdgeInsets?

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    selectionStyle = .none
    backgroundColor = .secondarySystemGroupedBackground
    contentView.backgroundColor = .clear

    toggle.addTarget(self, action: #selector(toggleChanged), for: .valueChanged)
    colorWell.supportsAlpha = false
    colorWell.addTarget(self, action: #selector(colorWellChanged), for: .valueChanged)

    // 行高的下限由系统给（内容配置自带行度量），这里只兜底 44（与系统表单一致，
    // Dynamic Type 放大时内容更高、自然被撑开）。
    let minHeight = contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumHeight)
    minHeight.priority = .required
    minHeight.isActive = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// picker 行把菜单按钮铺满 contentView（幂等：同一 cell 复用多次只挂一次）。
  private func attachPickerOverlay() {
    guard pickerMenuButton.superview !== contentView else { return }
    pickerMenuButton.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(pickerMenuButton)
    NSLayoutConstraint.activate([
      pickerMenuButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      pickerMenuButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      pickerMenuButton.topAnchor.constraint(equalTo: contentView.topAnchor),
      pickerMenuButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
    ])
  }

  /// 配置一行（上下文见 TiebaFormCellContext）。
  func apply(_ row: TiebaFormRow, context: TiebaFormCellContext) {
    self.onToggle = context.onToggle
    self.onPick = context.onPick
    self.onMenuPick = context.onMenuPick
    self.onColorChange = context.onColorChange
    let tint = context.tint
    let explicitTint = context.explicitTint

    // ── 复用重置 ──
    accessoryView = nil
    accessoryType = .none
    selectionStyle = .none
    toggle.isHidden = true
    toggle.isEnabled = true
    var pickerConfig = UIButton.Configuration.plain()
    pickerConfig.image = UIImage(systemName: "chevron.up.chevron.down")
    pickerConfig.imagePlacement = .trailing
    // 「值 + 箭头」整块靠右：箭头恒在文字右边（各自排布，不会叠字）。
    pickerConfig.imagePadding = 6
    pickerConfig.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 16)
    pickerMenuButton.configuration = pickerConfig
    pickerMenuButton.contentHorizontalAlignment = .trailing
    pickerMenuButton.showsMenuAsPrimaryAction = true
    // 浮层展开触觉（iOS 14+ 的 menuActionTriggered：只在菜单真的弹出时发）。
    pickerMenuButton.addAction(
      UIAction { _ in TiebaSceneHaptics.fire("sheet-present") },
      for: .menuActionTriggered
    )

    pickerMenuButton.isHidden = true
    pickerMenuButton.isEnabled = true
    colorWell.isHidden = true
    resolvedSeparatorInset = nil
    var hasImage = false

    let disabledColor = UIColor.tertiaryLabel
    let emphasized: UIColor = row.destructive ? .systemRed : (row.override ?? tint)

    // ── 内容配置（系统行度量）──
    var config: UIListContentConfiguration
    switch row.kind {
    case .picker:
      config = .valueCell()     // 标题 + 尾部当前值（右对齐、基线与标题对齐）
    case .link, .toggle, .menu:
      config = .subtitleCell()  // 标题 + 次行说明
    default:
      config = .cell()
    }

    if let icon = row.icon, row.kind != .hero {
      if let iconTint = row.iconTint {
        config.image = Self.squareIconImage(symbol: icon, color: row.disabled ? .systemGray3 : iconTint)
        config.imageProperties.maximumSize = CGSize(width: 30, height: 30)
        config.imageProperties.reservedLayoutSize = CGSize(width: 30, height: 30)
      } else {
        // 裸符号（Toggle/Picker/Button 的 systemImage）：随主色染色。
        config.image = UIImage(
          systemName: icon,
          withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        )
        config.imageProperties.tintColor = row.disabled ? disabledColor : emphasized
        config.imageProperties.maximumSize = CGSize(width: 24, height: 24)
        // 图槽宽度固定 24：文字起点可算（分隔线对齐），不靠翻视图树量实际 label。
        config.imageProperties.reservedLayoutSize = CGSize(width: 24, height: 24)
      }
      hasImage = true
    }

    config.text = row.title
    config.textProperties.color = row.disabled
      ? disabledColor
      : (row.kind == .button || row.kind == .confirm ? emphasized : .label)
    config.textProperties.numberOfLines = 0

    // 副标题：ListItem 的 supportingText / Toggle 的子 Text / Button 的说明。
    if row.kind == .link || row.kind == .toggle || row.kind == .button || row.kind == .confirm
      || row.kind == .menu {
      config.secondaryText = row.subtitle
      // ⚠️ 字号必须显式对齐：系统 .subtitleCell 的次行是 subheadline(15)，
      // 而迁移前 ListItem 的 supportingText 是 SwiftUI 行内默认 body(17)；
      // Button 的子 Text 在 SwiftUI 里也是行内默认字号（这里跟 body）。
      config.secondaryTextProperties.font = UIFont.preferredFont(forTextStyle: .body)
      config.secondaryTextProperties.color = row.disabled ? disabledColor : .secondaryLabel
      config.secondaryTextProperties.numberOfLines = 0
    }
    if row.kind == .text {
      config.textProperties.font = row.resolvedTitleWeight == .regular
        ? row.font
        : UIFont.tiebaFormFont(row.font, weight: row.resolvedTitleWeight)
      // 颜色规则与 SwiftUI 的 foregroundStyle 一致：JS 给了就用 JS 的，
      // 否则 .label（要次级灰时 JS 传 secondaryLabel token）。
      config.textProperties.color = row.override ?? .label
    }
    contentConfiguration = config

    // 分隔线对齐文字（跳过图标）：图槽宽由 imageProperties.reservedLayoutSize 固定，
    // 文字起点 = 内容左内边距 + 图槽宽 + imageToTextPadding，直接算，不翻视图树。
    if hasImage {
      let margins = config.directionalLayoutMargins
      resolvedSeparatorInset = UIEdgeInsets(
        top: 0,
        left: margins.leading + config.imageProperties.reservedLayoutSize.width + config.imageToTextPadding,
        bottom: 0,
        right: 0
      )
    }

    // ── 附件 / 行形态 ──
    switch row.kind {
    case .link:
      selectionStyle = row.disabled ? .none : .default

    case .toggle:
      toggle.isHidden = false
      modelToggleValue = row.value == "1" || row.value?.lowercased() == "true"
      toggle.isOn = modelToggleValue
      toggle.isEnabled = !row.disabled && !row.switchDisabled
      // 「默认」主题（explicitTint = false）不写 onTintColor：UISwitch 出厂就是
      // 系统绿，与设置页现状（默认主题下开关为绿）一致。
      toggle.onTintColor = (explicitTint && !row.disabled) ? (row.override ?? tint) : nil
      accessoryView = toggle
      selectionStyle = .none

    case .picker:
      // 整行可点：按钮铺满 contentView（自带弹菜单），并**自己画**「选中项文字 + 箭头」。
      // ⚠️ 值文本不能走 content 的 secondaryText：它是原始 value（"default"/"1"），
      // 菜单里却是 label（"默认"/"标准"），两者对不上（用户实证）；而且 secondaryText
      // 固定贴尾随边，会和覆盖层的箭头叠在一起。
      selectionStyle = .none
      if !row.options.isEmpty {
        attachPickerOverlay()
        pickerMenuButton.isHidden = false
        pickerMenuButton.isEnabled = !row.disabled
        pickerMenuButton.menu = buildMenu(row: row)
        var buttonConfig = pickerMenuButton.configuration ?? .plain()
        buttonConfig.title = row.options.first { $0.value == row.value }?.label ?? row.value
        buttonConfig.baseForegroundColor = row.disabled
          ? .tertiaryLabel
          : (explicitTint ? emphasized : .secondaryLabel)
        pickerMenuButton.configuration = buttonConfig
      }

    case .button, .confirm:
      selectionStyle = row.disabled ? .none : .default

    case .option:
      // Picker(.inline) 的一档：标题 + 系统打勾（accessoryType，行不是按钮形态）。
      accessoryType = row.selected ? .checkmark : .none
      selectionStyle = row.disabled ? .none : .default

    case .menu:
      // 行尾 ellipsis UIMenu（account 每行「移除账号」）；行本体可点（切换账号）。
      // 选中态（当前账号）用系统打勾放在 ellipsis 之前（accessoryView 里横排）。
      accessoryView = menuAccessory(row: row)
      selectionStyle = row.disabled ? .none : .default

    case .text:
      selectionStyle = .none

    case .color:
      // 系统 UIColorWell：色井外观 + 点击弹取色器，都是系统给的（原来是自绘色环
      // + 表单持有取色器 delegate 回传，那套整体删掉）。
      colorWell.isHidden = false
      colorWell.isEnabled = !row.disabled
      colorWell.selectedColor = row.value.flatMap { TiebaFormColor.hex($0) } ?? .systemBlue
      accessoryView = colorWell
      selectionStyle = .none

    case .hero, .textField, .segmented, .avatar, .prominentButton, .progress, .status,
      .spinner, .datePicker, .empty:
      // 这些种类走各自的专用 cell（见 TiebaFormCellRegistry.reuseID(for:)），
      // 不会落到本 cell；列在这里只为穷尽 switch。
      break
    }
  }

  /// RowIcon 形态图标：30x30 圆角色块 + 15pt semibold 白色系统符号。
  /// 用系统绘图 API 合成（不引资源、不画贝塞尔字形），按 (symbol|色) 缓存。
  private static func squareIconImage(symbol: String, color: UIColor) -> UIImage? {
    let key = symbol + "|" + TiebaFormListView.hexString(from: color)
    if let cached = iconCache[key] { return cached }
    let size = CGSize(width: 30, height: 30)
    let renderer = UIGraphicsImageRenderer(size: size)
    let image = renderer.image { _ in
      color.setFill()
      UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 8).fill()
      guard let glyph = UIImage(
        systemName: symbol,
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
      )?.withTintColor(.white, renderingMode: .alwaysOriginal) else { return }
      glyph.draw(at: CGPoint(
        x: (size.width - glyph.size.width) / 2,
        y: (size.height - glyph.size.height) / 2
      ))
    }
    iconCache[key] = image
    return image
  }

  private func buildMenu(row: TiebaFormRow) -> UIMenu {
    let actions = row.options.map { option in
      UIAction(
        title: option.label,
        state: option.value == row.value ? .on : .off,
        handler: { [weak self] _ in self?.onPick?(option.value) }
      )
    }
    // .singleSelection：单选菜单（系统保证同时只有一个 on 项 + 画打勾）。
    return UIMenu(title: row.title, options: .singleSelection, children: actions)
  }

  /// menu 行的行尾附件：可选打勾（当前账号）+ 行尾 ellipsis 菜单按钮。
  /// ellipsis 的形态对应迁移前的 `Menu(label:"", systemImage:"ellipsis",
  /// labelStyle: iconOnly, buttonStyle: plain)`：一个纯图标按钮，着色跟主色。
  private func menuAccessory(row: TiebaFormRow) -> UIView {
    let stack = UIStackView()
    stack.axis = .horizontal
    stack.alignment = .center
    stack.spacing = 8

    if row.selected {
      let check = UIImageView(image: UIImage(
        systemName: "checkmark",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
      ))
      check.tintColor = row.trailingColor ?? .systemGreen
      stack.addArrangedSubview(check)
    }

    let button = UIButton(type: .system)
    button.setImage(
      UIImage(
        systemName: "ellipsis",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)
      ),
      for: .normal
    )
    button.tintColor = row.disabled ? .tertiaryLabel : (row.override ?? .tintColor)
    button.isEnabled = !row.disabled && !row.menuItems.isEmpty
    if button.isEnabled {
      button.showsMenuAsPrimaryAction = true
      button.menu = buildMenuItemMenu(row: row)
      button.addAction(
        UIAction { _ in TiebaSceneHaptics.fire("sheet-present") },
        for: .menuActionTriggered
      )
    }
    // 纯图标按钮的命中区：图标本身约 17pt，给到 44 的行高（不改变布局宽度）。
    button.widthAnchor.constraint(greaterThanOrEqualToConstant: 30).isActive = true
    stack.addArrangedSubview(button)

    stack.translatesAutoresizingMaskIntoConstraints = true
    let size = stack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
    stack.frame = CGRect(origin: .zero, size: size)
    return stack
  }

  private func buildMenuItemMenu(row: TiebaFormRow) -> UIMenu {
    let actions = row.menuItems.map { item in
      UIAction(
        title: item.title,
        image: item.icon.flatMap { UIImage(systemName: $0) },
        attributes: item.destructive ? .destructive : [],
        handler: { [weak self] _ in self?.onMenuPick?(item.id) }
      )
    }
    return UIMenu(children: actions)
  }

  @objc private func toggleChanged() {
    TiebaSceneHaptics.fire("toggle")
    // 不做"先拨回模型值、等回推"：那会让一次点击连播两段动画（弹回 → 再弹过去），
    // 用户实证"开关动画非常差、完全不顺滑"。新值直接交给调用方，写库成功由
    // setValue 就地确认（值相同不重播动画）；写失败由写库侧拨回真实档位
    //（TiebaFormPageController 的失败分支）——那时的一次回弹才是语义本身。
    onToggle?(toggle.isOn)
  }

  /// 供 didSelectRow 使用：点行内任意处 = 拨一次开关（SwiftUI 开关行的行为）。
  func flipToggle() {
    guard !toggle.isHidden, toggle.isEnabled else { return }
    toggle.setOn(!toggle.isOn, animated: true)
    toggleChanged()
  }

  /// 系统会在布局阶段重置 separatorInset，这里把 apply 算好的值重申一次
  /// （值由内容配置的度量算出，不做视图树递归；无图标行不动，保持系统默认）。
  override func layoutSubviews() {
    super.layoutSubviews()
    guard let inset = resolvedSeparatorInset, separatorInset != inset else { return }
    separatorInset = inset
  }

  @objc private func colorWellChanged() {
    guard let color = colorWell.selectedColor else { return }
    TiebaSceneHaptics.fire("toggle")
    onColorChange?(TiebaFormListView.hexString(from: color))
  }
}

// MARK: - hero cell（关于页首块：图标 + 名称 + 版本）

final class TiebaFormHeroCell: UITableViewCell {
  static let reuseID = "TiebaFormHeroCell"

  /// Bundle 相对路径 → 图。滚动期反复读盘/解码的分配省掉（同图在同页多次出现）。
  private static var imageCache: [String: UIImage] = [:]

  private let stack = UIStackView()
  private let heroImage = UIImageView()
  private let titleLabel = UILabel()
  private let subtitleLabel = UILabel()

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    selectionStyle = .none
    backgroundColor = .secondarySystemGroupedBackground
    contentView.backgroundColor = .clear

    stack.axis = .vertical
    stack.alignment = .center
    // VStack spacing Spacing.xs(4) + padding vertical Spacing.lg(16)
    stack.spacing = 4
    stack.translatesAutoresizingMaskIntoConstraints = false

    heroImage.contentMode = .scaleAspectFill
    heroImage.clipsToBounds = true
    // RN 侧是 { width: 64, height: 64, borderRadius: 14 }（未声明 borderCurve
    // → 圆形圆角），保持一致，不要补 continuous。
    heroImage.layer.cornerRadius = 14
    heroImage.translatesAutoresizingMaskIntoConstraints = false

    titleLabel.textAlignment = .center
    titleLabel.numberOfLines = 0
    subtitleLabel.textAlignment = .center
    subtitleLabel.numberOfLines = 0

    stack.addArrangedSubview(heroImage)
    stack.addArrangedSubview(titleLabel)
    stack.addArrangedSubview(subtitleLabel)
    contentView.addSubview(stack)

    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
      stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
      stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
      stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
      heroImage.widthAnchor.constraint(equalToConstant: 64),
      heroImage.heightAnchor.constraint(equalToConstant: 64),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func apply(_ row: TiebaFormRow) {
    heroImage.isHidden = row.imageName == nil
    if let name = row.imageName {
      // 打包图（Bundle 相对路径，如 "expo.icon/Assets/icon-light.png"）：与 RN
      // 侧 require('@/assets/images/icon.png') 是同一张图（同 md5），走 Bundle
      // 直读，不进 Metro/网络（开发档也必须能显示，见 about.tsx 的缺口注释）。
      if let cached = Self.imageCache[name] {
        heroImage.image = cached
      } else if let image = UIImage(contentsOfFile: Bundle.main.bundlePath + "/" + name) {
        Self.imageCache[name] = image
        heroImage.image = image
      } else {
        heroImage.image = nil
      }
    }
    titleLabel.text = row.title
    titleLabel.font = row.font
    titleLabel.textColor = .label
    subtitleLabel.text = row.subtitle
    subtitleLabel.font = UIFont.preferredFont(forTextStyle: .subheadline)
    subtitleLabel.textColor = .secondaryLabel
  }
}

// MARK: - 系统符号小工具

/// SF Symbol → 配置好的 UIImage（cell 内共用；无效名返回 nil，UIKit 画占位不崩）。
enum TiebaFormSymbol {
  static func image(_ name: String?, pointSize: CGFloat, weight: UIImage.SymbolWeight = .regular) -> UIImage? {
    guard let name, !name.isEmpty else { return nil }
    return UIImage(
      systemName: name,
      withConfiguration: UIImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
    )
  }
}

// MARK: - 输入行（textField：UITextField / UITextView）

/// TextField 行。单行走 UITextField（placeholder/return 收键盘），多行走
/// UITextView（SwiftUI `TextField(axis: .vertical)`：内容增高、行随内容长）。
/// 受控语义：值由调用方下发（value）；每次编辑只上报 onTextChange。
/// 行高：多行按内容自撑（isScrollEnabled = false + 内容尺寸变化时刷一次表），
/// 与 SwiftUI 竖直输入框在 Form 里"随输入长高"的行为一致。
final class TiebaFormInputCell: TiebaFormBaseCell {
  static let reuseID = "TiebaFormInputCell"

  private let field = UITextField()
  private let textView = UITextView()
  private let placeholderLabel = UILabel()
  private var singleLineConstraints: [NSLayoutConstraint] = []
  private var multiLineConstraints: [NSLayoutConstraint] = []
  private var onTextChange: ((String) -> Void)?
  private var maxLength = 0
  private var isMultiline = false
  private var heightRefreshScheduled = false
  private weak var owningTableView: UITableView?

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    let margins = Self.rowMargins

    field.font = .preferredFont(forTextStyle: .body)
    field.adjustsFontForContentSizeCategory = true
    field.textColor = .label
    field.borderStyle = .none
    field.returnKeyType = .done
    field.delegate = self
    field.addTarget(self, action: #selector(fieldChanged), for: .editingChanged)
    field.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(field)

    textView.font = .preferredFont(forTextStyle: .body)
    textView.adjustsFontForContentSizeCategory = true
    textView.textColor = .label
    textView.backgroundColor = .clear
    textView.isScrollEnabled = false
    textView.textContainerInset = .zero
    textView.textContainer.lineFragmentPadding = 0
    textView.delegate = self
    textView.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(textView)

    placeholderLabel.font = .preferredFont(forTextStyle: .body)
    placeholderLabel.adjustsFontForContentSizeCategory = true
    placeholderLabel.textColor = .placeholderText
    placeholderLabel.numberOfLines = 0
    placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(placeholderLabel)

    singleLineConstraints = [
      field.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: margins.leading),
      field.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -margins.trailing),
      field.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 11),
      field.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -11),
    ]
    multiLineConstraints = [
      textView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: margins.leading),
      textView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -margins.trailing),
      textView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
      textView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
      textView.heightAnchor.constraint(greaterThanOrEqualToConstant: 24),
      placeholderLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
      placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: textView.trailingAnchor),
      placeholderLabel.topAnchor.constraint(equalTo: textView.topAnchor),
    ]
    NSLayoutConstraint.activate(singleLineConstraints)
  }

  override func didMoveToSuperview() {
    super.didMoveToSuperview()
    owningTableView = Self.nearestTableView(from: self)
  }

  private static func nearestTableView(from cell: UITableViewCell) -> UITableView? {
    var view: UIView? = cell.superview
    while let current = view {
      if let table = current as? UITableView { return table }
      view = current.superview
    }
    return nil
  }

  func apply(_ row: TiebaFormRow, context: TiebaFormCellContext) {
    onTextChange = context.onTextChange
    maxLength = row.maxLength
    isMultiline = row.multiline

    field.isHidden = isMultiline
    textView.isHidden = !isMultiline
    NSLayoutConstraint.deactivate(isMultiline ? singleLineConstraints : multiLineConstraints)
    NSLayoutConstraint.activate(isMultiline ? multiLineConstraints : singleLineConstraints)

    field.isEnabled = !row.disabled
    textView.isEditable = !row.disabled
    field.placeholder = isMultiline ? nil : row.placeholder
    placeholderLabel.text = row.placeholder

    // 受控值：**用户没有正在编辑**且文本确实不同才写回。
    // 光比较文本不够——JS 侧打字期间不重渲染，一旦它因别的状态重渲染（上传中、
    // 保存中、性别切换…），下发的仍是打字前的旧值，会把用户刚打的字覆盖掉。
    let value = row.value ?? ""
    if isMultiline {
      if !textView.isFirstResponder, textView.text != value { textView.text = value }
    } else if !field.isFirstResponder, field.text != value {
      field.text = value
    }
    updatePlaceholderVisibility()
    // 复用回来时高度按新内容收敛一次。cellForRow 内不能动表格（嵌套 beginUpdates），
    // 所以这里只登记一次，等本轮 runloop 结束再算。
    if isMultiline { scheduleHeightRefresh() }
  }

  private func updatePlaceholderVisibility() {
    guard isMultiline else {
      placeholderLabel.isHidden = true
      return
    }
    placeholderLabel.isHidden = !(textView.text ?? "").isEmpty
  }

  @objc private func fieldChanged() {
    onTextChange?(field.text ?? "")
  }

  /// 多行内容变化后让表格重算行高（自撑行；内容尺寸变了要显式失效一次）。
  /// ⚠️ 只能在 cellForRow 之外调用（apply 期间动表格会嵌套 beginUpdates），
  /// 且宽度要等布局完（未布局时 bounds.width = 0 会把高度算成无限大）。
  private func scheduleHeightRefresh() {
    guard !heightRefreshScheduled else { return }
    heightRefreshScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.heightRefreshScheduled = false
      self.refreshHeightIfNeeded()
    }
  }

  private func refreshHeightIfNeeded() {
    guard let table = owningTableView else { return }
    let width = textView.bounds.width
    guard width > 0 else { return }
    let target = textView.sizeThatFits(
      CGSize(width: width, height: .greatestFiniteMagnitude)
    ).height
    guard abs(target - textView.bounds.height) >= 0.5 else { return }
    UIView.performWithoutAnimation {
      table.beginUpdates()
      table.endUpdates()
    }
  }

  /// 截断到 maxLength（0 = 不限）。
  private func clamp(_ text: String) -> String {
    guard maxLength > 0, text.count > maxLength else { return text }
    return String(text.prefix(maxLength))
  }
}

extension TiebaFormInputCell: UITextFieldDelegate {
  func textField(
    _ textField: UITextField,
    shouldChangeCharactersIn range: NSRange,
    replacementString string: String
  ) -> Bool {
    guard maxLength > 0 else { return true }
    let current = (textField.text ?? "") as NSString
    let next = current.replacingCharacters(in: range, with: string)
    if next.count > maxLength {
      textField.text = String(next.prefix(maxLength))
      onTextChange?(textField.text ?? "")
      return false
    }
    return true
  }

  func textFieldShouldReturn(_ textField: UITextField) -> Bool {
    // SwiftUI 单行 TextField 回车 = 提交并收键盘（不触发任何业务回调）。
    textField.resignFirstResponder()
    return false
  }
}

extension TiebaFormInputCell: UITextViewDelegate {
  func textViewDidChange(_ textView: UITextView) {
    updatePlaceholderVisibility()
    if maxLength > 0, textView.text.count > maxLength {
      textView.text = String(textView.text.prefix(maxLength))
    }
    scheduleHeightRefresh()
    onTextChange?(textView.text ?? "")
  }

  func textView(
    _ textView: UITextView,
    shouldChangeTextIn range: NSRange,
    replacementText text: String
  ) -> Bool {
    guard maxLength > 0 else { return true }
    let current = (textView.text ?? "") as NSString
    let next = current.replacingCharacters(in: range, with: text)
    if next.count > maxLength {
      textView.text = String(next.prefix(maxLength))
      updatePlaceholderVisibility()
      scheduleHeightRefresh()
      onTextChange?(textView.text ?? "")
      return false
    }
    return true
  }
}

// MARK: - 分段行（segmented：UISegmentedControl）

/// Picker(.segmented) 行：系统分段控件，选中即上报（受控：值由 sections 下发）。
final class TiebaFormSegmentedCell: TiebaFormBaseCell {
  static let reuseID = "TiebaFormSegmentedCell"

  private let control = UISegmentedControl()
  private var onPick: ((String) -> Void)?
  private var values: [String] = []

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    let margins = Self.rowMargins
    control.translatesAutoresizingMaskIntoConstraints = false
    control.addTarget(self, action: #selector(segmentChanged), for: .valueChanged)
    contentView.addSubview(control)
    NSLayoutConstraint.activate([
      control.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: margins.leading),
      control.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -margins.trailing),
      control.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
      control.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
    ])
  }

  func apply(_ row: TiebaFormRow, context: TiebaFormCellContext) {
    onPick = context.onPick
    values = row.options.map(\.value)
    control.removeAllSegments()
    for (index, option) in row.options.enumerated() {
      control.insertSegment(withTitle: option.label, at: index, animated: false)
    }
    if let selected = values.firstIndex(of: row.value ?? "") {
      control.selectedSegmentIndex = selected
    } else {
      control.selectedSegmentIndex = UISegmentedControl.noSegment
    }
    control.isEnabled = !row.disabled
  }

  @objc private func segmentChanged() {
    TiebaSceneHaptics.fire("segment")
    let index = control.selectedSegmentIndex
    guard index >= 0, index < values.count else { return }
    onPick?(values[index])
  }
}

// MARK: - 头像行（avatar）

/// 头像行：圆头像（复用仓内 TiebaForumAvatarView：Nuke 加载 + 首字占位）
/// + 标题/副标题 + 尾部按钮或说明文字。用于「编辑资料」的头像块（尾部 = 更换头像
/// 按钮）与屏蔽页的云端黑名单/屏蔽吧。
final class TiebaFormAvatarCell: TiebaFormBaseCell {
  static let reuseID = "TiebaFormAvatarCell"

  /// 头像容器：尺寸随行变化（TiebaForumAvatarView 的尺寸在 init 固定，换尺寸才重建）。
  private let avatarBox = UIView()
  private var avatar: TiebaForumAvatarView?
  /// 当前行的头像尺寸（容器约束）
  private var avatarSize: CGFloat = 0
  /// 已建头像的尺寸（两者不同才重建头像视图）
  private var builtAvatarSize: CGFloat = 0
  private var avatarBoxWidth: NSLayoutConstraint?
  private var avatarBoxHeight: NSLayoutConstraint?
  private let titleLabel = UILabel()
  private let subtitleLabel = UILabel()
  private let textStack = UIStackView()
  private let rowStack = UIStackView()
  private let trailingButton = UIButton(type: .system)
  private let trailingLabel = UILabel()
  private let spinner = UIActivityIndicatorView(style: .medium)
  private var onPress: (() -> Void)?

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    let margins = Self.rowMargins

    avatarBox.translatesAutoresizingMaskIntoConstraints = false
    avatarBox.clipsToBounds = true

    titleLabel.font = .preferredFont(forTextStyle: .body)
    titleLabel.adjustsFontForContentSizeCategory = true
    titleLabel.textColor = .label
    titleLabel.numberOfLines = 1
    subtitleLabel.font = .preferredFont(forTextStyle: .footnote)
    subtitleLabel.adjustsFontForContentSizeCategory = true
    subtitleLabel.textColor = .secondaryLabel
    subtitleLabel.numberOfLines = 1

    textStack.axis = .vertical
    textStack.alignment = .leading
    textStack.spacing = 2
    textStack.addArrangedSubview(titleLabel)
    textStack.addArrangedSubview(subtitleLabel)

    trailingButton.titleLabel?.font = .preferredFont(forTextStyle: .body)
    trailingButton.addTarget(self, action: #selector(trailingPressed), for: .touchUpInside)
    trailingLabel.font = .preferredFont(forTextStyle: .footnote)
    trailingLabel.textColor = .tertiaryLabel
    trailingLabel.numberOfLines = 1

    rowStack.axis = .horizontal
    rowStack.alignment = .center
    rowStack.spacing = 12
    rowStack.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(rowStack)
    contentView.addSubview(avatarBox)
    rowStack.addArrangedSubview(textStack)
    rowStack.addArrangedSubview(trailingButton)
    rowStack.addArrangedSubview(trailingLabel)
    rowStack.addArrangedSubview(spinner)
    // 文本列吃掉多余宽度（尾部控件贴右）
    textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
    trailingButton.setContentHuggingPriority(.required, for: .horizontal)
    trailingLabel.setContentHuggingPriority(.required, for: .horizontal)

    avatarBoxWidth = avatarBox.widthAnchor.constraint(equalToConstant: 40)
    avatarBoxHeight = avatarBox.heightAnchor.constraint(equalToConstant: 40)
    avatarBoxWidth?.isActive = true
    avatarBoxHeight?.isActive = true

    NSLayoutConstraint.activate([
      avatarBox.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: margins.leading),
      avatarBox.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
      avatarBox.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 8),
      avatarBox.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -8),
      rowStack.leadingAnchor.constraint(equalTo: avatarBox.trailingAnchor, constant: 12),
      rowStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -margins.trailing),
      rowStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
      rowStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
    ])
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    // 复用即取消在途头像请求并清图（TiebaForumAvatarView 没暴露 cancel：空 URL 走同一条）。
    avatar?.configure(url: "", initial: "")
  }

  func apply(_ row: TiebaFormRow, context: TiebaFormCellContext) {
    onPress = context.onRowPress
    avatarSize = CGFloat(row.avatarSize)
    avatarBoxWidth?.constant = avatarSize
    avatarBoxHeight?.constant = avatarSize

    titleLabel.text = row.title
    titleLabel.isHidden = row.title.isEmpty
    subtitleLabel.text = row.subtitle
    subtitleLabel.isHidden = row.subtitle?.isEmpty ?? true
    // 只有头像 + 尾部控件（编辑资料的头像块）：文本列整列移除，尾部按钮紧贴头像
    // （原 RN 布局 avatarActions 是 flex:1 + alignItems:flex-start）。
    textStack.isHidden = row.title.isEmpty && (row.subtitle?.isEmpty ?? true)

    avatarView(size: avatarSize).configure(url: row.avatarURL ?? "", initial: row.initials ?? "")

    // 尾部形态
    switch row.trailingStyle {
    case "button", "filledButton":
      trailingButton.isHidden = false
      trailingLabel.isHidden = true
      var config: UIButton.Configuration = row.trailingStyle == "filledButton"
        ? .filled()
        : .plain()
      config.title = row.trailingTitle
      config.image = TiebaFormSymbol.image(row.trailingIcon, pointSize: 16, weight: .medium)
      config.imagePadding = row.trailingTitle?.isEmpty == false ? 6 : 0
      config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
      if row.trailingStyle == "filledButton" {
        // 原 UIButton variant="filled"：实心主色 + 白字（主色由调用方给）。
        let background = row.trailingColor ?? context.tint
        config.baseBackgroundColor = background
        config.baseForegroundColor = .white
        config.cornerStyle = .medium
      }
      trailingButton.configuration = config
      if row.trailingStyle == "button" {
        trailingButton.tintColor = row.trailingColor ?? context.tint
      }
      trailingButton.isEnabled = !row.disabled && !row.trailingDisabled
    case "text":
      trailingButton.isHidden = true
      trailingLabel.isHidden = false
      trailingLabel.text = row.trailingTitle
      trailingLabel.textColor = row.trailingColor ?? .tertiaryLabel
    default:
      trailingButton.isHidden = true
      trailingLabel.isHidden = true
    }
    // busy 转圈：原「更换头像」在上传中显示按钮右侧的 ProgressView（按钮文案由 JS
    // 换成「上传中…」并 disabled），这里保持同一形态。
    if row.trailingBusy {
      spinner.isHidden = false
      spinner.startAnimating()
    } else {
      spinner.stopAnimating()
      spinner.isHidden = true
    }
  }

  /// 尺寸变了才重建（头像的尺寸是 init 常量；同一页内尺寸恒定，等于只建一次）。
  private func avatarView(size: CGFloat) -> TiebaForumAvatarView {
    if let avatar, builtAvatarSize == size { return avatar }
    avatar?.removeFromSuperview()
    let view = TiebaForumAvatarView(size: size)
    view.translatesAutoresizingMaskIntoConstraints = false
    avatarBox.addSubview(view)
    NSLayoutConstraint.activate([
      view.centerXAnchor.constraint(equalTo: avatarBox.centerXAnchor),
      view.centerYAnchor.constraint(equalTo: avatarBox.centerYAnchor),
    ])
    avatar = view
    builtAvatarSize = size
    return view
  }

  @objc private func trailingPressed() {
    TiebaSceneHaptics.fire("press")
    onPress?()
  }
}

// MARK: - 系统按钮行（prominentButton）

/// Form 内的系统按钮（整行宽）：UIButton.Configuration 的玻璃配置
/// （glassButtonConfiguration / prominentGlassButtonConfiguration，iOS 26 起可用）
/// 与 plain；JS 的 borderedProminent/bordered/glass/plain 逐名对位。
final class TiebaFormActionCell: TiebaFormBaseCell {
  static let reuseID = "TiebaFormActionCell"

  private let button = UIButton(type: .system)
  private var onPress: (() -> Void)?

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    let margins = Self.rowMargins
    button.translatesAutoresizingMaskIntoConstraints = false
    button.addTarget(self, action: #selector(buttonPressed), for: .touchUpInside)
    contentView.addSubview(button)
    NSLayoutConstraint.activate([
      button.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: margins.leading),
      button.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -margins.trailing),
      button.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
      button.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
    ])
  }

  func apply(_ row: TiebaFormRow, context: TiebaFormCellContext) {
    onPress = context.onRowPress
    var config: UIButton.Configuration
    switch row.buttonStyle {
    case "bordered":
      config = .glass()
    case "plain":
      config = .plain()
    default:
      // borderedProminent / glass 都落系统玻璃主按钮（部署目标 26 恒可用）。
      config = .prominentGlass()
    }
    config.title = row.title
    config.image = TiebaFormSymbol.image(row.icon, pointSize: 17, weight: .regular)
    config.imagePadding = row.icon == nil ? 0 : 6
    config.buttonSize = row.buttonLarge ? .large : .medium
    config.cornerStyle = row.buttonCapsule ? .capsule : .dynamic
    if let color = row.override ?? (context.explicitTint ? context.tint : nil) {
      switch row.buttonStyle {
      case "bordered", "plain":
        config.baseForegroundColor = color
      default:
        config.baseBackgroundColor = color
      }
    }
    button.configuration = config
    button.isEnabled = !row.disabled
  }

  @objc private func buttonPressed() {
    TiebaSceneHaptics.fire("press")
    onPress?()
  }
}

// MARK: - 进度条行（progress）

/// 线性进度（SwiftUI `ProgressView(value:)` 的 linear 形态）：系统 UIProgressView。
final class TiebaFormProgressCell: TiebaFormBaseCell {
  static let reuseID = "TiebaFormProgressCell"

  private let bar = UIProgressView(progressViewStyle: .default)

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    let margins = Self.rowMargins
    bar.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(bar)
    NSLayoutConstraint.activate([
      bar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: margins.leading),
      bar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -margins.trailing),
      bar.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
      bar.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 8),
    ])
  }

  func apply(_ row: TiebaFormRow, context: TiebaFormCellContext) {
    let value = Float(min(max(row.progress, 0), 1))
    bar.setProgress(value, animated: true)
    bar.progressTintColor = row.override ?? context.tint
  }
}

// MARK: - 状态行（status）

/// 「图标 + 数值」簇行：oksign 的签到统计（✔ 12 ✖ 3 +经验）与逐吧进度
/// （吧名 …… ✔ +3 / 转圈 / 等待中）。左标题、右簇（HStack + Spacer 的原形态）。
/// 子视图在 init 建好（簇用多少建多少并留池复用），apply 只改值——签到进度每次
/// 刷新都走 apply，重建整行子视图/图片是滚动与进度期的纯浪费。
final class TiebaFormStatusCell: TiebaFormBaseCell {
  static let reuseID = "TiebaFormStatusCell"

  private let titleLabel = UILabel()
  private let trailingLabel = UILabel()
  private let spinner = UIActivityIndicatorView(style: .medium)
  private let rowStack = UIStackView()
  private let itemsStack = UIStackView()
  private let filler = UIView()
  /// 「图标 + 数值」对（按需增长，之后只改值）
  private var itemViews: [(icon: UIImageView, label: UILabel)] = []

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    let margins = Self.rowMargins
    titleLabel.font = .preferredFont(forTextStyle: .body)
    titleLabel.adjustsFontForContentSizeCategory = true
    titleLabel.textColor = .label
    titleLabel.numberOfLines = 0
    trailingLabel.font = .preferredFont(forTextStyle: .body)
    trailingLabel.adjustsFontForContentSizeCategory = true
    trailingLabel.textColor = .secondaryLabel
    trailingLabel.numberOfLines = 1
    itemsStack.axis = .horizontal
    itemsStack.alignment = .center
    itemsStack.spacing = 8
    // 簇不吸余量：余量只由标题（有标题时）或 filler（无标题时）吃掉。
    itemsStack.setContentHuggingPriority(.required, for: .horizontal)
    filler.setContentHuggingPriority(.defaultLow, for: .horizontal)
    rowStack.axis = .horizontal
    rowStack.alignment = .center
    rowStack.spacing = 8
    rowStack.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(rowStack)
    // 旧布局是 HStack[Text?, Spacer?, 簇/状态]：
    //   - 有标题（逐吧进度行）：标题在左、状态贴右 → 标题低 hugging 吃掉余量；
    //   - 无标题（签到统计）：整簇贴左 → 尾部加一个弹性占位吃掉余量。
    rowStack.addArrangedSubview(titleLabel)
    rowStack.addArrangedSubview(itemsStack)
    rowStack.addArrangedSubview(trailingLabel)
    rowStack.addArrangedSubview(filler)
    rowStack.addArrangedSubview(spinner)
    titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
    trailingLabel.setContentHuggingPriority(.required, for: .horizontal)
    NSLayoutConstraint.activate([
      rowStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: margins.leading),
      rowStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -margins.trailing),
      rowStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
      rowStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
    ])
  }

  func apply(_ row: TiebaFormRow, context: TiebaFormCellContext) {
    let hasTitle = !row.title.isEmpty
    titleLabel.isHidden = !hasTitle
    if hasTitle {
      titleLabel.text = row.title
      titleLabel.font = .systemFont(
        ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize,
        weight: row.resolvedTitleWeight
      )
    }
    while itemViews.count < row.statusItems.count { itemViews.append(makeItemPair()) }
    for (index, pair) in itemViews.enumerated() {
      let item = index < row.statusItems.count ? row.statusItems[index] : nil
      pair.icon.isHidden = item == nil
      pair.label.isHidden = item == nil
      guard let item else { continue }
      pair.icon.image = TiebaFormSymbol.image(item.icon, pointSize: 15, weight: .regular)
      pair.icon.tintColor = item.color ?? context.tint
      pair.label.text = item.text
      pair.label.font = .systemFont(
        ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize,
        weight: Self.weight(item.weight)
      )
      pair.label.textColor = item.color ?? .label
    }
    trailingLabel.text = row.trailingText
    trailingLabel.textColor = row.trailingTextColor ?? .secondaryLabel
    trailingLabel.isHidden = row.trailingText?.isEmpty != false
    filler.isHidden = hasTitle
    if row.showsSpinner {
      spinner.isHidden = false
      spinner.startAnimating()
    } else {
      spinner.stopAnimating()
      spinner.isHidden = true
    }
  }

  private func makeItemPair() -> (icon: UIImageView, label: UILabel) {
    let icon = UIImageView()
    icon.setContentHuggingPriority(.required, for: .horizontal)
    let label = UILabel()
    label.setContentHuggingPriority(.required, for: .horizontal)
    itemsStack.addArrangedSubview(icon)
    itemsStack.addArrangedSubview(label)
    return (icon, label)
  }

  private static func weight(_ raw: String) -> UIFont.Weight {
    switch raw {
    case "semibold": return .semibold
    case "bold": return .bold
    case "medium": return .medium
    default: return .regular
    }
  }
}

// MARK: - 转圈行（spinner）

/// 加载行：系统 UIActivityIndicatorView（edit-profile 的资料加载 / 保存中占位）。
final class TiebaFormSpinnerCell: TiebaFormBaseCell {
  static let reuseID = "TiebaFormSpinnerCell"

  private let spinner = UIActivityIndicatorView(style: .medium)

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    spinner.translatesAutoresizingMaskIntoConstraints = false
    spinner.hidesWhenStopped = false
    contentView.addSubview(spinner)
    NSLayoutConstraint.activate([
      spinner.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
      spinner.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
      spinner.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 12),
      contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
    ])
  }

  func apply(_ row: TiebaFormRow, context: TiebaFormCellContext) {
    spinner.color = row.override ?? context.tint
    spinner.startAnimating()
  }
}

// MARK: - 时间行（datePicker）

/// DatePicker(displayedComponents: hourAndMinute)：UIDatePicker 的 `.compact` +
/// `.time` 形态（SwiftUI 的 compact 日期选择器底层就是它，点开是系统时间选择浮层）。
/// 值以 "HH:mm" 上报（与原 Date 的 getHours/getMinutes 同语义）。
final class TiebaFormDateCell: TiebaFormBaseCell {
  static let reuseID = "TiebaFormDateCell"

  private let titleLabel = UILabel()
  private let picker = UIDatePicker()
  private var onPick: ((String) -> Void)?
  private var reported = ""

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    let margins = Self.rowMargins
    titleLabel.font = .preferredFont(forTextStyle: .body)
    titleLabel.adjustsFontForContentSizeCategory = true
    titleLabel.textColor = .label
    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    picker.preferredDatePickerStyle = .compact
    picker.datePickerMode = .time
    picker.minuteInterval = 1
    picker.addTarget(self, action: #selector(dateChanged), for: .valueChanged)
    picker.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(titleLabel)
    contentView.addSubview(picker)
    NSLayoutConstraint.activate([
      titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: margins.leading),
      titleLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
      picker.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -margins.trailing),
      picker.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
      picker.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),
      picker.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
      picker.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
    ])
  }

  func apply(_ row: TiebaFormRow, context: TiebaFormCellContext) {
    onPick = context.onPick
    titleLabel.text = row.title
    titleLabel.isHidden = row.title.isEmpty
    picker.isEnabled = !row.disabled
    let value = row.value ?? ""
    if value != reported {
      reported = value
      picker.date = Self.date(from: value)
    }
  }

  @objc private func dateChanged() {
    TiebaSceneHaptics.fire("toggle")
    let formatter = Self.formatter
    let next = formatter.string(from: picker.date)
    reported = next
    onPick?(next)
  }

  /// "HH:mm" → 今天的该时刻（缺省 08:00，与旧 parseTimeToDate 的兜底一致）。
  private static func date(from value: String) -> Date {
    let parts = value.split(separator: ":").compactMap { Int($0) }
    let hour = parts.count == 2 ? parts[0] : 8
    let minute = parts.count == 2 ? parts[1] : 0
    var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
    components.hour = hour
    components.minute = minute
    components.second = 0
    return Calendar.current.date(from: components) ?? Date()
  }

  private static let formatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "HH:mm"
    return formatter
  }()
}

// MARK: - 空态行（empty）

/// 区块内空态：系统的 UIContentUnavailableView（排版/字号/次级色全由系统给，
/// 与迁移前 SwiftUI 的 ContentUnavailableView 同源）。视图 init 建好，apply 只换配置。
final class TiebaFormEmptyCell: TiebaFormBaseCell {
  static let reuseID = "TiebaFormEmptyCell"

  private let content = UIView()
  private let emptyView = UIContentUnavailableView(configuration: .empty())

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    content.translatesAutoresizingMaskIntoConstraints = false
    emptyView.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(content)
    content.addSubview(emptyView)
    NSLayoutConstraint.activate([
      content.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
      content.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
      content.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
      content.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
      content.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
      emptyView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      emptyView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      emptyView.topAnchor.constraint(equalTo: content.topAnchor),
      emptyView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
    ])
  }

  func apply(_ row: TiebaFormRow, context: TiebaFormCellContext) {
    var config = UIContentUnavailableConfiguration.empty()
    config.image = TiebaFormSymbol.image(row.icon ?? "tray", pointSize: 26, weight: .regular)
    config.text = row.title
    config.secondaryText = row.subtitle
    emptyView.configuration = config
  }
}
