// 吧务团队（原 src/app/forum/[name]/bawu.tsx）：行渲染已是原生 TiebaKindListContentView，
// 本类只补数据（TiebaForumAPI.bawuTeam）与行模型（概览卡 / 角色分组 / 成员行）。
import UIKit

final class TiebaBawuTeamViewController: UIViewController {
  private let name: String
  private let forumId: String

  private let list = TiebaKindListContentView()
  private let stateView = UIContentUnavailableView(configuration: .loading())

  private var team: TiebaBawuTeam?
  private var rowItems: [TiebaBawuTeam.Member?] = []
  private var rows: [[String: Any]] = []
  /// 行页发布（页键守卫 + 整页后台测量都收敛在 driver）。
  private lazy var driver = TiebaRowPageDriver(list: list, keyPrefix: "bawu-\(forumId)")
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
    view.backgroundColor = .systemBackground
    list.translatesAutoresizingMaskIntoConstraints = false
    list.palette = .default
    list.onListEvent = { [weak self] event in self?.handleEvent(event) }
    list.isHidden = true
    stateView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(list)
    view.addSubview(stateView)
    NSLayoutConstraint.activate([
      list.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      list.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      list.topAnchor.constraint(equalTo: view.topAnchor),
      list.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      stateView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      stateView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      stateView.topAnchor.constraint(equalTo: view.topAnchor),
      stateView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    reload()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    applyInsets()
    driver.updateWidth(list.bounds.width)
  }

  override func viewSafeAreaInsetsDidChange() {
    super.viewSafeAreaInsetsDidChange()
    applyInsets()
  }

  /// 原生列表自己不做安全区（contentInsetAdjustmentBehavior = .never），
  /// 顶部内白 = 状态栏 + 导航栏。
  private func applyInsets() {
    list.contentInsetTop = view.safeAreaInsets.top
    list.contentInsetBottom = view.safeAreaInsets.bottom + 24
  }

  // MARK: - 数据

  /// 下拉刷新与首载共用一条路径，只有用户下拉才补刷新触觉（原页面只在 onRefresh 里发）。
  private var isUserRefresh = false

  @objc private func reload() {
    guard !isLoading else {
      list.endRefreshing()
      return
    }
    guard !forumId.isEmpty else {
      list.endRefreshing()
      showState(.error("缺少吧 ID"))
      return
    }
    isLoading = true
    if team == nil { showState(.loading) }
    Task { @MainActor in
      defer {
        isLoading = false
        isUserRefresh = false
        list.endRefreshing()
      }
      do {
        let result = try await TiebaForumAPI.bawuTeam(forumId: forumId)
        team = result
        guard !result.roles.isEmpty else {
          showState(.empty)
          return
        }
        let built = makeRows(result)
        rows = built.rows
        rowItems = built.items
        showState(.content)
        publish(fresh: true)
        if isUserRefresh { TiebaSceneHaptics.fire("toggle") }
      } catch {
        if team == nil { showState(.error(error.localizedDescription)) }
      }
    }
  }

  private func publish(fresh: Bool) {
    driver.publish(fresh: fresh) { [weak self] in
      self?.rows ?? []
    }
  }

  // MARK: - 行模型

  private func makeRows(_ team: TiebaBawuTeam) -> (rows: [[String: Any]], items: [TiebaBawuTeam.Member?]) {
    let colors = colorStrings()
    func color(_ key: String) -> String { colors[key] ?? "" }
    var rows: [[String: Any]] = []
    var items: [TiebaBawuTeam.Member?] = []

    let total = team.totalNum > 0 ? team.totalNum : team.memberCount
    rows.append([
      "variant": "summary",
      "a11y": "\(name)吧管理团队",
      "icon": "shield.lefthalf.filled",
      "iconSize": 20,
      "iconColor": color("primary"),
      "iconBg": color("primarySoft"),
      "iconBox": 40,
      "iconBoxRadius": 12,
      "title": "\(name)吧管理团队",
      "titleSize": 16,
      "titleWeight": 600,
      "titleLineHeight": 21,
      "subtitle": "共 \(total) 名吧务成员",
      "subtitleSize": 12,
      "subtitleWeight": 400,
      "subtitleLineHeight": 16,
      "subtitleMarginTop": 2,
      "colors": ["bg": color("groupFill")],
    ])
    items.append(nil)

    for role in team.roles {
      let roleName = role.name.isEmpty ? "吧务" : role.name
      rows.append([
        "variant": "section",
        "a11y": roleName,
        "title": roleName,
        "count": role.members.isEmpty ? "" : "\(role.members.count)人",
        "colors": [
          "dotColor": color("primary"),
          "chipBg": color("surfaceSecondary"),
          "chipTextColor": color("textTertiary"),
        ],
      ])
      items.append(nil)

      for member in role.members {
        var row: [String: Any] = [
          "variant": "user",
          "a11y": member.displayName,
          "avatar": member.portrait,
          "avatarInitial": String(member.displayName.prefix(1)),
          "avatarSize": 46,
          "title": member.displayName,
          "titleSize": 16,
          "titleWeight": 600,
          "titleLineHeight": 21,
          "subtitle": member.levelName.isEmpty ? member.roleName : "\(member.roleName) · \(member.levelName)",
          "subtitleSize": 12,
          "subtitleWeight": 400,
          "subtitleLineHeight": 16,
          "subtitleMarginTop": 2,
          "chevron": true,
          "chevronSize": 13,
          "chevronWeight": 600,
          "marginH": 16,
          "marginV": 4,
          "paddingH": 14,
          "paddingV": 11,
          "radius": 20,
          "gap": 12,
          "borderWidth": 0.5,
          "colors": [
            "bg": color("card"),
            "borderColor": color("divider"),
            "chevronColor": color("textDisabled"),
            "badgeColor": color("primary"),
            "badgeBg": color("primarySoft"),
          ],
        ]
        if member.userLevel > 0 {
          row["badge"] = "Lv.\(member.userLevel)"
          row["badgeSize"] = 10
          row["badgeWeight"] = 700
          row["badgeLineHeight"] = 14
          row["badgePaddingH"] = 5
          row["badgePaddingV"] = 1
          row["badgeRadius"] = 8
          row["badgeSpacing"] = 6
        }
        rows.append(row)
        items.append(member)
      }
    }
    return (rows, items)
  }

  /// 行色板：行视图默认值就是迁移前的默认主题色，这里把自适应色按当前深浅解析成
  /// 串下发（默认值里的 user 行卡片底是固定白，深色下会亮块），主色换成主题主色。
  private func colorStrings() -> [String: String] {
    let palette = TiebaSimpleRowPalette.default
    let dark = TiebaNavigator.shared.chromeTheme.dark
    let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)

    func hex(_ color: UIColor) -> String {
      let resolved = color.resolvedColor(with: traits)
      var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
      resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
      if a >= 0.999 {
        return String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
      }
      return String(
        format: "rgba(%d,%d,%d,%.2f)",
        Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()), a
      )
    }

