import UIKit

/// 帖子「更多」sheet（原 src/app/thread/[id]/more.tsx）：全部行来自路由参数。
///
/// 点行先收起 sheet；本页 viewDidDisappear（收起转场结束）时经 TiebaThreadMoreSignal
/// 把动作交给帖子页（原 DeviceEventEmitter 通道的原生替身）。
final class TiebaThreadMoreViewController: UIViewController {
  private let threadId: String
  private let canDelete: Bool
  private let seeLz: Bool
  private let reverse: Bool
  private let form = TiebaFormListView(frame: .zero)
  /// 选中动作暂存：等本页 viewDidDisappear（收起转场结束）再经 signal 发出。
  private var pendingAction: TiebaThreadMoreSignal.Action?

  init(route: TiebaRoute) {
    self.threadId = route.params["id"] ?? ""
    self.canDelete = route.params["canDelete"] == "1"
    self.seeLz = route.params["seeLz"] == "1"
    self.reverse = route.params["reverse"] == "1"
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
        "id": "sort",
        "kind": "link",
        "title": reverse ? "按正序浏览" : "按倒序浏览",
        "icon": "arrow.up.arrow.down",
        "iconTint": "#AF52DE",
      ],
      [
        "id": "jump",
        "kind": "link",
        "title": "跳转页码",
        "icon": "arrow.right.to.line",
        "iconTint": "#5856D6",
      ],
    ]
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
    if let action = TiebaThreadMoreSignal.Action(rawValue: id) {
      pendingAction = action
    }
    TiebaNavigator.shared.dismissPresented(animated: true)
  }
}
