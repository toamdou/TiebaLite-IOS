// ============================================================
// TiebaLite — 通用列表的滚动头槽位（TiebaKindListHeader）
//
// 页头 = 原生 UIView，挂在 section 的 top boundary supplementary item 上（与页脚
// 同一机制）。契约：headerHeight(forWidth:) 是"测多少画多少"的唯一来源（宽度 =
// 列表全宽；不含 contentInsetTop，由列表另加在 host 里）；spec.colors 覆盖色板默认，
// 页头内点击经 onAction 外传 → headerAction 事件。
// ============================================================

import UIKit
import Nuke
import NukeExtensions

// MARK: - 页头协议（列表只依赖这三个面）

/// 页头视图契约：列表不认识具体页头（话题页头 / 以后的分组页头），只认识
/// "能自适应高度 + 能应用主题 + 能把点击外传"这三件事。
@MainActor
public protocol TiebaKindListHeaderView: UIView {
  /// 页头内交互外传（name + payload；当前只有 "forum"）。
  var onAction: ((String, [String: Any]) -> Void)? { get set }
  /// 主题色板（缺省值来源；spec 的 colors 子字典优先）。
  func applyPalette(_ palette: TiebaSimpleRowPalette)
  /// 指定宽度下的内容高度（纯算术 + 缓存测量；不触发布局）。
  func headerHeight(forWidth width: CGFloat) -> CGFloat
}

// MARK: - 工厂

/// `header` prop 的 spec 字典 → 页头视图。spec["kind"] 决定形状：
///   · "topic" —— 话题页头（#话题# + 讨论数 + 简介 + 相关吧胶囊）
///   · "topicCentered" —— 话题数据缺失时的精简页头（居中标题）
///   · "forum" —— 吧页滚动头（吧名片 + 分段 + 排序/分类行）
/// 未知 kind → nil（= 无页头；调用方 JS 侧类型已把它限死在联合类型里）。
@MainActor
public enum TiebaKindListHeaderFactory {
  public static func make(spec: [String: Any]) -> TiebaKindListHeaderView? {
    switch TiebaSimpleRowParser.string(spec["kind"]) {
    case "topic", "topicCentered":
      return TiebaTopicHeaderView(spec: spec)
    case "forum":
      return TiebaForumHeaderView(spec: spec)
    case "userProfile":
      return TiebaUserProfileHeaderView(spec: spec)
    default:
      return nil
    }
  }
}

// MARK: - 页头宿主（集合视图补充视图）

/// boundary supplementary item 的宿主：只做"把页头摆在 topPadding 之下、铺满
/// 剩余高度"这一件事（topPadding = 列表的 contentInsetTop，语义与"无页头时
/// 加在首行之上的内白"完全一致——有页头时它落在页头之上）。
final class TiebaKindListHeaderHostView: UICollectionReusableView {
  static let reuseIdentifier = "TiebaKindListHeaderHostView"
  static let elementKind = UICollectionView.elementKindSectionHeader

  private weak var content: (any TiebaKindListHeaderView)?
  private var topPadding: CGFloat = 0

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  func configure(content: (any TiebaKindListHeaderView)?, topPadding: CGFloat) {
    if self.content !== content {
      self.content?.removeFromSuperview()
      if let content {
        addSubview(content)
      }
    }
    self.content = content
    self.topPadding = topPadding
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    guard let content else { return }
    content.frame = CGRect(
      x: 0,
      y: topPadding,
      width: bounds.width,
      height: max(bounds.height - topPadding, 0)
    )
  }
}

// MARK: - 话题页头

/// 话题详情页头（topic/[id].tsx 的 listHeader 原生等价）：
///   · 首行：40×40 圆角方框 + number 图标（warning）+ 24/800 话题名（≤2 行）
///     + 讨论数行（flame 13 error + 13/500 tabular-nums textSecondary）；
///   · 简介：14/20 textSecondary；
///   · 相关吧：13/600 标题 + 自适应换行胶囊（20 圆头像 + 13/500 吧名，半径 12，
///     底 surfaceSecondary，最大宽 180）；
///   · 底部 hairline（divider）。整块 padding 16（Spacing.lg）。
/// 精简模式（topicCentered，原 simpleHeader 分支）：仅居中 20/700 标题。
public final class TiebaTopicHeaderView: UIView, TiebaKindListHeaderView {
  // MARK: 接口

