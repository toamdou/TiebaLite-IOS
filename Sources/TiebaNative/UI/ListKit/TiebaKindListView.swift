// ============================================================
// TiebaLite — 通用行列表（TiebaKindListView）
//
// 纯 UIView：UICollectionView + CompositionalLayout（帧由测量缓存逐个给出）+
// DiffableDataSource（CellRegistration 分派 simple/feed/post）；事件经 onEvent 外传。
// 行宽契约 = TiebaLayout.quantize(列表宽 - 2×horizontalInset)，行种类路由见 TiebaKindRowPages。
// ============================================================

import UIKit
import Nuke

// MARK: - 行标识

/// 行标识 =（页键, 页内下标）；pageKey 变化 = 整页更换。
struct TiebaKindItem: Hashable {
  let pageKey: String
  let index: Int
}

// MARK: - 单元格

/// 单元格：只托管一个 TiebaSimpleRowView（行视图不感知集合视图）。
/// 整卡点击手势装在 cell 上；行内子交互（头像/昵称 = 作者点击区）由行视图
/// 给出命中区域，列表按区域上报（region = "avatar" | "card"）。
final class TiebaKindListViewCell: UICollectionViewCell {
  private let rowView = TiebaSimpleRowView()

  /// 点击回调：参数是点击点在 cell（= 行视图）坐标系的坐标。
  var onTap: ((CGPoint) -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    isAccessibilityElement = false
    contentView.isAccessibilityElement = false
    isOpaque = false
    backgroundColor = .clear
    contentView.backgroundColor = .clear
    contentView.addSubview(rowView)

    let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
    contentView.addGestureRecognizer(tap)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  func apply(model: TiebaSimpleRowModel?) {
    rowView.apply(model: model)
  }

  func applyPalette(_ palette: TiebaSimpleRowPalette) {
    rowView.palette = palette
  }

  func playEntrance(index: Int) {
    rowView.playEntranceAnimation(index: index)
  }

  /// 命中区域（行视图按点判定）："avatar" = 作者点击区（头像/昵称）。
  func hitRegion(at point: CGPoint) -> String {
    rowView.hitRegion(atPoint: point)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    if rowView.frame != contentView.bounds {
      rowView.frame = contentView.bounds
    }
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    rowView.prepareForReuse()
  }

  @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
    onTap?(gesture.location(in: self))
  }
}

// MARK: - 信息流单元格（kind = "feed" 的行）

/// 单元格：只托管一个 TiebaFeedRowView（信息流卡片行，行视图是绘制/度量的
/// 单一来源）。行内自管交互（右上角 × 的 ActionSheet / 图片长按菜单 / 操作栏
/// 按压反馈）由行视图自己处理；整卡点击装在 cell 上，命中区域由列表按行模型
/// layoutPlan 判定。
final class TiebaKindListFeedCell: UICollectionViewCell {
  /// 行内容视图（行视图自身不读宿主上下文，可独立实例化）。
  private let rowView = TiebaFeedRowView(frame: .zero)

  /// 点击回调：参数是点击点在 cell（= 行视图）坐标系的坐标。
  var onTap: ((CGPoint) -> Void)?
  /// 行右上角 × 菜单选中项（dislike / block / copy-title）。
  var onRowMenuAction: ((String) -> Void)?
  /// 行内图片长按菜单选中项（媒体序号, save-image / share-image）。
  var onMediaMenuAction: ((Int, String) -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    // 行视图自身是 accessibility element（TiebaFeedRowView），cell 只做容器。
    isAccessibilityElement = false
    contentView.isAccessibilityElement = false
    isOpaque = false
    backgroundColor = .clear
    contentView.backgroundColor = .clear
    contentView.addSubview(rowView)

    let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
    tap.delegate = self
    contentView.addGestureRecognizer(tap)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  func apply(pageKey: String, index: Int) {
    rowView.onMenuAction = onRowMenuAction
    rowView.onMediaMenuAction = onMediaMenuAction
    rowView.apply(pageKey: pageKey, index: index)
  }

  func applyPalette(_ palette: TiebaFeedRowPalette) {
    rowView.palette = palette
  }

  func playEntrance(index: Int) {
    rowView.playEntranceAnimation(index: index)
  }

  /// 不感兴趣折叠退场（280ms opacity + scaleY，见 TiebaFeedRowView）。
  func playCollapse() {
    rowView.playCollapseAnimation()
  }

  /// 媒体命中查询（行视图只读几何）：point 为 cell 坐标；命中返回
  /// `(媒体下标, 窗口坐标矩形)`；cell 本身就是 UIView，直接交给查看器。
  func mediaHit(at point: CGPoint) -> (index: Int, windowRect: CGRect)? {
    let rowPoint = rowView.convert(point, from: self)
    guard let hit = rowView.mediaHit(atRowPoint: rowPoint) else { return nil }
    return (hit.index, rowView.convert(hit.rect, to: nil))
  }

  /// 查看器退出重算：行内第 mediaIndex 张图的窗口坐标矩形（行视图只读几何）。
  func mediaWindowRect(atMediaIndex index: Int) -> CGRect? {
    guard let rect = rowView.mediaVisibleRect(atMediaIndex: index) else { return nil }
    return rowView.convert(rect, to: nil)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    if rowView.frame != contentView.bounds {
      rowView.frame = contentView.bounds
    }
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    // 完整复位：取消在途图片任务、清文本/图片/横滑带、归位动画终态。
    rowView.prepareForReuse()
  }

  @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
    onTap?(gesture.location(in: self))
  }
}

extension TiebaKindListFeedCell: UIGestureRecognizerDelegate {
  /// 落点在行内自管交互控件（右上角菜单钮）上的触摸不参与整卡点击：否则点 ×
  /// 会先弹菜单又发 rowTap（"点菜单同时进帖"类错位）。
  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
    guard let touchView = touch.view, touchView.isDescendant(of: self) else { return true }
    let rowPoint = rowView.convert(touch.location(in: self), from: self)
    return !rowView.ownsInteraction(atRowPoint: rowPoint)
  }
}

// MARK: - 帖子单元格（kind = "post" 的行，thread/[id] 原生页）

/// 单元格：只托管一个 TiebaPostRowView。帖子行的交互全部由行内自管
///（点赞/菜单/头像/楼中楼/图片/文本选择），cell 不装整卡手势——语义动作
/// 经 onPostEvent 外传（原生页面直接接管，不经字典事件）。
final class TiebaKindListPostCell: UICollectionViewCell {
  private let rowView = TiebaPostRowView()

