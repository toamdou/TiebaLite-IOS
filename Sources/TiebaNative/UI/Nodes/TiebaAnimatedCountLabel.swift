// 移植自上游 submodules/AnimatedCountLabelNode/Sources/AnimatedCountLabelNode.swift
//
// 上游这个文件里有两个几乎同构的类：AnimatedCountLabelNode（ASDisplayNode + asyncLayout）
// 与 AnimatedCountLabelView（UIView + update）。本移植只保留后者的形态 —— 它本来就是
// UIKit 视图版本，正好是本仓的目标形态，零语义损失。
//
// 改动（逐条编号，均相对上游）：
//   1. 只移植 AnimatedCountLabelView 一路；AnimatedCountLabelNode 的 asyncLayout 两段式
//      是 ASDisplayKit 的协议，本仓没有对应机制。ImmediateAnimatedCountLabelNode 的
//      updateLayout(size:insets:animated:) 与 makeCopy() 保留下来，做成同一个类上的方法。
//   2. 数字切分：上游 Node 版按「value % 10 逐位取余」切，View 版按 string 的字符逐个切。
//      这里取 View 版 —— 它尊重调用方真正传进来的字符串（"1.2万"、"12.3K" 这类带后缀的
//      计数不会被切成错的位数）。
//   3. TextNode → UILabel。上游每段文字是一个自绘 CoreText 的 TextNode；这里渲染交给
//      UILabel（真文本层），但**尺寸仍用 CoreText 量**（CTLineGetTypographicBounds）：
//      UILabel.sizeThatFits 会带上它自己的行高取整，逐段拼接时累积误差，而 CTLine 的
//      排印宽度与上游 TextNode 的度量口径一致。
//   4. textNode.layer.snapshotContentTree() → TiebaNodesGraphics.snapshotLayer(of:)，
//      animateScale/animateAlpha/animatePosition → 本仓 UI/Components/TiebaCAAnimationUtils.swift
//      的 CALayer.animate*（本次接线统一，见 TiebaNodeSupport.swift 改动 6）。
//   5. transition.updateFrameAdditive(node:frame:) → TiebaNodesTransition.updateFrameAdditive，
//      过渡类型见 TiebaNodeSupport.swift（本仓不做 ContainedViewLayoutTransition）。
//   6. 上游 View 版把 contentSize.width 一律按 floor(width * 0.9) 累加，但摆放时只在
//      reducedLetterSpacing 为真才乘 0.9 —— 返回的宽度与真实占用宽度对不上（默认参数下
//      差 10%）。这里两处统一：reducedLetterSpacing 决定用不用 0.9。
//   7. 上游 TextNode.asyncLayout 每次都再造一个节点、再 replace 旧节点；UILabel 就地改
//      attributedText 即可（同一实例），因此「换实例」那条分支在本移植里不存在，
//      换成「同一个 key 一律复用同一个 UILabel」。入场/退场动画的触发条件一字未改。
//   8. 移除上游注释掉的两处死代码（effectiveSegmentWidth 的 2.0 取整、被注释掉的
//      % 10 切分）。
//   9. 上游两版对滚动方向的判据相反（Node: 当前值 > 新值 ⇒ 向上；View: 当前值 < 新值 ⇒ 向上）。
//      这里采用 View 版判据。reverseAnimationDirection / alwaysOneDirection 语义同上游。
//  10. import Display / AsyncDisplayKit 去掉：本文件不需要任何图像生成工具，
//      只用 UIKit + CoreText。
//
// 并发：整类 @MainActor（UIView 子类）。动画全部交给 CAAnimation，不用 CADisplayLink。

import Foundation
import UIKit
import QuartzCore
import CoreText

/// 会「滚数字」的计数标签（上游 AnimatedCountLabelView）。
///
/// 用法：把格式化的数字按段交给 update(...)。同一 key 的段复用同一个 UILabel，
/// 数字段的值变化时旧数字会飞出去、新数字滚进来。
public final class TiebaAnimatedCountLabel: UIView {
    public struct Layout {
        public var size: CGSize
        public var isTruncated: Bool

        public init(size: CGSize, isTruncated: Bool) {
            self.size = size
            self.isTruncated = isTruncated
        }
    }

    /// 一段内容。number 携带「这个数字是多少」（用于判断滚动方向），
    /// text 是固定文案（后缀、分隔符等）。两者的第二项都是真正要画的属性文本。
    public enum Segment: Equatable {
        case number(Int, NSAttributedString)
        case text(Int, NSAttributedString)

        public static func == (lhs: Segment, rhs: Segment) -> Bool {
            switch lhs {
            case let .number(number, text):
                if case let .number(rhsNumber, rhsText) = rhs {
                    return number == rhsNumber && text.isEqual(to: rhsText)
                }
                return false
            case let .text(index, text):
                if case let .text(rhsIndex, rhsText) = rhs {
                    return index == rhsIndex && text.isEqual(to: rhsText)
                }
                return false
            }
        }
    }

