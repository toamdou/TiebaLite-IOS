// TiebaThreadViewController 的第二片（由 TiebaThreadViewController.swift 拆出，逐字搬运；成员跨文件可见性只在确实被引用的那一处放宽）。

import UIKit

extension TiebaThreadViewController {
  func forumBarItems() -> [UIBarButtonItem]? {
    // 数据没落地时用快照（点卡片进帖必写）：否则首包前右侧是空的，首包一到吧按钮
    // 才"突然"出现（用户实证）。深链无快照时仍等首包。
    let forumName = thread?.forumName ?? knownSnapshot?.forumName ?? ""
    guard !forumName.isEmpty else { return nil }
    let label = "进入\(forumName)吧"
    let avatar = thread?.forumAvatar ?? knownSnapshot?.forumAvatarURL?.absoluteString ?? ""
    guard !avatar.isEmpty, let url = URL(string: avatar) else {
      // 缺吧头像：退化成通用头像符号（与原 headerRight 的 symbolItem 分支同语义）。
      let item = UIBarButtonItem(
        image: UIImage(systemName: "person.crop.circle"),
        style: .plain,
        target: nil,
        action: nil
      )
      item.accessibilityLabel = label
      item.primaryAction = UIAction { [weak self] _ in self?.openForum() }
      item.tintColor = TiebaChromeTheme.current.navTint
      return [item]
    }
    let item = TiebaThreadForumAvatarItem(frame: CGRect(x: 0, y: 0, width: 30, height: 30))
    let button = item.button
    button.accessibilityLabel = label
    button.load(url: url)
    button.onTap = { [weak self] in self?.openForum() }
    return [UIBarButtonItem(customView: item)]
  }

  private func openForum() {
    let name = thread?.forumName ?? knownSnapshot?.forumName ?? ""
    guard !name.isEmpty else { return }
    TiebaSceneHaptics.fire("press")
    TiebaNavigator.shared.navigate(.forum(name: name, forumId: thread?.forumId ?? ""))
  }

  // MARK: - 浏览记录 / 收藏图片快照（原生 KV / SQLite，与 JS 同一份存储）

  func recordVisitIfNeeded() {
    guard !recordedVisit, let thread, !thread.id.isEmpty else { return }
    guard !TiebaPreferenceSnapshot.bool("incognitoMode", default: false) else { return }
    recordedVisit = true
    let now = Int(Date().timeIntervalSince1970 * 1000)
    let values: [[String: Any]] = [
      ["v": "thread"], ["v": thread.id], ["v": thread.forumId],
      ["v": thread.forumName], ["v": ""], ["v": thread.title],
      ["v": thread.authorName], ["v": thread.authorPortrait], ["v": now],
    ]
    Task.detached(priority: .utility) {
      let database = TiebaSQLite.mainDatabase
      _ = try? TiebaSQLite.shared.run(
        database: database,
        sql: "DELETE FROM visit_history WHERE type = ? AND thread_id = ?",
        params: [["v": "thread"], ["v": thread.id]]
      )
      _ = try? TiebaSQLite.shared.run(
        database: database,
        sql: """
          INSERT INTO visit_history (
            type, thread_id, forum_id, forum_name, avatar, title, author_name, author_portrait, timestamp
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
          """,
        params: values
      )
      _ = try? TiebaSQLite.shared.run(
        database: database,
        sql: """
          DELETE FROM visit_history WHERE id NOT IN (
            SELECT id FROM visit_history ORDER BY timestamp DESC, id DESC LIMIT ?
          )
          """,
        params: [["v": 200]]
      )
    }
  }

  private static let favoriteImagesKey = "@tiebalite:favorite_images_v1"

  func saveFavoriteImages(threadId: String) {
    let images = (mainPost?.images ?? [])
      .map { $0.src.isEmpty ? $0.originSrc : $0.src }
      .filter { !$0.isEmpty }
      .prefix(6)
    guard !images.isEmpty else { return }
    var map = favoriteImagesMap()
    map[threadId] = Array(images)
    if map.count > 200 {
      for key in map.keys.prefix(map.count - 200) { map.removeValue(forKey: key) }
    }
    guard let data = try? JSONSerialization.data(withJSONObject: map),
          let text = String(data: data, encoding: .utf8) else { return }
    try? TiebaKvStore.shared.set(key: Self.favoriteImagesKey, value: text)
  }

  func removeFavoriteImages(threadId: String) {
    var map = favoriteImagesMap()
    guard map[threadId] != nil else { return }
    map.removeValue(forKey: threadId)
    guard let data = try? JSONSerialization.data(withJSONObject: map),
          let text = String(data: data, encoding: .utf8) else { return }
    try? TiebaKvStore.shared.set(key: Self.favoriteImagesKey, value: text)
  }

  private func favoriteImagesMap() -> [String: [String]] {
    guard let raw = TiebaKvStore.shared.get(key: Self.favoriteImagesKey),
          let data = raw.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: [String]]
    else { return [:] }
    return object
  }
}

