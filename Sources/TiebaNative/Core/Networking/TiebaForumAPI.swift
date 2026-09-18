// 吧详情 / 吧规 / 吧务团队的原生数据访问（原 src/services/api/endpoints/forum.ts 的三个调用）。
// proto 解码走生成类型（不经 protos.json 描述符注册表），Cookie 与公共参数从原生
// 快照/KV 现读（与 JS buildCookieHeader / buildProtoCommonRequest 同值）。
import Foundation
import SwiftProtobuf

enum TiebaForumAPIError: LocalizedError {
  case api(code: Int32, message: String)
  case http(Int)
  case invalidResponse
  case invalidURL

  var errorDescription: String? {
    switch self {
    case .api(let code, let message):
      return message.isEmpty ? "API error: \(code)" : message
    case .http(let status):
      return "HTTP \(status)"
    case .invalidResponse:
      return "响应解析失败"
    case .invalidURL:
      return "无效请求地址"
    }
  }
}

struct TiebaForumDetail {
  var forumId = ""
  var name = ""
  var avatar = ""
  var slogan = ""
  var intro = ""
  var memberCount = 0
  var threadCount = 0
  var postCount: Int?
  var isLike = false
  var hotText = ""
  var recomReason = ""
}

struct TiebaForumRules {
  struct Section {
    var title = ""
    var segments: [TiebaRuleSegment] = []
  }

  var title = ""
  var publishTime = ""
  var preface = ""
  var authorName = ""
  var authorPortrait = ""
  var sections: [Section] = []
}

/// 吧规正文的一段（proto PbContent / web fallback 的宽松形状统一到这里）。
enum TiebaRuleSegment: Sendable {
  case text(String, bold: Bool)
  case image(src: String, width: CGFloat, height: CGFloat)
  case link(url: String, title: String)
  case quote(String)
  case lineBreak
}

struct TiebaBawuTeam: Sendable {
  struct Member: Sendable {
    var userId = ""
    var userName = ""
    var nameShow = ""
    var portrait = ""
    var userLevel = 0
    var levelName = ""
    var roleName = ""

    var displayName: String {
      let show = nameShow.isEmpty ? userName : nameShow
      return show.isEmpty ? "匿名用户" : show
    }
  }

  struct Role: Sendable {
    var name = ""
    var members: [Member] = []
  }

  var totalNum = 0
  var roles: [Role] = []

  var memberCount: Int {
    roles.reduce(0) { $0 + $1.members.count }
  }
}

enum TiebaForumAPI {
  // MARK: - 吧详情（proto 单源）

  /// ⚠️ 2026-09-15：原来主数据源是 web JSON `/mo/q/forumDetail`，服务端现在对这个
  /// 客户端返回的是 hybrid 的 error_page（HTML），JSONSerialization 必失败 → 页面
  /// 直接报「响应解析失败」（用户报的 bug）。改成走 `/c/f/forum/getforumdetail`：
  /// 与本 App 其它接口同一条 proto 通道（frsPage 同款），字段完备（含热度文本）。
  static func detail(forumId: String) async throws -> TiebaForumDetail {
    guard let info = try await protoForumInfo(forumId: forumId) else {
      throw TiebaForumAPIError.invalidResponse
    }
    var detail = TiebaForumDetail()
    detail.forumId = info.forumID > 0 ? String(info.forumID) : forumId
    detail.name = info.forumName
    detail.avatar = info.avatar
    detail.slogan = info.slogan
    detail.intro = plainText(info.content).trimmingCharacters(in: .whitespacesAndNewlines)
    detail.memberCount = Int(info.memberCount)
    detail.threadCount = Int(info.threadCount)
    detail.isLike = info.isLike != 0
    detail.hotText = info.hotText
    detail.recomReason = info.recomReason
    return detail
  }

  private static func protoForumInfo(forumId: String) async throws -> Tieba_RecommendForumInfo? {
    let data = try await protoPost(path: "/c/f/forum/getforumdetail", cmd: "303021&format=protobuf") { common in
      var request = Tieba_GetForumDetail_GetForumDetailRequestData()
      request.common = common
      request.forumID = Int64(forumId) ?? 0
      var wrapper = Tieba_GetForumDetail_GetForumDetailRequest()
      wrapper.data = request
      return wrapper
    }
    let response = try Tieba_GetForumDetail_GetForumDetailResponse(serializedBytes: data)
    try assertSuccess(response.hasError ? response.error : nil)
    guard response.hasData, response.data.hasForumInfo else { return nil }
    return response.data.forumInfo
  }

