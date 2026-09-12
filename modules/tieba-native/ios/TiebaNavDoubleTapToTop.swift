// 导航栏单击上报（JS 侧做双击判定 → 回顶）——由 TiebaNativeModule.swift 拆出。
//
// iOS 27β 上导航栏双击手势偶发"单击即触发"，双击判定改放 JS 侧
// （useNavDoubleTapToTop 400ms 窗口），原生只上报 bar 标题/空白区的单击。
import ExpoModulesCore
import Foundation
import ObjectiveC
import UIKit

extension TiebaNativeModule {
  enum DoubleTapState {
    /// 事件发送需要模块实例（sendEvent 是实例方法，手势回调是静态上下文）：
    /// protoInitialize 捕获，weak 不延长生命周期。
    nonisolated(unsafe) static weak var module: TiebaNativeModule?
    /// 双击门卫 delegate 的关联对象键（见 installNavDoubleTapToTop）。
    nonisolated(unsafe) static var gateKey: UInt8 = 0
  }

  // MARK: - 导航栏双击回顶（搜索/吧页/帖内/楼中楼；开关在设置-浏览）

  // 事件发送需要模块实例（sendEvent 是实例方法，手势回调是静态上下文）：
  // protoInitialize（启动首个 JS→原生调用）捕获，weak 不延长生命周期。
  static func retainEventModule(_ module: TiebaNativeModule) { DoubleTapState.module = module }
  /// 双击门卫 delegate 的关联对象键（见 installNavDoubleTapToTop）。
  

  /// 安装幂等：force 由 timer/KVO 反复跑，按手势类型判重。
  /// iOS 27β 上 UITapGestureRecognizer(numberOfTapsRequired:2) 在导航栏上
  /// 偶发"单击即触发"（真机 2026-09-01 实证：点一次就回顶）——双击判定改放
  /// JS 侧（useNavDoubleTapToTop 400ms 窗口），原生只上报 bar 标题/空白区的
  /// 单击（onNavDoubleTap 事件语义=bar 单击，JS 负责两次判定与抑制）。
  /// 门卫保留：左右边缘区与栏内 UIControl 不识别——事件仅在标题/空白区发出。
  static func installNavDoubleTapToTop(on bar: UINavigationBar) {
    let installed = bar.gestureRecognizers?.contains { $0 is NavDoubleTapGesture } ?? false
    guard !installed else { return }
    let tap = NavDoubleTapGesture(
      target: TiebaNativeModule.self,
      action: #selector(navDoubleTapped(_:))
    )
    tap.numberOfTapsRequired = 1
    // 必须关闭 touches 延迟（默认 true）！否则栏内所有 UIControl（返回钮/
    // 搜索钮/药丸）的 touch-up 要等双击判定窗口结束才派发——返回按钮点击
    // 后延迟 ~0.3s 才响应、振动落在返回之后（真机实测 2026-08-26）。
    tap.delaysTouchesBegan = false
    tap.delaysTouchesEnded = false
    // 命中栏内 UIControl（返回钮/按钮）时不启动识别：小目标上快速连点会
    // 被误判成双击回顶，页面跳顶后才弹菜单（真机实测反直觉，2026-08-26）。
    // delegate 须强持有：挂到手势的关联对象上随其存亡。
    let gate = NavDoubleTapGate()
    tap.delegate = gate
    objc_setAssociatedObject(tap, &DoubleTapState.gateKey, gate, .OBJC_ASSOCIATION_RETAIN)
    bar.addGestureRecognizer(tap)
  }

  @objc private static func navDoubleTapped(_ recognizer: UITapGestureRecognizer) {
    guard let module = DoubleTapState.module else { return }
    module.sendEvent("onNavDoubleTap", ["source": "navbar"])
  }
}

/// 导航栏双击手势的类型标记：幂等安装时按此判重（不与业务手势混淆）。
private final class NavDoubleTapGesture: UITapGestureRecognizer {}

// 双击回顶手势的门卫：点击落在 bar 内 UIControl（或其后代）时不开始识别，
// 把快速连点还给按钮本身（见 installNavDoubleTapToTop 注释）。左右边缘区
// （返回钮/右侧按钮群所在，药丸等非 UIControl 宿主也在）同样不识别——
// 用户在小目标周围空白处连点瞄准时不应触发回顶（真机实测反直觉）。
private final class NavDoubleTapGate: NSObject, UIGestureRecognizerDelegate {
  func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
    guard let bar = g.view else { return true }
    let p = g.location(in: bar)
    if p.x < 64 || p.x > bar.bounds.width - 64 { return false }
    var hit = bar.hitTest(p, with: nil)
    while hit != nil, hit !== bar {
      if hit is UIControl { return false }
      hit = hit?.superview
    }
    return true
  }
}
