// TiebaLite RN — Nuke 共享图片管线（TiebaNuke）
//
// 全 App 唯一一条图片缓存/请求管线（2026-09-13 完成收敛，原 TiebaImageIO 已删除）。
// 实际消费方：TiebaPhotoBrowser（大图查看器，GIF 不套处理器保多帧）、
// TiebaFeedRowView / TiebaHotListViewController / TiebaPhotoPreviewViewController、
// TiebaPostRowView（帖子与表情）及全部列表头像、TiebaNavigator 栏内头像、
// TiebaListView 预取器（makePrefetcher）、设置页（setCacheLimits / clearCaches）。
// 禁止再建第二条管线（缓存/请求合并都会分裂，见 performance-guide "Selecting a System"）。
//
// 目标版本：Nuke 13.2.0（本文件按 Nuke 13 的公开 API 编写）。
// 版本事实（2026-09 实测，勿凭记忆改）：
//   - Nuke 12/13 都没有发布到 CocoaPods：trunk 最新只到 10.7.1
//     （`pod spec cat Nuke` → 10.7.1；CDN all_pods_versions_3_d_e.txt 同）。
//     12.x/13.x 官方只提供 SwiftPM 与 GitHub Release 的 xcframework 附件。
//     本仓走 ios/vendor/Nuke 源码 vendor + 本地 podspec（13.2.0）。
//   - Nuke 13 的管线代理协议是 `ImagePipeline.Delegate`（嵌套在管线类型里），
//     旧的顶层名 `ImagePipelineDelegate` 保留为 deprecated typealias。
//     13 新增 `willLoadData(for:urlRequest:pipeline:)`（async，默认实现原样返回），
//     本文件仍走 `dataLoader(for:pipeline:)` + 自定义 URLSession 配置做 Referer
//     注入（Nuke 13 该 requirement 签名未变，且用 DataLoader 时 URLSession 级
//     httpAdditionalHeaders 一次写入最省事）。
//   - Nuke 13 删掉了闭包式加载 API 的 `queue:` 参数（`loadImage(with:progress:
//     completion:)` / `loadData(with:progress:completion:)`）：回调固定派发到
//     MainActor（签名里的 @MainActor @Sendable），传 queue 是 Nuke 12 的写法。
//     13 还新增了 async 版本（`image(for:)` / `imageTask(with:).response`）：
//     TiebaPhotoBrowser 用 async 版，TiebaPhotoBrowser 的保存路径 / TiebaNuke 的
//     缓存调整仍用闭包式（该重载在 13 里是 soft-deprecated 但完整保留，
//     Sources/Nuke/Pipeline/Deprecated.swift 实测）。
//   - 视图级加载（UIImageView 的取消/清图/过渡/复用）**不在本文件**：用
//     NukeExtensions 的 loadImage(with:options:into:…) / cancelRequest(for:)，
//     见 TiebaFeedRowView / TiebaSimpleRows / TiebaHotListViewController 等消费方。
//
// 防盗链：贴吧图床要求 Referer: https://tieba.baidu.com/
//   - 所有图片请求都经本管线注入；不要再手写 URLSession 取图（丢 Referer
//     且会分裂缓存）。
//   - 图片请求不设 User-Agent（TiebaNativeClient 的 `tieba/12.41.7.1`
//     只用于 API 请求）；需要再加头时用 TiebaNukePipelineDelegate(additionalHeaders:)。
//
// 缓存上限：磁盘 400MB（偏好 cacheMaxSizeMb）、内存按磁盘推出（见
// memoryLimitBytes(forDiskBytes:)，磁盘/4 夹 32–96MB）。启动与设置页滑块都经
// setCacheLimits(diskBytes:memoryBytes:) 重设，两处共用同一份公式。
// 磁盘上限对应偏好 cacheMaxSizeMb（默认 400），清缓存必须同时清
// DataCache 与内存 ImageCache（只删目录清不到已解码位图）。
//
// ATS：Nuke 默认 DataLoader 走 URLSession，受 ATS 约束，http:// 图片经
// secureURL(_:) 升级为 https（与 src/utils/thumbnail.ts 同一策略）。

