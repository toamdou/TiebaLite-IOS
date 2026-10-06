// TiebaFlightTransition —— 「源被吸入目标」的飞行体转场（报告 37 B3/B4/B5/B6 一体落地）。
//
// 移植自上游：
//   · ChatMessageTransitionNode.swift:91-172（全屏穿透覆盖容器、hitTest 恒 nil、0.3s）、
//     :396-457（飞行体 + portal 双 alpha 交接）、:373-395 / :966-998（外部位移与内容位移分开累加）；
//   · submodules/LensTransition/Sources/LensTransitionContainer.swift:231-345（转场几何采样表 +
//     最近边界点吸入模型）、:241-258（sourceSuckDurationFraction 0.9 / sourceFinalFurthestInsideDistance -8）。
//
// 【为什么这四条同批做，以及落点怎么来的】报告 40 §11 把 B3/B4/B5/B6 判成「无落点」，理由是
// 「本仓没有发帖/回帖流」。该前提经复核**成立**（帖子页更多菜单只有 只看楼主/跳页/分享/删除，
// 楼中楼只有删除，行内「回复」按钮 = openThread —— 见 41-*.md 的逐条取证），但**结论不成立**：
// 本仓有等价的产品动作 —— 一键签到（TiebaSignService 逐吧 msign，由吧首页顶栏签到圆钮发起）。
// 「每个签成功的吧，把它的吧头像从列表行吸进签到圆钮」正好满足这四条的前提：
//   · 源在 UICollectionView 的 cell 里（被裁剪、会被复用）⇒ 飞行体不能住在源里（B5）；
//   · 目标在顶栏玻璃容器（UIGlassContainerEffect 的 contentView）里 ⇒ 也不能塞进目标（B5）；
//   · 全程列表还能被拖动/重排（签到完成会就地重配行）⇒ 飞行体必须能跟随（B6）；
//   · 源与目标同时可见 ⇒ 两者的不透明度必须由一个分数派生才不会重影（B4）。
//
// 三条本仓既有约定（逐条遵守）：
//   1. 模型值恒为终态：飞行体只是 presentation，源视图的 alpha 在结束时无条件还原；
//   2. 不引私有 API：容器用 TiebaPassthroughContainerView（公开 hitTest 语义），
//      portal 用 TiebaPortalSourceView 的引用簿记 + 公开快照（不用私有 _UIPortalView）；
//   3. 缓动在生成采样表时就烘进去（B1 的 TiebaBakedEasing），逐帧只做线性读表。

import UIKit

// MARK: - B3 转场几何采样表

/// 上游 `TransitionKeyframes` 的采样表。上游是七项（LensTransitionContainer.swift:231-239：
/// bakedSizes / bakedPositions / localPositions / sourcePositions / radiusKeyframes /
/// containerPositions / minSide），本仓的落点只用到五项，另两项**折叠**而不是留空壳：
///   · `localPositions`（源在局部坐标里的位置）—— 本仓覆盖容器只有一个、没有嵌套 transform，
///     局部坐标恒等于容器坐标 ⇒ 与 `bakedPositions` 同值，不另存一份；
///   · `containerPositions`（容器原点）—— 覆盖容器铺满 window、原点恒为 .zero，
///     位移一律由 externalOffset / contentOffset 累加（B6）⇒ 单独存一份常量没有意义。
struct TiebaTransitionKeyframes: Sendable {
  /// 飞行体尺寸（源尺寸 → 目标尺寸内缩 `finalInsideDistance` 之后）。
  let bakedSizes: [CGSize]
  /// 飞行体中心（覆盖容器坐标 = window 坐标）。
  let bakedPositions: [CGPoint]
  /// 源视图中心（锚点轨：源被滚动/重排带走时按它跟随，B6）。
  let sourcePositions: [CGPoint]
  /// 圆角半径（过 A6 等比钳制后的值）。
  let radiusKeyframes: [CGFloat]
  /// A6 的钳制基准：源与目标里较小的那条边（逐帧半径不得越过它的一半）。
  let minSide: CGFloat

