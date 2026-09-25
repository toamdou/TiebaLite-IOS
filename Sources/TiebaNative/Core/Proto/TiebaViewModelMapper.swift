// ============================================================
// TiebaLite RN — proto view-model mapper（Foundation-only）
//
// 与 src/services/api/endpoints/helpers.ts 纯映射层逐语义对齐的原生移植：
//   assertProtoSuccess / isAdThread / isAdThreadInfo / toMillis /
//   mapMediaList / mapProtoThread / mapFeedThreadItems / mapUserLikeData /
//   mapFrsPageData
//
// 设计约束（刻意为之）：
//   - 只 import Foundation。输入 [String: Any] = TiebaSwiftProto.decode 归一化后
//     的字典（与旧路径交给 JSONSerialization 的是同一份），输出 [String: Any] /
//     [[String: Any]] / 标量。不依赖 SwiftProtobuf —— 可用裸 swiftc 编译并做
//     金标准对照（scripts/mapper-golden/），也不进 podspec 依赖。
//   - 输出形状 = JSON round-trip 后的 JS 形状：TS 里 JSON.stringify 丢弃
//     undefined 键（这里以「键缺席」表达）、NaN/Infinity 写成 null
//     （这里以 NSNull 表达）。JS 拿到的对象与旧路径 JSON.parse 后一致。
//   - 复刻 JS 语义的局部 helper：??（coalesce）/ ||（jsOr）/ String() / Number() /
//     `=== 1`（strictOne）/ typeof（truthy）。注意 String(true)="true"、
//     true === 1 为 false —— 不能拿 Swift 的隐式 Bool/NSNumber 桥接顶替。
//
// 与 TS 的刻意差异（仅畸形输入；正常 wire 数据不会遇到，均在此登记）：
//   1. mapMediaList/mapProtoThread 对数组里的 null/非对象元素选择跳过，
//      TS 会在属性访问时抛 TypeError；原生侧跳过不会整页失败，兜底=未映射。
//   2. Number() 不支持 JS 特有的 "0b101" 字面量（wire 数据不会出现）。
//   3. 输入里无法区分 undefined 与 null（[String: Any] 没有 undefined），
//      二者一律按 TS 的 null 分支处理 —— 与 JSON round-trip 后的行为一致。
//   4. 表情名走 Map 查找，不复刻 JS 原型链：TS 的 EMOTICON_NAME_MAP['constructor']
//      会命中 Object 构造器（truthy）并生成垃圾 src；原生只认 50 个真实表情
//      （wire 数据不会出现 constructor/__proto__ 这类名字）。
//   5. 非空数组作 author（typeof [] === 'object' 且 Object.keys 非空）时，TS 会
//      丢弃 userList 回退、原生仍回退 userList —— 仅当 author 是数组且 userList
//      含同 id 时可见；proto3 message 字段不会解码成数组。
// ============================================================

import Foundation

/// 与 TS TiebaApiError 对齐的原生错误（桥接层转回 JS 的 TiebaApiError）。
/// ⚠️ 必须实现 LocalizedError：调用方普遍按 `(error as? LocalizedError)?.errorDescription`
/// 取文案；只 conforms to Error 时 message 拿不出来、界面只剩兜底文案
///（2026-09-19 用户报"收藏失败"查不到真因就是这个）。
public struct TiebaViewModelError: Error, LocalizedError, Equatable {
  /// 与 TiebaApiError.code / errorCode 同值（TS 构造时二者传同一个数）。
  public let code: Double
  public let message: String

  public var errorDescription: String? { message }
}

/// proto → view-model 纯映射层。所有函数无状态、无 IO、只依赖 Foundation。
public enum TiebaViewModelMapper {

  // MARK: - 桥接入口

  /// 已注册的 mapper 名（原生调用方只经 mapResponse 走这三个）。
  ///   feedThreadList : PersonalizedResponseData → FeedItem[]（feed.ts 纯投影）
  ///   userLike       : UserLikeResponseData → {items,pageTag,hasMore,requestUnix}
  ///                    （feed.ts userLike 的纯数据投影；增量 Unix 状态留在 JS）
  ///   frsPage        : FrsPageResponseData → {threads,hasMore,forum,rawIsLike,
  ///                    rawUserLevel,goodClassify,navTabInfo}（forumStore 纯数据段；
  ///                    tbs 持久化/分桶/缓存兜底合并等留在 JS）
  ///
  /// 2026-09-13 删除：thread/posts/content/mediaList/pbPage 五个 mapper 分支与
  /// mapProtoPosts/mapProtoContent/mapPbPageData/jsLessThan —— 0 调用方
  /// （帖子页走 TiebaThreadAPI 的强类型视图模型，主页行直读生成类型）。
  ///
  /// payload 语义 = 该 mapper 的纯投影输入（response data 对象）；桥接层用
  /// `mapResponse` 处理完整响应到 data 的选取。
  public static func map(mapper: String, payload: Any?, options: [String: Any]) -> Any? {
    switch mapper {
    case "feedThreadList":
      let data = dict(payload)
      return mapFeedThreadItems(threadList: data?["threadList"], userList: data?["userList"])
    case "userLike":
      return mapUserLikeData(payload)
    case "frsPage":
      return mapFrsPageData(
        payload,
        page: number(coalesce(options["page"], 1)),
        forumName: options["forumName"]
      )
    default:
      return nil
    }
  }

