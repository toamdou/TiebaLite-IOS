// 移植自上游: submodules/Display/Source/TextNode.swift（上游 2989 行）与本仓同源的
// submodules/Display/Source/SubstringSearch.swift。
//
// 本文件 = 文本坐标系的"数据模型"：一次排版的完整结果（每行活 CTLine + frame + ascent/descent + NSRange +
// isRTL、下划线/删除线/剧透/内嵌项/附件矩形）以及基于它的命中测试与矩形查询。
// 排版算法与绘制在 TiebaTextNodeRenderer.swift（对应上游 :1205-2854 的静态实现），
// UIView 外壳在 TiebaTextView.swift（对应上游 :2856-2989）。三者合起来替代上游单个 TextNode.swift。
//
// 改动清单（逐条对应上游行号）：
//  1) [丢弃 ASDisplayNode 外壳] 上游 open class TextNode(:1205-2854, ASDisplayNode 子类)不搬；其中与视图无关的
//     排版/测量/绘制静态实现原样搬到 TiebaTextNode 命名空间。public protocol TextNodeProtocol(:1199) 继承
//     ASDisplayNode，无法保留。TextAccessibilityOverlayNode(:1088) 依赖 AccessibilityAreaNode + ASDisplayNode，
//     本仓无对应物，未搬（它的职责是给链接做无障碍元素，等无障碍层落地再补）。
//  2) [改名] 公开类型统一加 Tieba 前缀，避免与系统/本仓重名（铁律 6）：
//     TextRangeRectEdge → TiebaTextRangeRectEdge、TextNodeBlockQuoteData → TiebaTextNodeBlockQuoteData、
//     TextNodeCutout → TiebaTextNodeCutout、
//     TextVerticalAlignment → TiebaTextVerticalAlignment、TextNodeLayoutArguments → TiebaTextNodeLayoutArguments、
//     TextNodeLayout → TiebaTextNodeLayout；内部类型 TextNodeLine / TextNodeStrikethrough / TextNodeSpoiler /
//     TextNodeEmbeddedItem / TextNodeAttachment / TextNodeBlockQuote 同样加 Tieba 前缀。
//  3) [可见性] 上游把整套类型放在同一文件里，用 private/fileprivate 收敛；本模块按职责拆成 3 个文件，
//     故改为 internal（默认）——类型名都已带 Tieba 前缀，不会与本仓其他文件重名。
//  4) [删除未使用常量] 上游顶部 quoteIcon(:9) / codeIcon(:13) 走 AppBundle 的 UIImage(bundleImageName:)，
//     本仓没有 上游资源包；核对全文后确认这两个常量**从未被引用**，故整块删除（不是"取不到图"的降级）。
//  5) [依赖内联] 上游用到的 Display/上游核心模块 工具在本仓不存在（或属于其他同事的移植范围），这里以
//     Tieba 前缀的文件内函数内联，保证本目录自洽：UIScreenScale/floorToScreenPixels(:UIKitUtils:57,60)、
//     CGFloat.isEqual(to:)、CGRect.center(:ContainedViewLayoutTransition:7)、findSubstringRanges(:SubstringSearch)。
//     语义逐行照搬。
//  6) [Swift 6] UIScreen.main 在 iOS 26 SDK 里是 @MainActor 隔离且已弃用；改用
//     UIGraphicsImageRendererFormat.preferred().scale（SDK 语义即主屏 display scale，非隔离，且与本仓
//     TiebaUIKitUtils.swift 的同一做法一致），使 floorToScreenPixels / tiebaUIScreenPixel 保持 nonisolated——
//     文本测量本来就要能在后台线程跑。
//  7) [Swift 6] 未使用 @preconcurrency / nonisolated(unsafe) / @unchecked Sendable。本文件全是纯数据 + 不可变
//     快照；CTLine 不是 Sendable，所以这些类型也不声明 Sendable，由调用方保证留在同一隔离域（见 21 号文档说明）。
//  8) 算法一行未改（只做了上述机械改名/可见性/依赖内联）。

import Foundation
import UIKit
import CoreText

// MARK: - 上游分散工具的本地内联

// [移植] 上游 Display/Source/UIKitUtils.swift:57 `UIScreenScale`。
// iOS 26 SDK 里 UIScreen.main 是 @MainActor 且被标记弃用，改用 UIGraphicsImageRendererFormat.preferred().scale：
// SDK 文档对该方法的定义就是"主屏当前配置下最合适的 scale"，即主屏 display scale，取值与 UIScreen.main.scale 相同。
let tiebaTextScreenScale: CGFloat = UIGraphicsImageRendererFormat.preferred().scale

// [移植] 上游 Display/Source/UIKitUtils.swift:60 floorToScreenPixels（逐行照搬，只把全局量换成上面的 scale）。
func tiebaTextFloorToScreenPixels(_ value: CGFloat) -> CGFloat {
    return floor(value * tiebaTextScreenScale) / tiebaTextScreenScale
}

// [移植] 上游 Display/Source/UIKitUtils.swift:66 `UIScreenPixel`。
let tiebaTextUIScreenPixel: CGFloat = 1.0 / tiebaTextScreenScale

// [移植] 上游 CGFloat 的 isEqual(to:)（Display/上游核心模块 提供的浮点容差比较）。本仓没有该扩展，
// 按同一语义（容差 0.0001）内联。用它的三个场景都是"排版结果是否可复用"与"光标两侧偏移是否重合"，
// 直接 == 会在浮点尾差上抖动，故保留容差语义。
func tiebaTextIsEqual(_ lhs: CGFloat, _ rhs: CGFloat) -> Bool {
    return abs(lhs - rhs) < 0.0001
}

// [移植] 上游 Display/Source/ContainedViewLayoutTransition.swift:7 `CGRect.center`。
// 该扩展由本仓 UI/Transition 组移植，为避免同名重复声明，这里以函数内联。
func tiebaTextCenter(_ rect: CGRect) -> CGPoint {
    return CGPoint(x: rect.midX, y: rect.midY)
}

