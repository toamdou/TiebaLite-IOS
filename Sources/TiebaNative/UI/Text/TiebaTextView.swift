// 移植自上游: submodules/Display/Source/TextNode.swift:2856-2989（上游 open class TextView: UIView）。
//
// TextView 是上游文本坐标系的 UIView 外壳：持有 cachedLayout、负责 draw(_:) 与"排版结果可复用"的 asyncLayout 缓存键。
// 上游同文件还有 open class TextNode: ASDisplayNode（本仓丢弃，见 TiebaTextNodeRenderer.swift 头注）；
// 本文件就是 TiebaImmediateTextNode 的基类。
//
// 改动清单：
//  1) [改名] TextView → TiebaTextView（铁律 6：公开类型加 Tieba 前缀，避免与系统/本仓重名）；
//     对 TextNode.calculateLayout / TextNode.draw / TextNode.DrawingParameters 的引用同步改为 TiebaTextNode.*。
//  2) [Swift 6] 类本身不加标注：UIView 在 SDK 里已是 @MainActor，子类自动继承隔离，cachedLayout 的读写与
//     draw(_:) 都在主线程，正是 UIKit 的约定。asyncLayout 作为类的静态成员因此也是 MainActor 隔离的，
//     返回的 apply 闭包是非 Sendable 闭包、随上下文继承 MainActor 隔离，直接在主线程 apply（上游 ASDK 里这步
//     发生在后台排版完成后回主线程，语义等价）。未使用 @preconcurrency / @unchecked Sendable / assumeIsolated。
//  3) [删除 ASDK 生命周期] 上游 TextView 没有 didLoad 等 ASDK 回调；draw(_:) 里 UIGraphicsGetCurrentContext() 直接可用，
//     原样保留。
//  4) [保留上游的历史差异] 上游 TextNode.asyncLayout(:2844) 判空用 `width.isZero || height.isZero`，
//     TextView.asyncLayout(:2979) 用 `width.isZero && height.isZero`；本文件属 TextView，故照搬 && 未"修正"。
//     同名私有 calculateLayout(:2911)上游已无调用点，为忠实移植一并保留。
//  5) 算法一行未改。

import Foundation
import UIKit

open class TiebaTextView: UIView {
    public internal(set) var cachedLayout: TiebaTextNodeLayout?
    
    override public init(frame: CGRect) {
        super.init(frame: frame)
        
        self.backgroundColor = UIColor.clear
        self.isOpaque = false
        self.clipsToBounds = false
    }
    
    required public init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public func attributesAtPoint(_ point: CGPoint, orNearest: Bool = false) -> (Int, [NSAttributedString.Key: Any])? {
        if let cachedLayout = self.cachedLayout {
            return cachedLayout.attributesAtPoint(point, orNearest: orNearest)
        } else {
            return nil
        }
    }
    
    public func textRangesRects(text: String) -> [[CGRect]] {
        return self.cachedLayout?.textRangesRects(text: text) ?? []
    }
    
    public func attributeSubstring(name: String, index: Int) -> (String, String)? {
        return self.cachedLayout?.attributeSubstring(name: name, index: index)
    }
    
    public func attributeRects(name: String, at index: Int) -> [CGRect]? {
        if let cachedLayout = self.cachedLayout {
            return cachedLayout.lineAndAttributeRects(name: name, at: index)?.map { $0.1 }
        } else {
            return nil
        }
    }
    
    public func rangeRects(in range: NSRange) -> (rects: [CGRect], start: TiebaTextRangeRectEdge, end: TiebaTextRangeRectEdge)? {
        if let cachedLayout = self.cachedLayout {
            return cachedLayout.rangeRects(in: range)
        } else {
            return nil
        }
    }
    
    public func lineAndAttributeRects(name: String, at index: Int) -> [(CGRect, CGRect)]? {
        if let cachedLayout = self.cachedLayout {
            return cachedLayout.lineAndAttributeRects(name: name, at: index)
        } else {
            return nil
        }
    }
    
    private class func calculateLayout(attributedString: NSAttributedString?, minimumNumberOfLines: Int, maximumNumberOfLines: Int, truncationType: CTLineTruncationType, backgroundColor: UIColor?, constrainedSize: CGSize, alignment: NSTextAlignment, verticalAlignment: TiebaTextVerticalAlignment, lineSpacingFactor: CGFloat, cutout: TiebaTextNodeCutout?, insets: UIEdgeInsets, lineColor: UIColor?, textShadowColor: UIColor?, textShadowBlur: CGFloat?, textStroke: (UIColor, CGFloat)?, displaySpoilers: Bool) -> TiebaTextNodeLayout {
        return TiebaTextNode.calculateLayout(attributedString: attributedString, minimumNumberOfLines: minimumNumberOfLines, maximumNumberOfLines: maximumNumberOfLines, truncationType: truncationType, backgroundColor: backgroundColor, constrainedSize: constrainedSize, alignment: alignment, verticalAlignment: verticalAlignment, lineSpacingFactor: lineSpacingFactor, cutout: cutout, insets: insets, lineColor: lineColor, textShadowColor: textShadowColor, textShadowBlur: textShadowBlur, textStroke: textStroke, displaySpoilers: displaySpoilers, displayEmbeddedItemsUnderSpoilers: false, customTruncationToken: nil)
    }
    
