// 进帖转场的 Hero 配对：信息流/吧页卡片 → 帖子页主贴卡（卡片与首图各配一对）。
// 只有"点卡片进帖"用 Hero，其余转场系统原生（见 TiebaNavigator.armHero）。
// id 由各自模型驱动 ⇒ 天然唯一、随 cell 复用自动更新，不需点击时打点/返回后清理。
import Hero
import UIKit

enum TiebaHeroTransition {
  /// 阻尼比 0.85：ζ = damping / (2√stiffness) ⇒ 24 / (2√200) = 0.849。
  private static let spring: HeroModifier = .spring(stiffness: 200, damping: 24)

  static func cardID(threadId: String) -> String? {
    threadId.isEmpty ? nil : "tieba-card-\(threadId)"
  }

  static func imageID(threadId: String) -> String? {
    threadId.isEmpty ? nil : "tieba-image-\(threadId)"
  }

  /// 卡片：源与目标共用。卡片是多层复合视图（圆角 + 自绘文字），按 Snapshot 文档
  /// 避开 useOptimizedSnapshot；cascade 让卡内块状子视图依次入场。
  static func mark(_ view: UIView?, threadId: String) {
    guard let view else { return }
    view.hero.id = cardID(threadId: threadId)
    view.hero.modifiers = [
      .useNormalSnapshot, spring, .cascade(delta: 0.02, direction: .topToBottom),
    ]
  }

  /// 首图：源与目标共用（嵌套配对无双影——Hero 取快照前会把参与视图 alpha 归零）。
  static func markImage(_ view: UIView?, threadId: String) {
    guard let view else { return }
    view.hero.id = imageID(threadId: threadId)
    view.hero.modifiers = [.useNormalSnapshot, spring]
  }

  /// 目标页压暗。必须同时给 overlay 与 beginWith：canAnimate 只认直接属性（不看
  /// beginState），只给 beginWith 不生效；只给 overlay 则变成"越转场越暗"。
  static func markBackdrop(_ view: UIView?) {
    guard let view else { return }
    let dim: HeroModifier = .overlay(color: .black, opacity: 0.06)
    view.hero.modifiers = [dim, .beginWith(modifiers: [dim])]
  }

  static func clear(_ view: UIView?) {
    view?.hero.id = nil
    view?.hero.modifiers = nil
  }
}
