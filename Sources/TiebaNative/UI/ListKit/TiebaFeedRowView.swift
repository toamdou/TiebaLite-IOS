// ============================================================
// TiebaLite RN — 信息流行视图（TiebaFeedRowView）
//
// 设计（2026-09-12，与 TiebaRowMetrics 配套）：
//   - Fabric/Yoga 不查自定义视图的 intrinsicContentSize（TiebaRichTextView.swift:66-68），
//     行高由 JS 从 TiebaRowMetrics 同步查得后显式下发；本视图只在给定 frame 内绘制。
//   - 模型从 TiebaRowMetrics.shared.feedRow(pageKey:index:) 拉取（与测量同一实例，
//     含预算好的 NSAttributedString），apply 只接收 pageKey/index 两个原始 prop ——
//     零逐行数据编组、零 JSON.stringify。
//   - recycleItems 开启：apply()/prepareForReuse() 必须完整复位（取消在途图片任务、
//     清空 image/attributedText、横滑带归零、角标/状态复位），不能残留上一行内容。
//     例外：同一行重配（点赞/展开/主题重刷 = 身份键相同）只重贴文案与计数，
//     不取消在途图片、不归零图片带（否则每次计数变化都会全屏重发图片）。
//   - layoutSubviews 只按 model.plan 摆 frame，不跑任何 TextKit 测量。
//   - 图片走 TiebaNuke.pipeline（Referer + 内存/磁盘缓存 + 同 URL 请求合并），
//     按目标像素下采样。复用/换行用 cancelRequest(for:) 取消在途任务——任务
//     关联在视图上，取消后回调不再投递，旧图不会贴到新行。
//   - 动画只保留三处、全部短时且可打断：EntranceRow（首屏批次入场，220ms/35ms
//     级联）、CollapseRow（不感兴趣折叠，280ms）、LikeButton（heart pop + 计数
//     跳动，CASpringAnimation 承载 springs.ts 的同参弹簧）。全部 gate 在
//     UIAccessibility.isReduceMotionEnabled；图片仍无淡入。
//
// 交互区域（行内自管交互只有右上角菜单钮与图片长按菜单；其余区域的语义动作
// 仍由 cell 的整卡点击按 model.plan 命中后上报 JS）：
//   - avatarFrame                      → 用户页
//   - cardFrame 内除下方子区域         → 进帖子（现有 useFeedCardActions 路径）
//   - mediaFrame / mediaItemFrames[i]  → 图片查看器（带序号 i）
//   - 图片长按（UIContextMenuInteraction）→ 保存照片/分享照片（回传 JS 执行）；
//     点长按预览 = 进大图（onMediaOpen 外传，列表侧复用点图查看器入口）
//   - showMoreFrame                    → 长文展开（命中矩形 = 文本矩形外扩 6pt，
//                                       等价 TweetCard 的 hitSlop；文本绘制用 showMoreTextFrame）
//   - chipFrame                        → 吧页
//   - actionButtonFrames[0/1/2]        → 回复 / 分享 / 点赞（0.45 按压透明度；
//                                        点赞另有蓄力触觉 + heart pop）
//   - 卡片右上角 26×26 menuButtonFrame  → 不感兴趣/屏蔽作者/复制标题（回传 JS）
//   以上 frame 均可由 model.plan 直接取得（行坐标；内部常量与 TweetCard 对齐）。
//   图片带序号需要滚动内容坐标 → contentOffset 的换算（帧计划里没有偏移），
//   由 `mediaHit(atRowPoint:)` 提供（只读几何；列表侧点击分发用它）。
//   点是否落在菜单钮上由 `ownsInteraction(atRowPoint:)` 判定（cell 的整卡点击
//   手势据此过滤，避免"点菜单同时进帖"）。
// ============================================================

import UIKit
import Nuke
import NukeExtensions

// MARK: - 配色

// 语义色板在 TiebaRowMetrics.swift 的 TiebaFeedRowPalette：默认值与本节旧
// 静态常量逐一相同，JS 经 TiebaListView 的 themeColors prop 下发实际主题
// （非默认主题的 primary/chip/onChip 由此生效；行视图不再是"只有默认蓝"）。

// MARK: - 行内图片加载（Nuke 共享管线）

