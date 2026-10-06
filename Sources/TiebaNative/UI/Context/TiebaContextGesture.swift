// TiebaContextGesture —— 自研上下文菜单长按手势。
//
// 移植自上游 submodules/Display/Source/ContextGesture.swift（上游 280 行）。
//
// 【接线状态】已接线：UI/Components/TiebaSearchHistoryView.swift 的
//   TiebaPillCloudView.setPills 用 TiebaContextControllerSourceView 包住每颗搜索历史药丸，
//   长按由本手势驱动 0→1 的激活进度（药丸绕内容中点缩放），走满 1 才触发删除回调。
//
// 与系统 UIContextMenuInteraction 的关系（不要据此推翻上面的接线）：
//   · Sources/TiebaNative/UI/ListKit/TiebaFeedRowView.swift:556-666 与
//     UI/ListKit/TiebaPostRowView.swift:1626-1745 已经是完整的系统 UIContextMenuInteraction
//     （UITargetedPreview 锚点、新旧协议名双实现、升起触觉、收起不飞回）——那里的行仍走系统菜单。
//   · docs/uikit-migration/10-页面壳与交互层.md 的 R3：ContextGesture 与系统
//     UIContextMenuInteraction 不可同视图共存（两套长按准入会互相抢手势）。
//   ⇒ 本手势只挂在**没有**系统菜单的落点上（现在是搜索历史药丸）；不要挂到带系统菜单的视图。
//     它的价值是算法本身：0.12s 起手定时 + DisplayLink 驱动 0→1 的激活进度 +
//     激活瞬间递归杀光兄弟/父链手势。
//
// 逐条编号列出改动（相对上游 ContextGesture.swift）：
//   1) 符号加 Tieba 前缀：ContextGesture → TiebaContextGesture、ContextGestureTransition →
//      TiebaContextGestureTransition、cancelParentGestures → tiebaCancelParentGestures、
//      cancelOtherGestures → tiebaCancelOtherGestures（私有）。避免与其它目录的同名移植撞名。
//   2) 删去 AsyncDisplayKit 依赖（本仓纯 UIKit，无 ASDisplayNode）：
//      · cancelParentGestures 里 `(view as? ListViewBackingView)?.target.cancelSelection()`；
//      · `view.asyncdisplaykit_node as? HighlightTrackingButtonNode` 的 higligthedChanged(false)；
//      · cancelOtherGestures 里 `ListViewTapGestureRecognizer` 分支。
//      前两者依赖 ListView 引擎（本仓列表是 UICollectionView，无此概念）；第三者的语义
//      已由保留的 UITapGestureRecognizer 分支（.possible → .failed）覆盖。
//   3) 删去 `if #available(iOS 9.0, *)`（部署底线 iOS 26，恒可用）。
//   4) Swift 6 严格并发正统化（未用任何 @preconcurrency / nonisolated(unsafe) /
//      @unchecked Sendable / MainActor.assumeIsolated，也没有降 swift 版本）：
//      a) UIGestureRecognizer 在 SDK 里已是 @MainActor，子类自动继承隔离域，本类无需显式标注；
//      b) 两个文件级自由函数显式标 @MainActor —— 它们直接读写 UIView 与
//         UIGestureRecognizer.state，本来就是主线程代码；
//      c) Timer 的 target 包装类标 @MainActor —— 它把「主 actor 闭包」交给主 RunLoop 调用；
//         不标则把 @MainActor 闭包存进非隔离的 (() -> Void) 属性会丢全局 actor；
//      d) 手势内部代理类标 @MainActor —— UIGestureRecognizerDelegate 在 SDK 里即主 actor 协议。
//   5) 进度驱动复用本仓已有的 Core/TiebaDisplayLinkAnimator.swift（= 上游 SharedDisplayLinkDriver
//      + DisplayLinkAnimator 的等价物），调用形式与上游一字不差：
//      TiebaDisplayLinkAnimator(duration: 0.2, from: 0.0, to: 1.0, update:completion:)。
//   6) 除上述以外逐行保留：beginDelay = 0.12 / activateOnTap / 左缘 8pt 让位 /
//      force ≥ max(2.5, min(3.0, maximumPossibleForce)) 直接激活 / touchesEnded 的两个分支 /
//      touchesCancelled / reset / cancel / endPressedAppearance 的每个 if 都与上游一致，
//      未做任何「优化」或分支合并。

import UIKit

