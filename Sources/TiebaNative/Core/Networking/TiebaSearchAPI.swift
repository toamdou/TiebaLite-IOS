// 搜索数据访问（原 src/services/api/endpoints/search.ts + 搜索专用 web 通道）：
// 三个 /mo/q/search/* 端点（贴/吧/人）与吧内搜索（混合接口 + fname 限定）。
// 行字典直接产出列表行（kind=feed / kind=simple），搜索历史走统一 SQLite。
import Foundation

enum TiebaSearchAPI {
  struct ThreadHit {
    var id = ""
    var row: [String: Any] = [:]
  }

  struct ForumHit {
    var name = ""
    var row: [String: Any] = [:]
  }

  struct UserHit {
    var uid = ""
    var row: [String: Any] = [:]
  }

  struct PostHit {
    var threadId = ""
    var postId = ""
    var floor = 0
    var row: [String: Any] = [:]
  }

  // MARK: - 输入联想（原 Kotlin searchSuggestionsFlow / /c/s/searchSug cmd=309438）

  /// 搜索框输入联想：返回服务端建议词（最多 10 条）。匿名可读（2026-09-17 实测）。
  /// isforum=0 = 关键词联想；返回的 forum_loc/forumList 本页不用。
  static func suggest(word: String) async throws -> [String] {
    let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    let data = try await TiebaForumAPI.protoPost(
      path: "/c/s/searchSug", cmd: "309438&format=protobuf"
    ) { common in
      var body = Tieba_SearchSug_SearchSugRequestData()
      body.common = common
      body.word = trimmed
      body.isforum = "0"
      var request = Tieba_SearchSug_SearchSugRequest()
      request.data = body
      return request
    }
    let response = try Tieba_SearchSug_SearchSugResponse(serializedBytes: data)
    if response.hasError, response.error.errorCode != 0 {
      throw TiebaViewModelError(code: Double(response.error.errorCode), message: response.error.errorMsg)
    }
    guard response.hasData else { return [] }
    return response.data.list.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  }

  // MARK: - 贴 / 吧 / 人

  static func threads(
    keyword: String,
    page: Int,
    order: Int
  ) async throws -> (hits: [ThreadHit], hasMore: Bool) {
    let root = try await getJSON(
      path: "/mo/q/search/thread",
      query: [
        "word": keyword,
        "pn": String(page),
        "st": String(order),
        "tt": "1",
        "rn": "20",
        "ct": "1",
        "cv": "99.9.101",
      ],
      keyword: keyword
    )
    let data = (root["data"] as? [String: Any]) ?? root
    let list = (data["post_list"] as? [Any]) ?? (data["postList"] as? [Any]) ?? []
    let hits = list.compactMap { element -> ThreadHit? in
      guard let item = element as? [String: Any] else { return nil }
      let id = TiebaSimpleRowParser.string(item["tid"] ?? item["id"]) ?? ""
      guard !id.isEmpty else { return nil }
      var hit = ThreadHit()
      hit.id = id
      hit.row = threadRow(item)
      return hit.row.isEmpty ? nil : hit
    }
    let hasMore = (TiebaSimpleRowParser.double(data["has_more"] ?? data["hasMore"]) ?? 0) == 1
    return (hits, hasMore)
  }

  static func forums(keyword: String) async throws -> [ForumHit] {
    let root = try await getJSON(
      path: "/mo/q/search/forum",
      query: ["word": keyword],
      keyword: keyword
    )
    let data = (root["data"] as? [String: Any]) ?? root
    var items: [[String: Any]] = []
    if let exact = data["exact_match"] as? [String: Any] ?? data["exactMatch"] as? [String: Any] {
      items.append(exact)
    }
    items.append(contentsOf: array(data["fuzzy_match"] ?? data["fuzzyMatch"]) ?? [])
    if items.isEmpty { items = array(data) ?? [] }
    return items.compactMap { item in
      let name = TiebaSimpleRowParser.string(item["forum_name"] ?? item["forumName"]) ?? ""
      guard !name.isEmpty else { return nil }
      var hit = ForumHit()
      hit.name = name
      hit.row = forumRow(item)
      return hit
    }
  }

