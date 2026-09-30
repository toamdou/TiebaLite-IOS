// ============================================================
// TiebaLite — 骨架屏（TiebaSkeletonView）
//
// 迁移前 src/components/ui/Skeleton.tsx 的 UIKit 重建：thread/post/card/row
// 四种变体逐值复刻其 StyleSheet 几何（「同形」原则——尺寸不对的骨架比没有
// 更糟，真数据落地时页面会跳）；thread/post 行高由内容自然撑出，card/row 用
// 真实行高（232/88）。**高光扫过**（原 JS 的呼吸 opacity 已换掉，见
// TiebaSkeletonBoneView）：每格骨块自带一条斜向光带横掠，相邻格错开 0.12s
// 连成一道光波；Reduce Motion 时静态，且只在骨架真正可见（窗口 + 未隐藏 +
// 前台）时运行（JS 2026-09-12 发热审查的同款治理，避免后台空转）。
//
// 占位色 = surfaceTertiary（systemGray5）。禁用 surfaceSecondary /
// secondarySystemBackground —— 亮色下两者与页面背景同为 #F2F2F7，骨架块
// 贴在背景上完全隐形（历史上"骨架屏消失"的根因）。
// ============================================================

import UIKit

// MARK: - 变体

/// 骨架形状（对齐 Skeleton.tsx 的 SkeletonVariant）。
enum TiebaSkeletonVariant: String {
  /// 信息流卡片（TweetCard 同形，含媒体块，半数带图交替）
  case thread
  /// 楼层卡（PostCard 同形）
  case post
  /// 大图 160 + 标题 + 两行
  case card
  /// 36 圆头像 + 两行文本
  case row

  /// thread/post 由内容自然撑高（与真实卡片同构，真卡片落地零位移）。
  var isNaturalHeight: Bool { self == .thread || self == .post }

  /// 固定行高变体的缺省行高 = 各界面真实行高（card 大图 232 / row 通用行 88）。
  var defaultItemHeight: CGFloat? {
    switch self {
    case .card: return 232
    case .row: return 88
    case .thread, .post: return nil
    }
  }
}

// MARK: - 几何常量（Skeleton.tsx StyleSheet / TweetCard / PostCard 单一来源）

/// 卡片行几何（外边距/内距/头像/内容列/操作栏）**直接引用 TiebaFeedRowLayout**，
/// 不在本文件另抄一套；这里只放骨架独有的圆角/间距/post 卡几何。
private enum TiebaSkeletonMetrics {
  /// 圆角：chip 8 / card 20 / cardLarge 24（Radius + RadiusStyle，连续曲率）
  static let chipRadius: CGFloat = 8
  static let cardRadius: CGFloat = 20
  static let cardLargeRadius: CGFloat = 24
  /// 媒体块圆角 = MediaPager 图片圆角（Radius.card - 4）
  static let mediaRadius: CGFloat = cardRadius - 4
  /// 列表行距（SkeletonList list gap = Spacing.md）
  static let listGap: CGFloat = 12
  static let gapSmall: CGFloat = 8
  static let gapTiny: CGFloat = 4
  // post 楼层卡（PostCard 同形：padding 16 / 头像 36 / 头部 marginBottom 10）
  static let postPadding: CGFloat = 16
  static let postAvatar: CGFloat = 36
  static let postHeaderBottom: CGFloat = 10
  static let postBodyGap: CGFloat = 8
  static let postActionTop: CGFloat = 12
  /// 卡片细描边 = hairline（StyleSheet.hairlineWidth）：取调用视图 trait 的
  /// displayScale（UIScreen.main 自 iOS 26 起废弃）。
  static func hairline(for traits: UITraitCollection) -> CGFloat {
    1 / max(traits.displayScale, 1)
  }
}

// MARK: - 骨块（高光扫过）

