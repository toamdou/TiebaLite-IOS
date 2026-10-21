import UIKit

extension TiebaFeedRowView {
  // MARK: - 动画（入场 / 折叠）

  /// 首屏批次入场（EntranceRow）：opacity 0→1 + translateY 12→0，delay =
  /// min(index, 9) × 35ms、220ms、EASE_OUT。只由列表在首批页面上屏时调用一次；
  /// Reduce Motion 时直接静态（与 EntranceRow 的 reduceMotion 分支同语义）。
  public func playEntranceAnimation(index: Int) {
    TiebaEntrance.play(on: self, index: index)
  }

  /// 折叠退场时长（只读暴露，别在两处各写一个 0.28）。删数据现在由
  /// playCollapseAnimation 的 completion 驱动，不再需要外部约这时长。
  public static var collapseDuration: CFTimeInterval { TiebaFeedRowMotion.collapseDuration }

  /// 不感兴趣折叠（CollapseRow）：280ms、EASE_OUT、opacity 1→0。
  /// 数据移除仍由 completion 驱动（原 JS 的动画窗口后 360ms 兜底定时器已删）。
  ///
  /// **视觉高度与布局高度解耦**（TiebaApparentHeight）：动画只收**本视图的高度**
  /// （顶边不动、内容裁剪），列表给的布局高度在动画结束、数据真正移除之后才变。
  /// ⚠️ 改前是 `transform.scale.y`：整层连同**文字**一起被纵向压扁——文字在那个
  /// 280ms 里被压成半高，是可见的缺陷（同仓查看器的缩放不用在文字上也是这个道理）。
  /// Reduce Motion 无动画可等，必须同步回调一次，否则列表永远不删数据。
  public func playCollapseAnimation(completion: (() -> Void)? = nil) {
    collapseState.setLayoutHeight(max(bounds.height, 0))
    collapseState.beginTransition(to: 0)
    isCollapsing = true
    // 收缩期间必须裁剪：内容按完整高度摆好后**不再重排**（见 layoutSubviews 的
    // isCollapsing 早退），高度收下去的部分由裁剪吃掉——这就是"不压扁文字"的关键。
    clipsToBounds = true

    let finish: () -> Void = { [weak self] in
      guard let self else {
        completion?()
        return
      }
      self.collapseState.finishTransition()
      self.isCollapsing = false
      self.collapseAnimator = nil
      completion?()
    }

    guard !UIAccessibility.isReduceMotionEnabled else {
      collapseState.setApparentHeight(0)
      applyCollapseFrame()
      alpha = 0
      finish()
      return
    }
    let animator = UIViewPropertyAnimator(
      duration: TiebaFeedRowMotion.collapseDuration,
      curve: .easeOut
    ) { [weak self] in
      guard let self else { return }
      self.collapseState.setApparentHeight(0)
      self.applyCollapseFrame()
      self.alpha = 0
    }
    animator.addCompletion { _ in finish() }
    collapseAnimator = animator
    animator.startAnimation()
  }

  /// 把视觉高度贴到本视图（TiebaApparentHeight.apparentFrame：只换高度，origin/宽度不动 →
  /// 顶边不动，下面的行不会因为这次收缩而位移）。
  private func applyCollapseFrame() {
    frame = collapseState.apparentFrame(from: frame)
  }

  /// 复位行级动画（复用/换行）：动画 key 移除 + 终态归位，防止 transform/alpha
  /// 残留串到下一行（prepareForReuse 与 apply 都会走）。
  public func resetAnimations() {
    layer.removeAnimation(forKey: "tieba.entrance")
    layer.removeAnimation(forKey: "tieba.collapse")
    // 折叠：停掉动画并复位折叠状态（高度由列表下次布局重新给，这里只保证
    // alpha/裁剪/在途标记不串到下一行）。
    collapseAnimator?.stopAnimation(true)
    collapseAnimator = nil
    isCollapsing = false
    collapseState = TiebaApparentHeight(layoutHeight: max(bounds.height, 0))
    clipsToBounds = false
    alpha = 1
    layer.opacity = 1
    layer.transform = CATransform3DIdentity
    likeIconPopLayer?.removeAllAnimations()
    likeCountPopLayer?.removeAllAnimations()
    menuButton.layer.removeAllAnimations()
    for item in actionItems {
      item.alpha = 1
      item.layer.removeAllAnimations()
    }
    // 复用/换行时把在途的延迟蓄力一并作废，否则会在别的行上突然震一下。
    cancelPendingLikeCharge()
    TiebaHaptics.stopContinuousPlayer(playerId: TiebaFeedRowHapticIds.likeCharge)
  }

  // MARK: - 交互（右上角菜单 / 操作栏按压反馈）

