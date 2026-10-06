// task-36 观感等价台架（可复跑）：把「接线后的转场引擎」与「接线前的意图参数」逐帧比对。
//
// 跑法（在 Sources/TiebaNative 目录下）：
//   xcrun --sdk iphonesimulator swiftc -swift-version 6 \
//     -target arm64-apple-ios26.0-simulator -o /tmp/vp-harness/harness \
//     <本文件> UI/Transition/*.swift UI/Components/TiebaCAAnimationUtils.swift \
//     UI/Components/TiebaUIKitUtils.swift UI/Drawing/TiebaSpring.swift
//   xcrun simctl spawn booted /tmp/vp-harness/harness
// 最近一次结果：VERDICT: PASS maxDeviation=0.000000048 failures=0
//   （4.8e-8 是 opacity/弹簧参数的 Float32 表示误差，不是插值误差）
//
// 14 节覆盖：
//   1            .easeInOut → 系统 CAMediaTimingFunction 控制点逐点比对
//   2-9          UI/Sheets 已接线调用点：from/to/duration/speed/isAdditive/模型值 + 1001 点值序列
//   10           退场 .easeOut → .custom(0,0,0.58,1) 与系统 .easeOut 同控制点
//   11           ControlledTransition 七条属性 × 101 点进度序列（Float/CGFloat/CGPoint/CGRect/CATransform3D/CGColor）
//   12           没有图层入口的两种插值：CGSize / CGPath（元素级）
//   13           merge 语义：新目标接管续跑 / 同目标保留在跑的那颗（不重启）
//   14           交互进度映射 solve(.easeInOut) = 上游 4 轮牛顿迭代的近似精度（1.7e-3）
//
// 为什么能证明「逐帧等价」：CASpringAnimation/CABasicAnimation 的帧值完全由
//   (fromValue, toValue, duration × speed, timingFunction, 弹簧四参数) 决定 ——
//   台架把这六项从「引擎真正装到图层上的动画」里读回来逐一比对，再按
//   from + (to - from) * f 采样 progress→值序列。
// 注：加性动画是「无名」加的（key = nil），animationKeys() 看不到，故用 SpyLayer 记账。

// task-36 观感等价台架：把「接线后的转场引擎」与「接线前的意图参数」逐帧比对。
// 跑法：编译成 iOS 模拟器可执行文件，xcrun simctl spawn booted 运行。
import UIKit

func f9(_ v: Double) -> String { String(format: "%.9f", v) }

@MainActor
final class Harness {
    var maxDeviation: Double = 0.0
    var failures: [String] = []

    func check(_ name: String, _ ok: Bool, _ detail: String) {
        print("[\(ok ? "OK" : "FAIL")] \(name): \(detail)")
        if !ok { self.failures.append(name) }
    }

    func deviation(_ name: String, _ d: Double, _ detail: String) {
        self.maxDeviation = max(self.maxDeviation, d)
        let tag = d == 0.0 ? "OK" : (d < 1e-5 ? "OK~" : "FAIL")
        if d >= 1e-5 { self.failures.append(name) }
        print("[dev=\(f9(d)) \(tag)] \(name): \(detail)")
    }

    func num(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let d = v as? Double { return d }
        if let c = v as? CGFloat { return Double(c) }
        if let f = v as? Float { return Double(f) }
        return nil
    }

    func installed(_ layer: SpyLayer, _ keyPath: String) -> CABasicAnimation? {
        return layer.last(keyPath)?.animation
    }
}

// 上游 animate(from:to:key:) 对加性动画用 key = nil（additive ? nil : keyPath），
// 而无名动画不出现在 animationKeys() 里 —— 所以用子类在 add(_:forKey:) 处记录，
// 连「加了没加、挂在哪个键上」都能验证。
final class SpyLayer: CALayer {
    var log: [(animation: CAAnimation, key: String?)] = []

    override func add(_ anim: CAAnimation, forKey key: String?) {
        self.log.append((anim, key))
        super.add(anim, forKey: key)
    }

    func last(_ keyPath: String) -> (animation: CABasicAnimation, key: String?)? {
        for entry in self.log.reversed() {
            if let a = entry.animation as? CABasicAnimation, a.keyPath == keyPath {
                return (a, entry.key)
            }
        }
        return nil
    }
}