  var onPostEvent: ((TiebaPostRowEvent) -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    isAccessibilityElement = false
    contentView.isAccessibilityElement = false
    isOpaque = false
    backgroundColor = .clear
    contentView.backgroundColor = .clear
    contentView.addSubview(rowView)
    rowView.onEvent = { [weak self] event in
      self?.onPostEvent?(event)
    }
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  func apply(pageKey: String, index: Int) {
    rowView.apply(pageKey: pageKey, index: index)
  }

  func applyPalette(_ palette: TiebaSimpleRowPalette) {
    rowView.applyPalette(palette.base)
  }

  /// 查看器退出重算：第 index 张图的窗口坐标矩形（行视图只读几何）。
  func imageWindowRect(at index: Int) -> CGRect? {
    guard let rect = rowView.imageRect(at: index) else { return nil }
    return rowView.convert(rect, to: nil)
  }

  func playEntrance(index: Int) {
    rowView.playEntrance(index: index)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    if rowView.frame != contentView.bounds {
      rowView.frame = contentView.bounds
    }
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    rowView.prepareForReuse()
  }
}

// MARK: - 页脚（加载更多三态）

/// 页脚三态（对齐 LoadMoreFooter 的 hasMore/loading 组合）。
public enum TiebaKindFooterState: String {
  case more
  case loading
  case none
  case hidden
}

private final class TiebaKindFooterView: UICollectionReusableView {
  static let reuseIdentifier = "TiebaKindFooterView"
  static let elementKind = UICollectionView.elementKindSectionFooter

  private let spinner = UIActivityIndicatorView(style: .medium)
  private let label = UILabel()
  private let button = UIButton(type: .system)
  private let contentStack = UIStackView()
  private var onTap: (() -> Void)?

  /// 页脚高度：paddingVertical 20×2 + 内容高（spinner 20 / caption1 16 /
  /// footnoteBold 18 + 按钮 marginVertical 4×2）。
  static func height(for state: TiebaKindFooterState) -> CGFloat {
    let base: CGFloat = 40
    switch state {
    case .loading:
      return base + max(20, UIFontMetrics(forTextStyle: .footnote).scaledValue(for: 18))
    case .none:
      return base + UIFontMetrics(forTextStyle: .caption1).scaledValue(for: 16)
    case .more:
      return base + UIFontMetrics(forTextStyle: .footnote).scaledValue(for: 18) + 8
    case .hidden:
      return 0
    }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    spinner.hidesWhenStopped = true
    label.textAlignment = .center
    label.numberOfLines = 1
    contentStack.axis = .horizontal
    contentStack.alignment = .center
    contentStack.spacing = 10 // spinner 与文案的原横向间距
    contentStack.translatesAutoresizingMaskIntoConstraints = false
    for view in [spinner, label, button] as [UIView] {
      contentStack.addArrangedSubview(view)
    }
    addSubview(contentStack)
    NSLayoutConstraint.activate([
      contentStack.centerXAnchor.constraint(equalTo: centerXAnchor),
      contentStack.centerYAnchor.constraint(equalTo: centerYAnchor),
      contentStack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
      contentStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
    ])
    button.addTarget(self, action: #selector(handleButtonTap), for: .touchUpInside)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  func configure(
    state: TiebaKindFooterState,
    palette: TiebaSimpleRowPalette,
    onTap: @escaping () -> Void
  ) {
    self.onTap = onTap
    spinner.color = palette.base.primary
    let textColor = palette.base.textTertiary
    label.isHidden = state == .more
    button.isHidden = state != .more
    switch state {
    case .loading:
      spinner.startAnimating()
      label.attributedText = NSAttributedString(
        string: "加载中...",
        attributes: [
          .font: UIFontMetrics(forTextStyle: .footnote).scaledFont(
            for: .systemFont(ofSize: 13, weight: .semibold)
          ),
          .foregroundColor: textColor,
        ]
      )
    case .none:
      spinner.stopAnimating()
      label.attributedText = NSAttributedString(
        string: "没有更多了",
        attributes: [
          .font: UIFontMetrics(forTextStyle: .caption1).scaledFont(
            for: .systemFont(ofSize: 12, weight: .medium)
          ),
          .foregroundColor: textColor,
        ]
      )
    case .more:
      spinner.stopAnimating()
      label.attributedText = nil
      button.configuration = TiebaKindFooterView.moreConfiguration(palette: palette)
    case .hidden:
      spinner.stopAnimating()
      label.attributedText = nil
      button.configuration = nil
    }
  }

  /// 「加载更多」按钮：系统液态玻璃配置（UIButtonConfiguration.glassButtonConfiguration，
  /// iOS 26 起可用；部署目标 26 = 恒走此支）。
  private static func moreConfiguration(palette: TiebaSimpleRowPalette) -> UIButton.Configuration {
    var config = UIButton.Configuration.glass()
    config.cornerStyle = .capsule
    config.baseForegroundColor = palette.base.primary
    config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
      var outgoing = incoming
      outgoing.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(
        for: .systemFont(ofSize: 13, weight: .semibold)
      )
      return outgoing
    }
    config.title = "加载更多"
    // 原按钮宽 = 文字宽 + 56、高 = 文字高（footer height 预算里的 marginVertical 4）。
    config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 28, bottom: 4, trailing: 28)
    return config
  }

  @objc private func handleButtonTap() {
    onTap?()
  }
}

// MARK: - 列表 view body（纯 UIView）

/// 通用行列表的实体：UICollectionView + CompositionalLayout（custom group，
/// 帧由测量缓存逐个给出）+ DiffableDataSource。事件经 `onEvent` 闭包外传
/// （闭包内只声明 name + payload）。
public final class TiebaKindListContentView: UIView {
  // MARK: 接口（纯 Swift）

  /// 事件出口（name ∈ {"rowTap","visibleRangeChange","reachEnd",
  /// "refreshRequested","footerTap","swipeAction","menuAction","headerAction"}）。
  public var onEvent: ((String, [String: Any]) -> Void)?

  /// post 行的语义动作出口（原生页面用；与 onEvent 并存，互不影响）。
  /// internal：TiebaPostRowEvent 只在模块内使用。
  var onPostEvent: ((_ index: Int, _ event: TiebaPostRowEvent) -> Void)?

  /// 连续滚动回调（浮动栏自动隐藏用；不对每一次滚动做任何计算）。
  public var onScroll: ((UIScrollView) -> Void)?

  public private(set) var pageKey: String = ""

  /// 滚动头 spec（TiebaKindListHeaderFactory 的输入；nil = 无页头）。
  /// 内容等值时忽略（Fabric 每次 commit 都可能是新字典，不能按引用重建视图）。
  public var headerSpec: [String: Any]? {
    didSet {
      guard !TiebaKindListContentView.specEquals(headerSpec, oldValue) else { return }
      rebuildHeader()
    }
  }

  public var footerState: TiebaKindFooterState = .hidden {
    didSet {
      guard footerState != oldValue else { return }
      collectionView.collectionViewLayout.invalidateLayout()
      updateVisibleFooter()
    }
  }

  /// 首屏入场动画开关（EntranceRow 的等价：首批页面窗口内新建 cell 播级联动画）。
  public var entranceAnimationEnabled: Bool = true

  /// 行左右内缩（= RN contentContainerStyle.paddingHorizontal）。
  public var horizontalInset: CGFloat = 0 {
    didSet {
      guard horizontalInset != oldValue else { return }
      collectionView.collectionViewLayout.invalidateLayout()
    }
  }

