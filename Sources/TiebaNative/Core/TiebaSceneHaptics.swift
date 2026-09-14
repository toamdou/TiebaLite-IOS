// ============================================================
// TiebaSceneHaptics —— 场景触觉的**原生页面入口**
//
// 触觉场景表在 TiebaHaptics.swift（sceneTable，11 个场景整表下沉）。
// 页面统一经本文件入口：
//
//   原生 VC → TiebaSceneHaptics.fire("press") → 用户覆盖档位（内存表）
//            → TiebaHaptics.fireScene(scene:style:waveform:)
//
// 语义（原 JS hapticForScene(scene) 逐条对齐）：
//   - 表在原生，调用方只传"场景名 + 两个用户覆盖档位"；
//   - 覆盖档位从偏好读（hapticsSceneStyles / hapticsWaveforms，JSON 字符串，
//     坏 JSON/未知键一律忽略 → nil = 用内置映射，与 JS 的 getSceneOverrides 同款）；
//     偏好写入经 TiebaPreferenceChange 广播，订阅回调里重读，fire 只查内存表。
//   - 总开关（hapticFeedback）的真相源在 TiebaHaptics 引擎层，fireScene 内部
//     已判（TiebaHaptics.isEnabled），本文件不复制第二道闸。
// ============================================================
import Foundation

enum TiebaSceneHaptics {
  /// 播放某场景的触觉（scene 名与 JS HapticsScene 逐字一致：press / toggle / …）。
  static func fire(_ scene: String) {
    loadIfNeeded()
    TiebaHaptics.fireScene(
      scene: scene,
      style: tables[.sceneStyles]?[scene],
      waveform: tables[.waveforms]?[scene]
    )
  }

  /// 总开关（偏好 hapticFeedback）：直接写引擎层真相源。
  static func setEnabled(_ enabled: Bool) {
    TiebaHaptics.setEnabled(enabled)
  }

  /// 引擎生命周期（启动路径：回前台预热 / 进后台销毁省电）。
  static func warmUp() {
    loadIfNeeded()
    TiebaHaptics.warmUp()
  }

  static func shutdown() { TiebaHaptics.shutdown() }

  /// 「长按弹出大图」实时触觉（原 theme/hapticsRealtime.playImageLiftHaptic）：
  /// 长按升起动画开始时单次柔和瞬态，强度随 hapticsRealtimeStyles 档位缩放。
  static func playImageLift() {
    loadIfNeeded()
    guard let scale = realtimeScale(for: "imageLiftPop") else { return }
    TiebaHaptics.playTransient(
      intensity: max(0.05, min(1, 0.55 * scale)),
      sharpness: 0.45
    )
  }

  /// 实时触觉档位 → 强度缩放；nil = 该效果已关闭（off），默认适中（0.8）。
  private static func realtimeScale(for effect: String) -> Double? {
    switch tables[.realtimeStyles]?[effect] {
    case "off": return nil
    case "light": return 0.55
    case "strong": return 1
    default: return 0.8
    }
  }

  // MARK: - 覆盖表（内存缓存，随偏好变更重读）

  /// 三条覆盖表键。订阅与重读共用这一份，避免两处漂移。
  private enum Table: String, CaseIterable {
    case sceneStyles = "hapticsSceneStyles"
    case waveforms = "hapticsWaveforms"
    case realtimeStyles = "hapticsRealtimeStyles"
  }

  /// nonisolated(unsafe)：只在主线程读写；fire 的调用点全在 UI 事件里，
  /// 订阅回调也在主队列（TiebaPreferenceChange.observe 的 queue: .main）。
  /// ⚠️ 刻意不加锁、不跳队：触觉是最高频路径，锁与异步都是净开销。
  nonisolated(unsafe) private static var tables: [Table: [String: String]] = [:]
  /// 订阅 token（必须持有：本文件不注销订阅，进程内一直有效）。
  nonisolated(unsafe) private static var changeToken: NSObjectProtocol?

  /// 首次使用（回前台 warmUp / 第一次 fire）时读表并订阅偏好变更。
  /// 顺序是刻意的：先订阅再读，两件事之间落盘的写入不会漏（回调会重读）。
  private static func loadIfNeeded() {
    guard changeToken == nil else { return }
    changeToken = TiebaPreferenceChange.observe(keys: Table.allCases.map(\.rawValue)) {
      reloadTables()
    }
    reloadTables()
  }

  /// 清缓存 + 立即重读三条表（唯一的重读点，= 偏好变更回调）。
  /// ⚠️ 重读放在这里而不是 fire 里：fire 是最高频路径，旧实现每次触发都要
  /// 读 KV 串比代次（2 次 SQLite + 2 次 JSON），正是这条路径要消掉的成本。
  private static func reloadTables() {
    for table in Table.allCases {
      tables[table] = parseTable(TiebaPreferenceSnapshot.rawValue(table.rawValue))
    }
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
