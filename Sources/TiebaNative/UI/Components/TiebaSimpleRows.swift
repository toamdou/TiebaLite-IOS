// ============================================================
// TiebaLite RN — 通用列表行（TiebaSimpleRows）
//
// 用途（2026-09-13，LegendList 拆除第 3 批）：把"非信息流卡片"的 RN 行
// 搬到原生。这些界面（吧务团队 / 吧成员 / 粉丝关注 / 消息）原来用
// LegendList + RN 行组件渲染，行形状与 TweetCard 无关，但结构高度同质：
// 头像 + 两行文本 + 尾随箭头 / 正文 + 时间 / 分组标题 / 说明卡。
//
// 设计：**变体驱动的单一测量 + 单一绘制**，不为每个界面各写一套行视图：
//   - 变体（variant）：user（头像行）/ message（消息行）/ section（分组标题行）/
//     summary（说明卡行）。JS 只推"信息"（文本、颜色、尺寸键），不推行级样式；
//   - 几何默认值集中在各变体的 init 分支，注释逐项标出 RN 来源文件 + 字段。
//     JS 只覆盖差异键（如 bawu 的 avatarSize 46 / paddingV 11），未覆盖走默认；
//   - 测量在后台串行队列整页一趟（与 TiebaRowMetrics 同一架构、同一套
//     TextKit 调用），行视图绘制期零测量；测量结果按（pageKey, 0.5pt 量化宽）
//     键控整页缓存 + LRU（maxPages = 8）。
//
// 与 TiebaRowMetrics 的关系：那边是信息流卡片（TiebaFeedRowModel）专用的
// 700 行几何，行形状完全绑定 TweetCard；本文件是它的**同类并列实现**，
// 共享 TiebaFeedRowPalette（主题色板）与 TiebaRowText 的 TextKit 测量，但
// attributed 串**不写前景色**——换主题时只重贴色，不重测（TiebaFeedRowModel
// 把 .label 色写进了串，靠 refreshDynamicLayerColors 补救）。
//
// ⚠️ 宽度不做全局闸门：同屏多个列表各自的宽度不同（消息列表 16pt 横内缩、
// 吧务 0），全局闸门会互相清页。这里页键 =（pageKey, 宽度），查询显式传宽度，
// 互不干扰（TiebaRowMetrics 同一纪律）。
//
// 复用纪律：cell 复用前调 prepareForReuse()（取消在途图片请求、清文本），
// 绘制内容完全由 (pageKey, index) 对应的模型决定。
// ============================================================

import UIKit
import Nuke
import NukeExtensions

// MARK: - 色板（TiebaFeedRowPalette + 本批行需要的额外 token）

