// ============================================================
// TiebaPreferenceSnapshot —— 原生侧**只读**偏好快照（过渡期）
//
// 为什么需要：偏好（preferencesStore → unifiedDb → kv 表）在过渡期仍由 JS 写，
// 而已经整体原生化的页面（settings/about、webview、……）要在**不新建任何 TS
// 层**的前提下读到它。原生 KV（TiebaKvStore，统一 SQLite 的 kv 表）本来就是
// 同一份存储，所以这里只是一个只读视图：按 preferencesStore 的落盘格式取值。
//
// 纪律（与 docs/native-migration-plan.md「过渡期共享偏好的规则」一致）：
//   - 原生页面**每次出现时现读**（不做订阅/缓存），永远拿到最新值；
//   - JS 消费者全部删除之前，**原生只读不写**共享偏好（写 = Native 内存副本
//     与 JS 内存副本打架，JS 下次写回会覆盖）。
//
// 落盘格式（src/stores/preferencesStore.ts 的 preferencesPersistStorage）：
//   - 现行：每键一条 `tiebalite_preferences:<key>`，值是该键的 JSON 编码
//     （布尔 `true`/`false`、字符串带引号、数字裸写）；
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

  /// 取偏好键的原始存储串（JSON 字面量形态；逐键优先，旧整份 JSON 兜底）。
  static func rawValue(_ key: String) -> String? {
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

  /// 布尔偏好。非 `true`/`false`（坏值）→ fallback。
  static func bool(_ key: String, default fallback: Bool) -> Bool {
    switch rawValue(key) {
    case "true": return true
    case "false": return false
    default: return fallback
    }
  }

  /// 写一个偏好（值为 JS JSON.stringify 的字面量：字符串带引号、布尔/数字裸写）。
  /// 设置群原生化后原生成为写入方，键布局与 JS persist 逐字节一致。
  static func write(_ key: String, jsonLiteral: String) throws {
    try TiebaKvStore.shared.set(key: keyPrefix + key, value: jsonLiteral)
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
