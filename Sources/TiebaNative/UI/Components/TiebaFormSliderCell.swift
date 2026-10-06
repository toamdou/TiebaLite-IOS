// ============================================================
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
// ============================================================
import UIKit

final class TiebaFormSliderCell: TiebaFormBaseCell {
  static let reuseID = "TiebaFormSliderCell"

  private let titleLabel = UILabel()
  private let valueLabel = UILabel()
  private let slider = UISlider()
  private let previewBox = UIView()
  private let previewLabel = UILabel()

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
    let header = UIStackView(arrangedSubviews: [titleLabel, valueLabel])
    header.axis = .horizontal
    header.alignment = .firstBaseline
    header.spacing = 8

    slider.isContinuous = true
    slider.addTarget(self, action: #selector(sliderChanged), for: .valueChanged)

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
    if !slider.isTracking, let value = Double(row.value ?? "") {
      slider.value = Float(min(max(value, row.minValue), row.maxValue))
    }
    applyTypography()
    updateValueLabel()
    updatePreview()
  }

  /// 界面级字号：本行的标题/值/示例都跟着界面字号走。
  private func applyTypography() {
    let scale = TiebaTypography.uiScale()
    titleLabel.font = TiebaSimpleText.scaledFont(size: 17, weight: .regular, scale: scale)
    valueLabel.font = TiebaSimpleText.scaledFont(size: 15, weight: .medium, scale: scale)
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    onSlide = nil
    previewFont = nil
    previewLabel.text = nil
  }

  // MARK: - 交互

  @objc private func sliderChanged() {
    let value = quantized(Double(slider.value))
    updateValueLabel()
    updatePreview()
    onSlide?(value)
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
