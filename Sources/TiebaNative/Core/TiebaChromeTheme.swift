import UIKit

/// 主题与状态栏配置：跟随应用内主题，而非系统外观。
/// Sendable：四个字段全是值类型（UIColor 在 iOS 26 SDK 里本身就是 Sendable），
/// 所以这里不需要 @unchecked Sendable —— 真 Sendable 就够跨隔离域传主题。
///
/// ── 为什么"当前主题"挂在这里，而不是 TiebaNavigator 上 ──
///   主题是**下层**普遍要读的数据：UI 控件、设置表单、骨架屏、行模型构造期取色都读它。
///   原来的读法是 `TiebaChromeTheme.current`（82 处），于是每个读者都反向依赖
///   App 层的导航器——UI 模块因此不可能独立成库。依赖倒置的做法是把**值**降到 Core：
///   主题类型与"当前主题"快照都住在这里，导航器只保留一个**写**入点（applyTheme）。
///
/// ── 并发 ──
///   读者既在主 actor（VC 装视图），也在后台测量队列（骨架屏/行模型的底色）⇒ 用
///   TiebaMutex 快照而不是 actor 隔离：读是加锁取值，跨隔离域直接可读。
public struct TiebaChromeTheme: Sendable {
  /// 底栏选中态 / 强调色（原 colors.primary）
  public var tint: UIColor
  /// 导航栏返回箭头与按钮色（原 headerTint：默认 colors.text，可被"工具栏
  /// 使用主色调"改成 primary）
  public var navTint: UIColor
  public var background: UIColor
  public var dark: Bool

  public static let `default` = TiebaChromeTheme(
    tint: .label,
    navTint: .label,
    background: .systemBackground,
    dark: false
  )

  /// 进程内唯一的"当前主题"。**写入点只有 TiebaNavigator.applyTheme(_:)** ——
  /// 单一数据源：改前是导航器持有一份 + 82 个读者绕道去问它。
  private static let box = TiebaMutex<TiebaChromeTheme>(.default)

  public static var current: TiebaChromeTheme {
    get { box.withLock { $0 } }
    set { box.withLock { $0 = newValue } }
  }
}
