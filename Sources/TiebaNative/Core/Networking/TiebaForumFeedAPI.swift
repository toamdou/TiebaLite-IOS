// 吧页数据（原 src/stores/forumStore.ts 的数据段 + src/services/api/endpoints/forum.ts
// 的 likeForum / unfavolike / sign）。frsPage 走 v12 proto，解码后交给既有
// TiebaViewModelMapper 的 frsPage 纯投影（行字典 = mapProtoThread，与信息流卡片同一契约）；
// 关注/签到走签名 JSON 表单通道（TiebaNativeClient.postForm，与 JS apiPost 同参数）。
import Foundation

/// 吧名片数据（mapFrsPageData 的 forum 字典 → 类型化）。
struct TiebaForumCard {
  var forumId = ""
  var name = ""
  var avatar = ""
  var intro = ""
  var memberCount = 0
  var threadCount = 0
  var isLike = false
  var levelId = 0
  var levelName = ""
  var curScore = 0
  var levelupScore = 0
  var isSignIn = false
  var contSignNum = 0
  /// anti.tbs（关注/签到的写接口凭据）。
  var tbs = ""
}

struct TiebaForumClassify {
  var id = ""
  var name = ""
}

struct TiebaForumFeedPage {
  /// mapProtoThread 行字典（含置顶帖；广告帖已由投影剔除）。
  var threads: [[String: Any]] = []
  var hasMore = false
  /// 仅 page == 1 且有 forum 时非空。
  var card: TiebaForumCard?
  var classifies: [TiebaForumClassify] = []
}

struct TiebaForumLikeResult {
  var memberSum: Int?
  var levelId: Int?
  var levelName: String?
  var curScore: Int?
  var levelupScore: Int?
}

struct TiebaForumSignResult {
  var isSuccess = false
  var exp = 0
  var errorCode: Int?
  var errorMessage = ""
}

enum TiebaForumFeedAPI {
  /// 吧帖子列表。sortType：-1 = 吧默认列表（热门/精品），0 = 按回复，1 = 按发帖（最新）。
  static func page(
    forumName: String,
    page: Int,
    sortType: Int,
    isGood: Bool,
    classifyId: String?
  ) async throws -> TiebaForumFeedPage {
    let encodedKw = urlEncoded(forumName)
    let data = try await TiebaForumAPI.protoPost(
      path: "/c/f/frs/page",
      cmd: "301001&format=protobuf",
      extraHeaders: ["forum_name": encodedKw]
    ) { common in
      var request = Tieba_FrsPage_FrsPageRequestData()
      request.common = common
      request.kw = encodedKw
      request.pn = Int32(page)
      request.rn = 90
      request.rnNeed = 30
      request.qType = 2
      request.sortType = Int32(sortType)
      request.stType = "recom_flist"
      request.withGroup = 1
      request.loadType = page == 1 ? 1 : 2
      request.isGood = isGood ? 1 : 0
      request.cid = Int32(classifyId ?? "") ?? 0
      request.scrW = 1170
      request.scrH = 2532
      request.scrDip = 3
      request.callFrom = 0
      var wrapper = Tieba_FrsPage_FrsPageRequest()
      wrapper.data = request
      return wrapper
    }
    let decoded = try TiebaSwiftProto.decode(messagePath: "tieba.frsPage.FrsPageResponse", bytes: data)
    try TiebaViewModelMapper.assertProtoSuccess(decoded)
    // 空 data 与 JS `if (!data) throw` 同语义（mapResponse 返回 nil）。
    guard let mapped = TiebaViewModelMapper.mapResponse(
      mapper: "frsPage",
      decoded: decoded,
      options: ["page": Double(page), "forumName": forumName]
    ) as? [String: Any] else { throw TiebaForumAPIError.invalidResponse }

    var result = TiebaForumFeedPage()
    result.threads = mapped["threads"] as? [[String: Any]] ?? []
    result.hasMore = TiebaSimpleRowParser.bool(mapped["hasMore"]) ?? false
    if let raw = mapped["forum"] as? [String: Any] {
      var card = card(from: raw)
      applyFollowedCacheFallback(
        to: &card,
        rawIsLike: mapped["rawIsLike"],
        rawUserLevel: mapped["rawUserLevel"]
      )
      result.card = card
    }
    result.classifies = (mapped["goodClassify"] as? [[String: Any]] ?? []).compactMap { item in
      let id = TiebaSimpleRowParser.string(item["classId"]) ?? ""
      let name = TiebaSimpleRowParser.string(item["className"]) ?? ""
      guard !id.isEmpty, !name.isEmpty else { return nil }
      return TiebaForumClassify(id: id, name: name)
    }
    return result
  }

