// 移植自上游 submodules/ConfettiEffect/Sources/ConfettiView.swift
//
// 改动（逐条编号，均相对上游）：
//   1. import Display 去掉，换成本目录自带件：generateFilledCircleImage / generateImage /
//      generateTintedImage → TiebaNodesGraphics 同族；UIColor(rgb:) → 文件私有的
//      tiebaConfettiColor(_:)。颜色常量与上游一字不差（0x56CE6B / 0xCD89D0 / 0x1E9AFF / 0xFF8724）。
//   2. ConstantDisplayLinkAnimator → 本仓 Core/TiebaDisplayLinkAnimator.swift 的
//      TiebaConstantDisplayLinkAnimator（同一套 isPaused / invalidate 用法，走共享
//      display link 驱动：前后台自动暂停、与其它动画合用一个 CADisplayLink）。
//      Δt 仍与上游一致，取两次 CACurrentMediaTime 之差。
//   3. upstream 的 Vector2 → 文件私有 TiebaConfettiVector2（避免与任何全局同名类型撞名）。
//   4. 上游靠 Display 的 nullAction（覆写 action(forKey:) 返回一个空 CAAction）关掉隐式
//      动画——逐帧手写 position/transform 时，任何一条隐式动画都会和逐帧赋值打架。
//      这里改成「创建粒子 + 逐帧写属性」两端都包进 CATransaction(setDisableActions: true)：
//      效果等价（该线程当前事务内不再生成隐式动画），而且不必引入一个 nonisolated 的
//      全局非 Sendable 常量（Swift 6 下那种全局 let 是硬编译错误）。
//   5. dtAndDamping 元组：上游算了 3 种粒子的 (dt, damping)，但取用处是
//      `let (localDt, _) = ...`，damping 分量**从未被使用**（下面粒子循环里的
//      damping 是另写的 0.93 常量）。这里只保留被用到的 dt，行为不变。
//   6. 上游 step() 里 `self.slowdownStartTimestamps[0] = 0.33`（每帧都把 0 号类型的
//      减速起点重置为 0.33）原样保留 —— 它确实让「从上往下落」的那批粒子在 0.33s
//      有一次整体减速，是效果的一部分，不是笔误。
//   7. 越界防御：上游用 Int(frame.width) / Int(frame.height) 直接构造随机区间，
//      尺寸为 0 时区间为空，Int.random(in:) 会 trap。这里对区间下界做 max(1, …) 钳制，
//      正常尺寸下取值分布完全一致。
//   8. 结束时除了 isPaused = true 还调 invalidate()：上游只暂停，display link 与
//      其 target 会一直挂在 runloop 上（视图已经 removeFromSuperview，没人再能唤醒它）。
//   9. customImage 为 nil 时上游的 generateTintedImage 结果被强解包（!）；这里改走
//      optional 绑定，拿不到就回退到内置图形，不再有强解包崩溃点。
//
// 并发：整类 @MainActor（UIView 子类）。逐帧推进全在主线程；步进中的 70+40*2 个 CALayer
//      属性写入包在 CATransaction(setDisableActions: true) 里（上游同款），
//      不会为每帧生成隐式动画。

import Foundation
import UIKit
import QuartzCore

/// 文件私有的二维向量（上游 Vector2）。
private struct TiebaConfettiVector2 {
    var x: Float
    var y: Float
}

/// 单颗纸屑。状态直接挂在 layer 上（上游同款设计），省掉一层 id→state 的查表。
private final class TiebaConfettiParticleLayer: CALayer {
    let mass: Float
    var velocity: TiebaConfettiVector2
    var angularVelocity: Float
    var rotationAngle: Float = 0.0
    var localTime: Float = 0.0
    let type: Int

    init(image: CGImage, size: CGSize, position: CGPoint, mass: Float, velocity: TiebaConfettiVector2, angularVelocity: Float, type: Int) {
        self.mass = mass
        self.velocity = velocity
        self.angularVelocity = angularVelocity
        self.type = type

        super.init()

        self.contents = image
        self.bounds = CGRect(origin: CGPoint(), size: size)
        self.position = position
    }

