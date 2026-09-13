// 社交域数据访问（原 src/services/api/endpoints/social.ts 的黑名单 / 解除 /
// 屏蔽吧三个调用）。签名 JSON 通道（tiebac + common params + sign + st 参数）
// 与 JS client.ts 的 signed 变体逐参数一致；屏蔽吧优先走 proto（cmd=309692），
// proto 失败或空结果时落 JSON form。
import Foundation

enum TiebaSocialAPI {
  struct BlacklistUser {
    var uid = ""
    var portrait = ""
    var userName = ""
    var nickName = ""
    /// "FOLLOW,INTERACT,CHAT"（原 perm_list 位转标签）
    var btype = ""

    var displayName: String {
      if !nickName.isEmpty { return nickName }
      if !userName.isEmpty { return userName }
      return uid
    }
  }

  struct DislikeForum {
    var fid = ""
    var fname = ""
    var memberNum = 0
    var postNum = 0
  }

  // MARK: - 云端黑名单

  static func blacklist() async throws -> [BlacklistUser] {
    let body = try await signedPost(path: "/c/u/user/userBlackPage", fields: [:])
    let data = (body["data"] as? [String: Any]) ?? body
    let list = TiebaJSON.list(data, ["user_list", "black_list", "list"])
    return list.map { raw in
      var user = BlacklistUser()
      user.uid = TiebaJSON.string(raw, "id", "uid") ?? ""
      user.portrait = TiebaSimpleRowParser.cleanPortrait(TiebaJSON.string(raw, "portrait") ?? "")
      user.userName = TiebaJSON.string(raw, "name", "user_name") ?? ""
      user.nickName = TiebaJSON.string(raw, "name_show", "nick_name_new", "nickName") ?? ""
      let perm = raw["perm_list"] as? [String: Any]
      var types: [String] = []
      if TiebaJSON.int(perm, "follow") == 1 { types.append("FOLLOW") }
      if TiebaJSON.int(perm, "interact") == 1 { types.append("INTERACT") }
      if TiebaJSON.int(perm, "chat") == 1 { types.append("CHAT") }
      user.btype = types.joined(separator: ",")
      return user
    }
  }

  /// 解除黑名单（对齐 aiotieba del_blacklist_old：mute_user 字段）。
  static func removeBlacklist(uid: String) async throws {
    _ = try await signedPost(path: "/c/c/user/userMuteDel", fields: ["mute_user": uid])
  }

  // MARK: - 资料修改 / 头像上传（原 user.ts profileModify + social.ts uploadPortrait）

  /// 个人信息修改（与 JS profileModify 同字段：intro/sex/nick_name/stoken）。
  static func modifyProfile(intro: String, sex: Int, nickName: String) async throws {
    _ = try await signedPost(
      path: "/c/c/profile/modify",
      fields: [
        "intro": intro,
        "sex": String(sex),
        "nick_name": nickName,
        "stoken": TiebaBackgroundSnapshot.shared.stoken,
      ]
    )
  }

  /// 头像上传（multipart，upload 变体：不加 common/sign，只带 Cookie）。
  static func uploadPortrait(fileUri: String, tbs: String) async throws {
    let snapshot = TiebaBackgroundSnapshot.shared
    var headers: [String: String] = [
      "User-Agent": "tieba/22.6.5.1",
      "Accept-Language": "zh-CN,zh;q=0.9",
      "Accept": "application/json",
      "Charset": "UTF-8",
    ]
    var cookies: [String] = []
    if !snapshot.bduss.isEmpty { cookies.append("BDUSS=\(snapshot.bduss)") }
    if !snapshot.stoken.isEmpty { cookies.append("STOKEN=\(snapshot.stoken)") }
    if !cookies.isEmpty { headers["Cookie"] = cookies.joined(separator: "; ") }
    let response = try await TiebaHttpClient.shared.send(
      urlString: "https://tiebac.baidu.com/c/c/img/portrait",
      method: "POST",
      headers: headers,
      body: nil,
      formParts: [
        TiebaHttpFormPart(
          name: "portrait", value: nil, fileUri: fileUri,
          fileName: "portrait.jpg", mimeType: "image/jpeg"
        ),
        TiebaHttpFormPart(name: "tbs", value: tbs, fileUri: nil, fileName: nil, mimeType: nil),
        TiebaHttpFormPart(
          name: "stoken", value: snapshot.stoken, fileUri: nil, fileName: nil, mimeType: nil
        ),
      ],
      requestId: "native-portrait-\(UUID().uuidString)",
      timeoutMs: 60000
    )
    guard (200..<300).contains(response.status) else { throw TiebaForumAPIError.http(response.status) }
    guard let data = response.body.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { throw TiebaForumAPIError.invalidResponse }
    try assertNoError(object)
  }

