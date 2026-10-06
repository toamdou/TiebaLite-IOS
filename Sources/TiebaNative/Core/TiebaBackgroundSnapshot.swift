import Foundation
import Security
import Synchronization
import os

/// 后台快照（BDUSS/STOKEN/签到目标等）：JS 桥线程写入、BGTask 与请求组装线程
/// 读取，按设计跨线程。
///
/// 2026-09-12（并发审查）：此前字段是裸 `var`，读方可能读到写了一半的字段组合
/// （String 非原子，撕裂读写是未定义行为，而且这是凭据）。
/// 现在**全部字段收进一个 Sendable 值类型，由 Mutex 保护**：单字段读走计算属性，
/// `save/load/clear` 在锁内整体替换，保证读到的一定是自洽的一份快照。
/// 并发安全由编译器检查（Mutex<State>），不再需要 NSLock + @unchecked Sendable。
final class TiebaBackgroundSnapshot: Sendable {
  static let shared = TiebaBackgroundSnapshot()

  private static let log = Logger(
    subsystem: "com.tiebalite.app",
    category: "background-snapshot"
  )

  private let keychainService = "app"
  private let keychainAccount = "tiebalite.native.background_snapshot"

  /// 一份完整快照。值类型 + Sendable：读是整体拷贝、写是整体替换，
  /// 「字段组合自洽」由类型保证——不需要逐字段加锁，也不会读到半新半旧。
  private struct State: Sendable {
    var bduss = ""
    var stoken = ""
    var cookie = ""
    var uid = ""
    var tbs = ""
    var zid = ""
    var clientId = ""
    var forumIds: [String] = []
    var forumNames: [String] = []
  }

  /// 保护整份 State：单字段读写与 save/load/clear 的整体替换互斥。
  private let state = Mutex(State())

  var bduss: String {
    get { state.withLock { $0.bduss } }
    set { state.withLock { $0.bduss = newValue } }
  }
  var stoken: String {
    get { state.withLock { $0.stoken } }
    set { state.withLock { $0.stoken = newValue } }
  }
  var cookie: String {
    get { state.withLock { $0.cookie } }
    set { state.withLock { $0.cookie = newValue } }
  }
  var uid: String {
    get { state.withLock { $0.uid } }
    set { state.withLock { $0.uid = newValue } }
  }
  var tbs: String {
    get { state.withLock { $0.tbs } }
    set { state.withLock { $0.tbs = newValue } }
  }
  var zid: String {
    get { state.withLock { $0.zid } }
    set { state.withLock { $0.zid = newValue } }
  }
  var clientId: String {
    get { state.withLock { $0.clientId } }
    set { state.withLock { $0.clientId = newValue } }
  }
  var forumIds: [String] {
    get { state.withLock { $0.forumIds } }
    set { state.withLock { $0.forumIds = newValue } }
  }
  var forumNames: [String] {
    get { state.withLock { $0.forumNames } }
    set { state.withLock { $0.forumNames = newValue } }
  }

  func save(_ payload: [String: Any]) {
    // 先在锁外把 JSON 解成值，再一次性替换整份 State：锁窗口只有赋值，没有解析。
    var next = State()
    next.bduss = string(payload["bduss"])
    next.stoken = string(payload["stoken"])
    next.cookie = string(payload["cookie"])
    next.uid = string(payload["uid"])
    next.tbs = string(payload["tbs"])
    next.zid = string(payload["zid"])
    next.clientId = string(payload["clientId"])
    next.forumIds = payload["forumIds"] as? [String] ?? []
    next.forumNames = payload["forumNames"] as? [String] ?? []

    state.withLock { $0 = next }

    persist()
  }

  /// 把当前内存快照写回 Keychain。给"只改了字段"的调用方用
  /// （如 TiebaFollowedForums 刷新关注列表后同步 forumIds/forumNames
  /// ——后台自动签到按它工作；原 JS setBackgroundForums→syncBackgroundSnapshot）。
  func persist() {
    // 一次取整份快照：原来逐个字段 get 会分别加锁，理论上能拼出「半新半旧」的
    // payload（比如新 bduss 配旧 cookie），而这是一份凭据。
    let snapshot = state.withLock { $0 }
    let payload: [String: Any] = [
      "bduss": snapshot.bduss,
      "stoken": snapshot.stoken,
      "cookie": snapshot.cookie,
      "uid": snapshot.uid,
      "tbs": snapshot.tbs,
      "zid": snapshot.zid,
      "clientId": snapshot.clientId,
      "forumIds": snapshot.forumIds,
      "forumNames": snapshot.forumNames
    ]
    if let json = try? JSONSerialization.data(withJSONObject: payload) {
      writeKeychain(Self.encodePayload(json))
    }
  }

