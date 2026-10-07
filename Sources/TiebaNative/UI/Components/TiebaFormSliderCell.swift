// TiebaFormSliderCell —— 设置表单的**无级滑杆行**（kind = .slider）
//
// 为什么单独一种行：设置→个性化→阅读字号 要「操纵杆左右滑动无级调节」+
// 「实时文字示例」，而系统表单里没有"滑杆行"这个形态（UIListContentConfiguration
// 只有文字/值/图标槽）。本 cell 是纯 UIKit 三件套：UILabel（标题）+ UILabel（当前值）
// + UISlider（连续）+ 预览区（实时示例）。
//
// ── 纪律（与其余表单 cell 一致）──
//   · 受控：滑杆只**上报意图**（onSlide），落库与回推在页面层；页面写库成功后用
//     setValue(id:value:) 回推，本 cell 在 apply 里对齐（正在拖动时不对齐，
//     否则手指还被按着、值被顶回去，滑杆会"弹"）。
//   · 实时示例：示例字体由页面给的 previewFont(值) 现算——不读偏好、不等落库，
//     所以拖动过程中示例**逐帧**跟着变（用户要求"实时查看文字大小变化"）。
//   · 本行自身文字（标题/值/示例）走界面级字号（TiebaTypography.uiScale），
//     与表单其余行一致：界面字号一调，这一行也跟着调。
import UIKit

final class TiebaFormSliderCell: TiebaFormBaseCell {
  static let reuseID = "TiebaFormSliderCell"

  private let titleLabel = UILabel()
  private let valueLabel = UILabel()
  private let resetButton = UIButton(type: .system)
  private let slider = UISlider()
  private let previewBox = UIView()
  private let previewLabel = UILabel()

  /// 本行 id。**拖动期间它是"这一格归谁"的唯一凭据**（见 apply 的防串台分支）。
  private var rowID: String?
  /// 拖动进行中收到的"换一行"配置：等松手后再落（绝不中途改绑定）。
  private var deferredApply: (row: TiebaFormRow, context: TiebaFormCellContext)?
  /// 拖动开始/结束（列表层要等松手后再整表重排，见 TiebaFormListView.refreshTypography）。
  var onTrackingChanged: ((Bool) -> Void)?

  /// 重置档（row.defaultValue；nil = 这一行没有默认档，不显示重置按钮）。
  private var resetValue: Double?
  /// 是否正在被手指按着（列表层据此推迟 reloadData）。
  var isTrackingSlider: Bool { slider.isTracking }

