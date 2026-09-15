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
//    animatedImage 压成单帧），走 Nuke 默认解码器的多帧 UIImage（iOS 的
//    UIImage(data:) 对 GIF 返回动画图，UIImageView 直接播放）；渐进解码的
//    isPreview 帧显式拒绝当终图（见 TiebaPhotoBrowserImageLoader）。
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
//  3. 大 GIF 全帧常驻内存：Nuke 解码产物 + 内存缓存都是全尺寸多帧位图，
//     超大 GIF 会抬高峰值内存（无逐帧上限）。出路：自定义 ImageContainer.data
//     渲染器 + CGImageSource 逐帧。
//  4. 长图页下拉不退出：长图阅读模式 zoomScale > minimumZoomScale 被框架
//     下拉关闭守卫判定为"已缩放"，需点关闭按钮退出（旧查看器长图页同样只在
//     贴顶/贴底才移交退出）。
//  5. dismiss/scrollTo 两个 public 入口当前无调用方（旧桥注册已删），
//     保留给原生宿主。
//
//  历史缺口（已闭合）：转场矩形不再依赖 JS measureInWindow（列表 cell 原生
//  convert）；多图带按下第几张不再丢（行视图 mediaHit + 内部 scroll offset）；
//  保存进度/胶囊提示、动作执行、GIF 动图均已原生；「保存原图」已接 originUrl
//  （origin 缺失时菜单不展示，对齐旧 JS showOriginalBtn）。
//

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

  /// 关闭查看器（Zoom 转场 → 缩回源缩略图）。
  /// 宿主可按需调用（当前无调用方，见文件头缺口 5）。
  public static func dismiss(animated: Bool) {
    onMain {
      activeSession?.dismiss(animated: animated)
    }
  }

  /// 程序化翻页（越界忽略；循环模式下框架自动就近映射真实索引）。
  /// - Note: 同 dismiss，仅供 photoBrowserScrollTo 注册引用，随注册删除。
  public static func scrollTo(index: Int, animated: Bool) {
    onMain {
      activeSession?.browser?.scrollToPage(at: index, animated: animated)
    }
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
public struct TiebaPhotoItem: Sendable {
  let url: URL
  let thumbUrl: URL?
  /// 原图档（行模型 originURL）：nil = 该图没有原图档，菜单不展示「保存原图」。
  let originUrl: URL?
  let isGif: Bool
  let isLong: Bool
  /// 服务端「显示查看原图按钮」（Media.show_original_btn，proto 字段 20；GIF 恒
  /// 为 0）：true 且该页当前展示的不是原图时，菜单才出现「查看原图」。
  let canViewOriginal: Bool
  let width: CGFloat
  let height: CGFloat

  public init(
    url: URL,
    thumbUrl: URL?,
    originUrl: URL? = nil,
    isGif: Bool,
    isLong: Bool,
    width: Double,
    height: Double,
    canViewOriginal: Bool = false
  ) {
    self.url = url
    self.thumbUrl = (thumbUrl != url) ? thumbUrl : nil
    // 与原图档同 URL（GIF/原档模式、src==originSrc 的帖）：视为没有独立原图档，
    // 否则菜单会多出一个点了什么都不换的「查看原图」。
    self.originUrl = (originUrl != url) ? originUrl : nil
    self.isGif = isGif
    self.isLong = isLong
    self.canViewOriginal = canViewOriginal
    self.width = CGFloat(width)
    self.height = CGFloat(height)
  }

  /// 切到原图档（长按「查看原图」用）：显示 URL 换成原图、thumbUrl 保留旧档垫图、
  /// canViewOriginal 置 false（该页已在显示原图，菜单项随之消失）。
  func showingOriginal() -> TiebaPhotoItem {
    guard let originUrl else { return self }
    return TiebaPhotoItem(
      url: originUrl,
      thumbUrl: thumbUrl ?? url,
      originUrl: originUrl,
      isGif: isGif,
      isLong: isLong,
      width: width,
      height: height,
      canViewOriginal: false
    )
  }

  /// 帖子行图片 → 查看器项（档位选择与行内图片展示同源：GIF / 原档模式取原图，
  /// 其余取显示档、空则回落原图；url 非法 → nil 丢弃）。
  init?(image: TiebaThreadImage, preferences: TiebaPostPreferences) {
    let origin = image.originSrc.isEmpty ? image.src : image.originSrc
    let raw = image.isGif || preferences.dataSaverMode == "origin"
      ? origin
      : (image.src.isEmpty ? origin : image.src)
    guard let url = TiebaPhotoItem.normalizedURL(raw) else { return nil }
    let thumbRaw = TiebaPostRowText.displayURL(image, preferences: preferences)?
      .absoluteString ?? raw
    self.init(
      url: url,
      thumbUrl: TiebaPhotoItem.normalizedURL(thumbRaw),
      originUrl: TiebaPhotoItem.normalizedURL(origin),
      isGif: image.isGif,
      isLong: image.isTall,
      width: image.width,
      height: image.height,
      canViewOriginal: image.showOriginalBtn
    )
  }

  /// 长图判据（与 RN 侧 ImageViewer.tsx:318-330 同规则，仅在有真实尺寸
  /// 时生效；服务端 isLongPic 对"稍高于屏"的图会误判，故几何为准）：
  /// fit-width 显示高度 > 1.3 倍容器高。尺寸未知时退化为 isLong 标记。
  func isLongImage(in containerSize: CGSize) -> Bool {
    guard width > 0, height > 0, containerSize.width > 0, containerSize.height > 0 else {
      return isLong
    }
    return (containerSize.width * height) / width > containerSize.height * 1.3
  }

  /// 贴吧图源 http:// 一律升级 https（与 TiebaNuke.secureURL 同约定）。
  static func normalizedURL(_ raw: String) -> URL? {
    let upgraded = raw.hasPrefix("http://") ? "https://" + raw.dropFirst("http://".count) : raw
    return URL(string: upgraded)
  }
}

/// 转场起点（值类型；present 允许从任意线程调用，只把 Sendable 值送进主线程）。
/// frame = 源图片视图的窗口坐标矩形（视图测量），宽/高 < 2 视为无起点（框架 Fade）。
/// public：present 的入参形态（与 TiebaPhotoItem 同一公开面）。
public struct TiebaPhotoTransition: Sendable {
  let frame: CGRect?
  let contextTitle: String?

  public init(frame: CGRect?, contextTitle: String?) {
    self.frame = frame
    self.contextTitle = contextTitle
  }

  /// 页头 payload 的测量矩形（frameX/Y/W/H 四键齐且宽高 > 0）→ frame；缺键/非正
  /// 返回 nil。字典只在这条"视图测量几何"通路上存在（协议 onAction 约定），
  /// 领域数据一律不进字典。
  static func measuredFrame(in payload: [String: Any]) -> CGRect? {
    guard let x = (payload["frameX"] as? NSNumber)?.doubleValue,
          let y = (payload["frameY"] as? NSNumber)?.doubleValue,
          let w = (payload["frameW"] as? NSNumber)?.doubleValue,
          let h = (payload["frameH"] as? NSNumber)?.doubleValue,
          w > 0, h > 0 else { return nil }
    return CGRect(x: x, y: y, width: w, height: h)
  }
}

// MARK: - 错误

enum TiebaPhotoBrowserError: LocalizedError {
  case permissionDenied
  case saveFailed
  case invalidImageData
  case incompleteGif

  var errorDescription: String? {
    switch self {
    case .permissionDenied: return "PERMISSION_DENIED"
    case .saveFailed: return "无法保存图片到相册"
    case .invalidImageData: return "图片数据无效"
    case .incompleteGif: return "动图数据不完整"
    }
  }
}

// MARK: - Nuke 接缝

/// TiebaNuke（并行任务）唯一接缝：共享 pipeline + 目标像素尺寸降采样。
/// Nuke 13 API 依据 vendored 源码 Sources/Nuke（ImageRequest(url:processors:) +
/// ImagePipeline.image(for:) async / imageTask(with:).response / data(for:)；
/// 闭包式 loadData 无 queue 参数，见 Deprecated.swift）。
/// ⚠️ 依赖：TiebaNative.podspec 必须加 s.dependency 'Nuke/Core'，否则 import 失败。
enum TiebaPhotoBrowserImageLoader {
  /// 载入一张图（已解码、可直接上屏）。
  ///
  /// GIF 分支的两个硬约束（依据 vendored 源码，勿凭记忆改）：
  /// - **不套 resizeProcessor**：ImageProcessors.Resize 会对解码结果重绘
  ///   （CoreGraphics），多帧 animatedImage 只剩第一帧 → 动图变静图。无处理器
  ///   请求走 Nuke 默认解码器，GIF 路径是 UIImage(data:scale:)
  ///   （ios/vendor/Nuke/Sources/Nuke/Decoding/ImageDecoders+Default.swift:70-73、
  ///   167-173），iOS 上即多帧 animatedImage，data 也保留在 ImageContainer 里。
  /// - **isPreview 帧不是终图**：渐进解码的 GIF 会先发一帧静态预览
  ///   （同文件 :84-87，isPreview: true）。本管线 progressive 关闭，正常到不了，
  ///   但这里显式拒绝：拿数据任务的原始字节重新解码（data 任务不会返回预览帧）。
  static func load(_ url: URL, pixelSize: CGSize, isGif: Bool) async throws -> UIImage {
    if isGif {
      let request = ImageRequest(url: TiebaNuke.secureURL(url))
      let response = try await TiebaNuke.pipeline.imageTask(with: request).response
      if !response.isPreview {
        return response.image
      }
      let (data, _) = try await TiebaNuke.pipeline.data(for: request)
      guard let image = UIImage(data: data) else {
        throw TiebaPhotoBrowserError.incompleteGif
      }
      return image
    }
    let request = ImageRequest(
      url: TiebaNuke.secureURL(url),
      processors: [TiebaNuke.resizeProcessor(targetPixelSize: Self.target(pixelSize))]
    )
    return try await TiebaNuke.pipeline.image(for: request)
  }

  /// 展示请求（预取与加载必须同形态：同 URL + 同处理器，否则内存缓存键不同）。
  /// GIF 不套处理器（见 load 的约束）。
  static func request(_ item: TiebaPhotoItem, pixelSize: CGSize) -> ImageRequest {
    let url = TiebaNuke.secureURL(item.url)
    guard !item.isGif else { return ImageRequest(url: url) }
    return ImageRequest(
      url: url,
      processors: [TiebaNuke.resizeProcessor(targetPixelSize: Self.target(pixelSize))]
    )
  }

  /// 目标像素尺寸下限 1×1（0 会被 Resize 处理器视为无效）。
  private static func target(_ pixelSize: CGSize) -> CGSize {
    CGSize(width: max(1, pixelSize.width), height: max(1, pixelSize.height))
  }

  /// 原始字节 async 版（信息流图片动作与查看器共用：同一管线 → Referer/DataCache
  /// 与展示路径一致；不要再手写 URLSession，见 TiebaNuke 文件头）。
  static func data(_ url: URL) async throws -> Data {
    let request = ImageRequest(url: TiebaNuke.secureURL(url))
    let (data, _) = try await TiebaNuke.pipeline.data(for: request)
    return data
  }

  /// 原始字节（保存/分享用：GIF 保动画、图片保原始质量）。走同一管线的数据
  /// 层 → Referer/磁盘缓存与展示路径一致；progress 在主线程回调 0…1。
  /// Nuke 13：闭包式 loadData 去掉了 `queue:` 参数（回调固定 MainActor，
  /// 形参类型为 @MainActor @Sendable；Nuke 12 才有 queue 形参）。
  /// 两个闭包形参同样标 `@MainActor @Sendable` 与 Nuke 的形参对齐：它们被
  /// Nuke 的主 actor 闭包捕获，不标就是"发送非 Sendable 闭包"。
  static func data(
    _ url: URL,
    progress: (@MainActor @Sendable (Double) -> Void)?,
    completion: @escaping @MainActor @Sendable (Result<Data, Error>) -> Void
  ) {
    let request = ImageRequest(url: TiebaNuke.secureURL(url))
    TiebaNuke.pipeline.loadData(
      with: request,
      progress: { completed, total in
        guard total > 0 else { return }
        progress?(min(max(Double(completed) / Double(total), 0), 1))
      },
      completion: { result in
        switch result {
        case .success(let payload):
          completion(.success(payload.data))
        case .failure(let error):
          completion(.failure(error))
        }
      }
    )
  }
}

// MARK: - 会话（JXPhotoBrowserDelegate + 生命周期/事件）

/// @MainActor：会话从创建到销毁都绑在 UIKit 上（present/转场/动画/delegate
/// 回调），Swift 6 下不隔离的话，UIView.animate、Nuke 的 @MainActor @Sendable
/// 回调里捕获 self 都会被判 sending 'self'。入口（present/startSession/onMain）
/// 负责把调用收在主线程；delegate 用 @preconcurrency 一致性——JXPhotoBrowser
/// 4.x 是未标注并发（Swift 5 模式编译）的第三方 UI 协议，其回调按框架契约在
/// 主线程派发，一致性隔离不匹配只降级不改变运行时行为。
@MainActor
final class TiebaPhotoBrowserSession: NSObject, @preconcurrency JXPhotoBrowserDelegate {
  let items: [TiebaPhotoItem]
  let initialIndex: Int
  let contextTitle: String?
  /// 手动「查看原图」的页（下标集合）：这些页改用原图档重载，菜单项随之消失
  ///（旧 JS ImageViewer 的 manualOriginalPages，逐页生效、翻页不回退）。
  private var manualOriginalPages: Set<Int> = []
  private weak var host: UIViewController?
  private(set) var browser: TiebaPhotoBrowserViewController?
  private let actions = TiebaPhotoBrowserActionController()

  private let transitionFrame: CGRect?
  /// 初始页以外的退出重算查询（见 SourceFrameProvider）；nil = 只认初始页几何。
  private let sourceFrameProvider: TiebaPhotoBrowser.SourceFrameProvider?
  /// 被点那一格已加载的压缩图（权威转场源）；nil = 退回窗口扫描找源图视图。
  private let sourceImage: UIImage?
  /// 展示完成回调（见 TiebaPhotoBrowser.present）；触发一次后即清空。
  private var onPresented: (@MainActor @Sendable () -> Void)?
  /// 关闭回调（见 TiebaPhotoBrowser.present）；触发一次即丢（会话随即释放）。
  private var onClose: (@MainActor @Sendable () -> Void)?
  private var sourceThumbnailView: TiebaPhotoSourceThumbnailView?
  /// 安装时的替身几何：翻回初始页且宿主算不出当前矩形时恢复。
  private var sourceThumbnailInitialFrame: CGRect?
  /// 进场黑底（撤除见 removePresentBackdrop）。
  private var presentBackdrop: UIView?

  /// 会话级预取器：列表预取在查看器打开期间暂停（TiebaKindListView:727），
  /// 查看器自己按同一像素尺寸预取相邻页，翻页不再空转等 willDisplay 才发请求。
  private let prefetcher = TiebaNuke.makePrefetcher()

  private var chrome: TiebaPhotoBrowserChromeOverlay?
  private var indicator: JXPageIndicatorOverlay?
  private var chromeVisible = true
  private var chromeAutoHideWorkItem: DispatchWorkItem?
  private var lastSafeAreaInsets: UIEdgeInsets = .zero
  private var didFinish = false

  /// 长按菜单项 = 旧查看器 VIEWER_IMAGE_ACTIONS（ImageViewer.tsx:74-78）：
  /// 保存 / 保存原图 / 分享 / 查看原图（末项逐页追加，见 ImageViewer.tsx:1282-1288）。
  /// 动作在原生执行（TiebaPhotoBrowserActionController），不再上报 JS；「保存原图」
  /// 需要 originUrl、「查看原图」需要服务端 showOriginalBtn（缺失时该项不展示，
  /// 见 TiebaPhotoItem）。
  static let menuActions: [(id: String, title: String, icon: String)] = [
    (id: "save", title: "保存图片", icon: "square.and.arrow.down"),
    (id: "save-original", title: "保存原图", icon: "arrow.down.to.line"),
    (id: "view-original", title: "查看原图", icon: "photo"),
    (id: "share", title: "分享图片", icon: "square.and.arrow.up"),
  ]

  init(
    items: [TiebaPhotoItem],
    initialIndex: Int,
    transition: TiebaPhotoTransition,
    sourceImage: UIImage?,
    sourceFrameProvider: TiebaPhotoBrowser.SourceFrameProvider?,
    onClose: (@MainActor @Sendable () -> Void)?,
    onPresented: (@MainActor @Sendable () -> Void)?,
    host: UIViewController
  ) {
    self.items = items
    self.sourceImage = sourceImage
    self.initialIndex = initialIndex
    self.host = host
    self.contextTitle = transition.contextTitle
    self.transitionFrame = transition.frame
    self.sourceFrameProvider = sourceFrameProvider
    self.onClose = onClose
    self.onPresented = onPresented
    super.init()
  }

  // MARK: 启动 / 收尾

  func start() -> Bool {
    guard let host else { return false }
    // UIViewController.view 在 Swift 里是隐式解包可选：显式标注类型避免
    // `host.view.window` 被推成 Optional 链。
    let hostView: UIView = host.view
    guard hostView.window != nil else { return false }

    let browser = TiebaPhotoBrowserViewController()
    browser.delegate = self
    browser.initialIndex = initialIndex
    // 减少动态：直接无动画进出（旧查看器 reduceMotion 下也是瞬时开关）。
    browser.transitionType = UIAccessibility.isReduceMotionEnabled ? .none : .zoom
    browser.scrollDirection = .horizontal
    // 循环翻页至少要两张：单张会被循环虚拟数据源复制成 10 个同图页，滑一下只是
    // 同一张重载一次（长图尤其明显）。回弹拖动一并关掉——单张不该有左右位移。
    let hasMultipleItems = items.count > 1
    browser.isLoopingEnabled = hasMultipleItems
    browser.collectionView.bounces = hasMultipleItems
    browser.isDismissGestureEnabled = true
    browser.register(
      TiebaPhotoBrowserImageCell.self,
      forReuseIdentifier: TiebaPhotoBrowserImageCell.tiebaReuseIdentifier
    )
    browser.onDismissed = { [weak self] in self?.finish() }
    browser.onSafeAreaInsetsDidChange = { [weak self] insets in self?.applySafeArea(insets) }
    browser.onDidAppear = { [weak self] in
      guard let self else { return }
      self.removePresentBackdrop()
      self.prefetchNeighbors(of: self.browser?.pageIndex ?? self.initialIndex)
      // 展示完成回调只发一次（viewDidAppear 在转场动画结束后才到）。
      let presented = self.onPresented
      self.onPresented = nil
      presented?()
    }
    self.browser = browser

    installSourceThumbnail(hostView: hostView)
    installPresentBackdrop(on: browser)

    let indicator = JXPageIndicatorOverlay()
    indicator.hidesForSinglePage = true
    indicator.position = .bottom(padding: 28)
    browser.addOverlay(indicator)
    self.indicator = indicator

    let chrome = TiebaPhotoBrowserChromeOverlay(title: contextTitle)
    chrome.onClose = { [weak self] in self?.browser?.dismissSelf() }
    chrome.onAction = { [weak self] action in
      guard let self else { return }
      let index = self.browser?.pageIndex ?? self.initialIndex
      guard self.items.indices.contains(index) else { return }
      self.actions.perform(action: action, item: self.items[index])
    }
    browser.addOverlay(chrome)
    self.chrome = chrome

    let events = TiebaPhotoBrowserEventOverlay()
    events.onPageChanged = { [weak self] index in
      guard let self else { return }
      self.scheduleChromeAutoHide()
      self.prefetchNeighbors(of: index)
    }
    browser.addOverlay(events)

    // 保存/分享胶囊提示（进度/结果）挂在浏览器 view 顶层。
    let pillHost: UIView = browser.view
    actions.presenter = browser
    actions.attach(to: pillHost)

    browser.present(from: host)
    // 防御：宿主已在转场中/被别的 present 抢占时 UIKit 会丢弃本次展示，
    // 此时不会有 viewDidDisappear 回调 → 静态会话永不释放（后续 present
    // 全被拒）。下一 runloop 校验 present 链，未接上就按关闭收尾。
    DispatchQueue.main.async { [weak self] in
      guard let self, let browser = self.browser else { return }
      if browser.presentingViewController == nil && !browser.isBeingPresented {
        self.finish()
      }
    }
    return true
  }

  func dismiss(animated: Bool) {
    guard let browser else { return }
    if !animated {
      // 关掉转场代理，让 UIKit 走无动画拆除（reduceMotion 直关路径）。
      browser.transitioningDelegate = nil
      browser.transitionType = .none
    }
    browser.dismissSelf()
  }

  private func finish() {
    guard !didFinish else { return }
    didFinish = true
    sourceThumbnailView?.removeFromSuperview()
    sourceThumbnailView = nil
    removePresentBackdrop()
    prefetcher.stopPrefetching()
    chromeAutoHideWorkItem?.cancel()
    chromeAutoHideWorkItem = nil
    browser = nil
    // 关闭回调（宿主恢复打开期间暂停的状态）：与旧 onEvent 同时点、同线程（主）。
    let close = onClose
    onClose = nil
    close?()
    TiebaPhotoBrowser.sessionDidFinish()
  }

  // MARK: 源缩略图桥

  /// 建临时源缩略图：几何 + 垫图取自**被点那一格已加载的压缩图**（调用方点名，
  /// 权威源；横滑带格 / 单图 / 九宫格同一条路径）。它恒隐藏，只承担转场起止几何，
  /// 由 JXZoomPresentAnimator 拿它的 image 做"缩略图放大到全屏"的缩放动画。
  ///
  /// ⚠️ 源图拿不到时**不装缩略图**（框架降级 Fade）。绝不按矩形截屏：那截到的是
  /// "那个矩形位置上的屏幕内容"，源图未解析时会露出整张卡片（真机实证）。
  private func installSourceThumbnail(hostView: UIView) {
    guard let window = hostView.window else { return }
    let resolved: (frame: CGRect, image: UIImage)
    if let sourceImage, let frame = transitionFrame, frame.width >= 2, frame.height >= 2 {
      resolved = (frame, sourceImage)
    } else if let scanned = transitionSource(in: window), let image = scanned.image {
      resolved = (scanned.frame, image)
    } else {
      return
    }

    let thumbView = TiebaPhotoSourceThumbnailView(frame: hostView.convert(resolved.frame, from: nil))
    thumbView.image = resolved.image
    thumbView.contentMode = .scaleAspectFill
    thumbView.clipsToBounds = true
    thumbView.backgroundColor = .clear
    thumbView.isUserInteractionEnabled = false
    thumbView.isHidden = true
    hostView.addSubview(thumbView)
    sourceThumbnailView = thumbView
    // 初始页几何快照：翻回第一页/重算失败时恢复（不退回被点图的矩形）。
    sourceThumbnailInitialFrame = thumbView.frame
  }

  /// 转场源 = 被点图片视图的窗口 frame + 已解码图（免截屏、免下载）。
  /// 矩形若是卡片/媒体容器（图片视图完整落在其中）→ 连几何一起收敛到图片视图；
  /// 若是揭示移位后的目标位（图片视图与矩形只差一个纵向位移）→ 几何保留矩形
  /// （退出飞回才落在已就位处），垫图仍换真图，避免把矩形里的文字截进去。
  /// 都解析不到（未加载/非图片）→ (原矩形, 无图)，调用方矩形本身就是合法几何。
  ///
  /// ⚠️ 顺序是"同尺寸最近"优先、"完整落在矩形内"兜底：移位后的矩形容不下真图
  /// （两者差一个纵向位移），而卡片里的吧头像/角标小图恰好完整落在矩形内——反过来
  /// 先做 contained 就会拿吧头像当转场源（2026-09-15 用户报"点被屏幕底边裁掉的图，
  /// 先弹出吧头像再显示真实图片"）。
  private func transitionSource(in window: UIWindow) -> (frame: CGRect, image: UIImage?)? {
    guard let rect = transitionFrame, rect.width >= 2, rect.height >= 2,
          rect.width.isFinite, rect.height.isFinite else { return nil }
    if let near = TiebaPhotoBrowserSession.imageView(matching: rect, in: window) {
      return (rect, near.image)
    }
    if let contained = TiebaPhotoBrowserSession.imageView(containedIn: rect, in: window) {
      return (contained.convert(contained.bounds, to: nil), contained.image)
    }
    return (rect, nil)
  }

  /// 窗口层级里"完整落在 rect 内"的图片视图（有图、可见）：先要命中矩形中心
  /// 的（容器矩形里可能有多格），再比面积（卡片里还有头像/角标小图标）。
  private static func imageView(containedIn rect: CGRect, in window: UIWindow) -> UIImageView? {
    let container = rect.insetBy(dx: -1, dy: -1)
    let center = CGPoint(x: rect.midX, y: rect.midY)
    return bestImageView(in: window) { _, frame in
      guard container.contains(frame) else { return nil }
      let area = frame.width * frame.height
      return frame.contains(center) ? 1e12 + area : area
    }
  }

  /// 与 rect 同尺寸、离 rect 中心最近的可见图片视图（尺寸差 ≤2pt）：揭示移位后
  /// 的矩形只与真图差一个纵向位移，取最近者避免抓到别处尺寸相同的图。
  private static func imageView(matching rect: CGRect, in window: UIWindow) -> UIImageView? {
    let center = CGPoint(x: rect.midX, y: rect.midY)
    return bestImageView(in: window) { _, frame in
      guard abs(frame.width - rect.width) <= 2, abs(frame.height - rect.height) <= 2 else {
        return nil
      }
      return -hypot(frame.midX - center.x, frame.midY - center.y)
    }
  }

  /// 遍历窗口层级里可见、有图、尺寸非空的图片视图，交给 score 打分取最大者
  /// （score 返回 nil = 不合格）。窗口树数百个视图，present 一次的量级。
  private static func bestImageView(
    in window: UIWindow,
    score: (UIImageView, CGRect) -> CGFloat?
  ) -> UIImageView? {
    var best: (view: UIImageView, score: CGFloat)?
    func walk(_ view: UIView) {
      for sub in view.subviews where !sub.isHidden && sub.alpha > 0.01 {
        if let imageView = sub as? UIImageView, imageView.image != nil, !imageView.bounds.isEmpty,
           let value = score(imageView, sub.convert(sub.bounds, to: window)),
           best == nil || value > best!.score {
          best = (imageView, value)
        }
        walk(sub)
      }
    }
    walk(window)
    return best?.view
  }

  static func displayScale(for view: UIView) -> CGFloat {
    if let scale = view.window?.screen.scale, scale > 0 { return scale }
    let traitScale = view.traitCollection.displayScale
    return traitScale > 0 ? traitScale : 1
  }

  // MARK: 进场黑底

  /// 框架 Zoom 进场从 clear 渐变到 black（JXZoomPresentAnimator.swift:75），这
  /// 0.25s 下层列表的卡片（连文字）会透出来，像"先飞卡片再飞图"。垫一层不透明
  /// 黑底把进场起始帧限成"源图 + 黑底"，进场一结束即撤（下拉的渐透手感不变）。
  private func installPresentBackdrop(on browser: JXPhotoBrowserViewController) {
    let backdrop = UIView()
    backdrop.backgroundColor = .black
    backdrop.frame = browser.view.bounds
    backdrop.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    backdrop.isUserInteractionEnabled = false
    browser.view.insertSubview(backdrop, at: 0)
    presentBackdrop = backdrop
  }

  private func removePresentBackdrop() {
    presentBackdrop?.removeFromSuperview()
    presentBackdrop = nil
  }

  // MARK: 相邻页预取

  /// 预取 index ± 1（循环模式下取环绕页）：请求形态必须与展示完全一致
  /// （同一 URL + 同一处理器），否则内存缓存键不同、预取无效；页码变化重置任务集。
  private func prefetchNeighbors(of index: Int) {
    guard let browser, items.count > 1 else {
      prefetcher.stopPrefetching()
      return
    }
    let pixelSize = downsamplingPixelSize(for: browser)
    var indexes = Set<Int>()
    for offset in [-1, 1] {
      let neighbor = (index + offset + items.count) % items.count
      indexes.insert(neighbor)
    }
    indexes.remove(index)
    prefetcher.stopPrefetching()
    prefetcher.startPrefetching(
      with: indexes.map { TiebaPhotoBrowserImageLoader.request(items[$0], pixelSize: pixelSize) }
    )
  }

  // MARK: JXPhotoBrowserDelegate

  func numberOfItems(in browser: JXPhotoBrowserViewController) -> Int {
    items.count
  }

  func photoBrowser(
    _ browser: JXPhotoBrowserViewController,
    cellForItemAt index: Int,
    at indexPath: IndexPath
  ) -> JXPhotoBrowserAnyCell {
    let cell = browser.dequeueReusableCell(
      withReuseIdentifier: TiebaPhotoBrowserImageCell.tiebaReuseIdentifier,
      for: indexPath
    )
    if let imageCell = cell as? TiebaPhotoBrowserImageCell {
      imageCell.onSingleTap = { [weak self] in self?.toggleChrome() }
      imageCell.onMenuAction = { [weak self] action in
        guard let self, self.items.indices.contains(index) else { return }
        // 「查看原图」是视图状态（逐页切档 + 重载），不是保存/分享那类动作。
        if action == "view-original" {
          self.showOriginal(at: index)
          return
        }
        self.actions.perform(action: action, item: self.items[index])
      }
      imageCell.onLoadFailed = { [weak self] in self?.actions.showTransientFailure("图片加载失败") }
      imageCell.onDismissInteractionChange = { [weak self] interacting in
        self?.handleDismissInteraction(interacting)
      }
    }
    return cell
  }

  func photoBrowser(
    _ browser: JXPhotoBrowserViewController,
    willDisplay cell: JXPhotoBrowserAnyCell,
    at index: Int
  ) {
    guard let imageCell = cell as? TiebaPhotoBrowserImageCell,
          items.indices.contains(index) else { return }
    imageCell.configure(
      item: displayItem(at: index),
      index: index,
      targetPixelSize: downsamplingPixelSize(for: browser),
      containerSize: browser.view.bounds.size
    )
  }

  /// 该页实际要展示的项：手动「查看原图」的页换成原图档（其余页原样）。切档后
  /// canViewOriginal 变 false → 菜单里「查看原图」消失（与旧 JS 判据一致）。
  private func displayItem(at index: Int) -> TiebaPhotoItem {
    guard manualOriginalPages.contains(index) else { return items[index] }
    return items[index].showingOriginal()
  }

  /// 长按「查看原图」：记下该页改用原图档，然后整页重载（JXPhotoBrowser 的
  /// reloadData 保当前页与循环位置，会重新走 willDisplay → 用原图档配置）。
  private func showOriginal(at index: Int) {
    guard items.indices.contains(index), items[index].originUrl != nil,
          manualOriginalPages.insert(index).inserted else { return }
    browser?.reloadData()
  }

  func photoBrowser(
    _ browser: JXPhotoBrowserViewController,
    didEndDisplaying cell: JXPhotoBrowserAnyCell,
    at index: Int
  ) {
    (cell as? TiebaPhotoBrowserImageCell)?.cancelLoading()
  }

  /// Zoom 转场源视图：**转场当下**向宿主现算当前图的窗口矩形（翻页后 / 列表揭示
  /// 移位后都认最新几何）；算不到、且是初始页才退回安装时快照。
  ///
  /// ⚠️ 初始页原来恒用安装时矩形：揭示移位（展示后 0.35s 滚列表）没落定、或期间
  /// 列表又动过，大图就会飞回"原位置隔壁"再闪回真缩略图（真机实证）。
  /// 其余页算不到 → nil，框架降级 Fade（绝不能退回被点图的矩形：那会飞回错误的图）。
  func photoBrowser(_ browser: JXPhotoBrowserViewController, thumbnailViewAt index: Int) -> UIView? {
    guard let thumbnail = sourceThumbnailView else { return nil }
    if let container = thumbnail.superview,
       let rect = sourceFrameProvider?(index),
       rect.origin.x.isFinite, rect.origin.y.isFinite,
       rect.width.isFinite, rect.height.isFinite,
       rect.width >= 2, rect.height >= 2 {
      thumbnail.frame = container.convert(rect, from: nil)
      return thumbnail
    }
    guard index == initialIndex, let frame = sourceThumbnailInitialFrame else { return nil }
    thumbnail.frame = frame
    return thumbnail
  }

  /// 有意覆盖为"恒隐藏"：临时视图只是转场几何/图像载体，屏上真缩略图由原生
  /// 列表持有（Modal 底下本来就在，无需揭示）。默认实现会在转场时显隐该视图——
  /// 列表已滚动时会在错误位置露出重复缩略图。
  func photoBrowser(_ browser: JXPhotoBrowserViewController, setThumbnailHidden hidden: Bool, at index: Int) {
    sourceThumbnailView?.isHidden = true
  }

  // MARK: Chrome（顶栏）显隐

  private func toggleChrome() {
    setChromeVisible(!chromeVisible)
  }

  private func setChromeVisible(_ visible: Bool) {
    chromeVisible = visible
    chrome?.setVisible(visible, animated: true)
    // UIView.animate 的动画闭包归主 actor；本类不是 @MainActor（delegate 是
    // ObjC 协议，不能用 actor 隔离满足），但会话所有入口都在主线程——present
    // 内部切主（见文件头）、JXPhotoBrowser delegate / 手势回调都在主线程。
    // 与 ActionController.pill（:685）同一依据：assumeIsolated 只是把这条既有
    // 契约显式化，同步执行，没有真正的跨域。
    MainActor.assumeIsolated {
      UIView.animate(withDuration: 0.2) {
        self.indicator?.alpha = visible ? 1 : 0
      }
    }
    // 旧查看器：单击切换后不排自动收起；手势结束后才排（见 handleDismissInteraction）。
    if !visible {
      chromeAutoHideWorkItem?.cancel()
      chromeAutoHideWorkItem = nil
    }
  }

  private func handleDismissInteraction(_ interacting: Bool) {
    if interacting {
      chromeAutoHideWorkItem?.cancel()
      chromeAutoHideWorkItem = nil
      chrome?.setVisible(false, animated: true)
      MainActor.assumeIsolated {
        UIView.animate(withDuration: 0.15) {
          self.indicator?.alpha = 0
        }
      }
      return
    }
    // 回弹（未达关闭阈值）：恢复用户设定的显隐态，并按旧查看器 2.6s 后自动收起。
    chrome?.setVisible(chromeVisible, animated: true)
    MainActor.assumeIsolated {
      UIView.animate(withDuration: 0.2) {
        self.indicator?.alpha = self.chromeVisible ? 1 : 0
      }
    }
    if chromeVisible { scheduleChromeAutoHide() }
  }

  private func scheduleChromeAutoHide() {
    chromeAutoHideWorkItem?.cancel()
    let item = DispatchWorkItem { [weak self] in
      guard let self, self.chromeVisible else { return }
      self.setChromeVisible(false)
    }
    chromeAutoHideWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.6, execute: item)
  }

  private func applySafeArea(_ insets: UIEdgeInsets) {
    guard insets != lastSafeAreaInsets else { return }
    lastSafeAreaInsets = insets
    // 页码点位置于安全区之上（旧底部缩略条 paddingBottom = max(insets.bottom,16)）。
    indicator?.position = .bottom(padding: max(insets.bottom, 16) + 8)
    actions.updatePillBottomInset(insets.bottom)
    if let browser, let indicator {
      // position 变更走 reloadData 应用（JXPageIndicatorOverlay.swift:90-100）。
      indicator.reloadData(numberOfItems: items.count, pageIndex: browser.pageIndex)
    }
  }

  // MARK: 工具

  private func downsamplingPixelSize(for browser: JXPhotoBrowserViewController) -> CGSize {
    let size = browser.view.bounds.size
    let scale = TiebaPhotoBrowserSession.displayScale(for: browser.view)
    return CGSize(width: max(size.width, 1) * scale, height: max(size.height, 1) * scale)
  }
}

