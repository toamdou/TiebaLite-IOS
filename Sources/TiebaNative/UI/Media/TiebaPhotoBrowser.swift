//
//  TiebaPhotoBrowser.swift
//  TiebaNative
//
//  原生大图查看器（JXPhotoBrowser + Nuke）——替换 RN 侧
//  src/components/ImageViewer.tsx（1655 行：Modal + PagerView(SwiftUI TabView) +
//  Reanimated + 一堆 teardown 崩溃 workaround）。
//
//  全原生（2026-09-12 二期，零 TS/RN 面）：
//  - 展示链路：原生列表点击图片 → 本文件 present，items 由行模型 media/图片数组
//    值类型直构（TiebaPhotoItem），transition 矩形由被点图片视图 convert(to: nil)
//    得到（TiebaPhotoTransition）。不经 JS、不发事件（旧 TS 门面
//    TiebaPhotoBrowser.ts 已删除，模块注册同步移除）。
//  - 业务动作：保存图片 / 保存原图 / 分享全部在原生完成（PHPhotoLibrary 写
//    相册、UIActivityViewController 分享、Nuke 数据层下载原件字节）。
//    动作集合与旧查看器 VIEWER_IMAGE_ACTIONS 完全一致，不增不减。
//  - 事件出口 = present 的 onClose 回调（查看器完全关闭后回调一次）：宿主用它
//    恢复打开期间暂停的 Nuke 预取；没有静态事件总线、没有 JS 事件。
//
//  设计要点：
//  - 分页/复用/缩放全交给 JXPhotoBrowser：UICollectionView 分页 + 每页
//    JXZoomImageCell（UIScrollView 捏合/双击/平移），本文件不重写任何手势；
//  - 下拉/上滑退出 = 框架 Zoom 转场 + 本文件实现的 thumbnailViewAt（iOS Photos
//    "缩回原缩略图"）；源视图缺失/几何非法时框架自动降级 Fade（见
//    JXZoomPresentAnimator.swift:35-38 / JXZoomDismissAnimator.swift:31-38）。
//    多图行翻页后退出由宿主的 sourceFrameProvider 现算当前页矩形（初始页几何不变）。
//    上滑关闭由 vendor 框架原生支持（贴底判定，见 JXPhotoBrowserViewController
//    gestureRecognizerShouldBegin），封装层不再另挂 pan；
//  - 转场源几何：调用方矩形先在窗口层级里收敛到**被点图片自身的 image view**
//    （卡片/媒体容器矩形不再整卡起飞；解析不到才回落原矩形 + 截屏垫图）。
//  - 图片加载走 TiebaNuke.pipeline（并行任务落地的共享管线）：静态图按浏览器
//    像素尺寸降采样；缩略图（thumbUrl）先出、大图（url）后到，即旧查看器
//    的"两级加载"。全部 Nuke 调用收敛在 TiebaPhotoBrowserImageLoader 一处；
//    打开期间列表预取暂停（TiebaKindListView:727），本会话自带 prefetcher
//    以同一请求形态预取相邻页。
//  - GIF 会动：GIF 请求**不套** resizeProcessor（Resize 重绘会把多帧
//    压成首帧）。Nuke 默认解码器对 GIF 只产首帧 + 把原始字节挂在
//    ImageContainer.data（UIImageView 并不会自动播 GIF），播放由 Gifu
//    逐帧渲染承担（JXGIFObservedImageView，见 Vendor/JXPhotoBrowser 补丁）；
//    渐进解码的 isPreview 帧显式拒绝当终图（见 TiebaPhotoBrowserImageLoader）。
//  - 保存进度/结果用底部胶囊（TiebaPhotoBrowserPillView）：样式对齐旧查看器
//    styles.savePill（rgba(28,28,30,.88) / 圆角 18 / 白 14pt medium /
//    max(insets.bottom,16)+96 / 成功 2.2s 自动消失），并新增确定进度条。
//
//  与 RN 列表的桥（已废弃说明）：一期 JS 给一个窗口坐标矩形（transition.frame*），
//  原生建临时 UIImageView 当转场源缩略图。二期列表已原生，矩形来自真实图片
//  视图的窗口 frame（cell.convert），替身视图仍只承担"转场几何 + 垫图"职责
//  （垫图优先取源图片视图的已解码图，取不到才同步截屏；真缩略图在 Modal 底下、
//  无需揭示）。
//
//  ── 剩余缺口（原生二期无法闭合，问题与出路都写在这里）────────────────
//  1. 水印：imageWatermarkEnabled/imageWatermark 偏好只存在于 JS
//     （preferencesStore → unifiedDb），原生读不到 → 保存/分享不带水印。
//     出路：原生可读的偏好镜像（UserDefaults 或模块 setter）。TiebaImageWatermark
//     已有 applyWatermark 原生实现，拿到文本即可接。
//  2. 视频：视频行没有 media 数组（只有 poster），列表侧不上报图片命中、
//     仍走 rowTap -> JS 既有视频链路；本查看器不接视频 item。
//  3. 大 GIF 峰值内存：Gifu 按帧缓冲窗逐帧解码（查看页 setFrameBufferSize(8)，
//     不做全帧常驻），内存缓存里存的是首帧位图 + 原始 GIF 字节。超大 GIF 的
//     峰值 = 单帧位图 × 窗口，已显著低于"全帧常驻"。
//  4. 长图页下拉不退出：长图阅读模式 zoomScale > minimumZoomScale 被框架
//     下拉关闭守卫判定为"已缩放"，需点关闭按钮退出（旧查看器长图页同样只在
//     贴顶/贴底才移交退出）。
//
//  历史缺口（已闭合）：转场矩形不再依赖 JS measureInWindow（列表 cell 原生
//  convert）；多图带按下第几张不再丢（行视图 mediaHit + 内部 scroll offset）；
//  保存进度/胶囊提示、动作执行、GIF 动图均已原生；「保存原图」已接 originUrl
//  （origin 缺失时菜单不展示，对齐旧 JS showOriginalBtn）。
//

