// TiebaGlassContainerView —— 多块自建玻璃的宿主容器：只有放进同一个 UIGlassContainerEffect
// 的 contentView，它们之间才有 iOS 26 的"液态融合"（靠近时互相牵引、边缘融合）。
//
// 移植自上游 submodules/GlassBackgroundComponent/Sources/GlassBackgroundComponent.swift
//   :841-974（GlassBackgroundContainerView）。上游把**几乎每一处玻璃**都套在这个容器里
//   （grep GlassBackgroundContainerView = 112 处，例如 GlassControlPanel.swift:124-129 把一排
//   玻璃控件组塞进 contentView、HeaderPanelContainerComponent.swift:104-114 把顶栏玻璃塞进去）。
//
// 逐条对应：
//   · ① 容器 = UIVisualEffectView(effect: UIGlassContainerEffect())，effect.spacing 默认 7.0
//     （上游 :857-861 同默认）。SDK 头 UIGlassEffect.h 原文："The spacing specifies the distance
//     between elements at which they begin to merge." ⇒ **spacing 是观感参数**：玻璃间实际距离
//     大于 spacing 时，稳态观感与"不套容器"完全一致（本仓玻璃件之间多为 8pt ⇒ 默认 7 不改变现状）；
//     只有它们靠近到 spacing 以内（动画中、布局挤压时）才开始融合。要强制融合就调大它 —— 那是一次
//     视觉决策，改一个数字即可。
//   · ② 子玻璃**只允许**加进 `contentView`，加错位置直接断言（上游 :888-894）。
//   · ③ hitTest 三段结构（上游 :896-946）：三重早退 → 逆序遍历 contentView.subviews 逐个 hitTest
//     （只接受 isUserInteractionEnabled 的结果）→ 兜底命中 contentView 自己则返回 nil。
//     语义：容器只负责"托住"内容，**它的空白区是穿透的**。这是自绘玻璃/遮罩容器最常见的 bug
//     来源（"面板关掉之后那块区域点不动了"/"工具条玻璃把下面的列表滑动吃掉了"）。
//   · ④ 明暗由 overrideUserInterfaceStyle 驱动（上游 :950），不写自建 isDark 分支。
//
// 本仓差异（三条，都是铁律所致，不是简化）：
//   1. 上游额外挂了 EffectSettingsContainerView（swizzle 私有 UISDFBackdropView 的
//      backdropLayer:didChangeLuma: 压玻璃亮度）——**不移植**：报告 37 A8 已把"碰系统件外观就付私有债"
//      升级为团队规则，替代品是 UIGlassEffect.tintColor + overrideUserInterfaceStyle（本仓已在用）。
//   2. 上游的 useCustomGlassImpl / legacyView 分支是"iOS 26 以下自绘玻璃"那条路；本仓部署底线
//      iOS 26 ⇒ 只留系统玻璃一条路（判据③：不留第二实现）。
//   3. 上游用 ContainedViewLayoutTransition 摆 frame；本仓这里是普通 UIView，直接设 frame/约束。
//
// 并发：UIView 子类天然 @MainActor。

import UIKit

final class TiebaGlassContainerView: UIView {
    /// 玻璃容器本体。它自己**没有**材质 —— 只提供玻璃分组上下文，所以没有子玻璃时它是全透明的。
    private let effectView: UIVisualEffectView

    /// 子玻璃与内容都加到这里（上游 :849-855 的同一约定）。
    var contentView: UIView {
        return self.effectView.contentView
    }

    init(spacing: CGFloat = 7.0) {
        let effect = UIGlassContainerEffect()
        effect.spacing = spacing
        self.effectView = UIVisualEffectView(effect: effect)
        super.init(frame: .zero)
        self.backgroundColor = .clear
        self.addSubview(self.effectView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TiebaGlassContainerView 只支持代码创建")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        self.effectView.frame = self.bounds
    }

    /// ② 只允许 contentView 承载子视图（effectView 自身由本类管理）。
    override func didAddSubview(_ subview: UIView) {
        super.didAddSubview(subview)
        assert(subview === self.effectView, "玻璃容器的内容要加进 contentView，不能直接 addSubview")
    }

    /// ④ 明暗只走系统 trait（上游 :950），不引入自建 isDark 分支。
    func update(isDark: Bool) {
        let style: UIUserInterfaceStyle = isDark ? .dark : .light
        if self.effectView.overrideUserInterfaceStyle != style {
            self.effectView.overrideUserInterfaceStyle = style
        }
    }

    /// ③ 只让内容子视图参与命中，自己绝不吃点击（上游 :896-946）。
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if self.alpha.isZero {
            return nil
        }
        if self.isHidden {
            return nil
        }
        if !self.isUserInteractionEnabled {
            return nil
        }
        for view in self.contentView.subviews.reversed() {
            if let result = view.hitTest(self.convert(point, to: view), with: event), result.isUserInteractionEnabled {
                return result
            }
        }
        guard let result = self.contentView.hitTest(point, with: event) else {
            return nil
        }
        // 命中的是 contentView 自己 = 落在内容之间的空白：穿透。
        if result === self.contentView {
            return nil
        }
        return result
    }
}

// MARK: - 玻璃装配

/// 全仓**唯一**的玻璃装配入口（iOS 26 系统语义材质 UIGlassEffect）。
/// 收敛前 7 处各写一遍「effect + tint + UIVisualEffectView」的装配，材质规则散在各页；
/// 现在统一从这里出，观感规则（.regular + 可选 tint）只此一份。
extension TiebaGlassContainerView {
  static func makeEffect(tint: UIColor? = nil) -> UIVisualEffectView {
    let effect = UIGlassEffect(style: .regular)
    if let tint { effect.tintColor = tint }
    return UIVisualEffectView(effect: effect)
  }
}
