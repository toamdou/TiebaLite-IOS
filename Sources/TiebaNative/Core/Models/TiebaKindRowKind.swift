import UIKit

/// 行种类（JS 行字典的顶层键 `kind`；缺省 = `.simple`，与既有契约兼容）。
public nonisolated enum TiebaKindRowKind: String, Sendable {
  /// TiebaSimpleRows 的四个变体（user / message / section / summary）。
  case simple
  /// 信息流卡片行（ThreadInfo 形状；TiebaRowMetrics + TiebaFeedRowView）。
  case feed
  /// 帖子行（帖子页主贴/回复；TiebaPostRowMetrics + TiebaPostRowView，
  /// 只由原生页面（thread/[id]）经 publish(pageKey:kinds:) 使用）。
  case post
}
