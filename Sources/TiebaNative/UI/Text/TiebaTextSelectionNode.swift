// 移植自上游 submodules/TextSelectionNode/Sources/TextSelectionNode.swift（上游 850 行）。
//
// 本文件 = 「上游式文本选择」的显示与交互本体：长按选词 → 逐行选择高亮（跨行也连续）→ 两个自绘手柄
// → 拖动改选 → 弹出菜单（拷贝/查询/分享/翻译/引用/全选）。系统 UITextView 给不出这套显示效果
// （逐行高亮带 + 手柄 + 选择期间压掉列表滚动），这正是要学的部分。
//
// 改动清单（裁依赖 + Swift 6；算法逐行照搬）：
//   1) 类型名加 Tieba 前缀；ASDisplayNode 外壳换 UIView（addSubnode → addSubview、
//      removeFromSupernode → removeFromSuperview、ASImageNode → UIImageView）。
//      上游 didLoad() 里的接线搬到 init：UIView 没有 didLoad 生命周期。
//      上游为 ASDisplayNode 准备的 TextSelectionNodeView/hitTestImpl 间接层随之删除 ——
//      本类自己就是 UIView，直接 override hitTest（行为等价，少一层）。
//   2) PresentationStrings（本地化文案）→ 参数注入 TiebaTextSelectionStrings（默认中文）。
//   3) ContextMenuController / ContextMenuAction / ViewController（ContextUI + Display 依赖）→ 删除：
//      菜单只组装 TiebaTextSelectionMenuItem（标题 + 动作），由调用方 presentMenu/dismissMenu 闭包决定外观。
//      用什么 UI 弹菜单是调用方的事，本件不掺和。
//   4) DisplayLinkAnimator（Display 依赖）→ 文件私有 TiebaTextSelectionDisplayLinkAnimator（CADisplayLink）。
//   5) generateImage（Display 依赖）→ 文件私有等价实现（UIGraphicsImageRenderer，UIKit 坐标系同约定）。
//   6) LinkHighlightingNode → 复用本仓 TiebaLinkHighlightingNode；CALayer 动画工厂复用
//      UI/Components/TiebaCAAnimationUtils.swift。都不重写。
//   7) 上游的「原文属性」（OriginalTextAttribute/originalTextAttributeKey）在本仓不存在：
//      改为本文件公开的 TiebaTextOriginalAttribute 协议 + tiebaTextOriginalAttributeKey；映射算法照搬。
//   8) 上游的 node/view 二选一 → 值语义 TiebaTextSelectionTarget（视图 + 布局提供者）：
//      两条路径在本仓都归结为 TiebaTextNodeLayout 的两个公开方法。
//
// 【本轮不接线】将来的接线点与验收标准见文件末尾。
//
// 依赖（只读复用，未改）：UI/Text/TiebaLinkHighlightingNode.swift、UI/Components/TiebaCAAnimationUtils.swift。

import Foundation
import UIKit

// MARK: - 图像工具（上游 Display/GenerateImage.swift 的两个入口，文件私有等价实现）

/// 上游 generateImage(size:rotatedContext:)：rotatedContext 拿到 UIKit 坐标系（y 向下）的 ctx。
/// verticalMirror 复刻上游的**另一个**入口 generateImage(size:contextGenerator:) —— 它走
/// DrawingContext.withFlippedContext（原始 CGBitmapContext，y 向上），同一段绘制命令画出来的是
/// 一张**上下镜像**的图。UIKit 渲染器的 ctx 是 y 向下，这里翻一次 CTM 即等价。
private func tiebaTextSelectionGenerateImage(_ size: CGSize, opaque: Bool = false, scale: CGFloat? = nil, verticalMirror: Bool = false, rotatedContext: (CGSize, CGContext) -> Void) -> UIImage? {
    if size.width.isZero || size.height.isZero {
        return nil
    }
    let format = UIGraphicsImageRendererFormat.preferred()
    format.opaque = opaque
    if let scale, scale > 0.0 {
        format.scale = scale
    }
    return UIGraphicsImageRenderer(size: size, format: format).image { rendererContext in
        if verticalMirror {
            let context = rendererContext.cgContext
            context.translateBy(x: 0.0, y: size.height)
            context.scaleBy(x: 1.0, y: -1.0)
        }
        rotatedContext(size, rendererContext.cgContext)
    }
}

