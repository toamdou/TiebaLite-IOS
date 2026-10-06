// 从 TiebaPostRowMetrics.swift 拆出（H10 千行文件拆分）：行布局常量 + 时间文案。
// 纯搬运：整类型逐字搬走（不改访问级、不改一行逻辑）。

// MARK: - 布局常量

import UIKit
import Nuke

enum TiebaPostRowLayout {
  /// 左右边距（用户 2026-09-19："帖子卡片与屏幕两边的距离太大" ⇒ 16 收紧到 10）。
  /// 这个值同时是已知主贴占位卡的边距（TiebaThreadKnownPostView 引它），两边必须同值，
  /// 否则首包落地换卡时会横向跳一次。
  static let cardMarginH: CGFloat = 10
  static let cardMarginV: CGFloat = 4
  static let cardPadding: CGFloat = 16
  static let cardRadius: CGFloat = 16
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
  static let subPostDividerGap: CGFloat = 8
  /// 主贴回复工具栏（ThreadHeader.replyToolbar：paddingVertical 12×2 + 药丸 30）。
  static let toolbarHeight: CGFloat = 54

  static var nameFont: UIFont { TiebaSimpleText.font(size: 15, weight: .semibold) }
  static var nameFontMain: UIFont { TiebaSimpleText.font(size: 16, weight: .semibold) }
  /// 主贴卡标题（仅主贴行）：与已知主贴占位卡 knownTitle 逐项同尺（17pt/22pt/3 行），
  /// 首包落地换卡时标题原地接管，下面的作者行/正文不位移。
  static var titleFont: UIFont { TiebaSimpleText.font(size: 17, weight: .medium) }
  static let titleLineHeight: CGFloat = 22
  /// 标题**不限行**（0 = 不截断）：用户 2026-09-17 报"长标题被截断、显示不全"。
  /// 占位卡（TiebaThreadKnownPostView）的行数必须与这里一致，换卡才不跳。
  static let titleLineLimit = 0
  static var metaFont: UIFont { TiebaSimpleText.font(size: 12, weight: .regular) }
  static var badgeFont: UIFont { TiebaSimpleText.font(size: 11, weight: .bold) }
  static var lzFont: UIFont { TiebaSimpleText.font(size: 11, weight: .semibold) }
  static var actionFont: UIFont { TiebaSimpleText.font(size: 12, weight: .medium) }
  static var moreFont: UIFont { TiebaSimpleText.font(size: 13, weight: .semibold) }
  static var pillFont: UIFont { TiebaSimpleText.font(size: 13, weight: .semibold) }
  /// 排序药丸尾部那个向下箭头（点开 = 热门/正序/倒序三档菜单）。
  static var pillChevronConfig: UIImage.SymbolConfiguration {
    UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
  }
  /// 箭头占的宽度（10pt 字形 + 与标题的 4pt 间距）：药丸宽度要算上它。
  static let pillChevronWidth: CGFloat = 14
  static var subPostNameFont: UIFont { TiebaSimpleText.font(size: 14, weight: .semibold) }
  static var replyCountFont: UIFont { TiebaSimpleText.font(size: 15, weight: .semibold) }

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
    let time = TiebaPostTimeText.label(ms: post.createTimeMs, style: preferences.timestampStyle)
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

// MARK: - 时间文案（共享工具：相对/绝对两种风格一套实现）

/// JS utils relativeTime / absoluteTime 逐分支等价。
///
/// formatter 静态复用：本方法在后台测量队列与主线程都会被调（metaText 每次
/// publish 跑 400 楼，publish 又随每次点赞触发；旧实现每次调用都 alloc 一个
/// DateFormatter，连"刚刚"分支也建）。DateFormatter 自 iOS 7 起线程安全，且
/// dateFormat 只在构造时设定一次，运行期不再改。
enum TiebaPostTimeText {
  static func label(ms: Double, style: String) -> String {
    guard ms > 946_684_800_000 else { return "" }
    let date = Date(timeIntervalSince1970: ms / 1000)
    if style == "absolute" { return absoluteFormatter.string(from: date) }
    let diff = max(0, Date().timeIntervalSince1970 - ms / 1000)
    if diff < 60 { return "刚刚" }
    if diff < 3600 { return "\(Int(diff / 60))分钟前" }
    if diff < 86_400 { return "\(Int(diff / 3600))小时前" }
    if Calendar.current.isDateInYesterday(date) {
      return "昨天 \(clockFormatter.string(from: date))"
    }
    if diff < 7 * 86_400 { return "\(Int(diff / 86_400))天前" }
    return dayFormatter.string(from: date)
  }

  private static let absoluteFormatter = formatter("yyyy-MM-dd HH:mm")
  private static let clockFormatter = formatter("HH:mm")
  private static let dayFormatter = formatter("yyyy-MM-dd")

  /// 地区/历法固定，避免佛历等脏输出。
  private static func formatter(_ format: String) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.dateFormat = format
    return formatter
  }
}
