import UIKit

/// 帖子「更多」sheet（原 src/app/thread/[id]/more.tsx）：行状态来自类型化路由参数
///（canDelete / seeLz / sort——旧 params 里的 title/forumId/forumName/isCollected
/// 本页从未读取，迁移时未保留）。
///
/// 点行先收起 sheet；本页 viewDidDisappear（收起转场结束）时经 TiebaThreadMoreSignal
/// 把动作交给帖子页（原 DeviceEventEmitter 通道的原生替身）。
final class TiebaThreadMoreViewController: UIViewController {
  private let threadId: String
  private let canDelete: Bool
  private let seeLz: Bool
  private let sort: TiebaThreadSort
  private let form = TiebaFormListView(frame: .zero)
  /// 选中动作暂存：等本页 viewDidDisappear（收起转场结束）再经 signal 发出。
  private var pendingAction: TiebaThreadMoreSignal.Action?

  init(threadId: String, canDelete: Bool, seeLz: Bool, sort: TiebaThreadSort) {
    self.threadId = threadId
    self.canDelete = canDelete
    self.seeLz = seeLz
    self.sort = sort
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemGroupedBackground
    form.translatesAutoresizingMaskIntoConstraints = false
    form.isDark = TiebaNavigator.shared.chromeTheme.dark
    form.onRowPress = { [weak self] id in self?.handleRowPress(id) }
    form.onPick = { [weak self] group, value in
      guard group == "sort" else { return }
      self?.handleSortPick(value)
    }
    view.addSubview(form)
    NSLayoutConstraint.activate([
      form.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      form.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      form.topAnchor.constraint(equalTo: view.topAnchor),
      form.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    form.sections = sections()
  }

  private func sections() -> [[String: Any]] {
    let browsing: [[String: Any]] = [
      [
        "id": "seeLz",
        "kind": "link",
        "title": seeLz ? "只看楼主（开启）" : "只看楼主",
        "icon": seeLz ? "person.fill" : "person",
        "iconTint": "#5856D6",
      ],
      [
        "id": "jump",
        "kind": "link",
        "title": "跳转页码",
        "icon": "arrow.right.to.line",
        "iconTint": "#5856D6",
      ],
    ]
    // 排序 = 三档直接选（与帖子页那颗药丸同一套语义），当前档打勾；不再是"点一次换一档"。
    let sortRows: [[String: Any]] = TiebaThreadSort.allCases.map { option in
      [
        "id": "sort",
        "kind": "option",
        "title": option.title,
        "value": String(option.rawValue),
        "selected": option == sort,
      ]
    }
    var actions: [[String: Any]] = [
      [
        "id": "share",
        "kind": "link",
        "title": "分享",
        "icon": "square.and.arrow.up",
        "iconTint": "#0A84FF",
      ]
    ]
    if canDelete {
      actions.append([
        "id": "delete",
        "kind": "link",
        "title": "删除",
        "icon": "trash",
        "iconTint": "#FF3B30",
      ])
    }
    return [
      ["title": "浏览", "rows": browsing],
      ["title": "排序", "rows": sortRows],
      ["title": "操作", "rows": actions],
    ]
  }

  /// 收起转场已结束（viewDidDisappear 在 dismiss 动画完成后才到）才把动作交给
  /// 帖子页：接收侧收到即可直接 present（新窗口不会被收起中的转场静默拒绝）。
  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    guard let action = pendingAction else { return }
    pendingAction = nil
    TiebaThreadMoreSignal.shared.post(threadId: threadId, action: action)
  }

  private func handleRowPress(_ id: String) {
    TiebaSceneHaptics.fire("press")
    switch id {
    case "seeLz": pendingAction = .seeLz
    case "jump": pendingAction = .jump
    case "share": pendingAction = .share
    case "delete": pendingAction = .delete
    default: break
    }
    TiebaNavigator.shared.dismissPresented(animated: true)
  }

  /// 排序档位（option 行的 value = TiebaThreadSort 的 rawValue）。选的就是当前档
  /// 也不必特判：收起后由帖子页按"同档不重载"处理。
  private func handleSortPick(_ value: String) {
    TiebaSceneHaptics.fire("press")
    pendingAction = .selectSort(TiebaThreadSort(rawValue: Int(value) ?? -1) ?? .hot)
    TiebaNavigator.shared.dismissPresented(animated: true)
  }
}
