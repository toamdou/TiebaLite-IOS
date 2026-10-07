// TiebaOKSignViewController —— 一键签到设置（原 src/app/settings/oksign.tsx）
// 签到复用 TiebaSignService（首页同一条 msign 通道）；自动签到走
// TiebaBackgroundSync 的 BGTask 登记；进度观察走 addProgressObserver。
//
// 动效接线（见 docs/uikit-migration/22-接线-display-nodes.md）：
//   · 签到完成 → TiebaSignSuccessOverlay：UI/Nodes/TiebaConfettiView 撒彩带 +
//     UI/Drawing/TiebaCheckNode 画对勾。对勾的入场缓动不是 UIView.animate 的固定曲线，
//     而是 Core/TiebaDisplayLinkAnimator 的 TiebaConstantDisplayLinkAnimator 逐帧驱动 +
//     UI/Drawing/TiebaSpring 的 cubic-bezier 求值（带一点回弹）。
//   · 首次进入 → UI/Nodes/TiebaTooltipController 锚在导航栏「?」按钮上的引导气泡
//     （看过一次记进偏好；之后仍可点「?」再看）。
import UIKit

final class TiebaOKSignViewController: UIViewController {
  private let form = TiebaSettingsForm.makeForm()
  private let service = TiebaSignService.shared
  private var observerID: UUID?
  private var resultDismissed = false
  private var isScheduled = false
  /// 签到成功的浮层（彩带 + 对勾），播完自己从父视图摘掉并把这里置空。
  private var successOverlay: TiebaSignSuccessOverlay?
  /// 上一拍是否在签到中：只抓「进行中 → 结束」这一拍放彩带
  ///（进度观察者每个吧都会回调一次，不这样判会连放几十次）。
  private var wasSigning = false
  /// 本次签到是否已经庆祝过（取消/重试等重复回调都会落回这里去重）。
  private var didCelebrate = false
  /// 导航栏「?」按钮：既是首次引导气泡的锚点，也是随时再看的入口。
  private var helpButton: UIButton?

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemGroupedBackground
    form.onRowPress = { [weak self] id in self?.handleRowPress(id) }
    form.onToggle = { [weak self] id, value in self?.handleToggle(id, value) }
    form.onPick = { [weak self] id, value in self?.handlePick(id, value) }
    view.addSubview(form)
    TiebaSettingsForm.pin(form, in: view)
    installHelpButton()
    observerID = service.addProgressObserver { [weak self] in self?.reload() }
    reload()
  }

  // 观察者要在主 actor 上摘（TiebaSignService 是 @MainActor 单例）。
  // 用 isolated deinit 而不是在 nonisolated deinit 里 assumeIsolated：
  // 前者由编译器保证 deinit 跑在主 actor 上，后者是「断言此刻已在」的绕过写法。
  isolated deinit {
    guard let observerID else { return }
    TiebaSignService.shared.removeProgressObserver(observerID)
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    // 首次进入给一次锚定引导（一次性，与站内其它引导同款记偏好）。
    if !TiebaPreferences.bool("okSignGuideShown", default: false) {
      TiebaPreferences.set("okSignGuideShown", bool: true)
      showGuideTooltip()
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

    // 抓「进行中 → 结束」这一拍：有成功结果且没出错才庆祝（见属性注释）。
    if wasSigning && !isSigning {
      if service.lastError == nil, service.progressSuccess > 0, !didCelebrate {
        didCelebrate = true
        playSignSuccess()
      }
    }
    wasSigning = isSigning
    if isSigning { didCelebrate = false }
    let autoSign = TiebaPreferences.bool("autoSign", default: false)
    let autoSignTime = TiebaPreferences.string("autoSignTime", default: "08:00")

    var sections = [
      TiebaFormSection(
        title: "一键签到",
        rows: [
          TiebaFormRow(
            id: "manualSign",
            kind: .prominentButton,
            title: loggedIn ? "一键签到" : "请先登录",
            icon: "checkmark.circle.fill",
            disabled: !loggedIn,
            override: TiebaFormColor.resolve(accent),
            buttonLarge: true
          ),
          TiebaFormRow(
            id: "manualSignHint",
            kind: .text,
            title: "点击立即签到所有关注的贴吧",
            override: TiebaFormColor.resolve("secondaryLabel"),
            textStyle: "caption"
          ),
        ]
      )
    ]

    if isSigning {
      let done = service.progressDone
      let total = service.progressItems.count
      var statsRow = TiebaFormRow(
        id: "signingStats",
        kind: .status,
        title: "",
        statusItems: [
          TiebaFormStatusItem(
            icon: "checkmark.circle.fill",
            text: "\(service.progressSuccess)",
            color: TiebaFormColor.resolve("systemGreen")
          ),
          TiebaFormStatusItem(
            icon: "xmark.circle",
            text: "\(service.progressFail)",
            color: TiebaFormColor.resolve("systemRed")
          ),
        ]
      )
      if service.progressExp > 0 {
        statsRow.trailingText = "+\(service.progressExp) 经验"
      }
      var rows = [
        TiebaFormRow(id: "signingText", kind: .text, title: "正在签到 \(done) / \(total)"),
        TiebaFormRow(
          id: "signingProgress",
          kind: .progress,
          progress: total > 0 ? min(Double(done) / Double(total), 1) : 0
        ),
        statsRow,
        TiebaFormRow(
          id: "cancelSign",
          kind: .prominentButton,
          title: "取消签到",
          icon: "xmark.circle.fill",
          override: TiebaFormColor.resolve("systemRed"),
          buttonStyle: "bordered"
        ),
      ]
      if service.progressItems.isEmpty {
        rows.removeAll { $0.id == "signingStats" }
      }
      sections.append(TiebaFormSection(title: "签到进度", rows: rows))
    } else if let error = service.lastError, !resultDismissed {
      sections.append(TiebaFormSection(
        title: "签到出错",
        rows: [
          TiebaFormRow(
            id: "errorTitle",
            kind: .text,
            title: "签到出错",
            override: TiebaFormColor.resolve("systemRed"),
            titleWeight: "semibold"
          ),
          TiebaFormRow(
            id: "errorText",
            kind: .text,
            title: error,
            override: TiebaFormColor.resolve("secondaryLabel"),
            textStyle: "subheadline"
          ),
          TiebaFormRow(id: "dismissResult", kind: .button, title: "关闭", icon: "xmark"),
        ]
      ))
    } else if !resultDismissed, !service.progressItems.isEmpty {
      var summary = "成功 \(service.progressSuccess) 个"
      if service.progressFail > 0 { summary += "，失败 \(service.progressFail) 个" }
      if service.progressExp > 0 { summary += "，获得 \(service.progressExp) 经验" }
      sections.append(TiebaFormSection(
        title: "签到结果",
        rows: [
          TiebaFormRow(
            id: "doneTitle",
            kind: .text,
            title: "签到完成",
            override: TiebaFormColor.resolve("systemGreen"),
            titleWeight: "semibold"
          ),
          TiebaFormRow(
            id: "doneSummary",
            kind: .text,
            title: summary,
            override: TiebaFormColor.resolve("secondaryLabel"),
            textStyle: "subheadline"
          ),
          TiebaFormRow(id: "dismissResult", kind: .button, title: "完成", icon: "checkmark"),
        ]
      ))
    }

    // 展示位只有灵动岛：通知栏那条进度横幅实测永远停在 0/N（投递后无人更新），
    // 已连同 signDisplayMode 偏好一起删除（用户 2026-09-15 报）。
    let displayRows = [
      TiebaFormRow(
        id: "liveActivitySignEnabled",
        kind: .toggle,
        title: "灵动岛实时进度",
        subtitle: "关闭后签到进度不再显示在灵动岛，后台静默完成",
        value: TiebaPreferences.bool("liveActivitySignEnabled", default: true) ? "1" : "0"
      ),
      TiebaFormRow(
        id: "signSilent",
        kind: .toggle,
        title: "静默显示",
        subtitle: "后台自动签到的完成通知不发声，横幅照常显示",
        value: TiebaPreferences.bool("signSilent", default: false) ? "1" : "0"
      ),
    ]
    sections.append(TiebaFormSection(title: "进度显示", rows: displayRows))

    var autoRows = [
      TiebaFormRow(
        id: "autoSign",
        kind: .toggle,
        title: "每日自动签到",
        subtitle: "在每天指定时间尝试后台自动签到",
        value: autoSign ? "1" : "0"
      )
    ]
    if autoSign {
      autoRows.append(TiebaFormRow(id: "autoSignTime", kind: .datePicker, title: "签到时间", value: autoSignTime))
    }
    if isScheduled {
      autoRows.append(TiebaFormRow(
        id: "scheduledHint",
        kind: .text,
        title: "将在每天 \(autoSignTime) 自动签到",
        override: TiebaFormColor.resolve("secondaryLabel"),
        textStyle: "caption"
      ))
    }
    sections.append(TiebaFormSection(title: "自动签到", rows: autoRows))

    sections.append(TiebaFormSection(
      title: "签到行为",
      rows: [
        TiebaFormRow(
          id: "slowSignMode",
          kind: .toggle,
          title: "慢速模式",
          subtitle: "降低签到速度，减少被限制的风险",
          value: TiebaPreferences.bool("slowSignMode", default: false) ? "1" : "0"
        ),
        TiebaFormRow(
          id: "failAutoStop",
          kind: .toggle,
          title: "失败自动停止",
          subtitle: "遇到签到失败时立即停止",
          value: TiebaPreferences.bool("failAutoStop", default: true) ? "1" : "0"
        ),
        TiebaFormRow(
          id: "useOfficialSign",
          kind: .toggle,
          title: "使用官方批量签到",
          subtitle: "优先使用贴吧官方批量签到接口",
          value: TiebaPreferences.bool("useOfficialSign", default: true) ? "1" : "0"
        ),
      ]
    ))

    if !service.progressItems.isEmpty, !isSigning {
      sections.append(TiebaFormSection(title: "进度列表", rows: [progressSummaryRow()]))
    } else if !service.progressItems.isEmpty {
      sections.append(TiebaFormSection(
        title: "进度列表",
        rows: service.progressItems.map { item in
          var row = TiebaFormRow(id: "progress:\(item.forumId)", kind: .status, title: item.forumName)
          switch item.status {
          case "success":
            row.statusItems = [TiebaFormStatusItem(
              icon: "checkmark.circle.fill",
              text: item.exp > 0 ? "+\(item.exp)" : "",
              color: TiebaFormColor.resolve("systemGreen")
            )]
          case "failed":
            row.statusItems = [TiebaFormStatusItem(icon: "xmark.circle", text: "", color: TiebaFormColor.resolve("systemRed"))]
          case "signing":
            row.showsSpinner = true
          default:
            row.trailingText = "等待中"
          }
          return row
        }
      ))
    }

    sections.append(TiebaFormSection(
      title: "关于一键签到",
      rows: [
        TiebaFormRow(
          id: "aboutSign",
          kind: .text,
          title: "一键签到会依次为您关注的每一个贴吧签到。开启自动签到后，应用会在每天指定时间通过后台任务自动签到。频繁签到可能被贴吧系统临时限制，建议开启慢速模式降低风险。",
          override: TiebaFormColor.resolve("secondaryLabel"),
          textStyle: "caption"
        )
      ]
    ))

    form.sections = sections
  }

  private func progressSummaryRow() -> TiebaFormRow {
    var items = [
      TiebaFormStatusItem(
        icon: "checkmark.circle.fill",
        text: "\(service.progressSuccess)",
        color: TiebaFormColor.resolve("systemGreen")
      )
    ]
    if service.progressFail > 0 {
      items.append(TiebaFormStatusItem(
        icon: "xmark.circle",
        text: "\(service.progressFail)",
        color: TiebaFormColor.resolve("systemRed")
      ))
    }
    var row = TiebaFormRow(id: "progressSummary", kind: .status, title: "", statusItems: items)
    if service.progressExp > 0 {
      row.trailingText = "共 \(service.progressItems.count) 个吧 · +\(service.progressExp) 经验"
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

  // MARK: - 引导气泡与成功动效

  /// 导航栏右侧「?」。用 customView 而不是 UIBarButtonItem(image:)：气泡要锚到
  /// 这颗按钮上，必须自己拿得住这个视图。
  private func installHelpButton() {
    let button = UIButton(type: .system)
    button.setImage(
      UIImage(systemName: "questionmark.circle", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17)),
      for: .normal
    )
    // 30×30 = 气泡锚点用的测量矩形（bar button 的常规尺寸）。
    button.frame = CGRect(x: 0, y: 0, width: 30, height: 30)
    button.accessibilityLabel = "一键签到说明"
    button.addAction(UIAction { [weak self] _ in
      TiebaSceneHaptics.fire("press")
      self?.showGuideTooltip()
    }, for: .touchUpInside)
    navigationItem.rightBarButtonItem = UIBarButtonItem(customView: button)
    helpButton = button
  }

  /// 锚定气泡（全仓首个）：锚点 = 导航栏那颗「?」，点气泡外任意处置关闭。
  private func showGuideTooltip() {
    // 连点「?」/引导与手动弹重叠时会撞上「已有 presentation 在进行中」，这里直接挡住。
    guard presentedViewController == nil else { return }
    var configuration = TiebaTooltipConfiguration(baseFontSize: 17)
    configuration.timeout = 4.0
    configuration.dismissByTapOutside = true
    // 首次引导：整屏压暗、在「?」上挖一个洞（反相挖洞遮罩，见 UI/Components）。
    configuration.spotlightsSource = true
    let tooltip = TiebaTooltipController(
      content: .text("点「一键签到」会依次为每个关注的吧签到；开启每日自动签到后到点自动完成，无需手动操作。"),
      configuration: configuration,
      anchor: .view { [weak self] in
        // 还没上屏时返回 nil：气泡退化成居中，不会锚到一个不在窗口里的矩形。
        guard let button = self?.helpButton, button.window != nil else { return nil }
        return (button, button.bounds)
      }
    )
    tooltip.present(on: self)
  }

  /// 签到成功的彩带 + 对勾。纯新增浮层，不改页面任何既有行为。
  private func playSignSuccess() {
    TiebaSceneHaptics.fire("action-success")
    successOverlay?.removeFromSuperview()
    let overlay = TiebaSignSuccessOverlay(frame: view.bounds)
    overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    view.addSubview(overlay)
    successOverlay = overlay
    overlay.play { [weak self] in
      self?.successOverlay = nil
    }
  }

  /// 切「通知栏」/关灵动岛时结束在场的签到 Live Activity（与旧页同款清理）。
  private func recoverStaleSignActivities() {
    Task { @MainActor in
      await TiebaLiveActivityManager.shared.endAllInterrupted()
    }
  }
}

// MARK: - 签到成功动效

/// 签到成功的浮层：彩带（UI/Nodes/TiebaConfettiView）+ 对勾（UI/Drawing/TiebaCheckNode）。
///
/// 对勾的入场缓动不用 UIView.animate 的固定曲线，而是拿 Core/TiebaDisplayLinkAnimator 的
/// TiebaConstantDisplayLinkAnimator 逐帧驱动、每帧用 UI/Drawing/TiebaSpring.bezierPoint
/// 求 cubic-bezier(0.34, 1.56, 0.64, 1)（y 过 1 ⇒ 末尾回弹一下）。好处有两个：
/// 曲线本身可调（不用去凑 CAMediaTimingFunction 的控制点），且走共享 display link 驱动，
/// 与彩带那路动画在同一条 CADisplayLink 上、前后台自动暂停。
private final class TiebaSignSuccessOverlay: UIView {
  private static let checkSide: CGFloat = 56
  /// 对勾入场时长；整层存活时长（彩带落完自己会收，这里负责收尾淡出）。
  private static let appearDuration: Double = 0.42
  private static let totalDuration: Double = 3.0
  private static let fadeOutDuration: Double = 0.3

  private let confetti: TiebaConfettiView
  private let checkNode: TiebaCheckNode
  private var animator: TiebaConstantDisplayLinkAnimator?
  private var startTime: CFTimeInterval = 0
  private var onFinished: (() -> Void)?

  override init(frame: CGRect) {
    confetti = TiebaConfettiView(frame: CGRect(origin: CGPoint.zero, size: frame.size))
    checkNode = TiebaCheckNode(
      theme: .plain(backgroundColor: .systemGreen, strokeColor: .white, borderColor: .clear),
      content: .check(isRectangle: false)
    )
    super.init(frame: frame)

    isUserInteractionEnabled = false
    backgroundColor = .clear

    confetti.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    addSubview(confetti)

    let side = Self.checkSide
    checkNode.frame = CGRect(
      x: (frame.width - side) / 2, y: (frame.height - side) / 2,
      width: side, height: side
    )
    checkNode.autoresizingMask = [
      .flexibleTopMargin, .flexibleBottomMargin, .flexibleLeftMargin, .flexibleRightMargin,
    ]
    checkNode.transform = CGAffineTransform(scaleX: 0.01, y: 0.01)
    checkNode.alpha = 0
    addSubview(checkNode)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func play(onFinished: @escaping () -> Void) {
    self.onFinished = onFinished
    startTime = CACurrentMediaTime()
    // 对勾本身由 CheckNode 自己的图层动画画出来（see TiebaCheckNode.setSelected）。
    checkNode.setSelected(true, animated: true)
    let animator = TiebaConstantDisplayLinkAnimator(update: { [weak self] in
      self?.tick()
    })
    self.animator = animator
    animator.isPaused = false
  }

  private func tick() {
    let elapsed = CACurrentMediaTime() - startTime
    let t = CGFloat(min(1.0, elapsed / Self.appearDuration))
    // 回弹曲线：t=1 时 bezierPoint 被夹到 1.0（TiebaSpring 内部对 >= 0.997 做了夹取）。
    let eased = TiebaSpring.bezierPoint(0.34, 1.56, 0.64, 1.0, t)
    let scale = max(0.01, eased)
    checkNode.transform = CGAffineTransform(scaleX: scale, y: scale)
    checkNode.alpha = min(1.0, t * 3.0)

    let fadeStart = Self.totalDuration - Self.fadeOutDuration
    if elapsed >= Self.totalDuration {
      finish()
    } else if elapsed >= fadeStart {
      alpha = CGFloat(max(0.0, (Self.totalDuration - elapsed) / Self.fadeOutDuration))
    }
  }

  private func finish() {
    animator?.isPaused = true
    animator?.invalidate()
    animator = nil
    removeFromSuperview()
    let onFinished = self.onFinished
    self.onFinished = nil
    onFinished?()
  }
}
