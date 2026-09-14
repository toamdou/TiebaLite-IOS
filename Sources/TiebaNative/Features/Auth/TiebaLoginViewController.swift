// 登录页（原 src/app/login.tsx）：WKWebView 走百度通行证 → 跳回贴吧时从
// Cookie 双存储取 BDUSS/STOKEN → /c/s/login 换账号信息 → TiebaSession.activate。
// 遮罩/错误面/帮助/关闭与触觉逐项对齐旧页；信任域名见 TiebaWebViewController
// 的同一套 + 登录额外的 tb.himg.baidu.com。
import UIKit
import WebKit

final class TiebaLoginViewController: UIViewController, TiebaNativeScreen {
  private static let loginURL: URL = {
    // 字面量 URL 构造不了就是代码写错了：precondition 大声失败，不做静默降级。
    guard let url = URL(
      string: "https://wappass.baidu.com/passport?login&u=https%3A%2F%2Ftieba.baidu.com%2Findex%2Ftbwise%2Fmine"
    ) else {
      preconditionFailure("登录 URL 字面量非法")
    }
    return url
  }()
  private static let trustedHosts = [
    "tieba.baidu.com",
    "tiebac.baidu.com",
    "static.tieba.baidu.com",
    "tb1.bdstatic.com",
    "passport.baidu.com",
    "wappass.baidu.com",
    "wapp.baidu.com",
    "tb.himg.baidu.com",
  ]
  private static let timeoutSeconds: TimeInterval = 60

  private enum Phase: Equatable {
    case loading
    case extracting
    case success
    case error(String)
    case idle
  }

  var screenTitle: String? { "登录百度账号" }
  var screenLeftBarItems: [UIBarButtonItem]? { [closeItem] }
  var screenRightBarItems: [UIBarButtonItem]? { [helpItem] }

  private lazy var closeItem: UIBarButtonItem = {
    let item = UIBarButtonItem(image: UIImage(systemName: "xmark"), style: .plain, target: nil, action: nil)
    item.accessibilityLabel = "关闭登录"
    item.primaryAction = UIAction { [weak self] _ in self?.handleClose() }
    return item
  }()
  private lazy var helpItem: UIBarButtonItem = {
    let item = UIBarButtonItem(
      image: UIImage(systemName: "questionmark.circle"),
      style: .plain,
      target: nil,
      action: nil
    )
    item.accessibilityLabel = "登录帮助"
    item.primaryAction = UIAction { [weak self] _ in self?.handleHelp() }
    return item
  }()

  private let webView: WKWebView
  private let overlay = TiebaStateContentView()
  private let noticeDivider = UIView()
  private let noticeRow = UIStackView()
  private let noticeLabel = UILabel()

  private var phase: Phase = .loading {
    didSet {
      guard phase != oldValue else { return }
      applyPhase()
    }
  }
  private var loginProcessed = false
  private var didPerformInitialLoad = false
  private var timeoutTask: Task<Void, Never>?

  init() {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .default()
    configuration.allowsInlineMediaPlayback = false
    configuration.mediaTypesRequiringUserActionForPlayback = .all
    configuration.defaultWebpagePreferences.allowsContentJavaScript = true
    webView = WKWebView(frame: .zero, configuration: configuration)
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  // MARK: - 生命周期

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    webView.navigationDelegate = self
    webView.uiDelegate = self
    // 旧页显式 UA（非默认 WKWebView 串）。
    webView.customUserAgent =
      "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1"

    webView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(webView)
    overlay.translatesAutoresizingMaskIntoConstraints = false
    overlay.isDark = TiebaNavigator.shared.chromeTheme.dark
    overlay.onButtonPress = { [weak self] id in
      if id == "retry" { self?.handleRetry() } else if id == "close" { self?.handleClose() }
    }
    view.addSubview(overlay)
    buildNotice()
    NSLayoutConstraint.activate([
      webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      webView.topAnchor.constraint(equalTo: view.topAnchor),
      webView.bottomAnchor.constraint(equalTo: noticeDivider.topAnchor),
      overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      overlay.topAnchor.constraint(equalTo: view.topAnchor),
      overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      noticeRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
      noticeRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
      noticeRow.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
    ])
    applyPhase()
    startTimeout()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard !didPerformInitialLoad else { return }
    didPerformInitialLoad = true
    Task { @MainActor in
      await Self.syncSharedCookiesToWebKit(webView: webView)
      webView.load(URLRequest(url: Self.loginURL))
    }
  }

