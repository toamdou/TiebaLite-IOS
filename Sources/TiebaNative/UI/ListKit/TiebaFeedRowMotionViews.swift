// 从 TiebaFeedRowView.swift 拆出（H10 千行文件拆分）：主类之前的独立类型（整类型逐字搬运，仅下列声明放宽访问级）。
// 主类留在原文件：它的扩展要用到类内 private，同文件才合法。

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

// MARK: - 右上角菜单钮（UIButton.Configuration + 44pt 命中区）

/// 卡片右上角「更多」钮：26×26 槽位、ellipsis、textTertiary（与帖子页的更多钮同形）。
/// 原设计是 xmark（RN closeButton 直译），但它的动作是弹出「不感兴趣/屏蔽/复制标题」
/// 菜单、并非关闭卡片，iOS 信息流此处惯例也是省略号（2026-09-19 改）。
// 访问级 private → internal（H10 拆分，Lead 裁决 B）：final 被留在 TiebaFeedRowView.swift 的主类 TiebaFeedRowView 引用，
// 拆分后跨文件 private 不可见；只放宽这一处，其余成员访问级不动。
final class TiebaFeedRowMenuButton: UIButton {
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
      systemName: "ellipsis",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
    )
    config.contentInsets = .zero
    configuration = config
    isAccessibilityElement = true
    accessibilityLabel = "更多操作"
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
// 访问级 private → internal（H10 拆分，Lead 裁决 B）：let 被留在 TiebaFeedRowView.swift 的主类 TiebaFeedRowView 引用，
// 拆分后跨文件 private 不可见；只放宽这一处，其余成员访问级不动。
let tiebaBadgeBackground = UIColor.black.withAlphaComponent(0.55)

private final class TiebaFeedRowBadgeView: UIView {
  private let label = UILabel()
  private let iconView = UIImageView()
  private let iconWidth: CGFloat
  /// 无底模式（用户口径，GIF 角标专用）：不要胶囊底，纯白字 + 阴影压住亮图。
  private let backgroundless: Bool

  init(text: String, systemImage: String?, backgroundless: Bool = false) {
    self.backgroundless = backgroundless
    iconWidth = systemImage == nil ? 0 : 10
    super.init(frame: .zero)
    if backgroundless {
      backgroundColor = .clear
      // 阴影挂在 label 的层上：无底时白色文字需要暗描边才在浅图上可读
      //（容器层加阴影会连同透明背景一起被过滤掉，只能逐字描）。
      label.layer.shadowColor = UIColor.black.cgColor
      label.layer.shadowOpacity = 0.8
      label.layer.shadowRadius = 1.5
      label.layer.shadowOffset = CGSize(width: 0, height: 0.5)
    } else {
      backgroundColor = tiebaBadgeBackground
    }
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
    let padding: CGFloat = backgroundless ? 0 : 14
    let vertical: CGFloat = backgroundless ? 0 : 6
    let height = max(iconWidth, labelSize.height) + vertical
    // A7（移植自上游 submodules/TextBadgeComponent/Sources/TextBadgeComponent.swift:139）：
    // 徽章底"至少是个圆" —— 单字符（"1"、"图"）算出来比高还窄时把宽撑到与高相等，
    // 否则是一个竖椭圆。多字符徽章本来就更宽，这一项不改变它们。
    return CGSize(
      width: max(iconWidth + gap + labelSize.width + padding, height),
      height: height
    )
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    // A7（上游 :154 的 generateStretchableFilledCircleImage + template tint）：圆角按**当前**
    // 高度取半，而不是钉死 10 —— 纯色填充下这与"可拉伸圆头图"逐像素等价，字号/内边距变了
    // 也仍是胶囊（固定半径在高度变大时会退化成圆角矩形）。无底模式没有底。
    if !backgroundless {
      layer.cornerRadius = bounds.height / 2
    }
    let gap: CGFloat = iconWidth > 0 ? 3 : 0
    let horizontal: CGFloat = backgroundless ? 0 : 7
    iconView.frame = CGRect(x: horizontal, y: (bounds.height - iconWidth) / 2, width: iconWidth, height: iconWidth)
    label.frame = CGRect(
      x: horizontal + iconWidth + gap,
      y: 0,
      width: max(bounds.width - horizontal * 2 - iconWidth - gap, 0),
      height: bounds.height
    )
  }
}

// MARK: - 媒体单元（单图 / 图片带一格 / 视频 poster 共用）