  // MARK: - 吧规（proto 单源）

  /// `/mo/q/forumRuleDetail` 与吧详情同命运（返回 error_page），web 降级路径已删：
  /// 留着只会把 proto 的真实错误盖成「响应解析失败」。
  static func rules(forumId: String) async throws -> TiebaForumRules? {
    try await protoRules(forumId: forumId)
  }

  private static func protoRules(forumId: String) async throws -> TiebaForumRules? {
    let data = try await protoPost(path: "/c/f/forum/forumRuleDetail", cmd: "309690") { common in
      var request = Tieba_ForumRuleDetail_ForumRuleDetailRequestData()
      request.forumID = Int64(forumId) ?? 0
      request.common = common
      var wrapper = Tieba_ForumRuleDetail_ForumRuleDetailRequest()
      wrapper.data = request
      return wrapper
    }
    let response = try Tieba_ForumRuleDetail_ForumRuleDetailResponse(serializedBytes: data)
    try assertSuccess(response.hasError ? response.error : nil)
    let info = response.hasData ? response.data : Tieba_ForumRuleDetail_ForumRuleDetailResponseData()

    var rules = TiebaForumRules()
    rules.title = info.title
    rules.publishTime = info.publishTime
    rules.preface = info.preface
    if info.hasBazhu {
      rules.authorName = info.bazhu.nameShow.isEmpty ? info.bazhu.userName : info.bazhu.nameShow
      rules.authorPortrait = info.bazhu.portrait
    }
    rules.sections = info.rules.compactMap { rule in
      let segments = rule.content.map { segment(from: $0) }
      guard !rule.title.isEmpty || !segments.isEmpty else { return nil }
      return TiebaForumRules.Section(title: rule.title, segments: segments)
    }
    guard !rules.title.isEmpty || !rules.preface.isEmpty || !rules.sections.isEmpty else { return nil }
    return rules
  }

  /// PbContent → 段（type: 1 链接 / 3·20 图片 / 10 换行，其余按文本）。
  private static func segment(from content: Tieba_PbContent) -> TiebaRuleSegment {
    switch content.type {
    case 1:
      let url = content.link.isEmpty ? content.text : content.link
      return .link(url: url, title: content.text.isEmpty ? url : content.text)
    case 3, 20:
      let src = firstNonEmpty(content.cdnSrc, content.bigCdnSrc, content.src, content.bigSrc)
      return .image(src: src, width: CGFloat(content.width), height: CGFloat(content.height))
    case 10:
      return .lineBreak
    default:
      return .text(content.text.isEmpty ? content.c : content.text, bold: false)
    }
  }

  // MARK: - 吧务团队（proto）

  static func bawuTeam(forumId: String) async throws -> TiebaBawuTeam {
    let data = try await protoPost(path: "/c/f/forum/getBawuInfo", cmd: "301007") { common in
      var request = Tieba_GetBawuInfo_GetBawuInfoRequestData()
      request.common = common
      request.forumID = UInt64(forumId) ?? 0
      var wrapper = Tieba_GetBawuInfo_GetBawuInfoRequest()
      wrapper.data = request
      return wrapper
    }
    let response = try Tieba_GetBawuInfo_GetBawuInfoResponse(serializedBytes: data)
    try assertSuccess(response.hasError ? response.error : nil)
    guard response.hasData, response.data.hasBawuTeamInfo else { return TiebaBawuTeam() }

    let team = response.data.bawuTeamInfo
    var result = TiebaBawuTeam()
    result.totalNum = Int(team.totalNum)
    result.roles = team.bawuTeamList.compactMap { role in
      let members = role.roleInfo.map { info -> TiebaBawuTeam.Member in
        var member = TiebaBawuTeam.Member()
        member.userId = String(info.userID)
        member.userName = info.userName
        member.nameShow = info.nameShow
        member.portrait = info.portrait
        member.userLevel = Int(info.userLevel)
        member.levelName = info.levelName
        member.roleName = info.roleName.isEmpty ? role.roleName : info.roleName
        return member
      }
      guard !role.roleName.isEmpty || !members.isEmpty else { return nil }
      return TiebaBawuTeam.Role(name: role.roleName, members: members)
    }
    return result
  }

