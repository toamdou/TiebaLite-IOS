// 帖级快照（原 src/utils/threadSnapshot.ts）：列表→详情携带已知数据，帖子页首帧
// 显示"已知主贴区（标题/作者/摘要/首图）"，不等首包（iOS News 同款状态转场）。
//
// 语义与 JS 逐条一致：点卡片时写入，帖子页首帧消费一次即失效，60s TTL 防过期残留
//（深链/冷启无快照 = 走原整页骨架，行为不变）。只在主线程读写。
import UIKit

struct TiebaThreadSnapshot {
  var id = ""
  var title = ""
  var authorName = ""
  var authorPortrait = ""
  var abstract = ""
  var imageURL: URL?
  var imageWidth = 0.0
  var imageHeight = 0.0
}

extension TiebaThreadSnapshot {
  /// 信息流卡片行 → 快照（点卡片时写入；与 JS 的 setThreadSnapshot(thread) 同源）。
  init(row: TiebaFeedRowModel) {
    self.init()
    id = row.threadId
    title = row.titleText
    authorName = row.displayName
    authorPortrait = row.avatarURL?.absoluteString ?? ""
    abstract = row.abstractText
    let image = row.media.first
    imageURL = image?.url
    imageWidth = image?.width ?? 0
    imageHeight = image?.height ?? 0
  }
}

@MainActor
enum TiebaThreadSnapshots {
  private static let ttl: TimeInterval = 60
  private static var cached: (snapshot: TiebaThreadSnapshot, at: Date)?

  static func set(_ snapshot: TiebaThreadSnapshot) {
    guard !snapshot.id.isEmpty else { return }
    cached = (snapshot, Date())
  }

  /// 首帧消费：id 匹配且未过期才返回，读后立即失效（一次性）。
  static func consume(id: String) -> TiebaThreadSnapshot? {
    guard let entry = cached else { return nil }
    cached = nil
    guard entry.snapshot.id == id, Date().timeIntervalSince(entry.at) <= ttl else { return nil }
    return entry.snapshot
  }
}
