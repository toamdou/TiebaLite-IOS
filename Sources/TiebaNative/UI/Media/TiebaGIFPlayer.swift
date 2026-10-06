// TiebaGIFPlayer —— 用系统框架（ImageIO + CADisplayLink）实现的 GIF 播放器，用来**取代 Gifu**。
//
// 📚 这份代码的 UIKit 学习价值（见 docs/uikit-migration/24-Gifu替换.md）：
//   1. 「谁来合成帧」这件事可以完全交给系统：ImageIO 的 CGImageSourceCreateImageAtIndex 返回的是
//      **已按 disposal 合成好的整帧**，所以播放器不需要懂 GIF 的帧处置语义（那是 GIF 规范里最容易写错的部分）。
//      自己实现合成 = 几百行 + 一堆边界（disposal 0/1/2/3、透明索引色、局部调色板）。
//   2. 「播放」= 一个累加器 + 一个共享 CADisplayLink：不要用「按总时长算第几帧」的写法（变长帧会漂移）。
//   3. 「内存」= 按需解码 + 有界 NSCache + recycle() 真释放：滚动列表里最大的坑不是解码慢，是帧缓冲攒着不放。
//
// 改动/取舍（相对 Gifu）：
//   · 只留本仓真正用到的能力，不做 GIFAnimatable 那套「视图协议 + delegate + display(layer:)」间接层：
//     本仓的用法只有两种 —— 列表行（可能永远只显示首帧）和查看器（当前页播放）。直接给 view 赋值更直白。
//   · **帧时延与缩放几何逐行对齐 Gifu**（帧时延规则、constrained/filling 的取整方式），
//     这样替换后同一张 GIF 的播放节奏与帧尺寸不变（有模拟器逐帧比对，见文档）。
//   · display link 复用本仓唯一的 TiebaSharedDisplayLinkDriver（Core/TiebaDisplayLinkAnimator.swift）：
//     一个 feed 里有几十个 GIF，各自 new 一个 CADisplayLink 就是几十个 vsync 回调；
//     共享驱动器还会统一处理前后台切换。
//
// Swift 6：播放器整类 @MainActor（UIView 与 CADisplayLink 都是主线程物）；**解析与逐帧解码
// 全部在 TiebaGIFDecoder（actor）里做**，主线程只剩"把解好的 UIImage 贴到 imageView 上"。
// 没有任何 @preconcurrency / nonisolated(unsafe) / @unchecked Sendable（CGImageSource 不是
// Sendable，所以它被关在 actor 里，靠隔离而不是靠人工断言保证线程安全）。
//
// 为什么解码必须离开主线程（实测数字见 docs/uikit-migration/42-*）：
//   · 本仓真实帖子（p/11060036651，25 张动图 / 51MB）里 83 帧 2.83MB 的 GIF：
//     解析帧表 24~30ms、单帧解码+重采样 3.9ms（列表格）/ 14ms（查看器格）；
//   · 原来的写法把这两笔都放在主线程上：一屏 25 张同屏稳态 = 每秒 1.08s 的主线程解码
//     （>100% 占用），起播那一下还要一次性阻塞 ~857ms —— 表现就是"一堆 GIF 卡住/播不动"。

import Foundation
import UIKit
import ImageIO
import CoreGraphics

// MARK: - 数据源（纯解析，可单独验证）

/// GIF 的解析结果 + 按需解码。与 UI 无关，方便在自检/测试里直接比对帧序列。
struct TiebaGIFSource {
    /// 帧时延（秒）。已按下面的规则夹取，直接可用于播放。
    let delays: [Double]
    /// GIF 的循环次数：0 表示无限循环（kCGImagePropertyGIFLoopCount 的约定）。
    let loopCount: Int
    private let source: CGImageSource

    var frameCount: Int {
        return self.delays.count
    }

    /// 一帧都没有 / 不是 GIF → nil。
    init?(data: Data) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else {
            return nil
        }
        self.source = source

        var delays: [Double] = []
        delays.reserveCapacity(count)
        for index in 0 ..< count {
            delays.append(TiebaGIFSource.frameDelay(source: source, index: index))
        }
        self.delays = delays