  // MARK: - 关注 / 取消关注

  static func like(forumId: String, forumName: String, tbs: String) async throws -> TiebaForumLikeResult {
    guard !tbs.isEmpty else {
      throw TiebaForumAPIError.api(code: 400, message: "缺少 tbs，无法关注贴吧")
    }
    let body = try await postForm(
      path: "/c/c/forum/like",
      fields: ["fid": forumId, "kw": forumName, "tbs": tbs],
      requestId: "native-forum-like"
    )
    try TiebaViewModelMapper.assertProtoSuccess(body)
    guard let info = body["info"] as? [String: Any] else { return TiebaForumLikeResult() }
    func int(_ keys: String...) -> Int? {
      for key in keys {
        if let value = TiebaSimpleRowParser.double(info[key]) { return Int(value) }
      }
      return nil
    }
    return TiebaForumLikeResult(
      memberSum: int("member_sum", "memberSum"),
      levelId: int("level_id", "levelId"),
      levelName: TiebaSimpleRowParser.nonEmpty(info["level_name"] ?? info["levelName"]),
      curScore: int("cur_score", "curScore"),
      levelupScore: int("levelup_score", "levelUpScore")
    )
  }

  static func unlike(forumId: String, forumName: String, tbs: String) async throws {
    guard !tbs.isEmpty else {
      throw TiebaForumAPIError.api(code: 400, message: "缺少 tbs，无法取消关注贴吧")
    }
    let body = try await postForm(
      path: "/c/c/forum/unfavolike",
      fields: ["fid": forumId, "kw": forumName, "tbs": tbs],
      requestId: "native-forum-unlike"
    )
    try TiebaViewModelMapper.assertProtoSuccess(body)
  }

  // MARK: - 签到

  static func sign(forumName: String, tbs: String, forumId: String) async throws -> TiebaForumSignResult {
    guard !tbs.isEmpty else {
      throw TiebaForumAPIError.api(code: 400, message: "缺少 tbs，无法签到")
    }
    var fields = ["kw": forumName, "tbs": tbs]
    if !forumId.isEmpty { fields["fid"] = forumId }
    let body = try await postForm(
      path: "/c/c/forum/sign",
      fields: fields,
      requestId: "native-forum-sign"
    )
    // 顶层 1101（今日已签到）在原 JS 里被响应拦截器抛成 TiebaApiError(code 1101)，
    // 页面按"已签到"消费——这里等价归一为 SignResult（isSuccess=false + errorCode=1101）。
    let topError = TiebaViewModelMapper.getTiebaError(body)
    if let topError, Int(topError.code) == 1101 {
      let fallback = signFields(in: body["data"] as? [String: Any] ?? [:])
      return TiebaForumSignResult(
        isSuccess: false,
        exp: fallback.exp,
        errorCode: 1101,
        errorMessage: fallback.errorMessage
      )
    }
    if let topError { throw topError }
    let raw = body["data"] as? [String: Any] ?? [:]
    let parsed = signFields(in: raw)
    // 内层 error_code 由 getTiebaError 判定（isSuccess = 无错误，与 JS 同式）。
    let innerError = TiebaViewModelMapper.getTiebaError(raw)
    return TiebaForumSignResult(
      isSuccess: innerError == nil,
      exp: parsed.exp,
      errorCode: innerError.map { Int($0.code) },
      errorMessage: innerError?.message ?? parsed.errorMessage
    )
  }

  /// `raw.exp ?? user_info.sign_bonus_point`（JS 双读，否则"经验+0"）。
  private static func signFields(in raw: [String: Any]) -> (exp: Int, errorMessage: String) {
    let userInfo = (raw["user_info"] ?? raw["userInfo"]) as? [String: Any] ?? [:]
    let exp = TiebaSimpleRowParser.double(raw["exp"])
      ?? TiebaSimpleRowParser.double(userInfo["sign_bonus_point"] ?? userInfo["signBonusPoint"])
      ?? 0
    let message = TiebaSimpleRowParser.string(raw["error_msg"] ?? raw["errorMsg"]) ?? ""
    return (Int(exp), message)
  }

  // MARK: - 已关注吧缓存兜底（forumStore.mergeFollowedForumFallback 同规则）