    /// 解析后的段：key 决定「这是哪一槽位」，字符串里每个字符各占一槽。
    fileprivate enum ResolvedSegment: Equatable {
        enum Key: Hashable {
            case number(Int)
            case text(Int)
        }

        case number(id: Int, value: Int, string: NSAttributedString)
        case text(id: Int, string: NSAttributedString)

        static func == (lhs: ResolvedSegment, rhs: ResolvedSegment) -> Bool {
            switch lhs {
            case let .number(id, number, text):
                if case let .number(rhsId, rhsNumber, rhsText) = rhs {
                    return id == rhsId && number == rhsNumber && text.isEqual(to: rhsText)
                }
                return false
            case let .text(index, text):
                if case let .text(rhsIndex, rhsText) = rhs {
                    return index == rhsIndex && text.isEqual(to: rhsText)
                }
                return false
            }
        }

        var attributedText: NSAttributedString {
            switch self {
            case let .number(_, _, text):
                return text
            case let .text(_, text):
                return text
            }
        }

        var key: Key {
            switch self {
            case let .number(id, _, _):
                return .number(id)
            case let .text(index, _):
                return .text(index)
            }
        }
    }

    /// 每个槽位一个 UILabel（上游是每个槽位一个 TextNode）。
    fileprivate var resolvedSegments: [ResolvedSegment.Key: (ResolvedSegment, UILabel)] = [:]

    /// 对齐：数字项的锚点方向。右对齐（值在左、标签在右这类排版）时，
    /// 宽度变化向**左**生长，右侧的标签/图标不被顶动。
    /// 移植自上游 AnimatedCounterComponent.swift:241-248（anchorPoint + 显式 position）。
    public enum Alignment: Sendable {
        case leading
        case trailing
    }

    /// 缺省左对齐（锚点 0，宽度变化向右生长）。
    public var alignment: Alignment = .leading

    /// 每 pt 位移换多少秒入场延迟。
    /// 移植自上游 submodules/AnimatedTextComponent/Sources/AnimatedTextComponent.swift:139 的
    /// delayNorm = 0.002 与 :302-317 的 delay = delayNorm × **像素距离**。
    /// 用距离而不是槽位序号：位数一变（"9"→"10"）各段被推开的距离并不相同，按序号给延迟
    /// 会让波浪在屏幕上的推进速度忽快忽慢；按距离给则恒定（等宽数字与中文后缀混排也一样）。
    public static let delayPerPoint: Double = 0.002

    /// 数字变大时反着滚（上游同名开关）。
    public var reverseAnimationDirection: Bool = false
    /// 一律朝同一个方向滚，不看数字变大还是变小。
    public var alwaysOneDirection: Bool = false

    /// 最近一次 updateLayout 的入参，供 makeCopy() 复现布局用。
    private var constrainedSize: CGSize?
    private var lastInsets: UIEdgeInsets = .zero
    private var lastSegments: [Segment] = []
    private var lastReducedLetterSpacing: Bool = false

