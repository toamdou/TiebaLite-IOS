import ExpoModulesCore
import UIKit

public final class TiebaRichTextView: ExpoView, UITextViewDelegate {
  private let textView = UITextView()
  private let emoticonCache = NSCache<NSString, UIImage>()
  /// 在途的表情图下载任务（keyed by src，仅主线程读写）：滚动出屏、视图
  /// 销毁时取消未完成的下载（见 deinit），完成的在回调里移出。
  private var emoticonTasks: [String: URLSessionDataTask] = [:]
  /// 最近一次构建的富文本。表情图异步下载完成后重新赋值触发 TextKit
  /// 全量重排（attachment.image 变更 + setNeedsDisplay 不足以刷新布局缓存，
  /// 灰色占位会残留）。
  private var currentAttributed: NSAttributedString?

  // ⚠️ 必须立即重建：dirty 延迟模式（layoutSubviews 才重建）在列表复用/首帧
  // props 先于布局到达时会永远不触发 → 正文空白。楼中楼是 RN Text 能显示、
  // 正文/回复走本组件不显示，即此因。因此 6 个 prop 的 didSet 统一走
  // scheduleRebuild()：合并到下一 runloop 单次重建（同帧连续赋值只重建一次，
  // 消除全量 TextKit 重排的事件风暴），且 async 块在当前 runloop 收尾时执行、
  // 先于下一帧布局——"布局前必重建"语义不变。
  var contentWidth: CGFloat = 0 {
    didSet { scheduleRebuild() }
  }

  var fontSize: CGFloat = 15 {
    didSet {
      // 0 值防御：JS 偶发下发 0（未设值时），系统字体 0pt 会坍缩 TextKit 行高
      if fontSize <= 0 { fontSize = 15 }
      scheduleRebuild()
    }
  }

  var lineHeight: CGFloat = 22 {
    didSet {
      if lineHeight <= 0 { lineHeight = 22 }
      scheduleRebuild()
    }
  }

  var textColor: UIColor = .label {
    didSet { scheduleRebuild() }
  }

  var linkColor: UIColor = .systemBlue {
    didSet { scheduleRebuild() }
  }

  var runs: [[String: Any]] = [] {
    didSet { scheduleRebuild() }
  }

  let onLinkPress = EventDispatcher()
  let onUserPress = EventDispatcher()
  let onTopicPress = EventDispatcher()
  /// Fabric 布局引擎不调用 intrinsicContentSize → 自定义 view 高度恒为 0。
  /// 每次重建后把测量高度发给 JS，JS 设置显式 height（Fabric 尊重显式尺寸）。
  let onContentHeightChange = EventDispatcher()

