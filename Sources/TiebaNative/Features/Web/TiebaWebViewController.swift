// ============================================================
// TiebaWebViewController —— 内置浏览器（原 src/app/webview.tsx）
//
// 整屏原生：工具栏（自绘行）+ WKWebView + 加载骨架。本类是页面本体
//（TiebaWebView 是给原生宿主复用的内嵌 WebView 视图）。
//
// 逐项对齐旧页面（行为是硬指标，勿"顺手优化"）：
//   · 路由参数：TiebaRoute.webview(url:title:) 的类型化值（原生解析，JS 侧不参与）。
//   · 可信域名：WEBVIEW_TRUSTED_HOSTS 整表下沉（tieba.baidu.com / tiebac /
//     static.tieba / tb1.bdstatic / passport / wappass / wapp），host 等于或为其
//     子域；只对**顶层导航**裁决，子资源一律放行（否则贴吧页面内嵌第三方资源
//     会被拦成残缺页）。
//   · 非可信 URL：立刻用系统内置浏览器（SFSafariViewController，overFullScreen）
//     打开，并 dismissTo('/')（原生等价 = selectTab(0)，先把栈收敛回根屏）。
//     ⚠️ 这一支**不发起 WebView 加载**：旧代码是先渲染再 useEffect 弹走，WebView
//     那一帧的加载是渲染顺序的副产物；WKWebView 一旦 load 就拉起 ~200MB 的
//     WebContent 进程（见 CookieService 注释），为一个正在被关掉的页面付这笔钱
//     没有道理（用户可见行为不变）。
//   · 加载态：工具栏标题「加载中…」+ 主色小转圈 + 屏幕顶部骨架（4 张卡片）+
//     底部 2pt 主色加载条；骨架为指针穿透（原 pointerEvents="none"）。
//   · 工具按钮：关闭 / 后退 / 前进 / 刷新 / 更多（分享链接、复制链接、在 Safari
//     中打开、取消）。后退不可用时不置灰（点它 = router.back() 兜底退出，仅视觉
//     0.3 透明）；前进不可用 = 真禁用（不触发触觉）；每个动作前 press 触觉。
//   · 内容进程崩溃：恢复加载态并 reload（避免黑屏 + 假 loading 结束）。
//   · Cookie：加载前把 Foundation 存储的会话 cookie 灌进 WK 存储，并把 WK 侧
//     变化写回 Foundation（原 sharedCookiesEnabled 的语义）；退出时摘观察者。
//   · JS 对话框（alert/confirm/prompt）：UIAlertController 实现，按钮文案
//     Ok / Cancel 与 react-native-webview 一致（通行证校验失败提示就是 alert）。
// ============================================================
import UIKit
import WebKit

final class TiebaWebViewController: UIViewController {
  // MARK: - 常量（原 src/constants/webViewHosts.ts 的 WEBVIEW_TRUSTED_HOSTS）
  private static let trustedHosts = [
    "tieba.baidu.com",
    "tiebac.baidu.com",
    "static.tieba.baidu.com",
    "tb1.bdstatic.com",
    "passport.baidu.com",
    "wappass.baidu.com",
    "wapp.baidu.com",
  ]
  /// 缺省/兜底地址（原 `initialUrl || 'https://tieba.baidu.com'`）
  private static let defaultURL = "https://tieba.baidu.com"

  // MARK: - 页面状态（原 useState）
  /// 初始地址（空串 = 走 defaultURL，见 viewDidAppear）。
  private let url: String
  private let webView: WKWebView
  private var isLoading = true
  private var canGoBack = false
  private var canGoForward = false
  private var currentURL = ""
  private var pageTitle = ""
  /// 外链只外开一次（原 externalOpenedRef）
  private var externalOpened = false
  /// 首次加载只做一次（viewDidAppear 会因 SafariVC 覆盖/关闭再触发）
  private var didPerformInitialNavigation = false
  private var didLoadOnce = false
  private var cookiesObserverInstalled = false

