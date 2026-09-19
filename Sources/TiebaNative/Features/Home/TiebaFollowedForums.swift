// 已关注吧列表（原 src/services/forumFollowed.ts）：forumGuide web 表单分页
// （有界并发 4）、内存 5min / 磁盘 24h 双层缓存、关注/取关后失效。原生页与
// 后台快照共用同一份列表；缓存键与形状与 JS 一致（过渡期两边可互读）。
import Foundation
import os

struct TiebaForumInfo {
  var forumId = ""
  var forumName = ""
  var avatar = ""
  var memberCount = 0
  var levelId = 0
  var levelName = ""
  var isSign = false

  var displayName: String { forumName.isEmpty ? forumId : forumName }
}

enum TiebaFollowedForums {
  private static let pageSize = 50
  private static let maxPages = 20
  private static let maxTotal = 1000
  private static let concurrency = 4
  private static let pageTimeout: Double = 10
  private static let memoryTTL: TimeInterval = 300
  private static let diskTTL: TimeInterval = 24 * 60 * 60
  private static let diskKey = "followed_forums_cache_v1"
  private static let logger = Logger(subsystem: "com.tiebalite.app", category: "followed-forums")

  private static func log(_ message: String) {
    logger.error("\(message, privacy: .public)")
  }

  private struct CacheEntry {
    var expiresAt: Date
    var forums: [TiebaForumInfo]
    /// 这份数据属于哪个"签到自然日"（见 dayKey）：跨天只作废 isSign 这一位。
    var day: String
  }

  private static let lock = NSLock()
  nonisolated(unsafe) private static var memory: CacheEntry?
  nonisolated(unsafe) private static var inflight: Task<[TiebaForumInfo], Error>?
  /// 本会话内已签到的吧：服务端列表 is_sign 滞后时不让勾号回退（JS 同款合并）。
  /// **按天作用域**：进程跨天活着（后台挂一夜）时，昨天的集合会让今天的服务端列表
  /// 全被标成已签到 —— 一键签到于是回"今天所有关注的吧都已签到过了"（用户 2026-09-15 报）。
  nonisolated(unsafe) private static var sessionSigned: Set<String> = []
  nonisolated(unsafe) private static var sessionSignedDay = ""

  /// 签到状态的自然日（北京时间：服务端按它换日）。列表可以缓存 24h，但**勾号不能
  /// 跨天**——跨天读取时把 isSign 全部清零，靠服务端/重新签到再亮起来。
  static func today() -> String { dayKey() }