    public override init(frame: CGRect) {
        super.init(frame: frame)

        self.isUserInteractionEnabled = false
        self.backgroundColor = .clear
        self.clipsToBounds = true
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 上游 ImmediateAnimatedCountLabelNode.updateLayout(size:insets:animated:)。
    @discardableResult
    public func updateLayout(size: CGSize, insets: UIEdgeInsets = .zero, animated: Bool) -> CGSize {
        self.constrainedSize = size
        self.lastInsets = insets
        // 上游 Immediate 版把 animated 直接当「要不要动画」；update 内部还会在「原本是空的」
        // 情况下强制 immediate（首帧没有可对比的上一帧），两条规则叠加后语义一致。
        let transition: TiebaNodesTransition = animated ? .animated(duration: 0.2) : .immediate
        let layout = self.update(size: size, segments: self.lastSegments, insets: insets, transition: transition)
        return layout.size
    }

    /// 上游 ImmediateAnimatedCountLabelNode.makeCopy()：复制一份同尺寸、同内容的静态副本
    /// （没有入场动画），用于转场快照。
    public func makeCopy() -> TiebaAnimatedCountLabel {
        let copy = TiebaAnimatedCountLabel(frame: self.frame)
        copy.reverseAnimationDirection = self.reverseAnimationDirection
        copy.alwaysOneDirection = self.alwaysOneDirection
        if let constrainedSize = self.constrainedSize {
            copy.update(size: constrainedSize, segments: self.lastSegments, insets: self.lastInsets, transition: .immediate)
        }
        return copy
    }

    /// 设置内容并布局。对应上游 AnimatedCountLabelView.update(size:segments:reducedLetterSpacing:transition:)。
    @discardableResult
    public func update(size: CGSize, segments initialSegments: [Segment], insets: UIEdgeInsets = .zero, reducedLetterSpacing: Bool = false, transition: TiebaNodesTransition) -> Layout {
        self.lastSegments = initialSegments
        self.lastReducedLetterSpacing = reducedLetterSpacing

        let wasEmpty = self.resolvedSegments.isEmpty
        let reverseAnimationDirection = self.reverseAnimationDirection
        let alwaysOneDirection = self.alwaysOneDirection

        // 展平成「一字符一槽」。
        var segments: [ResolvedSegment] = []
        loop: for segment in initialSegments {
            switch segment {
            case let .number(value, string):
                if string.string.isEmpty {
                    continue loop
                }
                let attributes = string.attributes(at: 0, longestEffectiveRange: nil, in: NSRange(location: 0, length: 1))
                for character in string.string {
                    // 见文件头改动 2：按真实字符切，数字字符与文字字符分别归到两种槽位。
                    if Int(String(character)) != nil {
                        segments.append(.number(id: 1000 + segments.count, value: value, string: NSAttributedString(string: String(character), attributes: attributes)))
                    } else {
                        segments.append(.text(id: 1000 + segments.count, string: NSAttributedString(string: String(character), attributes: attributes)))
                    }
                }
            case let .text(id, string):
                segments.append(.text(id: id, string: string))
            }
        }

        // 见文件头改动 6：宽度累加与摆放间距用同一个系数。
        let spacingFactor: CGFloat = reducedLetterSpacing ? 0.9 : 1.0

        var contentSize = CGSize()
        var remainingSize = size
        var calculatedSegments: [ResolvedSegment.Key: (size: CGSize, width: CGFloat, apply: () -> UILabel)] = [:]
        var isTruncated = false
        var validKeys: [ResolvedSegment.Key] = []

        for segment in segments {
            validKeys.append(segment.key)

            let measured = Self.measure(segment.attributedText, maximumWidth: remainingSize.width)
            var effectiveSegmentWidth = measured.size.width
            if case .number = segment {
                // 上游此处留了个被注释掉的「宽度取偶数」调整，见文件头改动 8，不再保留。
            } else if segment.attributedText.string == " " {
                // 空格在部分字体下量出来接近 0，上游保底 4pt。
                effectiveSegmentWidth = max(effectiveSegmentWidth, 4.0)
            }
            if measured.isTruncated {
                isTruncated = true
            }

            calculatedSegments[segment.key] = (measured.size, effectiveSegmentWidth, { [weak self] in
                guard let self else {
                    return UILabel()
                }
                return self.label(for: segment)
            })
            contentSize.width += floor(effectiveSegmentWidth * spacingFactor)
            contentSize.height = max(contentSize.height, measured.size.height)
            remainingSize.width = max(0.0, remainingSize.width - measured.size.width)
        }

        // 首帧不播动画（没有「上一帧」可对比），上游同款。
        var transition = transition
        if wasEmpty {
            transition = .immediate
        }

        // 上游 Node 版的起点是 (insets.left, 0.0)：纵向由调用方摆视图，段内不做纵向内缩。
        var currentOffset = CGPoint(x: insets.left, y: 0.0)
        for segment in segments {
            var animation: (CGFloat, Double)?
            if let (currentSegment, currentLabel) = self.resolvedSegments[segment.key] {
                if case let .number(_, currentValue, currentString) = currentSegment,
                   case let .number(_, updatedValue, updatedString) = segment,
                   transition.isAnimated, !wasEmpty,
                   currentValue != updatedValue, currentString.string != updatedString.string,
                   let snapshot = TiebaNodesGraphics.snapshotLayer(of: currentLabel, scale: self.traitCollection.displayScale) {
                    var fromAlpha: CGFloat = 1.0
                    if let presentation = currentLabel.layer.presentation() {
                        fromAlpha = CGFloat(presentation.opacity)
                    }
                    var offsetY: CGFloat
                    // 见文件头改动 9：采用 View 版判据。
                    if currentValue < updatedValue || alwaysOneDirection {
                        offsetY = -floor(currentLabel.bounds.height * 0.6)
                    } else {
                        offsetY = floor(currentLabel.bounds.height * 0.6)
                    }
                    if reverseAnimationDirection {
                        offsetY = -offsetY
                    }
                    animation = (-offsetY, 0.2)
                    // snapshotLayer 已经把 frame 摆成 label 在父视图里的位置。
                    self.layer.addSublayer(snapshot)
                    snapshot.animatePosition(from: CGPoint(), to: CGPoint(x: 0.0, y: offsetY), duration: 0.2, removeOnCompletion: false, additive: true)
                    snapshot.animateScale(from: 1.0, to: 0.3, duration: 0.2, removeOnCompletion: false)
                    snapshot.animateAlpha(from: fromAlpha, to: 0.0, duration: 0.2, removeOnCompletion: false, completion: { [weak snapshot] _ in
                        snapshot?.removeFromSuperlayer()
                    })
                }
            }

            guard let calculated = calculatedSegments[segment.key] else {
                continue
            }
            let label = calculated.apply()
            let segmentFrame = CGRect(origin: currentOffset, size: calculated.size)
            // A5：延迟 = 0.002 × 本段被推开的像素距离（上游 :302-317）。首帧的新槽位没有
            // "上一个位置"，距离取 0 —— 它就是波浪起点，其余段按离它多远依次跟上。
            let shiftDelay = label.frame.isEmpty
                ? 0.0
                : Self.delayPerPoint * Double(abs(segmentFrame.minX - label.frame.minX))
            // 右对齐：锚点 1 + position 落在 bounds 右缘（与左对齐同一视觉矩形，
            // 只是「宽度变化时哪条边不动」不同）。放在下面摆 frame 之前：
            // 换锚点会连带动 position，必须在同一次里一起写掉。
            let anchorX: CGFloat = self.alignment == .trailing ? 1.0 : 0.0
            if label.layer.anchorPoint.x != anchorX {
                label.layer.anchorPoint = CGPoint(x: anchorX, y: 0.5)
                label.layer.position = CGPoint(x: label.bounds.width * anchorX, y: label.bounds.height / 2.0)
            }
            if label.frame.isEmpty {
                label.frame = segmentFrame
                if transition.isAnimated, !wasEmpty, animation == nil {
                    label.layer.animateScale(from: 0.1, to: 1.0, duration: 0.2, delay: shiftDelay)
                    label.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2, delay: shiftDelay)
                }
            } else if label.frame != segmentFrame {
                transition.updateFrameAdditive(label, frame: segmentFrame)
            }
            currentOffset.x += calculated.width * spacingFactor

            if self.resolvedSegments[segment.key] == nil {
                self.addSubview(label)
            }
            if let (offset, duration) = animation {
                label.layer.removeAllAnimations()
                label.layer.animatePosition(from: CGPoint(x: 0.0, y: offset), to: CGPoint(), duration: duration, delay: shiftDelay, additive: true)
                label.layer.animateScale(from: 0.3, to: 1.0, duration: duration, delay: shiftDelay)
                label.layer.animateAlpha(from: 0.0, to: 1.0, duration: duration, delay: shiftDelay)
            }
            self.resolvedSegments[segment.key] = (segment, label)
        }

        // 本帧不再出现的槽位：飞出去再摘。
        var removeKeys: [ResolvedSegment.Key] = []
        for key in self.resolvedSegments.keys where !validKeys.contains(key) {
            removeKeys.append(key)
        }
        for key in removeKeys {
            guard let (_, label) = self.resolvedSegments.removeValue(forKey: key) else {
                continue
            }
            if transition.isAnimated {
                label.layer.animateScale(from: 1.0, to: 0.1, duration: 0.2, removeOnCompletion: false)
                label.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.2, removeOnCompletion: false, completion: { [weak label] _ in
                    label?.removeFromSuperview()
                })
            } else {
                label.removeFromSuperview()
            }
        }

