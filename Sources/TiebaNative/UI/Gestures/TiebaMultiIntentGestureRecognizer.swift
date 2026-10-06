// 移植自上游 submodules/Display/Source/TapLongTapOrDoubleTapGestureRecognizer.swift（13KB）。
// 本次按**思路**重写，不照搬上游的业务回调（上游把"聊天背景/头像/消息气泡"的判定塞在识别器里）。
//
// 📚 这份代码的 UIKit 学习价值：**一个区域上并存四种意图时，靠 \`require(toFail:)\` 拼不出正确语义**。
//   系统给的是三个独立识别器（tap / doubleTap / longPress），它们的组合只能表达"谁等谁"，
//   表达不了：单击要**延迟确认**（等双击窗口过去）、长按要**等够时长**、拖动要**取消**前面所有意图、
//   以及"先高亮、后取消"这种**中间态**。所以上游自己写了一个识别器 + 一个显式状态机。
//
// 设计（最简优先，见任务铁律 3）：
//   · **裁定逻辑是纯结构体** \`TiebaMultiIntentGestureMachine\`：输入"带时间戳的事件"，输出"意图"。
//     它不碰 UIKit，所以能在模拟器里直接跑断言（这是本次"可复现验证"的落点）。
//   · 识别器子类只做三件事：把 touch 事件翻译成机器事件、按 display link 驱动 \`tick\`（长按/延迟确认靠它到期）、
//     把产出的意图发给回调。
//   · 用本仓唯一的 \`TiebaSharedDisplayLinkDriver\` 做 tick 源（不新开 CADisplayLink，见该文件说明）。
//
// 意图（对外最少必要集）：
//   highlight(Bool) —— 按下/取消高亮（调用方拿它做按压反馈）
//   singleTap       —— 确认后的单击（等过双击窗口才发出）
//   doubleTap       —— 双击
//   longPress       —— 长按成立（可紧接着跟拖动）
//   dragBegan/Moved/Ended —— 长按之后继续拖动（"长按拖动"），或直接拖动取消点击
//   cancelled       —— 全部作废（系统取消/超时/移出容差）
//
// Swift 6：机器是 Sendable 值类型；识别器是 UIGestureRecognizer 子类（天然 @MainActor）。
// 没有 @preconcurrency / nonisolated(unsafe) / @unchecked Sendable / assumeIsolated。

import Foundation
import UIKit
import CoreGraphics

// MARK: - 意图

enum TiebaGestureIntent: Equatable {
    /// 按压反馈（true = 按下，false = 松开/取消）。上游的 highlight 中间态。
    case highlight(Bool)
    /// 确认后的单击（**延迟**到双击窗口结束才发，这是与系统 tap 最大的区别）。
    case singleTap
    case doubleTap
    /// 长按成立。
    case longPress
    /// 长按成立之后的拖动（"长按拖动"）。
    case dragBegan(CGPoint)
    case dragMoved(CGPoint, translation: CGPoint)
    case dragEnded(CGPoint)
    /// 系统取消或移出容差。
    case cancelled
}

// MARK: - 裁定状态机（纯逻辑，可测）

struct TiebaMultiIntentGestureMachine {
    /// 长按判定时长（上游默认 0.4s 量级；系统 UILongPressGestureRecognizer 默认 0.5s）。
    var longPressDuration: TimeInterval = 0.4
    /// 双击窗口：第一次单击后等这么久没有第二次，才确认为单击。
    /// **这就是"延迟确认"** —— 不延迟的话，双击的第一下会立刻触发单击动作（例如查看器立刻关闭）。
    var doubleTapInterval: TimeInterval = 0.3
    /// 长按成立前允许的位移；超过就认为用户在拖动/滚动，取消一切点击意图。
    var cancelTolerance: CGFloat = 10

    /// 只做单击的瘦模式：**不产 doubleTap / longPress / drag**，只产 singleTap 与 cancelled。
    /// 用途：调用方已用别的识别器承担双击时（查看器的框架 doubleTapGesture 管缩放），
    /// 再让本件认双击就是两个识别器抢同一件事。
    enum Mode: Equatable {
        case multiIntent
        case tapOnly
    }

    var mode: Mode = .multiIntent
    /// 仅 .tapOnly 用：按住超过它就作废。**这是替换 TiebaUniversalTapRecognizer 的 0.15s 上限**：
    /// 查看器里长按会弹系统菜单，菜单弹出后抬手不该再触发一次单击（chrome 会闪一下）。
    var maximumTapDuration: TimeInterval = 0.15

