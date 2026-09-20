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

  /// 内容列最大宽度。iPad 横竖屏下容器宽到 1000pt+，正文行宽跟着拉满会变成
  /// 一句 60 个汉字（眼睛跟不住、图片也被拉成大板），所以超过这条线的宽度
  /// 平分给左右外边距，整列居中——各列表的 horizontalInset 按此推导。
  public static let maxContentWidth: CGFloat = 700

  /// 底部浮动条（toast 胶囊 / 帖子页浮动胶囊）的最大宽度：按内容自撑的条
  /// 若仍以视图宽定上限，iPad 上会拉成 700pt+ 的长条。胶囊自身 intrinsic 上限
  /// 356（文案 300 + 内白 32 + 指示器 24），取 360 让最长文案完整。
  public static let floatingMaxWidth: CGFloat = 360
}
