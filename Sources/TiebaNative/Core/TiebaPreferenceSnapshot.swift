// ============================================================
// TiebaPreferenceSnapshot —— 原生偏好的类型化读/写门面（唯一落盘点）
//
// 为什么单独一份：偏好存在统一 SQLite 的 kv 表（TiebaKvStore），落盘格式沿用
// 原 JS preferencesStore 的 preferencesPersistStorage（既有数据不做迁移），
// 已经整体原生化的页面不新建任何 TS 层，直接按同一格式读写。
//
// 纪律：
//   - 原生页面**每次出现时现读**（不做订阅），永远拿到最新值——现读的代价由
//     进程内读缓存承担（见 cache 注释），SQLite 点查不再落在行构造路径上；
//   - 写只有 store 一条路径（落盘 + 更新缓存 + 广播 TiebaPreferenceChange），不手拼字面量。
//
// 落盘格式（与原 JS 逐字节一致，读写都用 JSONEncoder/JSONDecoder 保证）：
//   - 现行：每键一条 `tiebalite_preferences:<key>`，值是该键的 JSON 编码
//     （布尔裸 `true`/`false`、字符串带引号、数字整型不带 `.0`）；
//   - 旧版：整份 JSON 存在 `tiebalite_preferences`（{preferences:{…}} 或裸对象），
//     现行 getItem 首次读取后拆成逐键并删除该键——这里保留同一条兼容读法。
//
// 读不到（键不存在/解析失败）→ nil / 调用方默认值：与 JS 的
// sanitizePreferenceValue 同语义（坏值回滚默认，不猜、不抛）。
// ============================================================
import Foundation

enum TiebaPreferenceSnapshot {
  /// preferencesStore 的 PREFERENCES_STORAGE_KEY（逐键存储 = 该键 + ":" + 偏好名）。
  private static let storageKey = "tiebalite_preferences"
  private static let keyPrefix = "tiebalite_preferences:"

  // MARK: - 进程内读缓存
  //
  // 偏好读遍布行构造路径（feed 行 Options.current() 每页 5 键、搜索每行 1 键、
  // 消息行时间标签逐行读），每键一次 SQLite 点查累计在页面构造上。缓存以
  // 「键 → 原始存储串或 .some(nil)（确证缺失，含旧整份 JSON 的 miss）」记忆化：
  //   - 写路径 store() 是唯一落盘点（文件头纪律），顺手更新缓存；
  //   - 全清/恢复默认（两个显式动作）调 invalidateCache()；
  //   - 本仓不存在绕过这里直写偏好键的路径；跨进程不适用（无扩展写共享库）。
  private static let cacheLock = NSLock()
  nonisolated(unsafe) private static var cache: [String: String?] = [:]

  /// 清空读缓存（KV 层全清/偏好前缀清空后必须调用，否则旧值在进程内复活）。
  static func invalidateCache() {
    cacheLock.withLock { cache.removeAll() }
  }

  /// 取偏好键的原始存储串（JSON 字面量形态；逐键优先，旧整份 JSON 兜底）。
  static func rawValue(_ key: String) -> String? {
    cacheLock.withLock {
      if let cached = cache[key] { return cached }
      let resolved = resolveRawValue(key)
      cache[key] = resolved
      return resolved
    }
  }

  private static func resolveRawValue(_ key: String) -> String? {
    if let perKey = TiebaKvStore.shared.get(key: keyPrefix + key) {
      return perKey
    }
    return legacyValue(key)
  }

  /// 字符串偏好。值按 JSON 串解析；解析失败（历史坏值/裸串）回落原始串
  /// ——与 JS parseStoredPreferenceValue 的语义一致。
  static func string(_ key: String) -> String? {
    guard let raw = rawValue(key) else { return nil }
    if let data = raw.data(using: .utf8),
      let decoded = try? JSONDecoder().decode(String.self, from: data)
    {
      return decoded
    }
    return raw
  }

  /// 布尔偏好。非 `true`/`false` 字面量（历史坏值，含带引号的字符串）→ nil。
  static func bool(_ key: String) -> Bool? {
    decoded(Bool.self, key)
  }

  /// 布尔偏好 + 默认值（调用面最广的签名）。坏值/缺失 → fallback。
  static func bool(_ key: String, default fallback: Bool) -> Bool {
    bool(key) ?? fallback
  }

  /// 数字偏好（整型/小数同一条解码路径）。非有限值（越界坏值）→ nil。
  static func number(_ key: String) -> Double? {
    guard let value = decoded(Double.self, key), value.isFinite else { return nil }
    return value
  }

  /// JSON 字面量 → 类型值（不抛：坏值即 nil，默认值由调用方给）。
  private static func decoded<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
    guard let raw = rawValue(key), let data = raw.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(type, from: data)
  }

  // MARK: - 写（类型化：唯一落盘点 + 唯一广播点）

  /// 写布尔：落盘裸 `true`/`false`。
  static func write(_ key: String, bool value: Bool) throws {
    try store(key, JSONEncoder().encode(value))
  }

  /// 写字符串：落盘带引号的 JSON 串。
  static func write(_ key: String, string value: String) throws {
    try store(key, JSONEncoder().encode(value))
  }

  /// 写数字：JSONEncoder 的 Double 形态——整型值输出 `400`（不带 `.0`）、小数
  /// 输出最短往返表示，与 JS JSON.stringify 逐字节一致（手写 numberLiteral 不再
  /// 参与写入；它只服务表单显示值）。非有限值 encode 抛错，不落坏字面量。
  static func write(_ key: String, number value: Double) throws {
    try store(key, JSONEncoder().encode(value))
  }

  /// 落盘 + 广播：键布局 `tiebalite_preferences:<key>`，值 = JSON 字面量字节。
  private static func store(_ key: String, _ encoded: Data) throws {
    // JSONEncoder 输出恒为 UTF-8：String(decoding:) 不产生第二错误分支。
    let value = String(decoding: encoded, as: UTF8.self)
    try TiebaKvStore.shared.set(key: keyPrefix + key, value: value)
    cacheLock.withLock { cache[key] = value }
    // 唯一写入点即广播点：在屏页面订阅后立刻刷新（不再等"下次出现时现读"）。
    TiebaPreferenceChange.post(key)
  }

  // MARK: - 旧整份 JSON（{preferences:{…}} 或裸对象）

  private static func legacyValue(_ key: String) -> String? {
    guard let legacy = TiebaKvStore.shared.get(key: storageKey),
      let data = legacy.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data),
      let root = object as? [String: Any]
    else { return nil }
    let preferences = (root["preferences"] as? [String: Any]) ?? root
    guard let value = preferences[key] else { return nil }
    // 归一成"逐键存储那种 JSON 字面量"，让上面的解析只有一条路径。
    if let encoded = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
      let text = String(data: encoded, encoding: .utf8)
    {
      return text
    }
    return nil
  }
}