    private enum Phase: Equatable {
        case idle
        /// 手指按下，尚未判定。
        case pressing(origin: CGPoint, startTime: TimeInterval)
        /// 长按已成立，进入可拖动状态。
        case longPressed(origin: CGPoint, current: CGPoint)
        /// 一次单击已抬手，正在等双击窗口。
        case awaitingSecondTap(firstTapTime: TimeInterval)
    }

    private var phase: Phase = .idle

    /// 供识别器判断"是否需要 tick"（只有 pressing / awaitingSecondTap 需要到期判定）。
    var needsTick: Bool {
        switch self.phase {
            case .pressing, .awaitingSecondTap: return true
            case .idle, .longPressed: return false
        }
    }

    mutating func began(at point: CGPoint, time: TimeInterval) -> [TiebaGestureIntent] {
        switch self.phase {
            case .idle:
                self.phase = .pressing(origin: point, startTime: time)
                // tapOnly 不发按压反馈（被它替换的 TiebaUniversalTapRecognizer 也不发，观感不变）。
                if self.mode == .tapOnly {
                    return []
                }
                // 按下**立刻**高亮：延迟高亮是另一个手法（HighlightableButton），这里不混进来。
                return [.highlight(true)]
            case .awaitingSecondTap:
                // 双击的第二下：立刻成立（不必等抬手 —— 与系统一致，手感更跟手）。
                self.phase = .idle
                return [.doubleTap]
            case .pressing, .longPressed:
                // 理论上不该发生（识别器保证一次只跟一个手指）；保守当作重新开始。
                self.phase = .pressing(origin: point, startTime: time)
                return [.highlight(true)]
        }
    }

    mutating func moved(to point: CGPoint, time: TimeInterval) -> [TiebaGestureIntent] {
        switch self.phase {
            case let .pressing(origin, startTime):
                let distance = hypot(point.x - origin.x, point.y - origin.y)
                if distance > self.cancelTolerance {
                    // 超容差 = 用户在滚动或拖动：点击/长按意图全部作废（否则滚动时手指略动就会误触发）。
                    self.phase = .idle
                    return [.cancelled]
                }
                // 超时长按：不抬手也算成立（这正是需要 tick 的原因）。tapOnly 下没有长按，直接返回。
                if self.mode == .multiIntent, time - startTime >= self.longPressDuration {
                    self.phase = .longPressed(origin: origin, current: point)
                    return [.longPress]
                }
                return []
            case let .longPressed(origin, _):
                self.phase = .longPressed(origin: origin, current: point)
                return [.dragMoved(point, translation: CGPoint(x: point.x - origin.x, y: point.y - origin.y))]
            case .idle, .awaitingSecondTap:
                return []
        }
    }

    mutating func ended(at point: CGPoint, time: TimeInterval) -> [TiebaGestureIntent] {
        switch self.phase {
            case let .pressing(_, startTime):
                self.phase = .idle
                if self.mode == .tapOnly {
                    // 抬手即确认单击：双击互斥已由调用方的 require(toFail:) 承担，这里**不再等窗口**，
                    // 否则会把 chrome 的显隐再推迟一个双击窗口（观感变化）。
                    return time - startTime <= self.maximumTapDuration ? [.singleTap] : [.cancelled]
                }
                if time - startTime >= self.longPressDuration {
                    // 按住很久但一直没动、抬手才判定：长按成立 + 结束（调用方通常弹菜单）。
                    return [.highlight(false), .longPress, .cancelled]
                }
                // 抬手在双击窗口内：不立刻给单击，先记下来等窗口过去（延迟确认）。
                self.phase = .awaitingSecondTap(firstTapTime: time)
                return [.highlight(false)]
            case .longPressed:
                self.phase = .idle
                return [.dragEnded(point), .highlight(false)]
            case .idle, .awaitingSecondTap:
                return []
        }
    }

    mutating func cancelled() -> [TiebaGestureIntent] {
        switch self.phase {
            case .idle:
                return []
            case .longPressed:
                self.phase = .idle
                return [.cancelled, .highlight(false)]
            case .pressing, .awaitingSecondTap:
                self.phase = .idle
                return [.cancelled, .highlight(false)]
        }
    }

    /// 到期判定（由识别器的 display link 驱动）。
    /// 两件事：① pressing 超时长按；② awaitingSecondTap 过了双击窗口 → 确认单击。
    mutating func tick(time: TimeInterval) -> [TiebaGestureIntent] {
        switch self.phase {
            case let .pressing(origin, startTime):
                if self.mode == .tapOnly {
                    // 按住超过上限：立刻作废（对齐旧件"超时置 .failed"的行为，按住期间就失效）。
                    if time - startTime > self.maximumTapDuration {
                        self.phase = .idle
                        return [.cancelled]
                    }
                    return []
                }
                if time - startTime >= self.longPressDuration {
                    self.phase = .longPressed(origin: origin, current: origin)
                    return [.longPress]
                }
                return []
            case let .awaitingSecondTap(firstTapTime):
                if time - firstTapTime >= self.doubleTapInterval {
                    self.phase = .idle
                    return [.singleTap]
                }
                return []
            case .idle, .longPressed:
                return []
        }
    }
}

