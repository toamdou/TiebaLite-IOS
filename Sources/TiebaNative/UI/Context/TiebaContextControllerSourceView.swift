// TiebaContextControllerSourceView —— 上下文菜单的「源视图」容器（长按落点 / 预览锚点）。
//
// 移植自上游 submodules/Display/Source/ContextControllerSourceNode.swift （上游 321 行；本文件只取其中的 ContextControllerSourceView 部分，即 :157-321，165 行）。
//
// 【接线状态】已接线：UI/Components/TiebaSearchHistoryView.swift 的
//   TiebaPillCloudView.setPills 用它包住每颗搜索历史药丸（targetViewForActivationProgress = 药丸，
//   activated → pill.onLongPress）。
// 落点为什么是这里而不是列表行：TiebaFeedRowView.swift:556-666 / TiebaPostRowView.swift:1626-1745
// 已经是系统 UIContextMenuInteraction，而 10 号报告 R3 指出二者不可同视图共存（两套长按准入互相抢），
// 所以本容器只用在**没有**系统菜单、此前只有一个硬切 UILongPressGestureRecognizer 的搜索历史药丸上。
//
// ★ 这个文件真正值得抄的一点（也是任务书点名的那条）：
//   按压缩放是**绕「内容中点」**（targetContentRect.midX/midY）而不是绕视图中心做的。
//   公式：minScale = max(0.7, (内容宽 - 15) / 内容宽)，currentScale = 1·(1-p) + minScale·p；
//   再把「中点偏移量的缩放差」scaleMid = (bounds.w/2 - rect.midX)·scale - (bounds.w/2 - rect.midX)
//   作为平移补进去，合成 sublayerTransform = Translate(Scale(currentScale))。
//   对一行「左图右文」的帖子来说，内容中点明显不在视图中心，绕中心缩放会让内容朝中心飘——
//   这就是本仓现在（围绕视图中心）视觉上不对的原因，也是这段公式存在的全部理由。
//
// 逐条编号列出改动（相对上游 ContextControllerSourceNode.swift 的 View 部分）：
//   1) 符号加 Tieba 前缀：ContextControllerSourceView → TiebaContextControllerSourceView。
//      上游同文件的 ContextControllerSourceNode（ASDisplayNode 版，:5-155）不移植 —— 本仓纯 UIKit。
//   2) 删去 ASDisplayNode 相关的属性：
//      · targetNodeForActivationProgress: ASDisplayNode?（保留它的 UIKit 对位
//        targetViewForActivationProgress 与 CALayer 对位 targetLayerForActivationProgress，
//        这两个上游本来就有）；
//      · targetNodeForActivationProgressContentRect 改名为 targetContentRectForActivationProgress
//        （同一语义：目标内容在目标 layer 坐标系里的矩形，缩放的「中点」由它决定）。
//   3) 上游 .ended 分支里调用的 targetLayer.animate(from:to:keyPath:timingFunction:duration:) 是
//      Display 模块的 CALayer 扩展。本移植改用本文件底部内联的等价物 tiebaContextAnimate(...)
//      （名字带前缀，以免与 UI/Components/TiebaCAAnimationUtils.swift:313 的同名方法构成非法重声明）。
//      【2026-10 迁移记录】该助手原先定义在同目录 TiebaContextMenuContainer.swift（自绘玻璃气泡）里；
//      气泡与自研菜单模型已按"系统接口更优就别动"删除（系统 UIContextMenuInteraction 在 iOS 26 是正解），
//      助手随之搬到这里 —— 它是本类唯一的使用者。
//   4) Swift 6 严格并发正统化（无 @preconcurrency / nonisolated(unsafe) / assumeIsolated /
//      降 swift 版本）：UIView 在 SDK 里是 @MainActor，本类自动继承隔离域；手势闭包 [weak self]
//      捕获与主 actor 同域。DispatchQueue.main.asyncAfter 那段按上游原样保留。
//   5) open class 保持可继承（上游 open）；init(frame:) / init?(coder:) 与上游一致。
//   6) 除上述外逐行保留：isMultipleTouchEnabled=false / isExclusiveTouch=true / animateScale /
//      useSublayerTransformForActivation 的 sublayerTransform↔transform 二选一 /
//      customActivationProgress 优先于内建缩放 / 无 activated 回调时自动 gesture.cancel()。

import UIKit

/// 上游 `ContextControllerSourceView`（:157-321）的直译。
/// 用法：给任何"可长按弹出上下文菜单"的行/卡片包一层（或直接作为它的类），
/// 把 `activated` 接到菜单呈现，把 `targetViewForActivationProgress` 指到真正要缩的那层
/// （不设则缩自己）。按压缩放由本类内部驱动，不需要调用方写动画代码。
/// 当前唯一调用方：TiebaPillCloudView（搜索历史药丸，见文件头「接线状态」）。
public class TiebaContextControllerSourceView: UIView {
    public private(set) var contextGesture: TiebaContextGesture?

