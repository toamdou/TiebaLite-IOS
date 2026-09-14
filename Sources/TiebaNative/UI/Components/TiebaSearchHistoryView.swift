// 搜索历史/建议区（原 src/components/search/SearchHistorySection.tsx）：全站搜索与
// 吧内搜索共用。建议与历史都是自动换行的药丸云（原 tagWrap 的 flexWrap），历史药丸
// 带相对时间；整块进竖向滚动区，头部「搜索历史 + chevron」整体可点切换展开。
import UIKit

final class TiebaSearchHistoryView: UIView {
  /// 可见历史条数（原 VISIBLE_HISTORY_COUNT）。
  private static let visibleHistoryCount = 6
  private static let sectionGap: CGFloat = 24
  private static let headerGap: CGFloat = 14
  private static let cloudGap: CGFloat = 10
  private static let suggestionMaxWidth: CGFloat = 200
  private static let historyMaxWidth: CGFloat = 220

  var onSelect: ((String) -> Void)?
  var onDelete: ((String) -> Void)?
  var onClear: (() -> Void)?
  var onToggleExpand: (() -> Void)?

  private let scroll = UIScrollView()
  private let content = UIStackView()
  private let palette = TiebaSimpleRowPalette.default
  private var expanded = false

  override init(frame: CGRect) {
    super.init(frame: frame)
    scroll.alwaysBounceVertical = true
    scroll.keyboardDismissMode = .onDrag
    scroll.translatesAutoresizingMaskIntoConstraints = false
    addSubview(scroll)
    content.axis = .vertical
    content.spacing = Self.sectionGap
    content.translatesAutoresizingMaskIntoConstraints = false
    scroll.addSubview(content)
    NSLayoutConstraint.activate([
      scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
      scroll.topAnchor.constraint(equalTo: topAnchor),
      scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
      content.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 16),
      content.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -16),
      // 搜索栏与历史区之间留呼吸（原 contentContainer paddingTop: 12）。
      content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 12),
      content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
      content.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -32),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(
    suggestions: [String],
    history: [TiebaSearchHistory.Item],
    expanded: Bool
  ) {
    self.expanded = expanded
    for view in content.arrangedSubviews {
      content.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
    if !suggestions.isEmpty {
      content.addArrangedSubview(suggestionSection(suggestions))
    }
    if history.isEmpty {
      content.addArrangedSubview(emptyState())
    } else {
      content.addArrangedSubview(historySection(history))
    }
  }

  // MARK: - 区块

  private func suggestionSection(_ suggestions: [String]) -> UIView {
    let cloud = TiebaPillCloudView(gap: Self.cloudGap)
    cloud.setPills(suggestions.map { text in
      makePill(text: text, time: "", maxWidth: Self.suggestionMaxWidth, deletable: false)
    })
    return section([sectionTitle("搜索建议"), cloud])
  }

  private func historySection(_ history: [TiebaSearchHistory.Item]) -> UIView {
    let visible = expanded ? history : Array(history.prefix(Self.visibleHistoryCount))
    let cloud = TiebaPillCloudView(gap: Self.cloudGap)
    cloud.setPills(visible.map { item in
      makePill(
        text: item.keyword,
        time: TiebaTimeLabel.label(millis: item.timestamp),
        maxWidth: Self.historyMaxWidth,
        deletable: true
      )
    })
    return section([historyHeader(count: history.count), cloud])
  }

  /// 区块 = 标题行 + 药丸云，间距 14（原 historyHeader marginBottom）。
  private func section(_ views: [UIView]) -> UIView {
    let stack = UIStackView(arrangedSubviews: views)
    stack.axis = .vertical
    stack.spacing = Self.headerGap
    return stack
  }

  private func sectionTitle(_ text: String) -> UILabel {
    let label = UILabel()
    label.text = text
    label.font = .systemFont(ofSize: 18, weight: .bold)
    label.textColor = palette.base.text
    return label
  }

  /// 标题行：[搜索历史 + chevron]占位[全部/收起][清空]（原 historyHeader）。
  private func historyHeader(count: Int) -> UIView {
    let row = UIStackView()
    row.axis = .horizontal
    row.alignment = .center
    row.spacing = 8
    row.addArrangedSubview(expandToggle())
    row.addArrangedSubview(UIView())
    if count > Self.visibleHistoryCount {
      row.addArrangedSubview(textButton(title: expanded ? "收起" : "全部") { [weak self] in
        guard let self else { return }
        TiebaSceneHaptics.fire("press")
        onToggleExpand?()
      })
    }
    row.addArrangedSubview(clearButton())
    return row
  }

  /// 标题与 chevron 同属一个按钮：整块可点切换展开（原 historyTitleRow）。
  private func expandToggle() -> UIButton {
    var container = AttributeContainer()
    container.font = UIFont.systemFont(ofSize: 18, weight: .bold)
    container.foregroundColor = palette.base.text
    var config = UIButton.Configuration.plain()
    config.contentInsets = .zero
    config.attributedTitle = AttributedString("搜索历史", attributes: container)
    config.image = UIImage(systemName: expanded ? "chevron.up" : "chevron.down")
    config.imagePlacement = .trailing
    config.imagePadding = 6
    config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 14)
    config.baseForegroundColor = palette.base.textTertiary
    let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in
      self?.onToggleExpand?()
    })
    button.accessibilityLabel = expanded ? "收起搜索历史" : "展开搜索历史"
    return button
  }

  private func textButton(title: String, action: @escaping () -> Void) -> UIButton {
    var config = UIButton.Configuration.plain()
    config.title = title
    config.buttonSize = .small
    config.baseForegroundColor = palette.base.textTertiary
    return UIButton(configuration: config, primaryAction: UIAction { _ in action() })
  }

  private func clearButton() -> UIButton {
    var config = UIButton.Configuration.plain()
    config.image = UIImage(
      systemName: "trash",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 16)
    )
    config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
    config.baseForegroundColor = palette.base.textTertiary
    // 触觉由页面在 clearHistory 里发（原 onClearHistory 内 hapticForScene('destructive')）。
    return UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in
      self?.onClear?()
    })
  }

  /// 无历史空态（原 emptyWrap：tray 40 + 文案，居顶 80）。
  private func emptyState() -> UIView {
    let icon = UIImageView(image: UIImage(systemName: "tray"))
    icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 40)
    icon.tintColor = palette.textDisabled
    icon.contentMode = .scaleAspectFit
    let label = UILabel()
    label.text = "搜索贴吧、帖子和用户"
    label.font = .preferredFont(forTextStyle: .subheadline)
    label.textColor = palette.base.textSecondary
    let column = UIStackView(arrangedSubviews: [icon, label])
    column.axis = .vertical
    column.alignment = .center
    column.spacing = 12
    let box = UIView()
    column.translatesAutoresizingMaskIntoConstraints = false
    box.addSubview(column)
    NSLayoutConstraint.activate([
      icon.heightAnchor.constraint(equalToConstant: 40),
      column.centerXAnchor.constraint(equalTo: box.centerXAnchor),
      column.topAnchor.constraint(equalTo: box.topAnchor, constant: 80),
      column.bottomAnchor.constraint(equalTo: box.bottomAnchor),
      column.leadingAnchor.constraint(greaterThanOrEqualTo: box.leadingAnchor),
      column.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor),
    ])
    return box
  }

  // MARK: - 药丸

  private func makePill(
    text: String,
    time: String,
    maxWidth: CGFloat,
    deletable: Bool
  ) -> TiebaSearchPill {
    let pill = TiebaSearchPill(text: text, time: time, maxWidth: maxWidth)
    pill.addAction(UIAction { [weak self] _ in
      TiebaSceneHaptics.fire("press")
      self?.onSelect?(text)
    }, for: .touchUpInside)
    if deletable {
      let longPress = UILongPressGestureRecognizer(
        target: self,
        action: #selector(handleLongPress(_:))
      )
      longPress.minimumPressDuration = 0.4
      pill.addGestureRecognizer(longPress)
    }
    return pill
  }

  @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
    guard gesture.state == .began, let pill = gesture.view as? TiebaSearchPill else { return }
    TiebaSceneHaptics.fire("long-press")
    onDelete?(pill.keyword)
  }
}