  /// 行间距（ItemSeparatorComponent 的原生等价：加在非末行高度里）。
  public var separatorHeight: CGFloat = 0 {
    didSet {
      guard separatorHeight != oldValue else { return }
      frameHeightCache = nil
      collectionView.collectionViewLayout.invalidateLayout()
    }
  }

  /// 触底阈值（视口高的比例；距内容底 < 阈值×视口高即发 reachEnd）。
  public var reachEndThreshold: CGFloat = 0.3

  /// 顶部内容内白（对齐 contentContainerStyle.paddingTop）。
  /// ⚠️ 这是**内容内白**（加在内容顶端之上、可随滚动滑出），不是
  /// collectionView.contentInset.top：后者会把系统 UIRefreshControl 的静止位
  /// 一起推下去（要拉 74pt 才看得见 spinner），与 RN 的 paddingTop 语义不同。
  /// 有页头时它落在页头之上（原 RN 的 paddingTop 也在 ListHeaderComponent 之上）。
  public var contentInsetTop: CGFloat = 0 {
    didSet {
      guard contentInsetTop != oldValue else { return }
      headerHeightCache = nil
      collectionView.collectionViewLayout.invalidateLayout()
      updateVisibleHeader()
    }
  }

  /// 底部内容内缩（对齐 contentContainerStyle.paddingBottom）：系统标准做法
  /// （contentInset.bottom 扩展可滚动区，与 RN paddingBottom 同效）。
  public var contentInsetBottom: CGFloat = 0 {
    didSet {
      guard contentInsetBottom != oldValue else { return }
      applyContentInset()
    }
  }

  /// 拖尾侧滑动作（**系统实现**：trailingSwipeActionsConfigurationForItemAt +
  /// UIContextualAction）。每项 [{ action, title, icon, destructive,
  /// backgroundColor }]；空 = 无侧滑。系统负责手势/物理/揭示动画，点击回调
  /// 经 onEvent("swipeAction") 外传，数据变更仍由调用方执行。
  public var swipeActions: [[String: Any]] = []

  public var palette: TiebaSimpleRowPalette = .default {
    didSet {
      guard palette != oldValue else { return }
      refreshControl.tintColor = palette.base.primary
      updateVisibleFooter()
      headerContentView?.applyPalette(palette)
      for cell in collectionView.visibleCells {
        (cell as? TiebaKindListViewCell)?.applyPalette(palette)
        // 信息流行用 TiebaFeedRowPalette = 本页色板的 base（同一份主题字典
        // 两条视图族各自消费；行视图只重绘、不重测）。
        (cell as? TiebaKindListFeedCell)?.applyPalette(palette.base)
        // 帖子行同样吃 TiebaSimpleRowPalette；运行期换主题必须一起刷，否则留旧色。
        (cell as? TiebaKindListPostCell)?.applyPalette(palette)
      }
    }
  }

