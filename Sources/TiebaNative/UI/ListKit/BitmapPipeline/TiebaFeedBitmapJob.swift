// ============================================================
// TiebaLite — 异步位图管线 · 跨域载荷（Job / Key / Result / 代次）
//
// 对应 上游 ASDK 的 displayBlock 载荷 + _displaySentinel（_ASDisplayLayer.mm:108-120、
// ASDisplayNode+AsyncDisplay.mm:341-351）。设计依据：
//   docs/uikit-migration/07-ObjC++转Swift可行性.md §3.2 / §5.2 / §5.3
//
// 并发三条铁律（本文件是第 ①③ 条）：
//   ① 跨域载荷 = 不可变 struct + @unchecked Sendable（论据写在每个类型上）
//   ③ 取消代次 = Atomic<UInt64>（唯一需要的原子量，它本身 Sendable，不需要 @unchecked）
//
// 本文件不依赖 TiebaNative 的任何其他类型：只吃 UIKit 的值类型，
// 因此可与 BitmapPipeline/ 其余文件一起独立 typecheck（见目录内交付说明）。
// ============================================================

import Synchronization
import UIKit

// MARK: - 取消代次

/// 单调递增的取消代次。**唯一需要跨线程的共享状态**，故只有这一个原子量。
///
/// 为什么不用 actor / 锁：写入方在**主线程**（画布的 update / clear），读取方在
/// 后台烘制线程（分段取消检查点），语义上就是个计数器；Atomic 的 relaxed 读写
/// 足够（不需要内存序保证 —— 位图数据本身靠闭包捕获传递，不经过这个量）。
///
/// epoch **0 保留给「预取」**：预取 Job 用 probe 恒返回 0，与 job.epoch = 0 永远相等，
/// 于是它的取消判据恒为假（= ASDK 里同步绘制路径「不支持取消」的等价物，
/// ASDisplayNode+AsyncDisplay.mm:347-351）。画布用的代次从 1 起。
public final class TiebaFeedBitmapEpoch: Sendable {
  private let counter = Atomic<UInt64>(0)

  public init() {}

  /// 自增并返回新代次（画布每次 update / clear 调一次 → 在途结果全部作废）。
  @discardableResult
  public func next() -> UInt64 {
    counter.wrappingAdd(1, ordering: .relaxed).newValue
  }

  /// 当前代次（后台线程读，用于分段取消检查）。
  public func probe() -> UInt64 {
    counter.load(ordering: .relaxed)
  }
}

// MARK: - 缓存键

/// 位图缓存键 = **所有会影响像素的输入的精确身份**。
///
/// 与旧实现（TiebaFeedRowView.swift:749-760 的 Entry + :862-885 逐字段比对）逐一对应，
/// 只是把「逐字段线性扫」换成 Hashable 键：
///   model（弱引用身份）→ ObjectIdentifier
///   size / scale / style / palette → 同名字段
///
/// ⚠️ R1（报告 §6）：TiebaFeedRowPalette 是 Equatable **不是 Hashable**，且
/// UIColor.hash 对动态色只反映「动态色」这一身份（浅/深两档会撞档）。所以这里存的是
/// paletteFingerprint（混 cgColor 分量，见 TiebaFeedRowPalette+BitmapKey.swift），
/// 不是 UIColor。
///
/// 不带 epoch：代次只用于「结果要不要收」，不影响像素身份（同键必然同像素）。
public struct TiebaFeedBitmapKey: Hashable, Sendable {
  /// 模型实例身份（模型不可变，见 TiebaRowMetrics.swift:58）。
  public let model: ObjectIdentifier
  public let width: CGFloat
  public let height: CGFloat
  public let scale: CGFloat
  /// UIUserInterfaceStyle.rawValue：深浅档决定动态色的解析结果，
  /// 也决定位图里烘进去的字形颜色，必须进键（旧 Entry.style 同义）。
  public let styleRaw: Int
  /// 色板指纹（不是 UIColor.hash，见类型注释与 R1）。
  public let paletteFingerprint: Int