    public var isGestureEnabled: Bool = true {
        didSet {
            self.contextGesture?.isEnabled = self.isGestureEnabled
        }
    }
    public var beginDelay: Double = TiebaMotionSpec.Gesture.longPressBeginDelay {
        didSet {
            self.contextGesture?.beginDelay = self.beginDelay
        }
    }
    public var animateScale: Bool = true

    public var activated: ((TiebaContextGesture, CGPoint) -> Void)?
    public var shouldBegin: ((CGPoint) -> Bool)?
    public var customActivationProgress: ((CGFloat, TiebaContextGestureTransition) -> Void)?
    public weak var additionalActivationProgressLayer: CALayer?
    public var targetViewForActivationProgress: UIView?
    public weak var targetLayerForActivationProgress: CALayer?
    /// [移植 2] 上游名 targetNodeForActivationProgressContentRect（ASDisplayNode 时代的命名）。
    /// 语义：目标内容在目标 layer 坐标系里的矩形；本仓无 ASDisplayNode，故去掉 Node 字样。
    public var targetContentRectForActivationProgress: CGRect?
    /// true（默认）= 写 sublayerTransform（只影响子层，自身 frame/border 不动）；
    /// false = 写 transform（整层连自身一起缩放，会带着自己的边框/阴影一起缩）。
    public var useSublayerTransformForActivation: Bool = true