  /// 页数据已在度量缓存中（调用方先走 TiebaRowPageDriver / prepareBlocking）。
  /// 换页键 = 整页更换：reload 快照（identifier 全变，diff 无意义）；同页仅行数
  /// 变化走 diff 保滚动位。
  public func setPage(pageKey: String) {
    let isSamePage = (self.pageKey == pageKey)
    self.pageKey = pageKey
    frameHeightCache = nil
    if !isSamePage {
      // 换页后可见区间即便与旧页数值相同（都 0…7）也必须重发，否则懒回填
      //（History/Subposts 依赖 visibleRangeChange）被去重吞掉。
      lastVisibleRange = nil
    }
    endRefreshing()
    // 行数取自页记录（TiebaKindRowPages）：度量被 LRU 淘汰时仍要画出等量
    // 占位行（行高走兜底），不能靠度量缓存的行数。
    let count = TiebaKindRowPages.shared.rowCount(pageKey: pageKey)
    if isSamePage, count == itemCount {
      collectionView.collectionViewLayout.invalidateLayout()
      reconfigureVisibleItems()
      return
    }
    reachEndArmed = true
    itemCount = count
    if !entrancePlayed, count > 0 {
      entrancePlayed = true
      if entranceAnimationEnabled {
        entrancePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
          self?.entrancePending = false
        }
      }
    }
    var snapshot = NSDiffableDataSourceSnapshot<Int, TiebaKindItem>()
    if count > 0 {
      snapshot.appendSections([0])
      snapshot.appendItems((0..<count).map { TiebaKindItem(pageKey: pageKey, index: $0) }, toSection: 0)
    }
    if isSamePage {
      dataSource.apply(snapshot, animatingDifferences: false)
    } else {
      dataSource.applySnapshotUsingReloadData(snapshot)
    }
    collectionView.collectionViewLayout.invalidateLayout()
    setNeedsLayout()
  }

  public func scrollToTop(animated: Bool) {
    collectionView.setContentOffset(
      CGPoint(x: 0, y: -collectionView.adjustedContentInset.top),
      animated: animated
    )
  }

  public func endRefreshing() {
    if refreshControl.isRefreshing {
      refreshControl.endRefreshing()
    }
  }

  // MARK: 状态

  private var itemCount = 0
  private var reachEndArmed = true
  private var lastVisibleRange: (start: Int, end: Int)?
  private var lastLaidOutSize: CGSize = .zero
  private var entrancePending = false
  private var entrancePlayed = false
  /// 整页帧高缓存：key =（pageKey, itemWidth, 行数）。布局输入不变时（页脚/主题/
  /// contentInset 变化都会 invalidateLayout）复用，不再逐行查度量（每行 2 次锁）。
  private var frameHeightCache: (pageKey: String, width: CGFloat, heights: [CGFloat])?
  private weak var visibleFooterView: TiebaKindFooterView?
  private weak var visibleHeaderHostView: TiebaKindListHeaderHostView?
  /// 当前页头视图（headerSpec 造出；nil = 无页头）。
  private var headerContentView: (any TiebaKindListHeaderView)?
  /// 页头总高缓存（(列表宽) → contentInsetTop + 页头自适应高）。
  private var headerHeightCache: (width: CGFloat, height: CGFloat)?
  private var isBrowserPresented = false
  private let refreshControl = UIRefreshControl()

  private let prefetcher = TiebaNuke.makePrefetcher()

  // MARK: 子视图

  private lazy var collectionView: UICollectionView = {
    let view = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
    view.backgroundColor = .clear
    view.isOpaque = false
    view.alwaysBounceVertical = true
    view.showsVerticalScrollIndicator = true
    view.contentInsetAdjustmentBehavior = .never
    view.allowsSelection = false
    view.register(
      TiebaKindFooterView.self,
      forSupplementaryViewOfKind: TiebaKindFooterView.elementKind,
      withReuseIdentifier: TiebaKindFooterView.reuseIdentifier
    )
    view.register(
      TiebaKindListHeaderHostView.self,
      forSupplementaryViewOfKind: TiebaKindListHeaderHostView.elementKind,
      withReuseIdentifier: TiebaKindListHeaderHostView.reuseIdentifier
    )
    return view
  }()

  private lazy var dataSource: UICollectionViewDiffableDataSource<Int, TiebaKindItem> = {
    let source = UICollectionViewDiffableDataSource<Int, TiebaKindItem>(
      collectionView: collectionView
    ) { [unowned self] collectionView, indexPath, item in
      // 行种类分派：页记录说这一行是哪一族（缺省/未知 = simple，与旧页兼容）。
      switch TiebaKindRowPages.shared.kind(pageKey: item.pageKey, index: item.index) {
      case .feed:
        return collectionView.dequeueConfiguredReusableCell(
          using: self.feedCellRegistration,
          for: indexPath,
          item: item
        )
      case .post:
        return collectionView.dequeueConfiguredReusableCell(
          using: self.postCellRegistration,
          for: indexPath,
          item: item
        )
      case .simple, .none:
        return collectionView.dequeueConfiguredReusableCell(
          using: self.simpleCellRegistration,
          for: indexPath,
          item: item
        )
      }
    }
    // 补充视图：页头（top boundary item）+ 页脚（bottom boundary item），同一
    // provider 按 kind 分派；页头内容由本视图持有的 headerContentView 提供
    //（一页一个头，不做复用池）。
    source.supplementaryViewProvider = { [weak self] collectionView, kind, indexPath in
      guard let self else { return nil }
      if kind == TiebaKindListHeaderHostView.elementKind {
        guard let host = collectionView.dequeueReusableSupplementaryView(
          ofKind: kind,
          withReuseIdentifier: TiebaKindListHeaderHostView.reuseIdentifier,
          for: indexPath
        ) as? TiebaKindListHeaderHostView else { return nil }
        host.configure(content: self.headerContentView, topPadding: max(self.contentInsetTop, 0))
        self.visibleHeaderHostView = host
        return host
      }
      guard kind == TiebaKindFooterView.elementKind else { return nil }
      guard let footer = collectionView.dequeueReusableSupplementaryView(
        ofKind: kind,
        withReuseIdentifier: TiebaKindFooterView.reuseIdentifier,
        for: indexPath
      ) as? TiebaKindFooterView else { return nil }
      footer.configure(state: self.footerState, palette: self.palette) { [weak self] in
        self?.handleFooterTap()
      }
      self.visibleFooterView = footer
      return footer
    }
    return source
  }()

  /// 简单行 cell（TiebaSimpleRowView；命中区域 = 行视图自己判定）。
  private lazy var simpleCellRegistration =
    UICollectionView.CellRegistration<TiebaKindListViewCell, TiebaKindItem> {
      [unowned self] cell, indexPath, item in
      cell.onTap = { [weak self] point in
        self?.handleTap(at: indexPath, point: point)
      }
      cell.applyPalette(self.palette)
      cell.apply(model: self.simpleModel(at: item.index))
      if self.entrancePending {
        cell.playEntrance(index: item.index)
      }
    }

  /// 信息流行 cell（TiebaFeedRowView；行内菜单回传 + 整卡点击上报）。
  private lazy var feedCellRegistration =
    UICollectionView.CellRegistration<TiebaKindListFeedCell, TiebaKindItem> {
      [unowned self] cell, indexPath, item in
      cell.onTap = { [weak self] point in
        self?.handleTap(at: indexPath, point: point)
      }
      cell.onRowMenuAction = { [weak self] action in
        self?.handleRowMenuAction(action, at: indexPath)
      }
      cell.onMediaMenuAction = { [weak self] mediaIndex, action in
        self?.handleMediaMenuAction(action, mediaIndex: mediaIndex, at: indexPath)
      }
      cell.applyPalette(self.palette.base)
      if let sub = TiebaKindRowPages.shared.subIndex(pageKey: item.pageKey, index: item.index) {
        cell.apply(pageKey: item.pageKey, index: sub)
      }
      if self.entrancePending {
        cell.playEntrance(index: item.index)
      }
    }

  /// 帖子行 cell（TiebaPostRowView；行内自管交互，cell 只转发事件）。
  private lazy var postCellRegistration =
    UICollectionView.CellRegistration<TiebaKindListPostCell, TiebaKindItem> {
      [unowned self] cell, indexPath, item in
      cell.onPostEvent = { [weak self] event in
        self?.onPostEvent?(indexPath.item, event)
      }
      cell.applyPalette(self.palette)
      cell.apply(pageKey: item.pageKey, index: item.index)
      if self.entrancePending {
        cell.playEntrance(index: item.index)
      }
    }

  // MARK: 初始化

  public override init(frame: CGRect) {
    super.init(frame: frame)
    isOpaque = false
    backgroundColor = .clear
    clipsToBounds = true

    addSubview(collectionView)
    collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    collectionView.frame = bounds
    collectionView.delegate = self
    collectionView.dataSource = dataSource
    collectionView.prefetchDataSource = self

    // ⚠️ 三个 cell 注册必须在这里就建好，不能等 cellProvider 首次访问 lazy 属性再建：
    // UIKit 会断言"registration 是在 cell provider 里创建的"并抛
    // NSInternalInconsistencyException（真机崩溃原文：Attempted to dequeue a cell
    // using a registration that was created inside … a UICollectionViewDiffableDataSource
    // cell provider）。三条具名访问就是"提前创建"本身——三者泛型不同，别写成数组。
    _ = simpleCellRegistration
    _ = feedCellRegistration
    _ = postCellRegistration

    refreshControl.addTarget(self, action: #selector(handleRefreshControl), for: .valueChanged)
    refreshControl.tintColor = palette.base.primary
    collectionView.refreshControl = refreshControl
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  deinit {
    prefetcher.stopPrefetching()
  }

  public override func layoutSubviews() {
    super.layoutSubviews()
    if collectionView.frame != bounds {
      collectionView.frame = bounds
    }
    // 宽度变化 = 行宽变化（高度缓存按宽度键控）：显式让 section provider 按新宽度
    // 重跑（量化口径见 TiebaLayout）。
    if bounds.size != lastLaidOutSize {
      lastLaidOutSize = bounds.size
      collectionView.collectionViewLayout.invalidateLayout()
      // setPage 早于首次布局时行宽为 0，行数查到 0、快照为空；布局拿到真实宽度
      // 后按新行宽重查一次（否则列表永久空白）。
      reapplyPageIfNeeded()
    }
    // 内容不足一屏时也要触发触底（首帧即 onEndReached 同语义）。
    updateReachEnd()
  }

  public override func didMoveToWindow() {
    super.didMoveToWindow()
    updatePrefetcherPause()
  }

  private func updatePrefetcherPause() {
    // 离屏 ∥ 查看器打开：两个条件合成一处（否则"打开查看器 → 列表离屏 → 关
    // 查看器"会把离屏的那次暂停覆盖成运行态）。
    prefetcher.isPaused = isBrowserPresented || window == nil
  }

  /// 行宽变化后按新宽度复查页内行数；与当前 itemCount 不一致即重建快照。
  /// 行数取自页记录（宽度无关），两族度量的宽度失配由 cell/高度查询各自兜底。
  private func reapplyPageIfNeeded() {
    guard !pageKey.isEmpty else { return }
    let count = TiebaKindRowPages.shared.rowCount(pageKey: pageKey)
    guard count != itemCount else { return }
    setPage(pageKey: pageKey)
  }

  private func applyContentInset() {
    collectionView.contentInset = UIEdgeInsets(
      top: 0,
      left: 0,
      bottom: contentInsetBottom,
      right: 0
    )
  }

  // MARK: 尺寸

  /// 单行宽 = TiebaLayout.quantize(集合视图宽 - 2×horizontalInset)；调用方推页时
  /// 的 containerWidth 必须按同一式算（各度量族的宽度闸门靠它命中）。
  private var itemWidth: CGFloat {
    TiebaLayout.quantize(max(collectionView.bounds.width - horizontalInset * 2, 0))
  }

  /// 兜底行高（simple 行）：测量缺失（页被 LRU 淘汰 / 尚未按当前宽度重推）时占位。
  static let fallbackItemHeight: CGFloat = 72

  /// 兜底行高（feed 行）：信息流卡片是数百 pt 的高块，用 simple 的 72pt 兜底会
  /// 在滚动中剧烈跳动，取信息流卡片的惯用兜底高（160）。
  static let fallbackFeedItemHeight: CGFloat = 160

  private func simpleModel(at index: Int) -> TiebaSimpleRowModel? {
    guard !pageKey.isEmpty,
          let sub = TiebaKindRowPages.shared.subIndex(pageKey: pageKey, index: index) else {
      return nil
    }
    return TiebaSimpleRowMetrics.shared.row(pageKey: pageKey, containerWidth: itemWidth, index: sub)
  }

  private func feedModel(at index: Int) -> TiebaFeedRowModel? {
    guard !pageKey.isEmpty,
          let sub = TiebaKindRowPages.shared.subIndex(pageKey: pageKey, index: index) else {
      return nil
    }
    return TiebaRowMetrics.shared.feedRow(pageKey: pageKey, index: sub)
  }

  private func postModel(at index: Int) -> TiebaPostRowModel? {
    guard !pageKey.isEmpty,
          let sub = TiebaKindRowPages.shared.subIndex(pageKey: pageKey, index: index) else {
      return nil
    }
    return TiebaPostRowMetrics.shared.row(pageKey: pageKey, index: sub)
  }

  private func frameHeight(at index: Int, width: CGFloat) -> CGFloat {
    var height: CGFloat
    switch TiebaKindRowPages.shared.kind(pageKey: pageKey, index: index) {
    case .post:
      // 帖子行：高度自带（含卡片内外边距）；宽度闸门同 feed 行（对不上宁可
      // 矮一截，也不拿旧宽度帧计划画新宽度）。
      if let model = postModel(at: index), model.containerWidth == width {
        height = model.measuredHeight
      } else {
        height = TiebaKindListContentView.fallbackFeedItemHeight
      }
    case .feed:
      // 信息流行：高度 = 行模型自带（含卡片外 4pt 上下边距）；宽度对不上宁可
      // 矮一截，也不拿旧宽度帧计划画新宽度。
      if let sub = TiebaKindRowPages.shared.subIndex(pageKey: pageKey, index: index),
         let row = TiebaRowMetrics.shared.feedRow(pageKey: pageKey, index: sub),
         row.containerWidth == width {
        height = row.measuredHeight
      } else {
        height = TiebaKindListContentView.fallbackFeedItemHeight
      }
    case .simple, .none:
      height = TiebaKindListContentView.fallbackItemHeight
      if !pageKey.isEmpty,
         let sub = TiebaKindRowPages.shared.subIndex(pageKey: pageKey, index: index),
         let measured = TiebaSimpleRowMetrics.shared.rowHeight(
           pageKey: pageKey,
           containerWidth: width,
           index: sub
         ), measured > 0 {
        height = measured
      }
    }
    // ItemSeparatorComponent 等价：行间距加在非末行（末行后不留空带）。
    if index < itemCount - 1 {
      height += separatorHeight
    }
    return height
  }

  /// 整页帧高：按 (pageKey, itemWidth, 行数) 缓存。页脚/主题/contentInset 变化
  /// 都会 invalidateLayout，但帧高输入没变——只重建失效部分，不逐行重查度量。
  private func frameHeights(width: CGFloat, count: Int) -> [CGFloat] {
    if let cache = frameHeightCache,
       cache.pageKey == pageKey,
       cache.width == width,
       cache.heights.count == count {
      return cache.heights
    }
    var heights: [CGFloat] = []
    heights.reserveCapacity(count)
    for index in 0..<count {
      heights.append(frameHeight(at: index, width: width))
    }
    frameHeightCache = (pageKey, width, heights)
    return heights
  }

  // MARK: 滚动头（top boundary supplementary item）

  private var hasHeader: Bool { headerContentView != nil }

  /// 页头总高 = contentInsetTop + 页头自适应高（按列表全宽）。0 = 不挂页头。
  /// 缓存按宽度键控：宽度变化（旋转/分屏）时由 layoutSubviews 的 invalidate 重算。
  private func headerTotalHeight(width: CGFloat) -> CGFloat {
    guard let headerContentView else { return 0 }
    if let cache = headerHeightCache, cache.width == width {
      return cache.height
    }
    let height = max(contentInsetTop, 0) + headerContentView.headerHeight(forWidth: width)
    headerHeightCache = (width, height)
    return height
  }

  /// spec 变化 → 重建页头视图（spec 等值时不会走到这里，见 headerSpec.didSet）。
  private func rebuildHeader() {
    headerContentView?.removeFromSuperview()
    headerContentView = headerSpec.flatMap { TiebaKindListHeaderFactory.make(spec: $0) }
    headerContentView?.onAction = { [weak self] name, payload in
      self?.handleHeaderAction(name, payload)
    }
    headerContentView?.applyPalette(palette)
    headerHeightCache = nil
    collectionView.collectionViewLayout.invalidateLayout()
    updateVisibleHeader()
  }

  /// 在屏 host 重新接管页头（spec/insets/主题变化时；高度变化由 invalidateLayout
  /// 重跑 section provider 完成）。
  private func updateVisibleHeader() {
    visibleHeaderHostView?.configure(
      content: headerContentView,
      topPadding: max(contentInsetTop, 0)
    )
  }

  private func handleHeaderAction(_ name: String, _ payload: [String: Any]) {
    var event: [String: Any] = ["pageKey": pageKey, "action": name]
    for (key, value) in payload {
      event[key] = value
    }
    emit("headerAction", event)
  }

  /// spec 等值比较（Fabric 每次 commit 都可能给新字典；引用比较会重建视图）。
  private static func specEquals(_ lhs: [String: Any]?, _ rhs: [String: Any]?) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil):
      return true
    case let (lhs?, rhs?):
      return NSDictionary(dictionary: lhs).isEqual(to: rhs)
    default:
      return false
    }
  }

  // MARK: 布局（CompositionalLayout）

  private func makeLayout() -> UICollectionViewCompositionalLayout {
    let configuration = UICollectionViewCompositionalLayoutConfiguration()
    configuration.scrollDirection = .vertical
    configuration.interSectionSpacing = 0
    return UICollectionViewCompositionalLayout(sectionProvider: { [weak self] sectionIndex, _ in
      self?.makeSection(index: sectionIndex) ?? TiebaKindListContentView.emptySection()
    }, configuration: configuration)
  }

  private func makeSection(index sectionIndex: Int) -> NSCollectionLayoutSection {
    guard sectionIndex < collectionView.numberOfSections else {
      return TiebaKindListContentView.emptySection()
    }
    // 行宽来源与 itemWidth / frameHeight 完全同一处（collectionView.bounds.width）
    // ——两边算法必须逐位一致，否则高度查询的宽度闸门拒绝命中，整列表退回兜底高。
    let itemWidth = self.itemWidth
    let count = collectionView.numberOfItems(inSection: sectionIndex)
    guard count > 0, itemWidth > 0 else {
      return TiebaKindListContentView.emptySection()
    }
    let inset = horizontalInset
    var frames: [NSCollectionLayoutGroupCustomItem] = []
    frames.reserveCapacity(count)
    // 内容内白（paddingTop 语义）：有页头时页头在最上、内白在页头之上（由 header
    // host 的 topPadding 承担，见 updateVisibleHeader / headerTotalHeight），
    // 组内不再留白；无页头时保持原行为（内白加在首行 frame 之上、随滚动滑出）。
    let heights = frameHeights(width: itemWidth, count: count)
    var y: CGFloat = hasHeader ? 0 : max(contentInsetTop, 0)
    for index in 0..<count {
      let height = heights[index]
      frames.append(
        NSCollectionLayoutGroupCustomItem(
          frame: CGRect(x: inset, y: y, width: itemWidth, height: height)
        )
      )
      y += height
    }
    let size = NSCollectionLayoutSize(
      widthDimension: .fractionalWidth(1),
      heightDimension: .absolute(y)
    )
    let group = NSCollectionLayoutGroup.custom(layoutSize: size) { _ in frames }
    let section = NSCollectionLayoutSection(group: group)
    section.contentInsets = .zero
    section.interGroupSpacing = 0
    var supplementaryItems: [NSCollectionLayoutBoundarySupplementaryItem] = []
    // 滚动头：页头视图按列表宽自适应高度（粘在 section 顶部，不悬浮——随内容滚走）。
    let headerHeight = headerTotalHeight(width: collectionView.bounds.width)
    if headerHeight > 0 {
      supplementaryItems.append(
        NSCollectionLayoutBoundarySupplementaryItem(
          layoutSize: NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1),
            heightDimension: .absolute(headerHeight)
          ),
          elementKind: TiebaKindListHeaderHostView.elementKind,
          alignment: .top
        )
      )
    }
    let footerHeight = TiebaKindFooterView.height(for: footerState)
    if footerHeight > 0 {
      supplementaryItems.append(
        NSCollectionLayoutBoundarySupplementaryItem(
          layoutSize: NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1),
            heightDimension: .absolute(footerHeight)
          ),
          elementKind: TiebaKindFooterView.elementKind,
          alignment: .bottom
        )
      )
    }
    section.boundarySupplementaryItems = supplementaryItems
    return section
  }

  private static func emptySection() -> NSCollectionLayoutSection {
    let size = NSCollectionLayoutSize(
      widthDimension: .fractionalWidth(1),
      heightDimension: .absolute(1)
    )
    let group = NSCollectionLayoutGroup.custom(layoutSize: size) { _ in [] }
    return NSCollectionLayoutSection(group: group)
  }

  // MARK: 快照辅助

  private func reconfigureVisibleItems() {
    let visible = collectionView.indexPathsForVisibleItems
      .compactMap { dataSource.itemIdentifier(for: $0) }
    guard !visible.isEmpty else { return }
    var snapshot = dataSource.snapshot()
    snapshot.reconfigureItems(visible)
    dataSource.apply(snapshot, animatingDifferences: false)
  }

  // MARK: 事件

  private func emit(_ name: String, _ payload: [String: Any]) {
    onEvent?(name, payload)
  }

  private func handleTap(at indexPath: IndexPath, point: CGPoint) {
    guard !pageKey.isEmpty else { return }
    let index = indexPath.item
    // 信息流行：命中区域按行模型 layoutPlan 判定（几何单一来源 = TiebaFeedRowInteraction），
    // 真实图片点击 → 原生查看器直开（不发事件）。
    if TiebaKindRowPages.shared.kind(pageKey: pageKey, index: index) == .feed {
      guard let row = feedModel(at: index) else {
        emit("rowTap", ["pageKey": pageKey, "index": index, "region": "card"])
        return
      }
      let hit = TiebaFeedRowInteraction.tapRegion(for: point, row: row)
      if hit.region == "media", !row.media.isEmpty,
         let cell = collectionView.cellForItem(at: indexPath) as? TiebaKindListFeedCell,
         let media = cell.mediaHit(at: point),
         presentPhotoBrowser(row: row, media: media, at: indexPath) {
        return
      }
      var payload: [String: Any] = [
        "pageKey": pageKey,
        "index": index,
        "region": hit.region,
      ]
      if let actionIndex = hit.actionIndex { payload["actionIndex"] = actionIndex }
      emit("rowTap", payload)
      return
    }
    // 简单行：命中区域由行视图给出（"avatar" = 作者点击区，其余 = 整卡）。
    let cell = collectionView.cellForItem(at: indexPath) as? TiebaKindListViewCell
    let region = cell?.hitRegion(at: point) ?? "card"
    emit("rowTap", ["pageKey": pageKey, "index": index, "region": region])
  }

  /// 行内菜单（右上角 × 的 ActionSheet；行视图自弹，选中项只回传）。
  private func handleRowMenuAction(_ action: String, at indexPath: IndexPath) {
    emit("menuAction", [
      "pageKey": pageKey,
      "index": indexPath.item,
      "action": action,
    ])
  }

  /// 不感兴趣退场：先让该行播折叠动画（数据保持在位），动画窗口后再回调删数据
  /// （原 JS collapsingId + 360ms 兜底定时器同一时序）。行已滚出/被复用 → 直接回调。
  func collapseRowThen(atIndex index: Int, remove: @escaping () -> Void) {
    let indexPath = IndexPath(item: index, section: 0)
    guard !pageKey.isEmpty,
          let item = dataSource.itemIdentifier(for: indexPath), item.pageKey == pageKey,
          let cell = collectionView.cellForItem(at: indexPath) as? TiebaKindListFeedCell
    else {
      remove()
      return
    }
    cell.playCollapse()
    DispatchQueue.main.asyncAfter(
      deadline: .now() + TiebaFeedRowView.collapseDuration + 0.08
    ) { remove() }
  }

  /// 图片长按菜单（保存照片 / 分享照片）事件外传（水印偏好/相册权限/toast 由
  /// 调用方执行）。
  private func handleMediaMenuAction(_ action: String, mediaIndex: Int, at indexPath: IndexPath) {
    var payload: [String: Any] = [
      "pageKey": pageKey,
      "index": indexPath.item,
      "mediaIndex": mediaIndex,
      "action": action,
    ]
    if let row = feedModel(at: indexPath.item), mediaIndex >= 0, mediaIndex < row.media.count {
      let media = row.media[mediaIndex]
      if let url = media.url { payload["url"] = url.absoluteString }
      if let origin = media.originURL { payload["originUrl"] = origin.absoluteString }
    }
    emit("menuAction", payload)
  }

  // MARK: 查看器退出重算（几何只读查询；行不可见/未挂载 → nil 走框架 Fade）

  /// feed 行：行内第 mediaIndex 张图的窗口矩形；行已滚出/被复用/该图滑出图片带 → nil。
  func feedMediaWindowRect(rowIndex: Int, mediaIndex: Int) -> CGRect? {
    let indexPath = IndexPath(item: rowIndex, section: 0)
    guard !pageKey.isEmpty,
          let item = dataSource.itemIdentifier(for: indexPath), item.pageKey == pageKey,
          let cell = collectionView.cellForItem(at: indexPath) as? TiebaKindListFeedCell
    else { return nil }
    return cell.mediaWindowRect(atMediaIndex: mediaIndex)
  }

  /// post 行：第 imageIndex 张图的窗口矩形；同上，拿不到 → nil。
  func postImageWindowRect(rowIndex: Int, imageIndex: Int) -> CGRect? {
    let indexPath = IndexPath(item: rowIndex, section: 0)
    guard !pageKey.isEmpty,
          let item = dataSource.itemIdentifier(for: indexPath), item.pageKey == pageKey,
          let cell = collectionView.cellForItem(at: indexPath) as? TiebaKindListPostCell
    else { return nil }
    return cell.imageWindowRect(at: imageIndex)
  }

  /// 图片点击 → 原生查看器（TiebaPhotoBrowser）直开：items/transition 全原生
  /// 构建，不发 rowTap。
  /// 揭示移位（useViewerSourceReveal 的原生等价）在展示动画后滚动列表，transition
  /// 用移位后矩形；打开期间暂停 Nuke 预取，关闭事件恢复。
  private func presentPhotoBrowser(
    row: TiebaFeedRowModel,
    media: (index: Int, windowRect: CGRect),
    at indexPath: IndexPath
  ) -> Bool {
    guard let plan = TiebaFeedRowInteraction.browserPlan(
      row: row,
      tappedMediaIndex: media.index,
      windowRect: media.windowRect,
      in: window,
      contentOffset: collectionView.contentOffset.y,
      contentSize: collectionView.contentSize,
      adjustedContentInset: collectionView.adjustedContentInset
    ) else {
      return false
    }
    // onEvent 只剩 dismiss（浏览器内部原生回调）；会话同一时刻只有一个，present
    // 未受理时把原 handler 放回（防御性，不吞掉别人的订阅）。
    let previousHandler = TiebaPhotoBrowser.onEvent
    TiebaPhotoBrowser.onEvent = { [weak self] name, _ in
      guard name == "dismiss" else { return }
      TiebaPhotoBrowser.onEvent = nil
      self?.isBrowserPresented = false
      self?.updatePrefetcherPause()
    }
    // 闭包只带 Sendable 值（Int 数组/下标），不把非 Sendable 的 plan 带进主机回调。
    let mediaIndexes = plan.mediaIndexes
    let rowIndex = indexPath.item
    let presented = TiebaPhotoBrowser.present(
      items: plan.items,
      initialIndex: plan.initialIndex,
      transition: plan.transition,
      sourceFrameProvider: { [weak self] pageIndex in
        // 页号 → 行内 media 下标（url 为 nil 被过滤时会错位）→ 当前可见矩形。
        guard let self, mediaIndexes.indices.contains(pageIndex) else { return nil }
        return self.feedMediaWindowRect(
          rowIndex: rowIndex,
          mediaIndex: mediaIndexes[pageIndex]
        )
      }
    )
    if presented {
      isBrowserPresented = true
      updatePrefetcherPause()
      if let scrollDelta = plan.scrollDelta {
        // 展示动画约 0.35s：之后 Modal 已完全盖住列表，滚动不可见，也不会
        // 干扰 Zoom 转场。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
          guard let self, self.isBrowserPresented else { return }
          self.collectionView.setContentOffset(
            CGPoint(x: 0, y: self.collectionView.contentOffset.y + scrollDelta),
            animated: true
          )
        }
      }
    } else {
      TiebaPhotoBrowser.onEvent = previousHandler
    }
    return presented
  }

  private func handleFooterTap() {
    emit("footerTap", ["pageKey": pageKey])
  }

  private func updateVisibleFooter() {
    guard let footer = visibleFooterView else { return }
    footer.configure(state: footerState, palette: palette) { [weak self] in
      self?.handleFooterTap()
    }
  }

  @objc private func handleRefreshControl() {
    emit("refreshRequested", ["pageKey": pageKey])
  }

  /// 视口区间（含端点）：仅变化时上报（调用方用它做页存活兜底）。
  private func updateVisibleRange() {
    let visible = collectionView.indexPathsForVisibleItems
    guard !visible.isEmpty else {
      lastVisibleRange = nil
      return
    }
    var first = Int.max
    var last = Int.min
    for path in visible {
      first = min(first, path.item)
      last = max(last, path.item)
    }
    guard lastVisibleRange?.start != first || lastVisibleRange?.end != last else { return }
    lastVisibleRange = (first, last)
    emit("visibleRangeChange", [
      "pageKey": pageKey,
      "start": first,
      "end": last,
      "count": itemCount,
    ])
  }

  /// 触底（阈值制）：距内容底 < 阈值×视口高 且已武装 → 发一次 reachEnd；
  /// 离开阈值区重新武装（一次性语义）。
  private func updateReachEnd() {
    guard itemCount > 0, !pageKey.isEmpty else { return }
    let inset = collectionView.adjustedContentInset
    let visibleHeight = collectionView.bounds.height
    guard visibleHeight > 0 else { return }
    // setPage 末尾的 setNeedsLayout 会先触发 layoutSubviews：此刻集合视图尚未
    // 按新快照布局（contentSize = 0/上一页高），负距离会直接误发 reachEnd。
    guard collectionView.contentSize.height > 0 else { return }
    let distance = collectionView.contentSize.height
      + inset.bottom
      - (collectionView.contentOffset.y + visibleHeight)
    let trigger = max(reachEndThreshold, 0) * visibleHeight
    if distance > trigger {
      reachEndArmed = true
      return
    }
    guard reachEndArmed else { return }
    reachEndArmed = false
    emit("reachEnd", ["pageKey": pageKey, "count": itemCount])
  }
}

