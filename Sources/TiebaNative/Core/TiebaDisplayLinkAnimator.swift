// TiebaDisplayLinkAnimator —— CADisplayLink 驱动层（共享 display link + 三种动画器）。
//
// 移植自上游 submodules/Display/Source/DisplayLinkAnimator.swift。
// 本仓改名：SharedDisplayLinkDriver → TiebaSharedDisplayLinkDriver、SharedDisplayLinkDriver.Link 协议 SharedDisplayLinkDriverLink → TiebaSharedDisplayLinkDriverLink、ConstantDisplayLinkAnimator → TiebaConstantDisplayLinkAnimator、DisplayLinkAnimator → TiebaDisplayLinkAnimator —— 公开符号加本仓前缀，避免污染模块全局命名空间
// 本仓改动：业务逻辑与代码结构零改动。仅做 Swift 6 并发标注（上游为 Swift 5 代码）：
//       1) 两处 NotificationCenter 观察者回调改用「init 里同步注册 + Task { @MainActor } 接管
//          回调体」的结构化并发写法（block 是 @Sendable nonisolated 闭包，驱动状态受 MainActor 隔离）
//          —— 原为 MainActor.assumeIsolated 断言；
//       2) TiebaDisplayLinkAnimator.deinit / TiebaConstantDisplayLinkAnimator.deinit 改用 Swift 6.2 的
//          isolated deinit（deinit 为 nonisolated，Link 成员受 MainActor 隔离）。
//       均以 // [移植] 注释就地标注。

import Foundation
import UIKit
import Darwin

// [移植] Swift 6 正统化：整条协议标 @MainActor —— Link 由 TiebaSharedDisplayLinkDriver（@MainActor）
// 创建与驱动，isPaused / invalidate 都直接操作它的状态。不标则其实现类
// （LinkImpl 等）无法标注隔离域，会报 #ConformanceIsolation 与 actor-isolated-call。
@MainActor
public protocol TiebaSharedDisplayLinkDriverLink: AnyObject {
    var isPaused: Bool { get set }
    
    func invalidate()
}

private let isIpad: Bool = {
    var systemInfo = utsname()
    uname(&systemInfo)
    let modelCode = withUnsafePointer(to: &systemInfo.machine) {
        $0.withMemoryRebound(to: CChar.self, capacity: 1) {
            ptr in String.init(validatingUTF8: ptr)
        }
    }
    
    if let modelCode {
        if modelCode.lowercased().hasPrefix("ipad") {
            return true
        }
    }
    
    return false
}()

// [移植] Swift 6：驱动实例的状态（displayLink/requests/isInForeground…）按设计只在主线程读写
//        （CADisplayLink 回调与 UIApplication 前后台通知都在主线程），单例也已标 @MainActor；
//        整类标 @MainActor 后，其 @Sendable 观察者闭包中捕获 self 才不需要跨隔离域传递（消除 SendingRisksDataRace）。
@MainActor public final class TiebaSharedDisplayLinkDriver {
    public enum FramesPerSecond: Comparable {
        case fps(Int)
        case max
        
        public static func <(lhs: FramesPerSecond, rhs: FramesPerSecond) -> Bool {
            switch lhs {
            case let .fps(lhsFps):
                switch rhs {
                case let .fps(rhsFps):
                    return lhsFps < rhsFps
                case .max:
                    return true
                }
            case .max:
                return false
            }
        }
    }
    
    public typealias Link = TiebaSharedDisplayLinkDriverLink
    
    // [移植] Swift 6：驱动实例持有 CADisplayLink / requests 等可变状态，且整份状态按设计只在主线程读写
    //        （CADisplayLink 回调在主 runloop；两个 UIApplication 前后台通知的闭包已 hop 到 @MainActor）。
    //        非隔离全局不能持有非 Sendable 类型，故把该单例标记为 @MainActor：隔离域与既有实际用法一致，
    //        取值/时机/语义不变（仍是首次访问时惰性创建的那一个实例）。
    @MainActor public static let shared = TiebaSharedDisplayLinkDriver()
    