  /// 桥接入口专用：payload = TiebaSwiftProto.decode 的完整响应（含 error/data）。
  /// response 级 mapper（feedThreadList/userLike/frsPage）取 `data` 作为投影输入。
  /// 未知 mapper → nil（调用方按无数据处理）。
  public static func mapResponse(mapper: String, decoded: Any?, options: [String: Any]) -> Any? {
    switch mapper {
    case "feedThreadList", "userLike", "frsPage":
      let data = dict(decoded)?["data"]
      // frsPage 空 data 必须保留调用方 `if (!data) throw` 语义：不映射，返回 nil。
      if mapper == "frsPage", !truthy(data) { return nil }
      return map(mapper: mapper, payload: data ?? [:] as [String: Any], options: options)
    default:
      return nil
    }
  }

  // MARK: - 时间戳（helpers.ts:22 toMillis）

  /// 秒级 → 毫秒；已是毫秒（>= 1e11）原样；0/NaN/Infinity → 0。
  public static func toMillis(_ v: Double) -> Double {
    if v == 0 || v.isNaN || v.isInfinite { return 0 }
    return v >= 100_000_000_000 ? v : v * 1000
  }

  // MARK: - 响应错误检查（helpers.ts:59 assertProtoSuccess + interceptors.ts getTiebaError）

  /// 与 TS assertProtoSuccess(decoded) 等价：非零 error_code / 非法 code 时抛错。
  /// 消息与错误码生成规则逐行对齐 interceptors.getTiebaError（NOT_LOGIN 的
  /// 登出副作用留在 JS 侧 protoClient，保持 auth 语义在单一出处）。
  public static func assertProtoSuccess(_ decoded: Any?) throws {
    if let error = getTiebaError(decoded) { throw error }
  }

  static func getTiebaError(_ data: Any?) -> TiebaViewModelError? {
    // if (!data || typeof data !== 'object') return null;
    guard truthy(data), let obj = dict(data) else { return nil }

    let protoError = dict(obj["error"])
    let protoErrorCode = coalesce(protoError?["error_code"], protoError?["errorCode"])
    let rawErrorCode = coalesce(obj["error_code"], obj["errno"], obj["err_code"])
    let errorCode = number(coalesce(protoErrorCode, rawErrorCode, 0))
    if errorCode != 0 {
      let protoErrorMsg = coalesce(protoError?["error_msg"], protoError?["errorMsg"])
      // obj.error_msg ?? (typeof obj.error === 'string' ? obj.error : undefined) ?? obj.msg ?? protoErrorMsg
      let errorMsg = coalesce(obj["error_msg"], obj["error"] as? String, obj["msg"], protoErrorMsg)
      let message = errorMsg.map { str($0) } ?? "API error: \(jsNumberToString(errorCode))"
      return TiebaViewModelError(code: errorCode, message: message)
    }

    // const rawCode = obj.code; if (rawCode !== undefined && rawCode !== null) { ... }
    if let rawCode = obj["code"], !isNullish(rawCode) {
      let code = number(rawCode)
      if code != 0 && code != 1 {
        let msg = coalesce(obj["message"], obj["msg"])
        let message = msg.map { str($0) } ?? "API returned code: \(jsNumberToString(code))"
        return TiebaViewModelError(code: code, message: message)
      }
    }
    return nil
  }

  // MARK: - 广告判定（helpers.ts:220 / 232）

  /// `ala_info`（ThreadInfo 字段 113）在 wire 上存在（非 null）即广告/直播卡。
  public static func isAdThread(_ raw: Any?) -> Bool {
    guard truthy(raw), let rd = dict(raw) else { return false }
    return !isNullish(coalesce(rd["alaInfo"], rd["ala_info"]))
  }

  /// 已映射 ThreadInfo 的广告判定：带 isAd 标记直接命中，否则按原始键回退。
  /// TS 是 `t.isAd === true`（严格布尔），不能用 `=== 1` 的 strictOne 顶替。
  public static func isAdThreadInfo(_ t: Any?) -> Bool {
    guard truthy(t), let td = dict(t) else { return false }
    if let n = td["isAd"] as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID(), n.boolValue {
      return true
    }
    return isAdThread(t)
  }

  // MARK: - 媒体列表（helpers.ts:129 mapMediaList）

