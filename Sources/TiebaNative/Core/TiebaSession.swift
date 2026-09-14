// 原生会话层：替 JS 的 authStore / AuthService / AuthSQLiteStorage / AuthSecureStorage
// 的登录态面（login / logout / 切号 / 删号 / tbs 续期 / 账号列表）。
//
// ⚠️ 落盘必须与 JS 逐字节兼容（否则已登录用户会"掉登录"）：
//   - Keychain：tiebalite.account.<uid>.{bduss,stoken,cookie,tbs,zid} 与
//     tiebalite.active.{bduss,stoken,cookie,tbs,zid}（TiebaKeychain 的键布局）；
//   - KV（SQLite）：@tiebalite:{active_id,account_list,account:<uid>,current_meta}，
//     账号 JSON 与 JS redact(account) 同形（无凭据字段）。
import Foundation
import os

private let sessionLog = Logger(subsystem: "com.tiebalite.app", category: "session")

struct TiebaAccount {
  var uid = ""
  var name = ""
  var nameShow = ""
  var portrait = ""
  var tbs = ""
  var bduss = ""
  var sToken = ""
  var cookie = ""
  var zid = ""
  var intro = ""
  var fansNum = 0
  var concernNum = 0
  var postNum = 0

  var displayName: String {
    let show = nameShow.isEmpty ? name : nameShow
    return show.isEmpty ? "贴吧用户" : show
  }

  var initials: String { String(displayName.prefix(1)) }
}

enum TiebaSessionError: LocalizedError {
  case cookieClearFailed
  case missingCredentials
  case missingBduss
  case missingTbs
  /// 登录态落盘失败（Keychain / KV 写失败）。必须让 activate 整体失败——写丢了
  /// 凭据却报"登录成功"，重启就是掉线（111）。
  case persistFailed(String)

  var errorDescription: String? {
    switch self {
    case .cookieClearFailed: return "清除原生 Cookie 失败，请重试"
    case .missingCredentials: return "该账号缺少登录凭据，请重新登录"
    case .missingBduss: return "缺少 BDUSS，无法完成登录"
    case .missingTbs: return "缺少 tbs，无法执行此操作，请刷新页面后重试"
    case .persistFailed: return "登录状态保存失败，请重试"
    }
  }
}

enum TiebaSession {
  /// 登录态变化（登录/切号/登出/删号）。原生消费方可观察；JS 侧内存态不随之更新。
  static let didChangeNotification = Notification.Name("TiebaSessionDidChange")

  private static let activeIdKey = "@tiebalite:active_id"
  private static let accountListKey = "@tiebalite:account_list"
  private static let accountPrefix = "@tiebalite:account:"
  private static let currentMetaKey = "@tiebalite:current_meta"
  private static let profileCacheKey = "@tiebalite:account_profile_cache_v1"
  private static let credentialFields = ["bduss", "stoken", "cookie", "tbs", "zid"]

  // MARK: - 状态

  static var isLoggedIn: Bool { !TiebaBackgroundSnapshot.shared.bduss.isEmpty }

  /// 活跃账号 uid：KV 的 active_id 优先，缺失回落后台快照（JS 同判据）。
  static var activeUid: String {
    let stored = TiebaKvStore.shared.get(key: activeIdKey) ?? ""
    return stored.isEmpty ? TiebaBackgroundSnapshot.shared.uid : stored
  }

  // MARK: - 账号读取

  /// 账号列表（KV 元数据，无凭据字段；顺序即 JS account_list 的顺序）。
  static func accounts() -> [TiebaAccount] {
    guard let raw = TiebaKvStore.shared.get(key: accountListKey),
      let list = TiebaJSON.list(from: raw)
    else { return [] }
    return list.map(account(fromJSON:)).filter { !$0.uid.isEmpty }
  }

