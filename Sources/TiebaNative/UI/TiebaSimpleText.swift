//  简单行/通用行的文本口径（字体、单行宽、行高）。
//  从 UI/ListKit/TiebaSimpleRows.swift 拆出：UI/Chrome 与 UI/Components 的表单件
//  也要用它，留在 ListKit 会把上层拖成 ListKit 的下游。

import UIKit
import Nuke
import NukeExtensions

nonisolated enum TiebaSimpleText {
  static func textStyle(for size: CGFloat) -> UIFont.TextStyle {
    switch size {
    case ..<11.5: return .caption2
    case ..<12.5: return .caption1
    case ..<14.5: return .footnote
    case ..<15.5: return .subheadline
    case ..<16.5: return .callout
    default: return .body
    }
  }

  /// RN fontWeight 数值 → UIFont.Weight（RN 的 100…900 → ultralight…black 映射）。
  static func weight(_ raw: Double) -> UIFont.Weight {
    switch Int(raw.rounded()) {
    case ...199: return .ultraLight
    case 200...299: return .thin
    case 300...399: return .light
    case 400...499: return .regular
    case 500...599: return .medium
    case 600...699: return .semibold
    case 700...799: return .bold
    case 800...899: return .heavy
    default: return .black
    }
  }

  // ── 字体缓存 ──
  // font(size:weight:) 是全仓行字体的咽喉（帖子行 TiebaPostRowLayout 全部字体 +
  // 简单行族）：帖子页每行 plan 访问 nameFont/actionFont/metaFont 等 10+ 次，
  // 400 楼整页 publish ≈ 4000 次 UIFontMetrics descriptor 解析，而 (size,weight)
  // 组合屈指可数——按组合缓存，系统字号档变化（didChange）整体失效。
  // UIFont 不可变且线程安全；测量在后台队列跑，访问统一走锁。
  //
  // 2026-10-06 两级字号：缓存键用**乘过应用内倍率之后的字号**（size×scale），
  // 所以「字号变了却命中旧档」在键上就不可能发生；世代（TiebaTypography.generation）
  // 只用来在变化时把字典清空一次，避免它随世代无限增长。
  private static let fontCacheLock = NSLock()
  nonisolated(unsafe) private static var fontCache: [FontKey: UIFont] = [:]
  nonisolated(unsafe) private static var fontCacheGeneration: UInt64 = .max

  private struct FontKey: Hashable {
    let size: CGFloat
    // UIFont.Weight.rawValue 是 CGFloat（不是 UInt）。
    let weightRaw: CGFloat
  }

  private static let fontCacheReset: Void = {
    NotificationCenter.default.addObserver(
      forName: UIContentSizeCategory.didChangeNotification,
      object: nil,
      queue: .main
    ) { _ in
      fontCacheLock.withLock { fontCache.removeAll() }
    }
    return ()
  }()

  /// **界面级**字体（界面字号 × 系统 Dynamic Type）。全仓界面文本的默认入口。
  static func font(size: CGFloat, weight: UIFont.Weight) -> UIFont {
    scaledFont(size: size, weight: weight, scale: TiebaTypography.uiScale())
  }

  /// **正文级**字体（正文字号 × 系统 Dynamic Type）：帖子卡片、帖子详情正文/
  /// 回复/楼中楼专用。与 font(size:weight:) 是同一套实现，只差缩放来源。
  static func bodyFont(size: CGFloat, weight: UIFont.Weight) -> UIFont {
    scaledFont(size: size, weight: weight, scale: TiebaTypography.bodyScale())
  }

  /// **界面级**字体 · 按系统字标（等价于 UIFont.preferredFont(forTextStyle:)，
  /// 但叠上应用内界面字号）。存在的理由：全仓还有几十处直接写
  /// .preferredFont(forTextStyle:) 的固定字号，界面字号管不到它们；机械替换成
  /// 这一句即可，同时保留"跟随系统 Dynamic Type"的既有语义。
  /// - Parameter weight: 缺省 = headline 用 semibold、其余 regular（与系统同）。
  static func uiFont(style: UIFont.TextStyle, weight: UIFont.Weight? = nil) -> UIFont {
    let resolved = weight ?? (style == .headline ? .semibold : .regular)
    return scaledFont(
      size: defaultPointSize(style), weight: resolved, scale: TiebaTypography.uiScale())
  }

  /// 系统字标的**未缩放**基准字号（UIFontMetrics 的原点；乘应用倍率前的那一档）。
  private static func defaultPointSize(_ style: UIFont.TextStyle) -> CGFloat {
    switch style {
    case .largeTitle: return 34
    case .title1: return 28
    case .title2: return 22
    case .title3: return 20
    case .headline: return 17
    case .body: return 17
    case .callout: return 16
    case .subheadline: return 15
    case .footnote: return 13
    case .caption1: return 12
    case .caption2: return 11
    default: return 17
    }
  }

  /// 指定倍率的字体。**实时示例专用**：滑杆值还没落库时也要能量出目标字号
  /// （font/bodyFont 读的是已落库的全局快照，量不出"手指当前这一格"）。
  static func scaledFont(size: CGFloat, weight: UIFont.Weight, scale: CGFloat) -> UIFont {
    _ = fontCacheReset
    // 应用内倍率先乘进字号，再过系统 Dynamic Type（UIFontMetrics 的基准字号
    // 也跟着缩，这样系统档与应用档是叠乘而不是互相覆盖）。
    let scaledSize = max(size * max(scale, 0.1), 1)
    let key = FontKey(size: scaledSize, weightRaw: weight.rawValue)
    return fontCacheLock.withLock {
      let generation = TiebaTypography.generation
      if fontCacheGeneration != generation {
        fontCache.removeAll(keepingCapacity: true)
        fontCacheGeneration = generation
      }
      if let cached = fontCache[key] { return cached }
      let font = UIFontMetrics(forTextStyle: textStyle(for: size))
        .scaledFont(for: UIFont.systemFont(ofSize: scaledSize, weight: weight))
      fontCache[key] = font
      return font
    }
  }

  /// 行高：RN 给了显式 lineHeight → ×UIFontMetrics；未给（RN 走字体默认行高）
  /// → font.lineHeight 向上取整，避免 UILabel 末行被裁半像素。
  /// - Parameter scale: 应用内倍率。**必须**与构造 font 时用的那一级一致
  ///   （正文级传 TiebaTypography.bodyScale()，界面级传 uiScale()），否则字大了
  ///   行盒没大，多行文本会互相压。
  static func lineHeight(_ explicit: Double?, font: UIFont, scale: CGFloat) -> CGFloat {
    guard let explicit, explicit > 0 else { return ceil(font.lineHeight) }
    return ceil(
      UIFontMetrics(forTextStyle: textStyle(for: font.pointSize))
        .scaledValue(for: CGFloat(explicit) * max(scale, 0.1)))
  }

  /// 测量用 attributed（只用 font + paragraph lineHeight；**不写颜色**——
  /// 绘制期按色板补色，换主题无需重测）。
  /// truncating = true（默认）时末行截断加省略号（单/多行摘要用）；false 时按字换行、
  /// 不截断（不限行的主贴标题用——段落样式里的 byTruncatingTail 会盖过 label 的
  /// numberOfLines=0，留着它最后一行照样带省略号）。
  static func makeAttributed(
    text: String,
    font: UIFont,
    lineHeight: CGFloat,
    truncating: Bool = true
  ) -> NSAttributedString {
    let paragraph = NSMutableParagraphStyle()
    paragraph.minimumLineHeight = lineHeight
    paragraph.maximumLineHeight = lineHeight
    paragraph.lineBreakMode = truncating ? .byTruncatingTail : .byWordWrapping
    return NSAttributedString(
      string: text,
      attributes: [.font: font, .paragraphStyle: paragraph]
    )
  }

  /// TextKit 测量（实现在 TiebaRowText，全仓唯一一份；调用方保证在测量队列上）。
  static func measureHeight(_ attributed: NSAttributedString, width: CGFloat, maxLines: Int) -> CGFloat {
    TiebaRowText.measureHeight(attributed, width: width, maxLines: maxLines)
  }

  /// 单行文本宽（徽章内联定位用；不改行高）。
  static func singleLineWidth(_ text: String, font: UIFont) -> CGFloat {
    TiebaRowText.singleLineWidth(text, font: font)
  }
}
