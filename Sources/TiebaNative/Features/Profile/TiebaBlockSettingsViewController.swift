import UIKit

/// 屏蔽设置（原 src/app/settings/block.tsx）：分段 = 屏蔽词 / 屏蔽用户 / 黑名单 / 屏蔽吧。
///
/// 本地屏蔽项读写原生 KV（TiebaBlockStore，与 JS BlockManager 同一份存储）；
/// 云端黑名单/屏蔽吧走 TiebaSocialAPI。⚠️ JS 侧的屏蔽过滤缓存只认 JS 自己写入的
/// 变更（blockEvents），原生写入不会让它失效——本页增删在 JS 消费者删除前对
/// JS 渲染的列表要到下次启动才生效（迁移报告已点名）。
final class TiebaBlockSettingsViewController: TiebaFormPageController {
  private enum Tab: String, CaseIterable {
    case keyword
    case user
    case blacklist
    case forums

    var label: String {
      switch self {
      case .keyword: return "屏蔽词"
      case .user: return "屏蔽用户"
      case .blacklist: return "黑名单"
      case .forums: return "屏蔽吧"
      }
    }
  }

  private enum LoadState {
    case loading
    case loaded
    case failed
  }

  private var activeTab: Tab = .keyword
  private var words: [TiebaBlockedWord] = []
  private var users: [TiebaBlockedUser] = []
  private var input = ""
  private var isRegex = false
  private var isWhitelist = false
  private var blacklist: [TiebaSocialAPI.BlacklistUser] = []
  private var blacklistState: LoadState = .loading
  private var removingUid: String?
  private var dislikeForums: [TiebaSocialAPI.DislikeForum] = []
  private var dislikeState: LoadState = .loading

  /// 本页跟导航壳主题（不是偏好直读），并取壳主题色。
  override var formIsDark: Bool { TiebaNavigator.shared.chromeTheme.dark }
  override var formTintHex: String? {
    let themeName = TiebaPreferenceSnapshot.string(formIsDark ? "darkTheme" : "lightTheme") ?? "default"
    guard themeName != "default" else { return nil }
    return TiebaFormListView.hexString(from: TiebaNavigator.shared.chromeTheme.tint)
  }

  override func viewDidLoad() {
    // 基类 viewDidLoad 末尾会 reload()：本地数据先就绪，避免首帧空表再刷一次。
    words = TiebaBlockStore.words()
    users = TiebaBlockStore.users()
    super.viewDidLoad()
    loadBlacklist()
    loadDislikeForums()
  }

  // MARK: - 行模型

  override func makeSections(dark: Bool) -> [[String: Any]] {
    var sections: [[String: Any]] = [[
      "rows": [[
        "id": "tab",
        "kind": "segmented",
        "value": activeTab.rawValue,
        "options": Tab.allCases.map { ["value": $0.rawValue, "label": $0.label] },
      ]]
    ]]
    switch activeTab {
    case .keyword, .user:
      sections.append(addSection())
      sections.append(localSection())
    case .blacklist:
      sections.append([
        "title": "云端黑名单",
        "footer": "由贴吧服务端维护的社交黑名单，与本地屏蔽相互独立。",
        "rows": blacklistRows(),
      ])
    case .forums:
      sections.append([
        "title": "屏蔽吧（云端）",
        "footer": "由贴吧服务端记录，解除请在贴吧客户端中操作。",
        "rows": dislikeRows(),
      ])
    }
    return sections
  }

  private func addSection() -> [String: Any] {
    var rows: [[String: Any]] = [[
      "id": "input",
      "kind": "textField",
      "placeholder": activeTab == .keyword ? "输入屏蔽关键词" : "输入用户ID",
      "value": input,
    ]]
    if activeTab == .keyword {
      rows.append(["id": "regex", "kind": "toggle", "title": "使用正则表达式", "value": isRegex ? "1" : "0"])
      rows.append(["id": "whitelist", "kind": "toggle", "title": "设为白名单", "value": isWhitelist ? "1" : "0"])
    }
    rows.append(["id": "add", "kind": "button", "title": "添加", "icon": "plus.circle.fill"])
    return ["title": activeTab == .keyword ? "添加屏蔽词" : "添加屏蔽用户", "rows": rows]
  }