//  ── 手势接线（task-13 交付；事故回退后按逐处 edit 重新落盘）────────────
//  · 长图/缩放态下拉关闭：走**框架原路径 + 声明钩子**。Vendor/JXZoomImageCell.swift 暴露
//    allowsDismissWhileZoomed（默认 false），本文件 Cell 在长图页覆写为 true；
//    JXPhotoBrowserViewController 的守卫据此对"缩放态 + 下拉 + 贴顶"放行，跟手位移按 zoomScale 折算
//    （两处都带「本仓补丁」注释，可 grep 自查）。不这样做：长图 fit-width 页只能点关闭按钮退出（缺口 4）。
//  · 单击：框架裸 tap 已禁用，改 TiebaMultiIntentGestureRecognizer 的 .tapOnly（0.15s 上限）；
//    语义仍是 handleSingleTap → onSingleTap?()（**切 chrome 显隐，不是关闭**）。
//  · 明确不接线：TiebaDirectionalPan / TiebaWindowPan / TiebaInteractiveTransition（理由见 22 号记录）；
//    自研菜单容器与动作模型已按"系统更优"删除，ContextGesture/ControllerSourceView 保留未接线。

import JXPhotoBrowser
import Nuke
import UIKit

// MARK: - 对外门面（TiebaListView 等原生调用方使用）

/// 原生大图查看器门面。展示入口全部可从任意线程调用（内部自行切主线程）。
public enum TiebaPhotoBrowser {
  /// 当前会话（delegate 是 weak，必须由这里强持有到关闭完成）。
  nonisolated(unsafe) private static var activeSession: TiebaPhotoBrowserSession?

  /// 退出/转场时按“查看器页号”现算源图窗口矩形的查询（多图来源传入；单图/头像不传）。
  /// @MainActor：只有 JXPhotoBrowser 转场回调（主线程）会调用它。
  public typealias SourceFrameProvider = @MainActor @Sendable (Int) -> CGRect?