  /// 单账号（元数据 + 该账号的 Keychain 凭据）。
  static func account(uid: String) -> TiebaAccount? {
    guard !uid.isEmpty else { return nil }
    guard let raw = TiebaKvStore.shared.get(key: accountPrefix + uid),
      let object = TiebaJSON.object(from: raw)
    else { return nil }
    var account = self.account(fromJSON: object)
    let credentials = credentials(uid: uid)
    account.bduss = credentials.bduss
    account.sToken = credentials.stoken
    account.cookie = credentials.cookie
    account.tbs = credentials.tbs
    account.zid = credentials.zid
    return account
  }

  static func currentAccount() -> TiebaAccount? { account(uid: activeUid) }

  /// Keychain 里的账号凭据（切号恢复用；缺失字段为 ""）。
  static func credentials(uid: String) -> (bduss: String, stoken: String, cookie: String, tbs: String, zid: String) {
    func read(_ field: String) -> String {
      TiebaKeychain.get(key: "tiebalite.account.\(uid).\(field)") ?? ""
    }
    return (read("bduss"), read("stoken"), read("cookie"), read("tbs"), read("zid"))
  }

  // MARK: - 僵尸会话清理

  /// 卸载重装时 Keychain 存活、沙盒（KV/账号元数据）被清空 —— 快照里仍有凭据，
  /// 于是以"已登录"启动却没有昵称/头像，且所有请求都带着失效凭据。健康登录一定
  /// 同时写下 KV 账号元数据（persist → saveMetadata），元数据缺失即孤儿凭据。
  ///
  /// ⚠️ 这是一次性迁移，**不是每次启动都跑的规则**：只有装标记（orphanPurgeFlagKey）
  /// 不在时评估一次，评估完就落标记。否则任何"元数据暂时读不到"（旧版升级、
  /// 写入失败、库损坏）都会把还能用的登录信息删掉——用户无法登录正是这条路径。
  static func purgeOrphanedSession() {
    let kv = TiebaKvStore.shared
    // 标记态：读过（.value）= 本安装已评估过；读不到（.unavailable）= 库有问题，
    // 保持原样下次再说（不写标记，避免"没评估成功也当评估过"）。
    switch kv.lookup(key: TiebaKvStore.orphanPurgeFlagKey) {
    case .value:
      return
    case .unavailable(let reason):
      sessionLog.error("跳过孤儿会话清理：标记不可读（\(reason, privacy: .public)）")
      return
    case .missing:
      break
    }
    let snapshot = TiebaBackgroundSnapshot.shared
    guard !snapshot.bduss.isEmpty else {
      // 没凭据 = 不可能有孤儿登录态：记一笔标记收工（本次安装不再评估）。
      writePurgeFlag()
      return
    }
    // 只有**确证** account_list 为空（键不存在 / 解析出空数组）才清理：读失败、
    // 解析失败、旧 MMKV 导入未完成都不动凭据——一次磁盘故障不该把用户永久登出，
    // 误判"没有账号元数据"而删 active 凭据正是这条路径最贵的错误（112）。
    switch kv.lookup(key: accountListKey) {
    case .unavailable(let reason):
      sessionLog.error("跳过孤儿会话清理：账号列表不可读（\(reason, privacy: .public)）")
      return
    case .value(let raw):
      guard let list = TiebaJSON.list(from: raw), list.isEmpty else {
        writePurgeFlag()
        return
      }
    case .missing:
      break
    }
    // 沙盒被清空的旁证：除了内部标记，kv 表里没有别的键。表里还有别的数据说明
    // KV 是健康的（只是账号元数据不在），此时"元数据缺失"更可能是旧版键名差异
    // 或写入失败——保留凭据，让用户自己登出，绝不代删（用户要求：不许把还能用的
    // 登录信息删掉）。
    let userKeys = TiebaKvStore.shared.allKeys()
      .filter { !TiebaKvStore.internalMarkerKeys.contains($0) }
    guard userKeys.isEmpty else {
      writePurgeFlag()
      return
    }
    sessionLog.info("孤儿登录态已清理（Keychain 有凭据但沙盒已清空）")
    snapshot.clear()
    for field in credentialFields {
      TiebaKeychain.delete(key: "tiebalite.active.\(field)")
    }
    do {
      try kv.remove(key: currentMetaKey)
    } catch {
      sessionLog.error("清理 current_meta 失败：\(error.localizedDescription, privacy: .public)")
    }
    writePurgeFlag()
  }