  public var onAction: ((String, [String: Any]) -> Void)?

  private var spec: [String: Any] = [:]
  private var palette: TiebaSimpleRowPalette = .default
  private var planCache: (width: CGFloat, plan: TiebaTopicHeaderPlan)?

  public init(spec: [String: Any]) {
    self.spec = spec
    super.init(frame: .zero)
    backgroundColor = .clear
    isOpaque = false
    addSubview(hairlineView)
    addSubview(iconBadgeView)
    iconBadgeView.addSubview(iconView)
    addSubview(titleLabel)
    addSubview(statIconView)
    addSubview(statLabel)
    addSubview(descLabel)
    addSubview(relateTitleLabel)
    applySpec()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  public func applyPalette(_ palette: TiebaSimpleRowPalette) {
    guard palette != self.palette else { return }
    self.palette = palette
    applySpec()
    setNeedsLayout()
  }

  /// 页头高度：padding + 内容（与 layoutSubviews 共用 makePlan，纯算术）。
  public func headerHeight(forWidth width: CGFloat) -> CGFloat {
    makePlan(width: width).totalHeight
  }

  // MARK: 子视图

  private let hairlineView = UIView()
  private let iconBadgeView = UIView()
  private let iconView = UIImageView()
  private let titleLabel = UILabel()
  private let statIconView = UIImageView()
  private let statLabel = UILabel()
  private let descLabel = UILabel()
  private let relateTitleLabel = UILabel()
  private var chipViews: [TiebaTopicForumChipView] = []

  // MARK: 解析 / 配置

  private func applySpec() {
    let colors = TiebaTopicHeaderColors(
      spec: spec["colors"] as? [String: Any] ?? [:],
      palette: palette
    )
    let centered = TiebaSimpleRowParser.string(spec["kind"]) == "topicCentered"
    let title = TiebaSimpleRowParser.nonEmpty(spec["title"]) ?? ""
    let desc = TiebaSimpleRowParser.nonEmpty(spec["desc"])
    let discuss = TiebaSimpleRowParser.double(spec["discuss"])
    let forums = TiebaTopicHeaderForums.parse(spec["forums"])

    // 标题
    titleLabel.isHidden = title.isEmpty
    titleLabel.text = title
    titleLabel.textAlignment = centered ? .center : .natural
    titleLabel.numberOfLines = centered ? 1 : 2
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.font = centered
      ? TiebaSimpleText.font(size: 20, weight: .bold)
      : TiebaSimpleText.font(size: 24, weight: .heavy)
    titleLabel.textColor = colors.text

    // 讨论数行
    let showsStat = !centered && discuss != nil && (discuss ?? 0) != 0
    statIconView.isHidden = !showsStat
    statLabel.isHidden = !showsStat
    if showsStat, let discuss {
      statIconView.image = UIImage(
        systemName: "flame",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .regular)
      )
      statIconView.tintColor = colors.error
      statLabel.text = "\(TiebaForumFormat.count(discuss)) 讨论"
      statLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
      statLabel.textColor = colors.textSecondary
    }

    // 简介
    descLabel.isHidden = centered || desc == nil
    descLabel.text = desc
    descLabel.numberOfLines = 0
    descLabel.lineBreakMode = .byTruncatingTail
    descLabel.font = TiebaSimpleText.font(size: 14, weight: .regular)
    descLabel.textColor = colors.textSecondary

    // 相关吧
    relateTitleLabel.isHidden = centered || forums.isEmpty
    relateTitleLabel.text = "相关吧"
    relateTitleLabel.font = TiebaSimpleText.font(size: 13, weight: .semibold)
    relateTitleLabel.textColor = colors.textSecondary

    iconBadgeView.isHidden = centered
    iconBadgeView.backgroundColor = colors.iconBadgeBackground
    iconView.image = UIImage(
      systemName: "number",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)
    )
    iconView.tintColor = colors.warning