  // MARK: - 吧成员 / 等级排行（原 social.ts getMemberUsers/getRankUsers + forum.ts getMemberInfo）

  /// 成员段数据：proto 会员信息为主；proto 为空/失败时由调用方落 web 兜底
  ///（getMemberUsers 的 HTML 解析产物没有 uid，点击不跳转）。
  struct TiebaForumMembers {
    struct Member {
      var userId = ""
      var userName = ""
      var nameShow = ""
      var portrait = ""
      var userLevel = 0
      var levelName = ""

      var displayName: String {
        let show = nameShow.isEmpty ? userName : nameShow
        return show.isEmpty ? "?" : show
      }
    }

    struct Group {
      var type = ""
      var num = 0
      var members: [Member] = []
    }

    struct MyInfo {
      var isLike = false
      var userLevel = 0
      var levelName = ""
      var curScore = 0
      var levelupScore = 0

      var progress: Double {
        guard levelupScore > 0 else { return 0 }
        return min(Double(curScore) / Double(levelupScore), 1)
      }
    }

    var groups: [Group] = []
    var myInfo: MyInfo?
  }

  struct TiebaForumRankUser {
    var userName = ""
    var level = 0
    var exp = 0
    var isVip = false
  }

  static func members(forumId: String) async throws -> TiebaForumMembers {
    let data = try await protoPost(path: "/c/f/forum/getMemberInfo", cmd: "301004") { common in
      var request = Tieba_GetMemberInfo_GetMemberInfoRequestData()
      request.common = common
      request.forumID = UInt64(forumId) ?? 0
      var wrapper = Tieba_GetMemberInfo_GetMemberInfoRequest()
      wrapper.data = request
      return wrapper
    }
    let response = try Tieba_GetMemberInfo_GetMemberInfoResponse(serializedBytes: data)
    try assertSuccess(response.hasError ? response.error : nil)
    guard response.hasData else { return TiebaForumMembers() }

    let info = response.data
    var result = TiebaForumMembers()
    result.groups = info.memberGroupInfo.compactMap { raw in
      let members = raw.memberGroupList.map { pub -> TiebaForumMembers.Member in
        var member = TiebaForumMembers.Member()
        member.userId = String(pub.userID)
        member.userName = pub.userName
        member.nameShow = pub.nameShow
        member.portrait = pub.portrait
        member.userLevel = Int(pub.userLevel)
        member.levelName = pub.levelName
        return member
      }
      guard !members.isEmpty || raw.memberGroupNum > 0 else { return nil }
      return TiebaForumMembers.Group(
        type: raw.memberGroupType,
        num: Int(raw.memberGroupNum),
        members: members
      )
    }
    if info.hasForumMemberInfo {
      let raw = info.forumMemberInfo
      result.myInfo = TiebaForumMembers.MyInfo(
        isLike: raw.isLike == 1,
        userLevel: Int(raw.userLevel),
        levelName: raw.levelName,
        curScore: Int(raw.curScore),
        levelupScore: Int(raw.levelupScore)
      )
    }
    return result
  }

  /// web 兜底（/bawu2/platform/listMemberInfo，HTML 解析，可能因反爬返回空）。
  static func memberUsers(forumName: String) async throws -> [TiebaForumMembers.Member] {
    let html = try await webGETText(
      path: "/bawu2/platform/listMemberInfo",
      query: ["word": forumName, "pn": "1", "ie": "utf-8"]
    )
    return parseMemberUsersHtml(html)
  }

  /// 等级排行（/f/like/furank，HTML 解析；空页 = 到底，原 JS 同判据）。
  static func rankUsers(forumName: String, pn: Int) async throws -> [TiebaForumRankUser] {
    let html = try await webGETText(
      path: "/f/like/furank",
      query: ["kw": forumName, "pn": String(pn), "ie": "utf-8"]
    )
    return parseRankUsersHtml(html)
  }

