// ============================================================
// TiebaLite — 系统状态块（TiebaStateContentView）
//
// 纯 UIKit 视图，可被原生 UIViewController 直接使用
// 状态块（空态/加载/失败）的 UIKit 实现，原生页面直接使用。
//
// 替 @expo/ui 的三个系统状态组件（登录页 / 消息页 空态与加载态）：
//   ContentUnavailableView  → UIContentUnavailableConfiguration（系统空态排版：
//                             图标尺寸、标题/说明字号、行距、次级色全部由系统给）
//   ProgressView()          → UIActivityIndicatorView（系统转圈）
//   Button(borderedProminent/bordered/glassProminent) → UIButton.Configuration
//                            （iOS 26 起 SwiftUI 的 borderedProminent/bordered 本身
//                             就是液态玻璃按钮，UIKit 对位是 prominentGlass()/glass()，
//                             判据同 TiebaNotFoundViewController 与 TiebaFormActionCell）
//
// 布局（与迁移前的 VStack 结构逐条对应）：
//   [转圈]  ← spacing 12（loading 态的 ProgressView + Text 间距）
//   [状态块：图标 / 标题 / 说明]  ← UIContentUnavailableView
//   [按钮列] ← spacing 16（错误页 ContentUnavailableView 与按钮的 VStack 间距）
// 按钮 fullWidth（原 `frame({ maxWidth: 9999 })`）时铺满容器宽度；否则按内容宽度
// 居中（消息页未登录空态的原形态）。
// ============================================================

import UIKit

/// 状态块里的一个按钮。
struct TiebaStateButton {
  let id: String
  /// SwiftUI buttonStyle 名：borderedProminent / bordered / glassProminent / plain
  let style: String
  let title: String
  let icon: String?
  let color: UIColor?
  let capsule: Bool
  let fullWidth: Bool
  let disabled: Bool
  /// controlSize large（原登录页两个按钮）
  let large: Bool

  /// 无 JSON 边界可失败：调用点全是本仓的字面量，缺 id/title 即构造错了。
  /// （历史上这里是 `init?`，逼得 12 处调用点写 `!`。）用 precondition 大声失败，
  /// 不做静默兜底。
  init(raw: [String: Any]) {
    let id = raw["id"] as? String ?? ""
    let title = raw["title"] as? String ?? ""
    precondition(!id.isEmpty && !title.isEmpty, "TiebaStateButton 缺 id/title：\(raw)")
    self.id = id
    self.title = title
    self.style = raw["style"] as? String ?? "borderedProminent"
    self.icon = raw["icon"] as? String
    // 颜色解析统一走全仓 canonical 实现（#RRGGBB / #RRGGBBAA / rgb()/rgba()）。
    self.color = (raw["color"] as? String).flatMap(tiebaColor(from:))
    self.capsule = raw["capsule"] as? Bool ?? false
    self.fullWidth = raw["fullWidth"] as? Bool ?? false
    self.disabled = raw["disabled"] as? Bool ?? false
    self.large = raw["large"] as? Bool ?? false
  }
}

/// 状态块的类型化状态：装配（图标/文案/按钮）集中在本文件，各列表页只声明状态，
/// 不再各自 switch 拼同样的视图。自定义态保留全量字段出口。
enum TiebaState {
  case loading
  /// 空态；retryTitle 非空 = 追加标准「刷新」按钮（id = "retry"）。
  case empty(image: String, text: String, secondary: String? = nil, retryTitle: String? = nil)
  case error(message: String, image: String = "wifi.exclamationmark", retryTitle: String = "重试")
  /// 未登录引导（图标与登录按钮固定，两处登录空态逐字相同）。
  case login(text: String, secondary: String)
  case custom(image: String?, text: String?, secondary: String?, buttons: [TiebaStateButton])
}

final class TiebaStateContentView: UIView {
  // MARK: - 数据（整份替换 → 重画；视图不做业务判断）

  /// 类型化状态（写入即装配整套视图）；nil = 调用方仍走逐属性 API。
  var state: TiebaState? {
    didSet {
      guard let state else { return }
      apply(state)
    }
  }

  var imageName: String? { didSet { rebuild() } }
  var imageColor: UIColor? { didSet { rebuild() } }
  /// 图标最大边长（pt）。nil = 系统空态默认尺寸。
  var imageSize: CGFloat? { didSet { rebuild() } }
  var text: String? { didSet { rebuild() } }
  /// 标题字号档：title3 / headline / body / subheadline / footnote / caption（默认 headline，即系统空态默认）
  var textStyle: String? { didSet { rebuild() } }
  var textWeight: String? { didSet { rebuild() } }
  var textColor: UIColor? { didSet { rebuild() } }
  var secondaryText: String? { didSet { rebuild() } }
  var secondaryStyle: String? { didSet { rebuild() } }
  var secondaryColor: UIColor? { didSet { rebuild() } }
  /// 顶部转圈（原 ProgressView）
  var showsSpinner: Bool = false { didSet { rebuild() } }
  var spinnerColor: UIColor? { didSet { rebuild() } }
  /// 按钮列（原 Button 们）
  var buttons: [TiebaStateButton] = [] { didSet { rebuildButtons() } }