  // MARK: - 底部安全说明

  private func buildNotice() {
    noticeDivider.backgroundColor = .separator
    noticeDivider.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(noticeDivider)
    let icon = UIImageView(image: UIImage(systemName: "lock.shield.fill"))
    icon.tintColor = .secondaryLabel
    icon.contentMode = .scaleAspectFit
    icon.translatesAutoresizingMaskIntoConstraints = false
    noticeLabel.text = "登录凭据仅保存在本机安全存储（Keychain）与 Cookie 存储中，仅用于请求百度接口。"
    noticeLabel.font = UIFont.preferredFont(forTextStyle: .caption1)
    noticeLabel.textColor = .secondaryLabel
    noticeLabel.numberOfLines = 0
    noticeRow.axis = .horizontal
    noticeRow.alignment = .center
    noticeRow.spacing = 8
    noticeRow.addArrangedSubview(icon)
    noticeRow.addArrangedSubview(noticeLabel)
    noticeRow.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(noticeRow)
    NSLayoutConstraint.activate([
      noticeDivider.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      noticeDivider.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      noticeDivider.bottomAnchor.constraint(equalTo: noticeRow.topAnchor, constant: -12),
      // 1px 分隔线：displayScale 取本 VC 的 trait（UIScreen.main 自 iOS 26 废弃）。
      noticeDivider.heightAnchor.constraint(equalToConstant: 1 / max(traitCollection.displayScale, 1)),
      icon.widthAnchor.constraint(equalToConstant: 14),
      icon.heightAnchor.constraint(equalToConstant: 14),
    ])
  }

  // MARK: - 状态遮罩

  private func applyPhase() {
    // 离开「等待登录」（loading/idle）即停表：失败/成功/提取中都不该再被超时覆盖。
    if phase != .loading && phase != .idle { timeoutTask?.cancel() }
    let tint = TiebaNavigator.shared.chromeTheme.tint
    overlay.spinnerColor = tint
    overlay.showsSpinner = false
    overlay.imageName = nil
    overlay.imageSize = nil
    overlay.imageColor = nil
    overlay.text = nil
    overlay.secondaryText = nil
    overlay.secondaryStyle = "subheadline"
    overlay.buttons = []
    overlay.backgroundColor = .clear

    switch phase {
    case .loading:
      overlay.showsSpinner = true
      overlay.secondaryText = "正在加载登录页面..."
    case .extracting:
      overlay.showsSpinner = true
      overlay.secondaryText = "正在获取用户信息..."
    case .success:
      overlay.imageName = "checkmark.circle.fill"
      overlay.imageColor = .systemGreen
      overlay.imageSize = 56
      overlay.text = "登录成功"
      overlay.textStyle = "title3"
      overlay.textWeight = "semibold"
    case .error(let message):
      overlay.imageName = "exclamationmark.triangle"
      overlay.text = "登录失败"
      overlay.textStyle = "headline"
      overlay.secondaryText = message
      overlay.buttons = [
        TiebaStateButton(raw: [
          "id": "retry", "title": "重新加载", "icon": "arrow.clockwise",
          "style": "borderedProminent", "color": TiebaFormListView.hexString(from: tint),
          "large": true, "fullWidth": true,
        ]),
        TiebaStateButton(raw: ["id": "close", "title": "返回", "style": "bordered", "large": true, "fullWidth": true]),
      ]
      overlay.backgroundColor = .systemBackground
    case .idle:
      break
    }
    let hidesWebView = phase == .loading || phase == .extracting || phase == .success
    webView.alpha = hidesWebView ? 0 : 1
    overlay.isHidden = phase == .idle
  }

  // MARK: - 超时

