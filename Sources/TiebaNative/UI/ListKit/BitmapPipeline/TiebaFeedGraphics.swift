// TiebaLite — 异步位图管线 · 图形（复刻 ASGraphicsContext.mm 的三个要点）
//
// 依据：docs/uikit-migration/07-ObjC++转Swift可行性.md §3.5
// 上游：submodules/AsyncDisplayKit/Source/ASGraphicsContext.mm（130 行，Tier C 纯 ObjC）
//
// 三个要点，缺一不可：
//   1. 格式池化        ASGraphicsContext.mm:47-61（dispatch_once 两个静态 format）
//   2. 提交前可取消    ASGraphicsContext.mm:95-109（runDrawingActions 而非 image{}）
//   3. trait 注入      ASGraphicsContext.mm:100-103（performAsCurrent）
//
// 要点 3 是本次改造最容易踩、最难查的坑：后台线程的 UITraitCollection.current 是
// 默认档（浅色），不注入时 .label / .secondaryLabel / UIColor { traits in ... }
// 全按浅色解析 —— 深色模式下**后台烘出来的那几行文字是黑的**（滚回去命中缓存又是对的）。
//
// 本文件不依赖 TiebaNative 的其他类型（只吃 Job 值类型 + UIKit）。

import UIKit

// MARK: - 外观档快照（跨域载荷）

/// UITraitCollection 的跨域箱。
///
/// 为什么可以 @unchecked：UITraitCollection 没有任何可变 API（Apple 文档明确它是
/// 值语义对象），只读跨线程与 ASDK 十年在后台队列上读 traitCollection 的做法一致
/// （ASDisplayNode+AsyncDisplay.mm 全程把 ASPrimitiveTraitCollection 传到后台绘制块）。
/// 这里不做拷贝也不改写，只用于 performAsCurrent 注入。
public struct TiebaFeedTraitSnapshot: @unchecked Sendable {
  public let traits: UITraitCollection

  public init(_ traits: UITraitCollection) {
    self.traits = traits
  }
}

// MARK: - 图形

public enum TiebaFeedGraphics {
  /// R3 闸门（报告 §6）：true = preferred()，宽色域 P3，与屏幕一致但与旧位图有色差
  ///（ASGraphicsContext.mm:51-57 用的就是 preferredFormat）；false = defaultFormat（sRGB），
  /// 与旧实现的 UIGraphicsImageRendererFormat() 逐像素一致。
  /// 阶段 1 若要切 preferred 应单独一个 commit + 前后截图对比。
  public static let usePreferredColorSpace = false

  /// 格式池（要点 1）。dispatch_once 语义由 Swift 的 static let 保证（swift_once）。
  ///
  /// @unchecked 论据：两个 format 在闭包里构造完就**再不改动**（改 scale 的场景走
  /// format(opaque:scale:) 的新建分支），只被并发只读 —— 与 ASGraphicsContext.mm:47-61
  /// 的静态 format 完全同构。
  private struct FormatPool: @unchecked Sendable {
    let translucent: UIGraphicsImageRendererFormat
    let opaque: UIGraphicsImageRendererFormat
  }

  private static let pool: FormatPool = {
    func make(opaque: Bool) -> UIGraphicsImageRendererFormat {
      let format = usePreferredColorSpace
        ? UIGraphicsImageRendererFormat.preferred()
        : UIGraphicsImageRendererFormat()
      format.opaque = opaque
      return format
    }
    return FormatPool(translucent: make(opaque: false), opaque: make(opaque: true))
  }()

  /// 取一份可直接交给 renderer 的 format。
  ///
  /// scale 与池化档一致时**直接复用共享实例**（只读，安全）；不一致才新建一份 ——
  /// 决不去改共享实例的 scale，否则就是数据竞争。这条分支与
  /// ASGraphicsContext.mm:82-93 一一对应。
  private static func format(opaque: Bool, scale: CGFloat) -> UIGraphicsImageRendererFormat {
    let pooled = opaque ? pool.opaque : pool.translucent
    if scale == pooled.scale { return pooled }
    let fresh = usePreferredColorSpace
      ? UIGraphicsImageRendererFormat.preferred()
      : UIGraphicsImageRendererFormat()
    fresh.opaque = opaque
    fresh.scale = max(scale, 1)
    return fresh
  }

