// TiebaImmediateTextNode —— 同步测量的轻量文本节点（尺寸/截断/行数即时可查）。
//
// 移植自上游 submodules/Display/Source/ImmediateTextNode.swift。
// 本仓改名：ImmediateTextNode → TiebaImmediateTextNode、ImmediateTextNodeLayoutInfo → TiebaImmediateTextNodeLayoutInfo、typealias ImmediateTextView → TiebaImmediateTextView —— 公开符号加本仓前缀，避免污染模块全局命名空间。
//
// 本仓改动（2026-10-05 更新：本模块的文本坐标系已落地在 UI/Text/，见下 1）：
//   1) 上游 open class ImmediateTextNode: TextNode（ASDisplayNode 外壳）。本模块按裁决丢弃 ASDisplayNode 外壳：
//      UI/Text/TiebaTextNodeLayout.swift（TextNodeLayout 等数据模型）、
//      UI/Text/TiebaTextNodeRenderer.swift（enum TiebaTextNode 命名空间，上游 TextNode 的排版/测量/绘制静态实现）、
//      UI/Text/TiebaTextView.swift（open class TiebaTextView: UIView，上游 TextView）三者合起来替代上游 TextNode。
//      故本类的基类 = TiebaTextView（UIView），排版/测量/绘制全部沿用上游同一套静态实现（未重写任何算法）。
//      类型名按铁律 6 加了 Tieba 前缀，本文件同步改名：TextNodeLayoutArguments → TiebaTextNodeLayoutArguments、
//      TextNodeLayout → TiebaTextNodeLayout、TextVerticalAlignment → TiebaTextVerticalAlignment、
//      TextNodeCutout → TiebaTextNodeCutout、TextView → TiebaTextView。
//      上游同文件里的 open class ImmediateTextView: TextView 与本类在本模块里是同一件事，
//      因此用 typealias TiebaImmediateTextView = TiebaImmediateTextNode 保留上游第二个名字。
//   2) 去掉 ASDK 生命周期：override func didLoad()（ASDisplayNode 回调）删除——它只调用下面的
//      updateInteractiveActions()，而交互部分整体未搬（见 5）。
//   3) addSubnode / removeFromSupernode / isNodeLoaded 等 AS* 调用随交互部分一起去掉。
//   4) [移植] 删除 public class ASTextNode: ImmediateTextNode（上游 :218-234）：
//      它是 AS* 类型名（铁律 4），内容只是 maximumNumberOfLines = 0 + override
//      calculateSizeThatFits(_:) 的 ASDK 适配，本模块用 TiebaImmediateTextNode 即可。
//   5) [移植] 交互部分仍未搬（上游 :56-75、:135-215 及 :276-293、:333-408）：tapRecognizer
//      (TapLongTapOrDoubleTapGestureRecognizer)、linkHighlightingNode、linkHighlightColor / linkHighlightInset、
//      highlightAttributeAction / tapAttributeAction / longTapAttributeAction、updateInteractiveActions()、
//      tapAction(_:)。
//      进度：LinkHighlightingNode 类已补回（UI/Text/TiebaLinkHighlightingNode.swift，含上游 :322-429 的类与
//      全部几何绘制），剩下的唯一阻塞项是 TapLongTapOrDoubleTapGestureRecognizer —— 本仓仍未移植，
//      没有它就无法把"按下链接"翻译成 highlightAttributeAction。等它落地后按上游原样补回即可
//      （届时 addSubnode → addSubview、removeFromSupernode → removeFromSuperview）。
//   6) 其余（TiebaImmediateTextNodeLayoutInfo / 所有测量方法与属性）逐行照搬。

import Foundation
import UIKit

public struct TiebaImmediateTextNodeLayoutInfo {
    public let size: CGSize
    public let truncated: Bool
    public let numberOfLines: Int
    
    public init(size: CGSize, truncated: Bool, numberOfLines: Int) {
        self.size = size
        self.truncated = truncated
        self.numberOfLines = numberOfLines
    }
}

open class TiebaImmediateTextNode: TiebaTextView {
    public var attributedText: NSAttributedString?
    public var textAlignment: NSTextAlignment = .natural
    public var verticalAlignment: TiebaTextVerticalAlignment = .top
    public var truncationType: CTLineTruncationType = .end
    public var maximumNumberOfLines: Int = 1
    public var lineSpacing: CGFloat = 0.0
    public var insets: UIEdgeInsets = UIEdgeInsets()
    public var textShadowColor: UIColor?
    public var textShadowBlur: CGFloat?
    public var textStroke: (UIColor, CGFloat)?
    public var cutout: TiebaTextNodeCutout?
    public var displaySpoilers = false
    
    public var trailingLineWidth: CGFloat?
    
    public var constrainedSize: CGSize?
    
    open func updateLayout(_ constrainedSize: CGSize) -> CGSize {
        self.constrainedSize = constrainedSize
        
        let makeLayout = TiebaTextView.asyncLayout(self)
        let (layout, apply) = makeLayout(TiebaTextNodeLayoutArguments(attributedString: self.attributedText, backgroundColor: nil, maximumNumberOfLines: self.maximumNumberOfLines, truncationType: self.truncationType, constrainedSize: constrainedSize, alignment: self.textAlignment, verticalAlignment: self.verticalAlignment, lineSpacing: self.lineSpacing, cutout: self.cutout, insets: self.insets, textShadowColor: self.textShadowColor, textShadowBlur: self.textShadowBlur, textStroke: self.textStroke, displaySpoilers: self.displaySpoilers))
        let _ = apply()
        if layout.numberOfLines > 1 {
            self.trailingLineWidth = layout.trailingLineWidth
        } else {
            self.trailingLineWidth = nil
        }
        return layout.size
    }
    
}