  // MARK: - 视图
  private let toolbar = UIView()
  private let toolbarRow = UIStackView()
  private let titleLabel = UILabel()
  private let spinner = UIActivityIndicatorView(style: .medium)
  private let closeButton = TiebaToolbarIconButton(symbol: "xmark", slot: 22, label: "关闭")
  private let backButton = TiebaToolbarIconButton(symbol: "chevron.left", slot: 22, label: "后退")
  private let forwardButton = TiebaToolbarIconButton(symbol: "chevron.right", slot: 22, label: "前进")
  private let refreshButton = TiebaToolbarIconButton(symbol: "arrow.clockwise", slot: 20, label: "刷新")
  private let moreButton = TiebaToolbarIconButton(symbol: "ellipsis", slot: 22, label: "更多")
  private let loadingBar = UIView()
  private let loadingOverlay = TiebaWebLoadingOverlayView()
  private var hairlineHeightConstraint: NSLayoutConstraint?

  init(url: String, title: String) {
    self.url = url
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .default()
    // 旧包 iOS 默认值（TiebaWebView 的同款配置）：不允许内联播放、媒体播放需要手势。
    configuration.allowsInlineMediaPlayback = false
    configuration.mediaTypesRequiringUserActionForPlayback = .all
    configuration.defaultWebpagePreferences.allowsContentJavaScript = true
    webView = WKWebView(frame: .zero, configuration: configuration)
    super.init(nibName: nil, bundle: nil)
    // 初始标题 = title（原 useState(title || '')，空串时界面显示「加载中…」）。
    pageTitle = title
    webView.allowsBackForwardNavigationGestures = true  // allowsBackForwardNavigationGestures
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  // MARK: - 生命周期

  override func viewDidLoad() {
    super.viewDidLoad()
    // 容器底色 = 主题 windowBackground（默认主题下 = systemBackground）。
    view.backgroundColor = .systemBackground
    webView.navigationDelegate = self
    webView.uiDelegate = self
    setUpToolbar()
    setUpWebView()
    setUpLoadingChrome()
    updateChrome()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard !didPerformInitialNavigation else { return }
    didPerformInitialNavigation = true
    let raw = url
    if !raw.isEmpty, !Self.isTrustedWebURL(raw) {
      // 原 useEffect：非可信 → 外开 + dismissTo('/')。见文件头的说明（不加载）。
      openInBrowser(raw)
      TiebaNavigator.shared.selectTab(0)
      return
    }
    load(Self.isTrustedWebURL(raw) ? raw : Self.defaultURL)
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    // SafariVC 覆盖再回来：观察者重新装上（load 时装过一次），加载态骨架恢复呼吸。
    if didLoadOnce { installCookieObserver() }
    loadingOverlay.setPulsing(isLoading)
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    // WKHTTPCookieStore 是进程级单例、强引用观察者，离屏必须摘（同 TiebaWebView）。
    removeCookieObserver()
    loadingOverlay.setPulsing(false)
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    // borderBottomWidth: StyleSheet.hairlineWidth（1 物理像素）。
    hairlineHeightConstraint?.constant = 1 / max(traitCollection.displayScale, 1)
  }

  // MARK: - 布局

  private func setUpToolbar() {
    // 主题 toolbar 色（默认主题：浅 #F2F2F7 / 深 #000000，与 systemGroupedBackground 逐值一致）。
    toolbar.backgroundColor = .systemGroupedBackground
    toolbar.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(toolbar)

    let hairline = UIView()
    hairline.backgroundColor = .separator  // colors.separator（默认主题逐值一致）
    hairline.translatesAutoresizingMaskIntoConstraints = false
    toolbar.addSubview(hairline)
    hairlineHeightConstraint = hairline.heightAnchor.constraint(equalToConstant: 0.5)

    toolbarRow.axis = .horizontal
    toolbarRow.alignment = .center
    toolbarRow.spacing = 4  // gap: Spacing.xs
    toolbarRow.translatesAutoresizingMaskIntoConstraints = false
    toolbar.addSubview(toolbarRow)

    // 标题区：转圈 + 标题，左右各 8（titleContainer paddingHorizontal: Spacing.sm）。
    let titleRow = UIStackView(arrangedSubviews: [spinner, titleLabel])
    titleRow.axis = .horizontal
    titleRow.alignment = .center
    titleRow.spacing = 6  // gap: 6
    titleRow.isLayoutMarginsRelativeArrangement = true
    titleRow.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8)
    titleRow.setContentHuggingPriority(.defaultLow, for: .horizontal)
    titleRow.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    titleLabel.font = .systemFont(ofSize: 16, weight: .medium)  // fontSize 16 / weight 500
    titleLabel.textColor = .label  // colors.text
    titleLabel.numberOfLines = 1
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
    titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    spinner.hidesWhenStopped = true
    spinner.setContentHuggingPriority(.required, for: .horizontal)
    spinner.setContentCompressionResistancePriority(.required, for: .horizontal)
    // loader: marginRight Spacing.xs=4 + gap 6 = 10
    titleRow.setCustomSpacing(10, after: spinner)

    closeButton.onTap = { [weak self] in self?.handleClose() }
    backButton.onTap = { [weak self] in self?.handleGoBack() }
    forwardButton.onTap = { [weak self] in self?.handleGoForward() }
    refreshButton.onTap = { [weak self] in self?.handleRefresh() }
    moreButton.onTap = { [weak self] in self?.presentMoreMenu() }
    // 顺序：关闭 / 后退 / 前进 / 刷新 / 标题（flex:1）/ 更多（原 toolbarRow 的声明序）。
    for button in [closeButton, backButton, forwardButton, refreshButton] {
      button.translatesAutoresizingMaskIntoConstraints = false
      toolbarRow.addArrangedSubview(button)
      NSLayoutConstraint.activate([
        button.widthAnchor.constraint(equalToConstant: 40),  // toolBtn 40x40
        button.heightAnchor.constraint(equalToConstant: 40),
      ])
    }
    toolbarRow.addArrangedSubview(titleRow)
    moreButton.translatesAutoresizingMaskIntoConstraints = false
    toolbarRow.addArrangedSubview(moreButton)
    NSLayoutConstraint.activate([
      moreButton.widthAnchor.constraint(equalToConstant: 40),
      moreButton.heightAnchor.constraint(equalToConstant: 40),
    ])

    NSLayoutConstraint.activate([
      toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      toolbar.topAnchor.constraint(equalTo: view.topAnchor),

      // toolbarRow: height 44, paddingHorizontal Spacing.sm=8, 顶部让出状态栏
      //（原 paddingTop: insets.top）。
      toolbarRow.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 8),
      toolbarRow.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -8),
      toolbarRow.topAnchor.constraint(equalTo: toolbar.safeAreaLayoutGuide.topAnchor),
      toolbarRow.heightAnchor.constraint(equalToConstant: 44),
      toolbar.bottomAnchor.constraint(equalTo: toolbarRow.bottomAnchor),

      // borderBottomWidth: StyleSheet.hairlineWidth（1 物理像素，画在栏内底部）。
      hairline.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
      hairline.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
      hairline.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor),
    ])
    hairlineHeightConstraint?.isActive = true
  }

  private func setUpWebView() {
    webView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(webView)
    NSLayoutConstraint.activate([
      webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      webView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
      webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
  }

  private func setUpLoadingChrome() {
    // 骨架覆盖整屏（原 loadingOverlay 是 absolute top0/left0/right0/bottom0，
    // 覆盖到工具栏之上），指针穿透。
    loadingOverlay.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(loadingOverlay)
    // 加载条：页面最底部 2pt 主色（原 loadingBar 在 WebView 之后、高度 2）。
    loadingBar.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(loadingBar)
    NSLayoutConstraint.activate([
      loadingOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      loadingOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      loadingOverlay.topAnchor.constraint(equalTo: view.topAnchor),
      loadingOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      loadingBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      loadingBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      loadingBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      loadingBar.heightAnchor.constraint(equalToConstant: 2),
    ])
  }

  // MARK: - 状态刷新

  private func updateChrome() {
    let theme = TiebaNavigator.shared.chromeTheme
    spinner.color = theme.tint  // colors.primary
    loadingBar.backgroundColor = theme.tint
    loadingOverlay.accentColor = theme.tint
    titleLabel.text = pageTitle.isEmpty ? "加载中…" : pageTitle
    spinner.isHidden = !isLoading
    if isLoading { spinner.startAnimating() } else { spinner.stopAnimating() }
    loadingOverlay.isHidden = !isLoading
    loadingBar.isHidden = !isLoading
    loadingOverlay.setPulsing(isLoading)
    // 后退不置灰（仅视觉 0.3）；前进真禁用（原 disabled={!canGoForward}）。
    backButton.alpha = canGoBack ? 1 : 0.3
    forwardButton.alpha = canGoForward ? 1 : 0.3
    forwardButton.isEnabled = canGoForward
  }

  /// 导航状态同步（原 onNavigationStateChange：canGoBack/canGoForward/currentUrl/title）。
  private func syncNavigationState() {
    canGoBack = webView.canGoBack
    canGoForward = webView.canGoForward
    currentURL = webView.url?.absoluteString ?? ""
    if let title = webView.title, !title.isEmpty { pageTitle = title }
  }

  // MARK: - 加载

  private func load(_ urlString: String) {
    guard let url = URL(string: urlString) else { return }
    didLoadOnce = true
    isLoading = true
    // 原 currentUrl 初值 = initialUrl：首个导航事件之前「分享/复制」也要有值。
    currentURL = urlString
    updateChrome()
    installCookieObserver()
    // 加载前把 Foundation 的会话 cookie 灌进 WK 存储（原 sharedCookiesEnabled 的
    // 行为 + ensureNativeWkCookies 的目的），全部落定再发起请求。
    Task { @MainActor [weak self] in
      guard let self else { return }
      await Self.syncSharedCookiesToWebKit(webView: self.webView)
      self.webView.load(URLRequest(url: url))
    }
  }

  private static func syncSharedCookiesToWebKit(webView: WKWebView) async {
    let store = webView.configuration.websiteDataStore.httpCookieStore
    for cookie in HTTPCookieStorage.shared.cookies ?? [] {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        store.setCookie(cookie) { continuation.resume() }
      }
    }
  }

  private func installCookieObserver() {
    guard !cookiesObserverInstalled else { return }
    cookiesObserverInstalled = true
    webView.configuration.websiteDataStore.httpCookieStore.add(self)
  }

  private func removeCookieObserver() {
    guard cookiesObserverInstalled else { return }
    cookiesObserverInstalled = false
    webView.configuration.websiteDataStore.httpCookieStore.remove(self)
  }

  // MARK: - 动作（触觉调用点与原页面一致）

  private func handleGoBack() {
    TiebaSceneHaptics.fire("press")
    if webView.canGoBack {
      webView.goBack()
    } else {
      // 无历史 → router.back() 兜底（栈底无动作）。
      _ = TiebaNavigator.shared.goBack()
    }
  }

  private func handleGoForward() {
    TiebaSceneHaptics.fire("press")
    webView.goForward()
  }

  private func handleRefresh() {
    TiebaSceneHaptics.fire("press")
    webView.reload()
  }

  private func handleClose() {
    TiebaSceneHaptics.fire("press")
    // router.dismissTo('/')：'/' 解析成 index（tab 0），原生等价 = selectTab(0)
    //（它先把栈收敛回根屏，本页随即被 pop）。
    TiebaNavigator.shared.selectTab(0)
  }

  /// 「…」菜单：分享链接 / 复制链接 / 在 Safari 中打开 / 取消
  ///（原 ActionSheetIOS，注释明写就是 UIKit 的 UIAlertController.actionSheet）。
  private func presentMoreMenu() {
    let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
    sheet.addAction(UIAlertAction(title: "分享链接", style: .default) { [weak self] _ in
      self?.shareLink()
    })
    sheet.addAction(UIAlertAction(title: "复制链接", style: .default) { [weak self] _ in
      self?.copyLink()
    })
    sheet.addAction(UIAlertAction(title: "在 Safari 中打开", style: .default) { [weak self] _ in
      guard let self else { return }
      self.openInBrowser(self.currentURL)
    })
    sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
    if let popover = sheet.popoverPresentationController {
      popover.sourceView = moreButton
      popover.sourceRect = moreButton.bounds
    }
    present(sheet, animated: true)
  }

  /// 分享链接。原 `Share.share({message: currentUrl, title: pageTitle})`：iOS 侧
  /// RN 只把 message 放进 activityItems（title 在 iOS 被忽略，见 Share.js +
  /// RCTActionSheetManager），且 presenter 取"当前最顶的 presented VC"、失败静默。
  private func shareLink() {
    let controller = UIActivityViewController(activityItems: [currentURL], applicationActivities: nil)
    if let popover = controller.popoverPresentationController {
      popover.sourceView = moreButton
      popover.sourceRect = moreButton.bounds
    }
    // 等菜单退场一拍（RN 同样是 dispatch_async 到主队列后再 present）。
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      (TiebaTopViewController.find() ?? self).present(controller, animated: true)
    }
  }

  private func copyLink() {
    TiebaClipboard.setString(currentURL)
  }

  /// 外开（SafariVC，原 WebBrowser.openBrowserAsync 的缺省选项：overFullScreen /
  /// done / 不折叠栏 / 非 readerMode），失败静默（原实现 .catch(() => {})）。
  private func openInBrowser(_ urlString: String) {
    guard !urlString.isEmpty else { return }
    Task { @MainActor in
      _ = try? await TiebaInAppBrowser.open(
        urlString: urlString,
        controlsColor: nil,
        dismissButtonStyle: .done,
        presentationStyle: .overFullScreen,
        enableBarCollapsing: false,
        readerMode: false
      )
    }
  }

  /// 非可信导航外开（原 openExternal：一次页面生命周期内只开一次）。
  private func openExternal(_ urlString: String) {
    guard !externalOpened else { return }
    externalOpened = true
    openInBrowser(urlString)
  }

  // MARK: - 可信域名

  /// 与 JS isTrustedHost(url, WEBVIEW_TRUSTED_HOSTS) 同义：hostname 等于宿或为其子域。
  static func isTrustedWebURL(_ rawURL: String) -> Bool {
    guard let components = URLComponents(string: rawURL), let host = components.host?.lowercased(),
      !host.isEmpty
    else { return false }
    return trustedHosts.contains { host == $0 || host.hasSuffix(".\($0)") }
  }
}