  public static func mapMediaList(_ raw: Any?) -> [[String: Any]] {
    // const list = [raw?.media, raw?.media_list].find(Array.isArray) ?? (Array.isArray(raw) ? raw : []);
    var list: [Any] = []
    if let rd = dict(raw) {
      // find(Array.isArray)：命中空数组也算命中（不再回退 media_list）。
      if let media = rd["media"] as? [Any] {
        list = media
      } else if let mediaList = rd["media_list"] as? [Any] {
        list = mediaList
      }
    } else if let arr = raw as? [Any] {
      list = arr
    }
    // 注意：raw 为 dict 但两个键都不是数组时，JS 的 find 返回 undefined，
    // 再回退 `Array.isArray(raw) ? raw : []` —— dict 不是数组 → []。已覆盖。

    var result: [[String: Any]] = []
    for item in list {
      // if (!m || typeof m !== 'object') continue;
      guard let m = dict(item) else { continue }

      let mediaType = str(coalesce(m["type"], ""))
      // 只有显式视频类型/字段才算视频（数字 type 1/2/3 是图片类型）。
      let isVideo = mediaType == "video"
        || truthy(coalesce(m["vsrc"], m["video_src"], m["videoSrc"], m["video"]))

      let src = toHttpsImgUrl(str(coalesce(
        m["bigPic"], m["big_pic"], m["bigSrc"], m["big_src"],
        m["srcPic"], m["src_pic"], m["src"],
        m["originPic"], m["origin_pic"], m["originSrc"], m["origin_src"], ""
      )))
      if src.isEmpty { continue }

      let smallRaw = str(coalesce(m["srcPic"], m["src_pic"], ""))
      let dynamicRaw = str(coalesce(m["dynamicPic"], m["dynamic_pic"], ""))
      let originRaw = str(coalesce(m["originPic"], m["origin_pic"], ""))
      let bigRaw = str(coalesce(m["bigPic"], m["big_pic"], ""))
      let srcRaw = str(coalesce(m["src"], ""))
      let isGif = hasGifSuffix("\(dynamicRaw) \(originRaw) \(bigRaw) \(srcRaw)")
      // 动图链：第一个带 .gif 后缀的 URL（dynamicPic > originPic > bigPic > src）。
      var gifChain = ""
      if isGif {
        for candidate in [dynamicRaw, originRaw, bigRaw, srcRaw] where hasGifSuffix(candidate) {
          gifChain = candidate
          break
        }
      }

      var out: [String: Any] = [:]
      out["type"] = isVideo ? "video" : "image"
      out["src"] = src

      // originSrc: toHttpsImgUrl(String(gifChain || (…))) || undefined
      let originCandidate = gifChain.isEmpty
        ? str(coalesce(m["originPic"], m["origin_pic"], m["originSrc"], m["origin_src"], m["bigPic"], m["big_pic"], ""))
        : gifChain
      let originSrc = toHttpsImgUrl(originCandidate)
      if !originSrc.isEmpty { out["originSrc"] = originSrc }

      // smallSrc: smallRaw && smallRaw !== String(m.bigPic ?? m.big_pic ?? '')
      let bigPicRaw = str(coalesce(m["bigPic"], m["big_pic"], ""))
      if !smallRaw.isEmpty && smallRaw != bigPicRaw {
        let small = toHttpsImgUrl(smallRaw)
        if !small.isEmpty { out["smallSrc"] = small }
      }

      // poster: String(m.poster ?? m.video_poster ?? m.videoPoster ?? '') || (isVideo ? src : undefined)
      let posterRaw = str(coalesce(m["poster"], m["video_poster"], m["videoPoster"], ""))
      if !posterRaw.isEmpty {
        out["poster"] = posterRaw
      } else if isVideo {
        out["poster"] = src
      }

      let width = number(coalesce(m["width"], 0))
      let height = number(coalesce(m["height"], 0))
      out["width"] = jsNumberOrNull((width == 0 || width.isNaN) ? 300 : width)
      out["height"] = jsNumberOrNull((height == 0 || height.isNaN) ? 300 : height)
      out["isLongPic"] = strictOne(coalesce(m["isLongPic"], m["is_long_pic"]))
      out["showOriginalBtn"] = strictOne(coalesce(m["showOriginalBtn"], m["show_original_btn"]))
      out["isGif"] = isGif
      if let duration = m["duration"], !isNullish(duration) {
        out["duration"] = jsNumberOrNull(number(duration))
      }
      result.append(out)
    }
    return result
  }

  // MARK: - 帖子（helpers.ts:239 mapProtoThread）

