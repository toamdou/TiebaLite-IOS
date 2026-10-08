import UIKit

/// 吧名/吧头像回填（原 search.ts 的 `forum_name ?? forumInfo?.forum_name` +
/// feed.ts:97-118 backfillForumAvatars 的唯一落点）：各页行字典的吧名键位不同、
/// 服务端 personalized/动态流恒不下发吧头像，缺名会让度量判据
/// （showForumPill && !forumName.isEmpty）把整块徽章判为不渲染。
/// 头像回填只读全站缓存 KV（forum_avatars_v1，无网络副作用），已有值不覆盖。
nonisolated enum TiebaFeedRowFallback {
  struct Resolved {
    var name = ""
    var avatar = ""
  }

  static func resolve(_ row: [String: Any]) -> Resolved {
    let name = forumName(row)
    return Resolved(name: name, avatar: forumAvatar(row, forumName: name))
  }

  /// 吧名逐键兜底（含 mapProtoThread 的 fname / forumInfo.name / forum.name 变体）。
  static func forumName(_ row: [String: Any]) -> String {
    let forumInfo = row["forumInfo"] as? [String: Any]
    let forumInfoSnake = row["forum_info"] as? [String: Any]
    let forum = row["forum"] as? [String: Any]
    let candidates: [Any?] = [
      row["forumName"], row["forum_name"], row["fname"],
      forumInfo?["forum_name"], forumInfo?["forumName"], forumInfo?["name"],
      forumInfoSnake?["forum_name"], forumInfoSnake?["forumName"], forumInfoSnake?["name"],
      forum?["forumName"], forum?["forum_name"], forum?["name"],
    ]
    for candidate in candidates {
      if let text = TiebaRowDict.nonEmpty(candidate) { return text }
    }
    return ""
  }

  /// 吧头像：行内已有值直通；缺失按 forumId 优先、退 `n:<吧名>` 读 KV 缓存。
  static func forumAvatar(_ row: [String: Any], forumName: String) -> String {
    let forumInfo = row["forumInfo"] as? [String: Any]
    let forumInfoSnake = row["forum_info"] as? [String: Any]
    let forum = row["forum"] as? [String: Any]
    let candidates: [Any?] = [
      row["forumAvatar"], row["forum_avatar"],
      forumInfo?["avatar"], forumInfoSnake?["avatar"], forum?["avatar"],
    ]
    for candidate in candidates {
      if let text = TiebaRowDict.nonEmpty(candidate) { return text }
    }
    let forumId = TiebaRowDict.string(row["forumId"] ?? row["forum_id"] ?? row["fid"]) ?? ""
    guard !forumId.isEmpty || !forumName.isEmpty,
          let key = TiebaForumAvatarCache.key(forumId: forumId, forumName: forumName)
    else { return "" }
    return TiebaForumAvatarCache.shared.cached(key: key)
  }
}