// [移植] 上游 Display/Source/SubstringSearch.swift 全文，逐行照搬（纯字符串处理，无任何 AS* 依赖），
// 仅函数名加 Tieba 前缀。TextNodeLayout.textRangesRects(text:) 依赖它。
func tiebaTextFindSubstringRanges(in string: String, query: String) -> ([Range<String.Index>], String) {
    var ranges: [Range<String.Index>] = []
    let queryWords = query.split { !$0.isLetter && !$0.isNumber && $0 != "#" && $0 != "@" }.filter { !$0.isEmpty && !["#", "@"].contains($0) }.map { $0.lowercased() }

    let text = string.lowercased()
    let searchRange = text.startIndex ..< text.endIndex
    text.enumerateSubstrings(in: searchRange, options: .byWords) { (rawSubstring, rawRange, _, _) in
        guard let rawSubstring = rawSubstring else {
            return
        }
        var substrings: [(String, Range<String.Index>)] = []
        if let index = rawSubstring.firstIndex(of: "'") {
            let leftString = String(rawSubstring[..<index])
            let rightString = String(rawSubstring[rawSubstring.index(after: index)...])
            if !leftString.isEmpty {
                substrings.append((leftString, rawRange.lowerBound ..< text.index(rawRange.lowerBound, offsetBy: leftString.count)))
            }
            if !rightString.isEmpty {
                substrings.append((rightString, text.index(rawRange.lowerBound, offsetBy: leftString.count + 1) ..< rawRange.upperBound))
            }
        } else {
            substrings.append((rawSubstring, rawRange))
        }

        for (substring, range) in substrings {
            for var word in queryWords {
                var count = 0
                var hasLeadingSymbol = false
                if word.hasPrefix("#") || word.hasPrefix("@") {
                    hasLeadingSymbol = true
                    word.removeFirst()
                }
                inner: for (c1, c2) in zip(word, substring) {
                    if c1 != c2 {
                        break inner
                    }
                    count += 1
                }
                if count > 0 {
                    let length = Double(max(word.count, substring.count))
                    if length > 0 {
                        let difference = abs(length - Double(count))
                        let rating = difference / length
                        if rating < 0.37 {
                            var range = range
                            if hasLeadingSymbol && range.lowerBound > searchRange.lowerBound {
                                range = text.index(before: range.lowerBound)..<range.upperBound
                            }
                            ranges.append(range)
                        }
                    }
                }
            }
        }
    }
    return (ranges, text)
}

// MARK: - 上游 :7-1018（类型与 TextNodeLayout）

let tiebaTextDefaultFont = UIFont.systemFont(ofSize: 15.0)

final class TiebaTextNodeStrikethrough {
    enum Style {
        case single
        case wavy
    }
    
    let range: NSRange
    let frame: CGRect
    let color: UIColor?
    let style: Style
    
    init(range: NSRange, frame: CGRect, color: UIColor?, style: Style) {
        self.range = range
        self.frame = frame
        self.color = color
        self.style = style
    }
}

final class TiebaTextNodeSpoiler {
    let range: NSRange
    let frame: CGRect
    
    init(range: NSRange, frame: CGRect) {
        self.range = range
        self.frame = frame
    }
}


final class TiebaTextNodeEmbeddedItem {
    let range: NSRange
    let frame: CGRect
    let item: AnyHashable
    
    init(range: NSRange, frame: CGRect, item: AnyHashable) {
        self.range = range
        self.frame = frame
        self.item = item
    }
}

final class TiebaTextNodeAttachment {
    let range: NSRange
    let frame: CGRect
    let attachment: UIImage
    
    init(range: NSRange, frame: CGRect, attachment: UIImage) {
        self.range = range
        self.frame = frame
        self.attachment = attachment
    }
}

public struct TiebaTextRangeRectEdge: Equatable {
    public var x: CGFloat
    public var y: CGFloat
    public var height: CGFloat
    
    public init(x: CGFloat, y: CGFloat, height: CGFloat) {
        self.x = x
        self.y = y
        self.height = height
    }
}

public final class TiebaTextNodeBlockQuoteData: NSObject {
    public enum Kind: Equatable {
        case quote
        case code(language: String?)
    }
    
    public let kind: Kind
    public let title: NSAttributedString?
    public let color: UIColor
    public let secondaryColor: UIColor?
    public let tertiaryColor: UIColor?
    public let backgroundColor: UIColor
    public let isCollapsible: Bool
    
    public init(kind: Kind, title: NSAttributedString?, color: UIColor, secondaryColor: UIColor?, tertiaryColor: UIColor?, backgroundColor: UIColor, isCollapsible: Bool) {
        self.kind = kind
        self.title = title
        self.color = color
        self.secondaryColor = secondaryColor
        self.tertiaryColor = tertiaryColor
        self.backgroundColor = backgroundColor
        self.isCollapsible = isCollapsible
        
        super.init()
    }
    
    override public func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? TiebaTextNodeBlockQuoteData else {
            return false
        }
        
        if self.kind != other.kind {
            return false
        }
        if let lhsTitle = self.title, let rhsTitle = other.title {
            if !lhsTitle.isEqual(to: rhsTitle) {
                return false
            }
        } else if (self.title == nil) != (other.title == nil) {
            return false
        }
        if !self.color.isEqual(other.color) {
            return false
        }
        if let lhsSecondaryColor = self.secondaryColor, let rhsSecondaryColor = other.secondaryColor {
            if !lhsSecondaryColor.isEqual(rhsSecondaryColor) {
                return false
            }
        } else if (self.secondaryColor == nil) != (other.secondaryColor == nil) {
            return false
        }
        if let lhsTertiaryColor = self.tertiaryColor, let rhsTertiaryColor = other.tertiaryColor {
            if !lhsTertiaryColor.isEqual(rhsTertiaryColor) {
                return false
            }
        } else if (self.tertiaryColor == nil) != (other.tertiaryColor == nil) {
            return false
        }
        
        return true
    }
}

final class TiebaTextNodeLine {
    let line: CTLine
    var frame: CGRect
    let ascent: CGFloat
    let descent: CGFloat
    let range: NSRange?
    let isRTL: Bool
    var backgrounds: [TiebaTextNodeStrikethrough]
    var strikethroughs: [TiebaTextNodeStrikethrough]
    var underlines: [TiebaTextNodeStrikethrough]
    var spoilers: [TiebaTextNodeSpoiler]
    var spoilerWords: [TiebaTextNodeSpoiler]
    var embeddedItems: [TiebaTextNodeEmbeddedItem]
    var attachments: [TiebaTextNodeAttachment]
    let additionalTrailingLine: (CTLine, Double)?
    
    init(line: CTLine, frame: CGRect, ascent: CGFloat, descent: CGFloat, range: NSRange?, isRTL: Bool, backgrounds: [TiebaTextNodeStrikethrough], strikethroughs: [TiebaTextNodeStrikethrough], underlines: [TiebaTextNodeStrikethrough], spoilers: [TiebaTextNodeSpoiler], spoilerWords: [TiebaTextNodeSpoiler], embeddedItems: [TiebaTextNodeEmbeddedItem], attachments: [TiebaTextNodeAttachment], additionalTrailingLine: (CTLine, Double)?) {
        self.line = line
        self.frame = frame
        self.ascent = ascent
        self.descent = descent
        self.range = range
        self.isRTL = isRTL
        self.backgrounds = backgrounds
        self.strikethroughs = strikethroughs
        self.underlines = underlines
        self.spoilers = spoilers
        self.spoilerWords = spoilerWords
        self.embeddedItems = embeddedItems
        self.attachments = attachments
        self.additionalTrailingLine = additionalTrailingLine
    }
}

