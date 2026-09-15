// 触觉引擎 + 场景映射表——直接吃 AHAP（Apple Haptic Audio Pattern）字典。
//
// 场景表就是 AHAP 字典，经 CHHapticPattern(dictionary:) 原生解析。旧版有一层
// "事件/参数曲线中间表示"把表逐条重建成 CHHapticEvent——那是 JS 桥时代的产物
//（表在 JS，过桥要编解码），JS 已不存在，转译层随之删除。
//
// 线程：所有操作收束到主线程（CHHapticEngine / UIFeedbackGenerator 都该在主线程用）。
// 状态只被主线程读写，不需要锁；`nonisolated(unsafe)` 只声明"没有隔离保护"，不等于
// 安全——纪律同 TiebaChromeHaptics。
//
// 总开关（偏好 hapticFeedback）的真相源在本文件：TiebaHaptics.isEnabled /
// setEnabled(_:)。TiebaChrome 的 chrome 按压只是转发（含它的临时静音窗口），
// 全 App 不再有第二份 enabled 状态。
import CoreHaptics
import Foundation
import UIKit

/// 场景条目：与 JS hapticsMap 的 HapticEntry 同构。impact/selection/notification
/// 目前没有场景在用（11 个场景全是 pattern），但契约里有这几个分支，保留实现
/// ——将来加"任务成功用系统 success 通知"这类场景时无需再动引擎层。
enum TiebaHapticSceneEntry {
  case pattern([CHHapticPattern.Key: Any])
  case impact(String)
  case selection
  case notification(String)
}

/// AHAP 字典构造。时间参数仍按**毫秒**书写（与旧 JS 契约一致），进字典时 /1000
/// 转秒；强度/锋利度就是 AHAP 参数原值，不再经中间表示。
private enum Ahap {
  /// 瞬态（t）：即时的单点触觉。
  static func transient(at timeMs: Double, intensity: Double, sharpness: Double) -> [CHHapticPattern.Key: Any] {
    pattern([event(.hapticTransient, at: timeMs, durationMs: 0, intensity: intensity, sharpness: sharpness)])
  }

  /// 连续段（c）：有持续时间的纹理。
  static func continuous(
    at timeMs: Double,
    durationMs: Double,
    intensity: Double,
    sharpness: Double
  ) -> [CHHapticPattern.Key: Any] {
    pattern([event(.hapticContinuous, at: timeMs, durationMs: durationMs, intensity: intensity, sharpness: sharpness)])
  }

  /// 一整条 pattern（AHAP 顶层：Version + Pattern）。
  static func pattern(_ events: [[CHHapticPattern.Key: Any]]) -> [CHHapticPattern.Key: Any] {
    [.version: 1.0, .pattern: events]
  }

  private static func event(
    _ type: CHHapticEvent.EventType,
    at timeMs: Double,
    durationMs: Double,
    intensity: Double,
    sharpness: Double
  ) -> [CHHapticPattern.Key: Any] {
    var definition: [CHHapticPattern.Key: Any] = [
      .eventType: type.rawValue,
      .time: timeMs / 1000,
      .eventParameters: [
        parameter(.hapticIntensity, intensity),
        parameter(.hapticSharpness, sharpness),
      ],
    ]
    // 只给连续段写时长（瞬态忽略 EventDuration）。
    if type == .hapticContinuous { definition[.eventDuration] = durationMs / 1000 }
    return definition
  }

  private static func parameter(
    _ id: CHHapticEvent.ParameterID,
    _ value: Double
  ) -> [CHHapticPattern.Key: Any] {
    [.parameterID: id.rawValue, .parameterValue: value]
  }
}

