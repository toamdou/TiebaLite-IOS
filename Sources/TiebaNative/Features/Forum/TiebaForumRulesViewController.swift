// 吧规（原 src/app/forum/[name]/rules.tsx）：系统 insetGrouped 列表 + PbContent
// 段落渲染（文本 / 图片 / 引用 / 链接 / 换行），数据来自 TiebaForumAPI.rules
//（proto 主、web 降级）。长吧规走列表虚拟化，不再整屏重建卡片。
import UIKit
import Nuke
import NukeExtensions

final class TiebaForumRulesViewController: UIViewController, TiebaNativeScreen {
  var screenTitle: String? { "吧规" }

  private let name: String
  private let forumId: String

  private let table = UITableView(frame: .zero, style: .insetGrouped)
  private let refreshControl = UIRefreshControl()
  private let stateView = UIContentUnavailableView(configuration: .loading())
  private var rules: TiebaForumRules?
  private var isLoading = false

  private enum Row {
    case title(String)
    case author(name: String, portrait: String, time: String)
    case preface(String)
    case segment(TiebaRuleSegment)
    case footer(String)
  }

  private struct Section {
    let title: String?
    let number: Int
    var rows: [Row]
  }

  private var sections: [Section] = []

  init(name: String, forumId: String) {
    self.name = name
    self.forumId = forumId
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemGroupedBackground
    table.dataSource = self
    table.delegate = self
    table.register(TiebaRuleTitleCell.self, forCellReuseIdentifier: TiebaRuleTitleCell.reuseID)
    table.register(TiebaRuleAuthorCell.self, forCellReuseIdentifier: TiebaRuleAuthorCell.reuseID)
    table.register(TiebaRulePrefaceCell.self, forCellReuseIdentifier: TiebaRulePrefaceCell.reuseID)
    table.register(TiebaRuleTextCell.self, forCellReuseIdentifier: TiebaRuleTextCell.reuseID)
    table.register(TiebaRuleQuoteCell.self, forCellReuseIdentifier: TiebaRuleQuoteCell.reuseID)
    table.register(TiebaRuleImageCell.self, forCellReuseIdentifier: TiebaRuleImageCell.reuseID)
    table.register(TiebaRuleLinkCell.self, forCellReuseIdentifier: TiebaRuleLinkCell.reuseID)
    table.register(TiebaRuleSpacerCell.self, forCellReuseIdentifier: TiebaRuleSpacerCell.reuseID)
    table.register(TiebaRuleFooterCell.self, forCellReuseIdentifier: TiebaRuleFooterCell.reuseID)
    table.rowHeight = UITableView.automaticDimension
    table.estimatedRowHeight = 60
    table.sectionHeaderTopPadding = 12
    refreshControl.addTarget(self, action: #selector(handleRefresh), for: .valueChanged)
    table.refreshControl = refreshControl
    table.translatesAutoresizingMaskIntoConstraints = false
    stateView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(table)
    view.addSubview(stateView)
    NSLayoutConstraint.activate([
      table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      table.topAnchor.constraint(equalTo: view.topAnchor),
      table.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      stateView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      stateView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      stateView.topAnchor.constraint(equalTo: view.topAnchor),
      stateView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    reload()
  }

  // MARK: - 数据

  /// 下拉刷新与首载共用一条路径，只有用户下拉才补刷新触觉（原页面只在 onRefresh 里发）。
  private var isUserRefresh = false

  @objc private func handleRefresh() {
    isUserRefresh = true
    reload()
  }

  @objc private func reload() {
    guard !isLoading else {
      refreshControl.endRefreshing()
      return
    }
    guard !forumId.isEmpty else {
      refreshControl.endRefreshing()
      showState(.error("缺少吧 ID"))
      return
    }
    isLoading = true
    if rules == nil { showState(.loading) }
    Task { @MainActor in
      defer {
        isLoading = false
        refreshControl.endRefreshing()
      }
      do {
        let result = try await TiebaForumAPI.rules(forumId: forumId)
        rules = result
        if let result {
          buildSections(result)
          table.reloadData()
          showState(.content)
        } else {
          showState(.empty)
        }
        if isUserRefresh { TiebaSceneHaptics.fire("toggle") }
      } catch {
        if rules == nil { showState(.error(error.localizedDescription)) }
      }
      isUserRefresh = false
    }
  }

  // MARK: - 内容

  private func buildSections(_ rules: TiebaForumRules) {
    let title = rules.title.isEmpty ? "\(name.isEmpty ? "本" : name)吧吧规" : rules.title
    var head: [Row] = [.title(title)]
    if !rules.authorName.isEmpty || !rules.publishTime.isEmpty {
      head.append(
        .author(
          name: rules.authorName.isEmpty ? "\(name)吧吧务团队" : rules.authorName,
          portrait: rules.authorPortrait,
          time: rules.publishTime
        )
      )
    }
    if !rules.preface.isEmpty { head.append(.preface(rules.preface)) }
    var built: [Section] = [Section(title: nil, number: 0, rows: head)]
    for (index, section) in rules.sections.enumerated() {
      built.append(
        Section(
          title: section.title.isEmpty ? nil : section.title,
          number: index + 1,
          rows: section.segments.map(Row.segment)
        )
      )
    }
    built.append(
      Section(
        title: nil,
        number: 0,
        rows: [.footer("以上内容来自\(name.isEmpty ? "本" : name)吧吧务团队发布的管理规范")]
      )
    )
    sections = built
  }

  /// 图片显示宽度 = 屏宽 − 页面左右 16×2 − 卡片内左右 16×2（原 RULE_IMAGE_INSET
  /// 同一算式）；下采样交给共享 Nuke options。屏宽/scale 从窗口场景取
  ///（UIScreen.main 自 iOS 26 废弃，多场景/外接屏下语义错误）。
  private func imageMaxPixel() -> CGFloat {
    let screen = view.window?.windowScene?.screen
    let screenWidth = screen?.bounds.width ?? view.bounds.width
    let width = view.bounds.width > 0 ? view.bounds.width : screenWidth
    return max(width - 64, 1) * traitCollection.displayScale
  }

  // MARK: - 状态

  private enum State {
    case loading
    case content
    case empty
    case error(String)
  }

  private func showState(_ state: State) {
    switch state {
    case .content:
      stateView.isHidden = true
      table.isHidden = false
    case .loading:
      stateView.configuration = UIContentUnavailableConfiguration.loading()
      stateView.isHidden = false
      table.isHidden = true
    case .empty:
      stateView.showEmpty(
        image: "doc.text",
        text: "暂无吧规",
        secondaryText: "\(name.isEmpty ? "这个" : name)吧还没有设置吧规"
      )
      table.isHidden = true
    case .error(let message):
      stateView.showError(message) { [weak self] in self?.reload() }
      table.isHidden = true
    }
  }
}

// MARK: - 表格

extension TiebaForumRulesViewController: UITableViewDataSource, UITableViewDelegate {
  func numberOfSections(in tableView: UITableView) -> Int { sections.count }

  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    sections[section].rows.count
  }

  func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
    guard let title = sections[section].title else { return nil }
    let header = TiebaRuleSectionHeaderView(reuseIdentifier: nil)
    header.configure(number: sections[section].number, title: title)
    return header
  }

  func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
    sections[section].title == nil ? 8 : UITableView.automaticDimension
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let row = sections[indexPath.section].rows[indexPath.row]
    switch row {
    case .title(let text):
      let cell = tableView.dequeueReusableCell(
        withIdentifier: TiebaRuleTitleCell.reuseID, for: indexPath
      ) as! TiebaRuleTitleCell
      cell.configure(text: text)
      return cell
    case .author(let name, let portrait, let time):
      let cell = tableView.dequeueReusableCell(
        withIdentifier: TiebaRuleAuthorCell.reuseID, for: indexPath
      ) as! TiebaRuleAuthorCell
      cell.configure(name: name, portrait: portrait, time: time)
      return cell
    case .preface(let text):
      let cell = tableView.dequeueReusableCell(
        withIdentifier: TiebaRulePrefaceCell.reuseID, for: indexPath
      ) as! TiebaRulePrefaceCell
      cell.configure(text: text)
      return cell
    case .footer(let text):
      let cell = tableView.dequeueReusableCell(
        withIdentifier: TiebaRuleFooterCell.reuseID, for: indexPath
      ) as! TiebaRuleFooterCell
      cell.configure(text: text)
      return cell
    case .segment(let segment):
      switch segment {
      case .text(let text, let bold):
        let cell = tableView.dequeueReusableCell(
          withIdentifier: TiebaRuleTextCell.reuseID, for: indexPath
        ) as! TiebaRuleTextCell
        cell.configure(text: text, bold: bold)
        return cell
      case .quote(let text):
        let cell = tableView.dequeueReusableCell(
          withIdentifier: TiebaRuleQuoteCell.reuseID, for: indexPath
        ) as! TiebaRuleQuoteCell
        cell.configure(text: text)
        return cell
      case .image(let src, let width, let height):
        let cell = tableView.dequeueReusableCell(
          withIdentifier: TiebaRuleImageCell.reuseID, for: indexPath
        ) as! TiebaRuleImageCell
        cell.configure(src: src, width: width, height: height, maxPixel: imageMaxPixel())
        return cell
      case .link(let url, let title):
        let cell = tableView.dequeueReusableCell(
          withIdentifier: TiebaRuleLinkCell.reuseID, for: indexPath
        ) as! TiebaRuleLinkCell
        cell.configure(url: url, title: title)
        return cell
      case .lineBreak:
        return tableView.dequeueReusableCell(
          withIdentifier: TiebaRuleSpacerCell.reuseID, for: indexPath
        )
      }
    }
  }
}