// MARK: - 顶栏吧头像（方形外壳：customView 被系统按条形拉伸时头像也不会变胶囊）

/// TiebaBarAvatarButton 的圆角按 init 尺寸（30/2）一次算好，栏内 customView 在
/// iOS 26 会被拉伸（宽 > 高）→ 圆角 15 < 宽/2 即药丸。外壳自己可被拉伸，但把按钮
/// 恒钉在 30×30 正方里，头像永远是正圆。
private final class TiebaThreadForumAvatarItem: UIView {
  let button = TiebaBarAvatarButton(frame: CGRect(x: 0, y: 0, width: 30, height: 30))

  override init(frame: CGRect) {
    super.init(frame: frame)
    addSubview(button)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override var intrinsicContentSize: CGSize { CGSize(width: 30, height: 30) }

  override func layoutSubviews() {
    super.layoutSubviews()
    let side: CGFloat = 30
    button.frame = CGRect(
      x: (bounds.width - side) / 2,
      y: (bounds.height - side) / 2,
      width: side,
      height: side
    )
  }
}

// MARK: - 底部浮动胶囊（原 ThreadFloatingBar：复制链接 / 帖点赞 / 收藏 / 更多）

final class TiebaThreadFloatingBar: UIView {
  enum Action {
    case copyLink
    case agree
    case collect
    case more
  }

  var onAction: ((Action) -> Void)?

  /// 浮动栏底色：纯色卡片色 + 一点阴影（原 JS 的液态玻璃 .clear 太花，用户要求
  /// 照系统浮动条的观感来：实底、轻微投影）。
  private let background = UIView()
  private let copyButton = TiebaThreadFloatingBar.makeButton("link")
  // 点赞图标与计数分开摆（计数在图标正上方，不再画进按钮里当角标）。
  private let agreeButton = TiebaThreadFloatingBar.makeButton(nil)
  private let agreeIcon = UIImageView()
  private let agreeCount = UILabel()
  private let collectButton = TiebaThreadFloatingBar.makeButton("star")
  private let moreButton = TiebaThreadFloatingBar.makeButton("ellipsis")
  private let buttonStack = UIStackView()
  private var palette: TiebaFeedRowPalette = .default

  private var barHidden = false
  /// 滚动方向门：累积 ΔY > 14pt 才翻转（上游 ListView.swift:1023-1029），见 TiebaScrollDirectionGate。
  private var scrollDirectionGate = TiebaScrollDirectionGate()

