import UIKit

/// 可选中的自撑高文本（原 RN `<Text selectable>`）。
///
/// 系统实现就是只读 `UITextView`：`isEditable = false` 关编辑、`isSelectable = true`
/// 给系统选择菜单（长按选词/全选/拷贝），`isScrollEnabled = false` 让高度随内容长。
/// 不手写选择逻辑——那正是要避免的重造。
final class TiebaSelectableLabel: UITextView {
  private var measuredWidth: CGFloat = 0

  init(font: UIFont, color: UIColor, alignment: NSTextAlignment = .natural) {
    super.init(frame: .zero, textContainer: nil)
    self.font = font
    textColor = color
    textAlignment = alignment
    isEditable = false
    isSelectable = true
    isScrollEnabled = false
    backgroundColor = .clear
    textContainerInset = .zero
    textContainer.lineFragmentPadding = 0
    adjustsFontForContentSizeCategory = true
    setContentCompressionResistancePriority(.required, for: .vertical)
    // 宽度由容器（栈/单元格）给，别拿文字固有宽度去撑布局。
    setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    delegate = self
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// 宽度变了要手动作废一次：UITextView 不会因 frame 宽度变化自动重报高度，
  /// 换行行数变了还按旧高度布局 → 截断/吞行。
  override func layoutSubviews() {
    super.layoutSubviews()
    guard bounds.width != measuredWidth else { return }
    measuredWidth = bounds.width
    invalidateIntrinsicContentSize()
  }
}

extension TiebaSelectableLabel: UITextViewDelegate {
  func textView(
    _ textView: UITextView,
    editMenuForTextIn range: NSRange,
    suggestedActions: [UIMenuElement]
  ) -> UIMenu? {
    textView.tiebaSelectableEditMenu(suggestedActions: suggestedActions)
  }

  /// [接线] 本类是自带 delegate 的只读文本框（见 init），链接点击同样要过伪装链接判定：
  /// 显示文字与真实地址不一致时先弹确认框，一致才交给系统默认动作。
  func textView(
    _ textView: UITextView,
    primaryActionFor textItem: UITextItem,
    defaultAction: UIAction
  ) -> UIAction? {
    guard case .link(let url) = textItem.content else { return defaultAction }
    let fullText = textView.attributedText?.string ?? ""
    let range = textItem.range
    let length = (fullText as NSString).length
    guard range.location != NSNotFound, NSMaxRange(range) <= length else { return defaultAction }
    let displayText = (fullText as NSString).substring(with: range)
    guard let concealed = TiebaTextLinkSafety.concealedAddress(
      url: url.absoluteString,
      displayText: displayText,
      fullText: fullText
    ) else { return defaultAction }
    return UIAction(title: defaultAction.title) { _ in
      TiebaTextLinkSafety.confirm(address: concealed, presenter: TiebaTopViewController.find()) {
        UIApplication.shared.open(url)
      }
    }
  }
}

// MARK: - 链接点击安全（伪装链接 / 同形字）

/// 文本里点开链接前的安全检查，两处共用：本文件的 TiebaSelectableLabel 与
/// UI/ListKit/TiebaPostRowView 的正文链接。
///
/// 为什么必须有：`tiebaDoesUrlMatchText`（Core/TiebaUrlEscaping.swift）此前在全仓 0 调用。
/// 它拦的是「显示文字与真实地址不一致」的链接，典型攻击是真实 URL 里塞 U+202E
/// （RIGHT-TO-LEFT OVERRIDE）双向覆盖字符：真实地址 `.../\u{202E}gpj.exe` 在屏幕上显示成
/// `.../exe.jpg`，用户看到的和点到的不是一个东西。贴吧正文几乎全是外链，这条必须接。
enum TiebaTextLinkSafety {
  /// 返回 nil = 直接放行；返回非 nil = 需要用户确认的真实地址（已缩短、已去控制符）。
  static func concealedAddress(url: String, displayText: String, fullText: String) -> String? {
    // 归一化后再比对：两边都过一遍 tiebaUrlEncodedStringFromString（先解百分号编码、再按 URL
    // 字符集编码），这样「中文路径 / 含空格」的链接不会因为编码差异被误判成伪装
    //（显示文字本来就是地址时，两边归一化后相等）。
    let normalizedUrl = tiebaUrlEncodedStringFromString(url)
    let normalizedText = tiebaUrlEncodedStringFromString(displayText)
    var concealed = !tiebaDoesUrlMatchText(url: normalizedUrl, text: normalizedText, fullText: fullText)
    // 贴吧正文里的裸域名显示（"www.x.com"）与补过协议的地址是同一个目标：识别端用 tiebaExplicitUrl
    // 补了协议、显示文字没有 —— 不先补齐会把最常见的外链全判成伪装。
    // 但这条豁免**绝不能盖掉 U+202E**：那种攻击恰恰是「显示文字 = 真实地址」而地址里藏了双向覆盖符，
    // 两边补齐后当然相等。所以只在整段文本没有双向控制符时才允许豁免。
    let hasBidiOverride = fullText.range(of: "\u{202e}") != nil
    if concealed, !hasBidiOverride, tiebaExplicitUrl(normalizedText) == tiebaExplicitUrl(normalizedUrl) {
      concealed = false
    }
    // 再叠一层同形字判定（host 里拉丁字母与非拉丁字符混排）：tiebaParseUrl 内部已豁免白名单与 tel:。
    let parsed = tiebaParseUrl(url: url, wasConcealed: concealed)
    concealed = parsed.concealed
    return concealed ? parsed.string : nil
  }

  /// 弹「链接可能被伪装」确认框：把真实地址摆给用户看，点了「继续打开」才真的打开。
  @MainActor
  static func confirm(
    address: String,
    presenter: UIViewController?,
    open: @MainActor @escaping () -> Void
  ) {
    let clean = address.replacingOccurrences(of: "\u{202E}", with: "")
    let alert = UIAlertController(
      title: "链接可能被伪装",
      message: "显示的文字与真实地址不一致。\n真实地址：\n\(clean)",
      preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(title: "取消", style: .cancel))
    alert.addAction(UIAlertAction(title: "继续打开", style: .default) { _ in open() })
    guard let presenter else {
      // 找不到宿主时不静默吞掉链接：直接打开，行为与旧路径一致（旧路径本来也没有这一层确认）。
      open()
      return
    }
    presenter.present(alert, animated: true)
  }
}

// MARK: - 只读文本的「全选」

extension UITextView {
  /// 只读（isEditable = false）文本的系统长按菜单不一定给「全选」——iOS 27 上实测没有
  /// （用户报"长按文字没有全选的选项"）。这里补一条；菜单里已有就不重复加（系统那条的
  /// 标题随语言走，中英都认）。
  func tiebaSelectableEditMenu(suggestedActions: [UIMenuElement]) -> UIMenu {
    let titles = Set(suggestedActions.compactMap { ($0 as? UIAction)?.title })
    guard !titles.contains("全选"), !titles.contains("Select All") else {
      return UIMenu(children: suggestedActions)
    }
    let selectAll = UIAction(title: "全选") { [weak self] _ in
      self?.selectAll(nil)
    }
    return UIMenu(children: suggestedActions + [selectAll])
  }
}
