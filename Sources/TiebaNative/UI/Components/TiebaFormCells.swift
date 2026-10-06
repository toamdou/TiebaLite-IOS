// TiebaFormCells —— 表单行 cell 家族
//
// 由 TiebaFormListView.swift 拆出（单文件 >1000 行 → 拆分，逐字搬运，未改一行逻辑）。
// 拆分纪律见 docs/uikit-migration/35-铁律-自检配方.md §4。

import UIKit

final class TiebaFormRowCell: UITableViewCell {
  static let reuseID = "TiebaFormRowCell"

  /// 系统表单行的最小行高（与 SwiftUI List 行一致；系统对分组行也是 44 起）。
  static let minimumHeight: CGFloat = 44

  /// (symbol|色) → 合成图。主 actor 隔离（cell 只在主线程配置），滚动时不重绘。
  /// 行首色块位图缓存。fileprivate：同文件的 TiebaFormListView 在外观档变化时要作废它
  ///（缓存键含解析后的色值，trait 翻转后旧键永不再命中）。
  /// 放宽为 internal：拆分后 TiebaFormListView（另一文件）在外观档变化时要作废它——
  /// 这是本类型唯一被跨文件引用的成员，故只放宽这一处（35 号文档 §4 的纪律）。
  static var iconCache: [String: UIImage] = [:]

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
      config.secondaryTextProperties.font = TiebaSimpleText.uiFont(style: .body)
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

    case .slider:
      // 无级滑杆行：附件/形态全部由 TiebaFormSliderCell 自己实现（本 cell 不参与）。
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
    subtitleLabel.font = TiebaSimpleText.uiFont(style: .subheadline)
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
