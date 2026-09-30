// 帖级快照（原 src/utils/threadSnapshot.ts）：列表→详情携带已知数据，帖子页首帧
// 显示"已知主贴区（标题/作者/摘要/首图）"，不等首包（iOS News 同款状态转场）。
//
// 原生语义 = 一次性交付：点卡片写入、帖子页首帧按同 id 消费一次即失效。不需要 TTL，
// 也不在 id 不符时清缓存——交付窗口只有"点击到下一屏首帧"，一次消费即无残留。
// 只在主线程读写。
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
  /// 列表里**已经解好并显示中**的缩略图位图。占位卡的图按卡片宽取图（与列表行
  /// 文本列宽不同 ⇒ Nuke 缓存键不同），重新下载解码期间若没有它就只剩灰底
  ///（用户 2026-09-19 报的"明明缩略图已加载好，进帖一片灰"）。
  var thumbnailImage: UIImage?
  /// 卡片所属吧：顶栏右侧的吧按钮在首包落地前就靠它画（否则按钮"突然"出现，
  /// 用户 2026-09-25 实证）。深链无快照时仍等首包。
  var forumName = ""
  var forumAvatarURL: URL?
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
    forumName = row.forumName
    forumAvatarURL = row.forumAvatarURL
  }
}

@MainActor
enum TiebaThreadSnapshots {
  private static var cached: TiebaThreadSnapshot?

  static func set(_ snapshot: TiebaThreadSnapshot) {
    guard !snapshot.id.isEmpty else { return }
    cached = snapshot
  }

  /// 首帧消费一次：同 id 才命中并取走；id 不符不动缓存（留给它自己的帖子页）。
  static func consume(id: String) -> TiebaThreadSnapshot? {
    guard let snapshot = cached, snapshot.id == id else { return nil }
    cached = nil
    return snapshot
  }

  /// 只读探查（**不消费**）：转场层用它判断"这次跳帖是不是点卡片进来的"。
  /// 是 → 才为这一跳打开 Hero；否则走系统原生 push（见 TiebaNavigator 的 heroArmed 说明）。
  static func peek(id: String) -> TiebaThreadSnapshot? {
    guard let snapshot = cached, snapshot.id == id else { return nil }
    return snapshot
  }
}
