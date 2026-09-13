// 吧详情（原 src/app/forum/[name]/detail.tsx）：系统 insetGrouped 表格 + 两个自绘
// 卡片（资料卡 / 数据卡），数据与动作全在原生（TiebaForumAPI + TiebaLinkOpener）。
import UIKit

final class TiebaForumDetailViewController: UIViewController, TiebaNativeScreen {
  var screenTitle: String? { "吧信息" }

  private let name: String
  private let forumId: String

  private let table = UITableView(frame: .zero, style: .insetGrouped)
  private let refreshControl = UIRefreshControl()
  private let stateView = UIContentUnavailableView(configuration: .loading())

  private enum Row {
    case profile
    case stats
    case link(key: String, title: String, subtitle: String, icon: String, tint: UIColor)
    case text(String, icon: String?, color: UIColor?)
    case value(String, String)
    case browser
  }

  private struct Section {
    let title: String?
    var rows: [Row]
  }

  private var sections: [Section] = []
  private var detail: TiebaForumDetail?
  private var isLoading = false

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
    table.register(TiebaForumProfileCell.self, forCellReuseIdentifier: TiebaForumProfileCell.reuseID)
    table.register(TiebaForumStatsCell.self, forCellReuseIdentifier: TiebaForumStatsCell.reuseID)
    table.register(TiebaForumSelectableCell.self, forCellReuseIdentifier: TiebaForumSelectableCell.reuseID)
    table.register(UITableViewCell.self, forCellReuseIdentifier: "default")
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
      showError("缺少吧 ID")
      return
    }
    isLoading = true
    if detail == nil { showLoading() }
    Task { @MainActor in
      defer {
        isLoading = false
        refreshControl.endRefreshing()
      }
      do {
        let result = try await TiebaForumAPI.detail(forumId: forumId)
        detail = result
        sections = buildSections(result)
        stateView.isHidden = true
        table.isHidden = false
        table.reloadData()
        if isUserRefresh { TiebaSceneHaptics.fire("toggle") }
      } catch {
        if detail == nil { showError(error.localizedDescription) }
      }
      isUserRefresh = false
    }
  }

  private func buildSections(_ detail: TiebaForumDetail) -> [Section] {
    var sections: [Section] = [
      Section(title: nil, rows: [.profile, .stats]),
      Section(title: "吧管理", rows: [
        .link(key: "bawu", title: "吧务团队", subtitle: "查看本吧管理团队", icon: "person.2.fill", tint: .systemBlue),
        .link(key: "members", title: "吧成员", subtitle: "查看本吧成员信息", icon: "person.3.fill", tint: .systemGreen),
        .link(key: "rules", title: "吧规", subtitle: "发帖前请先阅读吧规", icon: "doc.text.fill", tint: .systemOrange),
      ]),
    ]
    if !detail.intro.isEmpty {
      sections.append(Section(title: "简介", rows: [.text(detail.intro, icon: nil, color: nil)]))
    }
    var dataRows: [Row] = []
    if !detail.recomReason.isEmpty {
      dataRows.append(.text(detail.recomReason, icon: "sparkles", color: .systemOrange))
    }
    if !detail.hotText.isEmpty {
      dataRows.append(.text(detail.hotText, icon: "flame.fill", color: .systemRed))
    }
    if !dataRows.isEmpty {
      sections.append(Section(title: "吧数据中心", rows: dataRows))
    }
    sections.append(Section(title: "吧信息", rows: [
      .value("吧名称", name),
      .value("吧ID", detail.forumId.isEmpty ? forumId : detail.forumId),
      .browser,
    ]))
    return sections
  }

  // MARK: - 状态

  private func showLoading() {
    stateView.configuration = UIContentUnavailableConfiguration.loading()
    stateView.isHidden = false
    table.isHidden = true
  }

  private func showError(_ message: String) {
    stateView.showError(message) { [weak self] in
      self?.detail = nil
      self?.reload()
    }
    table.isHidden = true
  }

  // MARK: - 动作

  private func open(_ row: Row) {
    switch row {
    case .link(let key, _, _, _, _):
      TiebaSceneHaptics.fire("press")
      // 路径段编码唯一实现（.urlPathAllowed 会放行 / 与 ?，字符集是错的）。
      let path = "/forum/\(TiebaRoutePath.segment(name))/\(key)"
      TiebaNavigator.shared.navigate(path: path, params: ["forumId": forumId], mode: "push")
    case .browser:
      TiebaSceneHaptics.fire("press")
      // 原 handleOpenInBrowser = openLink(buildForumUrl(name))：贴吧吧链接命中
      // tryTiebaInApp，站内 push 到 /forum/<name>（不是开浏览器），保持一致。
      let kw = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
      TiebaLinkOpener.open("https://tieba.baidu.com/f?kw=\(kw)")
    default:
      break
    }
  }
}