  /// 右上角「更多」：与 RN 的 Alert.alert(title, nil, [菜单项…, 取消]) 同形态——
  /// iOS 侧本就是 UIAlertController(.actionSheet)，这里直出同一控件。
  /// 动作只回传 JS（不感兴趣面板/屏蔽/复制标题全在 FeedContent），原生不猜业务。
  @objc func handleMenuButtonTap() {
    guard let model, !model.menuOptions.isEmpty,
          let host = TiebaTopViewController.find() else { return }
    // RN 的 handleClosePress 在弹面板前触发 press 触觉（同款）。
    TiebaSceneHaptics.fire("press")
    let sheet = UIAlertController(
      title: model.titleText.isEmpty ? "帖子" : model.titleText,
      message: nil,
      preferredStyle: .actionSheet
    )
    for option in model.menuOptions {
      sheet.addAction(UIAlertAction(title: Self.menuTitle(for: option), style: .default) { [weak self] _ in
        self?.onMenuAction?(option)
      })
    }
    sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
    // iPad/大屏 popover 锚点（iPhone 上 actionSheet 忽略）。
    sheet.popoverPresentationController?.sourceView = menuButton
    sheet.popoverPresentationController?.sourceRect = menuButton.bounds
    host.present(sheet, animated: true)
  }

  /// 菜单项文案与 TweetCard.closeMenuOptions 的组装逻辑逐字对齐。
  private static func menuTitle(for option: String) -> String {
    switch option {
    case "dislike": return "不感兴趣"
    case "block": return "屏蔽作者"
    case "block-forum": return "屏蔽吧"
    case "copy-title": return "复制标题"
    default: return option
    }
  }

  // MARK: - 卡片长按菜单（与长按图片同一套：UIContextMenuInteraction + UITargetedPreview + UIMenu）


  /// 卡片长按菜单开关（页面按行字典 cardContextMenu 下发）：只在启用时挂交互，
  /// 关闭态零手势开销 —— 与图片菜单的 syncContextMenuInteraction 同策略。
  ///
  /// 宿主是**文字画布** textCanvas，不是 self / cardView：画布覆盖整卡、又压在图片/
  /// 头像/徽章/操作栏等子视图**之下**，命中链与那些子视图**互不相交** —— 手指落在
  /// 图片上时画布不在链里，图片那套长按菜单原样生效；同一行不会有两套长按抢手势。
  ///
  /// 菜单项固定四项，动作经 onMenuAction 回传页面（与右上角「更多」同一出口）：
  /// "share" 分享帖子 · "copy-content" 复制帖子内容 · "dislike" 不感兴趣 ·
  /// "block" 屏蔽作者 —— **启用本菜单的页面必须四个都接线**。
  func syncCardMenuInteraction() {
    let enabled = model?.showsCardContextMenu == true && model?.isTopBanner != true
    if enabled {
      if cardMenuInteraction == nil {
        let interaction = UIContextMenuInteraction(delegate: self)
        textCanvas.addInteraction(interaction)
        cardMenuInteraction = interaction
      }
    } else if let interaction = cardMenuInteraction {
      textCanvas.removeInteraction(interaction)
      cardMenuInteraction = nil
    }
  }

  /// 菜单身份 = 页键 # 行号 # 帖子 id。菜单是异步的：动作触发那一刻本视图可能已被
  /// 复用/换页（页级 reload + 翻页模型），身份对不上就丢弃这次动作 —— 宁可什么都不做，
  /// 也不能把「屏蔽作者」落到另一张帖子上。
  private var cardMenuIdentity: String? {
    guard let model, let identityKey else { return nil }
    return "\(identityKey)#\(model.threadId)"
  }

  private func emitCardMenuAction(_ action: String, identity: String) {
    guard cardMenuIdentity == identity else { return }
    onMenuAction?(action)
  }

  /// 操作栏按压（UIControl 跟踪）：三键统一 0.45 透明度；点赞另外承担蓄力
  /// 触觉（延迟启动）与 heart 弹簧 pop（1→1.35→1）。动作语义不在这里发——
  /// cell 的整卡点击照常命中 region=action，由 JS 定夺。
  @objc func handleActionTouchDown(_ control: UIControl) {
    control.alpha = 0.45
    guard control === actionItems[2] else { return }
    playLikePop()
    scheduleLikeCharge()
  }

  /// 抬手 / 拖出按钮 / 滚动抢走 touch / 手势取消：一律复位反馈并停震。
  @objc func handleActionTouchEnd(_ control: UIControl) {
    control.alpha = 1
    guard control === actionItems[2] else { return }
    cancelPendingLikeCharge()
    endLikeCharge()
    // 松手强制回 1（RN onPressOut 的 MOMENTUM 写入）：不依赖序列自动续跑，
    // 否则点赞乐观更新引发的行重配可能让 pop 停在 1.35。
    springLikeIcon(to: 1, key: "tieba.likePopSettle")
  }

