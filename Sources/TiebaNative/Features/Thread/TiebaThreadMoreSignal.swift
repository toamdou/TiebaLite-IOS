import Foundation

/// 帖子「更多」sheet → 帖子页的动作通道（原 JS 的 DeviceEventEmitter('thread-more-action')
/// 的原生替身）。普通 Swift 类型，无 Expo 依赖：sheet 发布、帖子页按 threadId 观察。
///
/// 观察方必须在主线程调度动作（sheet 收起动画期间不能 present 新窗口），本类型
/// 只负责同步投递。
@MainActor
final class TiebaThreadMoreSignal {
  enum Action: String {
    case seeLz
    case sort
    case jump
    case share
    case delete
  }

  static let shared = TiebaThreadMoreSignal()

  private var observers: [UUID: (String, Action) -> Void] = [:]

  private init() {}

  func observe(_ handler: @escaping (String, Action) -> Void) -> UUID {
    let token = UUID()
    observers[token] = handler
    return token
  }

  func remove(_ token: UUID) {
    observers.removeValue(forKey: token)
  }

  func post(threadId: String, action: Action) {
    for handler in observers.values {
      handler(threadId, action)
    }
  }
}
