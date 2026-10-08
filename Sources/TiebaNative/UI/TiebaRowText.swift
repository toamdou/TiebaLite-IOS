//  行内富文本的测量口径（高度、单行宽）。\n//  从 UI/ListKit/TiebaRowParser.swift 拆出：UI 层的通用文本件（TiebaSimpleText）也要用。

import UIKit

nonisolated enum TiebaRowText {
  /// 调用方保证在测量队列上；maxLines = 0 表示不限行数（NSTextContainer 语义）。
  static func measureHeight(_ attributed: NSAttributedString, width: CGFloat, maxLines: Int) -> CGFloat {
    measure(attributed, width: width, maxLines: maxLines).height
  }

  // ── 可复用 TextKit 栈 ──
  // 整页 prepare 逐行调 measure：信息流一行 2-3 处、一页 60+ 次；帖子页 400 楼
  // publish 数百次。每次新建 NSTextStorage+NSLayoutManager+NSTextContainer 的
  // 三件套分配与 layoutManager 冷启动是排版之外的纯开销（NSLayoutManager 属重
  // 对象）。测量恒在串行队列/后台 prepare 内执行（见 prepareFeedRowsBlocking 的
  // 契约），同一时刻只有一个调用方——按持锁换取单套栈复用即可，高度/截断判据
  // 不变。锁同时保护"递归进入 measure"（TextKit 回调不会再进 measure，防御）。
  private static let measureStackLock = NSLock()
  nonisolated(unsafe) private static var measureStorage: NSTextStorage?
  nonisolated(unsafe) private static var measureLayoutManager: NSLayoutManager?
  nonisolated(unsafe) private static var measureContainer: NSTextContainer?

  /// 高度（ceil 后的块高）+ **未取整**的 usedRect 高（阶段 0 的绘制期自然高）+
  /// 是否真被 maxLines 截断（同一趟布局里判：截断时可见字形范围盖不到
  /// 末字形）。三个值同出一趟布局、零额外排版。折叠判据必须用"真截断"，
  /// 不能只比字数。
  static func measure(
    _ attributed: NSAttributedString,
    width: CGFloat,
    maxLines: Int
  ) -> (height: CGFloat, exactHeight: CGFloat, truncated: Bool) {
    guard attributed.length > 0, width > 0 else { return (0, 0, false) }
    measureStackLock.lock()
    defer { measureStackLock.unlock() }
    let storage: NSTextStorage
    let layoutManager: NSLayoutManager
    let container: NSTextContainer
    if let reusableStorage = measureStorage,
      let reusableLayout = measureLayoutManager,
      let reusableContainer = measureContainer
    {
      storage = reusableStorage
      layoutManager = reusableLayout
      container = reusableContainer
    } else {
      storage = NSTextStorage(attributedString: attributed)
      layoutManager = NSLayoutManager()
      container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
      storage.addLayoutManager(layoutManager)
      layoutManager.addTextContainer(container)
      measureStorage = storage
      measureLayoutManager = layoutManager
      measureContainer = container
    }
    storage.setAttributedString(attributed)
    container.size = CGSize(width: width, height: .greatestFiniteMagnitude)
    container.maximumNumberOfLines = maxLines
    container.lineBreakMode = .byTruncatingTail
    layoutManager.ensureLayout(for: container)
    // 阶段 0：**未取整**的 usedRect 高。绘制期旧实现那一趟 boundingRect 量出来的就是
    // 它；存下来供垂直居中直接取用 ⇒ 绘制期不再排版第二遍。这里绝不能 ceil：frame
    // 高是 ceil 过的，旧的居中偏移 (frame.height - used)/2 ∈ [0, 0.5) 全靠它复刻
    //（换成 ceil 值会让偏移变 0，整段文字上移最多 0.5pt，不是逐像素一致）。
    let exactHeight = layoutManager.usedRect(for: container).height
    // ceil：避免 22.0001 → 22 后 UILabel 最后一行被裁掉半像素。
    let height = ceil(exactHeight)
    // 截断判据（截断态才给「加载更多」）——**不能**比 glyphRange(for:)：容器把整段字形都算作
    // 「在容器里」，限行只体现在排版出的**行数**上（实测：216 字限 4 行时 glyphRange 仍报
    // 216/216）。这里问 NSLayoutManager 本人：最后一行有没有被截掉的字形。
    //（改前那一版恒为 false ⇒ 长文永远不长出展开入口，用户 2026-10-06 报「没有加载更多按钮」。）
    var truncated = false
    if maxLines > 0, layoutManager.numberOfGlyphs > 0 {
      var lastLineStart = 0
      layoutManager.enumerateLineFragments(
        forGlyphRange: NSRange(location: 0, length: layoutManager.numberOfGlyphs)
      ) { _, _, _, range, _ in
        lastLineStart = range.location
      }
      truncated = layoutManager.truncatedGlyphRange(
        inLineFragmentForGlyphAt: lastLineStart
      ).length > 0
    }
    return (height, exactHeight, truncated)
  }

  /// 单行文本宽（徽章内联定位用；不改行高）。
  static func singleLineWidth(_ text: String, font: UIFont) -> CGFloat {
    guard !text.isEmpty else { return 0 }
    return ceil((text as NSString).size(withAttributes: [.font: font]).width)
  }
}