  private func startTimeout() {
    timeoutTask?.cancel()
    timeoutTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(Self.timeoutSeconds * 1_000_000_000))
      guard !Task.isCancelled, let self, !self.loginProcessed else { return }
      self.phase = .error("登录超时，请在页面中完成百度账号登录后重试")
      TiebaSceneHaptics.fire("action-fail")
    }
  }

  // MARK: - 登录检测

  private func isLoginRedirect(_ url: String) -> Bool {
    url.hasPrefix("https://tieba.baidu.com/index/tbwise/")
      || url.hasPrefix("https://tiebac.baidu.com/index/tbwise/")
  }

  private func handleNavigation(_ rawURL: String) {
    let url = rawURL
    if !loginProcessed, isLoginRedirect(url) {
      loginProcessed = true
      timeoutTask?.cancel()
      phase = .extracting
      TiebaSceneHaptics.fire("press")
      Task { @MainActor in await processLogin() }
    } else if phase == .loading, url.contains("passport.baidu.com") {
      phase = .idle
      startTimeout()
    }
  }

  /// 轮询等待 BDUSS+STOKEN 齐备（两者异步下发，缺一即半成品）。
  private func processLogin() async {
    var cookies = await Self.nativeCookies()
    var tries = 0
    while tries < 40, cookies["BDUSS"] == nil || cookies["STOKEN"] == nil {
      try? await Task.sleep(nanoseconds: 150_000_000)
      cookies = await Self.nativeCookies()
      tries += 1
    }
    let bduss = cookies["BDUSS"] ?? ""
    let stoken = cookies["STOKEN"] ?? ""
    guard !bduss.isEmpty else {
      fail("无法读取登录凭据（BDUSS）。\n\n请在开发构建中登录，或确认系统 Cookie 已写入。")
      return
    }
    guard !stoken.isEmpty else {
      fail("登录凭据不完整（已取得 BDUSS，STOKEN 未下发）。\n\n请重新登录一次；若仍复现，把 [login] 开头的日志发给开发者。")
      return
    }
    guard !Task.isCancelled else { return }
    do {
      var account = try await TiebaSession.fetchLoginAccount(bduss: bduss)
      account.sToken = stoken
      account.cookie = cookies.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
      account.zid = cookies["BAIDUZID"] ?? cookies["ZID"] ?? cookies["BAIDUID"] ?? ""
      let activated = try await TiebaSession.activate(account)
      TiebaSceneHaptics.fire("action-success")
      phase = .success
      // 登录后补一次资料（nameShow/头像），失败不阻断。
      Task { await TiebaSession.refreshProfile(uid: activated.uid) }
      Task { @MainActor [weak self] in
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        self?.handleClose()
      }
    } catch {
      fail("登录信息提取失败：\(error.localizedDescription)")
    }
  }

  private func fail(_ message: String) {
    phase = .error(message)
    TiebaSceneHaptics.fire("action-fail")
    loginProcessed = false
  }

  /// Foundation + WK 两存储合并（同名时 WK 覆盖，与 JS getNativeCookies 一致）。
  private static func nativeCookies() async -> [String: String] {
    var merged: [String: String] = [:]
    for webKit in [false, true] {
      let raw = await TiebaCookieStore.get(urlString: "https://tieba.baidu.com", webKit: webKit)
      for (name, value) in raw { merged[name.uppercased()] = value }
    }
    return merged
  }

  private static func syncSharedCookiesToWebKit(webView: WKWebView) async {
    let store = webView.configuration.websiteDataStore.httpCookieStore
    for cookie in HTTPCookieStorage.shared.cookies ?? [] {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        store.setCookie(cookie) { continuation.resume() }
      }
    }
  }

  // MARK: - 动作

  private func handleRetry() {
    loginProcessed = false
    phase = .loading
    startTimeout()
    webView.reload()
  }

  private func handleClose() {
    // router.back()：登录页是上推表单，dismiss 即回原页面；栈底兜底切「我的」。
    if !TiebaNavigator.shared.goBack() {
      TiebaNavigator.shared.selectTab(3)
    }
  }

  private func handleHelp() {
    let alert = UIAlertController(
      title: "登录帮助",
      message: "1. 在页面中输入你的百度账号和密码\n"
        + "2. 如需验证，请按页面提示完成\n"
        + "3. 登录成功后会自动跳转至贴吧\n"
        + "4. 应用将自动获取用户信息\n\n"
        + "如自动获取失败，可能是百度安全策略所致。\n"
        + "建议重新尝试或检查网络连接。",
      preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(title: "知道了", style: .cancel))
    present(alert, animated: true)
  }

  static func isTrustedLoginURL(_ rawURL: String) -> Bool {
    guard let host = URLComponents(string: rawURL)?.host?.lowercased(), !host.isEmpty else {
      return false
    }
    return trustedHosts.contains { host == $0 || host.hasSuffix(".\($0)") }
  }
}

