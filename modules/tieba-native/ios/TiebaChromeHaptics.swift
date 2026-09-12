// Chrome HDR 按压高光（返回钮 / 导航栏右钮 / 底栏钮）——由 TiebaNativeModule.swift 拆出。
//
// 系统 chrome 按钮是 UIControl，RN 的 Pressable 不是（JS 侧由 HdrPressable 负责）；
// 这里 swizzle UIView/UIControl 的 touchesBegan，命中系统栏按钮时给光效 + 轻触觉。
import ExpoModulesCore
import Foundation
import ObjectiveC
import UIKit

extension TiebaNativeModule {
  enum HapticsState {
    /// chrome 按压触觉总闸：由 JS 在偏好变化与启动时同步（默认开）。
    nonisolated(unsafe) static var enabled = true
    nonisolated(unsafe) static var swizzled = false
    /// 同控件去重：UIView/UIControl 双通道 + 连按重放都从两次降至一次。
    nonisolated(unsafe) static var lastChromeControl: UIControl?
    nonisolated(unsafe) static var lastChromeAt: TimeInterval = 0
  }

  static var hapticChromeHapticsEnabled: Bool { HapticsState.enabled }

  static func setHapticChromeHapticsEnabled(_ enabled: Bool) { HapticsState.enabled = enabled }

  static func installChromeHapticsHooks() { _ = chromeHapticsHooks }

  // MARK: - Chrome HDR 按压高光（返回钮 / 导航栏右钮 / 底栏钮）

  // 系统 chrome 按钮（返回箭头、headerRight 原生钮、NativeTabs 底栏项）是
  // UIControl；RN 的 Pressable 不是 UIControl，不走这条链路（JS 侧由
  // HdrPressable 负责）。命中 touch 的往往是按钮内部的子视图（如 chevron
  // imageView）而非控件本身，所以 swizzle 挂在 UIView 上：先调原实现，再沿
  // 响应链向上找最近 UIControl；其祖先含 UINavigationBar/UITabBar 才挂光效。
  // 过滤条件之外的视图零开销短路。

  static let chromeHapticsHooks: Void = {
    guard !HapticsState.swizzled else { return }
    HapticsState.swizzled = true
    // 双通道覆盖：纯 UIView 重写 touchesBegan 的控件（iOS 27 返回钮等
    // _UIModernBarButton 往往重写且不调 super）走 UIControl 通道。
    // applyChromeHdr 内部按（控件，时间窗）去重，双通道不重复反馈。
    let selector = #selector(UIView.touchesBegan(_:with:))
    if let method = class_getInstanceMethod(UIView.self, selector) {
      let original = method_getImplementation(method)
      typealias TouchesBeganFn = @convention(c) (AnyObject, Selector, Set<UITouch>, UIEvent?) -> Void
      let originalFn = unsafeBitCast(original, to: TouchesBeganFn.self)
      let block: @convention(block) (AnyObject, Set<UITouch>, UIEvent?) -> Void = { view, touches, event in
        originalFn(view, selector, touches, event)
        TiebaNativeModule.applyChromeHdr(to: view)
      }
      method_setImplementation(method, imp_implementationWithBlock(block))
    }
    if let controlMethod = class_getInstanceMethod(UIControl.self, #selector(UIControl.touchesBegan(_:with:))) {
      let controlOriginal = method_getImplementation(controlMethod)
      typealias ControlTouchesFn = @convention(c) (AnyObject, Selector, Set<UITouch>, UIEvent?) -> Void
      let controlOriginalFn = unsafeBitCast(controlOriginal, to: ControlTouchesFn.self)
      let controlBlock: @convention(block) (AnyObject, Set<UITouch>, UIEvent?) -> Void = { control, touches, event in
        controlOriginalFn(control, #selector(UIControl.touchesBegan(_:with:)), touches, event)
        TiebaNativeModule.applyChromeHdr(to: control)
      }
      method_setImplementation(controlMethod, imp_implementationWithBlock(controlBlock))
    }
    return ()
  }()

  /// 同控件去重：UIView/UIControl 双通道 + 连按重放都从两次降至一次。
  static func applyChromeHdr(to view: AnyObject) {
    guard let host = view as? UIView else { return }
    var control: UIControl?
    var isBar = false
    var cursor: UIView? = host
    while let v = cursor {
      if control == nil, let c = v as? UIControl {
        control = c
      }
      if v is UINavigationBar || v is UITabBar {
        isBar = true
        break
      }
      cursor = v.superview
    }
    guard isBar, let target = control,
          target.bounds.width > 0, target.bounds.height > 0 else { return }
    // 2026-09-03：收紧为系统 chrome 按钮类——RN 0.81+ 的 Pressable 渲染为
    // 原生 UIButton，信息流卡片（导航栈内）触摸时沿链命中 UINavigationBar
    // 即误触发 chrome 触觉（用户实测"滑动碰到点赞按钮也振动"）。系统
    // 返回钮/底栏项类名含 Bar/Tab + Button（_UIModernBarButton/
    // _UIButtonBarButton/_UITabBarButton）；RN 按钮类名（RCT*）不含，排除。
    let clsName = String(describing: type(of: target))
    let isSystemChromeButton = clsName.localizedCaseInsensitiveContains("Button")
      && (clsName.localizedCaseInsensitiveContains("Bar")
        || clsName.localizedCaseInsensitiveContains("Tab"))
    guard isSystemChromeButton else { return }
    // 双通道（UIView/UIControl）+ 快速连按去重：同一控件 800ms 内只反馈
    // 一次。返回键曾被实测「点击一次振两次」：pop 转场期间 UIKit 向原按钮
    // 重放 touchesBegan（约 150-400ms 后，250ms 去重窗之外），第二次振动
    // 恰落在「返回上一级之后」（2026-08-27 真机复现）。双通道同帧双发
    // （同一控件 <5ms）仍由本窗口覆盖。
    let now = ProcessInfo.processInfo.systemUptime
    if target === HapticsState.lastChromeControl, now - HapticsState.lastChromeAt < 0.8 { return }
    HapticsState.lastChromeControl = target
    HapticsState.lastChromeAt = now
    HdrChromeFlash.play(on: target)
  }
}