  struct Sample: Sendable {
    let size: CGSize
    let position: CGPoint
    let sourcePosition: CGPoint
    let radius: CGFloat
  }

  /// 线性读表（缓动已经在数组里；越界钳到两端）。
  func sample(at fraction: CGFloat) -> Sample {
    let count = bakedSizes.count
    guard count > 1 else {
      return Sample(
        size: bakedSizes.first ?? .zero,
        position: bakedPositions.first ?? .zero,
        sourcePosition: sourcePositions.first ?? .zero,
        radius: radiusKeyframes.first ?? 0
      )
    }
    let position = min(max(fraction, 0), 1) * CGFloat(count - 1)
    let lower = Int(position.rounded(.down))
    let upper = min(lower + 1, count - 1)
    let local = position - CGFloat(lower)
    func lerp(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * local }
    let lhs = bakedSizes[lower]
    let rhs = bakedSizes[upper]
    let lhsPosition = bakedPositions[lower]
    let rhsPosition = bakedPositions[upper]
    let lhsSource = sourcePositions[lower]
    let rhsSource = sourcePositions[upper]
    return Sample(
      size: CGSize(width: lerp(lhs.width, rhs.width), height: lerp(lhs.height, rhs.height)),
      position: CGPoint(x: lerp(lhsPosition.x, rhsPosition.x), y: lerp(lhsPosition.y, rhsPosition.y)),
      sourcePosition: CGPoint(x: lerp(lhsSource.x, rhsSource.x), y: lerp(lhsSource.y, rhsSource.y)),
      radius: lerp(radiusKeyframes[lower], radiusKeyframes[upper])
    )
  }

  /// 生成采样表。
  /// - Parameters:
  ///   - suckDurationFraction: 上游 0.9 —— 前 90% 的时间完成「吸入」，最后 10% 收尾。
  ///   - finalInsideDistance: 上游 8.0 —— 终点再往目标内部进 8pt（是「被吸进去」，不是停在表面）。
  static func make(
    sourceRect: CGRect,
    targetRect: CGRect,
    count: Int = 12,
    easing: TiebaBakedEasing = .easeOutStrong,
    suckDurationFraction: CGFloat = 0.9,
    finalInsideDistance: CGFloat = 8.0
  ) -> TiebaTransitionKeyframes {
    let count = max(count, 2)
    let sourceCenter = CGPoint(x: sourceRect.midX, y: sourceRect.midY)
    let targetCenter = CGPoint(x: targetRect.midX, y: targetRect.midY)
    let finalSize = CGSize(
      width: max(targetRect.width - finalInsideDistance * 2, 1),
      height: max(targetRect.height - finalInsideDistance * 2, 1)
    )
    var sizes: [CGSize] = []
    var positions: [CGPoint] = []
    var radii: [CGFloat] = []
    for eased in easing.progress(count: count) {
      let travel = min(eased / max(suckDurationFraction, 0.01), 1)
      let size = CGSize(
        width: sourceRect.width + (finalSize.width - sourceRect.width) * travel,
        height: sourceRect.height + (finalSize.height - sourceRect.height) * travel
      )
      // A6：圆角按「圆」取最短边的一半，再走本仓既有的等比钳制（不留第二套算法）。
      let clamped = TiebaRoundedRectGeometry.clampedCornerRadii(
        size: size,
        cornerRadii: TiebaCornerRadii(radius: min(size.width, size.height) * 0.5)
      )
      sizes.append(size)
      positions.append(CGPoint(
        x: sourceCenter.x + (targetCenter.x - sourceCenter.x) * travel,
        y: sourceCenter.y + (targetCenter.y - sourceCenter.y) * travel
      ))
      radii.append(clamped.maximum)
    }
    return TiebaTransitionKeyframes(
      bakedSizes: sizes,
      bakedPositions: positions,
      sourcePositions: Array(repeating: sourceCenter, count: count),
      radiusKeyframes: radii,
      minSide: max(min(sourceRect.width, sourceRect.height, targetRect.width, targetRect.height), 1)
    )
  }
}

// MARK: - B5 portal 视图

