// 从 TiebaPostRowView.swift 拆出（H10 千行文件拆分）：主类之前的独立类型（纯搬运，整类型逐字搬走）。
// 主类留在原文件：它自己的扩展要用到类内 private，同文件才合法。
// 后续按类型再拆（H10 续）：媒体协调器 / 内嵌视频 / 语音条 / 波形 / 媒体占位条已迁到 Inline/ 目录，
// 本文件只留行事件、共用手感收口与图片加载（Nuke）这组跨类型共用的辅助。

import AVFoundation
import AVKit
import UIKit
import Nuke
import NukeExtensions

// MARK: - 事件

enum TiebaPostRowEvent: Sendable {
  case avatar
  case agree
  case toggleSeeLz
  /// 排序档位选择（药丸弹菜单，直接选热门/正序/倒序，不再循环）。
  case selectSort(TiebaThreadSort)
  case copyContent
  /// 复制主贴标题（长按标题弹的菜单项）。
  case copyTitle
  case share
  case copyLink
  case delete
  case subPosts
  case image(index: Int, rect: CGRect)
  case link(String)
  case user(String)
}

// MARK: - 统一的按压 / 弹簧反馈

/// 吧页 / 帖子页控件共用的手感收口：按下用时长表里的微反馈档，松手/选中用
/// TiebaMotionSpec 的通用回弹弹簧；CAAnimation 交给 TiebaAnimationFrameRate
/// 对齐 ProMotion。Reduce Motion 下只写终态，不起动画。
@MainActor
enum TiebaInteractiveMotion {
  private static let pressKey = "tieba.post.press"
  private static let pulseKey = "tieba.post.pulse"
  private static let springKey = "tieba.post.spring"

  /// 按下 0.94，松手用回弹弹簧收口。
  static func press(_ view: UIView, pressed: Bool) {
    if pressed {
      let from = view.layer.presentation()?.transform ?? view.layer.transform
      let target = CATransform3DMakeScale(0.94, 0.94, 1)
      view.layer.removeAnimation(forKey: pressKey)
      view.layer.transform = target
      guard UIAccessibility.isReduceMotionEnabled == false else { return }
      let animation = CABasicAnimation(keyPath: "transform")
      animation.fromValue = NSValue(caTransform3D: from)
      animation.toValue = NSValue(caTransform3D: target)
      animation.duration = TiebaAnimationDuration.microFeedback
      animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
      TiebaAnimationFrameRate.align(animation, to: view)
      view.layer.add(animation, forKey: pressKey)
      return
    }
    springTransform(view, to: CATransform3DIdentity, key: pressKey)
  }

  /// 选中态/点赞态的克制 pop：0.86 → 1 的欠阻尼弹簧，带一点收势但不晃。
  static func pulse(_ view: UIView, from scale: CGFloat = 0.86) {
    guard UIAccessibility.isReduceMotionEnabled == false else {
      view.layer.removeAnimation(forKey: pulseKey)
      view.layer.transform = CATransform3DIdentity
      return
    }
    let start = CATransform3DMakeScale(scale, scale, 1)
    springTransform(view, to: CATransform3DIdentity, key: pulseKey, from: start)
  }

  /// 位移动画（浮条显隐）：使用同一颗通用回弹弹簧；新动作先摘旧 animation
  /// 并读取 presentation 当前值，因此滚动方向反复翻转时可中断、不跳帧。
  static func springTransform(
    _ view: UIView,
    to target: CATransform3D,
    key: String = springKey,
    from explicitFrom: CATransform3D? = nil
  ) {
    let from = explicitFrom ?? view.layer.presentation()?.transform ?? view.layer.transform
    view.layer.removeAnimation(forKey: key)
    view.layer.transform = target
    guard UIAccessibility.isReduceMotionEnabled == false else { return }
    let animation = CASpringAnimation(keyPath: "transform")
    animation.mass = TiebaMotionSpec.Spring.closeMass
    animation.stiffness = TiebaMotionSpec.Spring.closeStiffness
    animation.damping = TiebaMotionSpec.Spring.bounceDamping
    animation.initialVelocity = 0
    animation.fromValue = NSValue(caTransform3D: from)
    animation.toValue = NSValue(caTransform3D: target)
    animation.duration = animation.settlingDuration
    animation.timingFunction = CAMediaTimingFunction(name: .linear)
    animation.fillMode = .forwards
    animation.isRemovedOnCompletion = true
    TiebaAnimationFrameRate.align(animation, to: view)
    view.layer.add(animation, forKey: key)
  }

