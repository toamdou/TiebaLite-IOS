// 从 TiebaKindListView.swift 拆出（H10 千行文件拆分）：主类之前的独立类型（整类型逐字搬运，仅下列声明放宽访问级）。
// 主类留在原文件：它的扩展要用到类内 private，同文件才合法。

import UIKit
import Nuke

// MARK: - 行标识

/// 行标识 =（页键, **行内容身份**）。
///
/// [采用] 身份从"位置"改为"内容"：`identity` = `TiebaRowDiff.Entry.Identity`（内容指纹 +
/// 同指纹出现序号），**页码 `index` 不参与 Hashable**。
///
/// 为什么这是关键：旧标识是 `(pageKey, index)` —— 内容变了标识不变 ⇒ diffable 认为
/// "什么都没变"，只能靠 `reconfigureSamePageItems()` 把**可见行全部重配**兜底；
/// 而换页键时会走 `applySnapshotUsingReloadData` 整页重载。
/// 改成内容身份后：
///   · 内容变了的行 → 旧身份消失、新身份出现 → diffable 自己算出"删一行 + 插一行"，
///     **只重建真正变了的那几行**，不再需要全量 reconfigure；
///   · 整页平移 / 前插不会让所有行标识全变（序号是"第几个同内容行"，与位置无关）
///     ⇒ 不会误触发整页重载。
struct TiebaKindItem: Hashable, Sendable {
  let pageKey: String
  /// 内容身份（指纹 + 同指纹序号），与位置无关。
  let identity: TiebaRowDiff.Entry.Identity
  /// 页内下标：**仅供 cell 取模型用**，不参与身份比较。
  let index: Int

  static func == (lhs: TiebaKindItem, rhs: TiebaKindItem) -> Bool {
    lhs.pageKey == rhs.pageKey && lhs.identity == rhs.identity
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(pageKey)
    hasher.combine(identity)
  }
}

// MARK: - 列表事件（原生语义出口）

/// 列表外传事件（替代旧的 (name, payload) 字符串事件；页面用 switch 模式匹配消费）。
/// headerAction 的 action 是各页头自己的类型化 enum（TiebaKindListHeaderAction）；
/// payload 只承载视图测量几何（avatar 的 frameX/Y/W/H），见 TiebaKindListHeaderView。
enum TiebaKindListEvent {
  case rowTap(index: Int, region: String, actionIndex: Int?)
  case swipeAction(index: Int, action: String)
  case menuAction(index: Int, action: String)
  case mediaAction(index: Int, mediaIndex: Int, action: String, url: String?, originURL: String?)
  case headerAction(action: TiebaKindListHeaderAction, payload: [String: Any])
  case footerTap
  case refreshRequested
  case reachEnd(count: Int)
  case visibleRangeChange(start: Int, end: Int, count: Int)
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
/// 单一来源）。行内自管交互（右上角「更多」的 ActionSheet / 图片长按菜单 / 操作栏
/// 按压反馈）由行视图自己处理；整卡点击装在 cell 上，命中区域由列表按行模型
/// layoutPlan 判定。
final class TiebaKindListFeedCell: UICollectionViewCell {
  /// 行内容视图（行视图自身不读宿主上下文，可独立实例化）。
  private let rowView = TiebaFeedRowView(frame: .zero)

  /// 点击回调：参数是点击点在 cell（= 行视图）坐标系的坐标。
  var onTap: ((CGPoint) -> Void)?
  /// 行右上角「更多」菜单选中项（dislike / block / copy-title）。
  var onRowMenuAction: ((String) -> Void)?
  /// 行内图片长按菜单选中项（媒体序号, save-image / share-image）。
  var onMediaMenuAction: ((Int, String) -> Void)?
  /// 行内图片长按「点预览进大图」请求（媒体序号）：列表侧现算该格窗口矩形
  /// 后复用点图入口（presentPhotoBrowser）。
  var onMediaOpen: ((Int) -> Void)?

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
    rowView.onMediaOpen = onMediaOpen
    rowView.apply(pageKey: pageKey, index: index)
  }

  func applyPalette(_ palette: TiebaFeedRowPalette) {
    rowView.palette = palette
  }

  /// 首图已解好的位图（列表→详情快照用，见 TiebaFeedRowView.loadedThumbnailImage）。
  var loadedThumbnailImage: UIImage? { rowView.loadedThumbnailImage }

  func playEntrance(index: Int) {
    rowView.playEntranceAnimation(index: index)
  }