    public override func draw(_ rect: CGRect) {
        let layout = self.cachedLayout
        
        let context = UIGraphicsGetCurrentContext()!
        
        context.setAllowsAntialiasing(true)
        
        context.setAllowsFontSmoothing(false)
        context.setShouldSmoothFonts(false)
        
        context.setAllowsFontSubpixelPositioning(false)
        context.setShouldSubpixelPositionFonts(false)
        
        context.setAllowsFontSubpixelQuantization(true)
        context.setShouldSubpixelQuantizeFonts(true)
        
        TiebaTextNode.draw(rect, withParameters: TiebaTextNode.DrawingParameters(cachedLayout: layout, renderContentTypes: .all), isCancelled: { false }, isRasterizing: false)
    }
    
    public static func asyncLayout(_ maybeView: TiebaTextView?) -> (TiebaTextNodeLayoutArguments) -> (TiebaTextNodeLayout, () -> TiebaTextView) {
        let existingLayout: TiebaTextNodeLayout? = maybeView?.cachedLayout
        
        return { arguments in
            let layout: TiebaTextNodeLayout
            
            var updated = false
            if let existingLayout = existingLayout, existingLayout.constrainedSize == arguments.constrainedSize && existingLayout.maximumNumberOfLines == arguments.maximumNumberOfLines && existingLayout.truncationType == arguments.truncationType && existingLayout.cutout == arguments.cutout && existingLayout.explicitAlignment == arguments.alignment && existingLayout.lineSpacing.isEqual(to: arguments.lineSpacing) {
                let stringMatch: Bool
                
                var colorMatch: Bool = true
                if let backgroundColor = arguments.backgroundColor, let previousBackgroundColor = existingLayout.backgroundColor {
                    if !backgroundColor.isEqual(previousBackgroundColor) {
                        colorMatch = false
                    }
                } else if (arguments.backgroundColor != nil) != (existingLayout.backgroundColor != nil) {
                    colorMatch = false
                }
                
                if !colorMatch {
                    stringMatch = false
                } else if let existingString = existingLayout.attributedString, let string = arguments.attributedString {
                    stringMatch = existingString.isEqual(to: string)
                } else if existingLayout.attributedString == nil && arguments.attributedString == nil {
                    stringMatch = true
                } else {
                    stringMatch = false
                }
                
                if stringMatch {
                    layout = existingLayout
                } else {
                    layout = TiebaTextNode.calculateLayout(attributedString: arguments.attributedString, minimumNumberOfLines: arguments.minimumNumberOfLines, maximumNumberOfLines: arguments.maximumNumberOfLines, truncationType: arguments.truncationType, backgroundColor: arguments.backgroundColor, constrainedSize: arguments.constrainedSize, alignment: arguments.alignment, verticalAlignment: arguments.verticalAlignment, lineSpacingFactor: arguments.lineSpacing, cutout: arguments.cutout, insets: arguments.insets, lineColor: arguments.lineColor, textShadowColor: arguments.textShadowColor, textShadowBlur: arguments.textShadowBlur, textStroke: arguments.textStroke, displaySpoilers: arguments.displaySpoilers, displayEmbeddedItemsUnderSpoilers: arguments.displayEmbeddedItemsUnderSpoilers, customTruncationToken: arguments.customTruncationToken)
                    updated = true
                }
            } else {
                layout = TiebaTextNode.calculateLayout(attributedString: arguments.attributedString, minimumNumberOfLines: arguments.minimumNumberOfLines, maximumNumberOfLines: arguments.maximumNumberOfLines, truncationType: arguments.truncationType, backgroundColor: arguments.backgroundColor, constrainedSize: arguments.constrainedSize, alignment: arguments.alignment, verticalAlignment: arguments.verticalAlignment, lineSpacingFactor: arguments.lineSpacing, cutout: arguments.cutout, insets: arguments.insets, lineColor: arguments.lineColor, textShadowColor: arguments.textShadowColor, textShadowBlur: arguments.textShadowBlur, textStroke: arguments.textStroke, displaySpoilers: arguments.displaySpoilers, displayEmbeddedItemsUnderSpoilers: arguments.displayEmbeddedItemsUnderSpoilers, customTruncationToken: arguments.customTruncationToken)
                updated = true
            }
            
            let view = maybeView ?? TiebaTextView()
            
            return (layout, {
                view.cachedLayout = layout
                if updated {
                    if layout.size.width.isZero && layout.size.height.isZero {
                        view.layer.contents = nil
                    }
                    view.setNeedsDisplay()
                }
                
                return view
            })
        }
    }
}
