// ============================================================
// TiebaMoreSettingsViewController —— 更多设置（原 src/app/settings/more.tsx）
// 确认弹窗由表单原生画（actionSheet）；「崩溃与卡顿日志」入口已删（数据源从未
// 编进 App）。⚠️「清除全部数据」清不掉 JS 会话内存态，JS 页面需重启才反映。
// ============================================================
import UIKit

final class TiebaMoreSettingsViewController: TiebaFormPageController {
  private static let pollOptions: [(value: String, label: String)] = [
    ("30", "每 30 分钟"), ("60", "每 60 分钟"), ("120", "每 120 分钟"),
  ]
  private static let autoCleanOptions: [(value: String, label: String)] = [
    ("0", "关闭"), ("1", "每 1 天"), ("3", "每 3 天"), ("7", "每 7 天"),
    ("15", "每 15 天"), ("30", "每 30 天"),
  ]
  private static let maxSizeOptions: [(value: String, label: String)] = [
    ("100", "100 MB"), ("200", "200 MB"), ("400", "400 MB"), ("1000", "1000 MB"),
  ]
  /// JS clearAllKvSync 点名保留的旧搬运标记；本仓的一次性标记统一由
  /// TiebaKvStore.internalMarkerKeys 提供（clear 内部已强制保留）。
  private static let migrationKey = "@tiebalite:unified_migration_v1"
  private static let legacyKvDatabase = "ExpoSQLiteStorage"
  private static let activeCredentialKeys = [
    "tiebalite.active.bduss", "tiebalite.active.stoken", "tiebalite.active.cookie",
    "tiebalite.active.tbs", "tiebalite.active.zid",
  ]

  /// 本页展示的三个偏好键（行 id 与键逐字同名；在屏时被别处改写要即时回推）。
  private static let preferenceKeys = [
    "notificationPollMinutes", "cacheAutoCleanDays", "cacheMaxSizeMb",
  ]

  /// 观察者是 non-Sendable，deinit 非隔离：与 TiebaHomeViewController 同款声明。
  private nonisolated(unsafe) var prefToken: NSObjectProtocol?

  deinit {
    if let prefToken { NotificationCenter.default.removeObserver(prefToken) }
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    // 在屏时被别处改写就就地回推行值（本页三个选择器数值都过白名单/数字字面量）。
    prefToken = TiebaPreferenceChange.observe(keys: Self.preferenceKeys) { [weak self] in
      self?.refreshDisplayedValues()
    }
  }

  /// 行 id 与偏好键同名，就地回推即可；本页行结构固定（confirm 行不随偏好增删）。
  private func refreshDisplayedValues() {
    form.setValue(
      id: "notificationPollMinutes",
      value: TiebaPreferences.string(
        "notificationPollMinutes", allowed: Self.pollOptions.map(\.value), default: "30"))
    form.setValue(
      id: "cacheAutoCleanDays",
      value: TiebaPreferences.numberLiteral(
        TiebaPreferences.number("cacheAutoCleanDays", default: 0)))
    form.setValue(
      id: "cacheMaxSizeMb",
      value: TiebaPreferences.numberLiteral(
        TiebaPreferences.number("cacheMaxSizeMb", default: 400)))
  }

