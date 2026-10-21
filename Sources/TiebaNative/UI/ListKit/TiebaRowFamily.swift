// TiebaLite — 行族契约（TiebaRowFamily）
//
// 三族行（post / feed / simple）在「这一行多高」上只有两处差异：
//   ① 怎么取「当前宽度下已测的模型」；
//   ② 怎么「同步补测一次」。
// 原来这段四步降级阶梯（已测 → 补测 → 上一次真实高度 → 缺页通知 + 0）在
// TiebaKindListContentView.frameHeight(at:width:syncRemeasure:) 里被 switch kind(at:)
// 抄了三遍，三段唯一不同的就是上面两处 + simple 的缺页通知闸门。本文件把那两处差异
// 收进 TiebaRowFamily 的两个方法，阶梯只在 frameHeight 里写一遍。
//
// 访问级别：族的实现要查列表的 private 查询（postModel/feedModel/simpleModel/subIndex/
// contentIdentity/pageRowCount/notifyPageDataMissing），故 TiebaKindListView.swift 末尾
// 留了一层**同义转发**的 rowFamily* 桥——不去放大那些 private 的访问级别。

import CoreGraphics

@MainActor
enum TiebaRowFamily {
  case post
  case feed
  case simple

  /// `.none`（页记录里没有这一行的种类）按 simple 处理，与 frameHeight 原来的
  /// `case .simple, .none:` 同一分支。
  init(_ kind: TiebaKindRowKind?) {
    switch kind {
    case .post: self = .post
    case .feed: self = .feed
    case .simple, .none: self = .simple
    }
  }

  /// ① 当前宽度下的实测高度（nil = 没有可用的已测模型，交给下一步）。
  ///
  /// 三族各自的门槛：
  ///   · post：模型自带 containerWidth，宽度对不上即视为没测过；
  ///   · feed：同上（取模型走 feedModel(at:width:)，内容身份优先）；
  ///   · simple：模型没有 containerWidth 字段，只能要求 measuredHeight > 0。
  func measuredHeight(
    in list: TiebaKindListContentView, at index: Int, width: CGFloat
  ) -> CGFloat? {
    switch self {
    case .post:
      // 帖子行：高度自带（含卡片内外边距）；宽度闸门同 feed 行。
      guard let model = list.rowFamilyPostModel(at: index), model.containerWidth == width else {
        return nil
      }
      return model.measuredHeight
    case .feed:
      // 信息流行：高度 = 行模型自带（含卡片外 4pt 上下边距）。
      guard let row = list.rowFamilyFeedModel(at: index, width: width),
        row.containerWidth == width
      else {
        return nil
      }
      return row.measuredHeight
    case .simple:
      guard let measured = list.rowFamilySimpleModel(at: index, width: width)?.measuredHeight,
        measured > 0
      else {
        return nil
      }
      return measured
    }
  }

  /// ② 同步补测一次（nil = 补不出来：源数据确实不在）。
  ///
  /// 三族的差别只是「补测入口 + 位置参数怎么取」：
  ///   · post 走整页键 + 族内下标（TiebaPostRowMetrics.ensureRow）；
  ///   · feed / simple 走内容身份（TiebaRowMetrics.ensureFeedRow / TiebaSimpleRowMetrics.ensureRow）。
  func ensureHeight(
    in list: TiebaKindListContentView, at index: Int, width: CGFloat
  ) -> CGFloat? {
    switch self {
    case .post:
      guard let sub = list.rowFamilySubIndex(at: index),
        let remeasured = TiebaPostRowMetrics.shared.ensureRow(
          pageKey: list.pageKey, index: sub, containerWidth: width)
      else {
        return nil
      }
      return remeasured.measuredHeight
    case .feed:
      guard let identity = list.rowFamilyContentIdentity(at: index),
        let remeasured = TiebaRowMetrics.shared.ensureFeedRow(
          identity: identity, pageKey: list.pageKey, index: index, containerWidth: width)
      else {
        return nil
      }
      return remeasured.measuredHeight
    case .simple:
      guard let identity = list.rowFamilyContentIdentity(at: index),
        let remeasured = TiebaSimpleRowMetrics.shared.ensureRow(
          identity: identity, pageKey: list.pageKey, index: index, containerWidth: width)
      else {
        return nil
      }
      return remeasured.measuredHeight
    }
  }

  /// ④ 连「上一次真实高度」都没有时是否要请宿主重推。
  ///
  /// post / feed 无条件通知；simple 多一道闸门（页记录还没发布时通知没意义，
  /// 且整页重推会与首帧发布打架）。
  func notifiesOnMissing(in list: TiebaKindListContentView) -> Bool {
    switch self {
    case .post, .feed:
      return true
    case .simple:
      return list.rowFamilyPageRowCount > 0 && !list.pageKey.isEmpty
    }
  }
}