// MARK: - 药丸

/// 单颗药丸（原 tagPill / historyPill：胶囊底 + 14/8 内边距 + 内容宽度上限）。
/// 内容宽度上限靠 `widthAnchor <= maxWidth` 表达，压缩尺寸量出来就是夹取后的宽度。
final class TiebaSearchPill: UIControl {
  /// 长按删除回调要拿回原文（占用 accessibilityValue 会污染朗读）。
  let keyword: String

  private let palette = TiebaSimpleRowPalette.default
  private let label = UILabel()
  private let timeLabel = UILabel()

  init(text: String, time: String, maxWidth: CGFloat) {
    self.keyword = text
    super.init(frame: .zero)
    backgroundColor = palette.base.chip
    isAccessibilityElement = true
    accessibilityLabel = text
    accessibilityTraits = .button
    label.text = text
    label.font = .systemFont(ofSize: 14)
    label.textColor = palette.base.text
    label.numberOfLines = 1
    label.lineBreakMode = .byTruncatingTail
    // 收窄时截断关键词，时间标签保持完整（原 RN numberOfLines=1 + flexShrink 同序）。
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let row = UIStackView(arrangedSubviews: [label])
    row.axis = .horizontal
    row.alignment = .center
    row.spacing = 6
    row.isUserInteractionEnabled = false
    if !time.isEmpty {
      timeLabel.text = time
      timeLabel.font = .systemFont(ofSize: 10)
      timeLabel.textColor = palette.base.textTertiary
      timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
      row.addArrangedSubview(timeLabel)
    }
    row.translatesAutoresizingMaskIntoConstraints = false
    addSubview(row)
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
      row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
      row.topAnchor.constraint(equalTo: topAnchor, constant: 8),
      row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
      widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override var isHighlighted: Bool {
    didSet { alpha = isHighlighted ? 0.6 : 1 }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    // 胶囊圆角 = 半高（原 Radius.capsule：半尺寸时连续曲线与圆弧等价，不加 borderCurve）。
    layer.cornerRadius = bounds.height / 2
  }
}

// MARK: - 药丸云

/// 自动换行的药丸云（原 tagWrap：row + wrap + gap）。
/// 药丸压缩尺寸在 setPills 时量一次，布局期只做宽度夹取与按行摆放；高度经
/// intrinsicContentSize 上报给外层竖向栈。
final class TiebaPillCloudView: UIView {
  private let gap: CGFloat
  private var pills: [TiebaSearchPill] = []
  private var sizes: [CGSize] = []
  private var measuredHeight: CGFloat = 0

  init(gap: CGFloat) {
    self.gap = gap
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func setPills(_ pills: [TiebaSearchPill]) {
    for pill in self.pills { pill.removeFromSuperview() }
    self.pills = pills
    sizes = pills.map { $0.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize) }
    for pill in pills { addSubview(pill) }
    measuredHeight = 0
    setNeedsLayout()
    invalidateIntrinsicContentSize()
  }

  override var intrinsicContentSize: CGSize {
    CGSize(width: UIView.noIntrinsicMetric, height: measuredHeight)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let width = bounds.width
    guard width > 0, !pills.isEmpty else { return }
    var x: CGFloat = 0
    var y: CGFloat = 0
    var rowHeight: CGFloat = 0
    for (index, pill) in pills.enumerated() {
      let size = sizes[index]
      let w = min(size.width, width)
      if x > 0, x + w > width {
        x = 0
        y += rowHeight + gap
        rowHeight = 0
      }
      pill.frame = CGRect(x: x, y: y, width: w, height: size.height)
      x += w + gap
      rowHeight = max(rowHeight, size.height)
    }
    if abs(y + rowHeight - measuredHeight) > 0.5 {
      measuredHeight = y + rowHeight
      invalidateIntrinsicContentSize()
    }
  }
}
