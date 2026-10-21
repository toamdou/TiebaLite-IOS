import UIKit

extension TiebaFeedRowView {
  // MARK: - 布局（只摆 frame，不测量）

  /// 扁平档 = systemBackground 内容面 + 行底 1 物理像素 hairline；
  /// 卡片档 = palette.card 卡面 + 1 物理像素描边，无 hairline。
  /// 只在布局/主题切换时算一次，不进入滚动逐帧逻辑。
  func updateFeedSurfaceAppearance() {
    let flat = TiebaListAppearance.isFlat
    let scale = max(traitCollection.displayScale, 1)
    cardView.backgroundColor = flat ? .systemBackground : palette.card
    cardView.layer.cornerRadius = TiebaFeedRowLayout.cardRadius
    cardView.layer.borderWidth = 0
    cardView.layer.borderColor = UIColor.clear.cgColor
    rowHairline.backgroundColor = palette.separator
    let hairlineVisible = flat && isCollapsing == false && model != nil
    rowHairline.isHidden = hairlineVisible == false
    guard hairlineVisible else { return }
    let thickness = 1 / scale
    let inset = TiebaFeedRowLayout.cardMarginH + TiebaFeedRowLayout.cardPaddingX
    rowHairline.frame = CGRect(
      x: inset,
      y: bounds.height - thickness,
      width: max(bounds.width - inset * 2, 0),
      height: thickness
    )
  }

  public override func layoutSubviews() {
    super.layoutSubviews()
    // 折叠动画在途：**不重排**。高度在收，内容是按完整高度摆好的那一份，
    // 由 clipsToBounds 裁掉下半部分（重排的话就成了"内容跟着缩"，不是折叠）。
    guard !isCollapsing else { return }
    guard let model else {
      // 模型被清掉（换行 / 页还没测完）：画布必须一起清空，否则会留着上一行的文字。
      textCanvas.clear()
      accessibilityElements = nil
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
    updateFeedSurfaceAppearance()
    updateAccessibilityElements()
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
  static func cardRect(_ rect: CGRect?) -> CGRect? {
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
}