  private static func parseMemberUsersHtml(_ html: String) -> [TiebaForumMembers.Member] {
    let text = html as NSString
    func member(_ name: String, _ portrait: String) -> TiebaForumMembers.Member {
      var item = TiebaForumMembers.Member()
      item.userName = name
      item.nameShow = name
      item.portrait = portrait
      return item
    }
    var items: [TiebaForumMembers.Member] = []
    let exact = try? NSRegularExpression(
      pattern: #"<a[^>]*href="[^"]*tieba\.baidu\.com/home/main\?id=[^"]*"[^>]*title="([^"]+)"[^>]*><img[^>]*src="([^"]+)""#
    )
    if let exact {
      for match in exact.matches(in: html, range: NSRange(location: 0, length: text.length)) {
        items.append(member(text.substring(with: match.range(at: 1)), text.substring(with: match.range(at: 2))))
      }
    }
    if items.isEmpty, let loose = try? NSRegularExpression(pattern: #"title="([^"]+)"[^>]*>\s*</a>"#) {
      for match in loose.matches(in: html, range: NSRange(location: 0, length: text.length)) {
        items.append(member(text.substring(with: match.range(at: 1)), ""))
      }
    }
    return items
  }

  /// 原 JS 正则 /drl_item_vip|bg_lv(\d+)|<td[^>]*>([^<]+)<\/td>/g 的逐匹配状态机
  ///（vip 标记看命中点前 40 个 UTF-16 单元，td 文本是待配对的用户名）。
  private static func parseRankUsersHtml(_ html: String) -> [TiebaForumRankUser] {
    let text = html as NSString
    guard let re = try? NSRegularExpression(pattern: #"drl_item_vip|bg_lv(\d+)|<td[^>]*>([^<]+)</td>"#) else {
      return []
    }
    var items: [TiebaForumRankUser] = []
    var pendingName = ""
    var pendingVip = false
    for match in re.matches(in: html, range: NSRange(location: 0, length: text.length)) {
      let levelRange = match.range(at: 1)
      let nameRange = match.range(at: 2)
      if levelRange.location != NSNotFound, let level = Int(text.substring(with: levelRange)) {
        items.append(TiebaForumRankUser(userName: pendingName, level: level, exp: 0, isVip: pendingVip))
        pendingName = ""
        pendingVip = false
      } else if nameRange.location != NSNotFound {
        pendingName = text.substring(with: nameRange)
      } else {
        let start = max(0, match.range.location - 40)
        if text.substring(with: NSRange(location: start, length: match.range.location - start))
          .contains("drl_item_vip")
        {
          pendingVip = true
        }
      }
    }
    return items
  }

  // MARK: - 传输

  /// v12 proto：multipart（stoken + data 部件，无签名字段），解成生成类型。
  /// 非 private：TiebaSocialAPI 的 proto 通道（cmd=309692）复用同一条传输。
  /// extraHeaders：逐请求附加头（frsPage 的 forum_name，原 JS buildProtoTransportParts 同形）。
  static func protoPost<R: SwiftProtobuf.Message>(
    path: String,
    cmd: String,
    extraHeaders: [String: String] = [:],
    clientVersion: String = clientVersion,
    makeRequest: (Tieba_CommonRequest) -> R
  ) async throws -> Data {
    let snapshot = TiebaBackgroundSnapshot.shared
    guard let url = URL(string: "https://tiebac.baidu.com\(path)?cmd=\(cmd)") else {
      throw TiebaForumAPIError.invalidURL
    }
    let cuid = cuidValue()
    var formFields: [[String]] = []
    if !snapshot.stoken.isEmpty {
      formFields.append(["stoken", snapshot.stoken])
    }
    let headers: [String: String] = [
      "User-Agent": Self.v12UserAgent,
      "Accept-Language": "zh-CN,zh;q=0.9",
      "x_bd_data_type": "protobuf",
      "Charset": "UTF-8",
      "client_user_token": snapshot.uid,
      "Cookie": "ka=open; CUID=\(cuid); TBBRAND=\(Self.deviceModel)",
      "cuid": cuid,
      "cuid_galaxy2": cuid,
      "cuid_gid": "",
      "cuid_galaxy3": cuid,
      "c3_aid": cuid,
      "client_type": "2",
    ].merging(extraHeaders) { _, new in new }
    let protoData = try makeRequest(commonRequest(clientVersion: clientVersion)).serializedData()
    // 只读通道的有限重试（本文件调用点全是读：frsPage/pbPage/个人主页/信息流/
    // 吧详情/吧规/吧务/成员/黑名单）：切网瞬间、地铁里的一次抖动不再直接把页面
    // 打成"加载失败"。写接口走 postForm + 签名，**绝不能**重试（非幂等）。
    // 只重试"没到服务端"与"服务端 5xx"两类；4xx/业务错误立即上抛。
    var attempt = 0
    while true {
      do {
        return try await TiebaNativeClient.shared.postProto(
          urlString: url.absoluteString,
          headers: headers,
          formFields: formFields,
          protoData: protoData,
          skipSign: true,
          requestId: "native-forum-\(UUID().uuidString)",
          timeout: 15
        )
      } catch {
        attempt += 1
        guard attempt <= 2, shouldRetryRead(error) else { throw error }
        // 300ms、900ms + 抖动：多页面同时重试不会叠成一个尖峰。
        let base = attempt == 1 ? 0.3 : 0.9
        try? await Task.sleep(nanoseconds: UInt64((base + Double.random(in: 0...0.25)) * 1e9))
      }
    }
  }