        // 循环次数只在容器级属性里有（不在每帧属性里），所以要读第 0 帧的 GIF 字典顶层。
        self.loopCount = TiebaGIFSource.loopCount(source: source)
    }

    /// 解一帧（**系统已按 disposal 合成好**，见文件头第 1 条）。
    func frame(at index: Int) -> CGImage? {
        guard index >= 0, index < self.frameCount else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(self.source, index, nil)
    }

    /// 解码 + 按目标尺寸缩放（shouldResizeFrames 的语义）。
    /// 几何规则与 Gifu 的 CGSize.constrained(by:) / filling(_:) 逐行一致（见文件头取舍第 2 条）：
    /// 先按 round(aspectRatio * target.height) 试算宽度，超了就反过来按高度算 ——
    /// 这个"先宽后高/先高后宽"的顺序与直接算 min/max 缩放比在取整后可能差 1pt，
    /// 差 1pt 就会让同一张 GIF 在替换前后帧尺寸不同，所以照抄而非"优化"。
    func resizedFrame(at index: Int, targetSize: CGSize, contentMode: UIView.ContentMode) -> UIImage? {
        guard let cgImage = self.frame(at: index) else {
            return nil
        }
        let sourceSize = CGSize(width: cgImage.width, height: cgImage.height)
        let aspectRatio: CGFloat = sourceSize.height == 0 ? 1 : sourceSize.width / sourceSize.height

        let fittedSize: CGSize
        switch contentMode {
            case .scaleToFill:
                fittedSize = targetSize
            case .scaleAspectFill:
                let aspectWidth = round(aspectRatio * targetSize.height)
                let aspectHeight = round(targetSize.width / aspectRatio)
                fittedSize = aspectWidth > targetSize.width
                    ? CGSize(width: aspectWidth, height: targetSize.height)
                    : CGSize(width: targetSize.width, height: aspectHeight)
            default:
                // .scaleAspectFit / .center / .redraw … 统一按"装进目标框"处理。
                let aspectWidth = round(aspectRatio * targetSize.height)
                let aspectHeight = round(targetSize.width / aspectRatio)
                fittedSize = aspectWidth > targetSize.width
                    ? CGSize(width: targetSize.width, height: aspectHeight)
                    : CGSize(width: aspectWidth, height: targetSize.height)
        }

        if fittedSize.width < 1 || fittedSize.height < 1 {
            return UIImage(cgImage: cgImage)
        }
        // scale = 1：帧位图的像素尺寸就是我们想要的显示像素，交给 imageView 的 contentMode 去贴合。
        // 用 scale = 屏幕 scale 会让位图再放大 3 倍（内存 ×9），而 GIF 帧本来就不需要那么精细。
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: fittedSize, format: format)
        let image = renderer.image { _ in
            UIImage(cgImage: cgImage).draw(in: CGRect(origin: .zero, size: fittedSize))
        }
        return image
    }

    // MARK: 时延与循环（规则对齐 Gifu，理由写在各自注释里）

    /// 单帧时延。优先级：UnclampedDelayTime → DelayTime → 15fps 默认值；最后按浏览器规则夹取。
    private static func frameDelay(source: CGImageSource, index: Int) -> Double {
        var delay: Double?
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
           let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
            // 为什么优先 Unclamped：DelayTime 被系统按"最小 100ms 的显示下限"夹过，
            // 而 GIF 里的真实节奏在 Unclamped 里；用 DelayTime 会把 33ms 的帧播成 100ms（整段变慢）。
            if let unclamped = gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double, unclamped >= 0 {
                delay = unclamped
            } else if let clamped = gif[kCGImagePropertyGIFDelayTime] as? Double, clamped >= 0 {
                delay = clamped
            }
        }
        guard let delay, delay > 0 else {
            // 没有时延信息：按 15fps 估（Gifu 的 defaultFrameRate；也是 GIF 最常见的区间中值）。
            return 1.0 / 15.0
        }
        // 浏览器规则（也是 Gifu 的 capDuration）：**小于 20ms 的时延按 100ms 播**。
        // 不这样做会怎样：一大批 GIF 的时延字段是 0 或 0.01s，播放器会以 display link 的频率
        // 全速翻帧 —— CPU 与内存带宽全烧在动画上，而且肉眼只看到一片闪烁。
        // 这条规则来自"浏览器要保住 100ms 的最小可感知帧"的历史约定，不是拍脑袋。
        return delay < 0.02 - Double.ulpOfOne ? 0.1 : delay
    }

    /// 循环次数：0 = 无限。
    private static func loopCount(source: CGImageSource) -> Int {
        if let properties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any],
           let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any],
           let loop = gif[kCGImagePropertyGIFLoopCount] as? Int {
            return loop
        }
        // 缺省当无限循环：绝大多数 GIF 都不写这个键，而"只播一遍然后停住"在列表里观感是"坏了"。
        return 0
    }
}