  /// raw 单个 thread 对象 → UI ThreadInfo。语义逐行对齐 mapProtoThread，
  /// `forum`/`userList`/`forumName` 对应 TS opts。
  public static func mapProtoThread(
    _ raw: Any?,
    forum: Any? = nil,
    userList: Any? = nil,
    forumName: Any? = nil
  ) -> [String: Any] {
    // if (!raw) return {};（0/''/false/null 同为 falsy）
    guard truthy(raw) else { return [:] }
    // 非对象 truthy 值在 JS 里属性读取全 undefined → 走默认值；dict 缺失时按空字典。
    let rd = dict(raw) ?? [:]

    let userMap = buildUserMap(userList, keyOf: { u in coalesce(u["id"], u["uid"], u["user_id"]) })
    let authorId = str(coalesce(rd["authorId"], rd["author_id"], dict(rd["author"])?["id"], ""))
    // raw.author 可能是"存在但为空对象 {}"（proto3 解码产物）：有键才用内嵌。
    let rawAuthor = nonEmptyDict(rd["author"])
    let author = rawAuthor ?? userMap[authorId] ?? [:]
    let forumDict = dict(forum) ?? [:]
    let forumInfo = dict(coalesce(rd["forumInfo"], rd["forum_info"]))
    let resolvedForumName = coalesce(
      forumName,
      rd["forumName"], rd["forum_name"],
      forumInfo?["name"],
      forumDict["name"],
      ""
    )!

    let abstractRaw = coalesce(rd["_abstract"], rd["abstract"])
    let abstract: String
    if let arr = abstractRaw as? [Any] {
      abstract = arr.map { element -> String in
        if let s = element as? String { return s }
        if let ed = dict(element) { return str(coalesce(ed["text"], ed["txt"], ed["content"], "")) }
        return ""
      }.joined()
    } else {
      abstract = str(coalesce(abstractRaw, ""))
    }

    let originRaw = coalesce(rd["originThreadInfo"], rd["origin_thread_info"])
    let mediaList = mapMediaList(rd)

    var out: [String: Any] = [:]
    out["id"] = str(coalesce(rd["id"], rd["threadId"], rd["thread_id"], ""))
    out["isAd"] = isAdThread(rd)
    out["threadId"] = str(coalesce(rd["threadId"], rd["thread_id"], rd["id"], ""))
    out["firstPostId"] = str(coalesce(rd["firstPostId"], rd["first_post_id"], ""))
    // 被推荐的那条回复（"回复了xxx"类卡片）：ThreadInfo.post_id(52) = 回复 pid。
    // 这类卡上 id(1) 不是帖子 id、threadId(2) 才是 —— 导航用 threadId + 这个 pid。
    out["postId"] = str(coalesce(rd["postId"], rd["post_id"], ""))
    out["title"] = coalesce(rd["title"], "")!
    out["forumId"] = str(coalesce(rd["forumId"], rd["forum_id"], rd["fid"], forumInfo?["id"], forumDict["id"], ""))
    out["forumName"] = jsOr(resolvedForumName, rd["fname"], "")!
    out["forumAvatar"] = coalesce(forumInfo?["avatar"], forumDict["avatar"], rd["forumAvatar"], rd["forum_avatar"], "")!
    out["authorId"] = authorId
    out["authorName"] = coalesce(author["name"], author["userName"], author["user_name"], "")!
    out["authorNameShow"] = coalesce(author["nameShow"], author["name_show"], author["showNickname"], author["show_nickname"], author["name"], "")!
    out["authorPortrait"] = coalesce(author["portrait"], "")!
    out["authorLevelId"] = jsNumberOrNull(number(coalesce(author["levelId"], author["level_id"], 0)))
    // authorIP 多源兜底（author.location.addr / 顶层 ip 键 / userMap 项同含 ip）。
    out["authorIP"] = coalesce(
      rd["ipLocation"], rd["ip_location"],
      author["ipLocation"], author["ip_location"],
      author["ipAddress"], author["ip_address"],
      dict(author["location"])?["addr"],
      author["ip"],
      ""
    )!
    out["replyNum"] = jsNumberOrNull(number(coalesce(rd["replyNum"], rd["reply_num"], 0)))
    out["viewNum"] = jsNumberOrNull(number(coalesce(rd["viewNum"], rd["view_num"], 0)))
    out["lastTime"] = jsNumberOrNull(toMillis(number(coalesce(rd["lastTimeInt"], rd["last_time_int"], rd["lastTime"], rd["last_time"], 0))))
    out["createTime"] = jsNumberOrNull(toMillis(number(coalesce(rd["createTime"], rd["create_time"], 0))))
    out["isTop"] = strictOne(coalesce(rd["isTop"], rd["is_top"], 0))
    out["isGood"] = strictOne(coalesce(rd["isGood"], rd["is_good"], 0))
    out["isVideo"] = strictOne(coalesce(rd["isVideo"], rd["is_video"], 0))
      || truthy(rd["videoInfo"]) || truthy(rd["video_info"])
      || mediaList.contains { ($0["type"] as? String) == "video" }
    out["mediaList"] = mediaList
    out["abstract"] = abstract
    out["zanNum"] = jsNumberOrNull(number(coalesce(
      rd["agreeNum"], rd["agree_num"],
      dict(rd["agree"])?["agreeNum"], dict(rd["agree"])?["agree_num"],
      0
    )))
    out["shareNum"] = jsNumberOrNull(number(coalesce(rd["shareNum"], rd["share_num"], 0)))
    out["hasAgree"] = strictOne(coalesce(
      dict(rd["agree"])?["hasAgree"], dict(rd["agree"])?["has_agree"],
      rd["hasAgree"], rd["has_agree"], 0
    ))
    out["isShareThread"] = strictOne(coalesce(rd["isShareThread"], rd["is_share_thread"], 0))
    if truthy(originRaw) {
      let od = dict(originRaw) ?? [:]
      out["originThreadInfo"] = [
        "title": coalesce(od["title"], "")!,
        "content": coalesce(od["content"], "")!,
        "forumName": coalesce(od["fname"], od["forumName"], "")!,
        "media": mapMediaList(originRaw),
      ] as [String: Any]
    }
    return out
  }

  // MARK: - feed.ts 纯投影（分页/吧头像回填/增量 Unix 状态留在 JS）

