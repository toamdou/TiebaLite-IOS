// 发现页数据访问：推荐（proto cmd=309264）/ 关注（309474）信息流、热榜（309661）、
// 不感兴趣上报，以及首页 SWR 快照（与 JS 共用的 KV 键，只读）。
// 行字典一律经 TiebaViewModelMapper（与帖子页/话题页同一份信息流映射）。
import Foundation
import UIKit

enum TiebaFeedAPI {
  struct FeedPage {
    var items: [[String: Any]] = []
    var hasMore = false
  }

  struct UserLikePage {
    var items: [[String: Any]] = []
    var pageTag = ""
    var hasMore = false
  }

  struct Hot {
    struct Topic {
      var id = ""
      var name = ""
    }

    struct Tab {
      var code = ""
      var name = ""
    }

    struct Thread {
      var row: [String: Any] = [:]
      var hotNum = 0.0
      var agreeNum = 0.0
    }

    var topics: [Topic] = []
    var tabs: [Tab] = []
    var threads: [Thread] = []
    var hasMoreTopics = false
  }

  /// 推荐页容量（与 JS PERSONALIZED_PAGE_SIZE 同值：无 page 字段，翻页按条目数判）。
  static let personalizedPageSize = 11
  /// 旧 JS 写过的键：只用于写入时顺手清理。
  private static let snapshotKey = "@tiebalite:feed_snapshot_v1"

  /// 关注流增量时间戳（对齐 JS feed.ts 的模块级 lastSuccessRequestUnix）。
  /// **按天作用域**：进程挂夜后第二天第一次刷新仍带着昨天的游标，会让服务端只回
  /// "昨天之后"的增量；跨天就当没有游标、从头拉一次（与签到态同一条纪律）。
  nonisolated(unsafe) private static var lastUserLikeUnix = 0
  nonisolated(unsafe) private static var lastUserLikeDay = ""

  private static let cursorDayFormatter: DateFormatter = TiebaDateFormats.fixed("yyyy-MM-dd", timeZone: TimeZone(identifier: "Asia/Shanghai") ?? .current)

  private static func cursorDay() -> String { cursorDayFormatter.string(from: Date()) }

  /// 当前应当使用的游标：跨天 → 0（重新拉，不走增量）。
  private static func currentUserLikeUnix() -> Int {
    let today = cursorDay()
    guard lastUserLikeDay == today else {
      lastUserLikeUnix = 0
      lastUserLikeDay = today
      return 0
    }
    return lastUserLikeUnix
  }

  // MARK: - 推荐 / 关注

  static func personalized(loadType: Int, page: Int) async throws -> FeedPage {
    let data = try await TiebaForumAPI.protoPost(path: "/c/f/excellent/personalized", cmd: "309264") { common in
      var body = Tieba_PersonalizedRequestData()
      body.common = common
      body.loadType = UInt32(clamping: loadType)
      body.pn = UInt32(clamping: page)
      body.pageThreadCount = UInt32(personalizedPageSize)
      body.qType = 1
      body.newNetType = 1
      body.scrDip = 3
      body.scrH = 2532
      body.scrW = 1170
      body.appPos.apMac = "02:00:00:00:00:00"
      body.appPos.apConnected = true
      body.appPos.coordinateType = "BD09LL"
      var request = Tieba_PersonalizedRequest()
      request.data = body
      return request
    }
    let decoded = try TiebaSwiftProto.decode(
      messagePath: "tieba.personalized.PersonalizedResponse",
      bytes: data
    )
    try TiebaViewModelMapper.assertProtoSuccess(decoded)
    let items = TiebaViewModelMapper.mapResponse(
      mapper: "feedThreadList",
      decoded: decoded,
      options: [:]
    ) as? [[String: Any]] ?? []
    return FeedPage(items: items, hasMore: items.count >= personalizedPageSize)
  }