  // MARK: - 屏蔽吧

  static func dislikeForums(pn: Int, rn: Int) async throws -> [DislikeForum] {
    if let proto = try? await protoDislikeForums(pn: pn, rn: rn),
      !proto.items.isEmpty || proto.hasMore || proto.curPage != 0
    {
      return proto.items
    }
    let body = try await signedPost(
      path: "/c/u/user/getDislikeList",
      fields: ["pn": String(pn), "rn": String(rn)]
    )
    let data = (body["data"] as? [String: Any]) ?? body
    return TiebaJSON.list(data, ["forum_list", "dislike_list", "list"]).map { raw in
      var forum = DislikeForum()
      forum.fid = TiebaJSON.string(raw, "forumId", "forum_id", "fid") ?? ""
      forum.fname = TiebaJSON.string(raw, "forumName", "forum_name", "fname") ?? ""
      forum.memberNum = TiebaJSON.int(raw, "memberCount", "member_count") ?? 0
      forum.postNum = TiebaJSON.int(raw, "postNum", "post_num") ?? 0
      return forum
    }
  }

  private static func protoDislikeForums(
    pn: Int,
    rn: Int
  ) async throws -> (items: [DislikeForum], hasMore: Bool, curPage: Int) {
    let uid = Int64(TiebaBackgroundSnapshot.shared.uid) ?? 0
    let data = try await TiebaForumAPI.protoPost(path: "/c/u/user/getDislikeList", cmd: "309692") { common in
      var request = Tieba_GetDislikeList_GetDislikeListRequestData()
      request.common = common
      request.userID = uid
      request.pn = Int32(pn)
      request.rn = Int32(rn)
      var wrapper = Tieba_GetDislikeList_GetDislikeListRequest()
      wrapper.data = request
      return wrapper
    }
    let response = try Tieba_GetDislikeList_GetDislikeListResponse(serializedBytes: data)
    if response.hasError, response.error.errorCode != 0 {
      throw TiebaForumAPIError.api(code: response.error.errorCode, message: response.error.errorMsg)
    }
    guard response.hasData else { return ([], false, 0) }
    let items = response.data.forumList.map { raw -> DislikeForum in
      var forum = DislikeForum()
      forum.fid = String(raw.forumID)
      forum.fname = raw.forumName
      forum.memberNum = Int(raw.memberCount)
      forum.postNum = Int(raw.postNum)
      return forum
    }
    return (items, response.data.hasMore_p == 1, Int(response.data.curPage))
  }

  // MARK: - 签名 JSON 通道

  /// 签名 JSON 通道（tiebac）。非 private：TiebaFeedAPI 的不感兴趣上报复用同一份
  /// common params / sign / st 参数（与 JS 的 apiPost 签名链同值）。
  static func signedPost(path: String, fields: [String: String]) async throws -> [String: Any] {
    var params = commonParams()
    params.merge(stParams()) { _, new in new }
    params.merge(fields) { _, new in new }
    params["sign"] = TiebaSigner.signParams(params)
    let body = params
      .sorted { $0.key < $1.key }
      .map { "\($0.key)=\(TiebaRoutePath.segment($0.value))" }
      .joined(separator: "&")

    let snapshot = TiebaBackgroundSnapshot.shared
    var headers: [String: String] = [
      "User-Agent": "tieba/22.6.5.1",
      "Accept-Language": "zh-CN,zh;q=0.9",
      "Accept": "application/json",
      "Charset": "UTF-8",
      "Content-Type": "application/x-www-form-urlencoded",
      "force_login": "true",
    ]
    if !snapshot.uid.isEmpty { headers["client_user_token"] = snapshot.uid }
    var cookies: [String] = []
    if !snapshot.bduss.isEmpty { cookies.append("BDUSS=\(snapshot.bduss)") }
    if !snapshot.stoken.isEmpty { cookies.append("STOKEN=\(snapshot.stoken)") }
    if !cookies.isEmpty { headers["Cookie"] = cookies.joined(separator: "; ") }

    let response = try await TiebaHttpClient.shared.send(
      urlString: "https://tiebac.baidu.com\(path)",
      method: "POST",
      headers: headers,
      body: body,
      formParts: [],
      requestId: "native-social-\(UUID().uuidString)",
      timeoutMs: 15000
    )
    guard (200..<300).contains(response.status) else { throw TiebaForumAPIError.http(response.status) }
    guard let data = response.body.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { throw TiebaForumAPIError.invalidResponse }
    try assertNoError(object)
    return object
  }

