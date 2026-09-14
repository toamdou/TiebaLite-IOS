// ============================================================
// TiebaFormPageController —— 设置页群共用的表单页壳
//
// 设置页原先各自复制「viewDidLoad 挂钩 / viewWillAppear 重刷 / reload() /
// options 构造器」样板，且事件写完偏好后不回推表单（受控开关停在旧值）。这里把壳
// 收敛成基类：子类只给 makeSections 与自己的事件分支（本批 7 页已接入；
// account / oksign 两页暂未纳入，继续用 TiebaSettingsForm.reload 的旧挂钩）。
//
// 事件回推约定：写偏好成功 → form.setValue(id:value:) 就地 patch 该行（不整表
// reload）；写失败 → 不回推（开关弹回原值）+ action-fail 触觉 + 提示。
// 默认 handle 把事件 id 当偏好键（habit / image 的选择器即此约定）；
// id 与键不同的页面（设置首页的 /pref/… 路径、屏蔽页的局部状态）自行覆写。
// ============================================================
import UIKit

/// 表单事件（与 TiebaFormListView 的回调一一对应）。
enum TiebaFormEvent {
  case press(String)
  case toggle(String, Bool)
  case pick(String, String)
  case confirm(String)
  case color(String, String)
  case text(String, String)
}

class TiebaFormPageController: UIViewController {
  let form = TiebaSettingsForm.makeForm()

  /// 当前深浅（默认按偏好；屏蔽页覆写为导航壳主题）。
  var formIsDark: Bool { TiebaSettingsForm.isDark(in: self) }

  /// 表单主色（默认按当前主题；屏蔽页覆写为壳主题色）。
  var formTintHex: String? { TiebaSettingsForm.tintHex(dark: formIsDark) }

  // MARK: - 数据

  /// 子类给整份 sections（抽象点：子类必须实现）。
  func makeSections(dark: Bool) -> [[String: Any]] {
    fatalError("makeSections(dark:) 必须由子类实现")
  }

  /// [(value, label)] → 行 options 形态（各页原先各写一份）。
  func options(_ table: [(value: String, label: String)]) -> [[String: String]] {
    table.map { ["value": $0.value, "label": $0.label] }
  }

  /// 重刷：主题（主色/深浅）+ 整份 sections。
  func reload() {
    let dark = formIsDark
    form.tintHex = formTintHex
    form.isDark = dark
    form.sections = makeSections(dark: dark)
  }

  // MARK: - 事件

  /// 默认实现：id = 偏好键，落库 + 回推。子类覆写处理自己的 id（不调 super 表示
  /// 该事件由子类全权负责）。
  func handle(_ event: TiebaFormEvent) {
    switch event {
    case .toggle(let id, let value):
      write(id, bool: value)
    case .pick(let id, let value):
      write(id, string: value)
    case .press, .confirm, .color, .text:
      break
    }
  }

  /// 写布尔偏好；成功就地回推。row 缺省 = 行 id 与键同名。
  @discardableResult
  func write(_ key: String, bool value: Bool, row rowID: String? = nil) -> Bool {
    guard TiebaPreferences.set(key, bool: value) else {
      reportWriteFailure()
      // 写失败要把开关拨回真实档位（开关不再"先拨回等回推"，失败路径得自己拨正）。
      form.setValue(
        id: rowID ?? key,
        value: TiebaPreferences.bool(rowID ?? key, default: false) ? "1" : "0"
      )
      return false
    }
    form.setValue(id: rowID ?? key, value: value ? "1" : "0")
    return true
  }

  /// 写字符串偏好；成功就地回推。
  @discardableResult
  func write(_ key: String, string value: String, row rowID: String? = nil) -> Bool {
    guard TiebaPreferences.set(key, string: value) else {
      reportWriteFailure()
      return false
    }
    form.setValue(id: rowID ?? key, value: value)
    return true
  }

  /// 写数值偏好；成功就地回推（表单值用 JS 数字字面量形态）。
  @discardableResult
  func write(_ key: String, number value: Double, row rowID: String? = nil) -> Bool {
    guard TiebaPreferences.set(key, number: value) else {
      reportWriteFailure()
      return false
    }
    form.setValue(id: rowID ?? key, value: TiebaPreferences.numberLiteral(value))
    return true
  }

  /// 写盘失败的统一反馈（受控控件已弹回原值，这里只发失败触觉 + 提示）。
  func reportWriteFailure() {
    TiebaSceneHaptics.fire("action-fail")
    TiebaToast.show("设置保存失败，请重试", success: false)
  }

  // MARK: - 生命周期

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemGroupedBackground
    form.onRowPress = { [weak self] id in self?.handle(.press(id)) }
    form.onToggle = { [weak self] id, value in self?.handle(.toggle(id, value)) }
    form.onPick = { [weak self] id, value in self?.handle(.pick(id, value)) }
    form.onConfirm = { [weak self] id in self?.handle(.confirm(id)) }
    form.onColorChange = { [weak self] id, value in self?.handle(.color(id, value)) }
    form.onTextChange = { [weak self] id, value in self?.handle(.text(id, value)) }
    view.addSubview(form)
    TiebaSettingsForm.pin(form, in: view)
    reload()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    reload()
  }
}
