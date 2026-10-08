// 滚动方向门（TiebaScrollDirectionGate）
//
// 移植自上游 submodules/Display/Source/ListView.swift:1023-1029（generalAccumulatedDeltaY）：
//   逐帧把**带符号**的 ΔY 累加起来，只有 |累积量| 越过 14.0 才翻转"方向判定"，
//   翻转后立刻清零重新累。
//
// 【为什么必须"累加"而不能看瞬时值】"栏/浮条随滚动显隐"是二值状态，而手指每帧都在抖：
//   · 看瞬时速度（本仓改前：帖子页浮条判 |velocity.y| > 0.3pt/s）—— 0.3pt/s 等于"凡动必判"，
//     手指在空中抖一下栏就翻一次；
//   · 看单帧位移（本仓改前：吧页悬浮按钮判 |Δy| > 8）—— 120Hz 下一帧走 8pt 太容易，同样爱翻。
//   累加 = **对位移做低通**：往复抖动正负相消，只有"用户真的往一个方向走了 14pt"才计一次。
//
// 阈值出处：TiebaMotionSpec.Scroll.directionFlipThreshold（= 14.0，上游同值）。
// 调用方：Features/Thread/TiebaThreadViewController（浮条自动隐藏）
//         Features/Forum/TiebaForumViewController（悬浮按钮自动隐藏）。
//
// ⚠️ 2026-10-08 用户复报「手指下滑才隐藏，我要上滑隐藏」：这里的三元**写反了**
// （写成 accumulated < 0 → .forward），与下方 Direction 的定义正好相反——于是浮条
// 与悬浮按钮是在"往回翻"时收起、读内容时挂着。判据以 Direction 的定义为准：
// ΔY > 0（contentOffset 增大 = 手指上滑）⇒ .forward ⇒ 收起。

import CoreGraphics

/// 滚动方向（按 contentOffset 增量定义，**不是**手指方向）。
struct TiebaScrollDirectionGate: Sendable {
  enum Direction: Sendable {
    /// contentOffset.y 增大 = 手指上滑 = 正在翻看后面的内容 → 栏/浮条该收起。
    case forward
    /// contentOffset.y 减小 = 手指下滑 = 正在往回翻 → 栏/浮条该露出。
    case backward
  }

  /// 上一次的 contentOffset.y；nil = 还没起算（第一次调用只记基线，不判方向）。
  private var lastOffsetY: CGFloat?
  private var accumulated: CGFloat = 0

  /// 当前已认定的方向（nil = 还没翻过）。
  private(set) var direction: Direction?

  init() {}

  /// 回顶/换页等"位置被外力重置"的时刻调用：丢掉累加量，下一次调用重新记基线。
  /// （不重置的话，程序化回顶那一大段位移会被算成一次方向翻转。）
  mutating func reset() {
    lastOffsetY = nil
    accumulated = 0
  }

  /// 吃一帧 contentOffset.y；只有**方向翻转**时返回新方向，其余返回 nil。
  mutating func update(contentOffsetY: CGFloat) -> Direction? {
    guard let last = lastOffsetY else {
      lastOffsetY = contentOffsetY
      return nil
    }
    lastOffsetY = contentOffsetY
    accumulated += contentOffsetY - last
    guard abs(accumulated) > TiebaMotionSpec.Scroll.directionFlipThreshold else { return nil }
    let next: Direction = accumulated > 0 ? .forward : .backward
    accumulated = 0
    guard direction != next else { return nil }
    direction = next
    return next
  }
}