/// 行内图片统一入口：Nuke 管线（Referer + 内存/磁盘缓存 + 同 URL 合并）按目标
/// 像素下采样（fit inside，长边 ≤ maxPixel）。复用/换行必须 cancelRequest(for:)
///（任务关联在视图上，取消后回调不再投递；重复 load 也会先取消旧任务）。
@MainActor private func tiebaLoadRowImage(
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
private nonisolated enum TiebaFeedRowMotion {
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

private struct TiebaSpringParams {
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
private enum TiebaAnimatedProperty {
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
@MainActor
private func tiebaPlaySpring(
  on layer: CALayer,
  property: TiebaAnimatedProperty,
  from: CGFloat,
  to: CGFloat,
  spring: TiebaSpringParams,
  key: String,
  completion: (() -> Void)? = nil
) {
  layer.removeAnimation(forKey: key)
  let animation = CASpringAnimation(keyPath: property.keyPath)
  animation.mass = spring.mass
  animation.stiffness = spring.stiffness
  animation.damping = spring.damping
  animation.fromValue = from
  animation.toValue = to
  animation.duration = animation.settlingDuration
  animation.fillMode = .forwards
  animation.isRemovedOnCompletion = false
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
private enum TiebaFeedRowHapticIds {
  /// 点赞蓄力连续播放器（hapticsRealtime.ts 的 likeCharge；档位读 hapticsRealtimeStyles）。
  static let likeCharge = "likeCharge"
  /// JS CHARGE_INTENSITY / CHARGE_SHARPNESS。
  static let chargeIntensity = 0.3
  static let chargeSharpness = 0.25
}

// MARK: - 右上角菜单钮（UIButton.Configuration + 44pt 命中区）

/// TweetCard closeButton 的 UIKit 直译：26×26、xmark 13 bold、textTertiary。
/// 用 UIButton.Configuration.plain()：图标居中/缩放由配置系统算（此前自绘
/// UIControl + 手算居中产出过"× 太大"），本类只保留 hitSlop 外扩。
private final class TiebaFeedRowMenuButton: UIButton {
  /// 命中区下限（RN hitSlop=8 等价；26 视觉 + 两侧 9 = 44pt，行内布局仍按 26）。
  private static let minHitSide: CGFloat = 44

  /// 命中矩形：bounds 之外外扩到 ≥44pt（不改变视觉尺寸与帧计划占位）。
  var hitFrame: CGRect {
    let dx = max((Self.minHitSide - bounds.width) / 2, 0)
    let dy = max((Self.minHitSide - bounds.height) / 2, 0)
    return bounds.insetBy(dx: -dx, dy: -dy)
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    var config = UIButton.Configuration.plain()
    config.image = UIImage(
      systemName: "xmark",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .bold)
    )
    config.contentInsets = .zero
    configuration = config
    isAccessibilityElement = true
    accessibilityLabel = "屏蔽或举报"
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  func configure(tint: UIColor) {
    var config = configuration ?? .plain()
    config.baseForegroundColor = tint
    configuration = config
  }

  /// hitSlop 等价：bounds 外的触摸也归本控件（cell 的整卡点击靠
  /// TiebaFeedRowView.ownsInteraction 的同一 hitFrame 让位）。
  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    hitFrame.contains(point)
  }
}

// MARK: - 深色小角标（长图 / GIF / 计数）

/// 角标底色常量：RN 侧 MediaPager 的 rgba(0,0,0,0.55) 与 11pt semibold 白字，
/// 明暗主题同值（不随主题 token 走）。
private let tiebaBadgeBackground = UIColor.black.withAlphaComponent(0.55)

private final class TiebaFeedRowBadgeView: UIView {
  private let label = UILabel()
  private let iconView = UIImageView()
  private let iconWidth: CGFloat

  init(text: String, systemImage: String?) {
    iconWidth = systemImage == nil ? 0 : 10
    super.init(frame: .zero)
    backgroundColor = tiebaBadgeBackground
    layer.cornerRadius = 10
    label.text = text
    label.font = .systemFont(ofSize: 11, weight: .semibold)
    label.textColor = .white
    addSubview(label)
    iconView.tintColor = .white
    iconView.contentMode = .scaleAspectFit
    if let systemImage {
      iconView.image = UIImage(
        systemName: systemImage,
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
      )
    }
    if iconWidth > 0 { addSubview(iconView) }
    isHidden = true
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override func sizeThatFits(_ size: CGSize) -> CGSize {
    let labelSize = label.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
    let gap: CGFloat = iconWidth > 0 ? 3 : 0
    return CGSize(
      width: iconWidth + gap + labelSize.width + 14,
      height: max(iconWidth, labelSize.height) + 6
    )
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let gap: CGFloat = iconWidth > 0 ? 3 : 0
    iconView.frame = CGRect(x: 7, y: (bounds.height - iconWidth) / 2, width: iconWidth, height: iconWidth)
    label.frame = CGRect(
      x: 7 + iconWidth + gap,
      y: 0,
      width: max(bounds.width - 14 - iconWidth - gap, 0),
      height: bounds.height
    )
  }
}

// MARK: - 媒体单元（单图 / 图片带一格 / 视频 poster 共用）

private final class TiebaFeedRowMediaItemView: UIView {
  private let imageView = UIImageView()
  private let longBadge = TiebaFeedRowBadgeView(text: "长图", systemImage: "arrow.down")
  private let gifBadge = TiebaFeedRowBadgeView(text: "GIF", systemImage: nil)
  private let moreOverlay = UIView()
  private let moreLabel = UILabel()
  /// 视频播放入口：单张 play.circle.fill（此前是手拼的 44pt 圆底 + 独立 play 图标，
  /// 图标字号与容器不齐）。
  private let playBadge = UIImageView()

  /// 行下发的主题色板（占位底色）。
  var palette: TiebaFeedRowPalette = .default {
    didSet { backgroundColor = palette.placeholder }
  }

  /// 长按菜单上下文（行下发）：媒体序号、是否启用、动作回调。
  var mediaIndex = 0
  var contextMenuEnabled = false
  var onMenuAction: ((Int, String) -> Void)?
  /// 长按预览提交（点预览进大图）：媒体序号向行视图冒泡，由列表侧按格现算
  /// 几何并复用点图入口；本视图不构造任何几何、不开查看器。
  var onPreviewCommit: ((Int) -> Void)?
  /// 预览加载目标 = 压缩显示档（产品要求：长按菜单预览仍显示压缩图）；
  /// 保存/分享用原图不经这里——动作 payload 由行模型单独取 originURL。
  private var fullURL: URL?
  private var pixelWidth: Double = 0
  private var pixelHeight: Double = 0
  private var contextMenuInteraction: UIContextMenuInteraction?

  override init(frame: CGRect) {
    super.init(frame: frame)
    clipsToBounds = true
    backgroundColor = palette.placeholder
    imageView.contentMode = .scaleAspectFill
    addSubview(imageView)
    addSubview(longBadge)
    addSubview(gifBadge)

    moreOverlay.backgroundColor = UIColor.black.withAlphaComponent(0.5)
    moreOverlay.isHidden = true
    moreLabel.font = .systemFont(ofSize: 24, weight: .bold)
    moreLabel.textColor = .white
    moreLabel.textAlignment = .center
    moreOverlay.addSubview(moreLabel)
    addSubview(moreOverlay)

    playBadge.image = UIImage(
      systemName: "play.circle.fill",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 40, weight: .regular)
    )
    playBadge.tintColor = .white
    playBadge.contentMode = .scaleAspectFit
    playBadge.isHidden = true
    addSubview(playBadge)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  func prepareForReuse() {
    cancelRequest(for: imageView)
    imageView.image = nil
    longBadge.isHidden = true
    gifBadge.isHidden = true
    moreOverlay.isHidden = true
    playBadge.isHidden = true
    moreLabel.text = nil
    contextMenuEnabled = false
    syncContextMenuInteraction()
    fullURL = nil
    pixelWidth = 0
    pixelHeight = 0
  }

  /// 转场源图 = 自身 imageView 里那张已加载的图（无图返回 nil）。
  var transitionSourceImage: UIImage? { imageView.image }

  /// 长按菜单开关：只在启用时挂 UIContextMenuInteraction（关闭态零手势开销）。
  private func syncContextMenuInteraction() {
    if contextMenuEnabled {
      if contextMenuInteraction == nil {
        let interaction = UIContextMenuInteraction(delegate: self)
        addInteraction(interaction)
        contextMenuInteraction = interaction
      }
    } else if let interaction = contextMenuInteraction {
      removeInteraction(interaction)
      contextMenuInteraction = nil
    }
  }

  func configure(
    media: TiebaFeedRowMedia?,
    isVideoPoster: Bool,
    remainingCount: Int,
    cornerRadius: CGFloat,
    contentMode: UIView.ContentMode,
    imageContextMenu: Bool,
    contextMenuIndex: Int,
    onMenuAction: ((Int, String) -> Void)?,
    onPreviewCommit: ((Int) -> Void)?
  ) {
    layer.cornerRadius = cornerRadius
    layer.cornerCurve = .continuous
    imageView.contentMode = contentMode
    backgroundColor = palette.placeholder

    mediaIndex = contextMenuIndex
    self.onMenuAction = onMenuAction
    self.onPreviewCommit = onPreviewCommit
    // 视频 poster 不进图片菜单（RN 的 MediaPager 同样只在图片上挂 contextMenu）。
    contextMenuEnabled = imageContextMenu && !isVideoPoster && media != nil
    fullURL = media?.url ?? media?.originURL
    pixelWidth = media?.width ?? 0
    pixelHeight = media?.height ?? 0
    syncContextMenuInteraction()

    let isLong = media?.isLong == true
    let isGif = media?.isGif == true
    longBadge.isHidden = !isLong
    gifBadge.isHidden = !isGif
    if !longBadge.isHidden { longBadge.sizeToFit() }
    if !gifBadge.isHidden { gifBadge.sizeToFit() }

    if remainingCount > 0 {
      moreOverlay.isHidden = false
      moreLabel.text = "+\(remainingCount)"
    } else {
      moreOverlay.isHidden = true
      moreLabel.text = nil
    }

    playBadge.isHidden = !isVideoPoster
  }

  func load(url: URL?, maxPixel: CGFloat) {
    tiebaLoadRowImage(url: url, maxPixel: maxPixel, into: imageView)
  }

  /// 显示档取图：位图按视图尺寸裁切（cover）+ 圆角烘焙，尺寸与清晰度都对齐显示框。
  func loadDisplay(url: URL?, targetSize: CGSize, cornerRadius: CGFloat, scale: CGFloat) {
    tiebaPostLoadDisplayImage(
      url,
      targetSize: targetSize,
      cornerRadius: cornerRadius,
      scale: scale,
      into: imageView
    )
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    imageView.frame = bounds
    moreOverlay.frame = bounds
    moreLabel.frame = moreOverlay.bounds
    playBadge.frame = CGRect(
      x: bounds.midX - 22,
      y: bounds.midY - 22,
      width: 44,
      height: 44
    )
    // 长图/GIF 角标：右下角，两个同时存在时水平排开（RN 版固定同位会重叠）。
    var right = bounds.maxX - 8
    if !gifBadge.isHidden {
      gifBadge.frame = CGRect(
        x: right - gifBadge.bounds.width,
        y: bounds.maxY - 8 - gifBadge.bounds.height,
        width: gifBadge.bounds.width,
        height: gifBadge.bounds.height
      )
      right -= gifBadge.bounds.width + 4
    }
    if !longBadge.isHidden {
      longBadge.frame = CGRect(
        x: right - longBadge.bounds.width,
        y: bounds.maxY - 8 - longBadge.bounds.height,
        width: longBadge.bounds.width,
        height: longBadge.bounds.height
      )
    }
  }
}

// MARK: - 图片长按菜单（对齐 PostImageContextMenu：X 同款系统上下文菜单）

/// 长按媒体格 → 系统上下文菜单（深色压暗 + 大图预览 + 菜单在预览下方）。
/// 菜单项与 RN 的 POST_IMAGE_ACTIONS 逐字对齐（保存照片 / 分享照片）；动作
/// 不在此执行——回传 JS 复用 PostImageContextMenu 的 savePhoto/sharePhoto
/// （水印偏好在动作触发时现读，原生读不到 preferencesStore）。
extension TiebaFeedRowMediaItemView: UIContextMenuInteractionDelegate {
  func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    configurationForMenuAtLocation location: CGPoint
  ) -> UIContextMenuConfiguration? {
    guard contextMenuEnabled, imageView.image != nil || fullURL != nil, bounds.width > 0 else {
      return nil
    }
    // 预览首帧 = 屏上已渲染缩略图（零下载），原图后台加载淡入（预览控制器内完成）。
    let snapshot = UIGraphicsImageRenderer(bounds: bounds).image { _ in
      drawHierarchy(in: bounds, afterScreenUpdates: false)
    }
    let previewProvider: UIContextMenuContentPreviewProvider = { [weak self] in
      guard let self else { return nil }
      return TiebaPhotoPreviewViewController(
        initialImage: snapshot,
        fullUrl: self.fullURL?.absoluteString,
        pixelWidth: self.pixelWidth,
        pixelHeight: self.pixelHeight
      )
    }
    let actionProvider: UIContextMenuActionProvider = { [weak self] _ in
      guard let self else { return nil }
      let save = UIAction(
        title: "保存照片",
        image: UIImage(systemName: "square.and.arrow.down")
      ) { [weak self] _ in
        guard let self else { return }
        self.onMenuAction?(self.mediaIndex, "save-image")
      }
      let share = UIAction(
        title: "分享照片",
        image: UIImage(systemName: "square.and.arrow.up")
      ) { [weak self] _ in
        guard let self else { return }
        self.onMenuAction?(self.mediaIndex, "share-image")
      }
      return UIMenu(children: [save, share])
    }
    return UIContextMenuConfiguration(
      identifier: nil,
      previewProvider: previewProvider,
      actionProvider: actionProvider
    )
  }

  /// 升起动画以缩略图格为锚点；格已离开窗口（复用/滚出）时返回 nil——
  /// 飞回目标已死，沿用 TiebaPhotoContextMenuView 的既有防御（真机实证留白）。
  /// ⚠️ 方法名一个字都不能简写/错位：写成 `previewForHighlighting` 这类"几乎
  /// 匹配"的名字编译器只给 warning、系统永远不会调到，锚点会静默失效。
  /// 两个协议名都给：旧名自 iOS 16 起标废弃，但 UIKitCore 里新旧选择器都还在被
  /// 引用（真机上只实现其中一个都可能不被调），两个入口落到同一份实现。
  private func tiebaHighlightPreview() -> UITargetedPreview? {
    guard tiebaIsOnScreen else { return nil }
    return UITargetedPreview(view: self)
  }

  func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    configuration: UIContextMenuConfiguration,
    highlightPreviewForItemWithIdentifier identifier: any NSCopying
  ) -> UITargetedPreview? {
    tiebaHighlightPreview()
  }

  func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    configuration: UIContextMenuConfiguration,
    dismissalPreviewForItemWithIdentifier identifier: any NSCopying
  ) -> UITargetedPreview? {
    nil
  }

  /// （旧协议名，见上：与 identifier 形态同一份实现。）
  func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    previewForHighlightingMenuWithConfiguration configuration: UIContextMenuConfiguration
  ) -> UITargetedPreview? {
    tiebaHighlightPreview()
  }

  /// 收起动画不飞回（同 TiebaPhotoContextMenuView：iOS 26+ 飞回路径留白风险）。
  func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    previewForDismissingMenuWithConfiguration configuration: UIContextMenuConfiguration
  ) -> UITargetedPreview? {
    nil
  }

  /// 菜单升起瞬间的「弹出大图」触觉（RN playImageLiftHaptic）。
  func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    willDisplayMenuFor configuration: UIContextMenuConfiguration,
    animator: UIContextMenuInteractionAnimating?
  ) {
    TiebaSceneHaptics.playImageLift()
  }

  /// 点长按预览 = 提交：收起动画走完再冒泡「打开查看器」（菜单还在时 present
  /// 会与收起动画时序打架）。保存/分享菜单项仍走 onMenuAction，互不影响。
  func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    willPerformPreviewActionForMenuWith configuration: UIContextMenuConfiguration,
    animator: any UIContextMenuInteractionCommitAnimating
  ) {
    let index = mediaIndex
    animator.addCompletion { [weak self] in
      self?.onPreviewCommit?(index)
    }
  }
}

// MARK: - 操作栏单元（图标 + 计数）

/// UIControl 跟踪（不是手势）：滚动开始时 UIScrollView 会 cancel 子视图
/// tracking，不抢 scroll pan、也不会留悬挂的按压状态。
private final class TiebaFeedRowActionView: UIControl {
  private let iconView = UIImageView()
  private let label = UILabel()

