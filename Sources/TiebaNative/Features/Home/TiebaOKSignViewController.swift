// ============================================================
// TiebaOKSignViewController —— 一键签到设置（原 src/app/settings/oksign.tsx）
// 签到复用 TiebaSignService（首页同一条 msign 通道）；自动签到走
// TiebaBackgroundSync 的 BGTask 登记；进度观察走 addProgressObserver。
// ============================================================
import UIKit

final class TiebaOKSignViewController: UIViewController {
  private let form = TiebaSettingsForm.makeForm()
  private let service = TiebaSignService.shared
  private var observerID: UUID?
  private var resultDismissed = false
  private var isScheduled = false

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemGroupedBackground
    form.onRowPress = { [weak self] id in self?.handleRowPress(id) }
    form.onToggle = { [weak self] id, value in self?.handleToggle(id, value) }
    form.onPick = { [weak self] id, value in self?.handlePick(id, value) }
    view.addSubview(form)
    TiebaSettingsForm.pin(form, in: view)
    observerID = service.addProgressObserver { [weak self] in self?.reload() }
    reload()
  }

  deinit {
    guard let observerID else { return }
    MainActor.assumeIsolated {
      TiebaSignService.shared.removeProgressObserver(observerID)
    }
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    isScheduled = TiebaBackgroundSync.shared.isAutoSignRegistered()
    reload()
  }

  // MARK: - 数据

  private func reload() {
    let dark = TiebaSettingsForm.isDark(in: self)
    TiebaSettingsForm.reload(form, isDark: dark)

    let accent = TiebaSettingsForm.tintHex(dark: dark)
      ?? TiebaThemePalette.accent(themeName: "default", customPrimary: nil, isDark: dark)
    let loggedIn = TiebaUserAPI.isLoggedIn
    let isSigning = service.isSigning
    let autoSign = TiebaPreferences.bool("autoSign", default: false)
    let autoSignTime = TiebaPreferences.string("autoSignTime", default: "08:00")

    var sections: [[String: Any]] = [
      [
        "title": "一键签到",
        "rows": [
          [
            "id": "manualSign", "kind": "prominentButton",
            "title": loggedIn ? "一键签到" : "请先登录",
            "icon": "checkmark.circle.fill", "disabled": !loggedIn,
            "buttonLarge": true, "color": accent,
          ],
          [
            "id": "manualSignHint", "kind": "text", "textStyle": "caption",
            "color": "secondaryLabel", "title": "点击立即签到所有关注的贴吧",
          ],
        ],
      ]
    ]

    if isSigning {
      let done = service.progressDone
      let total = service.progressItems.count
      var statsRow: [String: Any] = [
        "id": "signingStats", "kind": "status", "title": "",
        "statusItems": [
          ["icon": "checkmark.circle.fill", "text": "\(service.progressSuccess)", "color": "systemGreen"],
          ["icon": "xmark.circle", "text": "\(service.progressFail)", "color": "systemRed"],
        ],
      ]
      if service.progressExp > 0 {
        statsRow["trailingText"] = "+\(service.progressExp) 经验"
      }
      var rows: [[String: Any]] = [
        ["id": "signingText", "kind": "text", "title": "正在签到 \(done) / \(total)"],
        [
          "id": "signingProgress", "kind": "progress",
          "progress": total > 0 ? min(Double(done) / Double(total), 1) : 0,
        ],
        statsRow,
        [
          "id": "cancelSign", "kind": "prominentButton", "title": "取消签到",
          "icon": "xmark.circle.fill", "buttonStyle": "bordered", "color": "systemRed",
        ],
      ]
      if service.progressItems.isEmpty {
        rows.removeAll { ($0["id"] as? String) == "signingStats" }
      }
      sections.append(["title": "签到进度", "rows": rows])
    } else if let error = service.lastError, !resultDismissed {
      sections.append([
        "title": "签到出错",
        "rows": [
          ["id": "errorTitle", "kind": "text", "title": "签到出错", "color": "systemRed", "titleWeight": "semibold"],
          ["id": "errorText", "kind": "text", "textStyle": "subheadline", "color": "secondaryLabel", "title": error],
          ["id": "dismissResult", "kind": "button", "title": "关闭", "icon": "xmark"],
        ],
      ])
    } else if !resultDismissed, !service.progressItems.isEmpty {
      var summary = "成功 \(service.progressSuccess) 个"
      if service.progressFail > 0 { summary += "，失败 \(service.progressFail) 个" }
      if service.progressExp > 0 { summary += "，获得 \(service.progressExp) 经验" }
      sections.append([
        "title": "签到结果",
        "rows": [
          ["id": "doneTitle", "kind": "text", "title": "签到完成", "color": "systemGreen", "titleWeight": "semibold"],
          ["id": "doneSummary", "kind": "text", "textStyle": "subheadline", "color": "secondaryLabel", "title": summary],
          ["id": "dismissResult", "kind": "button", "title": "完成", "icon": "checkmark"],
        ],
      ])
    }

    // 展示位只有灵动岛：通知栏那条进度横幅实测永远停在 0/N（投递后无人更新），
    // 已连同 signDisplayMode 偏好一起删除（用户 2026-09-15 报）。
    let displayRows: [[String: Any]] = [
      [
        "id": "liveActivitySignEnabled", "kind": "toggle", "title": "灵动岛实时进度",
        "subtitle": "关闭后签到进度不再显示在灵动岛，后台静默完成",
        "value": TiebaPreferences.bool("liveActivitySignEnabled", default: true) ? "1" : "0",
      ],
      [
        "id": "signSilent", "kind": "toggle", "title": "静默显示",
        "subtitle": "后台自动签到的完成通知不发声，横幅照常显示",
        "value": TiebaPreferences.bool("signSilent", default: false) ? "1" : "0",
      ],
    ]
    sections.append(["title": "进度显示", "rows": displayRows])

    var autoRows: [[String: Any]] = [
      [
        "id": "autoSign", "kind": "toggle", "title": "每日自动签到",
        "subtitle": "在每天指定时间尝试后台自动签到", "value": autoSign ? "1" : "0",
      ]
    ]
    if autoSign {
      autoRows.append(["id": "autoSignTime", "kind": "datePicker", "title": "签到时间", "value": autoSignTime])
    }
    if isScheduled {
      autoRows.append([
        "id": "scheduledHint", "kind": "text", "textStyle": "caption",
        "color": "secondaryLabel", "title": "将在每天 \(autoSignTime) 自动签到",
      ])
    }
    sections.append(["title": "自动签到", "rows": autoRows])

    sections.append([
      "title": "签到行为",
      "rows": [
        [
          "id": "slowSignMode", "kind": "toggle", "title": "慢速模式",
          "subtitle": "降低签到速度，减少被限制的风险",
          "value": TiebaPreferences.bool("slowSignMode", default: false) ? "1" : "0",
        ],
        [
          "id": "failAutoStop", "kind": "toggle", "title": "失败自动停止",
          "subtitle": "遇到签到失败时立即停止",
          "value": TiebaPreferences.bool("failAutoStop", default: true) ? "1" : "0",
        ],
        [
          "id": "useOfficialSign", "kind": "toggle", "title": "使用官方批量签到",
          "subtitle": "优先使用贴吧官方批量签到接口",
          "value": TiebaPreferences.bool("useOfficialSign", default: true) ? "1" : "0",
        ],
      ],
    ])

    if !service.progressItems.isEmpty, !isSigning {
      sections.append(["title": "进度列表", "rows": [progressSummaryRow()]])
    } else if !service.progressItems.isEmpty {
      sections.append([
        "title": "进度列表",
        "rows": service.progressItems.map { item in
          var row: [String: Any] = ["id": "progress:\(item.forumId)", "kind": "status", "title": item.forumName]
          switch item.status {
          case "success":
            row["statusItems"] = [["icon": "checkmark.circle.fill", "text": item.exp > 0 ? "+\(item.exp)" : "", "color": "systemGreen"]]
          case "failed":
            row["statusItems"] = [["icon": "xmark.circle", "text": "", "color": "systemRed"]]
          case "signing":
            row["showsSpinner"] = true
          default:
            row["trailingText"] = "等待中"
          }
          return row
        },
      ])
    }

    sections.append([
      "title": "关于一键签到",
      "rows": [
        [
          "id": "aboutSign", "kind": "text", "textStyle": "caption", "color": "secondaryLabel",
          "title": "一键签到会依次为您关注的每一个贴吧签到。开启自动签到后，应用会在每天指定时间通过后台任务自动签到。频繁签到可能被贴吧系统临时限制，建议开启慢速模式降低风险。",
        ]
      ],
    ])

    form.sections = sections
  }

  private func progressSummaryRow() -> [String: Any] {
    var items: [[String: Any]] = [
      ["icon": "checkmark.circle.fill", "text": "\(service.progressSuccess)", "color": "systemGreen"]
    ]
    if service.progressFail > 0 {
      items.append(["icon": "xmark.circle", "text": "\(service.progressFail)", "color": "systemRed"])
    }
    var row: [String: Any] = ["id": "progressSummary", "kind": "status", "title": "", "statusItems": items]
    if service.progressExp > 0 {
      row["trailingText"] = "共 \(service.progressItems.count) 个吧 · +\(service.progressExp) 经验"
    }
    return row
  }

  // MARK: - 动作

  private func handleRowPress(_ id: String) {
    switch id {
    case "manualSign":
      startSign()
    case "cancelSign":
      service.cancel()
    case "dismissResult":
      resultDismissed = true
      reload()
    default:
      break
    }
  }

  private func startSign() {
    guard TiebaUserAPI.isLoggedIn else {
      let alert = UIAlertController(title: "提示", message: "请先登录后再使用一键签到", preferredStyle: .alert)
      alert.addAction(UIAlertAction(title: "知道了", style: .cancel))
      present(alert, animated: true)
      return
    }
    guard !service.isSigning else { return }
    TiebaSceneHaptics.fire("press")
    resultDismissed = false
    service.start(presenter: self)
    reload()
  }

  private func handleToggle(_ id: String, _ value: Bool) {
    switch id {
    case "autoSign":
      TiebaSceneHaptics.fire("toggle")
      setAutoSign(value)
    case "slowSignMode", "failAutoStop", "useOfficialSign", "signSilent":
      TiebaSceneHaptics.fire("toggle")
      TiebaPreferences.set(id, bool: value)
    case "liveActivitySignEnabled":
      TiebaSceneHaptics.fire("toggle")
      TiebaPreferences.set(id, bool: value)
      if !value { recoverStaleSignActivities() }
    default:
      break
    }
  }

  private func handlePick(_ id: String, _ value: String) {
    switch id {
    case "autoSignTime":
      let previous = TiebaPreferences.string("autoSignTime", default: "08:00")
      TiebaPreferences.set("autoSignTime", string: value)
      if TiebaPreferences.bool("autoSign", default: false) {
        if !registerAutoSign(value) {
          // 原生登记失败回滚为旧值，避免 UI 与定时任务不一致。
          TiebaPreferences.set("autoSignTime", string: previous)
          isScheduled = false
          showError("更新签到时间失败")
        } else {
          isScheduled = true
        }
      }
      reload()
    default:
      break
    }
  }

  /// 开/关自动签到：失败回滚偏好，避免 UI 与定时任务不一致。
  private func setAutoSign(_ enabled: Bool) {
    if enabled {
      let time = TiebaPreferences.string("autoSignTime", default: "08:00")
      guard registerAutoSign(time) else {
        TiebaPreferences.set("autoSign", bool: false)
        isScheduled = false
        showError("设置自动签到失败")
        reload()
        return
      }
      TiebaPreferences.set("autoSign", bool: true)
      isScheduled = true
    } else {
      TiebaPreferences.set("autoSign", bool: false)
      TiebaBackgroundSync.shared.cancelAutoSign()
      TiebaBackgroundSync.shared.cancelSignReminder()
      isScheduled = false
    }
    reload()
  }

  private func registerAutoSign(_ time: String) -> Bool {
    let parts = time.split(separator: ":").compactMap { Int($0) }
    guard parts.count == 2, (0...23).contains(parts[0]), (0...59).contains(parts[1]) else {
      return false
    }
    do {
      try TiebaBackgroundSync.shared.registerAutoSign(hour: parts[0], minute: parts[1])
      TiebaBackgroundSync.shared.scheduleSignReminder(hour: parts[0], minute: parts[1])
      return true
    } catch {
      return false
    }
  }

  private func showError(_ message: String) {
    let alert = UIAlertController(title: "错误", message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "知道了", style: .cancel))
    present(alert, animated: true)
  }

  /// 切「通知栏」/关灵动岛时结束在场的签到 Live Activity（与旧页同款清理）。
  private func recoverStaleSignActivities() {
    Task { @MainActor in
      await TiebaLiveActivityManager.shared.endAllInterrupted()
    }
  }
}