  /// 复用/换行时清掉按压态，避免下一行继承缩小的 transform。
  static func reset(_ view: UIView) {
    view.layer.removeAnimation(forKey: pressKey)
    view.layer.removeAnimation(forKey: pulseKey)
    view.layer.removeAnimation(forKey: springKey)
    view.layer.transform = CATransform3DIdentity
  }
}

// MARK: - 图片加载（Nuke；options 组装统一走 TiebaNuke.options）

@MainActor
func tiebaPostLoadImage(
  _ url: URL?,
  maxPixel: CGFloat,
  into imageView: UIImageView,
  transition: Bool = false
) {
  guard let url else {
    imageView.image = nil
    return
  }
  loadImage(
    with: TiebaNuke.secureURL(url),
    options: TiebaNuke.options(maxPixel: maxPixel, transition: transition),
    into: imageView
  )
}

/// 显示档取图（aspectFill 视图专用）：位图 = 视图尺寸下的裁切结果，圆角也烘焙在
/// 像素里，所以视图侧不需要 clipsToBounds（省掉每帧一次离屏合成），也不会把长图
/// 解成远超显示尺寸的位图。视图必须已经摆好最终 frame（尺寸即入参来源）。
@MainActor
func tiebaPostLoadDisplayImage(
  _ url: URL?,
  targetSize: CGSize,
  cornerRadius: CGFloat,
  scale: CGFloat,
  into imageView: UIImageView,
  transition: Bool = false
) {
  guard let url, targetSize.width > 1, targetSize.height > 1 else {
    imageView.image = nil
    return
  }
  loadImage(
    with: TiebaNuke.secureURL(url),
    options: TiebaNuke.options(
      processor: TiebaNuke.displayProcessor(
        targetSize: targetSize,
        cornerRadius: cornerRadius,
        scale: scale
      ),
      transition: transition
    ),
    into: imageView
  )
}

/// 单图 fit 显示档（aspectFit 视图专用）：fit 缩放 + 圆角烘焙进位图（见
/// TiebaNuke.fitDisplayProcessor），视图侧不再 clipsToBounds。
@MainActor
func tiebaLoadFitDisplayImage(
  _ url: URL?,
  targetSize: CGSize,
  cornerRadius: CGFloat,
  scale: CGFloat,
  into imageView: UIImageView,
  transition: Bool = false
) {
  guard let url, targetSize.width > 1, targetSize.height > 1 else {
    imageView.image = nil
    return
  }
  loadImage(
    with: TiebaNuke.secureURL(url),
    options: TiebaNuke.options(
      processor: TiebaNuke.fitDisplayProcessor(
        targetSize: targetSize,
        cornerRadius: cornerRadius,
        scale: scale
      ),
      transition: transition
    ),
    into: imageView
  )
}

/// 在途 GIF 请求按**视图身份**登记（P2-5）：不登记就没法取消 —— 复用/换行后请求照跑，
/// 一个 GIF 的下载 + 多帧解码全白做，迟到回调还会去动已经换行的视图。
/// 只登记 Nuke 的 ImageTask（不持有视图，key 是 ObjectIdentifier）；token 用来判断
/// "这一格现在登记的还算不算自己"，避免新请求把旧请求的清理误删。
@MainActor private var tiebaGifLoads: [ObjectIdentifier: (token: UInt64, task: ImageTask)] = [:]
@MainActor private var tiebaGifLoadToken: UInt64 = 0

/// 取消该视图在途的 GIF 请求（复用/换行时调；没有在途请求就是空操作）。
@MainActor
func tiebaCancelGifLoad(_ view: TiebaGIFImageView) {
  tiebaGifLoads.removeValue(forKey: ObjectIdentifier(view))?.task.cancel()
}