/// 引擎与播放器状态。只允许主线程访问（所有入口经 onMain 收束）。
enum TiebaHapticState {
  /// 触觉总闸（偏好 hapticFeedback；启动与设置页经 TiebaHaptics.setEnabled 同步）。
  /// 真相源在引擎层：读方（TiebaSceneHaptics / chrome 按压）全走
  /// TiebaHaptics.isEnabled，chrome 文件不再持有一份 enabled。
  nonisolated(unsafe) static var enabled = true
  nonisolated(unsafe) static var engine: CHHapticEngine?
  /// pattern 播放器缓存（键=AHAP 字典的规范化序列化）：press 这类高频场景避免
  /// 每次重建 CHHapticPattern。播放器绑定在引擎上，引擎重建时必须清空
  /// （见 rebuildEngine）。
  nonisolated(unsafe) static var patternPlayers: [String: CHHapticAdvancedPatternPlayer] = [:]
  nonisolated(unsafe) static var continuousPlayers: [String: CHHapticAdvancedPatternPlayer] = [:]
  /// 连续播放器构造参数：引擎重建后按此恢复（旧包同名机制，点赞蓄力跨前后台不丢）。
  nonisolated(unsafe) static var continuousConfigs: [String: (intensity: Double, sharpness: Double)] = [:]
}

/// 触觉操作入口（日志与门控集中在这里，便于被 fireScene 复用）。
enum TiebaHaptics {
  // MARK: - 总开关（引擎层唯一真相源）

  /// 触觉总开关当前值（同步读：触觉是热路径，不做线程跳转）。
  static var isEnabled: Bool { TiebaHapticState.enabled }

  /// 设置总开关（偏好 hapticFeedback 下发；chrome 的临时静音窗口也走它）。
  static func setEnabled(_ enabled: Bool) { TiebaHapticState.enabled = enabled }

  // MARK: - 系统预设（Light/Medium/Heavy/Rigid/Soft 与 Success/Warning/Error）

  static func impact(style: String) {
    onMain {
      guard isEnabled else { return }
      performImpact(style: style)
    }
  }

  static func notify(type: String) {
    onMain {
      guard isEnabled else { return }
      performNotify(type: type)
    }
  }

  static func selection() {
    onMain {
      guard isEnabled else { return }
      performSelection()
    }
  }

  // MARK: - AHAP

  /// 直传一条 AHAP pattern（场景表之外的临时波形）。
  static func play(ahap: [CHHapticPattern.Key: Any]) {
    onMain {
      guard isEnabled else { return }
      playPattern(ahap)
    }
  }

  /// 场景触觉：style/waveform 是用户覆盖档位（null=默认）。映射表与解析
  /// 规则完整搬自 JS hapticsMap.resolveHapticEntry，参数不许"顺手优化"。
  static func fireScene(scene: String, style: String?, waveform: String?) {
    onMain {
      guard isEnabled else { return }
      guard let entry = resolveScene(scene: scene, style: style, waveform: waveform) else {
        return
      }
      switch entry {
      case .pattern(let ahap):
        playPattern(ahap)
      case .impact(let style):
        performImpact(style: style)
      case .selection:
        performSelection()
      case .notification(let type):
        performNotify(type: type)
      }
    }
  }

  /// 单次瞬态（强度/锋利度由调用方按偏好解析，见 TiebaSceneHaptics.playImageLift）。
  static func playTransient(intensity: Double, sharpness: Double) {
    onMain {
      guard isEnabled else { return }
      playPattern(Ahap.transient(at: 0, intensity: intensity, sharpness: sharpness))
    }
  }


  // MARK: - 引擎生命周期

  /// 预热引擎（App 回前台 / 总开关打开时调用）。原生 observer 与 JS 生命周期
  /// 都会调：已预热则直接返回——重复 rebuild 会停掉刚建好的引擎并清空播放器缓存。
  static func warmUp() {
    onMain {
      guard TiebaHapticState.engine == nil else { return }
      rebuildEngine()
    }
  }

  /// 销毁引擎（App 进后台 / 总开关关闭时调用）：省电，且防止后台震动。
  static func shutdown() {
    onMain {
      destroyEngineNow()
    }
  }

  // MARK: - 连续播放器（实时手势跟随：点赞蓄力）

  static func createContinuousPlayer(
    playerId: String,
    initialIntensity: Double,
    initialSharpness: Double
  ) {
    onMain {
      // 与旧包一致：创建不门控总开关，只落配置；引擎未就绪时等预热时恢复
      // （JS 侧 rtCreatePlayer 同样不门控，纪律是"stop 一定不门控、create/start
      // 不制造半空手势"）。
      TiebaHapticState.continuousConfigs[playerId] = (
        intensity: initialIntensity,
        sharpness: initialSharpness
      )
      createContinuousPlayerNow(
        playerId: playerId,
        intensity: initialIntensity,
        sharpness: initialSharpness
      )
    }
  }

