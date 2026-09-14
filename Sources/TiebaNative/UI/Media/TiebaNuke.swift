// ============================================================
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
//   - 图片请求不设 User-Agent（TiebaNativeClient.swift:133 的 "tieba/12.41.7.1"
//     只用于 API 请求）；需要再加头时用 TiebaNukePipelineDelegate(additionalHeaders:)。
//
// 缓存上限：内存 32MB / 磁盘 400MB，启动与设置页滑块都经
// setCacheLimits(diskBytes:memoryBytes:) 重设（内存 = 磁盘/16，夹 8–32MB）。
// 磁盘上限对应偏好 cacheMaxSizeMb（默认 400），清缓存必须同时清
// DataCache 与内存 ImageCache（只删目录清不到已解码位图）。
//
// ATS：Nuke 默认 DataLoader 走 URLSession，受 ATS 约束，http:// 图片经
// secureURL(_:) 升级为 https（与 src/utils/thumbnail.ts 同一策略）。
// ============================================================

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
public final class TiebaNukePipelineDelegate: ImagePipeline.Delegate, @unchecked Sendable {
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

  /// 内存缓存默认上限：32MB（旧 expo-image maxMemoryCost 档位带 8–32MB 的上限）。
  public static let defaultMemoryLimitBytes = 32 * 1024 * 1024

  /// 内存缓存条目数上限（200 条：一屏列表图片 + 头像余量）。
  public static let defaultMemoryCountLimit = 200

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
      costLimit: defaultMemoryLimitBytes,
      countLimit: defaultMemoryCountLimit
    )
    let dataCache = try? DataCache(name: diskCacheName)
    dataCache?.sizeLimit = defaultDiskLimitBytes

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
      maxConcurrentRequestCount: 2
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
      size: targetPixelSize,
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
      size: targetPixelSize,
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

  // 一步式加载（`TiebaNuke.load(into:…)`）已删除：视图加载统一走 NukeExtensions
  // （loadImage(with:options:into:progress:completion:) / cancelRequest(for:)），
  // 它自带"换图先取消在途请求、isPrepareForReuseEnabled 清旧图、过渡动画、
  // 视图释放自动取消"，本文件曾手写一遍的那套关联对象/ Cancellable 包装因此
  // 全部删除（手写版漏过：复用行重放淡入、换图不取消旧请求）。

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

  /// 运行时调整缓存上限（对齐"设置 → 最大缓存大小"滑块）。
  ///
  /// 调用点：TiebaAppBootstrap.applyCacheLimits 与 TiebaMoreSettingsViewController
  /// 的缓存档位变更（两条路径口径一致：内存 = 磁盘/16 夹 8–32MB）。
  ///
  /// 线程：nonisolated，ImageCache/DataCache 自身线程安全，任意线程可调。
  public static func setCacheLimits(diskBytes: Int, memoryBytes: Int) {
    if let dataCache = pipeline.configuration.dataCache as? DataCache {
      let limit = max(0, diskBytes)
      dataCache.sizeLimit = limit
      // sizeLimit 缩小时不会立即生效（DataCache 周期性 sweep），手动踢一次
      // 让"设置 → 最大缓存大小"立刻收敛到新上限。
      dataCache.sweep()
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