  /// 本地屏蔽项：menu 行（副标题显示 正则/白名单）+ 行尾 ellipsis 删除菜单；
  /// 点行本体与旧版一致弹「移除屏蔽项」确认框。
  private func localSection() -> [String: Any] {
    var rows: [[String: Any]]
    if activeTab == .keyword {
      rows = words.map { word in
        var subtitle = word.isRegex == true ? "正则" : ""
        if word.isWhitelist { subtitle += "白名单" }
        return [
          "id": "word:\(word.id)",
          "kind": "menu",
          "title": word.keyword,
          "subtitle": subtitle,
          "menuItems": [["id": "delete", "title": "删除", "destructive": true]],
        ]
      }
    } else {
      rows = users.map { user in
        [
          "id": "user:\(user.uid)",
          "kind": "menu",
          "title": user.username ?? user.uid,
          "menuItems": [["id": "delete", "title": "删除", "destructive": true]],
        ]
      }
    }
    if rows.isEmpty { rows = [["id": "empty", "kind": "text", "title": "暂无屏蔽项"]] }
    let title = activeTab == .keyword ? "屏蔽词列表 (\(words.count))" : "屏蔽用户 (\(users.count))"
    return ["title": title, "rows": rows]
  }

  private func blacklistRows() -> [[String: Any]] {
    switch blacklistState {
    case .loading:
      return [["id": "loading", "kind": "spinner"]]
    case .failed:
      return errorRows("云端黑名单加载失败", retry: "retryBlacklist")
    case .loaded:
      if blacklist.isEmpty {
        return [[
          "id": "emptyBlacklist",
          "kind": "empty",
          "icon": "person.crop.circle.badge.xmark",
          "title": "暂无云端黑名单",
          "subtitle": "你还没有在贴吧服务端拉黑过用户",
        ]]
      }
      return blacklist.map { user in
        [
          "id": "blacklist:\(user.uid)",
          "kind": "avatar",
          "avatarURL": user.portrait,
          "initials": String(user.displayName.prefix(1)),
          "title": user.displayName,
          "subtitle": blacklistDetail(user),
          "trailingStyle": "button",
          "trailingIcon": "minus.circle.fill",
          "trailingColor": "systemRed",
          "trailingBusy": removingUid == user.uid,
          "trailingDisabled": removingUid != nil,
        ]
      }
    }
  }

  private func dislikeRows() -> [[String: Any]] {
    switch dislikeState {
    case .loading:
      return [["id": "loading", "kind": "spinner"]]
    case .failed:
      return errorRows("屏蔽吧列表加载失败", retry: "retryDislike")
    case .loaded:
      if dislikeForums.isEmpty {
        return [[
          "id": "emptyDislike",
          "kind": "empty",
          "icon": "hand.raised.fill",
          "title": "暂无屏蔽吧",
          "subtitle": "未发现被屏蔽的贴吧",
        ]]
      }
      return dislikeForums.map { forum in
        [
          "id": "dislike:\(forum.fid)",
          "kind": "avatar",
          "initials": String(forum.fname.prefix(1)),
          "title": forum.fname,
          "subtitle": "\(TiebaForumFormat.count(forum.memberNum)) 成员 · \(TiebaForumFormat.count(forum.postNum)) 帖子",
          "trailingStyle": "text",
          "trailingTitle": "需在贴吧客户端解除",
        ]
      }
    }
  }