        return Layout(size: contentSize, isTruncated: isTruncated)
    }

    // MARK: - 文本

    /// 取（或建）该槽位的 UILabel。见文件头改动 7：同一 key 一律复用同一实例。
    private func label(for segment: ResolvedSegment) -> UILabel {
        if let (_, existing) = self.resolvedSegments[segment.key] {
            existing.attributedText = segment.attributedText
            return existing
        }
        let label = UILabel()
        label.numberOfLines = 1
        label.lineBreakMode = .byClipping
        label.isUserInteractionEnabled = false
        label.backgroundColor = .clear
        label.attributedText = segment.attributedText
        return label
    }

    /// 用 CoreText 量单段文本（见文件头改动 3）。返回的 width 已按可用宽度钳制，
    /// isTruncated 表示「本来更宽、被钳了」。
    private static func measure(_ attributedString: NSAttributedString, maximumWidth: CGFloat) -> (size: CGSize, isTruncated: Bool) {
        let available = max(0.0, maximumWidth)
        if attributedString.length == 0 {
            return (CGSize(width: 0.0, height: 0.0), false)
        }
        let line = CTLineCreateWithAttributedString(attributedString)
        var ascent: CGFloat = 0.0
        var descent: CGFloat = 0.0
        var leading: CGFloat = 0.0
        let naturalWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let height = ceil(ascent + descent + leading)
        let isTruncated = naturalWidth > available
        return (CGSize(width: min(naturalWidth, available), height: height), isTruncated)
    }
}
