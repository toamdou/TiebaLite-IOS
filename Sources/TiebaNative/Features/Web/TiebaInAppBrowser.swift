// 应用内浏览器（SFSafariViewController）——替代 expo-web-browser 的
// openBrowserAsync。
//
// 为什么是 SFSafariViewController 而不是 ASWebAuthenticationSession：
// 全仓调用点（linkOpener.openLink / webview.tsx 的三处"在浏览器打开"）都是
// "把 http(s) 页面给用户看"，没有一处需要 redirect/callback——没有 OAuth 流程，
// 没有 callbackURLScheme，也没有 JS 侧 await 返回值做分支。旧包 openAuthSessionAsync
// 在 src/ 里零调用，故本文件不建第二条会话路径（ASWebAuthenticationSession 的
// 全部价值就是回调 URL，凭空实现等于造死代码）。
//
// 与旧包对齐的行为（expo-web-browser iOS WebBrowserSession 逐一核对）：
//   - 从顶层 VC present（presented 链 → 导航栈顶）；
//   - iPad 给 popover 锚点（缺了在 popover 呈现模式下会崩）；
//   - 已在开时返回 "locked" 而不是叠加第二层（旧包 currentWebBrowserSession 同语义）；
//   - promise 在"浏览器关闭后"才 resolve（Done 钮 / 下滑关闭 / 程序化 dismiss），
//     类型串与旧包一致：cancel / dismiss / locked。调用方（linkOpener）await 到
//     关闭为止，这条时序不能变。
//   - 缺省 modalPresentationStyle = .overFullScreen（旧包 WebBrowserOptions 的
//     Record 默认值就是它；linkOpener 显式传 automatic 覆盖）。
//
// 与旧包的唯一取舍：toolbarColor（preferredBarTintColor）不再转发——iOS 26 起
// 该 API 已废弃（系统材质优先），且全仓无调用方；controlsColor
//（preferredControlTintColor）保留，linkOpener 用它跟随应用内主题主色。
import SafariServices
import UIKit

/// 跨桥抛错用的最小错误类型（与 TiebaCookieError 同形）。
struct TiebaBrowserError: LocalizedError {
  let message: String

  var errorDescription: String? { message }
}

@MainActor
enum TiebaInAppBrowser {
  /// 工具栏关闭按钮样式（旧包 DismissButtonStyle 三值）。字符串换成枚举后
  /// 非法值在类型层就不存在——原实现对未知串静默回落 .done。
  enum DismissButtonStyle {
    case done
    case close
    case cancel
  }

  /// 呈现样式（旧包 PresentationStyle 的 iOS 子集）。原实现对未知串回落
  /// overFullScreen；现在 overFullScreen 是显式取值，映射表不再有兜底分支。
  enum PresentationStyle {
    case automatic
    case fullScreen
    case pageSheet
    case formSheet
    case currentContext
    case overCurrentContext
    case overFullScreen
    case popover
    case none
  }

  /// 在途会话（同一时刻至多一个；旧包 currentWebBrowserSession 同语义）。
  private static var session: Session?