  /// 原 JS buildCommonParams（_client_version 22.6.5.1 一组，与 proto 通道的
  /// 12.64.1.1 不同）——服务端对旧版本号回 110001。
  private static func commonParams() -> [String: String] {
    let now = Int(Date().timeIntervalSince1970 * 1000)
    let snapshot = TiebaBackgroundSnapshot.shared
    let clientId = TiebaForumAPI.clientIdValue()
    let cuid = TiebaForumAPI.cuidValue()
    var params: [String: String] = [
      "BDUSS": snapshot.bduss,
      "_client_id": clientId,
      "_client_type": "2",
      "_os_version": "31",
      "model": "SM-G9910",
      "net_type": "1",
      "_phone_imei": clientId,
      "timestamp": String(now),
      "active_timestamp": String(now),
      "android_id": "",
      "baiduid": "",
      "brand": "samsung",
      "c3_aid": cuid,
      "cmode": "1",
      "cuid": cuid,
      "cuid_galaxy2": cuid,
      "cuid_gid": "",
      "event_day": TiebaForumAPI.eventDay(),
      "extra": "",
      "first_install_time": String(now - 86_400_000 * 30),
      "framework_ver": "3340042",
      "from": "tieba",
      "is_teenager": "0",
      "last_update_time": String(now - 86_400_000),
      "mac": "02:00:00:00:00:00",
      "oaid": "{\"id\":\"\",\"oaid\":\"\",\"aaid\":\"\",\"vaid\":\"\"}",
      "sample_id": clientId,
      "sdk_ver": "2.34.0",
      "start_scheme": "",
      "start_type": "1",
      "naws_game_ver": "1038000",
      "_client_version": "22.6.5.1",
      "personalized_rec_switch": "1",
      "z_id": "",
      "device_score": "50",
    ]
    if !snapshot.stoken.isEmpty { params["stoken"] = snapshot.stoken }
    return params
  }

  /// 原 JS buildStParams：100..850 的随机 stTime（100..120 段全空）。
  private static func stParams() -> [String: String] {
    let number = Int.random(in: 100...850)
    if number <= 120 { return ["stErrorNums": "0"] }
    return [
      "stErrorNums": "1",
      "stMethod": "1",
      "stMode": "1",
      "stTimesNum": "1",
      "stTime": String(number),
      "stSize": String(Int((Double.random(in: 0.4...8.4) * Double(number)).rounded())),
    ]
  }

  /// 原 JS getTiebaError：proto error.error_code / error_code|errno|err_code，以及
  /// 顶层 code（0/1 视为成功）。
  private static func assertNoError(_ object: [String: Any]) throws {
    let protoError = object["error"] as? [String: Any]
    let code = TiebaJSON.int(protoError, "error_code", "errorCode")
      ?? TiebaJSON.int(object, "error_code", "errno", "err_code")
      ?? 0
    if code != 0 {
      let message = TiebaJSON.string(object, "error_msg", "msg")
        ?? TiebaJSON.string(protoError, "error_msg", "errorMsg")
        ?? "API error: \(code)"
      throw TiebaForumAPIError.api(code: Int32(code), message: message)
    }
    if let raw = TiebaJSON.int(object, "code"), raw != 0, raw != 1 {
      throw TiebaForumAPIError.api(code: Int32(raw), message: TiebaJSON.string(object, "message", "msg") ?? "API returned code: \(raw)")
    }
  }
}
