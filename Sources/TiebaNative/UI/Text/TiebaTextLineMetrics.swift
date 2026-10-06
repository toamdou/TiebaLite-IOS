// 系统排版 ↔ TextNode 的行高换算（唯一实现，测量端与绘制端共用）。
//
// 为什么需要这一层：本仓的富文本用段落样式钉死行高（minimumLineHeight = maximumLineHeight = 22），
// TextKit/UILabel/UITextView 都读它；而 TextNode 不读段落样式 —— 它用
//     fontLineHeight = floor(ascent + |descent|)，行距 = floor(fontLineHeight × lineSpacingFactor)。
// 要让 TextNode 渲染出与系统逐行等高的结果（15pt 字体 22pt/行、14pt 字体 20pt/行），
// 只能按目标行高反推 factor —— 这个换算在两处被用到（plan 测量、行视图绘制），故只留一份。
//
// 实测：SF 15pt/22pt → base 17、needed 5 → factor 0.30（pitch 17+5=22）；SF 14pt/20pt → 0.25（pitch 16+4=20）。
// 与 UITextView 的高度对拍差 0.0pt（见 docs/uikit-migration/27-落地-textnode.md 的对拍表）。
import Foundation
import UIKit

public enum TiebaTextLineMetrics {
    /// 由「基准字体 + 目标行高」反推行距因子；取满足 floor(base × factor) >= needed 的最小两位小数。
    public static func lineSpacingFactor(for font: UIFont, targetLineHeight: CGFloat) -> CGFloat {
        let base = floor(font.ascender - font.descender)
        guard base > 0.0 else {
            return 0.0
        }
        let needed = targetLineHeight - base
        guard needed > 0.0 else {
            return 0.0
        }
        return (needed / base * 100.0).rounded(.up) / 100.0
    }
}