  static func startContinuousPlayer(playerId: String) {
    onMain {
      guard isEnabled else { return }
      guard let player = TiebaHapticState.continuousPlayers[playerId] else { return }
      try? player.start(atTime: CHHapticTimeImmediate)
    }
  }

  static func updateContinuousPlayer(
    playerId: String,
    intensityControl: Double,
    sharpnessControl: Double
  ) {
    onMain {
      guard let player = TiebaHapticState.continuousPlayers[playerId] else { return }
      let parameters = [
        CHHapticDynamicParameter(
          parameterID: .hapticIntensityControl,
          value: Float(intensityControl),
          relativeTime: 0
        ),
        CHHapticDynamicParameter(
          parameterID: .hapticSharpnessControl,
          value: Float(sharpnessControl),
          relativeTime: 0
        ),
      ]
      try? player.sendParameters(parameters, atTime: 0)
    }
  }

  static func stopContinuousPlayer(playerId: String) {
    onMain {
      guard let player = TiebaHapticState.continuousPlayers[playerId] else { return }
      try? player.stop(atTime: CHHapticTimeImmediate)
    }
  }

  // MARK: - 场景映射表（替 JS HAPTICS_MAP）

  /// AHAP 字典的键类型不是 Sendable（值是 Any），但两张表**静态初始化时一次性
  /// 建好、此后只读**（没有任何注册/追加路径），与 TiebaRouteTable.entries 同一条
  /// 不变量——nonisolated(unsafe) 只声明"没有隔离保护"，不是可写共享状态。
  /// 全部为瞬态组合（仅 like/sheet-present/long-press 带连续段），无参数曲线
  /// （本仓纪律：需要瞬态与带曲线的连续段并存时分两次调用）。
  nonisolated(unsafe) private static let sceneTable: [String: TiebaHapticSceneEntry] = [
    // 清脆轻点（对应旧 Light 手感）
    "press": .pattern(Ahap.transient(at: 0, intensity: 0.7, sharpness: 0.6)),
    // 锋利小 click（selection 质感）
    "toggle": .pattern(Ahap.transient(at: 0, intensity: 0.5, sharpness: 1.0)),
    "segment": .pattern(Ahap.transient(at: 0, intensity: 0.55, sharpness: 0.85)),
    // 点赞 pop：重击 + 70ms 短嗡尾（情绪峰值，明显重于按压）
    "like": .pattern(Ahap.pattern([
      Ahap.transient(at: 0, intensity: 1.0, sharpness: 0.8),
      Ahap.continuous(at: 0, durationMs: 70, intensity: 0.4, sharpness: 0.35),
    ])),
    // 收藏：双击确认节奏
    "favorite": .pattern(Ahap.pattern([
      Ahap.transient(at: 0, intensity: 0.7, sharpness: 0.45),
      Ahap.transient(at: 90, intensity: 1.0, sharpness: 0.35),
    ])),
    // 浮层展开：柔和短纹理
    "sheet-present": .pattern(Ahap.continuous(at: 0, durationMs: 90, intensity: 0.3, sharpness: 0.25)),
    // 长按菜单开启：低锋利度软提示
    "long-press": .pattern(Ahap.continuous(at: 0, durationMs: 60, intensity: 0.3, sharpness: 0.2)),
    // 破坏性确认：沉闷重击两拍（警示节奏）
    "destructive": .pattern(Ahap.pattern([
      Ahap.transient(at: 0, intensity: 1.0, sharpness: 0.25),
      Ahap.transient(at: 130, intensity: 1.0, sharpness: 0.2),
    ])),
    // 成功：上行三连（渐强渐锐，积极收尾）
    "action-success": .pattern(Ahap.pattern([
      Ahap.transient(at: 0, intensity: 0.55, sharpness: 0.5),
      Ahap.transient(at: 80, intensity: 0.75, sharpness: 0.75),
      Ahap.transient(at: 160, intensity: 1.0, sharpness: 1.0),
    ])),
    // 警示：先锐后钝的双拍
    "action-warning": .pattern(Ahap.pattern([
      Ahap.transient(at: 0, intensity: 0.9, sharpness: 0.9),
      Ahap.transient(at: 120, intensity: 0.9, sharpness: 0.3),
    ])),
    // 失败：下行（重击落空感）
    "action-fail": .pattern(Ahap.pattern([
      Ahap.transient(at: 0, intensity: 1.0, sharpness: 0.9),
      Ahap.transient(at: 110, intensity: 0.7, sharpness: 0.35),
    ])),
  ]