// MARK: - 分组头（序号 chip + 标题）

private final class TiebaRuleSectionHeaderView: UITableViewHeaderFooterView {
  private let chip = UILabel()
  private let chipBox = UIView()
  private let titleLabel = UILabel()

  override init(reuseIdentifier: String?) {
    super.init(reuseIdentifier: reuseIdentifier)
    chip.font = .systemFont(ofSize: 13, weight: .heavy)
    chip.textColor = TiebaNavigator.shared.chromeTheme.tint
    chip.textAlignment = .center
    chip.translatesAutoresizingMaskIntoConstraints = false
    chipBox.backgroundColor = TiebaNavigator.shared.chromeTheme.tint.withAlphaComponent(0.1)
    chipBox.layer.cornerRadius = 12
    chipBox.translatesAutoresizingMaskIntoConstraints = false
    chipBox.addSubview(chip)
    titleLabel.font = .preferredFont(forTextStyle: .headline)
    titleLabel.textColor = .label
    titleLabel.numberOfLines = 0

    let row = UIStackView(arrangedSubviews: [chipBox, titleLabel])
    row.axis = .horizontal
    row.alignment = .top
    row.spacing = 10
    row.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(row)
    NSLayoutConstraint.activate([
      chipBox.widthAnchor.constraint(equalToConstant: 24),
      chipBox.heightAnchor.constraint(equalToConstant: 24),
      chip.centerXAnchor.constraint(equalTo: chipBox.centerXAnchor),
      chip.centerYAnchor.constraint(equalTo: chipBox.centerYAnchor),
      row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 32),
      row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
      row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
      row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -2),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(number: Int, title: String) {
    chip.text = "\(number)"
    titleLabel.text = title
  }
}

// MARK: - 单元格

/// 标题（原 27/800 可选中文本）。
private final class TiebaRuleTitleCell: UITableViewCell {
  static let reuseID = "TiebaRuleTitleCell"
  private let label = TiebaSelectableLabel(
    font: .systemFont(ofSize: 27, weight: .heavy), color: .label
  )

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    selectionStyle = .none
    label.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(label)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
      label.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
      label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
      label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(text: String) {
    label.text = text
  }
}

/// 作者行（头像 40 + 昵称/发布时间）。
private final class TiebaRuleAuthorCell: UITableViewCell {
  static let reuseID = "TiebaRuleAuthorCell"
  private let avatar = TiebaForumAvatarView(size: 40)
  private let nameLabel = UILabel()
  private let timeLabel = UILabel()

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    selectionStyle = .none
    nameLabel.font = UIFont.tiebaFormFont(.preferredFont(forTextStyle: .subheadline), weight: .semibold)
    nameLabel.textColor = .label
    nameLabel.numberOfLines = 1
    timeLabel.font = .preferredFont(forTextStyle: .caption1)
    timeLabel.textColor = .tertiaryLabel
    timeLabel.numberOfLines = 1
    let column = UIStackView(arrangedSubviews: [nameLabel, timeLabel])
    column.axis = .vertical
    column.spacing = 2
    let row = UIStackView(arrangedSubviews: [avatar, column])
    row.axis = .horizontal
    row.alignment = .center
    row.spacing = 11
    row.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(row)
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
      row.trailingAnchor.constraint(lessThanOrEqualTo: contentView.layoutMarginsGuide.trailingAnchor),
      row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
      row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(name: String, portrait: String, time: String) {
    avatar.configure(url: portrait, initial: name.isEmpty ? "吧" : name)
    nameLabel.text = name
    timeLabel.text = time
    timeLabel.isHidden = time.isEmpty
  }
}

/// 前言卡（引用图标 + 13 号说明，底 = 主色 6%）。
private final class TiebaRulePrefaceCell: UITableViewCell {
  static let reuseID = "TiebaRulePrefaceCell"
  private let label = TiebaSelectableLabel(
    font: .preferredFont(forTextStyle: .subheadline), color: .secondaryLabel
  )

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    selectionStyle = .none
    let icon = UIImageView(image: UIImage(systemName: "text.quote"))
    icon.tintColor = TiebaNavigator.shared.chromeTheme.tint
    icon.setContentHuggingPriority(.required, for: .horizontal)
    icon.setContentCompressionResistancePriority(.required, for: .horizontal)
    let stack = UIStackView(arrangedSubviews: [icon, label])
    stack.axis = .horizontal
    stack.alignment = .top
    stack.spacing = 9
    stack.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(stack)
    contentView.backgroundColor = TiebaNavigator.shared.chromeTheme.tint.withAlphaComponent(0.06)
    contentView.layer.cornerRadius = 16
    contentView.layer.cornerCurve = .continuous
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
      stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
      stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(text: String) {
    label.text = text
  }
}

/// 正文段（可选中；bold = 强调段）。
private final class TiebaRuleTextCell: UITableViewCell {
  static let reuseID = "TiebaRuleTextCell"
  private let label = TiebaSelectableLabel(
    font: .preferredFont(forTextStyle: .subheadline), color: .secondaryLabel
  )

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    selectionStyle = .none
    label.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(label)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
      label.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
      label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 3),
      label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -3),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(text: String, bold: Bool) {
    let base = UIFont.preferredFont(forTextStyle: .subheadline)
    label.font = bold ? UIFont.tiebaFormFont(base, weight: .semibold) : base
    label.text = text
  }
}