/// 通用行色板 = 信息流色板（card/text/textSecondary/textTertiary/primary/
/// avatarFallback/isNight…）+ colors.ts 里本批行用到的额外 token。
/// 默认值 = 应用默认亮/暗语义色（与 colors.ts 的 light/dark 表逐值相同）；
/// JS 经 themeColors 下发实际主题后非默认主题的 primary/divider 等生效。
public nonisolated struct TiebaSimpleRowPalette: @unchecked Sendable, Equatable {
  public var base: TiebaFeedRowPalette
  /// colors.divider：吧务成员行 0.5pt 描边。
  public var divider: UIColor
  /// colors.groupFill：吧务说明卡底色。
  public var groupFill: UIColor
  /// colors.surfaceSecondary：计数 chip 底 / 头像占位底。
  public var surfaceSecondary: UIColor
  /// colors.textDisabled：消息时间行 / 吧务尾随箭头。
  public var textDisabled: UIColor
  /// colors.success：消息"赞"类型图标色。
  public var success: UIColor
  /// colors.textOnPrimary：头像首字母色（Avatar.tsx:117）。
  public var textOnPrimary: UIColor

  public static let `default` = TiebaSimpleRowPalette(
    base: .default,
    divider: TiebaSimpleRowPalette.adaptive(light: 0x3C3C43, lightAlpha: 0.12,
                                            dark: 0x545458, darkAlpha: 0.65),
    groupFill: TiebaSimpleRowPalette.adaptive(light: 0x787880, lightAlpha: 0.08,
                                              dark: 0xFFFFFF, darkAlpha: 0.08),
    surfaceSecondary: TiebaSimpleRowPalette.adaptive(light: 0xF2F2F7, dark: 0x1C1C1E),
    textDisabled: TiebaSimpleRowPalette.adaptive(light: 0x3C3C43, lightAlpha: 0.2,
                                                 dark: 0xEBEBF5, darkAlpha: 0.2),
    success: TiebaSimpleRowPalette.adaptive(light: 0x34C759, dark: 0x30D158),
    textOnPrimary: .white
  )

  /// JS 主题字典 → 色板；缺失/解析失败的键保留默认值（旧 JS 不下发时行为与
  /// 迁移前完全一致）。与 TiebaFeedRowPalette.init(dict:) 同款容错。
  public init(dict: [String: Any]) {
    var palette = TiebaSimpleRowPalette.default
    palette.base = TiebaFeedRowPalette(dict: dict)
    func apply(_ key: String, _ assign: (UIColor) -> Void) {
      guard let raw = dict[key] as? String, let color = tiebaColor(from: raw) else { return }
      assign(color)
    }
    apply("divider") { palette.divider = $0 }
    apply("groupFill") { palette.groupFill = $0 }
    apply("surfaceSecondary") { palette.surfaceSecondary = $0 }
    apply("textDisabled") { palette.textDisabled = $0 }
    apply("success") { palette.success = $0 }
    apply("textOnPrimary") { palette.textOnPrimary = $0 }
    self = palette
  }

  private init(
    base: TiebaFeedRowPalette,
    divider: UIColor,
    groupFill: UIColor,
    surfaceSecondary: UIColor,
    textDisabled: UIColor,
    success: UIColor,
    textOnPrimary: UIColor
  ) {
    self.base = base
    self.divider = divider
    self.groupFill = groupFill
    self.surfaceSecondary = surfaceSecondary
    self.textDisabled = textDisabled
    self.success = success
    self.textOnPrimary = textOnPrimary
  }

  private static func adaptive(light: UInt32, dark: UInt32) -> UIColor {
    adaptive(light: light, lightAlpha: 1, dark: dark, darkAlpha: 1)
  }

  private static func adaptive(
    light: UInt32,
    lightAlpha: CGFloat,
    dark: UInt32,
    darkAlpha: CGFloat
  ) -> UIColor {
    UIColor { traits in
      traits.userInterfaceStyle == .dark
        ? color(dark, alpha: darkAlpha)
        : color(light, alpha: lightAlpha)
    }
  }

  private static func color(_ hex: UInt32, alpha: CGFloat) -> UIColor {
    UIColor(
      red: CGFloat((hex >> 16) & 0xFF) / 255,
      green: CGFloat((hex >> 8) & 0xFF) / 255,
      blue: CGFloat(hex & 0xFF) / 255,
      alpha: alpha
    )
  }
}

// MARK: - 文本工具（与 typographyStyles 的显式 lineHeight 对齐）

/// 字号 → UIFont.TextStyle 映射（RN 文本 allowFontScaling 默认开，原生用
/// UIFontMetrics 复刻；映射按字号就近取档，与 TiebaFeedRowLayout.Fonts 同法）。
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

// MARK: - 变体与文本块

/// 行变体（JS 的 rows[i].variant；未知值按 user 兜底）。
public nonisolated enum TiebaSimpleRowVariant: String, Sendable {
  /// 头像 + 标题（+ 等级徽章）+ 副标题 + 尾随箭头（粉丝关注 / 吧务成员）。
  case user
  /// 头像 + 昵称（+ 类型图标）+ 正文（≤2 行）+ 原贴标题 + 时间（消息列表）。
  case message
  /// 分组标题行：色条 + 标题 + 计数 chip（吧务角色分组 / 吧成员分组）。
  case section
  /// 说明卡行：图标方框 + 标题 + 副标题（吧务团队概览卡）。
  case summary
}

/// 一行文本块：测量结果 + 绘制输入（attributed 串在测量队列构建，绘制期只贴）。
nonisolated struct TiebaSimpleTextBlock {
  let attributed: NSAttributedString
  let font: UIFont
  let lineHeight: CGFloat
  let height: CGFloat
  let text: String
  /// 测量时用的行数上限。**绘制必须用同一个值**（N4：消息正文按 2 行测量、label 却是 numberOfLines=1 ⇒
  /// 第二行不画，UILabel 再把单行垂直居中在 2 行高的 frame 里，下方空出一整行）。
  let lines: Int
}

// MARK: - 行变体载荷（H12）