  /// 波形预设（替 JS WAVEFORM_PRESETS）：纯瞬态组合，替换内置波形后仍会被
  /// 力度档位缩放叠加（与内置波形走同一条缩放路径）。
  nonisolated(unsafe) private static let waveformTable: [String: [CHHapticPattern.Key: Any]] = [
    // 只振一下：单次清脆轻点（用户诉求「选择只震动一次」的通用解）
    "single": Ahap.transient(at: 0, intensity: 0.7, sharpness: 0.6),
    // 双脉冲：两下快而轻（确认节奏，比内置多拍模式收敛）
    "double": Ahap.pattern([
      Ahap.transient(at: 0, intensity: 0.7, sharpness: 0.6),
      Ahap.transient(at: 90, intensity: 0.55, sharpness: 0.45),
    ]),
    // 渐强三连：上行渐锐（积极收尾，但比 action-success 内置轻）
    "rising": Ahap.pattern([
      Ahap.transient(at: 0, intensity: 0.45, sharpness: 0.4),
      Ahap.transient(at: 80, intensity: 0.7, sharpness: 0.7),
      Ahap.transient(at: 160, intensity: 1.0, sharpness: 1.0),
    ]),
    // 轻柔：单次低强度柔冲击（不想被打扰的场合）
    "soft": Ahap.transient(at: 0, intensity: 0.3, sharpness: 0.25),
  ]

  /// 力度档位 → 全事件 intensity 缩放系数（上限钳在 1）。
  private static let styleScale: [String: Double] = ["light": 0.6, "medium": 0.8, "heavy": 1]

  /// 解析场景 → 最终条目；nil = 静音（用户选 off）。规则逐条对齐 JS
  /// resolveHapticEntry：
  ///   1. 波形覆盖只作用于 pattern，且先于力度缩放（波形替换 events，
  ///      力度再在当前 events 上叠加）。
  ///   2. default / 未知档位 / 旧档位 rigid·soft（对 AHAP 模式无意义）→ 内置
  ///      映射，但波形覆盖仍然生效；未知档位不做缩放。
  ///   3. off → 静音；其余档位按系数缩放 intensity。
  private static func resolveScene(
    scene: String,
    style: String?,
    waveform: String?
  ) -> TiebaHapticSceneEntry? {
    guard let base = sceneTable[scene] else { return nil }
    let requestedStyle = style ?? "default"

    var wavePattern: [CHHapticPattern.Key: Any]?
    if case .pattern = base, let waveform, waveform != "default" {
      wavePattern = waveformTable[waveform]
    }

    if requestedStyle == "default" || requestedStyle == "rigid" || requestedStyle == "soft" {
      if let wavePattern { return .pattern(wavePattern) }
      return base
    }
    if requestedStyle == "off" { return nil }

    guard case .pattern(let basePattern) = base else { return base }
    let pattern = wavePattern ?? basePattern
    guard let factor = styleScale[requestedStyle] else { return .pattern(pattern) }
    return .pattern(scalingIntensity(pattern, factor: factor))
  }

  /// 力度档位缩放：只动 intensity（sharpness 不变），下限 0.05/上限 1
  /// ——与 JS scaleIntensity 逐字一致。值取 NSNumber 读法：表里写 0.7 或 1
  /// 都能命中（Double / Int 字面量都桥接成 NSNumber）。
  private static func scalingIntensity(
    _ pattern: [CHHapticPattern.Key: Any],
    factor: Double
  ) -> [CHHapticPattern.Key: Any] {
    guard let events = pattern[.pattern] as? [[CHHapticPattern.Key: Any]] else { return pattern }
    var copy = pattern
    copy[.pattern] = events.map { event -> [CHHapticPattern.Key: Any] in
      guard let parameters = event[.eventParameters] as? [[CHHapticPattern.Key: Any]] else {
        return event
      }
      var scaledEvent = event
      scaledEvent[.eventParameters] = parameters.map { parameter -> [CHHapticPattern.Key: Any] in
        guard
          (parameter[.parameterID] as? String) == CHHapticEvent.ParameterID.hapticIntensity.rawValue,
          let value = parameter[.parameterValue] as? NSNumber
        else { return parameter }
        var scaled = parameter
        scaled[.parameterValue] = max(0.05, min(1, value.doubleValue * factor))
        return scaled
      }
      return scaledEvent
    }
    return copy
  }

