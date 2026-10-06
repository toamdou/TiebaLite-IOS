// ============================================================
// TiebaMotionSpec —— 全仓「手感参数」总表（弹簧 / 滑动 / 手势阈值）
//
// 📚 与 TiebaAnimationDuration 的分工（两份合起来才是完整的手感手册）：
//   · TiebaAnimationDuration（UI/Transition/TiebaAnimation.swift）管**时长档位**：
//     0.12 / 0.15 / 0.18 / 0.2 / 0.25 / 0.3 / 0.35 / 0.4 / 0.5；
//   · 本表管**物理量与阈值**：弹簧四参数、减速率、起手延时、转场判据 —— 这些数字动一点，手感就换一种，
//     而时长表只管"多久走完"。
//
// 每个成员写三段：**值 / 上游出处 file:line / 手感（改了会怎样）**，外加一行「调用方」。
// 本表是**唯一取值来源**：调用点不许再写裸数字（除 Vendor 注入的旋钮，见下）。
// 历史：第一版只做「命名 + 出处 + 教学」（数值逐字不变）。本轮按用户「动效参数按上游来」
// 的批示，把表里**上游更优**的条目改成了上游值，并逐个接到真实调用点。
//
// 📚 弹簧入门（读表前先看这一条）：CASpringAnimation 的四个参数里，真正决定手感的是**阻尼比**
//   ζ = damping / (2·√(stiffness·mass))，以及**固有频率** ω0 = √(stiffness/mass)（越大越快）。
//   ζ < 1 欠阻尼 → 越过终点再弹回来（"弹"）；ζ ≈ 1 临界 → 刚好不过冲；ζ > 1 过阻尼 → 稳但"重"。
//   mass 只按 √ 影响 ω0，却线性影响 ζ —— 所以"调大 mass"= 更慢 + 更不弹，是最钝的一把旋钮。
//
// 【按上游调参：哪些已落地、哪些本仓无场景】
//   已落地（每个都有生产消费者，见各成员注释末尾的「调用方」）：
//     · iOS 26 系统弹簧 1 / 555.027 / 47.118（UIKitUtils.m:70-72）—— 引擎的 .spring 曲线 + 查看器 chrome；
//     · 系统签名时长 0.3832（CAAnimationUtils.swift:120-121 等三处互证）—— .spring 请求的特判；
//     · 弹簧阻尼 88 通用回弹（CAAnimationUtils.swift:312, 338-340）—— 文本选择手柄；
//     · 弹簧阻尼 124 带初速的关闭（ResizableSheetComponent.swift:641 等）—— 查看器拖拽收尾；
//     · 交互式转场完成判据 速度 > 1000 或进度 > 0.2（NavigationContainer.swift:285）
//       与速度驱动收尾时长 clamp(0.05…0.2, |距离/速度|)（NavigationTransitionCoordinator.swift:333）
//       —— 查看器下拉关闭（Vendor/JXPhotoBrowser 的判据与收尾，值由本表注入）；
//     · 滚动方向翻转阈值 14.0（ListView.swift:1024）—— 帖子页浮条 / 吧页悬浮按钮的显隐；
//     · 左缘让位 8pt、方向锁定 2 / 4pt、拖动取消容差（ContextGesture / DirectionalPanGesture）。
//   本仓无场景（**不写成常量**，只在此记档，理由见报告 43 的「无场景清单」）：
//     · rubber-band 系数 0.4（ListViewAnimation.swift:232-235）—— 越界由系统 UIScrollView 承担；
//     · 越界回调 48.0（ListView.swift:903）—— 下拉刷新走系统 UIRefreshControl；
//     · 吸顶头连续因子 clamp(距离/头高)（ListView.swift:3996-4017）—— 页级 reload 架构下无吸顶头；
//     · 遮罩 (1−p)·0.15 / 阴影 (1−p)·0.9 / 后层 (p−1)·w·0.3（NavigationTransitionCoordinator.swift:161,175-176）
//       —— 本仓 push/pop 由系统 + Hero 承担，没有"自绘 + 进度映射"的转场宿主；
//     · sheet 展开分母 100pt（ResizableSheetComponent.swift:586-587）—— 系统 UISheetPresentationController；
//     · 弹簧阻尼 180 大面板 / 图集转场（GalleryControllerNode.swift:462）—— 图集转场在 Vendor 的
//       UIView.animate 动画体里，改 CASpringAnimation 要重写 vendor 动画体。
//   · 自研惯性：decelerationRate 0.998、初速 ×15、|v| < 0.1 停表（ListView.swift:941-967）。
// ============================================================

import Foundation
import UIKit