/// 四个变体各自的字段：互斥由类型保证（一个模型只可能持有一个 case）。
/// 字段与类型从原平铺并集原样搬来；取值表达式一字未改。
struct TiebaSimpleRowUserPayload {
  let marginV: CGFloat
  let paddingH: CGFloat
  let paddingV: CGFloat
  let cornerRadius: CGFloat
  let borderWidth: CGFloat
  let backgroundColor: UIColor?
  let borderColor: UIColor?
  let avatarSize: CGFloat
  let avatarURL: URL?
  let avatarInitial: String
  let showsChevron: Bool
  let chevronSize: CGFloat
  let chevronColor: UIColor?
  let subtitleBlock: TiebaSimpleTextBlock?
  let subtitleMarginTop: CGFloat
  let badgeText: String?
  let badgeBlock: TiebaSimpleTextBlock?
  let badgeTextColor: UIColor?
  let badgeBackgroundColor: UIColor?
  let badgePaddingH: CGFloat
  let badgePaddingV: CGFloat
  let badgeRadius: CGFloat
  let badgeSpacing: CGFloat
  let typeIconSize: CGFloat
  let bodyGap: CGFloat
  let headerGap: CGFloat
}

struct TiebaSimpleRowMessagePayload {
  let marginV: CGFloat
  let paddingH: CGFloat
  let paddingV: CGFloat
  let cornerRadius: CGFloat
  let borderWidth: CGFloat
  let backgroundColor: UIColor?
  let borderColor: UIColor?
  let avatarSize: CGFloat
  let avatarURL: URL?
  let avatarInitial: String
  let isUnread: Bool
  let unreadDotColor: UIColor?
  let typeIconName: String?
  let typeIconSize: CGFloat
  let typeIconColor: UIColor?
  let bodyGap: CGFloat
  let headerGap: CGFloat
  let contentBlock: TiebaSimpleTextBlock?
  let threadBlock: TiebaSimpleTextBlock?
  let timeBlock: TiebaSimpleTextBlock?
}

struct TiebaSimpleRowSectionPayload {
  let topSpacing: CGFloat
  let sectionDotColor: UIColor?
  let sectionDotSpacing: CGFloat
  let countChipText: String?
  let countChipBlock: TiebaSimpleTextBlock?
  let countChipBackgroundColor: UIColor?
  let countChipTextColor: UIColor?
  let countChipPaddingH: CGFloat
  let countChipPaddingV: CGFloat
  let countChipRadius: CGFloat
}

struct TiebaSimpleRowSummaryPayload {
  let paddingH: CGFloat
  let paddingV: CGFloat
  let cornerRadius: CGFloat
  let backgroundColor: UIColor?
  let iconName: String?
  let iconSize: CGFloat
  let iconColor: UIColor?
  let iconBoxSize: CGFloat
  let iconBoxRadius: CGFloat
  let iconBoxColor: UIColor?
  let subtitleBlock: TiebaSimpleTextBlock?
  let subtitleMarginTop: CGFloat
}

enum TiebaSimpleRowPayload {
  case user(TiebaSimpleRowUserPayload)
  case message(TiebaSimpleRowMessagePayload)
  case section(TiebaSimpleRowSectionPayload)
  case summary(TiebaSimpleRowSummaryPayload)
}

extension TiebaSimpleRowPayload {
  var userValue: TiebaSimpleRowUserPayload? { if case .user(let payload) = self { return payload }; return nil }
  var messageValue: TiebaSimpleRowMessagePayload? { if case .message(let payload) = self { return payload }; return nil }
  var sectionValue: TiebaSimpleRowSectionPayload? { if case .section(let payload) = self { return payload }; return nil }
  var summaryValue: TiebaSimpleRowSummaryPayload? { if case .summary(let payload) = self { return payload }; return nil }
}

// MARK: - 行模型

