//
//  ZoomPresentAnimator.swift
//  JXPhotoBrowser
//

import UIKit

open class JXZoomPresentAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    
    open func transitionDuration(using ctx: UIViewControllerContextTransitioning?) -> TimeInterval {
        return 0.25
    }
    
    open func animateTransition(using ctx: UIViewControllerContextTransitioning) {
        let container = ctx.containerView
        let duration = transitionDuration(using: ctx)

        guard let toVC = ctx.viewController(forKey: .to) as? JXPhotoBrowserViewController,
              let toView = ctx.view(forKey: .to) else {
            ctx.completeTransition(false)
            return
        }

        // 添加目标视图并强制布局，确保 collectionView 有可见 Cell
        container.addSubview(toView)
        toView.frame = ctx.finalFrame(for: toVC)
        toView.layoutIfNeeded()
        
        // 滚动到初始位置，确保目标 Cell 可见
        toVC.scrollToInitialIndexIfNeeded()
        toVC.collectionView.layoutIfNeeded()

        // 检查前置条件：需要源缩略图视图
        // 注意：scrollToInitialIndexIfNeeded() 已将越界的 initialIndex clamp 为安全的 pageIndex，此处须用 pageIndex 避免越界崩溃
        guard let thumbnailView = toVC.delegate?.photoBrowser(toVC, thumbnailViewAt: toVC.pageIndex) else {
            fallbackToFade(toView: toView, duration: duration, ctx: ctx)
            return
        }
        
        let visibleCell = toVC.visibleCell()
        let targetIV = visibleCell?.transitionImageView

        // 起止几何
        let startFrame = thumbnailView.convert(thumbnailView.bounds, to: container)
        
        // 计算目标 frame：优先使用 targetIV，否则基于缩略图比例计算居中位置
        let endFrame: CGRect
        if let targetIV = targetIV, targetIV.bounds.size != .zero {
            endFrame = targetIV.convert(targetIV.bounds, to: container)
        } else {
            // targetIV 不可用（图片未加载），基于缩略图的比例计算目标位置
            let containerSize = container.bounds.size
            let originSize = thumbnailView.bounds.size
            guard originSize.width > 0, originSize.height > 0 else {
                fallbackToFade(toView: toView, duration: duration, ctx: ctx)
                return
            }
            // 按 AspectFit 计算目标尺寸
            let scale = min(containerSize.width / originSize.width, containerSize.height / originSize.height)
            let targetWidth = originSize.width * scale
            let targetHeight = originSize.height * scale
            let targetX = (containerSize.width - targetWidth) / 2
            let targetY = (containerSize.height - targetHeight) / 2
            endFrame = CGRect(x: targetX, y: targetY, width: targetWidth, height: targetHeight)
        }

        // 框架自动构造临时 ZoomView（无需业务方提供）
        let zoomView = Self.makeZoomView(from: thumbnailView)

        // 隐藏真实视图，避免重影
        // 缩略图显隐统一走 delegate 通道（setThumbnailHidden），不直接操作视图
        toVC.delegate?.photoBrowser(toVC, setThumbnailHidden: true, at: toVC.pageIndex)
        targetIV?.isHidden = true
        toView.alpha = 1
        toView.backgroundColor = .clear

        zoomView.frame = startFrame
        container.addSubview(zoomView)

        UIView.animate(withDuration: duration, animations: {
            zoomView.frame = endFrame
            // 10-10：圆角随放大收到 0。源缩略图在列表里可能是圆角图（帖子/回复的
            // 媒体格都带圆角），不把它收掉的话放大终点是一张"圆角大图"，
            // 而查看器的图片视图是方角 —— 落地瞬间会看到四角跳一下。
            zoomView.layer.cornerRadius = 0
            toView.backgroundColor = .black
        }) { _ in
            let completed = !ctx.transitionWasCancelled
            // 还原浏览器内的图片视图；缩略图在浏览期间保持隐藏，关闭时由 dismiss 流程恢复
            targetIV?.isHidden = false
            if !completed {
                toVC.delegate?.photoBrowser(toVC, setThumbnailHidden: false, at: toVC.pageIndex)
                toView.removeFromSuperview()
                zoomView.removeFromSuperview()
                ctx.completeTransition(false)
                return
            }
            // 落地这一步是**换视图**：临时图（缩略图，aspectFill）换成真图（aspectFit）。
            // 直接 remove 会在同一帧里把内容换掉，看着像"闪一下"；这里 0.12s 交叉淡出，
            // 让内容替换发生在两帧之间而不是一帧之内。
            UIView.animate(withDuration: 0.12, delay: 0, options: [.curveEaseOut]) {
                zoomView.alpha = 0
            } completion: { _ in
                zoomView.removeFromSuperview()
                ctx.completeTransition(true)
            }
        }
    }
    
    // MARK: - Helpers
    
    /// 基于源视图自动构造转场用的临时 UIImageView
    private static func makeZoomView(from sourceView: UIView) -> UIImageView {
        let zoomIV = UIImageView()
        if let imageView = sourceView as? UIImageView {
            zoomIV.image = imageView.image
            zoomIV.contentMode = imageView.contentMode
        } else {
            // 非 UIImageView 时，截取源视图快照
            let renderer = UIGraphicsImageRenderer(bounds: sourceView.bounds)
            zoomIV.image = renderer.image { ctx in
                sourceView.drawHierarchy(in: sourceView.bounds, afterScreenUpdates: false)
            }
            zoomIV.contentMode = .scaleAspectFill
        }
        zoomIV.clipsToBounds = true
        // 10-10：带上源视图的圆角，动画起手就是"列表里那张图"的形状（见上面 animate 里
        // 把它收到 0 的那一行）。圆角常挂在裁剪容器上，这里只认"源视图自己在裁剪且非 0"。
        if sourceView.clipsToBounds, sourceView.layer.cornerRadius > 0 {
            zoomIV.layer.cornerRadius = sourceView.layer.cornerRadius
            zoomIV.layer.cornerCurve = sourceView.layer.cornerCurve
        }
        return zoomIV
    }
    
    /// 降级为淡入动画
    private func fallbackToFade(toView: UIView, duration: TimeInterval, ctx: UIViewControllerContextTransitioning) {
        toView.alpha = 0
        UIView.animate(withDuration: duration, animations: {
            toView.alpha = 1
        }) { _ in
            let completed = !ctx.transitionWasCancelled
            if !completed {
                toView.alpha = 0
                toView.removeFromSuperview()
            }
            ctx.completeTransition(completed)
        }
    }
}