/// 上游 `ContextGestureTransition` 的直译。
/// `begin` = 0.12s 定时到点那一刻（此时进度 0）；`update` = DisplayLink 每帧推进；
/// `ended` 携带「结束前的进度」，调用方拿它当回弹动画的起点。
public enum TiebaContextGestureTransition {
    case begin
    case update
    case ended(CGFloat)
}

// [移植 4c] 上游是 `private class TimerTargetWrapper: NSObject`（无隔离标注，Swift 5 语义）。
// Swift 6：闭包体访问的状态全在主 actor（本文件的手势类继承 UIGestureRecognizer 的 @MainActor），
// 包装类必须同域，否则 `@MainActor () -> Void` 存进非隔离属性会报「loses global actor」。
// 标 @MainActor 不改变运行时行为：Timer 由主 RunLoop 驱动，回调本来就在主线程。
@MainActor
private final class TiebaContextGestureTimerTarget: NSObject {
    private let f: () -> Void

    init(_ f: @escaping () -> Void) {
        self.f = f
    }

    @objc func timerEvent() {
        self.f()
    }
}

/// 上游 `cancelParentGestures(view:ignore:)` 的直译（去掉 AsyncDisplayKit 的两个分支，见文件头 2）。
/// 作用：激活上下文菜单的一瞬间，沿 superview 链把沿途所有手势识别器（除自己）全部置为 failed，
/// 否则父级 scrollView 的 pan / 单元格的 tap 会在菜单已经弹出后继续响应，出现「菜单和滚动同时在动」。
// [移植 4b] 显式 @MainActor：直接读写 UIView.gestureRecognizers 与 UIGestureRecognizer.state。
@MainActor
public func tiebaCancelParentGestures(view: UIView, ignore: [UIGestureRecognizer] = []) {
    if let gestureRecognizers = view.gestureRecognizers {
        for recognizer in gestureRecognizers {
            if ignore.contains(where: { $0 === recognizer }) {
                continue
            }
            recognizer.state = .failed
        }
    }
    if let superview = view.superview {
        tiebaCancelParentGestures(view: superview, ignore: ignore)
    }
}

/// 上游 `cancelOtherGestures(gesture:view:)` 的直译（去掉 ListViewTapGestureRecognizer 分支）。
/// 从 window 起递归整棵视图树：兄弟 ContextGesture 走 cancel()（带进度回弹），
/// 还没开始识别的 UITapGestureRecognizer 直接 .failed（已开始的不动，避免打断用户已认可的手势）。
@MainActor
private func tiebaCancelOtherGestures(gesture: TiebaContextGesture, view: UIView) {
    if let gestureRecognizers = view.gestureRecognizers {
        for recognizer in gestureRecognizers {
            if let recognizer = recognizer as? TiebaContextGesture, recognizer !== gesture {
                recognizer.cancel()
            } else if let recognizer = recognizer as? UITapGestureRecognizer {
                switch recognizer.state {
                case .possible:
                    recognizer.state = .failed
                default:
                    break
                }
            }
        }
    }
    for subview in view.subviews {
        tiebaCancelOtherGestures(gesture: gesture, view: subview)
    }
}

// [移植 4d] 上游 `private final class InternalGestureRecognizerDelegate`。
// 唯一职责：禁止与 UIPanGestureRecognizer 同时识别（长按激活期间不能让列表跟着滚），
// 其余手势允许并存。@MainActor 与 SDK 里 UIGestureRecognizerDelegate 的隔离域一致。
@MainActor
private final class TiebaContextGestureInternalDelegate: NSObject, UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        if otherGestureRecognizer is UIPanGestureRecognizer {
            return false
        }
        return true
    }
}

/// 上游 `ContextGesture` 的直译：一个「长按 0.12s 起手 → DisplayLink 推进激活进度 → 到 1 时
/// 自己转 .began 并杀光别人」的 UIGestureRecognizer。
/// 与系统 UILongPressGestureRecognizer 的关键差异：它把 0→1 的中间进度（0.2s 内）通过
/// `activationProgress` 暴露出来，调用方据此对源视图做「绕内容中点缩放」的连续变形——
/// 这正是 上游 上下文菜单预览会"长出来"而不是"跳出来"的原因。
// [移植 4a] 不显式标 @MainActor：UIGestureRecognizer 已是 @MainActor，子类自动继承。
public final class TiebaContextGesture: UIGestureRecognizer, UIGestureRecognizerDelegate {
    private let internalDelegate = TiebaContextGestureInternalDelegate()

