// 已知主贴区（原 thread/[id].tsx 的 KnownPostHeader）：帖子首包返回前显示列表里
// 已知的标题/作者/摘要/首图，首包落地后整块（含骨架）一起被真实主贴卡替换。
// 几何逐项对齐 JS 的 knownCard/knownTitle/knownAuthorRow/knownAbstract/knownImage。
import UIKit
import NukeExtensions

final class TiebaThreadKnownPostView: UIView {
  private let card = UIView()
  private let titleLabel = UILabel()
  private let authorLabel = UILabel()
  private let abstractLabel = UILabel()
  private let imageView = UIImageView()

  private let snapshot: TiebaThreadSnapshot
  private var palette: TiebaFeedRowPalette = .default

  /// 图片按固定宽高比铺满卡片内容宽（JS: height = clamp(w × h/w, 1, 320)）。
  private var imageAspect: CGFloat {
    snapshot.imageWidth > 0 && snapshot.imageHeight > 0
      ? CGFloat(snapshot.imageWidth / snapshot.imageHeight) : 0
  }

  /// 竖长图（与 TiebaThreadImage.isTall / MediaPager LONG_IMAGE_RATIO 同值）。
  private var isTallImage: Bool {
    snapshot.imageWidth > 0 && snapshot.imageHeight > 0
      && CGFloat(snapshot.imageHeight / snapshot.imageWidth) > 2.4
  }

  /// 图片高度与真实主贴卡同一套规则（TiebaPostRowMetrics.swift:953-957）：竖长图
  /// 固定 300，其余按宽高比、上限 520。两边算不一样时，换卡那一刻图片与它下面的
  /// 内容会整体跳一次——用户报的"加载完突然往上瞬移"就有这一份。
  private func imageHeight(forWidth width: CGFloat) -> CGFloat {
    if isTallImage { return TiebaPostRowLayout.longImageHeight }
    return min(
      max(width / max(imageAspect, 0.01), 1),
      TiebaPostRowLayout.singleImageMaxHeight
    )
  }
  private var imageViewWidth: CGFloat = 0