import Foundation
import Nuke
import NukeExtensions

// MARK: - 防盗链数据加载器（Referer 注入）

/// Nuke 13 的图片请求拦截点：`ImagePipeline.Delegate.dataLoader(for:pipeline:)`。
///
/// 委托本身不持有可变状态：DataLoader 是 `@unchecked Sendable`（Nuke 内部
/// 已做线程安全），headers 在初始化时一次性写进 URLSessionConfiguration，
/// 因此这里可以安全地 `@unchecked Sendable`（与 TiebaBackgroundSync.swift:12
/// 的既有约定一致；本类无需 NSLock）。
///
/// - note: `ImagePipeline.Delegate` 在 Nuke 13 里要求 `AnyObject & Sendable`，
///   并带一组协议扩展默认实现（含 `willLoadData`）；本类只覆写 dataLoader。
///
/// [接线 2026-10-05] 原为 `@unchecked Sendable`（人工断言，绕过编译器检查）。现在改成编译器校验的
/// `Sendable`：本类唯一的存储属性是 Nuke 的 `DataLoader`，而 `DataLoader` 自身已经是
/// `@unchecked Sendable`（Vendor/Nuke/Sources/Nuke/Loading/DataLoader.swift:8，Nuke 内部已线程安全），
/// 所以「final 类 + 全部存储属性 Sendable + 无可变状态」三条静态检查全过 —— 不再需要人工断言。
public final class TiebaNukePipelineDelegate: ImagePipeline.Delegate, Sendable {
  /// 注入 Referer 等头的加载器（同一实例服务所有请求）。
  public let dataLoader: DataLoader

  public init(dataLoader: DataLoader) {
    self.dataLoader = dataLoader
  }

  /// 便捷构造：默认 Referer + 可选附加头（如需要 User-Agent 时）。
  public convenience init(additionalHeaders: [String: String] = [:]) {
    self.init(dataLoader: TiebaNuke.makeHeaderInjectingDataLoader(additionalHeaders: additionalHeaders))
  }

  // MARK: ImagePipelineDelegate

  public func dataLoader(for request: ImageRequest, pipeline: ImagePipeline) -> any DataLoading {
    dataLoader
  }
}

// MARK: - TiebaNuke

public enum TiebaNuke {
  // MARK: 常量

  /// 贴吧图床防盗链必需的 Referer（全 App 唯一值；改动前先核对图床要求）。
  public static let referer = "https://tieba.baidu.com/"

  /// 磁盘缓存默认上限：400MB（旧 expo-image maxDiskSize 默认档 + 原生缩略图上限）。
  public static let defaultDiskLimitBytes = 400 * 1024 * 1024

  /// 内存缓存上限由磁盘上限推出（唯一一份公式：管线初始化 / 启动 / 设置页滑块共用）。
  ///
  /// 口径：磁盘/4，夹 32–96MB。**这不是随手定的数**——内存层存的是**已解码位图**，
  /// 命中即零成本；动态页/吧页一屏就是几十张（图片带一行最多 9 张），只装得下一两屏
  /// 时往回滚必然重解（Nuke 的 cost = 位图字节数，带内一张小图约 0.3MB）。
  /// 旧口径 disk/16 夹 8–32MB（默认 400MB 磁盘 → 25MB）连一屏都装不满。
  /// 放大是安全的：内存告警会清两层缓存（见 TiebaAppBootstrap）。
  public static func memoryLimitBytes(forDiskBytes diskBytes: Int) -> Int {
    min(max(diskBytes / 4, 32 * 1024 * 1024), 96 * 1024 * 1024)
  }

  // MARK: 设备分级（解码尺寸 / 缓存档位）