/// 单行的完整绘制输入（init 后无可写入口，跨线程只读）。
/// 字段是四个变体的并集：每个变体只读自己那几个（其余为 nil/默认值）。
public nonisolated final class TiebaSimpleRowModel: @unchecked Sendable {
  public let pageKey: String
  public let index: Int
  public let variant: TiebaSimpleRowVariant
  public let containerWidth: CGFloat
  public let measuredHeight: CGFloat
  /// accessibilityLabel（整行朗读；JS 下发，缺省用标题/正文兜底）。
  public let accessibilityLabel: String

  // ── 卡片几何（四个变体共用；无卡片变体 margin/padding 为 0）──

  // ── user / message 共用：头像 ──

  // ── user ──

  // ── message ──

  // ── section ──

  // ── summary ──

  // ── 绘制期派生（纯算术）──
  /// 卡片盒（相对行视图坐标）：上下 marginV 各一次 + bottomMargin 一次。
  var cardFrame: CGRect {
    let width = max(containerWidth - marginH * 2, 0)
    let height = max(measuredHeight - marginV * 2 - bottomMargin, 0)
    return CGRect(x: marginH, y: marginV, width: width, height: height)
  }

  /// 卡片内容区（去掉 padding 与描边）。
  var contentFrame: CGRect {
    cardFrame.insetBy(dx: paddingH + borderWidth, dy: paddingV + borderWidth)
  }

  /// 文本列宽（user：头像右侧到箭头左侧；message：头像右侧到卡片右内缘）。
  var titleColumnWidth: CGFloat {
    let content = contentFrame
    switch variant {
    case .user:
      let right = showsChevron ? content.maxX - chevronSize - gap : content.maxX
      return max(right - (content.minX + avatarSize + gap), 0)
    case .message:
      return max(content.maxX - (content.minX + avatarSize + gap), 0)
    default:
      return max(content.width, 0)
    }
  }


  /// 变体载荷（H12）：字段按变体收进各自 case，互斥由类型保证。
  /// 下面每个旧字段保留一行只读转发，取值与原「平铺并集 + 未参与变体清零」逐字等价，
  /// 因此消费点无需改动即可编译且显示不变。
  let payload: TiebaSimpleRowPayload

  let marginH: CGFloat
  let bottomMargin: CGFloat
  let gap: CGFloat
  let titleBlock: TiebaSimpleTextBlock?
  let chevronWeight: UIFont.Weight
  let sectionDotSize: CGSize

  var marginV: CGFloat { payload.userValue?.marginV ?? payload.messageValue?.marginV ?? 0 }
  var paddingH: CGFloat { payload.userValue?.paddingH ?? payload.messageValue?.paddingH ?? payload.summaryValue?.paddingH ?? 0 }
  var paddingV: CGFloat { payload.userValue?.paddingV ?? payload.messageValue?.paddingV ?? payload.summaryValue?.paddingV ?? 0 }
  var cornerRadius: CGFloat { payload.userValue?.cornerRadius ?? payload.messageValue?.cornerRadius ?? payload.summaryValue?.cornerRadius ?? 0 }
  var borderWidth: CGFloat { payload.userValue?.borderWidth ?? payload.messageValue?.borderWidth ?? 0 }
  var backgroundColor: UIColor? { payload.userValue?.backgroundColor ?? payload.messageValue?.backgroundColor ?? payload.summaryValue?.backgroundColor ?? nil }
  var borderColor: UIColor? { payload.userValue?.borderColor ?? payload.messageValue?.borderColor ?? nil }
  var avatarURL: URL? { payload.userValue?.avatarURL ?? payload.messageValue?.avatarURL ?? nil }
  var avatarInitial: String { payload.userValue?.avatarInitial ?? payload.messageValue?.avatarInitial ?? "" }
  var avatarSize: CGFloat { payload.userValue?.avatarSize ?? payload.messageValue?.avatarSize ?? 0 }
  var badgeText: String? { payload.userValue?.badgeText ?? nil }
  var badgeBlock: TiebaSimpleTextBlock? { payload.userValue?.badgeBlock ?? nil }
  var badgeTextColor: UIColor? { payload.userValue?.badgeTextColor ?? nil }
  var badgeBackgroundColor: UIColor? { payload.userValue?.badgeBackgroundColor ?? nil }
  var badgePaddingH: CGFloat { payload.userValue?.badgePaddingH ?? 0 }
  var badgePaddingV: CGFloat { payload.userValue?.badgePaddingV ?? 0 }
  var badgeRadius: CGFloat { payload.userValue?.badgeRadius ?? 0 }
  var badgeSpacing: CGFloat { payload.userValue?.badgeSpacing ?? 0 }
  var subtitleBlock: TiebaSimpleTextBlock? { payload.userValue?.subtitleBlock ?? payload.summaryValue?.subtitleBlock ?? nil }
  var subtitleMarginTop: CGFloat { payload.userValue?.subtitleMarginTop ?? payload.summaryValue?.subtitleMarginTop ?? 0 }
  var showsChevron: Bool { payload.userValue?.showsChevron ?? false }
  var chevronSize: CGFloat { payload.userValue?.chevronSize ?? 0 }
  var chevronColor: UIColor? { payload.userValue?.chevronColor ?? nil }
  var isUnread: Bool { payload.messageValue?.isUnread ?? false }
  var unreadDotColor: UIColor? { payload.messageValue?.unreadDotColor ?? nil }
  var typeIconName: String? { payload.messageValue?.typeIconName ?? nil }
  var typeIconSize: CGFloat { payload.userValue?.typeIconSize ?? payload.messageValue?.typeIconSize ?? 0 }
  var typeIconColor: UIColor? { payload.messageValue?.typeIconColor ?? nil }
  var bodyGap: CGFloat { payload.userValue?.bodyGap ?? payload.messageValue?.bodyGap ?? 0 }
  var headerGap: CGFloat { payload.userValue?.headerGap ?? payload.messageValue?.headerGap ?? 0 }
  var contentBlock: TiebaSimpleTextBlock? { payload.messageValue?.contentBlock ?? nil }
  var threadBlock: TiebaSimpleTextBlock? { payload.messageValue?.threadBlock ?? nil }
  var timeBlock: TiebaSimpleTextBlock? { payload.messageValue?.timeBlock ?? nil }
  var sectionDotColor: UIColor? { payload.sectionValue?.sectionDotColor ?? nil }
  var sectionDotSpacing: CGFloat { payload.sectionValue?.sectionDotSpacing ?? 0 }
  var countChipText: String? { payload.sectionValue?.countChipText ?? nil }
  var countChipBlock: TiebaSimpleTextBlock? { payload.sectionValue?.countChipBlock ?? nil }
  var countChipBackgroundColor: UIColor? { payload.sectionValue?.countChipBackgroundColor ?? nil }
  var countChipTextColor: UIColor? { payload.sectionValue?.countChipTextColor ?? nil }
  var countChipPaddingH: CGFloat { payload.sectionValue?.countChipPaddingH ?? 0 }
  var countChipPaddingV: CGFloat { payload.sectionValue?.countChipPaddingV ?? 0 }
  var countChipRadius: CGFloat { payload.sectionValue?.countChipRadius ?? 0 }
  var topSpacing: CGFloat { payload.sectionValue?.topSpacing ?? 0 }
  var iconName: String? { payload.summaryValue?.iconName ?? nil }
  var iconSize: CGFloat { payload.summaryValue?.iconSize ?? 0 }
  var iconColor: UIColor? { payload.summaryValue?.iconColor ?? nil }
  var iconBoxSize: CGFloat { payload.summaryValue?.iconBoxSize ?? 0 }
  var iconBoxRadius: CGFloat { payload.summaryValue?.iconBoxRadius ?? 0 }
  var iconBoxColor: UIColor? { payload.summaryValue?.iconBoxColor ?? nil }
  init(pageKey: String, index: Int, raw: [String: Any], containerWidth: CGFloat) {
    let width = max(containerWidth, 0)
    let variant = TiebaSimpleRowVariant(
      rawValue: TiebaSimpleRowParser.string(raw["variant"]) ?? "user"
    ) ?? .user
    self.pageKey = pageKey
    self.index = index
    self.variant = variant
    self.containerWidth = width

    let colors = raw["colors"] as? [String: Any] ?? [:]
    func color(_ key: String, _ fallback: UIColor?) -> UIColor? {
      guard let raw = colors[key] as? String else { return fallback }
      return tiebaColor(from: raw) ?? fallback
    }
    func number(_ key: String, _ fallback: CGFloat) -> CGFloat {
      CGFloat(TiebaSimpleRowParser.double(raw[key]) ?? Double(fallback))
    }
    /// 文本块：文本 + 字号/字重/行高（键前缀 = 文本键名）+ TextKit 单次测量。
    func block(_ key: String, lines: Int = 1, width: CGFloat, fallbackSize: CGFloat, fallbackWeight: Double, styleKey: String? = nil) -> TiebaSimpleTextBlock? {
      guard let text = TiebaSimpleRowParser.nonEmpty(raw[key]) else { return nil }
      let prefix = styleKey ?? key
      let size = CGFloat(TiebaSimpleRowParser.double(raw["\(prefix)Size"]) ?? Double(fallbackSize))
      let weight = TiebaSimpleText.weight(TiebaSimpleRowParser.double(raw["\(prefix)Weight"]) ?? fallbackWeight)
      let font = TiebaSimpleText.font(size: size, weight: weight)
      let lineHeight = TiebaSimpleText.lineHeight(
        TiebaSimpleRowParser.double(raw["\(prefix)LineHeight"]),
        font: font,
        scale: TiebaTypography.uiScale()
      )
      let attributed = TiebaSimpleText.makeAttributed(text: text, font: font, lineHeight: lineHeight)
      let height = TiebaSimpleText.measureHeight(attributed, width: width, maxLines: lines)
      return TiebaSimpleTextBlock(
        attributed: attributed,
        font: font,
        lineHeight: lineHeight,
        height: height,
        text: text,
        lines: max(lines, 1)
      )
    }

    switch variant {
    // ───────────────────────── user ─────────────────────────
    case .user:
      // 默认 = 粉丝/关注行（SocialTabList.tsx socialItem：padding Spacing.md 12 /
      // RadiusStyle.card 20 / 头像 40 / gap 10 / 标题 14 semibold /
      // 副标题 caption2 11）。
      let paddingH = number("paddingH", 12)
      let paddingV = number("paddingV", 12)
      let gap = number("gap", 10)
      let avatarSize = number("avatarSize", 40)
      let marginH = number("marginH", 0)
      let marginV = number("marginV", 0)
      let borderWidth = number("borderWidth", 0)
      let bottomMargin = number("marginBottom", 0)
      let showsChevron = TiebaSimpleRowParser.bool(raw["chevron"]) == true
      let chevronSize = number("chevronSize", 14)
      let subtitleMarginTop = number("subtitleMarginTop", 0)
      self.marginH = marginH
      self.bottomMargin = bottomMargin
      self.gap = gap
      // 缺省卡底 = 主题卡片色：消息列表/吧务组都显式传 bg，而搜索结果的
      // user/message 行不传，写死 .white 在深色下就是白卡（用户实证）。
      self.chevronWeight = TiebaSimpleText.weight(TiebaSimpleRowParser.double(raw["chevronWeight"]) ?? 400)
      // 文本列宽：内容区 - 头像 - gap - 箭头（有箭头时让位箭头 + gap）。
      let contentWidth = max(width - marginH * 2 - (paddingH + borderWidth) * 2, 0)
      let textWidth = max(
        contentWidth - avatarSize - gap - (showsChevron ? chevronSize + gap : 0),
        0
      )
      self.titleBlock = block("title", width: textWidth, fallbackSize: 14, fallbackWeight: 600)
      // 载荷字段（计算属性）在 init 全量初始化前不可读 self，这里先落局部量。
      let subtitleBlock = block("subtitle", width: textWidth, fallbackSize: 11, fallbackWeight: 400)
      // 高度 = 描边×2 + 上下 marginV + 上下 padding + max(头像, 文本列) + bottomMargin。
      let textHeight = (titleBlock?.height ?? 0)
        + (subtitleBlock.map { subtitleMarginTop + $0.height } ?? 0)
      self.measuredHeight = borderWidth * 2 + marginV * 2 + paddingV * 2
        + max(avatarSize, textHeight) + bottomMargin
      self.accessibilityLabel = TiebaSimpleRowParser.nonEmpty(raw["a11y"])
        ?? (titleBlock?.text ?? "")
      // 未参与本变体的字段置空（Swift 要求全量初始化）。
      self.sectionDotSize = .zero

    // ──────────────────────── message ────────────────────────
      self.payload = .user(.init(
        marginV: marginV,
        paddingH: paddingH,
        paddingV: paddingV,
        cornerRadius: number("radius", 20),
        borderWidth: borderWidth,
        backgroundColor: color("bg", TiebaSimpleRowPalette.default.base.card),
        borderColor: color("borderColor", nil),
        avatarSize: avatarSize,
        avatarURL: TiebaSimpleRowParser.avatarURL(TiebaSimpleRowParser.nonEmpty(raw["avatar"]) ?? ""),
        avatarInitial: TiebaSimpleRowParser.nonEmpty(raw["avatarInitial"]) ?? "",
        showsChevron: showsChevron,
        chevronSize: chevronSize,
        chevronColor: color("chevronColor", nil),
        subtitleBlock: subtitleBlock,
        subtitleMarginTop: subtitleMarginTop,
        badgeText: TiebaSimpleRowParser.nonEmpty(raw["badge"]),
        badgeBlock: block("badge", width: textWidth, fallbackSize: 10, fallbackWeight: 700),
        badgeTextColor: color("badgeColor", nil),
        badgeBackgroundColor: color("badgeBg", nil),
        badgePaddingH: number("badgePaddingH", 5),
        badgePaddingV: number("badgePaddingV", 1),
        badgeRadius: number("badgeRadius", 8),
        badgeSpacing: number("badgeSpacing", 6),
        typeIconSize: 13,
        bodyGap: 3,
        headerGap: 8
      ))
    case .message:
      // 默认 = 消息行（MessageRow.tsx messageRow：padding Spacing.md 12 /
      // marginBottom Spacing.sm 8 / RadiusStyle.card 20 / gap 10 / 头像 40 /
      // messageBody gap 3 / messageHeader gap Spacing.sm 8）。
      let paddingH = number("paddingH", 12)
      let paddingV = number("paddingV", 12)
      let gap = number("gap", 10)
      let avatarSize = number("avatarSize", 40)
      let marginH = number("marginH", 0)
      let marginV = number("marginV", 0)
      let borderWidth = number("borderWidth", 0)
      let bottomMargin = number("marginBottom", 8)
      let typeIconName = TiebaSimpleRowParser.nonEmpty(raw["icon"])
      let typeIconSize = number("iconSize", 13)
      let bodyGap = number("bodyGap", 3)
      let headerGap = number("headerGap", 8)
      self.marginH = marginH
      self.bottomMargin = bottomMargin
      self.gap = gap
      let bodyWidth = max(
        width - marginH * 2 - (paddingH + borderWidth) * 2 - avatarSize - gap,
        0
      )
      // 昵称行：宽度 = body 宽 - 类型图标 - header gap（图标在昵称右侧）。
      let nameWidth = max(
        bodyWidth - (typeIconName == nil ? 0 : typeIconSize + headerGap),
        0
      )
      self.titleBlock = block("name", width: nameWidth, fallbackSize: 15, fallbackWeight: 600, styleKey: "name")
      let contentLines = Int(TiebaSimpleRowParser.double(raw["contentLines"]) ?? 2)
      // 载荷字段（计算属性）在 init 全量初始化前不可读 self，这里先落局部量。
      let contentBlock = block("content", lines: max(contentLines, 1), width: bodyWidth, fallbackSize: 15, fallbackWeight: 400)
      let threadBlock = block("threadTitle", width: bodyWidth, fallbackSize: 12, fallbackWeight: 400)
      let timeBlock = block("time", width: bodyWidth, fallbackSize: 11, fallbackWeight: 400)
      // 高度 = 描边×2 + 上下 marginV + 上下 padding + max(头像, body 列) + bottomMargin。
      var bodyHeight = (titleBlock?.height ?? 0)
      bodyHeight += bodyGap + (contentBlock?.height ?? 0)
      if let threadBlock { bodyHeight += bodyGap + threadBlock.height }
      bodyHeight += bodyGap + (timeBlock?.height ?? 0)
      self.measuredHeight = borderWidth * 2 + marginV * 2 + paddingV * 2
        + max(avatarSize, bodyHeight) + bottomMargin
      self.accessibilityLabel = TiebaSimpleRowParser.nonEmpty(raw["a11y"]) ?? ""
      // 其余变体字段置空。
      self.chevronWeight = .regular
      self.sectionDotSize = .zero

    // ──────────────────────── section ────────────────────────
      self.payload = .message(.init(
        marginV: marginV,
        paddingH: paddingH,
        paddingV: paddingV,
        cornerRadius: number("radius", 20),
        borderWidth: borderWidth,
        backgroundColor: color("bg", TiebaSimpleRowPalette.default.base.card),
        borderColor: color("borderColor", nil),
        avatarSize: avatarSize,
        avatarURL: TiebaSimpleRowParser.avatarURL(TiebaSimpleRowParser.nonEmpty(raw["avatar"]) ?? ""),
        avatarInitial: TiebaSimpleRowParser.nonEmpty(raw["avatarInitial"]) ?? "",
        isUnread: TiebaSimpleRowParser.bool(raw["unread"]) == true,
        unreadDotColor: color("unreadDotColor", nil),
        typeIconName: typeIconName,
        typeIconSize: typeIconSize,
        typeIconColor: color("iconColor", nil),
        bodyGap: bodyGap,
        headerGap: headerGap,
        contentBlock: contentBlock,
        threadBlock: threadBlock,
        timeBlock: timeBlock
      ))
    case .section:
      // 默认 = 分组标题（bawu.tsx roleHeader / members.tsx groupHeader：
      // marginTop 18 / marginBottom Spacing.sm 8 / marginHorizontal Spacing.xxl 28 /
      // 色条 4×14 圆角 2 / gap 7 / 标题 15 bold / 计数 chip 11 semibold
      // paddingH 8 paddingV 2 圆角 8 底 surfaceSecondary）。
      let marginH = number("marginH", 28)
      let topSpacing = number("marginTop", 18)
      let bottomMargin = number("marginBottom", 8)
      let dotColor = color("dotColor", nil)
      let dotSize = CGSize(
        width: number("dotWidth", 4),
        height: number("dotHeight", 14)
      )
      let dotSpacing = number("dotSpacing", 7)
      let chipPaddingH = number("chipPaddingH", 8)
      let chipPaddingV = number("chipPaddingV", 2)
      self.marginH = marginH
      self.bottomMargin = bottomMargin
      self.gap = number("gap", 7)
      self.sectionDotSize = dotSize
      let contentWidth = max(width - marginH * 2, 0)
      let chipBlock = block("count", width: contentWidth, fallbackSize: 11, fallbackWeight: 600)
      let chipTextWidth = chipBlock.map {
        TiebaSimpleText.singleLineWidth($0.text, font: $0.font)
      } ?? 0
      let chipTotalWidth = chipTextWidth > 0 ? chipTextWidth + chipPaddingH * 2 : 0
      let titleWidth = max(contentWidth - (chipTotalWidth > 0 ? chipTotalWidth + 8 : 0), 0)
      let titleBlock = block("title", width: titleWidth, fallbackSize: 15, fallbackWeight: 700)
      self.titleBlock = titleBlock
      let lineBase = max(
        dotSize.height,
        titleBlock?.height ?? 0,
        (chipBlock?.height ?? 0) + chipPaddingV * 2
      )
      self.measuredHeight = topSpacing + lineBase + bottomMargin
      self.accessibilityLabel = TiebaSimpleRowParser.nonEmpty(raw["a11y"])
        ?? (titleBlock?.text ?? "")
      // 其余变体字段置空。
      self.chevronWeight = .regular

    // ──────────────────────── summary ────────────────────────
      self.payload = .section(.init(
        topSpacing: topSpacing,
        sectionDotColor: dotColor,
        sectionDotSpacing: dotSpacing,
        countChipText: TiebaSimpleRowParser.nonEmpty(raw["count"]),
        countChipBlock: chipBlock,
        countChipBackgroundColor: color("chipBg", nil),
        countChipTextColor: color("chipTextColor", nil),
        countChipPaddingH: chipPaddingH,
        countChipPaddingV: chipPaddingV,
        countChipRadius: number("chipRadius", 8)
      ))
    case .summary:
      // 默认 = 吧务说明卡（bawu.tsx summaryCard：marginHorizontal Spacing.lg 16 /
      // marginBottom 6 / paddingH 14 / paddingV 13 / RadiusStyle.card 20 /
      // gap Spacing.md 12 / 图标方框 40 圆角 12 / 标题 calloutBold 16/21 /
      // 副标题 caption1 12/16 marginTop 2）。
      let marginH = number("marginH", 16)
      let paddingH = number("paddingH", 14)
      let paddingV = number("paddingV", 13)
      let gap = number("gap", 12)
      let bottomMargin = number("marginBottom", 6)
      let iconBoxSize = number("iconBox", 40)
      let subtitleMarginTop = number("subtitleMarginTop", 2)
      self.marginH = marginH
      self.bottomMargin = bottomMargin
      self.gap = gap
      let contentWidth = max(width - marginH * 2 - paddingH * 2, 0)
      let textWidth = max(contentWidth - iconBoxSize - gap, 0)
      self.titleBlock = block("title", width: textWidth, fallbackSize: 16, fallbackWeight: 600)
      // 载荷字段（计算属性）在 init 全量初始化前不可读 self，这里先落局部量。
      let subtitleBlock = block("subtitle", width: textWidth, fallbackSize: 12, fallbackWeight: 400)
      let textHeight = (titleBlock?.height ?? 0)
        + (subtitleBlock.map { subtitleMarginTop + $0.height } ?? 0)
      self.measuredHeight = paddingV * 2 + max(iconBoxSize, textHeight) + bottomMargin
      self.accessibilityLabel = TiebaSimpleRowParser.nonEmpty(raw["a11y"])
        ?? (titleBlock?.text ?? "")
      // 其余变体字段置空。
      self.chevronWeight = .regular
      self.sectionDotSize = .zero
      self.payload = .summary(.init(
        paddingH: paddingH,
        paddingV: paddingV,
        cornerRadius: number("radius", 20),
        backgroundColor: color("bg", nil),
        iconName: TiebaSimpleRowParser.nonEmpty(raw["icon"]),
        iconSize: number("iconSize", 20),
        iconColor: color("iconColor", nil),
        iconBoxSize: iconBoxSize,
        iconBoxRadius: number("iconBoxRadius", 12),
        iconBoxColor: color("iconBg", nil),
        subtitleBlock: subtitleBlock,
        subtitleMarginTop: subtitleMarginTop
      ))
    }
  }
}

// MARK: - 字典解析