  static func userLike(pageTag: String, loadType: Int) async throws -> UserLikePage {
    let unix = currentUserLikeUnix()
    let data = try await TiebaForumAPI.protoPost(path: "/c/f/concern/userlike", cmd: "309474") { common in
      var body = Tieba_UserLike_UserLikeRequestData()
      body.common = common
      body.pageTag = pageTag
      body.lastRequestUnix = UInt64(max(unix, 0))
      body.followType = 1
      body.loadType = Int32(clamping: loadType)
      var request = Tieba_UserLike_UserLikeRequest()
      request.data = body
      return request
    }
    let decoded = try TiebaSwiftProto.decode(
      messagePath: "tieba.userLike.UserLikeResponse",
      bytes: data
    )
    try TiebaViewModelMapper.assertProtoSuccess(decoded)
    let mapped = TiebaViewModelMapper.mapResponse(
      mapper: "userLike",
      decoded: decoded,
      options: [:]
    ) as? [String: Any] ?? [:]
    if let next = TiebaSimpleRowParser.double(mapped["requestUnix"]), next > 0 {
      lastUserLikeUnix = Int(next)
      lastUserLikeDay = cursorDay()
    }
    return UserLikePage(
      items: mapped["items"] as? [[String: Any]] ?? [],
      pageTag: mapped["pageTag"] as? String ?? "",
      hasMore: mapped["hasMore"] as? Bool ?? false
    )
  }

  // MARK: - 热榜

  static func hotThreadList(tabCode: String) async throws -> Hot {
    let data = try await TiebaForumAPI.protoPost(path: "/c/f/forum/hotThreadList", cmd: "309661") { common in
      var body = Tieba_HotThreadList_HotThreadListRequestData()
      body.common = common
      body.tabID = "1"
      body.tabCode = tabCode
      var request = Tieba_HotThreadList_HotThreadListRequest()
      request.data = body
      return request
    }
    let decoded = try TiebaSwiftProto.decode(
      messagePath: "tieba.hotThreadList.HotThreadListResponse",
      bytes: data
    )
    try TiebaViewModelMapper.assertProtoSuccess(decoded)
    guard let root = decoded["data"] as? [String: Any] else { return Hot() }

    var hot = Hot()
    for raw in (root["topicList"] as? [Any]) ?? [] {
      guard let item = raw as? [String: Any] else { continue }
      var topic = Hot.Topic()
      topic.id = TiebaSimpleRowParser.string(item["topicId"] ?? item["topic_id"]) ?? ""
      topic.name = TiebaSimpleRowParser.string(item["topicName"] ?? item["topic_name"]) ?? ""
      if !topic.id.isEmpty, !topic.name.isEmpty { hot.topics.append(topic) }
    }
    for raw in (root["hotThreadTabInfo"] as? [Any]) ?? [] {
      guard let item = raw as? [String: Any] else { continue }
      var tab = Hot.Tab()
      tab.code = TiebaSimpleRowParser.string(item["tabCode"] ?? item["tab_code"]) ?? ""
      tab.name = TiebaSimpleRowParser.string(item["tabName"] ?? item["tab_name"]) ?? ""
      if !tab.code.isEmpty, !tab.name.isEmpty { hot.tabs.append(tab) }
    }
    for raw in (root["threadInfo"] as? [Any]) ?? [] {
      guard let item = raw as? [String: Any] else { continue }
      var row = TiebaViewModelMapper.mapProtoThread(item)
      guard !row.isEmpty else { continue }
      // 吧名/吧头像兜底（同 TiebaFeedRowBuilder.make：热榜行同样缺 avatar）。
      let forum = TiebaFeedRowFallback.resolve(row)
      if !forum.name.isEmpty { row["forumName"] = forum.name }
      if !forum.avatar.isEmpty { row["forumAvatar"] = forum.avatar }
      var thread = Hot.Thread(row: row)
      thread.hotNum = TiebaSimpleRowParser.double(item["hotNum"] ?? item["hot_num"]) ?? 0
      let agree = item["agree"] as? [String: Any]
      thread.agreeNum = TiebaSimpleRowParser.double(
        item["agreeNum"] ?? item["agree_num"] ?? agree?["agreeNum"] ?? agree?["agree_num"]
      ) ?? 0
      hot.threads.append(thread)
    }
    // 话题只展示前 8 个（与旧页 slice(0, 8) 同）。
    hot.hasMoreTopics = hot.topics.count > 8
    return hot
  }

  // MARK: - 不感兴趣

  static func submitDislike(threadId: String, dislikeIds: String, forumId: String) async throws {
    let payload: [String: Any] = [
      "tid": threadId,
      "dislike_ids": dislikeIds,
      "fid": forumId,
      "click_time": Int(Date().timeIntervalSince1970 * 1000),
      "extra": "",
    ]
    guard let jsonData = try? JSONSerialization.data(withJSONObject: [payload]),
      let json = String(data: jsonData, encoding: .utf8)
    else { return }
    _ = try await TiebaSocialAPI.signedPost(
      path: "/c/c/excellent/submitDislike",
      fields: ["dislike": json, "dislike_from": "homepage"]
    )
  }