  /// 落一次性标记。写失败只记日志：下次启动会重新评估，而重新评估的判据同样
  /// 严格（确证读到空），不会因为"多评估一次"删掉有效凭据。
  private static func writePurgeFlag() {
    do {
      try TiebaKvStore.shared.set(key: TiebaKvStore.orphanPurgeFlagKey, value: "1")
    } catch {
      sessionLog.error("写孤儿清理标记失败：\(error.localizedDescription, privacy: .public)")
    }
  }

  // MARK: - 激活序列（JS activateAccount 的原生等价）

  /// 登录/切号单点入口：Cookie 先行（可失败则中止且零持久化副作用），
  /// 再写 Keychain + KV、原生后台快照、冷启动档案缓存。
  @discardableResult
  static func activate(_ raw: TiebaAccount) async throws -> TiebaAccount {
    var account = raw
    if account.uid.isEmpty { throw TiebaSessionError.missingBduss }
    if account.bduss.isEmpty { throw TiebaSessionError.missingBduss }
    if account.nameShow.isEmpty { account.nameShow = account.name }
    if account.cookie.isEmpty {
      account.cookie =
        "BDUSS=\(account.bduss); Path=/; Max-Age=315360000; Domain=.baidu.com; Httponly"
    }
    try await syncCookies(account)
    try persist(account)
    saveSnapshot(account)
    saveProfileCache(account)
    // 换号清关注吧缓存（内存 + 磁盘，缓存不分账号，不清会短时串号）。
    TiebaFollowedForums.invalidate()
    NotificationCenter.default.post(name: didChangeNotification, object: nil)
    return account
  }

  /// 登出：清 Cookie → 删当前账号 → 有剩余账号则切首个仍有 BDUSS 的，否则彻底清会话。
  static func logout() async throws -> TiebaAccount? {
    let cleared = await TiebaCookieStore.clearAll()
    guard cleared else { throw TiebaSessionError.cookieClearFailed }
    let uid = activeUid
    if !uid.isEmpty { deleteAccountData(uid: uid) }
    for meta in accounts() {
      let credentials = credentials(uid: meta.uid)
      guard !credentials.bduss.isEmpty else { continue }
      var next = meta
      next.bduss = credentials.bduss
      next.sToken = credentials.stoken
      next.cookie = credentials.cookie
      next.tbs = credentials.tbs
      next.zid = credentials.zid
      return try await activate(next)
    }
    TiebaBackgroundSnapshot.shared.clear()
    TiebaFollowedForums.invalidate()
    NotificationCenter.default.post(name: didChangeNotification, object: nil)
    return nil
  }

  static func switchAccount(uid: String) async throws {
    guard let target = account(uid: uid), !target.bduss.isEmpty else {
      throw TiebaSessionError.missingCredentials
    }
    try await activate(target)
  }

  /// 删除账号（账号页「移除账号」的非当前账号路径）。
  static func deleteAccount(uid: String) {
    guard !uid.isEmpty else { return }
    deleteAccountData(uid: uid)
    NotificationCenter.default.post(name: didChangeNotification, object: nil)
  }

  // MARK: - tbs

  /// 续期 tbs：网络失败回落""（requireTbs 统一转 missingTbs 文案），但**落盘
  /// 失败必须抛**——Keychain 没写下 tbs，用户下次操作还是失败。
  static func refreshTbs() async throws -> String {
    let bduss = TiebaBackgroundSnapshot.shared.bduss
    guard !bduss.isEmpty else { return "" }
    let tbs = (try? await fetchTbs(bduss: bduss)) ?? ""
    if !tbs.isEmpty { try persistTbs(tbs) }
    return tbs
  }

