import UIKit

extension TiebaFeedRowView {
  // MARK: - VoiceOver container

  /// 行不再是单个 staticText：meta / 标题 / 摘要分别成停靠点，标题作为打开帖子的 link，
  /// actionItems 与更多菜单各有独立按钮元素。frames 直接取已测量 plan，滚动中零重新排版。
  func updateAccessibilityElements() {
    // VoiceOver 关闭时 UIKit 不读取这棵树；不要为每次布局重建元素和闭包。
    guard UIAccessibility.isVoiceOverRunning else {
      accessibilityElements = nil
      return
    }
    guard let model else {
      accessibilityElements = nil
      return
    }
    if model.isTopBanner {
      let label = model.bannerText.isEmpty ? "置顶帖子" : model.bannerText
      let frame = model.plan.cardFrame
      let element: TiebaFeedRowAccessibilityElement?
      if model.threadId.isEmpty {
        element = makeAccessibilityElement(label: label, frame: frame, traits: .staticText)
      } else {
        element = makeTapAccessibilityElement(
          label: label, frame: frame, traits: .link, hint: "打开帖子")
      }
      accessibilityElements = element.map { [$0] as [Any] }
      return
    }

    let plan = model.plan
    var elements: [UIAccessibilityElement] = []
    let metaText = accessibilityMetaText(for: model)
    let metaFrame = unionFrame([plan.displayNameFrame, plan.metaFrame, plan.ipFrame])
    if let metaFrame, metaText.isEmpty == false,
      let element = makeStaticAccessibilityElement(label: metaText, frame: metaFrame)
    {
      elements.append(element)
    }
    if model.titleText.isEmpty == false,
      let frame = plan.titleFrame,
      let element = makeTapAccessibilityElement(
        label: model.titleText, frame: frame, traits: .link, hint: "打开帖子")
    {
      elements.append(element)
    }
    if model.abstractText.isEmpty == false, let frame = plan.abstractFrame {
      let element: TiebaFeedRowAccessibilityElement?
      if model.titleText.isEmpty {
        element = makeTapAccessibilityElement(
          label: model.abstractText, frame: frame, traits: .link, hint: "打开帖子")
      } else {
        element = makeStaticAccessibilityElement(label: model.abstractText, frame: frame)
      }
      if let element { elements.append(element) }
    }
    if model.titleText.isEmpty && model.abstractText.isEmpty,
      let element = makeTapAccessibilityElement(
        label: "打开帖子", frame: plan.cardFrame, traits: .link, hint: "打开帖子")
    {
      elements.append(element)
    }
    appendMediaAccessibilityElement(for: model, plan: plan, to: &elements)
    if let frame = plan.showMoreFrame, let element = makeTapAccessibilityElement(
      label: model.expanded ? "收起" : (model.showMoreText.isEmpty ? "显示更多" : model.showMoreText),
      frame: frame,
      traits: .button,
      hint: nil
    ) {
      elements.append(element)
    }
    if model.showsForumChip, let frame = plan.chipFrame,
      let element = makeTapAccessibilityElement(
        label: "\(model.forumName)吧", frame: frame, traits: .button, hint: "进入吧")
    {
      elements.append(element)
    }
    appendActionAccessibilityElements(for: model, plan: plan, to: &elements)
    if menuButton.isHidden == false,
      let frame = clippedAccessibilityFrame(menuButton.convert(menuButton.hitFrame, to: self)),
      let element = makeAccessibilityElement(label: "更多操作", frame: frame, traits: .button)
    {
      element.onActivate = { [weak self] in
        guard let self, self.menuButton.isHidden == false else { return false }
        self.menuButton.sendActions(for: .touchUpInside)
        return true
      }
      elements.append(element)
    }
    accessibilityElements = elements.isEmpty ? nil : elements as [Any]
  }

  private func makeStaticAccessibilityElement(
    label: String,
    frame: CGRect
  ) -> TiebaFeedRowAccessibilityElement? {
    makeAccessibilityElement(label: label, frame: frame, traits: .staticText)
  }