  public required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    textView.isEditable = false
    textView.isScrollEnabled = false
    textView.isSelectable = true
    textView.backgroundColor = .clear
    textView.textContainerInset = .zero
    textView.textContainer.lineFragmentPadding = 0
    textView.textContainer.widthTracksTextView = true
    textView.delegate = self
    textView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(textView)
    NSLayoutConstraint.activate([
      textView.leadingAnchor.constraint(equalTo: leadingAnchor),
      textView.trailingAnchor.constraint(equalTo: trailingAnchor),
      textView.topAnchor.constraint(equalTo: topAnchor),
      textView.bottomAnchor.constraint(equalTo: bottomAnchor)
    ])
  }

  deinit {
    // 滚动出屏/复用池回收：取消在途表情下载，避免回调打到已销毁视图。
    for task in emoticonTasks.values {
      task.cancel()
    }
  }

  public override var intrinsicContentSize: CGSize {
    let width = contentWidth > 0 ? contentWidth : bounds.width
    return textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
  }

  public override func layoutSubviews() {
    super.layoutSubviews()
    textView.frame = bounds
    invalidateIntrinsicContentSize()
  }

  public func textView(
    _ textView: UITextView,
    shouldInteractWith url: URL,
    in characterRange: NSRange,
    interaction: UITextItemInteraction
  ) -> Bool {
    handle(url)
    return false
  }

  // 系统文本编辑菜单（iOS 16+）：确保「全选」在场。iOS 26/27 的紧凑菜单在
  // 只读 UITextView 上偶发不渲染 Select All（8-25 真机「选择文字后无全选」），
  // 这里显式包裹，在系统建议项之外补一个「全选」动作（幂等：已有则不加）。
  @available(iOS 16.0, *)
  public func textView(
    _ textView: UITextView,
    editMenuForTextIn range: NSRange,
    suggestedActions: [UIMenuElement]
  ) -> UIMenu? {
    var elements = suggestedActions
    let hasSelectAll = elements.contains { element in
      guard let action = element as? UIAction else { return false }
      let title = action.title
      return (title == "全选") || (title == "Select All") || title.contains("全选")
    }
    if !hasSelectAll {
      let selectAll = UIAction(title: "全选") { [weak textView] _ in
        textView?.selectAll(nil)
      }
      elements.insert(selectAll, at: 0)
    }
    return UIMenu(children: elements)
  }

  private func handle(_ url: URL) {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
    let queryItem = { (name: String) -> String in
      components.queryItems?.first(where: { $0.name == name })?.value ?? ""
    }
    switch components.host {
    case "link":
      onLinkPress(["url": queryItem("url")])
    case "user":
      onUserPress(["uid": queryItem("uid")])
    case "topic":
      onTopicPress(["topicId": queryItem("id"), "topicName": queryItem("name")])
    default:
      // 真实外链（host 为实际域名）：原实现 break 导致帖子内链接全部不可点，
      // 交回 JS 统一处理（utils/linkOpener 决定站内跳转或开 WebView）。
      onLinkPress(["url": url.absoluteString])
    }
  }

  /// 重建调度去重标志：同一 runloop 内多个 prop didSet 只触发一次 rebuild。
  private var rebuildScheduled = false

  private func scheduleRebuild() {
    guard !rebuildScheduled else { return }
    rebuildScheduled = true
    // props 在主线程赋值；async 块在当前 runloop 收尾时执行，先于下一帧
    // 布局/绘制（布局前必重建）。弱引用：调度后视图已销毁则跳过。
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.rebuildScheduled = false
      self.rebuild()
    }
  }

  private func rebuild() {
    let attributed = NSMutableAttributedString()
    let baseFont = UIFont.systemFont(ofSize: fontSize)
    let paragraph = NSMutableParagraphStyle()
    paragraph.minimumLineHeight = lineHeight
    paragraph.maximumLineHeight = lineHeight
    let base: [NSAttributedString.Key: Any] = [
      .font: baseFont,
      .foregroundColor: textColor,
      .paragraphStyle: paragraph
    ]

    for run in runs {
      let kind = run["kind"] as? String ?? "text"
      let weight = fontWeight(from: run["fontWeight"] as? String)
      let attrs = attributes(base: base, weight: weight)
      switch kind {
      case "linebreak":
        attributed.append(NSAttributedString(string: "\n", attributes: attrs))
      case "emoji":
        attributed.append(NSAttributedString(string: run["text"] as? String ?? "", attributes: attrs))
      case "emoticon":
        appendEmoticon(
          attributed,
          src: run["src"] as? String ?? "",
          base: base
        )
      case "link":
        let text = run["text"] as? String ?? ""
        let urlString = run["url"] as? String ?? ""
        appendLink(attributed, text: text, urlString: urlString, attributes: attrs)
      case "at":
        let text = run["text"] as? String ?? ""
        let uid = run["uid"] as? String ?? ""
        // @ 提及不加下划线（可点、保持主题色，去掉视觉噪音）；外链/topic 保留下划线。
        appendLink(attributed, text: "@\(text)", urlString: "tieba-native://user?uid=\(uid)", attributes: attrs, underlined: false)
      case "topic":
        let text = run["text"] as? String ?? ""
        let topicId = run["topicId"] as? String ?? ""
        let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        appendLink(attributed, text: "#\(text)#", urlString: "tieba-native://topic?id=\(topicId)&name=\(encoded)", attributes: attrs)
      default:
        attributed.append(NSAttributedString(string: run["text"] as? String ?? "", attributes: attrs))
      }
    }

    textView.attributedText = attributed
    currentAttributed = attributed
    invalidateIntrinsicContentSize()
    // Fabric 布局引擎不调用 intrinsicContentSize：把测量高度发给 JS 设显式
    // height，否则正文区高度恒为 0 → 文字不可见。
    let width = contentWidth > 0 ? contentWidth : bounds.width
    if width > 0 {
      // 先设 textView 宽度再 sizeThatFits：不设的话 UITextView 按当前 frame
      // （首帧可能 0 宽）测量，长文会被当成一行 → 高度只有单行。
      textView.frame = CGRect(x: 0, y: 0, width: width, height: 0)
      let height = textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
      onContentHeightChange(["height": height, "width": width])
    }
  }

  /// Map the optional `fontWeight` run key (e.g. "500" / "bold") to a
  /// UIFont.Weight. Missing or unknown values fall back to .regular so
  /// existing callers (contentToRichTextRuns, subposts) render unchanged.
  private func fontWeight(from value: String?) -> UIFont.Weight {
    switch value {
    case "300": return .light
    case "400": return .regular
    case "500": return .medium
    case "600": return .semibold
    case "700", "bold": return .bold
    case "800": return .heavy
    default: return .regular
    }
  }

  /// The base attribute set with the given font weight swapped in, keeping
  /// point size, color and paragraph style intact.
  private func attributes(
    base: [NSAttributedString.Key: Any],
    weight: UIFont.Weight
  ) -> [NSAttributedString.Key: Any] {
    var attrs = base
    let currentFont = (base[.font] as? UIFont) ?? UIFont.systemFont(ofSize: fontSize)
    attrs[.font] = UIFont.systemFont(ofSize: currentFont.pointSize, weight: weight)
    return attrs
  }

  private func appendLink(
    _ attributed: NSMutableAttributedString,
    text: String,
    urlString: String,
    attributes: [NSAttributedString.Key: Any],
    underlined: Bool = true
  ) {
    var attrs = attributes
    attrs[.foregroundColor] = linkColor
    if underlined {
      attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
    }
    if let url = makeLinkURL(from: urlString) {
      attrs[.link] = url
    }
    attributed.append(NSAttributedString(string: text, attributes: attrs))
  }

  /// URL(string:) rejects raw non-ASCII characters (e.g. Chinese text in a
  /// post's external link), so those runs never got a `.link` attribute and
  /// taps did nothing. Percent-encode the string as a fallback so the run
  /// becomes tappable; the host-dispatch logic in `handle` is unchanged.
  private func makeLinkURL(from urlString: String) -> URL? {
    if let url = URL(string: urlString) {
      return url
    }
    guard
      let encoded = urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
    else {
      return nil
    }
    return URL(string: encoded)
  }

  private func appendEmoticon(
    _ attributed: NSMutableAttributedString,
    src: String,
    base: [NSAttributedString.Key: Any]
  ) {
    let attachment = NSTextAttachment()
    attachment.bounds = CGRect(x: 0, y: -3, width: emoticonSize, height: emoticonSize)
    if let cached = emoticonCache.object(forKey: src as NSString) {
      attachment.image = cached
    } else {
      attachment.image = placeholderImage()
      loadEmoticon(src, attachment: attachment)
    }
    attributed.append(NSAttributedString(attachment: attachment))
    attributed.append(NSAttributedString(string: " ", attributes: base))
  }

  private var emoticonSize: CGFloat {
    min(fontSize + 3, max(16, lineHeight - 4))
  }

  private func placeholderImage() -> UIImage {
    let size = CGSize(width: emoticonSize, height: emoticonSize)
    let renderer = UIGraphicsImageRenderer(size: size)
    return renderer.image { context in
      UIColor.systemGray5.setFill()
      context.fill(CGRect(origin: .zero, size: size))
    }
  }

  private func loadEmoticon(_ src: String, attachment: NSTextAttachment) {
    guard let url = URL(string: src) else { return }
    var request = URLRequest(url: url)
    request.timeoutInterval = 15
    request.setValue("https://tieba.baidu.com/", forHTTPHeaderField: "Referer")
    let task = URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
      guard
        let self,
        let data,
        let image = UIImage(data: data)
      else {
        return
      }
      DispatchQueue.main.async {
        self.emoticonTasks.removeValue(forKey: src)
        self.emoticonCache.setObject(image, forKey: src as NSString)
        attachment.image = image
        // 重新赋值 attributedText 强制 TextKit 全量重排：
        // attachment.image 变更 + setNeedsDisplay 不会使布局缓存失效，
        // 灰色占位将永远残留（表情"不显示"的根因）。
        if let attributed = self.currentAttributed {
          self.textView.attributedText = attributed
        } else {
          self.textView.setNeedsDisplay()
        }
      }
    }
    // 在途下载跟踪（keyed by src）：视图销毁（滚动出屏）时取消未完成下载。
    // 仅主线程读写（赋值在 rebuild、删除在 async 主线程块内）。
    emoticonTasks[src] = task
    task.resume()
  }
}
