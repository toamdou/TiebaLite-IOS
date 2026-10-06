// 移植自上游 submodules/TextSelectionNode/Sources/TextSelectionNode.swift（上游 850 行里的 :15-199 段）。
//
// 本文件 = 选择手势识别器 + 两个视图树工具函数。属于「上游式显示效果」的第一块：
// 长按出选择、按手柄拖动改选，是系统 UITextView 之外唯一能做到"逐行选择高亮 + 自绘手柄"的路径。
//
// 改动清单：
//   1) 类型名加 Tieba 前缀（TiebaTextSelectionGestureRecognizer）；Knob 私有枚举原样。
//   2) 长按计时器保持上游的 Timer + NSObject 目标写法（TimerTarget）：Timer 的 block 版在 Swift 6 里
//      要求 @Sendable 闭包，而回调要访问 MainActor 的识别器状态；用 target/selector 既避开这条，
//      也与上游逐行一致（不要在识别器里引入 fallback 计时路径）。
//   3) 上游这里没有异步/兜底分支，逐行照搬；两个工具函数（findScrollView / cancelScrollViewGestures）
//      保持文件私有，语义不变（拖手柄时要压掉外层 scrollView 的 pan，否则列表跟着滚）。
//
// 依赖：仅 UIKit。使用时由 TiebaTextSelectionNode 注入四个闭包，不反向引用宿主。

import Foundation
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// 手柄方向：左手柄贴选择起点、右手柄贴终点。
enum TiebaTextSelectionKnob {
    case left
    case right
}

/// 逐级向上找最近的可滚动祖先：拖手柄到屏幕边缘时要用它把选择滚进可视区。
/// （上游与选择节点同文件故为 private；本仓拆成两个文件，改为模块内可见。）
func tiebaTextSelectionFindScrollView(view: UIView?) -> UIScrollView? {
    if let view {
        if let scrollView = view as? UIScrollView {
            return scrollView
        }
        return tiebaTextSelectionFindScrollView(view: view.superview)
    }
    return nil
}

/// 压掉外层 scrollView 正在进行的 pan：手柄拖动期间列表不能再跟着滚（上游同款）。
func tiebaTextSelectionCancelScrollViewGestures(view: UIView?) {
    if let view {
        if let gestureRecognizers = view.gestureRecognizers {
            for recognizer in gestureRecognizers {
                if let recognizer = recognizer as? UIPanGestureRecognizer {
                    switch recognizer.state {
                    case .began, .possible:
                        recognizer.state = .ended
                    default:
                        break
                    }
                }
            }
        }
        tiebaTextSelectionCancelScrollViewGestures(view: view.superview)
    }
}

/// 选择手势识别器：三种动作收在一个状态机里（上游算法逐行照搬）
///   · 按在手柄上 → 拖动改选（touchesMoved 里按位移增量移动手柄）
///   · 按在文字上且 canBeginSelection → 0.3s 后进入选择（长按选词）
///   · 抬手且正在选择 → didRecognizeTap 置位一帧（宿主用它区分"点一下收选择"与"真的点了链接"）
public final class TiebaTextSelectionGestureRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    private var longTapTimer: Timer?
    private var movingKnob: (TiebaTextSelectionKnob, CGPoint, CGPoint)?
    private var currentLocation: CGPoint?

    /// 宿主注入：能否在该点开始选择（默认 true）。
    public var canBeginSelection: ((CGPoint) -> Bool)?
    /// 宿主注入：在该点开始选择。
    public var beginSelection: ((CGPoint) -> Void)?
    /// 宿主注入：该点是否落在某个手柄上（返回手柄与手柄中心）。
    var knobAtPoint: ((CGPoint) -> (TiebaTextSelectionKnob, CGPoint)?)?
    /// 宿主注入：把某个手柄移动到某点。
    var moveKnob: ((TiebaTextSelectionKnob, CGPoint) -> Void)?
    /// 宿主注入：手柄拖动结束（该弹菜单了）。
    public var finishedMovingKnob: (() -> Void)?
    /// 宿主注入：清掉选择。
    public var clearSelection: (() -> Void)?
    /// 抬手时是否算作"一次点击"（宿主读它来避免误触）。
    public private(set) var didRecognizeTap: Bool = false
    var isSelecting: Bool = false

    override public init(target: Any?, action: Selector?) {
        super.init(target: nil, action: nil)
        self.delegate = self
    }

    override public func reset() {
        super.reset()
        self.longTapTimer?.invalidate()
        self.longTapTimer = nil
        self.movingKnob = nil
        self.currentLocation = nil
    }

    override public func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)

        let currentLocation = touches.first?.location(in: self.view)
        self.currentLocation = currentLocation

        if let currentLocation {
            if let (knob, knobPosition) = self.knobAtPoint?(currentLocation) {
                // 命中手柄：立刻进入拖动态，并压掉外层滚动。
                self.movingKnob = (knob, knobPosition, currentLocation)
                tiebaTextSelectionCancelScrollViewGestures(view: self.view?.superview)
                self.state = .began
            } else if self.canBeginSelection?(currentLocation) ?? true {
                if self.longTapTimer == nil {
                    final class TimerTarget: NSObject {
                        let f: () -> Void
                        init(_ f: @escaping () -> Void) {
                            self.f = f
                        }
                        @objc func event() {
                            self.f()
                        }
                    }
                    let longTapTimer = Timer(timeInterval: 0.3, target: TimerTarget({ [weak self] in
                        self?.longTapEvent()
                    }), selector: #selector(TimerTarget.event), userInfo: nil, repeats: false)
                    self.longTapTimer = longTapTimer
                    RunLoop.main.add(longTapTimer, forMode: .common)
                }
            } else {
                self.state = .failed
            }
        }
    }

    override public func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)

        let currentLocation = touches.first?.location(in: self.view)
        self.currentLocation = currentLocation

        if let (knob, initialKnobPosition, initialGesturePosition) = self.movingKnob, let currentLocation {
            self.moveKnob?(knob, CGPoint(x: initialKnobPosition.x + currentLocation.x - initialGesturePosition.x, y: initialKnobPosition.y + currentLocation.y - initialGesturePosition.y))
        }
    }

    override public func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)

        if let longTapTimer = self.longTapTimer {
            self.longTapTimer = nil
            longTapTimer.invalidate()

            if self.isSelecting {
                // 抬手即"点了一下"：置位一帧，宿主据此收选择/不误触链接。
                self.didRecognizeTap = true
                DispatchQueue.main.async { [weak self] in
                    self?.didRecognizeTap = false
                }
            }

            self.clearSelection?()
        } else {
            if self.currentLocation != nil, self.movingKnob != nil {
                self.finishedMovingKnob?()
            }
        }
        self.state = .ended
    }

    override public func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        self.state = .cancelled
    }

    private func longTapEvent() {
        if let currentLocation = self.currentLocation {
            self.beginSelection?(currentLocation)
            self.state = .ended
        }
    }

    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        return true
    }

    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive press: UIPress) -> Bool {
        return true
    }
}
