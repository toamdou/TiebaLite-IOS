// TiebaFormInputCells —— 输入/分段/头像/动作等 cell（表单 cell 家族第二片）
//
// 由 TiebaFormCells.swift 拆出（单文件 >1000 行 → 拆分，逐字搬运）。

import UIKit

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

    field.font = TiebaSimpleText.uiFont(style: .body)
    field.adjustsFontForContentSizeCategory = true
    field.textColor = .label
    field.borderStyle = .none
    field.returnKeyType = .done
    field.delegate = self
    field.addTarget(self, action: #selector(fieldChanged), for: .editingChanged)
    field.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(field)

    textView.font = TiebaSimpleText.uiFont(style: .body)
    textView.adjustsFontForContentSizeCategory = true
    textView.textColor = .label
    textView.backgroundColor = .clear
    textView.isScrollEnabled = false
    textView.textContainerInset = .zero
    textView.textContainer.lineFragmentPadding = 0
    textView.delegate = self
    textView.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(textView)

    placeholderLabel.font = TiebaSimpleText.uiFont(style: .body)
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

    titleLabel.font = TiebaSimpleText.uiFont(style: .body)
    titleLabel.adjustsFontForContentSizeCategory = true
    titleLabel.textColor = .label
    titleLabel.numberOfLines = 1
    subtitleLabel.font = TiebaSimpleText.uiFont(style: .footnote)
    subtitleLabel.adjustsFontForContentSizeCategory = true
    subtitleLabel.textColor = .secondaryLabel
    subtitleLabel.numberOfLines = 1

    textStack.axis = .vertical
    textStack.alignment = .leading
    textStack.spacing = 2
    textStack.addArrangedSubview(titleLabel)
    textStack.addArrangedSubview(subtitleLabel)

    trailingButton.titleLabel?.font = TiebaSimpleText.uiFont(style: .body)
    trailingButton.addTarget(self, action: #selector(trailingPressed), for: .touchUpInside)
    trailingLabel.font = TiebaSimpleText.uiFont(style: .footnote)
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

  override func prepareForReuse() {
    super.prepareForReuse()
    // 复用池里的进度条带上一行的残留值：apply 恒 animated:true，会从残留值插值到新值，
    // 用户看到一段与实际进度无关的补涨/回退（与 avatar 行的复位纪律对齐）。
    bar.setProgress(0, animated: false)
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
    titleLabel.font = TiebaSimpleText.uiFont(style: .body)
    titleLabel.adjustsFontForContentSizeCategory = true
    titleLabel.textColor = .label
    titleLabel.numberOfLines = 0
    trailingLabel.font = TiebaSimpleText.uiFont(style: .body)
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
      // 用本文件既有的 tiebaFormFont（Dynamic Type 档位 + trait 加字重）：把 preferredFont
      // 的 pointSize 包成静态 systemFont 会让 adjustsFontForContentSizeCategory 变成空操作。
      titleLabel.font = UIFont.tiebaFormFont(
        TiebaSimpleText.uiFont(style: .body), weight: row.resolvedTitleWeight)
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
      pair.label.font = UIFont.tiebaFormFont(
        TiebaSimpleText.uiFont(style: .subheadline), weight: Self.weight(item.weight))
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
    titleLabel.font = TiebaSimpleText.uiFont(style: .body)
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

  private static let formatter: DateFormatter = TiebaDateFormats.fixed("HH:mm")
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
