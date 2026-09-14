// ============================================================
// TiebaImageSettingsViewController —— 图片与流量（原 src/app/settings/image.tsx）
//
// 分组/顺序与旧页一致：图片加载（策略/清晰度）→ 水印（样式/开关）→ 显示（暗化）
// → 视频（自动播放 + 页脚）。触觉只有「暗化」「自动播放」两个开关有。
// ============================================================
import UIKit

final class TiebaImageSettingsViewController: TiebaFormPageController {
  private static let loadTypes: [(value: String, label: String)] = [
    ("smart_origin", "智能省流量"), ("all_origin", "始终高质量"), ("all_no", "始终无图"),
  ]
  private static let dataSaver: [(value: String, label: String)] = [
    ("origin", "原图（最清晰，费流量）"), ("high", "高清（默认，省流量）"), ("lite", "省流（最省流量）"),
  ]
  private static let watermarks: [(value: String, label: String)] = [
    ("none", "不添加"), ("username", "用户名"), ("forum_name", "吧名"),
  ]

  /// 本页展示的全部偏好键（行 id 与键逐字同名；在屏时被别处改写要即时回推）。
  private static let preferenceKeys = [
    "imageLoadType", "dataSaverMode", "imageWatermark", "imageWatermarkEnabled",
    "imageDarkenWhenNight", "videoAutoplay",
  ]

  /// 观察者是 non-Sendable，deinit 非隔离：与 TiebaHomeViewController 同款声明。
  private nonisolated(unsafe) var prefToken: NSObjectProtocol?

  deinit {
    if let prefToken { NotificationCenter.default.removeObserver(prefToken) }
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    // 在屏时被别处改写就就地回推行值（选择器仍过白名单，与 makeSections 同规则）。
    prefToken = TiebaPreferenceChange.observe(keys: Self.preferenceKeys) { [weak self] in
      self?.refreshDisplayedValues()
    }
  }

  /// 行 id 与偏好键同名，就地回推即可；本页行结构固定，不整表重建。
  private func refreshDisplayedValues() {
    form.setValue(
      id: "imageLoadType",
      value: TiebaPreferences.string(
        "imageLoadType", allowed: Self.loadTypes.map(\.value), default: "smart_origin"))
    form.setValue(
      id: "dataSaverMode",
      value: TiebaPreferences.string(
        "dataSaverMode", allowed: Self.dataSaver.map(\.value), default: "high"))
    form.setValue(
      id: "imageWatermark",
      value: TiebaPreferences.string(
        "imageWatermark", allowed: Self.watermarks.map(\.value), default: "none"))
    form.setValue(
      id: "imageWatermarkEnabled",
      value: TiebaPreferences.bool("imageWatermarkEnabled", default: false) ? "1" : "0")
    form.setValue(
      id: "imageDarkenWhenNight",
      value: TiebaPreferences.bool("imageDarkenWhenNight", default: true) ? "1" : "0")
    form.setValue(
      id: "videoAutoplay",
      value: TiebaPreferences.bool("videoAutoplay", default: false) ? "1" : "0")
  }

  override func makeSections(dark: Bool) -> [[String: Any]] {
    func picker(_ id: String, _ title: String, _ table: [(value: String, label: String)], fallback: String) -> [String: Any] {
      [
        "id": id, "kind": "picker", "title": title,
        "value": TiebaPreferences.string(id, allowed: table.map(\.value), default: fallback),
        "options": options(table),
      ]
    }
    func toggle(_ id: String, _ title: String, _ icon: String, fallback: Bool) -> [String: Any] {
      [
        "id": id, "kind": "toggle", "title": title, "icon": icon,
        "value": TiebaPreferences.bool(id, default: fallback) ? "1" : "0",
      ]
    }

    return [
      [
        "title": "图片加载",
        "rows": [
          picker("imageLoadType", "图片加载策略", Self.loadTypes, fallback: "smart_origin"),
          picker("dataSaverMode", "大图清晰度", Self.dataSaver, fallback: "high"),
        ],
      ],
      [
        "title": "图片水印",
        "rows": [
          picker("imageWatermark", "水印样式", Self.watermarks, fallback: "none"),
          toggle("imageWatermarkEnabled", "图片右下角水印", "signature", fallback: false),
        ],
      ],
      [
        "title": "显示",
        "rows": [
          toggle("imageDarkenWhenNight", "暗色模式下暗化图片", "moon.circle.fill", fallback: true)
        ],
      ],
      [
        "title": "视频",
        "footer": "自动播放：帖内视频滚入视野即静音开播，滚出视野自动收起（滚回重播）；关闭后点按播放。WiFi 档需网络状态模块，暂不提供。",
        "rows": [
          toggle("videoAutoplay", "帖内视频自动播放", "play.circle", fallback: false)
        ],
      ],
    ]
  }

  override func handle(_ event: TiebaFormEvent) {
    switch event {
    case .toggle(let id, let value):
      // 触觉只有「暗化」「自动播放」两个开关有（水印开关没有，与旧页一致）。
      switch id {
      case "imageWatermarkEnabled":
        write(id, bool: value)
      case "imageDarkenWhenNight", "videoAutoplay":
        TiebaSceneHaptics.fire("toggle")
        write(id, bool: value)
      default:
        break
      }
    default:
      // 选择器：行 id 与偏好键逐字同名（见 makeSections），走基类默认实现。
      super.handle(event)
    }
  }
}