  /// 蓄力触觉延迟启动：手指只是滑过按钮（随即 touchCancel）不能震；令牌
  /// 自增作废在途任务（延迟窗口内取消 = 不震）。
  private func scheduleLikeCharge() {
    likeChargeToken += 1
    let token = likeChargeToken
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.likeChargeDelay) { [weak self] in
      guard let self, self.likeChargeToken == token else { return }
      self.beginLikeCharge()
    }
  }

  private func cancelPendingLikeCharge() {
    likeChargeToken += 1
  }

  /// 点赞蓄力（hapticsRealtime.ts 的 likeCharge）：按住期间低强度连续震，松手即停。
  /// 播放器与引擎复用全仓唯一的 TiebaHaptics（行内不再自建 CHHapticEngine）；
  /// 档位读设置页写入的 hapticsRealtimeStyles.likeCharge（off = 不播）。
  private func beginLikeCharge() {
    guard let scale = likeChargeScale() else { return }
    TiebaHaptics.createContinuousPlayer(
      playerId: TiebaFeedRowHapticIds.likeCharge,
      initialIntensity: TiebaFeedRowHapticIds.chargeIntensity * scale,
      initialSharpness: TiebaFeedRowHapticIds.chargeSharpness
    )
    TiebaHaptics.startContinuousPlayer(playerId: TiebaFeedRowHapticIds.likeCharge)
  }

  private func endLikeCharge() {
    TiebaHaptics.stopContinuousPlayer(playerId: TiebaFeedRowHapticIds.likeCharge)
  }

  /// 实时触觉档位 → 强度缩放；nil = 该效果已关闭（off），默认适中（0.8）。
  /// 档位表与 TiebaSceneHaptics.realtimeScale 一致（那边只暴露 imageLiftPop）。
  private func likeChargeScale() -> Double? {
    guard let raw = TiebaPreferenceSnapshot.string("hapticsRealtimeStyles"),
          let data = raw.data(using: .utf8),
          let table = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { return 0.8 }
    switch table[TiebaFeedRowHapticIds.likeCharge] as? String {
    case "off": return nil
    case "light": return 0.55
    case "strong": return 1
    default: return 0.8
    }
  }

  /// 点赞 pop：1→1.35（damping 12 / stiffness 380 / mass 0.6）→ 1（MOMENTUM）。
  /// Reduce Motion 直接跳过（RN LikeButton 的 reduceMotion 分支同语义）。
  private func playLikePop() {
    guard !UIAccessibility.isReduceMotionEnabled, let layer = likeIconPopLayer else { return }
    tiebaPlaySpring(
      on: layer,
      host: self,
      property: .scale,
      from: 1,
      to: 1.35,
      spring: TiebaFeedRowMotion.likePop,
      key: "tieba.likePop"
    ) { [weak self] in
      self?.springLikeIcon(to: 1, key: "tieba.likePopSettle")
    }
  }

  /// 用 MOMENTUM 弹簧把 heart 拉回原尺寸（打断在途 pop 时从呈现值出发）。
  private func springLikeIcon(to value: CGFloat, key: String) {
    guard let layer = likeIconPopLayer else { return }
    tiebaPlaySpring(
      on: layer,
      host: self,
      property: .scale,
      from: TiebaAnimatedProperty.scale.current(of: layer),
      to: value,
      spring: TiebaFeedRowMotion.momentum,
      key: key
    )
  }

  /// 计数跳动（RN numPop）：计数文案变化时 1→1.28→1（damping 11 / stiffness 320
  /// / mass 0.5，回落用 MOMENTUM）。计数由 JS 的权威模型驱动，原生只在变化时补动画；
  /// Reduce Motion 直接跳过（RN 同判据）。
  func playLikeCountBump() {
    guard !UIAccessibility.isReduceMotionEnabled, let layer = likeCountPopLayer else { return }
    tiebaPlaySpring(
      on: layer,
      host: self,
      property: .scale,
      from: 1,
      to: 1.28,
      spring: TiebaFeedRowMotion.countBump,
      key: "tieba.countBump"
    ) { [weak self] in
      guard let self, let layer = self.likeCountPopLayer else { return }
      tiebaPlaySpring(
        on: layer,
        host: self,
        property: .scale,
        from: 1.28,
        to: 1,
        spring: TiebaFeedRowMotion.momentum,
        key: "tieba.countBumpSettle"
      )
    }
  }
}