    hairlineView.backgroundColor = colors.divider
    hairlineView.isHidden = centered

    // 胶囊视图按需增删（数量通常 0…8；上限外的直接丢弃——RN 也是全量渲染，
    // 但页头是有限集合，不做虚拟化）。
    while chipViews.count < forums.count {
      let chip = TiebaTopicForumChipView()
      chip.addTarget(self, action: #selector(handleChipTap(_:)), for: .touchUpInside)
      addSubview(chip)
      chipViews.append(chip)
    }
    for (index, chip) in chipViews.enumerated() {
      guard index < forums.count else {
        chip.isHidden = true
        continue
      }
      chip.isHidden = false
      chip.configure(forum: forums[index], colors: colors)
    }
    planCache = nil
    setNeedsLayout()
  }

  @objc private func handleChipTap(_ chip: TiebaTopicForumChipView) {
    guard !chip.forumName.isEmpty else { return }
    onAction?("forum", ["name": chip.forumName])
  }

  deinit {
    // Nuke 的在途请求随视图销毁自动取消（loadImage 绑定到 imageView 的生命周期）。
  }

  // MARK: 布局

  public override func layoutSubviews() {
    super.layoutSubviews()
    let plan = makePlan(width: bounds.width)
    hairlineView.isHidden = plan.hairlineFrame == nil
    hairlineView.frame = plan.hairlineFrame ?? .zero
    iconBadgeView.frame = plan.badgeFrame
    iconBadgeView.layer.cornerRadius = TiebaTopicHeaderLayout.badgeRadius
    iconBadgeView.layer.cornerCurve = .continuous
    let iconSide = TiebaTopicHeaderLayout.statIconSize
    iconView.frame = CGRect(
      x: (iconBadgeView.bounds.width - iconSide) / 2,
      y: (iconBadgeView.bounds.height - iconSide) / 2,
      width: iconSide,
      height: iconSide
    )
    titleLabel.frame = plan.titleFrame
    statIconView.frame = plan.statIconFrame ?? .zero
    statLabel.frame = plan.statLabelFrame ?? .zero
    descLabel.frame = plan.descFrame ?? .zero
    relateTitleLabel.frame = plan.relateTitleFrame ?? .zero
    for (index, chip) in chipViews.enumerated() {
      chip.frame = index < plan.chipFrames.count ? plan.chipFrames[index] : .zero
    }
  }

  /// 尺寸计划（测量与绘制共用；纯算术 + 文本测量，不写任何视图 frame）。
  private func makePlan(width: CGFloat) -> TiebaTopicHeaderPlan {
    if let cache = planCache, cache.width == width { return cache.plan }
    let plan = TiebaTopicHeaderLayout.plan(width: width, spec: spec)
    planCache = (width, plan)
    return plan
  }
}

// MARK: - 相关吧胶囊

private final class TiebaTopicForumChipView: UIControl {
  private let avatarView = UIImageView()
  private let placeholderView = UIView()
  private let placeholderIcon = UIImageView()
  private let nameLabel = UILabel()

  private(set) var forumName = ""