  private func errorRows(_ text: String, retry: String) -> [[String: Any]] {
    [
      ["id": "\(retry)Text", "kind": "text", "textStyle": "subheadline", "color": "secondaryLabel", "title": text],
      ["id": retry, "kind": "button", "title": "重试", "icon": "arrow.clockwise"],
    ]
  }

  private func blacklistDetail(_ user: TiebaSocialAPI.BlacklistUser) -> String {
    var base = (!user.userName.isEmpty && !user.nickName.isEmpty) ? "@\(user.userName)" : "UID \(user.uid)"
    let type = Self.blacklistTypeLabel(user.btype)
    if !type.isEmpty { base += " · \(type)" }
    return base
  }

  /// 原 blacklistTypeLabel：btype 位串 → 中文标签。
  private static func blacklistTypeLabel(_ btype: String) -> String {
    let map = ["FOLLOW": "禁关注", "INTERACT": "禁互动", "CHAT": "禁聊天"]
    return btype.split(separator: ",").map { map[String($0)] ?? String($0) }.joined(separator: "/")
  }

  // MARK: - 动作

  override func handle(_ event: TiebaFormEvent) {
    switch event {
    case .press(let id):
      handleRowPress(id)
    case .toggle(let id, let value):
      handleToggle(id, value)
    case .pick(let id, let value):
      handlePick(id, value)
    case .text(_, let value):
      input = value
    default:
      break
    }
  }

  private func handlePick(_ id: String, _ value: String) {
    if id == "tab", let next = Tab(rawValue: value) {
      TiebaSceneHaptics.fire("toggle")
      activeTab = next
      input = ""
      isRegex = false
      isWhitelist = false
      view.endEditing(true)
      reload()
      return
    }
    // 行尾 ellipsis 菜单的删除项（menu 行）
    if value == "delete", id.hasPrefix("word:") || id.hasPrefix("user:") {
      promptRemoveLocal(id)
    }
  }

  /// 两个开关是页面内状态（不是偏好键）：就地回推，不整表重建。
  private func handleToggle(_ id: String, _ value: Bool) {
    TiebaSceneHaptics.fire("toggle")
    if id == "regex" { isRegex = value }
    if id == "whitelist" { isWhitelist = value }
    form.setValue(id: id, value: value ? "1" : "0")
  }

  private func handleRowPress(_ id: String) {
    switch id {
    case "add":
      add()
    case "retryBlacklist":
      TiebaSceneHaptics.fire("press")
      loadBlacklist()
    case "retryDislike":
      TiebaSceneHaptics.fire("press")
      loadDislikeForums()
    default:
      if id.hasPrefix("blacklist:") {
        promptRemoveBlacklist(uid: String(id.dropFirst("blacklist:".count)))
      } else if id.hasPrefix("word:") || id.hasPrefix("user:") {
        promptRemoveLocal(id)
      }
    }
  }

  private func add() {
    let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty else { return }
    if activeTab == .keyword {
      if isRegex, (try? NSRegularExpression(pattern: raw)) == nil {
        presentAlert("正则表达式无效", "请输入有效的正则表达式")
        return
      }
      let word = TiebaBlockedWord(
        id: Self.timestampId(),
        keyword: raw,
        isRegex: isRegex,
        category: isWhitelist ? "whitelist" : "blacklist"
      )
      do {
        try TiebaBlockStore.add(word: word)
      } catch {
        TiebaSceneHaptics.fire("action-fail")
        presentAlert("添加失败", message(for: error))
        return
      }
      words.append(word)
    } else {
      let user = TiebaBlockedUser(id: Self.timestampId(), uid: raw)
      do {
        try TiebaBlockStore.add(user: user)
      } catch {
        TiebaSceneHaptics.fire("action-fail")
        presentAlert("添加失败", message(for: error))
        return
      }
      if !users.contains(where: { $0.uid == raw }) { users.append(user) }
    }
    input = ""
    isRegex = false
    isWhitelist = false
    TiebaSceneHaptics.fire("action-success")
    // 受控输入行只在非第一响应者时写回（TiebaFormListView 的既有约束）：
    // 先收键盘，重置后的空值才会落到输入框。
    view.endEditing(true)
    reload()
  }

