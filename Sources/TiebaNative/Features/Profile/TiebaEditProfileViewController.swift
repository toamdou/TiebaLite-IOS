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
  /// 拉取失败的原因。失败后本页的简介/性别停在初始默认值，静默保存会把默认值写回服务端，
  /// 所以失败必须在页面上可见（走查 D11-1）。
  private var failedProfileReason = ""
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
      do {
        let detail = try await TiebaProfileAPI.profile(uid: target)
        guard target == self.uid else { return }
        self.nickName = detail.nameShow.isEmpty ? detail.name : detail.nameShow
        self.intro = detail.intro
        self.sex = detail.sex
        self.fetchedUid = target
        self.failedUid = ""
        self.failedProfileReason = ""
      } catch {
        self.failedUid = target
        self.failedProfileReason = error.localizedDescription
      }
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
    let tint = TiebaChromeTheme.current.tint
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
    // 资料没拉到时把"这一页的值不可信"写在页面上，并给一次重试：否则页面看起来完全正常，
    // 用户只改昵称就保存，简介/性别按默认值覆盖服务端（走查 D11-1）。
    let profileLoadFailed = !uid.isEmpty && failedUid == uid && !loading
    var nickSection = TiebaFormSection(title: "昵称", rows: [nickRow])
    if profileLoadFailed {
      nickSection.rows.append(TiebaFormRow(id: "reloadProfile", kind: .button, title: "重试加载资料"))
      nickSection.footer = "资料未能加载：\(failedProfileReason)。简介与性别仍是默认值，保存会按默认值覆盖服务端。"
    }
    return [
      avatarSection,
      nickSection,
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
    } else if id == "reloadProfile" {
      // 两个门都要清：failedUid 挡住 loadProfile 自身，fetched 挡住 viewWillAppear 的入口。
      failedUid = ""
      failedProfileReason = ""
      fetched = false
      loadProfile()
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
    // 资料没拉到就提交 = 用本页初始默认值（简介空、性别保密）覆写服务端昵称之外的字段
    //（走查 D11-1）。先把后果讲清楚，用户选「仍然保存」才真的写。
    guard fetchedUid == uid else {
      presentUnloadedProfileConfirm()
      return
    }
    performSave()
  }

  /// 资料未加载时的保存确认：说清"简介/性别会按默认值写回"，并给"重试加载"这条正路。
  private func presentUnloadedProfileConfirm() {
    let alert = UIAlertController(
      title: "资料未加载",
      message: failedProfileReason.isEmpty
        ? "简介与性别仍是默认值，继续保存会用默认值覆盖服务端。"
        : "资料未能加载（\(failedProfileReason)），继续保存会用默认值覆盖服务端。",
      preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(title: "重试加载", style: .default) { [weak self] in
      self?.handleRowPress("reloadProfile")
    })
    alert.addAction(UIAlertAction(title: "仍然保存", style: .destructive) { [weak self] in
      self?.performSave()
    })
    alert.addAction(UIAlertAction(title: "取消", style: .cancel))
    (TiebaTopViewController.find() ?? self).present(alert, animated: true)
  }

  private func performSave() {
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