final class TiebaTextNodeBlockQuote {
    let frame: CGRect
    let data: TiebaTextNodeBlockQuoteData
    let tintColor: UIColor
    let secondaryTintColor: UIColor?
    let tertiaryTintColor: UIColor?
    let backgroundColor: UIColor
    
    init(frame: CGRect, data: TiebaTextNodeBlockQuoteData, tintColor: UIColor, secondaryTintColor: UIColor?, tertiaryTintColor: UIColor?, backgroundColor: UIColor) {
        self.frame = frame
        self.data = data
        self.tintColor = tintColor
        self.secondaryTintColor = secondaryTintColor
        self.tertiaryTintColor = tertiaryTintColor
        self.backgroundColor = backgroundColor
    }
}


public struct TiebaTextNodeCutout: Equatable {
    public var topLeft: CGSize?
    public var topRight: CGSize?
    public var bottomRight: CGSize?
    
    public init(topLeft: CGSize? = nil, topRight: CGSize? = nil, bottomRight: CGSize? = nil) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomRight = bottomRight
    }
}

let tiebaTextDrawUnderlinesManually: Bool = {
    return true
}()

func tiebaTextDisplayLineFrame(frame: CGRect, isRTL: Bool, boundingRect: CGRect, cutout: TiebaTextNodeCutout?) -> CGRect {
    if tiebaTextIsEqual(frame.width, boundingRect.width) {
        return frame
    }
    var lineFrame = frame
    let intersectionFrame = lineFrame.offsetBy(dx: 0.0, dy: -lineFrame.height)

    if isRTL {
        lineFrame.origin.x = max(0.0, floor(boundingRect.width - lineFrame.size.width))
        if let topRight = cutout?.topRight {
            let topRightRect = CGRect(origin: CGPoint(x: boundingRect.width - topRight.width, y: 0.0), size: topRight)
            if intersectionFrame.intersects(topRightRect) {
                lineFrame.origin.x -= topRight.width
                return lineFrame
            }
        }
        if let bottomRight = cutout?.bottomRight {
            let bottomRightRect = CGRect(origin: CGPoint(x: boundingRect.width - bottomRight.width, y: boundingRect.height - bottomRight.height), size: bottomRight)
            if intersectionFrame.intersects(bottomRightRect) {
                lineFrame.origin.x -= bottomRight.width
                return lineFrame
            }
        }
    }
    return lineFrame
}

public enum TiebaTextVerticalAlignment {
    case top
    case middle
    case bottom
}

public final class TiebaTextNodeLayoutArguments {
    public let attributedString: NSAttributedString?
    public let backgroundColor: UIColor?
    public let minimumNumberOfLines: Int
    public let maximumNumberOfLines: Int
    public let truncationType: CTLineTruncationType
    public let constrainedSize: CGSize
    public let alignment: NSTextAlignment
    public let verticalAlignment: TiebaTextVerticalAlignment
    public let lineSpacing: CGFloat
    public let cutout: TiebaTextNodeCutout?
    public let insets: UIEdgeInsets
    public let lineColor: UIColor?
    public let textShadowColor: UIColor?
    public let textShadowBlur: CGFloat?
    public let textStroke: (UIColor, CGFloat)?
    public let displaySpoilers: Bool
    public let displayEmbeddedItemsUnderSpoilers: Bool
    public let customTruncationToken: NSAttributedString?
    
    public init(
        attributedString: NSAttributedString?,
        backgroundColor: UIColor? = nil,
        minimumNumberOfLines: Int = 0,
        maximumNumberOfLines: Int,
        truncationType: CTLineTruncationType,
        constrainedSize: CGSize,
        alignment: NSTextAlignment = .natural,
        verticalAlignment: TiebaTextVerticalAlignment = .top,
        lineSpacing: CGFloat = 0.12,
        cutout: TiebaTextNodeCutout? = nil,
        insets: UIEdgeInsets = UIEdgeInsets(),
        lineColor: UIColor? = nil,
        textShadowColor: UIColor? = nil,
        textShadowBlur: CGFloat? = nil,
        textStroke: (UIColor, CGFloat)? = nil,
        displaySpoilers: Bool = false,
        displayEmbeddedItemsUnderSpoilers: Bool = false,
        customTruncationToken: NSAttributedString? = nil
    ) {
        self.attributedString = attributedString
        self.backgroundColor = backgroundColor
        self.minimumNumberOfLines = minimumNumberOfLines
        self.maximumNumberOfLines = maximumNumberOfLines
        self.truncationType = truncationType
        self.constrainedSize = constrainedSize
        self.alignment = alignment
        self.verticalAlignment = verticalAlignment
        self.lineSpacing = lineSpacing
        self.cutout = cutout
        self.insets = insets
        self.lineColor = lineColor
        self.textShadowColor = textShadowColor
        self.textShadowBlur = textShadowBlur
        self.textStroke = textStroke
        self.displaySpoilers = displaySpoilers
        self.displayEmbeddedItemsUnderSpoilers = displayEmbeddedItemsUnderSpoilers
        self.customTruncationToken = customTruncationToken
    }
    
    public func withAttributedString(_ attributedString: NSAttributedString?) -> TiebaTextNodeLayoutArguments {
        return TiebaTextNodeLayoutArguments(
            attributedString: attributedString,
            backgroundColor: self.backgroundColor,
            minimumNumberOfLines: self.minimumNumberOfLines,
            maximumNumberOfLines: self.maximumNumberOfLines,
            truncationType: self.truncationType,
            constrainedSize: self.constrainedSize,
            alignment: self.alignment,
            verticalAlignment: self.verticalAlignment,
            lineSpacing: self.lineSpacing,
            cutout: self.cutout,
            insets: self.insets,
            lineColor: self.lineColor,
            textShadowColor: self.textShadowColor,
            textShadowBlur: self.textShadowBlur,
            textStroke: self.textStroke,
            displaySpoilers: self.displaySpoilers,
            displayEmbeddedItemsUnderSpoilers: self.displayEmbeddedItemsUnderSpoilers,
            customTruncationToken: self.customTruncationToken
        )
    }
}

public final class TiebaTextNodeLayout: NSObject {
    public final class EmbeddedItem: Equatable {
        public let range: NSRange
        public let rect: CGRect
        public let value: AnyHashable
        public let textColor: UIColor
        
        public init(range: NSRange, rect: CGRect, value: AnyHashable, textColor: UIColor) {
            self.range = range
            self.rect = rect
            self.value = value
            self.textColor = textColor
        }
        
        public static func ==(lhs: EmbeddedItem, rhs: EmbeddedItem) -> Bool {
            if lhs.range != rhs.range {
                return false
            }
            if lhs.rect != rhs.rect {
                return false
            }
            if lhs.value != rhs.value {
                return false
            }
            if lhs.textColor != rhs.textColor {
                return false
            }
            return true
        }
    }
    
