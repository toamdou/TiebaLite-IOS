// 状态栏接管（隐藏 + 样式）——由 TiebaNativeModule.swift 拆出。
//
// iOS 27 的状态栏机制：隐藏走私有 _preferredStatusBarVisibility 查询；RN 的
// RCTStatusBarManager.setStyle: 在 UIViewControllerBasedStatusBarAppearance=true
// 下会红屏。这里 swizzle 两个入口，把请求改走 VC 级查询。
import ExpoModulesCore
import Foundation
import ObjectiveC
import UIKit

extension TiebaNativeModule {
  /// extension 不能声明存储属性：可变状态收进命名空间类型。语义不变
  /// （nonisolated(unsafe)：仅主线程读写，ObjectiveC runtime 互操作无隔离标注）。
  enum StatusBarState {
    nonisolated(unsafe) static var modalHidden = false
    nonisolated(unsafe) static var modalSwizzled = false
    nonisolated(unsafe) static var style: UIStatusBarStyle = .default
    nonisolated(unsafe) static var managerAdopted = false
  }

  // MARK: - 状态栏接管（隐藏 + 样式）

  // ⚠️ Swift 6 并发契约：以下静态状态全部仅主线程读写——swizzle 回调/触摸/
  // 布局/KVO 都在主线程，载入路径自带主线程守卫或主队列跳转。ObjectiveC
  // runtime 互操作（imp_implementationWithBlock 等）无法携带隔离标注，
  // 故统一以 nonisolated(unsafe) 声明非隔离存储，维持原有语义。
  
  /// iOS 27 状态栏机制（实测）：
  /// - 隐藏：系统不再查询公开的 prefersStatusBarHidden（全程零查询），改查
  ///   私有 UIViewController._preferredStatusBarVisibility（typeEncoding
  ///   i16@0:8，枚举 2=可见 1=隐藏，系统默认返 2）。
  /// - RN 的 RCTStatusBarManager.setStyle: 原实现要求
  ///   UIViewControllerBasedStatusBarAppearance=NO，否则 RCTLogError 红屏
  ///   （且底层 [UIApplication setStatusBarStyle:] 在 iOS 27 已是 no-op）。
  /// 因此这里 swizzle 掉 RCTStatusBarManager 两个写入方法，把请求改走
  /// VC 级查询：既消红屏，又让样式真正生效。查看器（overFullScreen
  /// modal）打开时全 app 报告隐藏，关闭时恢复。
  static func adoptStatusBarManager() {
    guard !StatusBarState.managerAdopted else { return }
    guard let cls = NSClassFromString("RCTStatusBarManager") else { return }
    StatusBarState.managerAdopted = true
    if let mth = class_getInstanceMethod(cls, NSSelectorFromString("setStyle:animated:")) {
      let imp = imp_implementationWithBlock({ (_: AnyObject, style: String, _: Bool) -> Void in
        switch style {
        case "light-content": StatusBarState.style = .lightContent
        case "dark-content": StatusBarState.style = .darkContent
        default: StatusBarState.style = .default
        }
        TiebaNativeModule.refreshStatusBarAppearance()
      } as @convention(block) (AnyObject, String, Bool) -> Void)
      method_setImplementation(mth, imp)
    }
    if let mth = class_getInstanceMethod(cls, NSSelectorFromString("setHidden:withAnimation:")) {
      let imp = imp_implementationWithBlock({ (_: AnyObject, hidden: Bool, _: String) -> Void in
        TiebaNativeModule.applyModalStatusBarHidden(hidden)
      } as @convention(block) (AnyObject, Bool, String) -> Void)
      method_setImplementation(mth, imp)
    }
    // 样式查询入口（公开 API）：iOS 27 实测系统仍会查询，返回 swizzle 维护的样式
    if let mth = class_getInstanceMethod(UIViewController.self,
                                        #selector(getter: UIViewController.preferredStatusBarStyle)) {
      let imp = imp_implementationWithBlock({ (_: AnyObject) -> UIStatusBarStyle in
        return StatusBarState.style
      } as @convention(block) (AnyObject) -> UIStatusBarStyle)
      method_setImplementation(mth, imp)
    }
  }

  /// 改写状态栏隐藏查询：swizzle 基类 _preferredStatusBarVisibility，
  /// 大图查看器打开时全 app 返回 1（隐藏），关闭返回 2（可见）。
  static func applyModalStatusBarHidden(_ hidden: Bool) {
    StatusBarState.modalHidden = hidden
    let sel = NSSelectorFromString("_preferredStatusBarVisibility")
    if !StatusBarState.modalSwizzled,
       let mth = class_getInstanceMethod(UIViewController.self, sel) {
      StatusBarState.modalSwizzled = true
      let imp = imp_implementationWithBlock({ (_: AnyObject) -> Int in
        StatusBarState.modalHidden ? 1 : 2
      } as @convention(block) (AnyObject) -> Int)
      method_setImplementation(mth, imp)
    }
    refreshStatusBarAppearance()
  }

  /// 通知系统重新查询状态栏外观（最顶层 presented VC 即 RN Modal）
  /// 延迟到下一 runloop 再请求：调用方常在动画/布局提交期（Modal present/
  /// dismiss），彼时同步 setNeedsStatusBarAppearanceUpdate 会触发 UIKit
  /// _noteOverlayInsetsDidChange 断言 abort（真机退出大图闪退的崩溃堆栈，
  /// JS 侧延迟恢复是主修，这里双保险）。
  static func refreshStatusBarAppearance() {
    DispatchQueue.main.async {
      for window in UIApplication.shared.connectedScenes
        .compactMap({ ($0 as? UIWindowScene)?.keyWindow }) {
        var vc = window.rootViewController
        while let presented = vc?.presentedViewController {
          vc = presented
        }
        vc?.setNeedsStatusBarAppearanceUpdate()
      }
    }
  }
}
