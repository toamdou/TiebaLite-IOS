// ============================================================
// TiebaHapticsSettingsViewController —— 振动设置（原 src/app/settings/haptics.tsx）
// 每场景两档（力度/波形）+ 实时触觉档位；渲染与写入两侧都做白名单清洗，
// 保证偏好表不产生选择器不认识的档位。
// ============================================================
import UIKit

final class TiebaHapticsSettingsViewController: TiebaFormPageController {
  private struct Scene {
    let scene: String
    let label: String
    let group: String
  }

  private static let scenes: [Scene] = [
    Scene(scene: "press", label: "轻按", group: "action"),
    Scene(scene: "like", label: "点赞", group: "action"),
    Scene(scene: "favorite", label: "收藏", group: "action"),
    Scene(scene: "destructive", label: "破坏性确认", group: "action"),
    Scene(scene: "sheet-present", label: "浮层展开", group: "action"),
    Scene(scene: "long-press", label: "长按菜单", group: "action"),
    Scene(scene: "toggle", label: "开关切换", group: "signal"),
    Scene(scene: "segment", label: "页面切换", group: "signal"),
    Scene(scene: "action-success", label: "操作成功", group: "signal"),
    Scene(scene: "action-warning", label: "操作警示", group: "signal"),
    Scene(scene: "action-fail", label: "操作失败", group: "signal"),
  ]

  private static let sceneStyles: [(value: String, label: String)] = [
    ("default", "跟随默认"), ("off", "关闭"), ("light", "轻"), ("medium", "中"), ("heavy", "强"),
  ]
  private static let waveforms: [(value: String, label: String)] = [
    ("default", "内置波形"), ("single", "单次"), ("double", "双脉冲"), ("rising", "渐强三连"), ("soft", "轻柔"),
  ]
  private static let realtimeLevels: [(value: String, label: String)] = [
    ("off", "关闭"), ("light", "轻"), ("medium", "适中"), ("strong", "强"),
  ]
  private static let realtimeEffects: [(id: String, label: String)] = [
    ("imageLiftPop", "长按弹出大图"), ("likeCharge", "点赞蓄力"),
  ]

  /// 本页三张覆盖表的键（在屏时被别处改写要即时回推各选择器的选中档）。
  private static let preferenceKeys = [
    "hapticsSceneStyles", "hapticsWaveforms", "hapticsRealtimeStyles",
  ]

  /// 观察者是 non-Sendable，deinit 非隔离：与 TiebaHomeViewController 同款声明。
  private nonisolated(unsafe) var prefToken: NSObjectProtocol?

  deinit {
    if let prefToken { NotificationCenter.default.removeObserver(prefToken) }
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    // 「恢复默认」的三表连写也经广播回环：这里重算再回推，与 makeSections 同规则。
    prefToken = TiebaPreferenceChange.observe(keys: Self.preferenceKeys) { [weak self] in
      self?.refreshDisplayedValues()
    }
  }

  /// 覆盖表变更后就地回推全部选择器的选中档（清洗规则与 makeSections 共用
  /// overrides/safe，不维护第二份读法）；本页行结构固定，不整表重建。
  private func refreshDisplayedValues() {
    let styles = overrides("hapticsSceneStyles")
    let waveforms = overrides("hapticsWaveforms")
    let realtime = overrides("hapticsRealtimeStyles")
    for meta in Self.scenes {
      form.setValue(id: "strength:\(meta.scene)", value: safe(styles[meta.scene], Self.sceneStyles))
      form.setValue(id: "waveform:\(meta.scene)", value: safe(waveforms[meta.scene], Self.waveforms))
    }
    for effect in Self.realtimeEffects {
      form.setValue(
        id: "realtime:\(effect.id)",
        value: safe(realtime[effect.id], Self.realtimeLevels, fallback: "medium"))
    }
  }

  // MARK: - 数据

