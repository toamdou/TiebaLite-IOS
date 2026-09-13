// ============================================================
// TiebaUpdateDialogViewController —— 「检查更新」结果弹窗
//（原 src/components/settings/UpdateDialog.tsx，随关于页一起原生化）
//
// 形态：`.overFullScreen` + `.crossDissolve` + 半透明遮罩（rgba(0,0,0,0.35)），
// 卡片 = iOS 26 液态玻璃（UIGlassEffect；更早系统系统厚材质）+ 圆角 20（连续
// 曲率）+ 最大宽 420 / 最大高 78%——不再手绘不透明底与阴影。
//
// 内容与旧组件逐条同源（读数来自 TiebaUpdateService，即原 updateStore 的页面侧）：
//   title：checking → 正在检查更新… / error → 检查更新失败 / 无 release → 检查更新 /
//          hasUpdate → 发现新版本 v{version} / 否则 已是最新版本 v{currentVersion}
//   meta（done+release）：{最新|当前} v{x}[ · 发布于 yyyy-MM-dd]
//   meta（error）：error ?? 网络异常，请稍后重试
//   notes（done+notes）：AttributedString(markdown:) 属性文本，可滚动
//   按钮：done+release →「在浏览器中打开」（主色底/白字）+「关闭」；
//         其余只有「关闭」。
//
// ⚠️ 状态是**活的**：原弹窗订阅 zustand store，"检查中点两次"时它会从
// 「正在检查更新…」自动变成结果。这里同样订阅 TiebaUpdateService（addObserver），
// 在弹窗存续期间刷新内容。
// ============================================================
import UIKit

final class TiebaUpdateDialogViewController: UIViewController {
  private let service = TiebaUpdateService.shared

  private let card = UIVisualEffectView(effect: TiebaUpdateDialogViewController.cardEffect())
  private let stack = UIStackView()
  private let titleLabel = UILabel()
  private let metaLabel = UILabel()
  private let notesScroll = UIScrollView()
  private let notesLabel = UILabel()
  private let actionsRow = UIView()
  private let actionsStack = UIStackView()
  private let openReleaseButton = UIButton(type: .system)
  private let closeButton = UIButton(type: .system)

  private var observerToken: UUID?
  private var cardWidthConstraint: NSLayoutConstraint?
  /// 便签区高度的"内容高度"约束（750）：内容短时按内容撑、超长时被卡片上限压回可滚。
  private var notesHeightConstraint: NSLayoutConstraint?

  init() {
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .overFullScreen
    modalTransitionStyle = .crossDissolve
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    // 遮罩：rgba(0,0,0,0.35)，点遮罩不关闭（旧 Modal 同样没有 backdrop onPress）。
    view.backgroundColor = UIColor.black.withAlphaComponent(0.35)
    setUpCard()
    reload()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    // 与 zustand 订阅同义：弹窗存续期间跟着服务状态走。
    observerToken = service.addObserver { [weak self] in self?.reload() }
    reload()
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    if let observerToken {
      service.removeObserver(observerToken)
      self.observerToken = nil
    }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    // width: '100%', maxWidth: 420（backdrop padding 24）。
    cardWidthConstraint?.constant = min(420, view.bounds.width - 48)
  }

  // MARK: - 布局

  private func setUpCard() {
    // 卡片材质：iOS 26 液态玻璃；更早系统用系统厚材质（不手写不透明底/阴影）。
    card.layer.cornerRadius = 20
    card.layer.cornerCurve = .continuous
    card.clipsToBounds = true
    card.translatesAutoresizingMaskIntoConstraints = false

    stack.axis = .vertical
    stack.spacing = 10  // card gap: 10
    stack.alignment = .fill
    stack.translatesAutoresizingMaskIntoConstraints = false

    titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
    titleLabel.textColor = .label
    titleLabel.numberOfLines = 0

    metaLabel.numberOfLines = 0

    notesLabel.font = .systemFont(ofSize: 13)
    notesLabel.numberOfLines = 0
    notesLabel.translatesAutoresizingMaskIntoConstraints = false
    notesScroll.translatesAutoresizingMaskIntoConstraints = false
    notesScroll.addSubview(notesLabel)
    notesScroll.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 2, right: 0)  // notesContent paddingBottom: 2