/// B5 的 portal 视图。本仓不用私有 `_UIPortalView`（理由见 TiebaPortalSourceView 文件头），
/// 用公开 API 的等价物：`reloadPortal` 抓一张源视图快照当 `layer.contents`，
/// 于是源被 cell 裁剪/复用时飞行体仍然持有像素；`disablePortal` 交还位图。
@MainActor
final class TiebaFlightPortalView: UIView, TiebaPortalHosting {
  /// 源视图的公开快照（锚点与飞行体共用一份实现）。
  static func snapshot(of view: UIView) -> CGImage? {
    let size = view.bounds.size
    guard size.width >= 1, size.height >= 1 else { return nil }
    let image = UIGraphicsImageRenderer(size: size).image { _ in
      view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: false)
    }
    return image.cgImage
  }

  func reloadPortal(sourceView: UIView) {
    guard let image = Self.snapshot(of: sourceView) else { return }
    layer.contents = image
    layer.contentsScale = sourceView.traitCollection.displayScale
  }

  func disablePortal() {
    layer.contents = nil
  }
}

// MARK: - B3 · B4 · B5 · B6 飞行体转场

@MainActor
final class TiebaFlightTransition {
  /// 上游 ChatMessageTransitionNode.swift:166-172 的 0.3s（本仓同一档 = overlayDismiss）。
  static let duration: TimeInterval = TiebaAnimationDuration.overlayDismiss
  /// 上游 :451-457 的 portal 双 alpha 交错：目标 0.14s 淡出、源 0.12s 淡入（差 0.02s）。
  private static let sourceHandoffDelay: TimeInterval = 0.14
  private static let bodyHandoffDelay: TimeInterval = 0.12
  /// 本仓的源**不会消失**（列表行还在）：交接完成后按同一条分数把它还回来。
  private static let sourceRestoreStart: CGFloat = 0.75
  /// 两条 alpha ramp 的长度（占整条时间轴的比例，0.3s → ~0.09s）：比整段短得多，
  /// 交接是一个"点"而不是一段，飞行体拿到像素后立刻起飞。
  private static let handoffSpan: CGFloat = 0.3

  /// 全屏穿透覆盖容器：自身不吃点击、只把命中转交子视图（飞行体 `isUserInteractionEnabled = false`
  /// ⇒ 全程零命中）。上游同一个语义在 OverlayTransitionContainerController 里。
  private let host = TiebaPassthroughContainerView()
  /// portal 引用簿记的持有者：位置 = 源视图，像素交给飞行体呈现（上游 needsGlobalPortal 同语义）。
  private let anchor = TiebaPortalSourceView()
  private let body = TiebaFlightPortalView()
  private let keyframes: TiebaTransitionKeyframes
  private let duration: TimeInterval
  private weak var sourceView: UIView?
  private var externalOffset = CGPoint.zero
  private var contentOffset = CGPoint.zero
  private var animator: TiebaDisplayLinkAnimator?
  /// B4：源与目标共用的那个 0..1 分数（全转场唯一的时间真相）。
  private(set) var fraction: CGFloat = 0
  /// 结束回调（调用方在这里丢掉引用；容器与飞行体已从窗口摘除）。
  var onFinish: (() -> Void)?

  init?(source: UIView, target: UIView, in window: UIWindow, duration: TimeInterval = TiebaFlightTransition.duration) {
    let sourceRect = source.convert(source.bounds, to: window)
    let targetRect = target.convert(target.bounds, to: window)
    guard source.window === window, source.alpha > 0.01, !source.isHidden,
      sourceRect.width >= 1, sourceRect.height >= 1,
      targetRect.width >= 1, targetRect.height >= 1
    else { return nil }
    self.sourceView = source
    self.keyframes = TiebaTransitionKeyframes.make(sourceRect: sourceRect, targetRect: targetRect)
    self.duration = max(duration, 0.05)
    host.frame = window.bounds
    host.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    anchor.frame = sourceRect
    anchor.isUserInteractionEnabled = false
    body.isUserInteractionEnabled = false
    body.frame = sourceRect
    body.alpha = 0.01
    anchor.layer.contents = TiebaFlightPortalView.snapshot(of: source)
    window.addSubview(host)
    host.addSubview(anchor)
    anchor.addPortal(view: body)
    // 内容已交给 portal（上游 :451-457：目标 alpha 归零），锚点自身不再画像素。
    anchor.alpha = 0
  }