  /// 覆盖表解析：坏 JSON/非对象 → 空表（与消费侧同一宽容度）。
  private func overrides(_ key: String) -> [String: String] {
    guard let raw = TiebaPreferenceSnapshot.rawValue(key),
      let data = raw.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data),
      let table = object as? [String: Any]
    else { return [:] }
    var result: [String: String] = [:]
    for (key, value) in table {
      if let text = value as? String { result[key] = text }
    }
    return result
  }

  private func write(_ key: String, _ table: [String: String]) -> Bool {
    guard let data = try? JSONSerialization.data(withJSONObject: table, options: [.sortedKeys]),
      let text = String(data: data, encoding: .utf8)
    else { return false }
    return TiebaPreferences.set(key, string: text)
  }

  private func safe(_ raw: String?, _ choices: [(value: String, label: String)], fallback: String = "default") -> String {
    guard let raw, choices.contains(where: { $0.value == raw }) else { return fallback }
    return raw
  }

  private func pickerRow(_ id: String, _ title: String, value: String, options: [(value: String, label: String)]) -> [String: Any] {
    [
      "id": id, "kind": "picker", "title": title, "value": value, "options": self.options(options),
    ]
  }

  private func sceneRows(_ group: String, styles: [String: String], waveforms: [String: String]) -> [[String: Any]] {
    Self.scenes.filter { $0.group == group }.flatMap { meta -> [[String: Any]] in
      [
        pickerRow(
          "strength:\(meta.scene)", "\(meta.label) · 力度",
          value: safe(styles[meta.scene], Self.sceneStyles), options: Self.sceneStyles),
        pickerRow(
          "waveform:\(meta.scene)", "\(meta.label) · 波形",
          value: safe(waveforms[meta.scene], Self.waveforms), options: Self.waveforms),
      ]
    }
  }

  override func makeSections(dark: Bool) -> [[String: Any]] {
    let styles = overrides("hapticsSceneStyles")
    let waveforms = overrides("hapticsWaveforms")
    let realtime = overrides("hapticsRealtimeStyles")

    return [
      [
        "title": "操作反馈",
        "footer": "力度：「跟随默认」使用应用内置 AHAP 模式；轻/中/强为整体浓淡缩放。波形：改变触觉节奏（内置/单次/双脉冲/渐强三连/轻柔），与力度叠加生效。选择后立即回放一次以便试听。",
        "rows": sceneRows("action", styles: styles, waveforms: waveforms),
      ],
      [
        "title": "切换与结果通知",
        "rows": sceneRows("signal", styles: styles, waveforms: waveforms),
      ],
      [
        "title": "实时触觉（手势跟随）",
        "footer": "跟随手指连续变化：大图下滑关闭的剥离感、横滑退出边缘的抵抗感、点赞按住的蓄力。只在对应手势进行时生效；信息流滚动等高频场景刻意未加入。",
        "rows": Self.realtimeEffects.map { effect in
          pickerRow(
            "realtime:\(effect.id)", effect.label,
            value: safe(realtime[effect.id], Self.realtimeLevels, fallback: "medium"),
            options: Self.realtimeLevels)
        },
      ],
      [
        "footer": "恢复默认会清除所有场景的自定义覆盖（不影响总开关「振动反馈」）。",
        "rows": [
          ["id": "resetAll", "kind": "button", "title": "恢复默认", "icon": "arrow.counterclockwise"]
        ],
      ],
    ]
  }

  // MARK: - 动作

  override func handle(_ event: TiebaFormEvent) {
    switch event {
    case .pick(let id, let value):
      handlePick(id, value)
    case .press(let id):
      if id == "resetAll" { resetAll() }
    default:
      break
    }
  }

  private func handlePick(_ id: String, _ value: String) {
    let separator = id.firstIndex(of: ":")
    let prefix = separator.map { String(id[id.startIndex..<$0]) } ?? id
    let key = separator.map { String(id[id.index(after: $0)...]) } ?? ""
    switch prefix {
    case "strength":
      guard Self.sceneStyles.contains(where: { $0.value == value }) else { return }
      var table = overrides("hapticsSceneStyles")
      // 「跟随默认」= 删键，表保持最小（与旧页一致）。
      if value == "default" { table.removeValue(forKey: key) } else { table[key] = value }
      guard write("hapticsSceneStyles", table) else { reportWriteFailure(); return }
    case "waveform":
      guard Self.waveforms.contains(where: { $0.value == value }) else { return }
      var table = overrides("hapticsWaveforms")
      if value == "default" { table.removeValue(forKey: key) } else { table[key] = value }
      guard write("hapticsWaveforms", table) else { reportWriteFailure(); return }
    case "realtime":
      guard Self.realtimeLevels.contains(where: { $0.value == value }) else { return }
      var table = overrides("hapticsRealtimeStyles")
      table[key] = value
      guard write("hapticsRealtimeStyles", table) else { reportWriteFailure(); return }
    default:
      return
    }
    // 写入成功才回推选中值 + 回放试听（写失败时选择器保持旧档）。
    form.setValue(id: id, value: value)
    if prefix != "realtime" { TiebaSceneHaptics.fire(key) }
  }

  private func resetAll() {
    // 三张表都要写：不能短路（&& 会在第一处失败后跳过其余写入）。
    let styles = TiebaPreferences.set("hapticsSceneStyles", string: "{}")
    let realtime = TiebaPreferences.set("hapticsRealtimeStyles", string: "{}")
    let waveforms = TiebaPreferences.set("hapticsWaveforms", string: "{}")
    guard styles, realtime, waveforms else {
      reportWriteFailure()
      return
    }
    TiebaSceneHaptics.fire("press")
    reload()
  }
}