/// 骨架占位块。高光扫过 = 每个骨块自带一条斜向白带横掠而过：动画走 `locations`
/// （比例坐标，与骨块尺寸无关，旋转/换变体不必重启动画），全程在渲染服务器侧，
/// 主线程零参与。不可见 / Reduce Motion / 进后台时整组停掉（见 TiebaSkeletonList）。
///
/// 光带是 sublayer，只有 `masksToBounds` 能把它裁进圆角（含连续曲率）——本文件唯一
/// 裁切点。骨块是纯色小块、无位图内容，且骨架只在首屏加载期可见，代价可忽略。
final class TiebaSkeletonBoneView: UIView {
  /// 光带：clear → 高光 → clear；起点/终点落在骨块之外，末段停在画外 = 两次之间的间隔。
  private let shimmer = CAGradientLayer()
  private var isShimmering = false
  private var shimmerDelay: CFTimeInterval = 0
  private var shimmerHighlight: UIColor = .white

  init(radius: CGFloat) {
    super.init(frame: .zero)
    layer.cornerRadius = radius
    layer.cornerCurve = .continuous
    layer.masksToBounds = true
    shimmer.startPoint = CGPoint(x: 0, y: 0)
    shimmer.endPoint = CGPoint(x: 1, y: 0.55) // 斜向扫过
    shimmer.locations = [-0.6, -0.44, -0.28]
    layer.addSublayer(shimmer)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func layoutSubviews() {
    super.layoutSubviews()
    shimmer.frame = bounds
  }

  /// 高光色（动态色：CGColor 不随外观走，trait 变化时由调用方重解析）。
  func setShimmerHighlight(_ color: UIColor) {
    shimmerHighlight = color
    refreshShimmerColors()
  }

  func refreshShimmerColors() {
    shimmer.colors = [
      UIColor.clear.cgColor,
      shimmerHighlight.resolvedColor(with: traitCollection).cgColor,
      UIColor.clear.cgColor,
    ]
  }

  /// 可见才扫。delay 用于让相邻骨架格错开一点，看着像一道光波往下走。
  func setShimmering(_ on: Bool, delay: CFTimeInterval = 0) {
    guard on != isShimmering || (on && delay != shimmerDelay) else { return }
    isShimmering = on
    shimmerDelay = delay
    shimmer.removeAnimation(forKey: "shimmer")
    guard on else { return }
    let sweep = CAKeyframeAnimation(keyPath: "locations")
    sweep.values = [
      [-0.6, -0.44, -0.28] as [NSNumber],
      [1.28, 1.44, 1.6] as [NSNumber],
      [1.28, 1.44, 1.6] as [NSNumber],
    ]
    sweep.keyTimes = [0, 0.78, 1]
    sweep.duration = 1.6
    sweep.repeatCount = .infinity
    sweep.timingFunctions = [
      CAMediaTimingFunction(name: .easeInEaseOut),
      CAMediaTimingFunction(name: .linear),
    ]
    sweep.beginTime = CACurrentMediaTime() + delay
    shimmer.add(sweep, forKey: "shimmer")
  }
}

// MARK: - 单个骨架单元

/// 单个骨架单元（对齐 Skeleton.tsx 的 SkeletonCell）。
final class TiebaSkeletonCellView: UIView {
  let variant: TiebaSkeletonVariant
  /// 全部占位块（每块自带扫光；卡面/描边不在其中，不闪）。
  private var bones: [TiebaSkeletonBoneView] = []

  private let placeholderColor: UIColor
  private let cardColor: UIColor
  private let borderColor: UIColor
  private var borderSurfaces: [UIView] = []
  private var mediaBlock: UIView?
  private var mediaHeightConstraint: NSLayoutConstraint?
  /// 外观档变化登记（registerForTraitChanges；traitCollectionDidChange 已废弃）。
  private var styleRegistration: UITraitChangeRegistration?

