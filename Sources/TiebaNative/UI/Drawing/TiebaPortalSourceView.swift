// 移植自上游: submodules/Display/Source/PortalSourceView.swift :1-88
//   （关联上游文件：PortalView.swift / GlobalPortalView.swift，说明见下）
//
// ⚠️ 重要限制（先说清楚，别当成完整移植）：
//   上游 PortalSourceView 的搭档 PortalView **用了私有 API**，按铁律 4 / 与本仓 TiebaUIKitUtils.swift
//   对私有 API 的处理先例，**不移植**。证据（上游源码逐行可查）：
//     submodules/UIKitRuntimeUtils/Source/UIKitRuntimeUtils/UIKitUtils.m:211-230
//       `makePortalView()` 用 NSClassFromString 拼出私有类 "_UIPortalView"，
//       并设置私有属性 forwardsClientHitTestingToSourceView / matchesPosition / matchesTransform；
//     submodules/Display/Source/PortalView.swift:5 的 \`UIView & UIKitPortalViewProtocol\` 也来自那个 ObjC 模块。
//   所以本文件移植的是 **PortalSourceView 的引用簿记与生命周期**（这部分的逻辑是完整的、可用的），
//   把「真正做 portal 的那个视图」抽象成 \`TiebaPortalHosting\` 协议，由调用方注入实现（工厂注入）。
//   将来若真有需要，注入方可以自行决定用私有 _UIPortalView 还是 public 替代方案（如 iOS 17 的
//   \`UIView\` snapshot / \`UIPortalView\` 的公开等价物），本文件不需要再改。
//
// 找不到上游文件的条目：无（PortalView.swift / GlobalPortalView.swift 都找到了，见上面的限制说明）。
//
// 改动（逐条）：
//   1. PortalSourceView → TiebaPortalSourceView（UIView 子类，上游本来就是 UIView）。
//   2. PortalView / GlobalPortalView → 协议 TiebaPortalHosting / TiebaGlobalPortalHosting。
//      上游 GlobalPortalView 是 \`final class GlobalPortalView: PortalView\` + \`wasRemoved\` 闭包 +
//      \`triggerWasRemoved()\`，这里把后者收进协议（\`triggerWasRemoved\`），语义不变。
//   3. \`UIView.windowHost\`（WindowContent.swift:211-219，返回上游 WindowHost 协议）→
//      本文件私有的 \`tiebaGlobalPortalWindowHost\`，只要求 window 实现
//      \`addGlobalPortalHostView(sourceView:)\` 这一个方法（上游 WindowHost 有 8 个方法，
//      为了这一处调用把整套呈现体系拖进来不值得）。
//      上游找不到 window 时会 findWindow(self) 递归找；本仓没有那个 helper，只查 self.window
//      —— needsGlobalPortal 的用法都是「已上屏的视图」，这个差别在文档里说明，不悄悄吞掉。
//   4. \`deinit\` 里的 \`triggerWasRemoved()\` 保留（并标 \`isolated deinit\`，见方法上的注释）：
//      视图销毁时要让宿主回收整窗 portal，否则会留下一个孤儿宿主视图。
//   5. Swift 6：UIView 子类天然 @MainActor；两个协议都标 @MainActor（它们的实现必然是视图层）。
//      没有任何 @preconcurrency / nonisolated(unsafe) / @unchecked Sendable。

import Foundation
import UIKit

/// 上游 PortalView.swift:4-36 去掉私有 API 之后剩下的一组操作。
/// @MainActor：与文件头第 5 条一致 —— 实现必然是视图层（layer/contents），
/// 不标的话视图层的实现会变成"跨隔离域的 conformance"（Swift 6 直接报错）。
@MainActor
protocol TiebaPortalHosting: AnyObject {
    /// 上游 PortalView.reloadPortal(sourceView:)：绑定源视图并刷新呈现。
    func reloadPortal(sourceView: UIView)
    /// 上游 PortalView.disablePortal()。
    func disablePortal()
}

/// 上游 GlobalPortalView.swift:3-18。
@MainActor
protocol TiebaGlobalPortalHosting: TiebaPortalHosting {
    /// 上游 GlobalPortalView.triggerWasRemoved()：宿主替换/销毁时回调，用于回收。
    func triggerWasRemoved()
}

/// 上游 \`WindowHost.addGlobalPortalHostView(sourceView:)\` 这一条方法的最小面（见文件头第 3 条）。
protocol TiebaGlobalPortalWindowHost: AnyObject {
    func addGlobalPortalHostView(sourceView: TiebaPortalSourceView)
}

private extension UIView {
    var tiebaGlobalPortalWindowHost: (any TiebaGlobalPortalWindowHost)? {
        return self.window as? (any TiebaGlobalPortalWindowHost)
    }
}

final class TiebaPortalSourceView: UIView {
    /// 弱引用包装：portal 视图的生命周期由外部持有，源视图只做登记。
    private final class PortalReference {
        weak var portalView: (any TiebaPortalHosting)?

        init(portalView: any TiebaPortalHosting) {
            self.portalView = portalView
        }
    }

    private var portalReferences: [PortalReference] = []
    private weak var globalPortalView: (any TiebaGlobalPortalHosting)?

    /// 是否需要「整窗级」portal（用于跨层级呈现，例如从 cell 里浮到 window 上）。
    /// 打开时自身 alpha 归零（内容由整窗 portal 呈现），关闭时恢复。
    var needsGlobalPortal: Bool = false {
        didSet {
            if self.needsGlobalPortal != oldValue {
                if self.needsGlobalPortal {
                    self.alpha = 0.0

                    if let windowHost = self.tiebaGlobalPortalWindowHost {
                        windowHost.addGlobalPortalHostView(sourceView: self)
                    }
                } else {
                    self.alpha = 1.0

                    if let globalPortalView = self.globalPortalView {
                        self.globalPortalView = nil

                        globalPortalView.triggerWasRemoved()
                    }
                }
            }
        }
    }

    // [移植] Swift 6 的必需改动：`globalPortalView` 是非 Sendable 的协议存在类型，
    // 而 nonisolated deinit 不允许读它（编译报 "cannot access property ... from nonisolated deinit"）。
    // 解法是 `isolated deinit`（SE-0371，Swift 6.1+，本仓工具链 Swift 6.4）：
    // deinit 本体在主 actor 上执行 —— 对 UIView 来说这本来就是它该有的语义。
    // 这不是绕过（不是 @unchecked / assumeIsolated / nonisolated(unsafe)），是编译器给的正式写法。
    isolated deinit {
        // 上游同款：视图没了，整窗 portal 也要撤掉。
        if let globalPortalView = self.globalPortalView {
            globalPortalView.triggerWasRemoved()
        }
    }

    func addPortal(view: any TiebaPortalHosting) {
        self.portalReferences.append(PortalReference(portalView: view))
        // 未上屏时先不绑：didMoveToWindow 里会补绑，避免拿到 nil window 的白帧。
        if self.window != nil {
            view.reloadPortal(sourceView: self)
        }
    }

    func removePortal(view: any TiebaPortalHosting) {
        if let index = self.portalReferences.firstIndex(where: { $0.portalView === view }) {
            self.portalReferences.remove(at: index)
        }
        view.disablePortal()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()

        if self.window != nil {
            for portalReference in self.portalReferences {
                if let portalView = portalReference.portalView {
                    portalView.reloadPortal(sourceView: self)
                }
            }

            if self.needsGlobalPortal, self.globalPortalView == nil, let windowHost = self.tiebaGlobalPortalWindowHost {
                windowHost.addGlobalPortalHostView(sourceView: self)
            }
        }
    }
}