    // [移植] Swift 6 正统化：Link 协议已标 @MainActor，实现类跟随。
    @MainActor
    public final class LinkImpl: Link {
        private let driver: TiebaSharedDisplayLinkDriver
        public let framesPerSecond: FramesPerSecond
        let update: (CGFloat) -> Void
        var isValid: Bool = true
        public var isPaused: Bool = false {
            didSet {
                if self.isPaused != oldValue {
                    self.driver.requestUpdate()
                }
            }
        }
        
        init(driver: TiebaSharedDisplayLinkDriver, framesPerSecond: FramesPerSecond, update: @escaping (CGFloat) -> Void) {
            self.driver = driver
            self.framesPerSecond = framesPerSecond
            self.update = update
        }
        
        public func invalidate() {
            self.isValid = false
        }
    }
    
    private final class RequestContext {
        weak var link: LinkImpl?
        let framesPerSecond: FramesPerSecond
        
        var lastDuration: Double = 0.0
        
        init(link: LinkImpl, framesPerSecond: FramesPerSecond) {
            self.link = link
            self.framesPerSecond = framesPerSecond
        }
    }
    
    private var displayLink: CADisplayLink?
    private var requests: [RequestContext] = []
    
    private var isInForeground: Bool = false
    private var isProcessingEvent: Bool = false
    private var isUpdateRequested: Bool = false
    
    private init() {
        // [移植] Swift 6 正统化：通知观察者的注册移到了 init 之后的
        // installForegroundObservers()（见该方法注释）——在 init 体内捕获 self 传给
        // Task 会触发 region-based isolation 的 "sending 'self' risks data races" 检查
        // （此时 self 尚未完全初始化，不在任何可发送区域）。移到 init 返回后注册即合法。
        
        if Bundle.main.bundlePath.hasSuffix(".appex") {
            self.isInForeground = true
        } else {
            switch UIApplication.shared.applicationState {
            case .active:
                self.isInForeground = true
            default:
                self.isInForeground = false
            }
        }
        
        self.update()
        self.installForegroundObservers()
    }

