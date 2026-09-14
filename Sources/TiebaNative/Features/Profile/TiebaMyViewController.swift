// 「我的」tab 根屏（原 src/app/(tabs)/profile.tsx）：用户卡片（头像/昵称/简介/
// 三等分统计行/登录 CTA）+ 设置表单（TiebaFormListView）。数据：原生 KV 档案
// 缓存 + 快照登录态，资料走 TiebaUserAPI.profile（落后端不阻塞卡片）。
import UIKit

final class TiebaMyViewController: UIViewController, TiebaTabReselectable {
  private let card = UIView()
  private let cardMaterial = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
  private let cardGradient = CAGradientLayer()
  private let avatar = TiebaForumAvatarView(size: 64)
  private let avatarPlaceholder = UIView()
  private let avatarPlaceholderIcon = UIImageView()
  private let nameLabel = UILabel()
  private let introLabel = UILabel()
  private let statsRow = TiebaStatColumnsRow(
    valueFont: UIFontMetrics(forTextStyle: .title3).scaledFont(
      for: .systemFont(ofSize: 20, weight: .semibold)
    ),
    labelFont: UIFontMetrics(forTextStyle: .caption1).scaledFont(for: .systemFont(ofSize: 12)),
    separator: .fill(inset: 4)
  )
  private let loginButton = UIButton(type: .system)
  private let form = TiebaFormListView()