  static func users(keyword: String) async throws -> [UserHit] {
    let root = try await getJSON(
      path: "/mo/q/search/user",
      query: ["word": keyword],
      keyword: keyword
    )
    let data = (root["data"] as? [String: Any]) ?? root
    var items: [[String: Any]] = []
    if let exact = data["exact_match"] as? [String: Any] ?? data["exactMatch"] as? [String: Any] {
      items.append(exact)
    }
    items.append(
      contentsOf: array(data["fuzzy_match"] ?? data["fuzzyMatch"] ?? data["user_list"]) ?? []
    )
    if items.isEmpty { items = array(data) ?? [] }
    return items.compactMap { item in
      let uid = TiebaSimpleRowParser.string(item["id"] ?? item["user_id"] ?? item["userId"]) ?? ""
      guard !uid.isEmpty else { return nil }
      var hit = UserHit()
      hit.uid = uid
      hit.row = userRow(item)
      return hit
    }
  }

  // MARK: - 吧内搜索（st: 1 时间 / 2 相关性；tt: 1 仅主题贴 / 2 全部）

  static func posts(
    keyword: String,
    forumName: String,
    page: Int,
    sortType: Int,
    filterType: Int
  ) async throws -> (hits: [PostHit], hasMore: Bool) {
    let referer = "https://tieba.baidu.com/mo/q/hybrid-usergrow-search/searchGlobal"
      + "?entryPage=frs&forumName=\(escape(forumName))&_client_version=99.9.101&_client_type=2"
    let root = try await getJSON(
      path: "/mo/q/search/thread",
      query: [
        "word": keyword,
        "pn": String(page),
        "st": String(sortType),
        "tt": String(filterType),
        "rn": "30",
        "fname": forumName,
        "ct": "2",
        "cv": "99.9.101",
      ],
      keyword: keyword,
      referer: referer
    )
    let data = (root["data"] as? [String: Any]) ?? root
    let list = array(data["post_list"] ?? data["postList"] ?? data) ?? []
    let hits = list.compactMap { item -> PostHit? in
      let threadId = TiebaSimpleRowParser.string(item["tid"] ?? item["id"]) ?? ""
      guard !threadId.isEmpty else { return nil }
      let postInfo = item["post_info"] as? [String: Any] ?? item["postInfo"] as? [String: Any]
      var hit = PostHit()
      hit.threadId = threadId
      hit.postId = TiebaSimpleRowParser.string(item["pid"] ?? postInfo?["pid"]) ?? ""
      hit.floor = Int(TiebaSimpleRowParser.double(item["floor"] ?? postInfo?["floor"]) ?? 0)
      hit.row = postRow(item)
      return hit
    }
    let hasMore = (TiebaSimpleRowParser.double(data["has_more"] ?? data["hasMore"]) ?? 0) == 1
      || (data["has_more"] == nil && data["hasMore"] == nil && hits.count >= 30)
    return (hits, hasMore)
  }

  // MARK: - 行字典