  /// `mapThreadItems`（feed.ts:82）：threadList × userList → FeedItem[]。
  public static func mapFeedThreadItems(threadList: Any?, userList: Any?) -> [[String: Any]] {
    let list = (threadList as? [Any]) ?? []
    let users = (userList as? [Any]) ?? []
    return list.map { t in
      ["type": "thread", "threadInfo": mapProtoThread(t, userList: users)] as [String: Any]
    }
  }

  /// `userLike` 的纯数据投影（feed.ts:221-242）：容器解包 + author 回退 + 类型标注。
  /// 返回 {items,pageTag,hasMore,requestUnix} —— lastRequestUnix 增量状态
  /// 仍是 JS 模块级变量，不在原生。
  public static func mapUserLikeData(_ data: Any?) -> [String: Any] {
    let dd = dict(data) ?? [:]
    let containers = (coalesce(dd["threadList"], dd["threadInfo"]) as? [Any]) ?? []
    var items: [[String: Any]] = []
    for container in containers {
      let cd = dict(container)
      let threadRaw = coalesce(cd?["threadList"], cd?["thread_list"], container)
      guard truthy(threadRaw), let tr = dict(threadRaw) else { continue }
      let tid = coalesce(tr["id"], tr["tid"], tr["thread_id"], tr["threadId"])
      if isNullish(tid) && isNullish(tr["title"]) { continue }
      let forum = coalesce(tr["forum"], cd?["forum"]) ?? [:]
      var merged = tr
      if let author = coalesce(tr["author"], cd?["author"]) {
        merged["author"] = author
      }
      let thread = mapProtoThread(merged, forum: forum)
      let type = truthy(thread["isVideo"]) ? "video_thread" : "thread"
      items.append(["type": type, "threadInfo": thread])
    }
    // hasMore: (data?.hasMore ?? 0) === 1；requestUnix: Number(data?.requestUnix ?? 0)
    return [
      "items": items,
      "pageTag": coalesce(dd["pageTag"], "")!,
      "hasMore": strictOne(coalesce(dd["hasMore"], 0)),
      "requestUnix": jsNumberOrNull(number(coalesce(dd["requestUnix"], 0))),
    ]
  }

  // MARK: - frsPage 页面投影（forumStore.ts 纯数据段）

  /// `forumStore.loadForumData()` 的纯数据段投影（零行为变化）。options:
  /// page / forumName。返回 {threads, hasMore, forum, rawIsLike, rawUserLevel,
  /// goodClassify, navTabInfo}；forum 仅在 page===1 且服务端下发 forum 时非空。
  /// tbs 持久化 / set() / 分桶 / 缓存兜底合并（mergeFollowedForumFallback）留在 JS。
  public static func mapFrsPageData(_ data: Any?, page: Double, forumName: Any?) -> [String: Any] {
    let dd = dict(data) ?? [:]
    let forumRaw = dd["forum"]
    let userList = dd["userList"]

    var forumOut: Any = NSNull()
    var rawIsLikeOut: Any?
    var rawUserLevelOut: Any?
    var goodClassify: [[String: Any]] = []
    var navTabInfoOut: Any = NSNull()

    if truthy(forumRaw), page == 1, let forumData = dict(forumRaw) {
      let signInContainer = dict(coalesce(forumData["signInInfo"], forumData["sign_in_info"]))
      let signInUserAny = coalesce(signInContainer?["userInfo"], signInContainer?["user_info"])
      let signInUser = dict(signInUserAny)
      let rawIsLike = coalesce(forumData["isLike"], forumData["is_like"])
      let rawUserLevel = coalesce(forumData["userLevel"], forumData["levelId"], forumData["level_id"])
      let parsedUserLevel = jsParseIntOrZero(str(coalesce(rawUserLevel, "0")))

      var detail: [String: Any] = [:]
      detail["forumId"] = str(coalesce(forumData["id"], ""))
      if let fn = coalesce(forumData["name"], forumName) { detail["forumName"] = fn }
      detail["avatar"] = coalesce(forumData["avatar"], "")!
      detail["memberCount"] = jsNumberOrNull(jsParseIntOrNaN(str(coalesce(forumData["memberNum"], forumData["member_num"], "0"))))
      detail["threadCount"] = jsNumberOrNull(jsParseIntOrNaN(str(coalesce(forumData["threadNum"], forumData["thread_num"], "0"))))
      detail["intro"] = coalesce(forumData["slogan"], forumData["intro"], "")!
      detail["isLike"] = isLikeFlag(rawIsLike)
      if parsedUserLevel > 0 { detail["levelId"] = jsNumberOrNull(parsedUserLevel) }
      if let levelName = coalesce(forumData["levelName"], forumData["level_name"]) { detail["levelName"] = levelName }
      detail["curScore"] = jsNumberOrNull(jsOrZero(jsParseFloatOrNaN(str(coalesce(forumData["curScore"], forumData["cur_score"], "0")))))
      detail["levelupScore"] = jsNumberOrNull(jsOrZero(jsParseFloatOrNaN(str(coalesce(forumData["levelupScore"], forumData["levelup_score"], "0")))))
      let anti = dict(dd["anti"])
      detail["tbs"] = coalesce(anti?["tbs"], forumData["tbs"], "")!
      // signInInfo: signInUser 为 truthy 才产出（非对象 truthy 时字段全按缺失默认，
      // 与 TS 属性读取 undefined 的默认链一致）。
      if truthy(signInUserAny) {
        detail["signInInfo"] = [
          "isSignIn": strictOne(coalesce(signInUser?["isSignIn"], signInUser?["is_sign_in"])),
          "contSignNum": jsNumberOrNull(jsParseIntOrNaN(str(coalesce(signInUser?["contSignNum"], signInUser?["cont_sign_num"], "0")))),
          "userSignRank": jsNumberOrNull(jsParseIntOrNaN(str(coalesce(signInUser?["userSignRank"], signInUser?["user_sign_rank"], "0")))),
          "signBonusPoint": jsNumberOrNull(jsParseIntOrNaN(str(coalesce(signInUser?["signBonusPoint"], signInUser?["sign_bonus_point"], "0")))),
        ] as [String: Any]
      }
      forumOut = detail
      if let rawIsLike { rawIsLikeOut = rawIsLike }
      if let rawUserLevel { rawUserLevelOut = rawUserLevel }
      // goodClassify：`.map` 对非数组会抛（畸形输入）——原生按空数组处理（登记差异）。
      let classifyRaw = coalesce(forumData["goodClassify"], forumData["good_classify"])
      if let classifyArr = classifyRaw as? [Any] {
        goodClassify = classifyArr.compactMap { element -> [String: Any]? in
          guard let c = dict(element) else { return nil }
          return [
            "classId": str(coalesce(c["classId"], c["class_id"], c["id"], "")),
            "className": str(coalesce(c["className"], c["class_name"], c["name"], "")),
          ]
        }
      }
      // navTabInfo: data.navTabInfo ?? null（原样透传）。
      navTabInfoOut = coalesce(dd["navTabInfo"]) ?? NSNull()
    }

    // threads: mapProtoThread ×N + `!t.isAd` 过滤（ala_info 广告/直播剔除）。
    var threads: [[String: Any]] = []
    if let rawThreadList = dd["threadList"] as? [Any] {
      for item in rawThreadList {
        let t = mapProtoThread(item, forum: forumRaw, userList: userList, forumName: forumName)
        if !truthy(t["isAd"]) { threads.append(t) }
      }
    }

    // hasMore = pageData ? (pageData.hasMore === 1) : (threads.length >= 20)；
    // pageData 为 truthy 非对象时 TS 读属性得 undefined → false，等价。
    let hasMore: Bool
    if truthy(dd["page"]) {
      hasMore = strictOne(dict(dd["page"])?["hasMore"])
    } else {
      hasMore = threads.count >= 20
    }

    var out: [String: Any] = [:]
    out["threads"] = threads
    out["hasMore"] = hasMore
    out["forum"] = forumOut
    if let rawIsLikeOut { out["rawIsLike"] = rawIsLikeOut }
    if let rawUserLevelOut { out["rawUserLevel"] = rawUserLevelOut }
    out["goodClassify"] = goodClassify
    out["navTabInfo"] = navTabInfoOut
    return out
  }