  /// 设备档位：CPU 核数 < 4 视为低端。
  ///
  /// 为什么用 TiebaDeviceMetrics.performance 这个信号：它是本仓唯一 **nonisolated** 的整档设备事实
  /// （sysctl hw.ncpu >= 4），不碰 UIScreen.main（iOS 26 起 @MainActor 且已弃用）。管线是 static let
  /// 惰性初始化的，初始化表达式在 nonisolated 上下文里求值 —— 用屏幕尺寸分级会把整条管线逼成
  /// @MainActor，代价远大于收益。
  /// （TiebaDeviceMetrics 按判据三问保留：TiebaNuke 的解码分级是它的真实消费者。）
  private static let isLowTierDevice = !TiebaDeviceMetrics.performance.isGraphicallyCapable

  /// 单边解码像素上限（**护栏，不是常规下采样**）。
  ///
  /// 口径：低端机 3072px，其余 4096px。接线前逐个核对了全部调用方的实参，最大 ≈ 1600px
  /// （TiebaForumRulesViewController.imageMaxPixel = (视图宽-64)×scale；TiebaPostRowView =
  /// max(bounds.width,320)×scale；头像/表情 20–132px；TiebaKindListView = max(height,columnWidth)×scale），
  /// 因此**这个上限对现有调用方一律不生效，图片显示结果逐像素不变**。它只为「将来有人传进 4000px
  /// 级目标」兜底：那种图会解码成超大位图并整块上传纹理，低端机上直接触发内存告警。
  public static var maxDecodePixelSize: CGFloat {
    self.isLowTierDevice ? 3072.0 : 4096.0
  }

  /// 按 maxDecodePixelSize 等比收口（保持宽高比；只在上限之上才生效，否则原样返回）。
  static func clampedDecodePixelSize(_ size: CGSize) -> CGSize {
    let longest = max(size.width, size.height)
    let limit = self.maxDecodePixelSize
    guard longest > limit, longest > 0 else { return size }
    let factor = limit / longest
    return CGSize(width: (size.width * factor).rounded(), height: (size.height * factor).rounded())
  }

  /// 内存缓存条目数上限：低端机 240，其余 400（一屏列表图片 + 头像 + 相邻屏余量）。
  /// [接线] 原来是常量 400。分级只影响淘汰时机，不影响任何像素结果。
  public static var defaultMemoryCountLimit: Int {
    self.isLowTierDevice ? 240 : 400
  }

  /// DataCache 目录名（位于 Library/Caches 下：系统可回收；clearCaches 清它，
  /// 删整个 Caches 目录的清理路径也会一并覆盖）。
  public static let diskCacheName = "com.tiebalite.nuke"

  // MARK: 共享管线（全 App 唯一）

  /// 全 App 共享管线：Referer 注入 + 内存/磁盘上限对齐旧设置。
  ///
  /// 结构（均有文档依据）：
  /// - 磁盘层用 DataCache（cache-layers.md「Aggressive Disk Cache」）：
  ///   忽略 Cache-Control 的持久 LRU；`dataCachePolicy = .storeAll`：带处理器的
  ///   请求同时存处理后的图与**原始字节**，保存/分享的无处理器 loadData 才能
  ///   命中展示请求落下的原图数据（`.automatic` 只给无处理器请求存原始字节，
  ///   保存路径必然二次全量下载，2026-09-13 修复）。上限 400MB 仍然生效。
  /// - 手动启用 DataCache 时必须关掉原生 URLCache（cache-layers.md 明确要求），
  ///   这里由 makeHeaderInjectingDataLoader() 里 `urlCache = nil` 完成。
  /// - 内存层 ImageCache 存**已解码**位图（performance-guide），所以必须配
  ///   合 resizeProcessor 做目标尺寸下采样，不能全尺寸解码。
  public static let pipeline: ImagePipeline = {
    let dataLoader = makeHeaderInjectingDataLoader()
    let imageCache = ImageCache(
      costLimit: memoryLimitBytes(forDiskBytes: defaultDiskLimitBytes),
      countLimit: defaultMemoryCountLimit
    )
    let dataCache = try? DataCache(name: diskCacheName)
    dataCache?.sizeLimit = defaultDiskLimitBytes
    // ⚠️ 磁盘图片缓存**没有 TTL**（vendored Nuke 13 的 DataCache 只有容量上限，
    // 淘汰是纯 LRU；sweepInterval 只是"多久跑一次 LRU 清扫"）。想限制图片寿命
    // 就得降 sizeLimit，别指望过期时间——这里是唯一改动点。

    var configuration = ImagePipeline.Configuration(dataLoader: dataLoader)
    configuration.dataCache = dataCache
    configuration.imageCache = imageCache
    configuration.dataCachePolicy = .storeAll
    // 渐进式解码保持关闭：旧 expo-image 路径没有此行为，列表滚动优先省 CPU。
    configuration.isProgressiveDecodingEnabled = false

    return ImagePipeline(
      configuration: configuration,
      delegate: TiebaNukePipelineDelegate(dataLoader: dataLoader)
    )
  }()