  func load() {
    guard let stored = readKeychain(), let json = Self.decodePayload(stored) else { return }
    guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return }
    var next = State()
    next.bduss = string(object["bduss"])
    next.stoken = string(object["stoken"])
    next.cookie = string(object["cookie"])
    next.uid = string(object["uid"])
    next.tbs = string(object["tbs"])
    next.zid = string(object["zid"])
    next.clientId = string(object["clientId"])
    next.forumIds = object["forumIds"] as? [String] ?? []
    next.forumNames = object["forumNames"] as? [String] ?? []
    state.withLock { $0 = next }
  }

  func clear() {
    state.withLock { $0 = State() }
    deleteKeychain()
  }

  // MARK: - 落盘编码（Keychain 里的 payload）

  /// 快照 JSON 的落盘编码：大快照（关注列表动辄几十上百个吧）压 gzip，
  /// 压不小就原样存——小 payload 套 gzip 头反而更大。
  /// 读取端按 gzip 魔数识别，所以**旧版本写的明文 JSON 仍然读得出来**；
  /// 反向不兼容（新版写的 gzip 旧版本读不了）已在 22-接线报告里注明。
  nonisolated static func encodePayload(_ json: Data) -> Data {
    guard let compressed = TiebaGZip.compress(json), compressed.count < json.count else {
      return json
    }
    return compressed
  }

  nonisolated static func decodePayload(_ data: Data) -> Data? {
    TiebaGZip.isGzipped(data) ? TiebaGZip.decompress(data) : data
  }

  /// event_day 格式固定 en_US_POSIX + Gregorian：不受用户地区/非公历日历设置影响
  ///（否则出现 12 小时制错位/佛历年份等脏数据）。**静态**——每个签名请求都要它，
  /// 每请求新建 DateFormatter 是热路径上的纯浪费（同 TiebaForumAPI.eventDay）。
  private static let eventDayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.dateFormat = "yyyyMdd"
    return formatter
  }()

  func commonParams() -> [String: String] {
    // 一次取整份：同一批请求参数必须来自同一份快照（否则可能 BDUSS 是新的、
    // clientId 还是旧的，服务端侧对不上）。
    // ⚠️ timestamp 必须是墙钟（服务端契约），不能用跨重启单调时钟。
    let snapshot = state.withLock { $0 }
    let now = Int(Date().timeIntervalSince1970 * 1000)
    let eventDay = Self.eventDayFormatter.string(from: Date())
    let id = snapshot.clientId.isEmpty ? "00000000-0000-4000-8000-000000000000" : snapshot.clientId
    var params = [
      "BDUSS": snapshot.bduss,
      "_client_id": id,
      "_client_type": "2",
      "_os_version": "31",
      "model": "SM-G9910",
      "net_type": "1",
      "_phone_imei": id,
      "timestamp": String(now),
      "active_timestamp": String(now),
      "android_id": "",
      "baiduid": "",
      "brand": "samsung",
      "c3_aid": id,
      "cmode": "1",
      "cuid": id,
      "cuid_galaxy2": id,
      "cuid_gid": "",
      "event_day": eventDay,
      "extra": "",
      "first_install_time": String(now - 86400_000 * 30),
      "framework_ver": "3340042",
      "from": "tieba",
      "is_teenager": "0",
      "last_update_time": String(now - 86400_000),
      "mac": "02:00:00:00:00:00",
      "oaid": "{\"id\":\"\",\"oaid\":\"\",\"aaid\":\"\",\"vaid\":\"\"}",
      "sample_id": id,
      "sdk_ver": "2.34.0",
      "start_scheme": "",
      "start_type": "1",
      "swan_game_ver": "1038000",
      "_client_version": "12.41.7.1",
      "naws_game_ver": "1038000",
      "personalized_rec_switch": "1",
      "z_id": ""
    ]
    if !snapshot.stoken.isEmpty {
      params["stoken"] = snapshot.stoken
    }
    params["device_score"] = "50"
    return params
  }

  private func string(_ value: Any?) -> String {
    if let string = value as? String {
      return string
    }
    if let number = value as? NSNumber {
      return number.stringValue
    }
    return ""
  }

  private func writeKeychain(_ value: Data) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: keychainAccount,
      kSecValueData as String: value,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    ]
    SecItemDelete(query as CFDictionary)
    // Keychain 写入必须回读状态：失败静默丢弃会让下次冷启动凭据丢失（用户表现
    // 为"莫名掉登录"，无任何线索）。这里只记日志，不改变失败语义。
    let status = SecItemAdd(query as CFDictionary, nil)
    if status != errSecSuccess {
      Self.log.error("background snapshot keychain write failed: OSStatus \(status, privacy: .public)")
    }
  }

  /// 返回 Data 而不是 String：payload 可能是 gzip 二进制（解出来才是 JSON 文本）。
  private func readKeychain() -> Data? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: keychainAccount,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess, let data = item as? Data else { return nil }
    return data
  }

  private func deleteKeychain() {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: keychainAccount
    ]
    SecItemDelete(query as CFDictionary)
  }
}
