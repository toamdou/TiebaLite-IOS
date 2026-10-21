import UIKit

/// 未登录关注页的紧凑欢迎区：纯 systemBackground、无大渐变广告。
/// 内容放在 UIScrollView 内，AX1–AX5 下可滚动，不会与功能说明/CTA 重叠。
final class TiebaHomeWelcomeView: UIView {
  var onLogin: (() -> Void)?
  var onExplore: (() -> Void)?

  private let scrollView = UIScrollView()
  private let content = UIStackView()
  private let brandRow = UIStackView()
  private let emblem = UIView()
  private let emblemLabel = UILabel()
  private let brandLabel = UILabel()
  private let titleLabel = UILabel()
  private let detailLabel = UILabel()
  private let actions = UIStackView()
  private let loginButton = UIButton(type: .system)
  private let exploreButton = UIButton(type: .system)
  private let features = UIStackView()
  private var featureTitleLabels: [UILabel] = []
  private var featureDetailLabels: [UILabel] = []
  private var iconViews: [UIImageView] = []
  private var styleRegistration: UITraitChangeRegistration?

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    build()
    applyTypography()
    applyColors()
    styleRegistration = registerForTraitChanges([
      UITraitPreferredContentSizeCategory.self,
      UITraitUserInterfaceStyle.self,
      UITraitAccessibilityContrast.self,
    ]) { (view: TiebaHomeWelcomeView, _: UITraitCollection) in
      view.applyTypography()
      view.applyColors()
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func build() {
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.alwaysBounceVertical = true
    scrollView.showsVerticalScrollIndicator = true
    scrollView.contentInsetAdjustmentBehavior = .never
    addSubview(scrollView)

    content.translatesAutoresizingMaskIntoConstraints = false
    content.axis = .vertical
    content.alignment = .fill
    content.spacing = 18
    scrollView.addSubview(content)

    NSLayoutConstraint.activate([
      scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: topAnchor),
      scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
      // 直接让 content 定义 scrollView 的 contentSize：默认字号内容较短时
      // 仍从顶部 20pt 开始；AX 内容高过视口时自然变成可滚动内容。
      content.leadingAnchor.constraint(
        equalTo: scrollView.frameLayoutGuide.leadingAnchor,
        constant: 20
      ),
      content.trailingAnchor.constraint(
        equalTo: scrollView.frameLayoutGuide.trailingAnchor,
        constant: -20
      ),
      content.topAnchor.constraint(
        equalTo: scrollView.contentLayoutGuide.topAnchor,
        constant: 20
      ),
      content.bottomAnchor.constraint(
        equalTo: scrollView.contentLayoutGuide.bottomAnchor,
        constant: -20
      ),
    ])

    emblem.translatesAutoresizingMaskIntoConstraints = false
    emblem.backgroundColor = .tertiarySystemFill
    emblem.layer.cornerRadius = 12
    emblem.layer.cornerCurve = .continuous
    NSLayoutConstraint.activate([
      emblem.widthAnchor.constraint(equalToConstant: 40),
      emblem.heightAnchor.constraint(equalToConstant: 40),
    ])
    emblemLabel.text = "贴"
    emblemLabel.textAlignment = .center
    emblemLabel.isAccessibilityElement = false
    emblemLabel.translatesAutoresizingMaskIntoConstraints = false
    emblem.addSubview(emblemLabel)
    NSLayoutConstraint.activate([
      emblemLabel.centerXAnchor.constraint(equalTo: emblem.centerXAnchor),
      emblemLabel.centerYAnchor.constraint(equalTo: emblem.centerYAnchor),
    ])

    brandLabel.text = "贴吧 LITE"
    brandLabel.numberOfLines = 1
    brandRow.axis = .horizontal
    brandRow.alignment = .center
    brandRow.spacing = 10
    brandRow.addArrangedSubview(emblem)
    brandRow.addArrangedSubview(brandLabel)

    titleLabel.text = "关注你喜欢的吧"
    titleLabel.numberOfLines = 0
    titleLabel.lineBreakMode = .byWordWrapping
    titleLabel.accessibilityTraits = .header

    detailLabel.text = "登录后查看关注的吧和最新动态。"
    detailLabel.numberOfLines = 0
    detailLabel.lineBreakMode = .byWordWrapping

    loginButton.addAction(UIAction { [weak self] _ in
      TiebaSceneHaptics.fire("press")
      self?.onLogin?()
    }, for: .touchUpInside)
    loginButton.accessibilityLabel = "登录百度账号"

    exploreButton.addAction(UIAction { [weak self] _ in
      TiebaSceneHaptics.fire("press")
      self?.onExplore?()
    }, for: .touchUpInside)
    exploreButton.accessibilityLabel = "先看看推荐"
    exploreButton.accessibilityHint = "前往动态页浏览推荐内容"

    loginButton.setContentHuggingPriority(.required, for: .horizontal)
    exploreButton.setContentHuggingPriority(.required, for: .horizontal)
    actions.axis = .vertical
    actions.alignment = .leading
    actions.spacing = 8
    actions.addArrangedSubview(loginButton)
    actions.addArrangedSubview(exploreButton)
    NSLayoutConstraint.activate([
      loginButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
      exploreButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
      loginButton.widthAnchor.constraint(lessThanOrEqualTo: actions.widthAnchor),
      exploreButton.widthAnchor.constraint(lessThanOrEqualTo: actions.widthAnchor),
    ])

    features.axis = .vertical
    features.alignment = .fill
    features.spacing = 16
    features.addArrangedSubview(makeFeature(
      symbol: "star.circle",
      title: "关注吧",
      detail: "关注吧和最新动态会集中在这里。"
    ))
    features.addArrangedSubview(makeFeature(
      symbol: "clock.arrow.circlepath",
      title: "浏览记录",
      detail: "最近访问过的吧。"
    ))

    content.addArrangedSubview(brandRow)
    content.addArrangedSubview(titleLabel)
    content.addArrangedSubview(detailLabel)
    content.addArrangedSubview(actions)
    content.addArrangedSubview(features)
    content.setCustomSpacing(22, after: brandRow)
    content.setCustomSpacing(24, after: detailLabel)
  }