/// 手柄图：一根 2pt 竖线 + 一个 12pt 大圆 + 一个 2pt 小圆点（上游形状逐行照搬），再做九宫格拉伸。
/// inverted = 右手柄（大圆在下方）。**这条分支上游走的是 y 向上的上下文**（mirror），
/// 九宫格的"拉伸行"（topCap 之后那一行）必须正好落在 2pt 竖线上；少了镜像，那一行会落在
/// 12pt 大圆里 → 尾部手柄的杆被横向拉成 ≈10.3pt 的粗带（头部 2.00pt，用户报"尾部太粗"，见 43 号文档）。
private func tiebaTextSelectionGenerateKnobImage(color: UIColor, diameter: CGFloat, inverted: Bool = false) -> UIImage? {
    let f: (CGSize, CGContext) -> Void = { size, context in
        context.clear(CGRect(origin: CGPoint(), size: size))
        context.setFillColor(color.cgColor)
        context.fill(CGRect(origin: CGPoint(x: (size.width - 2.0) / 2.0, y: size.width / 2.0), size: CGSize(width: 2.0, height: size.height - size.width / 2.0 - 1.0)))
        context.fillEllipse(in: CGRect(origin: CGPoint(x: floor((size.width - diameter) / 2.0), y: floor((size.width - diameter) / 2.0)), size: CGSize(width: diameter, height: diameter)))
        context.fillEllipse(in: CGRect(origin: CGPoint(x: (size.width - 2.0) / 2.0, y: size.width + 2.0), size: CGSize(width: 2.0, height: 2.0)))
    }
    let size = CGSize(width: 12.0, height: 12.0 + 2.0 + 2.0)
    if inverted {
        return tiebaTextSelectionGenerateImage(size, verticalMirror: true, rotatedContext: f)?.stretchableImage(withLeftCapWidth: Int(size.width / 2.0), topCapHeight: Int(size.height) - (Int(size.width) + 1))
    } else {
        return tiebaTextSelectionGenerateImage(size, rotatedContext: f)?.stretchableImage(withLeftCapWidth: Int(size.width / 2.0), topCapHeight: Int(size.width) + 1)
    }
}
// MARK: - 主题 / 文案 / 动作（全部参数注入，不带上游 App 的主题树与本地化）

/// 上游 TextSelectionTheme（:60-72）：选择高亮色 + 手柄色/直径 + 明暗档。
public final class TiebaTextSelectionTheme {
    public let selection: UIColor
    public let knob: UIColor
    public let knobDiameter: CGFloat
    public let isDark: Bool

    public init(selection: UIColor, knob: UIColor, knobDiameter: CGFloat = 12.0, isDark: Bool) {
        self.selection = selection
        self.knob = knob
        self.knobDiameter = knobDiameter
        self.isDark = isDark
    }
}

/// 菜单文案：上游从 PresentationStrings 取，这里由调用方注入（默认中文）。
public struct TiebaTextSelectionStrings {
    public var copy: String
    public var share: String
    public var lookup: String
    public var translate: String
    public var quote: String
    public var selectAll: String

    public init(copy: String = "拷贝", share: String = "分享", lookup: String = "查询", translate: String = "翻译", quote: String = "引用", selectAll: String = "全选") {
        self.copy = copy
        self.share = share
        self.lookup = lookup
        self.translate = translate
        self.quote = quote
        self.selectAll = selectAll
    }
}

/// 上游 TextSelectionAction（:209-216）：选择菜单能做哪些事；业务动作由调用方在 performAction 里执行。
public enum TiebaTextSelectionAction: Equatable {
    case copy
    case share
    case lookup
    case translate
    case quote(range: Range<Int>)
}

/// 一个菜单项：标题 + 动作。替代上游的 ContextMenuAction（ContextUI 依赖）。
public struct TiebaTextSelectionMenuItem {
    public let title: String
    public let action: () -> Void

    public init(title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }
}

// MARK: - 选择目标（替代上游的 node/view 二选一）

/// 「被选择的文本」= 一个 UIView + 一份 TiebaTextNodeLayout。
/// 本仓的 TiebaTextView / TiebaImmediateTextNode 都暴露 cachedLayout，两条路径因此合一。
/// layoutProvider 每次现取（布局会随文本/宽度变化重建），不缓存旧 layout —— 选择期间文本被替换时不会拿到过期矩形。
public struct TiebaTextSelectionTarget {
    public let view: UIView
    private let layoutProvider: () -> TiebaTextNodeLayout?

    public init(view: UIView, layoutProvider: @escaping () -> TiebaTextNodeLayout?) {
        self.view = view
        self.layoutProvider = layoutProvider
    }

    public init(textView: TiebaTextView) {
        self.init(view: textView, layoutProvider: { [weak textView] in textView?.cachedLayout })
    }

    public init(textNode: TiebaImmediateTextNode) {
        self.init(view: textNode, layoutProvider: { [weak textNode] in textNode?.cachedLayout })
    }