  /// 展示查看器。
  /// - Parameters:
  ///   - items: 值类型图片项（TiebaPhotoItem；调用方从行模型直构，不经字典编组）。
  ///   - initialIndex: 初始页（越界自动 clamp）
  ///   - transition: 转场起点（源图片视图窗口坐标 + 顶栏上下文标题）
  ///   - sourceImage: 被点那一格已加载的压缩图（权威转场源）。传了就用它做缩放动画
  ///     的载体；没传才退回窗口扫描找源图视图。
  ///   - sourceFrameProvider: 初始页以外的退出重算（多图行必须传，否则翻页后
  ///     退出退化为 Fade）；返回该页源图当前窗口矩形，拿不到返回 nil。
  ///   - onClose: 查看器完全关闭后的主线程回调（只回调一次），宿主用它恢复打开
  ///     期间暂停的状态（如列表预取）。
  ///   - onPresented: 转场展示完成（viewDidAppear，Zoom 动画结束/Reduce Motion
  ///     直显）后的主线程回调，只回调一次；宿主用它做展示后才该发生的收尾
  ///     （如列表揭示移位），不要用固定时长近似。
  /// - Returns: 是否受理。items 为空 / 已有会话 / 找不到宿主 VC → false。
  /// - Note: 非主线程调用时返回值语义为"请求已入队"，会话创建结果不回落。
  @discardableResult
  public static func present(
    items: [TiebaPhotoItem],
    initialIndex: Int,
    transition: TiebaPhotoTransition,
    sourceImage: UIImage? = nil,
    sourceFrameProvider: SourceFrameProvider? = nil,
    onClose: (@MainActor @Sendable () -> Void)? = nil,
    onPresented: (@MainActor @Sendable () -> Void)? = nil
  ) -> Bool {
    guard !items.isEmpty else { return false }
    let index = max(0, min(initialIndex, items.count - 1))
    // items/transition 都是 Sendable 值类型：present 允许任意线程调用，主线程
    // 闭包只带值，不再有字典跨隔离域（旧 [String: Any] 入参已删）。
    if Thread.isMainThread {
      return startSession(
        items: items,
        initialIndex: index,
        transition: transition,
        sourceImage: sourceImage,
        sourceFrameProvider: sourceFrameProvider,
        onClose: onClose,
        onPresented: onPresented
      )
    }
    DispatchQueue.main.async {
      _ = startSession(
        items: items,
        initialIndex: index,
        transition: transition,
        sourceImage: sourceImage,
        sourceFrameProvider: sourceFrameProvider,
        onClose: onClose,
        onPresented: onPresented
      )
    }
    return true
  }

  // MARK: 内部

  private static func startSession(
    items: [TiebaPhotoItem],
    initialIndex: Int,
    transition: TiebaPhotoTransition,
    sourceImage: UIImage?,
    sourceFrameProvider: SourceFrameProvider?,
    onClose: (@MainActor @Sendable () -> Void)?,
    onPresented: (@MainActor @Sendable () -> Void)?
  ) -> Bool {
    guard activeSession == nil else { return false }
    // 会话是 @MainActor（见类注释）：present 允许任意线程调用，这里用
    // assumeIsolated 把"startSession 只在主线程执行"的既有契约显式化（调用方
    // 要么已在主线程、要么经 DispatchQueue.main 派发）；捕获的 items/transition
    // 都是 Sendable 值类型，host 在闭包内取，不产生跨域发送。
    return MainActor.assumeIsolated {
      guard let host = TiebaTopViewController.find() else { return false }
      let session = TiebaPhotoBrowserSession(
        items: items,
        initialIndex: initialIndex,
        transition: transition,
        sourceImage: sourceImage,
        sourceFrameProvider: sourceFrameProvider,
        onClose: onClose,
        onPresented: onPresented,
        host: host
      )
      guard session.start() else { return false }
      activeSession = session
      return true
    }
  }

  /// 会话关闭完成回调（由 session 调用；只清静态强引用）。
  static func sessionDidFinish() {
    activeSession = nil
  }

  /// 主线程收束入口：work 声明为 @MainActor @Sendable，闭包体内的会话调用
  /// 与主 actor 同域；已在主线程时用 assumeIsolated 直接执行（同步、无派发），
  /// 否则派到主队列再 assumeIsolated（DispatchQueue.main.async 保证主线程）。
  private static func onMain(_ work: @escaping @MainActor @Sendable () -> Void) {
    if Thread.isMainThread {
      MainActor.assumeIsolated(work)
    } else {
      DispatchQueue.main.async { MainActor.assumeIsolated(work) }
    }
  }
}

// MARK: - 数据模型

/// item 的值类型投影；调用方（列表/帖子页/吧页/资料页）从行模型直构，
/// url 非法的条目由调用方丢弃（不再有字典编组与解析回值）。
/// public + Sendable：present（公开入口）的入参，跨主队列派发只带值。