// MARK: - 表格

extension TiebaForumDetailViewController: UITableViewDataSource, UITableViewDelegate {
  func numberOfSections(in tableView: UITableView) -> Int { sections.count }

  func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
    sections[section].title
  }

  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    sections[section].rows.count
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let row = sections[indexPath.section].rows[indexPath.row]
    switch row {
    case .profile:
      let cell = tableView.dequeueReusableCell(
        withIdentifier: TiebaForumProfileCell.reuseID, for: indexPath
      ) as! TiebaForumProfileCell
      cell.configure(name: name, slogan: detail?.slogan ?? "", avatar: detail?.avatar ?? "", isLike: detail?.isLike ?? false)
      return cell
    case .stats:
      let cell = tableView.dequeueReusableCell(
        withIdentifier: TiebaForumStatsCell.reuseID, for: indexPath
      ) as! TiebaForumStatsCell
      var stats: [(String, String)] = [
        ("关注", TiebaForumFormat.count(detail?.memberCount ?? 0)),
        ("主题", TiebaForumFormat.count(detail?.threadCount ?? 0)),
      ]
      if let postCount = detail?.postCount { stats.append(("回贴", TiebaForumFormat.count(postCount))) }
      cell.configure(stats: stats)
      return cell
    default:
      // 简介 / 吧数据中心 / 吧ID：原页面这些 Text 都是 selectable，走自绘行。
      switch row {
      case .text(let text, let icon, let color):
        let cell = tableView.dequeueReusableCell(
          withIdentifier: TiebaForumSelectableCell.reuseID, for: indexPath
        ) as! TiebaForumSelectableCell
        cell.configure(text: text, icon: icon, iconColor: color)
        return cell
      case .value(let label, let value):
        let cell = tableView.dequeueReusableCell(
          withIdentifier: TiebaForumSelectableCell.reuseID, for: indexPath
        ) as! TiebaForumSelectableCell
        cell.configure(title: label, value: value)
        return cell
      default:
        break
      }
      let cell = tableView.dequeueReusableCell(withIdentifier: "default", for: indexPath)
      var config: UIListContentConfiguration
      var tappable = false
      switch row {
      case .link(_, let title, let subtitle, let icon, let tint):
        config = .subtitleCell()
        config.text = title
        config.secondaryText = subtitle
        config.image = UIImage(systemName: icon)
        config.imageProperties.tintColor = tint
        tappable = true
      case .browser:
        config = .cell()
        config.text = "在浏览器中打开"
        config.image = UIImage(systemName: "safari")
        config.imageProperties.tintColor = TiebaNavigator.shared.chromeTheme.tint
        tappable = true
      default:
        config = .cell()
      }
      cell.contentConfiguration = config
      cell.accessoryType = tappable ? .disclosureIndicator : .none
      cell.selectionStyle = tappable ? .default : .none
      return cell
    }
  }

  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    open(sections[indexPath.section].rows[indexPath.row])
  }
}

// MARK: - 可选中文本行

/// 自绘行：承载 `TiebaSelectableLabel`。系统 `UIListContentConfiguration` 的文字
/// 不可选中，而原页面的简介 / 吧数据中心 / 吧ID 都是 `selectable`。
private final class TiebaForumSelectableCell: UITableViewCell {
  static let reuseID = "TiebaForumSelectableCell"

  private let iconView = UIImageView()
  private let titleLabel = UILabel()
  private let textView = TiebaSelectableLabel(
    font: .preferredFont(forTextStyle: .body), color: .label
  )

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    selectionStyle = .none

    iconView.contentMode = .scaleAspectFit
    iconView.setContentHuggingPriority(.required, for: .horizontal)
    iconView.setContentCompressionResistancePriority(.required, for: .horizontal)

    titleLabel.font = .preferredFont(forTextStyle: .body)
    titleLabel.textColor = .secondaryLabel
    titleLabel.adjustsFontForContentSizeCategory = true
    titleLabel.setContentHuggingPriority(.required, for: .horizontal)
    titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

