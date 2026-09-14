import Foundation
import UIKit

/// 剪贴板贴吧链接识别（原 src/hooks/useClipboardDetector + ClipboardLinkDialog.tsx
/// 的原生等价物）：剪贴板变化/回前台时读一次，识别到帖子/吧链接就弹窗引导打开。
///
/// 约束：只在 App 前台读（进后台读会撞 iOS 粘贴提示），changeCount 去重
/// （同一份内容只处理一次，取代原 JS 的文本哈希 + 3s 节流与首查延迟）；
/// 开关是设置→使用习惯→剪贴板链接识别，关闭后连读都不发生。
/// 链接解析复用 TiebaNavigator 的两个静态解析器（深链同一份实现，不复制正则）。
@MainActor
final class TiebaClipboardLinkDetector {
  static let shared = TiebaClipboardLinkDetector()

  private var started = false
  /// 已处理的剪贴板版本号：同一份内容不重复读/重复弹（原 JS lastHash 同义）。
  private var lastHandledChangeCount = -1

  private init() {}

  func start() {
    guard !started else { return }
    started = true
    guard TiebaPreferences.bool("clipboardLinkDetection", default: true) else { return }
    // 回前台：启动/切回后补查一次当前内容。
    NotificationCenter.default.addObserver(
      forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in MainActor.assumeIsolated { self?.check() } }
    // 剪贴板内容变化（含其它 App 复制后切回）：事件驱动，不做时间节流。
    NotificationCenter.default.addObserver(
      forName: UIPasteboard.changedNotification, object: nil, queue: .main
    ) { [weak self] _ in MainActor.assumeIsolated { self?.check() } }
    check()
  }

  private func check() {
    guard TiebaPreferences.bool("clipboardLinkDetection", default: true) else { return }
    let pasteboard = UIPasteboard.general
    let changeCount = pasteboard.changeCount
    guard changeCount != lastHandledChangeCount else { return }

    let text = TiebaClipboard.getString()
    guard !text.isEmpty else { return }
    if let threadId = TiebaNavigator.extractThreadId(text), !threadId.isEmpty {
      lastHandledChangeCount = changeCount
      present(
        title: "检测到贴吧帖子链接",
        message: "帖子ID: \(threadId)\n\n\(text)",
        path: "thread/\(threadId)"
      )
      return
    }
    if let forumName = TiebaNavigator.extractForumName(text), !forumName.isEmpty {
      lastHandledChangeCount = changeCount
      present(
        title: "检测到贴吧链接",
        message: "吧名: \(forumName)\n\n\(text)",
        path: "forum/\(forumName)"
      )
    }
  }

  private func present(title: String, message: String, path: String) {
    // 让路：最上层已是系统弹窗（JS 检测器同帧的 Alert.alert）或压着模态时，
    // 同一段剪贴板内容不再叠第二个提示。
    guard let host = TiebaTopViewController.find(),
      !(host is UIAlertController),
      !(host.presentingViewController != nil && host.navigationController == nil)
    else { return }
    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "取消", style: .cancel))
    alert.addAction(UIAlertAction(title: "打开", style: .default) { _ in
      _ = TiebaNavigator.shared.navigate(path: path, params: [:], mode: "push")
    })
    host.present(alert, animated: true)
  }
}