  // MARK: - 首屏 SWR 快照（写读同源）
  //
  // 旧键 @tiebalite:feed_snapshot_v1 是 JS 写的，JS 删除后**只读不写**变成死缓存：
  // 冷启动会先闪一份几个月前的列表。现在写入侧接回来了（页面 page=1 成功后写），
  // 并且带时间戳——过期就不采用，宁可走骨架也不给用户看陈年内容。

  /// 快照可采用的时效：30 分钟。超过就当作没有（列表页首屏用骨架，网络回来即替换）。
  private static let snapshotMaxAge: TimeInterval = 30 * 60
  /// 快照条数上限（与旧 JS 一致）：序列化体积 ~40KB，避免 KV 常驻膨胀。
  private static let snapshotMaxItems = 25

  private static func snapshotKey(segment: String, uid: String) -> String {
    "@tiebalite:feed_snapshot_v2_\(segment)_\(uid.isEmpty ? "anon" : uid)"
  }

  /// 读快照（按分段 + 账号）：过期 / 跨天 / 脏行一律丢弃。
  static func cachedSnapshot(segment: String) -> [[String: Any]] {
    let key = snapshotKey(segment: segment, uid: TiebaBackgroundSnapshot.shared.uid)
    guard let raw = TiebaKvStore.shared.get(key: key),
      let data = raw.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let list = object["items"] as? [[String: Any]]
    else { return [] }
    let ts = TiebaJSON.doubleValue(object["ts"]) ?? 0
    // 快照存活时长改用单调时钟：这个 ts 会跨进程/跨重启存进 KV，而墙上时钟会被
    // 对时或手动改时间拨动——往回拨一次，过期快照就能"续命"很久；往回拨之后写的
    // 新快照又会被判成过期。TiebaMonotonicTime 以本次开机时刻为锚，重启后仍连续，
    // 正是给这种"持久化下来的间隔"用的（同机同钟，历史值由 Date 写成也照常可比）。
    guard ts > 0, TiebaMonotonicTime.now * 1000 - ts <= snapshotMaxAge * 1000 else { return [] }
    return list.filter { ($0["threadInfo"] as? [String: Any])?["id"] is String }
  }

  /// 写快照（页面 page=1 成功后调用；失败静默——快照是加速手段，不影响主流程）。
  /// 序列化（~1ms 级）留在调用线程，KV 写事务（含 fsync）挪后台：首屏成功路径
  /// 不被一条写事务拖住。旧死键的清理 DELETE 随写同批进后台（此后每次都命中
  /// 0 行，只花后台线程）。
  static func saveSnapshot(_ items: [[String: Any]], segment: String) {
    guard !items.isEmpty else { return }
    let payload: [String: Any] = [
      // 与 cachedSnapshot 的读数同源（TiebaMonotonicTime），见那里的注释。
      "ts": Int(TiebaMonotonicTime.now * 1000),
      "items": Array(items.prefix(snapshotMaxItems)),
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: payload),
      let text = String(data: data, encoding: .utf8)
    else { return }
    let key = snapshotKey(segment: segment, uid: TiebaBackgroundSnapshot.shared.uid)
    let legacyKey = snapshotKey
    Task.detached(priority: .utility) {
      try? TiebaKvStore.shared.set(key: key, value: text)
      try? TiebaKvStore.shared.remove(key: legacyKey)
    }
  }
}

/// 信息流行字典：ThreadInfo 映射输出 + 行级偏好（键名与 TiebaRowMetrics 的解析键对应）。
enum TiebaFeedRowBuilder {
  struct Options {
    var hideMedia = false
    var showIpLocation = true
    var showBothUsername = false
    var fontScale = 1.0
    var timestampStyle = "relative"
    var closeMenuOptions: [String] = ["block", "copy-title"]
    var imageContextMenu = false
    /// 卡片长按菜单（分享帖子/复制帖子内容/不感兴趣/屏蔽作者）开关。
    /// 缺省关：四个动作都由页面执行，只有接线了的页面才该打开（见 TiebaFeedRowModel）。
    var cardContextMenu = false