// MARK: - 业务动作（保存 / 保存原图 / 分享，全原生）

/// 取代旧 JS 链路（src/services/media.ts saveImageToGallery / shareFile）：
/// - 保存：Nuke 数据层下载原始字节 → PHPhotoLibrary 写相册（GIF 写原始 GIF
///   数据，相册里仍是动图）；写库前后底部胶囊显示进度/结果。
/// - 分享：下载 → 临时文件 → UIActivityViewController（iPad 走 popover 锚点）。
/// - 失败/权限：UIAlertController，文案与旧查看器一致
///   （"权限不足"/"请在设置中允许访问相册以保存图片"、"保存失败"）。
/// @MainActor：方法全在改 UIKit 状态（pill/presenter/相册写入回调），且被
/// Nuke 的 @MainActor @Sendable 回调捕获 self；会话（唯一构造方，见 :701）本身
/// 就在主 actor 上，跟着收敛到主 actor 后闭包捕获不再跨域。
@MainActor
final class TiebaPhotoBrowserActionController {
  /// 胶囊提示宿主（浏览器 view）。weak：会话释放即失效。
  weak var pillHost: UIView?
  /// Alert/分享面板的宿主 VC（浏览器自身）。
  weak var presenter: UIViewController?

  /// 胶囊视图。**不能在存储属性默认值里直接 TiebaPhotoBrowserPillView()**：
  /// Swift 6.4 对"nonisolated 上下文里的 main actor 隔离默认值"是硬错误
  /// （UIView 子类的 init 是 @MainActor，@preconcurrency 也降不了级，见
  /// TiebaNavBarChrome 184 同源问题）。assumeIsolated 成立的依据：本控制器只随
  /// 会话构造，而会话只在主线程建（TiebaPhotoBrowser.present 内部对自己切主，
  /// 见文件头"展示入口全部可从任意线程调用"）——真被后台构造会立刻 trap。
  private let pill = MainActor.assumeIsolated { TiebaPhotoBrowserPillView() }
  private var pillBottomConstraint: NSLayoutConstraint?
  private var isSaving = false
  private var isSharing = false
  /// 动作进行中自持：查看器被关闭（会话释放）时保存/分享不半路丢失。
  private var selfRetain: TiebaPhotoBrowserActionController?

