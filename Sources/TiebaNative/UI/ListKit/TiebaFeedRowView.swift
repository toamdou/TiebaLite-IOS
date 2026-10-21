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
    accessibilityElements = nil
    setNeedsLayout()
  }

  // MARK: - 状态

  var model: TiebaFeedRowModel?
  /// 折叠退场的视觉高度（TiebaApparentHeight：布局高度不动，只收视觉高度）。
  var collapseState = TiebaApparentHeight(layoutHeight: 0)
  var collapseAnimator: UIViewPropertyAnimator?
  /// 折叠在途：layoutSubviews 期间不重排内容（内容保持完整高度，被裁剪掉下半部分）。
  var isCollapsing = false
  /// 上次摆 frame 的输入指纹（模型身份 + 尺寸）：相同就不必再摆一遍（见 layoutSubviews）。
  struct PlacedToken: Equatable {
    let model: ObjectIdentifier
    let size: CGSize
    /// 位图按显示缩放烘焙：缩放档变了必须重摆一次（否则会留着低档的模糊位图）。
    /// 帧计划本身与缩放无关，这里带上它只为驱动画布重烘。
    let scale: CGFloat
  }
  var placedToken: PlacedToken?
  private var voiceOverStatusObserver: NSObjectProtocol?
  var applying = false
  var stripItems: [TiebaFeedRowMediaItemView] = []
  var stripFrames: [CGRect] = []
  var stripActiveIndex = 0
  var stripTotalCount = 0
  /// 图片带里**已经发过图片请求**的下标（懒加载记账，见 extendStripLoadWindow）。
  /// 只有换行（换帖/换宽度）才清空——同行重配要保持已加载的那几张不回退。
  var stripLoadedIndexes: Set<Int> = []
  /// 外观档变化登记（registerForTraitChanges，iOS 17 起；traitCollectionDidChange 已废弃）。
  private var styleRegistration: UITraitChangeRegistration?
  /// 已配置的 (pageKey#index)：主题重刷走 configure 但不能重置图片带滚动位置。
  var configuredIdentity: String?
  /// 上次绘制的点赞数/帖子 id：同一帖计数变化时播跳动（RN numPop 的判据）。
  var displayedLikeCount: Double?
  var lastRenderedThreadId: String?
  /// 点赞 pop 的动画载体（图标 / 计数各自的 CALayer，与 RN 的两层 Animated.View 同构）。
  var likeIconPopLayer: CALayer?
  var likeCountPopLayer: CALayer?
  /// 点赞蓄力触觉的延迟令牌：按压后 ~0.12s 才启动连续震（滑过按钮不震）；
  /// 抬手/滚动取消/行复用都自增作废在途任务。
  var likeChargeToken = 0
  static let likeChargeDelay: TimeInterval = 0.12

  /// 卡片长按菜单的交互实例（开关见 syncCardMenuInteraction）。
  var cardMenuInteraction: UIContextMenuInteraction?

  // MARK: - 子视图

  let cardView = UIView()
  let rowHairline = UIView()
  /// 卡内静态文字合画到这一张画布（见 TiebaFeedRowTextCanvas）。
  let textCanvas = TiebaFeedRowTextCanvas()
  /// 本轮要画的 9 段静态文字（configure 时按模型+色板生成，layout 时交给画布）。
  var runs: [TiebaFeedRowTextCanvas.Run] = []
  let avatarContainer = UIView()
  let avatarInitialLabel = UILabel()
  let avatarView = UIImageView()
  /// 右上角 26×26 更多钮（ellipsis + textTertiary，与帖子页同形）。
  let menuButton = TiebaFeedRowMenuButton(frame: .zero)
  let singleMediaView = TiebaFeedRowMediaItemView()
  let stripScrollView = UIScrollView()
  let stripCountLabel = UILabel()
  let quoteCard = UIView()
  let chipView = UIView()
  let chipAvatarView = UIImageView()
  let chipInitialLabel = UILabel()
  let chipLabel = UILabel()
  var actionItems: [TiebaFeedRowActionView] = []
  let bannerView = UIView()
  let bannerHairline = UIView()
  let bannerIconView = UIImageView()
  let bannerBadgeLabel = UILabel()
  let bannerTextLabel = UILabel()

  // MARK: - 初始化

  public override init(frame: CGRect) {
    super.init(frame: frame)
    isOpaque = false
    backgroundColor = .clear
    clipsToBounds = true
    // VoiceOver：本行是 semantic container；正文/标题/操作分别成为停靠点。
    isAccessibilityElement = false
    accessibilityContainerType = .semanticGroup
    voiceOverStatusObserver = NotificationCenter.default.addObserver(
      forName: UIAccessibility.voiceOverStatusDidChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      self.placedToken = nil
      self.setNeedsLayout()
    }

    // 卡片容器：扁平档直接是行内容面，不再画灰白卡。
    cardView.backgroundColor = TiebaListAppearance.isFlat ? .systemBackground : palette.card
    cardView.layer.cornerRadius = TiebaFeedRowLayout.cardRadius
    cardView.layer.cornerCurve = .continuous
    cardView.layer.borderWidth = 0
    cardView.layer.borderColor = palette.borderCard.cgColor
    // 卡面子视图都在 bounds 内，圆角只交给背景 layer；不再让整张卡进入离屏 mask。
    cardView.clipsToBounds = false
    cardView.isHidden = true
    cardView.isAccessibilityElement = false
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
    quoteCard.backgroundColor = .tertiarySystemFill
    quoteCard.layer.borderWidth = 0
    quoteCard.layer.borderColor = UIColor.clear.cgColor
    cardView.addSubview(quoteCard)
    // 画布只画文字、背景透明：压在引用卡底之上（引用文字才看得见），又在菜单钮/
    // 图片/徽章/操作栏之下（那些之后才挂，且都是不透明的实内容）。
    cardView.addSubview(textCanvas)

    // 右上角菜单钮（与帖子页同形的「更多」）：26×26 槽位、ellipsis、textTertiary；
    // 无菜单项的行（menuOptions 空）保持隐藏。
    menuButton.isHidden = true
    menuButton.isAccessibilityElement = false
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
      item.isAccessibilityElement = false
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
    bannerTextLabel.lineBreakMode = .byWordWrapping
    bannerTextLabel.numberOfLines = 0
    bannerView.addSubview(bannerTextLabel)
    addSubview(bannerView)

    // 扁平档行底 hairline：1 物理像素，压在卡片/横幅之上；卡片档完全隐藏。
    rowHairline.isUserInteractionEnabled = false
    rowHairline.backgroundColor = palette.separator
    rowHairline.isHidden = true
    addSubview(rowHairline)

    // 动态色转 CGColor 后不随外观走：系统级 trait 登记只在外观档真变时回调，
    // 不再每次 layoutSubviews 比对（traitCollectionDidChange 自 iOS 17 废弃）。
    styleRegistration = registerForTraitChanges([
      UITraitUserInterfaceStyle.self,
      UITraitAccessibilityContrast.self,
    ]) { (view: TiebaFeedRowView, _) in
      view.refreshDynamicLayerColors()
      view.updateAccessibilityElements()
    }
  }

  isolated deinit {
    if let voiceOverStatusObserver {
      NotificationCenter.default.removeObserver(voiceOverStatusObserver)
    }
  }

  public required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }
}
