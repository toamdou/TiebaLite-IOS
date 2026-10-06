// 移植自上游: submodules/Display/Source/TextNode.swift 的排版/测量/绘制静态实现
// （上游 :1206-1240 的类型 + :1309-2798 的 calculateLayoutV2 / calculateLayout / draw），
// 以及 submodules/Display/Source/GenerateImage.swift:302 的 generateTintedImage。
//
// 本文件 = 排版算法与绘制，全部收进 enum TiebaTextNode 命名空间（上游是 open class TextNode: ASDisplayNode 的
// 静态成员）。数据模型在 TiebaTextNodeLayout.swift，UIView 外壳在 TiebaTextView.swift。
//
// 改动清单：
//  1) [外壳] 上游 open class TextNode: ASDisplayNode(:1205) 用 ASDisplayNode 承担"后台排版 + 异步绘制"；
//     enum TiebaTextNode 只保留静态计算与绘制函数，异步/缓存策略交给 TiebaTextView.asyncLayout，
//     绘制入口改为直接接收 DrawingParameters（不再经 _ASDisplayLayer 的 drawParameters(forAsyncLayer:) 回调，
//     上游 :2298-2301 因此删除）。
//  2) [签名] 上游 `@objc override public class func draw(_:withParameters:isCancelled:isRasterizing:)`(:2302)
//     的参数是 Any?（由 ASDK 传递）；本模块改为强类型 `withParameters parameters: DrawingParameters`，
//     函数体只把取参数的两行改成直接解包，其余逐行照搬。
//  3) [删除 ASDK 绘制钩子] 上游 :2298-2301 `drawParameters(forAsyncLayer: _ASDisplayLayer)`（ASDK 私有层类型）
//     删除；等价信息由调用方构造 DrawingParameters 传入（TiebaTextView.draw(_:) 即上游 TextView.draw(:2915) 的做法）。
//  4) [SPI] 上游 :2311/:2314/:2317 调用 CGContext.setAllowsFontSmoothing / setAllowsFontSubpixelPositioning /
//     setAllowsFontSubpixelQuantization —— 这三个是 CoreGraphics 私有 SPI，本仓不引入私有 API，故删除；
//     对应的公开开关 setShouldSmoothFonts / setShouldSubpixelPositionFonts / setShouldSubpixelQuantizeFonts
//     按上游原值保留（字体平滑最终由这三个公开开关决定，渲染结果一致）。
//  5) [依赖内联] 上游 generateTintedImage(:GenerateImage.swift:302)用于给内嵌表情/附件着色，本仓未移植该文件，
//     这里以内联的 tiebaTextGenerateTintedImage 逐行照搬（纯 UIKit，无 AS*）。
//  6) [改名] 类型名与上游一致地加 Tieba 前缀；DrawingParameters / RenderContentTypes 作为
//     TiebaTextNode 的嵌套类型保留原名（铁律 6 允许放进 TiebaXxx 命名空间）。
//  7) [Swift 6] 未使用 @preconcurrency / nonisolated(unsafe) / @unchecked Sendable；这些静态函数只做纯计算与
//     CoreGraphics 绘制，天然 nonisolated（enum 无隔离），调用方（MainActor 的 TiebaTextView）可直接同步调用。
//     DrawingParameters 是 NSObject 子类、TextNodeLayout 内是 CTLine，都不是 Sendable——它们只在同一隔离域内
//     传递，编译器按"非 Sendable 值不跨隔离域"静态拦住越界使用。
//  8) 算法一行未改。

import Foundation
import UIKit
import CoreText

public enum TiebaTextNode {

    // [Swift 6] public 值类型不会自动推断 Sendable，而 .text/.emoji/.all 是 static let 全局量，
    // 必须显式声明 Sendable（纯 OptionSet + Int，静态检查可证，不是 @unchecked）。
    public struct RenderContentTypes: OptionSet, Sendable {
        public var rawValue: Int
        
        public init(rawValue: Int) {
            self.rawValue = rawValue
        }
        
        public static let text = RenderContentTypes(rawValue: 1 << 0)
        public static let emoji = RenderContentTypes(rawValue: 1 << 1)
        
        public static let all: RenderContentTypes = [.text, .emoji]
    }
    
    public final class DrawingParameters: NSObject {
        let cachedLayout: TiebaTextNodeLayout?
        let renderContentTypes: RenderContentTypes
        
        public init(cachedLayout: TiebaTextNodeLayout?, renderContentTypes: RenderContentTypes) {
            self.cachedLayout = cachedLayout
            self.renderContentTypes = renderContentTypes
            
            super.init()
        }
    }
    
    private static func shouldRenderAttachment(_ image: UIImage, renderContentTypes: RenderContentTypes) -> Bool {
        if renderContentTypes == .all {
            return true
        }
        if image.renderingMode == .alwaysOriginal {
            return renderContentTypes.contains(.emoji)
        } else {
            return renderContentTypes.contains(.text)
        }
    }

    // [移植] 上游 Display/Source/GenerateImage.swift:302 generateTintedImage(image:color:backgroundColor:)，
    // 逐行照搬（纯 UIKit/CoreGraphics）。draw(:2621) 用它给内嵌项/表情按当前文字色着色。
    static func tiebaTextGenerateTintedImage(image: UIImage?, color: UIColor, backgroundColor: UIColor? = nil) -> UIImage? {
        guard let image = image else {
            return nil
        }

        let imageSize = image.size

        UIGraphicsBeginImageContextWithOptions(imageSize, backgroundColor != nil, image.scale)
        if let context = UIGraphicsGetCurrentContext() {
            if let backgroundColor = backgroundColor {
                context.setFillColor(backgroundColor.cgColor)
                context.fill(CGRect(origin: CGPoint(), size: imageSize))
            }

            let imageRect = CGRect(origin: CGPoint(), size: imageSize)
            context.saveGState()
            context.translateBy(x: imageRect.midX, y: imageRect.midY)
            context.scaleBy(x: 1.0, y: -1.0)
            context.translateBy(x: -imageRect.midX, y: -imageRect.midY)
            context.clip(to: imageRect, mask: image.cgImage!)
            context.setFillColor(color.cgColor)
            context.fill(imageRect)
            context.restoreGState()
        }

        let tintedImage = UIGraphicsGetImageFromCurrentImageContext()!
        UIGraphicsEndImageContext()

        return tintedImage
    }

    // [移植] 上游 TextNode.swift:9 / :13 的 quoteIcon / codeIcon：走 AppBundle 的
    // UIImage(bundleImageName: "Chat/Message/ReplyQuoteIcon" / "Chat/Message/TextCodeIcon")。
    // 本仓没有 上游资源包，故置 nil —— 效果等同于上游取不到资源：block quote 的底色/竖条照画，
    // 只是不叠加角标图标。绘制处按上游结构加 if let 解包，其余绘制指令逐行照搬。
    static let quoteIcon: UIImage? = nil
    static let codeIcon: UIImage? = nil

    // [移植] 上游 Display/Source/UIKitUtils.swift:95 的 UIColor.alpha（逐行照搬）。
    // 本仓 UI/Drawing 组可能移植同名 UIColor 扩展，为避免同名重复声明，这里以命名空间内的函数内联。
    static func colorAlpha(_ color: UIColor) -> CGFloat {
        var alpha: CGFloat = 0.0
        if color.getRed(nil, green: nil, blue: nil, alpha: &alpha) {
            return alpha
        } else if color.getWhite(nil, alpha: &alpha) {
            return alpha
        } else {
            return 0.0
        }
    }

    // [移植] 上游 Display/Source/UIKitUtils.swift:407 的 withMultipliedAlpha（逐行照搬）。
    static func withMultipliedAlpha(_ color: UIColor, _ alpha: CGFloat) -> UIColor {
        var r1: CGFloat = 0.0
        var g1: CGFloat = 0.0
        var b1: CGFloat = 0.0
        var a1: CGFloat = 0.0
        if color.getRed(&r1, green: &g1, blue: &b1, alpha: &a1) {
            return UIColor(red: r1, green: g1, blue: b1, alpha: max(0.0, min(1.0, a1 * alpha)))
        }
        return color
    }