// MARK: - 卡片长按菜单（分享帖子 / 复制帖子内容 / 不感兴趣 / 屏蔽作者）

/// 长按卡片 → 系统上下文菜单：卡片本身被 lift 凸显、菜单在下方。
/// 与「长按图片」（TiebaFeedRowMediaItemView 同一套系统机制）分工：图片格上的
/// 长按仍归图片菜单（画布在命中链之外），卡片文字/空白上的长按归本菜单。
extension TiebaFeedRowView: UIContextMenuInteractionDelegate {
  public func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    configurationForMenuAtLocation location: CGPoint
  ) -> UIContextMenuConfiguration? {
    guard let model, model.showsCardContextMenu, !model.isTopBanner,
          let identity = cardMenuIdentity, bounds.width > 1 else { return nil }
    // [采用] 惯性滚动中长按一律不成立（图片/帖子行同一守卫，见 TiebaDecelerationGuard）。
    // 宿主取 window：列表的滚动视图在行视图**之上**，而该守卫只向下递归 —— 传行视图
    // 或画布都探不到集合视图，传 window（点的坐标一并换算到 window）才真的生效。
    if let window = self.window,
       !TiebaDecelerationGuard.shouldAllowLongPress(at: convert(location, to: window), in: window) {
      return nil
    }
    let actionProvider: UIContextMenuActionProvider = { [weak self] _ in
      // 手势到菜单呈现之间行被换掉 → 整套菜单作废（菜单项属于另一张帖子）。
      guard let self, self.cardMenuIdentity == identity else { return nil }
      let actions: [UIAction] = [
        UIAction(title: "分享帖子", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
          self?.emitCardMenuAction("share", identity: identity)
        },
        UIAction(title: "复制帖子内容", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
          self?.emitCardMenuAction("copy-content", identity: identity)
        },
        UIAction(title: "不感兴趣", image: UIImage(systemName: "hand.thumbsdown")) { [weak self] _ in
          self?.emitCardMenuAction("dislike", identity: identity)
        },
        UIAction(title: "屏蔽作者", image: UIImage(systemName: "person.crop.circle.badge.xmark")) { [weak self] _ in
          self?.emitCardMenuAction("block", identity: identity)
        },
      ]
      return UIMenu(children: actions)
    }
    return UIContextMenuConfiguration(
      identifier: nil,
      previewProvider: nil,
      actionProvider: actionProvider
    )
  }

  /// 升起锚点 = **整张卡片**（cardView）：卡片区域 + 圆角（Radius.card=20，与
  /// cardView.layer 同源）。方法名一个字都不能简写/错位（写成 previewForHighlighting
  /// 这类"几乎匹配"的名字只编译告警、系统永不调用，锚点静默失效）；新旧两个协议名
  /// 都给，两个入口落到同一份实现 —— 与图片/帖子行的既有防御同款。
  private func tiebaCardHighlightPreview() -> UITargetedPreview? {
    guard cardView.tiebaIsOnScreen, cardView.bounds.width > 1 else { return nil }
    let parameters = UIPreviewParameters()
    parameters.visiblePath = UIBezierPath(
      roundedRect: cardView.bounds,
      cornerRadius: cardView.layer.cornerRadius
    )
    // 卡片四角是透明的：不显式给 clear，系统会给 lift 出来的预览垫一层白底。
    parameters.backgroundColor = .clear
    return UITargetedPreview(view: cardView, parameters: parameters)
  }

  public func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    configuration: UIContextMenuConfiguration,
    highlightPreviewForItemWithIdentifier identifier: any NSCopying
  ) -> UITargetedPreview? {
    tiebaCardHighlightPreview()
  }

  /// 收起不飞回（与图片菜单一致：iOS 26+ 飞回路径留白风险）。
  public func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    configuration: UIContextMenuConfiguration,
    dismissalPreviewForItemWithIdentifier identifier: any NSCopying
  ) -> UITargetedPreview? {
    nil
  }

  /// （旧协议名，见上：与 identifier 形态同一份实现。）
  public func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    previewForHighlightingMenuWithConfiguration configuration: UIContextMenuConfiguration
  ) -> UITargetedPreview? {
    tiebaCardHighlightPreview()
  }

  public func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    previewForDismissingMenuWithConfiguration configuration: UIContextMenuConfiguration
  ) -> UITargetedPreview? {
    nil
  }

  /// 菜单升起瞬间的触觉：与长按图片同一个「升起」瞬态（长按卡片不再是静默的）。
  public func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    willDisplayMenuFor configuration: UIContextMenuConfiguration,
    animator: UIContextMenuInteractionAnimating?
  ) {
    TiebaSceneHaptics.playImageLift()
  }
}