  /// 只读请求是否值得重试：传输层错误（未连上/超时/连接中断）与服务端 5xx。
  private static func shouldRetryRead(_ error: Error) -> Bool {
    if let apiError = error as? TiebaForumAPIError, case .http(let status) = apiError {
      return status >= 500
    }
    if let urlError = error as? URLError {
      switch urlError.code {
      case .timedOut, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet,
        .dnsLookupFailed, .cannotFindHost, .secureConnectionFailed:
        return true
      default:
        return false
      }
    }
    return false
  }

  /// 同一通道的纯文本形态（吧成员/排行的响应是 HTML，不是 JSON）。
  private static func webGETText(path: String, query: [String: String]) async throws -> String {
    var components = URLComponents()
    components.scheme = "https"
    components.host = "tieba.baidu.com"
    components.path = path
    components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
    guard let url = components.url else { throw TiebaForumAPIError.invalidURL }
    let snapshot = TiebaBackgroundSnapshot.shared
    var cookies: [String] = []
    if !snapshot.bduss.isEmpty { cookies.append("BDUSS=\(snapshot.bduss)") }
    if !snapshot.stoken.isEmpty { cookies.append("STOKEN=\(snapshot.stoken)") }
    let response = try await TiebaHttpClient.shared.send(
      urlString: url.absoluteString,
      method: "GET",
      headers: [
        "User-Agent": "tieba/22.6.5.1",
        "Accept-Language": "zh-CN,zh;q=0.9",
        "Accept": "application/json",
        "Charset": "UTF-8",
        "Cookie": cookies.joined(separator: "; "),
      ],
      body: nil,
      formParts: [],
      requestId: "native-forum-\(UUID().uuidString)",
      timeoutMs: 15000
    )
    guard (200..<300).contains(response.status) else { throw TiebaForumAPIError.http(response.status) }
    return response.body
  }

  private static func assertSuccess(_ error: Tieba_Error?) throws {
    guard let error, error.errorCode != 0 else { return }
    throw TiebaForumAPIError.api(code: error.errorCode, message: error.errorMsg)
  }

  // MARK: - 请求身份（与 JS buildProtoCommonRequest / buildCookieHeader 同值）

  private static let v12UserAgent =
    "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/135.0.0.0 Mobile Safari/537.36 tieba/12.64.1.1"
  /// 声明给服务端的客户端版本。**能力按版本号下发，且各端点门控方向相反**：
  ///  - 楼中楼图片在 < 22.9 下被服务端压成文本「[图片]」（2026-09-17 实测：22.8 = 文本、
  ///    22.9 = 真图带 cdnSrc）⇒ pbPage / pbFloor **必须** ≥ 22.9；
  ///  - 吧帖子列表（frsPage）反过来：声明 ≥ 20.0 时服务端对部分吧（实测 deepseek、steam）
  ///    返回的 FrsPageResponseData **完全不含 thread_list(#7)**（百度/程序员/原神等正常），
  ///    列表因此空屏 ⇒ frsPage **必须** 12.64.1.1（2026-09-18 逐版本实探：12.41/12.64 有
  ///    thread_list，20.0 起归零）。
  /// 所以版本号按调用方给，不再是单一全局常量。HTTP UA 不参与门控。
  private static let clientVersion = "22.9.1.0"
  /// frsPage 专用：被证实能拿到 thread_list 的版本（JS 期一路沿用的值）。
  static let forumListClientVersion = "12.64.1.1"
  private static let deviceModel = "SM-G9910"

