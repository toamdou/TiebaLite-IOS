// 超分辨率（PiperSR_2x，2×）——大图模式长按「超分辨率」的执行体。
//
// 接口（coremlcompiler 机器复核，非 README 说法）：
//   input_image  : IMAGE 128×128 32BGRA      output_image : IMAGE 256×256 32BGRA
//   驱动 = MLDictionaryFeatureProvider(["input_image": MLFeatureValue(pixelBuffer:)]) → prediction(from:)
//   不需要 MLMultiArray / NCHW 转置 / 手工归一化（图内自带 ×1/255）；
//   computeUnits = .cpuAndNeuralEngine；模型保持 mlProgram FP16（不做量化：ANE 对 FP16 mlProgram 最优）。
//   ⚠️ MLModel 同时有 sync 与 async 两个 prediction(from:)：在 async 函数里直接写会**选到 async 版**
//      （编译报 "expression is 'async' but is not marked with 'await'"）。这里统一走 predict(...)
//      这个非 async 的静态包装，确保是**同步阻塞**调用（我们要它占住执行体、而不是让出）。
//
// 分块几何：
//   tile 128、halo 8 ⇒ stride 112，每块只信中央 112×112 输入 → 输出中央 224×224（有效吞吐 77%）。
//   块起点 clamp 到 [0, 边长−128]，**不零填充**（零填充会在边缘画出一道暗边）：
//   clamp 之后每一块都完整落在图内，边界块的边缘就是图像边缘本身。
//   核心区按轴切分 [0,len)：首块 [0, s+120)、中间块 [s+8, s+120)、末块 [上一块末, len)
//   ⇒ 恰好无缝、**不重叠**地铺满整幅目标位图。不重叠是必须的：重叠区会被后画的块覆盖，
//   而同一像素由两个不同位置/不同感受野的块产出时数值并不相同，接缝处会出现内容不连续。
//
// 渐进式：先算**可见视口**内的块 → 立刻回调一张快照给 UI 显示，其余区域后台补齐。
//   首帧看到的是"视口已锐化 + 其余区域一次性放大版"，与总耗时解耦。
//   快照 = dest.makeImage()（整幅拷贝），全程 ≤ 4~5 张。
//
// 关于"三段流水线"：切块（CPU 绘制 ~0.06ms/块）与推理（ANE ~9ms/块）本可用生产者/消费者重叠，
//   但 **CVPixelBuffer（CVBuffer）在 Swift 6 SDK 里不是 Sendable**，跨任务传递必须
//   @unchecked Sendable 包装 —— 本仓铁律禁止。收益上界也只有 0.7%，不值得为它破例。
//   因此：actor 内单循环（推理串行，ANE 本来就串行）+ CVPixelBufferPool 复用输入块。
//   绝不做多线程 prediction（多个 MLModel 实例/并发推理在 ANE 上更慢且抖动更大）。
//
// 零拷贝 / 分配：
//   · 输入 buffer 走 CVPixelBufferPool（IOSurface 后备，ANE 友好），全程只有一块在飞、反复复用。
//   · 源图一次绘制成 tile（不中转 UIImage、不做色彩空间往返）。
//   · 落图 = 按行 memcpy（目标与输出同为 BGRA，stride 各自取），**不用** CGContext.draw。
//   · 每块套 autoreleasepool：CG 绘制会产生大量临时对象。
//
// 内存 / 线程纪律：
//   · 目标位图**只分配一次**（2× BGRA8 CGContext，malloc 支撑）：data 指针在 context 生命周期内稳定，
//     不需要 lock/unlock。⚠️ 实测坑：拿 CVPixelBuffer 当画布、未加锁就 makeImage() 会画出整张白。
//   · 输入 tile 必须先 lock 再建 CGContext —— 不锁会拿到私有内存，画进去的内容模型根本看不到
//     （第一版实测：输出整张纯白）。
//   · 推理全程在 actor 的串行执行体上（调用方包在 Task.detached(priority:.userInitiated) 里），不占主线程。
//   · CVPixelBuffer 在 Swift 里由 ARC 管理（CVPixelBufferRelease 已标 unavailable），
//     纪律是"用完即丢引用"，不要 Unmanaged、不要手动 release。

import CoreGraphics
import CoreML
import CoreVideo
import Foundation

enum TiebaSuperResolutionError: Error, Equatable {
  case sourceNotReady
  case unsupportedSize(width: Int, height: Int)
  case tooManyPixels(Int)
  case modelUnavailable(String)
  case bitmapAllocationFailed
  case predictionFailed
  case cancelled
}

