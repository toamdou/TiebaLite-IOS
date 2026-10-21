// TiebaDesignSystem —— 视觉参数的**唯一真源**（圆角 / 字号 / 间距 / 层级 / 材质）
//
// ── 为什么需要这个文件 ──
//   改造前全仓有 19 种圆角、14 档字号、17 种间距、8 种蓝。每一处单独看都"能用"，
//   连起来看就是拼装感：参数不是从集合里取的，是每次实现时现编的。
//   设计规范如果不约束**基数**，只能产出"合规的丑"。
//
// ── 规矩（三条，违反即视为 bug）──
//   ① 圆角只许取 Radius.*（4 个）。禁止 `cornerRadius = 17` 这类字面量。
//   ② 字号只许取 Type.*（6 个）。禁止 `font(size: 21)`。
//   ③ 间距只许取 Space.*（6 个）。禁止 10 / 11 / 13 / 14 —— 它们不是网格值，是调参残留。
//
// ── 为什么是这几个数 ──
//   · 圆角：控件 6 / 小容器 10 / 卡片 14 / 胶囊。14 是"卡片"这个层级的唯一定义，
//     与页面边距 16 一起构成"间隙 ≥ 圆角"的呼吸比（改造前是 4pt 间隙配 20pt 圆角，
//     圆角是间隙的 5 倍，卡片会粘成气泡链）。
//   · 字号：直接对齐 HIG 的 caption2 / footnote / subhead / body / title2 / title1，
//     不发明新档位。14 与 15、17 与 18、27 与 28 在屏幕上不可分辨，留着只会让层级失效。
//   · 间距：4 的倍数网格，16 是页面边距（全屏唯一对齐线），其余是它的分数与倍数。
//
// ── 与既有类型的关系 ──
//   TiebaTypography 管的是**用户可调**的阅读字号（bodyScale / titleScale），
//   本文件管的是**设计师决定**的界面字号档位。两者不冲突：档位给出基准 pt，
//   TiebaTypography 的倍率在它之上缩放。但字号滑杆（12–24 / 14–34）建议删除，
//   只保留系统 Dynamic Type —— 详见 out/design-critique-2026-10-19.html §05。
//
// 并发：全是常量，无状态，天然 Sendable。

import UIKit

