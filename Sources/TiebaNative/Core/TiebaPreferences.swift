import UIKit
import os

enum TiebaPreferences {
  private static let storagePrefix = "tiebalite_preferences"
  private static let log = Logger(subsystem: "com.tiebalite.app", category: "preferences")

  // MARK: - 读（缺失/坏值 → fallback，与 JS sanitizePreferenceValue 同语义）

  static func bool(_ key: String, default fallback: Bool) -> Bool {
    TiebaPreferenceSnapshot.bool(key, default: fallback)
  }

  static func number(_ key: String, default fallback: Double) -> Double {
    TiebaPreferenceSnapshot.number(key) ?? fallback
  }

  static func string(_ key: String, default fallback: String) -> String {
    TiebaPreferenceSnapshot.string(key) ?? fallback
  }

  /// 枚举键白名单兜底：历史脏值不得进入选择器当前值（原 safePick 防线）。
  static func string(_ key: String, allowed: [String], default fallback: String) -> String {
    let value = TiebaPreferenceSnapshot.string(key) ?? fallback
    return allowed.contains(value) ? value : fallback
  }

  // MARK: - 写（类型化 API；返回是否落盘成功：调用方必须据此决定回推/成功提示）

  @discardableResult
  static func set(_ key: String, bool value: Bool) -> Bool {
    write(key) { try TiebaPreferenceSnapshot.write(key, bool: value) }
  }

  @discardableResult
  static func set(_ key: String, string value: String) -> Bool {
    write(key) { try TiebaPreferenceSnapshot.write(key, string: value) }
  }

  @discardableResult
  static func set(_ key: String, number value: Double) -> Bool {
    write(key) { try TiebaPreferenceSnapshot.write(key, number: value) }
  }

  /// 恢复默认：逐键 + 旧整份 JSON 同在前缀下，一次清掉。
  static func resetAll() throws {
    try TiebaKvStore.shared.clear(prefix: storagePrefix, preserveKeys: [])
    TiebaPreferenceSnapshot.invalidateCache()
  }

  /// 数字偏好的**显示值**（picker 行 value，把偏好填回表单）：JS JSON.stringify
  /// 的数字形态，整数不带 ".0"（1 而非 1.0）。写入路径不再经过它——落盘由
  /// TiebaPreferenceSnapshot.write(number:) 直出同形字节；保留是因为
  /// TiebaFormPageController / 设置页（文件外）仍在用它填显示值。
  static func numberLiteral(_ value: Double) -> String {
    value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
  }

  private static func write(_ key: String, _ store: () throws -> Void) -> Bool {
    do {
      try store()
      return true
    } catch {
      log.error("preference write failed \(key, privacy: .public): \(String(describing: error), privacy: .public)")
      return false
    }
  }
}
