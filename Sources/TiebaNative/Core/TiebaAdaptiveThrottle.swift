// ============================================================
// 自适应节流：把"固定间隔"换成"间隔随连续请求递增、封顶"。
//
// 对应 IGListKit 的 IGListAdaptiveCoalescingExperimentConfig：距上次放行不足
// currentInterval 就合并掉并让间隔长大一档；静默一段后回到最小间隔；不可见时
// 直接用最大间隔（用户看不见时，晚一点做没有代价）。
// ============================================================

import Foundation

struct TiebaAdaptiveThrottle {
  /// 最小间隔（= 旧固定节流值）：静默后重新从这里起算。
  var minInterval: CFTimeInterval
  /// 每被合并一次，间隔长大这么多。
  var intervalIncrement: CFTimeInterval
  /// 间隔上限 = 一次合并最久等多久（缺页自愈的等待上限就是这个值）。
  var maxInterval: CFTimeInterval

  private var currentInterval: CFTimeInterval
  private var lastPassAt: CFTimeInterval = -CFTimeInterval.greatestFiniteMagnitude

  init(
    minInterval: CFTimeInterval = 0.5,
    intervalIncrement: CFTimeInterval = 0.5,
    maxInterval: CFTimeInterval = 2
  ) {
    self.minInterval = minInterval
    self.intervalIncrement = intervalIncrement
    self.maxInterval = maxInterval
    currentInterval = minInterval
  }

  /// 现在放行吗？被合并掉时自动退避一档（`inactive` = 宿主不可见）。
  mutating func shouldPass(now: CFTimeInterval, inactive: Bool = false) -> Bool {
    let interval = inactive ? maxInterval : currentInterval
    guard now - lastPassAt >= interval else {
      currentInterval = min(currentInterval + intervalIncrement, maxInterval)
      return false
    }
    lastPassAt = now
    currentInterval = minInterval
    return true
  }
}