  private var onSlide: ((Double) -> Void)?
  /// 实时示例字体：入参 = 滑杆当前值（pt），出参 = 示例要用的字体。
  /// 页面决定它是正文级还是界面级（cell 不认识字号体系）。
  private var previewFont: ((Double) -> UIFont)?
  private var minValue: Double = 0
  private var maxValue: Double = 1
  /// 量化步长（0 = 不量化）。量化只是为了让落盘值干净，不影响"无级"手感。
  private var step: Double = 0

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    setUp()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private func setUp() {
    titleLabel.numberOfLines = 1
    valueLabel.numberOfLines = 1
    valueLabel.textAlignment = .right
    valueLabel.setContentHuggingPriority(.required, for: .horizontal)
    valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
    resetButton.setTitle("重置", for: .normal)
    resetButton.setContentHuggingPriority(.required, for: .horizontal)
    resetButton.setContentCompressionResistancePriority(.required, for: .horizontal)
    resetButton.addTarget(self, action: #selector(resetTapped), for: .touchUpInside)
    resetButton.isHidden = true

    // 标题 + 数值走基线对齐（两行字号不同）；「重置」按钮单独一行栈里居中——
    // 按钮不参与基线对齐：UIButton 的 firstBaseline 在不同内容下会给出不同的
    // 基线高度，混进同一个 .firstBaseline 栈里容易把标题顶偏（改动前只有两个
    // UILabel，加按钮就必须分层，否则行高和文字位置都跟着按钮变）。
    let valueRow = UIStackView(arrangedSubviews: [titleLabel, valueLabel])
    valueRow.axis = .horizontal
    valueRow.alignment = .firstBaseline
    valueRow.spacing = 8
    let header = UIStackView(arrangedSubviews: [valueRow, resetButton])
    header.axis = .horizontal
    header.alignment = .center
    header.spacing = 8

    slider.isContinuous = true
    slider.addTarget(self, action: #selector(sliderChanged), for: .valueChanged)
    // 拖动起止：列表层据此把 reloadData 推迟到松手之后（否则被按住的这一格会被
    // 复用成另一行 —— 用户实测"拖着拖着变成拖动另一个"）。
    slider.addTarget(self, action: #selector(sliderTouchDown), for: .touchDown)
    slider.addTarget(
      self, action: #selector(sliderTouchUp),
      for: [.touchUpInside, .touchUpOutside, .touchCancel])

    previewBox.layer.cornerRadius = 10
    previewBox.layer.cornerCurve = .continuous
    previewBox.backgroundColor = .secondarySystemGroupedBackground
    previewLabel.numberOfLines = 0
    previewLabel.textAlignment = .natural
    previewLabel.translatesAutoresizingMaskIntoConstraints = false
    previewBox.addSubview(previewLabel)

    let stack = UIStackView(arrangedSubviews: [header, slider, previewBox])
    stack.axis = .vertical
    stack.spacing = 8
    stack.setCustomSpacing(4, after: header)
    stack.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(stack)
    let margins = Self.rowMargins
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: margins.leading),
      stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -margins.trailing),
      stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
      stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
      previewLabel.leadingAnchor.constraint(equalTo: previewBox.leadingAnchor, constant: 12),
      previewLabel.trailingAnchor.constraint(equalTo: previewBox.trailingAnchor, constant: -12),
      previewLabel.topAnchor.constraint(equalTo: previewBox.topAnchor, constant: 10),
      previewLabel.bottomAnchor.constraint(equalTo: previewBox.bottomAnchor, constant: -10),
    ])
  }

  // MARK: - 配置

  func apply(_ row: TiebaFormRow, context: TiebaFormCellContext) {
    // ⚠️ 手指还按着这一格时被要求换成**另一行**（reloadData 把本 cell 复用给了
    // 另一条滑杆行）：此刻若照单全收，后面每一格拖动事件都会打到另一行的字号上
    // ——用户实测"拖着一个，拖着拖着变成拖动另一个"。这里只记下来，松手后再落；
    // 拖动期间本行的绑定（id / onSlide / 示例字体）一律保持不变。
    if slider.isTracking, row.id != rowID {
      deferredApply = (row, context)
      return
    }
    rowID = row.id
    resetValue = row.defaultValue
    onSlide = context.onSlide
    previewFont = context.previewFont
    minValue = row.minValue
    maxValue = row.maxValue
    step = row.step
    titleLabel.text = row.title
    previewLabel.text = (row.previewText?.isEmpty == false) ? row.previewText : row.title
    slider.minimumValue = Float(row.minValue)
    slider.maximumValue = Float(row.maxValue)
    slider.isEnabled = !row.disabled
    slider.accessibilityLabel = row.title
    resetButton.isEnabled = !row.disabled
    resetButton.tintColor = context.tint
    if !slider.isTracking, let value = Double(row.value ?? "") {
      slider.value = Float(min(max(value, row.minValue), row.maxValue))
    }
    applyTypography()
    updateValueLabel()
    updatePreview()
    updateResetButton()
  }

  /// 界面级字号：本行的标题/值/示例都跟着界面字号走。
  private func applyTypography() {
    let scale = TiebaTypography.uiScale()
    titleLabel.font = TiebaSimpleText.scaledFont(size: 17, weight: .regular, scale: scale)
    valueLabel.font = TiebaSimpleText.scaledFont(size: 15, weight: .medium, scale: scale)
    resetButton.titleLabel?.font = TiebaSimpleText.scaledFont(size: 15, weight: .regular, scale: scale)
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    // 正在被按住的一格不许被清空：清了就是"拖动突然失灵"（比串台更难查）。
    // 它的绑定保持到松手，松手回调里会落 deferredApply。
    guard !slider.isTracking else { return }
    onSlide = nil
    previewFont = nil
    rowID = nil
    deferredApply = nil
    resetValue = nil
    previewLabel.text = nil
    resetButton.isHidden = true
  }

  // MARK: - 交互

  @objc private func sliderChanged() {
    let value = quantized(Double(slider.value))
    updateValueLabel()
    updatePreview()
    updateResetButton()
    onSlide?(value)
  }

  @objc private func sliderTouchDown() {
    onTrackingChanged?(true)
  }

  /// 松手（含滑出/被打断）：先把拖动期间被推迟的那份配置落上，再告诉列表层
  /// "现在可以整表重排了"（列表层会把之前推迟的 reloadData 补上）。
  @objc private func sliderTouchUp() {
    if let deferred = deferredApply {
      deferredApply = nil
      apply(deferred.row, context: deferred.context)
    }
    onTrackingChanged?(false)
  }

  /// 一键回到默认档（17pt）：滑杆跳到默认值、示例与数值标签立刻跟上，
  /// 并照常上报一次 onSlide（落库路径与拖动完全相同，页面不需要第二套逻辑）。
  @objc private func resetTapped() {
    guard let resetValue, slider.isEnabled else { return }
    let target = Float(min(max(resetValue, minValue), maxValue))
    guard abs(slider.value - target) > 0.001 else { return }
    slider.setValue(target, animated: true)
    updateValueLabel()
    updatePreview()
    updateResetButton()
    TiebaSceneHaptics.fire("press")
    onSlide?(quantized(Double(target)))
  }

  /// 值≠默认档时才显示「重置」（默认档上没有可重置的东西，不该留一颗永远无效的按钮）。
  private func updateResetButton() {
    guard let resetValue else {
      resetButton.isHidden = true
      return
    }
    resetButton.isHidden = abs(Double(slider.value) - resetValue) < 0.05
  }

  private func quantized(_ raw: Double) -> Double {
    guard step > 0 else { return raw }
    let stepped = ((raw - minValue) / step).rounded() * step + minValue
    return min(max(stepped, minValue), maxValue)
  }

  private func updateValueLabel() {
    valueLabel.text = String(format: "%.1f", Double(slider.value))
    valueLabel.textColor = slider.isEnabled ? .secondaryLabel : .tertiaryLabel
  }

  private func updatePreview() {
    // 示例字体现算：拖动中也不等落库（"实时查看文字大小变化"）。
    let value = Double(slider.value)
    previewLabel.font = previewFont?(value)
      ?? TiebaSimpleText.scaledFont(size: CGFloat(value), weight: .regular,
                                    scale: TiebaTypography.uiScale())
  }
}

// 行类型注册表（TiebaFormCellRegistry）要求实现 TiebaFormCellConfiguring。
extension TiebaFormSliderCell: TiebaFormCellConfiguring {}