    public static func calculateLayoutV2(
        attributedString: NSAttributedString,
        minimumNumberOfLines: Int,
        maximumNumberOfLines: Int,
        truncationType: CTLineTruncationType,
        backgroundColor: UIColor?,
        constrainedSize: CGSize,
        alignment: NSTextAlignment,
        verticalAlignment: TiebaTextVerticalAlignment,
        lineSpacingFactor: CGFloat,
        cutout: TiebaTextNodeCutout?,
        insets: UIEdgeInsets,
        lineColor: UIColor?,
        textShadowColor: UIColor?,
        textShadowBlur: CGFloat?,
        textStroke: (UIColor, CGFloat)?,
        displaySpoilers: Bool,
        displayEmbeddedItemsUnderSpoilers: Bool,
        customTruncationToken: NSAttributedString?
    ) -> TiebaTextNodeLayout {
        let blockQuoteLeftInset: CGFloat = 9.0
        let blockQuoteRightInset: CGFloat = 0.0
        let blockQuoteIconInset: CGFloat = 7.0
        
        struct StringSegment {
            let title: NSAttributedString?
            let substring: NSAttributedString
            let firstCharacterOffset: Int
            let blockQuote: TiebaTextNodeBlockQuoteData?
            let tintColor: UIColor?
            let secondaryTintColor: UIColor?
            let tertiaryTintColor: UIColor?
        }
        var stringSegments: [StringSegment] = []
        
        let rawWholeString = attributedString.string as NSString
        let wholeStringLength = rawWholeString.length
        
        var segmentCharacterOffset = 0
        while true {
            var found = false
            attributedString.enumerateAttribute(NSAttributedString.Key("Attribute__Blockquote"), in: NSRange(location: segmentCharacterOffset, length: wholeStringLength - segmentCharacterOffset), using: { value, effectiveRange, stop in
                found = true
                stop.pointee = ObjCBool(true)
                
                if segmentCharacterOffset != effectiveRange.location {
                    stringSegments.append(StringSegment(
                        title: nil,
                        substring: attributedString.attributedSubstring(from: NSRange(
                            location: segmentCharacterOffset,
                            length: effectiveRange.location - segmentCharacterOffset
                        )),
                        firstCharacterOffset: segmentCharacterOffset,
                        blockQuote: nil,
                        tintColor: nil,
                        secondaryTintColor: nil,
                        tertiaryTintColor: nil
                    ))
                }
                
                if let value = value as? TiebaTextNodeBlockQuoteData {
                    if effectiveRange.length != 0 {
                        stringSegments.append(StringSegment(
                            title: value.title,
                            substring: attributedString.attributedSubstring(from: effectiveRange),
                            firstCharacterOffset: effectiveRange.location,
                            blockQuote: value,
                            tintColor: value.color,
                            secondaryTintColor: value.secondaryColor,
                            tertiaryTintColor: value.tertiaryColor
                        ))
                    }
                    segmentCharacterOffset = effectiveRange.location + effectiveRange.length
                    if segmentCharacterOffset < wholeStringLength && rawWholeString.character(at: segmentCharacterOffset) == 0x0a {
                        segmentCharacterOffset += 1
                    }
                } else {
                    stringSegments.append(StringSegment(
                        title: nil,
                        substring: attributedString.attributedSubstring(from: effectiveRange),
                        firstCharacterOffset: effectiveRange.location,
                        blockQuote: nil,
                        tintColor: nil,
                        secondaryTintColor: nil,
                        tertiaryTintColor: nil
                    ))
                    segmentCharacterOffset = effectiveRange.location + effectiveRange.length
                }
            })
            if !found {
                if segmentCharacterOffset != wholeStringLength {
                    stringSegments.append(StringSegment(
                        title: nil,
                        substring: attributedString.attributedSubstring(from: NSRange(
                            location: segmentCharacterOffset,
                            length: wholeStringLength - segmentCharacterOffset
                        )),
                        firstCharacterOffset: segmentCharacterOffset,
                        blockQuote: nil,
                        tintColor: nil,
                        secondaryTintColor: nil,
                        tertiaryTintColor: nil
                    ))
                }
                
                break
            }
        }
        
        struct CalculatedSegment {
            var titleLine: TiebaTextNodeLine?
            var lines: [TiebaTextNodeLine] = []
            var tintColor: UIColor?
            var secondaryTintColor: UIColor?
            var tertiaryTintColor: UIColor?
            var blockQuote: TiebaTextNodeBlockQuoteData?
            var additionalWidth: CGFloat = 0.0
        }
        
        var calculatedSegments: [CalculatedSegment] = []
        
        for segment in stringSegments {
            var calculatedSegment = CalculatedSegment()
            calculatedSegment.blockQuote = segment.blockQuote
            calculatedSegment.tintColor = segment.tintColor
            calculatedSegment.secondaryTintColor = segment.secondaryTintColor
            calculatedSegment.tertiaryTintColor = segment.tertiaryTintColor
            
            let rawSubstring = segment.substring.string as NSString
            let substringLength = rawSubstring.length
            
            let segmentTypesetterString = attributedString.attributedSubstring(from: NSRange(location: 0, length: segment.firstCharacterOffset + substringLength))
            let typesetter = CTTypesetterCreateWithAttributedString(segmentTypesetterString as CFAttributedString)
            
            var currentLineStartIndex = segment.firstCharacterOffset
            let segmentEndIndex = segment.firstCharacterOffset + substringLength
            
            var constrainedSegmentWidth = constrainedSize.width
            var additionalOffsetX: CGFloat = 0.0
            if segment.blockQuote != nil {
                additionalOffsetX += blockQuoteLeftInset
                constrainedSegmentWidth -= additionalOffsetX + blockQuoteLeftInset + blockQuoteRightInset
                calculatedSegment.additionalWidth += blockQuoteLeftInset + blockQuoteRightInset
            }
            
            var additionalSegmentRightInset: CGFloat = 0.0
            if let blockQuote = segment.blockQuote {
                switch blockQuote.kind {
                case .quote:
                    additionalSegmentRightInset = blockQuoteIconInset
                case .code:
                    if segment.title != nil {
                        additionalSegmentRightInset = blockQuoteIconInset
                    }
                }
            }
            
            if let title = segment.title {
                let rawTitleLine = CTLineCreateWithAttributedString(title)
                if let titleLine = CTLineCreateTruncatedLine(rawTitleLine, constrainedSegmentWidth - additionalSegmentRightInset, .end, nil) {
                    var lineAscent: CGFloat = 0.0
                    var lineDescent: CGFloat = 0.0
                    let lineWidth = CTLineGetTypographicBounds(titleLine, &lineAscent, &lineDescent, nil)
                    calculatedSegment.titleLine = TiebaTextNodeLine(
                        line: titleLine,
                        frame: CGRect(origin: CGPoint(x: additionalOffsetX, y: 0.0), size: CGSize(width: lineWidth + additionalSegmentRightInset, height: lineAscent + lineDescent)),
                        ascent: lineAscent,
                        descent: lineDescent,
                        range: nil,
                        isRTL: false,
                        backgrounds: [],
                        strikethroughs: [],
                        underlines: [],
                        spoilers: [],
                        spoilerWords: [],
                        embeddedItems: [],
                        attachments: [],
                        additionalTrailingLine: nil
                    )
                    additionalSegmentRightInset = 0.0
                }
            }
            
            while true {
                let lineCharacterCount = CTTypesetterSuggestLineBreak(typesetter, currentLineStartIndex, constrainedSegmentWidth - additionalSegmentRightInset)
                
                if lineCharacterCount != 0 {
                    let line = CTTypesetterCreateLine(typesetter, CFRange(location: currentLineStartIndex, length: lineCharacterCount))
                    var lineAscent: CGFloat = 0.0
                    var lineDescent: CGFloat = 0.0
                    var lineWidth = CTLineGetTypographicBounds(line, &lineAscent, &lineDescent, nil)
                    lineWidth = min(lineWidth, constrainedSegmentWidth - additionalSegmentRightInset)
                    
                    var isRTL = false
                    let glyphRuns = CTLineGetGlyphRuns(line) as NSArray
                    if glyphRuns.count != 0 {
                        let run = glyphRuns[0] as! CTRun
                        if CTRunGetStatus(run).contains(CTRunStatus.rightToLeft) {
                            isRTL = true
                        }
                    }
                    
                    calculatedSegment.lines.append(TiebaTextNodeLine(
                        line: line,
                        frame: CGRect(origin: CGPoint(x: additionalOffsetX, y: 0.0), size: CGSize(width: lineWidth + additionalSegmentRightInset, height: lineAscent + lineDescent)),
                        ascent: lineAscent,
                        descent: lineDescent,
                        range: NSRange(location: currentLineStartIndex, length: lineCharacterCount),
                        isRTL: isRTL && segment.blockQuote == nil,
                        backgrounds: [],
                        strikethroughs: [],
                        underlines: [],
                        spoilers: [],
                        spoilerWords: [],
                        embeddedItems: [],
                        attachments: [],
                        additionalTrailingLine: nil
                    ))
                }
                
                additionalSegmentRightInset = 0.0
                
                currentLineStartIndex += lineCharacterCount
                
                if currentLineStartIndex >= segmentEndIndex {
                    break
                }
            }
            
            calculatedSegments.append(calculatedSegment)
        }
        
        var size = CGSize()
        let isTruncated = false
        
        for segment in calculatedSegments {
            if let titleLine = segment.titleLine {
                size.width = max(size.width, titleLine.frame.origin.x + titleLine.frame.width + segment.additionalWidth)
            }
            for line in segment.lines {
                size.width = max(size.width, line.frame.origin.x + line.frame.width + segment.additionalWidth)
            }
        }
        
        var lines: [TiebaTextNodeLine] = []
        
        var blockQuotes: [TiebaTextNodeBlockQuote] = []
        
        for i in 0 ..< calculatedSegments.count {
            let segment = calculatedSegments[i]
            if i != 0 {
                if segment.blockQuote != nil {
                    size.height += 6.0
                }
            } else {
                if segment.blockQuote != nil {
                    size.height += 7.0
                }
            }
            
            let blockMinY = size.height - insets.bottom
            var blockWidth: CGFloat = 0.0
            
            if let titleLine = segment.titleLine {
                titleLine.frame = CGRect(origin: CGPoint(x: titleLine.frame.origin.x, y: -insets.bottom + size.height + titleLine.frame.size.height), size: titleLine.frame.size)
                titleLine.frame.size.width += max(0.0, segment.additionalWidth - 2.0)
                size.height += titleLine.frame.height + titleLine.frame.height * lineSpacingFactor
                blockWidth = max(blockWidth, titleLine.frame.origin.x + titleLine.frame.width)
                
                lines.append(titleLine)
            }
            
            for line in segment.lines {
                line.frame = CGRect(origin: CGPoint(x: line.frame.origin.x, y: -insets.bottom + size.height + line.frame.size.height), size: line.frame.size)
                line.frame.size.width += max(0.0, segment.additionalWidth - 2.0)
                size.height += line.frame.height + line.frame.height * lineSpacingFactor
                blockWidth = max(blockWidth, line.frame.origin.x + line.frame.width)
                
                if let lineRange = line.range {
                    attributedString.enumerateAttributes(in: lineRange, options: []) { attributes, range, _ in
                        if attributes[NSAttributedString.Key(rawValue: "TiebaSpoiler")] != nil || attributes[NSAttributedString.Key(rawValue: "Attribute__Spoiler")] != nil {
                            var ascent: CGFloat = 0.0
                            var descent: CGFloat = 0.0
                            CTLineGetTypographicBounds(line.line, &ascent, &descent, nil)
                            
                            var startIndex: Int?
                            var currentIndex: Int?
                            
                            let nsString = (attributedString.string as NSString)
                            nsString.enumerateSubstrings(in: range, options: .byComposedCharacterSequences) { substring, range, _, _ in
                                if let substring = substring, substring.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
                                    if let currentStartIndex = startIndex {
                                        startIndex = nil
                                        let endIndex = range.location
                                        tiebaTextAddSpoilerWord(line: line, ascent: ascent, descent: descent, startIndex: currentStartIndex, endIndex: endIndex)
                                    }
                                } else if startIndex == nil {
                                    startIndex = range.location
                                }
                                currentIndex = range.location + range.length
                            }
                            
                            if let currentStartIndex = startIndex, let currentIndex = currentIndex {
                                startIndex = nil
                                let endIndex = currentIndex
                                tiebaTextAddSpoilerWord(line: line, ascent: ascent, descent: descent, startIndex: currentStartIndex, endIndex: endIndex, rightInset: 0.0)
                            }
                            
                            tiebaTextAddSpoiler(line: line, ascent: ascent, descent: descent, startIndex: range.location, endIndex: range.location + range.length)
                        } else if let _ = attributes[NSAttributedString.Key.strikethroughStyle] {
                            let clampedEnd = max(range.location, min(lineRange.location + lineRange.length, range.location + range.length))
                            let lowerX = floor(CTLineGetOffsetForStringIndex(line.line, range.location, nil))
                            let upperX = ceil(CTLineGetOffsetForStringIndex(line.line, clampedEnd, nil))
                            let x = lowerX < upperX ? lowerX : upperX
                            line.strikethroughs.append(TiebaTextNodeStrikethrough(range: range, frame: CGRect(x: x, y: 0.0, width: abs(upperX - lowerX), height: line.frame.height), color: nil, style: .single))
                        }
                        
                        if let embeddedItem = (attributes[NSAttributedString.Key(rawValue: "TiebaEmbeddedItem")] as? AnyHashable ?? attributes[NSAttributedString.Key(rawValue: "Attribute__EmbeddedItem")] as? AnyHashable) {
                            if displayEmbeddedItemsUnderSpoilers || (attributes[NSAttributedString.Key(rawValue: "TiebaSpoiler")] == nil && attributes[NSAttributedString.Key(rawValue: "Attribute__Spoiler")] == nil) {
                                var ascent: CGFloat = 0.0
                                var descent: CGFloat = 0.0
                                CTLineGetTypographicBounds(line.line, &ascent, &descent, nil)
                                
                                tiebaTextAddEmbeddedItem(item: embeddedItem, line: line, ascent: ascent, descent: descent, startIndex: range.location, endIndex: range.location + range.length)
                            }
                        }
                        
                        if let attachment = attributes[NSAttributedString.Key.attachment] as? UIImage {
                            var ascent: CGFloat = 0.0
                            var descent: CGFloat = 0.0
                            CTLineGetTypographicBounds(line.line, &ascent, &descent, nil)
                            
                            tiebaTextAddAttachment(attachment: attachment, line: line, ascent: ascent, descent: descent, startIndex: range.location, endIndex: range.location + range.length)
                        }
                    }
                }
                
                lines.append(line)
            }
            
            let blockMaxY = size.height - insets.bottom
            
            if i != calculatedSegments.count - 1 {
                if segment.blockQuote != nil {
                    size.height += 8.0
                }
            } else {
                if segment.blockQuote != nil {
                    size.height += 6.0
                }
            }
            
            if let blockQuote = segment.blockQuote, let tintColor = segment.tintColor {
                blockQuotes.append(TiebaTextNodeBlockQuote(frame: CGRect(origin: CGPoint(x: 0.0, y: blockMinY - 2.0), size: CGSize(width: blockWidth, height: blockMaxY - (blockMinY - 2.0) + 4.0)), data: blockQuote, tintColor: tintColor, secondaryTintColor: segment.secondaryTintColor, tertiaryTintColor: segment.tertiaryTintColor, backgroundColor: blockQuote.backgroundColor))
            }
        }
        