  private static let dayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }()

  private static func dayKey(_ date: Date = Date()) -> String {
    dayFormatter.string(from: date)
  }

  /// 跨天读缓存：列表照用，签到位清零。
  private static func withoutSigns(_ forums: [TiebaForumInfo]) -> [TiebaForumInfo] {
    forums.map { forum in
      guard forum.isSign else { return forum }
      var item = forum
      item.isSign = false
      return item
    }
  }

  /// 有界并发拉全量（同一时间只有一个在途请求）；失败向上抛给页面重试入口。
  /// force = 用户主动刷新/签到后：跳过两层缓存直连服务端。
  static func fetchAll(force: Bool = false) async throws -> [TiebaForumInfo] {
    let today = dayKey()
    if !force, let entry = lock.withLock({ memory }), entry.expiresAt > Date() {
      guard entry.day == today else {
        // 跨天：列表还能用，签到位作废（并就地修正缓存，别每次读都重算）。
        let cleared = withoutSigns(entry.forums)
        lock.withLock { memory = CacheEntry(expiresAt: entry.expiresAt, forums: cleared, day: today) }
        return cleared
      }
      return entry.forums
    }
    // 冷启动秒显：内存 miss 时用 24h 磁盘缓存先出列表（内存 TTL 仍是 5min，
    // 过期后下一次聚焦自然走网络）。
    if !force, let disk = readDiskCache(), disk.expiresAt > Date(), !disk.forums.isEmpty {
      let crossedDay = disk.day != today
      let forums = crossedDay ? withoutSigns(disk.forums) : disk.forums
      lock.withLock {
        memory = CacheEntry(expiresAt: Date().addingTimeInterval(memoryTTL), forums: forums, day: today)
      }
      if crossedDay { writeDiskCache(forums, expiresAt: disk.expiresAt) }
      return forums
    }
    if let existing = lock.withLock({ inflight }) {
      return try await existing.value
    }
    let task = Task { try await fetchAllPages() }
    let raced = lock.withLock { () -> Task<[TiebaForumInfo], Error>? in
      if let existing = inflight { return existing }
      inflight = task
      return nil
    }
    if let raced { return try await raced.value }

    defer { lock.withLock { inflight = nil } }
    let forums = try await task.value
    let merged = mergeSigned(forums)
    lock.withLock {
      memory = CacheEntry(expiresAt: Date().addingTimeInterval(memoryTTL), forums: merged, day: dayKey())
    }
    writeDiskCache(merged)
    // 后台自动签到按 uid 的 forumIds 工作，列表刷新即同步（原 setBackgroundForums）。
    // ⚠️ 必须 persist：后台任务可能由冷进程启动，只改内存 = 拿到旧列表。
    TiebaBackgroundSnapshot.shared.forumIds = merged.map(\.forumId)
    TiebaBackgroundSnapshot.shared.forumNames = merged.map(\.forumName)
    TiebaBackgroundSnapshot.shared.persist()
    return merged
  }

  static func invalidate() {
    lock.withLock { memory = nil }
    do {
      try TiebaKvStore.shared.remove(key: diskKey)
    } catch {
      log("followed forums cache invalidate failed: \(error.localizedDescription)")
    }
  }

  static func markSigned(_ forumIds: [String]) {
    let today = dayKey()
    lock.withLock {
      if sessionSignedDay != today {
        sessionSigned.removeAll()
        sessionSignedDay = today
      }
      for id in forumIds where !id.isEmpty { sessionSigned.insert(id) }
      guard var entry = memory else { return }
      // 内存里可能是昨天的列表：先把旧勾号清掉再打今天这批。
      if entry.day != today {
        entry.forums = withoutSigns(entry.forums)
        entry.day = today
      }
      let signed = sessionSigned
      entry.forums = entry.forums.map {
        guard signed.contains($0.forumId) else { return $0 }
        var item = $0
        item.isSign = true
        return item
      }
      entry.expiresAt = Date().addingTimeInterval(memoryTTL)
      memory = entry
      // 磁盘缓存也跟上：否则同日冷启动后勾号要等网络回来才亮。
      writeDiskCache(entry.forums, expiresAt: entry.expiresAt)
    }
  }

  /// 当前内存列表（签到完成后就地刷新用）：没有内存条目 → nil（调用方回落到重拉）。
  /// 存在的意义是**别为了几个勾号把整份列表重拉一遍**（原来 onFinished 会
  /// invalidate + force，一次签到最多打出 20 个 forumGuide 请求）。
  static func currentSnapshot() -> [TiebaForumInfo]? {
    lock.withLock { memory.map(\.forums) }
  }

  /// 取关（原 unfavolike）：写接口，需 tbs。
  static func unfollow(forumId: String, forumName: String) async throws {
    // 缺失会向 /c/s/login 续期（对齐原 JS requireTbs；原实现只抛错 ⇒ 冷启动后取关必失败）
    let tbs = try await TiebaSession.requireTbs()
    let response = try await TiebaNativeClient.shared.postForm(
      urlString: "https://c.tieba.baidu.com/c/c/forum/unfavolike",
      fields: ["fid": forumId, "kw": forumName, "tbs": tbs],
      includeCommon: true,
      includeSign: true,
      requestId: "native-unfavolike-\(UUID().uuidString)",
      timeout: 15
    )
    if let code = TiebaJSON.int(response, "error_code", "errno"), code != 0 {
      throw TiebaForumAPIError.api(
        code: Int32(clamping: code),
        message: (response["error_msg"] as? String) ?? "取消关注失败"
      )
    }
    let remaining = lock.withLock { () -> [TiebaForumInfo]? in
      guard let current = memory else { return nil }
      let filtered = current.forums.filter { $0.forumId != forumId }
      memory = CacheEntry(expiresAt: current.expiresAt, forums: filtered, day: current.day)
      return filtered
    }
    if let remaining { writeDiskCache(remaining) }
  }

  // MARK: - 网络

  private static func fetchAllPages() async throws -> [TiebaForumInfo] {
    var pageMap: [Int: [TiebaForumInfo]] = [:]
    var seen = Set<String>()
    var total = 0
    var pageNo = 1
    while pageNo <= maxPages {
      let batch = Array(pageNo..<min(pageNo + concurrency, maxPages + 1))
      let results = try await withThrowingTaskGroup(of: (Int, [TiebaForumInfo]).self) { group in
        for page in batch {
          group.addTask { (page, try await fetchPage(page)) }
        }
        var collected: [(Int, [TiebaForumInfo])] = []
        for try await item in group { collected.append(item) }
        return collected
      }
      var batchHasMore = false
      for (page, forums) in results {
        var kept: [TiebaForumInfo] = []
        for item in forums {
          guard !item.forumId.isEmpty, !seen.contains(item.forumId) else { continue }
          seen.insert(item.forumId)
          kept.append(item)
          total += 1
          if total >= maxTotal { break }
        }
        pageMap[page] = kept
        if forums.count >= pageSize { batchHasMore = true }
      }
      if !batchHasMore || total >= maxTotal { break }
      pageNo += concurrency
    }
    var all: [TiebaForumInfo] = []
    for page in 1...maxPages {
      if let forums = pageMap[page] { all.append(contentsOf: forums) }
    }
    return all
  }

  private static func fetchPage(_ pageNo: Int) async throws -> [TiebaForumInfo] {
    var components = URLComponents()
    components.scheme = "https"
    components.host = "tieba.baidu.com"
    components.path = "/c/f/forum/forumGuide"
    let fields: [String: String] = [
      "sort_type": "3",
      "call_from": "3",
      "page_no": String(pageNo),
      "res_num": String(pageSize),
      "tbs": TiebaBackgroundSnapshot.shared.tbs,
    ]
    let body = TiebaRoutePath.formBody(fields)
    guard let url = components.url else { throw TiebaForumAPIError.invalidURL }
    let snapshot = TiebaBackgroundSnapshot.shared
    var cookies: [String] = []
    if !snapshot.bduss.isEmpty { cookies.append("BDUSS=\(snapshot.bduss)") }
    if !snapshot.stoken.isEmpty { cookies.append("STOKEN=\(snapshot.stoken)") }
    let response = try await TiebaHttpClient.shared.send(
      urlString: url.absoluteString,
      method: "POST",
      headers: [
        "User-Agent": "tieba/12.41.7.1",
        "Accept-Language": "zh-CN,zh;q=0.9",
        "Accept": "application/json",
        "Charset": "UTF-8",
        "Content-Type": "application/x-www-form-urlencoded",
        "Subapp-Type": "hybrid",
        "Cookie": cookies.joined(separator: "; "),
      ],
      body: body,
      formParts: [],
      requestId: "native-forum-guide-\(UUID().uuidString)",
      timeoutMs: pageTimeout * 1000
    )
    guard (200..<300).contains(response.status) else { throw TiebaForumAPIError.http(response.status) }
    guard let data = response.body.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { throw TiebaForumAPIError.invalidResponse }
    if let code = TiebaJSON.int(object, "error_code", "errno"), code != 0 {
      throw TiebaForumAPIError.api(
        code: Int32(clamping: code),
        message: (object["error_msg"] as? String) ?? "加载关注的贴吧失败"
      )
    }
    let container = (object["data"] as? [String: Any]) ?? object
    let list = (container["like_forum"] as? [[String: Any]])
      ?? (container["likeForum"] as? [[String: Any]])
      ?? []
    return list.compactMap(mapForumInfo)
  }

  /// mapForumInfo（helpers.ts）：snake_case / camelCase 双读；实现统一在 TiebaJSON。
  private static func mapForumInfo(_ item: [String: Any]) -> TiebaForumInfo? {
    var forum = TiebaForumInfo()
    forum.forumId = TiebaJSON.string(item, "forum_id", "forumId", "fid") ?? ""
    forum.forumName = TiebaJSON.string(item, "forum_name", "forumName") ?? ""
    forum.avatar = TiebaJSON.string(item, "avatar") ?? ""
    forum.memberCount = TiebaJSON.int(item, "member_count", "memberCount") ?? 0
    forum.levelId = TiebaJSON.int(item, "level_id", "levelId") ?? 0
    forum.levelName = TiebaJSON.string(item, "level_name", "levelName") ?? ""
    forum.isSign = TiebaJSON.bool(item, "is_sign", "isSign") ?? false
    return forum.forumId.isEmpty ? nil : forum
  }

  private static func mergeSigned(_ forums: [TiebaForumInfo]) -> [TiebaForumInfo] {
    let today = dayKey()
    lock.lock()
    if sessionSignedDay != today {
      sessionSigned.removeAll()
      sessionSignedDay = today
    }
    let signed = sessionSigned
    lock.unlock()
    guard !signed.isEmpty else { return forums }
    return forums.map {
      guard signed.contains($0.forumId) else { return $0 }
      var item = $0
      item.isSign = true
      return item
    }
  }

  // MARK: - 磁盘缓存（与 JS 同一键、同一形状）

  private static func readDiskCache() -> (expiresAt: Date, forums: [TiebaForumInfo], day: String)? {
    guard let raw = TiebaKvStore.shared.get(key: diskKey),
      let data = raw.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let list = object["forums"] as? [[String: Any]]
    else { return nil }
    let expiresAt = Date(timeIntervalSince1970: (TiebaJSON.doubleValue(object["expiresAt"]) ?? 0) / 1000)
    // 旧格式（无 day）一律按"跨天"处理：宁可少一个勾号，也不让昨天的签到态活到今天。
    let day = (object["day"] as? String) ?? ""
    return (expiresAt, list.compactMap(mapForumInfo), day)
  }

  private static func writeDiskCache(_ forums: [TiebaForumInfo], expiresAt: Date? = nil) {
    let payload: [String: Any] = [
      "expiresAt": Int(
        (expiresAt ?? Date().addingTimeInterval(diskTTL)).timeIntervalSince1970 * 1000
      ),
      "day": dayKey(),
      "forums": forums.map { forum -> [String: Any] in
        [
          "forumId": forum.forumId,
          "forumName": forum.forumName,
          "name": forum.forumName,
          "avatar": forum.avatar,
          "memberCount": forum.memberCount,
          "levelId": forum.levelId,
          "levelName": forum.levelName,
          "isLike": true,
          "isSign": forum.isSign,
        ]
      },
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: payload),
      let text = String(data: data, encoding: .utf8)
    else { return }
    do {
      try TiebaKvStore.shared.set(key: diskKey, value: text)
    } catch {
      // 磁盘缓存写失败不致命（下次刷新重写），但不能无声：留日志。
      TiebaFollowedForums.log("followed forums disk cache write failed: \(error.localizedDescription)")
    }
  }
}