    configure(button: openReleaseButton, title: "在浏览器中打开")
    configure(button: closeButton, title: "关闭")
    openReleaseButton.addTarget(self, action: #selector(openReleasePressed), for: .touchUpInside)
    closeButton.addTarget(self, action: #selector(closePressed), for: .touchUpInside)

    actionsStack.axis = .horizontal
    actionsStack.spacing = 10  // actions gap: 10
    actionsStack.alignment = .fill
    actionsStack.translatesAutoresizingMaskIntoConstraints = false
    actionsStack.addArrangedSubview(openReleaseButton)
    actionsStack.addArrangedSubview(closeButton)
    actionsRow.translatesAutoresizingMaskIntoConstraints = false
    actionsRow.addSubview(actionsStack)

    for subview in [titleLabel, metaLabel, notesScroll, actionsRow] {
      stack.addArrangedSubview(subview)
    }
    // 间距例外（原样式：notesScroll marginTop 2、actions marginTop 6）。
    stack.setCustomSpacing(12, after: metaLabel)
    stack.setCustomSpacing(16, after: notesScroll)

    card.contentView.addSubview(stack)
    view.addSubview(card)

    notesHeightConstraint = notesScroll.heightAnchor.constraint(equalTo: notesLabel.heightAnchor)
    notesHeightConstraint?.priority = .defaultHigh
    cardWidthConstraint = card.widthAnchor.constraint(equalToConstant: 320)

    NSLayoutConstraint.activate([
      card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      card.heightAnchor.constraint(lessThanOrEqualTo: view.heightAnchor, multiplier: 0.78),

      stack.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor, constant: 20),  // card padding 20
      stack.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor, constant: -20),
      stack.topAnchor.constraint(equalTo: card.contentView.topAnchor, constant: 20),
      stack.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor, constant: -20),

      notesLabel.leadingAnchor.constraint(equalTo: notesScroll.contentLayoutGuide.leadingAnchor),
      notesLabel.trailingAnchor.constraint(equalTo: notesScroll.contentLayoutGuide.trailingAnchor),
      notesLabel.topAnchor.constraint(equalTo: notesScroll.contentLayoutGuide.topAnchor),
      notesLabel.bottomAnchor.constraint(equalTo: notesScroll.contentLayoutGuide.bottomAnchor),
      notesLabel.widthAnchor.constraint(equalTo: notesScroll.frameLayoutGuide.widthAnchor),

      // 按钮行右对齐（原 actions: flexDirection row + justifyContent flex-end）。
      actionsStack.leadingAnchor.constraint(greaterThanOrEqualTo: actionsRow.leadingAnchor),
      actionsStack.trailingAnchor.constraint(equalTo: actionsRow.trailingAnchor),
      actionsStack.topAnchor.constraint(equalTo: actionsRow.topAnchor),
      actionsStack.bottomAnchor.constraint(equalTo: actionsRow.bottomAnchor),
    ])
    notesHeightConstraint?.isActive = true
    cardWidthConstraint?.isActive = true
  }

  /// 卡片材质：iOS 26 液态玻璃；更早系统用系统厚材质（同样是系统 API）。
  private static func cardEffect() -> UIVisualEffect {
    if #available(iOS 26.0, *) {
      return UIGlassEffect(style: .regular)
    }
    return UIBlurEffect(style: .systemThickMaterial)
  }

  /// 按钮形态：padding 16/9 + 胶囊圆角 + 14pt semibold（原 button/buttonText 样式）。
  /// 主色底/白字由刷新时按当前主题填（主题色不是常量）。
  private func configure(button: UIButton, title: String) {
    var config = UIButton.Configuration.plain()
    config.title = title
    config.background.cornerRadius = 0
    config.cornerStyle = .capsule  // RadiusStyle.capsule
    config.contentInsets = NSDirectionalEdgeInsets(top: 9, leading: 16, bottom: 9, trailing: 16)
    config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
      var outgoing = incoming
      outgoing.font = .systemFont(ofSize: 14, weight: .semibold)
      return outgoing
    }
    button.configuration = config
    button.setContentHuggingPriority(.required, for: .horizontal)
    button.setContentCompressionResistancePriority(.required, for: .horizontal)
  }

  // MARK: - 内容

  private func reload() {
    let status = service.status
    let release = service.release
    let hasUpdate = service.hasUpdate
    let currentVersion = service.currentVersion
    let theme = TiebaNavigator.shared.chromeTheme

    titleLabel.text = Self.dialogTitle(
      status: status,
      release: release,
      hasUpdate: hasUpdate,
      currentVersion: currentVersion
    )

    if status == .done, let release {
      let prefix = hasUpdate ? "最新 v\(release.version)" : "当前 v\(currentVersion)"
      let date = Self.formatDate(release.publishedAt)
      metaLabel.isHidden = false
      metaLabel.attributedText = Self.lineHeightAttributed(
        date.isEmpty ? prefix : "\(prefix) · 发布于 \(date)",
        font: .systemFont(ofSize: 13),
        lineHeight: 18,
        color: .secondaryLabel
      )
    } else if status == .error {
      metaLabel.isHidden = false
      metaLabel.attributedText = Self.lineHeightAttributed(
        service.error ?? "网络异常，请稍后重试",
        font: .systemFont(ofSize: 13),
        lineHeight: 18,
        color: .secondaryLabel
      )
    } else {
      metaLabel.isHidden = true
      metaLabel.attributedText = nil
    }

    let notes = (status == .done) ? (release?.notes ?? "") : ""
    if !notes.isEmpty {
      notesScroll.isHidden = false
      notesLabel.attributedText = Self.notesAttributed(notes)
    } else {
      notesScroll.isHidden = true
      notesLabel.attributedText = nil
    }

    openReleaseButton.isHidden = !(status == .done && release != nil)
    // 主色跟随应用内主题（原 colors.primary / colors.text / colors.background）。
    openReleaseButton.configuration?.baseForegroundColor = .white
    openReleaseButton.configuration?.background.backgroundColor = theme.tint
    closeButton.configuration?.baseForegroundColor = .label
    closeButton.configuration?.background.backgroundColor = theme.background
  }

  /// 原 UpdateDialog 的 title 计算（逐字）。
  static func dialogTitle(
    status: TiebaUpdateStatus,
    release: TiebaReleaseInfo?,
    hasUpdate: Bool,
    currentVersion: String
  ) -> String {
    if status == .checking { return "正在检查更新…" }
    if status == .error { return "检查更新失败" }
    guard let release else { return "检查更新" }
    return hasUpdate ? "发现新版本 v\(release.version)" : "已是最新版本 v\(currentVersion)"
  }

  // MARK: - 动作（两处都带 press 触觉，与旧组件的 HdrPressable 调用点一致）

  @objc private func openReleasePressed() {
    TiebaSceneHaptics.fire("press")
    guard let url = service.release?.url else { return }
    // 原组件：openLink(release.url, false) → 强制系统浏览器。
    TiebaLinkOpener.openExternal(url)
  }

  @objc private func closePressed() {
    TiebaSceneHaptics.fire("press")
    dismiss(animated: true)
  }

  // MARK: - 文本处理

  private static let releaseDateParser = ISO8601DateFormatter()
  private static let releaseDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }()

  /// 2026-09-01T14:13:52Z → 2026-09-01；不合规范回空串。
  static func formatDate(_ iso: String?) -> String {
    guard let iso, let date = releaseDateParser.date(from: iso) else { return "" }
    return releaseDateFormatter.string(from: date)
  }

  /// Release 说明（markdown）→ 属性文本：解析交给系统 AttributedString(markdown:)，
  /// 不再手写正则逐条"洗"符号；强调按 inlinePresentationIntent 映射字体，
  /// 列表项补回"· "前缀（UILabel 不渲染块级缩进）。
  private static func notesAttributed(_ markdown: String) -> NSAttributedString {
    let baseFont = UIFont.systemFont(ofSize: 13)
    let paragraph = NSMutableParagraphStyle()
    paragraph.minimumLineHeight = 19
    paragraph.maximumLineHeight = 19
    let baseAttributes: [NSAttributedString.Key: Any] = [
      .font: baseFont, .paragraphStyle: paragraph, .foregroundColor: UIColor.secondaryLabel,
    ]
    guard let parsed = try? AttributedString(markdown: markdown) else {
      // 解析失败极罕见（markdown 是本地字符串）：按原文展示，不做有损清洗。
      return NSAttributedString(string: markdown, attributes: baseAttributes)
    }
    let output = NSMutableAttributedString()
    for run in parsed.runs {
      var font = baseFont
      if let inline = run.inlinePresentationIntent {
        if inline.contains(.code) {
          font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        } else {
          var traits: UIFontDescriptor.SymbolicTraits = []
          if inline.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
          if inline.contains(.emphasized) { traits.insert(.traitItalic) }
          if let descriptor = baseFont.fontDescriptor.withSymbolicTraits(traits) {
            font = UIFont(descriptor: descriptor, size: 13)
          }
        }
      }
      var text = String(parsed[run.range].characters)
      // 列表项补回"· "前缀（UILabel 不渲染块级缩进；旧实现同样用"· "）。
      if let intent = run.presentationIntent,
        intent.components.contains(where: { component in
          if case .listItem = component.kind { return true }
          return false
        })
      {
        text = "· " + text
      }
      var attributes = baseAttributes
      attributes[.font] = font
      output.append(NSAttributedString(string: text, attributes: attributes))
    }
    return output
  }

  /// 行高对齐（原样式 lineHeight 18）：UILabel 没有 lineHeight，用段落样式给；
  /// 颜色也一并写进属性串（UILabel 对 attributedText 不保证回落 textColor）。
  private static func lineHeightAttributed(
    _ text: String,
    font: UIFont,
    lineHeight: CGFloat,
    color: UIColor
  ) -> NSAttributedString {
    let paragraph = NSMutableParagraphStyle()
    paragraph.minimumLineHeight = lineHeight
    paragraph.maximumLineHeight = lineHeight
    return NSAttributedString(
      string: text,
      attributes: [.font: font, .paragraphStyle: paragraph, .foregroundColor: color]
    )
  }
}
