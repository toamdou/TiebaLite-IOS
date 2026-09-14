// ============================================================
// TiebaLite — 空/错状态与页内小件的共享实现
//
// 收敛本域此前逐字近似的多份实现：错误态 UIContentUnavailableConfiguration
//（三角 + 重试）8 份、TiebaStateContentView 三态 switch 2 份、空态占位行 4 份、
// 列表色板染色 7 份、统计列 3 份、头像+标题+按钮行 2 份。
//
// 调用方只给数据与回调；状态视图的按钮 id 恒为 "retry"（各页原约定未变）。
// ============================================================

import UIKit

// MARK: - 系统空/错状态（UIContentUnavailableConfiguration）

@MainActor
enum TiebaContentUnavailable {
  /// 错误态唯一入口：三角 + "加载失败" + 说明 + 重试。
  static func error(
    _ message: String,
    onRetry: @escaping () -> Void
  ) -> UIContentUnavailableConfiguration {
    var config = UIContentUnavailableConfiguration.empty()
    config.image = UIImage(systemName: "exclamationmark.triangle")
    config.text = "加载失败"
    config.secondaryText = message
    var button = UIButton.Configuration.borderedProminent()
    button.title = "重试"
    config.button = button
    config.buttonProperties.primaryAction = UIAction { _ in onRetry() }
    return config
  }

  /// 空态：图标 + 标题/说明 + 可选按钮（无按钮 = 纯说明，如吧规空态）。
  static func empty(
    image: String,
    text: String,
    secondaryText: String? = nil,
    buttonTitle: String? = nil,
    buttonImage: String? = nil,
    onButton: (() -> Void)? = nil
  ) -> UIContentUnavailableConfiguration {
    var config = UIContentUnavailableConfiguration.empty()
    config.image = UIImage(systemName: image)
    config.text = text
    config.secondaryText = secondaryText
    if let buttonTitle {
      var button = UIButton.Configuration.borderedProminent()
      button.title = buttonTitle
      if let buttonImage { button.image = UIImage(systemName: buttonImage) }
      config.button = button
      if let onButton {
        config.buttonProperties.primaryAction = UIAction { _ in onButton() }
      }
    }
    return config
  }
}

extension UIContentUnavailableView {
  /// 挂错误态（三角 + 重试）并显示自身。
  func showError(_ message: String, onRetry: @escaping () -> Void) {
    configuration = TiebaContentUnavailable.error(message, onRetry: onRetry)
    isHidden = false
  }

  /// 挂空态并显示自身（可选按钮）。
  func showEmpty(
    image: String,
    text: String,
    secondaryText: String? = nil,
    buttonTitle: String? = nil,
    buttonImage: String? = nil,
    onButton: (() -> Void)? = nil
  ) {
    configuration = TiebaContentUnavailable.empty(
      image: image,
      text: text,
      secondaryText: secondaryText,
      buttonTitle: buttonTitle,
      buttonImage: buttonImage,
      onButton: onButton
    )
    isHidden = false
  }
}

// MARK: - 列表状态视图三态（TiebaStateContentView）

/// 列表页三态：加载（转圈/骨架由视图的 skeletonVariant 决定）/ 空 / 错。
enum TiebaListStateKind {
  case loading
  case empty(image: String, title: String, subtitle: String, refresh: Bool)
  case error(String)
}

extension TiebaStateContentView {
  /// 三态统一应用（错误态与 UIContentUnavailable 版同形：三角 + 重试 id "retry"）。
  func applyListState(_ state: TiebaListStateKind) {
    switch state {
    case .loading:
      showsSpinner = true
      imageName = nil
      text = nil
      secondaryText = nil
      buttons = []
    case .empty(let image, let title, let subtitle, let refresh):
      showsSpinner = false
      imageName = image
      text = title
      secondaryText = subtitle
      buttons = refresh
        ? [TiebaStateButton(raw: ["id": "retry", "title": "刷新", "style": "borderedProminent", "capsule": true])]
        : []
    case .error(let message):
      showsSpinner = false
      imageName = "exclamationmark.triangle"
      text = "加载失败"
      secondaryText = message
      buttons = [
        TiebaStateButton(raw: ["id": "retry", "title": "重试", "style": "borderedProminent", "capsule": true])
      ]
    }
  }
}

