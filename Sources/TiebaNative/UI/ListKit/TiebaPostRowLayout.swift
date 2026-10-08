// 从 TiebaPostRowMetrics.swift 拆出（H10 千行文件拆分）：行布局常量 + 时间文案。
// 纯搬运：整类型逐字搬走（不改访问级、不改一行逻辑）。

// MARK: - 布局常量

import UIKit
import Nuke

enum TiebaPostRowLayout {
  /// 卡面几何**由外观档给**（TiebaListAppearance）：卡片档 = 左右 10 / 上下 4 / 圆角 16，
  /// 扁平档 = 全 0（通栏、行间只靠发际线）。
  ///
  /// 卡片档的 10 来自用户 2026-09-19"帖子卡片与屏幕两边的距离太大"（16 收紧到 10）。
  /// 这个值同时是已知主贴占位卡的边距（TiebaThreadKnownPostView 引它），两边**同源**
  /// 才不会在首包落地换卡时横向跳一次 —— 所以这里不再各写各的常量，只做转发。
  static var cardMarginH: CGFloat { TiebaListAppearance.cardMarginH }
  static var cardMarginV: CGFloat { TiebaListAppearance.cardMarginV }
  static let cardPadding: CGFloat = TiebaListAppearance.cardPadding
  static var cardRadius: CGFloat { TiebaListAppearance.cardRadius }
  static let avatarSide: CGFloat = 36
  static let avatarSideMain: CGFloat = 40
  static let avatarGap: CGFloat = 10
  static let nameRowGap: CGFloat = 3
  static let authorBottom: CGFloat = 12
  static let levelGap: CGFloat = 6
  static let actionGap: CGFloat = 12
  static let mediaGap: CGFloat = 12
  static let imageRadius: CGFloat = 10
  static let stripHeight: CGFloat = 160
  static let stripSpacing: CGFloat = 6
  static let longImageHeight: CGFloat = 300
  static let singleImageMaxHeight: CGFloat = 520
  static let maxImages = 9
  static let audioHeight: CGFloat = 52
  static let subPostTop: CGFloat = 10
  /// 框内行距的一半（两行之间共 2×gap，与旧版"分隔线上下各一份"同值）。
  static let subPostDividerGap: CGFloat = 8
  /// 楼中楼预览框：内容列到框边的距离，以及框的圆角。框把预览整段收进一个浅底
  /// 圆角矩形（取代旧版"逐条上方一条分隔线 + 块顶一条 hairline"）。
  static let subPostBoxPadding: CGFloat = 10
  static let subPostBoxRadius: CGFloat = 8
  /// 主贴回复工具栏（ThreadHeader.replyToolbar：paddingVertical 12×2 + 药丸 30）。
  static let toolbarHeight: CGFloat = 54

  // ── 帖子卡字体（**正文级**）──
  // 用户口径 2026-10-06：「点进去帖子之后」的正文/回复/楼中楼都吃正文字号；
  // 而卡内作者名/时间/徽标/操作栏同属这张卡，跟着正文级一起缩放才不会出现
  // "字大了但名字还是小字"的断层。入口统一走 TiebaSimpleText.bodyFont。
  static var nameFont: UIFont { TiebaSimpleText.bodyFont(size: 15, weight: .semibold) }
  static var nameFontMain: UIFont { TiebaSimpleText.bodyFont(size: 16, weight: .semibold) }
  /// 主贴卡标题（仅主贴行）：与已知主贴占位卡 knownTitle 逐项同尺（17pt/22pt/3 行），
  /// 首包落地换卡时标题原地接管，下面的作者行/正文不位移。
  static var titleFont: UIFont { TiebaSimpleText.bodyFont(size: 17, weight: .medium) }
  /// 标题行盒（基准 22pt）。**必须随正文字号缩放**：行高不跟着字长，字一大
  /// 多行标题就会互相压（本仓"字号调了行高没调"的老坑，见 45-字号体系）。
  static var titleLineHeight: CGFloat { ceil(22 * TiebaTypography.bodyScale()) }
  /// 正文摘要行盒（基准 22pt，与 TiebaPostRowPlan 的 22×textScale 同源）。
  static var abstractLineHeight: CGFloat { ceil(22 * TiebaTypography.bodyScale()) }
  /// 标题**不限行**（0 = 不截断）：用户 2026-09-17 报"长标题被截断、显示不全"。
  /// 占位卡（TiebaThreadKnownPostView）的行数必须与这里一致，换卡才不跳。
  static let titleLineLimit = 0
  static var metaFont: UIFont { TiebaSimpleText.bodyFont(size: 12, weight: .regular) }
  static var badgeFont: UIFont { TiebaSimpleText.bodyFont(size: 11, weight: .bold) }
  static var lzFont: UIFont { TiebaSimpleText.bodyFont(size: 11, weight: .semibold) }
  static var actionFont: UIFont { TiebaSimpleText.bodyFont(size: 12, weight: .medium) }
  static var moreFont: UIFont { TiebaSimpleText.bodyFont(size: 13, weight: .semibold) }
  static var pillFont: UIFont { TiebaSimpleText.bodyFont(size: 13, weight: .semibold) }
  /// 排序药丸尾部那个向下箭头（点开 = 热门/正序/倒序三档菜单）。
  static var pillChevronConfig: UIImage.SymbolConfiguration {
    UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
  }
  /// 箭头占的宽度（10pt 字形 + 与标题的 4pt 间距）：药丸宽度要算上它。
  static let pillChevronWidth: CGFloat = 14
  /// 楼中楼名字的字体。**必须与正文同一个 pointSize**（正文是 14×应用倍率的 systemFont）：
  /// 名字现在并进同一条富文本，字号不一致时 20pt 行盒里首行基线又会对不上。
  static func subPostNameFont(_ scale: Double) -> UIFont {
    UIFont.systemFont(ofSize: 14 * scale, weight: .semibold)
  }
  static var replyCountFont: UIFont { TiebaSimpleText.bodyFont(size: 15, weight: .semibold) }