  override init(frame: CGRect) {
    super.init(frame: frame)
    layer.cornerRadius = 12 // RadiusStyle.input
    layer.cornerCurve = .continuous
    clipsToBounds = true

    // 占位块在下、头像图在上：图未到时露出占位（RN Avatar 的 person.2 兜底），
    // 图命中即盖住——不需要加载回调，也不存"失败"状态。
    placeholderView.clipsToBounds = true
    placeholderIcon.contentMode = .scaleAspectFit
    placeholderView.addSubview(placeholderIcon)
    addSubview(placeholderView)
    avatarView.clipsToBounds = true
    avatarView.contentMode = .scaleAspectFill
    addSubview(avatarView)
    nameLabel.numberOfLines = 1
    nameLabel.lineBreakMode = .byTruncatingTail
    addSubview(nameLabel)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  func configure(forum: (name: String, avatar: URL?), colors: TiebaTopicHeaderColors) {
    forumName = forum.name
    backgroundColor = colors.surfaceSecondary
    nameLabel.text = forum.name
    nameLabel.font = TiebaSimpleText.font(size: 13, weight: .medium)
    nameLabel.textColor = colors.text
    isAccessibilityElement = true
    accessibilityTraits = .button
    accessibilityLabel = "\(forum.name)吧"

    avatarView.image = nil
    avatarView.isHidden = forum.avatar == nil
    placeholderView.backgroundColor = colors.chip
    placeholderIcon.image = UIImage(
      systemName: "person.2.fill",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .regular)
    )
    placeholderIcon.tintColor = colors.textDisabled
    if let url = forum.avatar {
      var options = ImageLoadingOptions()
      options.pipeline = TiebaNuke.pipeline
      options.transition = nil
      options.isProgressiveRenderingEnabled = false
      options.processors = [
        TiebaNuke.resizeProcessor(targetPixelSize: CGSize(width: 20, height: 20)),
      ]
      loadImage(with: TiebaNuke.secureURL(url), options: options, into: avatarView)
    }
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let side = TiebaTopicHeaderLayout.chipAvatar
    let y = (bounds.height - side) / 2
    avatarView.frame = CGRect(
      x: TiebaTopicHeaderLayout.chipPaddingH,
      y: y,
      width: side,
      height: side
    )
    avatarView.layer.cornerRadius = side / 2
    placeholderView.frame = avatarView.frame
    placeholderView.layer.cornerRadius = side / 2
    placeholderIcon.frame = CGRect(x: 3, y: 3, width: side - 6, height: side - 6)
    let textX = TiebaTopicHeaderLayout.chipPaddingH + side + TiebaTopicHeaderLayout.chipGap
    nameLabel.frame = CGRect(
      x: textX,
      y: 0,
      width: max(bounds.width - textX - TiebaTopicHeaderLayout.chipPaddingH, 0),
      height: bounds.height
    )
  }
}

// MARK: - 尺寸计划（测量与绘制的单一来源）

/// 话题页头的帧计划（坐标 = 页头视图坐标；高度含底部 hairline，与 RN 的
/// border-box 一致）。
struct TiebaTopicHeaderPlan {
  var totalHeight: CGFloat = 0
  var badgeFrame: CGRect = .zero
  var titleFrame: CGRect = .zero
  var statIconFrame: CGRect?
  var statLabelFrame: CGRect?
  var descFrame: CGRect?
  var relateTitleFrame: CGRect?
  var chipFrames: [CGRect] = []
  var hairlineFrame: CGRect?
}

/// 页头几何常量（topic/[id].tsx styles 的逐项对应）。
@MainActor
enum TiebaTopicHeaderLayout {
  static let padding: CGFloat = 16 // Spacing.lg
  static let badgeSize: CGFloat = 40
  static let badgeRadius: CGFloat = 12 // RadiusStyle.input
  static let badgeGap: CGFloat = 12 // Spacing.md
  static let titleToStatGap: CGFloat = 5
  static let statIconSize: CGFloat = 13
  static let statIconGap: CGFloat = 4
  static let headerRowBottom: CGFloat = 8 // Spacing.sm
  static let descMarginTop: CGFloat = 8
  static let descLineHeight: CGFloat = 20
  static let relateMarginTop: CGFloat = 12 // Spacing.md
  static let relateTitleBottom: CGFloat = 8 // Spacing.sm
  static let relateGap: CGFloat = 8 // Spacing.sm（行/列间距同值）
  static let chipPaddingH: CGFloat = 10
  static let chipPaddingV: CGFloat = 6
  static let chipGap: CGFloat = 6
  static let chipAvatar: CGFloat = 20
  static let chipMaxWidth: CGFloat = 180