// MARK: - WKNavigationDelegate

extension TiebaWebViewController: WKNavigationDelegate {
  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
  ) {
    let request = navigationAction.request
    // isTopFrame 判据与旧包一致：请求 URL == 主文档 URL = 顶层导航。
    let isTopFrame = request.url == request.mainDocumentURL
    guard isTopFrame else {
      // 子资源（图片/脚本/XHR/iframe）一律放行。
      decisionHandler(.allow)
      return
    }
    let urlString = request.url?.absoluteString ?? ""
    guard Self.isTrustedWebURL(urlString) else {
      // 外部链接交给系统浏览器，禁止在应用 WebView 内继续加载。
      openExternal(urlString)
      decisionHandler(.cancel)
      return
    }
    decisionHandler(.allow)
  }

  func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
    // 原 onLoadStart：loading=true + 导航状态同步（onNavigationStateChange）。
    isLoading = true
    syncNavigationState()
    updateChrome()
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    isLoading = false
    syncNavigationState()
    updateChrome()
  }

  func webView(
    _ webView: WKWebView,
    didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    let nsError = error as NSError
    // NSURLErrorCancelled：重定向/新加载打断旧加载，不是真错误。
    if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }
    // WebKitErrorDomain 101/102：http 重定向/框架打断（旧包同过滤）。
    if nsError.domain == "WebKitErrorDomain", nsError.code == 102 || nsError.code == 101 { return }
    // 原 onLoadEnd 在 loadingError 路径同样触发 → loading 收尾（不看 title/nav）。
    isLoading = false
    updateChrome()
  }

  /// 已提交导航中途失败（didFailProvisionalNavigation 之外的那半）：原 onLoadEnd
  /// 在 loadingError 路径同样触发，不收尾就会留一个永远转的加载条。
  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    isLoading = false
    updateChrome()
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    // 渲染进程崩溃：恢复加载态并 reload（避免黑屏 + 假 loading 结束）。
    isLoading = true
    updateChrome()
    webView.reload()
  }
}