  /// 不感兴趣折叠退场（280ms opacity + scaleY，见 TiebaFeedRowView）。
  /// completion 在动画结束（或动画被复位移除）时回调，列表据此删数据。
  func playCollapse(completion: (() -> Void)? = nil) {
    rowView.playCollapseAnimation(completion: completion)
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

  /// 转场源图：该格已加载的压缩图（权威源，见 TiebaPhotoBrowser.present）。
  func mediaImage(atMediaIndex index: Int) -> UIImage? {
    rowView.mediaImage(at: index)
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
  /// 本 cell 当前承载的行下标：翻页时列表按它定位主贴行，只刷工具栏（不重配整行）。
  private(set) var rowIndex: Int?

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
    rowIndex = index
    rowView.apply(pageKey: pageKey, index: index)
  }

  /// 只刷新工具栏（翻页页码变化；行下标不变、正文不重排）。
  func refreshToolbar() {
    rowView.refreshToolbar()
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

// MARK: - 页脚（加载中动画 / 状态文案 / 失败重试；正常态不显示按钮）

/// 页脚状态。
///
/// [用户口径 2026-10-06] 底部**不再有**药丸型「加载更多」按钮：那条路径本来就是
/// `loadMore()` 的第二个入口（10 个页面的 `onListEvent` 里 `.reachEnd` 与 `.footerTap`
/// 走的是同一个分支），而触底自动加载由 `updateReachEnd()` 覆盖（含"内容不足一屏"）。
/// 于是 `more` = 什么都不显示（见 TiebaKindFooterView.height）；**只把"上一次翻页失败"
/// 单独保留成可点重试**（`retry`）—— 否则失败后停在这一屏，用户没有任何入口再试一次。
public enum TiebaKindFooterState: String {
  /// 还有更多内容：不显示任何东西（触底自动加载）。
  case more
  case loading
  case none
  /// 一条回复都没有（主贴仍钉在首行的页面用：不能走整页空态，否则主贴也不见）。
  case empty
  case hidden
  /// 上一次翻页失败（网络/服务端错误）：唯一保留药丸按钮的态。
  case retry
}

// 访问级 private → internal（H10 拆分，Lead 裁决 B）：final 被留在 TiebaKindListView.swift 的主类 TiebaKindListContentView 引用，
// 拆分后跨文件 private 不可见；只放宽这一处，其余成员访问级不动。
final class TiebaKindFooterView: UICollectionReusableView {
  static let reuseIdentifier = "TiebaKindFooterView"
  static let elementKind = UICollectionView.elementKindSectionFooter

  private let spinner = UIActivityIndicatorView(style: .medium)
  private let label = UILabel()
  private let button = UIButton(type: .system)
  private let contentStack = UIStackView()
  private var onTap: (() -> Void)?

  /// 页脚文案唯一字阶：四态同档，翻页切换时字号不跳（D3-4：原先 loading/more 走
  /// footnote 13 semibold、none/empty 走 caption1 12 medium，同级状态两套字阶肉眼可见）。
  private static var textFont: UIFont {
    UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .systemFont(ofSize: 13, weight: .semibold))
  }

  /// 行高与字号同源，避免两处各写一个数后再次分叉。
  private static var textLineHeight: CGFloat {
    UIFontMetrics(forTextStyle: .footnote).scaledValue(for: 18)
  }

  /// 页脚高度：paddingVertical 20×2 + 内容高（spinner 20 / 文案行高 / retry 再加
  /// 按钮 marginVertical 4×2）。
  static func height(for state: TiebaKindFooterState) -> CGFloat {
    let base: CGFloat = 40
    switch state {
    case .loading:
      return base + max(20, Self.textLineHeight)
    case .none, .empty:
      return base + Self.textLineHeight
    case .retry:
      return base + Self.textLineHeight + 8
    case .more, .hidden:
      // [用户口径 2026-10-06] "还有更多"不再有可点药丸：页脚整块收起（0 高 = 布局里
      // 连 supplementary 都不生成，见 TiebaRowListLayout 的 `footerHeight > 0` 判据），
      // 底部内容直接贴住最后一行；加载动画（.loading）与文案态（.none/.empty）不受影响。
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
    // 药丸按钮只在“失败重试”这一态出现（用户口径：正常态不显示「加载更多」）。
    label.isHidden = state == .more || state == .retry
    button.isHidden = state != .retry
    switch state {
    case .loading:
      spinner.startAnimating()
      label.attributedText = NSAttributedString(
        string: "加载中...",
        attributes: [.font: Self.textFont, .foregroundColor: textColor]
      )
    case .empty:
      spinner.stopAnimating()
      label.attributedText = NSAttributedString(
        string: "还没有人回复这个帖子",
        attributes: [.font: Self.textFont, .foregroundColor: textColor]
      )
    case .none:
      spinner.stopAnimating()
      label.attributedText = NSAttributedString(
        string: "没有更多了",
        attributes: [.font: Self.textFont, .foregroundColor: textColor]
      )
    case .more:
      // 正常态：页脚是 0 高、什么都不画（触底自动加载接管，见 TiebaKindFooterState 的注释）。
      spinner.stopAnimating()
      label.attributedText = nil
      button.configuration = nil
    case .retry:
      spinner.stopAnimating()
      label.attributedText = nil
      button.configuration = TiebaKindFooterView.retryConfiguration(palette: palette)
    case .hidden:
      spinner.stopAnimating()
      label.attributedText = nil
      button.configuration = nil
    }
  }

  /// 「重试」按钮：系统液态玻璃配置（UIButtonConfiguration.glassButtonConfiguration，
  /// iOS 26 起可用；部署目标 26 = 恒走此支）。样式与原来那颗「加载更多」药丸逐值一致
  /// （圆角胶囊 / 13pt semibold / 文字宽 + 56），只有文案与**出现时机**变了：
  /// 只在翻页失败（.retry）时出现，正常态一律不显示。
  private static func retryConfiguration(palette: TiebaSimpleRowPalette) -> UIButton.Configuration {
    // 降级：.glass() 是 iOS 26 起；17 退回经典 gray（胶囊/字号/色/内边距逐值不变）。
    var config: UIButton.Configuration =
      if #available(iOS 26.0, *) { .glass() } else { .gray() }
    config.cornerStyle = .capsule
    config.baseForegroundColor = palette.base.primary
    config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
      var outgoing = incoming
      outgoing.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(
        for: .systemFont(ofSize: 13, weight: .semibold)
      )
      return outgoing
    }
    config.title = "加载失败，点击重试"
    // 原按钮宽 = 文字宽 + 56、高 = 文字高（footer height 预算里的 marginVertical 4）。
    config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 28, bottom: 4, trailing: 28)
    return config
  }

  @objc private func handleButtonTap() {
    onTap?()
  }
}


