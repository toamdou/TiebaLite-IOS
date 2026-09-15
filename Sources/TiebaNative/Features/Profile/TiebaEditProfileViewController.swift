// 编辑资料（原 src/app/settings/edit-profile.tsx）：头像上传 + 昵称/性别/简介 +
// 保存。资料每 uid 只拉一次（头像上传等重渲染不覆写未保存的编辑）；输入值由
// 原生输入行自持，仅非编辑态才被 sections 回写（TiebaFormListView 的约定）。
import UIKit

final class TiebaEditProfileViewController: UIViewController {
  private static let sexOptions = [
    ("0", "保密"), ("1", "男"), ("2", "女"),
  ]

  private let form = TiebaSettingsForm.makeForm()
  private var uid = ""
  private var portrait = ""

  private var nickName = ""
  private var intro = ""
  private var sex = 0

  private var fetchedUid = ""
  private var failedUid = ""
  private var loading = false
  private var saving = false
  private var uploading = false

  private var fetched = false

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemGroupedBackground
    form.onRowPress = { [weak self] id in self?.handleRowPress(id) }
    form.onPick = { [weak self] group, value in self?.handlePick(group, value) }
    form.onTextChange = { [weak self] id, value in self?.handleTextChange(id, value) }
    view.addSubview(form)
    TiebaSettingsForm.pin(form, in: view)
    loadAccount()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    if !fetched, !loading { loadProfile() }
  }

  // MARK: - 数据

  private func loadAccount() {
    let account = TiebaSession.currentAccount()
    uid = account?.uid ?? ""
    portrait = account?.portrait ?? ""
    nickName = account.map { $0.nameShow.isEmpty ? $0.name : $0.nameShow } ?? ""
    reload()
    loadProfile()
  }

  /// 资料拉取只做一次（每 uid）：失败记 failedUid 不再重试，成功记 fetchedUid。
  private func loadProfile() {
    guard !uid.isEmpty, fetchedUid != uid, failedUid != uid else { return }
    loading = true
    reload()
    let target = uid
    Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        self.loading = false
        self.fetched = true
        self.reload()
      }
      guard let detail = try? await TiebaProfileAPI.profile(uid: target) else {
        self.failedUid = target
        return
      }
      guard target == self.uid else { return }
      self.nickName = detail.nameShow.isEmpty ? detail.name : detail.nameShow
      self.intro = detail.intro
      self.sex = detail.sex
      self.fetchedUid = target
    }
  }

  private func reload() {
    let dark = TiebaSettingsForm.isDark(in: self)
    TiebaSettingsForm.reload(form, isDark: dark)
    form.sections = buildSections(dark: dark)
  }

  private func buildSections(dark: Bool) -> [[String: Any]] {
    if loading {
      return [["rows": [["id": "loading", "kind": "spinner", "title": ""]]]]
    }
    let tint = TiebaNavigator.shared.chromeTheme.tint
    let avatarURL = TiebaSimpleRowParser.avatarURL(portrait)?.absoluteString ?? ""
    let avatarRow: [String: Any] = [
      "id": "avatar", "kind": "avatar", "title": "",
      "avatarURL": avatarURL, "initials": String(nickName.prefix(1)),
      "avatarSize": 64.0,
      "trailingStyle": "filledButton",
      "trailingTitle": uploading ? "上传中…" : "更换头像",
      "trailingIcon": "camera.fill",
      "trailingColor": TiebaFormListView.hexString(from: tint),
      "trailingDisabled": uploading,
      "trailingBusy": uploading,
    ]
    let nickRow: [String: Any] = [
      "id": "nickName", "kind": "textField", "title": "",
      "placeholder": "昵称", "maxLength": 30, "value": nickName,
    ]
    let introRow: [String: Any] = [
      "id": "intro", "kind": "textField", "title": "",
      "placeholder": "介绍一下自己", "maxLength": 200, "multiline": true, "value": intro,
    ]
    let sexRows: [[String: Any]] = Self.sexOptions.map { value, label in
      ["id": "sex", "kind": "option", "title": label, "value": value, "selected": sex == Int(value)]
    }
    let saveRow: [String: Any] = saving
      ? ["id": "saving", "kind": "spinner", "title": ""]
      : ["id": "save", "kind": "button", "title": "保存"]
    return [
      ["title": "头像", "rows": [avatarRow]],
      ["title": "昵称", "rows": [nickRow]],
      ["title": "性别", "rows": sexRows],
      ["title": "个人简介", "rows": [introRow]],
      ["rows": [saveRow]],
    ]
  }

  // MARK: - 动作

  private func handleRowPress(_ id: String) {
    if id == "save" { save() }
    else if id == "avatar" { openPicker() }
  }

  private func handlePick(_ group: String, _ value: String) {
    guard group == "sex", let next = Int(value) else { return }
    sex = next
    reload()
  }

  private func handleTextChange(_ id: String, _ value: String) {
    if id == "nickName" { nickName = value } else if id == "intro" { intro = value }
  }

  private func save() {
    guard !uid.isEmpty else {
      presentAlert("提示", "请先登录")
      return
    }
    guard !saving else { return }
    saving = true
    reload()
    let nick = nickName.trimmingCharacters(in: .whitespacesAndNewlines)
    let bio = intro.trimmingCharacters(in: .whitespacesAndNewlines)
    let sexValue = sex
    Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        self.saving = false
        self.reload()
      }
      do {
        try await TiebaSocialAPI.modifyProfile(intro: bio, sex: sexValue, nickName: nick)
        // 档案缓存立即回填：否则改造过的昵称/简介要到过期或重登才生效
        //（首页、图片水印都读这份缓存）。
        await TiebaSession.refreshProfile(uid: uid)
        TiebaSceneHaptics.fire("action-success")
        let alert = UIAlertController(title: "已保存", message: "个人资料已更新", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default) { _ in
          _ = TiebaNavigator.shared.goBack()
        })
        (TiebaTopViewController.find() ?? self).present(alert, animated: true)
      } catch {
        self.presentAlert("保存失败", error.localizedDescription)
      }
    }
  }

  private func openPicker() {
    TiebaSceneHaptics.fire("sheet-present")
    TiebaPhotoPicker.presentSingleImage { [weak self] result in
      guard let self else { return }
      switch result {
      case .success(let uri):
        guard !uri.isEmpty else { return }  // 用户取消
        self.uploadPortrait(uri)
      case .failure(let error):
        TiebaSceneHaptics.fire("action-fail")
        self.presentAlert("打开相册失败", error.localizedDescription)
      }
    }
  }

  private func uploadPortrait(_ uri: String) {
    uploading = true
    reload()
    Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        self.uploading = false
        self.reload()
      }
      do {
        let tbs = try await TiebaSession.requireTbs()
        try await TiebaSocialAPI.uploadPortrait(fileUri: uri, tbs: tbs)
        self.portrait = uri
        TiebaSession.updatePortrait(uri)
        TiebaSceneHaptics.fire("action-success")
        TiebaToast.show("头像已更新", success: true)
        // 服务端最终头像 ID 异步收敛（本地 uri 只作即时预览）。
        Task { await TiebaSession.refreshProfile(uid: self.uid) }
      } catch {
        TiebaSceneHaptics.fire("action-fail")
        TiebaToast.show("头像上传失败：\(error.localizedDescription)", success: false)
      }
    }
  }

  private func presentAlert(_ title: String, _ message: String) {
    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "好", style: .cancel))
    present(alert, animated: true)
  }
}