  // MARK: - 引擎实现

  /// 创建并启动引擎（幂等：已有引擎先停重建，与旧包 createAndStartHapticEngine
  /// 一致）。重建后 pattern 缓存清空、连续播放器按配置恢复。
  private static func rebuildEngine() {
    let state = TiebaHapticState.self
    state.engine?.stop(completionHandler: nil)
    state.engine = nil
    // 播放器绑定在旧引擎上：不清缓存会复用"死播放器"，start 静默失败
    // ——旧包重建引擎时只恢复连续播放器、pattern 缓存留着，重启后场景触觉
    // 全哑；这里一并清掉（迁移时修掉的包内缺陷）。
    state.patternPlayers.removeAll()
    state.continuousPlayers.removeAll()
    guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
    guard let engine = try? CHHapticEngine() else { return }
    // 只播触觉、不播音频：降低触觉延迟（旧包同设置）。
    engine.playsHapticsOnly = true
    // 系统打断/引擎复位后 CoreHaptics 要求显式重启：不重启则此后全静音，
    // 直到下次前后台切换（旧包靠 resetHandler 自恢复，保留该行为）。
    engine.resetHandler = {
      DispatchQueue.main.async {
        TiebaHaptics.rebuildEngine()
      }
    }
    // 引擎被停机（音频打断/系统回收）时也重建：只挂 resetHandler 的话，
    // 停机后播放器 start 会静默失败，此后所有触觉一直哑到下次前后台。
    engine.stoppedHandler = { _ in
      DispatchQueue.main.async {
        TiebaHaptics.rebuildEngine()
      }
    }
    do {
      try engine.start()
    } catch {
      return
    }
    state.engine = engine
    // 连续播放器按配置恢复；枚举期间只读 configs，写入的是 continuousPlayers。
    for (playerId, config) in state.continuousConfigs {
      createContinuousPlayerNow(
        playerId: playerId,
        intensity: config.intensity,
        sharpness: config.sharpness
      )
    }
  }

  /// 销毁引擎与其上的全部播放器；continuousConfigs 保留（下次预热时恢复）。
  private static func destroyEngineNow() {
    let state = TiebaHapticState.self
    for player in state.patternPlayers.values {
      try? player.stop(atTime: CHHapticTimeImmediate)
    }
    for player in state.continuousPlayers.values {
      try? player.stop(atTime: CHHapticTimeImmediate)
    }
    state.engine?.stop(completionHandler: nil)
    state.engine = nil
    state.patternPlayers.removeAll()
    state.continuousPlayers.removeAll()
  }

  /// 播放一条 AHAP pattern。播放器按指纹缓存复用（press 这类高频场景）。
  private static func playPattern(_ ahap: [CHHapticPattern.Key: Any]) {
    guard let events = ahap[.pattern] as? [[CHHapticPattern.Key: Any]], !events.isEmpty else {
      return
    }
    let state = TiebaHapticState.self
    // 懒建：预热（AppState active）与首个触觉之间存在竞态，引擎没起来时
    // 就地补建，避免"启动后第一次按压没振"（旧包在引擎未初始化时静默丢弃）。
    if state.engine == nil {
      rebuildEngine()
    }
    guard let engine = state.engine else { return }

    let key = patternKey(ahap)
    if let cached = state.patternPlayers[key] {
      try? cached.start(atTime: CHHapticTimeImmediate)
      return
    }
    do {
      let pattern = try CHHapticPattern(dictionary: ahap)
      let player = try engine.makeAdvancedPlayer(with: pattern)
      state.patternPlayers[key] = player
      try player.start(atTime: CHHapticTimeImmediate)
    } catch {
      // 触觉尽力而为：设备不支持/引擎异常时不影响 UI（旧包同样是 catch + 忽略）。
    }
  }

