// TiebaSimpleRowModel —— 行模型/测量/行视图（从 TiebaSimpleRows 拆出）
//
// 由 TiebaSimpleRows.swift 拆出（单文件 >1000 行 → 拆分，逐字搬运，未改一行逻辑）。
// 拆分纪律见 docs/uikit-migration/35-铁律-自检配方.md §4。

import UIKit
import Nuke
import NukeExtensions

// MARK: - 页面级缓存（本批行专用；与 TiebaRowMetrics 并列）

/// 页索引键 =（pageKey, 容器宽度）：**只剩位置**，每行存的是它的**内容键**。
/// [精简] 原键直接挂 Page(rows:)：位置即内容，整页一被 LRU 挤掉这些行的测量就跟着没了
///（→ 兜底高 / 缺页自愈 / 在显页 pin）。行内容改走 TiebaRowStore（键 = 内容身份 + 量化
/// 宽度，同一行内容跨页命中同一份测量），本索引只给位置查询、行数与顺序用。
/// 宽度仍是键的一部分：多个列表各自的宽度互不清页（与 TiebaRowMetrics 同一纪律）。
public nonisolated final class TiebaSimpleRowMetrics: @unchecked Sendable {
  public static let shared = TiebaSimpleRowMetrics()

  private struct PageKey: Hashable {
    let pageKey: String
    let width: CGFloat
  }

  /// prepareRows 的入参快照盒（字典来自 JS 桥，投递后调用方不再触碰）。
  private struct SendableRows: @unchecked Sendable {
    let rows: [[String: Any]]
  }

  /// 行内容存储：键 =（内容身份, 量化宽度）。
  /// 行预算 512 ≈ 旧整页 LRU(8) × 每页 64 行；本族模型很轻（几个 label），去重后能盖住
  /// 消息/搜索/主页这类长页。
  private let rows = TiebaRowStore<TiebaRowCacheKey, TiebaSimpleRowModel>(maxRows: 512)

  /// 内容键 → **原始行字典**（宽度无关）：与 TiebaRowMetrics.raws 同款，唯一用途是
  /// 「单行同步补测」——内容键含宽度，换宽后旧测量不命中，留着源字典就能当场按新宽度重测，
  /// 而不是让布局拿一个假高度。
  private let raws = TiebaRowStore<TiebaRowDiff.Entry.Identity, [String: Any]>(maxRows: 512)

  /// 页索引缓存（LRU + 在显页跳过）：四族度量缓存共用 TiebaPageStore。
  /// [精简] 预算 8 → 32 页：索引不含几何、很轻，位置查询不该因为别的屏又插了几页就查不到。
  private let pages = TiebaPageStore<PageKey, [TiebaRowCacheKey]>(
    maxPages: 32,
    pinKey: { $0.pageKey }
  )
  private let queue = DispatchQueue(
    label: "com.tiebalite.app.simple-row-metrics",
    qos: .userInitiated
  )

  private init() {
    // 系统内容尺寸档（动态字体）变化 → 已测高度全部失效（UIFontMetrics 随之变）。
    // 行级缓存键只含内容身份 + 宽度、**不含字号档**：不整体作废的话，消息/搜索/浏览历史
    // 这一族会永久停在旧字号旧行高（feed 族同一通知已这么清，见 TiebaRowMetrics.init）。
    NotificationCenter.default.addObserver(
      forName: UIContentSizeCategory.didChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.invalidateAll()
    }
  }

  /// 丢弃全部缓存（字号档变化时用）。行内容存储是**跨页**共享的：只清页索引会留下
  /// 「别的页还在引用」的旧测量（字号变了却复用旧高度）。
  private func invalidateAll() {
    pages.removeAll()
    rows.removeAll()
  }

  /// 0.5pt 量化统一走 TiebaLayout（全仓唯一实现；本入口保留给既有调用方）。
  static func quantize(_ width: CGFloat) -> CGFloat {
    TiebaLayout.quantize(width)
  }

  /// 异步整页测量（非阻塞；本批界面走 prepareRowsBlocking）。
  /// - Parameter identities: 每行的内容身份（与 rows 同序）—— 行级缓存键的一半。
  public func prepareRows(
    pageKey: String,
    rows: [[String: Any]],
    containerWidth: CGFloat,
    identities: [TiebaRowDiff.Entry.Identity]? = nil
  ) {
    guard let width = gate(pageKey: pageKey, containerWidth: containerWidth) else { return }
    let box = SendableRows(rows: rows)
    let ids = identities
    queue.async { [weak self] in
      guard let self else { return }
      let index = self.measureAndIndex(rows: box.rows, width: width, identities: ids)
      self.pages.publish(index, forKey: PageKey(pageKey: pageKey, width: width))
    }
  }

  /// 同步整页测量（JS 的 AsyncFunction 后台队列调用；resolve 返回即可查）。
  public func prepareRowsBlocking(
    pageKey: String,
    rows: [[String: Any]],
    containerWidth: CGFloat,
    identities: [TiebaRowDiff.Entry.Identity]? = nil
  ) {
    guard let width = gate(pageKey: pageKey, containerWidth: containerWidth) else { return }
    // 顺序有讲究：先保证内容在、再发布索引（索引一发布，位置查询就必须取得到内容）。
    let index = measureAndIndex(rows: rows, width: width, identities: identities)
    publish(pageKey: pageKey, width: width, index: index)
  }

  /// 页内**位置**行数（索引在就算，不代表内容还在）。
  public func rowCount(pageKey: String, containerWidth: CGFloat) -> Int {
    let width = TiebaSimpleRowMetrics.quantize(containerWidth)
    return pages.value(forKey: PageKey(pageKey: pageKey, width: width))?.count ?? 0
  }

  /// 本页在本宽度下**真正可渲染**的行数（索引在、内容也在）。
  /// [精简] 行级缓存的淘汰粒度是行，「整页行数」给不出这个信息（liveRowCount 用它）。
  public func presentRowCount(pageKey: String, containerWidth: CGFloat) -> Int {
    let width = TiebaSimpleRowMetrics.quantize(containerWidth)
    guard let index = pages.value(forKey: PageKey(pageKey: pageKey, width: width)) else { return 0 }
    var present = 0
    for key in index where rows.contains(key) { present += 1 }
    return present
  }

  public func rowHeight(pageKey: String, containerWidth: CGFloat, index: Int) -> CGFloat? {
    row(pageKey: pageKey, containerWidth: containerWidth, index: index)?.measuredHeight
  }

  /// 取行模型（位置 → 内容键 → 行内容存储）。
  public func row(pageKey: String, containerWidth: CGFloat, index: Int) -> TiebaSimpleRowModel? {
    let width = TiebaSimpleRowMetrics.quantize(containerWidth)
    guard let keys = pages.value(forKey: PageKey(pageKey: pageKey, width: width)),
          index >= 0, index < keys.count else { return nil }
    return rows.value(forKey: keys[index])
  }

  /// **内容键查询**（列表侧用：TiebaKindItem.identity 就是它）：与 pageKey、与页索引的
  /// 整页淘汰都无关 —— 同一行内容在任何页里都命中同一份测量。
  public func row(
    identity: TiebaRowDiff.Entry.Identity,
    containerWidth: CGFloat
  ) -> TiebaSimpleRowModel? {
    let width = TiebaSimpleRowMetrics.quantize(containerWidth)
    return rows.value(forKey: TiebaRowCacheKey(identity: identity, width: width))
  }

  // MARK: - 内部

  private func gate(pageKey: String, containerWidth: CGFloat) -> CGFloat? {
    guard !pageKey.isEmpty, containerWidth > 0 else { return nil }
    return TiebaSimpleRowMetrics.quantize(containerWidth)
  }

  /// 整页测量 + **写内容缓存**，返回页索引（位置 → 内容键）。
  /// [精简] 原 measureRows 无条件逐行重建模型（本族原本没有页内复用），重推即整页重测；
  /// 现在复用判据 = 内容键命中（TiebaRowStore.resolve），跨页/跨屏都命中。
  private func measureAndIndex(
    rows raws: [[String: Any]],
    width: CGFloat,
    identities: [TiebaRowDiff.Entry.Identity]?
  ) -> [TiebaRowCacheKey] {
    let ids = (identities?.count == raws.count ? identities : nil)
      ?? TiebaRowDiff.entries(for: raws).map(\.identity)
    let keys = ids.map { TiebaRowCacheKey(identity: $0, width: width) }
    // 源字典与模型一起留一份（宽度无关的键）：换宽度时才有东西可重测。
    for (offset, identity) in ids.enumerated() where offset < raws.count {
      self.raws.insert(raws[offset], forKey: identity)
    }
    _ = self.rows.resolve(Array(raws.enumerated()), keys: keys) { pair in
      TiebaSimpleRowModel(pageKey: "", index: pair.offset, raw: pair.element, containerWidth: width)
    }
    return keys
  }

  /// **单行同步补测**（与 TiebaRowMetrics.ensureFeedRow 同款）：用内容键对应的原始行字典
  /// 在当前宽度重测一次并写回内容键存储。
  /// - Returns: nil = 源行字典也不在了（这一行确实没数据），调用方应重推而不是编高度。
  public func ensureRow(
    identity: TiebaRowDiff.Entry.Identity,
    pageKey: String,
    index: Int,
    containerWidth: CGFloat
  ) -> TiebaSimpleRowModel? {
    // 判定与写回顺序与 feed 族共用 TiebaRowSyncRemeasure（见该类型的注释）。
    TiebaRowSyncRemeasure.ensure(
      identity: identity, pageKey: pageKey, index: index, containerWidth: containerWidth,
      rows: rows, raws: raws
    ) { raw, pageKey, index, width in
      TiebaSimpleRowModel(pageKey: pageKey, index: index, raw: raw, containerWidth: width)
    }
  }

  private func publish(pageKey: String, width: CGFloat, index: [TiebaRowCacheKey]) {
    pages.publish(index, forKey: PageKey(pageKey: pageKey, width: width))
  }
}

