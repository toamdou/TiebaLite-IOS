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
        time: TiebaTimeText.label(ms: item.timestamp),
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
    // 定值 systemFont 不随 Dynamic Type：历史区会变成全屏唯一不缩放的区域（同屏空态
    // 文案用 preferredFont）。用 UIFontMetrics 按固定基准字号缩放。
    label.font = UIFontMetrics(forTextStyle: .headline).scaledFont(for: .systemFont(ofSize: 18, weight: .bold))
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
    container.font = UIFontMetrics(forTextStyle: .headline).scaledFont(for: .systemFont(ofSize: 18, weight: .bold))
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
      // [接线 UI/Context] 长按不再用药丸自己的 UILongPressGestureRecognizer（固定 0.4s + 硬切），
      // 改由 TiebaPillCloudView 包一层 TiebaContextControllerSourceView：那套手势把 0→1 的激活
      // 进度透出来给药丸做「绕内容中点缩放」，走满 1 才回调这里。观感 = 按住时药丸连续缩小，
      // 到点触发删除（同视图两套长按准入会互相抢手势，故旧识别器已删）。
      pill.onLongPress = { [weak self] in
        TiebaSceneHaptics.fire("long-press")
        self?.onDelete?(text)
      }
    }
    return pill
  }
}

// MARK: - 药丸

/// 单颗药丸（原 tagPill / historyPill：胶囊底 + 14/8 内边距 + 内容宽度上限）。
/// 内容宽度上限靠 `widthAnchor <= maxWidth` 表达，压缩尺寸量出来就是夹取后的宽度。
final class TiebaSearchPill: UIControl {
  /// 长按删除回调要拿回原文（占用 accessibilityValue 会污染朗读）。
  let keyword: String
  /// 长按（由外层 TiebaContextControllerSourceView 的手势驱动，走满激活进度才回调）。
  /// nil = 本药丸没有长按语义，外层容器会把手势关掉（建议药丸就是这一类）。
  var onLongPress: (() -> Void)?

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
    label.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .systemFont(ofSize: 14))
    label.adjustsFontForContentSizeCategory = true
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
      timeLabel.font = UIFontMetrics(forTextStyle: .caption2).scaledFont(for: .systemFont(ofSize: 10))
      timeLabel.adjustsFontForContentSizeCategory = true
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

  /// C2（报告 37）：按下**即时**、松开才走 0.2s 缓出（配方见 TiebaPhotoBrowserCircleButton）。
  /// 按下先 removeAnimation("opacity") —— 上一次松开的回弹还在跑时会把 alpha 拉回去，
  /// 表现就是"按了不变暗"；按压档位 0.6 保持本仓原值，只改时序。
  /// （报告 40 C2 的第二个落点原是列表段头按钮，该文件已被零调用方清理删除，这里重建。）
  override var isHighlighted: Bool {
    didSet {
      if isHighlighted {
        layer.removeAnimation(forKey: "opacity")
        alpha = 0.6
      } else {
        alpha = 1.0
        layer.animateAlpha(from: 0.6, to: 1.0, duration: TiebaAnimationDuration.tapFeedback)
      }
    }
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
///
/// [接线 UI/Context] 每颗药丸外面包一层 TiebaContextControllerSourceView：
/// 长按准入、0.12s 起手、0→1 激活进度、**绕内容中点**缩放全在那一层里，
/// 走满进度才回调 pill.onLongPress。没有长按语义的药丸（搜索建议）把手势直接关掉，
/// 行为与接线前一致（点一下即选中）。药丸本身仍是 UIControl，tap 不受影响
/// （手势 0.32s 才 .began，轻点在此之前就抬手了）。
final class TiebaPillCloudView: UIView {
  private let gap: CGFloat
  private var pills: [TiebaSearchPill] = []
  /// 与 pills 一一对应的长按宿主（见类型注释）。
  private var holders: [TiebaContextControllerSourceView] = []
  private var sizes: [CGSize] = []
  private var measuredHeight: CGFloat = 0
  /// 上次测量时的内容尺寸档：档位变化后 sizes 必须重测（标签字体已随档重缩放）。
  private var measuredCategory: UIContentSizeCategory?

  init(gap: CGFloat) {
    self.gap = gap
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func setPills(_ pills: [TiebaSearchPill]) {
    for holder in holders { holder.removeFromSuperview() }
    holders = []
    self.pills = pills
    sizes = pills.map { $0.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize) }
    measuredCategory = traitCollection.preferredContentSizeCategory
    for pill in pills {
      let holder = TiebaContextControllerSourceView(frame: .zero)
      holder.isGestureEnabled = pill.onLongPress != nil
      // 内容 = 药丸自身（容器与药丸同尺寸）：缩放的「内容中点」就是药丸中点。
      holder.targetViewForActivationProgress = pill
      holder.activated = { [weak pill] gesture, _ in
        guard let onLongPress = pill?.onLongPress else {
          // 没有长按语义：自己取消，进度带着回弹收回去（与容器默认行为一致）。
          gesture.cancel()
          return
        }
        onLongPress()
      }
      pill.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      pill.frame = holder.bounds
      holder.addSubview(pill)
      holders.append(holder)
      addSubview(holder)
    }
    measuredHeight = 0
    setNeedsLayout()
    invalidateIntrinsicContentSize()
  }

  override var intrinsicContentSize: CGSize {
    CGSize(width: UIView.noIntrinsicMetric, height: measuredHeight)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    // 字号档变了（药丸标签字体由 adjustsFontForContentSizeCategory 重缩放）：框尺寸要跟着
    // 重测，否则字号变大而药丸框不变、文字被裁。
    if measuredCategory != traitCollection.preferredContentSizeCategory {
      measuredCategory = traitCollection.preferredContentSizeCategory
      sizes = pills.map { $0.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize) }
    }
    let width = bounds.width
    guard width > 0, !pills.isEmpty else { return }
    var x: CGFloat = 0
    var y: CGFloat = 0
    var rowHeight: CGFloat = 0
    for index in pills.indices {
      let size = sizes[index]
      let w = min(size.width, width)
      if x > 0, x + w > width {
        x = 0
        y += rowHeight + gap
        rowHeight = 0
      }
      // 宿主与药丸同框：药丸靠 autoresizing 跟着宿主走（见 setPills）。
      holders[index].frame = CGRect(x: x, y: y, width: w, height: size.height)
      x += w + gap
      rowHeight = max(rowHeight, size.height)
    }
    if abs(y + rowHeight - measuredHeight) > 0.5 {
      measuredHeight = y + rowHeight
      invalidateIntrinsicContentSize()
    }
  }
}
