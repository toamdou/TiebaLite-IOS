// 排版自检的 **UI 半段**（③ 字体 + 行盒同步）。
//
// 为什么单独一个文件：这一段拿的是**真实测量链**——TiebaFeedRowLayout.Fonts/LineHeights、
// TiebaSimpleText.singleLineWidth/bodyFont、TiebaPostRowLayout.titleLineHeight。这些是行布局，
// 属 UI/ListKit；而 TiebaTypography 住 Core。Core 反向引用 UI 就是依赖倒挂，UI 模块也就
// 不可能独立成库（2026-10-08 依赖倒置）。于是把这一段搬到 UI 层，Core 的
// TiebaTypography.selfCheck() 只保留 ① 换算 / ② 旧键迁移。
//
// 用法（与其余 selfCheck 同款：测试目标或调试期手动跑）：
//   _ = TiebaTypography.selfCheck() ?? TiebaTypography.selfCheckRowChain()
// 返回 nil = 全过。

import UIKit

extension TiebaTypography {
  /// ③ **"字号变了"必须同时改字与行盒**（本仓最容易出 bug 的地方）：
  /// 比 12pt 与 24pt 两档，字体 pointSize、行高、单行测量宽都必须严格变大。
  /// 只改字不改行高，多行正文就会互相压；只改行高不改字，文本会被裁。
  static func selfCheckRowChain() -> String? {
    var failures: [String] = []
    func expect(_ ok: Bool, _ label: String) {
      if !ok { failures.append(label) }
    }

    let smallScale = CGFloat(sizeRange.lowerBound / referenceSize)
    let largeScale = CGFloat(sizeRange.upperBound / referenceSize)
    let small = TiebaFeedRowLayout.geometry(containerWidth: 390, fontScale: smallScale)
    let large = TiebaFeedRowLayout.geometry(containerWidth: 390, fontScale: largeScale)
    expect(large.fonts.abstract.pointSize > small.fonts.abstract.pointSize + 1, "正文字体没随字号变大")
    expect(large.lineHeights.abstract > small.lineHeights.abstract + 1, "正文行盒没随字号变大")
    expect(large.fonts.title.pointSize > small.fonts.title.pointSize + 1, "标题字体没随字号变大")
    expect(large.lineHeights.title > small.lineHeights.title + 1, "标题行盒没随字号变大")
    let smallWidth = TiebaSimpleText.singleLineWidth("字号示例文字", font: small.fonts.abstract)
    let largeWidth = TiebaSimpleText.singleLineWidth("字号示例文字", font: large.fonts.abstract)
    expect(largeWidth > smallWidth + 1, "单行测量宽没随字号变大（字号没传到测量链）")
    // 帖子详情（正文级另一条链）：标题行盒基准 22pt × 当前正文倍率。
    expect(
      TiebaPostRowLayout.titleLineHeight >= ceil(22 * Double(smallScale)) - 1,
      "帖子卡标题行盒没随正文级字号缩放")
    expect(
      TiebaSimpleText.bodyFont(size: 15, weight: .regular).pointSize > 0,
      "bodyFont 不可用")

    return failures.isEmpty ? nil : failures.joined(separator: " / ")
  }
}