// MARK: - 行视图

/// 通用行视图：四变体共用一组子视图，按模型显示/摆放（绘制期零测量）。
/// 交互：整行点击由列表 cell 上报（本批界面没有行内按钮/长按菜单，所以本视图
/// 不挂任何手势）；无障碍整行一个 element（label 由 JS 下发）。
public final class TiebaSimpleRowView: UIView {
  // MARK: 接口

  /// 主题色板（列表下发；只影响绘制，不触发重测）。
  public var palette: TiebaSimpleRowPalette = .default {
    didSet {
      guard palette != oldValue else { return }
      applyPalette()
    }
  }

  private var model: TiebaSimpleRowModel?

  /// 作者点击命中区（迁移前的行内子交互）：user/message 变体的头像框 + 昵称框。
  /// message 行的两者在 RN 里都包在 AvatarPressable 里（MessageRow.tsx
  /// messageAvatarPressable / messageNamePressable），点它们进作者主页、点其余
  /// 部分进帖子——命中区在 layoutSubviews 里落，列表按点判定后发对应 region。
  private var authorHitFrames: [CGRect] = []

  /// 命中区域判定（point = 行视图坐标；列表侧 cell 传入）。
  /// 返回 "avatar"（作者点击区）或 "card"（整卡）。
  public func hitRegion(atPoint point: CGPoint) -> String {
    for frame in authorHitFrames where frame.contains(point) {
      return "avatar"
    }
    return "card"
  }