  // MARK: - JS 语义 helpers（内部）

  /// JS 的 nullish（undefined/null → true）；[String: Any] 里 undefined 不可表达，
  /// NSNull 即 wire/null 两态的统一表示。
  static func isNullish(_ v: Any?) -> Bool {
    guard let v else { return true }
    return v is NSNull
  }

  /// JS `a ?? b ?? c ?? fallback`，返回首个非 nullish 值。
  static func coalesce(_ values: Any?...) -> Any? {
    for value in values where !isNullish(value) { return value }
    return nil
  }

  /// JS `a || b || fallback`：取首个 truthy；全 falsy 时返回最后一个操作数
  /// （JS 语义不是 undefined —— `'' || '' || ''` 结果仍是 `''`）。
  static func jsOr(_ values: Any?...) -> Any? {
    var last: Any?
    for value in values {
      last = value
      if truthy(value) { return value }
    }
    return last
  }

  /// JS 真值表：nullish/''/0/NaN/false → false，其余 → true。
  static func truthy(_ v: Any?) -> Bool {
    guard let v, !(v is NSNull) else { return false }
    if let n = v as? NSNumber {
      if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
      let d = n.doubleValue
      return d != 0 && !d.isNaN
    }
    if let s = v as? String { return !s.isEmpty }
    return true
  }

  /// JS `x === 1`：布尔 true 不算（true !== 1），字符串 "1" 也不算。
  static func strictOne(_ v: Any?) -> Bool {
    guard let v, !(v is NSNull), let n = v as? NSNumber else { return false }
    if CFGetTypeID(n) == CFBooleanGetTypeID() { return false }
    return n.doubleValue == 1
  }

  /// JS `String(v)`（调用点均先 `?? ''`，故 nullish → ""）。
  static func str(_ v: Any?) -> String {
    guard let v, !(v is NSNull) else { return "" }
    if let s = v as? String { return s }
    if let n = v as? NSNumber {
      if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
      // 整型 NSNumber 用 stringValue 保 int64 精度；浮点走 JS Number→String 规则。
      let d = n.doubleValue
      if !d.isNaN && !d.isInfinite && d == d.rounded() && abs(d) < 9_007_199_254_740_992 {
        return String(Int64(d))
      }
      return jsNumberToString(d)
    }
    if let a = v as? [Any] {
      // JS String([1,2]) === "1,2"；嵌套数组递归展开，nullish → ""。
      return a.map { element -> String in
        if let nested = element as? [Any] { return str(nested) }
        return str(element)
      }.joined(separator: ",")
    }
    if v is [String: Any] { return "[object Object]" }
    return String(describing: v)
  }