    override init(layer: Any) {
        self.mass = 0.0
        self.velocity = TiebaConfettiVector2(x: 0.0, y: 0.0)
        self.angularVelocity = 0.0
        self.type = 0
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private func tiebaConfettiColor(_ rgb: UInt32) -> UIColor {
    return UIColor(
        red: CGFloat((rgb >> 16) & 0xFF) / 255.0,
        green: CGFloat((rgb >> 8) & 0xFF) / 255.0,
        blue: CGFloat(rgb & 0xFF) / 255.0,
        alpha: 1.0
    )
}

/// 撒纸屑效果（上游 ConfettiView）。挂到目标视图上、给个足够大的 frame 即可自播自停。
public final class TiebaConfettiView: UIView {
    private var particles: [TiebaConfettiParticleLayer] = []
    private var displayLink: TiebaConstantDisplayLinkAnimator?

    private var localTime: Float = 0.0

    /// 涟漪圆心（nil = 不放涟漪）。语义：彩带从**用户刚点的那个按钮**向外被"推"一下，
    /// 而不是整体平移 —— 波前按 距离÷速度 依次到达，详见 UI/Drawing/TiebaRippleMath.swift
    ///（移植自上游 submodules/SpaceWarpView/Sources/SpaceWarpView.swift:129-182）。
    /// 坐标 = 本组件的视图坐标（与 frame 同一套）；创建后、首帧前设都有效。
    public var rippleOrigin: CGPoint?

    /// 幅度刻意取小（10pt）：涟漪是"材质被扰动"，不该盖过彩带本身的抛物线。
    private let rippleParams = TiebaRippleParams(amplitude: 10.0, frequency: 10.0, decay: 5.0, speed: 1200.0)

    public init(frame: CGRect, customImage: UIImage? = nil) {
        super.init(frame: frame)

        self.isUserInteractionEnabled = false
        self.backgroundColor = .clear

        let colors: [UIColor] = [
            tiebaConfettiColor(0x56CE6B),
            tiebaConfettiColor(0xCD89D0),
            tiebaConfettiColor(0x1E9AFF),
            tiebaConfettiColor(0xFF8724)
        ]
        let imageSize = CGSize(width: 8.0, height: 8.0)
        var images: [(CGImage, CGSize)] = []
        for imageType in 0 ..< 2 {
            for color in colors {
                if imageType == 0 {
                    let image: UIImage?
                    if let customImage = customImage {
                        image = TiebaNodesGraphics.tinted(customImage, color: color)
                    } else {
                        image = TiebaNodesGraphics.filledCircle(diameter: imageSize.width, color: color)
                    }
                    // 见文件头改动 9：拿不到图就跳过这一张，不再强解包。
                    if let cgImage = image?.cgImage {
                        images.append((cgImage, customImage?.size ?? imageSize))
                    }
                } else {
                    // 竖条：上下两个半圆 + 中间矩形（上游逐行同值）。
                    let spriteSize = CGSize(width: 2.0, height: 6.0)
                    let image = TiebaNodesGraphics.image(size: spriteSize, opaque: false) { context, size in
                        context.clear(CGRect(origin: CGPoint(), size: size))
                        context.setFillColor(color.cgColor)
                        context.fillEllipse(in: CGRect(origin: CGPoint(x: 0.0, y: 0.0), size: CGSize(width: size.width, height: size.width)))
                        context.fillEllipse(in: CGRect(origin: CGPoint(x: 0.0, y: size.height - size.width), size: CGSize(width: size.width, height: size.width)))
                        context.fill(CGRect(origin: CGPoint(x: 0.0, y: size.width / 2.0), size: CGSize(width: size.width, height: size.height - size.width)))
                    }
                    if let cgImage = image?.cgImage {
                        images.append((cgImage, spriteSize))
                    }
                }
            }
        }
        // 一张图都没生成出来（自定义图不可解码等）就别启动动画了。
        guard !images.isEmpty else {
            return
        }
        let imageCount = images.count

        // 见文件头改动 4：粒子创建期的属性写入也必须在「关掉隐式动画」的事务里，
        // 否则每颗纸屑上屏时都会各带一条 0.25s 的隐式补间。
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // 见文件头改动 7：两个区间都钳成非空，避免尺寸退化时 Int.random(in:) 触发陷阱。
        let originXRange = 0 ..< max(1, Int(frame.width))
        let originYRange = min(-1, Int(-frame.height)) ..< 0
        let topMassRange: Range<Float> = 40.0 ..< 50.0
        let velocityYRange = Float(3.0) ..< Float(5.0)
        let angularVelocityRange = Float(1.0) ..< Float(6.0)
        let sizeVariation = Float(0.8) ..< Float(1.6)

        // 顶部：70 颗，从画面上方往下落。
        for i in 0 ..< 70 {
            let (image, size) = images[i % imageCount]
            let sizeScale = CGFloat(Float.random(in: sizeVariation))
            let particle = TiebaConfettiParticleLayer(
                image: image,
                size: CGSize(width: size.width * sizeScale, height: size.height * sizeScale),
                position: CGPoint(x: CGFloat(Int.random(in: originXRange)), y: CGFloat(Int.random(in: originYRange))),
                mass: Float.random(in: topMassRange),
                velocity: TiebaConfettiVector2(x: 0.0, y: Float.random(in: velocityYRange)),
                angularVelocity: Float.random(in: angularVelocityRange),
                type: 0
            )
            self.particles.append(particle)
            self.layer.addSublayer(particle)
        }

        // 两侧：各 40 颗，从画面左右下角斜向上喷。
        let sideMassRange: Range<Float> = 110.0 ..< 120.0
        let sideOriginYBase: Float = Float(frame.size.height * 9.0 / 10.0)
        let sideOriginVelocityValueRange = Float(1.1) ..< Float(1.3)
        let sideOriginVelocityValueScaling: Float = 2400.0 * Float(frame.height) / 896.0
        let sideOriginVelocityBase: Float = Float.pi / 2.0 + atanf(Float(CGFloat(sideOriginYBase) / (frame.size.width * 0.8)))
        let sideOriginVelocityVariation: Float = 0.09
        let sideOriginVelocityAngleRange = Float(sideOriginVelocityBase - sideOriginVelocityVariation) ..< Float(sideOriginVelocityBase + sideOriginVelocityVariation)
        let originAngleRange = Float(0.0) ..< (Float.pi * 2.0)
        let originAmplitudeDiameter: CGFloat = 230.0
        let originAmplitudeRange = Float(0.0) ..< Float(originAmplitudeDiameter / 2.0)

        let sideTypes: [Int] = [0, 1, 2]

        for sideIndex in 0 ..< 2 {
            let sideSign: Float = sideIndex == 0 ? 1.0 : -1.0
            let baseOriginX: CGFloat = sideIndex == 0 ? -originAmplitudeDiameter / 2.0 : (frame.width + originAmplitudeDiameter / 2.0)

            for i in 0 ..< 40 {
                let originAngle = Float.random(in: originAngleRange)
                let originAmplitude = Float.random(in: originAmplitudeRange)
                let originX = baseOriginX + CGFloat(cosf(originAngle) * originAmplitude)
                let originY = CGFloat(sideOriginYBase + sinf(originAngle) * originAmplitude)

                let velocityValue = Float.random(in: sideOriginVelocityValueRange) * sideOriginVelocityValueScaling
                let velocityAngle = Float.random(in: sideOriginVelocityAngleRange)
                let velocityX = sideSign * velocityValue * sinf(velocityAngle)
                let velocityY = velocityValue * cosf(velocityAngle)
                let (image, size) = images[i % imageCount]
                let sizeScale = CGFloat(Float.random(in: sizeVariation))
                let particle = TiebaConfettiParticleLayer(
                    image: image,
                    size: CGSize(width: size.width * sizeScale, height: size.height * sizeScale),
                    position: CGPoint(x: originX, y: originY),
                    mass: Float.random(in: sideMassRange),
                    velocity: TiebaConfettiVector2(x: velocityX, y: velocityY),
                    angularVelocity: Float.random(in: angularVelocityRange),
                    type: sideTypes[i % 3]
                )
                self.particles.append(particle)
                self.layer.addSublayer(particle)
            }
        }
        CATransaction.commit()

        self.startDisplayLinkIfNeeded()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func startDisplayLinkIfNeeded() {
        if self.displayLink == nil {
            // Δt 与上游同款：两次 CACurrentMediaTime 采样之差（首帧把「建粒子」的时间
            // 也算进去，所以第一帧位移略大，上游就是这个行为，保留）。
            var previousTimestamp = CACurrentMediaTime()
            self.displayLink = TiebaConstantDisplayLinkAnimator(update: { [weak self] in
                let currentTimestamp = CACurrentMediaTime()
                self?.step(dt: currentTimestamp - previousTimestamp)
                previousTimestamp = currentTimestamp
            })
        }
        self.displayLink?.isPaused = false
    }

    /// 减速起点：nil = 该类型还没出现过正向速度（落地弹跳）的粒子。
    private var slowdownStartTimestamps: [Float?] = [nil, nil, nil]

    private func step(dt: Double) {
        let dt = Float(dt)
        // 见文件头改动 6：上游每帧把 0 号类型的减速起点重置为 0.33。
        self.slowdownStartTimestamps[0] = 0.33

        var haveParticlesAboveGround = false
        let maxPositionY = self.bounds.height + 30.0

        let typeDelays: [Float] = [0.0, 0.01, 0.08]
        // 见文件头改动 5：只保留被用到的 dt。
        var typeDts: [Float] = []

        for i in 0 ..< 3 {
            let typeDelay = typeDelays[i]
            let currentTime = self.localTime - typeDelay
            if currentTime < 0.0 {
                typeDts.append(0.0)
            } else if let slowdownStart = self.slowdownStartTimestamps[i] {
                let slowdownDuration: Float = 0.7
                if currentTime >= slowdownStart && currentTime <= slowdownStart + slowdownDuration {
                    let slowdownTimestamp: Float = currentTime - slowdownStart

                    let slowdownRampInDuration: Float = 0.05
                    let slowdownRampOutDuration: Float = 0.2
                    let rawSlowdownT: Float
                    if slowdownTimestamp < slowdownRampInDuration {
                        rawSlowdownT = slowdownTimestamp / slowdownRampInDuration
                    } else if slowdownTimestamp >= slowdownDuration - slowdownRampOutDuration {
                        let reverseTransition = (slowdownTimestamp - (slowdownDuration - slowdownRampOutDuration)) / slowdownRampOutDuration
                        rawSlowdownT = 1.0 - reverseTransition
                    } else {
                        rawSlowdownT = 1.0
                    }

                    let slowdownTransition = rawSlowdownT * rawSlowdownT
                    // 减速段最多把 dt 压到 0.8 倍。
                    let slowdownFactor: Float = 0.8 * slowdownTransition + 1.0 * (1.0 - slowdownTransition)
                    typeDts.append(dt * slowdownFactor)
                } else {
                    typeDts.append(dt)
                }
            } else {
                typeDts.append(dt)
            }
        }
        self.localTime += dt

        let g = TiebaConfettiVector2(x: 0.0, y: 9.8)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var turbulenceVariation: [Float] = []
        for _ in 0 ..< 20 {
            turbulenceVariation.append(Float.random(in: -16.0 ..< 16.0) * 60.0)
        }
        let turbulenceVariationCount = turbulenceVariation.count
        var index = 0

        var typesWithPositiveVelocity: [Bool] = [false, false, false]

        for particle in self.particles {
            let localDt = typeDts[particle.type]
            if localDt.isZero {
                continue
            }
            let damping: Float = 0.93

            particle.localTime += localDt

            var position = particle.position

            position.x += CGFloat(particle.velocity.x * localDt)
            position.y += CGFloat(particle.velocity.y * localDt)
            particle.position = position

            particle.rotationAngle += particle.angularVelocity * localDt
            var particleTransform = CATransform3DMakeRotation(CGFloat(particle.rotationAngle), 0.0, 0.0, 1.0)
            // D3：涟漪只写在**呈现**上（transform），不写 position —— 物理状态保持干净，
            // 否则下一帧读回的 position 已经带着位移，波会自己累积自己。
            if let rippleOrigin = self.rippleOrigin {
                let offset = tiebaRippleOffset(
                    position: position,
                    origin: rippleOrigin,
                    time: CGFloat(self.localTime),
                    params: self.rippleParams
                )
                particleTransform = CATransform3DTranslate(particleTransform, offset.x, offset.y, 0.0)
            }
            particle.transform = particleTransform

            let acceleration = g

            var velocity = particle.velocity
            velocity.x += acceleration.x * particle.mass * localDt
            velocity.y += acceleration.y * particle.mass * localDt
            if velocity.y < 0.0 {
                // 向上飞（喷出来后回落）时不加湍流，只做衰减。
                velocity.x *= damping
                velocity.y *= damping
            } else {
                velocity.x += turbulenceVariation[index % turbulenceVariationCount] * localDt
                typesWithPositiveVelocity[particle.type] = true
            }
            particle.velocity = velocity

            index += 1

            if position.y < maxPositionY {
                haveParticlesAboveGround = true
            }
        }
        for i in 0 ..< 3 {
            if typesWithPositiveVelocity[i] && self.slowdownStartTimestamps[i] == nil {
                self.slowdownStartTimestamps[i] = max(0.0, self.localTime - typeDelays[i])
            }
        }
        CATransaction.commit()

        if !haveParticlesAboveGround {
            // 见文件头改动 8：暂停 + 失效，别把 display link 留在 runloop 上。
            self.displayLink?.isPaused = true
            self.displayLink?.invalidate()
            self.removeFromSuperview()
        }
    }
}