  override init(frame: CGRect) {
    super.init(frame: frame)
    iconView.contentMode = .scaleAspectFit
    label.textAlignment = .left
    label.lineBreakMode = .byClipping
    addSubview(iconView)
    addSubview(label)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  func configure(systemImage: String, text: String, tint: UIColor, font: UIFont) {
    iconView.image = TiebaSymbols.image(systemImage, pointSize: 17, weight: .regular)
    iconView.tintColor = tint
    label.text = text
    label.font = font
    label.textColor = tint
  }

  /// 由行的帧计划直接摆放（frame 为按钮局部坐标）。
  func layout(iconFrame: CGRect, labelFrame: CGRect) {
    iconView.frame = iconFrame
    label.frame = labelFrame
  }

  /// 点赞 pop / 计数跳动的动画载体（RN 的两层 Animated.View）。
  var iconLayer: CALayer { iconView.layer }
  var labelLayer: CALayer { label.layer }
}

// MARK: - 静态文字画布

/// 卡片静态文字画布：把卡内多段静态文字画进**同一张** backing store，省掉每段文字
/// 一个可见 CALayer 的绘制/合成与一份独立 backing store；并按行身份缓存位图，使
/// **来回滚动同一行不必重光栅化**（cell 复用会把画布换给别的行，否则每次复用都要重画）。
///
/// 绘制仍走 `UILabel.drawText(in:)`——即 label 自己的渲染实现，所以换行、尾部截断、
/// 垂直居中都与原实现逐像素一致（不自己拼 TextKit：那才是"文字错位/换行不同"这类
/// 只有肉眼才看得见的偏差的来源）。
///
/// 被画的 label 挂在**隐藏宿主**里（见 `labelHost`）：它们仍在视图树上，能拿到窗口
/// trait，深色/浅色动态色按当前外观正确解析；宿主整体 isHidden，所以 UIKit 不会画第二遍，
/// 也不为它们分配 backing store。label 的 isHidden 因此只承担"这一段要不要显示"的语义，
/// 与配置代码（configure / resetBlockVisibility）完全一致，无需改动。
///
/// 坐标系：画布与 labelHost 同在 cardView 的 (0,0) 且同尺寸，而 `place()` 写的正是
/// cardView 局部坐标，所以 `label.frame` 直接就是画布坐标，零换算。引用卡三个文字
/// 也走同一条路——它们以前挂在 quoteCard 里却仍按 cardView 空间摆放（`place()` 只减
/// cardMargin），等于少减了一次父原点、整组右移 `contentX - 2×cardMarginH`。纳入画布后
/// 这个偏差自然消失。
private final class TiebaFeedRowTextCanvas: UIView {
  private struct Run {
    let label: UILabel
    let frame: CGRect
  }

  /// 弱引用盒：缓存**不持有**模型，否则会把已被整页 LRU 淘汰的行钉在内存里
  ///（模型的 NSAttributedString 才是大头）。
  private final class ModelRef {
    weak var value: AnyObject?
    init(_ value: AnyObject) { self.value = value }
  }

  /// 一张缓存位图 + 它的**精确**身份。查找用逐字段比对而非哈希：身份是对象引用 +
  /// 值比较的混合，逐字段比对更直接。
  private struct Entry {
    let model: ModelRef
    let palette: TiebaFeedRowPalette
    let size: CGSize
    let scale: CGFloat
    let style: UIUserInterfaceStyle
    let image: CGImage
    let bytes: Int
    var lastUsed: UInt64
  }

  /// 位图预算。典型卡片（370×220pt @3x）约 2.9MB/张，24MB ≈ 8 张 ≈ 一屏多一点，
  /// 覆盖"往回滚一屏"的命中需求。调大能覆盖滚更远，代价是常驻内存线性增长。
  private static let byteBudget = 24 * 1024 * 1024
  /// 单张位图上限：展开后的长文卡可以到一千多 pt 高（十几 MB），存它会把预算挤空、
  /// 还把别的卡挤掉。这类卡仍然一次画好，只是不进缓存（它本来也不常被来回滚）。
  private static let maxEntryBytes = 8 * 1024 * 1024
  private static var entries: [Entry] = []
  private static var useClock: UInt64 = 0

  private var runs: [Run] = []
  private var bakedModel: AnyObject?
  private var bakedPalette: TiebaFeedRowPalette?

  override init(frame: CGRect) {
    super.init(frame: frame)
    isOpaque = false
    backgroundColor = .clear
    isUserInteractionEnabled = false
    isAccessibilityElement = false
    accessibilityElementsHidden = true
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  /// 收集本轮要画的文字，并按 (模型, 色板, 尺寸, 缩放, 深浅档) 取或烘位图。
  /// frame 取自 label 自己——与本行 `place()` 写进去的是同一个值（卡片坐标）。
  func update(labels: [UILabel], model: AnyObject, palette: TiebaFeedRowPalette) {
    runs = labels.map { Run(label: $0, frame: $0.frame) }.filter { !$0.label.isHidden }
    bakedModel = model
    bakedPalette = palette
    applyBitmap()
  }

  /// 清空（无模型 / 置顶横幅行：卡片整体隐藏，内容不该留着上一行的位图）。
  func clear() {
    runs = []
    bakedModel = nil
    bakedPalette = nil
    setContents(nil)
  }

  /// 外观档或色板变化时由宿主调用：整表作废。
  /// **不在这里重烘**——`applyPalette` 是"先刷 layer 色、后 configure 文案色"，
  /// 此刻 label 上可能还是旧色，重烘会把旧色位图存进新键。宿主清掉 placedToken 后
  /// 必然走一次完整布局，由 `update` 用配色完成的 label 重烘。
  static func invalidateCache() {
    entries.removeAll()
  }

  // MARK: 位图

  private var scaleForDisplay: CGFloat { max(traitCollection.displayScale, 1) }

  private func applyBitmap() {
    guard let model = bakedModel, let palette = bakedPalette else {
      setContents(nil)
      return
    }
    let size = bounds.size
    guard !runs.isEmpty, size.width > 1, size.height > 1 else {
      setContents(nil)
      return
    }
    let scale = scaleForDisplay
    let style = traitCollection.userInterfaceStyle

    if let index = Self.indexOfHit(
      model: model, palette: palette, size: size, scale: scale, style: style
    ) {
      Self.useClock &+= 1
      Self.entries[index].lastUsed = Self.useClock
      setContents(Self.entries[index].image)
      return
    }
    guard let image = makeBitmap(size: size, scale: scale) else {
      setContents(nil)
      return
    }
    let bytes = Int(size.width * scale) * Int(size.height * scale) * 4
    // 超长卡只画不存（见 maxEntryBytes）。
    if bytes <= Self.maxEntryBytes {
      Self.store(
        Entry(
          model: ModelRef(model),
          palette: palette,
          size: size,
          scale: scale,
          style: style,
          image: image,
          bytes: bytes,
          lastUsed: Self.useClock
        )
      )
    }
    setContents(image)
  }

  /// 逐字段精确比对；顺带把模型已释放（弱引用空）的条目清出去。
  private static func indexOfHit(
    model: AnyObject,
    palette: TiebaFeedRowPalette,
    size: CGSize,
    scale: CGFloat,
    style: UIUserInterfaceStyle
  ) -> Int? {
    var hit: Int?
    var index = entries.count - 1
    while index >= 0 {
      if entries[index].model.value == nil {
        entries.remove(at: index)   // 模型已释放：这条缓存永远不可能再命中
      } else if hit == nil,
        entries[index].model.value === model,
        entries[index].size == size,
        entries[index].scale == scale,
        entries[index].style == style,
        entries[index].palette == palette {
        hit = index
      }
      index -= 1
    }
    return hit
  }

  /// 存入并按预算淘汰最久未用的一张（绝不动刚存进来的这张）。
  private static func store(_ entry: Entry) {
    useClock &+= 1
    var fresh = entry
    fresh.lastUsed = useClock
    entries.append(fresh)
    var total = entries.reduce(0) { $0 + $1.bytes }
    while total > byteBudget, entries.count > 1 {
      var oldest = 0
      for index in entries.indices where entries[index].lastUsed < entries[oldest].lastUsed {
        oldest = index
      }
      guard entries[oldest].lastUsed != useClock else { break }
      total -= entries[oldest].bytes
      entries.remove(at: oldest)
    }
  }

  private func makeBitmap(size: CGSize, scale: CGFloat) -> CGImage? {
    let format = UIGraphicsImageRendererFormat()
    format.scale = scale
    format.opaque = false
    let canvas = CGRect(origin: .zero, size: size)
    let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
      for run in self.runs where run.frame.intersects(canvas) {
        run.label.drawText(in: run.frame)
      }
    }
    return image.cgImage
  }

  /// 直接写 `layer.contents`（不走 draw(_:)）。必须关掉隐式动画：cell 复用换位图时
  /// 否则会看到一次淡入过渡。
  private func setContents(_ image: CGImage?) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.contents = image
    layer.contentsScale = scaleForDisplay
    CATransaction.commit()
  }
}

// MARK: - 行视图

public final class TiebaFeedRowView: UIView, UIScrollViewDelegate {
  // MARK: - 协调者接口

  /// 页键（一页一次 prepareFeedRows 的 pageKey）。
  public var pageKey: String = "" {
    didSet {
      guard pageKey != oldValue else { return }
      applyIfConfigured()
    }
  }

  /// 页内行下标。
  public var rowIndex: Int = -1 {
    didSet {
      guard rowIndex != oldValue else { return }
      applyIfConfigured()
    }
  }

  /// 赋值 (pageKey, index)：从 TiebaRowMetrics 同步取模型并重置绘制状态。
  public func apply(pageKey: String, index: Int) {
    applying = true
    self.pageKey = pageKey
    self.rowIndex = index
    applying = false
    loadModel(pageKey: pageKey, index: index)
  }

  /// 右上角 × 菜单选中项（dislike / block / copy-title）：业务动作全在 JS
  /// （不感兴趣面板 / 屏蔽作者 / 复制标题，见 FeedContent 的 rowMenuAction）。
  public var onMenuAction: ((String) -> Void)?

  /// 图片长按菜单选中项（媒体序号, save-image / share-image）：保存/分享与
  /// 水印都在 JS 侧现有链路执行（PostImageContextMenu 同款），原生只出菜单。
  public var onMediaMenuAction: ((Int, String) -> Void)?

  /// 图片长按「点预览进大图」（媒体序号）：列表侧复用它走点图同款查看器入口
  ///（几何 = 该格当前窗口矩形，由列表按格现算；行视图不提供几何）。
  public var onMediaOpen: ((Int) -> Void)?

  /// 主题色板（TiebaListView 的 themeColors prop 下发；默认=默认亮/暗主题）。
  /// 只影响绘制，不参与测量：换主题无需整页重测。
  public var palette: TiebaFeedRowPalette = .default {
    didSet {
      guard palette != oldValue else { return }
      applyPalette()
    }
  }

  /// LegendList recycleItems 换行前的复位（协调者可在回收钩子显式调用；apply 内部也会调）。
  public func prepareForReuse() {
    applying = true
    pageKey = ""
    rowIndex = -1
    applying = false
    model = nil
    placedToken = nil
    resetAnimations()
    resetContent()
    accessibilityLabel = nil
    setNeedsLayout()
  }

  // MARK: - 动画（入场 / 折叠）

  /// 首屏批次入场（EntranceRow）：opacity 0→1 + translateY 12→0，delay =
  /// min(index, 9) × 35ms、220ms、EASE_OUT。只由列表在首批页面上屏时调用一次；
  /// Reduce Motion 时直接静态（与 EntranceRow 的 reduceMotion 分支同语义）。
  public func playEntranceAnimation(index: Int) {
    TiebaEntrance.play(on: self, index: index)
  }

