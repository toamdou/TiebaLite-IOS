// 编辑资料（原 src/app/settings/edit-profile.tsx）：头像上传 + 昵称/性别/简介 +
// 保存。资料每 uid 只拉一次（头像上传等重渲染不覆写未保存的编辑）；输入值由
// 原生输入行自持，仅非编辑态才被 sections 回写（TiebaFormListView 的约定）。
//
// 2026-10-05（报告 32 §1.2）：头像上传失败不再只飘 toast —— 失败挂在头像行上就地可操作
//   （预览留图 + 分组 footer 写原因 + 行内「重试上传」+ 追加「换一张图」）。
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
  /// 上传失败的那张图 + 失败原因：非空 = 错误挂在头像行上就地重试
  ///（报告 31 §一-6：错误是"对象"的一部分，不是屏幕中央一闪而过的 toast）。
  private var failedPortrait: (uri: String, reason: String)?

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

  private func buildSections(dark: Bool) -> [TiebaFormSection] {
    if loading {
      return [TiebaFormSection(rows: [TiebaFormRow(id: "loading", kind: .spinner, title: "")])]
    }
    let tint = TiebaNavigator.shared.chromeTheme.tint
    let avatarURL = TiebaSimpleRowParser.avatarURL(portrait)?.absoluteString ?? ""
    // 失败态（上传中不显示）：行内按钮变「重试上传」+ 系统红，失败原因写在本组 footer，
    // 再追加一行「换一张图」—— 一个错误给出两个就地出路，用户不必重进编辑页。
    let failure = uploading ? nil : failedPortrait
    let avatarRow = TiebaFormRow(
      id: "avatar",
      kind: .avatar,
      title: "",
      avatarURL: avatarURL,
      initials: String(nickName.prefix(1)),
      avatarSize: 64.0,
      trailingStyle: "filledButton",
      trailingTitle: uploading ? "上传中…" : (failure == nil ? "更换头像" : "重试上传"),
      trailingIcon: failure == nil ? "camera.fill" : "arrow.clockwise",
      trailingColor: TiebaFormColor.resolve(failure == nil ? TiebaFormListView.hexString(from: tint) : "systemRed"),
      trailingBusy: uploading,
      trailingDisabled: uploading
    )
    var avatarSection = TiebaFormSection(title: "头像", rows: [avatarRow])
    if let failure {
      avatarSection.footer = "头像上传失败：\(failure.reason)"
      avatarSection.rows = [
        avatarRow,
        TiebaFormRow(id: "avatarRepick", kind: .button, title: "换一张图"),
      ]
    }
    let nickRow = TiebaFormRow(
      id: "nickName",
      kind: .textField,
      title: "",
      value: nickName,
      placeholder: "昵称",
      maxLength: 30
    )
    let introRow = TiebaFormRow(
      id: "intro",
      kind: .textField,
      title: "",
      value: intro,
      placeholder: "介绍一下自己",
      maxLength: 200,
      multiline: true
    )
    let sexRows = Self.sexOptions.map { value, label in
      TiebaFormRow(id: "sex", kind: .option, title: label, value: value, selected: sex == Int(value))
    }
    let saveRow = saving
      ? TiebaFormRow(id: "saving", kind: .spinner, title: "")
      : TiebaFormRow(id: "save", kind: .button, title: "保存")
    return [
      avatarSection,
      TiebaFormSection(title: "昵称", rows: [nickRow]),
      TiebaFormSection(title: "性别", rows: sexRows),
      TiebaFormSection(title: "个人简介", rows: [introRow]),
      TiebaFormSection(rows: [saveRow]),
    ]
  }

  // MARK: - 动作

  private func handleRowPress(_ id: String) {
    if id == "save" {
      save()
    } else if id == "avatar" {
      // 有未处理的上传失败时，这一下就是「就地重试」；否则才是选新图。
      if let failure = failedPortrait { uploadPortrait(failure.uri) } else { openPicker() }
    } else if id == "avatarRepick" {
      openPicker()
    }
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
        self.failedPortrait = nil
        // 不把 Caches 临时路径写进会话档案：refreshProfile 是 fire-and-forget 且吞错，
        // 一旦落盘，系统清 Caches 后所有读账号头像的入口都加载死路径。即时预览只需本页
        // 的 portrait（下面那行 refreshProfile 成功后会写服务端值）。
        TiebaSceneHaptics.fire("action-success")
        TiebaToast.show("头像已更新", success: true)
        // 服务端最终头像 ID 异步收敛（本地 uri 只作即时预览）。
        Task { await TiebaSession.refreshProfile(uid: self.uid) }
      } catch {
        TiebaSceneHaptics.fire("action-fail")
        // 就地可操作：选中的图留在预览位（只写本页 portrait，不写会话/档案），失败原因挂到
        // 「头像」分组的 footer，行内按钮变「重试上传」并追加一行「换一张图」。
        // 不再飘 toast —— 用户在原地看着那一条失败的头像就能补救。
        self.portrait = uri
        self.failedPortrait = (uri, error.localizedDescription)
      }
    }
  }

  private func presentAlert(_ title: String, _ message: String) {
    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "好", style: .cancel))
    present(alert, animated: true)
  }
}
