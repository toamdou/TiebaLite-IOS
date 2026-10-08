// TiebaLite — CAAnimation 帧率对齐（TiebaAnimationFrameRate）
//
// 借鉴自上游（早期 vendored 的 Display 模块/Sources/Animation/CAAnimationUtils.swift
// 的 adjustFrameRate，约 17 行）：**做法**是"挂动画时顺手告诉系统这条动画
// 该跑多少帧"——`maximumFramesPerSecond > 61`（120Hz 档）才写
// `CAFrameRateRange(minimum: 30, maximum: 屏幕上限, preferred: 屏幕上限)`，纯 opacity
// 的淡入不写（省电）。只借这条判据，上游一行代码都没搬。
//
// 为什么值得借：本仓 `grep 'preferredFrameRateRange|maximumFramesPerSecond'` = 0 处。
// 我们只把 CAAnimation 交给渲染服务器插值，从不声明帧率 ⇒ 120Hz 设备上系统按默认档
// 调度：入场（220ms、几十行同时跑）、点赞弹簧这些**有位移/有缩放**的动画拿不到 120Hz。
// 反过来，无限循环的骨架扫光本可以被满帧跑（那是真费电，所以那里**不接**，见文件尾）。
//
// 与上游的两处差异，都是本仓既有纪律而非"顺手改"：
//   1. 屏幕从**视图**问（`view.window?.screen`），不读 `UIScreen.main`——后者自 iOS 26
//      废弃，多场景/外接屏下语义错误（本仓 11 处注释同一口径）。
//      代价：视图还没挂上窗口时问不到屏幕 ⇒ **不写**（返回 false），不猜。
//   2. `#available(iOS 15)` 闸门不需要（部署底线 iOS 26，见 BUILD.bazel minimum_os_version）。
//
// 上游另在 spring 路径硬写 `CAFrameRateRangeMake(80, 120, 120)`（CAAnimationUtils.swift）。
// 那条写死 120，且上游文件已随 早期 vendored 的 Display 模块 整目录删除（2026-10-05），上下文
// 无法再核对，故不照搬：本文件的 (30, 屏幕上限, 屏幕上限) 在 120Hz 设备上等价
//（preferred 就是屏幕上限），在 60Hz 设备上整体不写。
//
// 并发：只在主线程调用（读 UIView 窗口、写 CALayer 动画，与 TiebaEntrance 同一纪律）。
// 标 nonisolated 是为了让 TiebaEntrance.play 这种本身就 nonisolated 的动画入口能直接调：
// 标 @MainActor 会在那里变成"同步非隔离上下文调主 actor 方法"的**硬错误**（Swift 6 语言
// 模式，已实测），而本仓动画入口的既有写法是 nonisolated（见 TiebaEntrance）。

import QuartzCore
import UIKit