    /// 起手延时。默认 0.12s：比系统长按（0.5s）短得多，因为进度条本身还要 0.2s 才走到 1。
    public var beginDelay: Double = TiebaMotionSpec.Gesture.longPressBeginDelay
    /// 为 true 时，未激活的轻点也会回调 activatedAfterCompletion(_, true)（长按菜单里"点一下菜单外"用）。
    public var activateOnTap: Bool = false
    private var currentProgress: CGFloat = 0.0
    private var delayTimer: Timer?
    private var animator: TiebaDisplayLinkAnimator?
    private var isValidated: Bool = false
    private var wasActivated: Bool = false

    public var shouldBegin: ((CGPoint) -> Bool)?
    public var activationProgress: ((CGFloat, TiebaContextGestureTransition) -> Void)?
    public var activated: ((TiebaContextGesture, CGPoint) -> Void)?
    public var externalUpdated: ((UIView?, CGPoint) -> Void)?
    public var externalEnded: (((UIView?, CGPoint)?) -> Void)?
    public var activatedAfterCompletion: ((CGPoint, Bool) -> Void)?
    public var cancelGesturesOnActivation: (() -> Void)?

    public override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)

        self.delegate = self.internalDelegate
    }

    public override func reset() {
        super.reset()

        self.endPressedAppearance()

        self.currentProgress = 0.0
        self.delayTimer?.invalidate()
        self.delayTimer = nil
        self.isValidated = false
        self.externalUpdated = nil
        self.externalEnded = nil
        self.animator?.invalidate()
        self.animator = nil
        self.wasActivated = false
    }

    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)

        guard let touch = touches.first else {
            return
        }
        let location = touch.location(in: self.view)

        if let shouldBegin = self.shouldBegin {
            if !shouldBegin(location) {
                self.state = .failed
                return
            }
        }

        // 屏幕左缘 8pt 让位：系统返回手势（interactivePopGestureRecognizer）优先，
        // 否则在左边缘长按会同时触发"返回上一页"和上下文菜单。
        let windowLocation = touch.location(in: nil)
        if windowLocation.x < TiebaMotionSpec.Gesture.leftEdgeReserved {
            self.state = .failed
            return
        }

        // 起手定时只装一次：0.12s 到点才置 isValidated 并启动 0.2s 的进度动画。
        // 到点前抬手 → touchesEnded 里 invalidate，什么都没有发生（这就是"轻点不弹菜单"）。
        if self.delayTimer == nil {
            let delayTimer = Timer(timeInterval: self.beginDelay, target: TiebaContextGestureTimerTarget { [weak self] in
                guard let strongSelf = self, let _ = strongSelf.delayTimer else {
                    return
                }
                strongSelf.isValidated = true
                if strongSelf.animator == nil {
                    strongSelf.animator = TiebaDisplayLinkAnimator(duration: TiebaMotionSpec.Gesture.longPressActivation, from: 0.0, to: 1.0, update: { value in
                        guard let strongSelf = self else {
                            return
                        }
                        if strongSelf.isValidated {
                            strongSelf.currentProgress = value
                            strongSelf.activationProgress?(value, .update)
                        }
                    }, completion: {
                        guard let strongSelf = self else {
                            return
                        }
                        // 进度走满 1.0：此刻才真正"激活"（state 从 .possible → .began）。
                        // 若中途已被取消/抬手（state != .possible），什么都不做。
                        switch strongSelf.state {
                        case .possible:
                            strongSelf.delayTimer?.invalidate()
                            strongSelf.animator?.invalidate()
                            strongSelf.activated?(strongSelf, location)
                            strongSelf.wasActivated = true
                            if let view = strongSelf.view {
                                if let window = view.window {
                                    // 先杀全 window 的兄弟手势（含其它行的 ContextGesture），
                                    // 再给调用方一个额外钩子，最后沿父链杀上去。
                                    tiebaCancelOtherGestures(gesture: strongSelf, view: window)
                                }
                                strongSelf.cancelGesturesOnActivation?()
                                tiebaCancelParentGestures(view: view, ignore: [strongSelf])
                            }
                            strongSelf.state = .began
                        default:
                            break
                        }
                    })
                }
                // .begin 用当前进度（通常是 0）通知调用方，让缩放从"当前值"开始而不是硬跳。
                strongSelf.activationProgress?(strongSelf.currentProgress, .begin)
            }, selector: #selector(TiebaContextGestureTimerTarget.timerEvent), userInfo: nil, repeats: false)
            self.delayTimer = delayTimer
            RunLoop.main.add(delayTimer, forMode: .common)
        }
    }

    public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)

        if let touch = touches.first {
            // 3D Touch / Haptic Touch 的按压力度：达到阈值就直接激活，不等 0.12s + 0.2s。
            // 上限 3.0 / 下限 2.5 是为不同机型（maximumPossibleForce 各不相同）归一化。
            // [移植 3] 上游这里套了 if #available(iOS 9.0, *)；部署底线 iOS 26，已删。
            let maxForce: CGFloat = max(2.5, min(3.0, touch.maximumPossibleForce))
            if touch.force >= maxForce {
                if !self.isValidated {
                    self.isValidated = true
                }

                switch self.state {
                case .possible:
                    self.delayTimer?.invalidate()
                    self.animator?.invalidate()
                    self.activated?(self, touch.location(in: self.view))
                    self.wasActivated = true
                    // 注意上游这里用的是 self.view?.superview，而定时激活那条路径传的是 self.view
                    // 且把自己放进 ignore。两者等价：cancelParentGestures 只处理「起点及其祖先」上的
                    // 识别器，从 superview 起就等于「self.view 减去被 ignore 的自己」。
                    if let view = self.view?.superview {
                        if let window = view.window {
                            tiebaCancelOtherGestures(gesture: self, view: window)
                        }
                        tiebaCancelParentGestures(view: view)
                    }
                    self.state = .began
                default:
                    break
                }
            }

            // 无论是否激活，都把移动事件透给调用方（菜单展开后的"手指移到某项上"靠它）。
            self.externalUpdated?(self.view, touch.location(in: self.view))
        }
    }

    public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)

        if let touch = touches.first {
            if !self.currentProgress.isZero, self.isValidated {
                // 进度动画进行到一半抬手指：进度归零并让调用方回弹。
                // 注意上游顺序——先把 currentProgress 置 0，再把 0 作为"结束进度"传出去，
                // 所以 .ended 的关联值永远是 0.0（这与 touchesCancelled/cancel 传上一个进度不同）。
                self.currentProgress = 0.0
                self.activationProgress?(0.0, .ended(self.currentProgress))
                if self.wasActivated {
                    self.activatedAfterCompletion?(touch.location(in: self.view), false)
                }
            } else {
                self.currentProgress = 0.0
                // 从未激活过的轻点：activateOnTap 才回调（第二参数 true = 这是一次"点击"而非"长按完成"）。
                if !self.wasActivated && self.activateOnTap {
                    self.activatedAfterCompletion?(touch.location(in: self.view), true)
                }
            }

            self.externalEnded?((self.view, touch.location(in: self.view)))
        }

        self.delayTimer?.invalidate()
        self.animator?.invalidate()

        // 长按手势抬手即 .failed：一次触摸只允许弹一次菜单，复位后必须重新走 0.12s。
        self.state = .failed
    }

    public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)

        if let _ = touches.first, !self.currentProgress.isZero, self.isValidated {
            // 与 touchesEnded 不同：这里把"取消前的进度"传出去（回弹动画要知道从哪开始缩）。
            let previousProgress = self.currentProgress
            self.currentProgress = 0.0
            self.activationProgress?(0.0, .ended(previousProgress))
        }

        self.delayTimer?.invalidate()
        self.animator?.invalidate()

        self.state = .failed
    }

    /// 被别的 ContextGesture 激活时调用（见 tiebaCancelOtherGestures）：带进度回弹地取消自己。
    public func cancel() {
        if !self.currentProgress.isZero, self.isValidated {
            let previousProgress = self.currentProgress
            self.currentProgress = 0.0
            self.activationProgress?(0.0, .ended(previousProgress))

            self.delayTimer?.invalidate()
            self.animator?.invalidate()
            self.state = .failed
        } else {
            self.state = .failed
        }
    }

    /// 只收掉"按下外观"（进度回弹到 0），但不改 state —— 用于菜单已弹出后想让源视图恢复原状的场合。
    public func endPressedAppearance() {
        if !self.currentProgress.isZero, self.isValidated {
            let previousProgress = self.currentProgress
            self.currentProgress = 0.0
            self.delayTimer?.invalidate()
            self.animator?.invalidate()
            self.isValidated = false
            self.activationProgress?(0.0, .ended(previousProgress))
        }
    }
}
