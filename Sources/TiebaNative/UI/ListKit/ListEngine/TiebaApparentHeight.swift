// 移植自上游 submodules/Display/Source/ListViewItemNode.swift:244-321（apparentHeight / apparentFrame）
//
// 【为什么保留这一件（task-31 判定：**接**）】
//   上游让「布局高度」与「视觉高度」分离：折叠/展开只改视觉高度，真 frame 一动不动。
//   好处有三：① 动画期间不重测不重排；② 删行时可以先把视觉高度收到 0、动画结束才真正移除；
//   ③ 视觉高度可以暂时超出布局高度，展开时内容不会被裁掉一半。
//
// 【本仓落点】UI/ListKit/TiebaFeedRowView.playCollapseAnimation（不感兴趣折叠）：
//   改前用 CA `transform.scale.y` 压扁整层——**文字被纵向压扁**（真实缺陷，280ms 内肉眼可见）。
//   改后只收本视图的高度（apparentFrame：origin/宽度不动 ⇒ 顶边不动），内容按完整高度摆好后
//   由 clipsToBounds 裁掉下半部分；列表给的布局高度直到动画结束、数据真正移除才变。
//
// 【改动清单（相对上游）】
//   1. ASDisplayNode 上的两个可变属性 + 手工维护的 transition 元组 → 一个 Sendable 值类型；
//   2. 上游动画挂在 ListViewAnimation/DisplayLink 上 → 本仓直接用系统的 `UIViewPropertyAnimator`
//      驱动 frame（更少代码、可中断）；本类型只保留「状态 + 派生几何」这一层，不重复动画调度；
//   3. **未接线的部分已删除**（压到只剩接线用到的面）：TiebaApparentHeightAnimation（时间→值求值器）、
//      TiebaApparentHeightApplier（视图/内容应用助手）、handOff（动画过继）、
//      apparentBounds / apparentContentFrame / collapsedFraction。
//
// 【同族件的判定（task-31）】TiebaStationaryAnchor / TiebaScrollBand / TiebaListPlaceholder /
//   TiebaStickyHeader 四件**已整体删除**（页级 reload 架构下场景不成立或无收益），
//   逐条理由见 docs/uikit-migration/27-落地-crypto-binary.md。

import CoreGraphics
import Foundation

/// 一行的「布局高度 / 视觉高度」状态。值语义：可整份拷贝、对拍。
public struct TiebaApparentHeight: Sendable, Equatable {
  /// 视觉高度的过渡（动画中才非 nil）。上游的 apparentHeightTransition。
  public struct Transition: Sendable, Equatable {
    public let from: CGFloat
    public let to: CGFloat

    public init(from: CGFloat, to: CGFloat) {
      self.from = from
      self.to = to
    }
  }

  /// 布局高度：列表算出来的真高度，动画期间**不变**。
  public private(set) var layoutHeight: CGFloat
  /// 视觉高度：绘制/内容用的高度，动画期间由调用方逐帧写入。
  public private(set) var apparentHeight: CGFloat
  /// 动画中才有值；结束时由 finishTransition() 清掉。
  public private(set) var transition: Transition?

  public init(layoutHeight: CGFloat, apparentHeight: CGFloat? = nil) {
    self.layoutHeight = layoutHeight
    self.apparentHeight = apparentHeight ?? layoutHeight
    self.transition = nil
  }

  public var isAnimating: Bool { transition != nil }

  /// 布局高度变化：**不在动画中**时视觉高度跟着走（否则会停在旧高度上）。
  /// 动画中故意不跟：上游正是靠这一点让「内容高度变了」与「折叠动画」互不打架。
  public mutating func setLayoutHeight(_ height: CGFloat) {
    layoutHeight = height
    if transition == nil {
      apparentHeight = height
    }
  }

  public mutating func setApparentHeight(_ height: CGFloat) {
    apparentHeight = max(0, height)
  }

  public mutating func beginTransition(to height: CGFloat) {
    transition = Transition(from: apparentHeight, to: max(0, height))
  }

  public mutating func finishTransition() {
    transition = nil
  }

  /// 视觉 frame：origin 与宽度不变，只换高度。
  /// 折叠「顶边不动、下面的行不位移」就靠这一条（改了 origin 就变成整行上移）。
  public func apparentFrame(from frame: CGRect) -> CGRect {
    var result = frame
    result.size.height = apparentHeight
    return result
  }
}

#if DEBUG
extension TiebaApparentHeight {
  public static func debugSelfCheck() -> Bool {
    var value = TiebaApparentHeight(layoutHeight: 100)
    assert(value.apparentHeight == 100 && !value.isAnimating)

    // 派生几何：origin 与宽度不变，只有高度换掉（折叠时顶边不动的前提）
    let frame = CGRect(x: 0, y: 40, width: 320, height: 100)
    value.setApparentHeight(60)
    assert(value.apparentFrame(from: frame) == CGRect(x: 0, y: 40, width: 320, height: 60))

    // 动画中改布局高度：视觉高度不跟（上游语义）；结束后再改才跟随
    value.beginTransition(to: 0)
    value.setLayoutHeight(120)
    assert(value.apparentHeight == 60 && value.layoutHeight == 120, "动画中视觉高度不能被布局高度带走")
    value.finishTransition()
    value.setLayoutHeight(80)
    assert(value.apparentHeight == 80, "非动画态下视觉高度必须跟随布局高度")

    // 负值/零：视觉高度不能为负（frame 负高会翻转坐标系）
    value.setApparentHeight(-10)
    assert(value.apparentHeight == 0)
    return true
  }
}
#endif
