import Foundation
import Security

/// 后台快照（BDUSS/STOKEN/签到目标等）：JS 桥主线程写入、BGTask 后台读取，
/// 按设计跨线程。Swift 6 下以 @unchecked Sendable 声明（字段均为 String/
/// [String] 值类型，Keychain 落盘由本类串行执行）。
final class TiebaBackgroundSnapshot: @unchecked Sendable {
  static let shared = TiebaBackgroundSnapshot()

  private let keychainService = "app"
  private let keychainAccount = "tiebalite.native.background_snapshot"

  var bduss = ""
  var stoken = ""
  var cookie = ""
  var uid = ""
  var tbs = ""
  var zid = ""
  var clientId = ""
  var forumIds: [String] = []
  var forumNames: [String] = []

  func save(_ payload: [String: Any]) {
    bduss = string(payload["bduss"])
    stoken = string(payload["stoken"])
    cookie = string(payload["cookie"])
    uid = string(payload["uid"])
    tbs = string(payload["tbs"])
    zid = string(payload["zid"])
    clientId = string(payload["clientId"])
    forumIds = payload["forumIds"] as? [String] ?? []
    forumNames = payload["forumNames"] as? [String] ?? []

    let payload: [String: Any] = [
      "bduss": bduss,
      "stoken": stoken,
      "cookie": cookie,
      "uid": uid,
      "tbs": tbs,
      "zid": zid,
      "clientId": clientId,
      "forumIds": forumIds,
      "forumNames": forumNames
    ]
    if let json = try? JSONSerialization.data(withJSONObject: payload),
       let encoded = String(data: json, encoding: .utf8) {
      writeKeychain(encoded)
    }
  }

  func load() {
    guard let raw = readKeychain(), let data = raw.data(using: .utf8) else { return }
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
    bduss = string(json["bduss"])
    stoken = string(json["stoken"])
    cookie = string(json["cookie"])
    uid = string(json["uid"])
    tbs = string(json["tbs"])
    zid = string(json["zid"])
    clientId = string(json["clientId"])
    forumIds = json["forumIds"] as? [String] ?? []
    forumNames = json["forumNames"] as? [String] ?? []
  }

  func clear() {
    bduss = ""
    stoken = ""
    cookie = ""
    uid = ""
    tbs = ""
    zid = ""
    clientId = ""
    forumIds = []
    forumNames = []
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
    SecItemAdd(query as CFDictionary, nil)
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