  /// 赋值（列表侧已按宽度查好模型）：复位 → 配置 → 重排。
  public func apply(model: TiebaSimpleRowModel?) {
    self.model = model
    resetContent()
    guard let model else {
      isAccessibilityElement = false
      return
    }
    isAccessibilityElement = true
    accessibilityLabel = model.accessibilityLabel
    // 只有 user/message 行可点（头像/整卡）；section/summary 无点击行为，
    // 标 .button 会让 VoiceOver 误报"按钮"。
    switch model.variant {
    case .user, .message:
      accessibilityTraits = .button
    case .section, .summary:
      accessibilityTraits = []
    }
    configure(with: model)
    setNeedsLayout()
  }

  /// 复用前复位（取消在途图片请求、清文本、藏全部子视图、归位动画）。
  public func prepareForReuse() {
    model = nil
    resetContent()
  }

  /// 首屏入场：参数与其余三族共用 TiebaEntrance。
  public func playEntranceAnimation(index: Int) {
    TiebaEntrance.play(on: self, index: index)
  }

  // MARK: 子视图

  private let cardView = UIView()
  private let avatarView = UIImageView()
  private let avatarInitialLabel = UILabel()
  private let titleLabel = UILabel()
  private let subtitleLabel = UILabel()
  private let threadLabel = UILabel()
  private let timeLabel = UILabel()
  private let badgeView = UIView()
  private let badgeLabel = UILabel()
  private let chevronView = UIImageView()
  private let unreadDotView = UIView()
  private let typeIconView = UIImageView()
  private let sectionDotView = UIView()
  private let countChipView = UIView()
  private let countChipLabel = UILabel()
  private let iconBoxView = UIView()
  private let iconView = UIImageView()

