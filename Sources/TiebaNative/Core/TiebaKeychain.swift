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

  /// 进程内缓存（124）：credentials() 一次读 5 个键，未命中时每个键最多 3 次
  /// SecItemCopyMatching（no-auth/auth/legacy 回退），启动/切号路径会重复读同一批。
  /// 本进程内所有写都经过 set/delete（缓存随之更新/失效），读命中不再进 Security。
  ///
  /// 并发：命中/未命中表都是一个 Sendable 值类型，由 Mutex 保护——不是
  /// NSLock + nonisolated(unsafe) 全局可变状态（那是编译器管不到的共享可变状态）。
  /// Security 调用一律在锁外做，锁只覆盖字典读写。
  private struct CacheState: Sendable {
    var hits: [String: String] = [:]
    var misses: Set<String> = []
  }

  /// 三态：命中 / 确证未命中 / 没记录（要去问 Security）。
  private enum CacheLookup {
    case hit(String)
    case miss
    case unknown
  }

  private static let cache = TiebaMutex(CacheState())

  /// 读一个键；不存在 → nil。读序 no-auth → auth → legacy（兼容旧包写入面）。
  static func get(key: String) -> String? {
    let trimmed = key.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }
    switch cache.withLock({ state -> CacheLookup in
      if let hit = state.hits[key] { return .hit(hit) }
      if state.misses.contains(key) { return .miss }
      return .unknown
    }) {
    case .hit(let value):
      return value
    case .miss:
      return nil
    case .unknown:
      break
    }

    for service in [noAuthService, authService, baseService] {
      if let data = copy(service: service, key: key) {
        let value = String(data: data, encoding: .utf8)
        // 与旧实现一致：解码失败（非 UTF-8）时 value 为 nil → 字典赋值等于移除，
        // 该键不进任何表，下次读仍会去问 Security。
        cache.withLock { state in
          state.hits[key] = value
          state.misses.remove(key)
        }
        return value
      }
    }
    cache.withLock { _ = $0.misses.insert(key) }
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
    // 可访问性档位（本仓唯一使用、也是旧包唯一写入的一档）直接内联 SDK 常量：
    // 它是只读的 C 全局 let，在 nonisolated 上下文读取是安全的；反过来存成
    // static let 会因为 CFString 非 Sendable 报错——所以这里既不需要
    // nonisolated(unsafe)，也不需要多一个存储属性。
    addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

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
    cache.withLock { state in
      state.hits[key] = value
      state.misses.remove(key)
    }
  }

  /// 删一个键（三个 service 变体都删；不存在是 no-op，不抛——与旧包 delete 同）。
  /// 缓存同步记成未命中：删除是本进程的权威动作，之后再读不必再问 Security。
  static func delete(key: String) {
    let trimmed = key.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return }
    for service in [baseService, authService, noAuthService] {
      SecItemDelete(baseQuery(service: service, key: key) as CFDictionary)
    }
    cache.withLock { state in
      state.hits.removeValue(forKey: key)
      state.misses.insert(key)
    }
  }

  /// 列出所有 account 以 prefix 开头的键（三个 service 变体去重、排序稳定）。
  ///
  /// 为什么需要：删"本 App 的全部凭据"时不能靠 KV 里的账号列表——那条路会被"先清 KV"
  /// 打断（走查 D13-1），而 Keychain 自己记着 account 名，按它枚举与调用顺序无关。
  /// 只取属性不取 data：枚举不需要把凭据读进内存。
  static func keys(prefix: String) -> [String] {
    guard !prefix.isEmpty else { return [] }
    var found = Set<String>()
    for service in [baseService, authService, noAuthService] {
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecMatchLimit as String: kSecMatchLimitAll,
        kSecReturnAttributes as String: kCFBooleanTrue,
      ]
      var items: CFTypeRef?
      guard SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess,
        let list = items as? [[String: Any]]
      else { continue }
      for item in list {
        // account 是写入时按 UTF-8 Data 存的（见 baseQuery）；个别系统版本会回成 String，
        // 两种都认，认不出就跳过（宁可漏删一个自己也不误删别人的 service）。
        let account: String?
        if let data = item[kSecAttrAccount as String] as? Data {
          account = String(data: data, encoding: .utf8)
        } else {
          account = item[kSecAttrAccount as String] as? String
        }
        guard let account, account.hasPrefix(prefix) else { continue }
        found.insert(account)
      }
    }
    return found.sorted()
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