  override init(frame: CGRect) {
    super.init(frame: frame)
    // 不自裁：投影画在本层，圆角由 background 自己裁（子视图都在界内）。
    clipsToBounds = false
    layer.cornerRadius = 27
    layer.cornerCurve = .continuous
    layer.shadowColor = UIColor.black.cgColor
    layer.shadowOpacity = 0.10
    layer.shadowRadius = 8
    layer.shadowOffset = CGSize(width: 0, height: 2)
    background.layer.cornerRadius = 27
    background.layer.cornerCurve = .continuous
    background.clipsToBounds = true
    addSubview(background)
    // 四个按钮等宽排布（原手摆 frame 的等价）：fillEqually 的槽心 = 原 itemWidth 槽心，
    // 高度锁 44 后垂直居中，图标位置与手摆完全一致。
    buttonStack.axis = .horizontal
    buttonStack.distribution = .fillEqually
    buttonStack.alignment = .center
    for button in [copyButton, agreeButton, collectButton, moreButton] {
      button.heightAnchor.constraint(equalToConstant: 44).isActive = true
      buttonStack.addArrangedSubview(button)
    }
    addSubview(buttonStack)
    agreeIcon.contentMode = .scaleAspectFit
    agreeIcon.isUserInteractionEnabled = false
    addSubview(agreeIcon)
    // 帖子详情的点赞数（正文级）：等宽数字保留，字号随正文字号走。
    agreeCount.font = TiebaFont.with(
      size: 11 * TiebaTypography.bodyScale(), weight: .semibold, traits: .monospacedNumbers)
    agreeCount.textAlignment = .center
    agreeCount.isUserInteractionEnabled = false
    addSubview(agreeCount)
    copyButton.addTarget(self, action: #selector(handleCopy), for: .touchUpInside)
    agreeButton.addTarget(self, action: #selector(handleAgree), for: .touchUpInside)
    collectButton.addTarget(self, action: #selector(handleCollect), for: .touchUpInside)
    moreButton.addTarget(self, action: #selector(handleMore), for: .touchUpInside)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  func configure(hasAgree: Bool, zanNum: Int, isCollected: Bool, palette: TiebaFeedRowPalette) {
    self.palette = palette
    background.backgroundColor = palette.card
    agreeIcon.image = UIImage(
      systemName: hasAgree ? "heart.fill" : "heart",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)
    )
    agreeIcon.tintColor = hasAgree ? palette.liked : palette.text
    collectButton.setImage(UIImage(systemName: isCollected ? "star.fill" : "star"), for: .normal)
    collectButton.tintColor = isCollected ? UIColor.systemYellow : palette.text
    copyButton.tintColor = palette.text
    moreButton.tintColor = palette.text
    agreeCount.text = zanNum > 0 ? TiebaForumFormat.count(zanNum) : ""
    agreeCount.textColor = hasAgree ? palette.liked : palette.textSecondary
    setNeedsLayout()
  }

  /// 滚动自动隐藏（原 useFloatingBarAutoHide 的上下阈值 ±0.3）。
  ///
  /// ⚠️ 方向按**手指**判，而 pan 手势的 velocity 与 contentOffset 增量符号相反：
  /// 手指上滑（翻看后面的楼）⇒ velocity.y < 0，此时收起；手指下滑（往回翻）⇒
  /// velocity.y > 0，此时露出。旧 JS 判的是 contentOffset 增量（上滑为正），
  /// 原生照抄阈值时用了 pan 速度却没翻符号，方向正好是反的（2026-09-17 修）。
  ///
  /// [按上游改判据] 改前是**瞬时 pan 速度 ±0.3pt/s** —— 0.3pt/s 等于"凡动必判"，
  /// 手指抖一下浮条就翻一次（0.3 这个数只起了"非零"的作用）。
  /// 改后走上游的**累积位移**判据：带符号 ΔY 累加，越过 14.0pt 才翻方向
  ///（submodules/Display/Source/ListView.swift:1023-1029，见 TiebaScrollDirectionGate）。
  /// 手感变化：显隐**更稳、更可预期** —— 轻轻抖不再切换；真的要往下看/往回翻时才收放，
  /// 且同方向连读滚动只翻转一次（累加清零），不再每帧重判。
  func handleScroll(_ scrollView: UIScrollView) {
    let y = scrollView.contentOffset.y
    let threshold = max(scrollView.adjustedContentInset.top, 0) + 10
    if y < threshold {
      if barHidden { setBarHidden(false) }
      // 回顶 = 位置被外力重置，累加量作废（否则回顶那一大段位移会被算成一次翻转）。
      scrollDirectionGate.reset()
      return
    }
    guard let direction = scrollDirectionGate.update(contentOffsetY: y) else { return }
    switch direction {
    case .forward:
      if !barHidden { setBarHidden(true) }
    case .backward:
      if barHidden { setBarHidden(false) }
    }
  }

  private func setBarHidden(_ value: Bool) {
    barHidden = value
    let offset: CGFloat = value ? 120 : 0
    if UIAccessibility.isReduceMotionEnabled {
      transform = CGAffineTransform(translationX: 0, y: offset)
      return
    }
    UIView.animate(
      withDuration: value ? 0.18 : 0.22,
      delay: 0,
      options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction]
    ) {
      self.transform = CGAffineTransform(translationX: 0, y: offset)
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    background.frame = bounds
    // 投影轮廓按实际尺寸给（没有它 Core Animation 每帧从图层内容算轮廓）。
    layer.shadowPath = UIBezierPath(
      roundedRect: bounds,
      cornerRadius: layer.cornerRadius
    ).cgPath
    // 先让 stack 落位：下面 layoutAgreeContent 读的是 agreeButton.frame（箭头/计数）。
    buttonStack.frame = bounds
    buttonStack.layoutIfNeeded()
    layoutAgreeContent()
  }

  /// 点赞计数绝对定位在图标正上方；图标**恒钉按钮垂直中心**。
  /// 改前症状：计数+图标整组垂直居中 ⇒ 计数从无到有使组高变化，心形图标被往下推约 7.5pt
  ///（首楼点赞 0→1 的瞬间像误触抖动）。
  /// 改后行为：图标位置与计数有无无关（与同排其它三键一致），计数固定在图标上方 2pt，只做显隐。
  private func layoutAgreeContent() {
    let iconSide: CGFloat = 20
    let hasCount = !(agreeCount.text ?? "").isEmpty
    agreeIcon.frame = CGRect(
      x: agreeButton.frame.midX - iconSide / 2,
      y: agreeButton.frame.midY - iconSide / 2,
      width: iconSide,
      height: iconSide
    ).integral
    agreeCount.isHidden = !hasCount
    if hasCount {
      agreeCount.sizeToFit()
      let countHeight = ceil(agreeCount.font.lineHeight)
      let width = ceil(agreeCount.bounds.width) + 2
      agreeCount.frame = CGRect(
        x: agreeButton.frame.midX - width / 2,
        y: agreeIcon.frame.minY - 2 - countHeight,
        width: width,
        height: countHeight
      )
    }
  }

  @objc private func handleCopy() { onAction?(.copyLink) }
  @objc private func handleAgree() { onAction?(.agree) }
  @objc private func handleCollect() { onAction?(.collect) }
  @objc private func handleMore() { onAction?(.more) }

  private static func makeButton(_ symbol: String?) -> UIButton {
    let button = UIButton(type: .system)
    if let symbol {
      button.setImage(
        UIImage(
          systemName: symbol,
          withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        ),
        for: .normal
      )
    }
    return button
  }
}