  public init(
    model: ObjectIdentifier,
    size: CGSize,
    scale: CGFloat,
    styleRaw: Int,
    paletteFingerprint: Int
  ) {
    self.model = model
    self.width = size.width
    self.height = size.height
    self.scale = scale
    self.styleRaw = styleRaw
    self.paletteFingerprint = paletteFingerprint
  }

  public var size: CGSize { CGSize(width: width, height: height) }
}

// MARK: - 跨域载荷

/// 模型身份箱：完成回调要把模型交回 Store（Store 只持弱引用，见 TiebaFeedBitmapStore）。
///
/// 为什么要一个箱子：@Sendable 闭包里不能捕获 AnyObject（非 Sendable）。
/// 箱子里装的 TiebaFeedRowModel 本身是不可变的 @unchecked Sendable
/// （TiebaRowMetrics.swift:58），这里只是把「借用一次」这件事显式声明出来；
/// 箱子的生命周期 = 一次完成回调（毫秒级），不会把已被整页 LRU 淘汰的模型钉住。
public struct TiebaFeedBitmapModelToken: @unchecked Sendable {
  public let model: AnyObject

  public init(_ model: AnyObject) {
    self.model = model
  }
}

/// 一次烘制的完整输入。**构造后不可变**（字段全 let，数组为值类型）——
/// 这是它能是 @unchecked Sendable 的唯一论据。
///
/// NSAttributedString / UIFont 都是不可变对象，Core Text 对同一实例并发只读不共享
/// 可变状态（ASDK 十年来就是这么做的：ASDisplayNode+AsyncDisplay.mm:230-250
/// 在后台队列上跑同一批绘制原语）。
public struct TiebaFeedBitmapJob: @unchecked Sendable {
  /// 一段要画的文字 + 绘制矩形（画布坐标）。
  public struct Run: @unchecked Sendable {
    public let attributed: NSAttributedString
    public let frame: CGRect
    /// **阶段 0**：测量期预算好的自然高，用来消掉绘制期的第二遍排版。
    /// nil = 还没接上（此时绘制期回落「有界量高」= 现状，多一趟 CoreText 排版）。
    /// 精确改动方案见 TiebaFeedRowView.swift 里 Run 的注释与交付说明。
    public let naturalHeight: CGFloat?

    public init(attributed: NSAttributedString, frame: CGRect, naturalHeight: CGFloat? = nil) {
      self.attributed = attributed
      self.frame = frame
      self.naturalHeight = naturalHeight
    }
  }

  public let key: TiebaFeedBitmapKey
  public let runs: [Run]
  public let size: CGSize
  public let scale: CGFloat
  /// 位图是否不透明。卡内文字画布是透明的（圆角/引用卡底在下面），恒 false。
  public let opaque: Bool
  /// 取消代次：由画布在**主线程**单调递增后写进来，结果原样带回，主线程比对。
  public let epoch: UInt64

  public init(
    key: TiebaFeedBitmapKey,
    runs: [Run],
    size: CGSize,
    scale: CGFloat,
    opaque: Bool,
    epoch: UInt64
  ) {
    self.key = key
    self.runs = runs
    self.size = size
    self.scale = scale
    self.opaque = opaque
    self.epoch = epoch
  }

  /// 后备存储字节数（与原 TiebaFeedRowView.swift:842 逐字一致）。
  public var byteCount: Int {
    Int(size.width * scale) * Int(size.height * scale) * 4
  }
}

// MARK: - 结果

/// 后台烘制结果。CGImage 在 SDK 里已是 Sendable（CoreGraphics 的 CF 类型），
/// 所以这个 struct 不需要 @unchecked。
public struct TiebaFeedBitmapResult: Sendable {
  public let key: TiebaFeedBitmapKey
  /// 提交这份 Job 时画布的代次（原样带回，主线程比对）。
  public let epoch: UInt64
  public let image: CGImage
  public let bytes: Int

  public init(key: TiebaFeedBitmapKey, epoch: UInt64, image: CGImage, bytes: Int) {
    self.key = key
    self.epoch = epoch
    self.image = image
    self.bytes = bytes
  }
}
