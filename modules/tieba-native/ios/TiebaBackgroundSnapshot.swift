import Foundation
import Security
import os

/// 后台快照（BDUSS/STOKEN/签到目标等）：JS 桥线程写入、BGTask 与请求组装线程
/// 读取，按设计跨线程。
///
/// 2026-09-12（并发审查）：此前字段是裸 `var`，读方可能读到写了一半的字段组合
/// （String 非原子，撕裂读写是未定义行为，而且这是凭据）。现在**所有读写都在
/// 同一把 NSLock 内**：单字段读走计算属性，`save/load/clear` 在锁内整体替换，
/// 保证读到的一定是自洽的一份快照。Swift 6 下以 @unchecked Sendable 声明。
final class TiebaBackgroundSnapshot: @unchecked Sendable {
  static let shared = TiebaBackgroundSnapshot()

  private static let log = Logger(
    subsystem: "com.tiebalite.app",
    category: "background-snapshot"
  )

  private let keychainService = "app"
  private let keychainAccount = "tiebalite.native.background_snapshot"

  /// 保护下列全部字段：单字段读写与 save/load/clear 的整体替换互斥。
  private let lock = NSLock()

  private var bdussValue = ""
  private var stokenValue = ""
  private var cookieValue = ""
  private var uidValue = ""
  private var tbsValue = ""
  private var zidValue = ""
  private var clientIdValue = ""
  private var forumIdsValue: [String] = []
  private var forumNamesValue: [String] = []

  var bduss: String {
    get { lock.withLock { bdussValue } }
    set { lock.withLock { bdussValue = newValue } }
  }
  var stoken: String {
    get { lock.withLock { stokenValue } }
    set { lock.withLock { stokenValue = newValue } }
  }
  var cookie: String {
    get { lock.withLock { cookieValue } }
    set { lock.withLock { cookieValue = newValue } }
  }
  var uid: String {
    get { lock.withLock { uidValue } }
    set { lock.withLock { uidValue = newValue } }
  }
  var tbs: String {
    get { lock.withLock { tbsValue } }
    set { lock.withLock { tbsValue = newValue } }
  }
  var zid: String {
    get { lock.withLock { zidValue } }
    set { lock.withLock { zidValue = newValue } }
  }
  var clientId: String {
    get { lock.withLock { clientIdValue } }
    set { lock.withLock { clientIdValue = newValue } }
  }
  var forumIds: [String] {
    get { lock.withLock { forumIdsValue } }
    set { lock.withLock { forumIdsValue = newValue } }
  }
  var forumNames: [String] {
    get { lock.withLock { forumNamesValue } }
    set { lock.withLock { forumNamesValue = newValue } }
  }

  func save(_ payload: [String: Any]) {
    let nextBduss = string(payload["bduss"])
    let nextStoken = string(payload["stoken"])
    let nextCookie = string(payload["cookie"])
    let nextUid = string(payload["uid"])
    let nextTbs = string(payload["tbs"])
    let nextZid = string(payload["zid"])
    let nextClientId = string(payload["clientId"])
    let nextForumIds = payload["forumIds"] as? [String] ?? []
    let nextForumNames = payload["forumNames"] as? [String] ?? []

    lock.withLock {
      bdussValue = nextBduss
      stokenValue = nextStoken
      cookieValue = nextCookie
      uidValue = nextUid
      tbsValue = nextTbs
      zidValue = nextZid
      clientIdValue = nextClientId
      forumIdsValue = nextForumIds
      forumNamesValue = nextForumNames
    }

    let payload: [String: Any] = [
      "bduss": nextBduss,
      "stoken": nextStoken,
      "cookie": nextCookie,
      "uid": nextUid,
      "tbs": nextTbs,
      "zid": nextZid,
      "clientId": nextClientId,
      "forumIds": nextForumIds,
      "forumNames": nextForumNames
    ]
    if let json = try? JSONSerialization.data(withJSONObject: payload),
       let encoded = String(data: json, encoding: .utf8) {
      writeKeychain(encoded)
    }
  }

  func load() {
    guard let raw = readKeychain(), let data = raw.data(using: .utf8) else { return }
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
    lock.withLock {
      bdussValue = string(json["bduss"])
      stokenValue = string(json["stoken"])
      cookieValue = string(json["cookie"])
      uidValue = string(json["uid"])
      tbsValue = string(json["tbs"])
      zidValue = string(json["zid"])
      clientIdValue = string(json["clientId"])
      forumIdsValue = json["forumIds"] as? [String] ?? []
      forumNamesValue = json["forumNames"] as? [String] ?? []
    }
  }

  func clear() {
    lock.withLock {
      bdussValue = ""
      stokenValue = ""
      cookieValue = ""
      uidValue = ""
      tbsValue = ""
      zidValue = ""
      clientIdValue = ""
      forumIdsValue = []
      forumNamesValue = []
    }
    deleteKeychain()
  }

  func commonParams() -> [String: String] {
    let now = Int(Date().timeIntervalSince1970 * 1000)
    let date = Date()
    // 数字日期格式固定 en_US_POSIX + Gregorian：不受用户地区/非公历日历
    // 设置影响（否则 event_day 出现 12 小时制错位/佛历年份等脏数据）。
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.dateFormat = "yyyyMdd"
    let eventDay = formatter.string(from: date)
    let id = clientId.isEmpty ? "00000000-0000-4000-8000-000000000000" : clientId
    var params = [
      "BDUSS": bduss,
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
    if !stoken.isEmpty {
      params["stoken"] = stoken
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

  private func writeKeychain(_ value: String) {
    let data = Data(value.utf8)
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: keychainAccount,
      kSecValueData as String: data,
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

  private func readKeychain() -> String? {
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
    return String(data: data, encoding: .utf8)
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