    public struct LayoutInfo: Equatable {
        public let size: CGSize
        public let trailingLineWidth: CGFloat
        
        public init(size: CGSize, trailingLineWidth: CGFloat) {
            self.size = size
            self.trailingLineWidth = trailingLineWidth
        }
    }
    
    public let attributedString: NSAttributedString?
    let maximumNumberOfLines: Int
    let truncationType: CTLineTruncationType
    let backgroundColor: UIColor?
    let constrainedSize: CGSize
    let explicitAlignment: NSTextAlignment
    public let resolvedAlignment: NSTextAlignment
    let verticalAlignment: TiebaTextVerticalAlignment
    let lineSpacing: CGFloat
    let cutout: TiebaTextNodeCutout?
    public let insets: UIEdgeInsets
    public let size: CGSize
    public let rawTextSize: CGSize
    public let truncated: Bool
    let firstLineOffset: CGFloat
    let lines: [TiebaTextNodeLine]
    let blockQuotes: [TiebaTextNodeBlockQuote]
    let lineColor: UIColor?
    let textShadowColor: UIColor?
    let textShadowBlur: CGFloat?
    let textStroke: (UIColor, CGFloat)?
    let displaySpoilers: Bool
    public let hasRTL: Bool
    public let spoilers: [(NSRange, CGRect)]
    public let spoilerWords: [(NSRange, CGRect)]
    public let embeddedItems: [TiebaTextNodeLayout.EmbeddedItem]
    
    init(attributedString: NSAttributedString?, maximumNumberOfLines: Int, truncationType: CTLineTruncationType, constrainedSize: CGSize, explicitAlignment: NSTextAlignment, resolvedAlignment: NSTextAlignment, verticalAlignment: TiebaTextVerticalAlignment, lineSpacing: CGFloat, cutout: TiebaTextNodeCutout?, insets: UIEdgeInsets, size: CGSize, rawTextSize: CGSize, truncated: Bool, firstLineOffset: CGFloat, lines: [TiebaTextNodeLine], blockQuotes: [TiebaTextNodeBlockQuote], backgroundColor: UIColor?, lineColor: UIColor?, textShadowColor: UIColor?, textShadowBlur: CGFloat?, textStroke: (UIColor, CGFloat)?, displaySpoilers: Bool) {
        self.attributedString = attributedString
        self.maximumNumberOfLines = maximumNumberOfLines
        self.truncationType = truncationType
        self.constrainedSize = constrainedSize
        self.explicitAlignment = explicitAlignment
        self.resolvedAlignment = resolvedAlignment
        self.verticalAlignment = verticalAlignment
        self.lineSpacing = lineSpacing
        self.cutout = cutout
        self.insets = insets
        self.size = size
        self.rawTextSize = rawTextSize
        self.truncated = truncated
        self.firstLineOffset = firstLineOffset
        self.lines = lines
        self.blockQuotes = blockQuotes
        self.backgroundColor = backgroundColor
        self.lineColor = lineColor
        self.textShadowColor = textShadowColor
        self.textShadowBlur = textShadowBlur
        self.textStroke = textStroke
        self.displaySpoilers = displaySpoilers
        var hasRTL = false
        var spoilers: [(NSRange, CGRect)] = []
        var spoilerWords: [(NSRange, CGRect)] = []
        var embeddedItems: [TiebaTextNodeLayout.EmbeddedItem] = []
        for line in lines {
            if line.isRTL {
                hasRTL = true
            }
            
            let lineFrame: CGRect
            switch self.resolvedAlignment {
            case .center:
                lineFrame = CGRect(origin: CGPoint(x: floor((size.width - line.frame.size.width) / 2.0), y: line.frame.minY), size: line.frame.size)
            case .right:
                lineFrame = CGRect(origin: CGPoint(x: size.width - line.frame.size.width, y: line.frame.minY), size: line.frame.size)
            default:
                lineFrame = tiebaTextDisplayLineFrame(frame: line.frame, isRTL: line.isRTL, boundingRect: CGRect(origin: CGPoint(), size: size), cutout: cutout)
            }
            
            spoilers.append(contentsOf: line.spoilers.map { ( $0.range, $0.frame.offsetBy(dx: lineFrame.minX, dy: lineFrame.minY)) })
            spoilerWords.append(contentsOf: line.spoilerWords.map { ( $0.range, $0.frame.offsetBy(dx: lineFrame.minX, dy: lineFrame.minY)) })
            for embeddedItem in line.embeddedItems {
                var textColor: UIColor?
                if let attributedString = attributedString, embeddedItem.range.location < attributedString.length {
                    if let color = attributedString.attribute(.foregroundColor, at: embeddedItem.range.location, effectiveRange: nil) as? UIColor {
                        textColor = color
                    }
                    if textColor == nil {
                        if let color = attributedString.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor {
                            textColor = color
                        }
                    }
                }
                embeddedItems.append(TiebaTextNodeLayout.EmbeddedItem(range: embeddedItem.range, rect: embeddedItem.frame.offsetBy(dx: lineFrame.minX, dy: lineFrame.minY), value: embeddedItem.item, textColor: textColor ?? .black))
            }
        }
        self.hasRTL = hasRTL
        self.spoilers = spoilers
        self.spoilerWords = spoilerWords
        self.embeddedItems = embeddedItems
    }
    
    public func areLinesEqual(to other: TiebaTextNodeLayout) -> Bool {
        if self.lines.count != other.lines.count {
            return false
        }
        for i in 0 ..< self.lines.count {
            if !self.lines[i].frame.equalTo(other.lines[i].frame) {
                return false
            }
            if self.lines[i].isRTL != other.lines[i].isRTL {
                return false
            }
            if self.lines[i].range != other.lines[i].range {
                return false
            }
            let lhsRuns = CTLineGetGlyphRuns(self.lines[i].line) as NSArray
            let rhsRuns = CTLineGetGlyphRuns(other.lines[i].line) as NSArray
            
            if lhsRuns.count != rhsRuns.count {
                return false
            }
            
            for j in 0 ..< lhsRuns.count {
                let lhsRun = lhsRuns[j] as! CTRun
                let rhsRun = rhsRuns[j] as! CTRun
                let lhsGlyphCount = CTRunGetGlyphCount(lhsRun)
                let rhsGlyphCount = CTRunGetGlyphCount(rhsRun)
                if lhsGlyphCount != rhsGlyphCount {
                    return false
                }
                
                for k in 0 ..< lhsGlyphCount {
                    var lhsGlyph = CGGlyph()
                    var rhsGlyph = CGGlyph()
                    CTRunGetGlyphs(lhsRun, CFRangeMake(k, 1), &lhsGlyph)
                    CTRunGetGlyphs(rhsRun, CFRangeMake(k, 1), &rhsGlyph)
                    if lhsGlyph != rhsGlyph {
                        return false
                    }
                }
            }
        }
        return true
    }
    
    public var numberOfLines: Int {
        return self.lines.count
    }
    