  // MARK: 预取器

  /// 供原生列表/浏览器共用的预取器工厂（每个屏幕一个实例；预取器释放时自动
  /// 取消未完成任务，见 prefetching.md）。
  ///
  /// 预取请求请带上与展示时**相同**的下采样处理器（resizeProcessor/fitProcessor），
  /// 否则内存缓存里存的是全尺寸位图（prefetching.md 的 warning）；预取优先级自动为 .low。
  public static func makePrefetcher() -> ImagePrefetcher {
    ImagePrefetcher(
      pipeline: pipeline,
      destination: .memoryCache,
      // [接线] 低端机串行预取（1 条），其余 2 条：并发解码是内存峰值的主要来源，
      // 低端机 CPU 核数少、内存也小，降并发只影响预取速度，不影响已显示的任何像素。
      maxConcurrentRequestCount: self.isLowTierDevice ? 1 : 2
    )
  }

  // MARK: 下采样

  /// 按目标**像素**尺寸下采样（避免全尺寸解码；performance-guide「Downsample Images」）。
  ///
  /// 语义（ImageProcessors.Resize，见 image-processing.md / ImageProcessors.Resize）：
  /// - `unit: .pixels`：targetPixelSize 直接按像素解释，不再乘屏幕 scale；
  /// - `contentMode: .aspectFill`：等比缩放到至少填满目标尺寸（长边可能大于目标），
  ///   配合 crop: false 不裁切——列表 cover/contain 两种显示都只解码到"够用"；
  /// - `upscale: false`：小图不放大，避免二次重采样。
  public static func resizeProcessor(targetPixelSize: CGSize) -> any ImageProcessing {
    ImageProcessors.Resize(
      // [接线] 套一层设备护栏（见 maxDecodePixelSize）：现有实参都远低于上限，等于原样透传。
      size: self.clampedDecodePixelSize(targetPixelSize),
      unit: .pixels,
      contentMode: .aspectFill,
      crop: false,
      upscale: false
    )
  }

  /// resizeProcessor 的 "fit inside" 变体：长边 ≤ targetPixelSize（等比不裁切），
  /// 与 byPreparingThumbnail 语义一致。缩略图目标为方框时**不要**换回
  /// aspectFill——长图/横幅会被解成远超目标方框的位图。
  public static func fitProcessor(targetPixelSize: CGSize) -> any ImageProcessing {
    ImageProcessors.Resize(
      // [接线] 同 resizeProcessor：设备护栏，现有实参不触顶。
      size: self.clampedDecodePixelSize(targetPixelSize),
      unit: .pixels,
      contentMode: .aspectFit,
      crop: false,
      upscale: false
    )
  }

  /// 降采样语义：fill = aspectFill（长边可能超目标，配 crop:false 不裁切）；
  /// fit = aspectFit（长边 ≤ 目标）。方框目标（缩略图/头像）用 fit，否则长图
  /// 会被解成远超方框的位图。
  public enum Mode { case fill, fit }

