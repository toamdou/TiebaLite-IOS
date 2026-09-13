// ============================================================
// TiebaKeychain —— Keychain 单值存取（替代 expo-secure-store）
//
// ⚠️ 这个文件的键路径必须与 expo-secure-store **逐字节兼容**：消费方
// （AuthSecureStorage 的 BDUSS/STOKEN/COOKIE/tbs/zid）在旧包里写的都是这个
// 布局，改成"更干净"的 service/account 组合 = 全量凭据失联 = 用户被登出。
// 逐项对照 expo-secure-store/ios/SecureStoreModule.swift（2026-09-13 核对）：
//   - kSecClass = kSecClassGenericPassword；
//   - kSecAttrService = options.keychainService ?? "app"，且**按认证需求加后缀**：
//     set/get(requireAuthentication: false) → "app:no-auth"、true → "app:auth"、
//     不带参（legacy）→ "app"。本仓从不传 requireAuthentication，全部走
//     "app:no-auth"；读按 no-auth → auth → legacy 顺序回退（兼容旧包历史上
//     可能写过的另外两个 service）；
//   - kSecAttrAccount 与 kSecAttrGeneric = key 的 UTF-8 字节（Data，不是 String）；
//   - kSecAttrAccessible = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
//     （AuthSecureStorage 的 SECURE_STORE_OPTIONS 唯一取值）。它决定两件事：
//     锁屏后仍可读（后台任务要读凭据）、不随 iCloud/换机备份迁移——用户重装
//     同机时条目仍在（ThisDeviceOnly 只管备份迁移，不管 App 卸载）；
//   - 写 = SecItemAdd，errSecDuplicateItem → SecItemUpdate（同 service）；
//   - 删 = 三个 service 变体全删（含 legacy），错误忽略（旧包 delete 不抛）。
//   - key 校验：trim 后为空 → 抛（旧包 InvalidKeyException）。
//
// 不搬 expo 的 `requireAuthentication` / `authenticationPrompt`（kSecAttrAccessControl、
// 每次读弹面容）：全仓零调用，且会让"后台任务读凭据"失效——不是本仓要的语义。
// ============================================================
import Foundation
import Security

enum TiebaKeychainError: LocalizedError {
  case invalidKey
  case writeFailed(OSStatus)

  var errorDescription: String? {
    switch self {
    case .invalidKey:
      return "Keychain key must be a non-empty string"
    case .writeFailed(let status):
      return "Keychain write failed: \(status)"
    }
  }
}

enum TiebaKeychain {
  /// expo 的默认 service 与三种变体（见文件头）。
  private static let baseService = "app"
  private static let noAuthService = "app:no-auth"
  private static let authService = "app:auth"

  /// 本仓唯一使用（也是旧包唯一写入）的可访问性档位。
  /// nonisolated(unsafe)：CFString 常量，SDK 未标 Sendable（Swift 6 会当错误）。
  nonisolated(unsafe) private static let accessibility = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

  /// 进程内缓存（124）：credentials() 一次读 5 个键，未命中时每个键最多 3 次
  /// SecItemCopyMatching（no-auth/auth/legacy 回退），启动/切号路径会重复读同一批。
  /// 本进程内所有写都经过 set/delete（缓存随之更新/失效），读命中不再进 Security。
  private static let cacheLock = NSLock()
  nonisolated(unsafe) private static var cacheHits: [String: String] = [:]
  nonisolated(unsafe) private static var cacheMisses: Set<String> = []

  /// 读一个键；不存在 → nil。读序 no-auth → auth → legacy（兼容旧包写入面）。
  static func get(key: String) -> String? {
    let trimmed = key.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }
    cacheLock.lock()
    if let hit = cacheHits[key] {
      cacheLock.unlock()
      return hit
    }
    if cacheMisses.contains(key) {
      cacheLock.unlock()
      return nil
    }
    cacheLock.unlock()

    for service in [noAuthService, authService, baseService] {
      if let data = copy(service: service, key: key) {
        let value = String(data: data, encoding: .utf8)
        cacheLock.lock()
        cacheHits[key] = value
        cacheMisses.remove(key)
        cacheLock.unlock()
        return value
      }
    }
    cacheLock.lock()
    cacheMisses.insert(key)
    cacheLock.unlock()
    return nil
  }

  /// 写一个键（upsert）。失败抛错——写丢的是登录凭据，不能假装成功。
  static func set(key: String, value: String) throws {
    let trimmed = key.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { throw TiebaKeychainError.invalidKey }
    let valueData = Data(value.utf8)
    let query = baseQuery(service: noAuthService, key: key)
    var addQuery = query
    addQuery[kSecValueData as String] = valueData
    addQuery[kSecAttrAccessible as String] = accessibility

    let status = SecItemAdd(addQuery as CFDictionary, nil)
    switch status {
    case errSecSuccess:
      break
    case errSecDuplicateItem:
      let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: valueData] as CFDictionary)
      guard updateStatus == errSecSuccess else {
        throw TiebaKeychainError.writeFailed(updateStatus)
      }
    default:
      throw TiebaKeychainError.writeFailed(status)
    }
    cacheLock.lock()
    cacheHits[key] = value
    cacheMisses.remove(key)
    cacheLock.unlock()
  }

  /// 删一个键（三个 service 变体都删；不存在是 no-op，不抛——与旧包 delete 同）。
  /// 缓存同步记成未命中：删除是本进程的权威动作，之后再读不必再问 Security。
  static func delete(key: String) {
    let trimmed = key.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return }
    for service in [baseService, authService, noAuthService] {
      SecItemDelete(baseQuery(service: service, key: key) as CFDictionary)
    }
    cacheLock.lock()
    cacheHits.removeValue(forKey: key)
    cacheMisses.insert(key)
    cacheLock.unlock()
  }

  // MARK: - 原语

  private static func copy(service: String, key: String) -> Data? {
    var query = baseQuery(service: service, key: key)
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    query[kSecReturnData as String] = kCFBooleanTrue
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
    return item as? Data
  }

  private static func baseQuery(service: String, key: String) -> [String: Any] {
    let keyData = Data(key.utf8)
    return [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrGeneric as String: keyData,
      kSecAttrAccount as String: keyData,
    ]
  }
}
