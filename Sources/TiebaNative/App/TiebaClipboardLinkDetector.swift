import Foundation
import UIKit

/// 剪贴板贴吧链接识别（原 src/hooks/useClipboardDetector + ClipboardLinkDialog.tsx
/// 的原生等价物）：回前台/启动时读一次剪贴板，识别到帖子/吧链接就弹窗引导打开。
///
/// 约束：只在 App 前台读（进后台读会撞 iOS 粘贴提示），内容 hash 去重 + 3s 节流
/// （同原 JS）；开关是设置→使用习惯→剪贴板链接识别，关闭后连读都不发生。
/// 链接解析复用 TiebaNavigator 的两个静态解析器（深链同一份实现，不复制正则）。
@MainActor
final class TiebaClipboardLinkDetector {
  static let shared = TiebaClipboardLinkDetector()

  private static let throttle: TimeInterval = 3

  private var started = false
  private var lastCheckAt: Date?
  /// 最近一次识别成功的剪贴板原文：同内容不再重复弹窗（原 JS lastHash 同义）。
  private var lastHandledText = ""

  private init() {}

  func start() {
    guard !started else { return }
    started = true
    guard TiebaPreferences.bool("clipboardLinkDetection", default: true) else { return }
    NotificationCenter.default.addObserver(
      forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in MainActor.assumeIsolated { self?.check() } }
    // 首查让出首帧（弹窗要挂在已上屏的界面上，原 JS 亦在挂载后异步查）。
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.check() }
  }

  private func check() {
    guard TiebaPreferences.bool("clipboardLinkDetection", default: true) else { return }
    let now = Date()
    if let lastCheckAt, now.timeIntervalSince(lastCheckAt) < Self.throttle { return }
    lastCheckAt = now

    let text = TiebaClipboard.getString()
    guard !text.isEmpty, text != lastHandledText else { return }
    if let threadId = TiebaNavigator.extractThreadId(text), !threadId.isEmpty {
      lastHandledText = text
      present(
        title: "检测到贴吧帖子链接",
        message: "帖子ID: \(threadId)\n\n\(text)",
        path: "thread/\(threadId)"
      )
      return
    }
    if let forumName = TiebaNavigator.extractForumName(text), !forumName.isEmpty {
      lastHandledText = text
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
