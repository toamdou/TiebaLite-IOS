// 粉丝 / 关注列表（原 src/components/user/SocialTabList.tsx）：分段切换 +
// 头像行 + 分页 + 下拉刷新。旧页是盖在用户主页上的自绘覆盖层，这里改为系统
// sheet（同一能力，手势返回与滚动链路交给系统）。
import UIKit

final class TiebaUserSocialViewController: UIViewController {
  private let uid: String
  private let list = TiebaKindListContentView()
  private let stateView = UIContentUnavailableView(configuration: .loading())
  private let segmented = UISegmentedControl(items: ["粉丝", "关注"])

  private var fans: Bool
  private var users: [TiebaProfileSocialUser] = []
  private var page = 1
  private var hasMore = false
  private var isLoading = false
  private var isLoadingMore = false
  private var loadSeq = 0
  /// 行页发布（页键守卫 + 整页后台测量都收敛在 driver）。
  private lazy var driver = TiebaRowPageDriver(list: list, keyPrefix: "social-\(uid)")

  init(uid: String, fans: Bool) {
    self.uid = uid
    self.fans = fans
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = TiebaNavigator.shared.chromeTheme.background
    navigationItem.titleView = segmented
    segmented.selectedSegmentIndex = fans ? 0 : 1
    segmented.addTarget(self, action: #selector(handleSegmentChange), for: .valueChanged)
    let close = UIBarButtonItem(
      image: UIImage(systemName: "xmark"),
      style: .plain,
      target: nil,
      action: nil
    )
    close.accessibilityLabel = "关闭"
    close.primaryAction = UIAction { [weak self] _ in self?.dismiss(animated: true) }
    navigationItem.leftBarButtonItem = close

    list.onListEvent = { [weak self] event in self?.handleEvent(event) }
    list.horizontalInset = 10
    list.separatorHeight = 8
    list.reachEndThreshold = 0.3
    for subview in [list, stateView] as [UIView] {
      subview.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(subview)
    }
    NSLayoutConstraint.activate([
      list.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      list.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      list.topAnchor.constraint(equalTo: view.topAnchor),
      list.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      stateView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      stateView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      stateView.topAnchor.constraint(equalTo: view.topAnchor),
      stateView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    reload(reset: true)
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    list.contentInsetBottom = view.safeAreaInsets.bottom + 24
    // 行宽契约 = 列表宽 − 2×horizontalInset（本表 10pt 内缩）。
    driver.updateWidth(list.bounds.width - list.horizontalInset * 2)
  }

  // MARK: - 数据

  private func reload(reset: Bool) {
    guard !isLoading else {
      list.endRefreshing()
      return
    }
    guard !uid.isEmpty else {
      list.endRefreshing()
      showState(.error("缺少用户 ID"))
      return
    }
    isLoading = true
    if reset { loadSeq += 1 }
    let seq = loadSeq
    let target = reset ? 1 : page + 1
    if reset, users.isEmpty { showState(.loading) }
    Task { @MainActor in
      defer {
        isLoading = false
        list.endRefreshing()
      }
      do {
        let result = try await TiebaProfileAPI.socialList(uid: uid, fans: fans, page: target)
        guard seq == loadSeq else { return }
        if reset {
          users = result.items
          page = 1
        } else {
          users.append(contentsOf: result.items)
          page = target
        }
        hasMore = result.hasMore
        stateView.isHidden = true
        list.isHidden = false
        // 分页同页键重推；刷新/切段才换页键。
        publish(fresh: reset)
      } catch {
        guard seq == loadSeq else { return }
        if users.isEmpty {
          showState(.error(error.localizedDescription))
        } else {
          // 失败也要复位页脚：加载更多的入口把页脚设成了 .loading，没人复位就会
          // 永远停在转圈上，"加载更多"再也回不来（用户 2026-09-15 报的那个观感）。
          list.footerState = hasMore ? .more : .none
        }
      }
    }
  }

  private func publish(fresh: Bool) {
    list.footerState = hasMore ? .more : .none
    driver.publish(fresh: fresh) { [weak self] in
      guard let self else { return [] }
      return users.isEmpty ? emptyRows() : users.map(row)
    }
  }

  private func emptyRows() -> [[String: Any]] {
    let icon = fans ? "person.crop.circle.badge.questionmark" : "person.crop.circle.badge.plus"
    let description = fans ? "还没有人关注 TA" : "TA 还没有关注任何人"
    let title = fans ? "暂无粉丝" : "暂无关注"
    return [
      TiebaEmptyPlaceholderRow.make(
        a11y: title,
        icon: icon,
        title: title,
        subtitle: description,
        marginH: 0,
        marginV: 0,
        colors: TiebaRowTheme.colors()
      )
    ]
  }

  private func row(_ user: TiebaProfileSocialUser) -> [String: Any] {
    var row: [String: Any] = [
      "kind": TiebaKindRowKind.simple.rawValue,
      "variant": "user",
      "a11y": user.displayName,
      "avatar": user.portrait,
      "avatarInitial": String(user.displayName.prefix(2)),
      "title": user.displayName,
      "subtitle": user.userName.isEmpty || user.userName == user.displayName
        ? "" : "@\(user.userName)",
      "chevron": true,
      "marginH": 0,
      "marginV": 0,
      "paddingH": 12,
      "paddingV": 12,
      "gap": 10,
      "radius": 20,
    ]
    row.merge(TiebaRowTheme.colors()) { _, new in new }
    return row
  }

  private enum State {
    case loading
    case error(String)
  }

  private func showState(_ state: State) {
    switch state {
    case .loading:
      stateView.configuration = UIContentUnavailableConfiguration.loading()
      stateView.isHidden = false
    case .error(let message):
      stateView.showError(message) { [weak self] in self?.reload(reset: true) }
    }
    list.isHidden = true
  }

  // MARK: - 事件

  private func handleEvent(_ event: TiebaKindListEvent) {
    switch event {
    case .rowTap(let index, _, _):
      guard users.indices.contains(index) else { return }
      openUser(users[index].uid)
    case .reachEnd, .footerTap:
      loadMore()
    case .refreshRequested:
      reload(reset: true)
    default:
      break
    }
  }

  private func loadMore() {
    guard hasMore, !isLoading, !isLoadingMore else { return }
    isLoadingMore = true
    list.footerState = .loading
    Task { @MainActor in
      reload(reset: false)
      isLoadingMore = false
    }
  }

  @objc private func handleSegmentChange() {
    TiebaSceneHaptics.fire("toggle")
    fans = segmented.selectedSegmentIndex == 0
    list.scrollToTop(animated: false)
    users = []
    publish(fresh: true)
    reload(reset: true)
  }

  /// 行点击：收起本 sheet 后在主导航栈里打开该用户主页（本 sheet 无路由壳）。
  private func openUser(_ uid: String) {
    guard !uid.isEmpty else { return }
    TiebaSceneHaptics.fire("press")
    dismiss(animated: true) {
      TiebaNavigator.shared.navigate(.user(uid: uid))
    }
  }
}