  override func makeSections(dark: Bool) -> [[String: Any]] {
    let poll = TiebaPreferences.string(
      "notificationPollMinutes", allowed: Self.pollOptions.map(\.value), default: "30")
    let autoClean = TiebaPreferences.number("cacheAutoCleanDays", default: 0)
    let maxSize = TiebaPreferences.number("cacheMaxSizeMb", default: 400)

    return [
      [
        "title": "通知",
        "footer": "前台消息检查频率；低电量模式自动加倍，后台任务由系统统一调度。",
        "rows": [
          [
            "id": "notificationPollMinutes", "kind": "picker", "title": "消息检查频率",
            "value": poll, "options": options(Self.pollOptions),
          ]
        ],
      ],
      [
        "title": "数据",
        "rows": [
          [
            "id": "cacheAutoCleanDays", "kind": "picker", "title": "自动清理缓存",
            "value": TiebaPreferences.numberLiteral(autoClean),
            "options": options(Self.autoCleanOptions),
          ],
          [
            "id": "cacheMaxSizeMb", "kind": "picker", "title": "最大缓存大小",
            "value": TiebaPreferences.numberLiteral(maxSize),
            "options": options(Self.maxSizeOptions),
          ],
          [
            "id": "clearCache", "kind": "confirm", "title": "清除图片缓存", "icon": "trash.fill",
            "confirmTitle": "清除图片缓存",
            "confirmMessage": "图片与吧头像缓存将被清除（可在下次浏览时重新加载）；登录状态和应用设置不会被清除。",
            "confirmLabel": "确定清除",
          ],
          [
            "id": "resetAll", "kind": "confirm", "title": "重置所有设置", "icon": "arrow.counterclockwise",
            "confirmTitle": "重置所有设置",
            "confirmMessage": "这将恢复默认主题、偏好等，请重启应用以生效。",
            "confirmLabel": "确定重置",
          ],
          [
            "id": "clearAll", "kind": "confirm", "title": "清除全部数据", "icon": "trash.slash",
            "confirmTitle": "清除全部数据",
            "confirmMessage": "将清除登录状态、设置、历史、屏蔽数据与本地凭据，且不可恢复。",
            "confirmLabel": "确定清除",
          ],
        ],
      ],
      [
        "title": "更多",
        "footer": "系统应用设置可管理通知、权限与后台任务。",
        "rows": [
          [
            "id": "systemSettings", "kind": "button", "title": "系统应用设置",
            "icon": "gear", "color": "#007AFF",
          ]
        ],
      ],
    ]
  }

  // MARK: - 动作

  override func handle(_ event: TiebaFormEvent) {
    switch event {
    case .pick(let id, let value):
      handlePick(id, value)
    case .confirm(let id):
      handleConfirm(id)
    case .press(let id):
      guard id == "systemSettings" else { return }
      TiebaSceneHaptics.fire("press")
      guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
      UIApplication.shared.open(url)
    default:
      break
    }
  }

  private func handlePick(_ id: String, _ value: String) {
    switch id {
    case "notificationPollMinutes":
      guard let minutes = Double(value), Self.pollOptions.contains(where: { $0.value == value }) else { return }
      guard write("notificationPollMinutes", number: minutes) else { return }
      do {
        // 后台检查间隔重新登记（JS poller 的内存态不随之更新，原生登记先生效）。
        try TiebaBackgroundSync.shared.registerNotificationPoll(minutes: minutes)
        TiebaSceneHaptics.fire("toggle")
      } catch {
        // 偏好已落盘，只有 BGTask 登记失败：不静默（前台轮询注册时会按偏好重试）。
        TiebaSceneHaptics.fire("action-fail")
        TiebaToast.show("后台调度登记失败，稍后会自动重试", success: false)
      }
    case "cacheAutoCleanDays":
      guard let days = Double(value) else { return }
      guard write("cacheAutoCleanDays", number: days) else { return }
      TiebaSceneHaptics.fire("toggle")
    case "cacheMaxSizeMb":
      guard let mb = Double(value) else { return }
      guard write("cacheMaxSizeMb", number: mb) else { return }
      applyCacheLimit(mb: mb)
      TiebaSceneHaptics.fire("toggle")
    default:
      break
    }
  }

  private func handleConfirm(_ id: String) {
    switch id {
    case "clearCache":
      clearImageCache()
    case "resetAll":
      resetAllSettings()
    case "clearAll":
      clearAllData()
    default:
      break
    }
  }

  // MARK: - 缓存

  /// 内存 = 磁盘档位的 1/16，夹在 8–32MB（与旧 applyCacheMaxSize 同口径）。
  private func applyCacheLimit(mb: Double) {
    let bytes = Int(max(0, mb) * 1024 * 1024)
    tiebaNukeCacheLimits(diskBytes: bytes)
  }

  private func tiebaNukeCacheLimits(diskBytes: Int) {
    let memoryMB = min(32, max(8, Int(round(Double(diskBytes) / 1024 / 1024 / 16))))
    TiebaNuke.setCacheLimits(diskBytes: diskBytes, memoryBytes: memoryMB * 1024 * 1024)
  }