  static func requireTbs() async throws -> String {
    let tbs = TiebaBackgroundSnapshot.shared.tbs
    if !tbs.isEmpty { return tbs }
    let refreshed = try await refreshTbs()
    if !refreshed.isEmpty { return refreshed }
    throw TiebaSessionError.missingTbs
  }

  private static func persistTbs(_ tbs: String) throws {
    let uid = activeUid
    if !uid.isEmpty {
      try setSecure("tiebalite.account.\(uid).tbs", tbs)
    }
    try setSecure("tiebalite.active.tbs", tbs)
    if !uid.isEmpty {
      guard let meta = TiebaJSON.stringify(["uid": uid]) else {
        throw TiebaSessionError.persistFailed("current_meta encode failed")
      }
      try TiebaKvStore.shared.set(key: currentMetaKey, value: meta)
    }
    let snapshot = TiebaBackgroundSnapshot.shared
    snapshot.tbs = tbs
    snapshot.persist()
  }

  // MARK: - 登录 wire（对齐 aiotieba /c/s/login；原 JS fetchAccountLogin）

  /// 用 BDUSS 换取账号信息（uid/name/portrait + anti.tbs）。
  static func fetchLoginAccount(bduss: String) async throws -> TiebaAccount {
    let response = try await loginRequest(bduss: bduss)
    guard let body = TiebaJSON.object(from: response.body) else {
      throw TiebaForumAPIError.invalidResponse
    }
    if let code = TiebaJSON.int(body, "error_code"), code != 0 {
      throw TiebaForumAPIError.api(code: Int32(code), message: TiebaJSON.string(body, "error_msg") ?? "")
    }
    if let code = TiebaJSON.int(body, "code"), code != 0 {
      throw TiebaForumAPIError.api(code: Int32(code), message: TiebaJSON.string(body, "message") ?? "")
    }
    let nested = body["data"] as? [String: Any]
    let user = (body["user"] as? [String: Any]) ?? (nested?["user"] as? [String: Any]) ?? [:]
    let uid = TiebaJSON.string(user, "id", "uid", "user_id") ?? ""
    guard !uid.isEmpty else { throw TiebaForumAPIError.invalidResponse }
    let anti = (body["anti"] as? [String: Any]) ?? (nested?["anti"] as? [String: Any])
    var tbs = TiebaJSON.string(anti, "tbs") ?? (nested.flatMap { TiebaJSON.string($0, "tbs") }) ?? ""
    if tbs.isEmpty { tbs = (try? await fetchTbs(bduss: bduss)) ?? "" }
    var account = TiebaAccount()
    account.uid = uid
    account.name = TiebaJSON.string(user, "name") ?? ""
    account.nameShow = TiebaJSON.string(user, "name_show", "nameShow") ?? account.name
    account.portrait = TiebaJSON.string(user, "portrait") ?? ""
    account.bduss = bduss
    account.tbs = tbs
    return account
  }

  static func fetchTbs(bduss: String) async throws -> String {
    let response = try await loginRequest(bduss: bduss)
    guard (200..<300).contains(response.status),
      let body = TiebaJSON.object(from: response.body)
    else { throw TiebaForumAPIError.invalidResponse }
    let nested = body["data"] as? [String: Any]
    let anti = (body["anti"] as? [String: Any]) ?? (nested?["anti"] as? [String: Any])
    return TiebaJSON.string(anti, "tbs") ?? (nested.flatMap { TiebaJSON.string($0, "tbs") }) ?? ""
  }

  private static func loginRequest(bduss: String) async throws -> TiebaHttpRawResponse {
    let version = "22.6.5.1"
    let sign = TiebaSigner.signParams(["_client_version": version, "bdusstoken": bduss])
    let body = "_client_version=\(TiebaRoutePath.segment(version))&bdusstoken=\(TiebaRoutePath.segment(bduss))&sign=\(sign)"
    let response = try await TiebaHttpClient.shared.send(
      urlString: "https://tiebac.baidu.com/c/s/login",
      method: "POST",
      headers: [
        "Content-Type": "application/x-www-form-urlencoded",
        "User-Agent": "bdtb for Android \(version)",
      ],
      body: body,
      formParts: [],
      requestId: "native-login-\(UUID().uuidString)",
      timeoutMs: 15000
    )
    guard (200..<300).contains(response.status) else { throw TiebaForumAPIError.http(response.status) }
    return response
  }

