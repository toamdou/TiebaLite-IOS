// 首屏批次入场（EntranceRow 的原生唯一实现）。
//
// 原 JS src/components/feed/EntranceRow.tsx 冻结的参数：
//   opacity 0→1 + translateY 12→0，220ms（DURATION.enter），
//   delay = min(index, ENTRANCE_STAGGER_LIMIT - 1) × 35ms（上限 10 ⇒ min(index, 9)），
//   EASE_OUT，reduceMotion 时**直接静态显示**。
//
// 迁移期四个行族（feed 行 / 帖行 / 通用行 / 吧 chip）各抄了一份，抄出三处漂移：
// 位移 12 vs 10pt、级联上限 9 vs 10 vs 1.2s 钳制、Reduce Motion 有的静态有的淡入。
// 收敛到本文件，参数只有这一份。
//
// 为什么用 CAAnimation 而不是 UIView.animate（别"顺手简化"）：
//   1. 这是**表现层动画**——模型值始终是终态（alpha 1 / identity），行被回收时
//      不会留下"半透明/半位移"的模型状态（UIView.animate 会把模型值设成终态、
//      只动 presentation，但时延窗口里复用可见残影）；
//   2. 列表行的复用复位靠 `layer.removeAnimation(forKey:)`（见
//      TiebaFeedRowView.resetAnimations）——UIView.animate 挂的是 UIKit 内部键，
//      按 "tieba.entrance" 移除它无效，复用时会带着在途动画串到下一行。
//   所以 key 名 "tieba.entrance" 是本类型与各 reset 路径之间的契约，不要改。
import UIKit

enum TiebaEntrance {
  /// 级联上限（JS ENTRANCE_STAGGER_LIMIT）：index ≥ 9 一律按 9 计。
  static let staggerLimit = 10
  static let duration: CFTimeInterval = 0.22
  static let stagger: CFTimeInterval = 0.035
  static let offset: CGFloat = 12
  /// 动画键（各视图的复用复位按它移除，见文件头）。
  static let animationKey = "tieba.entrance"

  /// 该 index 的延迟（钳制语义与 JS 逐字一致：min(index, limit - 1) × stagger）。
  static func delay(forIndex index: Int) -> CFTimeInterval {
    CFTimeInterval(min(max(index, 0), staggerLimit - 1)) * stagger
  }

  /// 淡入上移入场。模型值保持终态，动画只作用于 presentation。
  static func play(on view: UIView) {
    play(on: view, index: 0)
  }

  static func play(on view: UIView, index: Int) {
    let layer = view.layer
    layer.removeAnimation(forKey: animationKey)
    // 模型恒为终态：Reduce Motion 下什么都不做就是"直接静态显示"。
    layer.opacity = 1
    layer.transform = CATransform3DIdentity
    guard !UIAccessibility.isReduceMotionEnabled else { return }

    let group = CAAnimationGroup()
    let opacity = CABasicAnimation(keyPath: "opacity")
    opacity.fromValue = 0
    opacity.toValue = 1
    let translation = CABasicAnimation(keyPath: "transform.translation.y")
    translation.fromValue = offset
    translation.toValue = 0
    group.animations = [opacity, translation]
    group.duration = duration
    group.beginTime = CACurrentMediaTime() + delay(forIndex: index)
    group.fillMode = .backwards
    group.timingFunction = TiebaEntranceTiming.easeOut
    layer.add(group, forKey: animationKey)
  }

  /// 移除在途入场（复用复位用；与 animationKey 配套）。
  static func cancel(on view: UIView) {
    view.layer.removeAnimation(forKey: animationKey)
  }
}

/// EASE_OUT cubic-bezier(0.32, 0.72, 0, 1)（JS EASE_OUT 同值）。
/// nonisolated(unsafe)：CAMediaTimingFunction 是不可变值对象（构造后无 setter），
/// 与 kCAMediaTimingFunctionEaseOut 同性质的进程级常量，跨线程只读安全。
private enum TiebaEntranceTiming {
  nonisolated(unsafe) static let easeOut = CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0, 1)
}