  /// 打开内置浏览器，返回关闭类型（cancel / dismiss / locked）。
  /// 参数与旧包 WebBrowserOptions 的 iOS 子集一一对应。
  /// - Parameter controlsColor: '#RRGGBB'（调用点传的是主题主色，该字段由
  ///   normalizeHex/主题表保证恒为 hex 形态）。收字符串而不是 UIColor：这条
  ///   边界只在 present 时解析一次 hex（TiebaFormColor.hex），非法/空串即 nil。
  static func open(
    urlString: String,
    controlsColor: String?,
    dismissButtonStyle: DismissButtonStyle,
    presentationStyle: PresentationStyle,
    enableBarCollapsing: Bool,
    readerMode: Bool
  ) async throws -> String {
    // 旧包只放行 http/https（isValid），非法 URL 抛 WebBrowserInvalidURLException。
    guard let url = URL(string: urlString),
      let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https"
    else {
      throw TiebaBrowserError(message: "内置浏览器只支持 http/https URL：\(urlString)")
    }
    // 已在开：旧包 resolve(["type": "locked"])，不叠加第二层（叠加会被 UIKit 拒绝）。
    guard session == nil else { return "locked" }
    guard let presenter = TiebaTopViewController.find() else {
      throw TiebaBrowserError(message: "没有可用的宿主视图控制器")
    }

    let configuration = SFSafariViewController.Configuration()
    configuration.barCollapsingEnabled = enableBarCollapsing
    configuration.entersReaderIfAvailable = readerMode
    let safari = SFSafariViewController(url: url, configuration: configuration)
    safari.modalPresentationStyle = modalStyle(presentationStyle)
    safari.dismissButtonStyle = dismissStyle(dismissButtonStyle)
    // 空串/非法串 → nil = 系统默认 tint（主色恒为 hex，正常路径不会走到这里）。
    safari.preferredControlTintColor = controlsColor.flatMap { hex in
      TiebaFormColor.hex(hex)
    }

    return await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
      let active = Session(continuation: continuation)
      session = active
      safari.delegate = active
      if UIDevice.current.userInterfaceIdiom == .pad {
        // iPad：popover 呈现模式（presentationStyle=popover，或系统自适应选中 popover）
        // 缺少 sourceView/sourceRect 会直接崩 present（旧包同样处理）。
        safari.popoverPresentationController?.sourceView = presenter.view
        safari.popoverPresentationController?.sourceRect = CGRect(
          x: presenter.view?.bounds.midX ?? 0,
          y: presenter.view?.bounds.maxY ?? 0,
          width: 0,
          height: 0
        )
      }
      presenter.present(safari, animated: true) {
        // 宿主正在转场/被别的 present 抢占时 UIKit 会丢弃本次展示（completion
        // 仍会调用且无关闭回调）→ session 永不复位、之后打开恒 "locked"。
        // 先校验 present 链（TiebaPhotoBrowser.swift:457 同款兜底）。
        active.finishIfPresentationDropped(safari)
        // presented 之后才挂自适应代理：presentationController 在呈现前拿不到
        //（旧包在 present 前设置，实际收不到"下滑关闭"回调——本实现补上，
        // 否则下滑关闭时 promise 永挂、session 永不清）。
        safari.presentationController?.delegate = active
      }
    }
  }

  /// 用户从外部手段关闭时的收口对象。delegate 的 @MainActor 隔离写在 conformance 上
  ///（Swift 6：协议要求是 nonisolated，整类 @MainActor 会报 ConformanceIsolation；
  /// UIKit 实际只在主线程回调，隔离到 main 是事实声明）。
  private final class Session: NSObject, @MainActor SFSafariViewControllerDelegate,
    @MainActor UIAdaptivePresentationControllerDelegate
  {
    private let continuation: CheckedContinuation<String, Never>
    /// 一次性闸：Done 钮与 presentationController 回调可能都到，只认第一次。
    private var finished = false

    init(continuation: CheckedContinuation<String, Never>) {
      self.continuation = continuation
      super.init()
    }

    func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
      finish("cancel")
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
      finish("cancel")
    }

    /// present completion 里的兜底：present 链没接上（宿主转场中被丢弃）时按
    /// 取消收尾，否则 session 永远非 nil。
    func finishIfPresentationDropped(_ controller: SFSafariViewController) {
      guard controller.presentingViewController == nil, !controller.isBeingPresented else {
        return
      }
      finish("cancel")
    }

    private func finish(_ type: String) {
      guard !finished else { return }
      finished = true
      TiebaInAppBrowser.session = nil
      continuation.resume(returning: type)
    }
  }

  /// 枚举 → UIModalPresentationStyle（与旧包 PresentationStyle.toPresentationStyle 同表）。
  private static func modalStyle(_ style: PresentationStyle) -> UIModalPresentationStyle {
    switch style {
    case .fullScreen: return .fullScreen
    case .pageSheet: return .pageSheet
    case .formSheet: return .formSheet
    case .currentContext: return .currentContext
    case .overCurrentContext: return .overCurrentContext
    case .popover: return .popover
    case .none: return .none
    case .overFullScreen: return .overFullScreen
    case .automatic: return .automatic
    }
  }

  /// 枚举 → SFSafariViewController.DismissButtonStyle（旧包 DismissButtonStyle 同表）。
  private static func dismissStyle(_ style: DismissButtonStyle) -> SFSafariViewController.DismissButtonStyle {
    switch style {
    case .done: return .done
    case .close: return .close
    case .cancel: return .cancel
    }
  }
}