public nonisolated enum TiebaDesignSystem {

  // MARK: - 圆角

  /// 圆角四档。用 `Radius.card` 而不是 `14`。
  public enum Radius {
    /// 按钮、输入框、小徽章、标签。
    public static let control: CGFloat = 6
    /// 卡内小容器、图标底、引用块。
    public static let inset: CGFloat = 10
    /// 卡片、分组容器。**全仓卡片的唯一定义。**
    public static let card: CGFloat = 14
    /// 胶囊（用高度的一半，别写字面量）。
    public static func capsule(_ height: CGFloat) -> CGFloat { height / 2 }
  }

  // MARK: - 字号

  /// 界面字号六档（对齐 HIG Dynamic Type 的 Large 档）。
  /// 需要字重时配 `UIFont.Weight`，不要靠"再大 1pt"来强调。
  public enum Typography {
    /// caption2 · 11pt —— 徽章、极次要标注。
    public static let caption: CGFloat = 11
    /// footnote · 13pt —— 时间、IP 属地、计数、脚注。**元信息只能在这里。**
    public static let meta: CGFloat = 13
    /// subhead · 15pt —— 正文、摘要、列表副标题。
    public static let body: CGFloat = 15
    /// body/headline · 17pt —— 昵称、帖子标题、列表主标题。
    public static let title: CGFloat = 17
    /// title2 · 22pt —— 页面级标题（如主贴标题）。
    public static let heading: CGFloat = 22
    /// title1 · 28pt —— 大标题（设置页、我的页顶部）。
    public static let display: CGFloat = 28
  }

  /// 字重只有三档语义。`semibold` 是"强调"，`regular` 是"默认"，`medium` 是"可点"。
  public enum Weight {
    public static let regular = UIFont.Weight.regular
    public static let medium = UIFont.Weight.medium
    public static let semibold = UIFont.Weight.semibold
  }

  // MARK: - 间距

  /// 间距六档（4 的倍数）。页面边距恒为 `m`。
  public enum Space {
    public static let xxs: CGFloat = 2
    public static let xs: CGFloat = 4
    public static let s: CGFloat = 8
    /// 页面左右边距。全屏所有内容的左边线都从这条线起。
    public static let m: CGFloat = 16
    public static let l: CGFloat = 24
    public static let xl: CGFloat = 32
  }

  // MARK: - 层级（一屏最多三级）

  /// 文本层级的三档语义。一屏之内只用这三档，不许出现第四种"音量"。
  public enum Level {
    /// 主角：一屏只有一个。字号 title + semibold + label。
    case primary
    /// 正文：可读内容。字号 body + regular + label。
    case secondary
    /// 元信息：时间、来源、计数。字号 meta + regular + secondaryLabel。
    case tertiary

    public var size: CGFloat {
      switch self {
      case .primary: return Typography.title
      case .secondary: return Typography.body
      case .tertiary: return Typography.meta
      }
    }

    public var weight: UIFont.Weight {
      switch self {
      case .primary: return Weight.semibold
      case .secondary, .tertiary: return Weight.regular
      }
    }

    public var color: UIColor {
      switch self {
      case .primary, .secondary: return .label
      case .tertiary: return .secondaryLabel
      }
    }

    public func font(scaledFor textStyle: UIFont.TextStyle) -> UIFont {
      UIFontMetrics(forTextStyle: textStyle).scaledFont(
        for: .systemFont(ofSize: size, weight: weight))
    }
  }

  // MARK: - 表面

  /// 表面三档。**一屏最多用两种**：画布 + 一种承载面。
  public enum Surface {
    /// 页面画布。三个 tab 共用同一个值（改造前是 #F4F3FA / #F4F4F4 / #F3F2F7 三种）。
    public static let canvas = UIColor.systemGroupedBackground
    /// 承载面（卡片 / 分组容器）。纯色，**不用玻璃、不用渐变**。
    public static let raised = UIColor.secondarySystemGroupedBackground
    /// 卡内再下一层（引用块、代码块）。
    public static let sunken = UIColor.tertiarySystemGroupedBackground
  }

  // MARK: - 材质

  /// 材质分层：玻璃只属于功能层。
  ///
  /// HIG · Liquid Glass：玻璃只用于浮在内容之上的控件（导航栏、标签栏、工具栏、
  /// sheet、浮层）。**用在卡片、列表行、内容容器上是缺陷** —— 何况玻璃的语义是
  /// "折射身后的内容"，身后是纯色画布时它只剩半透明灰，观感即"脏"。
  public enum Material {
    /// 功能层（导航栏 / 标签栏 / 浮动操作条）：系统玻璃，交给 UIKit 自动处理。
    public static let functional = true
    /// 内容层（卡片 / 列表行 / 分组容器）：**永远是纯色**。
    public static let content = false
  }

  // MARK: - 几何

  /// 同心圆角：内圆角 = 外圆角 − 内边距。
  ///
  /// 这是"高级感"最容易被忽略的几何来源：20pt 的卡配 16pt 内边距时，
  /// 内层元素应该用 4pt 而不是随手一个 8pt。半径不连续，眼睛就读出"拼的"。
  /// （HIG · Toolbars：自定义控件必须与栏的圆角同心。iOS 26 起系统直接给了 API：
  ///  SwiftUI 是 `ConcentricRectangle`，UIKit 是 `UICornerConfiguration` —— 需要
  ///  跟随屏幕/父容器物理圆角时优先用系统 API，这个函数只用于纯数值推导。）
  public static func concentric(_ outer: CGFloat, inset: CGFloat) -> CGFloat {
    max(outer - inset, 0)
  }

  // MARK: - 自检 / lint 白名单

  /// 允许出现的圆角字面量（含 0 = 直角）。lint 脚本据此比对。
  public static let allowedRadii: Set<CGFloat> = [0, 6, 10, 14]

  /// 允许出现的字号字面量。lint 脚本据此比对。
  public static let allowedTypeSizes: Set<CGFloat> = [11, 13, 15, 17, 22, 28]

  /// 允许出现的间距字面量（含 0）。
  public static let allowedSpacings: Set<CGFloat> = [0, 2, 4, 8, 16, 24, 32]

  /// 调试期自检：返回 nil = 全过。约定同 TiebaTypography.selfCheck()。
  public static func selfCheck() -> String? {
    var failures: [String] = []
    func expect(_ ok: Bool, _ label: String) { if !ok { failures.append(label) } }

    expect(allowedRadii.count == 4, "圆角白名单不是 4 档")
    expect(allowedTypeSizes.count == 6, "字号白名单不是 6 档")
    expect(allowedSpacings.count == 7, "间距白名单不是 7 档（含 0）")

    // 同心：卡片 14 配 16 内边距时内层应为 0（不是负数）。
    expect(concentric(Radius.card, inset: Space.m) == 0, "同心圆角没有钳到 0")
    expect(concentric(Radius.card, inset: Space.xs) == 10, "同心圆角算错")

    // 层级：三级三档，不许两级同字号同字重。
    expect(Level.primary.size != Level.secondary.size, "主角与正文同字号")
    expect(Level.secondary.size != Level.tertiary.size, "正文与元信息同字号")

    return failures.isEmpty ? nil : failures.joined(separator: " / ")
  }
}
