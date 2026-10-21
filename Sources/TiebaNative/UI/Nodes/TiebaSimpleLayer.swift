// TiebaLite — 逐帧属性图层的公共基类（TiebaSimpleLayer）
//
// 📚 学习价值（03-12）：CALayer 的属性写入默认带 0.25s 隐式补间。逐帧动画的层
//   （粒子、骨架骨块、扫描高光）每帧写 position/bounds/opacity，如果不关隐式动作，
//   每一帧都会各自生成一条补间动画 —— 帧与帧互相叠加，观感是"糊"而不是"动"。
//
// 过去本仓的写法是**调用方自觉**包一层：
//     CATransaction.begin()
//     CATransaction.setDisableActions(true)
//     … 逐帧写属性 …
//     CATransaction.commit()
// 这个约定有三个问题：
//   ① 漏包一次就产生一次抖动，而且很难在 review 里看出来；
//   ② 事务是**线程级**的，包大一点会顺带压掉无关层的动画；
//   ③ 每个调用点都要重复一遍，新代码天然不会写。
//
// 收口到基类后：`action(forKey:)` 一律返回 `NSNull()`（= 显式"没有动作"），
// 该层上的隐式动画从根上关掉，调用方不必再包事务。子类要动画必须**显式** `add(_:forKey:)`
// —— 这正是我们想要的默认：隐式动画应当是例外，不是常态。
//
// 顺带拿到生命周期钩子：`kCAOnOrderIn` / `kCAOnOrderOut` 是 Core Animation 在层
// 进出渲染树时查询的两个特殊 key。默认实现返回 nil（无动作），我们在这里塞一个
// 只执行回调的 action —— 于是「上屏才跑」「离屏就停」有了统一落点，
// 不用每个特效各自监听 window / superview 变化。

import QuartzCore

/// 逐帧写属性的图层基类：隐式动画全关，附带进出层级的生命周期钩子。
///
/// 用法：
/// ```swift
/// final class ScanLayer: TiebaSimpleLayer {
///   override init() {
///     super.init()
///     onOrderIn = { [weak self] in self?.startTicking() }
///     onOrderOut = { [weak self] in self?.stopTicking() }
///   }
/// }
/// ```
/// 子类**不要**再依赖隐式动画；要动画请显式 `add(_:forKey:)`。
open class TiebaSimpleLayer: CALayer {
  /// 层被加入渲染树（`kCAOnOrderIn`）。此时 `superlayer` 已就位，可以读几何。
  public var onOrderIn: (() -> Void)?

  /// 层被移出渲染树（`kCAOnOrderOut`）。用来停显示链路、释放昂贵资源。
  public var onOrderOut: (() -> Void)?

  open override func action(forKey event: String) -> CAAction? {
    switch event {
    case kCAOnOrderIn:
      guard let onOrderIn else { return nil }
      return TiebaLayerLifecycleAction(handler: onOrderIn)
    case kCAOnOrderOut:
      guard let onOrderOut else { return nil }
      return TiebaLayerLifecycleAction(handler: onOrderOut)
    default:
      // 显式「没有动作」：`NSNull()` 是 CA 认可的哨兵，比返回 nil（= 交给默认查找）
      // 更彻底 —— nil 会让 CA 继续往上找 superlayer / delegate，最终仍可能拿到补间。
      return NSNull()
    }
  }
}

/// 只执行一个回调的 CAAction。
///
/// `CAAction.run(forKey:object:arguments:)` 是 `@objc` 协议方法，由 CA 在渲染树变更时
/// 同步调用（主线程）。这里不持有任何跨隔离状态，回调本身由调用方保证主线程语义。
private final class TiebaLayerLifecycleAction: NSObject, CAAction {
  private let handler: () -> Void

  init(handler: @escaping () -> Void) {
    self.handler = handler
  }

  func run(forKey event: String, object anObject: Any, arguments dict: [AnyHashable: Any]?) {
    handler()
  }
}