  /// 显示档处理器（aspectFill 视图专用）：按视图**精确显示尺寸**下采样（cover
  /// 裁切）并把圆角烘焙进位图。两件事各自都是一次修正：
  ///   1. 旧口径是"正方形上界 + crop:false"，横图/长图会被解成远超显示尺寸的
  ///      位图（长图可达 4 倍像素），滚动时新图的解码与纹理上传成倍放大；
  ///   2. 圆角烘焙后显示层不必再 masksToBounds，每帧一次离屏合成随之消失。
  /// 视图侧因此只需 contentMode = .scaleAspectFill（与裁切后的位图逐像素等价），
  /// contentMode = .scaleAspectFit 的视图不要用这个处理器（会被裁掉留白）。
  public static func displayProcessor(
    targetSize: CGSize,
    cornerRadius: CGFloat,
    scale: CGFloat
  ) -> any ImageProcessing {
    let pixel = CGSize(
      width: max((targetSize.width * scale).rounded(), 1),
      height: max((targetSize.height * scale).rounded(), 1)
    )
    let resize = ImageProcessors.Resize(
      size: pixel,
      unit: .pixels,
      contentMode: .aspectFill,
      crop: true,
      // 允许放大：位图必须与显示框**逐像素同尺寸**，否则烘焙的圆角会随视图的
      // 二次缩放被放大（小图尤其明显）。小图本来就要被视图放大，这里只是提前做。
      upscale: true
    )
    guard cornerRadius > 0.5 else { return resize }
    return ImageProcessors.Composition([
      resize,
      ImageProcessors.RoundedCorners(radius: cornerRadius * scale, unit: .pixels),
    ])
  }

  /// 单图 fit 显示档处理器（aspectFit 视图专用）：fit 缩放到视图**像素**尺寸 +
  /// 圆角烘焙进位图。fit 产物 = 视图内的可见图矩形（长边贴边、短边留白），
  /// 圆角在该矩形上生效；视图侧 contentMode = .scaleAspectFit 居中显示即与
  /// 「clipsToBounds 圆角」逐像素等价，而每帧一次的离屏合成随之消失。
  /// upscale: true 与 displayProcessor 同理——位图必须贴住显示像素，否则烘焙
  /// 的圆角随视图的二次放大被放大（小图尤其明显）。
  public static func fitDisplayProcessor(
    targetSize: CGSize,
    cornerRadius: CGFloat,
    scale: CGFloat
  ) -> any ImageProcessing {
    let pixel = CGSize(
      width: max((targetSize.width * scale).rounded(), 1),
      height: max((targetSize.height * scale).rounded(), 1)
    )
    let resize = ImageProcessors.Resize(
      size: pixel,
      unit: .pixels,
      contentMode: .aspectFit,
      crop: false,
      upscale: true
    )
    guard cornerRadius > 0.5 else { return resize }
    return ImageProcessors.Composition([
      resize,
      ImageProcessors.RoundedCorners(radius: cornerRadius * scale, unit: .pixels),
    ])
  }

  /// 视图加载的 options 组装：全 App 只有这一处知道「哪条管线 + 哪个降采样处理器
  /// + 要不要淡入」。调用点直接交给 NukeExtensions.loadImage(with:options:into:)。
  /// maxPixel ≤ 0 = 不下采样（大图档）。
  public static func options(
    maxPixel: CGFloat,
    mode: Mode = .fill,
    transition: Bool = false
  ) -> ImageLoadingOptions {
    let size = CGSize(width: maxPixel, height: maxPixel)
    let processor: (any ImageProcessing)? = maxPixel > 0
      ? (mode == .fit ? fitProcessor(targetPixelSize: size) : resizeProcessor(targetPixelSize: size))
      : nil
    return options(processor: processor, transition: transition)
  }

  /// 处理器直给版（显示档处理器见 displayProcessor；两处共用同一条管线口径）。
  public static func options(
    processor: (any ImageProcessing)?,
    transition: Bool = false
  ) -> ImageLoadingOptions {
    var options = ImageLoadingOptions()
    options.pipeline = pipeline
    options.transition = transition ? .fadeIn(duration: 0.2) : nil
    options.isProgressiveRenderingEnabled = false
    if let processor {
      options.processors = [processor]
    }
    return options
  }

