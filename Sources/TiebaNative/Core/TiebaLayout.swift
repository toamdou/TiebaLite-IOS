// ============================================================
// TiebaLite — 布局量化（TiebaLayout）
//
// 行宽 0.5pt 量化契约：各度量族与集合布局必须逐位一致，否则宽度闸门拒绝命中、
// 整列表退回兜底高。全仓唯一实现，任何文件都不要再抄公式（0.5pt 抖动不换页）。
// ============================================================

import CoreGraphics

public nonisolated enum TiebaLayout {
  /// 行宽量化（也叫 itemWidth / containerWidth 的量化口径）。
  public static func quantize(_ width: CGFloat) -> CGFloat {
    (width * 2).rounded() / 2
  }
}