  init(snapshot: TiebaThreadSnapshot) {
    self.snapshot = snapshot
    super.init(frame: .zero)
    isAccessibilityElement = false
    build()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func layoutSubviews() {
    super.layoutSubviews()
    loadImageIfNeeded()
  }

  func applyPalette(_ palette: TiebaFeedRowPalette) {
    self.palette = palette
    card.backgroundColor = palette.card
    card.layer.borderColor = palette.borderCard.cgColor
    titleLabel.textColor = palette.text
    authorLabel.textColor = palette.textSecondary
    abstractLabel.textColor = palette.textSecondary
    imageView.backgroundColor = palette.placeholder
  }

  // MARK: - 装配

  private func build() {
    card.layer.cornerRadius = TiebaPostRowLayout.cardRadius
    card.layer.cornerCurve = .continuous
    card.layer.borderWidth = 1 / max(traitCollection.displayScale, 1)
    card.translatesAutoresizingMaskIntoConstraints = false
    addSubview(card)

    let stack = UIStackView()
    stack.axis = .vertical
    stack.alignment = .fill
    stack.spacing = 12 // knownCard gap
    stack.isLayoutMarginsRelativeArrangement = true
    stack.directionalLayoutMargins = NSDirectionalEdgeInsets(
      top: 16, leading: 16, bottom: 16, trailing: 16
    )
    stack.translatesAutoresizingMaskIntoConstraints = false
    card.addSubview(stack)

    // 标题：占位卡的第一个块（JS knownTitle 17pt/22pt/最多 3 行）。快照里标题一直
    // 有，漏掉它占位卡就没有帖名——与作者行、摘要同尺排下去，换真卡不位移。
    if !snapshot.title.isEmpty {
      titleLabel.font = TiebaSimpleText.font(size: 17, weight: .medium)
      // 与真卡（TiebaPostRowLayout.titleLineLimit = 0）保持一致：都不截断，
      // 否则换卡那一刻标题行数会变、下面整块跳一次。
      titleLabel.numberOfLines = TiebaPostRowLayout.titleLineLimit
      titleLabel.attributedText = TiebaSimpleText.makeAttributed(
        text: snapshot.title,
        font: TiebaSimpleText.font(size: 17, weight: .medium),
        lineHeight: 22
      )
      stack.addArrangedSubview(titleLabel)
    }

    // 作者行：与真实主贴卡同尺（头像 40 / 昵称 16 semibold）——换卡时不位移。
    let row = UIStackView()
    row.axis = .horizontal
    row.alignment = .center
    row.spacing = 10
    let avatar = TiebaForumAvatarView(size: 40)
    avatar.configure(url: snapshot.authorPortrait, initial: snapshot.authorName)
    row.addArrangedSubview(avatar)
    authorLabel.text = snapshot.authorName
    authorLabel.font = TiebaSimpleText.font(size: 16, weight: .semibold)
    authorLabel.numberOfLines = 1
    row.addArrangedSubview(authorLabel)
    stack.addArrangedSubview(row)

    if !snapshot.abstract.isEmpty {
      abstractLabel.text = snapshot.abstract
      // 字号/行高与真实主贴正文同尺（15pt/22pt，见 TiebaPostRowMetrics.buildContent）：
      // 摘要本来就是正文的预览，行高不一致时换卡会整块上下跳（用户 2026-09-15 报）。
      // 颜色留次要色——预览的视觉设计不变。
      abstractLabel.font = TiebaSimpleText.font(size: 15, weight: .regular)
      abstractLabel.numberOfLines = 2
      abstractLabel.attributedText = TiebaSimpleText.makeAttributed(
        text: snapshot.abstract,
        font: TiebaSimpleText.font(size: 15, weight: .regular),
        lineHeight: 22
      )
      stack.addArrangedSubview(abstractLabel)
    }

    if snapshot.imageURL != nil, imageAspect > 0 {
      imageView.contentMode = .scaleAspectFill
      // 圆角在图片管线里烘焙进像素（见 TiebaNuke.displayProcessor）：本层不再
      // clipsToBounds，省掉每帧一次离屏合成；cornerRadius 只服务占位底色。
      imageView.layer.cornerRadius = 10
      imageView.layer.cornerCurve = .continuous
      imageView.translatesAutoresizingMaskIntoConstraints = false
      stack.addArrangedSubview(imageView)
      let ratio = imageView.heightAnchor.constraint(
        equalTo: imageView.widthAnchor,
        multiplier: 1 / imageAspect
      )
      ratio.priority = .defaultHigh
      var imageConstraints = [
        imageView.heightAnchor.constraint(lessThanOrEqualToConstant: TiebaPostRowLayout.singleImageMaxHeight),
        imageView.heightAnchor.constraint(greaterThanOrEqualToConstant: 1),
      ]
      // 竖长图不做比例约束，固定 300（真实卡同规则）；宽度由卡片内容宽决定，
      // 所以这两个约束在任何宽度下都算得出确定高度。
      if isTallImage {
        imageConstraints.append(
          imageView.heightAnchor.constraint(equalToConstant: TiebaPostRowLayout.longImageHeight)
        )
      } else {
        imageConstraints.append(ratio)
      }
      NSLayoutConstraint.activate(imageConstraints)
    }

    NSLayoutConstraint.activate([
      // 左右边距与真实主贴卡同值（TiebaPostRowLayout.cardMarginH）：否则换卡瞬间
      // 卡片会横向收放一次。
      card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: TiebaPostRowLayout.cardMarginH),
      card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -TiebaPostRowLayout.cardMarginH),
      card.topAnchor.constraint(equalTo: topAnchor),
      // 底部 12 = SkeletonList 的 paddingTop（JS 两个块之间的间距）。
      card.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
      stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
      stack.topAnchor.constraint(equalTo: card.topAnchor),
      stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
    ])
  }

  /// 首图按"视图最终尺寸"取图（下采样 + 烘焙圆角都在管线里）：宽度只有布局后
  /// 才知道，所以放在 layoutSubviews；宽度变化（旋屏/分屏）按新尺寸重取。
  private func loadImageIfNeeded() {
    guard let url = snapshot.imageURL, imageAspect > 0 else { return }
    let width = imageView.bounds.width
    guard width > 1, abs(width - imageViewWidth) > 0.5 else { return }
    imageViewWidth = width
    let height = imageHeight(forWidth: width)
    let scale = max(traitCollection.displayScale, 1)
    loadImage(
      with: TiebaNuke.secureURL(url),
      options: TiebaNuke.options(
        processor: TiebaNuke.displayProcessor(
          targetSize: CGSize(width: width, height: height),
          cornerRadius: imageView.layer.cornerRadius,
          scale: scale
        ),
        transition: true
      ),
      into: imageView
    )
  }
}