// MARK: - 后台解码器

/// 帧表解析结果（全 Sendable：播放器只读，不在后台留任何引用）。
struct TiebaGIFMetadata: Sendable {
    /// 帧时延（秒），已按浏览器规则夹取（见 TiebaGIFSource.frameDelay）。
    let delays: [Double]
    /// 0 = 无限循环（GIF 约定）。
    let loopCount: Int

    var frameCount: Int {
        return self.delays.count
    }
}

/// 解码闸门：同时最多 `limit` 路后台解码（**全局单例**）。
///
/// 为什么必须有闸门（本机实测，8 核 M1 / 3 张真实 GIF 轮转成 25 个播放器、8s 实时模拟）：
///   路数 1 → 准时率 72.6%（tick 落后合计 704s）
///   路数 2 → 70.7%（539s）· 3 → 80.2%（118s）· 4 → 85.1%（21s）· 6/不限 → 85.9%（14ms，已到该模拟的
///   上界）。**解码是纯 CPU 活，并发低于必要值时会互相排队把动画拖慢。**
/// 为什么不用 TiebaFeedScrollGate.shared.limit（滚动中 1）：那条口径是给**整行位图烘制**
/// 定的（一次几十毫秒，且滚动期该给它让路）；GIF 单帧只有 ~4ms，一屏 25 张的稳态需求
/// ≈ 25 × 11fps × 4ms ≈ 1.1s CPU/s —— 压到 1 路时准时率就从 85% 掉到 73%。滚动期真正
/// 该让路的是烘制，不是 GIF 帧。
///
/// ⚠️ 闸门是**额度**不是排队上限：拿不到额度就在 FIFO 链上等，解完一帧立刻把额度交给
/// 链首 —— 不存在"排在后面的永远轮不上"（那需要额度被长期占住，而这里每帧都还）。
actor TiebaGIFDecodeGate {
    static let shared = TiebaGIFDecodeGate()

    /// 额度 = min(4, max(2, 核数 - 2))：6 核 iPhone → 4，4 核老机 → 2。
    /// 上限取 4 是因为上面那组实测在 4~6 路之间已经到顶，再多只是抢内存带宽。
    private static let limit = min(4, max(2, ProcessInfo.processInfo.activeProcessorCount - 2))

    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// 取一个额度（满了就在链尾排队）。
    func acquire() async {
        if self.active < Self.limit {
            self.active += 1
            return
        }
        await withCheckedContinuation { continuation in
            self.waiters.append(continuation)
        }
        // 被唤醒时额度已经算在自己头上（见 release 的直接转让）。
    }

    /// 还一个额度：有等待者就**直接转让**（不减 active，避免"还了又被新来者抢走"）。
    func release() {
        if self.waiters.isEmpty {
            self.active = max(0, self.active - 1)
        } else {
            self.waiters.removeFirst().resume()
        }
    }
}

