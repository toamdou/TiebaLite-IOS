// 已知主贴区（原 thread/[id].tsx 的 KnownPostHeader）：帖子首包返回前显示列表里
// 已知的标题/作者/摘要/首图，首包落地后整块（含骨架）一起被真实主贴卡替换。
// 几何逐项对齐 JS 的 knownCard/knownTitle/knownAuthorRow/knownAbstract/knownImage。
import UIKit
import NukeExtensions

final class TiebaThreadKnownPostView: UIView {
  private let card = UIView()
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
      abstractLabel.font = TiebaSimpleText.font(size: 14, weight: .regular)
      abstractLabel.numberOfLines = 2
      abstractLabel.attributedText = TiebaSimpleText.makeAttributed(
        text: snapshot.abstract,
        font: TiebaSimpleText.font(size: 14, weight: .regular),
        lineHeight: 20
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
      NSLayoutConstraint.activate([
        ratio,
        imageView.heightAnchor.constraint(lessThanOrEqualToConstant: 320),
        imageView.heightAnchor.constraint(greaterThanOrEqualToConstant: 1),
      ])
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
    let height = min(max(width / imageAspect, 1), 320)
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