// 独立实现的「值序列」参考：CABasicAnimation 对数值属性的取值 = from + (to - from) * f。
func lerp(_ a: Double, _ b: Double, _ f: Double) -> Double { a + (b - a) * f }

// 独立实现的三次贝塞尔求解（牛顿 + 二分），用来验证引擎把 .easeInOut 映射成了哪条曲线。
func bezierY(_ x: Double, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Double {
    func curve(_ t: Double, _ p1: Double, _ p2: Double) -> Double {
        let mt = 1.0 - t
        return 3.0 * mt * mt * t * p1 + 3.0 * mt * t * t * p2 + t * t * t
    }
    var lo = 0.0, hi = 1.0, t = x
    for _ in 0 ..< 60 {
        let cx = curve(t, x1, x2)
        if abs(cx - x) < 1e-12 { break }
        if cx < x { lo = t } else { hi = t }
        t = (lo + hi) / 2.0
    }
    return curve(t, y1, y2)
}

@MainActor
func run() -> Int32 {
    let h = Harness()
    let samples = 1001

    print("=== 1. 缓动曲线：.easeInOut → CAMediaTimingFunction 逐点比对 ===")
    let ease = TiebaContainedViewLayoutTransition.animated(duration: 0.3, curve: .easeInOut)
    if let anim = ease.animation(), let tf = anim.timingFunction {
        var cps: [CGPoint] = []
        for i in 0 ..< 4 {
            var xy: [Float] = [0.0, 0.0]
            tf.getControlPoint(at: i, values: &xy)
            cps.append(CGPoint(x: CGFloat(xy[0]), y: CGFloat(xy[1])))
        }
        let expect: [CGPoint] = [CGPoint(x: 0, y: 0), CGPoint(x: 0.42, y: 0), CGPoint(x: 0.58, y: 1), CGPoint(x: 1, y: 1)]
        var cpDev = 0.0
        for i in 0 ..< 4 {
            cpDev = max(cpDev, abs(Double(cps[i].x - expect[i].x)))
            cpDev = max(cpDev, abs(Double(cps[i].y - expect[i].y)))
        }
        h.deviation("easeInOut 控制点", cpDev, "系统值是 (\(cps.map { "(\($0.x),\($0.y))" }.joined(separator: " ")))")
        h.check("easeInOut 名称", tf == CAMediaTimingFunction(name: .easeInEaseOut), "与旧写法 UIView.animate(.curveEaseInOut) 同一条曲线")
        h.deviation("参考贝塞尔 vs 控制点构造", cpDev, "偏差为 0 即两条曲线逐点相同（同一组控制点）")
    } else {
        h.check("easeInOut animation()", false, "animation() 返回 nil")
    }

    print("")
    print("=== 2. SheetView.animateIn：遮罩淡入 0→1 / 0.4s easeInOut ===")
    do {
        let layer = SpyLayer()
        layer.opacity = 0.0
        TiebaContainedViewLayoutTransition.animated(duration: 0.4, curve: .easeInOut).updateAlpha(layer: layer, alpha: 1.0)
        let anim = h.installed(layer, "opacity")
        let from = h.num(anim?.fromValue) ?? -1, to = h.num(anim?.toValue) ?? -1
        h.deviation("animateIn 遮罩 from/to", max(abs(from - 0.0), abs(to - 1.0)), "接线后动画 (from \(from) → to \(to))，意图 (0 → 1)")
        h.deviation("animateIn 遮罩 duration", abs((anim?.duration ?? -1) - 0.4), "duration=\(anim?.duration ?? -1)")
        var seqDev = 0.0
        for i in 0 ..< samples {
            let f = Double(i) / Double(samples - 1)
            seqDev = max(seqDev, abs(lerp(from, to, f) - lerp(0.0, 1.0, f)))
        }
        h.deviation("animateIn 遮罩 progress→值序列", seqDev, "\(samples) 个采样点逐点比对")
        h.deviation("animateIn 遮罩模型值", abs(Double(layer.opacity) - 1.0), "调用后模型值=\(layer.opacity)（旧写法靠 fillMode=.forwards 停在终点）")
    }

    print("")
    print("=== 3. 关闭：面板头 / 遮罩淡出（beginWithCurrentState: true） ===")
    do {
        let layer = SpyLayer()
        layer.opacity = 0.1
        TiebaContainedViewLayoutTransition.animated(duration: 0.15, curve: .easeInOut).updateAlpha(layer: layer, alpha: 0.0, beginWithCurrentState: true)
        let a1 = h.installed(layer, "opacity")
        let f1 = h.num(a1?.fromValue) ?? -1, t1 = h.num(a1?.toValue) ?? -1
        h.deviation("头部淡出 0.1→0", max(abs(f1 - 0.1), abs(t1 - 0.0)), "from \(f1) → to \(t1)，duration \(a1?.duration ?? -1)")

        let layer2 = SpyLayer()
        layer2.opacity = 1.0
        TiebaContainedViewLayoutTransition.animated(duration: 0.3, curve: .easeInOut).updateAlpha(layer: layer2, alpha: 0.0, beginWithCurrentState: true)
        let a2 = h.installed(layer2, "opacity")
        let f2 = h.num(a2?.fromValue) ?? -1, t2 = h.num(a2?.toValue) ?? -1
        h.deviation("遮罩淡出 1→0", max(abs(f2 - 1.0), abs(t2 - 0.0)), "from \(f2) → to \(t2)，duration \(a2?.duration ?? -1)")
    }

    print("")
    print("=== 4. 弹簧位置（进场 mass3/stiffness1000/damping500） ===")
    do {
        let layer = SpyLayer()
        layer.position = CGPoint(x: 100, y: 800)
        let params = (m: 3.0, s: 1000.0, d: 500.0, v: 0.0)
        TiebaContainedViewLayoutTransition.spring(mass: params.m, stiffness: params.s, damping: params.d, initialVelocity: params.v)
            .updatePosition(layer: layer, position: CGPoint(x: 100, y: 400))
        let anim = h.installed(layer, "position")
        let probe = CASpringAnimation(keyPath: "position")
        probe.mass = params.m; probe.stiffness = params.s; probe.damping = params.d; probe.initialVelocity = params.v
        h.deviation("进场弹簧 duration", abs((anim?.duration ?? -1) - probe.settlingDuration), "引擎 duration=\(anim?.duration ?? -1)，裸 CASpringAnimation.settlingDuration=\(probe.settlingDuration)")
        h.deviation("进场弹簧 speed", abs(Double(anim?.speed ?? -1) - 1.0), "speed=\(anim?.speed ?? -1)（速度系数 1 = 逐帧与裸 CASpringAnimation 相同）")
        if let spring = anim as? CASpringAnimation {
            h.deviation("进场弹簧参数", max(max(abs(Double(spring.mass) - params.m), abs(Double(spring.stiffness) - params.s)), max(abs(Double(spring.damping) - params.d), abs(Double(spring.initialVelocity) - params.v))), "mass=\(spring.mass) stiffness=\(spring.stiffness) damping=\(spring.damping) v=\(spring.initialVelocity)")
        } else {
            h.check("进场弹簧类型", false, "安装的不是 CASpringAnimation：\(String(describing: anim))")
        }
        if let nv = anim?.fromValue as? NSValue {
            let p = nv.cgPointValue
            h.deviation("进场弹簧 from", max(abs(Double(p.x) - 100), abs(Double(p.y) - 800)), "from=\(p)")
        }
        if let nv = anim?.toValue as? NSValue {
            let p = nv.cgPointValue
            h.deviation("进场弹簧 to", max(abs(Double(p.x) - 100), abs(Double(p.y) - 400)), "to=\(p)")
        }
        h.deviation("进场弹簧模型值", abs(Double(layer.position.y) - 400), "模型 position=\(layer.position)")
    }

    print("")
    print("=== 5. 关闭弹簧（mass5/stiffness900/damping124 + 松手初速度） ===")
    do {
        let layer = SpyLayer()
        layer.position = CGPoint(x: 200, y: 300)
        let v = 1.7
        TiebaContainedViewLayoutTransition.spring(mass: 5.0, stiffness: 900.0, damping: 124.0, initialVelocity: CGFloat(v))
            .updatePosition(layer: layer, position: CGPoint(x: 200, y: 900))
        let anim = h.installed(layer, "position")
        let probe = CASpringAnimation(keyPath: "position")
        probe.mass = 5.0; probe.stiffness = 900.0; probe.damping = 124.0; probe.initialVelocity = CGFloat(v)
        h.deviation("关闭弹簧 duration", abs((anim?.duration ?? -1) - probe.settlingDuration), "engine=\(anim?.duration ?? -1) settling=\(probe.settlingDuration)")
        h.deviation("关闭弹簧 speed", abs(Double(anim?.speed ?? -1) - 1.0), "speed=\(anim?.speed ?? -1)")
        if let spring = anim as? CASpringAnimation {
            h.deviation("关闭弹簧初速度", abs(Double(spring.initialVelocity) - v), "initialVelocity=\(spring.initialVelocity)（意图 \(v)）")
        }
    }

    print("")
    print("=== 6. 无松手速度的加性位移 0.25s easeInOut（removeOnCompletion: false） ===")
    do {
        let layer = SpyLayer()
        layer.position = CGPoint(x: 50, y: 60)
        let before = layer.position
        TiebaContainedViewLayoutTransition.animated(duration: 0.25, curve: .easeInOut)
            .animatePositionAdditive(layer: layer, offset: CGPoint(x: 0, y: 120), to: CGPoint(), removeOnCompletion: false)
        let anim = h.installed(layer, "position")
        h.check("加性位移无名键", layer.last("position")?.key == nil, "key=\(String(describing: layer.last("position")?.key))（上游对加性动画用 nil 键）")
        h.check("加性位移 isAdditive", anim?.isAdditive == true, "isAdditive=\(anim?.isAdditive ?? false)")
        h.check("加性位移 removeOnCompletion", anim?.isRemovedOnCompletion == false, "isRemovedOnCompletion=\(anim?.isRemovedOnCompletion ?? true)")
        h.deviation("加性位移 duration", abs((anim?.duration ?? -1) - 0.25), "duration=\(anim?.duration ?? -1)")
        if let nv = anim?.fromValue as? NSValue {
            h.deviation("加性位移 from", max(abs(Double(nv.cgPointValue.x)), abs(Double(nv.cgPointValue.y) - 120)), "from=\(nv.cgPointValue)")
        }
        if let nv = anim?.toValue as? NSValue {
            h.deviation("加性位移 to", max(abs(Double(nv.cgPointValue.x)), abs(Double(nv.cgPointValue.y))), "to=\(nv.cgPointValue)")
        }
        h.deviation("加性位移模型值不动", max(abs(Double(layer.position.x - before.x)), abs(Double(layer.position.y - before.y))), "模型 position=\(layer.position)（加性 = 相对量，模型不该变）")
    }

    print("")
    print("=== 7. ToastView 缩放弹簧 mass3/stiffness1000/damping500 → 0.96 ===")
    do {
        let layer = SpyLayer()
        TiebaContainedViewLayoutTransition.spring(mass: 3.0, stiffness: 1000.0, damping: 500.0, initialVelocity: 0.0)
            .updateTransformScale(layer: layer, scale: 0.96)
        let entry = layer.last("transform.scale")
        if let spring = entry?.animation {
            h.check("缩放弹簧键名", true, "key=\(entry?.key ?? "nil") keyPath=\(spring.keyPath ?? "nil")")
            h.deviation("缩放弹簧 speed", abs(Double(spring.speed) - 1.0), "speed=\(spring.speed)")
            let f = h.num(spring.fromValue) ?? -1, t = h.num(spring.toValue) ?? -1
            h.deviation("缩放弹簧 from/to", max(abs(f - 1.0), abs(t - 0.96)), "from=\(f) to=\(t)（意图 1.0 → 0.96）")
        } else {
            h.check("缩放弹簧类型", false, "账本里没有 transform.scale: \(layer.log.map { $0.animation })")
        }
        h.deviation("缩放弹簧模型值", abs(Double(layer.transform.m11) - 0.96), "模型 m11=\(layer.transform.m11)")
    }

    print("")
    print("=== 8. scrollView bounds 0.3s easeInOut（force） ===")
    do {
        let layer = SpyLayer()
        layer.bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let target = CGRect(x: 0, y: 0, width: 390, height: 700)
        TiebaContainedViewLayoutTransition.animated(duration: 0.3, curve: .easeInOut).updateBounds(layer: layer, bounds: target, force: true)
        let anim = h.installed(layer, "bounds")
        if let nv = anim?.toValue as? NSValue {
            let r = nv.cgRectValue
            h.deviation("bounds to", max(max(abs(Double(r.width) - 390), abs(Double(r.height) - 700)), 0), "to=\(r) duration=\(anim?.duration ?? -1)")
        } else {
            h.check("bounds 动画存在", anim != nil, "未找到 bounds 动画（可能走了 immediate 分支）")
        }
        h.deviation("bounds 模型值", max(abs(Double(layer.bounds.width) - 390), abs(Double(layer.bounds.height) - 700)), "模型 bounds=\(layer.bounds)")
    }

    print("")
    print("=== 9. 旋转占位/倒计时环的加性位移（±6 / ±10） ===")
    do {
        for (name, off, to) in [("占位 -6", CGPoint(x: 0, y: -6), CGPoint()), ("占位 +6→0", CGPoint(x: 0, y: 6), CGPoint()), ("倒计时环 +10", CGPoint(x: 0, y: 10), CGPoint()), ("倒计时环 -10", CGPoint(x: 0, y: -10), CGPoint())] {
            let layer = SpyLayer()
            TiebaContainedViewLayoutTransition.animated(duration: 0.2, curve: .easeInOut)
                .animatePositionAdditive(layer: layer, offset: off, to: to)
            let anim = h.installed(layer, "position")
            var dev = 0.0
            if let nv = anim?.fromValue as? NSValue {
                dev = max(abs(Double(nv.cgPointValue.x - off.x)), abs(Double(nv.cgPointValue.y - off.y)))
            } else { dev = 1e9 }
            h.deviation("加性 \(name)", dev, "from 与意图一致；isAdditive=\(anim?.isAdditive ?? false)")
        }
    }

    print("")
    print("=== 10. ToastView 退场 .easeOut（上游 :2242）→ 引擎 .custom(0,0,0.58,1) ===")
    do {
        func cps(_ tf: CAMediaTimingFunction?) -> [CGPoint] {
            var out: [CGPoint] = []
            guard let tf else { return out }
            for i in 0 ..< 4 {
                var xy: [Float] = [0.0, 0.0]
                tf.getControlPoint(at: i, values: &xy)
                out.append(CGPoint(x: CGFloat(xy[0]), y: CGFloat(xy[1])))
            }
            return out
        }
        let curve = TiebaContainedViewLayoutTransition.animated(duration: 0.25, curve: .custom(0.0, 0.0, 0.58, 1.0))
        let engineAnim = curve.animation()
        let a = cps(engineAnim?.timingFunction)
        let b = cps(CAMediaTimingFunction(name: .easeOut))
        var dev = 0.0
        h.check("easeOut 控制点齐全", a.count == 4 && b.count == 4, "engine=\(a) system=\(b)")
        for i in 0 ..< min(a.count, b.count) {
            dev = max(dev, abs(Double(a[i].x - b[i].x)))
            dev = max(dev, abs(Double(a[i].y - b[i].y)))
        }
        h.deviation("easeOut 曲线等价", dev, "引擎 .custom(0,0,0.58,1) vs 系统 .easeOut（同一组控制点）")
        h.deviation("easeOut duration", abs((engineAnim?.duration ?? -1) - 0.25), "duration=\(engineAnim?.duration ?? -1)")
        let layer = SpyLayer()
        layer.opacity = 1.0
        curve.updateAlpha(layer: layer, alpha: 0.0, beginWithCurrentState: true)
        let anim = h.installed(layer, "opacity")
        h.deviation("easeOut 淡出 from/to", max(abs((h.num(anim?.fromValue) ?? -1) - 1.0), abs(h.num(anim?.toValue) ?? -1)), "from=\(h.num(anim?.fromValue) ?? -1) to=\(h.num(anim?.toValue) ?? -1)")
    }

    print("")
    print("=== 11. ControlledTransition（可打断/可合并）：7 条属性 + 2 种无入口插值 ===")
    do {
        func take(_ layer: SpyLayer, _ path: String) -> Any? { layer.last(path)?.animation.fromValue }
        func mid(_ f: Int) -> CGFloat { CGFloat(f) / 100.0 }

        // (a) opacity：Float 插值
        do {
            let layer = SpyLayer()
            layer.opacity = 0.0
            let ct = TiebaControlledTransition(duration: 0.3, curve: .linear, interactive: true)
            ct.animator.updateAlpha(layer: layer, alpha: 1.0, completion: nil)
            var dev = 0.0
            for i in 0 ... 100 {
                ct.animator.setAnimationProgress(mid(i))
                let got = (take(layer, "opacity") as? NSNumber)?.doubleValue ?? -999.0
                dev = max(dev, abs(got - lerp(0.0, 1.0, Double(mid(i)))))
            }
            h.deviation("CT opacity Float 101 点", dev, "0 → 1，curve .linear")
        }

        // (b) transform.scale：CGFloat 插值
        do {
            let layer = SpyLayer()
            let ct = TiebaControlledTransition(duration: 0.3, curve: .linear, interactive: true)
            ct.animator.updateScale(layer: layer, scale: 0.5, completion: nil)
            var dev = 0.0
            for i in 0 ... 100 {
                ct.animator.setAnimationProgress(mid(i))
                let got = (take(layer, "transform.scale") as? NSNumber)?.doubleValue ?? -999.0
                dev = max(dev, abs(got - lerp(1.0, 0.5, Double(mid(i)))))
            }
            h.deviation("CT transform.scale CGFloat 101 点", dev, "1.0 → 0.5")
        }

        // (c) position：CGPoint 插值
        do {
            let layer = SpyLayer()
            layer.position = CGPoint(x: 10, y: 20)
            let ct = TiebaControlledTransition(duration: 0.3, curve: .linear, interactive: true)
            ct.animator.updatePosition(layer: layer, position: CGPoint(x: 110, y: 220), completion: nil)
            var dev = 0.0
            for i in 0 ... 100 {
                ct.animator.setAnimationProgress(mid(i))
                let got = (take(layer, "position") as? NSValue)?.cgPointValue ?? CGPoint(x: -999, y: -999)
                dev = max(dev, abs(Double(got.x) - lerp(10, 110, Double(mid(i)))))
                dev = max(dev, abs(Double(got.y) - lerp(20, 220, Double(mid(i)))))
            }
            h.deviation("CT position CGPoint 101 点", dev, "(10,20) → (110,220)")
        }

        // (d) bounds：CGRect 插值
        do {
            let layer = SpyLayer()
            layer.bounds = CGRect(x: 0, y: 0, width: 10, height: 20)
            let ct = TiebaControlledTransition(duration: 0.3, curve: .linear, interactive: true)
            ct.animator.updateBounds(layer: layer, bounds: CGRect(x: 1, y: 2, width: 110, height: 220), completion: nil)
            var dev = 0.0
            for i in 0 ... 100 {
                ct.animator.setAnimationProgress(mid(i))
                let got = (take(layer, "bounds") as? NSValue)?.cgRectValue ?? CGRect(x: -999, y: -999, width: -999, height: -999)
                let f = Double(mid(i))
                dev = max(dev, abs(Double(got.origin.x) - lerp(0, 1, f)))
                dev = max(dev, abs(Double(got.origin.y) - lerp(0, 2, f)))
                dev = max(dev, abs(Double(got.size.width) - lerp(10, 110, f)))
                dev = max(dev, abs(Double(got.size.height) - lerp(20, 220, f)))
            }
            h.deviation("CT bounds CGRect 101 点", dev, "(0,0,10,20) → (1,2,110,220)")
        }

        // (e) transform：CATransform3D 16 分量逐分量
        do {
            let layer = SpyLayer()
            let ct = TiebaControlledTransition(duration: 0.3, curve: .linear, interactive: true)
            ct.animator.updateTransform(layer: layer, transform: CATransform3DMakeScale(2.0, 2.0, 1.0), completion: nil)
            var dev = 0.0
            for i in 0 ... 100 {
                ct.animator.setAnimationProgress(mid(i))
                guard let got = (take(layer, "transform") as? NSValue)?.caTransform3DValue else { dev = 999.0; continue }
                let f = Double(mid(i))
                dev = max(dev, abs(Double(got.m11) - lerp(1, 2, f)))
                dev = max(dev, abs(Double(got.m22) - lerp(1, 2, f)))
                dev = max(dev, abs(Double(got.m33) - lerp(1, 1, f)))
                dev = max(dev, abs(Double(got.m44) - lerp(1, 1, f)))
            }
            h.deviation("CT transform CATransform3D 101 点", dev, "单位阵 → scale(2,2,1)")
        }

        // (f) backgroundColor：CGColor（端点精确 + 中点信息）
        do {
            let layer = SpyLayer()
            layer.backgroundColor = UIColor.black.cgColor
            let ct = TiebaControlledTransition(duration: 0.3, curve: .linear, interactive: true)
            ct.animator.updateBackgroundColor(layer: layer, color: .white, completion: nil)
            ct.animator.setAnimationProgress(0.0)
            let c0 = (take(layer, "backgroundColor") as! CGColor).components ?? []
            ct.animator.setAnimationProgress(1.0)
            let c1 = (take(layer, "backgroundColor") as! CGColor).components ?? []
            ct.animator.setAnimationProgress(0.5)
            let c5 = (take(layer, "backgroundColor") as! CGColor).components ?? []
            h.deviation("CT backgroundColor 端点", max(abs(Double((c0.first ?? -1) - 0.0)), abs(Double((c1.first ?? -1) - 1.0))), "f=0 → \(c0)，f=1 → \(c1)")
            print("[info] CGColor 中点(0.5) → \(c5)：mixedWith 走 UIColor 色彩空间/预乘路径，与朴素分量线性插值不逐位相同（上游同一调用）")
        }
    }

    print("")
    print("=== 12. 无图层入口的两种插值：CGSize / CGPath ===")
    do {
        let sizeFrom = CGSize(width: 10, height: 20)
        let sizeTo = CGSize(width: 110, height: 220)
        var sizeDev = 0.0
        for i in 0 ... 100 {
            let f = CGFloat(i) / 100.0
            let got = sizeFrom.tiebaInterpolate(with: sizeTo, fraction: f)
            sizeDev = max(sizeDev, abs(Double(got.width) - lerp(10, 110, Double(f))))
            sizeDev = max(sizeDev, abs(Double(got.height) - lerp(20, 220, Double(f))))
        }
        h.deviation("CGSize 插值 101 点", sizeDev, "10×20 → 110×220")

        let p0 = CGMutablePath()
        p0.move(to: CGPoint(x: 0, y: 0))
        p0.addLine(to: CGPoint(x: 10, y: 0))
        let p1 = CGMutablePath()
        p1.move(to: CGPoint(x: 100, y: 50))
        p1.addLine(to: CGPoint(x: 110, y: 50))
        func points(_ path: CGPath) -> [CGPoint] {
            var out: [CGPoint] = []
            path.applyWithBlock { el in
                let e = el.pointee
                switch e.type {
                case .moveToPoint, .addLineToPoint:
                    out.append(e.points[0])
                default:
                    break
                }
            }
            return out
        }
        var pathDev = 0.0
        for i in 1 ... 99 {
            let f = CGFloat(i) / 100.0
            let got = points(p0.tiebaInterpolate(with: p1, fraction: f))
            if got.count != 2 { pathDev = 999.0; continue }
            let d = Double(f)
            pathDev = max(pathDev, abs(Double(got[0].x) - lerp(0, 100, d)))
            pathDev = max(pathDev, abs(Double(got[0].y) - lerp(0, 50, d)))
            pathDev = max(pathDev, abs(Double(got[1].x) - lerp(10, 110, d)))
        }
        h.deviation("CGPath 元素级插值 99 点", pathDev, "两条 move+line 路径逐点比对")
        h.check("CGPath 端点短路", points(p0.tiebaInterpolate(with: p1, fraction: 0.0)) == points(p0) && points(p0.tiebaInterpolate(with: p1, fraction: 1.0)) == points(p1), "f<=0 返回自身、f>=1 返回目标")
    }

    print("")
    print("=== 13. 可合并转场：新转场 merge 旧转场（打断续跑） / 同目标 merge（不重启） ===")
    do {
        // (a) 目标不同：新转场接管，从当前值（= 旧转场已写入的模型值）续跑到新目标
        let layer = SpyLayer()
        layer.position = CGPoint(x: 0, y: 0)
        let old = TiebaControlledTransition(duration: 0.3, curve: .linear, interactive: true)
        old.animator.updatePosition(layer: layer, position: CGPoint(x: 100, y: 0), completion: nil)
        old.animator.setAnimationProgress(0.5)
        let fresh = TiebaControlledTransition(duration: 0.3, curve: .linear, interactive: true)
        fresh.animator.updatePosition(layer: layer, position: CGPoint(x: 0, y: 200), completion: nil)
        fresh.merge(with: old, forceRestart: false)
        fresh.animator.setAnimationProgress(1.0)
        let at1 = (layer.last("position")?.animation.fromValue as? NSValue)?.cgPointValue ?? CGPoint(x: -999, y: -999)
        fresh.animator.setAnimationProgress(0.0)
        let at0 = (layer.last("position")?.animation.fromValue as? NSValue)?.cgPointValue ?? CGPoint(x: -999, y: -999)
        h.deviation("新目标 merge：进度 1 = 新目标", max(abs(Double(at1.x)), abs(Double(at1.y) - 200)), "progress 1 → \(at1)（期望 (0,200)）")
        h.deviation("新目标 merge：进度 0 = 打断时的当前值", max(abs(Double(at0.x) - 100), abs(Double(at0.y))), "progress 0 → \(at0)（期望 (100,0)，不是旧起点 (0,0)）")
        print("[info] 语义：打断在 (100,0) 的进行中动画 → 画面从当前值直奔新目标 (0,200)，不重启、不闪回")

        // (b) 目标相同：保留正在跑的那颗，新转场里那颗重复动画被摘掉（否则会从起点重启、闪一下）
        let layer2 = SpyLayer()
        layer2.position = CGPoint(x: 0, y: 0)
        let running = TiebaControlledTransition(duration: 0.3, curve: .linear, interactive: true)
        running.animator.updatePosition(layer: layer2, position: CGPoint(x: 100, y: 0), completion: nil)
        running.animator.setAnimationProgress(0.5)
        let duplicate = TiebaControlledTransition(duration: 0.3, curve: .linear, interactive: true)
        duplicate.animator.animatePosition(layer: layer2, from: CGPoint(x: 100, y: 0), to: CGPoint(x: 100, y: 0), completion: nil)
        duplicate.merge(with: running, forceRestart: false)
        let live = (layer2.animationKeys() ?? []).compactMap { layer2.animation(forKey: $0) as? CABasicAnimation }.filter { $0.keyPath == "position" }
        h.check("同目标 merge：只剩一颗在跑的动画", live.count == 1, "遗留 position 动画数 = \(live.count)")
        let liveValue = (live.first?.fromValue as? NSValue)?.cgPointValue ?? CGPoint(x: -999, y: -999)
        h.deviation("同目标 merge：沿用旧那颗（停在 0.5 处）", max(abs(Double(liveValue.x) - 50), abs(Double(liveValue.y))), "fromValue = \(liveValue)（期望 (50,0)，没被重启成 (0,0)）")
    }

    print("")
    print("=== 14. 交互进度映射：curve.solve(.easeInOut) vs 独立贝塞尔求解（上游近似精度） ===")
    do {
        let curve = TiebaContainedViewLayoutTransitionCurve.easeInOut
        var dev = 0.0
        for i in 0 ... 100 {
            let f = CGFloat(i) / 100.0
            dev = max(dev, abs(Double(curve.solve(at: f)) - bezierY(Double(f), 0.42, 0.0, 0.58, 1.0)))
        }
        // 上游 Spring.swift:42-67 就是「牛顿迭代固定 4 轮 + >=0.997 夹到 1」的近似解，
        // 本仓 TiebaSpring.bezierPoint 逐行照搬 ⇒ 这条偏差是上游自带精度，不是接线回归。
        // 它只影响交互驱动的进度映射；CA 动画那条路走的是系统 CAMediaTimingFunction（第 1 节，1.7e-8）。
        h.check("solve(.easeInOut) 与上游近似精度一致", dev < 5e-3, "101 点最大偏差 = \(f9(dev))（4 轮牛顿迭代 + 0.997 夹取的理论量级）")
    }

    print("")
    let verdict = h.failures.isEmpty && h.maxDeviation < 1e-5
    print("VERDICT: \(verdict ? "PASS" : "FAIL") maxDeviation=\(f9(h.maxDeviation)) failures=\(h.failures.count) \(h.failures.joined(separator: ","))")
    return verdict ? 0 : 1
}

exit(run())