  /// JS `Number(v)`：null → 0，布尔 → 0/1，字符串按 ToNumber 规则，其余 NaN。
  static func number(_ v: Any?) -> Double {
    guard let v, !(v is NSNull) else { return 0 }
    if let n = v as? NSNumber { return n.doubleValue }
    if let s = v as? String { return jsToNumber(s) }
    if let a = v as? [Any] {
      if a.isEmpty { return 0 }
      if a.count == 1 { return number(a[0]) }
      return .nan
    }
    return .nan
  }

  /// JS Number("…")：trim → 空串 0 / Infinity / 0x 十六进制 / 十进制字面量。
  static func jsToNumber(_ raw: String) -> Double {
    let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.isEmpty { return 0 }
    if s == "Infinity" || s == "+Infinity" { return .infinity }
    if s == "-Infinity" { return -.infinity }
    var body = Substring(s)
    var sign = 1.0
    if body.hasPrefix("+") { body = body.dropFirst() }
    else if body.hasPrefix("-") { sign = -1; body = body.dropFirst() }
    if body.hasPrefix("0x") || body.hasPrefix("0X") {
      let hex = String(body.dropFirst(2))
      if !hex.isEmpty, let v = UInt64(hex, radix: 16) { return sign * Double(v) }
      return .nan
    }
    return Double(s) ?? .nan
  }

  /// JS parseInt(s, 10)：允许前导空白与正负号，读到非数字停止；无数字 → nil（NaN）。
  static func parseInt(_ raw: String) -> Double? {
    let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    var idx = s.startIndex
    var sign = 1.0
    if idx < s.endIndex, s[idx] == "+" { idx = s.index(after: idx) }
    else if idx < s.endIndex, s[idx] == "-" { sign = -1; idx = s.index(after: idx) }
    var digits = ""
    while idx < s.endIndex, s[idx].isNumber, s[idx].isASCII {
      digits.append(s[idx])
      idx = s.index(after: idx)
    }
    guard !digits.isEmpty, let v = Double(digits) else { return nil }
    return sign * v
  }

  /// JS `parseInt(s, 10) || 0`（无数字 → 0）。
  static func jsParseIntOrZero(_ raw: String) -> Double { parseInt(raw) ?? 0 }

  /// JS `parseInt(s, 10)`，NaN 保留（JSON round-trip 后为 null）。
  static func jsParseIntOrNaN(_ raw: String) -> Double { parseInt(raw) ?? .nan }

  /// JS `parseFloat(s)`：允许前导空白/正负号/小数点/指数，取最长合法前缀；
  /// 无数字 → NaN（.5 / 5. 与 JS 同义）。
  static func jsParseFloatOrNaN(_ raw: String) -> Double {
    let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.isEmpty { return .nan }
    var idx = s.startIndex
    var sign = 1.0
    if idx < s.endIndex, s[idx] == "+" { idx = s.index(after: idx) }
    else if idx < s.endIndex, s[idx] == "-" { sign = -1; idx = s.index(after: idx) }
    if idx < s.endIndex, s[idx...].hasPrefix("Infinity") { return sign * .infinity }
    var intPart = ""
    while idx < s.endIndex, s[idx].isNumber, s[idx].isASCII {
      intPart.append(s[idx]); idx = s.index(after: idx)
    }
    var fracPart = ""
    var sawDot = false
    if idx < s.endIndex, s[idx] == "." {
      sawDot = true
      idx = s.index(after: idx)
      while idx < s.endIndex, s[idx].isNumber, s[idx].isASCII {
        fracPart.append(s[idx]); idx = s.index(after: idx)
      }
    }
    if intPart.isEmpty && fracPart.isEmpty { return .nan }
    var mantissa = intPart.isEmpty ? "0" : intPart
    if sawDot { mantissa += "." + (fracPart.isEmpty ? "0" : fracPart) }
    guard var value = Double(mantissa) else { return .nan }
    if idx < s.endIndex, s[idx] == "e" || s[idx] == "E" {
      var j = s.index(after: idx)
      var expSign = 1.0
      if j < s.endIndex, s[j] == "+" { j = s.index(after: j) }
      else if j < s.endIndex, s[j] == "-" { expSign = -1; j = s.index(after: j) }
      var expDigits = ""
      while j < s.endIndex, s[j].isNumber, s[j].isASCII {
        expDigits.append(s[j]); j = s.index(after: j)
      }
      if !expDigits.isEmpty, let e = Double(expDigits) {
        value *= pow(10, expSign * e)
      }
    }
    return sign * value
  }

  /// JS `x || 0`（NaN → 0；0 → 0；Infinity 原样；负数原样）。
  static func jsOrZero(_ d: Double) -> Double { d.isNaN ? 0 : d }