  /// 扫光高光色：浅色下白带压在 #E5E5EA 骨块上；深色下只给极淡一档。
  private static let shimmerHighlight = UIColor { traits in
    traits.userInterfaceStyle == .dark
      ? UIColor.white.withAlphaComponent(0.14)
      : UIColor.white.withAlphaComponent(0.55)
  }

  init(
    variant: TiebaSkeletonVariant,
    withMedia: Bool,
    placeholderColor: UIColor,
    cardColor: UIColor,
    borderColor: UIColor
  ) {
    self.variant = variant
    self.placeholderColor = placeholderColor
    self.cardColor = cardColor
    self.borderColor = borderColor
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    isAccessibilityElement = false
    switch variant {
    case .thread: buildThread(withMedia: withMedia)
    case .post: buildPost()
    case .card: buildCard()
    case .row: buildRow()
    }
    // 动态色转 CGColor 后不随外观走：首帧解析 + trait 真变时重解析。
    styleRegistration = registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
      (view: TiebaSkeletonCellView, _) in
      view.refreshBorderColors()
      view.refreshShimmerColors()
    }
    refreshBorderColors()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func layoutSubviews() {
    super.layoutSubviews()
    // thread 媒体块高 = round(内容列宽 × 0.75)（真实单图 4:3 钳制呈现）
    if let mediaBlock, let mediaHeightConstraint, let container = mediaBlock.superview {
      let height = (max(container.bounds.width, 0) * 0.75).rounded()
      if abs(mediaHeightConstraint.constant - height) > 0.5 {
        mediaHeightConstraint.constant = height
      }
    }
  }

  // MARK: 块工厂

  func setShimmering(_ on: Bool, delay: CFTimeInterval = 0) {
    for bone in bones {
      bone.setShimmering(on, delay: delay)
    }
  }

  private func refreshShimmerColors() {
    for bone in bones {
      bone.refreshShimmerColors()
    }
  }

  private func makeBlock(radius: CGFloat) -> UIView {
    let view = TiebaSkeletonBoneView(radius: radius)
    view.backgroundColor = placeholderColor
    view.setShimmerHighlight(Self.shimmerHighlight)
    view.translatesAutoresizingMaskIntoConstraints = false
    bones.append(view)
    return view
  }

  private func makeBar(height: CGFloat, width: CGFloat? = nil) -> UIView {
    let view = makeBlock(radius: TiebaSkeletonMetrics.chipRadius)
    view.heightAnchor.constraint(equalToConstant: height).isActive = true
    if let width {
      view.widthAnchor.constraint(equalToConstant: width).isActive = true
    }
    return view
  }

  /// 卡片面（背景 card + hairline 描边；layer 色随外观在 trait 变化时刷新）。
  private func makeSurface(radius: CGFloat) -> UIView {
    let view = UIView()
    view.backgroundColor = cardColor
    view.layer.cornerRadius = radius
    view.layer.cornerCurve = .continuous
    view.layer.borderWidth = TiebaSkeletonMetrics.hairline(for: traitCollection)
    view.translatesAutoresizingMaskIntoConstraints = false
    borderSurfaces.append(view)
    return view
  }

  /// layer 的 CGColor 不跟随动态色：外观档变化（styleRegistration）时重解析。
  private func refreshBorderColors() {
    let color = borderColor.resolvedColor(with: traitCollection).cgColor
    for surface in borderSurfaces {
      surface.layer.borderColor = color
    }
  }

  // MARK: thread（TweetCard 同形）