    let row = UIStackView(arrangedSubviews: [iconView, titleLabel, textView])
    row.axis = .horizontal
    row.alignment = .top
    row.spacing = 8
    row.translatesAutoresizingMaskIntoConstraints = false
    iconView.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(row)
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
      row.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
      row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 11),
      row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -11),
      iconView.widthAnchor.constraint(equalToConstant: 15),
      iconView.heightAnchor.constraint(equalToConstant: 15),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// 正文行（原 `<Text selectable>`，可带前置图标）。
  func configure(text: String, icon: String?, iconColor: UIColor?) {
    iconView.isHidden = icon == nil
    iconView.image = icon.flatMap { UIImage(systemName: $0) }
    iconView.tintColor = iconColor
    titleLabel.isHidden = true
    textView.textAlignment = .natural
    textView.textColor = .secondaryLabel
    textView.text = text
  }

  /// 值行（原 infoRow 左标签 + 右值；吧ID 原本就是 selectable）。
  func configure(title: String, value: String) {
    iconView.isHidden = true
    titleLabel.isHidden = false
    titleLabel.text = title
    textView.textAlignment = .right
    textView.textColor = .label
    textView.text = value
  }
}

// MARK: - 资料卡

private final class TiebaForumProfileCell: UITableViewCell {
  static let reuseID = "TiebaForumProfileCell"

  private let avatarView = TiebaForumAvatarView(size: 76)
  private let nameLabel = UILabel()
  private let sloganLabel = UILabel()
  private let chip = UIStackView()
  private let chipView = UIView()

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    selectionStyle = .none

    nameLabel.font = .systemFont(ofSize: 24, weight: .bold)
    nameLabel.textColor = .label
    nameLabel.textAlignment = .center
    nameLabel.adjustsFontForContentSizeCategory = true
    sloganLabel.font = .preferredFont(forTextStyle: .footnote)
    sloganLabel.textColor = .secondaryLabel
    sloganLabel.textAlignment = .center
    sloganLabel.numberOfLines = 2
    sloganLabel.adjustsFontForContentSizeCategory = true

    let chipIcon = UIImageView(image: UIImage(systemName: "checkmark.seal.fill"))
    chipIcon.contentMode = .scaleAspectFit
    let chipLabel = UILabel()
    chipLabel.font = .preferredFont(forTextStyle: .caption1)
    chipLabel.text = "已关注"
    chip.axis = .horizontal
    chip.alignment = .center
    chip.spacing = 4
    chip.addArrangedSubview(chipIcon)
    chip.addArrangedSubview(chipLabel)
    chipView.layer.cornerRadius = 11
    chipView.addSubview(chip)

    let stack = UIStackView(arrangedSubviews: [avatarView, nameLabel, sloganLabel, chipView])
    stack.axis = .vertical
    stack.alignment = .center
    stack.spacing = 8
    stack.setCustomSpacing(12, after: avatarView)
    stack.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(stack)
    avatarView.translatesAutoresizingMaskIntoConstraints = false
    chip.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
      stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 18),
      stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -18),
      chip.leadingAnchor.constraint(equalTo: chipView.leadingAnchor, constant: 10),
      chip.trailingAnchor.constraint(equalTo: chipView.trailingAnchor, constant: -10),
      chip.topAnchor.constraint(equalTo: chipView.topAnchor, constant: 4),
      chip.bottomAnchor.constraint(equalTo: chipView.bottomAnchor, constant: -4),
      chipIcon.widthAnchor.constraint(equalToConstant: 12),
      chipIcon.heightAnchor.constraint(equalToConstant: 12),
    ])
    chipLabel.textColor = TiebaNavigator.shared.chromeTheme.tint
    chipIcon.tintColor = TiebaNavigator.shared.chromeTheme.tint
    chipView.backgroundColor = TiebaNavigator.shared.chromeTheme.tint.withAlphaComponent(0.1)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(name: String, slogan: String, avatar: String, isLike: Bool) {
    nameLabel.text = "\(name)吧"
    sloganLabel.text = slogan
    sloganLabel.isHidden = slogan.isEmpty
    chipView.isHidden = !isLike
    avatarView.configure(url: avatar, initial: name)
  }
}

// MARK: - 数据卡

private final class TiebaForumStatsCell: UITableViewCell {
  static let reuseID = "TiebaForumStatsCell"

  private let statsRow = TiebaStatColumnsRow(
    valueFont: .monospacedDigitSystemFont(ofSize: 21, weight: .bold),
    labelFont: .preferredFont(forTextStyle: .caption1),
    separator: .fixed(height: 30)
  )

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    selectionStyle = .none
    statsRow.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(statsRow)
    NSLayoutConstraint.activate([
      statsRow.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
      statsRow.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
      statsRow.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
      statsRow.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(stats: [(String, String)]) {
    statsRow.setColumns(
      values: stats.map(\.1),
      labels: stats.map(\.0),
      valueColor: .label,
      labelColor: .tertiaryLabel
    )
  }
}