  static func plan(width: CGFloat, spec: [String: Any]) -> TiebaTopicHeaderPlan {
    var plan = TiebaTopicHeaderPlan()
    let centered = TiebaSimpleRowParser.string(spec["kind"]) == "topicCentered"
    let title = TiebaSimpleRowParser.nonEmpty(spec["title"]) ?? ""
    let contentWidth = max(width - padding * 2, 0)
    let hairline = 1 / max(UIScreen.main.scale, 1)

    if centered {
      // 精简页头：padding + 居中标题（20/700）+ padding（原 simpleHeader 分支）。
      let attributed = attributed(text: title, size: 20, weight: .bold, lineHeight: nil)
      var y = padding
      if let attributed {
        let height = TiebaSimpleText.measureHeight(attributed, width: contentWidth, maxLines: 1)
        plan.titleFrame = CGRect(x: padding, y: y, width: contentWidth, height: height)
        y += height
      }
      plan.hairlineFrame = nil
      plan.totalHeight = y + padding
      return plan
    }

    var y = padding
    // ── 首行：徽章 + 标题列 ──
    let titleWidth = max(contentWidth - badgeSize - badgeGap, 0)
    let titleHeight = attributed(text: title, size: 24, weight: .heavy, lineHeight: nil)
      .map { TiebaSimpleText.measureHeight($0, width: titleWidth, maxLines: 2) } ?? 0
    let discuss = TiebaSimpleRowParser.double(spec["discuss"])
    let showsStat = discuss != nil && (discuss ?? 0) != 0
    let statLabelHeight: CGFloat = showsStat
      ? ceil(UIFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium).lineHeight)
      : 0
    let statRowHeight = showsStat ? max(statIconSize, statLabelHeight) : 0
    let colHeight = titleHeight + (showsStat ? titleToStatGap + statRowHeight : 0)
    let rowHeight = max(badgeSize, colHeight)
    plan.badgeFrame = CGRect(x: padding, y: y, width: badgeSize, height: badgeSize)
    let colX = padding + badgeSize + badgeGap
    plan.titleFrame = CGRect(x: colX, y: y, width: titleWidth, height: titleHeight)
    if showsStat {
      let statTop = y + titleHeight + titleToStatGap
      plan.statIconFrame = CGRect(
        x: colX,
        y: statTop + (statRowHeight - statIconSize) / 2,
        width: statIconSize,
        height: statIconSize
      )
      plan.statLabelFrame = CGRect(
        x: colX + statIconSize + statIconGap,
        y: statTop + (statRowHeight - statLabelHeight) / 2,
        width: max(titleWidth - statIconSize - statIconGap, 0),
        height: statLabelHeight
      )
    }
    y += rowHeight + headerRowBottom

    // ── 简介 ──
    if let desc = TiebaSimpleRowParser.nonEmpty(spec["desc"]) {
      let descHeight = attributed(text: desc, size: 14, weight: .regular, lineHeight: descLineHeight)
        .map { TiebaSimpleText.measureHeight($0, width: contentWidth, maxLines: 0) } ?? 0
      y += descMarginTop
      plan.descFrame = CGRect(x: padding, y: y, width: contentWidth, height: descHeight)
      y += descHeight
    }

    // ── 相关吧 ──
    let forums = TiebaTopicHeaderForums.parse(spec["forums"])
    if !forums.isEmpty {
      let relateTitleHeight = ceil(TiebaSimpleText.font(size: 13, weight: .semibold).lineHeight)
      y += relateMarginTop
      plan.relateTitleFrame = CGRect(
        x: padding,
        y: y,
        width: contentWidth,
        height: relateTitleHeight
      )
      y += relateTitleHeight + relateTitleBottom
      let chipHeight = chipPaddingV * 2
        + max(chipAvatar, ceil(TiebaSimpleText.font(size: 13, weight: .medium).lineHeight))
      let chipFont = TiebaSimpleText.font(size: 13, weight: .medium)
      var x = padding
      for forum in forums {
        let textWidth = TiebaSimpleText.singleLineWidth(forum.name, font: chipFont)
        let naturalWidth = chipPaddingH * 2 + chipAvatar + chipGap + textWidth
        let chipWidth = min(naturalWidth, chipMaxWidth)
        // 换行判定与 RN flexWrap + gap 同几何：放不下就另起一行（首个不换）。
        if x > padding, x + chipWidth > padding + contentWidth {
          x = padding
          y += chipHeight + relateGap
        }
        plan.chipFrames.append(CGRect(x: x, y: y, width: chipWidth, height: chipHeight))
        x += chipWidth + relateGap
      }
      y += chipHeight
    }

