// ============================================================
// TiebaSettingsViewController —— 设置首页（原 src/app/settings/index.tsx）
// ============================================================
import UIKit

final class TiebaSettingsViewController: TiebaFormPageController {
  private func isDefaultTheme(dark: Bool) -> Bool {
    TiebaThemePalette.themeName(dark: dark) == "default"
  }

  private func rowTint(_ color: String, dark: Bool) -> String {
    isDefaultTheme(dark: dark) ? color : TiebaSettingsForm.tintHex(dark: dark) ?? color
  }

  private func iconRow(
    _ id: String, _ title: String, _ subtitle: String, _ icon: String, _ color: String, dark: Bool
  ) -> [String: Any] {
    [
      "id": id,
      "kind": "link",
      "title": title,
      "subtitle": subtitle,
      "icon": icon,
      "iconTint": rowTint(color, dark: dark),
    ]
  }

  private func toggleRow(
    _ id: String, _ title: String, _ subtitle: String, _ icon: String, _ color: String,
    on: Bool, dark: Bool
  ) -> [String: Any] {
    [
      "id": id,
      "kind": "toggle",
      "title": title,
      "subtitle": subtitle,
      "icon": icon,
      "iconTint": rowTint(color, dark: dark),
      "value": on ? "1" : "0",
      "switchRowTap": false,
    ]
  }

  override func makeSections(dark: Bool) -> [[String: Any]] {
    let hapticFeedback = TiebaPreferences.bool("hapticFeedback", default: true)
    let autoCheckUpdate = TiebaPreferences.bool("autoCheckUpdate", default: true)

    return [
      [
        "title": "外观",
        "rows": [
          iconRow("/settings/theme", "个性化", "深浅色外观、字号、导航栏样式", "paintpalette.fill", "#AF52DE", dark: dark)
        ],
      ],
      [
        "title": "使用习惯",
        "rows": [
          iconRow("/settings/habit", "使用习惯", "首页、浏览、贴子、内容等偏好", "slider.horizontal.3", "#8E8E93", dark: dark),
          toggleRow(
            "/pref/hapticFeedback", "振动反馈", "点击、长按、成功/失败等操作反馈",
            "iphone.radiowaves.left.and.right", "#8E8E93", on: hapticFeedback, dark: dark
          ),
          iconRow("/settings/haptics", "振动设置", "为每个场景单独选择振动强度", "waveform", "#FF9500", dark: dark),
          iconRow("/settings/oksign", "一键签到", "自动签到关注的贴吧", "checkmark.circle", "#34C759", dark: dark),
        ],
      ],
      [
        "title": "内容与流量",
        "rows": [
          iconRow("/settings/image", "图片与流量", "图片加载策略、水印、清晰度与流量", "photo.on.rectangle", "#34C759", dark: dark),
          iconRow("/settings/block", "屏蔽设置", "屏蔽词、屏蔽用户、云端黑名单", "hand.raised", "#FF9500", dark: dark),
        ],
      ],
      [
        "title": "账号与安全",
        "rows": [
          iconRow("/settings/account", "账号管理", "登录账号、退出登录", "person.circle", "#4477E0", dark: dark)
        ],
      ],
      [
        "title": "通用",
        "rows": [
          toggleRow(
            "/pref/autoCheckUpdate", "自动检测更新", "启动时检查 GitHub 最新 Release（关于页可手动检查）",
            "arrow.triangle.2.circlepath", "#4477E0", on: autoCheckUpdate, dark: dark
          ),
          iconRow("/settings/more", "更多设置", "缓存与数据、外部链接、日志与关于", "ellipsis.circle", "#8E8E93", dark: dark),
        ],
      ],
    ]
  }

  // MARK: - 动作

  override func handle(_ event: TiebaFormEvent) {
    switch event {
    case .press(let id):
      switch id {
      case "/settings/theme", "/settings/habit", "/settings/haptics", "/settings/oksign",
        "/settings/image", "/settings/block", "/settings/account", "/settings/more":
        TiebaSettingsForm.push(id)
      default:
        break
      }
    case .toggle(let id, let value):
      handleToggle(id, value)
    default:
      break
    }
  }

  /// ⚠️ 行 id 是 /pref/… 路径，偏好键在斜杠后：写入时显式给 row（不能按 id 同名落库）。
  private func handleToggle(_ id: String, _ value: Bool) {
    switch id {
    case "/pref/hapticFeedback":
      guard write("hapticFeedback", bool: value, row: id) else { return }
      TiebaChrome.setHapticChromeHapticsEnabled(value)
      if value {
        TiebaHaptics.warmUp()
        TiebaSceneHaptics.fire("toggle")
      } else {
        TiebaHaptics.shutdown()
      }
    case "/pref/autoCheckUpdate":
      guard write("autoCheckUpdate", bool: value, row: id) else { return }
      if value { TiebaSceneHaptics.fire("toggle") }
      TiebaToast.show(value ? "已开启自动检测更新" : "已关闭自动检测更新")
    default:
      break
    }
  }
}