/// GIF 播放档（Gifu 逐帧渲染）。GIF 请求必须无处理器：Resize/圆角烘焙都会把
/// 多帧重绘压成首帧（TiebaPhotoBrowser 文件头同结论）。数据源是 Nuke 默认解码器
/// 挂在 container.data 的原始 GIF 字节；到位后先落首帧静态底再异步起帧。
/// 帧按 targetSize×contentMode 重采样（Gifu shouldResizeFrames），缓冲窗
/// frameBufferSize 控内存；targetSize 未布局（≤1pt）时退全尺寸帧。
/// isStale 由调用方持行级身份判断（复用/换行后迟到的 GIF 不回贴）。
@MainActor
func tiebaLoadGifImage(
  _ url: URL,
  targetSize: CGSize,
  contentMode: UIView.ContentMode,
  frameBufferSize: Int,
  into view: TiebaGIFImageView,
  isStale: @escaping @MainActor () -> Bool
) {
  // 换图前释放上一个 GIF 的帧缓冲：play() 内部也会先 recycle()，这里显式再调一次
  // 是为了**换图失败/被取消**的路径也不会留下上一个 GIF 的帧（早退分支不走 play）。
  view.prepareForGIFReuse()
  view.clipsToBounds = true
  let key = ObjectIdentifier(view)
  tiebaGifLoadToken &+= 1
  let token = tiebaGifLoadToken
  // 同一格重复 load 先取消旧请求（与 tiebaLoadRowImage 的 cancelRequest 同纪律：
  // 取消的是 ImageTask 本身，下载/解码真的停，不只是不再 await）。
  tiebaGifLoads[key]?.task.cancel()
  // imageTask.response 给出完整 ImageResponse（container 里才有 GIF 原始字节）；
  // image(for:) 只回已解码的首帧位图。
  //
  // 优先级按"这一格现在在不在屏幕上"分档：UICollectionView 的预取趟会先把屏幕外的
  // cell 建出来（cellForItemAt → apply → layoutImages），它们也会来抢动图档；一帖 25 张
  // 动图合计 51MB（实测），屏幕外那些若按 normal 排队，屏幕上这几张就得排在它们后面
  //（表现："先划到的先播、后划到的迟迟不动"）。低优先级不会被丢，Nuke 只是把它排在后面 ——
  // 划到它时仍在队列里，只是晚一点。
  var request = ImageRequest(url: TiebaNuke.secureURL(url))
  request.priority = view.tiebaIsVisibleInWindow ? .normal : .low
  let imageTask = TiebaNuke.pipeline.imageTask(with: request)
  tiebaGifLoads[key] = (token, imageTask)
  Task { [weak view] in
    defer { if tiebaGifLoads[key]?.token == token { tiebaGifLoads[key] = nil } }
    guard
      let response = try? await imageTask.response,
      let view, !isStale()
    else { return }
    view.image = response.container.image
    guard let data = response.container.data else { return }
    // 首帧静态底已经赋值（上面一行），把它**当第 0 帧交给播放器**：否则播放器会为了
    // 第 0 帧再解一遍（实测 83 帧 / 2.83MB 的真实 GIF：首帧解码+重采样 4~45ms，白做），
    // 而那笔开销原来正好落在主线程上。查看器那条路径早就是这么做的（R3-3）。
    view.gifPlayer.play(
      data: data,
      into: view,
      targetSize: targetSize,
      contentMode: contentMode,
      frameBufferSize: frameBufferSize,
      firstFrame: view.image,
      // 08-08：同一个表情被转贴多次 / 同一张动图在屏上出现两遍时，解码结果与在途标记
      // 由共享池复用（键里还会带目标尺寸与 contentMode，尺寸不同的不会混用）。
      identity: url.absoluteString
    )
  }
}

//
// 行视图不自己实现头像：直接复用 TiebaForumViews 的 TiebaForumAvatarView
// （首字占位 + Nuke 取图）。它是 init 定尺视图（主贴 40 / 回复 36），尺寸变化
// 时由 configureAvatar 重建。