  /// JS forumFollowed 把关注列表写进同一 KV 表（followed_forums_cache_v1，TTL 24h）。
  /// 只补服务端没下发的字段：is_like 缺失 → 视为已关注；等级缺失 → 补等级；
  /// 签到态取并集。绝不覆盖服务端明确给出的 0。
  private static func applyFollowedCacheFallback(
    to card: inout TiebaForumCard,
    rawIsLike: Any?,
    rawUserLevel: Any?
  ) {
    guard !card.forumId.isEmpty,
      let raw = TiebaKvStore.shared.get(key: "followed_forums_cache_v1"),
      let data = raw.data(using: .utf8),
      let cache = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let forums = cache["forums"] as? [[String: Any]]
    else { return }
    let expiresAt = TiebaSimpleRowParser.double(cache["expiresAt"]) ?? 0
    guard expiresAt > Date().timeIntervalSince1970 * 1000 else { return }
    // 签到态只信当天：缓存里的 isSign 属于被缓存的那一天，跨天兜底会把吧页头钉在
    // 「今天已经签到过了」并拦掉签到按钮（用户 2026-09-15 报）。等级/关注兜底照旧。
    let signFallbackTrusted =
      (TiebaSimpleRowParser.string(cache["day"]) ?? "") == TiebaFollowedForums.today()
    guard let entry = forums.first(where: {
      TiebaSimpleRowParser.string($0["forumId"]) == card.forumId
    }) else { return }

    let isLikeKnown = !(rawIsLike == nil || rawIsLike is NSNull)
    let levelKnown = !(rawUserLevel == nil || rawUserLevel is NSNull)
    if !isLikeKnown, !card.isLike { card.isLike = true }
    let entryLevel = Int(TiebaSimpleRowParser.double(entry["levelId"]) ?? 0)
    if !levelKnown, card.levelId == 0, entryLevel > 0 {
      card.levelId = entryLevel
      if card.levelName.isEmpty {
        card.levelName = TiebaSimpleRowParser.string(entry["levelName"]) ?? ""
      }
    }
    if signFallbackTrusted, !card.isSignIn, TiebaSimpleRowParser.bool(entry["isSign"]) == true {
      card.isSignIn = true
      card.contSignNum = Int(TiebaSimpleRowParser.double(entry["signCount"]) ?? 0)
    }
  }

  // MARK: - 解析 / 传输

  private static func card(from raw: [String: Any]) -> TiebaForumCard {
    var card = TiebaForumCard()
    card.forumId = TiebaSimpleRowParser.string(raw["forumId"]) ?? ""
    card.name = TiebaSimpleRowParser.string(raw["forumName"]) ?? ""
    card.avatar = TiebaSimpleRowParser.string(raw["avatar"]) ?? ""
    card.intro = TiebaSimpleRowParser.string(raw["intro"]) ?? ""
    card.memberCount = Int(TiebaSimpleRowParser.double(raw["memberCount"]) ?? 0)
    card.threadCount = Int(TiebaSimpleRowParser.double(raw["threadCount"]) ?? 0)
    card.isLike = TiebaSimpleRowParser.bool(raw["isLike"]) ?? false
    card.levelId = Int(TiebaSimpleRowParser.double(raw["levelId"]) ?? 0)
    card.levelName = TiebaSimpleRowParser.string(raw["levelName"]) ?? ""
    card.curScore = Int(TiebaSimpleRowParser.double(raw["curScore"]) ?? 0)
    card.levelupScore = Int(TiebaSimpleRowParser.double(raw["levelupScore"]) ?? 0)
    card.tbs = TiebaSimpleRowParser.string(raw["tbs"]) ?? ""
    if let signIn = raw["signInInfo"] as? [String: Any] {
      card.isSignIn = TiebaSimpleRowParser.bool(signIn["isSignIn"]) ?? false
      card.contSignNum = Int(TiebaSimpleRowParser.double(signIn["contSignNum"]) ?? 0)
    }
    return card
  }

  /// 签名 JSON 表单（与 JS apiPost 的 common params + sign 同形）。
  private static func postForm(
    path: String,
    fields: [String: String],
    requestId: String
  ) async throws -> [String: Any] {
    try await TiebaNativeClient.shared.postForm(
      urlString: "https://c.tieba.baidu.com\(path)",
      fields: fields,
      includeCommon: true,
      includeSign: true,
      requestId: "\(requestId)-\(UUID().uuidString)",
      timeout: 15
    )
  }

  /// encodeURIComponent 等价集合（unreserved + JS 不转义的 `!*'()`）。
  private static func urlEncoded(_ value: String) -> String {
    let allowed = CharacterSet(
      charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()"
    )
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
  }
}