  /// 贴结果 → 信息流行（原 SearchResultList.searchThreadToThreadInfo 的投影）。
  private static func threadRow(_ item: [String: Any]) -> [String: Any] {
    let user = item["user"] as? [String: Any] ?? [:]
    let mainPost = item["main_post"] as? [String: Any] ?? item["mainPost"] as? [String: Any] ?? [:]
    let media = array(item["media"]) ?? array(mainPost["media"]) ?? []
    let createSeconds = TiebaSimpleRowParser.double(item["modified_time"] ?? item["modifiedTime"] ?? item["time"]) ?? 0
    // 原 search.ts：forum_name ?? forumInfo.forum_name；头像 forum_info.avatar
    // ?? forumInfo.avatar（逐键兜底，不能整体取一个字典）。缺名会让左下角
    // 吧徽章整块不渲染（用户反馈）。
    let forumInfoSnake = item["forum_info"] as? [String: Any]
    let forumInfoCamel = item["forumInfo"] as? [String: Any]
    let forumName = TiebaSimpleRowParser.string(
      item["forum_name"] ?? item["forumName"]
        ?? forumInfoCamel?["forum_name"] ?? forumInfoSnake?["forum_name"]
        ?? forumInfoCamel?["name"] ?? forumInfoSnake?["name"]
    ) ?? ""
    var forumAvatar = TiebaSimpleRowParser.string(
      forumInfoSnake?["avatar"] ?? forumInfoCamel?["avatar"]
    ) ?? ""
    if forumAvatar.isEmpty, !forumName.isEmpty,
      let key = TiebaForumAvatarCache.key(forumId: "", forumName: forumName)
    {
      // 原 SearchResultList：服务端不带头像时按吧名读全站吧头像 KV 缓存
      //（forum_avatars_v1，只读；搜索帖 forumId 恒空 → n:<吧名> 键）。
      forumAvatar = TiebaForumAvatarCache.shared.cached(key: key)
    }
    var thread: [String: Any] = [
      "id": TiebaSimpleRowParser.string(item["tid"]) ?? "",
      "title": TiebaSimpleRowParser.string(item["title"]) ?? "",
      "forumName": forumName,
      "forumAvatar": forumAvatar,
      "authorName": TiebaSimpleRowParser.string(user["user_name"] ?? user["userName"]) ?? "",
      "authorNameShow": TiebaSimpleRowParser.string(user["show_nickname"] ?? user["showNickname"]) ?? "",
      "authorPortrait": TiebaSimpleRowParser.string(user["portrait"]) ?? "",
      "authorIP": TiebaSimpleRowParser.string(
        user["ip_location"] ?? user["ipLocation"] ?? user["ip_address"] ?? user["ipAddress"]
      ) ?? "",
      "replyNum": TiebaSimpleRowParser.double(item["post_num"] ?? item["postNum"]) ?? 0,
      "zanNum": TiebaSimpleRowParser.double(item["like_num"] ?? item["likeNum"]) ?? 0,
      "shareNum": TiebaSimpleRowParser.double(item["share_num"] ?? item["shareNum"]) ?? 0,
      "createTime": createSeconds > 0 ? createSeconds * 1000 : 0,
      "isVideo": media.contains { (($0["type"] as? String) ?? "pic") == "video" },
      "abstract": htmlToText(TiebaSimpleRowParser.string(item["content"]) ?? ""),
      "hasAgree": false,
    ]
    thread["mediaList"] = media.enumerated().map { index, raw -> [String: Any] in
      let big = TiebaSimpleRowParser.string(raw["big_pic"] ?? raw["bigPic"]) ?? ""
      let src = TiebaSimpleRowParser.string(raw["src"]) ?? ""
      let small = TiebaSimpleRowParser.string(raw["small_pic"] ?? raw["smallPic"]) ?? ""
      return [
        "type": ((raw["type"] as? String) ?? "pic") == "video" ? "video" : "image",
        "src": big.isEmpty ? (src.isEmpty ? small : src) : big,
        "originSrc": big.isEmpty ? (src.isEmpty ? small : src) : big,
        "smallSrc": small,
        "width": TiebaSimpleRowParser.double(raw["width"]) ?? 300,
        "height": TiebaSimpleRowParser.double(raw["height"]) ?? 300,
        "index": index,
      ]
    }
    var options = TiebaFeedRowBuilder.Options.current()
    options.imageContextMenu = true
    // 搜索结果也走「不感兴趣」三件套（面板 + 上报 + 折叠退场），与动态流同一套菜单项；
    // 原 JS 搜索卡没渲染 × 按钮，属用户新增要求。
    options.closeMenuOptions = ["dislike", "block", "copy-title"]
    return TiebaFeedRowBuilder.make(thread: thread, options: options)
  }

  /// 吧结果 → 通用行（原 SearchForumCard：padding 14 / 头像 44 / 标题
  /// calloutBold 16-21 / 副标题 footnote 13-18 / 卡内 gap 3，距屏水平 10）。
  /// user 变体默认（粉丝关注行）是 40 头像 + 14/11 字号，必须逐项覆盖。
  private static func forumRow(_ item: [String: Any]) -> [String: Any] {
    let members = TiebaSimpleRowParser.double(
      item["concern_num_ori"] ?? item["concernNumOri"] ?? item["concern_num"]
        ?? item["member_num"] ?? item["memberNum"]
    ) ?? 0
    let threads = TiebaSimpleRowParser.double(
      item["post_num_ori"] ?? item["postNumOri"] ?? item["post_num"]
        ?? item["thread_num"] ?? item["threadNum"]
    ) ?? 0
    let liked = (TiebaSimpleRowParser.double(item["has_concerned"] ?? item["hasConcerned"]) ?? 0) == 1
    let subtitle = "\(TiebaForumFormat.count(Int(members))) 关注 ·"
      + " \(TiebaForumFormat.count(Int(threads))) 贴子\(liked ? " · 已关注" : "")"
    let name = TiebaSimpleRowParser.string(item["forum_name"] ?? item["forumName"]) ?? ""
    return [
      "kind": "simple",
      "variant": "user",
      "avatar": TiebaSimpleRowParser.string(item["avatar"]) ?? "",
      "avatarInitial": String(name.prefix(1)),
      "avatarSize": 44,
      "title": name.isEmpty ? "" : "\(name)吧",
      "titleSize": 16,
      "titleWeight": 600,
      "titleLineHeight": 21,
      "subtitle": subtitle,
      "subtitleSize": 13,
      "subtitleLineHeight": 18,
      "chevron": true,
      "marginH": 10,
      "marginV": 6,
      "paddingH": 14,
      "paddingV": 14,
      "gap": 12,
      "radius": 20,
      "borderWidth": 0.5,
      "subtitleMarginTop": 3,
    ]
  }