  /// 把胶囊挂到宿主 view：底部居中，位置对齐旧查看器
  /// bottom = max(insets.bottom,16)+96（相对屏幕底），最大宽 82%。
  func attach(to host: UIView) {
    pillHost = host
    pill.translatesAutoresizingMaskIntoConstraints = false
    host.addSubview(pill)
    let bottom = pill.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -96)
    pillBottomConstraint = bottom
    NSLayoutConstraint.activate([
      pill.centerXAnchor.constraint(equalTo: host.centerXAnchor),
      bottom,
      pill.widthAnchor.constraint(lessThanOrEqualTo: host.widthAnchor, multiplier: 0.82),
      pill.widthAnchor.constraint(greaterThanOrEqualToConstant: 112),
    ])
    updatePillBottomInset(host.safeAreaInsets.bottom)
  }

  /// 底部避让随安全区更新：目标 = 屏幕底往上 max(insets.bottom,16)+96
  /// （旧查看器公式）；本约束锚在 view 底，故取差值。
  func updatePillBottomInset(_ safeAreaBottom: CGFloat) {
    pillBottomConstraint?.constant = -(max(safeAreaBottom, 16) + 96 - safeAreaBottom)
  }

  /// 执行动作。id 集合与旧查看器 VIEWER_IMAGE_ACTIONS 一致：
  /// save / save-original / share。save-original 用原图档（originUrl），
  /// origin 缺失时菜单不展示该项（对齐旧 JS showOriginalBtn）。
  func perform(action: String, item: TiebaPhotoItem) {
    switch action {
    case "save":
      save(url: item.url)
    case "save-original":
      save(url: item.originUrl ?? item.url)
    case "share":
      share(item: item)
    default:
      break
    }
  }

  /// 瞬时失败提示（图片加载失败等；2.2s 自动消失）。
  func showTransientFailure(_ text: String) {
    pill.showResult(success: false, text: text)
  }

  // MARK: 保存

  private func save(url: URL) {
    guard !isSaving else { return }
    isSaving = true
    retainWhileBusy()
    pill.show(text: "正在保存…", progress: 0)
    TiebaPhotoBrowserImageLoader.data(
      url,
      progress: { [weak self] fraction in
        self?.pill.update(progress: fraction)
      },
      completion: { [weak self] result in
        guard let self else { return }
        switch result {
        case .success(let data):
          self.writeToPhotoLibrary(data: data) { [weak self] result in
            guard let self else { return }
            self.isSaving = false
            self.releaseWhenIdle()
            switch result {
            case .success:
              // 旧查看器 hapticForScene('action-success')。无 view 初始化已标待废弃
              // （UIFeedbackGenerator.h:21）：改挂 pill（控制器持有、必在窗口内），档位/时序不变。
              UINotificationFeedbackGenerator(view: self.pill).notificationOccurred(.success)
              self.pill.showResult(success: true, text: "保存成功")
            case .failure(let error):
              self.pill.hide()
              self.handleSaveFailure(error)
            }
          }
        case .failure(let error):
          self.isSaving = false
          self.releaseWhenIdle()
          self.pill.hide()
          self.handleSaveFailure(error)
        }
      }
    )
  }

  private func handleSaveFailure(_ error: Error) {
    if case TiebaPhotoBrowserError.permissionDenied = error {
      presentAlert(title: "权限不足", message: "请在设置中允许访问相册以保存图片")
      return
    }
    presentAlert(title: "保存失败", message: Self.readableMessage(error) ?? "无法保存图片到相册")
  }

  /// 2026-09-12：写入实现抽到 TiebaPhotoLibrary（JS 侧 saveImageToGallery 退场
  /// expo-media-library 后要与查看器共用同一份 addOnly 授权 + 写入语义）；本方法
  /// 只保留"查看器保存"这个调用点，错误契约不变（permissionDenied → "权限不足"，
  /// completion 恒在主线程回调）。
  private func writeToPhotoLibrary(
    data: Data,
    completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void
  ) {
    TiebaPhotoLibrary.save(data: data, completion: completion)
  }

  // MARK: 分享

  private func share(item: TiebaPhotoItem) {
    guard !isSharing else { return }
    isSharing = true
    retainWhileBusy()
    // 旧查看器 hapticForScene('press')。init(style:) 已标待废弃
    // （UIImpactFeedbackGenerator.h:38）：改挂 pill，档位/时序不变。
    UIImpactFeedbackGenerator(style: .light, view: pill).impactOccurred()
    pill.show(text: "正在准备分享…", progress: 0)
    TiebaPhotoBrowserImageLoader.data(
      item.url,
      progress: { [weak self] fraction in
        self?.pill.update(progress: fraction)
      },
      completion: { [weak self] result in
        guard let self else { return }
        self.isSharing = false
        self.releaseWhenIdle()
        self.pill.hide()
        switch result {
        case .success(let data):
          self.presentShareSheet(data: data, sourceURL: item.url)
        case .failure(let error):
          self.presentAlert(title: "分享失败", message: Self.readableMessage(error) ?? "图片下载失败，请稍后重试")
        }
      }
    )
  }

  /// @MainActor：TiebaShareSheet 是 MainActor 隔离（present 类操作），调用点
  /// （share 的 completion）本来就是 @MainActor 闭包，这里把隔离显式写进签名。
  @MainActor
  private func presentShareSheet(data: Data, sourceURL: URL) {
    guard let presenter, presenter.view.window != nil else { return }
    do {
      let fileURL = try Self.writeTemporaryFile(data: data, sourceURL: sourceURL)
      // 呈现收敛到 TiebaShareSheet（与 JS 门面 sharePresent 同一份实现）：
      // iPad 锚点/completion 时序只有一处，成功与否由返回值判断（不在窗口上=false）。
      _ = TiebaShareSheet.present(fileURL: fileURL, from: presenter) {
        // 分享结束即清理临时文件（成功/取消/失败都清）。
        try? FileManager.default.removeItem(at: fileURL)
      }
    } catch {
      presentAlert(title: "分享失败", message: Self.readableMessage(error) ?? "无法创建分享文件")
    }
  }

  /// 分享临时文件：文件名按数据魔数定扩展名（GIF 保 .gif，系统按动图分享）。
  private static func writeTemporaryFile(data: Data, sourceURL: URL) throws -> URL {
    let ext = fileExtension(for: data, fallbackURL: sourceURL)
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("tieba_share_\(UUID().uuidString).\(ext)")
    try data.write(to: url, options: .atomic)
    return url
  }

  private static func fileExtension(for data: Data, fallbackURL: URL) -> String {
    if data.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "gif" } // "GIF8"
    if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" } // ‰PNG
    if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" } // JPEG SOI
    if data.starts(with: [0x52, 0x49, 0x46, 0x46]) { return "webp" } // RIFF（图床仅 webp）
    let ext = fallbackURL.pathExtension.lowercased()
    return ext.isEmpty ? "jpg" : ext
  }

  // MARK: 提示

  private func presentAlert(title: String, message: String) {
    guard let presenter, presenter.view.window != nil,
          presenter.presentedViewController == nil else { return }
    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "好", style: .default))
    presenter.present(alert, animated: true)
  }

  private static func readableMessage(_ error: Error) -> String? {
    if let localized = (error as? LocalizedError)?.errorDescription, !localized.isEmpty {
      return localized
    }
    let message = (error as NSError).localizedDescription
    return message.isEmpty ? nil : message
  }

  private func retainWhileBusy() {
    selfRetain = self
  }

  private func releaseWhenIdle() {
    guard !isSaving, !isSharing else { return }
    selfRetain = nil
  }
}

