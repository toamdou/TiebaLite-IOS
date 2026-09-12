// HdrChromeFlash——单次触发的 chrome 按钮按压高光——由 TiebaNativeModule.swift 拆出。
import ExpoModulesCore
import Foundation
import ObjectiveC
import UIKit

/// 单次触发的 chrome 按钮按压高光：缩放回弹（"点击时稍微扩大"）+ 控件内
/// 白闪 + 外扩光晕（超出控件边界 10pt，用户要求亮区往外扩）。全部附加在目标
/// 控件上、非交互；动画结束自移除。与 JS HdrPressable 同一视觉语言、同一
/// SDR 合成做法（App Store 同款），亮度拉满。
final class HdrChromeFlash: UIView {
  /// 'HDR'：同一控件连按时先摘掉旧光效再重放。
  private static let markerTag = 0x4844

  static func play(on control: UIControl) {
    if let existing = control.viewWithTag(markerTag) {
      existing.removeFromSuperview()
    }
    // 触觉与光效同源同刻：chrome 按钮（返回/导航右钮/底栏项）按压的轻震动。
    // 受全局"震动反馈"开关约束（JS 侧经 setHapticFeedbackEnabled 同步）。
    if TiebaNativeModule.hapticChromeHapticsEnabled {
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    let flash = HdrChromeFlash(frame: control.bounds)
    flash.tag = markerTag
    flash.isUserInteractionEnabled = false
    control.addSubview(flash)

    // 控件内白闪（SDR 合成拉满：峰值 1.0 纯白）
    let glow = UIView(frame: control.bounds)
    glow.backgroundColor = .white
    glow.layer.cornerRadius = 9
    flash.addSubview(glow)

    // 外扩光晕：超出控件边界 10pt，稍低透明度模拟玻璃受光漫射
    let halo = UIView(frame: control.bounds.insetBy(dx: -10, dy: -10))
    halo.backgroundColor = .white
    halo.layer.cornerRadius = 15
    flash.addSubview(halo)

    // 峰值瞬间置位（按压瞬间即亮，不缓起），再同步淡出
    glow.alpha = 1.0
    halo.alpha = 0.7

    // 缩放回弹：0.12s 弹到 1.18，弹簧回 1（transform 不影响布局）。
    // 契约：调用方（applyChromeHdr，命中导航/底栏内 UIControl 的 touch）不得
    // 自带 transform 或在其上加动画——本函数直接读写 control.transform。
    // 刻意不做 layer.removeAllAnimations() 式"先取消旧动画"：命中的控件位于
    // 系统 chrome 内，可能携带与按压无关的第三方动画（角标/进度等），无条件
    // 清动画会误伤；这里以"调用方零 transform"契约 + markerTag 摘旧光效兜底。
    control.transform = .identity
    UIView.animate(withDuration: 0.12, animations: {
      control.transform = CGAffineTransform(scaleX: 1.18, y: 1.18)
    }) { _ in
      UIView.animate(
        withDuration: 0.28, delay: 0, usingSpringWithDamping: 0.55,
        initialSpringVelocity: 0.4, options: []
      ) {
        control.transform = .identity
      }
    }

    UIView.animate(withDuration: 0.55, delay: 0, options: [.curveEaseOut], animations: {
      glow.alpha = 0
    })
    UIView.animate(withDuration: 0.62, delay: 0, options: [.curveEaseOut], animations: {
      halo.alpha = 0
    }) { _ in
      flash.removeFromSuperview()
    }
  }
}