// MARK: - 空态占位行（simple 行的 summary 变体）

enum TiebaEmptyPlaceholderRow {
  /// 空 tab 的占位行：列表头仍在、滚动不塌。
  static func make(
    a11y: String,
    icon: String,
    title: String,
    subtitle: String,
    marginH: Double = 10,
    marginV: Double = 4,
    colors: [String: Any]? = nil
  ) -> [String: Any] {
    var row: [String: Any] = [
      "variant": "summary",
      "a11y": a11y,
      "icon": icon,
      "iconSize": 20,
      "iconBox": 40,
      "iconBoxRadius": 12,
      "title": title,
      "titleSize": 16,
      "titleWeight": 600,
      "subtitle": subtitle,
      "subtitleSize": 13,
      "subtitleWeight": 400,
      "subtitleMarginTop": 2,
      "marginH": marginH,
      "marginV": marginV,
    ]
    if let colors { row["colors"] = colors }
    return row
  }
}

// MARK: - 列表色板染色

enum TiebaChromePalette {
  /// 列表色板 = 默认语义色 + 导航壳主色（primary/chip/onChip 三键，与底栏强调色一致）。
  static func listPalette() -> TiebaSimpleRowPalette {
    var palette = TiebaSimpleRowPalette.default
    let tint = TiebaNavigator.shared.chromeTheme.tint
    palette.base.primary = tint
    return palette
  }
}

// MARK: - 统计列（值 + 标签）

/// 统计列：竖排 = 值上标签下（页宽等分统计行）；横排 = 值左标签右（资料卡
/// 统计行）。点击由调用方接 target（默认不可交互）。
final class TiebaStatColumnView: UIControl {
  enum Axis {
    case vertical
    case horizontal
  }

  private let valueLabel = UILabel()
  private let labelLabel = UILabel()

  init(axis: Axis, valueFont: UIFont, labelFont: UIFont, spacing: CGFloat = 2) {
    super.init(frame: .zero)
    valueLabel.font = valueFont
    valueLabel.adjustsFontForContentSizeCategory = true
    labelLabel.font = labelFont
    labelLabel.adjustsFontForContentSizeCategory = true
    if axis == .vertical {
      valueLabel.textAlignment = .center
      labelLabel.textAlignment = .center
    }
    let stack = UIStackView(arrangedSubviews: [valueLabel, labelLabel])
    stack.axis = axis == .vertical ? .vertical : .horizontal
    stack.spacing = spacing
    stack.alignment = axis == .vertical ? .center : .firstBaseline
    stack.isUserInteractionEnabled = false
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(value: String, label: String, valueColor: UIColor, labelColor: UIColor) {
    valueLabel.text = value
    valueLabel.textColor = valueColor
    labelLabel.text = label
    labelLabel.textColor = labelColor
    isAccessibilityElement = true
    accessibilityLabel = "\(label) \(value)"
  }
}

/// 页宽等分统计行（N 列 + hairline 竖分隔）。列数随数据增删，数据更新只改文本。
final class TiebaStatColumnsRow: UIView {
  enum SeparatorStyle {
    /// 分隔线上下各内缩 inset（统计行自带留白）。
    case fill(inset: CGFloat)
    /// 固定高度。
    case fixed(height: CGFloat)
  }

  private let valueFont: UIFont
  private let labelFont: UIFont
  private let separatorStyle: SeparatorStyle
  private let stack = UIStackView()
  private var columns: [TiebaStatColumnView] = []
  private var separators: [UIView] = []