/// 引用段（主色竖条 + 脚注文本，底 tertiarySystemFill）。
private final class TiebaRuleQuoteCell: UITableViewCell {
  static let reuseID = "TiebaRuleQuoteCell"
  private let label = TiebaSelectableLabel(
    font: .preferredFont(forTextStyle: .footnote), color: .secondaryLabel
  )

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    selectionStyle = .none
    let bar = UIView()
    bar.backgroundColor = TiebaNavigator.shared.chromeTheme.tint
    bar.translatesAutoresizingMaskIntoConstraints = false
    bar.widthAnchor.constraint(equalToConstant: 3).isActive = true
    let row = UIStackView(arrangedSubviews: [bar, label])
    row.axis = .horizontal
    row.alignment = .fill
    row.spacing = 10
    row.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(row)
    contentView.backgroundColor = .tertiarySystemFill
    contentView.layer.cornerRadius = 8
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
      row.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
      row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
      row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(text: String) {
    label.text = text
  }
}

/// 图片段（src 为空 = 原页面的「[图片]」占位；有宽高按比例，否则 180 兜底）。
private final class TiebaRuleImageCell: UITableViewCell {
  static let reuseID = "TiebaRuleImageCell"
  private let ruleImageView = UIImageView()
  private let placeholder = UILabel()
  private var aspectConstraint: NSLayoutConstraint?
  private var fallbackHeight: NSLayoutConstraint?

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    selectionStyle = .none
    ruleImageView.contentMode = .scaleAspectFill
    ruleImageView.clipsToBounds = true
    ruleImageView.layer.cornerRadius = 10
    ruleImageView.backgroundColor = .secondarySystemFill
    ruleImageView.translatesAutoresizingMaskIntoConstraints = false
    placeholder.text = "[图片]"
    placeholder.font = .preferredFont(forTextStyle: .subheadline)
    placeholder.textColor = .tertiaryLabel
    placeholder.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(ruleImageView)
    contentView.addSubview(placeholder)
    NSLayoutConstraint.activate([
      ruleImageView.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
      ruleImageView.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
      ruleImageView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
      ruleImageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
      placeholder.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
      placeholder.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func prepareForReuse() {
    super.prepareForReuse()
    cancelRequest(for: ruleImageView)
    ruleImageView.image = nil
  }

  func configure(src: String, width: CGFloat, height: CGFloat, maxPixel: CGFloat) {
    aspectConstraint?.isActive = false
    aspectConstraint = nil
    fallbackHeight?.isActive = false
    fallbackHeight = nil
    guard !src.isEmpty, let url = URL(string: src) else {
      ruleImageView.isHidden = true
      ruleImageView.image = nil
      placeholder.isHidden = false
      // 占位也要给图片视图一个确定高度，否则自适应高无解。
      let fixed = ruleImageView.heightAnchor.constraint(equalToConstant: 28)
      fixed.isActive = true
      fallbackHeight = fixed
      return
    }
    placeholder.isHidden = true
    ruleImageView.isHidden = false
    if width > 0, height > 0 {
      let ratio = ruleImageView.heightAnchor.constraint(
        equalTo: ruleImageView.widthAnchor, multiplier: height / width
      )
      ratio.isActive = true
      aspectConstraint = ratio
    } else {
      let fixed = ruleImageView.heightAnchor.constraint(equalToConstant: 180)
      fixed.isActive = true
      fallbackHeight = fixed
    }
    loadImage(
      with: TiebaNuke.secureURL(url),
      options: TiebaNuke.options(maxPixel: maxPixel),
      into: ruleImageView
    )
  }
}

/// 链接段（主色胶囊按钮）。
private final class TiebaRuleLinkCell: UITableViewCell {
  static let reuseID = "TiebaRuleLinkCell"
  private let button = UIButton(type: .system)
  private var url = ""

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    selectionStyle = .none
    button.contentHorizontalAlignment = .leading
    button.translatesAutoresizingMaskIntoConstraints = false
    button.addAction(UIAction { [weak self] _ in
      guard let self, !self.url.isEmpty else { return }
      TiebaSceneHaptics.fire("press")
      TiebaLinkOpener.open(self.url)
    }, for: .touchUpInside)
    contentView.addSubview(button)
    NSLayoutConstraint.activate([
      button.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
      button.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
      button.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
      button.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(url: String, title: String) {
    self.url = url
    var config = UIButton.Configuration.plain()
    config.title = title
    config.image = UIImage(systemName: "link")
    config.imagePadding = 4
    config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
    config.baseForegroundColor = TiebaNavigator.shared.chromeTheme.tint
    config.background.backgroundColor = TiebaNavigator.shared.chromeTheme.tint.withAlphaComponent(0.08)
    config.background.cornerRadius = 8
    config.titleLineBreakMode = .byTruncatingTail
    button.configuration = config
  }
}

/// 空行（原 lineBreak = 8pt）。
private final class TiebaRuleSpacerCell: UITableViewCell {
  static let reuseID = "TiebaRuleSpacerCell"

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    selectionStyle = .none
    let spacer = UIView()
    spacer.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(spacer)
    NSLayoutConstraint.activate([
      spacer.heightAnchor.constraint(equalToConstant: 8),
      spacer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      spacer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      spacer.topAnchor.constraint(equalTo: contentView.topAnchor),
      spacer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// 尾注（居中 caption）。
private final class TiebaRuleFooterCell: UITableViewCell {
  static let reuseID = "TiebaRuleFooterCell"
  private let label = UILabel()

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    selectionStyle = .none
    label.font = .preferredFont(forTextStyle: .caption1)
    label.textColor = .tertiaryLabel
    label.textAlignment = .center
    label.numberOfLines = 0
    label.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(label)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
      label.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
      label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
      label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(text: String) {
    label.text = text
  }
}