  public override init(frame: CGRect) {
    super.init(frame: frame)
    isOpaque = false
    backgroundColor = .clear
    isAccessibilityElement = true

    cardView.isUserInteractionEnabled = false
    // cardView 只当卡片底（底色/圆角/描边）：内容一律挂行视图、按行坐标摆放
    //（四个 layout* 的算式都是行坐标）。挂进 cardView 会再叠一层卡片原点，
    // marginH/marginV ≠ 0 的行（搜索吧卡 10/6、分组标题 28/0）就卡片内留白、不居中。
    addSubview(cardView)

    avatarView.clipsToBounds = true
    avatarView.contentMode = .scaleAspectFill
    addSubview(avatarView)
    avatarInitialLabel.textAlignment = .center
    avatarInitialLabel.numberOfLines = 1
    avatarInitialLabel.isHidden = true
    avatarInitialLabel.clipsToBounds = true
    avatarView.addSubview(avatarInitialLabel)

    for label in [titleLabel, subtitleLabel, threadLabel, timeLabel, badgeLabel, countChipLabel] {
      label.numberOfLines = 1
      label.isHidden = true
      label.lineBreakMode = .byTruncatingTail
    }
    addSubview(titleLabel)
    addSubview(subtitleLabel)
    addSubview(threadLabel)
    addSubview(timeLabel)

    badgeView.isHidden = true
    badgeView.clipsToBounds = true
    addSubview(badgeView)
    badgeView.addSubview(badgeLabel)

    chevronView.contentMode = .scaleAspectFit
    chevronView.isHidden = true
    addSubview(chevronView)

    unreadDotView.isHidden = true
    addSubview(unreadDotView)

    typeIconView.contentMode = .scaleAspectFit
    typeIconView.isHidden = true
    addSubview(typeIconView)

    sectionDotView.isHidden = true
    addSubview(sectionDotView)

    countChipView.isHidden = true
    countChipView.clipsToBounds = true
    addSubview(countChipView)
    countChipLabel.isHidden = true
    countChipView.addSubview(countChipLabel)

    iconBoxView.isHidden = true
    iconBoxView.clipsToBounds = true
    addSubview(iconBoxView)
    iconView.contentMode = .scaleAspectFit
    iconBoxView.addSubview(iconView)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  // MARK: 复位与配色

  private func resetContent() {
    cancelRequest(for: avatarView)
    avatarView.image = nil
    avatarInitialLabel.text = nil
    avatarInitialLabel.isHidden = true
    for label in [titleLabel, subtitleLabel, threadLabel, timeLabel, badgeLabel, countChipLabel] {
      label.attributedText = nil
      label.isHidden = true
    }
    for view in [badgeView, chevronView, unreadDotView, typeIconView, sectionDotView,
                 countChipView, iconBoxView] {
      view.isHidden = true
    }
    chevronView.image = nil
    typeIconView.image = nil
    iconView.image = nil
    layer.removeAllAnimations()
    alpha = 1
    transform = .identity
  }

  /// 色板应用：先落各视图底色/描边，再按色板重贴已配置文本的颜色。
  /// ⚠️ attributed 串里没有颜色属性，颜色在 setText 里按 label.textColor 补——
  /// 所以换主题 = 改 textColor + 重贴一次（不重测、不重建串）。
  private func applyPalette() {
    guard let model else { return }
    cardView.backgroundColor = model.backgroundColor ?? .clear
    cardView.layer.cornerRadius = model.cornerRadius
    cardView.layer.cornerCurve = .continuous
    if let borderColor = model.borderColor, model.borderWidth > 0 {
      cardView.layer.borderWidth = model.borderWidth
      cardView.layer.borderColor = borderColor.cgColor
    } else {
      cardView.layer.borderWidth = 0
    }
    badgeView.backgroundColor = model.badgeBackgroundColor ?? palette.base.chip
    countChipView.backgroundColor = model.countChipBackgroundColor ?? palette.surfaceSecondary
    unreadDotView.backgroundColor = model.unreadDotColor ?? palette.base.primary
    sectionDotView.backgroundColor = model.sectionDotColor ?? palette.base.primary
    iconBoxView.backgroundColor = model.iconBoxColor ?? palette.groupFill
    iconView.tintColor = model.iconColor ?? palette.base.primary
    typeIconView.tintColor = model.typeIconColor ?? palette.base.primary
    chevronView.tintColor = model.chevronColor ?? palette.base.textTertiary
    avatarView.backgroundColor = palette.base.avatarFallback
    avatarInitialLabel.textColor = palette.textOnPrimary
    titleLabel.textColor = palette.base.text
    subtitleLabel.textColor = model.variant == .message
      ? palette.base.textSecondary
      : palette.base.textTertiary
    threadLabel.textColor = palette.base.textTertiary
    timeLabel.textColor = palette.textDisabled
    badgeLabel.textColor = model.badgeTextColor ?? palette.base.primary
    countChipLabel.textColor = model.countChipTextColor ?? palette.base.textTertiary
    refreshTextColors()
  }

  // MARK: 配置

  private func configure(with model: TiebaSimpleRowModel) {
    // 色板必须先落（label.textColor 是 setText 的取色来源）。
    applyPalette()
    switch model.variant {
    case .user:
      configureAvatar(model)
      if model.badgeBlock != nil {
        badgeView.isHidden = false
      }
      if model.showsChevron {
        chevronView.image = TiebaSymbols.image(
          "chevron.right",
          pointSize: max(model.chevronSize, 1),
          weight: symbolWeight(model.chevronWeight)
        )
        chevronView.isHidden = false
      }
    case .message:
      configureAvatar(model)
      if let name = model.typeIconName {
        typeIconView.image = TiebaSymbols.image(name, pointSize: max(model.typeIconSize, 1), weight: .semibold)
        typeIconView.isHidden = false
      }
      unreadDotView.isHidden = !model.isUnread
    case .section:
      countChipView.isHidden = model.countChipBlock == nil
      sectionDotView.isHidden = false
    case .summary:
      if let name = model.iconName {
        iconView.image = TiebaSymbols.image(name, pointSize: max(model.iconSize, 1), weight: .regular)
      }
      iconBoxView.isHidden = false
    }
    setNeedsLayout()
  }

  /// 按当前模型贴全部文本（configure 与换主题都走这里；幂等）。
  private func refreshTextColors() {
    guard let model else { return }
    // [N4] subtitleLabel 的行数上限随变体复位：message 的正文按 contentBlock 测出的行数（生产方 2 行）绘制，
    // 其余变体的 subtitle 仍是单行 —— 两者必须与测量同源，否则绘制多一行/少一行都会让行高与内容脱节。
    subtitleLabel.numberOfLines = 1
    switch model.variant {
    case .user:
      setText(titleLabel, model.titleBlock)
      setText(subtitleLabel, model.subtitleBlock)
      setText(badgeLabel, model.badgeBlock)
    case .message:
      setText(titleLabel, model.titleBlock)
      subtitleLabel.numberOfLines = model.contentBlock?.lines ?? 1
      setText(subtitleLabel, model.contentBlock)
      setText(threadLabel, model.threadBlock)
      setText(timeLabel, model.timeBlock)
    case .section:
      setText(titleLabel, model.titleBlock)
      setText(countChipLabel, model.countChipBlock)
    case .summary:
      setText(titleLabel, model.titleBlock)
      setText(subtitleLabel, model.subtitleBlock)
    }
  }

  private func configureAvatar(_ model: TiebaSimpleRowModel) {
    if let url = model.avatarURL {
      let pixel = model.avatarSize * max(traitCollection.displayScale, 1)
      loadImage(
        with: TiebaNuke.secureURL(url),
        options: TiebaNuke.options(maxPixel: pixel, mode: .fill),
        into: avatarView
      )
    } else if !model.avatarInitial.isEmpty {
      avatarInitialLabel.isHidden = false
      avatarInitialLabel.text = String(model.avatarInitial.prefix(2)).uppercased()
      avatarInitialLabel.font = .systemFont(
        ofSize: max(round(model.avatarSize * 0.38), 1),
        weight: .semibold
      )
      avatarInitialLabel.textColor = palette.textOnPrimary
    }
    avatarView.isHidden = false
  }

  /// 贴文本（attributed 串只有 font/paragraph，颜色在这里按色板补）。
  private func setText(_ label: UILabel, _ block: TiebaSimpleTextBlock?) {
    guard let block else {
      label.attributedText = nil
      label.isHidden = true
      return
    }
    let mutable = NSMutableAttributedString(attributedString: block.attributed)
    mutable.addAttribute(
      .foregroundColor,
      value: label.textColor ?? palette.base.text,
      range: NSRange(location: 0, length: mutable.length)
    )
    label.attributedText = mutable
    label.isHidden = false
  }

  private func symbolWeight(_ weight: UIFont.Weight) -> UIImage.SymbolWeight {
    switch weight {
    case .ultraLight: return .ultraLight
    case .thin: return .thin
    case .light: return .light
    case .medium: return .medium
    case .semibold: return .semibold
    case .bold: return .bold
    case .heavy: return .heavy
    case .black: return .black
    default: return .regular
    }
  }

  // MARK: 布局（纯算术；与测量式一一对应）

  public override func layoutSubviews() {
    super.layoutSubviews()
    guard let model else { return }
    cardView.frame = model.cardFrame
    // 作者点击命中区每轮重算（其余变体无行内子交互 → 空）。
    authorHitFrames = []
    switch model.variant {
    case .user: layoutUser(model)
    case .message: layoutMessage(model)
    case .section: layoutSection(model)
    case .summary: layoutSummary(model)
    }
  }

  private func layoutUser(_ model: TiebaSimpleRowModel) {
    let content = model.contentFrame
    let avatar = model.avatarSize
    let avatarFrame = CGRect(
      x: content.minX,
      y: content.midY - avatar / 2,
      width: avatar,
      height: avatar
    )
    avatarView.frame = avatarFrame
    avatarView.layer.cornerRadius = avatar / 2
    avatarInitialLabel.frame = avatarView.bounds
    avatarInitialLabel.layer.cornerRadius = avatar / 2

    var textRight = content.maxX
    if model.showsChevron {
      let size = model.chevronSize
      chevronView.frame = CGRect(
        x: content.maxX - size,
        y: content.midY - size / 2,
        width: size,
        height: size
      )
      textRight = content.maxX - size - model.gap
    }
    let textX = avatarFrame.maxX + model.gap
    let textWidth = max(textRight - textX, 0)
    let titleHeight = model.titleBlock?.height ?? 0
    let subtitleHeight = model.subtitleBlock.map { model.subtitleMarginTop + $0.height } ?? 0
    var y = content.midY - (titleHeight + subtitleHeight) / 2
    // 等级徽章内联在标题右侧（bawu userNameRow：Text + 6pt gap + 徽章）。
    var badgeWidth: CGFloat = 0
    if let badge = model.badgeBlock {
      badgeWidth = TiebaSimpleText.singleLineWidth(badge.text, font: badge.font)
        + model.badgePaddingH * 2
    }
    if let title = model.titleBlock {
      let titleWidth = max(textWidth - (badgeWidth > 0 ? badgeWidth + model.badgeSpacing : 0), 0)
      titleLabel.frame = CGRect(x: textX, y: y, width: titleWidth, height: title.height)
      if let badge = model.badgeBlock, badgeWidth > 0 {
        let badgeHeight = badge.height + model.badgePaddingV * 2
        badgeView.frame = CGRect(
          x: textX + titleWidth + model.badgeSpacing,
          y: y + (title.height - badgeHeight) / 2,
          width: badgeWidth,
          height: badgeHeight
        )
        badgeView.layer.cornerRadius = model.badgeRadius
        badgeView.layer.cornerCurve = .continuous
        badgeLabel.frame = badgeView.bounds
      }
      y = titleLabel.frame.maxY
    }
    if let subtitle = model.subtitleBlock {
      subtitleLabel.frame = CGRect(
        x: textX,
        y: y + model.subtitleMarginTop,
        width: textWidth,
        height: subtitle.height
      )
    }
  }

  private func layoutMessage(_ model: TiebaSimpleRowModel) {
    let card = model.cardFrame
    let content = model.contentFrame
    let avatar = model.avatarSize
    avatarView.frame = CGRect(x: content.minX, y: content.minY, width: avatar, height: avatar)
    avatarView.layer.cornerRadius = avatar / 2
    avatarInitialLabel.frame = avatarView.bounds
    avatarInitialLabel.layer.cornerRadius = avatar / 2

    // 未读红点：行内边距 12 + 头像 40 → 头像右缘 x=52，圆点 8×8 骑右上角
    // （MessageRow.tsx unreadDot top 8 / left 48）。
    let dotSide: CGFloat = 8
    unreadDotView.frame = CGRect(
      x: card.minX + model.paddingH + avatar - 4,
      y: card.minY + 8,
      width: dotSide,
      height: dotSide
    )
    unreadDotView.layer.cornerRadius = dotSide / 2

    let bodyX = avatarView.frame.maxX + model.gap
    let bodyWidth = max(content.maxX - bodyX, 0)
    var y = content.minY
    if let title = model.titleBlock {
      var nameWidth = bodyWidth
      if model.typeIconName != nil {
        let iconSize = model.typeIconSize
        typeIconView.frame = CGRect(
          x: content.maxX - iconSize,
          y: y + (title.height - iconSize) / 2,
          width: iconSize,
          height: iconSize
        )
        nameWidth = max(bodyWidth - iconSize - model.headerGap, 0)
      }
      titleLabel.frame = CGRect(x: bodyX, y: y, width: nameWidth, height: title.height)
      y = titleLabel.frame.maxY
    }
    if let contentBlock = model.contentBlock {
      y += model.bodyGap
      subtitleLabel.frame = CGRect(x: bodyX, y: y, width: bodyWidth, height: contentBlock.height)
      y = subtitleLabel.frame.maxY
    }
    if let thread = model.threadBlock {
      y += model.bodyGap
      threadLabel.frame = CGRect(x: bodyX, y: y, width: bodyWidth, height: thread.height)
      y = threadLabel.frame.maxY
    }
    if let time = model.timeBlock {
      y += model.bodyGap
      timeLabel.frame = CGRect(x: bodyX, y: y, width: bodyWidth, height: time.height)
    }
    // 作者点击区 = 头像 + 昵称（MessageRow.tsx 的 messageAvatarPressable /
    // messageNamePressable 两个 Pressable 的并集；点其余部分进帖子）。
    authorHitFrames = [avatarView.frame, titleLabel.frame]
  }

  private func layoutSection(_ model: TiebaSimpleRowModel) {
    let contentX = model.marginH
    let contentWidth = max(model.containerWidth - model.marginH * 2, 0)
    let lineHeight = max(
      model.titleBlock?.height ?? 0,
      model.sectionDotSize.height,
      model.countChipBlock.map { $0.height + model.countChipPaddingV * 2 } ?? 0
    )
    let dotX = contentX
    let dotY = model.topSpacing + (lineHeight - model.sectionDotSize.height) / 2
    sectionDotView.frame = CGRect(
      x: dotX,
      y: dotY,
      width: model.sectionDotSize.width,
      height: model.sectionDotSize.height
    )
    sectionDotView.layer.cornerRadius = model.sectionDotSize.width / 2

    var chipWidth: CGFloat = 0
    if let chip = model.countChipBlock {
      chipWidth = TiebaSimpleText.singleLineWidth(chip.text, font: chip.font)
        + model.countChipPaddingH * 2
      let chipHeight = chip.height + model.countChipPaddingV * 2
      countChipView.frame = CGRect(
        x: contentX + contentWidth - chipWidth,
        y: model.topSpacing + (lineHeight - chipHeight) / 2,
        width: chipWidth,
        height: chipHeight
      )
      countChipView.layer.cornerRadius = model.countChipRadius
      countChipView.layer.cornerCurve = .continuous
      countChipLabel.frame = countChipView.bounds
    }
    if let title = model.titleBlock {
      let titleX = dotX + model.sectionDotSize.width + model.sectionDotSpacing
      let titleWidth = max(
        contentX + contentWidth - titleX - (chipWidth > 0 ? chipWidth + 8 : 0),
        0
      )
      titleLabel.frame = CGRect(
        x: titleX,
        y: model.topSpacing + (lineHeight - title.height) / 2,
        width: titleWidth,
        height: title.height
      )
    }
  }

  private func layoutSummary(_ model: TiebaSimpleRowModel) {
    let content = model.contentFrame
    let box = model.iconBoxSize
    let boxFrame = CGRect(
      x: content.minX,
      y: content.midY - box / 2,
      width: box,
      height: box
    )
    iconBoxView.frame = boxFrame
    iconBoxView.layer.cornerRadius = model.iconBoxRadius
    iconBoxView.layer.cornerCurve = .continuous
    let iconSide = max(model.iconSize, 1)
    iconView.frame = CGRect(
      x: (box - iconSide) / 2,
      y: (box - iconSide) / 2,
      width: iconSide,
      height: iconSide
    )

    let textX = boxFrame.maxX + model.gap
    let textWidth = max(content.maxX - textX, 0)
    let titleHeight = model.titleBlock?.height ?? 0
    let subtitleHeight = model.subtitleBlock.map { model.subtitleMarginTop + $0.height } ?? 0
    var y = content.midY - (titleHeight + subtitleHeight) / 2
    if let title = model.titleBlock {
      titleLabel.frame = CGRect(x: textX, y: y, width: textWidth, height: title.height)
      y = titleLabel.frame.maxY
    }
    if let subtitle = model.subtitleBlock {
      subtitleLabel.frame = CGRect(
        x: textX,
        y: y + model.subtitleMarginTop,
        width: textWidth,
        height: subtitle.height
      )
    }
  }
}