  /// 楼中楼预览的行盒高度（与 buildContent(isSubPost:) 的 20×scale 同值）。
  static func subPostLineHeight(_ scale: Double) -> CGFloat { ceil(20 * scale) }

  /// 名字标签必须与正文文本框共用同一行盒，否则正文首行会掉到名字右下角。
  static func subPostNameParagraph(_ scale: Double) -> NSParagraphStyle {
    let paragraph = NSMutableParagraphStyle()
    paragraph.minimumLineHeight = 20 * scale
    paragraph.maximumLineHeight = 20 * scale
    paragraph.lineBreakMode = .byTruncatingTail
    return paragraph
  }

  /// hideMedia / blockVideo 的占位条（无视频/未屏蔽 → nil）。
  static func mediaPlaceholder(
    hasVideo: Bool,
    preferences: TiebaPostPreferences
  ) -> TiebaPostMediaPlaceholder? {
    guard hasVideo else { return nil }
    if preferences.hideMedia { return TiebaPostMediaPlaceholder(icon: "video", text: "[视频]") }
    if preferences.blockVideo { return TiebaPostMediaPlaceholder(icon: "video.slash", text: "[视频已屏蔽]") }
    return nil
  }

  static func metaText(post: TiebaThreadPost, isMain: Bool, preferences: TiebaPostPreferences) -> String {
    let time = TiebaTimeText.label(ms: post.createTimeMs, style: preferences.timestampStyle)
    var parts: [String] = []
    if !time.isEmpty { parts.append(time) }
    if !isMain, post.floor > 0 { parts.append("\(post.floor)楼") }
    if preferences.showIpLocation, !post.ipLocation.isEmpty {
      parts.append("IP属地：\(post.ipLocation)")
    }
    return parts.joined(separator: " · ")
  }

  /// Kotlin getIconColorByLevel + greifyColor(0.2)（等级色字 + 25% 透明底）。
  static func levelColor(_ level: Int) -> UIColor? {
    guard level > 0 else { return nil }
    let base: (CGFloat, CGFloat, CGFloat)
    switch level {
    case ...3: base = (0x2F, 0xBE, 0xAB)
    case ...9: base = (0x3A, 0xA7, 0xE9)
    case ...15: base = (0xFF, 0xA1, 0x26)
    case ...18: base = (0xFF, 0x9C, 0x19)
    default: base = (0xB7, 0xBC, 0xB6)
    }
    var (h, s, v) = rgbToHSV(base)
    s = max(0, s - 0.2)
    v = max(0, v - 0.2 / 3)
    return hsvToColor(h, s, v)
  }

  private static func rgbToHSV(_ rgb: (CGFloat, CGFloat, CGFloat)) -> (CGFloat, CGFloat, CGFloat) {
    let (r, g, b) = (rgb.0 / 255, rgb.1 / 255, rgb.2 / 255)
    let maxValue = max(r, g, b), minValue = min(r, g, b), delta = maxValue - minValue
    var h: CGFloat = 0
    if delta != 0 {
      if maxValue == r { h = ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
      else if maxValue == g { h = (b - r) / delta + 2 }
      else { h = (r - g) / delta + 4 }
      h *= 60
      if h < 0 { h += 360 }
    }
    return (h, maxValue == 0 ? 0 : delta / maxValue, maxValue)
  }

  private static func hsvToColor(_ h: CGFloat, _ s: CGFloat, _ v: CGFloat) -> UIColor {
    let c = v * s
    let x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1))
    let m = v - c
    let rgb: (CGFloat, CGFloat, CGFloat)
    switch h {
    case ..<60: rgb = (c, x, 0)
    case ..<120: rgb = (x, c, 0)
    case ..<180: rgb = (0, c, x)
    case ..<240: rgb = (0, x, c)
    case ..<300: rgb = (x, 0, c)
    default: rgb = (c, 0, x)
    }
    return UIColor(red: rgb.0 + m, green: rgb.1 + m, blue: rgb.2 + m, alpha: 1)
  }
}