public nonisolated enum TiebaAnimationFrameRate {
  /// 提升档阈值：屏幕最大刷新率 **> 61** 才写（上游同值，CAAnimationUtils.swift）。
  /// 60Hz 设备写了没意义——它本来就是满帧。
  public static let promotionThreshold = 61

  /// 该视图所在屏幕的最大刷新率；**还不在任何窗口上时返回 0**（判不出，别当 60 用）。
  ///
  /// `assumeIsolated`：不满足"在主线程"就该 crash，而不是静默跨线程读 UIView 的窗口状态
  ///（本仓既有写法，见 TiebaPhotoBrowser）。拿不到视图可问的调用方走下面的
  /// 纯值入口——那条没有线程约束。
  nonisolated public static func maximumFramesPerSecond(of view: UIView) -> Int {
    MainActor.assumeIsolated { view.window?.screen.maximumFramesPerSecond ?? 0 }
  }

  /// 把动画对齐到该视图所在屏幕的帧率上限：120Hz 档写 `preferredFrameRateRange`，
  /// 其余情况（60Hz / 视图未上屏 / 纯淡入）什么都不做。
  ///
  /// 返回值 = 是否写了。**纯淡入不写**沿用上游的省电判据：opacity 逐帧看不出差别，
  /// 让它按默认档跑更省电。组动画按"**所有**子动画都是纯淡入"推广该判据——否则本仓的
  /// 入场组（opacity + transform.translation.y，TiebaEntrance）会被误判成
  /// 纯淡入而丢掉提升（上游只判顶层 CABasicAnimation，组必漏判）。
  ///
  /// 把"要 add 到 layer 上的那条"传进来（组就连组传，子动画会一起写，见 applyRange）。
  @discardableResult
  nonisolated public static func align(_ animation: CAAnimation, to view: UIView) -> Bool {
    align(animation, maximumFramesPerSecond: maximumFramesPerSecond(of: view))
  }

  /// 纯值入口：判据只有"屏幕最大刷新率"一个输入，不碰视图（层动画助手/单测用）。
  @discardableResult
  nonisolated public static func align(_ animation: CAAnimation, maximumFramesPerSecond maxFps: Int) -> Bool {
    guard maxFps > promotionThreshold else { return false }
    guard !isPureFade(animation) else { return false }
    let framesPerSecond = Float(maxFps)
    applyRange(
      CAFrameRateRange(minimum: 30, maximum: framesPerSecond, preferred: framesPerSecond),
      to: animation
    )
    return true
  }

  /// 写帧率区间（组动画连子动画一起写）。上游只写顶层那一条；组内子动画是各自独立的
  /// CAAnimation、各有该属性，写全两条路径只是把"调度看组还是看子"这个不确定项消掉
  /// ——属性本身只是提示，多写不改变行为。
  nonisolated private static func applyRange(_ range: CAFrameRateRange, to animation: CAAnimation) {
    animation.preferredFrameRateRange = range
    guard let group = animation as? CAAnimationGroup else { return }
    for child in group.animations ?? [] {
      applyRange(range, to: child)
    }
  }

  /// 纯淡入判定：上游只认顶层 `CABasicAnimation.keyPath == "opacity"`；组推广成
  /// "所有子动画都是纯淡入才算"（空组不算——没有可判的内容，宁可写）。
  nonisolated private static func isPureFade(_ animation: CAAnimation) -> Bool {
    if let group = animation as? CAAnimationGroup {
      let children = group.animations ?? []
      return !children.isEmpty && children.allSatisfy { isPureFade($0) }
    }
    guard let basic = animation as? CABasicAnimation else { return false }
    return basic.keyPath == "opacity"
  }

  // MARK: - 接线清单（判断"哪里有效"的依据；接新动画前先读这里）

  // 已接（都有位移/缩放，时长 220–280ms，120Hz 看得出差别）：
  //   1. TiebaEntrance.play —— 入场组 opacity + translateY，首屏几十行同时跑；
  //   2. tiebaPlaySpring —— 点赞 pop / 计数跳动两条弹簧（弹簧与手势驱动正是 ProMotion
  //      的主场；上游也对 spring 路径单独写过帧率，CAAnimationUtils.swift）；
  //   3. （原条目已删）折叠组动画此后改为 UIViewPropertyAnimator（frame + alpha），**没有**接 CA 帧率对齐
  //      —— 它不再产出 CAAnimation，align 无从下手。按本清单排查帧率覆盖面时，别把折叠当成"已对齐"。
  //
  // 判断"不该接"（各有理由，别"顺手"补）：
  //   - 骨架扫光（TiebaSkeletonView）：repeatCount = .infinity，整个加载期
  //     一直跑，且是键帧线性慢扫（1.6s 一轮）——提到 120Hz 只是把渲染服务器的采样翻倍，
  //     眼睛看不出，电却一直在耗（上游 DisplayLinkAnimator 自己也在按需降频省电）。
  //   - FAB 按压/回弹（TiebaForumViewController）：UIView.animate 不把
  //     CAAnimation 交出来，要对齐只能事后扫 layer.animationKeys() 去改 UIKit 的内部动画
  //     ——拿 0.12s 缩放的平滑度换一条脆接线，不值（它也没有长位移可看）。
  //   - 各处纯淡入（TiebaSplashController / TiebaNavigator / TiebaSignService /
  //     TiebaPhotoBrowser）：本 API 的
  //     省电判据本身就拒（isPureFade），而且它们同样是 UIView.animate，拿不到动画对象。
  //   - Hero 转场（TiebaHeroTransition.swift）：动画由 Hero 内部创建持有，外面够不着。
}
