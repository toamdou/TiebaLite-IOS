import Foundation

/// 本地状态读写：JS 桥的后台快照入口 + UserDefaults/JSON/数值辅助。
/// 辅助方法被 +Notifications/+AutoSign 共用，故为 internal（原 private 只在
/// 单文件内可见，拆文件后必须放宽）。
extension TiebaBackgroundSync {
  func saveBackgroundSnapshot(_ payload: [String: Any]) {
    TiebaBackgroundSnapshot.shared.save(payload)
  }

  func clearBackgroundSnapshot() {
    let uid = TiebaBackgroundSnapshot.shared.uid
    TiebaBackgroundSnapshot.shared.clear()
    if !uid.isEmpty {
      defaults.removeObject(forKey: autoSignSuccessKey(uid))
      defaults.removeObject(forKey: autoSignSummaryKey(uid))
    }
  }

  // ----------------------------------------------------------------
  // JSON / 数值辅助（+Notifications/+AutoSign 共用）
  // ----------------------------------------------------------------

  func decodeJSON(_ raw: String) -> Any? {
    guard let data = raw.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data)
  }

  func saveJSON(_ payload: [String: Any], forKey key: String) {
    guard let data = try? JSONSerialization.data(withJSONObject: payload),
          let encoded = String(data: data, encoding: .utf8)
    else {
      return
    }
    defaults.set(encoded, forKey: key)
  }

  private func coerceNumber<T>(
    _ value: Any?,
    numberValue: (NSNumber) -> T,
    stringValue: (String) -> T?
  ) -> T? {
    if let number = value as? NSNumber {
      return numberValue(number)
    }
    if let string = value as? String, let parsed = stringValue(string) {
      return parsed
    }
    return nil
  }

  func int(_ value: Any?) -> Int {
    coerceNumber(value, numberValue: \.intValue, stringValue: Int.init) ?? 0
  }

  func string(_ value: Any?) -> String {
    coerceNumber(value, numberValue: \.stringValue, stringValue: Optional.some) ?? ""
  }
}