  /// 折叠退场时长（只读暴露，别在两处各写一个 0.28）。删数据现在由
  /// playCollapseAnimation 的 completion 驱动，不再需要外部约这时长。
  public static var collapseDuration: CFTimeInterval { TiebaFeedRowMotion.collapseDuration }

  /// 不感兴趣折叠（CollapseRow）：280ms、EASE_OUT、opacity + scaleY 同步 1→0；
  /// 数据移除改由 completion 驱动（原 JS 的动画窗口后 360ms 兜底定时器）。
  /// Reduce Motion 无动画可等，必须同步回调一次，否则列表永远不删数据。
  public func playCollapseAnimation(completion: (() -> Void)? = nil) {
    if UIAccessibility.isReduceMotionEnabled {
      layer.opacity = 0
      layer.transform = CATransform3DMakeScale(1, 0, 1)
      completion?()
      return
    }
    let group = CAAnimationGroup()
    let opacity = CABasicAnimation(keyPath: "opacity")
    opacity.fromValue = 1
    opacity.toValue = 0
    let scale = CABasicAnimation(keyPath: "transform.scale.y")
    scale.fromValue = 1
    scale.toValue = 0
    group.animations = [opacity, scale]
    group.duration = TiebaFeedRowMotion.collapseDuration
    group.timingFunction = TiebaFeedRowMotion.easeOut
    group.fillMode = .forwards
    group.isRemovedOnCompletion = false
    layer.opacity = 0
    layer.transform = CATransform3DMakeScale(1, 0, 1)
    if let completion {
      // 完成块挂 CATransaction（同 tiebaPlaySpring）：动画被复用复位移除时
      // 也会回调一次，删数据不会卡死在等不到的动画上。
      CATransaction.begin()
      CATransaction.setCompletionBlock(completion)
      layer.add(group, forKey: "tieba.collapse")
      CATransaction.commit()
    } else {
      layer.add(group, forKey: "tieba.collapse")
    }
  }

  /// 复位行级动画（复用/换行）：动画 key 移除 + 终态归位，防止 transform/alpha
  /// 残留串到下一行（prepareForReuse 与 apply 都会走）。
  public func resetAnimations() {
    layer.removeAnimation(forKey: "tieba.entrance")
    layer.removeAnimation(forKey: "tieba.collapse")
    layer.opacity = 1
    layer.transform = CATransform3DIdentity
    likeIconPopLayer?.removeAllAnimations()
    likeCountPopLayer?.removeAllAnimations()
    menuButton.layer.removeAllAnimations()
    for item in actionItems {
      item.alpha = 1
      item.layer.removeAllAnimations()
    }
    // 复用/换行时把在途的延迟蓄力一并作废，否则会在别的行上突然震一下。
    cancelPendingLikeCharge()
    TiebaHaptics.stopContinuousPlayer(playerId: TiebaFeedRowHapticIds.likeCharge)
  }

  // MARK: - 状态

  private var model: TiebaFeedRowModel?
  /// 上次摆 frame 的输入指纹（模型身份 + 尺寸）：相同就不必再摆一遍（见 layoutSubviews）。
  private struct PlacedToken: Equatable {
    let model: ObjectIdentifier
    let size: CGSize
    /// 位图按显示缩放烘焙：缩放档变了必须重摆一次（否则会留着低档的模糊位图）。
    /// 帧计划本身与缩放无关，这里带上它只为驱动画布重烘。
    let scale: CGFloat
  }
  private var placedToken: PlacedToken?
  private var applying = false
  private var stripItems: [TiebaFeedRowMediaItemView] = []
  private var stripFrames: [CGRect] = []
  private var stripActiveIndex = 0
  private var stripTotalCount = 0
  /// 图片带里**已经发过图片请求**的下标（懒加载记账，见 extendStripLoadWindow）。
  /// 只有换行（换帖/换宽度）才清空——同行重配要保持已加载的那几张不回退。
  private var stripLoadedIndexes: Set<Int> = []
  /// 外观档变化登记（registerForTraitChanges，iOS 17 起；traitCollectionDidChange 已废弃）。
  private var styleRegistration: UITraitChangeRegistration?
  /// 已配置的 (pageKey#index)：主题重刷走 configure 但不能重置图片带滚动位置。
  private var configuredIdentity: String?
  /// 上次绘制的点赞数/帖子 id：同一帖计数变化时播跳动（RN numPop 的判据）。
  private var displayedLikeCount: Double?
  private var lastRenderedThreadId: String?
  /// 点赞 pop 的动画载体（图标 / 计数各自的 CALayer，与 RN 的两层 Animated.View 同构）。
  private var likeIconPopLayer: CALayer?
  private var likeCountPopLayer: CALayer?
  /// 点赞蓄力触觉的延迟令牌：按压后 ~0.12s 才启动连续震（滑过按钮不震）；
  /// 抬手/滚动取消/行复用都自增作废在途任务。
  private var likeChargeToken = 0
  private static let likeChargeDelay: TimeInterval = 0.12

  // MARK: - 子视图

  private let cardView = UIView()
  /// 卡内静态文字合画到这一张画布（见 TiebaFeedRowTextCanvas）。
  private let textCanvas = TiebaFeedRowTextCanvas()
  /// 被画文字的宿主：整体隐藏（不给它们分配 backing store、不让 UIKit 画第二遍），
  /// 只为让 label 留在视图树上、从窗口继承正确的 trait（动态色按深/浅色解析）。
  private let labelHost = UIView()
  private let avatarContainer = UIView()
  private let avatarInitialLabel = UILabel()
  private let avatarView = UIImageView()
  private let displayNameLabel = UILabel()
  /// 名字行尾部元信息 =「@昵称 + 时间」一个 label（模型把 4pt 段间空隙烘进 kern，
  /// 见 TiebaFeedRowModel.metaAttributed）：少一个 label、少一次文本布局。
  private let metaLabel = UILabel()
  private let ipLabel = UILabel()
  /// 右上角 26×26 菜单钮（TweetCard styles.closeButton：xmark 13 bold + textTertiary）。
  private let menuButton = TiebaFeedRowMenuButton(frame: .zero)
  private let titleLabel = UILabel()
  private let abstractLabel = UILabel()
  private let showMoreLabel = UILabel()
  private let singleMediaView = TiebaFeedRowMediaItemView()
  private let stripScrollView = UIScrollView()
  private let stripCountLabel = UILabel()
  private let quoteCard = UIView()
  private let quoteForumLabel = UILabel()
  private let quoteTitleLabel = UILabel()
  private let quoteContentLabel = UILabel()
  private let chipView = UIView()
  private let chipAvatarView = UIImageView()
  private let chipInitialLabel = UILabel()
  private let chipLabel = UILabel()
  private var actionItems: [TiebaFeedRowActionView] = []
  private let bannerView = UIView()
  private let bannerHairline = UIView()
  private let bannerIconView = UIImageView()
  private let bannerBadgeLabel = UILabel()
  private let bannerTextLabel = UILabel()

  // MARK: - 初始化