// MARK: - UICollectionViewDelegate

extension TiebaKindListContentView: UICollectionViewDelegate {
  public func collectionView(
    _ collectionView: UICollectionView,
    willDisplay cell: UICollectionViewCell,
    forItemAt indexPath: IndexPath
  ) {
    updateVisibleRange()
    updateReachEnd()
  }

  public func collectionView(
    _ collectionView: UICollectionView,
    didEndDisplaying cell: UICollectionViewCell,
    forItemAt indexPath: IndexPath
  ) {
    updateVisibleRange()
  }

  public func scrollViewDidScroll(_ scrollView: UIScrollView) {
    updateVisibleRange()
    updateReachEnd()
    onScroll?(scrollView)
  }

  /// 拖尾侧滑（**系统自带**，替代手写 TiebaSwipeActionView）：手势/物理/揭示
  /// 动画全由 UIKit 负责，本方法只按调用方下发的配置组装动作。
  /// 视觉映射（删除动作的原参数）：
  ///   actionBackgroundColor #FF3B30 → UIContextualAction.backgroundColor；
  ///   symbol trash 17 semibold → UIImage(systemName:, pointSize:)；
  ///   title 删除 → UIContextualAction.title。
  /// ⚠️ 与手写版的差异（系统不可配置，已报告）：动作条为整行高、无 4/16pt 外边距
  /// 与 16pt 连续圆角；图标与标题由系统纵向堆叠。
  public func collectionView(
    _ collectionView: UICollectionView,
    trailingSwipeActionsConfigurationForItemAt indexPath: IndexPath
  ) -> UISwipeActionsConfiguration? {
    guard !swipeActions.isEmpty else { return nil }
    var actions: [UIContextualAction] = []
    for spec in swipeActions {
      guard let actionId = spec["action"] as? String, !actionId.isEmpty else { continue }
      let destructive = (spec["destructive"] as? Bool) ?? false
      let action = UIContextualAction(
        style: destructive ? .destructive : .normal,
        title: spec["title"] as? String
      ) { [weak self] _, _, completion in
        guard let self else {
          completion(false)
          return
        }
        self.emit("swipeAction", [
          "pageKey": self.pageKey,
          "index": indexPath.item,
          "action": actionId,
        ])
        // 数据变更由调用方执行，系统只负责收拢动作条。
        completion(true)
      }
      if let icon = spec["icon"] as? String, !icon.isEmpty {
        action.image = UIImage(
          systemName: icon,
          withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        )
      }
      if let raw = spec["backgroundColor"] as? String, let color = tiebaColor(from: raw) {
        action.backgroundColor = color
      }
      actions.append(action)
    }
    guard !actions.isEmpty else { return nil }
    let configuration = UISwipeActionsConfiguration(actions: actions)
    configuration.performsFirstActionWithFullSwipe = true
    return configuration
  }
}