  private func clearImageCache() {
    TiebaSceneHaptics.fire("destructive")
    // Nuke 内存+磁盘（唯一图片缓存栈）；历史头像引用按缓存一并擦除（记录本身保留）。
    TiebaNuke.clearCaches()
    TiebaNuke.removeLegacyImageCacheDirectory()
    do {
      // 吧头像 URL 缓存（全站统一）：唯一手动清理入口。
      try TiebaKvStore.shared.set(key: "forum_avatars_v1", value: "{}")
      try clearHistoryPortraits()
    } catch {
      TiebaSceneHaptics.fire("action-fail")
      TiebaToast.show("缓存清理失败，请重试", success: false)
      return
    }
    TiebaSceneHaptics.fire("action-success")
  }

  private func clearHistoryPortraits() throws {
    let sql = """
      UPDATE visit_history SET author_portrait = '' WHERE type = 'thread';
      UPDATE visit_history SET avatar = '' WHERE type = 'forum';
      """
    try TiebaSQLite.shared.exec(database: TiebaSQLite.mainDatabase, sql: sql)
  }

  // MARK: - 重置 / 清除

  private func resetAllSettings() {
    TiebaSceneHaptics.fire("destructive")
    do {
      try TiebaPreferences.resetAll()
      try clearBlockedItems()
      try removeLegacyStorage()
      TiebaSceneHaptics.fire("action-success")
    } catch {
      TiebaSceneHaptics.fire("action-fail")
      TiebaToast.show("重置失败，请重试", success: false)
    }
    reload()
  }

  private func clearAllData() {
    TiebaSceneHaptics.fire("destructive")
    do {
      try TiebaPreferences.resetAll()
      // 全清 KV（账号列表/元数据/历史引用/屏蔽项/缓存），保留一次性迁移标记：
      // 删了标记会让旧 MMKV 在下次启动被重新灌回来、或重跑孤儿登录态清理。
      try TiebaKvStore.shared.clear(prefix: nil, preserveKeys: [Self.migrationKey])
      try TiebaSQLite.shared.exec(
        database: TiebaSQLite.mainDatabase,
        sql: "DELETE FROM search_history; DELETE FROM visit_history;"
      )
      clearSecureCredentials()
      TiebaBackgroundSnapshot.shared.clear()
      TiebaBackgroundSync.shared.cancelAll()
      TiebaNuke.clearCaches()
      TiebaNuke.removeLegacyImageCacheDirectory()
      TiebaNavigator.shared.setTabBadge(index: 2, text: "")
      TiebaSceneHaptics.fire("action-success")
    } catch {
      TiebaSceneHaptics.fire("action-fail")
      TiebaToast.show("清除失败，请重试", success: false)
    }
    reload()
  }

  /// 删除屏蔽词/用户（含旧版聚合键）：与 JS BlockManager.clearAllBlocked 同范围。
  private func clearBlockedItems() throws {
    let prefixes = ["@tiebalite:blocked_word:", "@tiebalite:blocked_user:"]
    let legacyKeys = ["@tiebalite:blocked_words", "@tiebalite:blocked_users"]
    let keys = TiebaKvStore.shared.allKeys().filter { key in
      legacyKeys.contains(key) || prefixes.contains { key.hasPrefix($0) }
    }
    guard !keys.isEmpty else { return }
    try TiebaKvStore.shared.batchWrite(keys.map { (key: $0, value: nil) })
  }

  private func removeLegacyStorage() throws {
    guard TiebaSQLite.shared.databaseExists(named: Self.legacyKvDatabase) else { return }
    try TiebaSQLite.shared.deleteDatabase(named: Self.legacyKvDatabase)
  }

  /// 活跃凭据 + 账内凭据（AuthSecureStorage 的 Keychain 布局）。
  private func clearSecureCredentials() {
    var uids: [String] = []
    if let raw = TiebaKvStore.shared.get(key: "@tiebalite:account_list"),
      let data = raw.data(using: .utf8),
      let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    {
      uids = list.compactMap { $0["uid"] as? String }
    }
    for key in Self.activeCredentialKeys {
      TiebaKeychain.delete(key: key)
    }
    for uid in uids {
      for field in ["bduss", "stoken", "cookie", "tbs", "zid"] {
        TiebaKeychain.delete(key: "tiebalite.account.\(uid).\(field)")
      }
    }
  }
}
