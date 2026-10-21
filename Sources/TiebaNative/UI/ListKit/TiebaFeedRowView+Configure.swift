import UIKit
import Nuke
import NukeExtensions

extension TiebaFeedRowView {
  // MARK: - apply / 复位

  func applyIfConfigured() {
    guard !applying, !pageKey.isEmpty, rowIndex >= 0 else { return }
    loadModel(pageKey: pageKey, index: rowIndex)
  }

  func loadModel(pageKey: String, index: Int) {
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
  func resetContent() {
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
    accessibilityElements = nil
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
  func applyPalette() {
    cardView.backgroundColor = TiebaListAppearance.isFlat ? .systemBackground : palette.card
    cardView.layer.borderColor = palette.borderCard.resolvedColor(with: traitCollection).cgColor
    avatarContainer.backgroundColor = palette.avatarFallback
    bannerHairline.backgroundColor = palette.borderCard
    bannerIconView.tintColor = palette.primary
    bannerBadgeLabel.textColor = palette.primary
    bannerBadgeLabel.backgroundColor = palette.primary.withAlphaComponent(0.1)
    bannerTextLabel.textColor = palette.text
    quoteCard.backgroundColor = .tertiarySystemFill
    quoteCard.layer.borderWidth = 0
    quoteCard.layer.borderColor = UIColor.clear.cgColor
    chipView.backgroundColor = palette.chip
    chipLabel.textColor = palette.onChip
    menuButton.configure(tint: palette.textTertiary)
    for item in stripItems {
      item.palette = palette
    }
    singleMediaView.palette = palette
    // 动态色转 CGColor 的两处（卡片/引用卡描边）立即按当前外观重解析一次。
    refreshDynamicLayerColors()
    updateFeedSurfaceAppearance()
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
    updateAccessibilityElements()
  }

  /// (pageKey, index) 字符串键：区分"换行"与"同行重配（点赞/展开/主题重刷）"。
  var identityKey: String? {
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
    bannerTextLabel.numberOfLines = 0
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
        cornerRadius: TiebaListAppearance.cardRadius, // Radius.card - 4（MediaPager mediaWrap）
        contentMode: .scaleAspectFill,
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
          singleMediaView.loadDisplay(
            url: url,
            targetSize: CGSize(width: model.geometry.textColumnWidth, height: height),
            cornerRadius: TiebaListAppearance.cardRadius,
            scale: scale
          )
        } else {
          singleMediaView.load(
            url: url,
            maxPixel: model.geometry.contentWidth * scale
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
        : palette.textSecondary
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

  // MARK: - 外观切换（layer 的 CGColor 不会自动跟随动态色）

  /// 外观档变化时重解析 CGColor（由 styleRegistration 触发；换色板时也直接调）。
  func refreshDynamicLayerColors() {
    // 画布位图里烘的是具体颜色：深浅档一变，旧位图必须整表作废，否则深色下仍贴浅色字形。
    // 同时清 placedToken 强制下一次布局重摆——**不在这里就地重烘**：调用方（applyPalette /
    // trait 回调）此刻还没 configure，label 上可能仍是旧色，重烘会把旧色存进新键。
    TiebaFeedRowTextCanvas.invalidateCache()
    placedToken = nil
    setNeedsLayout()
    cardView.layer.borderColor = UIColor.clear.cgColor
    quoteCard.backgroundColor = .tertiarySystemFill
    quoteCard.layer.borderWidth = 0
    quoteCard.layer.borderColor = UIColor.clear.cgColor
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