  init(valueFont: UIFont, labelFont: UIFont, separator: SeparatorStyle) {
    self.valueFont = valueFont
    self.labelFont = labelFont
    separatorStyle = separator
    super.init(frame: .zero)
    stack.axis = .horizontal
    stack.distribution = .fillEqually
    stack.alignment = .center
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// 更新各列（列数按数据增删）。
  func setColumns(values: [String], labels: [String], valueColor: UIColor, labelColor: UIColor) {
    while columns.count < values.count {
      let column = TiebaStatColumnView(axis: .vertical, valueFont: valueFont, labelFont: labelFont)
      stack.addArrangedSubview(column)
      columns.append(column)
    }
    while columns.count > values.count, let last = columns.popLast() {
      stack.removeArrangedSubview(last)
      last.removeFromSuperview()
    }
    rebuildSeparators()
    for (index, column) in columns.enumerated() {
      column.configure(
        value: values[index],
        label: labels[index],
        valueColor: valueColor,
        labelColor: labelColor
      )
    }
  }

  private func rebuildSeparators() {
    for separator in separators {
      separator.removeFromSuperview()
    }
    separators.removeAll()
    guard columns.count > 1 else { return }
    for index in 1..<columns.count {
      let divider = UIView()
      divider.backgroundColor = .separator
      divider.translatesAutoresizingMaskIntoConstraints = false
      addSubview(divider)
      var constraints = [
        divider.centerXAnchor.constraint(equalTo: columns[index].leadingAnchor),
        divider.centerYAnchor.constraint(equalTo: centerYAnchor),
        divider.widthAnchor.constraint(equalToConstant: 1 / max(traitCollection.displayScale, 1)),
      ]
      switch separatorStyle {
      case .fill(let inset):
        constraints.append(
          divider.heightAnchor.constraint(equalTo: heightAnchor, constant: -inset * 2)
        )
      case .fixed(let height):
        constraints.append(divider.heightAnchor.constraint(equalToConstant: height))
      }
      NSLayoutConstraint.activate(constraints)
      separators.append(divider)
    }
  }
}

// MARK: - 头像 + 标题列 + 按钮列（吧名片 / 用户资料卡的同一行几何）

/// 横向行：头像（定宽、垂直居中）+ 标题列（吸收剩余宽）+ 按钮列（贴右）。
/// 标题列/按钮列的内容由调用方装入（本视图只管行级几何）。
final class TiebaAvatarHeaderRow: UIView {
  let avatarView: TiebaForumAvatarView
  let titleColumn = UIStackView()
  let actionRow = UIStackView()

  init(
    avatarSize: CGFloat,
    avatarSpacing: CGFloat,
    columnSpacing: CGFloat,
    titleSpacing: CGFloat = 4
  ) {
    avatarView = TiebaForumAvatarView(size: avatarSize)
    super.init(frame: .zero)
    titleColumn.axis = .vertical
    // .fill 而不是 .leading：标题列宽度由外层行给，label 必须被压到该宽度才会
    // 截断（.leading 下按固有宽度溢出，会压到右侧按钮上）。
    titleColumn.alignment = .fill
    titleColumn.spacing = titleSpacing
    titleColumn.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    actionRow.axis = .horizontal
    actionRow.spacing = 6
    actionRow.alignment = .center
    actionRow.setContentHuggingPriority(.required, for: .horizontal)
    actionRow.setContentCompressionResistancePriority(.required, for: .horizontal)
    avatarView.setContentHuggingPriority(.required, for: .horizontal)
    avatarView.setContentCompressionResistancePriority(.required, for: .horizontal)

    let row = UIStackView(arrangedSubviews: [avatarView, titleColumn, actionRow])
    row.axis = .horizontal
    row.alignment = .center
    row.spacing = columnSpacing
    row.setCustomSpacing(avatarSpacing, after: avatarView)
    row.translatesAutoresizingMaskIntoConstraints = false
    addSubview(row)
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: leadingAnchor),
      row.trailingAnchor.constraint(equalTo: trailingAnchor),
      row.topAnchor.constraint(equalTo: topAnchor),
      row.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