  private func buildThread(withMedia: Bool) {
    let surface = makeSurface(radius: TiebaSkeletonMetrics.cardRadius)
    addSubview(surface)
    let inner = UIView()
    inner.translatesAutoresizingMaskIntoConstraints = false
    surface.addSubview(inner)
    NSLayoutConstraint.activate([
      surface.leadingAnchor.constraint(equalTo: leadingAnchor, constant: TiebaFeedRowLayout.cardMarginH),
      surface.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -TiebaFeedRowLayout.cardMarginH),
      surface.topAnchor.constraint(equalTo: topAnchor, constant: TiebaFeedRowLayout.cardMarginV),
      surface.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -TiebaFeedRowLayout.cardMarginV),
      inner.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: TiebaFeedRowLayout.cardPaddingX),
      inner.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -TiebaFeedRowLayout.cardPaddingX),
      inner.topAnchor.constraint(equalTo: surface.topAnchor, constant: TiebaFeedRowLayout.cardPaddingTop),
      inner.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -TiebaFeedRowLayout.cardPaddingBottom),
    ])

    let avatar = makeBlock(radius: TiebaFeedRowLayout.avatarSize / 2)
    let nameBar = makeBar(height: 13, width: 132)
    let timeBar = makeBar(height: 11, width: 56)
    for view in [avatar, nameBar, timeBar] {
      inner.addSubview(view)
    }
    NSLayoutConstraint.activate([
      avatar.leadingAnchor.constraint(equalTo: inner.leadingAnchor),
      avatar.topAnchor.constraint(equalTo: inner.topAnchor),
      avatar.widthAnchor.constraint(equalToConstant: TiebaFeedRowLayout.avatarSize),
      avatar.heightAnchor.constraint(equalToConstant: TiebaFeedRowLayout.avatarSize),
      nameBar.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: TiebaFeedRowLayout.avatarGap),
      nameBar.centerYAnchor.constraint(equalTo: avatar.centerYAnchor),
      timeBar.leadingAnchor.constraint(equalTo: nameBar.trailingAnchor, constant: TiebaFeedRowLayout.avatarGap),
      timeBar.centerYAnchor.constraint(equalTo: avatar.centerYAnchor),
    ])

    let content = UIStackView()
    content.axis = .vertical
    content.spacing = TiebaFeedRowLayout.contentColumnGap
    // 百分比宽条不能被 fill 对齐拉伸：统一 leading + 显式宽度约束
    content.alignment = .leading
    content.translatesAutoresizingMaskIntoConstraints = false
    inner.addSubview(content)
    NSLayoutConstraint.activate([
      content.leadingAnchor.constraint(
        equalTo: inner.leadingAnchor,
        constant: TiebaFeedRowLayout.contentIndent
      ),
      content.trailingAnchor.constraint(equalTo: inner.trailingAnchor),
      content.topAnchor.constraint(
        equalTo: inner.topAnchor,
        constant: TiebaFeedRowLayout.avatarSize + TiebaFeedRowLayout.contentColumnTopOffset
      ),
      content.bottomAnchor.constraint(equalTo: inner.bottomAnchor),
    ])

    let title = makeBar(height: 16)
    let line1 = makeBar(height: 14)
    let line2 = makeBar(height: 14)
    content.addArrangedSubview(title)
    content.addArrangedSubview(line1)
    content.addArrangedSubview(line2)
    // 宽度约束必须在加入层级之后激活（否则无共同祖先，激活即崩）
    title.widthAnchor.constraint(equalTo: content.widthAnchor, multiplier: 0.88).isActive = true
    line1.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
    line2.widthAnchor.constraint(equalTo: content.widthAnchor, multiplier: 0.72).isActive = true

    var lastBodyBlock: UIView = line2
    if withMedia {
      let media = makeBlock(radius: TiebaSkeletonMetrics.mediaRadius)
      content.addArrangedSubview(media)
      media.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
      let height = media.heightAnchor.constraint(equalToConstant: 0)
      height.isActive = true
      mediaBlock = media
      mediaHeightConstraint = height
      lastBodyBlock = media
    }

    let actions = makeActionsRow()
    content.addArrangedSubview(actions)
    actions.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
    // 操作栏 marginTop 2（叠加 contentCol gap 6）
    content.setCustomSpacing(TiebaFeedRowLayout.contentColumnGap + 2, after: lastBodyBlock)
  }

  /// 操作栏：三等分，每组 17 圆图标 + 30×9 文本条（水平居中）。
  private func makeActionsRow() -> UIView {
    let row = UIStackView()
    row.axis = .horizontal
    row.distribution = .fillEqually
    row.translatesAutoresizingMaskIntoConstraints = false
    row.heightAnchor.constraint(equalToConstant: TiebaFeedRowLayout.actionRowMinHeight).isActive = true
    for _ in 0..<3 {
      let slot = UIView()
      slot.translatesAutoresizingMaskIntoConstraints = false
      let icon = makeBlock(radius: TiebaFeedRowLayout.actionIconSize / 2)
      icon.widthAnchor.constraint(equalToConstant: TiebaFeedRowLayout.actionIconSize).isActive = true
      icon.heightAnchor.constraint(equalToConstant: TiebaFeedRowLayout.actionIconSize).isActive = true
      let text = makeBar(height: 9, width: 30)
      let group = UIStackView(arrangedSubviews: [icon, text])
      group.axis = .horizontal
      group.spacing = TiebaFeedRowLayout.actionIconGap
      group.alignment = .center
      group.translatesAutoresizingMaskIntoConstraints = false
      slot.addSubview(group)
      NSLayoutConstraint.activate([
        group.centerXAnchor.constraint(equalTo: slot.centerXAnchor),
        group.centerYAnchor.constraint(equalTo: slot.centerYAnchor),
      ])
      row.addArrangedSubview(slot)
    }
    return row
  }

  // MARK: post（PostCard 同形）

  private func buildPost() {
    let surface = makeSurface(radius: TiebaSkeletonMetrics.cardRadius)
    addSubview(surface)
    let inner = UIView()
    inner.translatesAutoresizingMaskIntoConstraints = false
    surface.addSubview(inner)
    NSLayoutConstraint.activate([
      surface.leadingAnchor.constraint(equalTo: leadingAnchor, constant: TiebaFeedRowLayout.cardMarginH),
      surface.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -TiebaFeedRowLayout.cardMarginH),
      surface.topAnchor.constraint(equalTo: topAnchor, constant: TiebaFeedRowLayout.cardMarginV),
      surface.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -TiebaFeedRowLayout.cardMarginV),
      inner.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: TiebaSkeletonMetrics.postPadding),
      inner.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -TiebaSkeletonMetrics.postPadding),
      inner.topAnchor.constraint(equalTo: surface.topAnchor, constant: TiebaSkeletonMetrics.postPadding),
      inner.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -TiebaSkeletonMetrics.postPadding),
    ])

    let avatar = makeBlock(radius: TiebaSkeletonMetrics.postAvatar / 2)
    let nickBar = makeBar(height: 12, width: 110)
    for view in [avatar, nickBar] {
      inner.addSubview(view)
    }
    NSLayoutConstraint.activate([
      avatar.leadingAnchor.constraint(equalTo: inner.leadingAnchor),
      avatar.topAnchor.constraint(equalTo: inner.topAnchor),
      avatar.widthAnchor.constraint(equalToConstant: TiebaSkeletonMetrics.postAvatar),
      avatar.heightAnchor.constraint(equalToConstant: TiebaSkeletonMetrics.postAvatar),
      nickBar.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: TiebaFeedRowLayout.avatarGap),
      nickBar.centerYAnchor.constraint(equalTo: avatar.centerYAnchor),
    ])

    let body = UIStackView()
    body.axis = .vertical
    body.spacing = TiebaSkeletonMetrics.postBodyGap
    body.alignment = .leading
    body.translatesAutoresizingMaskIntoConstraints = false
    inner.addSubview(body)
    let body1 = makeBar(height: 14)
    let body2 = makeBar(height: 14)
    let body3 = makeBar(height: 14)
    for bar in [body1, body2, body3] {
      body.addArrangedSubview(bar)
    }
    body1.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
    body2.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
    body3.widthAnchor.constraint(equalTo: body.widthAnchor, multiplier: 0.64).isActive = true
    let actionBar = makeBar(height: 10)
    inner.addSubview(actionBar)
    actionBar.widthAnchor.constraint(equalTo: inner.widthAnchor, multiplier: 0.42).isActive = true
    NSLayoutConstraint.activate([
      body.leadingAnchor.constraint(equalTo: inner.leadingAnchor),
      body.trailingAnchor.constraint(equalTo: inner.trailingAnchor),
      body.topAnchor.constraint(
        equalTo: avatar.bottomAnchor,
        constant: TiebaSkeletonMetrics.postHeaderBottom
      ),
      actionBar.leadingAnchor.constraint(equalTo: inner.leadingAnchor),
      actionBar.topAnchor.constraint(
        equalTo: body.bottomAnchor,
        constant: TiebaSkeletonMetrics.postActionTop
      ),
      actionBar.bottomAnchor.constraint(equalTo: inner.bottomAnchor),
    ])
  }

  // MARK: card（大图 + 标题 + 两行；行高由列表的 itemHeight 固定）

  private func buildCard() {
    let container = UIView()
    container.translatesAutoresizingMaskIntoConstraints = false
    addSubview(container)

    let media = makeBlock(radius: TiebaSkeletonMetrics.cardLargeRadius)
    let title = makeBar(height: 16)
    let line1 = makeBar(height: 12)
    let line2 = makeBar(height: 12)
    for view in [media, title, line1, line2] {
      container.addSubview(view)
    }
    line2.widthAnchor.constraint(equalTo: container.widthAnchor, multiplier: 0.56).isActive = true
    NSLayoutConstraint.activate([
      container.leadingAnchor.constraint(equalTo: leadingAnchor),
      container.trailingAnchor.constraint(equalTo: trailingAnchor),
      container.centerYAnchor.constraint(equalTo: centerYAnchor),
      media.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      media.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      media.topAnchor.constraint(equalTo: container.topAnchor),
      media.heightAnchor.constraint(equalToConstant: 160),
      title.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      title.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      title.topAnchor.constraint(equalTo: media.bottomAnchor, constant: TiebaSkeletonMetrics.gapSmall),
      line1.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      line1.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      line1.topAnchor.constraint(equalTo: title.bottomAnchor, constant: TiebaSkeletonMetrics.gapTiny),
      line2.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      line2.topAnchor.constraint(equalTo: line1.bottomAnchor, constant: TiebaSkeletonMetrics.gapTiny),
      container.bottomAnchor.constraint(equalTo: line2.bottomAnchor),
    ])
  }

  // MARK: row（36 圆头像 + 两行；行高由列表的 itemHeight 固定）

  private func buildRow() {
    let container = UIView()
    container.translatesAutoresizingMaskIntoConstraints = false
    addSubview(container)

    let avatar = makeBlock(radius: 18)
    let column = UIStackView()
    column.axis = .vertical
    column.spacing = TiebaSkeletonMetrics.gapTiny
    // 百分比宽条不能被 fill 对齐拉伸：leading + 显式宽度约束
    column.alignment = .leading
    column.translatesAutoresizingMaskIntoConstraints = false
    let bar1 = makeBar(height: 12)
    let bar2 = makeBar(height: 10)
    column.addArrangedSubview(bar1)
    column.addArrangedSubview(bar2)
    bar1.widthAnchor.constraint(equalTo: column.widthAnchor, multiplier: 0.52).isActive = true
    bar2.widthAnchor.constraint(equalTo: column.widthAnchor, multiplier: 0.78).isActive = true
    for view in [avatar, column] {
      container.addSubview(view)
    }
    NSLayoutConstraint.activate([
      container.leadingAnchor.constraint(equalTo: leadingAnchor),
      container.trailingAnchor.constraint(equalTo: trailingAnchor),
      container.centerYAnchor.constraint(equalTo: centerYAnchor),
      avatar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      avatar.centerYAnchor.constraint(equalTo: container.centerYAnchor),
      avatar.widthAnchor.constraint(equalToConstant: 36),
      avatar.heightAnchor.constraint(equalToConstant: 36),
      container.heightAnchor.constraint(greaterThanOrEqualToConstant: 36),
      column.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: TiebaSkeletonMetrics.gapSmall),
      column.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      column.centerYAnchor.constraint(equalTo: container.centerYAnchor),
    ])
  }
}