enum TiebaMotionSpec {
    /// 弹簧（上游 CASpringAnimation 同一套 mass / stiffness / damping / initialVelocity 语义）。
    ///
    /// 返回值直接用引擎的 `spring(mass:stiffness:damping:initialVelocity:)` 工厂：它会把 duration 设成
    /// **这颗弹簧自己的 settlingDuration**，于是引擎按 `settlingDuration/duration` 归一化后的速度系数恰好是 1
    /// —— 也就是"和裸 CASpringAnimation 逐帧一样"。随便传一个时长会让整段弹簧变快或变慢。
    @MainActor
    enum Spring {
        // MARK: iOS 26 系统弹簧（唯一一套"系统曲线"参数）

        /// 上游 iOS 26 起 `makeSpringAnimation` / `make26SpringAnimationImpl` 的固定三参数。
        ///
        /// 上游：`submodules/UIKitRuntimeUtils/Source/UIKitRuntimeUtils/UIKitUtils.m:70-72`
        /// （iOS 26 分支；iOS 26 之前是 :59-62 的 3 / 1000 / 500）。
        ///
        /// 手感：ζ = damping / (2·√(stiffness·mass)) = **1.000 恰好临界阻尼**，ω0 = 23.56。
        /// —— 起步很快、末尾收得干净，**完全不过冲**：这就是 iOS 26 系统那条"顺滑但不弹"的曲线。
        /// 与旧档 3/1000/500（ζ = 4.564，重过阻尼）相比：旧档是"稳稳落座"，这颗是"轻快落座"，
        /// 同一段位移下前 1/3 就走掉大部分行程。
        /// 改了会怎样：把 damping 调小立刻开始过冲（面板会和背后的遮罩错开一帧，像"没贴住"）；
        /// 把 stiffness 调小则整体变慢变"绵"。
        /// 调用方：① UI/Transition/TiebaTransitionSupport.swift 的 `springValue`（引擎 .spring 曲线解析解）；
        /// ② UI/Components/TiebaCAAnimationUtils.swift 的 `tiebaMake26SpringAnimation`（CA 弹簧工厂）。
        /// nonisolated：消费者（引擎的曲线求解器、CALayer 动画工厂）都在 nonisolated 上下文里；
        /// 三个都是不可变 Sendable 值，跨 actor 只读安全，不需要任何绕过标注。
        nonisolated static let ios26Mass: CGFloat = 1.0
        nonisolated static let ios26Stiffness: CGFloat = 555.027
        nonisolated static let ios26Damping: CGFloat = 47.118

        /// 面板 / 提示条**进场**：mass 1、stiffness 555.027、damping 47.118（= 上面那颗 iOS 26 系统弹簧）。
        ///
        /// 上游：`UIKitUtils.m:70-72`。**改前是 3 / 1000 / 500（iOS 26 之前那一档）**，本轮按用户
        /// 「动效参数按上游来」的批示换成 iOS 26 当前实现。
        ///
        /// 手感变化（相比改前的 ζ = 4.564）：**略微更"活"** —— 同一段位移前 1/3 走得更快、
        /// 收尾更利落；因为 ζ 恰好 = 1.000，仍然一点都不过冲，不存在"面板弹一下"的风险。
        /// 调用方：与引擎的 .spring 曲线同源（本函数是"显式传参"那条通道，给不走 curve 的调用点用）。
        static func systemPanel(initialVelocity: CGFloat = 0.0) -> TiebaContainedViewLayoutTransition {
            TiebaContainedViewLayoutTransition.spring(mass: ios26Mass, stiffness: ios26Stiffness, damping: ios26Damping, initialVelocity: initialVelocity)
        }

        /// 阻尼三档（上游把"弹不弹"收成三个数，mass / stiffness 在关闭与图集场景固定 5 / 900）：
        ///   · 88 —— **通用回弹**：`CAAnimationUtils.swift:312, 338-340` 的 `animateSpring` 默认值，ζ = 0.656；
        ///   · 124 —— **带初速的关闭**：`ResizableSheetComponent.swift:641`（sheet 拖拽关闭）、
        ///     `NavigationController.swift:1715`（最小化转场），ζ = 0.924；
        ///   · 180 —— **大面板 / 图集转场**：`GalleryControllerNode.swift:462`，ζ = 1.342（回弹消失，"被吸走"）。
        /// 为什么是三个数而不是连续可调：同一种"收势"全仓一个值，用户在不同面板上感到的**阻尼手感才一致**。
        /// 调用方（裸值通道）：UI/Text/TiebaTextSelectionNode.swift 的手柄弹出（88）。
        static let bounceDamping: CGFloat = 88.0
        static let closeDamping: CGFloat = 124.0
        /// 关闭档的 mass / stiffness（上游 :88-89 固定 5 / 900，只有 damping 分档）。
        static let closeMass: CGFloat = 5.0
        static let closeStiffness: CGFloat = 900.0

