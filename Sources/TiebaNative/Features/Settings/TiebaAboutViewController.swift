// ============================================================
// TiebaAboutViewController —— 「关于」页（原 src/app/settings/about.tsx）
//
// 整屏原生：视图 = TiebaFormListView（plain UIView，系统表单行），数据与动作全在
// 本类里（无 JS、无 Expo）。页面结构走 TiebaFormListView，
// 这里直接挂**纯视图本体**，连那层 Expo 适配器都不需要。
//
// 布局与文案逐字对齐旧页面：
//   区块 1：hero 行（打包图 expo.icon/Assets/icon-light.png + 应用名 + Version x）
//   区块 2「更新」：检查更新按钮 / 结果文字行（发现新版本… | 已是最新版本）/
//                  失败文字行（检查失败：…）/ 条件出现的 Release 页面按钮
//   区块 3「仓库与致谢」：5 个仓库按钮
// 两段 footer 文案与 5 个按钮的标题/图标/URL 全部照搬（见下方常量）。
//
// 行为对齐：
//   - 触觉：每次按钮动作前 hapticForScene('press')（检查更新 / 仓库 / 打开 Release）；
//   - 检查更新：原生 GitHub 拉取（TiebaUpdateService），点完**总是**弹结果弹窗
//     （原 handleCheck 的 finally setDialogVisible(true)）；
//   - 「检查更新」按钮在检查中显示「正在检查…」且连点复用同一次请求；
//   - 结果状态跨页面存续（服务是单例，与 zustand store 语义一致）；
//   - 表单染色的「默认主题不染色」规则：从原生 KV 现读 lightTheme/darkTheme，
//     主题名为 default 时不下发 tint（行图标五彩、按钮走系统蓝）——与
//     useFormTintHex() 逐字同义；主色取导航壳的 themeTint（= colors.primary）。
// ============================================================
import UIKit

final class TiebaAboutViewController: UIViewController {
  // 仓库链：本应用（纯原生）← Kotlin 版（fork）← Kotlin 原版（真正原创）
  private static let repoApp = "https://github.com/toamdou/TiebaLite-IOS"
  private static let repoKotlinFork = "https://github.com/zcc10086/TiebaLite"
  private static let repoKotlinOriginal = "https://github.com/HuanCheng65/TiebaLite"
  private static let repoAiotieba = "https://github.com/Starry-OvO/aiotieba"
  private static let repoTbclient = "https://github.com/n0099/tbclient.protobuf"

  private static let updateFooter = "更新源为 GitHub 仓库（toamdou/TiebaLite-IOS）的 Releases。可在「设置 → 通用 → 自动检测更新」开启启动时自动检查。"
  private static let reposFooter = "本应用为纯原生（Swift / UIKit）实现；Kotlin 版（zcc10086/TiebaLite）fork 自 Kotlin 原版（HuanCheng65/TiebaLite），API 协议与交互均以其为参照；协议字段定义参考 aiotieba 项目与 n0099/tbclient.protobuf（贴吧客户端 protobuf 定义合集）。"

  private let service = TiebaUpdateService.shared
  private let form = TiebaFormListView(frame: .zero)
  private var observerToken: UUID?
  /// 主题类键：外观（染色/深浅）就地重算；本页行结构不随主题变，不整表重建。
  private static let appearanceKeys = ["lightTheme", "darkTheme", "customPrimaryColor"]
  /// 观察者/外观登记都是 non-Sendable，deinit 非隔离：与 TiebaHomeViewController 同款声明。
  private nonisolated(unsafe) var prefToken: NSObjectProtocol?
  private var styleRegistration: UITraitChangeRegistration?