    public var trailingLineWidth: CGFloat {
        if let lastLine = self.lines.last {
            var width = lastLine.frame.maxX
            
            for blockQuote in self.blockQuotes {
                if lastLine.frame.intersects(blockQuote.frame) {
                    width = max(width, ceil(blockQuote.frame.maxX) + 2.0)
                }
            }
            return width
        } else {
            return 0.0
        }
    }

    public var trailingLineIsRTL: Bool {
        if let lastLine = self.lines.last {
            return lastLine.isRTL
        } else {
            return false
        }
    }
    
    public func attributesAtPoint(_ point: CGPoint, orNearest: Bool) -> (Int, [NSAttributedString.Key: Any])? {
        if let attributedString = self.attributedString {
            let transformedPoint = CGPoint(x: point.x - self.insets.left, y: point.y - self.insets.top)
            if orNearest {
                var lineIndex = -1
                var closestLine: (Int, CGRect, CGFloat)?
                for line in self.lines {
                    lineIndex += 1
                    var lineFrame = CGRect(origin: CGPoint(x: line.frame.origin.x, y: line.frame.origin.y - line.frame.size.height + line.descent), size: line.frame.size)
                    switch self.resolvedAlignment {
                    case .center:
                        lineFrame.origin.x = floor((self.size.width - lineFrame.size.width) / 2.0)
                    case .natural:
                        lineFrame = tiebaTextDisplayLineFrame(frame: lineFrame, isRTL: line.isRTL, boundingRect: CGRect(origin: CGPoint(), size: self.size), cutout: self.cutout)
                    case .right:
                        lineFrame.origin.x = self.size.width - lineFrame.size.width
                    default:
                        break
                    }
                    
                    let currentDistance = (tiebaTextCenter(lineFrame).y - point.y) * (tiebaTextCenter(lineFrame).y - point.y)
                    if let current = closestLine {
                        if current.2 > currentDistance {
                            closestLine = (lineIndex, lineFrame, currentDistance)
                        }
                    } else {
                        closestLine = (lineIndex, lineFrame, currentDistance)
                    }
                }
                
                if let (index, lineFrame, _) = closestLine {
                    let line = self.lines[index]
                    
                    let lineRange = CTLineGetStringRange(line.line)
                    var index: Int
                    if transformedPoint.x <= lineFrame.minX {
                        index = lineRange.location
                    } else if transformedPoint.x >= lineFrame.maxX {
                        index = lineRange.location + lineRange.length
                    } else {
                        index = CTLineGetStringIndexForPosition(line.line, CGPoint(x: transformedPoint.x - lineFrame.minX, y: floor(lineFrame.height / 2.0)))
                        if index != 0 {
                            var glyphStart: CGFloat = 0.0
                            CTLineGetOffsetForStringIndex(line.line, index, &glyphStart)
                            if transformedPoint.x < glyphStart {
                                var closestLowerIndex: Int?
                                let glyphRuns = CTLineGetGlyphRuns(line.line) as NSArray
                                if glyphRuns.count != 0 {
                                    for run in glyphRuns {
                                        let run = run as! CTRun
                                        let glyphCount = CTRunGetGlyphCount(run)
                                        for i in 0 ..< glyphCount {
                                            var glyphIndex: CFIndex = 0
                                            CTRunGetStringIndices(run, CFRangeMake(i, 1), &glyphIndex)
                                            if glyphIndex < index {
                                                if let closestLowerIndexValue = closestLowerIndex {
                                                    if closestLowerIndexValue < glyphIndex {
                                                        closestLowerIndex = glyphIndex
                                                    }
                                                } else {
                                                    closestLowerIndex = glyphIndex
                                                }
                                            }
                                        }
                                    }
                                }
                                if let closestLowerIndex = closestLowerIndex {
                                    index = closestLowerIndex
                                }
                            }
                        }
                    }
                    return (index, [:])
                }
            }
            var lineIndex = -1
            for line in self.lines {
                lineIndex += 1
                var lineFrame = CGRect(origin: CGPoint(x: line.frame.origin.x, y: line.frame.origin.y - line.frame.size.height + line.descent), size: line.frame.size)
                switch self.resolvedAlignment {
                    case .center:
                        lineFrame.origin.x = floor((self.size.width - lineFrame.size.width) / 2.0)
                    case .natural:
                        lineFrame = tiebaTextDisplayLineFrame(frame: lineFrame, isRTL: line.isRTL, boundingRect: CGRect(origin: CGPoint(), size: self.size), cutout: self.cutout)
                    case .right:
                        lineFrame.origin.x = self.size.width - lineFrame.size.width
                    default:
                        break
                }
                if lineFrame.contains(transformedPoint) {
                    var index = CTLineGetStringIndexForPosition(line.line, CGPoint(x: transformedPoint.x - lineFrame.minX, y: transformedPoint.y - lineFrame.minY))
                    if index == attributedString.length {
                        var closestLowerIndex: Int?
                        let glyphRuns = CTLineGetGlyphRuns(line.line) as NSArray
                        if glyphRuns.count != 0 {
                            for run in glyphRuns {
                                let run = run as! CTRun
                                let glyphCount = CTRunGetGlyphCount(run)
                                for i in 0 ..< glyphCount {
                                    var glyphIndex: CFIndex = 0
                                    CTRunGetStringIndices(run, CFRangeMake(i, 1), &glyphIndex)
                                    if glyphIndex < index {
                                        if let closestLowerIndexValue = closestLowerIndex {
                                            if closestLowerIndexValue < glyphIndex {
                                                closestLowerIndex = glyphIndex
                                            }
                                        } else {
                                            closestLowerIndex = glyphIndex
                                        }
                                    }
                                }
                            }
                        }
                        if let closestLowerIndex = closestLowerIndex {
                            index = closestLowerIndex
                        }
                    } else if index != 0 {
                        var glyphStart: CGFloat = 0.0
                        CTLineGetOffsetForStringIndex(line.line, index, &glyphStart)
                        if transformedPoint.x < glyphStart {
                            var closestLowerIndex: Int?
                            let glyphRuns = CTLineGetGlyphRuns(line.line) as NSArray
                            if glyphRuns.count != 0 {
                                for run in glyphRuns {
                                    let run = run as! CTRun
                                    let glyphCount = CTRunGetGlyphCount(run)
                                    for i in 0 ..< glyphCount {
                                        var glyphIndex: CFIndex = 0
                                        CTRunGetStringIndices(run, CFRangeMake(i, 1), &glyphIndex)
                                        if glyphIndex < index {
                                            if let closestLowerIndexValue = closestLowerIndex {
                                                if closestLowerIndexValue < glyphIndex {
                                                    closestLowerIndex = glyphIndex
                                                }
                                            } else {
                                                closestLowerIndex = glyphIndex
                                            }
                                        }
                                    }
                                }
                            }
                            if let closestLowerIndex = closestLowerIndex {
                                index = closestLowerIndex
                            }
                        }
                    }
                    if index >= 0 && index < attributedString.length {
                        if let range = line.range, index < range.location + range.length {
                            return (index, attributedString.attributes(at: index, effectiveRange: nil))
                        }
                    }
                    break
                }
            }
            lineIndex = -1
            for line in self.lines {
                lineIndex += 1
                var lineFrame = CGRect(origin: CGPoint(x: line.frame.origin.x, y: line.frame.origin.y - line.frame.size.height + line.descent), size: line.frame.size)
                switch self.resolvedAlignment {
                    case .center:
                        lineFrame.origin.x = floor((self.size.width - lineFrame.size.width) / 2.0)
                    case .natural:
                        lineFrame = tiebaTextDisplayLineFrame(frame: lineFrame, isRTL: line.isRTL, boundingRect: CGRect(origin: CGPoint(), size: self.size), cutout: self.cutout)
                    case .right:
                        lineFrame.origin.x = self.size.width - lineFrame.size.width
                    default:
                        break
                }
                if lineFrame.offsetBy(dx: 0.0, dy: -lineFrame.size.height).insetBy(dx: -3.0, dy: -3.0).contains(transformedPoint) {
                    var index = CTLineGetStringIndexForPosition(line.line, CGPoint(x: transformedPoint.x - lineFrame.minX, y: transformedPoint.y - lineFrame.minY))
                    if index == attributedString.length {
                        var closestLowerIndex: Int?
                        let glyphRuns = CTLineGetGlyphRuns(line.line) as NSArray
                        if glyphRuns.count != 0 {
                            for run in glyphRuns {
                                let run = run as! CTRun
                                let glyphCount = CTRunGetGlyphCount(run)
                                for i in 0 ..< glyphCount {
                                    var glyphIndex: CFIndex = 0
                                    CTRunGetStringIndices(run, CFRangeMake(i, 1), &glyphIndex)
                                    if glyphIndex < index {
                                        if let closestLowerIndexValue = closestLowerIndex {
                                            if closestLowerIndexValue < glyphIndex {
                                                closestLowerIndex = glyphIndex
                                            }
                                        } else {
                                            closestLowerIndex = glyphIndex
                                        }
                                    }
                                }
                            }
                        }
                        if let closestLowerIndex = closestLowerIndex {
                            index = closestLowerIndex
                        }
                    } else if index != 0 {
                        var glyphStart: CGFloat = 0.0
                        CTLineGetOffsetForStringIndex(line.line, index, &glyphStart)
                        if transformedPoint.x < glyphStart {
                            var closestLowerIndex: Int?
                            let glyphRuns = CTLineGetGlyphRuns(line.line) as NSArray
                            if glyphRuns.count != 0 {
                                for run in glyphRuns {
                                    let run = run as! CTRun
                                    let glyphCount = CTRunGetGlyphCount(run)
                                    for i in 0 ..< glyphCount {
                                        var glyphIndex: CFIndex = 0
                                        CTRunGetStringIndices(run, CFRangeMake(i, 1), &glyphIndex)
                                        if glyphIndex < index {
                                            if let closestLowerIndexValue = closestLowerIndex {
                                                if closestLowerIndexValue < glyphIndex {
                                                    closestLowerIndex = glyphIndex
                                                }
                                            } else {
                                                closestLowerIndex = glyphIndex
                                            }
                                        }
                                    }
                                }
                            }
                            if let closestLowerIndex = closestLowerIndex {
                                index = closestLowerIndex
                            }
                        }
                    }
                    if index >= 0 && index < attributedString.length {
                        if let range = line.range, index < range.location + range.length {
                            return (index, attributedString.attributes(at: index, effectiveRange: nil))
                        }
                    }
                    break
                }
            }
        }
        return nil
    }
    
