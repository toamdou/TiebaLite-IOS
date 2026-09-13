// 语音/视频播放的音频会话。默认的 soloAmbient 会被静音拨片掐掉、锁屏即停，
// 播放前必须切到 .playback；播完注销并把被抢占的音乐交还。
import AVFoundation
import Foundation

@MainActor
enum TiebaAudioSession {
  private struct Handle {
    let isPlaying: () -> Bool
    let pause: () -> Void
    let resume: () -> Void
  }

  private static var handles: [String: Handle] = [:]
  /// 因系统打断而暂停的播放器：打断结束且系统给 shouldResume 才续播。
  private static var interruptedIds: [String] = []
  private static var observersInstalled = false
  /// 注册项最近一次处于播放态的时间（register 记一次，检查到 isPlaying 刷新）。
  /// unregister 只在 TiebaPostRowView.prepareForReuse 调用（该文件不在本任务
  /// 范围）：行视图被释放/漏调时靠时间戳兜底清理，避免字典无界膨胀。
  private static var lastActivity: [String: Date] = [:]
  /// 兜底阈值：isPlaying 为假且静默超过该时长才清理。
  private static let staleInterval: TimeInterval = 120

  /// 播放前对齐一次。视频 PiP 会把 mode 改成 .moviePlayback（同一 category），
  /// 所以不能只配一次就记 flag。
  static func activate() {
    installObserversIfNeeded()
    pruneStaleHandles()
    let session = AVAudioSession.sharedInstance()
    if session.category != .playback || session.mode != .default {
      try? session.setCategory(.playback, mode: .default)
    }
    try? session.setActive(true)
  }

  /// 无在播播放器时注销会话；notifyOthersOnDeactivation 让被抢占的音乐恢复。
  static func deactivateIfIdle() {
    pruneStaleHandles()
    guard !handles.values.contains(where: { $0.isPlaying() }) else { return }
    try? AVAudioSession.sharedInstance().setActive(
      false,
      options: [.notifyOthersOnDeactivation]
    )
  }

  static func register(
    id: String,
    isPlaying: @escaping () -> Bool,
    pause: @escaping () -> Void,
    resume: @escaping () -> Void
  ) {
    guard !id.isEmpty else { return }
    handles[id] = Handle(isPlaying: isPlaying, pause: pause, resume: resume)
    lastActivity[id] = Date()
    pruneStaleHandles()
  }

  static func unregister(id: String) {
    guard !id.isEmpty else { return }
    handles[id] = nil
    lastActivity[id] = nil
    interruptedIds.removeAll { $0 == id }
  }

  /// 兜底清理（见 lastActivity）：正在播的刷新时间戳、绝不清理；打断中的 id
  /// 保留（打断结束要 resume，handle 不能丢）。
  private static func pruneStaleHandles() {
    let now = Date()
    for (id, handle) in handles where handle.isPlaying() {
      lastActivity[id] = now
    }
    let stale = handles.compactMap { (id, handle) -> String? in
      guard !interruptedIds.contains(id), !handle.isPlaying() else { return nil }
      let last = lastActivity[id] ?? now
      return now.timeIntervalSince(last) > staleInterval ? id : nil
    }
    for id in stale {
      handles[id] = nil
      lastActivity[id] = nil
    }
  }

  private static func installObserversIfNeeded() {
    guard !observersInstalled else { return }
    observersInstalled = true
    let center = NotificationCenter.default

    // 来电/Siri/其它 App 抢占：暂停并记录，结束后按系统建议续播。
    center.addObserver(
      forName: AVAudioSession.interruptionNotification,
      object: AVAudioSession.sharedInstance(),
      queue: .main
    ) { note in
      // Notification 非 Sendable：先取出 Sendable 的原始值再进主 actor 区域。
      let rawType = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
      let rawOptions = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
      MainActor.assumeIsolated {
        guard let rawType,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        switch type {
        case .began:
          interruptedIds = handles.filter { $0.value.isPlaying() }.map(\.key)
          for id in interruptedIds { handles[id]?.pause() }
        case .ended:
          let shouldResume = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            .contains(.shouldResume)
          let ids = interruptedIds
          interruptedIds = []
          guard shouldResume else { return }
          for id in ids { handles[id]?.resume() }
        @unknown default:
          break
        }
      }
    }

    // 拔耳机 → 暂停（继续播就变外放）。
    center.addObserver(
      forName: AVAudioSession.routeChangeNotification,
      object: AVAudioSession.sharedInstance(),
      queue: .main
    ) { note in
      let rawReason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
      MainActor.assumeIsolated {
        guard let rawReason,
              AVAudioSession.RouteChangeReason(rawValue: rawReason) == .oldDeviceUnavailable else {
          return
        }
        for handle in handles.values where handle.isPlaying() { handle.pause() }
      }
    }
  }
}