// 访问级 private → internal（H10 拆分，Lead 裁决 B）：final 被留在 TiebaFeedRowView.swift 的主类 TiebaFeedRowView 引用，
// 拆分后跨文件 private 不可见；只放宽这一处，其余成员访问级不动。
final class TiebaFeedRowMediaItemView: UIView {
  // TiebaGIFImageView：GIF 档由 UI/Media/TiebaGIFPlayer 逐帧渲染，静态档当普通 UIImageView 用。
  // 行视图这里只创建、不播放：列表卡片显示的是服务端下发的**静态档**（GIF 三档口径见 TiebaNuke），
  // 真正播放在进帖/查看器里发生；所以这个 player 只有在别处调用 play 时才会启表。
  private let imageView = TiebaGIFImageView()

  /// 进帖转场的图片配对用（同模块内部）：媒体项不持有 threadId，由行视图下发 id。
  var heroImageView: UIView { imageView }
  /// 当前已解好的位图（列表→详情快照把它带给占位卡，避免进帖先显示灰底）。
  var loadedImage: UIImage? { imageView.image }
  private let longBadge = TiebaFeedRowBadgeView(text: "长图", systemImage: "arrow.down")
  private let gifBadge = TiebaFeedRowBadgeView(text: "GIF", systemImage: nil, backgroundless: true)

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
    // 不再 clipsToBounds：静态图的圆角由管线烘焙进位图（displayProcessor/
    // fitDisplayProcessor，位图与显示框逐像素等价），裁切挂在每帧离屏合成上
    // （仓内 TiebaPostRowView 同结论）。GIF 档例外：tiebaLoadGifImage 里临时
    // 开回 clipsToBounds（帧不烘焙圆角）。cornerRadius 仍保留——它裁的是本层
    // 占位底色（纯色随圆角自动剪裁，不需要 masksToBounds）。
    clipsToBounds = false
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
    TiebaHeroTransition.clear(imageView)
    cancelRequest(for: imageView)
    // 复用必须走 prepareForGIFReuse()：它 = recycle()（停表 + **真释放帧缓存** + 释放 CGImageSource）。
    // 老的 Gifu 只提供 stopAnimatingGIF()，那只暂停 animator、帧缓冲一个都不放，
    // 滚动一遍 feed 就把沿途所有 GIF 的整窗帧缓冲攒在内存里 —— 这正是换掉它的原因之一。
    imageView.prepareForGIFReuse()
    imageView.image = nil
    longBadge.isHidden = true
    gifBadge.isHidden = true
    moreOverlay.isHidden = true
    playBadge.isHidden = true
    moreLabel.text = nil
    contextMenuEnabled = false
    syncContextMenuInteraction()
    fullURL = nil
    gifProbeCandidates = []
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

    longBadge.isHidden = media?.isLong != true
    gifBadge.isHidden = true
    if !longBadge.isHidden { longBadge.sizeToFit() }
    // GIF 角标：HEAD 探测零流量判定；探测目标是动图档（src_pic），命中即亮标。
    // 卡片只标不播——播放入口在进帖行与大图查看器（见 TiebaNuke「GIF 三档」注）。
    if !isVideoPoster {
      gifProbeCandidates = [media?.animatedURL, media?.originURL]
      probeGIFBadge()
    } else {
      gifProbeCandidates = []
    }

    if remainingCount > 0 {
      moreOverlay.isHidden = false
      moreLabel.text = "+\(remainingCount)"
    } else {
      moreOverlay.isHidden = true
      moreLabel.text = nil
    }