/// 后台帧解码器：**解析（帧表/时延）与逐帧解码重采样都在这里**，主 actor 只负责上屏。
///
/// 为什么是 actor，而不是把 CGImageSource 塞进一个 @unchecked Sendable 盒子：
/// 实测 `CGImageSource` 在本 SDK 里**不是 Sendable**（跨隔离域传递会被编译器拒绝），
/// 而 actor 的隔离状态任何时刻都不跨域；返回的 UIImage 是 Sendable（SDK 已声明），
/// 跨回主 actor 合法。于是本文件继续保持"零 @preconcurrency / 零 nonisolated(unsafe) /
/// 零 @unchecked Sendable"。
///
/// 为什么一个播放器一个 actor，而不是全局一个：全局 actor = 全局串行，一屏十几张动图会
/// 排成一条队（那正是"排在后面的永远轮不上"的病根）；每个播放器一个 actor，解码并发由
/// 协作线程池兜底（≤ 核数），既不 N 张图各开一条线程，也不会互相饿死。每个播放器同时
/// 最多排 3 帧、单帧实测 4~14ms（见 42-*），一屏 25 张的稳态占用远低于池子容量。
///
/// 为什么不能"每帧新建一个 CGImageSource 再解"（那样就不需要 actor 了）：GIF 的第 N 帧
/// 要么复用同一个 source（ImageIO 内部按帧序推进，热帧 0.07ms），要么从 0 解到 N
/// （实测 19~28ms）—— 帧号越大越贵，播放器每帧都付不起。
actor TiebaGIFDecoder {
    private let data: Data
    private let targetSize: CGSize
    private let contentMode: UIView.ContentMode
    /// 懒建：CGImageSource 在这一层（后台）创建，此后只在 actor 上访问。
    private var source: TiebaGIFSource?

    init(data: Data, targetSize: CGSize, contentMode: UIView.ContentMode) {
        self.data = data
        self.targetSize = targetSize
        self.contentMode = contentMode
    }

    /// 帧表解析（原先是 play() 里同步跑在主线程上的那 24~30ms）。
    func metadata() -> TiebaGIFMetadata? {
        guard let source = self.sourceInstance() else { return nil }
        return TiebaGIFMetadata(delays: source.delays, loopCount: source.loopCount)
    }

    /// 解第 index 帧：目标尺寸有效时顺带重采样（几何规则与改动前逐行一致，见 resizedFrame）。
    /// 解码段（同步、CPU 密集）用全局闸门圈起来，避免 N 张同屏时互相抢内存带宽。
    /// （`async` 是必须的：actor 内部的函数要 await 闸门就得显式声明 async。）
    func frame(at index: Int) async -> UIImage? {
        guard let source = self.sourceInstance() else { return nil }
        await TiebaGIFDecodeGate.shared.acquire()
        let image = self.decodeImage(at: index, from: source)
        await TiebaGIFDecodeGate.shared.release()
        return image
    }

    /// 同步解码（actor 隔离：CGImageSource 只在这里被碰）。
    private func decodeImage(at index: Int, from source: TiebaGIFSource) -> UIImage? {
        if self.targetSize.width > 1, self.targetSize.height > 1 {
            return source.resizedFrame(at: index, targetSize: self.targetSize, contentMode: self.contentMode)
        }
        guard let cgImage = source.frame(at: index) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private func sourceInstance() -> TiebaGIFSource? {
        if let source {
            return source
        }
        let made = TiebaGIFSource(data: self.data)
        self.source = made
        return made
    }
}

// MARK: - 播放器

@MainActor
final class TiebaGIFPlayer {
    /// 帧缓存。用 NSCache 而不是字典：内存压力下系统会自己丢对象（我们不用手写 LRU），
    /// 且它是线程安全的（后台解好的帧仍由主 actor 存进来，缓存本身不参与隔离假设）。
    /// countLimit 就是"缓冲窗" —— 见 play(...) 的参数说明。
    private let frames = NSCache<NSNumber, UIImage>()

    /// 后台解码器（解析 + 逐帧解码都在它那里）。
    private var decoder: TiebaGIFDecoder?
    private var link: (any TiebaSharedDisplayLinkDriverLink)?
    private weak var imageView: UIImageView?

    private var targetSize: CGSize = .zero
    private var contentMode: UIView.ContentMode = .scaleAspectFit
    private var shouldResizeFrames = false

    /// 后台解析回来的帧表。三者同源：一起就位、一起清空（tick 用 delays.count 判就位）。
    private var framesTotal = 0
    private var delays: [Double] = []
    private var loopCount = 0

    private var frameIndex = 0
    /// 时间累加器：跨 display link 帧累加，凑够当前帧的时延才翻页（理由见 tick(duration:)）。
    private var accumulatedTime: Double = 0
    private var completedLoops = 0

    /// 在途解码的帧号（同一帧不排两次队）。
    private var inFlightFrames: Set<Int> = []
    /// 帧缓存代次：recycle() / 离屏清空 / 内存告警清空都 +1，在途解码回来对不上就丢弃。
    private var frameGeneration = 0
    /// 离屏清空只做一次（回到屏幕上再置回 false）。
    private var didPurgeWhileOffscreen = false

    /// GIF 字节魔数（"GIF8"，与 TiebaNuke.sniffGIFMagic 同一口径）。
    private static let gifMagic: [UInt8] = [0x47, 0x49, 0x46, 0x38]

    var isPlaying: Bool {
        guard let link else { return false }
        return !link.isPaused
    }

    var frameCount: Int {
        return self.framesTotal
    }

    // MARK: 存活登记（内存告警统一清帧缓存）

    private struct WeakBox {
        weak var player: TiebaGIFPlayer?
    }

    /// 存活播放器（弱引用登记）。为什么要这份登记：帧缓存是每个播放器自己的 NSCache，
    /// 而内存告警处理（TiebaAppBootstrap.installMemoryWarningObserver）原来只清 Nuke 与
    /// 文字画布 —— 一屏十几张动图时，帧位图（查看器单帧 603KB × 8 帧窗）正是那一刻最大
    /// 的一块可回收内存。登记与注销同寿命于视图（一图一个播放器），无高频写入。
    private static var livePlayers: [WeakBox] = []

    init() {
        Self.livePlayers.removeAll { $0.player == nil }
        Self.livePlayers.append(WeakBox(player: self))
    }

    /// 内存告警：所有存活播放器释放帧缓存（不动帧表与 CGImageSource）。
    ///
    /// 不整份 recycle()：在屏在播的播放器清完帧缓存后，下一拍会按需在**后台**重解
    /// （观感是"跳了一帧"，不是"停了"）。**离屏**的播放器（视图已不在宿主窗口里）
    /// 则整份 recycle：一帖 25 张动图的压缩字节合计 51MB（实测），比帧位图更值钱；
    /// 它们回到屏幕时会走正常加载路径重建（reuse → apply → 探测结果命中会话缓存 →
    /// Nuke 缓存命中 → play）。
    static func purgeFrameCachesForMemoryWarning() {
        for box in livePlayers {
            guard let player = box.player else { continue }
            if player.imageView?.window == nil {
                player.recycle()
            } else {
                player.purgeFrameCache()
            }
        }
    }

    /// 释放帧缓存（不动 CGImageSource / 帧表 / display link）：离屏与内存告警共用。
    func purgeFrameCache() {
        self.frames.removeAllObjects()
        self.cachedFrameCountStorage = 0
        self.inFlightFrames.removeAll(keepingCapacity: true)
        self.frameGeneration &+= 1
    }

    /// 我们自己数的"已放入缓存的帧数"（自检/测试用：recycle() 之后必须是 0）。
    /// 为什么不用 NSCache.count：NSCache 没有这个 API（它会在内存压力下自行逐出对象，
    /// 因此"当前到底有几帧"对调用方本来就是不可知的）。这里要的是一个**可断言的上界**：
    /// 放过几帧就加几，recycle() 归零 —— 用来证明"真释放"而不是"以为释放了"。
    private var cachedFrameCountStorage = 0

    var cachedFrameCount: Int {
        return self.cachedFrameCountStorage
    }

    // MARK: 生命周期

    /// 开始播放（或换一张图重新开始）。
    ///
    /// - parameter frameBufferSize: 缓冲窗 = 最多同时留几帧解码后的位图。
    ///   这是**峰值内存的唯一旋钮**：单帧 W×H×4 字节，30 帧 500×500 的 GIF 全留就是 30MB；
    ///   留 8 帧 → 上限 8MB 且滚动时不会随"经过的 GIF 数量"累积。
    ///   注意它只是上限：真实占用取决于"一帧的显示时间里能解几帧"。
    /// - returns: 数据是不是 GIF（字节魔数 "GIF8"）。false = 调用方要恢复"抑制 image 回调"
    ///   之类的旁路开关 —— 播放没起来却一直抑制着，会让后续正常的图片赋值不再触发布局，
    ///   是那种"很久以后才发现"的 bug。注意这里**不再**顺手做 CGImageSource 解析：
    ///   解析与逐帧解码都在 TiebaGIFDecoder（后台），解析失败就不起表（屏幕上仍是调用方
    ///   贴好的静态首帧，与"判否"的观感一致）。
    @discardableResult
    func play(
        data: Data,
        into imageView: UIImageView,
        targetSize: CGSize,
        contentMode: UIView.ContentMode,
        frameBufferSize: Int = 8,
        /// 调用方已经解码好的首帧（查看器的 `container.image`）。传它就**不必再解一遍第 0 帧**
        /// —— 大 GIF 的首帧解码+重采样实测 4~45ms（42-*），全是白做。
        firstFrame: UIImage? = nil
    ) -> Bool {
        self.recycle()

        // 有效性判定只花一次 memcmp：GIF 的头 4 字节是 "GIF8"。
        // 为什么不在这里 CGImageSourceCreateWithData + GetCount 判（改动前的写法）：
        // 实测这两个调用要 5~7ms（83 帧 / 2.83MB 的真实 GIF 要扫完整张帧表），一屏 25 张
        // 就是一百多 ms 白卡在主线程上 —— 而这只是"值不值得起播"的判断。
        guard data.starts(with: TiebaGIFPlayer.gifMagic) else {
            return false
        }

        let decoder = TiebaGIFDecoder(data: data, targetSize: targetSize, contentMode: contentMode)
        self.decoder = decoder
        self.imageView = imageView
        self.targetSize = targetSize
        self.contentMode = contentMode
        // shouldResizeFrames 的语义（保留 Gifu 的名字）：目标尺寸有效才缩放。
        // 无效尺寸（还没布局）时直接给原帧 —— 否则会把帧缩成 0×0 给出一张空图。
        self.shouldResizeFrames = targetSize.width > 1 && targetSize.height > 1
        self.frames.countLimit = max(1, frameBufferSize)
        self.frameIndex = 0
        self.accumulatedTime = 0
        self.completedLoops = 0
        self.framesTotal = 0
        self.delays = []
        self.loopCount = 0
        self.didPurgeWhileOffscreen = false

        // 先同步上首帧：调用方传进来的 imageView 可能还是空白的，
        // 等第一个 display link 回调（最多 16ms）再出图会闪一下白。
        if let firstFrame {
            // [修复 R3-3] 调用方（查看器/列表）刚刚把解码好的首帧上屏了；这里直接把它当第 0 帧缓存起来，
            // 省掉一次完整解码。**不覆盖 imageView.image**（屏幕上已经是这一帧，覆盖只会造成同帧重绘）。
            self.frames.setObject(firstFrame, forKey: NSNumber(value: 0))
            self.cachedFrameCountStorage += 1
            if imageView.image == nil {
                imageView.image = firstFrame
            }
        }

        // 帧表在后台解析；解析完再决定起不起表（单帧 GIF 不起）。
        Task { [weak self] in
            guard let metadata = await decoder.metadata() else { return }
            // 换图 / recycle / 内存告警之后对不上身份 → 结果作废（不是"静默丢"，是明确的代次判定）。
            guard let self, self.decoder === decoder else { return }
            self.framesTotal = metadata.frameCount
            self.delays = metadata.delays
            self.loopCount = metadata.loopCount
            guard metadata.frameCount > 1 else {
                // 单帧 GIF：没有动画可播（屏幕上已是调用方贴好的那一帧），不要白开一条表。
                return
            }
            // 起播前先把当前帧与下一帧排进后台队列：第一拍就有帧可上，不用等一次解码。
            self.requestFrame(at: 0)
            self.requestFrame(at: 1)
            self.startLink()
        }
        return true
    }

    /// 共享 display link：回调参数是"这一拍的实际时长"（秒），正好喂给累加器。
    /// 用 60fps 请求：GIF 常见 15~24fps，低于 60 的刷新率会让短时延帧（20~33ms）被量化到 33ms 以上。
    private func startLink() {
        guard self.link == nil else { return }
        self.link = TiebaSharedDisplayLinkDriver.shared.add(framesPerSecond: .fps(60)) { [weak self] duration in
            self?.tick(duration: Double(duration))
        }
    }

    /// 停止播放但**保留当前帧**（对齐 Gifu 的 stopAnimatingGIF）。
    /// 用途：cell 划出屏幕/查看器切到别的页时，图还在，只是不动了。
    func stop() {
        self.link?.invalidate()
        self.link = nil
    }

    /// 停止 + **真正释放全部帧缓存**。滚动复用、换图、页面销毁都必须走它。
    ///
    /// 为什么必须单独有这个 API（这是 Gifu 踩过的坑，本仓 TiebaFeedRowView 的注释里也记着）：
    /// Gifu 的 stopAnimatingGIF() 只是把 CADisplayLink 暂停，FrameStore 里的帧位图**一个都没放**。
    /// 结果是"滚动一遍 feed，沿途每个 GIF 的整窗帧缓冲都留在内存里"，几十张动图就是几百 MB。
    /// 这里把三样东西都清掉才算真释放：
    ///   ① NSCache（位图本体）② CGImageSource（还握着压缩后的原始字节）③ display link（停表，不再持有 self）。
    func recycle() {
        self.stop()
        self.frames.removeAllObjects()
        self.cachedFrameCountStorage = 0
        self.decoder = nil
        self.imageView = nil
        self.framesTotal = 0
        self.delays = []
        self.loopCount = 0
        self.inFlightFrames.removeAll(keepingCapacity: true)
        // 在途解码回来时对不上代次 → 直接丢弃（它占的 NSCache 键也已经不算数了）。
        self.frameGeneration &+= 1
        self.didPurgeWhileOffscreen = false
        self.frameIndex = 0
        self.accumulatedTime = 0
        self.completedLoops = 0
    }

    isolated deinit {
        // [移植] Swift 6：link 是 MainActor 隔离的非 Sendable 句柄，nonisolated deinit 读不到，
        // 用 isolated deinit（SE-0371，本仓工具链支持）让 deinit 跑在主 actor 上。
        self.link?.invalidate()
    }

    // MARK: 推进

    /// 每 display link 一拍调一次：把这一拍的真实时长累加进累加器，凑够才翻帧。
    ///
    /// 为什么用累加器而不是「按已播时间除以总时长算第几帧」：
    /// GIF 每帧时延可以完全不同（常见 0.02 / 0.5 / 1.0 混排）。用总时长比例算索引，
    /// 会让长帧被"抢"给后面的短帧，表现是**节奏整体漂移、关键时刻跳帧**；
    /// 累加器是逐帧结算，误差不累积。
    private func tick(duration: Double) {
        // ① 离屏（滚出可视区 / 进了复用池 / 还没上屏的预取单元格）：停解帧并**真释放帧缓存**。
        //    表不停：这一拍就是"回到屏幕上"的检测点，代价只是一次坐标换算。
        //    为什么不用 stop() 或 link.isPaused：那样回到屏幕时没有任何人会把表重新装上
        //    （cell 只会 prepareForReuse，重复上屏时 apply() 因同模型早退、不再走 layoutImages），
        //    表现就是"滚回来那张 GIF 不动了"。
        if !self.isOnScreen {
            self.purgeFramesWhileOffscreen()
            return
        }
        self.didPurgeWhileOffscreen = false

        guard self.frameCount > 1, self.delays.count == self.frameCount else {
            return
        }
        self.accumulatedTime += duration

        var didAdvance = false
        // while 而不是 if：一拍照不上两帧以上时（后台回来、卡顿），一次性把欠的帧补上，
        // 否则动画会"变慢"而不是"追上"。
        while self.accumulatedTime >= self.delays[self.frameIndex] {
            self.accumulatedTime -= self.delays[self.frameIndex]
            self.frameIndex += 1
            didAdvance = true
            if self.frameIndex >= self.frameCount {
                self.frameIndex = 0
                self.completedLoops += 1
                // loopCount == 0 是无限循环（GIF 约定）。有限次数播完就停住并保留最后一帧。
                if self.loopCount > 0 && self.completedLoops >= self.loopCount {
                    self.stop()
                    break
                }
            }
        }

        guard didAdvance else {
            return
        }
        self.presentFrame(at: self.frameIndex)
    }

    /// 上屏第 index 帧。主线程**只做两件事**：命中缓存就贴图；没命中就交给后台解，
    /// 并保持当前帧（不阻塞、不闪白）。帧晚到的代价是"掉一帧"，不是"卡住整条时间线"。
    private func presentFrame(at index: Int) {
        if let cached = self.frames.object(forKey: NSNumber(value: index)) {
            self.imageView?.image = cached
        }
        // 预解窗口 = 当前帧 + 后两帧。不是越大越好：每多一帧就多一份后台排队
        //（25 张同屏时排队长度 = 张数 × 窗口），而 GIF 帧本来就按播放顺序到达。
        for offset in 0 ..< min(3, self.frameCount) {
            self.requestFrame(at: (index + offset) % self.frameCount)
        }
    }

    /// 排一次后台解码（同一帧不重复排队；已缓存的直接跳过）。
    private func requestFrame(at index: Int) {
        guard let decoder, index >= 0, index < self.frameCount else {
            return
        }
        let key = NSNumber(value: index)
        guard self.frames.object(forKey: key) == nil,
              self.inFlightFrames.insert(index).inserted
        else {
            return
        }
        let generation = self.frameGeneration
        Task { [weak self] in
            let image = await decoder.frame(at: index)
            guard let self, self.frameGeneration == generation else {
                // 期间 recycle()/离屏清空/内存告警清空过 → 结果作废（inFlight 也已一并清掉）。
                return
            }
            self.inFlightFrames.remove(index)
            guard self.decoder === decoder, let image else {
                return
            }
            self.frames.setObject(image, forKey: key)
            self.cachedFrameCountStorage += 1
            // 解好的正好是该显示的那一帧（期间可能已翻页）→ 立刻上屏，不必等下一拍。
            if self.frameIndex == index, self.isOnScreen {
                self.imageView?.image = image
            }
        }
    }

    /// 视图是否还在屏幕上（判定实现见 UIView.tiebaIsVisibleInWindow）。
    private var isOnScreen: Bool {
        return self.imageView?.tiebaIsVisibleInWindow == true
    }

    /// 离屏清空（只做一次；回到屏幕由 tick 复位）。
    private func purgeFramesWhileOffscreen() {
        guard !self.didPurgeWhileOffscreen else {
            return
        }
        self.didPurgeWhileOffscreen = true
        self.accumulatedTime = 0
        self.purgeFrameCache()
    }
}

// MARK: - 视图宿主（Gifu 的 GIFImageView 替代品）

/// 一个自带播放器的 UIImageView。存在的意义只有一个：**让"哪个播放器对应哪个视图"这件事
/// 由类型保证**，调用方不必自己维护一对并行数组/字典（列表行里那种"视图与播放器错位"的 bug 极难查）。
final class TiebaGIFImageView: UIImageView {
    let gifPlayer = TiebaGIFPlayer()

    /// 复用/换图时调它：停表 + 释放帧缓存 + 清空当前图（对齐 Gifu 的 prepareForReuse 用法）。
    func prepareForGIFReuse() {
        self.gifPlayer.recycle()
        self.image = nil
    }
}

extension UIView {
    /// 视图是否还在屏幕上（与宿主窗口求交）。
    ///
    /// 为什么不用 `window != nil`：滚出可视区的 cell 仍在窗口里（只是 frame 在可视区外），
    /// 而预取趟里建出来、还没上屏的 cell 也照样在窗口里 —— 只有求交能同时覆盖这两种。
    /// 尺寸还没布局（≤1pt）时按"在屏"处理：那种时刻的播放/取图请求本就不该被离屏逻辑吃掉。
    ///
    /// 两个消费方：TiebaGIFPlayer（离屏停解帧 + 放帧缓存）与 tiebaGIFRequestPriority
    ///（离屏的动图档请求降一档优先级，见 TiebaPostRowInline）。
    var tiebaIsVisibleInWindow: Bool {
        guard !self.isHidden else { return false }
        guard self.bounds.width > 1, self.bounds.height > 1 else { return true }
        guard let window = self.window else { return false }
        return self.convert(self.bounds, to: window).intersects(window.bounds)
    }
}
