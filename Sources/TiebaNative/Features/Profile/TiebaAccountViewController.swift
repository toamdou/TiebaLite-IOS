// 账号管理（原 src/app/settings/account.tsx）：账号列表（切换/移除）+ 编辑个人资料
// + 添加账号 + 退出登录。数据与动作全走 TiebaSession（原生会话层）。
import UIKit

final class TiebaAccountViewController: UIViewController {
  private let form = TiebaSettingsForm.makeForm()
  private var accounts: [TiebaAccount] = []
  private var currentUid = ""

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemGroupedBackground
    form.onRowPress = { [weak self] id in self?.handleRowPress(id) }
    form.onPick = { [weak self] id, menuID in self?.handlePick(id, menuID: menuID) }
    form.onConfirm = { [weak self] id in self?.handleConfirm(id) }
    view.addSubview(form)
    TiebaSettingsForm.pin(form, in: view)
    reload()
    NotificationCenter.default.addObserver(
      self, selector: #selector(sessionDidChange), name: TiebaSession.didChangeNotification, object: nil
    )
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    reload()
  }

  @objc private func sessionDidChange() {
    reload()
  }

  // MARK: - 数据

  private func reload() {
    accounts = TiebaSession.accounts()
    currentUid = TiebaSession.activeUid
    let dark = TiebaSettingsForm.isDark(in: self)
    TiebaSettingsForm.reload(form, isDark: dark)
    form.sections = buildSections()
  }

  private func buildSections() -> [[String: Any]] {
    let loggedIn = TiebaSession.isLoggedIn
    let accountRows: [[String: Any]] = accounts.map { account in
      [
        "id": account.uid,
        "kind": "menu",
        "title": account.displayName,
        "subtitle": account.name.isEmpty ? "UID: \(account.uid)" : "@\(account.name)",
        "selected": account.uid == currentUid,
        "trailingColor": "#34C759",
        "menuItems": [["id": "remove", "title": "移除账号", "icon": "trash", "destructive": true]],
      ]
    }
    var sections: [[String: Any]] = [
      [
        "title": "已登录账号",
        "rows": accounts.isEmpty
          ? [[
              "id": "emptyAccounts", "kind": "empty",
              "icon": "person.crop.circle.badge.questionmark",
              "title": "暂无账号", "subtitle": "登录后将显示在这里",
            ]]
          : accountRows,
      ]
    ]
    if loggedIn {
      sections.append([
        "rows": [[
          "id": "editProfile", "kind": "button", "title": "编辑个人资料",
          "icon": "person.crop.circle.badge.checkmark",
        ]]
      ])
    }
    sections.append([
      "rows": [["id": "addAccount", "kind": "button", "title": "添加账号", "icon": "person.badge.plus"]]
    ])
    if loggedIn {
      sections.append([
        "rows": [[
          "id": "logout", "kind": "confirm", "title": "退出登录",
          "icon": "rectangle.portrait.and.arrow.right", "destructive": true,
          "confirmTitle": "退出登录", "confirmMessage": "确定要退出当前账号吗？", "confirmLabel": "退出",
        ]]
      ])
    }
    return sections
  }

  // MARK: - 动作

  private func handleRowPress(_ id: String) {
    switch id {
    case "editProfile":
      TiebaSettingsForm.push("/settings/edit-profile")
    case "addAccount":
      TiebaSceneHaptics.fire("press")
      TiebaNavigator.shared.navigate(path: "/login", params: [:], mode: "push")
    default:
      guard let target = accounts.first(where: { $0.uid == id }) else { return }
      switchAccount(target)
    }
  }

  private func switchAccount(_ account: TiebaAccount) {
    guard account.uid != currentUid else { return }
    Task { @MainActor in
      do {
        try await TiebaSession.switchAccount(uid: account.uid)
        TiebaSceneHaptics.fire("action-success")
      } catch {
        TiebaSceneHaptics.fire("action-fail")
        TiebaToast.show(error.localizedDescription, success: false)
      }
      reload()
    }
  }

  /// 行尾菜单（唯一一项：移除账号）。
  private func handlePick(_ id: String, menuID: String) {
    guard menuID == "remove", let target = accounts.first(where: { $0.uid == id }) else { return }
    presentRemoveAlert(target)
  }

  private func presentRemoveAlert(_ account: TiebaAccount) {
    let isCurrent = account.uid == currentUid
    let alert = UIAlertController(
      title: "移除账号",
      message: isCurrent
        ? "这是当前登录的账号，移除后将退出登录。"
        : "确定要移除账号「\(account.displayName)」吗？",
      preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(title: "取消", style: .cancel))
    alert.addAction(UIAlertAction(title: "移除", style: .destructive) { [weak self] _ in
      self?.remove(account, isCurrent: isCurrent)
    })
    present(alert, animated: true)
  }

  private func remove(_ account: TiebaAccount, isCurrent: Bool) {
    TiebaSceneHaptics.fire("destructive")
    Task { @MainActor in
      if isCurrent {
        do {
          _ = try await TiebaSession.logout()
          TiebaSceneHaptics.fire("action-success")
        } catch {
          TiebaSceneHaptics.fire("action-fail")
          TiebaToast.show(error.localizedDescription, success: false)
        }
      } else {
        TiebaSession.deleteAccount(uid: account.uid)
        TiebaSceneHaptics.fire("action-success")
      }
      reload()
    }
  }

  private func handleConfirm(_ id: String) {
    guard id == "logout" else { return }
    Task { @MainActor in
      do {
        _ = try await TiebaSession.logout()
        TiebaSceneHaptics.fire("action-success")
        _ = TiebaNavigator.shared.goBack()
      } catch {
        TiebaSceneHaptics.fire("action-fail")
        TiebaToast.show(error.localizedDescription, success: false)
      }
    }
  }
}
