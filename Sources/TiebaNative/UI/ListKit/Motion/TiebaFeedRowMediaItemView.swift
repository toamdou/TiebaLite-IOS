// 从 TiebaFeedRowMotionViews.swift 拆出（按类型分文件，纯搬运、整类型逐字搬走）。

import UIKit
import Nuke
import NukeExtensions

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