    playBadge.isHidden = !isVideoPoster
  }

  /// GIF 探测代次：复用换内容后旧探测结果不再回贴角标。
  private var gifProbeGeneration = 0
  /// 本卡的 GIF 判定候选链（动图档 src_pic → 原图档 origin_pic）。
  /// [修复 2026-10-06] 原来只探动图档：服务端没下发 src_pic 的卡片（历史/搜索/部分信息流）
  /// 候选为空 → 一次都不探测 → 角标永远不亮。原图档在 GIF 时与动图档同字节（线上 25/25）。
  private var gifProbeCandidates: [URL?] = []

  private func probeGIFBadge() {
    let candidates = gifProbeCandidates
    guard candidates.contains(where: { $0 != nil }) else { return }
    gifProbeGeneration += 1
    let generation = gifProbeGeneration
    Task { [weak self] in
      guard await TiebaNuke.firstGIFURL(among: candidates) != nil else { return }
      guard let self, self.gifProbeGeneration == generation,
            self.gifProbeCandidates == candidates else { return }
      self.gifBadge.isHidden = false
      self.gifBadge.sizeToFit()
      self.setNeedsLayout()
    }
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

  /// 单图 fit 显示档：fit 缩放 + 圆角烘焙（见 TiebaNuke.fitDisplayProcessor），
  /// 配合容器 clipsToBounds = false 去掉每帧离屏合成。
  func loadFitDisplay(url: URL?, targetSize: CGSize, cornerRadius: CGFloat, scale: CGFloat) {
    tiebaLoadFitDisplayImage(
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
    // [采用] 惯性滚动中长按一律不成立 —— 与 TiebaPostRowView 同一守卫（审计 15 号指出此处漏加）。
    // 本视图是 feed 行**唯一的长按入口**，菜单动作带 mediaIndex（见下方），
    // 列表在减速中复用 cell 后会把它落到错的图上，比落错楼层更隐蔽。
    if let host = interaction.view,
       !TiebaDecelerationGuard.shouldAllowLongPress(at: location, in: host) {
      return nil
    }
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
// 访问级 private → internal（H10 拆分，Lead 裁决 B）：final 被留在 TiebaFeedRowView.swift 的主类 TiebaFeedRowView 引用，
// 拆分后跨文件 private 不可见；只放宽这一处，其余成员访问级不动。
final class TiebaFeedRowActionView: UIControl {
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
/// 绘制走 NSAttributedString.draw(with:options:context:)——与 UILabel 底层同一套排版
/// （图形/字体/行高都在属性串里），但**不需要 UIView 参与**。相比上一版把 9 段文字交给
/// 9 个隐藏 label：每行少 9 个视图对象、少 9 次 trait 传播。
///
/// **位图烘制已搬出主线程**（见 BitmapPipeline/，报告 07 的阶段 1+2）：
///   - 命中缓存 → 直接写 layer.contents（与旧路径逐字一致）；
///   - 滚动中未命中 → TiebaFeedBitmapBaker 后台烘，结果回主校验代次后再 attach
///     （对应 ASDK 的 displayBlock + _displaySentinel，ASDisplayNode+AsyncDisplay.mm:341-382）；
///   - 静止 / 首屏未命中 → 同步兜底一帧（对应 _ASDisplayLayer.mm:150-158 的 displayImmediately）。
/// 画布自己是 layer.contents 的**唯一所有者**：后台结果与预取产物都不直接碰图层。
///
/// 行数限制由 frame 高度承担，不用 numberOfLines：折叠态 title/abstract 的 frame 高度
/// 正是按 maxLines 量出来的，配 .truncatesLastVisibleLine 即在末行加省略号
///（NSStringDrawingContext.maximumNumberOfLines 是私有属性，SDK 头文件里没有，不采用）。
///
/// 坐标系（**容易写错，务必按这条来**）：plan 里所有 frame 都是**行坐标**——它的
/// cardX = cardMarginH、cardY = cardMarginV，即行内容的左上角加了卡片外边距。
/// 而画布是 cardView 的子视图，原点是卡片左上角 ⇒ 画布坐标 = 行坐标 − (cardMarginH,
/// cardMarginV)。所以喂给画布的每一段 frame 都要过 cardRect()（子视图走 place() 是同
/// 一条转换）。
/// ⚠️ 这里曾写成"画布与 plan 的 frame 同属 cardView 局部坐标、零换算"，照它做就漏掉转换，
/// 整组文字右下各偏 (16, 4)：名字压到头像下沿、标题右端顶出画布被提前截断（而截断是绘制
/// 期才知道的，测量期判不出截断 ⇒「显示更多」不出现）。
/// [可见性] 由 private 放开为模块内可见：内存告警入口在 App/TiebaAppBootstrap 要调
/// `invalidateCache()`（复检 P2-4），只放开这一个类型、不改任何行为。
final class TiebaFeedRowTextCanvas: UIView {
  /// 一段要画的文字：**已完全解析**的属性串（字体/颜色/行高都烘进属性里）+ 绘制矩形。
  ///
  /// 不持有 UILabel：绘制走 NSAttributedString.draw(with:options:context:)——与 UILabel
  /// 底层同一套排版，但不需要 UIView 参与。这带来两件事：每行少 9 个视图对象，
  /// 且该原语不绑主线程（它就是异步位图管线的输入）。
  /// **直接复用管线载荷**（原先这里是另立的一个同形 struct）：画布输入 = Job 输入，
  /// 同一份 runs 既喂本帧同步绘制、也喂后台烘制 / 预取。两份定义一旦漂移，预取烘出来的
  /// 位图就会与画布要画的不是同一张 —— 缓存键里**不含 runs**，只认
  /// (model, size, scale, styleRaw, paletteFingerprint)。
  /// naturalHeight 的语义见 BitmapPipeline/TiebaFeedBitmapJob.swift 的 Run：
  /// **阶段 0**：测量期预算的自然高（绘制期垂直居中用，省掉第二遍 CoreText 排版）。
  /// nil = 该段还没接上测量值，绘制期回落「有界量高」（= 旧行为，多一趟排版）。
  /// 画布这侧能直接给出的按行高给（名字/元信息/IP/显示更多/引用帖两段）；title /
  /// abstract / quoteContent 三段取 TiebaRowMetrics 测出的**未取整 usedRect 高**
  ///（exactHeight → blocks → plan.natural*Height）。9 段全接上后回落分支不再走到。
  typealias Run = TiebaFeedBitmapJob.Run

  /// 取消代次（并发三条铁律第 ③ 条）：主线程单调递增，后台烘制线程只读它。
  /// 换行/复用（clear）与换内容（update）都会自增 ⇒ 在途结果全部作废 ——
  /// 这就是四级取消里的第 1、2 级（换行/复用、换主题/换色板都经这两处）。
  private let epochBox = TiebaFeedBitmapEpoch()

  private var runs: [Run] = []
  private var bakedModel: AnyObject?
  private var bakedPalette: TiebaFeedRowPalette?

  override init(frame: CGRect) {
    super.init(frame: frame)
    isOpaque = false
    backgroundColor = .clear
    // [长按卡片菜单] 画布原来是纯绘制层（关交互）：卡片长按菜单的宿主就挂在它上面。
    // 选它的原因是"命中链互不相交"——画布覆盖整卡、却压在图片/头像/徽章/操作栏等
    // 子视图**之下**：手指落在那张图上时画布根本不在命中链里，图片那套长按菜单原样
    // 生效；落在文字/卡面空白上才命中画布。同一行因此绝不会有两套长按抢手势。
    // 详见 TiebaFeedRowView.syncCardMenuInteraction()。
    isUserInteractionEnabled = true
    isAccessibilityElement = false
    accessibilityElementsHidden = true
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  /// 收集本轮要画的文字，并按 (模型, 色板, 尺寸, 缩放, 深浅档) 取或烘位图。
  /// frame 已在 plan 里算好（卡片坐标），画布与 labelHost 同在 (0,0) 同尺寸，零换算。
  func update(runs: [Run], model: AnyObject, palette: TiebaFeedRowPalette) {
    self.runs = runs
    bakedModel = model
    bakedPalette = palette
    // 先自增代次再取/烘：上一次的在途结果即使回来也不认（对应 _ASDisplayLayer.mm:188-193
    // 的 setNeedsDisplay → cancelAsyncDisplay）。
    applyBitmap(epoch: epochBox.next())
  }

  /// 清空（无模型 / 置顶横幅行：卡片整体隐藏，内容不该留着上一行的位图）。
  func clear() {
    runs = []
    bakedModel = nil
    bakedPalette = nil
    epochBox.next()   // 置空同样要作废在途结果，否则上一行的位图会贴到复用的行上
    setContents(nil)
  }

  /// 外观档或色板变化时由宿主调用：整表作废。
  /// **不在这里重烘**——applyPalette 是"先刷 layer 色、后 configure 文案色"，
  /// 此刻属性串可能还是旧色，重烘会把旧色位图存进新键。宿主清掉 placedToken 后
  /// 必然走一次完整布局，由 update 用配色完成的 runs 重烘。
  static func invalidateCache() {
    TiebaFeedBitmapStore.shared.invalidate()
  }

  // MARK: 位图

  private var scaleForDisplay: CGFloat { max(traitCollection.displayScale, 1) }

  /// 取缓存 / 烘位图 / attach。三个分支与旧实现一一对应，只是"未命中"这一支
  /// 拆成了滚动中（后台）与静止（同步兜底）—— 对应 ASDK 的 range controller 与
  /// displayImmediately 的分工。**不要无条件异步化**：那会让每张新卡空窗 1-2 帧。
  private func applyBitmap(epoch: UInt64) {
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
    let traits = traitCollection
    // 缓存键 = 所有会影响像素的输入：模型身份 + 尺寸 + 缩放 + 深浅档 + 色板指纹。
    // ⚠️ 色板必须用 bitmapFingerprint（混 cgColor 分量），不能用 UIColor.hash ——
    // 动态色的 hash 只反映"这是动态色"这一身份，深浅两档会撞档（报告 07 §6 R1）。
    let key = TiebaFeedBitmapKey(
      model: ObjectIdentifier(model),
      size: size,
      scale: scale,
      styleRaw: traits.userInterfaceStyle.rawValue,
      paletteFingerprint: palette.bitmapFingerprint(in: traits)
    )
    if let image = TiebaFeedBitmapStore.shared.image(for: key) {
      setContents(image)
      return
    }
    // 未命中：**不要 setContents(nil)** —— 旧 contents 就是滚动期最合适的占位
    //（换行时 clear() 已经置空，那是另一回事）。
    let job = TiebaFeedBitmapJob(
      key: key,
      // Run 就是 TiebaFeedBitmapJob.Run（见画布的 typealias）：零转换、零拷贝。
      runs: runs,
      size: size,
      scale: scale,
      opaque: false,
      epoch: epoch
    )

    // 滚动中：后台烘，本帧不排版（提前量的正解是预取，见报告 07 §5.5）。
    // B1（移植自上游 submodules/RasterizedCompositionComponent/Sources/RasterizedCompositionComponent.swift:90-104
    // 的 hasAnimationsInTree、:379-387 的模式切换）：**本行在播动画时不做同步重烘** ——
    // 同步绘制会把动画那一帧顶掉。上游判据是"子树里有动画就用真图层、否则整棵栅格化"；
    // 本仓画布是叶子层、动画挂在行宿主层上，所以判据向上看（见 isRowAnimating）。
    // 只在已有 contents 时改走后台：首帧不兜底会白屏（见上方"不要无条件异步化"）。
    if TiebaFeedScrollGate.shared.isScrolling(in: self)
      || (self.isRowAnimating && self.layer.contents != nil) {
      // 只把 Atomic 的代次盒与模型身份箱带过线程边界：**不捕获 UIView**（哪怕是弱引用），
      // 后台从头到尾不碰任何共享可变状态。
      let box = epochBox
      let token = TiebaFeedBitmapModelToken(model)
      TiebaFeedBitmapBaker.shared.submit(
        job,
        traits: traits,
        epochProbe: { box.probe() }
      ) { [weak self] result in
        guard let result else { return }   // 被取消 / 绘制失败：保留旧 contents，不闪白
        Task { @MainActor in
          // 二次校验（对应 ASDisplayNode+AsyncDisplay.mm:365 的主线程再查一次）：
          // 代次仍是我这份、尺寸也没被换过，才允许写 layer.contents。
          guard let self, box.probe() == result.epoch, self.bounds.size == job.size else {
            return
          }
          TiebaFeedBitmapStore.shared.insert(result, model: token.model)
          self.setContents(result.image)
        }
      }
      return
    }

    // 静止 / 首屏：同步兜底一帧（用户看不到掉帧）。滚动中走到这里 = 本管线要消灭的开销。
    guard let image = TiebaFeedBitmapBaker.shared.renderSync(job, traits: traits) else {
      setContents(nil)   // 真失败（不是取消）：宁可空着，也不要留着上一行的位图
      return
    }
    TiebaFeedBitmapStore.shared.insert(
      image: image,
      key: key,
      bytes: job.byteCount,
      model: model
    )
    setContents(image)
  }

  /// 本行（自己 + 全部祖先层）是否有在跑的动画 —— 上游 hasAnimationsInTree 的对应物
  /// （RasterizedCompositionComponent.swift:90-104）。本仓的入场/点赞弹簧挂在行的宿主层上，
  /// 画布自己是叶子层，所以判据必须向上看。
  private var isRowAnimating: Bool {
    var current: CALayer? = self.layer
    while let layer = current {
      if let keys = layer.animationKeys(), !keys.isEmpty {
        return true
      }
      current = layer.superlayer
    }
    return false
  }

  /// 直接写 layer.contents（不走 draw(_:)）。必须关掉隐式动画：cell 复用换位图时
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