// MARK: - 底部胶囊提示（保存进度/结果；样式对齐旧查看器 styles.savePill）

/// 旧查看器底部"保存成功"药丸：rgba(28,28,30,.88) / 圆角 18 / 白 14pt medium /
/// 阴影 / 2.2s 自动消失。这里加一个 3pt 确定进度条（保存/下载进度），
/// 并进行中文案（"正在保存…"/"正在准备分享…"）；底走系统液态玻璃
/// （部署底线 iOS 26，UIGlassEffect 恒可用，不再有低版本分档）。
final class TiebaPhotoBrowserPillView: UIView {
  private static let horizontalPadding: CGFloat = 16
  private static let verticalPadding: CGFloat = 9
  private static let contentGap: CGFloat = 6
  private static let indicatorSize: CGFloat = 18
  private static let progressHeight: CGFloat = 3
  private static let cornerRadius: CGFloat = 18

  /// 玻璃底（部署底线 iOS 26，恒可用）。
  private let glassBackground: UIVisualEffectView = {
    let effect = UIGlassEffect(style: .regular)
    effect.tintColor = UIColor(red: 28 / 255, green: 28 / 255, blue: 30 / 255, alpha: 0.55)
    return UIVisualEffectView(effect: effect)
  }()

  private let spinner = UIActivityIndicatorView(style: .medium)
  private let iconView = UIImageView()
  private let label = UILabel()
  private let progressTrack = UIView()
  private let progressFill = UIView()
  private var progressFraction: Double?
  private var hideWorkItem: DispatchWorkItem?

