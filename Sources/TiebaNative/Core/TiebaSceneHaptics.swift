// ============================================================
// TiebaSceneHaptics —— 场景触觉的**原生页面入口**
//
// 触觉场景表在 TiebaHaptics.swift（sceneTable，11 个场景整表下沉）。
// 页面统一经本文件入口：
//
//   原生 VC → TiebaSceneHaptics.fire("press") → 取用户覆盖档位（原生 KV，按原始串缓存）
//            → TiebaHaptics.fireScene(scene:style:waveform:)
//
// 语义（原 JS hapticForScene(scene) 逐条对齐）：
//   - 表在原生，调用方只传"场景名 + 两个用户覆盖档位"；
//   - 覆盖档位从偏好读（hapticsSceneStyles / hapticsWaveforms，JSON 字符串，
//     坏 JSON/未知键一律忽略 → nil = 用内置映射，与 JS 的 getSceneOverrides 同款）；
//     解析结果按原始 KV 串缓存（代次见 table(for:)），偏好一写入即失效。
//   - 总开关（hapticFeedback）的真相源在 TiebaHaptics 引擎层，fireScene 内部
//     已判（TiebaHaptics.isEnabled），本文件不复制第二道闸。
// ============================================================
import Foundation

enum TiebaSceneHaptics {
  /// 播放某场景的触觉（scene 名与 JS HapticsScene 逐字一致：press / toggle / …）。
  static func fire(_ scene: String) {
    TiebaHaptics.fireScene(
      scene: scene,
      style: table(for: "hapticsSceneStyles")[scene],
      waveform: table(for: "hapticsWaveforms")[scene]
    )
  }

  /// 总开关（偏好 hapticFeedback）：直接写引擎层真相源。
  static func setEnabled(_ enabled: Bool) {
    TiebaHaptics.setEnabled(enabled)
  }

  /// 引擎生命周期（启动路径：回前台预热 / 进后台销毁省电）。
  static func warmUp() { TiebaHaptics.warmUp() }

  static func shutdown() { TiebaHaptics.shutdown() }

  /// 「长按弹出大图」实时触觉（原 theme/hapticsRealtime.playImageLiftHaptic）：
  /// 长按升起动画开始时单次柔和瞬态，强度随 hapticsRealtimeStyles 档位缩放。
  static func playImageLift() {
    guard let scale = realtimeScale(for: "imageLiftPop") else { return }
    TiebaHaptics.playTransient(
      intensity: max(0.05, min(1, 0.55 * scale)),
      sharpness: 0.45
    )
  }

  /// 实时触觉档位 → 强度缩放；nil = 该效果已关闭（off），默认适中（0.8）。
  private static func realtimeScale(for effect: String) -> Double? {
    switch table(for: "hapticsRealtimeStyles")[effect] {
    case "off": return nil
    case "light": return 0.55
    case "strong": return 1
    default: return 0.8
    }
  }

  // MARK: - 覆盖表读取（按原始串失效的缓存）

  /// 已解析的覆盖表 + 它对应的原始 KV 串（代次）。
  private struct CachedTable {
    var raw: String?
    var parsed: [String: String]
  }

  /// nonisolated(unsafe)：只在主线程读写（触觉全部从 UI 事件发出，fire 的调用点
  /// 都在主线程），与同模块其它 nonisolated(unsafe) 同一条纪律。
  nonisolated(unsafe) private static var tableCache: [String: CachedTable] = [:]

  /// 取一张覆盖表（`{"press":"medium",…}`）。KV 没有版本号/变更通知、写入方
  /// （设置页 TiebaPreferences）也不在本域——所以以**原始 KV 串**当代次：串变了
  /// 就重解析，没变直接用上次的表，偏好一写入即自动失效。
  ///
  /// 为什么要缓存：触觉是最高频的反馈路径（按下/松手/切段连发），改前每次触发
  /// 要现读 2 次 SQLite + 2 次 JSONDecoder + 2 次表 JSONSerialization，全在主线程。
  private static func table(for key: String) -> [String: String] {
    let raw = TiebaPreferenceSnapshot.rawValue(key)
    if let cached = tableCache[key], cached.raw == raw { return cached.parsed }
    let parsed = parseTable(raw)
    tableCache[key] = CachedTable(raw: raw, parsed: parsed)
    return parsed
  }

  /// 原始存储串 → 表。字符串偏好的值是 JSON 串（带引号），解析失败回落原始串
  ///（与 TiebaPreferenceSnapshot.string 同语义）；表本身坏 JSON/非字典 → 空表
  ///（= 无覆盖，全部走内置映射）。
  private static func parseTable(_ raw: String?) -> [String: String] {
    guard let raw else { return [:] }
    let json: String
    if let data = raw.data(using: .utf8),
      let decoded = try? JSONDecoder().decode(String.self, from: data)
    {
      json = decoded
    } else {
      json = raw
    }
    guard let data = json.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data),
      let table = object as? [String: Any]
    else { return [:] }
    return table.compactMapValues { $0 as? String }
  }
}