  public override init(frame: CGRect) {
    super.init(frame: frame)
    isOpaque = false
    backgroundColor = .clear
    clipsToBounds = true
    isAccessibilityElement = true
    accessibilityTraits = .staticText

    // 卡片容器
    cardView.backgroundColor = palette.card
    cardView.layer.cornerRadius = 20 // Radius.card
    cardView.layer.cornerCurve = .continuous
    cardView.layer.borderWidth = 1 / max(traitCollection.displayScale, 1)
    cardView.layer.borderColor = palette.borderCard.cgColor
    cardView.clipsToBounds = true // TweetCard card.overflow:'hidden'：横滑带/圆角裁切
    cardView.isHidden = true
    cardView.accessibilityElementsHidden = true
    addSubview(cardView)

    // 头部
    avatarContainer.backgroundColor = palette.avatarFallback
    avatarContainer.clipsToBounds = true
    avatarInitialLabel.textAlignment = .center
    avatarInitialLabel.font = .systemFont(ofSize: 44 * 0.38, weight: .semibold)
    avatarInitialLabel.textColor = .white
    avatarContainer.addSubview(avatarInitialLabel)
    avatarView.contentMode = .scaleAspectFill
    avatarContainer.addSubview(avatarView)
    // 静态文字的 label 全部挂在这个隐藏宿主里（见 TiebaFeedRowTextCanvas）：
    // 留在视图树上才能从窗口继承 trait（动态色才按深/浅色解析），但整体隐藏，
    // 既不参与绘制也不分配 backing store。真实绘制由 textCanvas 统一完成。
    labelHost.isHidden = true
    labelHost.isUserInteractionEnabled = false
    labelHost.addSubview(displayNameLabel)
    labelHost.addSubview(metaLabel)
    labelHost.addSubview(ipLabel)
    labelHost.addSubview(titleLabel)
    labelHost.addSubview(abstractLabel)
    labelHost.addSubview(showMoreLabel)
    labelHost.addSubview(quoteForumLabel)
    labelHost.addSubview(quoteTitleLabel)
    labelHost.addSubview(quoteContentLabel)
    cardView.addSubview(avatarContainer)

    configureStaticLabel(displayNameLabel)
    configureStaticLabel(metaLabel)
    configureStaticLabel(ipLabel)

    // 转发引用帖：卡片本体（底 + 描边）先挂，让引用文字压在上面。
    quoteCard.isHidden = true
    quoteCard.layer.cornerRadius = 12 // Radius.input
    quoteCard.layer.cornerCurve = .continuous
    quoteCard.layer.borderWidth = 1 / max(traitCollection.displayScale, 1)
    quoteCard.layer.borderColor = palette.separator.cgColor
    configureStaticLabel(quoteForumLabel)
    configureMultilineLabel(quoteTitleLabel)
    configureMultilineLabel(quoteContentLabel)
    cardView.addSubview(quoteCard)
    // 画布只画文字、背景透明：压在引用卡底之上（引用文字才看得见），又在菜单钮/
    // 图片/徽章/操作栏之下（那些之后才挂，且都是不透明的实内容）。
    cardView.addSubview(textCanvas)
    cardView.addSubview(labelHost)

    // 右上角菜单钮（TweetCard closeButton 的 UIKit 直译）：26×26 圆形、
    // xmark 13 bold、textTertiary；无菜单项的行（menuOptions 空）保持隐藏。
    menuButton.isHidden = true
    menuButton.configure(tint: palette.textTertiary)
    menuButton.addTarget(self, action: #selector(handleMenuButtonTap), for: .touchUpInside)
    cardView.addSubview(menuButton)

    // 正文
    configureMultilineLabel(titleLabel)
    configureMultilineLabel(abstractLabel)
    configureStaticLabel(showMoreLabel)

    // 媒体
    singleMediaView.isHidden = true
    cardView.addSubview(singleMediaView)
    stripScrollView.isHidden = true
    stripScrollView.showsHorizontalScrollIndicator = false
    stripScrollView.isDirectionalLockEnabled = true
    stripScrollView.decelerationRate = .normal
    stripScrollView.backgroundColor = .clear
    stripScrollView.contentInsetAdjustmentBehavior = .never
    stripScrollView.delegate = self
    cardView.addSubview(stripScrollView)
    stripCountLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
    stripCountLabel.textColor = .white
    stripCountLabel.textAlignment = .center
    stripCountLabel.backgroundColor = tiebaBadgeBackground
    stripCountLabel.layer.cornerRadius = 10
    stripCountLabel.layer.cornerCurve = .continuous
    stripCountLabel.clipsToBounds = true
    stripCountLabel.isHidden = true
    cardView.addSubview(stripCountLabel)

    // 吧名徽章
    chipView.isHidden = true
    chipView.backgroundColor = palette.chip
    chipView.layer.cornerRadius = 20 // Radius.card
    chipView.layer.cornerCurve = .continuous
    chipView.clipsToBounds = true
    chipAvatarView.contentMode = .scaleAspectFill
    chipAvatarView.clipsToBounds = true
    chipInitialLabel.textAlignment = .center
    chipInitialLabel.font = .systemFont(ofSize: 20 * 0.38, weight: .semibold)
    chipInitialLabel.textColor = palette.onChip
    chipView.addSubview(chipInitialLabel)
    chipView.addSubview(chipAvatarView)
    configureStaticLabel(chipLabel)
    cardView.addSubview(chipView)
    chipView.addSubview(chipLabel)

    // 操作栏：UIControl 跟踪（回复/分享/点赞）。触底 0.45 透明度、抬手/取消
    // 复位；点赞额外承担蓄力触觉（延迟启动）与弹簧 pop。UIControl tracking 不
    // 吞 touch（cell 整卡点击照常收到），滚动手势开始时会以 touchCancel 收尾。
    for _ in 0..<3 {
      let item = TiebaFeedRowActionView()
      item.isHidden = true
      actionItems.append(item)
      cardView.addSubview(item)
      item.addTarget(self, action: #selector(handleActionTouchDown(_:)), for: .touchDown)
      item.addTarget(
        self,
        action: #selector(handleActionTouchEnd(_:)),
        for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit]
      )
    }

    // 置顶横幅
    bannerView.isHidden = true
    bannerView.accessibilityElementsHidden = true
    bannerHairline.backgroundColor = palette.borderCard
    bannerView.addSubview(bannerHairline)
    bannerIconView.image = UIImage(
      systemName: "megaphone.fill",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .regular)
    )
    bannerIconView.tintColor = palette.primary
    bannerIconView.contentMode = .scaleAspectFit
    bannerView.addSubview(bannerIconView)
    bannerBadgeLabel.text = "置顶"
    bannerBadgeLabel.font = .systemFont(ofSize: 12, weight: .bold)
    bannerBadgeLabel.textColor = palette.primary
    bannerBadgeLabel.textAlignment = .center
    bannerBadgeLabel.backgroundColor = palette.primary.withAlphaComponent(0.1)
    bannerBadgeLabel.layer.cornerRadius = 8
    bannerBadgeLabel.layer.cornerCurve = .continuous
    bannerBadgeLabel.clipsToBounds = true
    bannerView.addSubview(bannerBadgeLabel)
    bannerTextLabel.font = .systemFont(ofSize: 13, weight: .medium)
    bannerTextLabel.textColor = palette.text
    bannerTextLabel.lineBreakMode = .byTruncatingTail
    bannerTextLabel.numberOfLines = 1
    bannerView.addSubview(bannerTextLabel)
    addSubview(bannerView)

    // 动态色转 CGColor 后不随外观走：系统级 trait 登记只在外观档真变时回调，
    // 不再每次 layoutSubviews 比对（traitCollectionDidChange 自 iOS 17 废弃）。
    styleRegistration = registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
      (view: TiebaFeedRowView, _) in
      view.refreshDynamicLayerColors()
    }
  }

  public required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  // MARK: - apply / 复位

  private func applyIfConfigured() {
    guard !applying, !pageKey.isEmpty, rowIndex >= 0 else { return }
    loadModel(pageKey: pageKey, index: rowIndex)
  }

  private func loadModel(pageKey: String, index: Int) {
    // 先取旧身份再复位：同一行重配（点赞/展开/主题重刷）必须保留在途图片与
    // 图片带位置，只有换行才整体复位（resetContent 会清掉 configuredIdentity，
    // 放在复位后比较会恒不相等 → 图片每次计数变化都取消重发）。
    var sameRow = configuredIdentity != nil && configuredIdentity == identityKey
    guard let fetched = TiebaRowMetrics.shared.feedRow(pageKey: pageKey, index: index) else {
      // 页还没测完（或宽度刚变被清掉）：保持空白；列表拿到高度后会重新 apply。
      resetContent()
      model = nil
      accessibilityLabel = nil
      setNeedsLayout()
      return
    }
    // 行宽变了（旋转/分屏）→ 图片下采样目标也变：按换行复位，重发图片。
    if sameRow, model?.containerWidth != fetched.containerWidth {
      sameRow = false
    }
    if sameRow {
      // 行字典逐字未变的行复用同一模型实例：没有任何内容需要重配（点赞/展开只
      // 影响被点的那一行，其余可见行不该跟着重贴文案）。
      guard model !== fetched else { return }
      resetBlockVisibility()
    } else {
      resetContent()
    }
    model = fetched
    configure(with: fetched)
    setNeedsLayout()
  }

  /// 复用/换行复位：取消在途图片、清空全部文本与图片、横滑带归零。
  private func resetContent() {
    cancelRequest(for: avatarView)
    cancelRequest(for: chipAvatarView)
    for item in stripItems {
      item.prepareForReuse()
    }
    singleMediaView.prepareForReuse()
    avatarView.image = nil
    chipAvatarView.image = nil
    // 先清计数状态再归零偏移：setContentOffset 会同步回调 scrollViewDidScroll，
    // 带着旧帧列表会算出错误序号写进角标。
    stripActiveIndex = 0
    stripFrames = []
    stripTotalCount = 0
    stripScrollView.setContentOffset(.zero, animated: false)
    resetBlockVisibility()
    configuredIdentity = nil
  }

  /// 块级可见性复位（不动图片与横滑带的在途任务/滚动位置）：
  /// configure 只负责"显示"，消失的块必须由这里先清掉，同行重配才不会留残影。
  private func resetBlockVisibility() {
    for label in allTextLabels {
      label.text = nil
      label.attributedText = nil
      label.isHidden = true
    }
    cardView.isHidden = true
    bannerView.isHidden = true
    quoteCard.isHidden = true
    chipView.isHidden = true
    menuButton.isHidden = true
    singleMediaView.isHidden = true
    stripScrollView.isHidden = true
    stripCountLabel.isHidden = true
    for item in actionItems {
      item.isHidden = true
    }
  }

  private var allTextLabels: [UILabel] {
    [
      displayNameLabel, metaLabel, ipLabel,
      titleLabel, abstractLabel, showMoreLabel,
      quoteForumLabel, quoteTitleLabel, quoteContentLabel, chipLabel,
      bannerBadgeLabel, bannerTextLabel,
    ]
  }

  private func configureStaticLabel(_ label: UILabel) {
    label.isHidden = true
    label.lineBreakMode = .byTruncatingTail
    label.numberOfLines = 1
  }

  private func configureMultilineLabel(_ label: UILabel) {
    label.isHidden = true
    label.lineBreakMode = .byTruncatingTail
    label.numberOfLines = 0
  }

  // MARK: - 主题重刷

  /// 色板变化（TiebaListView 的 themeColors prop）：静态层直接改色，卡内
  /// 文本/图片用现有模型重配一次。同行重配不会重置图片带滚动位置，也不重启
  /// 在途图片任务（configureMedia 的 isSameRow 判据）；换主题是低频操作，
  /// 不做逐视图增量改色的复杂度。
  private func applyPalette() {
    cardView.backgroundColor = palette.card
    cardView.layer.borderColor = palette.borderCard.resolvedColor(with: traitCollection).cgColor
    avatarContainer.backgroundColor = palette.avatarFallback
    bannerHairline.backgroundColor = palette.borderCard
    bannerIconView.tintColor = palette.primary
    bannerBadgeLabel.textColor = palette.primary
    bannerBadgeLabel.backgroundColor = palette.primary.withAlphaComponent(0.1)
    bannerTextLabel.textColor = palette.text
    quoteCard.layer.borderColor = palette.separator.resolvedColor(with: traitCollection).cgColor
    chipView.backgroundColor = palette.chip
    chipLabel.textColor = palette.onChip
    menuButton.configure(tint: palette.textTertiary)
    for item in stripItems {
      item.palette = palette
    }
    singleMediaView.palette = palette
    // 动态色转 CGColor 的两处（卡片/引用卡描边）立即按当前外观重解析一次。
    refreshDynamicLayerColors()
    if let model {
      configure(with: model)
    }
    setNeedsLayout()
  }

  // MARK: - 配置

  private func configure(with model: TiebaFeedRowModel) {
    if model.isTopBanner {
      configureBanner(with: model)
    } else {
      configureCard(with: model)
    }
    configuredIdentity = identityKey
    accessibilityLabel = makeAccessibilityLabel(for: model)
  }

  /// (pageKey, index) 字符串键：区分"换行"与"同行重配（点赞/展开/主题重刷）"。
  private var identityKey: String? {
    guard !pageKey.isEmpty, rowIndex >= 0 else { return nil }
    return "\(pageKey)#\(rowIndex)"
  }

  /// 同一行重配：在途图片与图片带滚动位置都保留，只重贴文案与计数。
  private var isSameRowReconfigure: Bool {
    configuredIdentity != nil && configuredIdentity == identityKey
  }

  private func configureCard(with model: TiebaFeedRowModel) {
    cardView.isHidden = false
    bannerView.isHidden = true
    menuButton.isHidden = model.menuOptions.isEmpty
    menuButton.configure(tint: palette.textTertiary)
    let fonts = model.geometry.fonts

    // 头像：首字色块在下、图片在上（图片命中即盖住首字，无需回调切显隐）。
    avatarInitialLabel.text = String(model.avatarInitial.prefix(2)).uppercased()
    avatarView.isHidden = false
    if !isSameRowReconfigure {
      tiebaLoadRowImage(
        url: model.avatarURL,
        maxPixel: 44 * max(traitCollection.displayScale, 1),
        into: avatarView
      )
    }

    setText(displayNameLabel, model.displayName, font: fonts.displayName, color: palette.text)
    // 元信息串：色按当前色板统一覆盖（模型侧只写语义色，换主题即变）。
    if let attributed = model.metaAttributed {
      let colored = NSMutableAttributedString(attributedString: attributed)
      colored.addAttribute(
        .foregroundColor,
        value: palette.textSecondary,
        range: NSRange(location: 0, length: colored.length)
      )
      metaLabel.attributedText = colored
      metaLabel.isHidden = false
    }
    setText(ipLabel, model.ipText, font: fonts.ip, color: palette.textSecondary)

    // 正文：attributed 已由测量期构建，这里零重建；「精品」前缀按主题色板补色
    //（模型不写前缀色，否则换主题改不动）。
    if let attributed = model.titleAttributed {
      titleLabel.attributedText = titleAttributed(attributed, prefix: model.titlePrefix)
      titleLabel.numberOfLines = model.titleLineLimit == 0 ? 0 : model.titleLineLimit
      titleLabel.isHidden = false
    }
    if let attributed = model.abstractAttributed {
      abstractLabel.attributedText = attributed
      abstractLabel.numberOfLines = model.abstractLineLimit == 0 ? 0 : model.abstractLineLimit
      abstractLabel.isHidden = false
    }
    if model.isCollapsible && !model.expanded {
      showMoreLabel.text = model.showMoreText
      showMoreLabel.font = fonts.showMore
      showMoreLabel.textColor = palette.primary
      showMoreLabel.isHidden = false
    }

    configureMedia(with: model)
    configureQuote(with: model)
    configureChip(with: model)
    configureActions(with: model)
  }

  private func configureBanner(with model: TiebaFeedRowModel) {
    bannerView.isHidden = false
    cardView.isHidden = true
    bannerBadgeLabel.isHidden = false
    // 铭牌文案是常量，但 resetContent 会清空全部文本，这里必须补回。
    bannerBadgeLabel.text = "置顶"
    bannerTextLabel.isHidden = false
    if let attributed = model.bannerAttributed {
      bannerTextLabel.attributedText = attributed
    }
    bannerTextLabel.numberOfLines = 1
  }

  private func configureMedia(with model: TiebaFeedRowModel) {
    guard model.showsMedia else { return }
    let scale = max(traitCollection.displayScale, 1)
    let isSameRow = isSameRowReconfigure
    let mediaMenuHandler: (Int, String) -> Void = { [weak self] index, action in
      self?.onMediaMenuAction?(index, action)
    }
    let mediaOpenHandler: (Int) -> Void = { [weak self] index in
      self?.onMediaOpen?(index)
    }

    if model.mediaIsStrip {
      let shown = min(model.media.count, TiebaFeedRowLayout.maxImagesPerRow)
      ensureStripItems(count: shown)
      stripTotalCount = model.media.count
      if !isSameRow {
        stripActiveIndex = 0
      }
      stripScrollView.isHidden = false
      stripCountLabel.text = "\(min(stripActiveIndex + 1, model.media.count))/\(model.media.count)"
      stripCountLabel.isHidden = false
      let countSize = stripCountLabel.sizeThatFits(
        CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
      )
      stripCountLabel.bounds = CGRect(
        x: 0,
        y: 0,
        width: countSize.width + 14,
        height: max(countSize.height, 16)
      )
      for (index, item) in stripItems.enumerated() {
        guard index < shown else {
          item.isHidden = true
          continue
        }
        let media = model.media[index]
        item.isHidden = false
        item.palette = palette
        item.configure(
          media: media,
          isVideoPoster: false,
          remainingCount: index == shown - 1 ? model.media.count - shown : 0,
          cornerRadius: 0,
          contentMode: .scaleAspectFill,
          imageContextMenu: model.showsImageContextMenu,
          contextMenuIndex: index,
          onMenuAction: mediaMenuHandler,
          onPreviewCommit: mediaOpenHandler
        )
      }
      // 图片请求整段一次做完（只解可见 + 2 格，其余随横滑补，见 extendStripLoadWindow）。
      if !isSameRow {
        stripLoadedIndexes.removeAll(keepingCapacity: true)
        extendStripLoadWindow(offsetX: stripScrollView.contentOffset.x)
      }
    } else {
      let media = model.media.first
      let url = media?.url ?? model.videoPosterURL
      singleMediaView.isHidden = false
      singleMediaView.palette = palette
      singleMediaView.configure(
        media: media,
        isVideoPoster: model.showsVideoPoster,
        remainingCount: 0,
        cornerRadius: 16, // Radius.card - 4（MediaPager mediaWrap）
        contentMode: .scaleAspectFit,
        imageContextMenu: model.showsImageContextMenu,
        contextMenuIndex: 0,
        onMenuAction: mediaMenuHandler,
        onPreviewCommit: mediaOpenHandler
      )
      if !isSameRow {
        let height = model.singleMediaHeight ?? 0
        singleMediaView.load(
          url: url,
          maxPixel: max(height, model.geometry.textColumnWidth) * scale
        )
      }
    }
  }

  private func configureQuote(with model: TiebaFeedRowModel) {
    guard model.quoteForumText != nil || model.quoteTitleText != nil || model.quoteContentText != nil else {
      return
    }
    quoteCard.isHidden = false
    if let attributed = model.quoteForumAttributed {
      quoteForumLabel.attributedText = attributed
      quoteForumLabel.numberOfLines = 1
      quoteForumLabel.isHidden = false
    }
    if let attributed = model.quoteTitleAttributed {
      quoteTitleLabel.attributedText = attributed
      quoteTitleLabel.numberOfLines = 1
      quoteTitleLabel.isHidden = false
    }
    if let attributed = model.quoteContentAttributed {
      quoteContentLabel.attributedText = attributed
      quoteContentLabel.numberOfLines = 2
      quoteContentLabel.isHidden = false
    }
  }

  private func configureChip(with model: TiebaFeedRowModel) {
    guard model.showsForumChip else { return }
    chipView.isHidden = false
    chipLabel.text = "\(model.forumName)吧"
    chipLabel.font = model.geometry.fonts.chipText
    chipLabel.textColor = palette.onChip
    chipLabel.isHidden = false
    chipInitialLabel.text = String(model.forumChipInitial.prefix(2)).uppercased()
    chipInitialLabel.textColor = palette.onChip
    if !isSameRowReconfigure {
      tiebaLoadRowImage(
        url: model.forumAvatarURL,
        maxPixel: 20 * max(traitCollection.displayScale, 1),
        into: chipAvatarView
      )
    }
  }

  private func configureActions(with model: TiebaFeedRowModel) {
    guard model.showsActions else { return }
    let fonts = model.geometry.fonts.actionText
    let icons = ["bubble.left", "square.and.arrow.up", model.isLiked ? "heart.fill" : "heart"]
    let texts = [model.replyText, model.shareText, model.likeText]
    // 计数跳动判据与 RN numPop 相同：同一帖（threadId 不变）的数值变化且新值
    // > 0（首帧/换帖不播——RN 的 prevCountRef 初值即当前值、复用行重新挂载）。
    let sameThread = lastRenderedThreadId != nil && lastRenderedThreadId == model.threadId
    let shouldBumpCount = sameThread
      && displayedLikeCount != nil
      && displayedLikeCount != model.likeCount
      && model.likeCount > 0
    for (index, item) in actionItems.enumerated() {
      item.isHidden = false
      let tint = index == 2 && model.isLiked
        ? palette.liked
        : palette.textTertiary
      item.configure(systemImage: icons[index], text: texts[index], tint: tint, font: fonts)
      if index == 2 {
        likeIconPopLayer = item.iconLayer
        likeCountPopLayer = item.labelLayer
      }
    }
    lastRenderedThreadId = model.threadId
    displayedLikeCount = model.likeCount
    if shouldBumpCount {
      playLikeCountBump()
    }
  }

  private func setText(_ label: UILabel, _ text: String?, font: UIFont, color: UIColor) {
    guard let text, !text.isEmpty else { return }
    label.text = text
    label.font = font
    label.textColor = color
    label.isHidden = false
  }

  /// 标题串：「精品」前缀段按当前色板的 warning 补色（模型只存文案，换主题即变）。
  private func titleAttributed(_ attributed: NSAttributedString, prefix: String?) -> NSAttributedString {
    guard let prefix, !prefix.isEmpty, attributed.length >= (prefix as NSString).length else {
      return attributed
    }
    let colored = NSMutableAttributedString(attributedString: attributed)
    colored.addAttribute(
      .foregroundColor,
      value: palette.warning,
      range: NSRange(location: 0, length: (prefix as NSString).length)
    )
    return colored
  }

  private func ensureStripItems(count: Int) {
    while stripItems.count < count {
      let item = TiebaFeedRowMediaItemView()
      stripItems.append(item)
      stripScrollView.addSubview(item)
    }
  }

  private func makeAccessibilityLabel(for model: TiebaFeedRowModel) -> String {
    if model.isTopBanner {
      return model.bannerText.isEmpty ? "置顶" : "置顶，\(model.bannerText)"
    }
    var parts: [String] = [model.displayName]
    if let time = model.timeText { parts.append(time) }
    if !model.titleText.isEmpty { parts.append(model.titleText) }
    if !model.abstractText.isEmpty { parts.append(model.abstractText) }
    if model.isLiked { parts.append("已点赞") }
    return parts.joined(separator: "，")
  }

  // MARK: - 交互（右上角菜单 / 操作栏按压反馈）

  /// 右上角 ×：与 RN 的 Alert.alert(title, nil, [菜单项…, 取消]) 同形态——
  /// iOS 侧本就是 UIAlertController(.actionSheet)，这里直出同一控件。
  /// 动作只回传 JS（不感兴趣面板/屏蔽/复制标题全在 FeedContent），原生不猜业务。
  @objc private func handleMenuButtonTap() {
    guard let model, !model.menuOptions.isEmpty,
          let host = TiebaTopViewController.find() else { return }
    // RN 的 handleClosePress 在弹面板前触发 press 触觉（同款）。
    TiebaSceneHaptics.fire("press")
    let sheet = UIAlertController(
      title: model.titleText.isEmpty ? "帖子" : model.titleText,
      message: nil,
      preferredStyle: .actionSheet
    )
    for option in model.menuOptions {
      sheet.addAction(UIAlertAction(title: Self.menuTitle(for: option), style: .default) { [weak self] _ in
        self?.onMenuAction?(option)
      })
    }
    sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
    // iPad/大屏 popover 锚点（iPhone 上 actionSheet 忽略）。
    sheet.popoverPresentationController?.sourceView = menuButton
    sheet.popoverPresentationController?.sourceRect = menuButton.bounds
    host.present(sheet, animated: true)
  }

  /// 菜单项文案与 TweetCard.closeMenuOptions 的组装逻辑逐字对齐。
  private static func menuTitle(for option: String) -> String {
    switch option {
    case "dislike": return "不感兴趣"
    case "block": return "屏蔽作者"
    case "copy-title": return "复制标题"
    default: return option
    }
  }

  /// 操作栏按压（UIControl 跟踪）：三键统一 0.45 透明度；点赞另外承担蓄力
  /// 触觉（延迟启动）与 heart 弹簧 pop（1→1.35→1）。动作语义不在这里发——
  /// cell 的整卡点击照常命中 region=action，由 JS 定夺。
  @objc private func handleActionTouchDown(_ control: UIControl) {
    control.alpha = 0.45
    guard control === actionItems[2] else { return }
    playLikePop()
    scheduleLikeCharge()
  }

  /// 抬手 / 拖出按钮 / 滚动抢走 touch / 手势取消：一律复位反馈并停震。
  @objc private func handleActionTouchEnd(_ control: UIControl) {
    control.alpha = 1
    guard control === actionItems[2] else { return }
    cancelPendingLikeCharge()
    endLikeCharge()
    // 松手强制回 1（RN onPressOut 的 MOMENTUM 写入）：不依赖序列自动续跑，
    // 否则点赞乐观更新引发的行重配可能让 pop 停在 1.35。
    springLikeIcon(to: 1, key: "tieba.likePopSettle")
  }

  /// 蓄力触觉延迟启动：手指只是滑过按钮（随即 touchCancel）不能震；令牌
  /// 自增作废在途任务（延迟窗口内取消 = 不震）。
  private func scheduleLikeCharge() {
    likeChargeToken += 1
    let token = likeChargeToken
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.likeChargeDelay) { [weak self] in
      guard let self, self.likeChargeToken == token else { return }
      self.beginLikeCharge()
    }
  }

  private func cancelPendingLikeCharge() {
    likeChargeToken += 1
  }

  /// 点赞蓄力（hapticsRealtime.ts 的 likeCharge）：按住期间低强度连续震，松手即停。
  /// 播放器与引擎复用全仓唯一的 TiebaHaptics（行内不再自建 CHHapticEngine）；
  /// 档位读设置页写入的 hapticsRealtimeStyles.likeCharge（off = 不播）。
  private func beginLikeCharge() {
    guard let scale = likeChargeScale() else { return }
    TiebaHaptics.createContinuousPlayer(
      playerId: TiebaFeedRowHapticIds.likeCharge,
      initialIntensity: TiebaFeedRowHapticIds.chargeIntensity * scale,
      initialSharpness: TiebaFeedRowHapticIds.chargeSharpness
    )
    TiebaHaptics.startContinuousPlayer(playerId: TiebaFeedRowHapticIds.likeCharge)
  }

  private func endLikeCharge() {
    TiebaHaptics.stopContinuousPlayer(playerId: TiebaFeedRowHapticIds.likeCharge)
  }

  /// 实时触觉档位 → 强度缩放；nil = 该效果已关闭（off），默认适中（0.8）。
  /// 档位表与 TiebaSceneHaptics.realtimeScale 一致（那边只暴露 imageLiftPop）。
  private func likeChargeScale() -> Double? {
    guard let raw = TiebaPreferenceSnapshot.string("hapticsRealtimeStyles"),
          let data = raw.data(using: .utf8),
          let table = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { return 0.8 }
    switch table[TiebaFeedRowHapticIds.likeCharge] as? String {
    case "off": return nil
    case "light": return 0.55
    case "strong": return 1
    default: return 0.8
    }
  }

  /// 点赞 pop：1→1.35（damping 12 / stiffness 380 / mass 0.6）→ 1（MOMENTUM）。
  /// Reduce Motion 直接跳过（RN LikeButton 的 reduceMotion 分支同语义）。
  private func playLikePop() {
    guard !UIAccessibility.isReduceMotionEnabled, let layer = likeIconPopLayer else { return }
    tiebaPlaySpring(
      on: layer,
      property: .scale,
      from: 1,
      to: 1.35,
      spring: TiebaFeedRowMotion.likePop,
      key: "tieba.likePop"
    ) { [weak self] in
      self?.springLikeIcon(to: 1, key: "tieba.likePopSettle")
    }
  }

  /// 用 MOMENTUM 弹簧把 heart 拉回原尺寸（打断在途 pop 时从呈现值出发）。
  private func springLikeIcon(to value: CGFloat, key: String) {
    guard let layer = likeIconPopLayer else { return }
    tiebaPlaySpring(
      on: layer,
      property: .scale,
      from: TiebaAnimatedProperty.scale.current(of: layer),
      to: value,
      spring: TiebaFeedRowMotion.momentum,
      key: key
    )
  }

  /// 计数跳动（RN numPop）：计数文案变化时 1→1.28→1（damping 11 / stiffness 320
  /// / mass 0.5，回落用 MOMENTUM）。计数由 JS 的权威模型驱动，原生只在变化时补动画；
  /// Reduce Motion 直接跳过（RN 同判据）。
  private func playLikeCountBump() {
    guard !UIAccessibility.isReduceMotionEnabled, let layer = likeCountPopLayer else { return }
    tiebaPlaySpring(
      on: layer,
      property: .scale,
      from: 1,
      to: 1.28,
      spring: TiebaFeedRowMotion.countBump,
      key: "tieba.countBump"
    ) { [weak self] in
      guard let layer = self?.likeCountPopLayer else { return }
      tiebaPlaySpring(
        on: layer,
        property: .scale,
        from: 1.28,
        to: 1,
        spring: TiebaFeedRowMotion.momentum,
        key: "tieba.countBumpSettle"
      )
    }
  }

  // MARK: - 布局（只摆 frame，不测量）

  public override func layoutSubviews() {
    super.layoutSubviews()
    guard let model else {
      // 模型被清掉（换行 / 页还没测完）：画布必须一起清空，否则会留着上一行的文字。
      textCanvas.clear()
      return
    }
    // 同一个模型 + 同一尺寸 ⇒ 帧计划没变，四十来个 frame 不必再摆一遍（配置、图片
    // 到达、系统多次布局都会把 layoutSubviews 叫醒）；换行/换宽度/换模型都会换 token。
    let token = PlacedToken(
      model: ObjectIdentifier(model),
      size: bounds.size,
      scale: max(traitCollection.displayScale, 1)
    )
    if placedToken == token { return }
    placedToken = token
    // 帧计划在测量期已算好（模型不可变），布局期只摆 frame。
    let plan = model.plan

    if model.isTopBanner {
      bannerView.frame = plan.cardFrame
      bannerHairline.frame = CGRect(
        x: 0,
        y: 0,
        width: plan.cardFrame.width,
        height: 1 / max(traitCollection.displayScale, 1)
      )
      placeBanner(bannerIconView, plan.bannerIconFrame, in: plan.cardFrame)
      placeBanner(bannerBadgeLabel, plan.bannerBadgeFrame, in: plan.cardFrame)
      placeBanner(bannerTextLabel, plan.bannerTextFrame, in: plan.cardFrame)
      // 置顶横幅不用卡片画布（cardView 整体隐藏）：清掉，免得复用上来时残留上一行的位图。
      textCanvas.clear()
      return
    }

    cardView.frame = plan.cardFrame
    // 画布与 label 宿主铺满卡片、同在 (0,0)：label 的 frame（place() 写的卡片坐标）
    // 就是画布坐标，绘制时零换算。
    textCanvas.frame = cardView.bounds
    labelHost.frame = cardView.bounds
    place(avatarContainer, plan.avatarFrame)
    avatarContainer.layer.cornerRadius = avatarContainer.bounds.width / 2
    avatarInitialLabel.frame = avatarContainer.bounds
    avatarView.frame = avatarContainer.bounds
    place(displayNameLabel, plan.displayNameFrame)
    place(metaLabel, plan.metaFrame)
    place(ipLabel, plan.ipFrame)
    place(menuButton, plan.menuButtonFrame)
    place(titleLabel, plan.titleFrame)
    place(abstractLabel, plan.abstractFrame)
    // 文本按文本矩形摆放；plan.showMoreFrame 是命中矩形（外扩 6pt hitSlop）。
    place(showMoreLabel, plan.showMoreTextFrame)

    if let mediaFrame = cardRect(plan.mediaFrame) {
      singleMediaView.frame = mediaFrame
      stripScrollView.frame = mediaFrame
      stripScrollView.contentSize = CGSize(width: plan.mediaContentWidth, height: mediaFrame.height)
      if !stripScrollView.isHidden {
        stripCountLabel.frame = CGRect(
          x: mediaFrame.maxX - 8 - stripCountLabel.bounds.width,
          y: mediaFrame.maxY - 8 - stripCountLabel.bounds.height,
          width: stripCountLabel.bounds.width,
          height: stripCountLabel.bounds.height
        )
      }
    }
    for (index, item) in stripItems.enumerated() {
      if index < plan.mediaItemFrames.count {
        item.frame = plan.mediaItemFrames[index]
      } else {
        item.frame = .zero
      }
    }
    stripFrames = plan.mediaItemFrames

    place(quoteCard, plan.quoteFrame)
    place(quoteForumLabel, plan.quoteForumFrame)
    place(quoteTitleLabel, plan.quoteTitleFrame)
    place(quoteContentLabel, plan.quoteContentFrame)
    place(chipView, plan.chipFrame)
    // ⚠️ 吧头像/首字/吧名都是 chipView 的子视图，而 plan 里这三个矩形与 chipFrame
    // 同在**卡片坐标系**：直接 place 会把整组内容右移一个 chipFrame.minX，chipView
    // 又 clipsToBounds，于是吧名被整段裁掉（用户报的"左下角吧名吧头像显示不出来"，
    // 只剩一个白首字）。与下面操作栏 item.layout 同款：减父视图原点换算成局部坐标。
    if let chipFrame = plan.chipFrame, let avatar = plan.chipAvatarFrame,
      let text = plan.chipTextFrame
    {
      chipAvatarView.frame = avatar.offsetBy(dx: -chipFrame.minX, dy: -chipFrame.minY)
      chipInitialLabel.frame = chipAvatarView.bounds
      chipLabel.frame = text.offsetBy(dx: -chipFrame.minX, dy: -chipFrame.minY)
    } else {
      chipAvatarView.frame = .zero
      chipInitialLabel.frame = .zero
      chipLabel.frame = .zero
    }
    chipAvatarView.layer.cornerRadius = chipAvatarView.bounds.width / 2

    for (index, item) in actionItems.enumerated() {
      guard index < plan.actionButtonFrames.count,
            index < plan.actionIconFrames.count,
            index < plan.actionLabelFrames.count else {
        break
      }
      let button = plan.actionButtonFrames[index]
      item.frame = cardRect(button) ?? .zero
      let icon = plan.actionIconFrames[index]
      let label = plan.actionLabelFrames[index]
      item.layout(
        iconFrame: icon.offsetBy(dx: -button.minX, dy: -button.minY),
        labelFrame: label.offsetBy(dx: -button.minX, dy: -button.minY)
      )
    }

    // 静态文字一次性交给画布。frame 上面已由 place() 写好，这里只决定"画哪些"：
    // 未显示的段由 update 按 isHidden 过滤（isHidden 就是配置代码的显示语义）。
    // 传模型身份 + 色板：画布据此取缓存位图，命中则完全跳过光栅化。
    textCanvas.update(
      labels: [
        displayNameLabel, metaLabel, ipLabel,
        titleLabel, abstractLabel, showMoreLabel,
        quoteForumLabel, quoteTitleLabel, quoteContentLabel,
      ],
      model: model,
      palette: palette
    )
  }

  /// 行坐标 → 卡片坐标。
  private func cardRect(_ rect: CGRect?) -> CGRect? {
    guard let rect else { return nil }
    return rect.offsetBy(
      dx: -TiebaFeedRowLayout.cardMarginH,
      dy: -TiebaFeedRowLayout.cardMarginV
    )
  }

  // MARK: - 媒体命中查询（列表侧点击分发用；本视图仍不装任何手势）

  /// 点位命中查询：行坐标（行视图坐标系）点 → 媒体下标 + 该图当前可见矩形（行坐标）。
  ///
  /// 图片带的"按下的是第几张"只能由内部 scroll offset 派生：帧计划
  /// （`mediaItemFrames`）是滚动内容坐标，视口 `contentOffset` 变了它不变。
  /// 这里把每格的 frame 先减去 `contentOffset.x` 换算进行坐标（mediaFrame 就是
  /// 视口），再取**真的包含该点**的那一格。
  ///
  /// ⚠️ 命中必须落在图上（可见矩形内）：图片带的视口是**整张卡的宽度**（首图左边
  /// 的 leadInset 与末图之后的余量都在视口里），取"离点最近的一格"会让点这些空白区
  /// 也进大图浏览（用户 2026-09-15 报"点第一张图左边的空白区直接进大图"）。空白区
  /// 不命中 → 落回整卡点击（进帖），与旧 JS 每张图各自一个 Pressable 的行为一致。
  ///
  /// - Returns: `(index, rect)`；`index` 是 `model.media` 的下标（查看器
  ///   initialIndex 直接用），`rect` 是**与该图滚动视口相交后的可见部分**
  ///   （行坐标；部分滑出屏的格不会给 Zoom 转场一个屏外矩形）。
  ///   nil = 模型缺失 / 无真实图片（视频 poster 行也走这里 → nil，列表侧
  ///   不得把 poster 当图片查看器输入）/ 点不在媒体区或不在任何一张图上。
  /// - Note: 纯只读几何查询，不触发交互、不发事件，不破坏 (pageKey, index)
  ///   单 prop 契约（无新增 prop）。
  public func mediaHit(atRowPoint point: CGPoint) -> (index: Int, rect: CGRect)? {
    guard let model, !model.isTopBanner, model.showsMedia, !model.media.isEmpty else { return nil }
    // ⚠️ 帧计划本身就是行坐标（cardRect 只给 cardView 的子视图用）：入点是行坐标、
    // 返回矩形也按行坐标给；套 cardRect 会让命中区与转场矩形整体偏一个卡片原点。
    guard let mediaFrame = model.plan.mediaFrame,
          mediaFrame.width > 1, mediaFrame.height > 1,
          mediaFrame.contains(point) else { return nil }
    guard model.mediaIsStrip else { return (0, mediaFrame) }

    for candidate in stripVisibleFrames(mediaFrame: mediaFrame) where candidate.rect.contains(point) {
      return (candidate.index, candidate.rect)
    }
    return nil
  }

  /// 查看器退出重算用：行坐标下第 index 张图的**当前可见矩形**（与 mediaHit 同一份
  /// 带内换算）。nil = 越界 / 滑出视口，调用方据此走框架 Fade。
  public func mediaVisibleRect(atMediaIndex index: Int) -> CGRect? {
    guard let model, !model.isTopBanner, model.showsMedia,
          model.media.indices.contains(index) else { return nil }
    guard let mediaFrame = model.plan.mediaFrame,
          mediaFrame.width > 1, mediaFrame.height > 1 else { return nil }
    // 单图：整格即目标（与 mediaHit 的 (0, mediaFrame) 同源）。
    guard model.mediaIsStrip else { return index == 0 ? mediaFrame : nil }
    return stripVisibleFrames(mediaFrame: mediaFrame).first { $0.index == index }?.rect
  }

  /// 图片带逐格换算：内容坐标 → 行坐标（偏移 -contentOffset.x，视口 = mediaFrame）
  /// 再求交。mediaHit 与 mediaVisibleRect 共用，禁止另写一套换算。
  private func stripVisibleFrames(mediaFrame: CGRect) -> [(index: Int, rect: CGRect)] {
    guard let model else { return [] }
    let offsetX = stripScrollView.contentOffset.x
    var result: [(index: Int, rect: CGRect)] = []
    for (index, frame) in model.plan.mediaItemFrames.enumerated() {
      let rowFrame = frame.offsetBy(dx: mediaFrame.minX - offsetX, dy: mediaFrame.minY)
      let visible = rowFrame.intersection(mediaFrame)
      // 可见宽 < 2pt 视为滑出：按它做转场会得到屏外/退化矩形。
      guard !visible.isNull, visible.width >= 2, visible.height >= 2 else { continue }
      result.append((index, visible))
    }
    return result
  }

  /// 转场源图：行内第 index 张图已加载的那张压缩图（imageView 铺满该格，
  /// 所以 mediaHit/mediaVisibleRect 给的矩形就是它的窗口矩形）。交给查看器当
  /// 权威源，省掉"窗口扫描找 imageView、找不到就按矩形截屏"那条会截到整张卡片的兜底。
  /// ⚠️ 单图行必须也走这里：它的图在 singleMediaView（不是横滑带），漏掉就会落回
  /// 窗口扫描——图被屏幕边缘裁掉时矩形被揭示移位改过，扫描会扫到卡片里的吧头像。
  public func mediaImage(at index: Int) -> UIImage? {
    guard let model, !model.isTopBanner, model.showsMedia,
          model.media.indices.contains(index) else { return nil }
    guard model.mediaIsStrip else {
      return index == 0 ? singleMediaView.transitionSourceImage : nil
    }
    guard stripItems.indices.contains(index) else { return nil }
    return stripItems[index].transitionSourceImage
  }

  /// 行坐标点是否落在行内自管交互控件（右上角菜单钮）上：cell 的整卡点击
  /// 手势先问这里，命中则不放行——否则点菜单会同时进帖（菜单面板与帖子页
  /// 双跳）。操作栏三键不在此列：它们的按压反馈（UIControl 跟踪）不吞 touch，
  /// 动作语义仍走整卡点击的 region=action。
  public func ownsInteraction(atRowPoint point: CGPoint) -> Bool {
    guard !menuButton.isHidden else { return false }
    // 与按钮 point(inside:) 同一 hitFrame：命中区（44pt）让位的范围必须覆盖
    // 按钮真实可点范围，否则外扩圈内的点击会同时弹菜单又进帖。
    return menuButton.hitFrame.contains(menuButton.convert(point, from: self))
  }

  private func place(_ view: UIView, _ rect: CGRect?) {
    view.frame = cardRect(rect) ?? .zero
  }

  private func placeBanner(_ view: UIView, _ rect: CGRect?, in bannerFrame: CGRect) {
    guard let rect else {
      view.frame = .zero
      return
    }
    view.frame = rect.offsetBy(dx: -bannerFrame.minX, dy: -bannerFrame.minY)
  }

  // MARK: - 外观切换（layer 的 CGColor 不会自动跟随动态色）

  /// 外观档变化时重解析 CGColor（由 styleRegistration 触发；换色板时也直接调）。
  private func refreshDynamicLayerColors() {
    // 画布位图里烘的是具体颜色：深浅档一变，旧位图必须整表作废，否则深色下仍贴浅色字形。
    // 同时清 placedToken 强制下一次布局重摆——**不在这里就地重烘**：调用方（applyPalette /
    // trait 回调）此刻还没 configure，label 上可能仍是旧色，重烘会把旧色存进新键。
    TiebaFeedRowTextCanvas.invalidateCache()
    placedToken = nil
    setNeedsLayout()
    cardView.layer.borderColor = palette.borderCard
      .resolvedColor(with: traitCollection).cgColor
    quoteCard.layer.borderColor = palette.separator
      .resolvedColor(with: traitCollection).cgColor
    bannerHairline.backgroundColor = palette.borderCard
  }

  // MARK: - 图片带计数角标（仅展示，不触发任何动作）

  public func scrollViewDidScroll(_ scrollView: UIScrollView) {
    guard scrollView === stripScrollView, !stripFrames.isEmpty else { return }
    // 横滑把新格带进视口 → 补发它们的图片（幂等：已发过的不再发）。
    extendStripLoadWindow(offsetX: scrollView.contentOffset.x)
    let center = scrollView.contentOffset.x + scrollView.bounds.width / 2
    var index = 0
    for (i, frame) in stripFrames.enumerated() {
      if frame.midX <= center {
        index = i
      } else {
        break
      }
    }
    guard index != stripActiveIndex else { return }
    stripActiveIndex = index
    stripCountLabel.text = "\(index + 1)/\(stripTotalCount)"
  }

  /// 图片带懒加载：只给"可见 + 2 格"发图片请求（幂等，已发过的下标跳过）。
  ///
  /// 为什么：一行最多 9 张，以前挂上就全解——其中六七张用户根本没横滑到，解码、
  /// 内存缓存、纹理全白做，还把内存图片缓存挤掉（往回滚要重解）。窗口往后多留
  /// 2 格是横滑余量：正常速度横滑时下一格已经在位，不会看到占位块。没进窗口的
  /// 格保持占位底色（与"图还没到"同观感）。
  ///
  /// 显示尺寸取帧计划里这一格的真实尺寸：宽图会被 plan 钳到 300pt，按未钳的
  /// stripHeight×aspect 取图会多解一倍像素，且 fit 档在 aspectFill 视图里还会被放大（糊）。
  private func extendStripLoadWindow(offsetX: CGFloat) {
    guard let model, let mediaFrame = model.plan.mediaFrame, mediaFrame.width > 0 else { return }
    let frames = model.plan.mediaItemFrames
    guard !frames.isEmpty else { return }
    var first = frames.count
    var last = -1
    let visibleMaxX = offsetX + mediaFrame.width
    for (index, frame) in frames.enumerated() where frame.maxX > offsetX && frame.minX < visibleMaxX {
      first = min(first, index)
      last = max(last, index)
    }
    guard last >= first else { return }
    let margin = 2
    let scale = max(traitCollection.displayScale, 1)
    for index in max(first - margin, 0)...min(last + margin, frames.count - 1) {
      guard stripLoadedIndexes.insert(index).inserted,
            stripItems.indices.contains(index),
            model.media.indices.contains(index)
      else { continue }
      stripItems[index].loadDisplay(
        url: model.media[index].url,
        targetSize: frames[index].size,
        cornerRadius: 0,
        scale: scale
      )
    }
  }
}