        /// 面板**退场**（用户甩下来，带松手速度）：mass 5、stiffness 900、damping 124。
        ///
        /// 上游：`submodules/Display/Source/Navigation/NavigationController.swift:1715`
        /// （最小化转场同参）、`submodules/Components/ResizableSheetComponent/Sources/ResizableSheetComponent.swift:641`（sheet 拖拽关闭同参）。
        ///
        /// 手感：ζ ≈ 0.92 —— **刚好欠阻尼**，收尾时一次极轻的回弹；这正是"甩下去"该有的收势。
        /// initialVelocity 用归一化后的松手速度（本仓 TiebaSheetDismissalPolicy.springInitialVelocity，上界 8.0，
        /// 上游 MinimizedContainer.swift:729 的 `min(8.0, abs(velocity/distance))`）：推得越快，关得越干脆。
        /// 改了会怎样：damping 升到 180 回弹消失（变成"被吸走"）；降到 88 会明显弹两下。
        /// 调用方：查看器下拉关闭的**松手收尾**（Vendor/JXPhotoBrowser 的拖拽手势，值由
        /// UI/Media/TiebaPhotoBrowserCells.swift 从本表注入 —— Vendor 不能反向依赖本模块）。
        static func sheetDismiss(initialVelocity: CGFloat = 0.0) -> TiebaContainedViewLayoutTransition {
            TiebaContainedViewLayoutTransition.spring(mass: closeMass, stiffness: closeStiffness, damping: closeDamping, initialVelocity: initialVelocity)
        }

        /// **系统签名时长 0.3832s** —— iOS 26 系统级转场（键盘收起 / 系统 sheet）的时长。
        ///
        /// 上游三处互证：`Display/Source/CAAnimationUtils.swift:120-121`（特判这个数就改用 iOS 26 弹簧）、
        /// `Display/Source/WindowContent.swift:1381-1388`、`UIKitRuntimeUtils/.../UIViewController+Navigation.m:254`
        /// （导航栏插件也认这个数）。
        ///
        /// 手感：凡是"要和系统动画同拍"的地方，用别的时长都会有一帧的错位感 —— 系统那条曲线已经在跑了，
        /// 我们只是搭上同一班车。0.3832 就是这班车的发车时刻。
        /// 调用方：UI/Components/TiebaCAAnimationUtils.swift:189（duration 落在这个数上 → 换 iOS 26 弹簧）。
        nonisolated static let signatureDuration: TimeInterval = 0.3832
    }

    /// 滑动 / 滚动。
    enum Scroll {
        /// 系统惯性减速率：`UIScrollView.DecelerationRate.normal` == **0.998**（每毫秒把速度乘 0.998）。
        ///
        /// 上游：`submodules/Display/Source/ListView.swift:941` 把这个数显式写出来做自研惯性
        /// （`v·15·0.998^(1000t)`，|v| < 0.1 停表，:948/:967）。这里的 0.998 就是系统默认档，不是自造值。
        ///
        /// 手感：0.998 → 松手后滑行"长而稳"；0.99（≈系统 .fast）会明显发黏、大约只滑一半距离。
        /// 本仓：行内横滑带（TiebaFeedRowView:329）用系统默认；页级列表交给 UICollectionView 的系统惯性。
        @MainActor
        static let systemDecelerationRate: UIScrollView.DecelerationRate = .normal

        /// 滚动方向翻转阈值：累积同向 ΔY **超过 14.0pt** 才认作"用户换方向了"。
        ///
        /// 上游：`submodules/Display/Source/ListView.swift:1023-1029`（`generalAccumulatedDeltaY`：
        /// 逐帧累加带符号的 ΔY，越过 ±14.0 才翻转方向判定，然后**清零**重新累）。
        ///
        /// 手感：小 → 手指抖一下就翻（栏/浮条乱闪）；大 → 迟钝。
        /// 14pt 是"人确实回了一下手"的最小位移 —— 它比单帧位移大得多，所以**天然滤掉抖动**，
        /// 这正是它必须"累加"而不是"看瞬时速度"的原因。
        /// 调用方：UI/Gestures/TiebaScrollDirectionGate.swift（帖子页浮条 / 吧页悬浮按钮的显隐）。
        static let directionFlipThreshold: CGFloat = 14.0
    }

    /// 手势阈值（长度单位 pt，时长单位 s）。
    enum Gesture {
        /// 长按起手延时：**0.12s**。
        ///
        /// 上游：`submodules/Display/Source/ContextGesture.swift:77` 的 `beginDelay`。
        ///
        /// 手感：比系统长按（0.5s）短得多 —— 因为菜单**不是到点就弹**：0.12s 之后还要再走
        /// `longPressActivation`(0.2s) 把进度推到 1，合计约 0.32s。既让"轻点"来得及取消，又不至于像系统菜单那样"要等"。
        /// 改了会怎样：调大 → 更像系统长按、更"钝"；调到 0.2 以上，连续进度的"长出来"就来不及看清。
        static let longPressBeginDelay: TimeInterval = 0.12

