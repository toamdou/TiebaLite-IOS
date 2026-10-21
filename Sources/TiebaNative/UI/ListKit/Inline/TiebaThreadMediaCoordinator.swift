// 从 TiebaPostRowInline.swift 拆出（按类型分文件，纯搬运、整类型逐字搬走）。

import Foundation

// MARK: - 媒体互斥 / 离屏暂停（原 mediaBusStore 的原生等价）

@MainActor
final class TiebaThreadMediaCoordinator {
  static let shared = TiebaThreadMediaCoordinator()

  private var activeKey: String?
  private var visibleKeys: Set<String>?
  private var pauseHandlers: [String: () -> Void] = [:]
  private var resumeHandlers: [String: () -> Void] = [:]

  private init() {}

  func register(
    key: String,
    pause: @escaping () -> Void,
    resume: (() -> Void)? = nil
  ) {
    pauseHandlers[key] = pause
    if let resume { resumeHandlers[key] = resume }
    // 可见性已上报过后才注册的媒体（行复用时才 configure）：不在可视集就先暂停。
    if let visibleKeys, !visibleKeys.contains(key) { pause() }
  }

  func unregister(key: String) {
    pauseHandlers.removeValue(forKey: key)
    resumeHandlers.removeValue(forKey: key)
    if activeKey == key { activeKey = nil }
  }

  /// 抢占总线（后激活者胜）；旧的 active 立即暂停。
  func activate(key: String) {
    let previous = activeKey
    activeKey = key
    if let previous, previous != key {
      pauseHandlers[previous]?()
    }
  }

  func deactivate(key: String) {
    if activeKey == key { activeKey = nil }
  }

  /// 列表层上报可视媒体 key；null = 未接入可见性（视为全部可见）。
  func setVisibleKeys(_ keys: Set<String>?) {
    visibleKeys = keys
    guard let keys else { return }
    for (key, pause) in pauseHandlers where !keys.contains(key) {
      pause()
    }
    for (key, resume) in resumeHandlers where keys.contains(key) {
      resume()
    }
  }

  /// 自动起播前查可见性：预取/复用的行可能已经上报过可视集且不在其中。
  func isVisible(key: String) -> Bool {
    guard let visibleKeys else { return true }
    return visibleKeys.contains(key)
  }
}