  /// 人结果 → 通用行（原 SearchUserCard：同横排卡 / 头像 44 / 昵称
  /// calloutBold 16-21 / 简介 footnote 13-18（HTML 去标签）/ 粉丝 caption1，
  /// 卡内 gap 2；fansNum = 0 不显示粉丝行）。
  private static func userRow(_ item: [String: Any]) -> [String: Any] {
    let name = TiebaSimpleRowParser.string(item["name"] ?? item["user_name"] ?? item["userName"]) ?? ""
    let nameShow = TiebaSimpleRowParser.string(item["show_nickname"] ?? item["name_show"] ?? item["nameShow"]) ?? ""
    let fans = TiebaSimpleRowParser.double(
      item["fans_num_ori"] ?? item["fansNumOri"] ?? item["fans_num"]
    ) ?? 0
    let intro = htmlToText(TiebaSimpleRowParser.string(item["intro"]) ?? "")
    var parts: [String] = []
    if !intro.isEmpty { parts.append(intro) }
    if fans > 0 { parts.append("\(TiebaForumFormat.count(Int(fans))) 粉丝") }
    let displayName = nameShow.isEmpty ? name : nameShow
    return [
      "kind": "simple",
      "variant": "user",
      "avatar": TiebaSimpleRowParser.string(item["portrait"]) ?? "",
      "avatarInitial": String(displayName.prefix(1)),
      "avatarSize": 44,
      "title": displayName,
      "titleSize": 16,
      "titleWeight": 600,
      "titleLineHeight": 21,
      "subtitle": parts.joined(separator: " · "),
      "subtitleSize": 13,
      "subtitleLineHeight": 18,
      "chevron": true,
      "marginH": 10,
      "marginV": 6,
      "paddingH": 14,
      "paddingV": 14,
      "gap": 12,
      "radius": 20,
      "borderWidth": 0.5,
      "subtitleMarginTop": 2,
    ]
  }

  /// 吧内搜索的单条回复 → 消息行（头像 + 昵称 + 正文 + 原贴标题 + 时间）。
  private static func postRow(_ item: [String: Any]) -> [String: Any] {
    let user = item["user"] as? [String: Any] ?? [:]
    let seconds = TiebaSimpleRowParser.double(item["modified_time"] ?? item["time"]) ?? 0
    let name = TiebaSimpleRowParser.string(user["user_name"] ?? user["userName"]) ?? ""
    let nameShow = TiebaSimpleRowParser.string(user["show_nickname"] ?? user["showNickname"]) ?? ""
    return [
      "kind": "simple",
      "variant": "message",
      "avatar": TiebaSimpleRowParser.string(user["portrait"]) ?? "",
      "avatarInitial": String((nameShow.isEmpty ? name : nameShow).prefix(1)),
      "name": nameShow.isEmpty ? name : nameShow,
      "content": htmlToText(TiebaSimpleRowParser.string(item["content"]) ?? ""),
      "threadTitle": TiebaSimpleRowParser.string(item["title"]) ?? "",
      "time": seconds > 0 ? relativeTime(seconds: seconds) : "",
      "replyNum": TiebaSimpleRowParser.double(item["post_num"] ?? item["postNum"]) ?? 0,
      "marginH": 10,
      "marginV": 6,
      "paddingH": 16,
      "paddingV": 16,
      "radius": 12,
      "borderWidth": 0.5,
    ]
  }

  // MARK: - 传输

  private static let baiduIdKey = "@tiebalite:baiduid"

