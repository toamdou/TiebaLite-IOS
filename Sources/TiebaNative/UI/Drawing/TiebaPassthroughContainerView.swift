// 移植自上游: submodules/Display/Source/PassthroughContainerNode.swift :1-16
//
// 作用：一个「自身不接收触摸、只把命中测试透传给子节点」的容器。
//       典型场景：覆盖层外壳铺满全屏但不想吃掉点击，只有里面那几个按钮可点。
//
// 改动（逐条）：
//   1. ASDisplayNode → UIView：上游遍历 \`subnodes\` 并对每个 \`subnode.view\` 做 hitTest，
//      UIView 侧直接遍历 \`subviews\`（顺序天然是「后加的在上面」，与上游 subnodes 顺序一致）。
//   2. 类型名 PassthroughContainerNode → TiebaPassthroughContainerView。
//      改「Node→View」后缀是因为它现在真的是 UIView；保留 Node 会让读者以为是别的体系的东西。
//   3. 上游 \`self.view.convert(point, to: subnode.view)\` → \`self.convert(point, to: subview)\`，同一件事。
//   4. 上游对自身返回 nil（不接收触摸）；这里照搬。注意：这样一来背景色仍然会被画出来
//      （drawRect/backgroundColor 与 hitTest 无关），只是点不到 —— 这是上游刻意要的语义。
//   5. Swift 6：UIView 子类天然 @MainActor。

import Foundation
import UIKit

final class TiebaPassthroughContainerView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        for subview in self.subviews {
            if let result = subview.hitTest(self.convert(point, to: subview), with: event) {
                return result
            }
        }
        return nil
    }
}
