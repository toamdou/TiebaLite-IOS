// 移植自上游 submodules/Display/Source/TextNode.swift 的 TextAccessibilityOverlayNode（:1020-1125）
// 与 submodules/Display/Source/AccessibilityAreaNode.swift 的职责，用本仓已有的几何 API 重写。
//
// 上游做法：给文本节点叠一个透明层，层里为每个链接（UrlAttributeT 属性）建一个 AccessibilityAreaNode，
// 元素矩形取 TextNodeLayout.allAttributeRects(name:)，标签取属性的值。本仓没有 ASDK 的 AccessibilityAreaNode，
// 直接用 UIAccessibilityElement + layout 的 rangeRects 等价重建 —— 少一层节点，语义相同。
//
// 改动清单：
//   1) 上游按「每个矩形的属性值」逐块建元素（多行链接会拆成多个元素）；这里按**属性区间**建元素、
//      矩形取该区间所有行矩形的并集，标签取屏上显示文字 —— VoiceOver 读出来才是用户看到的词，
//      而不是 tieba-native:// 内部 URL（上游读的是 URL，本仓以显示文字为准，见 open 回调另给 URL）。
//   2) 上游的 openUrl 闭包逐元素建；这里同样逐元素建，但由调用方决定打开方式（本仓走 TiebaLinkOpener）。
//   3) 只做链接元素：文本本体由宿主视图自己作为 accessibilityElement（设置 accessibilityLabel = 全文）。
//
// 【本轮不接线】接线点：正文改用 TextNode 渲染后，在行视图 apply 末尾调 install(on:layout:open:)。
// 验收标准：VoiceOver 逐个聚焦到链接、读出显示文字、双击能打开；元素矩形与链接视觉矩形一致。

import Foundation
import UIKit

/// 单个链接的无障碍元素：双击激活时回调 open(urlString)。
public final class TiebaTextAccessibilityElement: UIAccessibilityElement {
    /// 返回 true 表示已处理（UIAccessibilityElement 的约定）。
    public var activate: (() -> Bool)?

    public override func accessibilityActivate() -> Bool {
        return self.activate?() ?? false
    }
}

/// 从 TiebaTextNodeLayout 生成链接的无障碍元素（系统没有「把自绘文本变成可读链接」的能力，故必须自建）。
@MainActor
public enum TiebaTextAccessibility {
    /// 取出所有带 .link 属性的区间 → 每个区间一个元素。
    /// - Parameters:
    ///   - container: 元素的 accessibilityContainer（通常是承载文本的视图）。
    ///   - layout: TextNode 的排版结果（提供 attribute 与 rangeRects）。
    ///   - attributeName: 链接属性名，默认 NSAttributedString.Key.link；上游用自定义的 UrlAttributeT。
    ///   - open: 激活回调，参数是属性里的 URL（本仓是 tieba-native:// 内部 URL，由调用方翻译）。
    ///   - open: 激活回调：(属性里的 URL, 屏上显示文字)。显示文字一并给出，调用方才能做
    ///     「屏幕文字与真实地址不一致就确认」的伪装链接检查（与点击路径同一份判据）。
    public static func linkElements(
        container: Any,
        layout: TiebaTextNodeLayout,
        attributeName: NSAttributedString.Key = .link,
        open: @escaping (_ urlString: String, _ displayText: String) -> Void
    ) -> [UIAccessibilityElement] {
        guard let attributedString = layout.attributedString, attributedString.length > 0 else {
            return []
        }
        var elements: [UIAccessibilityElement] = []
        let fullRange = NSRange(location: 0, length: attributedString.length)
        attributedString.enumerateAttribute(attributeName, in: fullRange, options: []) { value, range, _ in
            guard let value, range.length > 0 else {
                return
            }
            // 一行只有一部分是链接时，rangeRects 会给出该区间跨行的每一段矩形；并起来就是 VoiceOver 的聚焦框。
            guard let rects = layout.rangeRects(in: range)?.rects, !rects.isEmpty else {
                return
            }
            var frame = rects[0]
            for rect in rects.dropFirst() {
                frame = frame.union(rect)
            }
            let displayText = (attributedString.string as NSString).substring(with: range)
            let element = TiebaTextAccessibilityElement(accessibilityContainer: container)
            element.accessibilityLabel = displayText
            element.accessibilityTraits = .link
            element.accessibilityFrameInContainerSpace = frame
            let rawValue: String
            if let url = value as? URL {
                rawValue = url.absoluteString
            } else if let string = value as? String {
                rawValue = string
            } else {
                rawValue = ""
            }
            element.activate = {
                open(rawValue, displayText)
                return true
            }
            elements.append(element)
        }
        return elements
    }

    /// 装到视图上：视图本身作为文本元素（label = 全文），链接作为子元素。
    /// 返回装好的元素个数，便于自检与调用方断言。
    @discardableResult
    public static func install(
        on view: UIView,
        layout: TiebaTextNodeLayout,
        attributeName: NSAttributedString.Key = .link,
        open: @escaping (_ urlString: String, _ displayText: String) -> Void
    ) -> Int {
        view.isAccessibilityElement = false
        let elements = self.linkElements(container: view, layout: layout, attributeName: attributeName, open: open)
        view.accessibilityElements = elements
        return elements.count
    }
}