  private static func getJSON(
    path: String,
    query: [String: String],
    keyword: String,
    referer: String? = nil
  ) async throws -> [String: Any] {
    var components = URLComponents()
    components.scheme = "https"
    components.host = "tieba.baidu.com"
    components.path = path
    components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
    guard let url = components.url else { throw TiebaForumAPIError.invalidURL }

    let snapshot = TiebaBackgroundSnapshot.shared
    let cuid = TiebaForumAPI.cuidValue()
    var cookies = [
      "CUID=\(cuid)",
      "TBBRAND=SM-G9910",
      "cuid_galaxy2=\(cuid)",
      "SP_FW_VER=3.340.42",
      "SG_FW_VER=1.38.0",
    ]
    if !snapshot.bduss.isEmpty { cookies.append("BDUSS=\(snapshot.bduss)") }
    if !snapshot.stoken.isEmpty { cookies.append("STOKEN=\(snapshot.stoken)") }
    cookies.append("BAIDU_WISE_UID=\(snapshot.uid.isEmpty ? cuid : snapshot.uid)")
    cookies.append("USER_JUMP=-1")
    if !snapshot.bduss.isEmpty { cookies.append("BDUSS_BFESS=\(snapshot.bduss)") }
    if let baiduId = TiebaKvStore.shared.get(key: baiduIdKey), !baiduId.isEmpty {
      cookies.append("BAIDUID=\(baiduId)")
      cookies.append("BAIDUID_BFESS=\(baiduId)")
    }
    cookies.append("mo_originid=2")
    if !snapshot.zid.isEmpty { cookies.append("BAIDUZID=\(snapshot.zid)") }

    let refererValue = referer
      ?? "https://tieba.baidu.com/mo/q/hybrid/search?keyword=\(escape(keyword))"
        + "&_webview_time=\(Int(Date().timeIntervalSince1970 * 1000))"
    let response = try await TiebaHttpClient.shared.send(
      urlString: url.absoluteString,
      method: "GET",
      headers: [
        "User-Agent": "tieba/12.35.1.0 skin/default",
        "Pragma": "no-cache",
        "Cache-Control": "no-cache",
        "Accept": "application/json, text/plain, */*",
        "Accept-Language": "zh-CN,zh;q=0.9",
        "X-Requested-With": "com.baidu.tieba",
        "Referer": refererValue,
        "Cookie": cookies.joined(separator: "; "),
      ],
      body: nil,
      formParts: [],
      requestId: "native-search-\(UUID().uuidString)",
      timeoutMs: 15000
    )
    guard (200..<300).contains(response.status) else { throw TiebaForumAPIError.http(response.status) }
    captureBaiduId(response.setCookies)
    guard let data = response.body.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { throw TiebaForumAPIError.invalidResponse }
    return object
  }

  /// 搜索通道的唯一副作用：服务端回吐 BAIDUID 时落 KV（首次请求不带，与 JS 同）。
  private static func captureBaiduId(_ setCookies: [String]) {
    for cookie in setCookies {
      guard let range = cookie.range(of: "BAIDUID=", options: .caseInsensitive) else { continue }
      let value = cookie[range.upperBound...].prefix { $0 != ";" }
      guard !value.isEmpty else { continue }
      try? TiebaKvStore.shared.set(key: baiduIdKey, value: String(value))
      return
    }
  }

  private static func escape(_ raw: String) -> String {
    raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? raw
  }

  private static func array(_ value: Any?) -> [[String: Any]]? {
    if let list = value as? [[String: Any]] { return list }
    if let dict = value as? [String: Any] { return Array(dict.values.compactMap { $0 as? [String: Any] }) }
    return nil
  }