  init() {
    super.init(frame: .zero)
    glassBackground.isUserInteractionEnabled = false
    glassBackground.layer.cornerRadius = Self.cornerRadius
    glassBackground.layer.cornerCurve = .continuous
    glassBackground.clipsToBounds = true
    addSubview(glassBackground)
    layer.cornerRadius = Self.cornerRadius
    layer.cornerCurve = .continuous
    layer.shadowColor = UIColor.black.cgColor
    layer.shadowOpacity = 0.18
    layer.shadowRadius = 10
    layer.shadowOffset = CGSize(width: 0, height: 4)
    isUserInteractionEnabled = false
    isHidden = true
    alpha = 0

    spinner.color = .white
    spinner.hidesWhenStopped = false
    spinner.transform = CGAffineTransform(scaleX: 0.78, y: 0.78)
    addSubview(spinner)

    iconView.tintColor = .white
    iconView.contentMode = .scaleAspectFit
    iconView.isHidden = true
    addSubview(iconView)

    label.textColor = .white
    label.font = .systemFont(ofSize: 14, weight: .medium)
    label.textAlignment = .center
    label.lineBreakMode = .byTruncatingTail
    addSubview(label)

    progressTrack.backgroundColor = UIColor.white.withAlphaComponent(0.18)
    progressTrack.layer.cornerRadius = 1.5
    progressTrack.clipsToBounds = true
    progressTrack.isHidden = true
    progressTrack.addSubview(progressFill)
    progressFill.backgroundColor = .white
    addSubview(progressTrack)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override var intrinsicContentSize: CGSize {
    let labelSize = label.sizeThatFits(
      CGSize(width: 300, height: CGFloat.greatestFiniteMagnitude)
    )
    var width = Self.horizontalPadding * 2 + min(labelSize.width, 300)
    if !spinner.isHidden || !iconView.isHidden {
      width += Self.indicatorSize + Self.contentGap
    }
    let progressExtra: CGFloat = progressFraction != nil ? Self.progressHeight + 2 : 0
    return CGSize(
      width: ceil(width),
      height: max(labelSize.height, Self.indicatorSize) + Self.verticalPadding * 2 + progressExtra
    )
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    glassBackground.frame = bounds
    let progressExtra = progressFraction != nil ? Self.progressHeight + 2 : 0
    var x = Self.horizontalPadding
    let contentHeight = max(bounds.height - Self.verticalPadding * 2 - progressExtra, 0)
    let indicatorY = Self.verticalPadding + (contentHeight - Self.indicatorSize) / 2
    if !spinner.isHidden {
      spinner.frame = CGRect(x: x, y: indicatorY, width: Self.indicatorSize, height: Self.indicatorSize)
      x += Self.indicatorSize + Self.contentGap
    } else if !iconView.isHidden {
      iconView.frame = CGRect(x: x, y: indicatorY, width: Self.indicatorSize, height: Self.indicatorSize)
      x += Self.indicatorSize + Self.contentGap
    }
    label.frame = CGRect(
      x: x,
      y: Self.verticalPadding,
      width: max(bounds.width - x - Self.horizontalPadding, 0),
      height: contentHeight
    )
    guard progressFraction != nil else { return }
    let track = CGRect(
      x: Self.horizontalPadding,
      y: bounds.height - Self.verticalPadding - Self.progressHeight,
      width: max(bounds.width - Self.horizontalPadding * 2, 0),
      height: Self.progressHeight
    )
    progressTrack.frame = track
    progressFill.frame = CGRect(
      x: 0,
      y: 0,
      width: track.width * CGFloat(min(max(progressFraction ?? 0, 0), 1)),
      height: track.height
    )
  }

  /// 进行中态。progress = nil 时不显示进度条。
  func show(text: String, progress: Double?) {
    hideWorkItem?.cancel()
    hideWorkItem = nil
    label.text = text
    spinner.isHidden = false
    spinner.startAnimating()
    iconView.isHidden = true
    progressFraction = progress
    progressTrack.isHidden = (progress == nil)
    isHidden = false
    setNeedsLayout()
    invalidateIntrinsicContentSize()
    UIView.animate(withDuration: 0.18) { self.alpha = 1 }
  }

  func update(progress: Double) {
    progressFraction = min(max(progress, 0), 1)
    progressTrack.isHidden = false
    setNeedsLayout()
    invalidateIntrinsicContentSize()
  }

  /// 结果态：图标 + 文案，2.2s 后自动淡出（旧查看器 2200ms）。
  func showResult(success: Bool, text: String) {
    spinner.stopAnimating()
    spinner.isHidden = true
    iconView.image = UIImage(
      systemName: success ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
    )
    iconView.isHidden = false
    label.text = text
    progressFraction = nil
    progressTrack.isHidden = true
    isHidden = false
    setNeedsLayout()
    invalidateIntrinsicContentSize()
    UIView.animate(withDuration: 0.18) { self.alpha = 1 }
    hideWorkItem?.cancel()
    let item = DispatchWorkItem { [weak self] in self?.hide() }
    hideWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: item)
  }

