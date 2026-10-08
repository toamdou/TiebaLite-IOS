// 从 TiebaPhotoBrowser.swift 拆出（H10 千行文件拆分）：过渡/错误/图片加载/动作等值类型。
// 纯搬运：整类型逐字搬走。

import JXPhotoBrowser
import Nuke
import UIKit

/// item 的值类型投影；调用方（列表/帖子页/吧页/资料页）从行模型直构，
/// url 非法的条目由调用方丢弃（不再有字典编组与解析回值）。
/// public + Sendable：present（公开入口）的入参，跨主队列派发只带值。
public struct TiebaPhotoItem: Sendable {
  let url: URL
  let thumbUrl: URL?
  /// 原图档（行模型 originURL）：nil = 该图没有原图档，菜单不展示「保存原图」。
  let originUrl: URL?
  /// 动图档（帖页 big_cdn_src / 动态页 src_pic）：GIF 判定与播放**优先**用它。
  /// nil = 服务端没给独立动图档，判定退到 url / originUrl（见 gifProbeCandidates）。
  /// [修复 2026-10-06] 原来查看器拿显示档（cdn_src 的 g=0 档）做 HEAD 探测，而线上
  /// 取证显示该档对六成动图返回静态 JPEG ⇒ 点开永远不动（用户实测的"识别了但不播"）。
  let animatedUrl: URL?
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
    animatedUrl: URL? = nil,
    // [修复] 给默认值：列表侧（ForumVC / UserProfileVC / FeedRowInteraction）构造查看器项时
    // 并不预知该图是不是 GIF（服务端对 GIF 无元数据标记，判定只能靠字节嗅探）。
    // 默认 false = 走显示档处理器（列表要的静态压缩档）；查看器的 GIF 播放由
    // apply(container:…) 里的 TiebaNuke.isGIFContainer 嗅探兜底，不依赖这个标志。
    isGif: Bool = false,
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
    self.animatedUrl = (animatedUrl != url) ? animatedUrl : nil
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
      animatedUrl: animatedUrl,
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
    // [修复] 模型 TiebaThreadImage 已无 isGif 字段（服务端对 GIF 也没有任何元数据标记，见 TiebaNuke「GIF 三档」），
    // 所以构造期无法预判；这里只按「原档模式」选档，真正的 GIF 判定改在拿到响应字节时嗅探（见 apply）。
    let raw = preferences.dataSaverMode == "origin"
      ? origin
      : (image.src.isEmpty ? origin : image.src)
    guard let url = TiebaPhotoItem.normalizedURL(raw) else { return nil }
    let thumbRaw = preferences.displayURL(for: image)?
      .absoluteString ?? raw
    self.init(
      url: url,
      thumbUrl: TiebaPhotoItem.normalizedURL(thumbRaw),
      originUrl: TiebaPhotoItem.normalizedURL(origin),
      // [修复] 动图档（big_cdn_src）随 item 一起带下去：查看器对它做 HEAD 探测（25/25 命中），
      // 播放也拉它；显示档只当垫图（对 GIF 六成是静态 JPEG，见 TiebaNuke 的三档取证）。
      animatedUrl: TiebaPhotoItem.normalizedURL(image.bigSrc),
      isGif: false,   // 构造期未知；load 前用 firstGIFURL 判、apply 里再用容器嗅探兜底
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
    TiebaImageURL.normalized(raw)
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
  /// 载入一张图（已解码、可直接上屏）；GIF 返回附带原始字节的 container 供 Gifu 播放。
  ///
  /// GIF 分支的两个硬约束（依据 vendored 源码，勿凭记忆改）：
  /// - **不套 resizeProcessor**：ImageProcessors.Resize 会对解码结果重绘
  ///   （CoreGraphics），多帧动画只剩第一帧 → 动图变静图。无处理器请求走
  ///   Nuke 默认解码器，GIF 产物是首帧 UIImage，原始 GIF 字节挂在
  ///   ImageContainer.data（ImageDecoders+Default.swift:193 + ImageContainer
  ///   文档「attaches data to GIFs」），播放交给 Gifu（JXGIFObservedImageView）。
  /// - **isPreview 帧不是终图**：渐进解码的 GIF 会先发一帧静态预览
  ///   （同文件 :84-87，isPreview: true）。本管线 progressive 关闭，正常到不了，
  ///   但这里显式拒绝：拿数据任务的原始字节重新解码（data 任务不会返回预览帧）。
  /// - parameter isGif: 仅查看器会显式传 `item.isGif`；列表缩略图调用方不传（默认 false = 走显示档处理器，
  ///   正是列表要的「静态压缩档」）。GIF 判定不依赖模型字段：查看器在 apply 里用字节嗅探兜底。
  static func load(_ request: ImageRequest, isGif: Bool) async throws -> ImageContainer {
    if isGif {
      // GIF 必须走**无处理器**请求（见上方约束）：isGif 可能来自 probe（item.isGif 在帖子图
      // 路径上恒 false），所以这里按 url 重建、丢掉展示档处理器 —— 带 Resize 会把多帧压成首帧。
      let gifRequest = ImageRequest(url: request.url)
      let response = try await TiebaNuke.pipeline.imageTask(with: gifRequest).response
      if !response.isPreview {
        return response.container
      }
      let (data, _) = try await TiebaNuke.pipeline.data(for: gifRequest)
      guard let image = UIImage(data: data) else {
        throw TiebaPhotoBrowserError.incompleteGif
      }
      return ImageContainer(image: image, type: .gif, data: data)
    }
    // [修复] 原来这里重新 new 一个「只有位图」的 container：GIF 的原始字节与 .gif 类型
    // 在这一步被丢掉，apply 里的字节嗅探兜底因此永远不可能命中（HEAD 失败/漏判的路径没救）。
    // Nuke 的默认处理器桥是 `var container = container; container.image = output`
    // （Vendor/Nuke/Sources/Nuke/Processing/ImageProcessing.swift:62-69）——处理器只换
    // .image，data/type 原样保留，所以取 response.container 直接透传
    //（image(for:) 只回位图，拿不到容器，故走 imageTask）。
    let response = try await TiebaNuke.pipeline.imageTask(with: request).response
    return response.container
  }

  /// GIF 判定候选链（可靠度排序；去重由 TiebaNuke.firstGIFURL 做）。
  ///
  /// 口径（线上取证，见 TiebaNuke「GIF 三档」注）：
  /// - 有独立动图档（帖页 big_cdn_src / 动态页 src_pic）→ 只探它。动图档对动图 25/25
  ///   命中，且一次 HEAD 就够（查看器一屏一页，多探一次原图档是给 HEAD 抖动留的兜底）。
  /// - 没有动图档（服务端没下发，或构造方只给了显示档）→ 显示档 + 原图档：显示档对
  ///   GIF 只有四成是动图字节（g=0 档），原图档才是 25/25 的那个。
  static func gifProbeCandidates(_ item: TiebaPhotoItem) -> [URL?] {
    let display = TiebaNuke.secureURL(item.url)
    guard let animated = item.animatedUrl else {
      return [display, item.originUrl.map(TiebaNuke.secureURL)]
    }
    let origin = item.originUrl.map(TiebaNuke.secureURL)
    return [TiebaNuke.secureURL(animated), origin == display ? nil : origin]
  }

  /// 展示请求（预取与加载必须同形态：同 URL + 同处理器，否则内存缓存键不同）。
  /// GIF 不套处理器（见 load 的约束）。
  static func request(_ item: TiebaPhotoItem, pixelSize: CGSize, containerSize: CGSize) -> ImageRequest {
    let url = TiebaNuke.secureURL(item.url)
    guard let processor = processor(item, pixelSize: pixelSize, containerSize: containerSize) else {
      return ImageRequest(url: url)
    }
    return ImageRequest(url: url, processors: [processor])
  }

  /// 缩略图请求（两级加载的"先出"那一级）：方框目标一律 fit（TiebaNuke 的口径：
  /// 方框目标用 fill 会把长图/横幅解成远超方框的位图）。
  static func thumbRequest(_ url: URL?, pixelSize: CGSize) -> ImageRequest? {
    guard let url else { return nil }
    return ImageRequest(
      url: TiebaNuke.secureURL(url),
      processors: [TiebaNuke.fitProcessor(targetPixelSize: Self.target(pixelSize))]
    )
  }

  /// 展示档处理器 —— 按**图片自身比例 + 展示框**选目标，不再无脑用整屏框 aspectFill。
  ///
  /// [N1] 旧口径（整屏框 aspectFill，见 review-report-round2 N1）在比例不符时多付 5～30 倍位图：
  /// 12000×3000 全景 → 10200×2556 ≈ 105MB，而"长边铺满"展示只需要 1179×295 ≈ 1.4MB；
  /// 且 fill 的 scale ≥ 1 时 Nuke 直接返回原图（Graphics.swift:39-40 `guard scale < 1 || upscale`），
  /// 下采样被整体绕过。
  ///
  /// 新口径与 cell 的展示语义 1:1：
  /// - 普通图：cell 基础布局是"长边铺满"（aspectFit）⇒ 目标 = **fit 进屏框**，与展示 1:1；
  /// - 长图：cell 进长图阅读模式后按**宽铺满**显示，fit 进屏框会把 1080×20000 解成 138×2556
  ///   的细带（没法读）⇒ 保持 aspectFill：对竖长图 max(宽比, 高比) 恰好退化成 fit-width
  ///   （1179×21833），源图宽 ≤ 屏宽时才绕过（此时本来就没有像素可省）。
  /// 长图判定复用 cell 的同一个函数（TiebaPhotoItem.isLongImage(in:)），不新增第二套阈值。
  static func processor(
    _ item: TiebaPhotoItem,
    pixelSize: CGSize,
    containerSize: CGSize
  ) -> (any ImageProcessing)? {
    guard !item.isGif else { return nil }
    let target = Self.target(pixelSize)
    return item.isLongImage(in: containerSize)
      ? TiebaNuke.resizeProcessor(targetPixelSize: target)
      : TiebaNuke.fitProcessor(targetPixelSize: target)
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

/// 查看器动作（长按菜单与顶栏按钮共用一套）。
/// 原为裸字符串在四个类型间流转（复检 Q3-6）：拼错/新增动作是静默无反应；
/// 类型化后 `perform` 是穷举 switch，新增 case 编译期就能发现漏改。
/// rawValue 只在 Vendor 边界（JXPhotoBrowser 的 cell 回传字符串）用一次。
enum TiebaPhotoBrowserAction: String {
  case save
  case saveOriginal = "save-original"
  case viewOriginal = "view-original"
  case share
}

/// @MainActor：会话从创建到销毁都绑在 UIKit 上（present/转场/动画/delegate
/// 回调），Swift 6 下不隔离的话，UIView.animate、Nuke 的 @MainActor @Sendable
/// 回调里捕获 self 都会被判 sending 'self'。入口（present/startSession/onMain）
/// 负责把调用收在主线程；delegate 用 @preconcurrency 一致性——JXPhotoBrowser
/// 4.x 是未标注并发（Swift 5 模式编译）的第三方 UI 协议，其回调按框架契约在
/// 主线程派发，一致性隔离不匹配只降级不改变运行时行为。