  /// 相对时间（列表行的 time 文本；语义与 JS utils relativeTime 一致）。
  static func relativeTime(seconds: Double) -> String {
    let diff = max(0, Date().timeIntervalSince1970 - seconds)
    if diff < 60 { return "刚刚" }
    if diff < 3600 { return "\(Int(diff / 60))分钟前" }
    if diff < 86_400 { return "\(Int(diff / 3600))小时前" }
    if diff < 7 * 86_400 { return "\(Int(diff / 86_400))天前" }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: Date(timeIntervalSince1970: seconds))
  }

  /// 搜索摘要里的 HTML 去标签（JS htmlToText 的轻量等价：块级标签留空格 + 实体解码）。
  static func htmlToText(_ html: String) -> String {
    guard html.contains("<") else { return collapse(html) }
    var text = html
    for raw in ["script", "style"] {
      text = text.replacingOccurrences(
        of: "<\(raw)[^>]*>[\\s\\S]*?</\(raw)>",
        with: " ",
        options: [.regularExpression, .caseInsensitive]
      )
    }
    text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
    let entities = [
      "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
      "&#39;": "'", "&apos;": "'", "&hellip;": "…", "&mdash;": "—", "&ldquo;": "“",
      "&rdquo;": "”", "&middot;": "·", "&copy;": "©",
    ]
    for (key, value) in entities {
      text = text.replacingOccurrences(of: key, with: value, options: .caseInsensitive)
    }
    return collapse(text)
  }

  private static func collapse(_ text: String) -> String {
    text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

/// 搜索历史（统一 SQLite 的 search_history 表，与 JS 仓储同一份数据/同键空间）。
enum TiebaSearchHistory {
  struct Item {
    var keyword = ""
    var timestamp = 0.0
  }

  private static let database = "tiebalite.db"
  private static let schema = """
    CREATE TABLE IF NOT EXISTS search_history (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      forum_id TEXT NOT NULL DEFAULT '',
      keyword TEXT NOT NULL,
      timestamp INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_search_history_scope_time
      ON search_history(forum_id, timestamp DESC, id DESC);
    """

  static func load(forumId: String?, limit: Int) -> [Item] {
    guard let rows = try? TiebaSQLite.shared.query(
      database: database,
      sql: "SELECT keyword, timestamp FROM search_history WHERE forum_id = ?"
        + " ORDER BY timestamp DESC, id DESC",
      params: [["v": forumId ?? ""]]
    ) else {
      // 表尚未建（JS 迁移未跑过）：补建，不改动已有数据。
      try? TiebaSQLite.shared.exec(database: database, sql: schema)
      return []
    }
    var seen = Set<String>()
    var items: [Item] = []
    for row in rows {
      let keyword = TiebaSimpleRowParser.string(row["keyword"]) ?? ""
      guard !keyword.isEmpty, seen.insert(keyword.lowercased()).inserted else { continue }
      items.append(Item(
        keyword: keyword,
        timestamp: TiebaSimpleRowParser.double(row["timestamp"]) ?? 0
      ))
      if items.count >= limit { break }
    }
    return items
  }

  /// 落一条：同 scope 下去重 → 插入 → 只保留最近 limit 条（与 JS 三语句同序）。
  /// 写盘 + 重读整段进后台（三写一读同步跑会卡住 commit 的调用线程）。
  @discardableResult
  static func append(keyword: String, forumId: String?, limit: Int) async -> [Item] {
    await Task.detached(priority: .userInitiated) {
      let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return load(forumId: forumId, limit: limit) }
      let scope = forumId ?? ""
      do {
        try TiebaSQLite.shared.begin(database: database)
        _ = try TiebaSQLite.shared.run(
          database: database,
          sql: "DELETE FROM search_history WHERE forum_id = ? AND lower(keyword) = lower(?)",
          params: [["v": scope], ["v": trimmed]]
        )
        _ = try TiebaSQLite.shared.run(
          database: database,
          sql: "INSERT INTO search_history (forum_id, keyword, timestamp) VALUES (?, ?, ?)",
          params: [["v": scope], ["v": trimmed], ["v": Int(Date().timeIntervalSince1970 * 1000)]]
        )
        _ = try TiebaSQLite.shared.run(
          database: database,
          sql: "DELETE FROM search_history WHERE forum_id = ? AND id NOT IN ("
            + " SELECT id FROM search_history WHERE forum_id = ?"
            + " ORDER BY timestamp DESC, id DESC LIMIT ?)",
          params: [["v": scope], ["v": scope], ["v": limit]]
        )
        try TiebaSQLite.shared.commit(database: database)
      } catch {
        try? TiebaSQLite.shared.rollback(database: database)
      }
      return load(forumId: forumId, limit: limit)
    }.value
  }

  static func remove(keyword: String, forumId: String?, limit: Int) -> [Item] {
    _ = try? TiebaSQLite.shared.run(
      database: database,
      sql: "DELETE FROM search_history WHERE forum_id = ? AND lower(keyword) = lower(?)",
      params: [["v": forumId ?? ""], ["v": keyword.trimmingCharacters(in: .whitespacesAndNewlines)]]
    )
    return load(forumId: forumId, limit: limit)
  }

  static func clear(forumId: String?) {
    _ = try? TiebaSQLite.shared.run(
      database: database,
      sql: "DELETE FROM search_history WHERE forum_id = ?",
      params: [["v": forumId ?? ""]]
    )
  }
}