        size.width = ceil(size.width)
        size.height = ceil(size.height)
        
        let rawTextSize = size
        size.width += insets.left + insets.right
        size.height += insets.top + insets.bottom
        
        return TiebaTextNodeLayout(
            attributedString: attributedString,
            maximumNumberOfLines: maximumNumberOfLines,
            truncationType: truncationType,
            constrainedSize: constrainedSize,
            explicitAlignment: alignment,
            resolvedAlignment: alignment,
            verticalAlignment: verticalAlignment,
            lineSpacing: lineSpacingFactor,
            cutout: cutout,
            insets: insets,
            size: size,
            rawTextSize: rawTextSize,
            truncated: isTruncated,
            firstLineOffset: lines.first?.descent ?? 0.0,
            lines: lines,
            blockQuotes: blockQuotes,
            backgroundColor: backgroundColor,
            lineColor: lineColor,
            textShadowColor: textShadowColor,
            textShadowBlur: textShadowBlur,
            textStroke: textStroke,
            displaySpoilers: displaySpoilers
        )
    }
    

    public static func calculateLayout(attributedString: NSAttributedString?, minimumNumberOfLines: Int, maximumNumberOfLines: Int, truncationType: CTLineTruncationType, backgroundColor: UIColor?, constrainedSize: CGSize, alignment: NSTextAlignment, verticalAlignment: TiebaTextVerticalAlignment, lineSpacingFactor: CGFloat, cutout: TiebaTextNodeCutout?, insets: UIEdgeInsets, lineColor: UIColor?, textShadowColor: UIColor?, textShadowBlur: CGFloat?, textStroke: (UIColor, CGFloat)?, displaySpoilers: Bool, displayEmbeddedItemsUnderSpoilers: Bool, customTruncationToken: NSAttributedString?) -> TiebaTextNodeLayout {
        guard let attributedString else {
            return TiebaTextNodeLayout(attributedString: attributedString, maximumNumberOfLines: maximumNumberOfLines, truncationType: truncationType, constrainedSize: constrainedSize, explicitAlignment: alignment, resolvedAlignment: alignment, verticalAlignment: verticalAlignment, lineSpacing: lineSpacingFactor, cutout: cutout, insets: insets, size: CGSize(), rawTextSize: CGSize(), truncated: false, firstLineOffset: 0.0, lines: [], blockQuotes: [], backgroundColor: backgroundColor, lineColor: lineColor, textShadowColor: textShadowColor, textShadowBlur: textShadowBlur, textStroke: textStroke, displaySpoilers: displaySpoilers)
        }
        
        var found = false
        attributedString.enumerateAttribute(NSAttributedString.Key("Attribute__Blockquote"), in: NSRange(location: 0, length: attributedString.length), using: { value, effectiveRange, _ in
            if let _ = value as? TiebaTextNodeBlockQuoteData {
                found = true
            }
        })
        
        if found {
            return calculateLayoutV2(attributedString: attributedString, minimumNumberOfLines: minimumNumberOfLines, maximumNumberOfLines: maximumNumberOfLines, truncationType: truncationType, backgroundColor: backgroundColor, constrainedSize: constrainedSize, alignment: alignment, verticalAlignment: verticalAlignment, lineSpacingFactor: lineSpacingFactor, cutout: cutout, insets: insets, lineColor: lineColor, textShadowColor: textShadowColor, textShadowBlur: textShadowBlur, textStroke: textStroke, displaySpoilers: displaySpoilers, displayEmbeddedItemsUnderSpoilers: displayEmbeddedItemsUnderSpoilers, customTruncationToken: customTruncationToken)
        }
        
        let stringLength = attributedString.length
        
        let font: CTFont
        let resolvedAlignment: NSTextAlignment
        
        if stringLength != 0 {
            if let stringFont = attributedString.attribute(NSAttributedString.Key.font, at: 0, effectiveRange: nil) {
                font = stringFont as! CTFont
            } else {
                font = tiebaTextDefaultFont
            }
            if alignment == .center {
                resolvedAlignment = .center
            } else {
                if let paragraphStyle = attributedString.attribute(NSAttributedString.Key.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle {
                    resolvedAlignment = paragraphStyle.alignment
                } else {
                    resolvedAlignment = alignment
                }
            }
        } else {
            font = tiebaTextDefaultFont
            resolvedAlignment = alignment
        }
        
        let fontAscent = CTFontGetAscent(font)
        let fontDescent = CTFontGetDescent(font)
        let fontLineHeight = floor(fontAscent + fontDescent)
        let fontLineSpacing = floor(fontLineHeight * lineSpacingFactor)
        
        var lines: [TiebaTextNodeLine] = []
        let blockQuotes: [TiebaTextNodeBlockQuote] = []
        
        var maybeTypesetter: CTTypesetter?
        maybeTypesetter = CTTypesetterCreateWithAttributedString(attributedString as CFAttributedString)
        if maybeTypesetter == nil {
            return TiebaTextNodeLayout(attributedString: attributedString, maximumNumberOfLines: maximumNumberOfLines, truncationType: truncationType, constrainedSize: constrainedSize, explicitAlignment: alignment, resolvedAlignment: resolvedAlignment, verticalAlignment: verticalAlignment, lineSpacing: lineSpacingFactor, cutout: cutout, insets: insets, size: CGSize(), rawTextSize: CGSize(), truncated: false, firstLineOffset: 0.0, lines: [], blockQuotes: [], backgroundColor: backgroundColor, lineColor: lineColor, textShadowColor: textShadowColor, textShadowBlur: textShadowBlur, textStroke: textStroke, displaySpoilers: displaySpoilers)
        }
        
        let typesetter = maybeTypesetter!
        
        var lastLineCharacterIndex: CFIndex = 0
        var layoutSize = CGSize()
        
        var cutoutEnabled = false
        var cutoutMinY: CGFloat = 0.0
        var cutoutMaxY: CGFloat = 0.0
        var cutoutWidth: CGFloat = 0.0
        var cutoutOffset: CGFloat = 0.0
        
        var bottomCutoutEnabled = false
        var bottomCutoutSize = CGSize()
                    
        if let topLeft = cutout?.topLeft {
            cutoutMinY = -fontLineSpacing
            cutoutMaxY = topLeft.height + fontLineSpacing
            cutoutWidth = topLeft.width
            cutoutOffset = cutoutWidth
            cutoutEnabled = true
        } else if let topRight = cutout?.topRight {
            cutoutMinY = -fontLineSpacing
            cutoutMaxY = topRight.height + fontLineSpacing
            cutoutWidth = topRight.width
            cutoutEnabled = true
        }
        
        if let bottomRight = cutout?.bottomRight {
            bottomCutoutSize = bottomRight
            bottomCutoutEnabled = true
        }
        
        let firstLineOffset = tiebaTextFloorToScreenPixels(fontDescent)
        
        var truncated = false
        var first = true
        while true {
            var backgrounds: [TiebaTextNodeStrikethrough] = []
            var strikethroughs: [TiebaTextNodeStrikethrough] = []
            var underlines: [TiebaTextNodeStrikethrough] = []
            var spoilers: [TiebaTextNodeSpoiler] = []
            var spoilerWords: [TiebaTextNodeSpoiler] = []
            var embeddedItems: [TiebaTextNodeEmbeddedItem] = []
            var attachments: [TiebaTextNodeAttachment] = []
            
            var lineConstrainedWidth = constrainedSize.width
            var lineConstrainedWidthDelta: CGFloat = 0.0
            var lineOriginY = tiebaTextFloorToScreenPixels(layoutSize.height + fontAscent)
            if !first {
                lineOriginY += fontLineSpacing
            }
            var lineCutoutOffset: CGFloat = 0.0
            var lineAdditionalWidth: CGFloat = 0.0
            
            if cutoutEnabled {
                if lineOriginY - fontLineHeight < cutoutMaxY && lineOriginY + fontLineHeight > cutoutMinY {
                    lineConstrainedWidth = max(1.0, lineConstrainedWidth - cutoutWidth)
                    lineConstrainedWidthDelta = -cutoutWidth
                    lineCutoutOffset = cutoutOffset
                    lineAdditionalWidth = cutoutWidth
                }
            }
            
            let lineCharacterCount = CTTypesetterSuggestLineBreak(typesetter, lastLineCharacterIndex, Double(lineConstrainedWidth))
            
            func tiebaTextAddSpoiler(line: CTLine, ascent: CGFloat, descent: CGFloat, startIndex: Int, endIndex: Int) {
                var secondaryLeftOffset: CGFloat = 0.0
                let rawLeftOffset = CTLineGetOffsetForStringIndex(line, startIndex, &secondaryLeftOffset)
                var leftOffset = floor(rawLeftOffset)
                if !tiebaTextIsEqual(rawLeftOffset, secondaryLeftOffset) {
                    leftOffset = floor(secondaryLeftOffset)
                }
                
                var secondaryRightOffset: CGFloat = 0.0
                let rawRightOffset = CTLineGetOffsetForStringIndex(line, endIndex, &secondaryRightOffset)
                var rightOffset = ceil(rawRightOffset)
                if !tiebaTextIsEqual(rawRightOffset, secondaryRightOffset) {
                    rightOffset = ceil(secondaryRightOffset)
                }
                
                spoilers.append(TiebaTextNodeSpoiler(range: NSMakeRange(startIndex, endIndex - startIndex + 1), frame: CGRect(x: min(leftOffset, rightOffset), y: descent - (ascent + descent), width: abs(rightOffset - leftOffset), height: ascent + descent)))
            }
            
            func tiebaTextAddSpoilerWord(line: CTLine, ascent: CGFloat, descent: CGFloat, startIndex: Int, endIndex: Int, rightInset: CGFloat = 0.0) {
                var secondaryLeftOffset: CGFloat = 0.0
                let rawLeftOffset = CTLineGetOffsetForStringIndex(line, startIndex, &secondaryLeftOffset)
                var leftOffset = floor(rawLeftOffset)
                if !tiebaTextIsEqual(rawLeftOffset, secondaryLeftOffset) {
                    leftOffset = floor(secondaryLeftOffset)
                }
                
                var secondaryRightOffset: CGFloat = 0.0
                let rawRightOffset = CTLineGetOffsetForStringIndex(line, endIndex, &secondaryRightOffset)
                var rightOffset = ceil(rawRightOffset)
                if !tiebaTextIsEqual(rawRightOffset, secondaryRightOffset) {
                    rightOffset = ceil(secondaryRightOffset)
                }
                
                spoilerWords.append(TiebaTextNodeSpoiler(range: NSMakeRange(startIndex, endIndex - startIndex + 1), frame: CGRect(x: min(leftOffset, rightOffset), y: descent - (ascent + descent), width: abs(rightOffset - leftOffset) + rightInset, height: ascent + descent)))
            }
            
            func tiebaTextAddEmbeddedItem(item: AnyHashable, line: CTLine, ascent: CGFloat, descent: CGFloat, startIndex: Int, endIndex: Int, rightInset: CGFloat = 0.0) {
                var secondaryLeftOffset: CGFloat = 0.0
                let rawLeftOffset = CTLineGetOffsetForStringIndex(line, startIndex, &secondaryLeftOffset)
                var leftOffset = floor(rawLeftOffset)
                if !tiebaTextIsEqual(rawLeftOffset, secondaryLeftOffset) {
                    leftOffset = floor(secondaryLeftOffset)
                }
                
                var secondaryRightOffset: CGFloat = 0.0
                let rawRightOffset = CTLineGetOffsetForStringIndex(line, endIndex, &secondaryRightOffset)
                var rightOffset = ceil(rawRightOffset)
                if !tiebaTextIsEqual(rawRightOffset, secondaryRightOffset) {
                    rightOffset = ceil(secondaryRightOffset)
                }
                
                embeddedItems.append(TiebaTextNodeEmbeddedItem(range: NSMakeRange(startIndex, endIndex - startIndex + 1), frame: CGRect(x: min(leftOffset, rightOffset), y: descent - (ascent + descent), width: abs(rightOffset - leftOffset) + rightInset, height: ascent + descent), item: item))
            }
            
            func tiebaTextAddAttachment(attachment: UIImage, line: CTLine, ascent: CGFloat, descent: CGFloat, startIndex: Int, endIndex: Int, isAtEndOfTheLine: Bool, rightInset: CGFloat = 0.0) {
                var secondaryLeftOffset: CGFloat = 0.0
                let rawLeftOffset = CTLineGetOffsetForStringIndex(line, startIndex, &secondaryLeftOffset)
                var leftOffset = floor(rawLeftOffset)
                if !tiebaTextIsEqual(rawLeftOffset, secondaryLeftOffset) {
                    leftOffset = floor(secondaryLeftOffset)
                }
                
                var rightOffset: CGFloat = leftOffset
                if isAtEndOfTheLine {
                    let rawRightOffset = CTLineGetTypographicBounds(line, nil, nil, nil)
                    rightOffset = floor(rawRightOffset)
                } else {
                    var secondaryRightOffset: CGFloat = 0.0
                    let rawRightOffset = CTLineGetOffsetForStringIndex(line, endIndex, &secondaryRightOffset)
                    rightOffset = ceil(rawRightOffset)
                    if !tiebaTextIsEqual(rawRightOffset, secondaryRightOffset) {
                        rightOffset = ceil(secondaryRightOffset)
                    }
                }
                
                attachments.append(TiebaTextNodeAttachment(range: NSMakeRange(startIndex, endIndex - startIndex), frame: CGRect(x: min(leftOffset, rightOffset), y: descent - (ascent + descent), width: abs(rightOffset - leftOffset) + rightInset, height: ascent + descent), attachment: attachment))
            }
            
            var isLastLine = false
            if maximumNumberOfLines != 0 && lines.count == maximumNumberOfLines - 1 && lineCharacterCount > 0 {
                isLastLine = true
            } else if layoutSize.height + (fontLineSpacing + fontLineHeight) * 2.0 > constrainedSize.height {
                isLastLine = true
            }
            if isLastLine {
                if first {
                    first = false
                } else {
                    layoutSize.height += fontLineSpacing
                }
                
                var didClipLinebreak = false
                var lineRange = CFRange(location: lastLineCharacterIndex, length: stringLength - lastLineCharacterIndex)
                let nsString = (attributedString.string as NSString)
                for i in lineRange.location ..< (lineRange.location + lineRange.length) {
                    if nsString.character(at: i) == 0x0a {
                        lineRange.length = max(0, i - lineRange.location)
                        didClipLinebreak = true
                        break
                    }
                }
                
                var brokenLineRange = CFRange(location: lastLineCharacterIndex, length: lineCharacterCount)
                if brokenLineRange.location + brokenLineRange.length > attributedString.length {
                    brokenLineRange.length = attributedString.length - brokenLineRange.location
                }
                if lineRange.length == 0 && !didClipLinebreak {
                    break
                }
                
                let coreTextLine: CTLine
                let originalLine = CTTypesetterCreateLineWithOffset(typesetter, lineRange, 0.0)
                
                var lineConstrainedSize = constrainedSize
                lineConstrainedSize.width += lineConstrainedWidthDelta
                if bottomCutoutEnabled {
                    lineConstrainedSize.width -= bottomCutoutSize.width
                }
                
                let truncatedTokenString: NSAttributedString
                if let customTruncationToken {
                    if lineRange.length == 0 && customTruncationToken.string.hasPrefix("\u{2026} ") {
                        truncatedTokenString = customTruncationToken.attributedSubstring(from: NSRange(location: 2, length: customTruncationToken.length - 2))
                    } else {
                        truncatedTokenString = customTruncationToken
                    }
                } else {
                    var truncationTokenAttributes: [NSAttributedString.Key : AnyObject] = [:]
                    truncationTokenAttributes[NSAttributedString.Key.font] = font
                    truncationTokenAttributes[NSAttributedString.Key(rawValue:  kCTForegroundColorFromContextAttributeName as String)] = true as NSNumber
                    let tokenString = "\u{2026}"
                    
                    truncatedTokenString = NSAttributedString(string: tokenString, attributes: truncationTokenAttributes)
                }
                let truncationToken = CTLineCreateWithAttributedString(truncatedTokenString)
                let truncationTokenWidth = CTLineGetTypographicBounds(truncationToken, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(truncationToken)
                
                var effectiveLineRange = brokenLineRange
                var additionalTrailingLine: (CTLine, Double)?
                
                var measureFitWidth = CTLineGetTypographicBounds(originalLine, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(originalLine)
                if customTruncationToken != nil && lineRange.location + lineRange.length < attributedString.length {
                    measureFitWidth += truncationTokenWidth
                }
                
                if lineRange.length == 0 || measureFitWidth < Double(lineConstrainedSize.width) {
                    if didClipLinebreak {
                        if lineRange.length == 0 {
                            coreTextLine = CTLineCreateWithAttributedString(NSAttributedString())
                        } else {
                            coreTextLine = originalLine
                        }
                        additionalTrailingLine = (truncationToken, truncationTokenWidth)
                        
                        truncated = true
                    } else {
                        coreTextLine = originalLine
                    }
                } else {
                    if customTruncationToken != nil {
                        let coreTextLine1 = CTLineCreateTruncatedLine(originalLine, max(1.0, Double(lineConstrainedSize.width)), truncationType, truncationToken) ?? truncationToken
                        let runs = (CTLineGetGlyphRuns(coreTextLine1) as [AnyObject]) as! [CTRun]
                        var hasTruncationToken = false
                        for run in runs {
                            let runRange = CTRunGetStringRange(run)
                            if runRange.location + runRange.length >= nsString.length {
                                hasTruncationToken = true
                                break
                            }
                        }
                        
                        if hasTruncationToken {
                            coreTextLine = coreTextLine1
                        } else {
                            let coreTextLine2 = CTLineCreateTruncatedLine(originalLine, max(1.0, Double(lineConstrainedSize.width) - truncationTokenWidth), truncationType, truncationToken) ?? truncationToken
                            coreTextLine = coreTextLine2
                        }
                    } else {
                        coreTextLine = CTLineCreateTruncatedLine(originalLine, max(1.0, Double(lineConstrainedSize.width)), truncationType, truncationToken) ?? truncationToken
                    }
                    let runs = (CTLineGetGlyphRuns(coreTextLine) as [AnyObject]) as! [CTRun]
                    for run in runs {
                        let runAttributes: NSDictionary = CTRunGetAttributes(run)
                        if let _ = runAttributes["CTForegroundColorFromContext"] {
                            brokenLineRange.length = CTRunGetStringRange(run).location - brokenLineRange.location
                            break
                        }
                    }
                    if customTruncationToken != nil {
                        assert(true)
                    }
                    effectiveLineRange = CFRange(location: effectiveLineRange.location, length: 0)
                    for run in runs {
                        let runRange = CTRunGetStringRange(run)
                        if runRange.location + runRange.length > brokenLineRange.location + brokenLineRange.length {
                            continue
                        }
                        effectiveLineRange.length = max(effectiveLineRange.length, (runRange.location + runRange.length) - effectiveLineRange.location)
                    }
                    
                    if brokenLineRange.location + brokenLineRange.length > attributedString.length {
                        brokenLineRange.length = attributedString.length - brokenLineRange.location
                    }
                    if effectiveLineRange.location + effectiveLineRange.length > attributedString.length {
                        effectiveLineRange.length = attributedString.length - effectiveLineRange.location
                    }
                    truncated = true
                }
                
                var headIndent: CGFloat = 0.0
                if brokenLineRange.location >= 0 && brokenLineRange.length > 0 && brokenLineRange.location + brokenLineRange.length <= attributedString.length {
                    attributedString.enumerateAttributes(in: NSMakeRange(brokenLineRange.location, brokenLineRange.length), options: []) { attributes, range, _ in
                        if attributes[NSAttributedString.Key(rawValue: "TiebaSpoiler")] != nil || attributes[NSAttributedString.Key(rawValue: "Attribute__Spoiler")] != nil {
                            var ascent: CGFloat = 0.0
                            var descent: CGFloat = 0.0
                            CTLineGetTypographicBounds(coreTextLine, &ascent, &descent, nil)
                            
                            var startIndex: Int?
                            var currentIndex: Int?
                            
                            let nsString = (attributedString.string as NSString)
                            nsString.enumerateSubstrings(in: range, options: .byComposedCharacterSequences) { substring, range, _, _ in
                                if let substring = substring, substring.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
                                    if let currentStartIndex = startIndex {
                                        startIndex = nil
                                        let endIndex = range.location
                                        tiebaTextAddSpoilerWord(line: coreTextLine, ascent: ascent, descent: descent, startIndex: currentStartIndex, endIndex: endIndex)
                                    }
                                } else if startIndex == nil {
                                    startIndex = range.location
                                }
                                currentIndex = range.location + range.length
                            }
                            
                            if let currentStartIndex = startIndex, let currentIndex = currentIndex {
                                startIndex = nil
                                let endIndex = currentIndex
                                tiebaTextAddSpoilerWord(line: coreTextLine, ascent: ascent, descent: descent, startIndex: currentStartIndex, endIndex: endIndex, rightInset: truncated ? 12.0 : 0.0)
                            }
                            
                            tiebaTextAddSpoiler(line: coreTextLine, ascent: ascent, descent: descent, startIndex: range.location, endIndex: range.location + range.length)
                        } else if let _ = attributes[NSAttributedString.Key(rawValue: "TiebaBackground")] {
                            let clampedEnd = max(range.location, min(brokenLineRange.location + brokenLineRange.length, range.location + range.length))
                            let lowerX = floor(CTLineGetOffsetForStringIndex(coreTextLine, range.location, nil))
                            let upperX = ceil(CTLineGetOffsetForStringIndex(coreTextLine, clampedEnd, nil))
                            let x = lowerX < upperX ? lowerX : upperX
                            backgrounds.append(TiebaTextNodeStrikethrough(range: range, frame: CGRect(x: x, y: 0.0, width: abs(upperX - lowerX), height: fontLineHeight), color: nil, style: .single))
                        } else if let _ = attributes[NSAttributedString.Key.strikethroughStyle] {
                            let clampedEnd = max(range.location, min(brokenLineRange.location + brokenLineRange.length, range.location + range.length))
                            let lowerX = floor(CTLineGetOffsetForStringIndex(coreTextLine, range.location, nil))
                            let upperX = ceil(CTLineGetOffsetForStringIndex(coreTextLine, clampedEnd, nil))
                            let x = lowerX < upperX ? lowerX : upperX
                            strikethroughs.append(TiebaTextNodeStrikethrough(range: range, frame: CGRect(x: x, y: 0.0, width: abs(upperX - lowerX), height: fontLineHeight), color: nil, style: .single))
                        } else if let underlineStyle = attributes[NSAttributedString.Key.underlineStyle] as? Int {
                            let clampedEnd = max(range.location, min(brokenLineRange.location + brokenLineRange.length, range.location + range.length))
                            let lowerX = floor(CTLineGetOffsetForStringIndex(coreTextLine, range.location, nil))
                            let upperX = ceil(CTLineGetOffsetForStringIndex(coreTextLine, clampedEnd, nil))
                            let x = lowerX < upperX ? lowerX : upperX
                            underlines.append(TiebaTextNodeStrikethrough(range: range, frame: CGRect(x: x, y: 0.0, width: abs(upperX - lowerX), height: fontLineHeight), color: attributes[NSAttributedString.Key.underlineColor] as? UIColor, style: underlineStyle == NSUnderlineStyle.patternDot.rawValue ? .wavy : .single))
                        } else if let paragraphStyle = attributes[NSAttributedString.Key.paragraphStyle] as? NSParagraphStyle {
                            headIndent = paragraphStyle.headIndent
                        }

                        if let embeddedItem = (attributes[NSAttributedString.Key(rawValue: "TiebaEmbeddedItem")] as? AnyHashable ?? attributes[NSAttributedString.Key(rawValue: "Attribute__EmbeddedItem")] as? AnyHashable) {
                            if displayEmbeddedItemsUnderSpoilers || (attributes[NSAttributedString.Key(rawValue: "TiebaSpoiler")] == nil && attributes[NSAttributedString.Key(rawValue: "Attribute__Spoiler")] == nil) {
                                var ascent: CGFloat = 0.0
                                var descent: CGFloat = 0.0
                                CTLineGetTypographicBounds(coreTextLine, &ascent, &descent, nil)

                                tiebaTextAddEmbeddedItem(item: embeddedItem, line: coreTextLine, ascent: ascent, descent: descent, startIndex: range.location, endIndex: range.location + range.length)
                            }
                        }

                        if let attachment = attributes[NSAttributedString.Key.attachment] as? UIImage {
                            var ascent: CGFloat = 0.0
                            var descent: CGFloat = 0.0
                            CTLineGetTypographicBounds(coreTextLine, &ascent, &descent, nil)

                            tiebaTextAddAttachment(attachment: attachment, line: coreTextLine, ascent: ascent, descent: descent, startIndex: range.location, endIndex: max(range.location, min(lineRange.location + lineRange.length, range.location + range.length)), isAtEndOfTheLine: range.location + range.length >= lineRange.location + lineRange.length - 1)
                        }
                    }
                }

                var lineAscent: CGFloat = 0.0
                var lineDescent: CGFloat = 0.0
                let lineWidth = min(lineConstrainedSize.width, ceil(CGFloat(CTLineGetTypographicBounds(coreTextLine, &lineAscent, &lineDescent, nil) - CTLineGetTrailingWhitespaceWidth(coreTextLine))))
                let lineFrame = CGRect(x: lineCutoutOffset + headIndent, y: lineOriginY, width: lineWidth, height: fontLineHeight)
                layoutSize.height += fontLineHeight + fontLineSpacing
                
                if let (_, additionalTrailingLineWidth) = additionalTrailingLine {
                    lineAdditionalWidth += additionalTrailingLineWidth
                }
                
                layoutSize.width = max(layoutSize.width, lineWidth + lineAdditionalWidth)
                
                var isRTL = false
                let glyphRuns = CTLineGetGlyphRuns(coreTextLine) as NSArray
                if glyphRuns.count != 0 {
                    let run = glyphRuns[0] as! CTRun
                    if CTRunGetStatus(run).contains(CTRunStatus.rightToLeft) {
                        isRTL = true
                    }
                }
                
                lines.append(TiebaTextNodeLine(
                    line: coreTextLine,
                    frame: lineFrame,
                    ascent: lineAscent,
                    descent: lineDescent,
                    range: NSMakeRange(effectiveLineRange.location, effectiveLineRange.length),
                    isRTL: isRTL,
                    backgrounds: backgrounds,
                    strikethroughs: strikethroughs,
                    underlines: underlines,
                    spoilers: spoilers,
                    spoilerWords: spoilerWords,
                    embeddedItems: embeddedItems,
                    attachments: attachments,
                    additionalTrailingLine: additionalTrailingLine
                ))
                break
            } else {
                if lineCharacterCount > 0 {
                    if first {
                        first = false
                    } else {
                        layoutSize.height += fontLineSpacing
                    }
                    
                    var lineRange = CFRangeMake(lastLineCharacterIndex, lineCharacterCount)
                    if lineRange.location + lineRange.length > attributedString.length {
                        lineRange.length = attributedString.length - lineRange.location
                    }
                    if lineRange.length < 0 {
                        break
                    }

                    let coreTextLine = CTTypesetterCreateLineWithOffset(typesetter, lineRange, 100.0)
                    lastLineCharacterIndex += lineCharacterCount
                    
                    var headIndent: CGFloat = 0.0
                    attributedString.enumerateAttributes(in: NSMakeRange(lineRange.location, lineRange.length), options: []) { attributes, range, _ in
                        if attributes[NSAttributedString.Key(rawValue: "TiebaSpoiler")] != nil || attributes[NSAttributedString.Key(rawValue: "Attribute__Spoiler")] != nil {
                            var ascent: CGFloat = 0.0
                            var descent: CGFloat = 0.0
                            CTLineGetTypographicBounds(coreTextLine, &ascent, &descent, nil)
                                                            
                            var startIndex: Int?
                            var currentIndex: Int?
                            
                            let nsString = (attributedString.string as NSString)
                            nsString.enumerateSubstrings(in: range, options: .byComposedCharacterSequences) { substring, range, _, _ in
                                if let substring = substring, substring.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
                                    if let currentStartIndex = startIndex {
                                        startIndex = nil
                                        let endIndex = range.location
                                        tiebaTextAddSpoilerWord(line: coreTextLine, ascent: ascent, descent: descent, startIndex: currentStartIndex, endIndex: endIndex)
                                    }
                                } else if startIndex == nil {
                                    startIndex = range.location
                                }
                                currentIndex = range.location + range.length
                            }
                            
                            if let currentStartIndex = startIndex, let currentIndex = currentIndex {
                                startIndex = nil
                                let endIndex = currentIndex
                                tiebaTextAddSpoilerWord(line: coreTextLine, ascent: ascent, descent: descent, startIndex: currentStartIndex, endIndex: endIndex)
                            }
                            
                            tiebaTextAddSpoiler(line: coreTextLine, ascent: ascent, descent: descent, startIndex: range.location, endIndex: range.location + range.length)
                        } else if let _ = attributes[NSAttributedString.Key(rawValue: "TiebaBackground")] {
                            let clampedEnd = max(range.location, min(lineRange.location + lineRange.length, range.location + range.length))
                            let lowerX = floor(CTLineGetOffsetForStringIndex(coreTextLine, range.location, nil))
                            let upperX = ceil(CTLineGetOffsetForStringIndex(coreTextLine, clampedEnd, nil))
                            let x = lowerX < upperX ? lowerX : upperX
                            backgrounds.append(TiebaTextNodeStrikethrough(range: range, frame: CGRect(x: x, y: 0.0, width: abs(upperX - lowerX), height: fontLineHeight), color: nil, style: .single))
                        } else if let _ = attributes[NSAttributedString.Key.strikethroughStyle] {
                            let clampedEnd = max(range.location, min(lineRange.location + lineRange.length, range.location + range.length))
                            let lowerX = floor(CTLineGetOffsetForStringIndex(coreTextLine, range.location, nil))
                            let upperX = ceil(CTLineGetOffsetForStringIndex(coreTextLine, clampedEnd, nil))
                            let x = lowerX < upperX ? lowerX : upperX
                            strikethroughs.append(TiebaTextNodeStrikethrough(range: range, frame: CGRect(x: x, y: 0.0, width: abs(upperX - lowerX), height: fontLineHeight), color: nil, style: .single))
                        } else if let underlineStyle = attributes[NSAttributedString.Key.underlineStyle] as? Int {
                            let clampedEnd = max(range.location, min(lineRange.location + lineRange.length, range.location + range.length))
                            let lowerX = floor(CTLineGetOffsetForStringIndex(coreTextLine, range.location, nil))
                            let upperX = ceil(CTLineGetOffsetForStringIndex(coreTextLine, clampedEnd, nil))
                            let x = lowerX < upperX ? lowerX : upperX
                            underlines.append(TiebaTextNodeStrikethrough(range: range, frame: CGRect(x: x, y: 0.0, width: abs(upperX - lowerX), height: fontLineHeight), color: attributes[NSAttributedString.Key.underlineColor] as? UIColor, style: underlineStyle == NSUnderlineStyle.patternDot.rawValue ? .wavy : .single))
                        } else if let paragraphStyle = attributes[NSAttributedString.Key.paragraphStyle] as? NSParagraphStyle {
                            headIndent = paragraphStyle.headIndent
                        }

                        if let embeddedItem = (attributes[NSAttributedString.Key(rawValue: "TiebaEmbeddedItem")] as? AnyHashable ?? attributes[NSAttributedString.Key(rawValue: "Attribute__EmbeddedItem")] as? AnyHashable) {
                            if displayEmbeddedItemsUnderSpoilers || (attributes[NSAttributedString.Key(rawValue: "TiebaSpoiler")] == nil && attributes[NSAttributedString.Key(rawValue: "Attribute__Spoiler")] == nil) {
                                var ascent: CGFloat = 0.0
                                var descent: CGFloat = 0.0
                                CTLineGetTypographicBounds(coreTextLine, &ascent, &descent, nil)

                                tiebaTextAddEmbeddedItem(item: embeddedItem, line: coreTextLine, ascent: ascent, descent: descent, startIndex: range.location, endIndex: range.location + range.length)
                            }
                        }

                        if let attachment = attributes[NSAttributedString.Key.attachment] as? UIImage {
                            var ascent: CGFloat = 0.0
                            var descent: CGFloat = 0.0
                            CTLineGetTypographicBounds(coreTextLine, &ascent, &descent, nil)

                            tiebaTextAddAttachment(attachment: attachment, line: coreTextLine, ascent: ascent, descent: descent, startIndex: range.location, endIndex: max(range.location, min(lineRange.location + lineRange.length, range.location + range.length)), isAtEndOfTheLine: range.location + range.length >= lineRange.location + lineRange.length - 1)
                        }
                    }
                    
                    var lineAscent: CGFloat = 0.0
                    var lineDescent: CGFloat = 0.0
                    let lineWidth = ceil(CGFloat(CTLineGetTypographicBounds(coreTextLine, &lineAscent, &lineDescent, nil) - CTLineGetTrailingWhitespaceWidth(coreTextLine)))
                    let lineFrame = CGRect(x: lineCutoutOffset + headIndent, y: lineOriginY, width: lineWidth, height: fontLineHeight)
                    layoutSize.height += fontLineHeight
                    layoutSize.width = max(layoutSize.width, lineWidth + lineAdditionalWidth + headIndent)
                    
                    var isRTL = false
                    let glyphRuns = CTLineGetGlyphRuns(coreTextLine) as NSArray
                    if glyphRuns.count != 0 {
                        let run = glyphRuns[0] as! CTRun
                        if CTRunGetStatus(run).contains(CTRunStatus.rightToLeft) {
                            isRTL = true
                        }
                    }
                    
                    lines.append(TiebaTextNodeLine(
                        line: coreTextLine,
                        frame: lineFrame,
                        ascent: lineAscent,
                        descent: lineDescent,
                        range: NSMakeRange(lineRange.location, lineRange.length),
                        isRTL: isRTL,
                        backgrounds: backgrounds,
                        strikethroughs: strikethroughs,
                        underlines: underlines,
                        spoilers: spoilers,
                        spoilerWords: spoilerWords,
                        embeddedItems: embeddedItems,
                        attachments: attachments,
                        additionalTrailingLine: nil
                    ))
                } else {
                    if !lines.isEmpty {
                        layoutSize.height += fontLineSpacing
                    }
                    break
                }
            }
        }
        
        let rawLayoutSize = layoutSize
        if !lines.isEmpty && bottomCutoutEnabled {
            let proposedWidth = lines[lines.count - 1].frame.width + bottomCutoutSize.width
            if proposedWidth > layoutSize.width {
                if proposedWidth <= constrainedSize.width + .ulpOfOne {
                    layoutSize.width = proposedWidth
                } else {
                    layoutSize.height += bottomCutoutSize.height
                }
            }
        }
        
        if lines.count < minimumNumberOfLines {
            var lineCount = lines.count
            while lineCount < minimumNumberOfLines {
                if lineCount != 0 {
                    layoutSize.height += fontLineSpacing
                }
                layoutSize.height += fontLineHeight
                lineCount += 1
            }
        }
        
        return TiebaTextNodeLayout(attributedString: attributedString, maximumNumberOfLines: maximumNumberOfLines, truncationType: truncationType, constrainedSize: constrainedSize, explicitAlignment: alignment, resolvedAlignment: resolvedAlignment, verticalAlignment: verticalAlignment, lineSpacing: lineSpacingFactor, cutout: cutout, insets: insets, size: CGSize(width: ceil(layoutSize.width) + insets.left + insets.right, height: ceil(layoutSize.height) + insets.top + insets.bottom), rawTextSize: CGSize(width: ceil(rawLayoutSize.width) + insets.left + insets.right, height: ceil(rawLayoutSize.height) + insets.top + insets.bottom), truncated: truncated, firstLineOffset: firstLineOffset, lines: lines, blockQuotes: blockQuotes, backgroundColor: backgroundColor, lineColor: lineColor, textShadowColor: textShadowColor, textShadowBlur: textShadowBlur, textStroke: textStroke, displaySpoilers: displaySpoilers)
    }

    public static func draw(_ bounds: CGRect, withParameters parameters: DrawingParameters, isCancelled: () -> Bool, isRasterizing: Bool) {
        if isCancelled() {
            return
        }
        
        let context = UIGraphicsGetCurrentContext()!
        
        context.setAllowsAntialiasing(true)
        
        context.setAllowsFontSmoothing(false)
        context.setShouldSmoothFonts(false)
        
        context.setAllowsFontSubpixelPositioning(false)
        context.setShouldSubpixelPositionFonts(false)
        
        context.setAllowsFontSubpixelQuantization(true)
        context.setShouldSubpixelQuantizeFonts(true)
        
        var blendMode: CGBlendMode = .normal
        
        let renderContentTypes: RenderContentTypes = parameters.renderContentTypes
        
        var clearRects: [CGRect] = []
        if let layout = parameters.cachedLayout {
            if !isRasterizing || layout.backgroundColor != nil {
                context.setBlendMode(.copy)
                blendMode = .copy
                
                context.setFillColor((layout.backgroundColor ?? UIColor.clear).cgColor)
                context.fill(bounds)
                
                context.setBlendMode(.normal)
                blendMode = .normal
            }
            
            let alignment = layout.resolvedAlignment
            var offset = CGPoint(x: layout.insets.left, y: layout.insets.top)
            switch layout.verticalAlignment {
                case .top:
                    break
                case .middle:
                    offset.y = floor((bounds.height - layout.size.height) / 2.0) + layout.insets.top
                case .bottom:
                    offset.y = floor(bounds.height - layout.size.height) + layout.insets.top
            }
            
            if !layout.lines.isEmpty {
                offset.y += layout.lines[0].descent
            }
            
            for blockQuote in layout.blockQuotes {
                let radius: CGFloat = 4.0
                let lineWidth: CGFloat = 3.0
                
                var blockFrame = blockQuote.frame.offsetBy(dx: offset.x + 2.0, dy: offset.y)
                if blockFrame.origin.x + blockFrame.size.width > bounds.width - layout.insets.right - 2.0 - 30.0 {
                    blockFrame.size.width = bounds.width - layout.insets.right - blockFrame.origin.x - 2.0
                }
                blockFrame.size.width += 4.0
                blockFrame.origin.x -= 2.0
                
                context.setFillColor(blockQuote.backgroundColor.cgColor)
                context.addPath(UIBezierPath(roundedRect: blockFrame, cornerRadius: radius).cgPath)
                context.fillPath()
                
                context.setFillColor(blockQuote.tintColor.cgColor)
                
                switch blockQuote.data.kind {
                case .quote:
                    // [移植] 上游直接引用非可选 quoteIcon；本仓无资源包，故 if let 解包（见常量处注释）。
                    if let quoteIcon = quoteIcon {
                        let quoteRect = CGRect(origin: CGPoint(x: blockFrame.maxX - 4.0 - quoteIcon.size.width, y: blockFrame.minY + 4.0), size: quoteIcon.size)
                        context.saveGState()
                        context.translateBy(x: quoteRect.midX, y: quoteRect.midY)
                        context.scaleBy(x: 1.0, y: -1.0)
                        context.translateBy(x: -quoteRect.midX, y: -quoteRect.midY)
                        context.clip(to: quoteRect, mask: quoteIcon.cgImage!)
                        context.fill(quoteRect)
                        context.restoreGState()
                        context.resetClip()
                    }
                case .code:
                    if blockQuote.data.title != nil, let codeIcon = codeIcon {
                        let quoteRect = CGRect(origin: CGPoint(x: blockFrame.maxX - 4.0 - codeIcon.size.width, y: blockFrame.minY + 4.0), size: codeIcon.size)
                        context.saveGState()
                        context.translateBy(x: quoteRect.midX, y: quoteRect.midY)
                        context.scaleBy(x: 1.0, y: -1.0)
                        context.translateBy(x: -quoteRect.midX, y: -quoteRect.midY)
                        context.clip(to: quoteRect, mask: codeIcon.cgImage!)
                        context.fill(quoteRect)
                        context.restoreGState()
                        context.resetClip()
                    }
                }
                
                let lineFrame = CGRect(origin: CGPoint(x: blockFrame.minX, y: blockFrame.minY), size: CGSize(width: lineWidth, height: blockFrame.height))
                context.move(to: CGPoint(x: lineFrame.minX, y: lineFrame.minY + radius))
                context.addArc(tangent1End: CGPoint(x: lineFrame.minX, y: lineFrame.minY), tangent2End: CGPoint(x: lineFrame.minX + radius, y: lineFrame.minY), radius: radius)
                context.addLine(to: CGPoint(x: lineFrame.minX + radius, y: lineFrame.maxY))
                context.addArc(tangent1End: CGPoint(x: lineFrame.minX, y: lineFrame.maxY), tangent2End: CGPoint(x: lineFrame.minX, y: lineFrame.maxY - radius), radius: radius)
                context.closePath()
                context.clip()
                
                if let secondaryTintColor = blockQuote.secondaryTintColor {
                    let isMonochrome = colorAlpha(secondaryTintColor) == 0.0
                    
                    let tertiaryTintColor = blockQuote.tertiaryTintColor
                    let dashHeight: CGFloat = tertiaryTintColor != nil ? 6.0 : 9.0
                    
                    do {
                        context.saveGState()
                        
                        let dashOffset: CGFloat
                        if let _ = tertiaryTintColor {
                            dashOffset = isMonochrome ? -7.0 : 5.0
                        } else {
                            dashOffset = isMonochrome ? -4.0 : 5.0
                        }
                        
                        if isMonochrome {
                            context.setFillColor(withMultipliedAlpha(blockQuote.tintColor, 0.2).cgColor)
                            context.fill(lineFrame)
                            context.setFillColor(blockQuote.tintColor.cgColor)
                        } else {
                            context.setFillColor(blockQuote.tintColor.cgColor)
                            context.fill(lineFrame)
                            context.setFillColor(secondaryTintColor.cgColor)
                        }
                        
                        if let _ = tertiaryTintColor {
                            context.translateBy(x: 0.0, y: dashHeight)
                        }
                        
                        func drawDashes() {
                            context.translateBy(x: blockFrame.minX, y: blockFrame.minY + dashOffset)
                            
                            var offset = 0.0
                            while offset < blockFrame.height {
                                context.move(to: CGPoint(x: 0.0, y: 3.0))
                                context.addLine(to: CGPoint(x: lineWidth, y: 0.0))
                                context.addLine(to: CGPoint(x: lineWidth, y: dashHeight))
                                context.addLine(to: CGPoint(x: 0.0, y: dashHeight + 3.0))
                                context.closePath()
                                context.fillPath()
                                
                                context.translateBy(x: 0.0, y: 18.0)
                                offset += 18.0
                            }
                        }
                        
                        drawDashes()
                        context.restoreGState()
                        
                        if let tertiaryTintColor {
                            context.saveGState()
                            if isMonochrome {
                                context.setFillColor(blockQuote.tintColor.withAlphaComponent(0.4).cgColor)
                            } else {
                                context.setFillColor(tertiaryTintColor.cgColor)
                            }
                            drawDashes()
                            context.restoreGState()
                        }
                    }
                } else {
                    context.setFillColor(blockQuote.tintColor.cgColor)
                    context.setBlendMode(.copy)
                    context.fill(lineFrame)
                    context.setBlendMode(.normal)
                }
                
                context.resetClip()
            }
            
            if let textShadowColor = layout.textShadowColor {
                context.setTextDrawingMode(.fill)
                context.setShadow(offset: layout.textShadowBlur != nil ? .zero : CGSize(width: 0.0, height: 1.0), blur: layout.textShadowBlur ?? 0.0, color: textShadowColor.cgColor)
            }
            
            if let (textStrokeColor, textStrokeWidth) = layout.textStroke {
                context.setBlendMode(.normal)
                blendMode = .normal
                
                context.setLineCap(.round)
                context.setLineJoin(.round)
                context.setStrokeColor(textStrokeColor.cgColor)
                context.setFillColor(textStrokeColor.cgColor)
                context.setLineWidth(textStrokeWidth)
                context.setTextDrawingMode(.fillStroke)
            }
            
            let textMatrix = context.textMatrix
            let textPosition = context.textPosition
            context.textMatrix = CGAffineTransform(scaleX: 1.0, y: -1.0)
            
            for i in 0 ..< layout.lines.count {
                let line = layout.lines[i]
                
                var lineFrame = line.frame
                lineFrame.origin.y += offset.y
                
                if alignment == .center {
                    lineFrame.origin.x = offset.x + floor((bounds.size.width - lineFrame.width) / 2.0)
                } else if alignment == .natural {
                    if line.isRTL {
                        lineFrame.origin.x = offset.x + floor(bounds.size.width - lineFrame.width)
                        lineFrame = tiebaTextDisplayLineFrame(frame: lineFrame, isRTL: line.isRTL, boundingRect: CGRect(origin: CGPoint(), size: bounds.size), cutout: layout.cutout)
                    } else {
                        lineFrame.origin.x += offset.x
                    }
                } else if alignment == .right {
                    lineFrame.origin.x = offset.x + (bounds.size.width - lineFrame.width)
                }
                
                //context.setStrokeColor(UIColor.red.cgColor)
                //context.stroke(lineFrame.offsetBy(dx: 0.0, dy: -lineFrame.height))
                
                lineFrame.origin.y += -line.descent
                
                context.textPosition = CGPoint(x: lineFrame.minX, y: lineFrame.minY)
                
                if layout.displaySpoilers && !line.spoilers.isEmpty {
                    context.saveGState()
                    var clipRects: [CGRect] = []
                    for spoiler in line.spoilerWords {
                        var spoilerClipRect = spoiler.frame.offsetBy(dx: lineFrame.minX, dy: lineFrame.minY - tiebaTextUIScreenPixel)
                        spoilerClipRect.size.height += 1.0 + tiebaTextUIScreenPixel
                        clipRects.append(spoilerClipRect)
                    }
                    context.clip(to: clipRects)
                }
                    
                let glyphRuns = CTLineGetGlyphRuns(line.line) as NSArray
                
                if glyphRuns.count != 0 {
                    let hasAttachments = !line.attachments.isEmpty
                    for run in glyphRuns {
                        let run = run as! CTRun
                        let glyphCount = CTRunGetGlyphCount(run)
                        let attributes = CTRunGetAttributes(run) as NSDictionary
                        if attributes["Attribute__EmbeddedItem"] != nil {
                            continue
                        }
                        
                        if renderContentTypes != .all {
                            if let font = attributes["NSFont"] as? UIFont, font.fontName.contains("ColorEmoji") {
                                if !renderContentTypes.contains(.emoji) {
                                    continue
                                }
                            } else {
                                if !renderContentTypes.contains(.text) {
                                    continue
                                }
                            }
                        }
                        
                        var fixDoubleEmoji = false
                        if glyphCount == 2, let font = attributes["NSFont"] as? UIFont, font.fontName.contains("ColorEmoji"), let string = layout.attributedString {
                            let range = CTRunGetStringRange(run)
                            
                            if range.location < string.length && (range.location + range.length) <= string.length {
                                let substring = string.attributedSubstring(from: NSMakeRange(range.location, range.length)).string
                                
                                let heart = Unicode.Scalar(0x2764)!
                                let man = Unicode.Scalar(0x1F468)!
                                let woman = Unicode.Scalar(0x1F469)!
                                let leftHand = Unicode.Scalar(0x1FAF1)!
                                let rightHand = Unicode.Scalar(0x1FAF2)!
                                
                                if substring.unicodeScalars.contains(heart) && (substring.unicodeScalars.contains(man) || substring.unicodeScalars.contains(woman)) {
                                    fixDoubleEmoji = true
                                } else if substring.unicodeScalars.contains(leftHand) && substring.unicodeScalars.contains(rightHand) {
                                    fixDoubleEmoji = true
                                }
                            }
                        }
                        
                        if fixDoubleEmoji {
                            context.setBlendMode(.normal)
                        }
                        
                        if hasAttachments {
                            let stringRange = CTRunGetStringRange(run)
                            if line.attachments.contains(where: { $0.range.contains(stringRange.location) }) {
                            } else {
                                CTRunDraw(run, context, CFRangeMake(0, glyphCount))
                            }
                        } else {
                            CTRunDraw(run, context, CFRangeMake(0, glyphCount))
                        }
                        
                        if fixDoubleEmoji {
                            context.setBlendMode(blendMode)
                        }
                    }
                }
                
                for attachment in line.attachments {
                    let image = attachment.attachment
                    if !TiebaTextNode.shouldRenderAttachment(image, renderContentTypes: renderContentTypes) {
                        continue
                    }

                    var textColor: UIColor?
                    layout.attributedString?.enumerateAttributes(in: attachment.range, options: []) { attributes, range, _ in
                        if let color = attributes[NSAttributedString.Key.foregroundColor] as? UIColor {
                            textColor = color
                        }
                    }
                    if image.renderingMode == .alwaysOriginal {
                        let imageRect = CGRect(origin: CGPoint(x: attachment.frame.midX - image.size.width * 0.5, y: attachment.frame.midY - image.size.height * 0.5 + 1.0), size: image.size).offsetBy(dx: lineFrame.minX, dy: lineFrame.minY)
                        context.translateBy(x: imageRect.midX, y: imageRect.midY)
                        context.scaleBy(x: 1.0, y: -1.0)
                        context.translateBy(x: -imageRect.midX, y: -imageRect.midY)
                        context.draw(image.cgImage!, in: imageRect)
                        context.translateBy(x: imageRect.midX, y: imageRect.midY)
                        context.scaleBy(x: 1.0, y: -1.0)
                        context.translateBy(x: -imageRect.midX, y: -imageRect.midY)
                    } else if let textColor {
                        if let tintedImage = tiebaTextGenerateTintedImage(image: image, color: textColor) {
                            let imageRect = CGRect(origin: CGPoint(x: attachment.frame.midX - tintedImage.size.width * 0.5, y: attachment.frame.midY - tintedImage.size.height * 0.5 + 1.0), size: tintedImage.size).offsetBy(dx: lineFrame.minX, dy: lineFrame.minY)
                            context.translateBy(x: imageRect.midX, y: imageRect.midY)
                            context.scaleBy(x: 1.0, y: -1.0)
                            context.translateBy(x: -imageRect.midX, y: -imageRect.midY)
                            context.draw(tintedImage.cgImage!, in: imageRect)
                            context.translateBy(x: imageRect.midX, y: imageRect.midY)
                            context.scaleBy(x: 1.0, y: -1.0)
                            context.translateBy(x: -imageRect.midX, y: -imageRect.midY)
                        }
                    }
                }
                
                if tiebaTextDrawUnderlinesManually {
                    for strikethrough in line.underlines {
                        guard let lineRange = line.range else {
                            continue
                        }
                        var textColor: UIColor?
                        layout.attributedString?.enumerateAttributes(in: NSMakeRange(lineRange.location, lineRange.length), options: []) { attributes, range, _ in
                            if range == strikethrough.range, let color = attributes[NSAttributedString.Key.foregroundColor] as? UIColor {
                                textColor = color
                            }
                        }
                        switch strikethrough.style {
                        case .single:
                            if let color = strikethrough.color {
                                context.setFillColor(color.cgColor)
                            } else if let textColor {
                                context.setFillColor(textColor.cgColor)
                            }
                            let frame = strikethrough.frame.offsetBy(dx: lineFrame.minX, dy: lineFrame.minY)
                            context.fill(CGRect(x: frame.minX, y: frame.minY + 1.0, width: frame.width, height: 1.0))
                        case .wavy:
                            if let color = strikethrough.color {
                                context.setStrokeColor(color.cgColor)
                            } else if let textColor {
                                context.setStrokeColor(textColor.cgColor)
                            }
                            context.setLineWidth(1.33)
                            context.setLineCap(.round)
                            context.setLineJoin(.round)
                            let frame = strikethrough.frame.offsetBy(dx: lineFrame.minX, dy: lineFrame.minY - 6.0)

                            let amplitude: CGFloat = 1.2
                            let period: CGFloat = 8.0
                            let phase: CGFloat = -0.5
                            let midY = frame.midY
                            let step: CGFloat = 1.0

                            context.saveGState()
                            context.clip(to: frame)

                            var x = frame.minX
                            context.move(to: CGPoint(x: x, y: midY + amplitude * sin(phase)))
                            x += step
                            while x <= frame.maxX + step {
                                let y = midY + amplitude * sin((x - frame.minX) * 2.0 * .pi / period + phase)
                                context.addLine(to: CGPoint(x: x, y: y))
                                x += step
                            }
                            context.strokePath()
                            context.restoreGState()
                            
                            /*context.setFillColor(UIColor.red.cgColor)
                            let frame1 = strikethrough.frame.offsetBy(dx: lineFrame.minX, dy: lineFrame.minY)
                            context.fill(CGRect(x: frame1.minX, y: frame1.minY + 1.0, width: frame1.width, height: 1.0))*/
                        }
                    }
                }
                if !line.backgrounds.isEmpty {
                    for background in line.backgrounds {
                        guard let lineRange = line.range else {
                            continue
                        }
                        var textColor: UIColor?
                        layout.attributedString?.enumerateAttributes(in: NSMakeRange(lineRange.location, lineRange.length), options: []) { attributes, range, _ in
                            if range == background.range, let color = attributes[NSAttributedString.Key.foregroundColor] as? UIColor {
                                textColor = color
                            }
                        }
                        if let textColor = textColor {
                            context.setFillColor(withMultipliedAlpha(textColor, 0.1).cgColor)
                        }
                        let frame = background.frame.offsetBy(dx: lineFrame.minX, dy: lineFrame.minY)
                        context.addPath(CGPath(roundedRect: CGRect(x: frame.minX, y: frame.minY - frame.height, width: frame.width, height: frame.height).insetBy(dx: -4.0, dy: -2.0 + tiebaTextUIScreenPixel).offsetBy(dx: 0.0, dy: 3.0 + tiebaTextUIScreenPixel), cornerWidth: frame.height * 0.5, cornerHeight: frame.height * 0.5, transform: nil))
                        context.fillPath()
                    }
                }
                
                if !line.strikethroughs.isEmpty {
                    for strikethrough in line.strikethroughs {
                        guard let lineRange = line.range else {
                            continue
                        }
                        var textColor: UIColor?
                        layout.attributedString?.enumerateAttributes(in: NSMakeRange(lineRange.location, lineRange.length), options: []) { attributes, range, _ in
                            if range == strikethrough.range, let color = attributes[NSAttributedString.Key.foregroundColor] as? UIColor {
                                textColor = color
                            }
                        }
                        if let textColor = textColor {
                            context.setFillColor(textColor.cgColor)
                        }
                        let frame = strikethrough.frame.offsetBy(dx: lineFrame.minX, dy: lineFrame.minY)
                        context.fill(CGRect(x: frame.minX, y: frame.minY - 5.0, width: frame.width, height: 1.0))
                    }
                }
                
                if !line.spoilers.isEmpty {
                    if layout.displaySpoilers {
                        context.restoreGState()
                    } else {
                        for spoiler in line.spoilerWords {
                            var spoilerClearRect = spoiler.frame.offsetBy(dx: lineFrame.minX, dy: lineFrame.minY - tiebaTextUIScreenPixel)
                            spoilerClearRect.size.height += 1.0 + tiebaTextUIScreenPixel
                            clearRects.append(spoilerClearRect)
                        }
                    }
                }
                
                if let (additionalTrailingLine, _) = line.additionalTrailingLine {
                    context.textPosition = CGPoint(x: lineFrame.maxX, y: lineFrame.minY)
                    
                    let glyphRuns = CTLineGetGlyphRuns(additionalTrailingLine) as NSArray
                    if glyphRuns.count != 0 {
                        for run in glyphRuns {
                            let run = run as! CTRun
                            let glyphCount = CTRunGetGlyphCount(run)
                            let attributes = CTRunGetAttributes(run) as NSDictionary
                            if attributes["Attribute__EmbeddedItem"] != nil {
                                continue
                            }
                            
                            var fixDoubleEmoji = false
                            if glyphCount == 2, let font = attributes["NSFont"] as? UIFont, font.fontName.contains("ColorEmoji"), let string = layout.attributedString {
                                let range = CTRunGetStringRange(run)
                                
                                if range.location < string.length && (range.location + range.length) <= string.length {
                                    let substring = string.attributedSubstring(from: NSMakeRange(range.location, range.length)).string
                                    
                                    let heart = Unicode.Scalar(0x2764)!
                                    let man = Unicode.Scalar(0x1F468)!
                                    let woman = Unicode.Scalar(0x1F469)!
                                    let leftHand = Unicode.Scalar(0x1FAF1)!
                                    let rightHand = Unicode.Scalar(0x1FAF2)!
                                    
                                    if substring.unicodeScalars.contains(heart) && (substring.unicodeScalars.contains(man) || substring.unicodeScalars.contains(woman)) {
                                        fixDoubleEmoji = true
                                    } else if substring.unicodeScalars.contains(leftHand) && substring.unicodeScalars.contains(rightHand) {
                                        fixDoubleEmoji = true
                                    }
                                }
                            }
                            
                            if fixDoubleEmoji {
                                context.setBlendMode(.normal)
                            }
                            CTRunDraw(run, context, CFRangeMake(0, glyphCount))
                            if fixDoubleEmoji {
                                context.setBlendMode(blendMode)
                            }
                        }
                    }
                }
            }
            
            context.textMatrix = textMatrix
            context.textPosition = CGPoint(x: textPosition.x, y: textPosition.y)
        }
        
        context.setBlendMode(.normal)
        
        for rect in clearRects {
            context.clear(rect)
        }
    }
    
}