  /// 登录后 best-effort 回填资料（nameShow/portrait/intro/计数到 KV 档案缓存）。
  /// 元数据落盘失败返回 nil（调用点外部文件不接受 throws，不能谎报回填成功）。
  @discardableResult
  static func refreshProfile(uid: String) async -> TiebaAccount? {
    guard !uid.isEmpty, let profile = try? await TiebaUserAPI.profile(uid: uid) else { return nil }
    guard activeUid == uid else { return nil }
    guard var account = currentAccount() ?? account(uid: uid) else { return nil }
    if !profile.name.isEmpty { account.name = profile.name }
    if !profile.nameShow.isEmpty { account.nameShow = profile.nameShow }
    if !profile.portrait.isEmpty { account.portrait = profile.portrait }
    if !profile.intro.isEmpty { account.intro = profile.intro }
    account.fansNum = profile.fansNum
    account.concernNum = profile.concernNum
    account.postNum = profile.postNum
    do {
      try saveMetadata(account)
    } catch {
      sessionLog.error("资料回填持久化失败：\(error.localizedDescription, privacy: .public)")
      return nil
    }
    saveProfileCache(account)
    NotificationCenter.default.post(name: didChangeNotification, object: nil)
    return account
  }

  /// 头像上传成功后的就地回写（账号页/编辑资料页头像立即更新）。落盘失败只记日志
  /// 并放弃本次回写：调用点（编辑资料页）不接受 throws，但绝不假装已保存。
  static func updatePortrait(_ portrait: String) {
    guard !portrait.isEmpty, var account = currentAccount() else { return }
    account.portrait = portrait
    do {
      try saveMetadata(account)
    } catch {
      sessionLog.error("头像回写持久化失败：\(error.localizedDescription, privacy: .public)")
      return
    }
    saveProfileCache(account)
    NotificationCenter.default.post(name: didChangeNotification, object: nil)
  }

  // MARK: - 持久化（JS saveAccountSync / deleteAccountSync 同形）

  /// 凭据 + 元数据全量落盘。任何一步失败都抛出 → activate 整体失败（111）。
  private static func persist(_ account: TiebaAccount) throws {
    for field in credentialFields {
      try setSecure("tiebalite.account.\(account.uid).\(field)", credentialValue(account, field: field))
    }
    // 活跃凭据（bduss/stoken/cookie 非空写、空删；tbs/zid 同 persistMeta）
    try setSecure("tiebalite.active.bduss", account.bduss)
    try setSecure("tiebalite.active.stoken", account.sToken)
    try setSecure("tiebalite.active.cookie", account.cookie)
    try setSecure("tiebalite.active.tbs", account.tbs)
    try setSecure("tiebalite.active.zid", account.zid)
    try saveMetadata(account)
    guard let meta = TiebaJSON.stringify(["uid": account.uid]) else {
      throw TiebaSessionError.persistFailed("current_meta encode failed")
    }
    try TiebaKvStore.shared.set(key: currentMetaKey, value: meta)
  }

  /// 账号 JSON + 列表 upsert（保留既有的 levelId/levelName 等档案字段）。
  /// 编码失败或 KV 写失败都抛出：登录"成功"但元数据没落盘 = 重启后掉线（111）。
  private static func saveMetadata(_ account: TiebaAccount) throws {
    var record = rawAccount(uid: account.uid)
    record["id"] = 0
    record["uid"] = account.uid
    record["name"] = account.name
    record["nameShow"] = account.nameShow
    record["portrait"] = account.portrait
    record["uuid"] = account.uid
    if !account.intro.isEmpty { record["intro"] = account.intro }
    if account.fansNum > 0 { record["fansNum"] = account.fansNum }
    if account.concernNum > 0 { record["concernNum"] = account.concernNum }
    if account.postNum > 0 { record["postNum"] = account.postNum }

    guard let recordText = TiebaJSON.stringify(record) else {
      throw TiebaSessionError.persistFailed("account encode failed")
    }
    try TiebaKvStore.shared.set(key: accountPrefix + account.uid, value: recordText)
    var list = rawAccountList().filter { TiebaJSON.string($0, "uid") != account.uid }
    list.append(record)
    guard let listText = TiebaJSON.stringify(list) else {
      throw TiebaSessionError.persistFailed("account list encode failed")
    }
    try TiebaKvStore.shared.set(key: accountListKey, value: listText)
    try TiebaKvStore.shared.set(key: activeIdKey, value: account.uid)
  }