  /// 加载骨架（Skeleton.tsx 原生重建）：置变体后 loading 态（showsSpinner）
  /// 显示同形骨架；空态/错误态/登录态（showsSpinner = false）不受影响。
  var skeletonVariant: TiebaSkeletonVariant? { didSet { rebuild() } }
  /// 骨架单元数量（默认 8，同 JS SkeletonList）。
  var skeletonCount: Int = 8 {
    didSet {
      guard skeletonCount != oldValue else { return }
      skeletonView.count = skeletonCount
    }
  }
  /// 骨架列表内边距（对应 JS 各页 SkeletonList 的 style padding）。
  var skeletonInsets: UIEdgeInsets = .zero {
    didSet { skeletonView.contentInsets = skeletonInsets }
  }

  /// 应用内深浅（宿主 trait 只跟系统，深色必须显式下发）
  var isDark: Bool = false {
    didSet {
      guard isDark != oldValue else { return }
      overrideUserInterfaceStyle = isDark ? .dark : .light
      skeletonView.isDark = isDark
    }
  }

  override var isHidden: Bool {
    didSet { skeletonView.isSuspended = isHidden }
  }

  /// 按钮按下：{ id }
  var onButtonPress: ((String) -> Void)?

  // MARK: - Private

  private let contentStack = UIStackView()
  private let spinner = UIActivityIndicatorView(style: .medium)
  private let stateContainer = UIView()
  private let buttonsStack = UIStackView()
  private var buttonsWidthConstraint: NSLayoutConstraint?
  private var buttonViews: [String: UIButton] = [:]
  private let stateView = UIContentUnavailableView(configuration: .empty())
  private let skeletonView = TiebaSkeletonList()