  func hide() {
    hideWorkItem?.cancel()
    hideWorkItem = nil
    UIView.animate(withDuration: 0.18, animations: { self.alpha = 0 }) { _ in
      self.isHidden = true
    }
  }
}

// MARK: - 浏览器 VC 子类（关闭上报 / 状态栏 / 安全区）

final class TiebaPhotoBrowserViewController: JXPhotoBrowserViewController {
  var onDismissed: (() -> Void)?
  var onSafeAreaInsetsDidChange: ((UIEdgeInsets) -> Void)?
  /// 进场转场完成（进场黑底的撤除时机）。
  var onDidAppear: (() -> Void)?
  private var didReportDismiss = false

  /// 状态栏：旧查看器经 TiebaNative.setModalStatusBarHidden(true) 隐藏；
  /// 这里 VC 级直接接管（overFullScreen 需显式声明捕获状态栏外观）。
  override var prefersStatusBarHidden: Bool { true }
  override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation { .fade }

  override func viewDidLoad() {
    super.viewDidLoad()
    modalPresentationCapturesStatusBarAppearance = true
  }

  override func viewSafeAreaInsetsDidChange() {
    super.viewSafeAreaInsetsDidChange()
    onSafeAreaInsetsDidChange?(view.safeAreaInsets)
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    onDidAppear?()
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    reportDismissIfNeeded()
  }

  override func dismiss(animated flag: Bool, completion: (() -> Void)?) {
    super.dismiss(animated: flag) { [weak self] in
      completion?()
      self?.reportDismissIfNeeded()
    }
  }

  private func reportDismissIfNeeded() {
    guard !didReportDismiss else { return }
    guard isBeingDismissed || presentingViewController == nil else { return }
    didReportDismiss = true
    onDismissed?()
  }
}

// MARK: - Cell（JXZoomImageCell 子类 + Nuke 两级加载 + 长按菜单）

final class TiebaPhotoBrowserImageCell: JXZoomImageCell {
  static let tiebaReuseIdentifier = "TiebaPhotoBrowserImageCell"
  /// 长图阅读模式的缩放上限（fit-width 需要超过默认 3.0；见 applyLongImageFit）。
  private static let longImageMaximumZoom: CGFloat = 12

  var onSingleTap: (() -> Void)?
  var onMenuAction: ((String) -> Void)?
  var onLoadFailed: (() -> Void)?
  var onDismissInteractionChange: ((Bool) -> Void)?

  private let spinner = UIActivityIndicatorView(style: .large)
  private var thumbTask: Task<Void, Never>?
  private var fullTask: Task<Void, Never>?
  private var generation = 0
  private var retryCount = 0
  private var fullImageReady = false
  private var appliedURL: URL?
  /// 当前页是否有原图档（决定长按菜单是否展示「保存原图」）。
  private var hasOrigin = false
  /// 当前页是否可切看原图（服务端 showOriginalBtn 且有独立原图档，且不在展示原图）。
  private var hasViewOriginal = false
  private var wantsLongFit = false
  private var longFitApplied = false
  private var isApplyingLongFit = false

