// TiebaAnimation —— 全仓动画的**统一入口**（只换入口、不改数值）。
//
// 📚 学习价值：把「动画怎么写」收口到一处，是 UIKit 项目里最容易被忽视的架构问题。
//   散落的 `UIView.animate(withDuration:)` 本身没错，但它们让三件事无法统一：曲线语义、时长口径、
//   以及"将来要整体调节奏时改哪里"。统一入口的价值不在于现在少写几个字，而在于**改一处即全站生效**。
//
// 【边界 —— 必须遵守】
//   本入口**只覆盖**两种调用形态：
//     ① UIView.animate(withDuration:animations:)
//     ② UIView.animate(withDuration:delay:options:animations:completion:)
//   `usingSpringWithDamping:` 的弹簧版**一律保留原样**：它的观感由 damping 决定，
//   映射到任何 CAMediaTimingFunction 都会改变曲线 → 违反「不破坏当前 UI 显示效果」。
//
// 【为什么默认曲线是 .easeInOut】
//   `UIView.animate(withDuration:)` 的默认曲线就是 ease-in-out（UIKit 的文档与实测一致），
//   所以 `curve: .easeInOut` 是**零变化**的默认值 —— 既有的调用点换成入口后时长与曲线逐字保留。
//
// Swift 6：整件标 @MainActor —— `UIView.animate` 本身是主 actor 隔离的，入口若标 nonisolated，
// 把调用方的非 Sendable 闭包转发进去会报 sending 的区域隔离错误（实测）。标 @MainActor 后隔离域一致，零绕过。

import Foundation
import UIKit

/// 曲线语义名 → UIKit 现有控制点的一一映射（**只做映射，不新增曲线**）。
enum TiebaAnimationCurve {
    case easeInOut
    case easeIn
    case easeOut
    case linear

    /// 与 UIView.AnimationOptions 的曲线位一一对应；`.easeInOut` 对应空集 = UIKit 默认。
    var options: UIView.AnimationOptions {
        switch self {
            case .easeInOut: return []
            case .easeIn: return .curveEaseIn
            case .easeOut: return .curveEaseOut
            case .linear: return .curveLinear
        }
    }
}

/// 时长分层表（全 App 一份）。
///
/// 📚 学习价值：同一个 App 里「同样是切换」却各写各的时长，会让节奏显得廉价；把档位收成一张表，
///   调一次节奏就是改一个数字（这也是 TiebaAnimation 这个统一入口存在的理由）。
/// 语义分档：状态切换最轻（0.18–0.2）→ 浮层出现 0.25 → 消失 0.3 → 整块滑入 0.35–0.5；
/// 「有质量感」的动作一律走弹簧（见 TiebaContainedViewLayoutTransition.spring），不占这里的档位。
/// 只收录**现网已在用**的档位，数值与既有调用点逐字一致（引入它不改变任何观感）。
///
/// [按上游补档] 上游扫了 6996 处 duration 得到 11 档（报告 41 §1.3）。本表原先只收 ≥0.18 的 7 档，
/// 理由是"小于 0.18 的微动效会被误用成一次状态切换"。本轮按用户「动效参数按上游来」补两档，
/// **但只收有明确语义、且现网确实在用的那两个数**：
///   · 0.15（上游出现 388 次，289 次是 animateAlpha）—— **高亮/余韵的快档**；
///   · 0.12（上游 60 次，26 次是 animateAlpha）—— **微动效（按下反馈、换数）**。
/// 更小的 0.1 / 0.08（182 / 24 次）仍**刻意不收**：它们低到人眼只当"避免硬跳"，
/// 收进表里必然被拿去当"一次状态切换"用（原判断依然成立）。
/// 上游另外几档（0.45 图集转场 / 0.35 大面板 / 0.5 系统弹簧）本仓或已有同名档、或不在本表范围。
enum TiebaAnimationDuration {
    /// 高亮 / 余韵的快档：手指离开后"最后一下"的淡出、内容交接时的让位（上游 0.15 档）。
    ///
    /// 上游：`submodules/Display/Source/ContextGesture.swift` 一族的高亮消退；
    /// 本仓调用方：UI/Media/TiebaPhotoBrowserSession.swift:507（用户开始拖动关闭 → 页码点让位消失）。
    /// 手感：比 stateChange(0.18) 再快一点 —— 手指已经在动了，慢一档就会"跟不上手"。
    static let fastFade: TimeInterval = 0.15

    /// 微动效：**按下反馈**、换数（上游 0.12 档）。
    ///
    /// 上游：`submodules/Display/Source/ContextGesture.swift:77` 一族；
    /// 本仓调用方：UI/Nodes/TiebaTooltipController.swift:460（提示条换文案的交叉淡入）、
    /// Features/Forum/TiebaForumViewController.swift:1127（悬浮按钮按下缩到 0.85）。
    /// 手感：按下就"到位"——0.12 是"看得见但感觉不到时长"的那一档。
    static let microFeedback: TimeInterval = 0.12
    /// 状态切换（最轻的一档：图标/文字状态互换）。
    static let stateChange: TimeInterval = 0.18
    /// 点按反馈（chrome 显隐等「被手指直接触发」的淡入淡出）。
    static let tapFeedback: TimeInterval = 0.2
    /// 浮层出现（toast / 面板进场）。
    static let overlayAppear: TimeInterval = 0.25
    /// 浮层消失（比出现略久：退场要看得清）。
    static let overlayDismiss: TimeInterval = 0.3
    /// 整块滑入（跨屏位移的面板）。
    static let largeSlide: TimeInterval = 0.35
    /// 模态出现（action sheet / 大面板进场）。
    static let modalAppear: TimeInterval = 0.4
    /// 有质量的弹入（配合弹簧曲线的整块动作）。
    static let springMass: TimeInterval = 0.5
}

@MainActor
enum TiebaAnimation {
    /// 统一动画入口。签名与 `UIView.animate` 的同名标签保持兼容，因此调用点只需把
    /// `UIView.animate(withDuration:` 换成 `TiebaAnimation.animate(duration:` —— **数值一字不改**。
    static func animate(
        curve: TiebaAnimationCurve = .easeInOut,
        duration: TimeInterval,
        delay: TimeInterval = 0,
        options: UIView.AnimationOptions = [],
        animations: @escaping () -> Void,
        completion: ((Bool) -> Void)? = nil
    ) {
        UIView.animate(
            withDuration: duration,
            delay: delay,
            // 曲线位只在调用方没显式给曲线时补上：`.easeInOut` 是空集，所以默认路径与原来完全一致。
            options: options.union(curve.options),
            animations: animations,
            completion: completion
        )
    }
}