  override init(frame: CGRect) {
    super.init(frame: frame)
    setUp()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private func setUp() {
    contentStack.axis = .vertical
    contentStack.alignment = .center
    contentStack.spacing = 12   // loading 态 ProgressView 与文字的原 VStack 间距
    contentStack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(contentStack)

    stateView.translatesAutoresizingMaskIntoConstraints = false
    stateContainer.addSubview(stateView)

    spinner.hidesWhenStopped = true
    buttonsStack.axis = .vertical
    buttonsStack.alignment = .center
    buttonsStack.spacing = 16   // 错误页 ContentUnavailableView 与按钮的原 VStack 间距

    contentStack.addArrangedSubview(spinner)
    contentStack.addArrangedSubview(stateContainer)
    contentStack.addArrangedSubview(buttonsStack)

    // 骨架铺满容器（顶对齐；loading 态替代居中转圈）
    skeletonView.isHidden = true
    addSubview(skeletonView)

    NSLayoutConstraint.activate([
      contentStack.centerXAnchor.constraint(equalTo: centerXAnchor),
      contentStack.centerYAnchor.constraint(equalTo: centerYAnchor),
      contentStack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
      contentStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
      contentStack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
      contentStack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),

      // 状态块铺满容器宽度：SwiftUI 的 ContentUnavailableView 在 VStack(maxWidth:
      // 10000) 里同样占满可用宽度（内容自居中）。
      stateContainer.leadingAnchor.constraint(equalTo: contentStack.leadingAnchor),
      stateContainer.trailingAnchor.constraint(equalTo: contentStack.trailingAnchor),
      stateView.leadingAnchor.constraint(equalTo: stateContainer.leadingAnchor),
      stateView.trailingAnchor.constraint(equalTo: stateContainer.trailingAnchor),
      stateView.topAnchor.constraint(equalTo: stateContainer.topAnchor),
      stateView.bottomAnchor.constraint(equalTo: stateContainer.bottomAnchor),

      skeletonView.leadingAnchor.constraint(equalTo: leadingAnchor),
      skeletonView.trailingAnchor.constraint(equalTo: trailingAnchor),
      skeletonView.topAnchor.constraint(equalTo: topAnchor),
      skeletonView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
    rebuild()
    rebuildButtons()
  }

  private func rebuild() {
    // 配置对象（SDK 的 Swift 接口按值语义导入）：改完属性再交给状态视图。
    var config = UIContentUnavailableConfiguration.empty()
    if let imageName, !imageName.isEmpty {
      config.image = UIImage(
        systemName: imageName,
        withConfiguration: UIImage.SymbolConfiguration(pointSize: imageSize ?? 48, weight: .regular)
      )
      config.imageProperties.tintColor = imageColor
      if let imageSize {
        config.imageProperties.maximumSize = CGSize(width: imageSize, height: imageSize)
      }
    }
    config.text = text
    if let style = textStyle {
      config.textProperties.font = Self.font(style: style, weight: textWeight ?? "regular")
    }
    if let textColor { config.textProperties.color = textColor }
    config.secondaryText = secondaryText
    if let style = secondaryStyle {
      config.secondaryTextProperties.font = Self.font(style: style, weight: "regular")
    }
    if let secondaryColor { config.secondaryTextProperties.color = secondaryColor }
    stateView.configuration = config
    spinner.color = spinnerColor
    // 骨架变体存在时 loading 态改用骨架（空/错/登录态 showsSpinner=false 不触发）
    let showSkeleton = showsSpinner && skeletonVariant != nil
    if let skeletonVariant { skeletonView.variant = skeletonVariant }
    skeletonView.isHidden = !showSkeleton
    skeletonView.isSuspended = isHidden || !showSkeleton
    contentStack.isHidden = showSkeleton
    if showsSpinner && !showSkeleton {
      spinner.startAnimating()
    } else {
      spinner.stopAnimating()
    }
    spinner.isHidden = !showsSpinner || showSkeleton
  }

  private func rebuildButtons() {
    for view in buttonsStack.arrangedSubviews {
      buttonsStack.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
    buttonViews.removeAll()
    buttonsWidthConstraint?.isActive = false
    buttonsWidthConstraint = nil

    for item in buttons {
      let button = UIButton(type: .system)
      button.configuration = Self.configuration(for: item)
      button.isEnabled = !item.disabled
      button.addAction(UIAction { [weak self] _ in
        TiebaSceneHaptics.fire("press")
        self?.onButtonPress?(item.id)
      }, for: .touchUpInside)
      buttonViews[item.id] = button
      buttonsStack.addArrangedSubview(button)
      if item.fullWidth {
        button.widthAnchor.constraint(equalTo: buttonsStack.widthAnchor).isActive = true
      }
    }
    if buttons.contains(where: { $0.fullWidth }) {
      let width = buttonsStack.widthAnchor.constraint(equalTo: widthAnchor)
      width.isActive = true
      buttonsWidthConstraint = width
    }
  }

  // MARK: - 类型化状态装配

  private func apply(_ state: TiebaState) {
    switch state {
    case .loading:
      imageName = nil
      text = nil
      secondaryText = nil
      showsSpinner = true
      buttons = []
    case .empty(let image, let text, let secondary, let retryTitle):
      showsSpinner = false
      imageName = image
      self.text = text
      secondaryText = secondary
      buttons = retryTitle.map { [Self.retryButton(title: $0)] } ?? []
    case .error(let message, let image, let retryTitle):
      showsSpinner = false
      imageName = image
      text = "加载失败"
      secondaryText = message
      buttons = [Self.retryButton(title: retryTitle)]
    case .login(let text, let secondary):
      showsSpinner = false
      imageName = "person.crop.circle.badge.questionmark"
      self.text = text
      secondaryText = secondary
      buttons = [
        TiebaStateButton(raw: [
          "id": "login",
          "title": "登录百度账号",
          "style": "glassProminent",
          "icon": "person.crop.circle.badge.checkmark",
          "capsule": true,
        ])
      ]
    case .custom(let image, let text, let secondary, let buttons):
      showsSpinner = false
      imageName = image
      self.text = text
      secondaryText = secondary
      self.buttons = buttons
    }
  }

  /// 标准重试/刷新按钮（各页 error / empty 的同一形态）。
  static func retryButton(title: String) -> TiebaStateButton {
    TiebaStateButton(raw: ["id": "retry", "title": title, "style": "borderedProminent", "capsule": true])
  }

  /// 按钮配置：SwiftUI buttonStyle 名 → UIButton.Configuration（玻璃配置 = 系统
  /// glassButtonConfiguration/prominentGlassButtonConfiguration，部署目标 26 恒可用）。
  static func configuration(for item: TiebaStateButton) -> UIButton.Configuration {
    var config: UIButton.Configuration
    switch item.style {
    case "bordered":
      config = .glass()
    case "glassProminent":
      config = .prominentGlass()
    case "plain":
      config = .plain()
    default:
      config = .prominentGlass()
    }
    config.title = item.title
    config.image = item.icon.flatMap {
      UIImage(
        systemName: $0,
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)
      )
    }
    config.imagePadding = item.icon == nil ? 0 : 6
    config.buttonSize = item.large ? .large : .medium
    config.cornerStyle = item.capsule ? .capsule : .dynamic
    if let color = item.color {
      switch item.style {
      case "bordered", "plain":
        config.baseForegroundColor = color
      default:
        config.baseBackgroundColor = color
      }
    }
    return config
  }

  /// SwiftUI textStyle 名 → 动态字体（可叠加字重）。
  static func font(style: String, weight: String) -> UIFont {
    let textStyle: UIFont.TextStyle
    switch style {
    case "title3": textStyle = .title3
    case "headline": textStyle = .headline
    case "subheadline": textStyle = .subheadline
    case "footnote": textStyle = .footnote
    case "caption": textStyle = .caption1
    case "largeTitle": textStyle = .largeTitle
    case "title": textStyle = .title1
    default: textStyle = .body
    }
    let base = UIFont.preferredFont(forTextStyle: textStyle)
    let value: UIFont.Weight
    switch weight {
    case "medium": value = .medium
    case "semibold": value = .semibold
    case "bold": value = .bold
    default: value = .regular
    }
    guard value != .regular else { return base }
    let descriptor = base.fontDescriptor.addingAttributes([
      .traits: [UIFontDescriptor.TraitKey.weight: value],
    ])
    return UIFont(descriptor: descriptor, size: 0)
  }
}