    public func linesRects() -> [CGRect] {
        var rects: [CGRect] = []
        for line in self.lines {
            rects.append(line.frame)
        }
        return rects
    }
    
    public func textRangesRects(text: String) -> [[CGRect]] {
        guard let attributedString = self.attributedString else {
            return []
        }
        
        let (ranges, searchText) = tiebaTextFindSubstringRanges(in: attributedString.string, query: text)

        var result: [[CGRect]] = []
        for stringRange in ranges {
            var rects: [CGRect] = []
            let range = NSRange(stringRange, in: searchText)
            for line in self.lines {
                guard let rangeValue = line.range else {
                    continue
                }
                let lineRange = NSIntersectionRange(range, rangeValue)
                if lineRange.length != 0 {
                    var leftOffset: CGFloat = 0.0
                    if lineRange.location != rangeValue.location {
                        leftOffset = floor(CTLineGetOffsetForStringIndex(line.line, lineRange.location, nil))
                    }
                    var rightOffset: CGFloat = line.frame.width
                    if lineRange.location + lineRange.length != rangeValue.length {
                        var secondaryOffset: CGFloat = 0.0
                        let rawOffset = CTLineGetOffsetForStringIndex(line.line, lineRange.location + lineRange.length, &secondaryOffset)
                        rightOffset = ceil(rawOffset)
                        if !tiebaTextIsEqual(rawOffset, secondaryOffset) {
                            rightOffset = ceil(secondaryOffset)
                        }
                    }
                    var lineFrame = CGRect(origin: CGPoint(x: line.frame.origin.x, y: line.frame.origin.y - line.frame.size.height + line.descent), size: line.frame.size)
                    lineFrame = tiebaTextDisplayLineFrame(frame: lineFrame, isRTL: line.isRTL, boundingRect: CGRect(origin: CGPoint(), size: self.size), cutout: self.cutout)
                    
                    let width = abs(rightOffset - leftOffset)
                    rects.append(CGRect(origin: CGPoint(x: lineFrame.minX + min(leftOffset, rightOffset) + self.insets.left, y: lineFrame.minY + self.insets.top), size: CGSize(width: width, height: lineFrame.size.height)))
                }
            }
            if !rects.isEmpty {
                result.append(rects)
            }
        }
        return result
    }
    
    public func attributeSubstring(name: String, index: Int) -> (String, String)? {
        if let attributedString = self.attributedString {
            var range = NSRange()
            let _ = attributedString.attribute(NSAttributedString.Key(rawValue: name), at: index, effectiveRange: &range)
            if range.length != 0 {
                return ((attributedString.string as NSString).substring(with: range), attributedString.string)
            }
        }
        return nil
    }
    
    public func attributeSubstringWithRange(name: String, index: Int) -> (String, String, NSRange)? {
        if let attributedString = self.attributedString {
            var range = NSRange()
            let _ = attributedString.attribute(NSAttributedString.Key(rawValue: name), at: index, effectiveRange: &range)
            if range.length != 0 {
                return ((attributedString.string as NSString).substring(with: range), attributedString.string, range)
            }
        }
        return nil
    }
    
