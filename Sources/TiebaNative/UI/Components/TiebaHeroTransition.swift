// 帖子转场的 Hero 配对与观感（点卡片进帖 = 卡片滑入详情 + 首图飞行 + 子元素级联）。
//
// 配对契约：同一 threadId 派生的 id 打在**源视图**与**目标视图**上，Hero 自己把
// 源快照从列表位置移动/缩放到详情页位置（含圆角承接与内容交叉淡入）。
//   - 卡片级：信息流卡片 ↔ 帖子页主贴卡（占位卡 / 首包落地后的真实卡）
//   - 图片级：卡片首图 ↔ 详情页首图（单独飞，比整卡纯位移更有层次）
//   - 源：信息流行 / 帖行（各自 apply 时按自己的模型打 id，随 cell 复用自动更新）
//
// 为什么 id 由"每行自己的模型"决定，而不是"点击时临时打、返回后清"：
//   1. 天然唯一——不同帖子不同 id，多行共存不会撞车；临时打 id 要在返回后清理，
//      漏一处就会让旧行留住 id 与新目标配对（Hero 取遍历到的第一个匹配）；
//   2. 复用安全——cell 换行时 apply 会换成新行的 id，不需要额外钩子。
//
// 嵌套配对（卡片与卡内图片都配对）会不会双影：不会。Hero 在取任何快照之前先把
// **全部**参与动画的视图 alpha 置 0（HeroContext.hide），拍某张快照时才单独恢复
// 它自己（unhide(view:)），所以卡片快照里图片是空的、图片另拍一份单独飞——
// 这正是它支持父子同时配对的机制（见 HeroTransition.animate 的 hide 循环）。
//
// 没配对时（深链、收藏页进帖等没有源卡片的情况）Hero 自动退化成系统 push，
// 见 .auto 语义（源与目标的根视图都没有 heroID ⇒ 不做魔改）。
import Hero
import UIKit

enum TiebaHeroTransition {
  // MARK: - 观感常量

  /// 弹性阻尼：设计稿的 dampingRatio 0.85。
  /// 换算 ζ = damping / (2√stiffness)：stiffness 200 ⇒ damping = 0.85×2×√200 ≈ 24。
  private static let spring: HeroModifier = .spring(stiffness: 200, damping: 24)

  /// 子元素级联步长（秒）：卡片内块状子视图依次入场。
  /// 0.02 与原 JS 入场动画的 35ms 级联同量级但更紧——转场本身只有几百毫秒，
  /// 步长过大会让最后一个子元素在转场结束后才到位。
  private static let cascadeStep: TimeInterval = 0.02

  // MARK: - id

  /// 卡片级配对 id（整张卡片）。空 threadId → nil（不打 id，走系统 push）。
  static func cardID(threadId: String) -> String? {
    threadId.isEmpty ? nil : "tieba-thread-card-\(threadId)"
  }

  /// 首图配对 id（卡内第一张图单独飞行）。空 threadId → nil。
  static func imageID(threadId: String) -> String? {
    threadId.isEmpty ? nil : "tieba-thread-image-\(threadId)"
  }

  // MARK: - 打点（源与目标共用）

  /// 卡片。
  ///
  /// 快照类型按 Snapshot Types 文档选：信息流卡片是"圆角 + 自绘文字画布 + 多层子视图"
  /// 的复合视图，文档明确警告 useOptimizedSnapshot 对自定义/带遮罩视图可能出偏差，
  /// 所以用 useNormalSnapshot（snapshotView(afterScreenUpdates:)，最忠实）。
  /// 圆角由 Hero 从 layer 承接（HeroContext 会读 cornerRadius），不另加。
  ///
  /// `.cascade` 让卡片内的块状子元素（标题/作者/图片/操作栏）自顶向下依次入场，
  /// 比整卡整体移动更有层次（Modifiers 文档：cascade 用递增 delay 作用到子视图）。
  /// ⚠️ 弹簧与 duration 互斥（Hero 源码 spring 分支优先且自算时长），不写 .duration。
  static func mark(_ view: UIView?, threadId: String) {
    guard let view else { return }
    view.hero.id = cardID(threadId: threadId)
    view.hero.modifiers = [
      .useNormalSnapshot,
      spring,
      .cascade(delta: cascadeStep, direction: .topToBottom),
    ]
  }

  /// 首图：源与目标共用（目标侧无图时传 nil，等于取消配对）。
  static func markImage(_ view: UIView?, threadId: String) {
    guard let view else { return }
    view.hero.id = imageID(threadId: threadId)
    view.hero.modifiers = [
      .useNormalSnapshot,
      spring,
    ]
  }

  /// 清掉一个视图的配对（cell 复用换行时调用，避免旧 id 残留）。
  static func clear(_ view: UIView?) {
    view?.hero.id = nil
    view?.hero.modifiers = nil
  }

  /// 转场期背景压暗（目标页根视图用）：让被放大的卡片从背景里"浮"出来。
  ///
  /// ⚠️ 必须同时给 `.overlay`（直接属性）与 `.beginWith`：
  ///   - `canAnimate` 只认直接属性（position/size/opacity/overlay/…），**不看 beginState**；
  ///     只写 `.beginWith(.overlay)` 的话根视图根本进不了动画列表，压暗静默失效；
  ///   - 只写 `.overlay` 则是"从 0 渐变到 0.06"（转场结束时最深），不是"开场即压暗"。
  /// 两个一起给：overlay 让视图被选中，beginWith 把它的初始值直接设成目标值 ⇒
  /// 整个转场期间恒定压暗、结束时随快照一起消失。
  /// 强度 0.06：再深会与详情页自己的深色底叠加成灰块（本仓有深浅两套主题）。
  static func markBackdrop(_ view: UIView?) {
    guard let view else { return }
    let dim: HeroModifier = .overlay(color: .black, opacity: 0.06)
    view.hero.modifiers = [dim, .beginWith(modifiers: [dim])]
  }
}