    var layout: TiebaTextNodeLayout? {
        return self.layoutProvider()
    }

    var currentText: NSAttributedString? {
        return self.layout?.attributedString
    }

    func attributesAtPoint(_ point: CGPoint, orNearest: Bool = false) -> (Int, [NSAttributedString.Key: Any])? {
        return self.layout?.attributesAtPoint(point, orNearest: orNearest)
    }

    func textRangeRects(in range: NSRange) -> (rects: [CGRect], start: TiebaTextRangeRectEdge, end: TiebaTextRangeRectEdge)? {
        return self.layout?.rangeRects(in: range)
    }
}

// MARK: - 原文映射（上游 StringFormatting 模块的 OriginalTextAttribute）

/// 打在富文本上的「原文」标记：该段显示文本对应的原始字符串。
/// 上游拿它把显示文本里的选择映射回原文（引用功能）；本仓由调用方在需要时打标。
public protocol TiebaTextOriginalAttribute {
    var string: String { get }
}

public let tiebaTextOriginalAttributeKey = NSAttributedString.Key("TiebaTextOriginal")
private let tiebaTextSelectionPreviousTextKey = NSAttributedString.Key("__tieba_previous_text")

// MARK: - 选择节点本体（上游 :218-850；ASDisplayNode → UIView）

/// 文本选择节点：自己就是承载选择的 UIView（上游是 ASDisplayNode + TextSelectionNodeView 两层）。
/// 层级：self（选择层，覆盖在被选文本之上）→ highlightAreaView（选择高亮带）→ 两个手柄 UIImageView。
/// 它不改被选文本的任何内容，只画高亮与手柄，所以可以叠在任何 TiebaTextView / TiebaImmediateTextNode 上。
public final class TiebaTextSelectionNode: UIView {
    private let theme: TiebaTextSelectionTheme
    private let strings: TiebaTextSelectionStrings
    private let target: TiebaTextSelectionTarget
    private let updateIsActive: (Bool) -> Void
    public var canBeginSelection: (CGPoint) -> Bool = { _ in true }
    /// 选择范围变化（含 nil = 取消选择）时回调。
    public var updateRange: ((NSRange?) -> Void)?
    /// 菜单呈现：给「锚点视图 + 锚点矩形 + 菜单项」，怎么弹由调用方决定（上游用 ContextMenuController）。
    public var presentMenu: ((UIView, CGRect, [TiebaTextSelectionMenuItem]) -> Void)?
    /// 关掉当前菜单（上游 contextMenu?.dismiss()）。
    public var dismissMenu: (() -> Void)?
    private let rootView: () -> UIView?
    private let performAction: (NSAttributedString, TiebaTextSelectionAction) -> Void
    private var highlightOverlay: TiebaLinkHighlightingNode?
    private let leftKnob: UIImageView
    private let rightKnob: UIImageView

    /// 高亮带容器（上游 highlightAreaNode）：与手柄分离，便于外部只想拿高亮层时单独取用。
    public let highlightAreaView: UIView

    private var currentRange: (Int, Int)?
    private var currentRects: [CGRect]?

    /// 相邻行选择矩形之间允许被"补平"的最大缝（pt）。
    /// 上游硬编码 4.0：那是按它自己的行距因子（0.12 → 行距 2pt）调的。
    /// 本仓 TextNode 的行距因子是 0.30（行盒 17pt + 行距 5pt），4.0 盖不住 → 多行选择带会露出 5pt 条纹。
    /// 取 8.0：大于本仓行距（5）、远小于一个行盒（17），既能补平行间缝，又不会把
    /// "两段本来就不连续的选择"（隔了一整行）误连起来。
    private let maximumBridgedLineGap: CGFloat = 8.0

    public private(set) var recognizer: TiebaTextSelectionGestureRecognizer?

    public var enableCopy: Bool = true
    public var enableLookup: Bool = true
    public var enableQuote: Bool = false
    public var enableTranslate: Bool = true
    public var enableShare: Bool = true

    /// 抬手那一下是否算「点击」（宿主据此避免把收选择误当成点链接）。
    public var didRecognizeTap: Bool {
        return self.recognizer?.didRecognizeTap ?? false
    }