  func start() {
    sourceView?.alpha = 1
    apply(fraction: 0)
    animator = TiebaDisplayLinkAnimator(
      duration: duration,
      from: 0,
      to: 1,
      update: { [weak self] value in self?.apply(fraction: value) },
      completion: { [weak self] in self?.finish() }
    )
  }

  /// B6①：外部引起的位移（容器自己动了：列表 frame 变化、分区展开、键盘）。
  func addExternalOffset(_ offset: CGPoint) {
    externalOffset.x += offset.x
    externalOffset.y += offset.y
    apply(fraction: fraction)
  }

  /// B6②：内容自身引起的位移（列表滚动、插入/删除让源行移动）。
  func addContentOffset(_ offset: CGPoint) {
    contentOffset.x += offset.x
    contentOffset.y += offset.y
    apply(fraction: fraction)
  }

  /// 立即收束（页面走了 / 源被回收时调用方可以提前结束）。
  func cancel() {
    finish()
  }

  private func apply(fraction value: CGFloat) {
    fraction = min(max(value, 0), 1)
    let bodyHandoff = CGFloat(Self.bodyHandoffDelay / duration)
    let sourceHandoff = CGFloat(Self.sourceHandoffDelay / duration)
    // 交接窗口（0 → 0.12s）里飞行体**不动**：像素刚从源交过来，两边必须停在同一处，
    // 否则就是 B4 说的"两块同时半透明且位置不同"（重影）。窗口结束后才起飞。
    let motion = ramp(fraction, start: bodyHandoff, span: 1 - bodyHandoff)
    let sample = keyframes.sample(at: motion)
    let dx = externalOffset.x + contentOffset.x
    let dy = externalOffset.y + contentOffset.y
    body.bounds = CGRect(origin: .zero, size: sample.size)
    body.center = CGPoint(x: sample.position.x + dx, y: sample.position.y + dy)
    body.layer.cornerRadius = min(sample.radius, keyframes.minSide * 0.5)
    body.layer.cornerCurve = .continuous
    // 锚点跟着源走：两种位移都作用在它身上（B6）。
    anchor.center = CGPoint(x: sample.sourcePosition.x + dx, y: sample.sourcePosition.y + dy)
    // B4：两个 alpha 都由这**一个** fraction 派生，B5 的交接只是两条 ramp 的起点差 0.02s
    //（源 0.14s 淡出、飞行体 0.12s 淡入 ⇒ 交接点前后总强度恒定，没有空档）。
    let bodyAlpha = ramp(fraction, start: bodyHandoff, span: Self.handoffSpan)
    let sourceAlpha = 1 - ramp(fraction, start: sourceHandoff, span: Self.handoffSpan)
    body.alpha = max(0.01, bodyAlpha)
    if let sourceView, sourceView.window != nil {
      let restore = ramp(fraction, start: Self.sourceRestoreStart, span: 1 - Self.sourceRestoreStart)
      sourceView.alpha = sourceAlpha + (1 - sourceAlpha) * restore
    }
  }

  /// [start, start+span] 上的 0→1 斜坡（start 之前恒 0、start+span 之后恒 1）。
  private func ramp(_ value: CGFloat, start: CGFloat, span: CGFloat) -> CGFloat {
    let span = max(span, 0.001)
    return min(max((value - start) / span, 0), 1)
  }

  private func finish() {
    guard animator != nil || body.superview != nil else { return }
    animator?.invalidate()
    animator = nil
    fraction = 1
    sourceView?.alpha = 1
    // 引用簿记解绑 → disablePortal()（飞行体不再持有位图）。
    anchor.removePortal(view: body)
    body.removeFromSuperview()
    anchor.removeFromSuperview()
    host.removeFromSuperview()
    onFinish?()
  }
}