  private func makeTapAccessibilityElement(
    label: String,
    frame: CGRect,
    traits: UIAccessibilityTraits,
    hint: String?
  ) -> TiebaFeedRowAccessibilityElement? {
    guard let clipped = clippedAccessibilityFrame(frame),
      let element = makeAccessibilityElement(label: label, frame: clipped, traits: traits, hint: hint)
    else { return nil }
    let point = CGPoint(x: clipped.midX, y: clipped.midY)
    element.onActivate = { [weak self] in
      self?.forwardTapToHostCell(atRowPoint: point) ?? false
    }
    return element
  }

  private func makeAccessibilityElement(
    label: String,
    frame: CGRect,
    traits: UIAccessibilityTraits,
    hint: String? = nil
  ) -> TiebaFeedRowAccessibilityElement? {
    guard let clipped = clippedAccessibilityFrame(frame), label.isEmpty == false else { return nil }
    let element = TiebaFeedRowAccessibilityElement(accessibilityContainer: self)
    element.accessibilityLabel = label
    element.accessibilityFrameInContainerSpace = clipped
    element.accessibilityTraits = traits
    element.accessibilityHint = hint
    return element
  }

  private func clippedAccessibilityFrame(_ frame: CGRect?) -> CGRect? {
    guard let frame else { return nil }
    let clipped = frame.intersection(bounds)
    guard clipped.isNull == false, clipped.width > 0, clipped.height > 0 else { return nil }
    return clipped
  }

  private func optionalFrame(_ frame: CGRect) -> CGRect? {
    frame.width > 0 && frame.height > 0 ? frame : nil
  }

  private func unionFrame(_ frames: [CGRect?]) -> CGRect? {
    var result: CGRect?
    for frame in frames.compactMap({ $0 }) {
      result = result.map { $0.union(frame) } ?? frame
    }
    return result
  }

  private func appendMediaAccessibilityElement(
    for model: TiebaFeedRowModel,
    plan: TiebaFeedRowLayoutPlan,
    to elements: inout [UIAccessibilityElement]
  ) {
    guard model.showsMedia, let frame = plan.mediaFrame else { return }
    let count = model.media.count
    let label: String
    if model.showsVideoPoster {
      label = "视频"
    } else if count == 1 {
      label = "1 张图片"
    } else {
      label = "\(count) 张图片"
    }
    if let element = makeAccessibilityElement(label: label, frame: frame, traits: .image) {
      elements.append(element)
    }
  }

  private func appendActionAccessibilityElements(
    for model: TiebaFeedRowModel,
    plan: TiebaFeedRowLayoutPlan,
    to elements: inout [UIAccessibilityElement]
  ) {
    guard model.showsActions else { return }
    let count = min(plan.actionButtonFrames.count, min(actionItems.count, 3))
    for index in 0..<count where actionItems[index].isHidden == false {
      guard let element = makeTapAccessibilityElement(
        label: actionAccessibilityLabel(index: index, model: model),
        frame: plan.actionButtonFrames[index],
        traits: .button,
        hint: nil
      ) else { continue }
      elements.append(element)
    }
  }

  private func actionAccessibilityLabel(index: Int, model: TiebaFeedRowModel) -> String {
    switch index {
    case 0:
      return model.replyText.isEmpty ? "回复" : "回复，\(model.replyText)"
    case 1:
      return model.shareText.isEmpty ? "分享" : "分享，\(model.shareText)"
    case 2:
      let action = model.isLiked ? "取消点赞" : "点赞"
      return model.likeText.isEmpty ? action : "\(action)，\(model.likeText)"
    default:
      return "操作"
    }
  }

  private func accessibilityMetaText(for model: TiebaFeedRowModel) -> String {
    var parts: [String] = []
    if model.displayName.isEmpty == false { parts.append(model.displayName) }
    if let meta = model.metaAttributed?.string, meta.isEmpty == false {
      parts.append(meta)
    } else if let time = model.timeText, time.isEmpty == false {
      parts.append(time)
    }
    if let ip = model.ipText, ip.isEmpty == false { parts.append(ip) }
    return parts.joined(separator: "，")
  }

  /// 把 VoiceOver activation 回送到 cell 既有 tap 分发：不复制页面业务逻辑。
  private func forwardTapToHostCell(atRowPoint point: CGPoint) -> Bool {
    var ancestor: UIView? = superview
    while let view = ancestor {
      if let cell = view as? TiebaKindListFeedCell {
        guard let handler = cell.onTap else { return false }
        handler(convert(point, to: cell))
        return true
      }
      ancestor = view.superview
    }
    return false
  }
}