    y += padding
    // RN 的 borderBottomWidth 计入盒高（border-box）；页头高含这根 hairline。
    plan.hairlineFrame = CGRect(x: 0, y: max(y - hairline, 0), width: width, height: hairline)
    plan.totalHeight = y
    return plan
  }

  /// 测量用 attributed（TiebaSimpleText：UIFontMetrics 缩放 + RN 显式 lineHeight
  /// 语义；颜色不参与测量，绘制期由 label 自带）。
  private static func attributed(
    text: String,
    size: CGFloat,
    weight: UIFont.Weight,
    lineHeight: Double?
  ) -> NSAttributedString? {
    guard !text.isEmpty else { return nil }
    let font = TiebaSimpleText.font(size: size, weight: weight)
    return TiebaSimpleText.makeAttributed(
      text: text,
      font: font,
      lineHeight: TiebaSimpleText.lineHeight(lineHeight, font: font)
    )
  }
}

// MARK: - 主题色（spec.colors 优先，缺键回落色板默认）

struct TiebaTopicHeaderColors {
  let text: UIColor
  let textSecondary: UIColor
  let textDisabled: UIColor
  let divider: UIColor
  let warning: UIColor
  let error: UIColor
  let chip: UIColor
  let surfaceSecondary: UIColor
  let primary: UIColor

  init(spec: [String: Any], palette: TiebaSimpleRowPalette) {
    func color(_ key: String, _ fallback: UIColor) -> UIColor {
      guard let raw = spec[key] as? String, let parsed = tiebaColor(from: raw) else {
        return fallback
      }
      return parsed
    }
    text = color("text", palette.base.text)
    textSecondary = color("textSecondary", palette.base.textSecondary)
    textDisabled = color("textDisabled", palette.textDisabled)
    divider = color("divider", palette.divider)
    warning = color("warning", palette.base.warning)
    // error 不在 TiebaFeedRowPalette/TiebaSimpleRowPalette 里（两套色板都没有
    // 用到它）；colors.ts 的 error = #FF3B30 / #FF453A ≈ systemRed，缺失时用
    // 系统红兜底（JS 侧恒下发 colors.error，兜底只对旧 JS 生效）。
    error = color("error", .systemRed)
    chip = color("chip", palette.base.chip)
    surfaceSecondary = color("surfaceSecondary", palette.surfaceSecondary)
    primary = color("primary", palette.base.primary)
  }

  /// 徽章底：topic/[id].tsx 的 isNight 两档（rgba(255,159,10,0.16) / rgba(255,149,0,0.12)）。
  var iconBadgeBackground: UIColor {
    UIColor { traits in
      let night = traits.userInterfaceStyle == .dark
      return UIColor(
        red: 1,
        green: night ? 159 / 255 : 149 / 255,
        blue: night ? 10 / 255 : 0,
        alpha: night ? 0.16 : 0.12
      )
    }
  }
}

// MARK: - 相关吧解析（TiebaSimpleRowParser 没有的列表形状）

/// spec.forums = [{ name, avatar? }]（avatar 为完整 URL 或空串）。取值一律直调
/// TiebaSimpleRowParser（全仓唯一字典解析），本处只保留列表结构。
nonisolated enum TiebaTopicHeaderForums {
  static func parse(_ value: Any?) -> [(name: String, avatar: URL?)] {
    guard let list = value as? [Any] else { return [] }
    var result: [(name: String, avatar: URL?)] = []
    for element in list {
      guard let item = element as? [String: Any] else { continue }
      guard let name = TiebaSimpleRowParser.nonEmpty(item["name"]) else { continue }
      let avatar = TiebaSimpleRowParser.nonEmpty(item["avatar"]).flatMap(TiebaSimpleRowParser.avatarURL)
      result.append((name, avatar))
    }
    return result
  }
}