  // 一步式加载（`TiebaNuke.load(into:…)`）已删除：视图加载统一走 NukeExtensions（换图先取消在途请求、
  // isPrepareForReuseEnabled 清旧图、过渡动画、视图释放自动取消）；手写版漏过「复用行重放淡入、换图不取消旧请求」。

  // MARK: 工具

  /// http:// → https://（ATS 禁止明文 HTTP；与 src/utils/thumbnail.ts 同一策略）。
  /// 其余 scheme（file/data/…）原样返回。
  public static func secureURL(_ url: URL) -> URL {
    guard url.scheme?.lowercased() == "http",
          var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return url
    }
    components.scheme = "https"
    return components.url ?? url
  }

  // MARK: GIF 三档（判定 / 显示 / 播放）

  // 实测口径（2026-10-05，线上探针逐档下载比对；**推翻了 10-03 的改写方案**）：
  // - 服务端对 GIF **没有任何元数据标记**：Media.type=3 与普通图相同、URL 全 .jpg
  //   后缀；判定只能靠响应字节/HEAD 的 Content-Type。
  // - 图床的变换段（`forum/<enc params>/sign=…`）**与 sign 严格绑定，客户端一律
  //   不许改写**：任何改写（含"去掉 g=0"）都会被 CDN 打回一张 4.2KB 的贴吧 logo
  //   占位图（实测 d5f0/caca/ae3b 三组 sign × 全部改写组合，无一例外）。
  // - 服务端下发的字段本身就是正确的三档，原样使用即可：
  //   帖页 cdn_src=静态压缩档（真首帧，几十 KB）· big_cdn_src=动图档（no-g，GIF
  //   字节）· origin_src=原图；动态页 big_pic=静态档 · src_pic=动图档 · origin_pic。
  //   （CDN 对 GIF 不重采样：动图各档字节相同，原样用最小档。）
  // - HEAD 动图档返回 Content-Type: image/gif——零字节下载即可判定。
  // 消费口径：卡片显示静态档 + HEAD 判角标；进帖/查看器拉动图档播放；「查看原图」
  // 走 originSrc（GIF 与原图同字节，命中缓存秒切）。

  /// 探测结果缓存（会话级；进程内字典即可，HEAD 本身零 body，别为它落盘）。
  ///
  /// [接线 2026-10-05] 原为 `nonisolated(unsafe) static var` + NSLock。该写法属于 Swift 6 绕过
  /// （人工声明「这块全局可变状态是安全的」，编译器不再检查）。改成 `TiebaMutex<[URL: Bool]>`
  /// （跨版本 shim，见 Core/TiebaMutex.swift；标准库 Mutex 是 iOS 18+）：
  /// 同样的会话级字典，但互斥由运行时对象保证，`Sendable` 由编译器校验，`nonisolated(unsafe)` 消失。
  private static let gifProbeResults = TiebaMutex<[URL: Bool]>([:])

  /// 零流量 GIF 判定：HEAD 看 Content-Type，头不明确时退到前 6 字节魔数。
  /// 探测目标必须是**动图档 URL**（帖页 big_cdn_src / 动态页 src_pic，服务端原样
  /// 字段，绝不能改写）——显示档对同一张 GIF 有 60% 是 g=0 静态 JPEG（线上取证见
  /// docs/uikit-migration/41-*），对它做 HEAD 必然漏判。失败（网络错/非 http(s)）
  /// 返回 nil 不缓存，下次再试；结论缓存整个会话。
  public static func probeGIF(_ url: URL) async -> Bool? {
    if let cached = gifProbeResults.withLock({ $0[url] }) { return cached }
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          components.scheme?.hasPrefix("http") == true else { return nil }
    // 单飞：同一 URL 的在途探测共享一个 Task（见 gifProbeInFlight 的理由）。
    let task = gifProbeInFlight.withLock { inFlight -> Task<Bool?, Never> in
      if let existing = inFlight[url] { return existing }
      let created = Task<Bool?, Never> {
        let result = await performGIFProbe(url)
        // 只清自己那一格：同 URL 的后来者拿到的是同一个 Task，不会插进来。
        gifProbeInFlight.withLock { $0[url] = nil }
        return result
      }
      inFlight[url] = created
      return created
    }
    return await task.value
  }

  /// 在途探测（单飞表）。为什么必须单飞：一帖 25 张动图会被三条路径分别探测
  ///（信息流卡片角标 / 帖子行 / 查看器），而 nil 结论（超时、头不可信、非 http）
  /// 按设计**不缓存**、下次重新布局又会再来一轮 —— 没有单飞时同一个 URL 会被并发探
  /// 2~3 次，几十条重复 HEAD 挤在 URLSession 的每主机连接数（6）上排队，
  /// 越靠后的探测回来得越晚（用户观感："越往后越探不出来"）。
  private static let gifProbeInFlight = TiebaMutex<[URL: Task<Bool?, Never>]>([:])

  /// 真探测：HEAD 看 Content-Type，头不明确时退到前 6 字节魔数。
  private static func performGIFProbe(_ url: URL) async -> Bool? {
    var request = URLRequest(url: url)
    request.httpMethod = "HEAD"
    request.setValue(referer, forHTTPHeaderField: "Referer")
    guard let (_, response) = try? await sharedSession.data(for: request),
          let http = response as? HTTPURLResponse else { return nil }
    let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
    if contentType.contains("image/gif") {
      gifProbeResults.withLock { $0[url] = true }
      return true
    }
    // 头"不是 gif"分两种：明确是别的图片类型（可信，直接判否）；缺失/octet-stream/
    // 非 image/*（不可信——CDN 换头、占位图、代理都可能这样）→ 取前几字节看魔数。
    // 为什么只在这种情况才多花一次 Range GET：正常图片类型下 HEAD 与 GET 的
    // Content-Type 实测 116/116 一致（线上取证），没必要给每张静图加一次请求。
    let headerIsConclusive = contentType.hasPrefix("image/")
      && !contentType.contains("octet-stream")
    if headerIsConclusive {
      gifProbeResults.withLock { $0[url] = false }
      return false
    }
    guard let isGIF = await sniffGIFMagic(url) else { return nil }
    gifProbeResults.withLock { $0[url] = isGIF }
    return isGIF
  }

  /// 依序探测候选 URL，返回**第一个判定为动图**的 URL；全不命中 → nil。
  ///
  /// 为什么需要一条候选链（线上取证 2026-10-06，用户报的 p/11060036651 全量 29 图 /
  /// 25 张动图）：服务端对 GIF 没有任何元数据标记，判定只能看响应字节；而**显示档**
  /// （帖页 cdn_src 的 g=0 档）对其中 15/25 张返回的是静态 JPEG——只探显示档必然漏判；
  /// 动图档 big_cdn_src 与 原图档 origin_src 各自 25/25 命中（两者字节相同）。
  /// 候选由调用方按「有独立动图档就只探它，没有才补原图档」构造（见
  /// TiebaPostRowText.gifProbeCandidates / TiebaPhotoBrowserImageLoader.gifProbeCandidates）：
  /// 常态一张图只花一次 HEAD，不放大列表的探测流量。
  public static func firstGIFURL(among candidates: [URL?]) async -> URL? {
    var seen = Set<URL>()
    for candidate in candidates {
      guard let url = candidate, seen.insert(url).inserted else { continue }
      if await probeGIF(url) == true { return url }
    }
    return nil
  }

  /// 前 6 字节魔数判定（"GIF8"）。HEAD 头不可信时的兜底：Range GET 只取几个字节，
  /// 失败返回 nil（调用方据此不缓存结论，下次重试）。
  private static func sniffGIFMagic(_ url: URL) async -> Bool? {
    var request = URLRequest(url: url)
    request.setValue(referer, forHTTPHeaderField: "Referer")
    request.setValue("bytes=0-5", forHTTPHeaderField: "Range")
    guard let (data, response) = try? await sharedSession.data(for: request),
          let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
    else { return nil }
    return data.starts(with: [0x47, 0x49, 0x46, 0x38])
  }

  /// 带防盗链头的轻量会话：仅供 HEAD 判定（图片字节一律走 pipeline，别用它取图）。
  private static let sharedSession: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.urlCache = nil
    config.httpShouldUsePipelining = true
    return URLSession(configuration: config)
  }()

  /// 在场字节嗅探（响应已经下载完时的零成本判定）：Nuke 默认解码器按内容识别
  /// GIF 并把原始字节挂到 container.data，处理器只替换 .image（ImageProcessing
  /// 默认桥），所以经过显示档处理器的响应仍可判。
  public static func isGIFContainer(_ container: ImageContainer) -> Bool {
    if container.type == .gif { return true }
    if let data = container.data {
      return data.starts(with: [0x47, 0x49, 0x46, 0x38]) // "GIF8"
    }
    return false
  }


  /// 运行时调整缓存上限（对齐"设置 → 最大缓存大小"滑块）。
  ///
  /// 调用点：TiebaAppBootstrap.applyCacheLimits 与 TiebaMoreSettingsViewController
  /// 的缓存档位变更（两条路径口径一致：内存走 memoryLimitBytes(forDiskBytes:)）。
  ///
  /// 线程：nonisolated，ImageCache/DataCache 自身线程安全，任意线程可调。
  public static func setCacheLimits(diskBytes: Int, memoryBytes: Int) {
    if let dataCache = pipeline.configuration.dataCache as? DataCache {
      let limit = max(0, diskBytes)
      // [修复 R23-1] 只在**缩容**时手动 sweep。sweep 是同步的磁盘遍历，
      // 原来无条件调用 → 启动路径与设置页滑块回调都会在主线程上做一次全目录扫描（扩容时纯属白做：
      // 旧数据仍然有效，没有任何需要立刻清掉的东西）。扩容交给 DataCache 自己的周期性清扫。
      let didShrink = limit < dataCache.sizeLimit
      dataCache.sizeLimit = limit
      if didShrink {
        dataCache.sweep()
      }
    }
    if let imageCache = pipeline.configuration.imageCache as? ImageCache {
      let limit = max(0, memoryBytes)
      imageCache.costLimit = limit
      imageCache.trim(toCost: limit)
    }
  }

  /// 只清 Nuke 的两层缓存（手动"清理缓存"/系统内存告警用）。
  ///
  /// ⚠️ 内存层是已解码位图，只删 Caches 目录清不到它，必须走这个调用释放
  /// （内存告警时不清会被 watchdog 强杀）。
  public static func clearCaches() {
    pipeline.cache.removeAll(caches: [.all])
  }

  /// 删除旧 TiebaImageIO 的磁盘目录（迁移后无主，clearCaches 清不到它）。
  /// 幂等；只在启动清理/手动清缓存调用，内存告警路径不要调（纯磁盘 I/O）。
  public static func removeLegacyImageCacheDirectory() {
    guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
      return
    }
    try? FileManager.default.removeItem(
      at: base.appendingPathComponent("TiebaImageIO", isDirectory: true)
    )
  }

  // MARK: 内部

  /// 构造注入了 Referer 的 DataLoader：DataCache 启用时 URL 缓存必须关掉
  /// （cache-layers.md），Referer 写进 session 级 httpAdditionalHeaders，
  /// 该 session 发出的每个图片请求都会带上（含预取/表情/预览等所有调用方）。
  static func makeHeaderInjectingDataLoader(
    additionalHeaders: [String: String] = [:]
  ) -> DataLoader {
    let configuration = DataLoader.defaultConfiguration
    configuration.urlCache = nil

    var headers = configuration.httpAdditionalHeaders ?? [:]
    headers["Referer"] = referer
    for (key, value) in additionalHeaders {
      headers[key] = value
    }
    configuration.httpAdditionalHeaders = headers

    return DataLoader(configuration: configuration)
  }

}