// MARK: - 识别器（薄壳）

@MainActor
final class TiebaMultiIntentGestureRecognizer: UIGestureRecognizer {
    /// 意图回调（**一定是主线程**：识别器本身就是主 actor）。
    var onIntent: ((TiebaGestureIntent) -> Void)?

    private var machine = TiebaMultiIntentGestureMachine()

    /// 只做单击的瘦模式（查看器用：双击归框架 doubleTapGesture 管缩放），见 machine 的 .tapOnly。
    var mode: TiebaMultiIntentGestureMachine.Mode = .multiIntent {
        didSet {
            self.machine.mode = self.mode
            self.machine.maximumTapDuration = self.maximumTapDuration
        }
    }

    /// 仅 .tapOnly 用：按住超过它就作废。
    var maximumTapDuration: TimeInterval = 0.15 {
        didSet { self.machine.maximumTapDuration = self.maximumTapDuration }
    }
    private var link: (any TiebaSharedDisplayLinkDriverLink)?

    /// 只认一个手指：多指是缩放/旋转的地盘，不抢。
    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        self.cancelsTouchesInView = false
        self.delaysTouchesBegan = false
        self.delaysTouchesEnded = false
    }

    override func reset() {
        super.reset()
        self.stopTicking()
        self.machine = TiebaMultiIntentGestureMachine()
        // reset() 会换一台新机器：把配置重新灌进去（否则第二轮交互会退回默认模式）。
        self.machine.mode = self.mode
        self.machine.maximumTapDuration = self.maximumTapDuration
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard let touch = touches.first else {
            return
        }
        // 单击/双击/长按共用 .possible 状态：真正的判定在 machine 里，状态只用来让 UIKit 知道手势还活着。
        if self.state == .possible {
            self.state = .began
        }
        self.emit(self.machine.began(at: touch.location(in: self.view), time: touch.timestamp))
        self.startTickingIfNeeded()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard let touch = touches.first else {
            return
        }
        self.emit(self.machine.moved(to: touch.location(in: self.view), time: touch.timestamp))
        self.startTickingIfNeeded()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        let time = touches.first?.timestamp ?? CACurrentMediaTime()
        let point = touches.first?.location(in: self.view) ?? .zero
        self.emit(self.machine.ended(at: point, time: time))
        // 注意：这里**不把 state 置为 .ended** —— 单击还在等双击窗口，此时结束手势会让 UIKit
        // 认为这一轮交互已结束（后续第二下点击会被当成新一轮，双击就永远出不来）。
        // 状态在 tick 确认单击、或双击成立时才收尾。
        self.startTickingIfNeeded()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        self.emit(self.machine.cancelled())
        self.finishIfPossible()
    }

    // MARK: tick 驱动（用全仓唯一的共享 display link）

    private func startTickingIfNeeded() {
        guard self.machine.needsTick else {
            self.stopTicking()
            return
        }
        guard self.link == nil else {
            return
        }
        // 只在"需要到期判定"的时间窗内挂 display link：一次点击最多 0.4s，代价可忽略。
        self.link = TiebaSharedDisplayLinkDriver.shared.add(framesPerSecond: .fps(60)) { [weak self] _ in
            self?.tick()
        }
    }

    private func stopTicking() {
        self.link?.invalidate()
        self.link = nil
    }

    private func tick() {
        let intents = self.machine.tick(time: CACurrentMediaTime())
        self.emit(intents)
        if !self.machine.needsTick {
            self.stopTicking()
            self.finishIfPossible()
        }
    }

    /// 一轮交互真正结束：让手势回到 .possible（否则后续 touch 不再进 touchesBegan）。
    private func finishIfPossible() {
        self.stopTicking()
        if self.state == .began || self.state == .changed {
            self.state = .ended
        }
        self.state = .possible
    }

    private func emit(_ intents: [TiebaGestureIntent]) {
        for intent in intents {
            self.onIntent?(intent)
        }
    }

    isolated deinit {
        // [移植] isolated deinit：link 是 MainActor 隔离的非 Sendable 句柄，nonisolated deinit 读不到。
        self.link?.invalidate()
    }
}