    let tint = TiebaNavigator.shared.chromeTheme.tint
    return [
      "primary": hex(tint),
      "primarySoft": hex(tint.withAlphaComponent(0.12)),
      "card": hex(palette.base.card),
      "groupFill": hex(palette.groupFill),
      "surfaceSecondary": hex(palette.surfaceSecondary),
      "textTertiary": hex(palette.base.textTertiary),
      "textDisabled": hex(palette.textDisabled),
      "divider": hex(palette.divider),
    ]
  }

  // MARK: - 事件

  private func handleEvent(_ event: TiebaKindListEvent) {
    switch event {
    case .rowTap(let index, _, _):
      guard index >= 0, index < rowItems.count,
        let member = rowItems[index], !member.userId.isEmpty
      else { return }
      TiebaSceneHaptics.fire("press")
      TiebaNavigator.shared.navigate(path: "/user/\(member.userId)", params: [:], mode: "push")
    case .refreshRequested:
      isUserRefresh = true
      reload()
    default:
      break
    }
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
      list.isHidden = false
    case .loading:
      stateView.configuration = UIContentUnavailableConfiguration.loading()
      stateView.isHidden = false
      list.isHidden = true
    case .empty:
      stateView.showEmpty(
        image: "person.2",
        text: "暂无吧务信息",
        secondaryText: "这个吧还没有公开管理团队"
      )
      list.isHidden = true
    case .error(let message):
      stateView.showError(message) { [weak self] in self?.reload() }
      list.isHidden = true
    }
  }
}