  /// 删除账号（非当前账号路径也走这里）。列表重写前必须确证 account_list 读到了：
  /// 读失败/解析失败时按空列表写回 = 其余账号元数据被清（同 112 的教训）。
  private static func deleteAccountData(uid: String) {
    do {
      try TiebaKvStore.shared.remove(key: accountPrefix + uid)
    } catch {
      sessionLog.error("删除账号元数据失败：\(error.localizedDescription, privacy: .public)")
    }
    let existing: [[String: Any]]?
    switch TiebaKvStore.shared.lookup(key: accountListKey) {
    case .unavailable(let reason):
      sessionLog.error("账号列表不可读，跳过列表重写：\(reason, privacy: .public)")
      existing = nil
    case .missing:
      existing = []
    case .value(let raw):
      existing = TiebaJSON.list(from: raw)
      if existing == nil {
        sessionLog.error("账号列表解析失败，跳过列表重写")
      }
    }
    if let existing, let text = TiebaJSON.stringify(existing.filter { TiebaJSON.string($0, "uid") != uid }) {
      do {
        try TiebaKvStore.shared.set(key: accountListKey, value: text)
      } catch {
        sessionLog.error("重写账号列表失败：\(error.localizedDescription, privacy: .public)")
      }
    }
    for field in credentialFields {
      TiebaKeychain.delete(key: "tiebalite.account.\(uid).\(field)")
    }
    // 删的是当前账号：活跃凭据与 current_meta 一并清（JS clearAllAuthSync）。
    if (TiebaKvStore.shared.get(key: activeIdKey) ?? "") == uid {
      do {
        try TiebaKvStore.shared.remove(key: activeIdKey)
        try TiebaKvStore.shared.remove(key: currentMetaKey)
      } catch {
        sessionLog.error("清理 active_id/current_meta 失败：\(error.localizedDescription, privacy: .public)")
      }
      for field in credentialFields {
        TiebaKeychain.delete(key: "tiebalite.active.\(field)")
      }
    }
  }

  // MARK: - Cookie / 快照

  /// Cookie 同步（JS setNativeCookies 同形：只写 Foundation 存储；WK 存储在
  /// 打开 WebView 前由该页自己灌——见 TiebaWebViewController.load）。
  private static func syncCookies(_ account: TiebaAccount) async throws {
    var entries: [String: String] = [:]
    if !account.bduss.isEmpty { entries["BDUSS"] = account.bduss }
    if !account.sToken.isEmpty { entries["STOKEN"] = account.sToken }
    for part in account.cookie.split(separator: ";") {
      guard let eq = part.firstIndex(of: "="), eq != part.startIndex else { continue }
      let name = part[..<eq].trimmingCharacters(in: .whitespaces).uppercased()
      let value = part[part.index(after: eq)...].trimmingCharacters(in: .whitespaces)
      if !name.isEmpty, !value.isEmpty, entries[name] == nil { entries[name] = value }
    }
    for (name, value) in entries {
      try await TiebaCookieStore.set(
        urlString: "https://tieba.baidu.com/",
        name: name,
        value: value,
        domain: ".baidu.com",
        path: "/",
        secure: true,
        httpOnly: name == "BDUSS" || name == "STOKEN",
        maxAge: 315_360_000,
        webKit: false
      )
    }
  }