    public func allAttributeRects(name: String) -> [(Any, CGRect)] {
        guard let attributedString = self.attributedString else {
            return []
        }
        var result: [(Any, CGRect)] = []
        attributedString.enumerateAttribute(NSAttributedString.Key(rawValue: name), in: NSRange(location: 0, length: attributedString.length), options: []) { (value, range, _) in
            if let value = value, range.length != 0 {
                var coveringRect = CGRect()
                for line in self.lines {
                    guard let rangeValue = line.range else {
                        continue
                    }
                    let lineRange = NSIntersectionRange(range, rangeValue)
                    if lineRange.length != 0 {
                        var leftOffset: CGFloat = 0.0
                        if lineRange.location != rangeValue.location {
                            leftOffset = floor(CTLineGetOffsetForStringIndex(line.line, lineRange.location, nil))
                        }
                        var rightOffset: CGFloat = line.frame.width
                        if lineRange.location + lineRange.length != rangeValue.length {
                            var secondaryOffset: CGFloat = 0.0
                            let rawOffset = CTLineGetOffsetForStringIndex(line.line, lineRange.location + lineRange.length, &secondaryOffset)
                            rightOffset = ceil(rawOffset)
                            if !tiebaTextIsEqual(rawOffset, secondaryOffset) {
                                rightOffset = ceil(secondaryOffset)
                            }
                        }
                        
                        var lineFrame = CGRect(origin: CGPoint(x: line.frame.origin.x, y: line.frame.origin.y - line.frame.size.height + line.descent), size: line.frame.size)
                        switch self.resolvedAlignment {
                            case .center:
                                lineFrame.origin.x = floor((self.size.width - lineFrame.size.width) / 2.0)
                            case .natural:
                                lineFrame = tiebaTextDisplayLineFrame(frame: lineFrame, isRTL: line.isRTL, boundingRect: CGRect(origin: CGPoint(), size: self.size), cutout: self.cutout)
                            case .right:
                                lineFrame.origin.x = self.size.width - lineFrame.size.width
                            default:
                                break
                        }
                        
                        let rect = CGRect(origin: CGPoint(x: lineFrame.minX + min(leftOffset, rightOffset) + self.insets.left, y: lineFrame.minY + self.insets.top), size: CGSize(width: abs(rightOffset - leftOffset), height: lineFrame.size.height))
                        if coveringRect.isEmpty {
                            coveringRect = rect
                        } else {
                            coveringRect = coveringRect.union(rect)
                        }
                    }
                }
                if !coveringRect.isEmpty {
                    result.append((value, coveringRect))
                }
            }
        }
        return result
    }
    
    public func lineAndAttributeRects(name: String, at index: Int) -> [(CGRect, CGRect)]? {
        if let attributedString = self.attributedString {
            var range = NSRange()
            let _ = attributedString.attribute(NSAttributedString.Key(rawValue: name), at: index, effectiveRange: &range)
            if range.length != 0 {
                var rects: [(CGRect, CGRect)] = []
                for line in self.lines {
                    guard let rangeValue = line.range else {
                        continue
                    }
                    let lineRange = NSIntersectionRange(range, rangeValue)
                    if lineRange.length != 0 {
                        var leftOffset: CGFloat = 0.0
                        if lineRange.location != rangeValue.location || line.isRTL {
                            leftOffset = floor(CTLineGetOffsetForStringIndex(line.line, lineRange.location, nil))
                        }
                        var rightOffset: CGFloat = line.frame.width
                        if lineRange.location + lineRange.length != rangeValue.length || line.isRTL {
                            var secondaryOffset: CGFloat = 0.0
                            let rawOffset = CTLineGetOffsetForStringIndex(line.line, lineRange.location + lineRange.length, &secondaryOffset)
                            rightOffset = ceil(rawOffset)
                            if !tiebaTextIsEqual(rawOffset, secondaryOffset) {
                                rightOffset = ceil(secondaryOffset)
                            }
                        }
                        var lineFrame = CGRect(origin: CGPoint(x: line.frame.origin.x, y: line.frame.origin.y - line.frame.size.height + line.descent), size: line.frame.size)
                        
                        lineFrame = tiebaTextDisplayLineFrame(frame: lineFrame, isRTL: line.isRTL, boundingRect: CGRect(origin: CGPoint(), size: self.size), cutout: self.cutout)
                        
                        let width = abs(rightOffset - leftOffset)
                        if width > 1.0 {
                            rects.append((lineFrame, CGRect(origin: CGPoint(x: lineFrame.minX + min(leftOffset, rightOffset) + self.insets.left, y: lineFrame.minY + self.insets.top), size: CGSize(width: width, height: lineFrame.size.height))))
                        }
                    }
                }
                if !rects.isEmpty {
                    return rects
                }
            }
        }
        return nil
    }
    
    public func rangeRects(in range: NSRange) -> (rects: [CGRect], start: TiebaTextRangeRectEdge, end: TiebaTextRangeRectEdge)? {
        guard let _ = self.attributedString, range.length != 0 else {
            return nil
        }
        var rects: [(CGRect, CGRect)] = []
        var startEdge: TiebaTextRangeRectEdge?
        var endEdge: TiebaTextRangeRectEdge?
        for line in self.lines {
            guard let rangeValue = line.range else {
                continue
            }
            let lineRange = NSIntersectionRange(range, rangeValue)
            if lineRange.length != 0 {
                var leftOffset: CGFloat = 0.0
                if lineRange.location != rangeValue.location || line.isRTL {
                    leftOffset = floor(CTLineGetOffsetForStringIndex(line.line, lineRange.location, nil))
                }
                var rightOffset: CGFloat = line.frame.width
                if lineRange.location + lineRange.length != rangeValue.upperBound || line.isRTL {
                    var secondaryOffset: CGFloat = 0.0
                    let rawOffset = CTLineGetOffsetForStringIndex(line.line, lineRange.location + lineRange.length, &secondaryOffset)
                    rightOffset = ceil(rawOffset)
                    if !tiebaTextIsEqual(rawOffset, secondaryOffset) {
                        rightOffset = ceil(secondaryOffset)
                    }
                }
                var lineFrame = CGRect(origin: CGPoint(x: line.frame.origin.x, y: line.frame.origin.y - line.frame.size.height + line.descent), size: line.frame.size)
                
                lineFrame = tiebaTextDisplayLineFrame(frame: lineFrame, isRTL: line.isRTL, boundingRect: CGRect(origin: CGPoint(), size: self.size), cutout: self.cutout)
                
                let width = max(0.0, abs(rightOffset - leftOffset))
                
                if rangeValue.contains(range.lowerBound) {
                    let offsetX = floor(CTLineGetOffsetForStringIndex(line.line, range.lowerBound, nil))
                    startEdge = TiebaTextRangeRectEdge(x: lineFrame.minX + offsetX, y: lineFrame.minY, height: lineFrame.height)
                }
                if rangeValue.contains(range.upperBound - 1) {
                    let offsetX: CGFloat
                    if rangeValue.upperBound == range.upperBound {
                        offsetX = lineFrame.maxX
                    } else {
                        var secondaryOffset: CGFloat = 0.0
                        let primaryOffset = floor(CTLineGetOffsetForStringIndex(line.line, range.upperBound - 1, &secondaryOffset))
                        secondaryOffset = floor(secondaryOffset)
                        let nextOffet = floor(CTLineGetOffsetForStringIndex(line.line, range.upperBound, &secondaryOffset))
                        
                        if primaryOffset != secondaryOffset {
                            offsetX = secondaryOffset
                        } else {
                            offsetX = nextOffet
                        }
                    }
                    endEdge = TiebaTextRangeRectEdge(x: lineFrame.minX + offsetX, y: lineFrame.minY, height: lineFrame.height)
                }
                
                rects.append((lineFrame, CGRect(origin: CGPoint(x: lineFrame.minX + min(leftOffset, rightOffset) + self.insets.left, y: lineFrame.minY + self.insets.top), size: CGSize(width: width, height: lineFrame.size.height))))
            }
        }
        if !rects.isEmpty, var startEdge = startEdge, var endEdge = endEdge {
            startEdge.x += self.insets.left
            startEdge.y += self.insets.top
            endEdge.x += self.insets.left
            endEdge.y += self.insets.top
            return (rects.map { $1 }, startEdge, endEdge)
        }
        return nil
    }
}