  /// 非 private：TiebaThreadAPI 的 pbPage 复用同一份身份参数。
  /// `version` 默认 22.9.1.0（楼中楼图片档）；只有 frsPage 显式传旧版本号。
  static func commonRequest(clientVersion version: String = clientVersion) -> Tieba_CommonRequest {
    let now = Int64(Date().timeIntervalSince1970 * 1000)
    let clientId = clientIdValue()
    let cuid = cuidValue()
    var common = Tieba_CommonRequest()
    common.clientType = 2
    common.clientVersion = version
    common.clientID = clientId
    common.phoneImei = clientId
    common.cuid = cuid
    common.timestamp = now
    common.model = deviceModel
    common.bduss = TiebaBackgroundSnapshot.shared.bduss
    common.netType = 1
    common.pversion = "1.0.3"
    common.osVersion = "31"
    common.brand = "samsung"
    common.legoLibVersion = "3.0.0"
    common.stoken = TiebaBackgroundSnapshot.shared.stoken
    common.cuidGalaxy2 = cuid
    common.cuidGid = ""
    common.oaid = ""
    common.c3Aid = cuid
    common.sampleID = clientId
    common.isTeenager = 0
    common.from = "1020031h"
    common.activeTimestamp = now
    common.androidID = ""
    common.cmode = 1
    common.eventDay = eventDay()
    common.extra = ""
    common.firstInstallTime = now - 86_400_000 * 30
    common.frameworkVer = "3340042"
    common.lastUpdateTime = now - 86_400_000
    common.personalizedRecSwitch = 1
    common.qType = 0
    common.scrDip = 3
    common.scrH = 2532
    common.scrW = 1170
    common.sdkVer = "2.34.0"
    common.startScheme = ""
    common.startType = 1
    common.nawsGameVer = "1038000"
    common.userAgent = "tieba/\(version)"
    common.zID = ""
    return common
  }

  /// 与 JS buildCookieHeader / buildProtoCommonRequest 同值；非 private 供
  /// TiebaSocialAPI 的签名 JSON 通道复用同一份身份参数。
  /// 复用静态 formatter：commonRequest 每请求都调，新建 DateFormatter 的
  /// locale/calendar 解析是热路径上的纯浪费。
  nonisolated(unsafe) private static let eventDayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.dateFormat = "yyyyMdd"
    return formatter
  }()

  static func eventDay() -> String {
    eventDayFormatter.string(from: Date())
  }

  private static let identityLock = NSLock()
  nonisolated(unsafe) private static var cachedCuid: String?
  /// client_id 同样内存缓存：它在每个 proto 请求的 common 里，原来是每请求一次
  /// KV 点查（与 cachedCuid 同一动机）。
  nonisolated(unsafe) private static var cachedClientId: String?

  static func clientIdValue() -> String {
    identityLock.lock()
    defer { identityLock.unlock() }
    if let cached = cachedClientId { return cached }
    var value = TiebaKvStore.shared.get(key: "@tiebalite:client_id") ?? ""
    if value.isEmpty { value = TiebaBackgroundSnapshot.shared.clientId }
    cachedClientId = value
    return value
  }

  /// JS 在启动时把 cuid 写进 KV（wappc_<毫秒>_<随机>）；读不到时按同一形态生成
  /// 并缓存，避免每次请求换一个指纹。非 private：TiebaSocialAPI 复用。
  static func cuidValue() -> String {
    identityLock.lock()
    defer { identityLock.unlock() }
    if let cached = cachedCuid { return cached }
    if let stored = TiebaKvStore.shared.get(key: "@tiebalite:cuid"), !stored.isEmpty {
      cachedCuid = stored
      return stored
    }
    let generated = "wappc_\(Int(Date().timeIntervalSince1970 * 1000))_\(String(UInt32.random(in: 0...UInt32.max), radix: 16))"
    cachedCuid = generated
    return generated
  }

  // MARK: - JSON 容错读取

  private static func plainText(_ content: [Tieba_PbContent]) -> String {
    content.map { segment in
      switch segment.type {
      case 3, 10, 20: return ""
      default: return segment.text.isEmpty ? segment.c : segment.text
      }
    }.joined()
  }

  private static func firstNonEmpty(_ values: String...) -> String {
    values.first { !$0.isEmpty } ?? ""
  }
}
