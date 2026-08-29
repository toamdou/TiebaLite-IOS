import Foundation
import UIKit

/// F1 隐私遮罩（2026-08-26 内存安全审查）：应用锁开启时，App 失活瞬间
/// 盖一层全屏模糊独立 window。iOS 多任务快照在 willResignActive 前后截取，
/// JS 层 AppState 盖不住这个时序，必须原生同步上屏。
///
/// 独立 UIWindow（windowLevel = .alert + 100）而非往 key window 加 subview：
/// RN Modal 会另开 window，subview 方案盖不住；独立高层级 window 全覆盖。
///
/// 开关状态镜像进 UserDefaults：下次启动 didFinishLaunching 即自启
/// （armFromMirror），早于 JS hydrate，堵住冷启动最早期退后台的空窗。
///
/// 并发契约：两个公开入口（armFromMirror/setEnabled/setSessionUnlocked）
/// 自带主线程跳转守卫，NotificationCenter 观察者队列指定 .main——
/// 全部状态仅主线程读写。Swift 6 下以 @unchecked Sendable 声明该不变量。
final class TiebaPrivacyShield: @unchecked Sendable {
  static let shared = TiebaPrivacyShield()

  private static let mirrorKey = "tiebalite.privacy_shield_enabled"

  private var window: UIWindow?
  private var enabled = false
  /// 会话解锁态：false = 面容验证通过前遮罩必须保持（didBecomeActive 不撤）。
  /// JS 在解锁成功/上锁/进后台时同步（F1 修复：真机实测此前 didBecomeActive
  /// 即 hide，面容弹窗还没验证完内容就露出来了）。
  private var sessionUnlocked = false
  private var observers: [NSObjectProtocol] = []

  private init() {}

  /// 启动期从 UserDefaults 镜像恢复开关（早于任何 JS 代码）。
  func armFromMirror() {
    setEnabled(UserDefaults.standard.bool(forKey: Self.mirrorKey))
  }

  /// JS 下发会话解锁态：unlocked=true（面容验证成功）→ 前台立即撤遮罩；
  /// unlocked=false（上锁/进后台/冷启动）→ 遮罩保持立着。
  func setSessionUnlocked(_ unlocked: Bool) {
    guard Thread.isMainThread else {
      DispatchQueue.main.async { self.setSessionUnlocked(unlocked) }
      return
    }
    sessionUnlocked = unlocked
    if unlocked && UIApplication.shared.applicationState == .active {
      hide()
    }
  }

  func setEnabled(_ on: Bool) {
    // JS 同步调用入口跑在 JS 线程：本函数会建 UIWindow 并 setRootViewController，
    // UIKit 沿途查询方向掩码会进入 ExpoAppDelegate 的 MainActor 隔离方法，
    // 非主线程直接 dispatch_assert_queue SIGTRAP（真机实测：面容验证成功瞬间
    // 应用仍处 inactive，"非 active 立即补盖"分支被命中，2026-08-26）。
    guard Thread.isMainThread else {
      DispatchQueue.main.async { self.setEnabled(on) }
      return
    }
    guard enabled != on else { return }
    enabled = on
    UserDefaults.standard.set(on, forKey: Self.mirrorKey)
    if on {
      // 新开启的锁会话：默认未解锁（等首次面容验证通过才撤遮罩）
      sessionUnlocked = false
      installObservers()
      // 极少见：开关变化时已处于失活态（后台改设置），立即补盖。
      if UIApplication.shared.applicationState != .active {
        show()
      }
    } else {
      removeObservers()
      hide()
    }
  }

  private func installObservers() {
    guard observers.isEmpty else { return }
    let center = NotificationCenter.default
    observers.append(center.addObserver(
      forName: UIApplication.willResignActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in self?.show() })
    // 回前台不再无条件 hide：验证成功（setSessionUnlocked(true)）前遮罩
    // 必须保持——否则面容弹窗还没验证完内容就露出来（真机实测）。
    observers.append(center.addObserver(
      forName: UIApplication.didBecomeActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      if self.sessionUnlocked { self.hide() }
    })
  }

  private func removeObservers() {
    for observer in observers {
      NotificationCenter.default.removeObserver(observer)
    }
    observers.removeAll()
  }

  private func show() {
    guard enabled else { return }
    let w = ensureWindow()
    // 遮罩存续期间不会旋转（失活态），但保险起见每次显示前对齐当前屏幕。
    w.frame = UIScreen.main.bounds
    w.isHidden = false
  }

  private func hide() {
    window?.isHidden = true
  }

  private func ensureWindow() -> UIWindow {
    if let window { return window }
    let w = UIWindow(frame: UIScreen.main.bounds)
    w.windowLevel = .alert + 100
    let viewController = UIViewController()
    viewController.view.backgroundColor = .clear
    let blur = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
    blur.frame = viewController.view.bounds
    blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    viewController.view.addSubview(blur)
    w.rootViewController = viewController
    w.isHidden = true
    window = w
    return w
  }
}
