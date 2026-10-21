// 从 TiebaFeedRowView.swift 拆出（H10 千行文件拆分）：主类之前的独立类型（整类型逐字搬运，仅下列声明放宽访问级）。
// 主类留在原文件：它的扩展要用到类内 private，同文件才合法。
// 后续按类型再拆（H10 续）：可访问元素 / 菜单钮 / 角标 / 媒体单元 / 操作栏 / 静态文字画布
// 已迁到 Motion/ 目录，本文件只留跨类型共用的辅助（取图、弹簧令牌、触觉 id、角标底色）。

import UIKit
import Nuke
import NukeExtensions


// 语义色板在 TiebaRowMetrics.swift 的 TiebaFeedRowPalette：默认值与本节旧
// 静态常量逐一相同，JS 经 TiebaListView 的 themeColors prop 下发实际主题
// （非默认主题的 primary/chip/onChip 由此生效；行视图不再是"只有默认蓝"）。

// MARK: - 行内图片加载（Nuke 共享管线）

/// 行内图片统一入口：Nuke 管线（Referer + 内存/磁盘缓存 + 同 URL 合并）按目标
/// 像素下采样（fit inside，长边 ≤ maxPixel）。复用/换行必须 cancelRequest(for:)
///（任务关联在视图上，取消后回调不再投递；重复 load 也会先取消旧任务）。
// 访问级 private → internal（H10 拆分，Lead 裁决 B）：主类 `TiebaFeedRowView` 也调它装图，
// 拆分后跨文件 private 不可见。本条不在最初清点的 8 处里 —— `@MainActor` 写在 `private` 前，首轮扫描漏了。
@MainActor func tiebaLoadRowImage(
  url: URL?,
  maxPixel: CGFloat,
  into imageView: UIImageView
) {
  loadImage(
    with: url.map { TiebaNuke.secureURL($0) },
    options: TiebaNuke.options(maxPixel: maxPixel, mode: .fit),
    into: imageView
  )
}

// MARK: - 弹簧动画工具（参数与 src/theme/springs.ts 逐值对齐）

/// 动画令牌（Reanimated 的 damping/stiffness/mass 与 CASpringAnimation 是同一
/// 套物理模型，可直接照搬；restDisplacement/restSpeed 默认 0.001 两处一致）。
/// 引用点：TweetCard LikeButton（pop / numPop）与 CollapseRow。
/// （EntranceRow 的时长/级联/位移已收进 TiebaEntrance，与其余三个行族共用一份。）
// 访问级 private → internal（H10 拆分，Lead 裁决 B）：nonisolated 被留在 TiebaFeedRowView.swift 的主类 TiebaFeedRowView 引用，
// 拆分后跨文件 private 不可见；只放宽这一处，其余成员访问级不动。
nonisolated enum TiebaFeedRowMotion {
  /// LikeButton pop：withSpring(1.35, {damping:12, stiffness:380, mass:0.6})
  static let likePop = TiebaSpringParams(mass: 0.6, stiffness: 380, damping: 12)
  /// MOMENTUM（松手/计数回落）：damping 16, stiffness 220, mass 1
  static let momentum = TiebaSpringParams(mass: 1, stiffness: 220, damping: 16)
  /// 计数跳动首段：withSpring(1.28, {damping:11, stiffness:320, mass:0.5})
  static let countBump = TiebaSpringParams(mass: 0.5, stiffness: 320, damping: 11)
  /// CollapseRow：280ms + EASE_OUT cubic-bezier(0.32,0.72,0,1)
  static let collapseDuration: CFTimeInterval = 0.28
  /// nonisolated(unsafe)：CAMediaTimingFunction 不是 Sendable，但它是 Core
  /// Animation 的**不可变值对象**——由控制点构造后没有任何 setter，Apple 自家
  /// 的 kCAMediaTimingFunctionEaseIn/EaseOut 就是进程级共享常量；这里只被本文件
  /// 主线程动画代码读取（group.timingFunction 赋值），跨线程只读安全。
  nonisolated(unsafe) static let easeOut = CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0, 1)
}

// 访问级 private → internal（H10 拆分，Lead 裁决 B）：放宽后的 `TiebaAnimatedProperty` 关联值、
// `tiebaPlaySpring(spring:)` 签名都用到它，类型泄漏检查要求它至少 internal。同属首轮清点遗漏。
struct TiebaSpringParams {
  let mass: CGFloat
  let stiffness: CGFloat
  let damping: CGFloat

  var settlingDuration: CFTimeInterval {
    let animation = CASpringAnimation()
    animation.mass = mass
    animation.stiffness = stiffness
    animation.damping = damping
    return animation.settlingDuration
  }
}

/// 可动画属性（CALayer 的 KVC 对 transform.scale 不完整，显式读写）。
/// 当前只服务点赞 pop/计数跳动的 scale 弹簧；接入新属性时在此扩展。
// 访问级 private → internal（H10 拆分，Lead 裁决 B）：enum 被留在 TiebaFeedRowView.swift 的主类 TiebaFeedRowView 引用，
// 拆分后跨文件 private 不可见；只放宽这一处，其余成员访问级不动。
enum TiebaAnimatedProperty {
  case scale

  var keyPath: String {
    switch self {
    case .scale: return "transform.scale"
    }
  }

  func apply(_ value: CGFloat, to layer: CALayer) {
    switch self {
    case .scale:
      layer.transform = CATransform3DMakeScale(value, value, 1)
    }
  }