    /// 每次出现现读偏好：过渡期原生只读共享偏好，不做订阅（见 TiebaPreferenceSnapshot）。
    static func current() -> Options {
      Options(
        hideMedia: TiebaPreferenceSnapshot.bool("hideMedia", default: false),
        showIpLocation: TiebaPreferenceSnapshot.bool("showIpLocation", default: true),
        showBothUsername: TiebaPreferenceSnapshot.bool("showBothUsername", default: false),
        // 正文级字号（两级体系；旧 fontScale 键由 TiebaTypography 迁移）
        fontScale: TiebaTypography.snapshot().bodyScale,
        timestampStyle: TiebaPreferenceSnapshot.string("timestampStyle") ?? "relative"
      )
    }
  }

  static func make(thread: [String: Any], options: Options, expanded: Bool = false) -> [String: Any] {
    var row = thread
    // 吧名/吧头像回填（原 search.ts 的 forum_name ?? forumInfo.forum_name 与
    // feed.ts:97-118 backfillForumAvatars 的统一落点；服务端 forumInfo 恒空，
    // 缺名会让度量把整块吧徽章判为不渲染）。
    let forum = TiebaFeedRowFallback.resolve(thread)
    if !forum.name.isEmpty { row["forumName"] = forum.name }
    if !forum.avatar.isEmpty { row["forumAvatar"] = forum.avatar }
    row["kind"] = TiebaKindRowKind.feed.rawValue
    row["timeType"] = "create"
    row["expanded"] = expanded
    row["hideMedia"] = options.hideMedia
    row["showIpLocation"] = options.showIpLocation
    row["showBothUsername"] = options.showBothUsername
    row["fontScale"] = options.fontScale
    row["timestampStyle"] = options.timestampStyle
    row["closeMenuOptions"] = options.closeMenuOptions
    row["imageContextMenu"] = options.imageContextMenu
    row["cardContextMenu"] = options.cardContextMenu
    row["showForumPill"] = true
    return row
  }
}


/// 通用行字典的主题色（行字典的 colors 子字典只认 hex/rgba 串；映射与吧务页同）。
@MainActor
enum TiebaRowTheme {
  static func colors() -> [String: String] {
    let palette = TiebaSimpleRowPalette.default
    let dark = TiebaNavigator.shared.chromeTheme.dark
    let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)

    func hex(_ color: UIColor) -> String {
      let resolved = color.resolvedColor(with: traits)
      var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
      resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
      if a >= 0.999 {
        return String(
          format: "#%02X%02X%02X",
          Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded())
        )
      }
      return String(
        format: "rgba(%d,%d,%d,%.2f)",
        Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()), a
      )
    }

    let tint = TiebaNavigator.shared.chromeTheme.tint
    return [
      "primary": hex(tint),
      "primarySoft": hex(tint.withAlphaComponent(0.12)),
      "card": hex(palette.base.card),
      "groupFill": hex(palette.groupFill),
      "surfaceSecondary": hex(palette.surfaceSecondary),
      "textTertiary": hex(palette.base.textTertiary),
      "textDisabled": hex(palette.textDisabled),
      "divider": hex(palette.divider),
      "chevronColor": hex(palette.textDisabled),
      "borderColor": hex(palette.divider),
    ]
  }
}

/// 信息流过滤（对齐 JS FeedContent.visibleItems：广告/直播开关 + 屏蔽词/屏蔽用户）。
enum TiebaFeedFilter {
  static func visible(_ items: [[String: Any]], filterAds: Bool) -> [[String: Any]] {
    // 一页一次：屏蔽词在这里预编译（此前逐行逐词现编 NSRegularExpression，
    // O(行×词) 次编译；正则只编一次）。
    // [算法审查 40 §4.E] 判据收敛：本页原来自己实现了一份「白名单放行 / 黑名单屏蔽 + 屏蔽用户」，
    // 现在直接用 TiebaPostBlockFilter（帖子行测量那条最热路径的同一张表）—— 同一规则一份实现。
    let filter = TiebaPostBlockFilter.load()
    return items.filter { item in
      guard let thread = item["threadInfo"] as? [String: Any] else { return true }
      if filterAds, TiebaViewModelMapper.isAdThreadInfo(thread) { return false }
      if !filter.isEmpty {
        let text = "\(thread["title"] as? String ?? "") \(thread["abstract"] as? String ?? "")"
        if filter.isContentBlocked(text) { return false }
      }
      if !filter.users.isEmpty {
        let name = thread["authorName"] as? String ?? ""
        if filter.isUserBlocked(uid: thread["authorId"] as? String ?? "", name: name) {
          return false
        }
      }
      return true
    }
  }
}