// MARK: - 预取（Nuke ImagePrefetcher；按行种类分派同处理器请求）

extension TiebaKindListContentView: UICollectionViewDataSourcePrefetching {
  public func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
    let requests = prefetchRequests(for: indexPaths)
    guard !requests.isEmpty else { return }
    prefetcher.startPrefetching(with: requests)
  }

  public func collectionView(
    _ collectionView: UICollectionView,
    cancelPrefetchingForItemsAt indexPaths: [IndexPath]
  ) {
    let requests = prefetchRequests(for: indexPaths)
    guard !requests.isEmpty else { return }
    prefetcher.stopPrefetching(with: requests)
  }

  /// 预取请求必须与展示侧同 URL（secureURL）+ 同处理器：Nuke 的缓存键含处理器，
  /// 裸 URL 预取既不命中展示缓存，还会把全尺寸位图写进内存缓存。
  private func prefetchRequests(for indexPaths: [IndexPath]) -> [ImageRequest] {
    guard !pageKey.isEmpty else { return [] }
    // UIScreen.main 自 iOS 26 起废弃：像素口径取本视图 trait 的 displayScale。
    let scale = max(traitCollection.displayScale, 1)
    var seen = Set<String>()
    var requests: [ImageRequest] = []
    // 目标像素口径与展示侧逐一对齐（feed=fitProcessor，simple/post=resizeProcessor）。
    func append(_ url: URL?, maxPixel: CGFloat, mode: TiebaNuke.Mode) {
      guard let url, maxPixel > 0 else { return }
      let secure = TiebaNuke.secureURL(url)
      let key = "\(secure.absoluteString)#\(maxPixel)#\(mode)"
      guard seen.insert(key).inserted else { return }
      let pixel = CGSize(width: maxPixel, height: maxPixel)
      requests.append(
        ImageRequest(
          url: secure,
          processors: [
            mode == .fit
              ? TiebaNuke.fitProcessor(targetPixelSize: pixel)
              : TiebaNuke.resizeProcessor(targetPixelSize: pixel),
          ]
        )
      )
    }
    for path in indexPaths {
      switch TiebaKindRowPages.shared.kind(pageKey: pageKey, index: path.item) {
      case .feed:
        guard let row = feedModel(at: path.item), !row.isTopBanner else { continue }
        append(row.avatarURL, maxPixel: TiebaFeedRowLayout.avatarSize * scale, mode: .fit)
        if row.showsMedia {
          if row.mediaIsStrip {
            // 带的显示目标 = max(行高, 行高×宽高比)（MultiImageStrip itemWidths）。
            let stripHeight = row.stripHeight ?? 0
            for media in row.media.prefix(TiebaFeedRowLayout.maxImagesPerRow) {
              append(
                media.url,
                maxPixel: max(stripHeight, stripHeight * media.aspectRatio) * scale,
                mode: .fit
              )
            }
          } else {
            let columnWidth = TiebaFeedRowLayout.textColumnWidth(containerWidth: row.containerWidth)
            append(
              row.media.first?.url ?? row.videoPosterURL,
              maxPixel: max(row.singleMediaHeight ?? 0, columnWidth) * scale,
              mode: .fit
            )
          }
        }
        if row.showsForumChip {
          append(
            row.forumAvatarURL,
            maxPixel: TiebaFeedRowLayout.chipAvatarSize * scale,
            mode: .fit
          )
        }
      case .post:
        guard let row = postModel(at: path.item), !row.imagesHidden,
              row.preferences.imageLoadType != "all_no" else { continue }
        append(row.avatarURL, maxPixel: row.plan.avatarFrame.width * scale, mode: .fill)
        guard let imagesFrame = row.plan.imagesFrame else { continue }
        let single = row.images.count == 1
        let shown = row.images.prefix(TiebaPostRowLayout.maxImages)
        for (index, image) in shown.enumerated() {
          guard let url = TiebaPostRowText.displayURL(image, preferences: row.preferences) else {
            continue
          }
          let frame = single || !row.plan.imageItemFrames.indices.contains(index)
            ? imagesFrame
            : row.plan.imageItemFrames[index]
          append(url, maxPixel: max(frame.width, frame.height) * scale, mode: .fill)
        }
      case .simple, .none:
        guard let row = simpleModel(at: path.item) else { continue }
        append(row.avatarURL, maxPixel: row.avatarSize * scale, mode: .fill)
      }
    }
    return requests
  }
}