// MARK: - 骨架列表

/// 骨架列表（对齐 Skeleton.tsx 的 SkeletonList）：默认 8 格；
/// thread/post 行高自然撑出，card/row 缺省 232/88。
final class TiebaSkeletonList: UIView {
  /// 形状（换值即重建，供搜索页按 tab 切换 thread/row）。
  var variant: TiebaSkeletonVariant = .thread { didSet { if variant != oldValue { rebuild() } } }
  /// 单元数量（默认 8）。
  var count: Int = 8 { didSet { if count != oldValue { rebuild() } } }
  /// 单个单元高度（仅 row/card 需要；nil 用变体缺省行高）。
  var itemHeight: CGFloat? { didSet { if itemHeight != oldValue { rebuild() } } }

  /// 占位块颜色 = surfaceTertiary（systemGray5 浅 #E5E5EA / 深 #2C2C2E）。
  var placeholderColor: UIColor = .systemGray5 {
    didSet { if placeholderColor != oldValue { rebuild() } }
  }
  /// 卡片面色（thread/post 卡片容器，默认 theme.card）。
  var cardColor: UIColor = TiebaFeedRowPalette.default.card {
    didSet { if cardColor != oldValue { rebuild() } }
  }
  /// 卡片 hairline 描边（默认 theme.borderCard）。
  var borderColor: UIColor = TiebaFeedRowPalette.default.borderCard {
    didSet { if borderColor != oldValue { rebuild() } }
  }
  /// 应用内深浅（调用方语义输入）。**不再写 overrideUserInterfaceStyle**：骨架
  /// 全是动态色（占位/卡片面 + 描边走 registerForTraitChanges 重解析），trait
  /// 由窗口级 override 与宿主子页下发，变了自己就跟着变。属性保留是因为页面
  /// 仍按旧签名下发它（文件外的调用点，写入无副作用）。
  var isDark: Bool = false
  /// 宿主整块隐藏但不改本视图 isHidden 时的补充挂起（如 Web 覆盖层）。
  var isSuspended: Bool = false { didSet { updatePulse() } }
  /// 列表内边距（原各页 SkeletonList style 的 padding，如 16/8/24）。
  var contentInsets: UIEdgeInsets = .zero { didSet { applyInsets() } }
  /// 骨架之上的一整块前置视图（帖子页的「已知主贴区」占位；换值即重建）。
  /// 宿主只负责给视图，摆位顺序（前置块在最上）由骨架保证。
  var headerView: UIView? {
    didSet { if headerView !== oldValue { rebuild() } }
  }