  /// pattern 指纹：AHAP 字典转 JSON 兼容形状（键取 rawValue，数组逐层递归）后
  /// 按 key 排序序列化——同一 pattern 每次得到同一字符串。只用于缓存去重。
  private static func patternKey(_ ahap: [CHHapticPattern.Key: Any]) -> String {
    guard
      let data = try? JSONSerialization.data(
        withJSONObject: jsonCompatible(ahap),
        options: [.sortedKeys]
      )
    else { return "" }
    return String(decoding: data, as: UTF8.self)
  }

  /// [CHHapticPattern.Key: Any] → JSONSerialization 能吃的形状（String 键 + 基础类型）。
  private static func jsonCompatible(_ value: Any) -> Any {
    if let dictionary = value as? [CHHapticPattern.Key: Any] {
      var out: [String: Any] = [:]
      for (key, entry) in dictionary { out[key.rawValue] = jsonCompatible(entry) }
      return out
    }
    if let array = value as? [Any] {
      return array.map(jsonCompatible)
    }
    return value
  }

  /// 建一个 30 秒连续底噪播放器（旧包 duration: 30000——CoreHaptics 单位是秒，
  /// 即 8 小时余；点赞蓄力靠 stop 收尾，不靠时长自然结束）。
  private static func createContinuousPlayerNow(
    playerId: String,
    intensity: Double,
    sharpness: Double
  ) {
    let state = TiebaHapticState.self
    guard let engine = state.engine else { return }
    if let existing = state.continuousPlayers[playerId] {
      try? existing.stop(atTime: CHHapticTimeImmediate)
      state.continuousPlayers.removeValue(forKey: playerId)
    }
    let event = CHHapticEvent(
      eventType: .hapticContinuous,
      parameters: [
        CHHapticEventParameter(parameterID: .hapticIntensity, value: Float(intensity)),
        CHHapticEventParameter(parameterID: .hapticSharpness, value: Float(sharpness)),
      ],
      relativeTime: 0,
      duration: 30000
    )
    do {
      let pattern = try CHHapticPattern(events: [event], parameters: [])
      state.continuousPlayers[playerId] = try engine.makeAdvancedPlayer(with: pattern)
    } catch {
      // 尽力而为（旧包同：创建失败只打日志）。
    }
  }

  // MARK: - 系统预设实现（无门控/无线程跳转，调用方已完成）

  /// 反馈生成器的宿主 view：无 view 的 init 已标待废弃
  ///（UIFeedbackGenerator.h:21 / UIImpactFeedbackGenerator.h:38），替代形要求绑定
  /// 一个 view。取前台活跃场景的 keyWindow；无窗口（后台/启动中）没有可归属的 UI
  /// 上下文，直接不发。assumeIsolated 依据：入口全经 onMain 收束，恒在主线程。
  private static var feedbackHostView: UIView? {
    MainActor.assumeIsolated {
      UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .first { $0.activationState == .foregroundActive }?
        .keyWindow
    }
  }

  private static func performImpact(style: String) {
    let feedbackStyle: UIImpactFeedbackGenerator.FeedbackStyle
    switch style {
    case "heavy": feedbackStyle = .heavy
    case "medium": feedbackStyle = .medium
    case "rigid": feedbackStyle = .rigid
    case "soft": feedbackStyle = .soft
    default: feedbackStyle = .light
    }
    guard let host = feedbackHostView else { return }
    let generator = UIImpactFeedbackGenerator(style: feedbackStyle, view: host)
    generator.prepare()
    generator.impactOccurred()
  }

  private static func performNotify(type: String) {
    let feedbackType: UINotificationFeedbackGenerator.FeedbackType
    switch type {
    case "success": feedbackType = .success
    case "warning": feedbackType = .warning
    case "error": feedbackType = .error
    default: return // 未知通知类型不反馈（TS 枚举约束内不会发生）
    }
    guard let host = feedbackHostView else { return }
    let generator = UINotificationFeedbackGenerator(view: host)
    generator.prepare()
    generator.notificationOccurred(feedbackType)
  }

  private static func performSelection() {
    guard let host = feedbackHostView else { return }
    let generator = UISelectionFeedbackGenerator(view: host)
    generator.prepare()
    generator.selectionChanged()
  }
}