  /// JS `v === 1 || v === '1' || v === true`（forum.is_like 判定；true !== 1）。
  static func isLikeFlag(_ v: Any?) -> Bool {
    if strictOne(v) { return true }
    if let s = v as? String, s == "1" { return true }
    if let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
    return false
  }

  /// JS Number→String 的常用分支（最短往返；整数不带 .0）。
  static func jsNumberToString(_ d: Double) -> String {
    if d.isNaN { return "NaN" }
    if d.isInfinite { return d > 0 ? "Infinity" : "-Infinity" }
    if d == 0 { return "0" }
    if d == d.rounded() && abs(d) < 1e15 { return String(Int64(d)) }
    return String(d)
  }

  /// NaN/Infinity 在 JSON.stringify 里是 null —— 原生以 NSNull 表达，跨桥后一致。
  static func jsNumberOrNull(_ d: Double) -> Any {
    if d.isNaN || d.isInfinite { return NSNull() }
    return NSNumber(value: d)
  }

  /// JSON.stringify 里 undefined 键缺席；这里用 Optional 表示键缺席。
  static func dict(_ v: Any?) -> [String: Any]? {
    guard let v, !(v is NSNull) else { return nil }
    return v as? [String: Any]
  }

  /// `obj && typeof obj === 'object' && Object.keys(obj).length > 0` 的 dict 版本。
  static func nonEmptyDict(_ v: Any?) -> [String: Any]? {
    guard let d = dict(v), !d.isEmpty else { return nil }
    return d
  }

  /// helpers.buildUserMap：keyOf 输出为空串的条目不进 map；重复键后者覆盖。
  static func buildUserMap(_ userList: Any?, keyOf: ([String: Any]) -> Any?) -> [String: [String: Any]] {
    var map: [String: [String: Any]] = [:]
    guard let list = userList as? [Any] else { return map }
    for element in list {
      guard let u = dict(element) else { continue }
      let uid = str(coalesce(keyOf(u), ""))
      if !uid.isEmpty { map[uid] = u }
    }
    return map
  }

  /// thumbnailUrl(url, THUMB_LIST=360)：http:// 与 // 协议相对 → https，
  /// 本地 URI/其余原样（width 只作 >0 守卫，CDN 尺寸注入已停用）。
  /// ⚠️ 复刻 JS 的不对称：升级判据 startsWith 是**大小写敏感**的（只认小写
  /// "http://" 与 "//"），而 replace 是 /i 的 —— "HTTP://x" 原样保留。
  static func toHttpsImgUrl(_ url: String) -> String {
    if url.isEmpty { return url }
    if url.hasPrefix("http://") {
      return "https://" + url.dropFirst("http://".count)
    }
    if url.hasPrefix("//") { return "https://" + url.dropFirst(2) }
    return url
  }

  /// `/\.gif(?:\?|#|$)/i`。
  static func hasGifSuffix(_ s: String) -> Bool {
    let lower = s.lowercased()
    var searchStart = lower.startIndex
    while let range = lower.range(of: ".gif", range: searchStart..<lower.endIndex) {
      let after = range.upperBound
      if after == lower.endIndex { return true }
      let ch = lower[after]
      if ch == "?" || ch == "#" { return true }
      searchStart = after
    }
    return false
  }

  // MARK: - 表情（constants/emoticons.ts）

  static let emoticonNameMap: [String: Int] = [
    "呵呵": 1, "哈哈": 2, "吐舌": 3, "啊": 4, "酷": 5, "怒": 6,
    "开心": 7, "汗": 8, "泪": 9, "黑线": 10, "鄙视": 11, "不高兴": 12,
    "真棒": 13, "钱": 14, "疑问": 15, "阴险": 16, "吐": 17, "咦": 18,
    "委屈": 19, "花心": 20, "呼~": 21, "笑眼": 22, "笑脸": 22, "冷": 23, "太开心": 24,
    "滑稽": 25, "勉强": 26, "狂汗": 27, "乖": 28, "睡觉": 29, "惊哭": 30,
    "生气": 31, "惊讶": 32, "喷": 33, "爱心": 34, "心碎": 35, "玫瑰": 36,
    "礼物": 37, "彩虹": 38, "星星月亮": 39, "太阳": 40, "钱币": 41,
    "灯泡": 42, "茶杯": 43, "蛋糕": 44, "音乐": 45, "haha": 46,
    "胜利": 47, "大拇指": 48, "弱": 49, "OK": 50,
  ]

  static func emoticonNumber(named name: String) -> Int? {
    emoticonNameMap[name]
  }

  /// text === "image_emoticon{N}"（正则 + parseInt 等价）。
  static func imageEmoticonNumber(_ text: String) -> Int? {
    let prefix = "image_emoticon"
    guard text.hasPrefix(prefix) else { return nil }
    let digits = String(text.dropFirst(prefix.count))
    guard !digits.isEmpty, digits.allSatisfy({ $0.isNumber && $0.isASCII }) else { return nil }
    return Int(digits)
  }

  static func buildEmoticonSrc(_ num: Int) -> String {
    "https://tb1.bdstatic.com/tb/editor/images/client/image_emoticon\(num).png"
  }
}