// MARK: - WKUIDelegate（JS 对话框，按钮文案与 react-native-webview 一致）

extension TiebaWebViewController: WKUIDelegate {
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
      alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
        completionHandler(nil)
      })
    }
  }

  private func presentJavaScriptPanel(message: String, actions: @escaping (UIAlertController) -> Void) {
    let alert = UIAlertController(title: "", message: message, preferredStyle: .alert)
    actions(alert)
    (TiebaTopViewController.find() ?? self).present(alert, animated: true)
  }
}

// MARK: - WKHTTPCookieStoreObserver

extension TiebaWebViewController: WKHTTPCookieStoreObserver {
  func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
    // WK 侧 cookie 变化 → 写回 Foundation 存储（旧包 cookiesDidChangeInCookieStore 同款）。
    cookieStore.getAllCookies { cookies in
      for cookie in cookies {
        HTTPCookieStorage.shared.setCookie(cookie)
      }
    }
  }
}

// MARK: - 工具栏图标按钮

/// 工具栏图标按钮（原 HdrPressable + SymbolView）。
///
/// 图槽与旧渲染逐项一致：SymbolView 的 size 只决定容器边长，图像本身恒为
/// UIFont.systemFontSize（17pt），靠 scaleToFill 铺满图槽（见 TiebaSymbolView 头注释），
/// 所以这里也用 imageView.frame = 图槽 + scaleToFill，而不是按 pointSize 缩放。
/// 按压无视觉反馈：旧页面的 HdrPressable 走的是默认 effect="subtle"（零视觉变化）。
final class TiebaToolbarIconButton: UIControl {
  var onTap: (() -> Void)?