    /// [移植] Swift 6 正统化：NotificationCenter 的 block 是 @Sendable 的 nonisolated 闭包，
    /// 上游在闭包里用 MainActor.assumeIsolated 断言「此刻就在主 actor 上」（绕过隔离检查）。
    /// 这里改为正统的结构化并发：注册在 init 返回后同步完成（不漏通知），回调体交给
    /// Task { @MainActor } 在主 actor 上执行，不需要任何断言。
    /// 语义差异：回调体由「投递线程同步执行」变为「下一个主 actor 回合执行」，晚一拍（亚毫秒级）；
    /// 此处只改 isInForeground 并调用 update()（切换 CADisplayLink 的 isPaused、按需创建/销毁），
    /// 对帧时序没有可观察影响。
    private func installForegroundObservers() {
        // 上游丢弃 observer token，这里保持 let _ = 不变。
        let _ = NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil, using: { [weak self] _ in
            Task { @MainActor in
                guard let self else {
                    return
                }
                self.isInForeground = true
                self.update()
            }
        })
        let _ = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil, using: { [weak self] _ in
            Task { @MainActor in
                guard let self else {
                    return
                }
                self.isInForeground = false
                self.update()
            }
        })
    }

    private func requestUpdate() {
        if self.isProcessingEvent {
            self.isUpdateRequested = true
        } else {
            self.update()
        }
    }
    
    private func update() {
        var hasActiveItems = false
        var maxFramesPerSecond: FramesPerSecond = .fps(30)
        for request in self.requests {
            if let link = request.link {
                if link.framesPerSecond > maxFramesPerSecond {
                    maxFramesPerSecond = link.framesPerSecond
                }
                if link.isValid && !link.isPaused {
                    hasActiveItems = true
                    break
                }
            }
        }
        
        if self.isInForeground && hasActiveItems {
            let displayLink: CADisplayLink
            if let current = self.displayLink {
                displayLink = current
            } else {
                displayLink = CADisplayLink(target: self, selector: #selector(self.displayLinkEvent))
                self.displayLink = displayLink
                displayLink.add(to: .main, forMode: .common)
            }
            if #available(iOS 15.0, *) {
                let maxFps = Float(UIScreen.main.maximumFramesPerSecond)
                if maxFps > 61.0 {
                    var frameRateRange: CAFrameRateRange
                    switch maxFramesPerSecond {
                    case let .fps(fps):
                        if fps > 60 {
                            frameRateRange = CAFrameRateRange(minimum: 30.0, maximum: 120.0, preferred: 120.0)
                        } else {
                            frameRateRange = .default
                        }
                    case .max:
                        frameRateRange = CAFrameRateRange(minimum: 30.0, maximum: 120.0, preferred: 120.0)
                    }
                    
                    if isIpad {
                        frameRateRange = CAFrameRateRange(minimum: 30.0, maximum: 120.0, preferred: 120.0)
                    }
                    
                    if displayLink.preferredFrameRateRange != frameRateRange {
                        displayLink.preferredFrameRateRange = frameRateRange
                        print("TiebaSharedDisplayLinkDriver: switch to \(frameRateRange)")
                    }
                }
            }
            displayLink.isPaused = false
        } else {
            if let displayLink = self.displayLink {
                self.displayLink = nil
                displayLink.invalidate()
            }
        }
    }
    
    @objc private func displayLinkEvent(displayLink: CADisplayLink) {
        self.isProcessingEvent = true
        
        let duration = displayLink.targetTimestamp - displayLink.timestamp
        
        var removeIndices: [Int]?
        loop: for i in 0 ..< self.requests.count {
            let request = self.requests[i]
            if let link = request.link, link.isValid {
                if !link.isPaused {
                    var itemDuration = duration
                    
                    switch request.framesPerSecond {
                    case let .fps(value):
                        let secondsPerFrame = 1.0 / CGFloat(value)
                        itemDuration = secondsPerFrame
                        request.lastDuration += duration
                        if request.lastDuration >= secondsPerFrame * 0.95 {
                        } else {
                            continue loop
                        }
                    case .max:
                        break
                    }
                    
                    request.lastDuration = 0.0
                    link.update(itemDuration)
                }
            } else {
                if removeIndices == nil {
                    removeIndices = [i]
                } else {
                    removeIndices?.append(i)
                }
            }
        }
        if let removeIndices = removeIndices {
            for index in removeIndices.reversed() {
                self.requests.remove(at: index)
            }
            
            if self.requests.isEmpty {
                self.isUpdateRequested = true
            }
        }
        
        self.isProcessingEvent = false
        if self.isUpdateRequested {
            self.isUpdateRequested = false
            self.update()
        }
    }
    
    public func add(framesPerSecond: FramesPerSecond = .fps(60), _ update: @escaping (CGFloat) -> Void) -> Link {
        let link = LinkImpl(driver: self, framesPerSecond: framesPerSecond, update: update)
        self.requests.append(RequestContext(link: link, framesPerSecond: framesPerSecond))
        
        self.update()
        
        return link
    }
}

// [移植] Swift 6 正统化：标 @MainActor —— 本类驱动 CADisplayLink、只被 UI 调用，
// 本就是主线程类型。标了之后 self 即 Sendable，通知回调里的 Task { @MainActor } 可安全捕获，
// 不需要任何 assumeIsolated / nonisolated(unsafe)。
// [移植] Swift 6：本类整类标 @MainActor——它注册 CADisplayLink（TiebaSharedDisplayLinkDriver.shared 受 MainActor 隔离）、
//        由 CADisplayLink 在主线程回调 tick()，并且 deinit 需要访问非 Sendable 的 Link 成员；
//        隔离域与既有实际用法一致，调用方（ContextGesture 等 UI 代码）本就在主线程。
@MainActor public final class TiebaDisplayLinkAnimator {
    private var displayLink: TiebaSharedDisplayLinkDriver.Link?
    private let duration: Double
    private let fromValue: CGFloat
    private let toValue: CGFloat
    private let startTime: Double
    private let update: (CGFloat) -> Void
    private let completion: () -> Void
    private var completed = false
    