  override init(frame: CGRect) {
    super.init(frame: frame)
    commonSetup()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    commonSetup()
  }

  private func commonSetup() {
    backgroundColor = .clear
    contentView.backgroundColor = .clear
    spinner.color = .white
    spinner.hidesWhenStopped = true
    spinner.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(spinner)
    NSLayoutConstraint.activate([
      spinner.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
      spinner.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
    ])
    // 长按菜单挂整个 Cell（页面铺满，任意位置长按都出菜单；与旧查看器
    // TiebaPhotoContextMenu(previewEnabled:false) 的交互范围一致）。
    addInteraction(UIContextMenuInteraction(delegate: self))
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    cancelLoading()
    generation += 1
    appliedURL = nil
    retryCount = 0
    fullImageReady = false
    hasOrigin = false
    hasViewOriginal = false
    wantsLongFit = false
    longFitApplied = false
    spinner.stopAnimating()
  }

  // MARK: 配置 / 加载

  func configure(item: TiebaPhotoItem, index: Int, targetPixelSize: CGSize, containerSize: CGSize) {
    guard appliedURL != item.url else { return }
    appliedURL = item.url
    hasOrigin = item.originUrl != nil
    hasViewOriginal = item.canViewOriginal && item.originUrl != nil
    generation += 1
    let generation = self.generation
    retryCount = 0
    fullImageReady = false
    longFitApplied = false
    thumbTask?.cancel()
    fullTask?.cancel()
    imageView.image = nil
    scrollView.setZoomScale(scrollView.minimumZoomScale, animated: false)
    // 旧查看器缩放域 1~5、双击 3x（parts.tsx useZoomGesture maxScale:5 /
    // doubleTapConfig defaultScale:3）；框架默认上限 3.0，这里对齐旧值。
    scrollView.maximumZoomScale = 5
    doubleTapZoomScale = 3
    wantsLongFit = item.isLongImage(in: containerSize)
    spinner.stopAnimating()

    if let thumbURL = item.thumbUrl {
      thumbTask = Task { [weak self] in
        guard let image = try? await TiebaPhotoBrowserImageLoader.load(
          thumbURL,
          pixelSize: targetPixelSize,
          isGif: false
        ) else { return }
        DispatchQueue.main.async {
          self?.apply(image: image, isThumb: true, generation: generation)
        }
      }
    } else {
      spinner.startAnimating()
    }
    loadFull(item: item, targetPixelSize: targetPixelSize, generation: generation)
  }

  func cancelLoading() {
    thumbTask?.cancel()
    fullTask?.cancel()
    thumbTask = nil
    fullTask = nil
  }

  private func loadFull(item: TiebaPhotoItem, targetPixelSize: CGSize, generation: Int) {
    fullTask = Task { [weak self] in
      do {
        let image = try await TiebaPhotoBrowserImageLoader.load(
          item.url,
          pixelSize: targetPixelSize,
          isGif: item.isGif
        )
        DispatchQueue.main.async {
          self?.apply(image: image, isThumb: false, generation: generation)
        }
      } catch {
        DispatchQueue.main.async {
          self?.handleFullImageFailure(item: item, targetPixelSize: targetPixelSize, generation: generation)
        }
      }
    }
  }

  /// 失败自动重试 2 次（旧查看器 useImageLoadRetry：600ms 后退避重试，
  /// 大图档首次进查看器缓存 miss + 弱网是主要失败面）。
  private func handleFullImageFailure(item: TiebaPhotoItem, targetPixelSize: CGSize, generation: Int) {
    guard generation == self.generation else { return }
    retryCount += 1
    guard retryCount <= 2 else {
      spinner.stopAnimating()
      onLoadFailed?()
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
      guard let self, generation == self.generation else { return }
      self.loadFull(item: item, targetPixelSize: targetPixelSize, generation: generation)
    }
  }

  private func apply(image: UIImage, isThumb: Bool, generation: Int) {
    guard generation == self.generation else { return }
    // 大图已到后缩略图任务迟到：不覆盖（保持清晰）。
    if isThumb && fullImageReady { return }
    // GIF 的 UIImage 是多帧 animatedImage（Nuke 默认解码器产物），
    // UIImageView 赋值后自动播放，无需 startAnimating。
    imageView.image = image
    if isThumb { return }
    fullImageReady = true
    spinner.stopAnimating()
    // 大图落位后再套长图阅读模式（需要真实像素比例算 fit-width）。
    setNeedsLayout()
    applyLongImageFitIfNeeded()
  }

  // MARK: 长图阅读模式

  /// 长图 = 进入即 fit-width（旧 LongImageView：宽=屏宽、单指上下读完）。
  /// 框架 cell 的基础布局是长边铺满（aspectFit），长图会缩成一条；这里在
  /// 大图落位后把 scrollView 程序化放大到 fit-width（只用公开 API：提高
  /// maximumZoomScale + setZoomScale，未改框架）。副作用：zoomScale >
  /// minimum 后框架的关闭手势守卫判定为"已缩放" → 长图页下拉/上滑都不退出，
  /// 用关闭按钮退出；旧查看器长图页也只在贴顶/贴底才移交退出（见文件头缺口 4）。
  private func applyLongImageFitIfNeeded() {
    guard wantsLongFit, !longFitApplied, !isApplyingLongFit,
          let image = imageView.image, image.size.width > 1, image.size.height > 1,
          bounds.width > 1, bounds.height > 1 else { return }
    longFitApplied = true
    isApplyingLongFit = true
    defer { isApplyingLongFit = false }

    let fitScale = min(bounds.width / image.size.width, bounds.height / image.size.height)
    let contentWidth = max(image.size.width * fitScale, 1)
    let neededZoom = bounds.width / contentWidth
    guard neededZoom > 1.02 else { return }
    scrollView.minimumZoomScale = 1
    scrollView.maximumZoomScale = min(max(5, neededZoom), Self.longImageMaximumZoom)
    scrollView.setZoomScale(neededZoom, animated: false)
    scrollView.contentOffset = CGPoint(x: 0, y: 0)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    if wantsLongFit && !longFitApplied {
      applyLongImageFitIfNeeded()
    }
  }

  // MARK: 手势回调（覆写框架行为，保持旧查看器交互）

  /// 单击 = 显隐 chrome（旧查看器 toggleUI）；框架默认是关闭浏览器，
  /// 这里按"保持现有交互"覆写。如需回到框架默认（iOS Photos 单击关闭），
  /// 删掉本覆写即可。
  override func handleSingleTap(_ gesture: UITapGestureRecognizer) {
    onSingleTap?()
  }

  override func photoBrowserDismissInteractionDidChange(isInteracting: Bool) {
    super.photoBrowserDismissInteractionDidChange(isInteracting: isInteracting)
    onDismissInteractionChange?(isInteracting)
  }
}

// MARK: - 长按菜单（UIContextMenuInteraction + UIMenu，同 TiebaPhotoContextMenuView）

extension TiebaPhotoBrowserImageCell: UIContextMenuInteractionDelegate {
  func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    configurationForMenuAtLocation location: CGPoint
  ) -> UIContextMenuConfiguration? {
    UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
      // 原图档缺失时不展示「保存原图」；「查看原图」还要服务端 showOriginalBtn
      // 且该页当前没在展示原图（已在展示时切档会把该项摘掉，对齐旧 JS）。
      let showsOrigin = self?.hasOrigin ?? false
      let showsViewOriginal = self?.hasViewOriginal ?? false
      let children = TiebaPhotoBrowserSession.menuActions
        .filter { spec in
          switch spec.id {
          case "save-original": return showsOrigin
          case "view-original": return showsViewOriginal
          default: return true
          }
        }
        .map { spec in
          UIAction(title: spec.title, image: UIImage(systemName: spec.icon)) { [weak self] _ in
            self?.onMenuAction?(spec.id)
          }
        }
      return UIMenu(children: children)
    }
  }

  /// 无预览：页面本身已是大图（同 TiebaPhotoContextMenuView previewEnabled=false
  /// 的分支）；返回 nil 让系统把菜单直接弹在长按位置。
  /// ⚠️ iOS 16 起旧名 previewForHighlightingMenuWithConfiguration 已废弃并
  /// 换成 configuration:highlightPreview… 形态（UIContextMenuInteraction.h:123/
  /// 132/167/179）：只实现旧名会静默不生效（连带 TiebaPhotoContextMenuView.swift
  /// :112-118 的同名旧实现同样没被系统调用，属既有隐患）。
  func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    configuration: UIContextMenuConfiguration,
    highlightPreviewForItemWithIdentifier identifier: any NSCopying
  ) -> UITargetedPreview? {
    nil
  }

  func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    configuration: UIContextMenuConfiguration,
    dismissalPreviewForItemWithIdentifier identifier: any NSCopying
  ) -> UITargetedPreview? {
    nil
  }
}

// MARK: - 源缩略图替身视图