// MARK: - WKNavigationDelegate

extension TiebaLoginViewController: WKNavigationDelegate {
  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
  ) {
    let request = navigationAction.request
    guard request.url == request.mainDocumentURL else {
      decisionHandler(.allow)  // 子资源一律放行
      return
    }
    let url = request.url?.absoluteString ?? ""
    // 旧页 onShouldStartLoadWithRequest=false：不可信顶层导航直接拦下（不外开）。
    guard Self.isTrustedLoginURL(url) else {
      decisionHandler(.cancel)
      return
    }
    if let targetFrame = navigationAction.targetFrame, !targetFrame.isMainFrame {
      decisionHandler(.allow)
      return
    }
    decisionHandler(.allow)
    handleNavigation(url)
  }

  func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
    handleNavigation(webView.url?.absoluteString ?? "")
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    handleNavigation(webView.url?.absoluteString ?? "")
    if phase == .loading { phase = .idle }
  }

  func webView(
    _ webView: WKWebView,
    didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    let nsError = error as NSError
    if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }
    if nsError.domain == "WebKitErrorDomain", nsError.code == 101 || nsError.code == 102 { return }
    guard !loginProcessed else { return }
    phase = .error("页面加载失败，请检查网络连接后重试")
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    guard !loginProcessed else { return }
    phase = .error("页面加载失败，请检查网络连接后重试")
  }
}

// MARK: - WKUIDelegate（通行证页的 alert/confirm/prompt；文案与旧包一致）

extension TiebaLoginViewController: WKUIDelegate {
  func webView(
    _ webView: WKWebView,
    runJavaScriptAlertPanelWithMessage message: String,
    initiatedByFrame frame: WKFrameInfo,
    completionHandler: @escaping @MainActor () -> Void
  ) {
    presentJavaScriptPanel(message: message) { alert in
      alert.addAction(UIAlertAction(title: "Ok", style: .default) { _ in completionHandler() })
    }
  }

  func webView(
    _ webView: WKWebView,
    runJavaScriptConfirmPanelWithMessage message: String,
    initiatedByFrame frame: WKFrameInfo,
    completionHandler: @escaping @MainActor (Bool) -> Void
  ) {
    presentJavaScriptPanel(message: message) { alert in
      alert.addAction(UIAlertAction(title: "Ok", style: .default) { _ in completionHandler(true) })
      alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
    }
  }

  func webView(
    _ webView: WKWebView,
    runJavaScriptTextInputPanelWithPrompt prompt: String,
    defaultText: String?,
    initiatedByFrame frame: WKFrameInfo,
    completionHandler: @escaping @MainActor (String?) -> Void
  ) {
    presentJavaScriptPanel(message: prompt) { alert in
      alert.addTextField { textField in textField.text = defaultText }
      alert.addAction(UIAlertAction(title: "Ok", style: .default) { _ in
        completionHandler(alert.textFields?.last?.text)
      })
      alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
    }
  }

  private func presentJavaScriptPanel(message: String, actions: @escaping (UIAlertController) -> Void) {
    let alert = UIAlertController(title: "", message: message, preferredStyle: .alert)
    actions(alert)
    (TiebaTopViewController.find() ?? self).present(alert, animated: true)
  }
}