  private let imageView = UIImageView()

  init(symbol: String, slot: CGFloat, label: String) {
    super.init(frame: .zero)
    accessibilityLabel = label
    accessibilityTraits = .button
    imageView.contentMode = .scaleToFill
    imageView.image = UIImage(
      systemName: symbol,
      withConfiguration: UIImage.SymbolConfiguration(pointSize: UIFont.systemFontSize)
    )
    imageView.tintColor = .label  // colors.text
    imageView.translatesAutoresizingMaskIntoConstraints = false
    imageView.isUserInteractionEnabled = false
    addSubview(imageView)
    NSLayoutConstraint.activate([
      imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
      imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
      imageView.widthAnchor.constraint(equalToConstant: slot),
      imageView.heightAnchor.constraint(equalToConstant: slot),
    ])
    addTarget(self, action: #selector(handleTap), for: .touchUpInside)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  @objc private func handleTap() { onTap?() }
}

// MARK: - 加载骨架

/// 加载骨架（原 webview.tsx SkeletonList variant="card" count={4} + 底部
/// 「正在加载页面…」提示）：卡片几何/呼吸动画/占位色全部由 TiebaSkeletonList
/// 提供（Skeleton.tsx 原生重建，勿在此另画一套）。
final class TiebaWebLoadingOverlayView: UIView {
  private let skeletonList = TiebaSkeletonList(variant: .card, count: 4)
  private let hintSpinner = UIActivityIndicatorView(style: .medium)

  /// 提示行转圈的颜色（原 ActivityIndicator color={colors.primary}）。
  var accentColor: UIColor? {
    didSet { hintSpinner.color = accentColor }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false  // pointerEvents="none"
    backgroundColor = .clear
    skeletonList.contentInsets = UIEdgeInsets(top: 16, left: 16, bottom: 0, right: 16)
    addSubview(skeletonList)

    hintSpinner.startAnimating()
    let hintLabel = UILabel()
    hintLabel.text = "正在加载页面…"
    hintLabel.font = .preferredFont(forTextStyle: .footnote)
    hintLabel.textColor = .secondaryLabel  // colors.textSecondary
    let hintRow = UIStackView(arrangedSubviews: [hintSpinner, hintLabel])
    hintRow.axis = .horizontal
    hintRow.alignment = .center
    hintRow.spacing = 8  // loadingHint gap: Spacing.sm
    hintRow.isLayoutMarginsRelativeArrangement = true
    hintRow.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 16, leading: 0, bottom: 16, trailing: 0)
    hintRow.translatesAutoresizingMaskIntoConstraints = false
    addSubview(hintRow)

    NSLayoutConstraint.activate([
      skeletonList.leadingAnchor.constraint(equalTo: leadingAnchor),
      skeletonList.trailingAnchor.constraint(equalTo: trailingAnchor),
      skeletonList.topAnchor.constraint(equalTo: topAnchor),
      hintRow.centerXAnchor.constraint(equalTo: centerXAnchor),
      hintRow.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// 呼吸开关（只在加载态跑；停止时清掉动画并复位）。重复置同值时短路，
  /// 避免每次导航状态刷新都重启一次呼吸。
  func setPulsing(_ on: Bool) {
    skeletonList.isSuspended = !on
  }
}
