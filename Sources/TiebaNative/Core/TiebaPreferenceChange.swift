// 偏好写入的唯一广播口（原 JS preferencesStore 的订阅语义）：写成功即发一次，
// 在屏页面订阅后立刻刷新 —— 不再靠"下次出现时现读偏好"兜着。
import Foundation

extension Notification.Name {
  static let tiebaPreferenceDidChange = Notification.Name("TiebaPreferenceDidChange")
}

enum TiebaPreferenceChange {
  private static let keyUserInfoKey = "key"

  /// 偏好键（与 KV 键同名，不带 `tiebalite_preferences:` 前缀）。
  static func post(_ key: String) {
    NotificationCenter.default.post(
      name: .tiebaPreferenceDidChange,
      object: nil,
      userInfo: [keyUserInfoKey: key]
    )
  }

  /// 订阅某个键（key == nil = 任意键）。token 释放即失效（dispose bag 的家规写法）。
  static func observe(key: String? = nil, _ handler: @escaping () -> Void) -> NSObjectProtocol {
    NotificationCenter.default.addObserver(
      forName: .tiebaPreferenceDidChange,
      object: nil,
      queue: .main
    ) { note in
      guard let changed = note.userInfo?[keyUserInfoKey] as? String else { return }
      guard key == nil || key == changed else { return }
      handler()
    }
  }

  /// 订阅一组键（任一变化即回调一次）。
  static func observe(keys: [String], _ handler: @escaping () -> Void) -> NSObjectProtocol {
    NotificationCenter.default.addObserver(
      forName: .tiebaPreferenceDidChange,
      object: nil,
      queue: .main
    ) { note in
      guard let changed = note.userInfo?[keyUserInfoKey] as? String else { return }
      guard keys.contains(changed) else { return }
      handler()
    }
  }
}