  /// 旧版 ConfirmationDialog：标题「移除屏蔽项」+「确定要移除此屏蔽项吗？」+
  /// 删除（destructive）/取消。
  private func promptRemoveLocal(_ id: String) {
    let alert = UIAlertController(title: "移除屏蔽项", message: "确定要移除此屏蔽项吗？", preferredStyle: .actionSheet)
    alert.addAction(UIAlertAction(title: "取消", style: .cancel))
    alert.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
      self?.removeLocal(id)
    })
    presentActionSheet(alert)
  }

  private func removeLocal(_ id: String) {
    let isWord = id.hasPrefix("word:")
    let target = String(id.dropFirst(isWord ? "word:".count : "user:".count))
    do {
      if isWord {
        try TiebaBlockStore.removeWord(id: target)
        words.removeAll { $0.id == target }
      } else {
        try TiebaBlockStore.removeUser(uid: target)
        users.removeAll { $0.uid == target }
      }
      TiebaSceneHaptics.fire("action-success")
      reload()
    } catch {
      TiebaSceneHaptics.fire("action-fail")
      presentAlert("删除失败", message(for: error))
    }
  }

  private func promptRemoveBlacklist(uid: String) {
    guard let user = blacklist.first(where: { $0.uid == uid }) else { return }
    let alert = UIAlertController(
      title: "解除云端黑名单",
      message: "确定要解除对「\(user.displayName)」的黑名单吗？",
      preferredStyle: .actionSheet
    )
    alert.addAction(UIAlertAction(title: "取消", style: .cancel))
    alert.addAction(UIAlertAction(title: "解除", style: .destructive) { [weak self] _ in
      self?.removeBlacklist(uid)
    })
    presentActionSheet(alert)
  }

  /// iPad 上 actionSheet 必须有 popover 锚点（缺失会崩）。
  private func presentActionSheet(_ alert: UIAlertController) {
    if let popover = alert.popoverPresentationController {
      popover.sourceView = view
      popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
    }
    present(alert, animated: true)
  }

  private func removeBlacklist(_ uid: String) {
    TiebaSceneHaptics.fire("destructive")
    removingUid = uid
    reload()
    Task { @MainActor in
      do {
        try await TiebaSocialAPI.removeBlacklist(uid: uid)
        blacklist.removeAll { $0.uid == uid }
        TiebaSceneHaptics.fire("action-success")
      } catch {
        TiebaSceneHaptics.fire("action-fail")
        presentAlert("解除失败", message(for: error))
      }
      removingUid = nil
      reload()
    }
  }

  // MARK: - 数据

  private func loadBlacklist() {
    blacklistState = .loading
    reload()
    Task { @MainActor in
      do {
        blacklist = try await TiebaSocialAPI.blacklist()
        blacklistState = .loaded
      } catch {
        blacklistState = .failed
      }
      reload()
    }
  }

  private func loadDislikeForums() {
    dislikeState = .loading
    reload()
    Task { @MainActor in
      do {
        dislikeForums = try await TiebaSocialAPI.dislikeForums(pn: 1, rn: 50)
        dislikeState = .loaded
      } catch {
        dislikeState = .failed
      }
      reload()
    }
  }

  // MARK: - 工具

  private func presentAlert(_ title: String, _ message: String) {
    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "确定", style: .default))
    present(alert, animated: true)
  }

  /// 旧文案约定：无服务端/本地错误描述时用「网络错误，请稍后重试」。
  private func message(for error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? "网络错误，请稍后重试"
  }

  /// 原 id: Date.now().toString()
  private static func timestampId() -> String {
    String(Int(Date().timeIntervalSince1970 * 1000))
  }
}