  private static func saveSnapshot(_ account: TiebaAccount) {
    let snapshot = TiebaBackgroundSnapshot.shared
    // 冷启动未 load 时先取回持久化的 clientId（JS syncBackgroundSnapshot 的 payload 同键）。
    if snapshot.bduss.isEmpty { snapshot.load() }
    snapshot.bduss = account.bduss
    snapshot.stoken = account.sToken
    snapshot.cookie = account.cookie
    snapshot.uid = account.uid
    snapshot.tbs = account.tbs
    snapshot.zid = account.zid
    snapshot.clientId = resolvedClientId()
    snapshot.forumIds = []
    snapshot.forumNames = []
    snapshot.persist()
  }

  private static func resolvedClientId() -> String {
    if let stored = TiebaKvStore.shared.get(key: "@tiebalite:client_id"), !stored.isEmpty {
      return stored
    }
    let existing = TiebaBackgroundSnapshot.shared.clientId
    if !existing.isEmpty { return existing }
    let generated = UUID().uuidString.lowercased()
    do {
      try TiebaKvStore.shared.set(key: "@tiebalite:client_id", value: generated)
    } catch {
      sessionLog.error("client_id 落盘失败：\(error.localizedDescription, privacy: .public)")
    }
    return generated
  }

  private static func saveProfileCache(_ account: TiebaAccount) {
    var record = rawAccount(uid: account.uid)
    record["uid"] = account.uid
    record["name"] = account.name
    record["nameShow"] = account.nameShow
    record["portrait"] = account.portrait
    if !account.intro.isEmpty { record["intro"] = account.intro }
    if account.fansNum > 0 { record["fansNum"] = account.fansNum }
    if account.concernNum > 0 { record["concernNum"] = account.concernNum }
    if account.postNum > 0 { record["postNum"] = account.postNum }
    guard let text = TiebaJSON.stringify(record) else { return }
    do {
      try TiebaKvStore.shared.set(key: profileCacheKey, value: text)
    } catch {
      sessionLog.error("档案缓存落盘失败：\(error.localizedDescription, privacy: .public)")
    }
  }

  // MARK: - Keychain / JSON 辅助

  private static func credentialValue(_ account: TiebaAccount, field: String) -> String {
    switch field {
    case "bduss": return account.bduss
    case "stoken": return account.sToken
    case "cookie": return account.cookie
    case "tbs": return account.tbs
    default: return account.zid
    }
  }

  /// 非空写 / 空删（空值不落 Keychain，读回同为 ""）。写失败**必须抛**：
  /// persist 的凭据全部走它，吞掉 = 登录成功但重启掉线（111）。
  private static func setSecure(_ key: String, _ value: String) throws {
    if value.isEmpty {
      TiebaKeychain.delete(key: key)
    } else {
      try TiebaKeychain.set(key: key, value: value)
    }
  }

  private static func account(fromJSON object: [String: Any]) -> TiebaAccount {
    var account = TiebaAccount()
    account.uid = TiebaJSON.string(object, "uid") ?? ""
    account.name = TiebaJSON.string(object, "name") ?? ""
    account.nameShow = TiebaJSON.string(object, "nameShow", "name_show") ?? ""
    account.portrait = TiebaJSON.string(object, "portrait") ?? ""
    account.intro = TiebaJSON.string(object, "intro") ?? ""
    account.fansNum = TiebaJSON.int(object, "fansNum") ?? 0
    account.concernNum = TiebaJSON.int(object, "concernNum") ?? 0
    account.postNum = TiebaJSON.int(object, "postNum") ?? 0
    return account
  }

  private static func rawAccount(uid: String) -> [String: Any] {
    guard let raw = TiebaKvStore.shared.get(key: accountPrefix + uid),
      let object = TiebaJSON.object(from: raw)
    else { return [:] }
    return object
  }

  private static func rawAccountList() -> [[String: Any]] {
    guard let raw = TiebaKvStore.shared.get(key: accountListKey),
      let list = TiebaJSON.list(from: raw)
    else { return [] }
    return list
  }
}