        /// 长按激活 / 取消的补间时长：**0.2s**。
        ///
        /// 上游：`ContextGesture.swift:143`（进度 0→1 的 `DisplayLinkAnimator(duration: 0.2)`）
        /// 与 `ContextControllerSourceNode` 抬手时"0.2s easeOut 补回恒等" —— **同值、两个角色**。
        ///
        /// 手感：进度在 0.2s 内连续推到 1，所以预览是"长出来"而不是"跳出来"；抬手也是 0.2s 缩回去。
        /// 改了会怎样：调大 → 更"绵"但菜单响应显得慢；调小 → 变成布尔跳变，失去连续进度的意义。
        static let longPressActivation: TimeInterval = 0.2

        /// 屏幕**左缘让位**宽度：落点在 x < 8.0 的长按一律失败，把这一段留给系统返回手势。
        ///
        /// 上游：`submodules/Display/Source/ContextGesture.swift:131`。
        ///
        /// 手感：小 → 左边缘长按会同时触发"返回上一页"和上下文菜单（两个动作抢一次触摸）；
        /// 大 → 左边缘一条长按不出菜单。8pt 与系统返回手势自己的起手区等宽。
        /// 调用方：UI/Context/TiebaContextGesture.swift:197。
        static let leftEdgeReserved: CGFloat = 8.0

        /// **方向锁定**（手势先验证方向再上报）：主轴 2pt 起步、交叉轴 4pt 否决。
        ///
        /// 上游：`DirectionalPanGesture/DirectionalPanGestureRecognizer.swift:55-69`（横向分支）：
        ///   · 交叉轴 `|y| > 4.0 且 |y| > 2|x|` → **失败**（这是竖向滚，别抢）；
        ///   · 主轴 `|x| > 2.0 且 2|y| < |x|` → **成立**（这是横向拖，接管）。
        /// 两个条件都要求"主轴至少是交叉轴的 2 倍" —— 45° 附近上下不确定时宁可失败。
        /// 手感：这正是"横滑带不误触竖滚"的关键；只看速度比大小（改前的写法）在斜向拖时会两边抢。
        /// 调用方：UI/ListKit/TiebaPostRowInline.swift:909-913（语音条的横向拖动定位）。
        static let directionLockAxisThreshold: CGFloat = 2.0
        static let directionLockCrossThreshold: CGFloat = 4.0
    }

    /// 交互式转场的**松手判据与收尾**（手指拖到哪、松手后走不走完）。
    enum Transition {
        /// 松手速度门槛：**> 1000 pt/s** 就算"甩出去"，直接走完。
        ///
        /// 上游：`Display/Source/Navigation/NavigationContainer.swift:285`（`velocity > 1000 || progress > 0.2`）；
        /// 模态同参 `Navigation/NavigationModalContainer.swift:185`。
        ///
        /// 手感：调小 → 轻轻一推就走完（回不去了）；调大 → 得用力甩。
        /// 调用方：Vendor/JXPhotoBrowser 下拉关闭（经 UI/Media/TiebaPhotoBrowserCells.swift 注入）。
        static let dismissVelocityThreshold: CGFloat = 1000.0

        /// 进度门槛：**> 0.2** 也算走完（哪怕几乎没速度）。
        ///
        /// 上游：同上 `NavigationContainer.swift:285`。这个门槛很**激进** —— 只拖 1/5 也会走完，
        /// 代价是更容易误返回；上游的取舍是"用户一旦开始拖，多半就是想走"。
        /// 手感：调小 → 拖一点点就回不去；调大 → 要拖过半才认。
        static let dismissProgressThreshold: CGFloat = 0.2

        /// 速度驱动的收尾时长：`clamp(0.05 … 0.2, |距离 / 速度|)` + easeInOut。
        ///
        /// 上游：`Display/Source/NavigationTransitionCoordinator.swift:333`
        /// （`abs(distance/velocity)` 夹在 0.05…0.2；:328-331 无速度时才退回 `0.5 + .spring`）。
        ///
        /// 手感：**手速决定动画时长** —— 甩得越快，补完得越快；固定时长是"程序化"的手感，
        /// 这个才是"接手你的动量"。这也是全表里手感最高级的一处差距。
        /// 调用方：同 dismissVelocityThreshold。
        static let settleMinDuration: TimeInterval = 0.05
        static let settleMaxDuration: TimeInterval = 0.2
    }
}
