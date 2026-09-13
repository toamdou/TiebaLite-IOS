// 统一 JSON 容错读取/编码（全仓唯一实现）。此前 ForumAPI / Session / ProfileAPI /
// SocialAPI / FollowedForums / MessageAPI / UserAPI / VisitHistoryStore 各有一份
// 同名 jsonString/jsonInt/... 私有副本，语义出入（String-only vs NSNumber 兜底、
// bool 是否认 "0"/"false"）靠人肉保持同步——收敛到这里，键序 = 首个非空命中。
import Foundation

enum TiebaJSON {
  // MARK: - 按键读取（variadic keys，顺序即优先级）

  /// 首个非空字符串：String 原样、NSNumber 转十进制串（uid/timestamp 常被服务端
  /// 发成数字，只认 String 会静默丢字段）。
  static func string(_ object: [String: Any]?, _ keys: String...) -> String? {
    for key in keys {
      guard let value = object?[key] else { continue }
      if let text = value as? String, !text.isEmpty { return text }
      if let number = value as? NSNumber { return number.stringValue }
    }
    return nil
  }

  static func int(_ object: [String: Any]?, _ keys: String...) -> Int? {
    for key in keys {
      guard let value = object?[key] else { continue }
      if let number = value as? NSNumber { return number.intValue }
      if let text = value as? String, let number = Int(text) { return number }
    }
    return nil
  }

  static func double(_ object: [String: Any]?, _ keys: String...) -> Double? {
    for key in keys {
      guard let value = object?[key] else { continue }
      if let number = value as? NSNumber { return number.doubleValue }
      if let text = value as? String, let number = Double(text) { return number }
    }
    return nil
  }

  /// true：Bool / 非零 NSNumber / "1" / "true"；false：Bool / 零 NSNumber / "0" /
  /// "false"；其余 nil（调用方决定默认值，不在这里发明默认）。
  static func bool(_ object: [String: Any]?, _ keys: String...) -> Bool? {
    for key in keys {
      guard let value = object?[key] else { continue }
      if let flag = boolValue(value) { return flag }
    }
    return nil
  }

  /// 首个「存在且是数组」的键；命中但值不是数组 → []（不再回退后续键，与
  /// 旧 SocialAPI.jsonList 的 find 语义一致）。
  static func list(_ object: [String: Any], _ keys: [String]) -> [[String: Any]] {
    for key in keys {
      if let value = object[key] { return (value as? [[String: Any]]) ?? [] }
    }
    return []
  }

  // MARK: - 单值读取（调用方已取到 one 个 Any?）

  static func stringValue(_ value: Any?) -> String? {
    if let text = value as? String, !text.isEmpty { return text }
    if let number = value as? NSNumber { return number.stringValue }
    return nil
  }

  static func intValue(_ value: Any?) -> Int? {
    if let number = value as? NSNumber { return number.intValue }
    if let text = value as? String, let number = Int(text) { return number }
    return nil
  }

  static func doubleValue(_ value: Any?) -> Double? {
    if let number = value as? NSNumber { return number.doubleValue }
    if let text = value as? String, let number = Double(text) { return number }
    return nil
  }

  static func boolValue(_ value: Any?) -> Bool? {
    if let flag = value as? Bool { return flag }
    if let number = value as? NSNumber { return number.intValue != 0 }
    if let text = value as? String {
      if text == "1" || text.lowercased() == "true" { return true }
      if text == "0" || text.lowercased() == "false" { return false }
    }
    return nil
  }

  // MARK: - 解析 / 编码

  static func object(from text: String) -> [String: Any]? {
    guard let data = text.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }

  static func list(from text: String) -> [[String: Any]]? {
    guard let data = text.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
  }

  /// JSON 文本；非法 JSON 对象 → nil（调用方决定抛错还是跳过，这里不吞成 "{}"）。
  static func stringify(_ object: Any) -> String? {
    guard JSONSerialization.isValidJSONObject(object),
      let data = try? JSONSerialization.data(withJSONObject: object)
    else { return nil }
    return String(data: data, encoding: .utf8)
  }
}