  deinit {
    if let prefToken { NotificationCenter.default.removeObserver(prefToken) }
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemGroupedBackground
    form.translatesAutoresizingMaskIntoConstraints = false
    form.onRowPress = { [weak self] id in self?.handleRowPress(id) }
    view.addSubview(form)
    NSLayoutConstraint.activate([
      form.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      form.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      form.topAnchor.constraint(equalTo: view.topAnchor),
      form.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    reloadSections()
    // 在屏时主题/主色被别处改写就地重染表单（原来只有出现时现读）。
    prefToken = TiebaPreferenceChange.observe(keys: Self.appearanceKeys) { [weak self] in
      self?.refreshAppearance()
    }
    // 跟随系统时深浅由本页显式下发（form.isDark 会锁死表单自身 trait），
    // 系统切档后不重算会停在上一档（导航壳只重刷自己）。
    styleRegistration = registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
      (controller: TiebaAboutViewController, _) in
      controller.refreshAppearance()
    }
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    // 这句不是"现读偏好"：更新结果的文本行随服务状态增删（结构性），且服务观察者
    // 在离开时会被移除，回到本页必须重挂 + 用最新状态重建一次；外观重算见 refreshAppearance。
    reloadSections()
    observerToken = service.addObserver { [weak self] in self?.reloadSections() }
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    if let observerToken {
      service.removeObserver(observerToken)
      self.observerToken = nil
    }
  }

  // MARK: - 数据

  private func reloadSections() {
    form.tintHex = Self.formTintHex()
    form.isDark = TiebaNavigator.shared.chromeTheme.dark
    form.sections = buildSections()
  }

  /// 外观就地重算（行结构不随主题变，不重刷 sections）：深浅/主色从偏好 + 当前
  /// trait 现算 —— 导航壳的 themeTint 要等 applyTheme 重下发，广播回调里读可能读到旧值。
  private func refreshAppearance() {
    let dark = TiebaSettingsForm.isDark(in: self)
    form.tintHex = TiebaSettingsForm.tintHex(dark: dark)
    form.isDark = dark
  }

  /// useFormTintHex() 的原生同义实现：「默认」主题不染色（nil）；其余主题下发
  /// 导航壳的 themeTint（= colors.primary）。主题名按当前深浅取 lightTheme/darkTheme
  /// （深浅用导航壳收到的 dark，即 JS 的 isDark，避免被宿主强制 trait 影响判断）。
  private static func formTintHex() -> String? {
    let dark = TiebaNavigator.shared.chromeTheme.dark
    let themeName = TiebaPreferenceSnapshot.string(dark ? "darkTheme" : "lightTheme") ?? "default"
    guard themeName != "default" else { return nil }
    return TiebaFormListView.hexString(from: TiebaNavigator.shared.chromeTheme.tint)
  }

  private func buildSections() -> [[String: Any]] {
    let status = service.status
    let release = service.release
    let checking = status == .checking

    var updateRows: [[String: Any]] = [
      [
        "id": "checkUpdate",
        "kind": "button",
        "title": checking ? "正在检查…" : "检查更新",
        "icon": "arrow.triangle.2.circlepath",
      ]
    ]
    if status == .done, let release {
      updateRows.append([
        "id": "updateResult",
        "kind": "text",
        "textStyle": "subheadline",
        "title": service.hasUpdate
          ? "发现新版本 v\(release.version)（当前 v\(service.currentVersion)）"
          : "已是最新版本（v\(service.currentVersion)）",
      ])
    }
    if status == .error {
      updateRows.append([
        "id": "updateError",
        "kind": "text",
        "textStyle": "footnote",
        // 旧页面传的是 colors.textSecondary（rgba 串）：原生表单解析不了 rgba，
        // 回落到 .label——这里用等价的系统语义 token，恢复旧页面的次级灰。
        "color": "secondaryLabel",
        "title": "检查失败：\(service.error ?? "网络异常")",
      ])
    }
    if release != nil {
      updateRows.append([
        "id": "openRelease",
        "kind": "button",
        "title": "在浏览器中打开 Release 页面",
        "icon": "safari",
      ])
    }

    let repoButtons: [(id: String, title: String, icon: String)] = [
      ("repoApp", "本应用 · toamdou/TiebaLite-IOS", "iphone"),
      ("repoKotlinFork", "Kotlin 版 · zcc10086/TiebaLite", "arrow.triangle.branch"),
      ("repoKotlinOriginal", "Kotlin 原版 · HuanCheng65/TiebaLite", "crown.fill"),
      ("repoAiotieba", "aiotieba · Starry-OvO/aiotieba", "network"),
      ("repoTbclient", "tbclient.protobuf · n0099", "curlybraces"),
    ]

    return [
      [
        "rows": [
          [
            "id": "hero",
            "kind": "hero",
            "title": "贴吧Lite",
            "subtitle": "Version \(TiebaReleaseAPI.currentVersion())",
            "textStyle": "title",
            "imageName": "expo.icon/Assets/icon-light.png",
          ]
        ]
      ],
      [
        "title": "更新",
        "footer": Self.updateFooter,
        "rows": updateRows,
      ],
      [
        "title": "仓库与致谢",
        "footer": Self.reposFooter,
        "rows": repoButtons.map { item in
          [
            "id": item.id,
            "kind": "button",
            "title": item.title,
            "icon": item.icon,
          ]
        },
      ],
    ]
  }

  // MARK: - 动作

  private func handleRowPress(_ id: String) {
    switch id {
    case "checkUpdate":
      handleCheck()
    case "openRelease":
      TiebaSceneHaptics.fire("press")
      // 原：openRelease(release?.url || RELEASES_PAGE_URL)，强制系统浏览器。
      TiebaLinkOpener.openExternal(service.release?.url ?? TiebaReleaseAPI.releasesPage)
    case "repoApp":
      openRepo(Self.repoApp)
    case "repoKotlinFork":
      openRepo(Self.repoKotlinFork)
    case "repoKotlinOriginal":
      openRepo(Self.repoKotlinOriginal)
    case "repoAiotieba":
      openRepo(Self.repoAiotieba)
    case "repoTbclient":
      openRepo(Self.repoTbclient)
    default:
      break
    }
  }

  /// 点「检查更新」= 拉一次最新 Release，然后弹窗展示版本与更新日志
  ///（原 handleCheck：await check() 之后**无条件** setDialogVisible(true)）。
  private func handleCheck() {
    TiebaSceneHaptics.fire("press")
    Task { @MainActor in
      await service.check()
      presentResultDialog()
    }
  }

  private func openRepo(_ url: String) {
    TiebaSceneHaptics.fire("press")
    TiebaLinkOpener.open(url)
  }

  private func presentResultDialog() {
    // 连点两次时第一次的请求仍在飞：第二次的 check() 早退，这里立刻弹
    // 「正在检查更新…」，结果落地时弹窗内部自行刷新（订阅服务状态）。
    guard presentedViewController == nil else { return }
    present(TiebaUpdateDialogViewController(), animated: true)
  }
}
