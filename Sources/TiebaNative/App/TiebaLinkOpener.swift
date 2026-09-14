// ============================================================
// TiebaLinkOpener —— 链接打开（原 src/utils/linkOpener.ts 的 openLink 分支）
//
// 调用方：关于页的 5 个仓库按钮 / 吧规正文里的链接（openLink(url)）、
// Release 相关按钮（openLink(url, false) = openExternal）。
// 吧规链接会命中 tryTiebaInApp（贴吧站内链接直达）——这两个分支不是死代码。
//
// 行为对齐（逐条）：
//   - 贴吧站内链接（/p/<tid>、/f?kw=<吧名>）直接站内跳转，不开浏览器；
//     百度站外链接确认页 /mo/q/checkurl?url= 解包后直开真实目标；
//   - useBuiltInBrowser 偏好从原生 KV 现读（缺省 true，与 DEFAULT_PREFERENCES 一致）；
//   - 内置浏览器 = SFSafariViewController（TiebaInAppBrowser），controlsColor 用
//     应用内主题主色——JS 那边是 getThemeColors(...).primary，与导航壳收到的
//     themeTint 同源同值；
//   - 系统浏览器 = UIApplication.open(_:options:)（现代面）；打不开时弹 Alert（标题
//     「无法打开链接」，正文是 URL 本身）——与 JS 的 `Alert.alert('无法打开链接', url)` 同形；
//   - 内置浏览器 present 失败时回落系统浏览器（JS 的 catch → Linking.openURL）。
// ============================================================
import UIKit

@MainActor
enum TiebaLinkOpener {
  /// openLink(url)：站内直达 → 确认页解包 → 按「内置浏览器」偏好分流。
  static func open(_ urlString: String) {
    if openTiebaInApp(urlString) { return }
    if let target = checkURLRedirectTarget(urlString) {
      openInApp(target)
      return
    }
    if TiebaPreferenceSnapshot.bool("useBuiltInBrowser", default: true) {
      openInApp(urlString)
    } else {
      openExternal(urlString)
    }
  }

  /// 贴吧站内链接直达（原 tryTiebaInApp，2026-08-29 用户反馈）：帖子 /p/<tid> 与
  /// 吧 /f?kw=<吧名> 命中时 router.push 站内页；短链无法静态还原，维持原行为。
  private static func openTiebaInApp(_ raw: String) -> Bool {
    guard let components = URLComponents(string: raw),
      let host = components.host?.lowercased(),
      host == "tieba.baidu.com" || host == "www.tieba.baidu.com"
    else { return false }
    // /p/<tid>：其后可能还有路径与查询（?pn=2 等），取紧邻的数字段。
    if components.path.hasPrefix("/p/") {
      let threadId = components.path.dropFirst(3).prefix { $0.isNumber }
      if !threadId.isEmpty {
        return TiebaNavigator.shared.navigate(path: "/thread/\(threadId)", params: [:], mode: "push")
      }
    }
    // /f?kw=<吧名>
    if components.path == "/f",
      let kw = components.queryItems?.first(where: { $0.name == "kw" })?.value, !kw.isEmpty
    {
      let encoded = kw.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? kw
      return TiebaNavigator.shared.navigate(path: "/forum/\(encoded)", params: [:], mode: "push")
    }
    return false
  }

  /// 百度站外链接安全确认页（/mo/q/checkurl?url=…）：该确认页依赖贴吧环境，
  /// 在应用内 SafariVC 打不开（2026-09-01 用户实测）→ 解析 url 参数、校验目标
  /// host 后直接打开真实目标；目标是环回/私有/保留地址（或非 https）时返回 nil。
  private static func checkURLRedirectTarget(_ raw: String) -> String? {
    guard let components = URLComponents(string: raw),
      components.host?.lowercased() == "tieba.baidu.com",
      components.path == "/mo/q/checkurl",
      let rawTarget = components.queryItems?.first(where: { $0.name == "url" })?.value,
      let target = URLComponents(string: rawTarget),
      target.scheme == "https",
      let host = target.host?.lowercased(), !host.isEmpty,
      host != "localhost", !host.hasSuffix(".localhost"),
      !isIPv4Literal(host)
    else { return nil }
    return target.url?.absoluteString
  }

  /// IP 字面量一律拒绝（无法可靠区分环回/私有/保留，公开站点用域名）。
  private static func isIPv4Literal(_ host: String) -> Bool {
    let parts = host.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4 else { return false }
    return parts.allSatisfy { part in
      !part.isEmpty && part.count <= 3 && part.allSatisfy { $0.isNumber }
    }
  }

  /// openLink(url, false)：强制系统浏览器（Release 页面 / 弹窗里的「在浏览器中打开」）。
  /// 不预检 canOpenURL：SDK 已标记它废弃（UIApplication.h:98，"Prefer attempting to
  /// open URLs and handling any failures"），open 的 completion(false) 就是同一失败信号。
  static func openExternal(_ urlString: String) {
    guard let url = URL(string: urlString) else {
      showCannotOpen(urlString)
      return
    }
    UIApplication.shared.open(url, options: [:]) { success in
      guard !success else { return }
      Task { @MainActor in showCannotOpen(urlString) }
    }
  }

  /// 内置浏览器（SFSafariViewController）。参数逐条对齐 linkOpener 的 in-app 分支：
  /// dismissButtonStyle done / presentationStyle automatic / barCollapsing /
  /// 非 readerMode。
  static func openInApp(_ urlString: String) {
    let controlsColor = TiebaFormListView.hexString(from: TiebaNavigator.shared.chromeTheme.tint)
    Task { @MainActor in
      do {
        _ = try await TiebaInAppBrowser.open(
          urlString: urlString,
          controlsColor: controlsColor,
          dismissButtonStyle: .done,
          presentationStyle: .automatic,
          enableBarCollapsing: true,
          readerMode: false
        )
      } catch {
        // 旧 JS 的 catch 分支同样回落系统浏览器（再失败才提示）。
        openExternal(urlString)
      }
    }
  }

  private static func showCannotOpen(_ urlString: String) {
    guard let presenter = TiebaTopViewController.find() else { return }
    let alert = UIAlertController(title: "无法打开链接", message: urlString, preferredStyle: .alert)
    // Alert.alert(title, message) 不给按钮时，RN 补的是本地化的 "OK"
    //（RCTAlertManager.mm:96 的 RCTUIKitLocalizedString(@"OK")，中文环境显示「好」）。
    let okTitle = Bundle(for: UIApplication.self)
      .localizedString(forKey: "OK", value: nil, table: "Localizable")
    alert.addAction(UIAlertAction(title: okTitle, style: .default))
    presenter.present(alert, animated: true)
  }
}