  /// 一次可取消的位图烘制。**必须在非主线程可用**（ASDK 自 iOS 10 起就在后台队列上调
  /// UIGraphicsImageRenderer：_ASDisplayLayer.mm:124-135 的 displayQueue）。
  ///
  /// - Parameters:
  ///   - traits: 绘制期注入的外观档（要点 3）。传画布当时的 traitCollection。
  ///   - isCancelled: 取消判据。后台**每个分段检查点**都会调它；实现只读一个原子量。
  /// - Returns: 取消 / 绘制失败 / 尺寸非法时 nil。
  public static func render(
    _ job: TiebaFeedBitmapJob,
    traits: UITraitCollection,
    isCancelled: () -> Bool
  ) -> CGImage? {
    guard job.size.width > 0, job.size.height > 0, !job.runs.isEmpty else { return nil }
    // 开跑前先查一次：代次已过期就连 renderer 与整张后备存储都不建。
    guard !isCancelled() else { return nil }

    let renderer = UIGraphicsImageRenderer(
      size: job.size,
      format: format(opaque: job.opaque, scale: job.scale)
    )
    var image: UIImage?
    do {
      try renderer.runDrawingActions({ _ in
        // 要点 3：trait 注入。Swift 名是 performAsCurrent(_:)，
        // 不是 ObjC 的 performAsCurrentTraitCollection:（报告 §1.2 探针 C）。
        traits.performAsCurrent {
          draw(job, isCancelled: isCancelled)
        }
      }, completionActions: { context in
        // 要点 2：**提交前可取消**。位图是在这里（currentImage）才真正分配的 ——
        // image { } 没有这个钩子，取消只能在绘制中途生效，而后备存储已经分配好了。
        // 对应 ASGraphicsContext.mm:95-96 的注释与 :104-108 的 isCancelled 分支。
        guard !isCancelled() else { return }
        image = (context as? UIGraphicsImageRendererContext)?.currentImage
      })
    } catch {
      return nil
    }
    return image?.cgImage
  }

  /// 逐段绘制。每段之间查一次取消（分段取消检查点，对应
  /// CHECK_CANCELLED_AND_RETURN_NIL，ASDisplayNode+AsyncDisplay.mm:216-219）。
  private static func draw(_ job: TiebaFeedBitmapJob, isCancelled: () -> Bool) {
    let canvas = CGRect(origin: .zero, size: job.size)
    for run in job.runs {
      if isCancelled() { return }
      let frame = run.frame
      guard run.attributed.length > 0, frame.intersects(canvas),
            frame.width > 0, frame.height > 0
      else { continue }
      // 阶段 0：测量期已给自然高就直接用（**省掉第二遍排版**）；
      // 没给就回落旧行为（有界量高，见下面 boundedNaturalHeight 的注释）。
      let natural = run.naturalHeight ?? boundedNaturalHeight(run)
      let inset = natural < frame.height ? max((frame.height - natural) / 2, 0) : 0
      run.attributed.draw(
        with: CGRect(
          x: frame.minX,
          y: frame.minY + inset,
          width: frame.width,
          height: frame.height - inset
        ),
        options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
        context: nil
      )
    }
  }

  /// 有界量高（**只在没有 naturalHeight 时走**）：垂直居中只需要知道「自然高是否超过框高」——
  /// 超框（截断态）inset 恒为 0。无界 .greatestFiniteMagnitude 会把折叠态长摘要的**全文**
  /// 逐行排完（几十行 vs 实画 4 行，约 5-10 倍排版量）再整个丢弃；有界版排版在框高处停，
  /// 结果与无界版逐像素一致。（原实现逐字搬来。）
  private static func boundedNaturalHeight(_ run: TiebaFeedBitmapJob.Run) -> CGFloat {
    run.attributed.boundingRect(
      with: CGSize(width: run.frame.width, height: run.frame.height),
      options: [.usesLineFragmentOrigin],
      context: nil
    ).height
  }
}