enum TiebaSuperResolutionLimits {
  /// 模型固定输入边长。
  static let tile = 128
  /// 每边丢弃的 halo。感受野 ±14，取 8：有效吞吐 (128−16)/128 = 77%。
  static let halo = 8
  /// 相邻块起点的步长。
  static let stride = tile - 2 * halo
  /// 超过这个像素数不做（2× 目标位图 = 4 倍内存：4MP → 目标 8MP BGRA ≈ 32MB）。
  static let maxPixels = 4_000_000
  /// 一次任务结束后模型的空闲保留窗口：期间再点不必重新 load/compile。
  static let modelIdleSeconds: Duration = .seconds(90)
  /// 进度回调节奏（每 N 块一次）。
  static let progressStride = 4

  /// 能否超分：边长不小于 tile（否则块都放不下、也没有可超分的余量），且总像素不超上限。
  static func canUpscale(width: Int, height: Int) -> Bool {
    width >= tile && height >= tile && width * height <= maxPixels
  }

  /// 块起点序列：0 起步、步长 stride，最后一块 clamp 到 length − tile。
  /// 保证严格递增、每块都完整落在图内。
  static func tileStarts(length: Int) -> [Int] {
    precondition(length >= tile, "边长小于 tile：调用方必须先过 canUpscale")
    let last = length - tile
    var starts: [Int] = []
    var start = 0
    while true {
      starts.append(start)
      if start == last { break }
      start = min(start + stride, last)
    }
    return starts
  }

  /// 每块只信的核心区（源图像素坐标）：首块左边不留 halo（图像边界本身合法）、
  /// 末块右边同理；中间块两侧各留 halo。返回值恰好无缝且不重叠地铺满 [0, length)。
  static func tileCores(starts: [Int], length: Int) -> [Range<Int>] {
    var cores: [Range<Int>] = []
    var cursor = 0
    for (index, start) in starts.enumerated() {
      let isLast = (index == starts.count - 1)
      let upper = isLast ? length : start + tile - halo
      cores.append(cursor..<upper)
      cursor = upper
    }
    return cores
  }

  /// 块数（进度分母）。
  static func tileCount(width: Int, height: Int) -> Int {
    guard canUpscale(width: width, height: height) else { return 0 }
    return tileStarts(length: width).count * tileStarts(length: height).count
  }
}

/// 一块待切的位置（块起点，源图像素坐标）。
private struct TiebaSuperResolutionJob {
  let x: Int
  let y: Int
}

