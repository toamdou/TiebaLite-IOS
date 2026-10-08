// TiebaLite RN — 信息流行视图（TiebaFeedRowView）
//
// 设计（2026-09-12，与 TiebaRowMetrics 配套）：
//   - Fabric/Yoga 不查自定义视图的 intrinsicContentSize，
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
//   - 卡片长按（UIContextMenuInteraction，宿主 = 文字画布 textCanvas）→ 分享帖子 /
//     复制帖子内容 / 不感兴趣 / 屏蔽作者（四项都经 onMenuAction 回传页面执行；
//     图片格上的长按仍归图片菜单 —— 画布在命中链之外，同一行只有一套长按会成立）
//   以上 frame 均可由 model.plan 直接取得（行坐标；内部常量与 TweetCard 对齐）。
//   图片带序号需要滚动内容坐标 → contentOffset 的换算（帧计划里没有偏移），
//   由 `mediaHit(atRowPoint:)` 提供（只读几何；列表侧点击分发用它）。
//   点是否落在菜单钮上由 `ownsInteraction(atRowPoint:)` 判定（cell 的整卡点击
//   手势据此过滤，避免"点菜单同时进帖"）。

import UIKit
import Nuke
import NukeExtensions

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

  /// 右上角「更多」菜单选中项（dislike / block / copy-title）：业务动作全在 JS
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
    syncCardMenuInteraction()
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

  /// 不感兴趣折叠（CollapseRow）：280ms、EASE_OUT、opacity 1→0。
  /// 数据移除仍由 completion 驱动（原 JS 的动画窗口后 360ms 兜底定时器已删）。
  ///
  /// **视觉高度与布局高度解耦**（TiebaApparentHeight）：动画只收**本视图的高度**
  /// （顶边不动、内容裁剪），列表给的布局高度在动画结束、数据真正移除之后才变。
  /// ⚠️ 改前是 `transform.scale.y`：整层连同**文字**一起被纵向压扁——文字在那个
  /// 280ms 里被压成半高，是可见的缺陷（同仓查看器的缩放不用在文字上也是这个道理）。
  /// Reduce Motion 无动画可等，必须同步回调一次，否则列表永远不删数据。
  public func playCollapseAnimation(completion: (() -> Void)? = nil) {
    collapseState.setLayoutHeight(max(bounds.height, 0))
    collapseState.beginTransition(to: 0)
    isCollapsing = true
    // 收缩期间必须裁剪：内容按完整高度摆好后**不再重排**（见 layoutSubviews 的
    // isCollapsing 早退），高度收下去的部分由裁剪吃掉——这就是"不压扁文字"的关键。
    clipsToBounds = true

    let finish: () -> Void = { [weak self] in
      guard let self else {
        completion?()
        return
      }
      self.collapseState.finishTransition()
      self.isCollapsing = false
      self.collapseAnimator = nil
      completion?()
    }

    guard !UIAccessibility.isReduceMotionEnabled else {
      collapseState.setApparentHeight(0)
      applyCollapseFrame()
      alpha = 0
      finish()
      return
    }
    let animator = UIViewPropertyAnimator(
      duration: TiebaFeedRowMotion.collapseDuration,
      curve: .easeOut
    ) { [weak self] in
      guard let self else { return }
      self.collapseState.setApparentHeight(0)
      self.applyCollapseFrame()
      self.alpha = 0
    }
    animator.addCompletion { _ in finish() }
    collapseAnimator = animator
    animator.startAnimation()
  }

  /// 把视觉高度贴到本视图（TiebaApparentHeight.apparentFrame：只换高度，origin/宽度不动 →
  /// 顶边不动，下面的行不会因为这次收缩而位移）。
  private func applyCollapseFrame() {
    frame = collapseState.apparentFrame(from: frame)
  }

  /// 复位行级动画（复用/换行）：动画 key 移除 + 终态归位，防止 transform/alpha
  /// 残留串到下一行（prepareForReuse 与 apply 都会走）。
  public func resetAnimations() {
    layer.removeAnimation(forKey: "tieba.entrance")
    layer.removeAnimation(forKey: "tieba.collapse")
    // 折叠：停掉动画并复位折叠状态（高度由列表下次布局重新给，这里只保证
    // alpha/裁剪/在途标记不串到下一行）。
    collapseAnimator?.stopAnimation(true)
    collapseAnimator = nil
    isCollapsing = false
    collapseState = TiebaApparentHeight(layoutHeight: max(bounds.height, 0))
    clipsToBounds = false
    alpha = 1
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
  /// 折叠退场的视觉高度（TiebaApparentHeight：布局高度不动，只收视觉高度）。
  private var collapseState = TiebaApparentHeight(layoutHeight: 0)
  private var collapseAnimator: UIViewPropertyAnimator?
  /// 折叠在途：layoutSubviews 期间不重排内容（内容保持完整高度，被裁剪掉下半部分）。
  private var isCollapsing = false
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
  /// 本轮要画的 9 段静态文字（configure 时按模型+色板生成，layout 时交给画布）。
  private var runs: [TiebaFeedRowTextCanvas.Run] = []
  private let avatarContainer = UIView()
  private let avatarInitialLabel = UILabel()
  private let avatarView = UIImageView()
  /// 右上角 26×26 更多钮（ellipsis + textTertiary，与帖子页同形）。
  private let menuButton = TiebaFeedRowMenuButton(frame: .zero)
  private let singleMediaView = TiebaFeedRowMediaItemView()
  private let stripScrollView = UIScrollView()
  private let stripCountLabel = UILabel()
  private let quoteCard = UIView()
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
    // 图片层必须真的挂上：首字色块在下、头像图在上（图片命中即盖住首字）。
    // 这一行在"9 个 UILabel 改直接绘制"那轮被误删 ⇒ 头像永远是首字色块、图片不显示。
    avatarContainer.addSubview(avatarView)
    avatarView.contentMode = .scaleAspectFill
    cardView.addSubview(avatarContainer)

    // 转发引用帖：卡片本体（底 + 描边）先挂，让引用文字压在上面。
    quoteCard.isHidden = true
    quoteCard.layer.cornerRadius = 12 // Radius.input
    quoteCard.layer.cornerCurve = .continuous
    quoteCard.layer.borderWidth = 1 / max(traitCollection.displayScale, 1)
    quoteCard.layer.borderColor = palette.separator.cgColor
    cardView.addSubview(quoteCard)
    // 画布只画文字、背景透明：压在引用卡底之上（引用文字才看得见），又在菜单钮/
    // 图片/徽章/操作栏之下（那些之后才挂，且都是不透明的实内容）。
    cardView.addSubview(textCanvas)

    // 右上角菜单钮（与帖子页同形的「更多」）：26×26 槽位、ellipsis、textTertiary；
    // 无菜单项的行（menuOptions 空）保持隐藏。
    menuButton.isHidden = true
    menuButton.configure(tint: palette.textTertiary)
    menuButton.addTarget(self, action: #selector(handleMenuButtonTap), for: .touchUpInside)
    cardView.addSubview(menuButton)

    // 媒体
    singleMediaView.isHidden = true
    cardView.addSubview(singleMediaView)
    stripScrollView.isHidden = true
    stripScrollView.showsHorizontalScrollIndicator = false
    stripScrollView.isDirectionalLockEnabled = true
    stripScrollView.decelerationRate = TiebaMotionSpec.Scroll.systemDecelerationRate
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
    // 药丸型（用户口径）：正圆端头 = circular 曲线 + 半径=半高（在 layout 里随
    // 实际高度落定）。continuous 曲线在半径超半高时叠成"橄榄型"，已否。
    chipView.layer.cornerCurve = .circular
    chipView.clipsToBounds = true
    chipAvatarView.contentMode = .scaleAspectFill
    chipAvatarView.clipsToBounds = true
    chipInitialLabel.textAlignment = .center
    chipInitialLabel.font = .systemFont(ofSize: 20 * 0.38, weight: .semibold)
    chipInitialLabel.textColor = palette.onChip
    chipView.addSubview(chipInitialLabel)
    chipView.addSubview(chipAvatarView)
    chipLabel.isHidden = true
    chipLabel.lineBreakMode = .byTruncatingTail
    chipLabel.numberOfLines = 1
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
  /// 卡内静态文字随画布一起清（画布缓存在 layoutSubviews 里按模型重建）。
  private func resetBlockVisibility() {
    runs = []
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

  // MARK: - 卡内静态文字（画布输入）

  /// 9 段静态文字：字体/颜色/行高全部在此解析成属性串，交给画布一次性绘制。
  /// 原来是 9 个 UILabel（各自 numberOfLines / textColor / attributedText），
  /// 现在只按 plan 的 frame 产出绘制项——**不建任何视图**。
  /// 行数限制由 frame 高度天然承担（见 TiebaFeedGraphics 的逐段绘制）。
  ///
  /// **静态纯函数**：只吃 (模型, 色板, 引用卡显隐)，不读任何视图状态 —— 预取路径
  /// （TiebaKindListView 的 prefetchItemsAt）没有行视图，却必须产出与画布**逐字段同键、
  /// 同 runs** 的 Job（键里不含 runs，所以 runs 也必须同源），这里是那份输入的唯一产地。
  ///
  /// - Parameter quoteVisible: 引用卡是否显示。原实现读 `quoteCard.isHidden`（视图态），
  ///   现在按纯模型派生（isQuoteVisible(model:)）—— 与 configureQuote 同一条判据。
  ///   派生不引入差异：configureCard 里 configureQuote 恒在本函数之前跑，
  ///   `!quoteCard.isHidden` ≡ `isQuoteVisible(model)`。
  static func makeRuns(
    model: TiebaFeedRowModel,
    palette: TiebaFeedRowPalette,
    quoteVisible: Bool
  ) -> [TiebaFeedBitmapJob.Run] {
    let fonts = model.geometry.fonts
    let plan = model.plan
    var runs: [TiebaFeedRowTextCanvas.Run] = []
    // plan 的 frame 是**行坐标**（含 cardMarginH/cardMarginV 偏移，见 TiebaRowLayout 的
    // cardX = cardMarginH），而画布是 cardView 的子视图、坐标原点是卡片左上角。
    // 所以每一段都要过 cardRect 转换——子视图走 place() 是同一条转换。
    // 此前这里直接透传行坐标，整组文字右下各偏 (16, 4)：名字压在头像下沿、标题右端
    // 顶出画布被提前截断，而截断是绘制期才知道的，测量期判不出「显示更多」。
    // naturalHeight = **测量期已知的自然高**（阶段 0）：绘制期垂直居中不再需要先跑
    // 一遍有界量高（旧实现每段两趟 CoreText 排版）。单行段直接给行高；多行段
    //（title / abstract / quoteContent）用 plan 里带的未取整 usedRect 高（测量期与
    // frame 同源，见 TiebaRowMetrics.measure 的 exactHeight）。任一段为 nil 时画布
    // 仍回落旧行为（正确性不变，只是多一趟排版）。
    func add(_ attributed: NSAttributedString?, _ frame: CGRect?, naturalHeight: CGFloat? = nil) {
      guard let attributed, attributed.length > 0, let rect = Self.cardRect(frame) else { return }
      runs.append(.init(attributed: attributed, frame: rect, naturalHeight: naturalHeight))
    }
    // 昵称 / IP：纯文本按当前色板着色（换主题即变）。
    // ⚠️ 昵称必须与紧随其后的元信息（@昵称 + 时间）走**同一段落行高**（lineHeights.subhead）：
    // 改前这里是唯一的「无 paragraphStyle」段（自然高 = 字体行高 ≈17.9），而 frame 高 = 20、
    // 元信息段的自然高 = 20 —— 两个不同的居中基准 ⇒ 同一行里昵称比「回复于 xx 前」高约 1pt
    //（用户 2026-10-06 报「用户名与回复于 xx 前没有居中对齐在一条线上」，真机像素实测 1.0-1.2pt）。
    // 同段落后两者逐位同基线（同 frame 高 + 同自然高 ⇒ 同 inset）。
    add(
      TiebaFeedRowLayout.makeAttributed(
        text: model.displayName,
        font: fonts.displayName,
        color: palette.text,
        lineHeight: model.geometry.lineHeights.subhead
      ),
      plan.displayNameFrame,
      naturalHeight: model.geometry.lineHeights.subhead
    )
    // 元信息（@昵称 + 时间）是一个串：色按当前色板统一覆盖（模型侧只写语义色）。
    if let meta = model.metaAttributed {
      let colored = NSMutableAttributedString(attributedString: meta)
      colored.addAttribute(
        .foregroundColor,
        value: palette.textSecondary,
        range: NSRange(location: 0, length: colored.length)
      )
      // meta 是 makeAttributed 建的（min/maximumLineHeight = lineHeights.subhead）：
      // 单行自然高恒等于 frame 高 ⇒ inset 0（旧实现量出来也是 0，只是白排一趟）。
      add(colored, plan.metaFrame, naturalHeight: model.geometry.lineHeights.subhead)
    }
    if let ip = model.ipText, !ip.isEmpty {
      add(
        NSMutableAttributedString(
          string: ip,
          attributes: [.font: fonts.ip, .foregroundColor: palette.textSecondary]
        ),
        plan.ipFrame,
        naturalHeight: fonts.ip.lineHeight
      )
    }
    // 正文：attributed 已在测量期构建（含行高），这里只补「精品」前缀色。
    if let title = model.titleAttributed {
      add(
        Self.titleAttributed(title, prefix: model.titlePrefix, palette: palette),
        plan.titleFrame,
        naturalHeight: plan.naturalTitleHeight
      )
    }
    add(model.abstractAttributed, plan.abstractFrame, naturalHeight: plan.naturalAbstractHeight)
    if model.isCollapsible && !model.expanded, !model.showMoreText.isEmpty {
      add(
        NSMutableAttributedString(
          string: model.showMoreText,
          attributes: [.font: fonts.showMore, .foregroundColor: palette.primary]
        ),
        plan.showMoreTextFrame,
        // frame 高 = lineHeights.subhead + 4（showMore.marginTop 之上的 2 + 2），
        // 自然高 = 一行 ⇒ 旧实现给的是 2pt 的居中偏移，这里逐字复刻。
        naturalHeight: model.geometry.lineHeights.subhead
      )
    }
    // 引用帖三段：仅当引用卡显示时画（卡片隐藏时其文字也不该出现）。
    if quoteVisible {
      add(
        model.quoteForumAttributed,
        plan.quoteForumFrame,
        naturalHeight: model.geometry.lineHeights.quoteForum
      )
      add(
        model.quoteTitleAttributed,
        plan.quoteTitleFrame,
        naturalHeight: model.geometry.lineHeights.quoteTitle
      )
      add(
        model.quoteContentAttributed,
        plan.quoteContentFrame,
        naturalHeight: plan.naturalQuoteContentHeight
      )
    }
    return runs
  }

  /// 实例转发（**薄**，只为不动既有调用点语义）：引用卡显隐按纯模型派生，
  /// 与 configureQuote 同判据。见静态 makeRuns(model:palette:quoteVisible:)。
  private func makeRuns(model: TiebaFeedRowModel) -> [TiebaFeedRowTextCanvas.Run] {
    Self.makeRuns(model: model, palette: palette, quoteVisible: Self.isQuoteVisible(model: model))
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
    // 卡片长按菜单开关随模型走（换行/换页/同页重配都在这里收敛）。
    syncCardMenuInteraction()
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
    // 进帖转场的源端配对（Hero 魔改转场）：id 由本行自己的 threadId 决定，
    // cell 复用换行时随之更新，不留残留（见 TiebaHeroTransition）。
    TiebaHeroTransition.mark(cardView, threadId: model.threadId)
    menuButton.isHidden = model.menuOptions.isEmpty
    bannerView.isHidden = true
    menuButton.isHidden = model.menuOptions.isEmpty
    menuButton.configure(tint: palette.textTertiary)

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

    // 引用卡显隐必须先定：它决定引用帖三段文字进不进画布（见 makeRuns）。
    configureQuote(with: model)
    // 卡内 9 段静态文字（原 9 个 UILabel）→ 绘制项。
    runs = makeRuns(model: model)

    configureMedia(with: model)
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
    // 无媒体（或设置里隐藏了媒体）：清掉上一行的图片配对，否则复用后残留旧 id。
    guard model.showsMedia else {
      TiebaHeroTransition.clear(singleMediaView.heroImageView)
      for item in stripItems { TiebaHeroTransition.clear(item.heroImageView) }
      return
    }
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
      // 进帖转场：图片带只配第 1 张（用户点卡片时看到的就是它），其余清掉避免撞 id。
      TiebaHeroTransition.markImage(stripItems.first?.heroImageView, threadId: model.threadId)
      for item in stripItems.dropFirst() { TiebaHeroTransition.clear(item.heroImageView) }
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
      // 进帖转场：单图即首图。
      TiebaHeroTransition.markImage(singleMediaView.heroImageView, threadId: model.threadId)
      if !isSameRow {
        let height = model.singleMediaHeight ?? 0
        if height > 0 {
          // fit 显示档：位图 = 显示框像素 + 圆角烘焙（容器已去 clipsToBounds）。
          // 半径与上方 configure(cornerRadius: 16) 同源（Radius.card - 4）。
          singleMediaView.loadFitDisplay(
            url: url,
            targetSize: CGSize(width: model.geometry.textColumnWidth, height: height),
            cornerRadius: 16,
            scale: scale
          )
        } else {
          singleMediaView.load(
            url: url,
            maxPixel: model.geometry.textColumnWidth * scale
          )
        }
      }
    }
  }

  /// 引用卡是否显示：**纯模型派生**，判据的唯一定义处。configureQuote 用它决定卡片底
  /// 的显隐，静态 makeRuns 用它决定三段引用文字进不进画布，预取路径同样调它 ——
  /// 预取时没有行视图、读不到 quoteCard.isHidden，三处必须是同一条判据。
  static func isQuoteVisible(model: TiebaFeedRowModel) -> Bool {
    model.quoteForumText != nil || model.quoteTitleText != nil || model.quoteContentText != nil
  }

  /// 引用帖：只决定卡片底的显隐。三段文字由 makeRuns 按同一判据产出（见该处）。
  private func configureQuote(with model: TiebaFeedRowModel) {
    guard Self.isQuoteVisible(model: model) else { return }
    quoteCard.isHidden = false
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

  /// 标题串：「精品」前缀段按色板的 warning 补色（模型只存文案，换主题即变）。
  /// static：makeRuns 抽成静态纯函数后这里不能再读实例的 palette（预取路径没有实例）。
  private static func titleAttributed(
    _ attributed: NSAttributedString,
    prefix: String?,
    palette: TiebaFeedRowPalette
  ) -> NSAttributedString {
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

  /// 右上角「更多」：与 RN 的 Alert.alert(title, nil, [菜单项…, 取消]) 同形态——
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
    case "block-forum": return "屏蔽吧"
    case "copy-title": return "复制标题"
    default: return option
    }
  }

  // MARK: - 卡片长按菜单（与长按图片同一套：UIContextMenuInteraction + UITargetedPreview + UIMenu）

  /// 卡片长按菜单的交互实例（开关见 syncCardMenuInteraction）。
  private var cardMenuInteraction: UIContextMenuInteraction?

  /// 卡片长按菜单开关（页面按行字典 cardContextMenu 下发）：只在启用时挂交互，
  /// 关闭态零手势开销 —— 与图片菜单的 syncContextMenuInteraction 同策略。
  ///
  /// 宿主是**文字画布** textCanvas，不是 self / cardView：画布覆盖整卡、又压在图片/
  /// 头像/徽章/操作栏等子视图**之下**，命中链与那些子视图**互不相交** —— 手指落在
  /// 图片上时画布不在链里，图片那套长按菜单原样生效；同一行不会有两套长按抢手势。
  ///
  /// 菜单项固定四项，动作经 onMenuAction 回传页面（与右上角「更多」同一出口）：
  /// "share" 分享帖子 · "copy-content" 复制帖子内容 · "dislike" 不感兴趣 ·
  /// "block" 屏蔽作者 —— **启用本菜单的页面必须四个都接线**。
  private func syncCardMenuInteraction() {
    let enabled = model?.showsCardContextMenu == true && model?.isTopBanner != true
    if enabled {
      if cardMenuInteraction == nil {
        let interaction = UIContextMenuInteraction(delegate: self)
        textCanvas.addInteraction(interaction)
        cardMenuInteraction = interaction
      }
    } else if let interaction = cardMenuInteraction {
      textCanvas.removeInteraction(interaction)
      cardMenuInteraction = nil
    }
  }

  /// 菜单身份 = 页键 # 行号 # 帖子 id。菜单是异步的：动作触发那一刻本视图可能已被
  /// 复用/换页（页级 reload + 翻页模型），身份对不上就丢弃这次动作 —— 宁可什么都不做，
  /// 也不能把「屏蔽作者」落到另一张帖子上。
  private var cardMenuIdentity: String? {
    guard let model, let identityKey else { return nil }
    return "\(identityKey)#\(model.threadId)"
  }

  private func emitCardMenuAction(_ action: String, identity: String) {
    guard cardMenuIdentity == identity else { return }
    onMenuAction?(action)
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
      host: self,
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
      host: self,
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
      host: self,
      property: .scale,
      from: 1,
      to: 1.28,
      spring: TiebaFeedRowMotion.countBump,
      key: "tieba.countBump"
    ) { [weak self] in
      guard let self, let layer = self.likeCountPopLayer else { return }
      tiebaPlaySpring(
        on: layer,
        host: self,
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
    // 折叠动画在途：**不重排**。高度在收，内容是按完整高度摆好的那一份，
    // 由 clipsToBounds 裁掉下半部分（重排的话就成了"内容跟着缩"，不是折叠）。
    guard !isCollapsing else { return }
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
    place(avatarContainer, plan.avatarFrame)
    avatarContainer.layer.cornerRadius = avatarContainer.bounds.width / 2
    avatarInitialLabel.frame = avatarContainer.bounds
    avatarView.frame = avatarContainer.bounds
    place(menuButton, plan.menuButtonFrame)

    if let mediaFrame = Self.cardRect(plan.mediaFrame) {
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
    // 药丸端头半径 = 实际高的一半（帧高固定 ~28pt，写死会随字号档漂移）。
    chipView.layer.cornerRadius = chipView.bounds.height / 2

    for (index, item) in actionItems.enumerated() {
      guard index < plan.actionButtonFrames.count,
            index < plan.actionIconFrames.count,
            index < plan.actionLabelFrames.count else {
        break
      }
      let button = plan.actionButtonFrames[index]
      item.frame = Self.cardRect(button) ?? .zero
      let icon = plan.actionIconFrames[index]
      let label = plan.actionLabelFrames[index]
      item.layout(
        iconFrame: icon.offsetBy(dx: -button.minX, dy: -button.minY),
        labelFrame: label.offsetBy(dx: -button.minX, dy: -button.minY)
      )
    }

    // 静态文字一次性交给画布（runs 已在 configure 时按模型+色板生成）。
    // 传模型身份 + 色板：画布据此取缓存位图，命中则完全跳过光栅化。
    textCanvas.update(runs: runs, model: model, palette: palette)
  }

  /// 行坐标 → 卡片坐标。static：静态 makeRuns 也要做这条换算（预取路径没有视图实例），
  /// 换算只有这一处定义，免得两处各写一遍偏移量。
  private static func cardRect(_ rect: CGRect?) -> CGRect? {
    guard let rect else { return nil }
    return rect.offsetBy(
      dx: -TiebaFeedRowLayout.cardMarginH,
      dy: -TiebaFeedRowLayout.cardMarginV
    )
  }

  /// 首图已解好的位图（无媒体/未加载 → nil）。列表侧写快照时取走，供详情页占位卡
  /// 立刻顶上，避免"缩略图明明已显示、进帖却先是一片灰"。
  var loadedThumbnailImage: UIImage? {
    if !singleMediaView.isHidden, let image = singleMediaView.loadedImage { return image }
    return stripItems.first { !$0.isHidden }?.loadedImage
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
    view.frame = Self.cardRect(rect) ?? .zero
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
      let media = model.media[index]
      stripItems[index].loadDisplay(
        url: media.url,
        targetSize: frames[index].size,
        cornerRadius: 0,
        scale: scale
      )
    }
  }
}

// MARK: - 卡片长按菜单（分享帖子 / 复制帖子内容 / 不感兴趣 / 屏蔽作者）

/// 长按卡片 → 系统上下文菜单：卡片本身被 lift 凸显、菜单在下方。
/// 与「长按图片」（TiebaFeedRowMediaItemView 同一套系统机制）分工：图片格上的
/// 长按仍归图片菜单（画布在命中链之外），卡片文字/空白上的长按归本菜单。
extension TiebaFeedRowView: UIContextMenuInteractionDelegate {
  public func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    configurationForMenuAtLocation location: CGPoint
  ) -> UIContextMenuConfiguration? {
    guard let model, model.showsCardContextMenu, !model.isTopBanner,
          let identity = cardMenuIdentity, bounds.width > 1 else { return nil }
    // [采用] 惯性滚动中长按一律不成立（图片/帖子行同一守卫，见 TiebaDecelerationGuard）。
    // 宿主取 window：列表的滚动视图在行视图**之上**，而该守卫只向下递归 —— 传行视图
    // 或画布都探不到集合视图，传 window（点的坐标一并换算到 window）才真的生效。
    if let window = self.window,
       !TiebaDecelerationGuard.shouldAllowLongPress(at: convert(location, to: window), in: window) {
      return nil
    }
    let actionProvider: UIContextMenuActionProvider = { [weak self] _ in
      // 手势到菜单呈现之间行被换掉 → 整套菜单作废（菜单项属于另一张帖子）。
      guard let self, self.cardMenuIdentity == identity else { return nil }
      let actions: [UIAction] = [
        UIAction(title: "分享帖子", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
          self?.emitCardMenuAction("share", identity: identity)
        },
        UIAction(title: "复制帖子内容", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
          self?.emitCardMenuAction("copy-content", identity: identity)
        },
        UIAction(title: "不感兴趣", image: UIImage(systemName: "hand.thumbsdown")) { [weak self] _ in
          self?.emitCardMenuAction("dislike", identity: identity)
        },
        UIAction(title: "屏蔽作者", image: UIImage(systemName: "person.crop.circle.badge.xmark")) { [weak self] _ in
          self?.emitCardMenuAction("block", identity: identity)
        },
      ]
      return UIMenu(children: actions)
    }
    return UIContextMenuConfiguration(
      identifier: nil,
      previewProvider: nil,
      actionProvider: actionProvider
    )
  }

  /// 升起锚点 = **整张卡片**（cardView）：卡片区域 + 圆角（Radius.card=20，与
  /// cardView.layer 同源）。方法名一个字都不能简写/错位（写成 previewForHighlighting
  /// 这类"几乎匹配"的名字只编译告警、系统永不调用，锚点静默失效）；新旧两个协议名
  /// 都给，两个入口落到同一份实现 —— 与图片/帖子行的既有防御同款。
  private func tiebaCardHighlightPreview() -> UITargetedPreview? {
    guard cardView.tiebaIsOnScreen, cardView.bounds.width > 1 else { return nil }
    let parameters = UIPreviewParameters()
    parameters.visiblePath = UIBezierPath(
      roundedRect: cardView.bounds,
      cornerRadius: cardView.layer.cornerRadius
    )
    // 卡片四角是透明的：不显式给 clear，系统会给 lift 出来的预览垫一层白底。
    parameters.backgroundColor = .clear
    return UITargetedPreview(view: cardView, parameters: parameters)
  }

  public func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    configuration: UIContextMenuConfiguration,
    highlightPreviewForItemWithIdentifier identifier: any NSCopying
  ) -> UITargetedPreview? {
    tiebaCardHighlightPreview()
  }

  /// 收起不飞回（与图片菜单一致：iOS 26+ 飞回路径留白风险）。
  public func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    configuration: UIContextMenuConfiguration,
    dismissalPreviewForItemWithIdentifier identifier: any NSCopying
  ) -> UITargetedPreview? {
    nil
  }

  /// （旧协议名，见上：与 identifier 形态同一份实现。）
  public func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    previewForHighlightingMenuWithConfiguration configuration: UIContextMenuConfiguration
  ) -> UITargetedPreview? {
    tiebaCardHighlightPreview()
  }

  public func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    previewForDismissingMenuWithConfiguration configuration: UIContextMenuConfiguration
  ) -> UITargetedPreview? {
    nil
  }

  /// 菜单升起瞬间的触觉：与长按图片同一个「升起」瞬态（长按卡片不再是静默的）。
  public func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    willDisplayMenuFor configuration: UIContextMenuConfiguration,
    animator: UIContextMenuInteractionAnimating?
  ) {
    TiebaSceneHaptics.playImageLift()
  }
}
