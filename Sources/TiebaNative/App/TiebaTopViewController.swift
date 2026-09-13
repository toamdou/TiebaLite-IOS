// 顶层可见视图控制器查找——原生壳里"要从当前界面 present 一个系统 VC"时的
// 公共入口（分享面板 / 内置浏览器 / 大图查看器）。
//
// 为什么抽出来（2026-09-12）：同一算法原先在 TiebaPhotoBrowser.swift 里以
// TiebaPhotoBrowserTopViewController 的名字存在一份最小副本，TiebaNavBarChrome
// 里还有一份 private 的 topScreenView（返回 view）。本次新增分享面板与
// SFSafariViewController 两个 present 方，再复制第三、第四份就是四处漂移的
// 隐患——查看器那份的原注释也留了"若再增需求，建议抽公共 helper 收敛"。
// NavBarChrome 的 topScreenView 不在本次收敛范围（它取的是 view 且与栏扫描
// 逻辑耦合），保持原样。
//
// 算法（与 NavBarChrome 同款）：key window（normal 层级优先）→ 沿 presented
// 链走到最深的一个 → 若是导航容器再取栈顶。深链/模态（分享面板、ActionSheet、
// Alert）都会在这条链上，所以从"最深的 presented"present 新 VC 不会撞上
// "already presenting"。
//
// 同文件另有 chrome 域的视图树查询（forEachSubviewRecursively / nearestAncestor /
// primaryScrollView）：这些算法原先在 NavigationShell、NavBarChrome、ChromeHaptics、
// NavDoubleTapToTop 各存一份副本，已收敛到这里唯一一份。
import UIKit

enum TiebaTopViewController {
  static func find() -> UIViewController? {
    let windows = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
    let keyWindow = windows.first { $0.isKeyWindow && $0.windowLevel == .normal } ?? windows.first
    guard let window = keyWindow, var vc = window.rootViewController else { return nil }
    while let presented = vc.presentedViewController { vc = presented }
    if let nav = vc as? UINavigationController, let top = nav.topViewController { vc = top }
    return vc
  }
}

// MARK: - 视图树查询（chrome 域唯一一份）

extension UIView {
  /// 深度优先遍历子树（含自身）。视图树遍历的唯一写法：栏收集、滚动边缘效果
  /// 扫描、scrollsToTop 收敛都走这里，避免"每处各写一遍递归"再漂移。
  ///
  /// nonisolated：chrome 侧（TiebaChrome 的 force/tick 路径）是**非隔离**类型，
  /// 从那里传闭包进来会被当成跨隔离域发送（"(UIView) -> Void" 非 Sendable）而
  /// 编译失败；这些遍历契约上都在主线程（调用点全部由主线程入口兜底），
  /// 所以这里不设隔离，由调用方保证线程。
  nonisolated func forEachSubviewRecursively(_ body: (UIView) -> Void) {
    body(self)
    for sub in subviews { sub.forEachSubviewRecursively(body) }
  }

  /// 沿 superview 链找最近满足条件的祖先（不含自身）。
  func nearestAncestor(where matches: (UIView) -> Bool) -> UIView? {
    var cursor = superview
    while let view = cursor {
      if matches(view) { return view }
      cursor = view.superview
    }
    return nil
  }

  /// 本子树里的"主滚动视图"：可滚动、有高度、面积最大的那个。
  ///
  /// 为什么是"面积最大"而不是"第一个"：页面顶层常嵌横向药丸行/横滑条，它们是
  /// UIScrollView 但很矮；系统给栏找跟踪对象时若挑中它们，底栏收纳与栏边缘模糊
  /// 都会跟错对象（表现为滚正文栏底不变、药丸一滑栏就变）。
  func primaryScrollView() -> UIScrollView? {
    var best: (view: UIScrollView, area: CGFloat)?
    forEachSubviewRecursively { view in
      guard let scroll = view as? UIScrollView, scroll.isScrollEnabled,
        scroll.bounds.height > 1
      else { return }
      let area = scroll.bounds.width * scroll.bounds.height
      if area > (best?.area ?? 0) { best = (scroll, area) }
    }
    return best?.view
  }
}