/// 转场源视图的替身：只做 Zoom 转场的几何/图像载体（恒隐藏）。矩形来自
/// 原生列表被点图片视图的窗口 frame；真缩略图在 Modal 底下保持可见。
final class TiebaPhotoSourceThumbnailView: UIImageView {}

// MARK: - 顶栏 chrome overlay（关闭 + 页码/标题 + 保存/分享）

/// 旧查看器顶栏（styles.ts topBar / topBarButton）：黑色玻璃条 +
/// 左侧 40pt 圆形关闭钮（xmark 22 bold、白 10% 底、按压 0.55 透明度）+
/// 中间 "n/N" 16pt semibold 与 13pt 上下文标题 + 右侧保存/分享 40pt 圆钮。
/// 动作（save/share）由 session 转给原生 ActionController 执行。
/// 顶栏底/圆钮走系统液态玻璃（部署底线 iOS 26，UIGlassEffect 恒可用）。
final class TiebaPhotoBrowserChromeOverlay: UIView, JXPhotoBrowserOverlay {
  var onClose: (() -> Void)?
  var onAction: ((String) -> Void)?

  private static let buttonSize: CGFloat = 40
  private static let horizontalPadding: CGFloat = 16
  private static let bottomPadding: CGFloat = 8
  private static let minimumTopPadding: CGFloat = 30

  /// 顶栏底材质：系统液态玻璃（部署底线 iOS 26，恒可用）。
  private static func makeBarEffect() -> UIVisualEffect {
    let effect = UIGlassEffect(style: .regular)
    // 顶栏恒深色（查看器黑底），玻璃带深色调保证白字/白图标可读。
    effect.tintColor = UIColor(red: 28 / 255, green: 28 / 255, blue: 30 / 255, alpha: 0.4)
    return effect
  }

  private let blur = UIVisualEffectView(effect: TiebaPhotoBrowserChromeOverlay.makeBarEffect())
  private let closeButton = TiebaPhotoBrowserCircleButton(type: .custom)
  private let saveButton = TiebaPhotoBrowserCircleButton(type: .custom)
  private let shareButton = TiebaPhotoBrowserCircleButton(type: .custom)
  private let counterLabel = UILabel()
  private let titleLabel = UILabel()
  private let title: String?
  private var totalItems = 0
  private var heightConstraint: NSLayoutConstraint?
  private var topPaddingConstraint: NSLayoutConstraint?

  init(title: String?) {
    self.title = title
    super.init(frame: .zero)
    build()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  private func build() {
    backgroundColor = .clear

    blur.isUserInteractionEnabled = false
    blur.translatesAutoresizingMaskIntoConstraints = false
    addSubview(blur)

    configureButton(closeButton, symbol: "xmark", weight: .bold, label: "关闭图片查看器")
    closeButton.addTarget(self, action: #selector(handleClose), for: .touchUpInside)
    configureButton(saveButton, symbol: "square.and.arrow.down", weight: .medium, label: "保存到相册")
    saveButton.addTarget(self, action: #selector(handleSave), for: .touchUpInside)
    configureButton(shareButton, symbol: "square.and.arrow.up", weight: .medium, label: "分享图片")
    shareButton.addTarget(self, action: #selector(handleShare), for: .touchUpInside)

    counterLabel.textColor = .white
    counterLabel.font = .systemFont(ofSize: 16, weight: .semibold)
    counterLabel.textAlignment = .center

    titleLabel.text = title
    titleLabel.textColor = UIColor.white.withAlphaComponent(0.85)
    titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
    titleLabel.textAlignment = .center
    titleLabel.numberOfLines = 1
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.isHidden = (title?.isEmpty ?? true)

    let centerStack = UIStackView(arrangedSubviews: [counterLabel, titleLabel])
    centerStack.axis = .vertical
    centerStack.alignment = .center
    centerStack.spacing = 2
    centerStack.isUserInteractionEnabled = false
    centerStack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(centerStack)

    NSLayoutConstraint.activate([
      blur.topAnchor.constraint(equalTo: topAnchor),
      blur.leadingAnchor.constraint(equalTo: leadingAnchor),
      blur.trailingAnchor.constraint(equalTo: trailingAnchor),
      blur.bottomAnchor.constraint(equalTo: bottomAnchor),
      centerStack.centerXAnchor.constraint(equalTo: centerXAnchor),
      centerStack.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
      centerStack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 96),
      centerStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -96),
    ])
  }

  private func configureButton(
    _ button: TiebaPhotoBrowserCircleButton,
    symbol: String,
    weight: UIImage.SymbolWeight,
    label: String
  ) {
    button.translatesAutoresizingMaskIntoConstraints = false
    button.tintColor = .white
    let image = UIImage(
      systemName: symbol,
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: weight)
    )
    // 系统液态玻璃圆钮（部署底线 iOS 26，恒可用）。
    var config = UIButton.Configuration.glass()
    config.image = image
    config.baseForegroundColor = .white
    config.cornerStyle = .capsule
    button.configuration = config
    button.accessibilityLabel = label
    addSubview(button)
    NSLayoutConstraint.activate([
      button.widthAnchor.constraint(equalToConstant: Self.buttonSize),
      button.heightAnchor.constraint(equalToConstant: Self.buttonSize),
    ])
  }

  // MARK: JXPhotoBrowserOverlay

  func setup(with browser: JXPhotoBrowserViewController) {
    translatesAutoresizingMaskIntoConstraints = false
    let container = browser.view!
    let top = topAnchor.constraint(equalTo: container.topAnchor)
    let leading = leadingAnchor.constraint(equalTo: container.leadingAnchor)
    let trailing = trailingAnchor.constraint(equalTo: container.trailingAnchor)
    let height = heightAnchor.constraint(equalToConstant: 78)
    NSLayoutConstraint.activate([top, leading, trailing, height])
    heightConstraint = height

    closeButton.leadingAnchor.constraint(
      equalTo: leadingAnchor,
      constant: Self.horizontalPadding
    ).isActive = true
    topPaddingConstraint = closeButton.topAnchor.constraint(equalTo: topAnchor, constant: Self.minimumTopPadding)
    topPaddingConstraint?.isActive = true
    saveButton.trailingAnchor.constraint(
      equalTo: trailingAnchor,
      constant: -Self.horizontalPadding
    ).isActive = true
    saveButton.topAnchor.constraint(equalTo: closeButton.topAnchor).isActive = true
    shareButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -8).isActive = true
    shareButton.topAnchor.constraint(equalTo: closeButton.topAnchor).isActive = true

    updateMetrics()
  }

  func reloadData(numberOfItems: Int, pageIndex: Int) {
    totalItems = numberOfItems
    updateCounter(pageIndex: pageIndex)
  }

  func didChangedPageIndex(_ index: Int) {
    updateCounter(pageIndex: index)
    updateMetrics()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    updateMetrics()
  }

  /// 顶栏内容下缘 = max(安全区顶, 30)（旧 topBar paddingTop: max(insets.top,30)）。
  private func updateMetrics() {
    let insets = superview?.safeAreaInsets ?? safeAreaInsets
    let top = max(insets.top, Self.minimumTopPadding)
    topPaddingConstraint?.constant = top
    heightConstraint?.constant = top + Self.buttonSize + Self.bottomPadding
  }

  private func updateCounter(pageIndex: Int) {
    let safeIndex = max(0, min(pageIndex, max(totalItems - 1, 0)))
    counterLabel.text = "\(safeIndex + 1)/\(totalItems)"
  }

  // MARK: 显隐 / 动作

  func setVisible(_ visible: Bool, animated: Bool) {
    isUserInteractionEnabled = visible
    let update = { self.alpha = visible ? 1 : 0 }
    if animated {
      UIView.animate(withDuration: 0.2, animations: update)
    } else {
      update()
    }
  }

  @objc private func handleClose() {
    TiebaSceneHaptics.fire("press")
    onClose?()
  }

  @objc private func handleSave() {
    TiebaSceneHaptics.fire("press")
    onAction?("save")
  }

  @objc private func handleShare() {
    TiebaSceneHaptics.fire("press")
    onAction?("share")
  }
}

/// 圆形按钮：按压 0.55 透明度（styles.ts topBarButtonPressed，旧查看器
/// 顶栏按钮无高光，仅按压微降不透明度）。
final class TiebaPhotoBrowserCircleButton: UIButton {
  override var isHighlighted: Bool {
    didSet { alpha = isHighlighted ? 0.55 : 1 }
  }
}

// MARK: - 页变化事件 overlay（框架的页码通知通道）

/// 页码变化 → chrome 自动收起计时。用 overlay 而不是 KVO：
/// JXPhotoBrowserViewController.pageIndex 的 didSet 只通知 overlays
/// （JXPhotoBrowserViewController.swift:16-30）。
final class TiebaPhotoBrowserEventOverlay: UIView, JXPhotoBrowserOverlay {
  var onPageChanged: ((Int) -> Void)?
  private var lastIndex: Int?

  func setup(with browser: JXPhotoBrowserViewController) {
    isUserInteractionEnabled = false
    isHidden = true
  }

  func reloadData(numberOfItems: Int, pageIndex: Int) {
    // reloadData 在初始定位/布局后触发：只记录基线，不发首帧事件。
    lastIndex = pageIndex
  }

  func didChangedPageIndex(_ index: Int) {
    guard index != lastIndex else { return }
    lastIndex = index
    onPageChanged?(index)
  }
}