  private var account: TiebaAccountProfile?
  private var profile: TiebaUserProfile?
  /// profile 所属 uid（切号后旧资料作废）。
  private var profileUid = ""
  private var isLoadingProfile = false

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemGroupedBackground
    buildCard()
    form.translatesAutoresizingMaskIntoConstraints = false
    form.onRowPress = { [weak self] id in self?.handleRowPress(id) }
    view.addSubview(form)
    NSLayoutConstraint.activate([
      form.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      form.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      form.topAnchor.constraint(equalTo: card.bottomAnchor, constant: 8),
      form.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    reload(force: true)
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    TiebaUserAPI.refreshLoginSnapshot()
    // 每次出现现读账号（登录/登出/切号后回来即最新）；资料只在需要时拉。
    reload(force: false)
  }

  /// 底栏重复点击：重拉资料。
  func tabReselected() {
    reload(force: true)
  }

  // MARK: - 卡片

  private func buildCard() {
    card.translatesAutoresizingMaskIntoConstraints = false
    card.layer.cornerRadius = 20
    card.layer.cornerCurve = .continuous
    card.clipsToBounds = true
    cardMaterial.translatesAutoresizingMaskIntoConstraints = false
    card.addSubview(cardMaterial)
    cardGradient.colors = [
      UIColor(red: 32 / 255, green: 138 / 255, blue: 239 / 255, alpha: 0.16).cgColor,
      UIColor(red: 32 / 255, green: 138 / 255, blue: 239 / 255, alpha: 0.04).cgColor,
    ]
    cardGradient.startPoint = CGPoint(x: 0.5, y: 0)
    cardGradient.endPoint = CGPoint(x: 0.5, y: 1)
    card.layer.addSublayer(cardGradient)

    let header = UIStackView(arrangedSubviews: [avatar, avatarPlaceholder, makeTextColumn()])
    header.axis = .horizontal
    header.alignment = .center
    header.spacing = 12
    avatarPlaceholder.translatesAutoresizingMaskIntoConstraints = false
    avatarPlaceholder.backgroundColor = .secondarySystemFill
    avatarPlaceholder.layer.cornerRadius = 32
    avatarPlaceholderIcon.image = UIImage(systemName: "person.crop.circle")
    avatarPlaceholderIcon.tintColor = .tertiaryLabel
    avatarPlaceholderIcon.contentMode = .center
    avatarPlaceholderIcon.translatesAutoresizingMaskIntoConstraints = false
    avatarPlaceholder.addSubview(avatarPlaceholderIcon)

    statsRow.isHidden = true
    statsRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true

    let content = UIStackView(arrangedSubviews: [header, statsRow, loginButton])
    content.axis = .vertical
    content.spacing = 12
    content.translatesAutoresizingMaskIntoConstraints = false
    card.addSubview(content)
    card.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(card)

    let tap = UITapGestureRecognizer(target: self, action: #selector(handleCardTap))
    card.addGestureRecognizer(tap)

    configureLoginButton()
    NSLayoutConstraint.activate([
      card.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
      card.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
      card.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
      cardMaterial.leadingAnchor.constraint(equalTo: card.leadingAnchor),
      cardMaterial.trailingAnchor.constraint(equalTo: card.trailingAnchor),
      cardMaterial.topAnchor.constraint(equalTo: card.topAnchor),
      cardMaterial.bottomAnchor.constraint(equalTo: card.bottomAnchor),
      content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
      content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
      content.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
      content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
      avatar.widthAnchor.constraint(equalToConstant: 64),
      avatar.heightAnchor.constraint(equalToConstant: 64),
      avatarPlaceholder.widthAnchor.constraint(equalToConstant: 64),
      avatarPlaceholder.heightAnchor.constraint(equalToConstant: 64),
      avatarPlaceholderIcon.centerXAnchor.constraint(equalTo: avatarPlaceholder.centerXAnchor),
      avatarPlaceholderIcon.centerYAnchor.constraint(equalTo: avatarPlaceholder.centerYAnchor),
    ])
  }

  private func makeTextColumn() -> UIView {
    nameLabel.font = UIFontMetrics(forTextStyle: .title3).scaledFont(for: .systemFont(ofSize: 20, weight: .semibold))
    nameLabel.adjustsFontForContentSizeCategory = true
    nameLabel.numberOfLines = 1
    introLabel.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .systemFont(ofSize: 13))
    introLabel.adjustsFontForContentSizeCategory = true
    introLabel.textColor = .secondaryLabel
    introLabel.numberOfLines = 2
    let column = UIStackView(arrangedSubviews: [nameLabel, introLabel])
    column.axis = .vertical
    column.spacing = 2
    return column
  }

  private func configureLoginButton() {
    var config = UIButton.Configuration.filled()
    config.title = "立即登录"
    config.image = UIImage(systemName: "person.crop.circle.badge.checkmark")
    config.imagePadding = 6
    config.cornerStyle = .capsule
    config.baseBackgroundColor = TiebaNavigator.shared.chromeTheme.tint
    config.baseForegroundColor = .white
    loginButton.configuration = config
    loginButton.addAction(UIAction { _ in
      TiebaSceneHaptics.fire("press")
      TiebaNavigator.shared.navigate(.login)
    }, for: .touchUpInside)
  }

  // MARK: - 数据

  private func reload(force: Bool) {
    let loggedIn = TiebaUserAPI.isLoggedIn
    account = loggedIn ? currentAccount() : nil
    // 切号/登出：旧账号资料立即作废（防卡片串号）。
    if profileUid != (account?.uid ?? "") {
      profile = nil
      profileUid = ""
    }
    applyAccount()
    let uid = (account?.uid).flatMap { $0.isEmpty ? nil : $0 } ?? TiebaUserAPI.uid
    guard loggedIn, !uid.isEmpty else {
      profile = nil
      profileUid = ""
      return
    }
    // 已有同一账号的资料且非强制刷新：只走本地（旧页只在挂载/重按时拉网络）。
    if !force, profile != nil, profileUid == uid { return }
    guard !isLoadingProfile else { return }
    isLoadingProfile = true
    Task { @MainActor in
      defer { isLoadingProfile = false }
      guard let result = try? await TiebaUserAPI.profile(uid: uid) else { return }
      // 账号已切换/登出：结果作废（防串号）。
      guard TiebaUserAPI.uid == uid else { return }
      profile = result
      profileUid = uid
      applyAccount()
    }
  }

  /// 账号来源合并（原 JS account 的字段来源序）：档案缓存（TiebaUserAPI，键与
  /// JS account_profile_cache_v1 同一份）优先，空字段回落账号元数据 KV
  ///（TiebaSession，与 JS @tiebalite:account:<uid> 同一份）。两者都缺时昵称才
  /// 会落固定文案——这也是老版本残留数据下"只显示贴吧用户"的根因。
  private func currentAccount() -> TiebaAccountProfile? {
    let uid = TiebaUserAPI.uid
    var merged = TiebaAccountProfile()
    // 档案缓存 uid 与快照不一致（切号窗口）＝缓存作废，不拿上一个账号的昵称。
    if let cached = TiebaUserAPI.cachedAccount(), uid.isEmpty || cached.uid == uid {
      merged = cached
    }
    // 只认快照 uid 的元数据（active_id 可能落后快照，切号窗口不串号）。
    let meta = uid.isEmpty ? TiebaSession.currentAccount() : TiebaSession.account(uid: uid)
    guard !merged.uid.isEmpty || meta != nil || !uid.isEmpty else { return nil }
    if merged.uid.isEmpty { merged.uid = meta?.uid ?? uid }
    if merged.name.isEmpty { merged.name = meta?.name ?? "" }
    if merged.nameShow.isEmpty { merged.nameShow = meta?.nameShow ?? "" }
    if merged.portrait.isEmpty { merged.portrait = meta?.portrait ?? "" }
    if merged.intro.isEmpty { merged.intro = meta?.intro ?? "" }
    if merged.fansNum == 0 { merged.fansNum = meta?.fansNum ?? 0 }
    if merged.concernNum == 0 { merged.concernNum = meta?.concernNum ?? 0 }
    if merged.postNum == 0 { merged.postNum = meta?.postNum ?? 0 }
    return merged
  }

  /// 第一个非空串（JS 的 `a || b` 语义，用于 nameShow/name/portrait/intro 链）。
  private static func firstNonEmpty(_ values: String?...) -> String? {
    for value in values {
      if let value, !value.isEmpty { return value }
    }
    return nil
  }

  private func applyAccount() {
    let loggedIn = TiebaUserAPI.isLoggedIn
    cardGradient.colors = [
      UIColor(red: 32 / 255, green: 138 / 255, blue: 239 / 255, alpha: loggedIn ? 0.16 : 0.10).cgColor,
      UIColor(red: 32 / 255, green: 138 / 255, blue: 239 / 255, alpha: 0.03).cgColor,
    ]
    avatar.isHidden = !loggedIn
    avatarPlaceholder.isHidden = loggedIn
    loginButton.isHidden = loggedIn
    statsRow.isHidden = !loggedIn
    if loggedIn {
      // 昵称链：资料 nameShow → 缓存 nameShow → 缓存 name →「贴吧用户」
      //（原 JS：account?.nameShow || account?.name || '贴吧用户'，资料回填优先）。
      let nameShow = Self.firstNonEmpty(profile?.nameShow, account?.nameShow)
      let name = Self.firstNonEmpty(nameShow, account?.name)
      let displayName = name ?? "贴吧用户"
      let portrait = Self.firstNonEmpty(profile?.portrait, account?.portrait) ?? ""
      avatar.configure(
        url: TiebaSimpleRowParser.avatarURL(portrait)?.absoluteString ?? "",
        initial: String((name ?? "吧").prefix(1))
      )
      nameLabel.text = displayName
      let intro = Self.firstNonEmpty(profile?.intro, account?.intro) ?? ""
      introLabel.text = intro.isEmpty ? nil : intro
      introLabel.isHidden = intro.isEmpty
      let values = [
        profile?.concernNum ?? account?.concernNum ?? 0,
        profile?.fansNum ?? account?.fansNum ?? 0,
        profile?.postNum ?? account?.postNum ?? 0,
      ]
      statsRow.setColumns(
        values: values.map { TiebaForumFormat.count(max($0, 0)) },
        labels: ["关注", "粉丝", "帖子"],
        valueColor: .label,
        labelColor: .secondaryLabel
      )
    } else {
      nameLabel.text = "登录百度账号"
      introLabel.text = "登录后查看个人信息、签到、收藏"
      introLabel.isHidden = false
    }
    form.tintHex = Self.formTintHex()
    form.isDark = TiebaNavigator.shared.chromeTheme.dark
    form.sections = buildSections(loggedIn: loggedIn)
    view.setNeedsLayout()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    cardGradient.frame = card.bounds
  }

  private static func formTintHex() -> String? {
    let dark = TiebaNavigator.shared.chromeTheme.dark
    let themeName = TiebaPreferenceSnapshot.string(dark ? "darkTheme" : "lightTheme") ?? "default"
    guard themeName != "default" else { return nil }
    return TiebaFormListView.hexString(from: TiebaNavigator.shared.chromeTheme.tint)
  }

  private func buildSections(loggedIn: Bool) -> [[String: Any]] {
    let uid = account?.uid ?? TiebaUserAPI.uid
    var contentRows: [[String: Any]] = []
    if loggedIn, !uid.isEmpty {
      contentRows += [
        ["id": "profile", "kind": "link", "title": "个人主页", "icon": "person", "iconTint": "#5856D6"],
        ["id": "threads", "kind": "link", "title": "我的帖子", "icon": "doc.text", "iconTint": "#FF9500"],
        ["id": "forums", "kind": "link", "title": "关注的吧", "icon": "square.grid.2x2", "iconTint": "#34C759"],
      ]
    }
    contentRows += [
      ["id": "history", "kind": "link", "title": "浏览历史", "icon": "clock", "iconTint": "#FF9500"],
      ["id": "threadstore", "kind": "link", "title": "我的收藏", "icon": "bookmark", "iconTint": "#FF3B30"],
    ]
    return [
      ["title": "我的内容", "rows": contentRows],
      [
        "title": "设置",
        "footerSpacer": 24,
        "rows": [
          ["id": "settings", "kind": "link", "title": "设置", "icon": "gearshape", "iconTint": "#8E8E93"],
          ["id": "about", "kind": "link", "title": "关于 贴吧Lite", "icon": "info.circle", "iconTint": "#5AC8FA"],
        ],
      ],
    ]
  }

  // MARK: - 动作

  @objc private func handleCardTap() {
    guard TiebaUserAPI.isLoggedIn else { return }
    TiebaSceneHaptics.fire("press")
    TiebaUserAPI.navigateToOwnProfile()
  }

  private func handleRowPress(_ id: String) {
    let uid = account?.uid ?? TiebaUserAPI.uid
    // 行 id → 类型化路由：原 "/user/<uid>?tab=xxx" 查询串改由 tab 领域值携带。
    let routes: [String: TiebaRoute] = [
      "profile": .user(uid: uid),
      "threads": .user(uid: uid, tab: "threads"),
      "forums": .user(uid: uid, tab: "forums"),
      "history": .history(),
      "threadstore": .threadstore,
      "settings": .settings,
      "about": .settingsAbout,
    ]
    guard let route = routes[id] else { return }
    TiebaSceneHaptics.fire("press")
    TiebaNavigator.shared.navigate(route)
  }
}
