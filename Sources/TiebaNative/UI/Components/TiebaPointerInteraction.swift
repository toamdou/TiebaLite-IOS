// TiebaPointerInteraction —— iPad 指针（触控板/妙控鼠标）悬停反馈：7 档 UIPointerStyle 的封装。
//
// 移植自上游 submodules/Display/Source/PointerInteraction.swift（130 行）。报告 37 C3。
//
// 三条值得单独记住的做法：
//   ① .default 档**自动给命中区加内边距**：水平 +10、垂直 +4、高度下限 40（上游 :55-58）——
//      让指针高亮比控件本体大一圈。这是触控目标（44pt）与视觉尺寸脱节的通用补偿；
//   ② .hover 档显式传 preferredTintMode: .none / prefersShadow: false / prefersScaledContent: false
//      （上游 :74）—— **关掉系统的“内容放大”**。默认的 scaledContent 会让图标在悬停时突然变大，
//      在密集列表里很吵；
//   ③ willEnter/willExit 走 animator.addAnimations { }（上游 :80-98）：把悬停动画交给系统去和指针
//      同步，而不是自己起一条 CABasicAnimation（自己起的曲线必然和指针不同步）。
//
// 本仓差异：
//   1. 上游分 PointerInteraction（公开）+ PointerInteractionImpl（私有，deinit 里摘 interaction）
//      两层是为了兼容 iOS 13.4 之前的可用性；本仓部署底线 iOS 26 ⇒ 合成一个类，少一层转发。
//   2. floorToScreenPixels 用本仓 TiebaNodesGraphics.floorToScreenPixels(_:scale:)（判据③）。
//   3. ASDisplayNode 入口（上游 :116-118）删掉：本仓没有 ASDisplayNode。
//
// 并发：UIPointerInteractionDelegate 在 SDK 头里就是 NS_SWIFT_UI_ACTOR ⇒ 整类 @MainActor。

import UIKit

/// 上游 :4-12 的 7 档。
enum TiebaPointerStyle {
    /// 命中区外扩（水平 10 / 垂直 4 / 高度下限 40）。
    case `default`
    case insetRectangle(CGFloat, CGFloat)
    case rectangle(CGSize)
    /// 直径 nil = 取长边（正方形控件即内切圆）。
    case circle(CGFloat?)
    /// 文本光标（竖条）。
    case caret
    case lift
    /// 系统悬停效果，但**关掉内容缩放**（见文件头 ②）。
    case hover
}

@MainActor
final class TiebaPointerInteraction: NSObject, UIPointerInteractionDelegate {
    private let style: TiebaPointerStyle
    private let willEnter: () -> Void
    private let willExit: () -> Void
    private weak var customInteractionView: UIView?
    private weak var interaction: UIPointerInteraction?

    init(
        view: UIView,
        customInteractionView: UIView? = nil,
        style: TiebaPointerStyle = .default,
        willEnter: @escaping () -> Void = {},
        willExit: @escaping () -> Void = {}
    ) {
        self.style = style
        self.willEnter = willEnter
        self.willExit = willExit
        self.customInteractionView = customInteractionView
        super.init()

        let interaction = UIPointerInteraction(delegate: self)
        view.addInteraction(interaction)
        self.interaction = interaction
    }

    // 上游 PointerInteractionImpl.deinit 同款：交互对象不是自动回收的。
    //（Swift 6 的 isolated deinit，先例见 UI/Drawing/TiebaPortalSourceView.swift:104。）
    isolated deinit {
        if let interaction = self.interaction {
            interaction.view?.removeInteraction(interaction)
        }
    }

    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        guard let interactionView = self.customInteractionView ?? interaction.view else {
            return nil
        }
        let targetedPreview = UITargetedPreview(view: interactionView)
        let scale = interactionView.contentScaleFactor
        func rounded(_ value: CGFloat) -> CGFloat {
            return TiebaNodesGraphics.floorToScreenPixels(value, scale: scale)
        }
        func shapeRect(size: CGSize) -> CGRect {
            return CGRect(
                origin: CGPoint(
                    x: rounded(targetedPreview.view.center.x - size.width / 2.0),
                    y: rounded(targetedPreview.view.center.y - size.height / 2.0)
                ),
                size: size
            )
        }

        switch self.style {
        case .default:
            let horizontalPadding: CGFloat = 10.0
            let verticalPadding: CGFloat = 4.0
            let minHeight: CGFloat = 40.0
            let size = CGSize(
                width: targetedPreview.size.width + horizontalPadding * 2.0,
                height: max(minHeight, targetedPreview.size.height + verticalPadding * 2.0)
            )
            return UIPointerStyle(
                effect: .highlight(targetedPreview),
                shape: .roundedRect(shapeRect(size: size), radius: UIPointerShape.defaultCornerRadius)
            )
        case let .insetRectangle(horizontal, vertical):
            let size = CGSize(
                width: targetedPreview.size.width - horizontal * 2.0,
                height: targetedPreview.size.height - vertical * 2.0
            )
            return UIPointerStyle(
                effect: .highlight(targetedPreview),
                shape: .roundedRect(shapeRect(size: size), radius: UIPointerShape.defaultCornerRadius)
            )
        case let .rectangle(size):
            return UIPointerStyle(
                effect: .highlight(targetedPreview),
                shape: .roundedRect(shapeRect(size: size), radius: UIPointerShape.defaultCornerRadius)
            )
        case let .circle(diameter):
            let finalDiameter = diameter ?? max(targetedPreview.size.width, targetedPreview.size.height)
            let rect = CGRect(
                origin: CGPoint(
                    x: rounded(targetedPreview.view.center.x - finalDiameter / 2.0),
                    y: rounded(targetedPreview.view.center.y - finalDiameter / 2.0)
                ),
                size: CGSize(width: finalDiameter, height: finalDiameter)
            )
            return UIPointerStyle(effect: .highlight(targetedPreview), shape: .path(UIBezierPath(ovalIn: rect)))
        case .caret:
            return UIPointerStyle(shape: .verticalBeam(length: 24.0), constrainedAxes: .vertical)
        case .lift:
            return UIPointerStyle(effect: .lift(targetedPreview))
        case .hover:
            return UIPointerStyle(
                effect: .hover(targetedPreview, preferredTintMode: .none, prefersShadow: false, prefersScaledContent: false)
            )
        }
    }

    func pointerInteraction(_ interaction: UIPointerInteraction, willEnter region: UIPointerRegion, animator: UIPointerInteractionAnimating) {
        guard interaction.view != nil else {
            return
        }
        let willEnter = self.willEnter
        animator.addAnimations {
            willEnter()
        }
    }

    func pointerInteraction(_ interaction: UIPointerInteraction, willExit region: UIPointerRegion, animator: UIPointerInteractionAnimating) {
        guard interaction.view != nil else {
            return
        }
        let willExit = self.willExit
        animator.addAnimations {
            willExit()
        }
    }
}