/// 分块 2× 超分。actor：模型与 tile 缓冲都在后台执行体上被串行使用。
actor TiebaSuperResolutionEngine {
  static let shared = TiebaSuperResolutionEngine()

  private var model: MLModel?
  private var idleReleaseTask: Task<Void, Never>?

  /// 2× 超分（渐进式）。
  /// - Parameter priority: 源图像素坐标下的"优先区"（当前可见视口）；命中它的块先算，
  ///   算完立刻回调一次快照，让用户先看到视口锐化，其余区域后台补齐。nil = 全部按行序。
  /// - Parameter onPartial: 中途快照 (image, done, total)：视口完成时与之后每约 1/3 剩余块回调。
  /// - Parameter progress: 进度 (done, total)：每 progressStride 块一次。
  /// - Returns: 最终 2× 图。抛出 = 失败（调用方保持原图不动）；Task 取消 → .cancelled。
  func upscale(
    _ source: CGImage,
    priority: CGRect?,
    onPartial: @Sendable (CGImage, Int, Int) -> Void,
    progress: @Sendable (Int, Int) -> Void
  ) async throws -> CGImage {
    let width = source.width
    let height = source.height
    guard TiebaSuperResolutionLimits.canUpscale(width: width, height: height) else {
      throw width * height > TiebaSuperResolutionLimits.maxPixels
        ? TiebaSuperResolutionError.tooManyPixels(width * height)
        : TiebaSuperResolutionError.unsupportedSize(width: width, height: height)
    }
    // 模型先就绪再动显示：加载失败时页面必须保持原图（不能先给一张"只是放大"的糊图）。
    let model = try loadedModel()

    let tile = TiebaSuperResolutionLimits.tile
    let xStarts = TiebaSuperResolutionLimits.tileStarts(length: width)
    let yStarts = TiebaSuperResolutionLimits.tileStarts(length: height)
    let xCores = TiebaSuperResolutionLimits.tileCores(starts: xStarts, length: width)
    let yCores = TiebaSuperResolutionLimits.tileCores(starts: yStarts, length: height)

    // 目标位图：唯一一次分配，之后所有块按整数偏移直接写内存。
    guard let destination = CGContext(
      data: nil,
      width: width * 2,
      height: height * 2,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    ), let destinationBase = destination.data else {
      throw TiebaSuperResolutionError.bitmapAllocationFailed
    }
    let destinationBytesPerRow = destination.bytesPerRow
    // 底图：源图一次 2× 放大（低质量插值，只给"还没处理的区域"垫底）。这样任何时刻的快照都是
    // 完整的一幅图，而不是"视口清晰、四周黑色"——渐进式刷新才有意义。
    destination.interpolationQuality = .low
    destination.draw(source, in: CGRect(x: 0, y: 0, width: width * 2, height: height * 2))

    // 块顺序：优先区（当前视口）内的块按行序先做，其余按行序补。
    var ordered: [TiebaSuperResolutionJob] = []
    ordered.reserveCapacity(xStarts.count * yStarts.count)
    for startY in yStarts {
      for startX in xStarts { ordered.append(TiebaSuperResolutionJob(x: startX, y: startY)) }
    }
    var viewportCount = 0
    if let priority, !priority.isNull, priority.width > 0, priority.height > 0 {
      let inViewport = ordered.filter { job in
        CGRect(x: job.x, y: job.y, width: tile, height: tile).intersects(priority)
      }
      let rest = ordered.filter { job in
        !CGRect(x: job.x, y: job.y, width: tile, height: tile).intersects(priority)
      }
      ordered = inViewport + rest
      viewportCount = inViewport.count
    }
    let total = ordered.count
    guard total > 0 else {
      throw TiebaSuperResolutionError.unsupportedSize(width: width, height: height)
    }
    // 快照节奏：视口完成时 1 张，之后剩余块再发 ~3 张（快照是整幅拷贝，不能每块都发）。
    let partialStride = max(max(total - viewportCount, 1) / 3, 1)

    guard let pool = Self.makePool(tile: tile), let tileBuffer = Self.makeBuffer(from: pool) else {
      throw TiebaSuperResolutionError.bitmapAllocationFailed
    }

    var done = 0
    for job in ordered {
      if Task.isCancelled { throw TiebaSuperResolutionError.cancelled }
      guard let columnIndex = xStarts.firstIndex(of: job.x),
            let rowIndex = yStarts.firstIndex(of: job.y) else {
        throw TiebaSuperResolutionError.predictionFailed
      }
      let coreX = xCores[columnIndex]
      let coreY = yCores[rowIndex]

      // ① 切块：起点已 clamp 在图内 ⇒ 永远是整块落在图内的 1:1 拷贝。
      //    CG 上下文的 y 轴与内存行序相反，故纵向偏移取 −(height − job.y − tile)。
      autoreleasepool {
        CVPixelBufferLockBaseAddress(tileBuffer, [])
        if let tileContext = Self.context(for: tileBuffer) {
          tileContext.setBlendMode(.copy)
          tileContext.interpolationQuality = .none
          tileContext.draw(source, in: CGRect(
            x: -CGFloat(job.x),
            y: -CGFloat(height - job.y - tile),
            width: CGFloat(width),
            height: CGFloat(height)
          ))
        }
        CVPixelBufferUnlockBaseAddress(tileBuffer, [])
      }

      // ② 推理（ANE，串行）
      let output: any MLFeatureProvider
      do {
        output = try Self.predict(model, tileBuffer)
      } catch {
        throw TiebaSuperResolutionError.predictionFailed
      }
      guard let outputBuffer = output.featureValue(for: "output_image")?.imageBufferValue else {
        throw TiebaSuperResolutionError.predictionFailed
      }

      // ③ 落图：只拷核心区（输出坐标 =（核心区源坐标 − 块起点）× 2，目标坐标 = 核心区源坐标 × 2），
      //    两边都是整数偏移，不做任何重采样。
      let outputLowX = (coreX.lowerBound - job.x) * 2
      let outputHighX = (coreX.upperBound - job.x) * 2
      let outputLowY = (coreY.lowerBound - job.y) * 2
      let outputHighY = (coreY.upperBound - job.y) * 2
      CVPixelBufferLockBaseAddress(outputBuffer, .readOnly)
      guard let outputBase = CVPixelBufferGetBaseAddress(outputBuffer) else {
        CVPixelBufferUnlockBaseAddress(outputBuffer, .readOnly)
        throw TiebaSuperResolutionError.predictionFailed
      }
      let outputBytesPerRow = CVPixelBufferGetBytesPerRow(outputBuffer)
      let rowBytes = (outputHighX - outputLowX) * 4
      for row in outputLowY..<outputHighY {
        memcpy(
          destinationBase + (2 * job.y + row) * destinationBytesPerRow + coreX.lowerBound * 8,
          outputBase + row * outputBytesPerRow + outputLowX * 4,
          rowBytes
        )
      }
      CVPixelBufferUnlockBaseAddress(outputBuffer, .readOnly)

      done += 1
      if done % TiebaSuperResolutionLimits.progressStride == 0 || done == total {
        progress(done, total)
      }
      // 渐进式快照：视口做完立刻发一张；之后每 partialStride 块一张；最后一张必发。
      let isViewportDone = viewportCount > 0 && done == viewportCount && done < total
      let isStrideHit = done > viewportCount && (done - viewportCount) % partialStride == 0
      if done == total || isViewportDone || (isStrideHit && done < total) {
        if let snapshot = destination.makeImage() {
          onPartial(snapshot, done, total)
        }
      }
    }

    guard let result = destination.makeImage() else {
      throw TiebaSuperResolutionError.bitmapAllocationFailed
    }
    scheduleIdleRelease()
    return result
  }

  // MARK: 模型生命周期（点击才加载、用完 90s 释放）

  private func loadedModel() throws -> MLModel {
    if let model { return model }
    let url: URL
    do {
      url = try TiebaSuperResolutionModelStore.compiledModelURL()
    } catch {
      throw TiebaSuperResolutionError.modelUnavailable(String(describing: error))
    }
    let configuration = MLModelConfiguration()
    configuration.computeUnits = .cpuAndNeuralEngine
    do {
      let loaded = try MLModel(contentsOf: url, configuration: configuration)
      model = loaded
      return loaded
    } catch {
      throw TiebaSuperResolutionError.modelUnavailable(String(describing: error))
    }
  }

  /// 一批任务结束后延迟释放：期间再点直接用现成实例（首载含映射与缓存读取，每张图重载会把
  /// 分块的收益吃掉）；90s 内没有新任务则置 nil，让 ARC 回收（ANE 侧缓存由系统按内存压力回收）。
  private func scheduleIdleRelease() {
    idleReleaseTask?.cancel()
    idleReleaseTask = Task { [weak self] in
      try? await Task.sleep(for: TiebaSuperResolutionLimits.modelIdleSeconds)
      guard !Task.isCancelled else { return }
      await self?.releaseModelIfIdle()
    }
  }

  private func releaseModelIfIdle() {
    model = nil
    idleReleaseTask = nil
  }

  // MARK: 缓冲 / 推理（静态，不碰 actor 状态）

  /// 非 async 的包装：确保选到 MLModel 的**同步** prediction（async 版会让出执行体）。
  private static func predict(_ model: MLModel, _ tileBuffer: CVPixelBuffer) throws -> any MLFeatureProvider {
    let provider = try MLDictionaryFeatureProvider(
      dictionary: ["input_image": MLFeatureValue(pixelBuffer: tileBuffer)]
    )
    return try model.prediction(from: provider)
  }

  /// 输入块缓冲池：IOSurface 后备（与 CoreML 内部缓冲同源，ANE 读起来少一次拷贝），
  /// 尺寸/格式固定 ⇒ 池里永远只会有这一种块，复用不重建。
  private static func makePool(tile: Int) -> CVPixelBufferPool? {
    let attributes: [CFString: Any] = [
      kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey: tile,
      kCVPixelBufferHeightKey: tile,
      kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
      kCVPixelBufferBytesPerRowAlignmentKey: 64,
    ]
    var pool: CVPixelBufferPool?
    guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess else {
      return nil
    }
    return pool
  }

  private static func makeBuffer(from pool: CVPixelBufferPool) -> CVPixelBuffer? {
    var buffer: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess else {
      return nil
    }
    return buffer
  }

  /// 只在调用方已 lock 的前提下使用（baseAddress 只在 lock 期间有效）。
  private static func context(for buffer: CVPixelBuffer) -> CGContext? {
    CGContext(
      data: CVPixelBufferGetBaseAddress(buffer),
      width: CVPixelBufferGetWidth(buffer),
      height: CVPixelBufferGetHeight(buffer),
      bitsPerComponent: 8,
      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    )
  }
}