    public override init(frame: CGRect) {
        super.init(frame: frame)

        // 一行只允许一根手指参与（多点触控会让两行同时进入按压状态）。
        self.isMultipleTouchEnabled = false
        self.isExclusiveTouch = true

        let contextGesture = TiebaContextGesture(target: self, action: nil)
        self.contextGesture = contextGesture
        self.addGestureRecognizer(contextGesture)

        contextGesture.beginDelay = self.beginDelay
        contextGesture.isEnabled = self.isGestureEnabled

        contextGesture.shouldBegin = { [weak self] point in
            // 宽度为 0 说明还没布局，此时不该开始识别（否则会拿 0 宽的内容矩形去算缩放）。
            guard let strongSelf = self, !strongSelf.bounds.width.isZero else {
                return false
            }
            return strongSelf.shouldBegin?(point) ?? true
        }

        contextGesture.activationProgress = { [weak self] progress, update in
            guard let strongSelf = self, !strongSelf.bounds.width.isZero else {
                return
            }
            // 调用方自定义进度优先：一旦给了 customActivationProgress，内建缩放完全让位。
            if let customActivationProgress = strongSelf.customActivationProgress {
                customActivationProgress(progress, update)
            } else if strongSelf.animateScale {
                // 目标层三选一：ASDisplayNode（不移植）→ UIView → CALayer → 自己。
                let targetLayer: CALayer
                let targetContentRect: CGRect
                if let targetView = strongSelf.targetViewForActivationProgress {
                    targetLayer = targetView.layer
                    if let contentRect = strongSelf.targetContentRectForActivationProgress {
                        targetContentRect = contentRect
                    } else {
                        targetContentRect = CGRect(origin: CGPoint(), size: targetLayer.bounds.size)
                    }
                } else if let explicitLayer = strongSelf.targetLayerForActivationProgress {
                    targetLayer = explicitLayer
                    if let contentRect = strongSelf.targetContentRectForActivationProgress {
                        targetContentRect = contentRect
                    } else {
                        targetContentRect = CGRect(origin: CGPoint(), size: targetLayer.bounds.size)
                    }
                } else {
                    targetLayer = strongSelf.layer
                    targetContentRect = CGRect(origin: CGPoint(), size: targetLayer.bounds.size)
                }

                // ★ 围绕内容中点缩放的核心 6 行（逐字照抄上游 :237-248）：
                //   scaleSide 取「内容宽度」；内容越窄，允许的最小缩放越接近 0.7 下限，
                //   宽内容最多缩掉 15pt —— 这样不同尺寸的行缩掉的绝对量一致，视觉节奏统一。
                let scaleSide = targetContentRect.width
                let minScale: CGFloat = max(0.7, (scaleSide - 15.0) / scaleSide)
                let currentScale = 1.0 * (1.0 - progress) + minScale * progress

                // 「视图中心 - 内容中点」这个偏移，在缩放后必须按同一比例缩，
                // 否则内容中点会朝视图中心漂移（= 绕视图中心缩放的错误效果）。
                // 把缩放前后偏移的差值当平移补进去，等价于「把缩放锚点搬到内容中点」。
                let originalCenterOffsetX: CGFloat = targetLayer.bounds.width / 2.0 - targetContentRect.midX
                let scaledCenterOffsetX: CGFloat = originalCenterOffsetX * currentScale

                let originalCenterOffsetY: CGFloat = targetLayer.bounds.height / 2.0 - targetContentRect.midY
                let scaledCenterOffsetY: CGFloat = originalCenterOffsetY * currentScale

                let scaleMidX: CGFloat = scaledCenterOffsetX - originalCenterOffsetX
                let scaleMidY: CGFloat = scaledCenterOffsetY - originalCenterOffsetY

                switch update {
                case .update, .begin:
                    // .begin 与 .update 在上游是两段一模一样的代码（此处合并，行为零差异）：
                    // 都直接写最终值、不走 CA 动画 —— 进度本身就是每帧算出来的。
                    let sublayerTransform = CATransform3DTranslate(CATransform3DScale(CATransform3DIdentity, currentScale, currentScale, 1.0), scaleMidX, scaleMidY, 0.0)
                    if strongSelf.useSublayerTransformForActivation {
                        targetLayer.sublayerTransform = sublayerTransform
                    } else {
                        targetLayer.transform = sublayerTransform
                    }
                    if let additionalActivationProgressLayer = strongSelf.additionalActivationProgressLayer {
                        additionalActivationProgressLayer.transform = sublayerTransform
                    }
                case .ended:
                    // 抬手/取消：用 0.2s easeOut 从「当前变形」补间到目标变形（通常是恒等），
                    // 让回弹是动画而不是瞬跳。注意目标值仍由传进来的 progress 决定。
                    let sublayerTransform = CATransform3DTranslate(CATransform3DScale(CATransform3DIdentity, currentScale, currentScale, 1.0), scaleMidX, scaleMidY, 0.0)

                    if strongSelf.useSublayerTransformForActivation {
                        let previousTransform = targetLayer.sublayerTransform
                        targetLayer.sublayerTransform = sublayerTransform

                        targetLayer.tiebaContextAnimate(from: NSValue(caTransform3D: previousTransform), to: NSValue(caTransform3D: sublayerTransform), keyPath: "sublayerTransform", timingFunction: CAMediaTimingFunction(name: .easeOut), duration: TiebaMotionSpec.Gesture.longPressActivation)
                    } else {
                        let previousTransform = targetLayer.transform
                        targetLayer.transform = sublayerTransform

                        targetLayer.tiebaContextAnimate(from: NSValue(caTransform3D: previousTransform), to: NSValue(caTransform3D: sublayerTransform), keyPath: "transform", timingFunction: CAMediaTimingFunction(name: .easeOut), duration: TiebaMotionSpec.Gesture.longPressActivation)
                    }

                    if let additionalActivationProgressLayer = strongSelf.additionalActivationProgressLayer {
                        // 额外图层是「别人的层」（weak 持有），不能挂 CA 动画，只能在动画时长后再落定，
                        // 否则它会先瞬跳、再被主层的补间甩一下。上游用 DispatchQueue.main.asyncAfter(0.2)。
                        DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + TiebaMotionSpec.Gesture.longPressActivation, execute: {
                            additionalActivationProgressLayer.transform = sublayerTransform
                        })
                    }
                }
            }
        }
        contextGesture.activated = { [weak self] gesture, location in
            // 没有外部 activated 回调时，说明这个视图压根不该弹菜单：自我取消（连带进度回弹）。
            guard let strongSelf = self else {
                gesture.cancel()
                return
            }
            // 激活瞬间把内建缩放收掉（0 进度 + .ended），把画面交给菜单的呈现动画。
            if let customActivationProgress = strongSelf.customActivationProgress {
                customActivationProgress(0.0, .ended(0.0))
            }

            if let activated = strongSelf.activated {
                activated(gesture, location)
            } else {
                gesture.cancel()
            }
        }
        contextGesture.isEnabled = self.isGestureEnabled
    }

    public required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 上游同名的兜底取消：先 cancel（带回弹），再靠 enable/disable 一跳把 UIGestureRecognizer
    /// 内部状态彻底复位（单纯 cancel 之后，同一根手指的后续 touches 仍可能回到本识别器）。
    public func cancelGesture() {
      self.contextGesture?.cancel()
      self.contextGesture?.isEnabled = false
      self.contextGesture?.isEnabled = self.isGestureEnabled
    }
  }

  // MARK: - CALayer 补间（上游 CALayer.animate 的最小等价物）
  //
  // 本类 .ended 分支的补间动画用它。
  // 为什么内联而不是复用 UI/Components/TiebaCAAnimationUtils.swift:313：那一份在另一个目录，
  // 而本目录要能在「系统框架 + 本目录」的封闭集合里独立编译验证（见文件头交付标准）。
  // 动画属性与上游一致：isRemovedOnCompletion = true / fillMode = .forwards / key = keyPath。
  internal extension CALayer {
    func tiebaContextAnimate(from: Any?, to: Any, keyPath: String, timingFunction: CAMediaTimingFunction, duration: Double) {
      let animation = CABasicAnimation(keyPath: keyPath)
      animation.fromValue = from
      animation.toValue = to
      animation.duration = duration
      animation.timingFunction = timingFunction
      animation.isRemovedOnCompletion = true
      animation.fillMode = .forwards
      self.add(animation, forKey: keyPath)
    }
}