// MARK: - 上游 :1127-1197（排版辅助函数：剧透/内嵌项/附件矩形）

func tiebaTextAddSpoiler(line: TiebaTextNodeLine, ascent: CGFloat, descent: CGFloat, startIndex: Int, endIndex: Int) {
    var secondaryLeftOffset: CGFloat = 0.0
    let rawLeftOffset = CTLineGetOffsetForStringIndex(line.line, startIndex, &secondaryLeftOffset)
    var leftOffset = floor(rawLeftOffset)
    if !tiebaTextIsEqual(rawLeftOffset, secondaryLeftOffset) {
        leftOffset = floor(secondaryLeftOffset)
    }
    
    var secondaryRightOffset: CGFloat = 0.0
    let rawRightOffset = CTLineGetOffsetForStringIndex(line.line, endIndex, &secondaryRightOffset)
    var rightOffset = ceil(rawRightOffset)
    if !tiebaTextIsEqual(rawRightOffset, secondaryRightOffset) {
        rightOffset = ceil(secondaryRightOffset)
    }
    
    line.spoilers.append(TiebaTextNodeSpoiler(range: NSMakeRange(startIndex, endIndex - startIndex + 1), frame: CGRect(x: min(leftOffset, rightOffset), y: descent - (ascent + descent), width: abs(rightOffset - leftOffset), height: ascent + descent)))
}

func tiebaTextAddSpoilerWord(line: TiebaTextNodeLine, ascent: CGFloat, descent: CGFloat, startIndex: Int, endIndex: Int, rightInset: CGFloat = 0.0) {
    var secondaryLeftOffset: CGFloat = 0.0
    let rawLeftOffset = CTLineGetOffsetForStringIndex(line.line, startIndex, &secondaryLeftOffset)
    var leftOffset = floor(rawLeftOffset)
    if !tiebaTextIsEqual(rawLeftOffset, secondaryLeftOffset) {
        leftOffset = floor(secondaryLeftOffset)
    }
    
    var secondaryRightOffset: CGFloat = 0.0
    let rawRightOffset = CTLineGetOffsetForStringIndex(line.line, endIndex, &secondaryRightOffset)
    var rightOffset = ceil(rawRightOffset)
    if !tiebaTextIsEqual(rawRightOffset, secondaryRightOffset) {
        rightOffset = ceil(secondaryRightOffset)
    }
    
    line.spoilerWords.append(TiebaTextNodeSpoiler(range: NSMakeRange(startIndex, endIndex - startIndex + 1), frame: CGRect(x: min(leftOffset, rightOffset), y: descent - (ascent + descent), width: abs(rightOffset - leftOffset) + rightInset, height: ascent + descent)))
}

func tiebaTextAddEmbeddedItem(item: AnyHashable, line: TiebaTextNodeLine, ascent: CGFloat, descent: CGFloat, startIndex: Int, endIndex: Int, rightInset: CGFloat = 0.0) {
    var secondaryLeftOffset: CGFloat = 0.0
    let rawLeftOffset = CTLineGetOffsetForStringIndex(line.line, startIndex, &secondaryLeftOffset)
    var leftOffset = floor(rawLeftOffset)
    if !tiebaTextIsEqual(rawLeftOffset, secondaryLeftOffset) {
        leftOffset = floor(secondaryLeftOffset)
    }
    
    var secondaryRightOffset: CGFloat = 0.0
    let rawRightOffset = CTLineGetOffsetForStringIndex(line.line, endIndex, &secondaryRightOffset)
    var rightOffset = ceil(rawRightOffset)
    if !tiebaTextIsEqual(rawRightOffset, secondaryRightOffset) {
        rightOffset = ceil(secondaryRightOffset)
    }
    
    line.embeddedItems.append(TiebaTextNodeEmbeddedItem(range: NSMakeRange(startIndex, endIndex - startIndex + 1), frame: CGRect(x: min(leftOffset, rightOffset), y: descent - (ascent + descent), width: abs(rightOffset - leftOffset) + rightInset, height: ascent + descent), item: item))
}

func tiebaTextAddAttachment(attachment: UIImage, line: TiebaTextNodeLine, ascent: CGFloat, descent: CGFloat, startIndex: Int, endIndex: Int, rightInset: CGFloat = 0.0) {
    var secondaryLeftOffset: CGFloat = 0.0
    let rawLeftOffset = CTLineGetOffsetForStringIndex(line.line, startIndex, &secondaryLeftOffset)
    var leftOffset = floor(rawLeftOffset)
    if !tiebaTextIsEqual(rawLeftOffset, secondaryLeftOffset) {
        leftOffset = floor(secondaryLeftOffset)
    }
    
    var secondaryRightOffset: CGFloat = 0.0
    let rawRightOffset = CTLineGetOffsetForStringIndex(line.line, endIndex, &secondaryRightOffset)
    var rightOffset = ceil(rawRightOffset)
    if !tiebaTextIsEqual(rawRightOffset, secondaryRightOffset) {
        rightOffset = ceil(secondaryRightOffset)
    }
    
    line.attachments.append(TiebaTextNodeAttachment(range: NSMakeRange(startIndex, endIndex - startIndex), frame: CGRect(x: min(leftOffset, rightOffset), y: descent - (ascent + descent), width: abs(rightOffset - leftOffset) + rightInset, height: ascent + descent), attachment: attachment))
}
