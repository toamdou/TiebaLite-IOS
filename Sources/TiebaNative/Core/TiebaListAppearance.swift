// TiebaListAppearance —— 列表外观档（卡片 / 扁平）
//
// 【用户口径 2026-10-08】参考推特（Twitter）的设计语言做**扁平档**：
//   · 亮色背景用**纯白**（原来是 systemGroupedBackground 的分组灰）；
//   · 行**通栏**（无左右边距、无圆角卡面），行间用 1 物理像素发际线分隔；
//   · 本轮只落在**关注页 / 帖子页**（帖子行族同源的楼中楼页一并跟随；楼中楼不画导引线）。
// 开关：设置 → 个性化 → 「设计风格」（偏好键 listAppearance，取值 card / flat）。
//
// ── 为什么要有"世代（generation）" ──
//   与 TiebaTypography 同一个理由：行几何（边距 / 圆角 / 底色）是**测量缓存键**的输入
//   ——全仓按「内容身份」（TiebaRowDiff 的行指纹）键控度量缓存。外观档一变，每一行的
//   几何都变，旧测量必须整体失配重测。把世代混进行指纹就得到结构性解法：不逐个缓存
//   去清（清漏一处就是静默旧档），而是让"换了外观档"直接等于"这一行是另一行内容"。
//
// ── 并发 ──
//   行模型在后台测量队列构造，每行都要问一次外观档 ⇒ 快照走 TiebaMutex 缓存，读零
//   SQLite。失效由 TiebaPreferenceSnapshot 的写入路径驱动（与字号同一处，顺序同款）。

import UIKit

nonisolated enum TiebaListAppearance {

  /// 偏好键（设置 → 个性化 → 设计风格）。
  static let key = "listAppearance"

  enum Style: String, Sendable, CaseIterable {
    /// 卡片档：分组灰底 + 圆角白卡 + 卡片间距（改造前的观感）。
    case card
    /// 扁平档：通栏 + 发际线 + 纯白底（推特语言）。
    case flat

    var title: String {
      switch self {
      case .card: return "卡片"
      case .flat: return "扁平"
      }
    }
  }

  /// 默认档。2026-10-08 用户要求关注页/帖子页扁平化 ⇒ 默认**扁平**；
  /// 想回退到改造前的观感，设置 → 个性化 → 设计风格 切「卡片」即可（无需改代码）。
  static let defaultStyle: Style = .flat

  private struct State {
    var style: Style?
    var generation: UInt64 = 0
  }

  private static let state = TiebaMutex<State>(State())

  // MARK: - 读

  /// 当前外观档（进程内缓存；偏好变更时由写入路径失效）。
  static func style() -> Style {
    if let cached = state.withLock({ $0.style }) { return cached }
    return reload()
  }

  static var isFlat: Bool { style() == .flat }

  /// 外观档世代：任何一次档位变化 +1。混进行指纹用（见文件头）。
  static var generation: UInt64 { _ = style(); return state.withLock { $0.generation } }

  /// 本体系的偏好键（TiebaPreferenceSnapshot 写盘后据此决定要不要刷快照）。
  static func isAppearanceKey(_ key: String) -> Bool { key == Self.key }

  /// 重新解析偏好并刷新缓存。偏好广播与设置页写盘后调用。
  @discardableResult
  static func reload() -> Style {
    let next = Style(rawValue: TiebaPreferenceSnapshot.string(key) ?? "") ?? defaultStyle
    state.withLock { state in
      guard state.style != next else { return }
      state.style = next
      state.generation &+= 1
    }
    return next
  }

  // MARK: - 几何 / 颜色
  //
  // 行族（TiebaPostRowPlan / TiebaPostRowView / TiebaPostRowLayout / 骨架卡 /
  // 已知主贴占位卡）**只读**这一组，不在绘制期加分支 —— 换档 = 换输入常量。

  /// 行左右的卡片边距（扁平 = 0，通栏）。
  static var cardMarginH: CGFloat { isFlat ? 0 : 10 }
  /// 行上下的卡片边距（扁平 = 0：行与行之间只靠发际线分隔）。
  static var cardMarginV: CGFloat { isFlat ? 0 : 4 }
  /// 行内容的内边距（两档一致：内容边距不变，变的只是"卡面"有没有）。
  static let cardPadding: CGFloat = 16
  /// 行底圆角（扁平 = 0）。
  static var cardRadius: CGFloat { isFlat ? 0 : 16 }

  /// 页面底色：扁平亮色 = systemBackground = **纯白**（用户明确"不要深灰"）；
  /// 深色/纯黑档由系统语义色与主题自动跟随，不在这里另开一套颜色。
  static var pageBackground: UIColor { isFlat ? .systemBackground : .systemGroupedBackground }

  /// 行间发际线：只有扁平档画（卡片档的行靠卡片间距分隔）。
  static var drawsRowHairline: Bool { isFlat }

  /// 行卡面底色：扁平档不画独立卡面 ⇒ 用页面底色；卡片档 = 主题给的卡色。
  static func rowSurface(card: UIColor) -> UIColor { isFlat ? pageBackground : card }

  /// 行卡面描边宽：扁平档不描边（没有卡面就没有轮廓）。
  static func rowBorderWidth(scale: CGFloat) -> CGFloat { isFlat ? 0 : 1 / max(scale, 1) }

  /// 楼中楼预览框底色：比页面底再深一档的填充（亮色 #F2F2F7；暗色用白色 7% 叠加，
  /// AMOLED 纯黑底上落成 #121212 一档，仍读得成"一块框"）。两档外观同色：框是
  /// 内嵌分区，不随卡片/扁平改变语义。
  static var subPostBoxBackground: UIColor {
    UIColor { trait in
      trait.userInterfaceStyle == .dark
        ? UIColor(white: 1, alpha: 0.07)
        : UIColor(red: 242 / 255, green: 242 / 255, blue: 247 / 255, alpha: 1)
    }
  }

  /// 行卡面描边色：扁平档无描边 ⇒ nil。
  static func rowBorderColor(card: UIColor) -> UIColor? { isFlat ? nil : card }

  /// 通用卡面圆角：扁平档一律 0（关注页的吧卡是 20，与帖子行的 16 不同源，
  /// 所以这里收的是"卡片档该是多少"，由调用方给）。
  static func surfaceRadius(_ card: CGFloat) -> CGFloat { isFlat ? 0 : card }
}