    public init(
        theme: TiebaTextSelectionTheme,
        strings: TiebaTextSelectionStrings = TiebaTextSelectionStrings(),
        target: TiebaTextSelectionTarget,
        updateIsActive: @escaping (Bool) -> Void,
        rootView: @escaping () -> UIView?,
        presentMenu: ((UIView, CGRect, [TiebaTextSelectionMenuItem]) -> Void)? = nil,
        dismissMenu: (() -> Void)? = nil,
        externalKnobSurface: UIView? = nil,
        performAction: @escaping (NSAttributedString, TiebaTextSelectionAction) -> Void
    ) {
        self.theme = theme
        self.strings = strings
        self.target = target
        self.updateIsActive = updateIsActive
        self.rootView = rootView
        self.presentMenu = presentMenu
        self.dismissMenu = dismissMenu
        self.performAction = performAction
        self.leftKnob = UIImageView()
        self.leftKnob.isUserInteractionEnabled = false
        self.leftKnob.image = tiebaTextSelectionGenerateKnobImage(color: theme.knob, diameter: theme.knobDiameter)
        self.leftKnob.alpha = 0.0
        self.rightKnob = UIImageView()
        self.rightKnob.isUserInteractionEnabled = false
        self.rightKnob.image = tiebaTextSelectionGenerateKnobImage(color: theme.knob, diameter: theme.knobDiameter, inverted: true)
        self.rightKnob.alpha = 0.0
        self.highlightAreaView = UIView()

        super.init(frame: .zero)

        // 选择层本身不吃触摸：命中判断交给 hitTest（只有手柄与自身 bounds 内才返回 self）。
        self.isUserInteractionEnabled = true
        self.backgroundColor = .clear
        self.addSubview(self.highlightAreaView)

        if let externalKnobSurface {
            // 手柄放到外层（例如滚动容器）时，拖到边缘也不会被裁掉。
            externalKnobSurface.addSubview(self.leftKnob)
            externalKnobSurface.addSubview(self.rightKnob)
        } else {
            self.addSubview(self.leftKnob)
            self.addSubview(self.rightKnob)
        }

        self.installRecognizer()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 上游写在 didLoad() 里的接线（UIView 无 didLoad，搬到 init 末尾）。
    private func installRecognizer() {
        let recognizer = TiebaTextSelectionGestureRecognizer(target: nil, action: nil)
        recognizer.knobAtPoint = { [weak self] point in
            return self?.knobAtPoint(point)
        }
        recognizer.moveKnob = { [weak self] knob, point in
            guard let self, let currentRange = self.currentRange else {
                return
            }
            // 手势坐标 → 被选文本视图坐标（两者可能不是同一个视图）。
            let mappedPoint = self.convert(point, to: self.target.view)
            if let stringIndex = self.target.attributesAtPoint(mappedPoint, orNearest: true)?.0 {
                var updatedLeft = currentRange.0
                var updatedRight = currentRange.1
                switch knob {
                case .left:
                    updatedLeft = stringIndex
                case .right:
                    updatedRight = stringIndex
                }
                if self.currentRange?.0 != updatedLeft || self.currentRange?.1 != updatedRight {
                    self.currentRange = (updatedLeft, updatedRight)
                    let updatedRange = NSRange(location: min(updatedLeft, updatedRight), length: max(updatedLeft, updatedRight) - min(updatedLeft, updatedRight))
                    self.updateSelection(range: updatedRange, animateIn: false)
                }

                // 拖到列表边缘时把选择滚进可视区（否则手柄会被屏幕边缘卡住）。
                if let scrollView = tiebaTextSelectionFindScrollView(view: self.superview) {
                    let scrollPoint = self.convert(point, to: scrollView)
                    scrollView.scrollRectToVisible(CGRect(origin: CGPoint(x: scrollPoint.x, y: scrollPoint.y - 50.0), size: CGSize(width: 1.0, height: 100.0)), animated: false)
                }
            }
        }
        recognizer.finishedMovingKnob = { [weak self] in
            guard let self else {
                return
            }
            self.displayMenu()
        }
        recognizer.beginSelection = { [weak self] point in
            guard let self, let attributedString = self.target.currentText else {
                return
            }
            self.dismissSelection()
            let mappedPoint = self.convert(point, to: self.target.view)
            var resultRange: NSRange?
            if let stringIndex = self.target.attributesAtPoint(mappedPoint, orNearest: false)?.0 {
                resultRange = TiebaTextSelectionNode.wordRange(attributedString: attributedString, at: stringIndex)
            }
            self.currentRange = resultRange.flatMap {
                ($0.lowerBound, $0.upperBound)
            }
            self.updateSelection(range: resultRange, animateIn: true)
            self.displayMenu()
            self.recognizer?.isSelecting = true
            self.updateIsActive(true)
        }
        recognizer.clearSelection = { [weak self] in
            self?.dismissSelection()
            self?.updateIsActive(false)
        }
        recognizer.canBeginSelection = { [weak self] point in
            guard let self else {
                return false
            }
            return self.canBeginSelection(point)
        }
        self.recognizer = recognizer
        self.addGestureRecognizer(recognizer)
    }

    /// 上游两处逐行重复的「按词切分」逻辑收敛成一个静态方法（同一算法，去掉重复）。
    /// 用 CFStringTokenizer 的 word 单元：中英文、日文都能按系统词界切；找不到词界就退化成单字符。
    private static func wordRange(attributedString: NSAttributedString, at stringIndex: Int) -> NSRange {
        let string = attributedString.string as NSString
        let inputRange = CFRangeMake(0, string.length)
        let flag = UInt(kCFStringTokenizerUnitWord)
        let locale = CFLocaleCopyCurrent()
        let tokenizer = CFStringTokenizerCreate(kCFAllocatorDefault, string as CFString, inputRange, flag, locale)
        var tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        while !tokenType.isEmpty {
            let currentTokenRange = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            if currentTokenRange.location <= stringIndex && currentTokenRange.location + currentTokenRange.length > stringIndex {
                return NSRange(location: currentTokenRange.location, length: currentTokenRange.length)
            }
            tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        }
        return NSRange(location: stringIndex, length: 1)
    }
    // MARK: 公开入口（上游 :431-505、:610-616）

    /// 布局变化后重新贴一次选择高亮（文本换行/宽度变了，旧矩形就过期了）。
    public func updateLayout() {
        if let currentRange = self.currentRange {
            let updatedMin = currentRange.0
            let updatedMax = currentRange.1
            let updatedRange = NSRange(location: min(updatedMin, updatedMax), length: max(updatedMin, updatedMax) - min(updatedMin, updatedMax))
            self.updateSelection(range: updatedRange, animateIn: false)
        }
    }

    /// 直接设一个选择范围（原文坐标；内部会转换到显示文本坐标）。
    public func setSelection(range: NSRange, displayMenu: Bool) {
        guard let attributedString = self.target.currentText else {
            return
        }
        let range = self.convertSelectionFromOriginalText(attributedString: attributedString, range: range)
        self.currentRange = (range.lowerBound, range.upperBound)
        self.updateSelection(range: range, animateIn: true)
        self.updateIsActive(true)
        if displayMenu {
            self.displayMenu()
        }
    }

    // MARK: 原文映射（上游 :507-608，逐行照搬）

    /// 显示文本坐标 → 原文坐标：把「原文属性」段的长度差补回选区起点/长度。
    private func convertSelectionToOriginalText(attributedString: NSAttributedString, range: NSRange) -> NSRange {
        var adjustedRange = range
        attributedString.enumerateAttribute(tiebaTextOriginalAttributeKey, in: NSRange(location: 0, length: range.lowerBound), options: [], using: { value, range, _ in
            guard let value = value as? TiebaTextOriginalAttribute else {
                return
            }
            let updatedSubstring = NSMutableAttributedString(string: value.string)
            adjustedRange.location += updatedSubstring.length - range.length
        })
        attributedString.enumerateAttribute(tiebaTextOriginalAttributeKey, in: range, options: [], using: { value, range, _ in
            guard let value = value as? TiebaTextOriginalAttribute else {
                return
            }
            let updatedSubstring = NSMutableAttributedString(string: value.string)
            adjustedRange.length += updatedSubstring.length - range.length
        })
        func normalizedSelectionRange(_ range: NSRange, length: Int) -> NSRange {
            let location = min(max(range.location, 0), length)
            let upperBound = min(max(location, range.location + range.length), length)
            return NSRange(location: location, length: upperBound - location)
        }
        return normalizedSelectionRange(adjustedRange, length: attributedString.length)
    }

    /// 原文坐标 → 显示文本坐标：先把所有「原文属性」段就地展开成显示文本，再按记录的前身长度回算。
    private func convertSelectionFromOriginalText(attributedString: NSAttributedString, range: NSRange) -> NSRange {
        var adjustedRange = range

        final class PreviousText: NSObject {
            let id: Int
            let string: String

            init(id: Int, string: String) {
                self.id = id
                self.string = string
            }
        }

        var nextId = 0
        let attributedString = NSMutableAttributedString(attributedString: attributedString)
        var fullRange = NSRange(location: 0, length: attributedString.length)
        while true {
            var found = false
            attributedString.enumerateAttribute(tiebaTextOriginalAttributeKey, in: fullRange, options: [], using: { value, range, stop in
                if let value = value as? TiebaTextOriginalAttribute {
                    let updatedSubstring = NSMutableAttributedString(string: value.string)
                    let replacementRange = NSRange(location: 0, length: updatedSubstring.length)
                    updatedSubstring.addAttributes(attributedString.attributes(at: range.location, effectiveRange: nil), range: replacementRange)
                    updatedSubstring.addAttribute(tiebaTextSelectionPreviousTextKey, value: PreviousText(id: nextId, string: attributedString.attributedSubstring(from: range).string), range: replacementRange)
                    nextId += 1
                    attributedString.replaceCharacters(in: range, with: updatedSubstring)
                    let updatedRange = NSRange(location: range.location, length: updatedSubstring.length)
                    found = true
                    stop.pointee = ObjCBool(true)
                    fullRange = NSRange(location: updatedRange.upperBound, length: fullRange.upperBound - range.upperBound)
                }
            })
            if !found {
                break
            }
        }
        attributedString.enumerateAttribute(tiebaTextSelectionPreviousTextKey, in: NSRange(location: 0, length: range.lowerBound), options: [], using: { value, range, _ in
            guard let value = value as? PreviousText else {
                return
            }
            adjustedRange.location += NSMutableAttributedString(string: value.string).length - range.length
        })
        attributedString.enumerateAttribute(tiebaTextSelectionPreviousTextKey, in: range, options: [], using: { value, range, _ in
            guard let value = value as? PreviousText else {
                return
            }
            adjustedRange.length += NSMutableAttributedString(string: value.string).length - range.length
        })
        return adjustedRange
    }

    // MARK: 选择高亮 + 手柄（上游 :618-700）

    private func updateSelection(range: NSRange?, animateIn: Bool) {
        self.updateRange?(range)

        var rects: (rects: [CGRect], start: TiebaTextRangeRectEdge, end: TiebaTextRangeRectEdge)?
        if let range {
            if var rectsValue = self.target.textRangeRects(in: range) {
                var rectList = rectsValue.rects
                // 相邻行的行盒之间补掉 <=4pt 的缝：不补的话逐行高亮之间会露出细缝（上游算法）。
                if rectList.count > 1 {
                    for i in 0 ..< rectList.count - 1 {
                        let deltaY = rectList[i + 1].minY - rectList[i].maxY
                        if deltaY > 0.0 && deltaY <= self.maximumBridgedLineGap {
                            rectList[i].size.height += deltaY * 0.5
                            rectList[i + 1].size.height += deltaY * 0.5
                            rectList[i + 1].origin.y -= deltaY * 0.5
                        }
                    }
                }
                rectsValue.rects = rectList
                rects = rectsValue
            } else {
                rects = nil
            }
        }

        self.currentRects = rects?.rects

        if let (rects, startEdge, endEdge) = rects, !rects.isEmpty {
            let highlightOverlay: TiebaLinkHighlightingNode
            if let current = self.highlightOverlay {
                highlightOverlay = current
            } else {
                highlightOverlay = TiebaLinkHighlightingNode(color: self.theme.selection)
                highlightOverlay.isUserInteractionEnabled = false
                highlightOverlay.innerRadius = 2.0
                highlightOverlay.outerRadius = 2.0
                highlightOverlay.inset = 1.0
                highlightOverlay.useModernPathCalculation = true
                self.highlightOverlay = highlightOverlay
                self.highlightAreaView.addSubview(highlightOverlay)
            }
            highlightOverlay.frame = self.bounds
            highlightOverlay.updateRects(rects)
            if let image = self.leftKnob.image {
                self.leftKnob.frame = CGRect(origin: CGPoint(x: floor(startEdge.x - image.size.width / 2.0), y: startEdge.y - self.theme.knobDiameter), size: CGSize(width: image.size.width, height: self.theme.knobDiameter + startEdge.height))
                self.rightKnob.frame = CGRect(origin: CGPoint(x: floor(endEdge.x - image.size.width / 2.0), y: endEdge.y), size: CGSize(width: image.size.width, height: self.theme.knobDiameter + endEdge.height))
            }
            if self.leftKnob.alpha.isZero {
                // 首次出现：高亮淡入 + 手柄先淡入再弹一下（上游节奏，逐行照搬）。
                highlightOverlay.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.3, timingFunction: CAMediaTimingFunctionName.easeOut.rawValue)
                self.leftKnob.alpha = 1.0
                self.leftKnob.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.14, delay: 0.19)
                self.rightKnob.alpha = 1.0
                self.rightKnob.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.14, delay: 0.19)
                // [按上游调阻尼] 改前 damping: 80.0（本仓自造）→ 改后 88（上游 animateSpring 的默认档，
                // 出处 CAAnimationUtils.swift:312, 338-340，见 TiebaMotionSpec.Spring.bounceDamping）。
                // 手感：ζ 0.596 → 0.656 —— 手柄弹出时**多一点点回弹**（与行内点赞/计数环同一档阻尼，全仓统一）。
                self.leftKnob.layer.animateSpring(from: 0.5 as NSNumber, to: 1.0 as NSNumber, keyPath: "transform.scale", duration: 0.2, delay: 0.25, initialVelocity: 0.0, damping: TiebaMotionSpec.Spring.bounceDamping)
                self.rightKnob.layer.animateSpring(from: 0.5 as NSNumber, to: 1.0 as NSNumber, keyPath: "transform.scale", duration: 0.2, delay: 0.25, initialVelocity: 0.0, damping: TiebaMotionSpec.Spring.bounceDamping)
                if animateIn {
                    var result = CGRect()
                    for rect in rects {
                        if result.isEmpty {
                            result = rect
                        } else {
                            result = result.union(rect)
                        }
                    }
                    // 从「包裹整段选择的两倍大矩形」缩回原位：视觉上像从手指处长出选择带。
                    highlightOverlay.layer.animateScale(from: 2.0, to: 1.0, duration: 0.26)
                    let fromResult = CGRect(origin: CGPoint(x: result.minX - result.width / 2.0, y: result.minY - result.height / 2.0), size: CGSize(width: result.width * 2.0, height: result.height * 2.0))
                    highlightOverlay.layer.animatePosition(from: CGPoint(x: (-fromResult.midX + highlightOverlay.bounds.midX) / 1.0, y: (-fromResult.midY + highlightOverlay.bounds.midY) / 1.0), to: CGPoint(), duration: 0.26, additive: true)
                }
            }
        } else if let highlightOverlay = self.highlightOverlay {
            self.highlightOverlay = nil
            highlightOverlay.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.18, removeOnCompletion: false, completion: { [weak highlightOverlay] _ in
                highlightOverlay?.removeFromSuperview()
            })
            self.leftKnob.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.18)
            self.leftKnob.alpha = 0.0
            self.leftKnob.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.18)
            self.rightKnob.alpha = 0.0
            self.rightKnob.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.18)
        }
    }

    // MARK: 手柄命中 / 选择生命周期（上游 :702-730）

    /// 手柄命中区：先按窄框（±4/±8）判、再按宽容差（±14）判 —— 手指没那么准，容差决定了能不能抓住手柄。
    private func knobAtPoint(_ point: CGPoint) -> (TiebaTextSelectionKnob, CGPoint)? {
        if !self.leftKnob.alpha.isZero, self.leftKnob.frame.insetBy(dx: -4.0, dy: -8.0).contains(point) {
            return (.left, CGPoint(x: self.leftKnob.frame.offsetBy(dx: 0.0, dy: self.leftKnob.frame.width / 2.0).midX, y: self.leftKnob.frame.offsetBy(dx: 0.0, dy: self.leftKnob.frame.width / 2.0).midY))
        }
        if !self.rightKnob.alpha.isZero, self.rightKnob.frame.insetBy(dx: -4.0, dy: -8.0).contains(point) {
            return (.right, CGPoint(x: self.rightKnob.frame.offsetBy(dx: 0.0, dy: -self.rightKnob.frame.width / 2.0).midX, y: self.rightKnob.frame.offsetBy(dx: 0.0, dy: -self.rightKnob.frame.width / 2.0).midY))
        }
        if !self.leftKnob.alpha.isZero, self.leftKnob.frame.insetBy(dx: -14.0, dy: -14.0).contains(point) {
            return (.left, CGPoint(x: self.leftKnob.frame.offsetBy(dx: 0.0, dy: self.leftKnob.frame.width / 2.0).midX, y: self.leftKnob.frame.offsetBy(dx: 0.0, dy: self.leftKnob.frame.width / 2.0).midY))
        }
        if !self.rightKnob.alpha.isZero, self.rightKnob.frame.insetBy(dx: -14.0, dy: -14.0).contains(point) {
            return (.right, CGPoint(x: self.rightKnob.frame.offsetBy(dx: 0.0, dy: -self.rightKnob.frame.width / 2.0).midX, y: self.rightKnob.frame.offsetBy(dx: 0.0, dy: -self.rightKnob.frame.width / 2.0).midY))
        }
        return nil
    }

    private func dismissSelection() {
        self.currentRange = nil
        self.recognizer?.isSelecting = false
        self.updateSelection(range: nil, animateIn: false)
        self.dismissMenu?()
    }

    /// 外部要求收选择（例如列表开始滚动、页面切走）。
    public func cancelSelection() {
        self.dismissSelection()
        self.updateIsActive(false)
    }

    // MARK: 菜单（上游 :732-839；ContextMenuController → presentMenu 闭包）

    private func displayMenu() {
        guard let currentRects = self.currentRects, !currentRects.isEmpty, let currentRange = self.currentRange, let attributedString = self.target.currentText else {
            return
        }
        let range = NSRange(location: min(currentRange.0, currentRange.1), length: max(currentRange.0, currentRange.1) - min(currentRange.0, currentRange.1))
        var completeRect = currentRects[0]
        for i in 0 ..< currentRects.count {
            completeRect = completeRect.union(currentRects[i])
        }
        // 锚点矩形往上留 12pt：菜单不能压在手指/选择带上（上游做法）。
        completeRect = completeRect.insetBy(dx: 0.0, dy: -12.0)

        // 菜单里的文本要用「原文」而不是显示文本（上游把 OriginalTextAttribute 段替换回去）。
        let string = NSMutableAttributedString(attributedString: attributedString.attributedSubstring(from: range))
        var fullRange = NSRange(location: 0, length: string.length)
        while true {
            var found = false
            string.enumerateAttribute(tiebaTextOriginalAttributeKey, in: fullRange, options: [], using: { value, range, stop in
                if let value = value as? TiebaTextOriginalAttribute {
                    let updatedSubstring = NSMutableAttributedString(string: value.string)
                    let replacementRange = NSRange(location: 0, length: updatedSubstring.length)
                    updatedSubstring.addAttributes(string.attributes(at: range.location, effectiveRange: nil), range: replacementRange)
                    string.replaceCharacters(in: range, with: updatedSubstring)
                    let updatedRange = NSRange(location: range.location, length: updatedSubstring.length)
                    found = true
                    stop.pointee = ObjCBool(true)
                    fullRange = NSRange(location: updatedRange.upperBound, length: fullRange.upperBound - range.upperBound)
                }
            })
            if !found {
                break
            }
        }

        let adjustedRange = self.convertSelectionToOriginalText(attributedString: attributedString, range: range)

        var items: [TiebaTextSelectionMenuItem] = []
        if self.enableCopy {
            items.append(TiebaTextSelectionMenuItem(title: self.strings.copy, action: { [weak self] in
                self?.performAction(string, .copy)
                self?.cancelSelection()
            }))
        }
        if self.enableQuote {
            items.append(TiebaTextSelectionMenuItem(title: self.strings.quote, action: { [weak self] in
                self?.performAction(string, .quote(range: adjustedRange.lowerBound ..< adjustedRange.upperBound))
                self?.cancelSelection()
            }))
        }
        if self.enableLookup {
            items.append(TiebaTextSelectionMenuItem(title: self.strings.lookup, action: { [weak self] in
                self?.performAction(string, .lookup)
                self?.cancelSelection()
            }))
        }
        if self.enableTranslate {
            items.append(TiebaTextSelectionMenuItem(title: self.strings.translate, action: { [weak self] in
                self?.performAction(string, .translate)
                self?.cancelSelection()
            }))
        }
        let realFullRange = NSRange(location: 0, length: attributedString.length)
        if range != realFullRange {
            items.append(TiebaTextSelectionMenuItem(title: self.strings.selectAll, action: { [weak self] in
                guard let self else {
                    return
                }
                self.dismissMenu?()
                self.setSelection(range: realFullRange, displayMenu: true)
            }))
        } else if self.enableShare {
            items.append(TiebaTextSelectionMenuItem(title: self.strings.share, action: { [weak self] in
                self?.performAction(string, .share)
                self?.cancelSelection()
            }))
        }

        self.dismissMenu?()
        self.presentMenu?(self, completeRect, items)
    }

    // MARK: 命中（上游 :841-849）

    /// 只有「手柄命中」与「自身 bounds 内」才吃触摸：其余点必须穿透给底下的正文视图，
    /// 否则选择层会挡住正文的长按/点击（这是选择层能和系统 UITextView 共存的关键）。
    public override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if self.knobAtPoint(point) != nil {
            return self
        }
        if self.bounds.contains(point) {
            return self
        }
        return nil
    }
}

// MARK: - 接线现状
//
// 已接线（正文行 TiebaPostRowView.swift:344-352）：行视图在正文上叠一个本层，
// target 传 TiebaTextSelectionTarget(textNode:)，菜单走行视图自己的 UIContextMenuInteraction，
// 列表滚动/复用/换模型时调 cancelSelection()，文本宽度变化后调 updateLayout()。
//
// 其余验收口径（手势/不干扰/视觉/无障碍）以行视图的实际行为为准；原先那份 DEBUG 自检
// （UI/Text/TiebaTextSelectionDebugCheck.swift，只读本层的 debug 读取口）已随零调用方清理删除。