    // [移植] Swift 6：本构造器要向 @MainActor 的 TiebaSharedDisplayLinkDriver.shared 注册 display link
    //        （CACurrentMediaTime + CADisplayLink 本来也只能在主线程做），故标记 @MainActor——
    //        与 TiebaSharedDisplayLinkDriver.shared 的隔离域一致；deinit/invalidate 只碰非隔离的 Link 句柄，不受影响。
    @MainActor public init(duration: Double, from fromValue: CGFloat, to toValue: CGFloat, update: @escaping (CGFloat) -> Void, completion: @escaping () -> Void) {
        self.duration = duration
        self.fromValue = fromValue
        self.toValue = toValue
        self.update = update
        self.completion = completion
        
        self.startTime = CACurrentMediaTime()
        
        self.displayLink = TiebaSharedDisplayLinkDriver.shared.add { [weak self] _ in
            self?.tick()
        }
        self.displayLink?.isPaused = false
    }
    
    // [移植] Swift 6：displayLink 是非 Sendable 的存在类型（any TiebaSharedDisplayLinkDriverLink），
    //        nonisolated deinit 不能访问；本类整类 @MainActor，故用 Swift 6.2 的 isolated deinit。
    isolated deinit {
        self.displayLink?.isPaused = true
        self.displayLink?.invalidate()
    }
    
    public func invalidate() {
        self.displayLink?.isPaused = true
        self.displayLink?.invalidate()
    }
    
    @objc private func tick() {
        if self.completed {
            return
        }
        let timestamp = CACurrentMediaTime()
        var t = (timestamp - self.startTime) / self.duration
        t = max(0.0, t)
        t = min(1.0, t)
        self.update(self.fromValue * CGFloat(1 - t) + self.toValue * CGFloat(t))
        if abs(t - 1.0) < Double.ulpOfOne {
            self.completed = true
            self.displayLink?.isPaused = true
            self.completion()
        }
    }
}

// [移植] Swift 6：与 TiebaDisplayLinkAnimator 同理（MainActor 单例 + CADisplayLink 主线程回调 + 非 Sendable Link 成员）。
@MainActor public final class TiebaConstantDisplayLinkAnimator {
    private var displayLink: TiebaSharedDisplayLinkDriver.Link?
    private let update: () -> Void
    private var completed = false
    
    private func updateDisplayLink() {
        guard let displayLink = self.displayLink else {
            return
        }
        let _ = displayLink
    }
    
    // [移植] Swift 6：didSet 里要访问 @MainActor 的 TiebaSharedDisplayLinkDriver.shared（按需创建 display link），
    //        故该属性标记 @MainActor——isPaused 是 UI 动画开关，上游也只会在主线程改；其余成员不受影响。
    @MainActor public var isPaused: Bool = true {
        didSet {
            if self.isPaused != oldValue {
                if !self.isPaused && self.displayLink == nil {
                    let displayLink = TiebaSharedDisplayLinkDriver.shared.add { [weak self] _ in
                        self?.tick()
                    }
                    self.displayLink = displayLink
                    self.updateDisplayLink()
                }
                
                self.displayLink?.isPaused = self.isPaused
            }
        }
    }
    
    public init(update: @escaping () -> Void) {
        self.update = update
    }
    
    // [移植] Swift 6：同 TiebaDisplayLinkAnimator.deinit，本类整类 @MainActor，故用 isolated deinit
    //        访问非 Sendable 的 displayLink。
    isolated deinit {
        if let displayLink = self.displayLink {
            displayLink.isPaused = true
            displayLink.invalidate()
        }
    }
    
    public func invalidate() {
        if let displayLink = self.displayLink {
            displayLink.isPaused = true
            displayLink.invalidate()
        }
    }
    
    @objc private func tick() {
        if self.completed {
            return
        }
        self.update()
    }
}