  /// 呈现树当前值（打断在途弹簧时作为 from，避免跳变）。
  func current(of layer: CALayer) -> CGFloat {
    switch self {
    case .scale:
      return (layer.presentation() ?? layer).transform.m11
    }
  }
}

/// 弹簧播放：模型值立即写终值（动画结束不回跳），presentation 由
/// CASpringAnimation 从 from 推到 to；fillMode forwards + 保留到完成回调里移除，
/// 保证回调只触发一次（RN 的 withSequence 语义）。
///
/// @MainActor：CALayer 动画是主线程状态，而且下面 `DispatchQueue.main.async`
/// 的闭包被编译器按主 actor 闭包检查——非隔离函数里捕获 layer 会被判成
/// "把 layer 发送给主 actor"（SIL 区域隔离报 sending 'layer'）。所有调用点都在
/// @MainActor 的 TiebaFeedRowView 内，标 @MainActor 后捕获与闭包同域，不需要
/// 也没有发生任何跨域发送。
///
/// `host` 只服务帧率对齐（TiebaAnimationFrameRate）：动画挂在 host 子树的层上，而屏幕
/// 只能从视图问，所以由调用方把宿主传进来，不在这里顺着 superlayer 猜（pop 层是
/// action item 自带的层，delegate 不一定是本行）。
@MainActor
// 访问级 private → internal（H10 拆分，Lead 裁决 B）：func 被留在 TiebaFeedRowView.swift 的主类 TiebaFeedRowView 引用，
// 拆分后跨文件 private 不可见；只放宽这一处，其余成员访问级不动。
func tiebaPlaySpring(
  on layer: CALayer,
  host: UIView,
  property: TiebaAnimatedProperty,
  from: CGFloat,
  to: CGFloat,
  spring: TiebaSpringParams,
  key: String,
  completion: (() -> Void)? = nil
) {
  // 顺序要紧：`removeAnimation` 之后 `animation(forKey:)` 就是 nil，所以先判再摘。
  let isInterrupting = layer.animation(forKey: key) != nil
  layer.removeAnimation(forKey: key)
  // 03-08 全仓清扫：同键动画还在跑时，from 必须取**展示层当前值**，不能用来参里的 from。
  //
  // 这个文件里其实早就写好了这条判据（`TiebaAnimatedProperty.current(of:)`，注释就是
  // "打断在途弹簧时作为 from，避免跳变"），但本函数一直没用它 —— 同一个文件里两套写法，
  // 于是连点两次点赞：第一次弹簧跑到 0.96 时被 remove，第二次又从 0.86 起跳，
  // 屏幕上表现为"缩回去再弹一遍"。改成中断即接力后，连点是连续回弹。
  let effectiveFrom: CGFloat
  if isInterrupting {
    effectiveFrom = property.current(of: layer)
  } else {
    effectiveFrom = from
  }
  let animation = CASpringAnimation(keyPath: property.keyPath)
  animation.mass = spring.mass
  animation.stiffness = spring.stiffness
  animation.damping = spring.damping
  animation.fromValue = effectiveFrom
  animation.toValue = to
  animation.duration = animation.settlingDuration
  animation.fillMode = .forwards
  animation.isRemovedOnCompletion = false
  // 帧率对齐：弹簧/缩放是 ProMotion 主场（有运动、可感知），屏幕从宿主视图问。
  TiebaAnimationFrameRate.align(animation, to: host)
  property.apply(to, to: layer)
  if let completion {
    CATransaction.begin()
    CATransaction.setCompletionBlock {
      layer.removeAnimation(forKey: key)
      completion()
    }
    layer.add(animation, forKey: key)
    CATransaction.commit()
  } else {
    layer.add(animation, forKey: key)
    DispatchQueue.main.async { [weak layer] in
      layer?.removeAnimation(forKey: key)
    }
  }
}

// MARK: - 行内触觉

/// 行内触觉全部走全仓唯一的场景表 / 播放器（TiebaSceneHaptics / TiebaHaptics）：
/// 行内不再自建 CHHapticEngine（否则设置页的「长按弹出大图 / 点赞蓄力」档位失效）。
/// 点赞蓄力的播放器 id 与设置页 hapticsRealtimeStyles 的键同名。
// 访问级 private → internal（H10 拆分，Lead 裁决 B）：enum 被留在 TiebaFeedRowView.swift 的主类 TiebaFeedRowView 引用，
// 拆分后跨文件 private 不可见；只放宽这一处，其余成员访问级不动。
enum TiebaFeedRowHapticIds {
  /// 点赞蓄力连续播放器（hapticsRealtime.ts 的 likeCharge；档位读 hapticsRealtimeStyles）。
  static let likeCharge = "likeCharge"
  /// JS CHARGE_INTENSITY / CHARGE_SHARPNESS。
  static let chargeIntensity = 0.3
  static let chargeSharpness = 0.25
}

// MARK: - 深色小角标（长图 / GIF / 计数）

/// 角标底色常量：RN 侧 MediaPager 的 rgba(0,0,0,0.55) 与 11pt semibold 白字，
/// 明暗主题同值（不随主题 token 走）。
/// 共用方：Motion/TiebaFeedRowBadgeView.swift（角标底色）与 TiebaFeedRowView（信息流计数条）。
// 访问级 private → internal（H10 拆分，Lead 裁决 B）：let 被留在 TiebaFeedRowView.swift 的主类 TiebaFeedRowView 引用，
// 拆分后跨文件 private 不可见；只放宽这一处，其余成员访问级不动。
let tiebaBadgeBackground = UIColor.black.withAlphaComponent(0.55)