  private func makeFeature(symbol: String, title: String, detail: String) -> UIView {
    let icon = UIImageView(image: UIImage(
      systemName: symbol,
      withConfiguration: UIImage.SymbolConfiguration(textStyle: .body, scale: .medium)
    ))
    icon.tintColor = TiebaHomeAccessibleColor.tertiaryIcon
    icon.contentMode = .scaleAspectFit
    icon.adjustsImageSizeForAccessibilityContentSizeCategory = true
    icon.isAccessibilityElement = false
    icon.setContentHuggingPriority(.required, for: .horizontal)
    icon.setContentCompressionResistancePriority(.required, for: .horizontal)

    let titleLabel = UILabel()
    titleLabel.text = title
    titleLabel.numberOfLines = 0
    titleLabel.lineBreakMode = .byWordWrapping
    titleLabel.isAccessibilityElement = false
    titleLabel.adjustsFontForContentSizeCategory = true

    let detailLabel = UILabel()
    detailLabel.text = detail
    detailLabel.numberOfLines = 0
    detailLabel.lineBreakMode = .byWordWrapping
    detailLabel.isAccessibilityElement = false
    detailLabel.adjustsFontForContentSizeCategory = true

    let copy = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
    copy.axis = .vertical
    copy.alignment = .fill
    copy.spacing = 2
    let row = UIStackView(arrangedSubviews: [icon, copy])
    row.axis = .horizontal
    row.alignment = .top
    row.spacing = 12
    row.isAccessibilityElement = true
    row.accessibilityTraits = .staticText
    row.accessibilityLabel = "\(title)。\(detail)"
    row.isUserInteractionEnabled = false
    featureTitleLabels.append(titleLabel)
    featureDetailLabels.append(detailLabel)
    iconViews.append(icon)
    return row
  }

  private func applyTypography() {
    // 40pt 品牌徽标里的单字属于装饰性 icon；固定字号避免 AX 下撑破固定方形。
    emblemLabel.font = .systemFont(ofSize: 24, weight: .bold)
    brandLabel.font = TiebaSimpleText.font(size: 12, weight: .semibold)
    titleLabel.font = TiebaSimpleText.font(size: 28, weight: .semibold)
    detailLabel.font = TiebaSimpleText.font(size: 15, weight: .regular)
    for label in featureTitleLabels {
      label.font = TiebaSimpleText.font(size: 15, weight: .semibold)
    }
    for label in featureDetailLabels {
      label.font = TiebaSimpleText.font(size: 13, weight: .regular)
    }
    configureButtons()
    setNeedsLayout()
    invalidateIntrinsicContentSize()
  }

  private func configureButtons() {
    // content 内只做实色 primary CTA；Liquid Glass 仅保留给 chrome。
    var login = UIButton.Configuration.filled()
    login.title = "登录百度账号"
    login.titleLineBreakMode = .byWordWrapping
    login.image = UIImage(
      systemName: "person.crop.circle.badge.checkmark",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
    )
    login.imagePadding = 8
    login.cornerStyle = .capsule
    login.baseBackgroundColor = TiebaHomeAccessibleColor.brand
    login.baseForegroundColor = TiebaHomeAccessibleColor.onBrand
    login.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 18, bottom: 12, trailing: 18)
    login.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
      var outgoing = incoming
      outgoing.font = TiebaSimpleText.font(size: 15, weight: .semibold)
      return outgoing
    }
    loginButton.configuration = login
    loginButton.titleLabel?.numberOfLines = 0
    loginButton.titleLabel?.lineBreakMode = .byWordWrapping
    loginButton.tintColor = TiebaHomeAccessibleColor.brand

    var explore = UIButton.Configuration.plain()
    explore.title = "先看看推荐"
    explore.titleLineBreakMode = .byWordWrapping
    explore.image = UIImage(
      systemName: "sparkles",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)
    )
    explore.imagePadding = 7
    explore.cornerStyle = .capsule
    explore.baseForegroundColor = TiebaHomeAccessibleColor.brandForeground
    explore.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
    explore.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
      var outgoing = incoming
      outgoing.font = TiebaSimpleText.font(size: 15, weight: .semibold)
      return outgoing
    }
    exploreButton.configuration = explore
    exploreButton.titleLabel?.numberOfLines = 0
    exploreButton.titleLabel?.lineBreakMode = .byWordWrapping
    exploreButton.tintColor = TiebaHomeAccessibleColor.brandForeground
  }

  private func applyColors() {
    emblem.backgroundColor = .tertiarySystemFill
    emblemLabel.textColor = .label
    brandLabel.textColor = TiebaHomeAccessibleColor.secondaryText
    titleLabel.textColor = TiebaHomeAccessibleColor.primaryText
    detailLabel.textColor = TiebaHomeAccessibleColor.secondaryText
    for label in featureTitleLabels {
      label.textColor = .label
    }
    for label in featureDetailLabels {
      label.textColor = TiebaHomeAccessibleColor.secondaryText
    }
    for icon in iconViews {
      icon.tintColor = TiebaHomeAccessibleColor.tertiaryIcon
    }
  }
}
