//
//  ZoomDismissAnimator.swift
//  JXPhotoBrowser
//

import UIKit

open class JXZoomDismissAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    open func transitionDuration(using ctx: UIViewControllerContextTransitioning?) -> TimeInterval {
        return 0.25
    }
    
    open func animateTransition(using ctx: UIViewControllerContextTransitioning) {
        let container = ctx.containerView
        let duration = transitionDuration(using: ctx)
        
        guard let fromVC = ctx.viewController(forKey: .from) as? JXPhotoBrowserViewController,
              let fromView = ctx.view(forKey: .from) else {
            ctx.completeTransition(false)
            return
        }
        
        if let toView = ctx.view(forKey: .to) {
            container.insertSubview(toView, belowSubview: fromView)
            toView.alpha = 1
            toView.layoutIfNeeded()
        }
        
        let pageIndex = fromVC.pageIndex
        // 前置条件不满足则直接降级为淡出
        guard let srcCell = fromVC.visibleCell(),
              let srcIV = srcCell.transitionImageView, srcIV.bounds.size != .zero,
              let thumbnailView = fromVC.delegate?.photoBrowser(fromVC, thumbnailViewAt: pageIndex) else {
            // 降级为淡出前先恢复列表缩略图显示，避免淡出完成后缩略图永久隐藏
            fromVC.delegate?.photoBrowser(fromVC, setThumbnailHidden: false, at: pageIndex)
            animateFadeOut(view: fromView, duration: duration, ctx: ctx)
            return
        }
        
        // 以当前图片视图为蓝本构建临时缩放视图
        //
        // 【本仓补丁 · 长图退出变形】原来只建一个 UIImageView、复制 srcIV 的
        // contentMode（aspectFill），然后把 frame 从源矩形线性插到缩略图矩形。
        // 对普通图够用，长图会崩：
        //   · 长图在查看器里是 fit-width 放大态（见 TiebaPhotoBrowserCells 的
        //     applyLongImageFitIfNeeded），源矩形高达 1000+pt、比屏幕还高；
        //   · aspectFill 让**图片**几乎不缩（缩放比只从 1.39 变到 1.27），真正在变的是
        //     "取景窗口"；而窗口的锚点（图片里的哪一段）首尾根本不同 ——
        //     查看器显示的是长图**顶部**，列表缩略图是整图**居中裁切**。
        //   于是整段动画内容一直在滑，收尾那一帧窗口塌到 300pt 高时，画面突然
        //   "换了一张" —— 用户看到的就是"到最后突然变形"。
        //
        // 改法：外层裁剪容器 + 内层图片，两套 frame 各自插值。
        //   · 外层 = 起始取景窗口（源矩形与屏幕求交，**不越出屏幕**），裁到圆角；
        //   · 内层 = 整张图在当前窗口里的真实位置，起点让内容与查看器逐像素对齐，
        //     终点收到窗口大小（此时 aspectFill 正好等于列表缩略图的居中裁切）。
        // 两端都对得上，中间是连续的"窗口收拢 + 内容归位"，没有跳变。
        let zoomIV = UIView()
        zoomIV.clipsToBounds = true
        zoomIV.layer.cornerRadius = srcIV.layer.cornerRadius
        zoomIV.backgroundColor = srcIV.backgroundColor

        let innerIV = UIImageView()
        innerIV.image = srcIV.image
        innerIV.contentMode = .scaleAspectFill
        innerIV.clipsToBounds = true

        // 起止几何
        let fullStart = srcIV.convert(srcIV.bounds, to: container)
        let visibleStart = fullStart.intersection(container.bounds)
        let startFrame = (visibleStart.isNull || visibleStart.isEmpty) ? fullStart : visibleStart
        let endFrame = thumbnailView.convert(thumbnailView.bounds, to: container)

        // 隐藏真实视图，避免重影
        // 缩略图显隐统一走 delegate 通道（setThumbnailHidden），不直接操作视图；
        // 浏览期间缩略图理应已隐藏，此处再设一次以覆盖列表 Cell 复用导致隐藏状态丢失的情况
        srcIV.isHidden = true
        fromVC.delegate?.photoBrowser(fromVC, setThumbnailHidden: true, at: pageIndex)

        zoomIV.frame = startFrame
        // 内层起点 = 整张图在起始窗口坐标系里的位置（负值即"图上边被窗口裁掉"）
        innerIV.frame = CGRect(
            x: fullStart.minX - startFrame.minX,
            y: fullStart.minY - startFrame.minY,
            width: fullStart.width,
            height: fullStart.height
        )
        zoomIV.addSubview(innerIV)
        container.addSubview(zoomIV)

        UIView.animate(withDuration: duration, animations: {
            zoomIV.frame = endFrame
            // 内层收到与外层同尺寸：此刻 aspectFill == 列表缩略图的居中裁切
            innerIV.frame = CGRect(origin: .zero, size: endFrame.size)
            // 10-10：落回缩略图时圆角要回到缩略图自己的圆角。原来只从查看器图片视图
            // （方角、radius 0）复制一次，飞回去的终点是方角图压在圆角缩略图上，
            // 交接那一帧能看到四角"啪"地补上。
            zoomIV.layer.cornerRadius = thumbnailView.layer.cornerRadius
            fromView.alpha = 0
        }) { _ in
            let completed = !ctx.transitionWasCancelled
            zoomIV.removeFromSuperview()
            if completed {
                fromVC.delegate?.photoBrowser(fromVC, setThumbnailHidden: false, at: pageIndex)
                fromView.removeFromSuperview()
                fromView.alpha = 1
                srcIV.isHidden = false
            } else {
                srcIV.isHidden = false
                fromView.alpha = 1
                fromVC.delegate?.photoBrowser(fromVC, setThumbnailHidden: true, at: pageIndex)
            }
            ctx.completeTransition(completed)
        }
    }
    
    // MARK: - Helpers
    
    /// 降级为淡出动画（不缩放，可覆写）
    open func animateFadeOut(view: UIView, duration: TimeInterval, ctx: UIViewControllerContextTransitioning) {
        UIView.animate(withDuration: duration, animations: {
            view.alpha = 0
        }) { _ in
            let wasCancelled = ctx.transitionWasCancelled
            if wasCancelled {
                view.alpha = 1
                ctx.completeTransition(false)
            } else {
                view.removeFromSuperview()
                view.alpha = 1
                ctx.completeTransition(true)
            }
        }
    }
}