  private let stack = UIStackView()
  /// 每格一个扫光开关（动画在渲染服务器侧，主线程零参与）。
  private var pulseHosts: [TiebaSkeletonCellView] = []
  private var isPulsing = false

  init(
    variant: TiebaSkeletonVariant = .thread,
    count: Int = 8,
    itemHeight: CGFloat? = nil
  ) {
    self.variant = variant
    self.count = count
    self.itemHeight = itemHeight
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    // 顶对齐、自然高度：超出宿主的部分裁掉（不越过底栏/导航栏画出界）
    clipsToBounds = true
    isAccessibilityElement = true
    accessibilityLabel = "内容加载中"
    accessibilityTraits = .updatesFrequently
    stack.axis = .vertical
    stack.alignment = .fill
    stack.isLayoutMarginsRelativeArrangement = true
    // 顶部留白由 contentInsets 一处承担，不让栈再叠一份安全区边距：骨架挂在全屏
    // 列表顶部，栈的 margins 会被自动抬高一份 safeArea.top ⇒ 首个块（帖子页的已知
    // 主贴卡）比真实内容低约 59pt，首包落地时整块往上跳一次（用户 2026-09-18 报的
    // "卡片离顶栏一段空白、加载完突然位移"）。同 80a47e6 修的三处页头栈。
    stack.insetsLayoutMarginsFromSafeArea = false
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    // 只钉上/左右：高度由内容撑出（钉底会让 .fill 分布拉伸最后一个单元）
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.topAnchor.constraint(equalTo: topAnchor),
    ])
    let center = NotificationCenter.default
    for name in [
      UIApplication.didEnterBackgroundNotification,
      UIApplication.willEnterForegroundNotification,
      UIAccessibility.reduceMotionStatusDidChangeNotification,
    ] {
      center.addObserver(self, selector: #selector(handleVisibilitySignal), name: name, object: nil)
    }
    rebuild()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override var isHidden: Bool {
    didSet { updatePulse() }
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    updatePulse()
  }

  @objc private func handleVisibilitySignal(_ notification: Notification) {
    updatePulse()
  }

  // MARK: 组装

  private func applyInsets() {
    stack.directionalLayoutMargins = NSDirectionalEdgeInsets(
      top: contentInsets.top,
      leading: contentInsets.left,
      bottom: contentInsets.bottom,
      trailing: contentInsets.right
    )
  }

  private func rebuild() {
    isPulsing = false
    for view in stack.arrangedSubviews {
      stack.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
    pulseHosts.removeAll()
    // 前置块恒在最上：真正撑高的那一块由它自己定（内容自然高度）。
    if let headerView {
      stack.addArrangedSubview(headerView)
    }
    stack.spacing = variant.isNaturalHeight ? 0 : TiebaSkeletonMetrics.listGap
    let height = itemHeight ?? variant.defaultItemHeight
    for index in 0..<max(count, 0) {
      let cell = TiebaSkeletonCellView(
        variant: variant,
        // 真实信息流图文混排：骨架按半数带图交替，首格即含图片占位
        withMedia: index % 2 == 0,
        placeholderColor: placeholderColor,
        cardColor: cardColor,
        borderColor: borderColor
      )
      if let height {
        cell.heightAnchor.constraint(equalToConstant: height).isActive = true
      }
      stack.addArrangedSubview(cell)
      pulseHosts.append(cell)
    }
    applyInsets()
    updatePulse()
  }

  // MARK: 扫光（可见才跑）

  private func updatePulse() {
    let shouldRun = !UIAccessibility.isReduceMotionEnabled
      && !isSuspended
      && !isHidden
      && UIApplication.shared.applicationState == .active
      && hasVisibleHierarchy
    guard shouldRun else {
      stopPulse()
      return
    }
    guard !isPulsing else { return }
    isPulsing = true
    for (index, cell) in pulseHosts.enumerated() {
      // 每格错开 0.12s：一道光波自上而下走过整个骨架列表，而不是所有格子同时闪。
      cell.setShimmering(true, delay: Double(index) * 0.12)
    }
  }

  /// 停止：撤销动画。Reduce Motion / 不可见的静态占位值就是骨块底色本身。
  private func stopPulse() {
    isPulsing = false
    for cell in pulseHosts {
      cell.setShimmering(false)
    }
  }

  /// 窗口 + 全祖先链都未 hidden 才算可见（宿主可能隐藏的是外层容器）。
  private var hasVisibleHierarchy: Bool {
    guard tiebaIsOnScreen else { return false }
    var node: UIView? = self
    while let current = node {
      if current.isHidden { return false }
      node = current.superview
    }
    return true
  }
}
