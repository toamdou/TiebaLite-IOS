import Foundation

enum TiebaProtoError: LocalizedError {
  case invalidDescriptor
  case messageNotFound(String)
  case invalidPayload(String)
  case invalidWire(String)

  var errorDescription: String? {
    switch self {
    case .invalidDescriptor:
      return "Invalid protobuf descriptor JSON"
    case .messageNotFound(let path):
      return "Protobuf message not found: \(path)"
    case .invalidPayload(let reason):
      return "Invalid protobuf payload: \(reason)"
    case .invalidWire(let reason):
      return "Invalid protobuf wire data: \(reason)"
    }
  }
}

struct TiebaProtoField {
  let name: String
  let id: Int
  let type: String
  let repeated: Bool
  let protoName: String
}

struct TiebaProtoMessage {
  let path: String
  let fields: [Int: TiebaProtoField]
  /// name → field 索引。walk() 一次性构建（initialize 时），
  /// 投影器 project() 按名查字段直接用，不再每消息重建。
  let fieldByName: [String: TiebaProtoField]
}

final class TiebaProtoRegistry {
  static let shared = TiebaProtoRegistry()

  private var root: [String: Any] = [:]
  private var messages: [String: TiebaProtoMessage] = [:]
  private var resolveCache: [String: ResolveResult] = [:]
  private let resolveLock = NSLock()

  private enum ResolveResult {
    case message(TiebaProtoMessage)
    case notFound
  }

  func initialize(json: String) throws {
    guard
      let data = json.data(using: .utf8),
      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      throw TiebaProtoError.invalidDescriptor
    }
    root = object
    messages = [:]
    resolveCache = [:]
    try walk(object, path: "")
  }

  private func walk(_ object: [String: Any], path: String) throws {
    guard let nested = object["nested"] as? [String: Any] else { return }
    for (key, value) in nested {
      let fullPath = path.isEmpty ? key : "\(path).\(key)"
      guard let child = value as? [String: Any] else { continue }
      if let rawFields = child["fields"] as? [String: Any] {
        var fields: [Int: TiebaProtoField] = [:]
        for (fieldName, raw) in rawFields {
          guard
            let field = raw as? [String: Any],
            let id = field["id"] as? NSNumber
          else {
            continue
          }
          fields[id.intValue] = TiebaProtoField(
            name: fieldName,
            id: id.intValue,
            type: field["type"] as? String ?? "string",
            repeated: (field["rule"] as? String) == "repeated",
            protoName: field["protoName"] as? String ?? fieldName
          )
        }
        var fieldsByName: [String: TiebaProtoField] = [:]
        for field in fields.values {
          fieldsByName[field.name] = field
        }
        messages[fullPath] = TiebaProtoMessage(path: fullPath, fields: fields, fieldByName: fieldsByName)
      }
      try walk(child, path: fullPath)
    }
  }

  func message(path: String) throws -> TiebaProtoMessage {
    guard let message = messages[path] else {
      throw TiebaProtoError.messageNotFound(path)
    }
    return message
  }

  func resolveMessage(typeName: String, currentPath: String) throws -> TiebaProtoMessage {
    let trimmed = typeName.hasPrefix(".") ? String(typeName.dropFirst()) : typeName
    // Absolute paths are already unique; relative names depend on the namespace.
    let key = trimmed.contains(".") ? trimmed : "\(currentPath)|\(trimmed)"

    resolveLock.lock()
    let cached = resolveCache[key]
    resolveLock.unlock()
    if let cached {
      switch cached {
      case .message(let message):
        return message
      case .notFound:
        throw TiebaProtoError.messageNotFound(trimmed)
      }
    }

    do {
      let resolved: TiebaProtoMessage
      if trimmed.contains(".") {
        resolved = try message(path: trimmed)
      } else {
        resolved = try resolveRelative(typeName: trimmed, currentPath: currentPath)
      }
      cache(key, .message(resolved))
      return resolved
    } catch {
      // Negative results are cached too: string/bytes fields probe resolveMessage
      // on every length-delimited read, and repeating the namespace fallback scan
      // on every miss is the hottest decode path.
      cache(key, .notFound)
      throw error
    }
  }

  private func cache(_ key: String, _ result: ResolveResult) {
    resolveLock.lock()
    resolveCache[key] = result
    resolveLock.unlock()
  }

  private func resolveRelative(typeName: String, currentPath: String) throws -> TiebaProtoMessage {
    var namespace = currentPath
    while true {
      let candidate = namespace.isEmpty ? typeName : "\(namespace).\(typeName)"
      if let message = messages[candidate] {
        return message
      }
      guard let dot = namespace.lastIndex(of: ".") else { break }
      namespace = String(namespace[..<dot])
    }
    if let message = messages[typeName] {
      return message
    }
    throw TiebaProtoError.messageNotFound(typeName)
  }
}

// 编码已整体迁移到 JS 侧 protobufjs（src/services/api/proto.ts，嵌套 message
// 正确平铺，绕开原生编码器结构错乱 bug）；原生编码器 TiebaProtoEncoder 及其
// 全部私有方法已于 2026-08-25 删除（仓库内零引用，见 TiebaNativeModule.swift
// 桥函数裁剪）。这里只保留解码 + 投影。

final class TiebaProtoDecoder {
  private let registry: TiebaProtoRegistry
  private var data = Data()
  private var index = 0
  // Exclusive end of the currently decoded message window. Nested messages
  // narrow this instead of copying subdata / allocating a new decoder.
  private var windowEnd = 0

  init(registry: TiebaProtoRegistry = .shared) {
    self.registry = registry
  }

  func decode(messagePath: String, bytes: Data) throws -> [String: Any] {
    return try decode(messagePath: messagePath, data: bytes, from: 0, to: bytes.count)
  }

  // Shared entry point: top-level calls get the full buffer; nested messages
  // reuse this instance with a narrowed window, avoiding subdata copies and
  // per-level decoder allocation.
  func decode(messagePath: String, data bytes: Data, from start: Int, to end: Int) throws -> [String: Any] {
    let message = try registry.message(path: messagePath)
    let savedData = data
    let savedIndex = index
    let savedWindowEnd = windowEnd
    data = bytes
    index = start
    windowEnd = end
    var result: [String: Any] = [:]

    while index < windowEnd {
      guard let key = try readVarint() else { break }
      let fieldId = Int(key >> 3)
      let wireType = Int(key & 0x07)
      guard let field = message.fields[fieldId] else {
        try skip(wireType: wireType)
        continue
      }

      if field.repeated {
        if isPackedField(field, wireType: wireType, messagePath: messagePath) {
          let values = try readPacked(field: field, messagePath: messagePath)
          result[field.name] = (result[field.name] as? [Any] ?? []) + values
        } else {
          let value = try read(field: field, wireType: wireType, messagePath: messagePath)
          result[field.name] = (result[field.name] as? [Any] ?? []) + [value]
        }
      } else {
        result[field.name] = try read(field: field, wireType: wireType, messagePath: messagePath)
      }
    }

    // 状态恢复仅发生在此（成功路径末尾）。中途 throw（非法 wire 数据、
    // 嵌套 decode 失败）时不回滚：解码器实例与单次 decode 生命周期绑定
    // ——嵌套消息复用同一实例推进 index，任何一层 throw 都会一路向上传播，
    // 调用方必然丢弃该实例，不存在"继续用坏状态解码"的路径，故无需回滚。
    data = savedData
    index = savedIndex
    windowEnd = savedWindowEnd
    return omitDefaults(result)
  }

  private func readVarint() throws -> UInt64? {
    guard index < windowEnd else { return nil }
    var result: UInt64 = 0
    var shift: UInt64 = 0
    while index < windowEnd {
      if shift >= 64 {
        throw TiebaProtoError.invalidWire("varint too long")
      }
      let byte = data[index]
      index += 1
      result |= UInt64(byte & 0x7f) << shift
      if byte & 0x80 == 0 {
        return result
      }
      shift += 7
    }
    throw TiebaProtoError.invalidWire("truncated varint")
  }

  private func readLength() throws -> Int {
    guard let length = try readVarint() else {
      throw TiebaProtoError.invalidWire("missing length")
    }
    guard length <= UInt64(windowEnd - index) else {
      throw TiebaProtoError.invalidWire("length exceeds payload")
    }
    return Int(length)
  }

  private func read(field: TiebaProtoField, wireType: Int, messagePath: String) throws -> Any {
    switch wireType {
    case 0:
      guard let raw = try readVarint() else {
        throw TiebaProtoError.invalidWire("missing varint")
      }
      return scalar(fromVarint: raw, type: field.type)
    case 1:
      return fixed64(from: try readFixedBytes(width: 8, error: "missing fixed64"), type: field.type)
    case 2:
      let length = try readLength()
      let sliceStart = index
      index += length
      if let nestedMessage = try? registry.resolveMessage(typeName: field.type, currentPath: messagePath) {
        // Reuse this instance: narrower window, no subdata copy, no decoder churn.
        return try decode(messagePath: nestedMessage.path, data: data, from: sliceStart, to: sliceStart + length)
      }
      let slice = data.subdata(in: sliceStart..<(sliceStart + length))
      if field.type == "string" {
        return String(data: slice, encoding: .utf8) ?? ""
      }
      if field.type == "bytes" {
        return slice.base64EncodedString()
      }
      throw TiebaProtoError.invalidWire("unexpected length-delimited field \(field.type)")
    case 5:
      return fixed32(from: try readFixedBytes(width: 4, error: "missing fixed32"), type: field.type)
    default:
      throw TiebaProtoError.invalidWire("unsupported wire type \(wireType)")
    }
  }

  private func readFixedBytes(width: Int, error reason: String) throws -> Data {
    guard index + width <= windowEnd else {
      throw TiebaProtoError.invalidWire(reason)
    }
    defer { index += width }
    return data.subdata(in: index..<(index + width))
  }

  private func isPackedField(_ field: TiebaProtoField, wireType: Int, messagePath: String) -> Bool {
    guard field.repeated, wireType == 2 else { return false }
    return !["string", "bytes"].contains(field.type) &&
      (try? registry.resolveMessage(typeName: field.type, currentPath: messagePath)) == nil
  }

  private func readPacked(field: TiebaProtoField, messagePath: String) throws -> [Any] {
    let length = try readLength()
    let end = index + length
    var values: [Any] = []
    while index < end {
      let wireType = packedWireType(for: field.type)
      values.append(try read(field: field, wireType: wireType, messagePath: messagePath))
    }
    return values
  }

  private func packedWireType(for type: String) -> Int {
    switch type {
    case "double", "fixed64", "sfixed64":
      return 1
    case "float", "fixed32", "sfixed32":
      return 5
    default:
      return 0
    }
  }

  private func scalar(fromVarint raw: UInt64, type: String) -> Any {
    switch type {
    case "bool":
      return raw != 0
    case "int32":
      return Int32(truncatingIfNeeded: raw)
    case "int64":
      return Int64(bitPattern: raw)
    case "uint32":
      return UInt32(truncatingIfNeeded: raw)
    case "uint64":
      return raw
    case "sint32":
      return zigZagDecode32(UInt32(truncatingIfNeeded: raw))
    case "sint64":
      return zigZagDecode64(raw)
    default:
      return Int64(bitPattern: raw)
    }
  }

  private func fixed64(from slice: Data, type: String) -> Any {
    let value = slice.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
    switch type {
    case "double":
      return Double(bitPattern: value)
    case "sfixed64":
      return Int64(bitPattern: value)
    default:
      return value
    }
  }

  private func fixed32(from slice: Data, type: String) -> Any {
    let value = slice.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    switch type {
    case "float":
      return Float(bitPattern: value)
    case "sfixed32":
      return Int32(bitPattern: value)
    default:
      return value
    }
  }

  private func zigZagDecode32(_ value: UInt32) -> Int32 {
    return Int32(bitPattern: (value >> 1) ^ UInt32(bitPattern: -(Int32(bitPattern: value) & 1)))
  }

  private func zigZagDecode64(_ value: UInt64) -> Int64 {
    return Int64(bitPattern: (value >> 1) ^ UInt64(bitPattern: -(Int64(bitPattern: value) & 1)))
  }

  private func skip(wireType: Int) throws {
    switch wireType {
    case 0:
      _ = try readVarint()
    case 1:
      index += 8
    case 2:
      let length = try readLength()
      index += length
    case 5:
      index += 4
    case 3:
      while true {
        guard let key = try readVarint() else {
          throw TiebaProtoError.invalidWire("unterminated group")
        }
        if Int(key & 0x07) == 4 { break }
        try skip(wireType: Int(key & 0x07))
      }
    case 4:
      throw TiebaProtoError.invalidWire("unexpected end group")
    default:
      throw TiebaProtoError.invalidWire("unsupported skip wire type \(wireType)")
    }
  }

  private func omitDefaults(_ object: [String: Any]) -> [String: Any] {
    var result = object
    var removeKeys: [String] = []
    for (key, value) in object {
      if let array = value as? [Any] {
        if array.isEmpty { removeKeys.append(key) }
      } else if let dictionary = value as? [String: Any] {
        // Prune nested messages in place; empty nested dicts are kept so the
        // shape returned to JS is byte-for-byte the same as before.
        result[key] = omitDefaults(dictionary)
      } else if isDefault(value) {
        removeKeys.append(key)
      }
    }
    for key in removeKeys {
      result.removeValue(forKey: key)
    }
    return result
  }

  private func isDefault(_ value: Any) -> Bool {
    if let number = value as? NSNumber {
      if CFGetTypeID(number) == CFBooleanGetTypeID() {
        return !number.boolValue
      }
      return number.doubleValue == 0
    }
    if let string = value as? String {
      return string.isEmpty
    }
    if let data = value as? Data {
      return data.isEmpty
    }
    return false
  }
}

/// Post-decode field projection ("响应映射下沉 — 投影裁剪").
///
/// After a response is decoded into a full `[String: Any]` tree, we prune every
/// message down to the fields the JS render layer actually reads, before the
/// JSON string is serialized and crossed over the bridge. This kills the
/// "full payload over the bridge twice" cost: only render-relevant data ever
/// leaves native, so the JS heap only ever holds one (projected) copy.
///
/// Contract with `src/services/api/endpoints/helpers.ts`:
///   - Field names are the descriptor camelCase names the decoder produces, so
///     helpers reads (`raw.field ?? raw.field_name`) resolve identically.
///   - The heavy pruning helpers already perform is mirrored here:
///       * ThreadInfo.firstPostContent is dropped (no UI reads it).
///       * Post.subPostList → SubPost.subPostList is capped to the first 3
///         (helpers keeps `slice(0, 3)` as a no-op guard).
///   - `toMillis` / `isDisagree` / subPosts slicing semantics are NOT moved
///     into Swift; they stay in helpers unchanged.
///   - Message types not listed in the whitelist keep all their fields
///     (safe default) — the table only targets the heavy/shared types.
final class TiebaProtoProjector {
  static let shared = TiebaProtoProjector()

  private let registry: TiebaProtoRegistry

  /// Message path → allowed field names. Keys are the exact full message paths
  /// used by `protoPost`'s responseType and the shared types nested inside.
  private let whitelists: [String: Set<String>] = [
    // ---- shared render types ----
    "tieba.ThreadInfo": [
      "id", "threadId", "title", "replyNum", "viewNum", "lastTimeInt", "lastTime",
      "createTime", "isTop", "isGood", "authorId", "forumId",
      "forumName", "media", "_abstract", "agreeNum", "agree", "shareNum",
      "isShareThread", "originThreadInfo", "author", "videoInfo", "firstPostId",
      "tabId", "tabName", "hotNum",
      // 广告/直播贴判据（对齐 Kotlin `.filter { it.ala_info == null }`）。
      // 漏配时投影器剥掉该字段，JS 侧全部 isAd 过滤结构性失效。
      "alaInfo",
    ],
    "tieba.Post": [
      "id", "tid", "floor", "time", "timeEx", "authorId", "author", "content",
      "subPostNumber", "subPostList", "agree",
    ],
    "tieba.SubPost": ["pid", "subPostList"],
    "tieba.SubPostList": [
      "id", "content", "time", "authorId", "author", "agree", "location",
    ],
    "tieba.PbContent": [
      "type", "text", "link", "src", "bsize", "bigSrc", "cdnSrc", "bigCdnSrc",
      "originSrc", "c", "uid", "duringTime", "width", "height", "cdnSrcActive",
      "voiceMD5",
    ],
    "tieba.User": [
      "id", "name", "nameShow", "portrait", "levelId", "levelName",
      "sex", "gender", "intro", "fansNum", "concernNum", "postNum", "threadNum",
      "myLikeNum", "totalAgreeNum", "ipAddress", "ip", "tbAge", "isBawu",
      "tiebaUid", "hasConcerned", "bazhuGrade", "newGodData",
    ],
    "tieba.Media": ["type", "bigPic", "srcPic", "originPic", "width", "height"],
    "tieba.Abstract": ["type", "text", "link", "src"],
    "tieba.Agree": ["agreeNum", "hasAgree", "disagreeNum", "diffAgreeNum"],
    "tieba.Page": ["currentPage", "totalPage", "totalCount", "hasMore"],
    "tieba.Error": ["errorCode", "errorMsg", "userMsg"],
    "tieba.ForumInfo": [
      "id", "name", "avatar", "memberNum", "threadNum", "postNum", "slogan",
      "isLike", "userLevel", "levelName", "curScore", "levelupScore",
      "signInInfo", "goodClassify",
    ],
    "tieba.SimpleForum": ["id", "name", "avatar", "memberNum", "postNum"],
    "tieba.ForumSignInfo": ["userInfo"],
    "tieba.ForumSignUser": ["isSignIn", "contSignNum", "userSignRank", "signBonusPoint"],
    "tieba.ForumClassify": ["name", "id", "classId", "className"],
    "tieba.FrsTabInfo": [
      "tabId", "tabType", "tabName", "tabUrl", "tabGid", "tabTitle",
      "isGeneralTab", "tabCode", "isDefault",
    ],
    "tieba.frsPage.NavTabInfo": ["tab", "menu", "head"],
    "tieba.OriginThreadInfo": ["title", "content", "media", "fname"],
    // 用户主页 userPost：缺 media/作者/统计字段会致帖卡图片、作者行全空
    //（mapProtoThread 读 raw.media / raw.userName 等；userPost 每页 20 条不裁性能）。
    // postId（proto post_id=3）必须保留：回复帖没有独立 thread_id，缺 postId 时
    // JS 侧 id 恒回退到 threadId → 同一主题下所有回复 key 相同 → FlashList 只渲染
    // 1 个 cell（key 退化，2026-08-25 修复：白名单补回 postId）。
    "tieba.PostInfoList": [
      "threadId", "postId", "forumId", "title", "content", "replyNum", "forumName", "createTime",
      "media", "videoInfo", "agreeNum", "agree", "shareNum", "viewNum",
      "userName", "userPortrait", "userId", "nameShow", "_abstract",
      "isShareThread", "originThreadInfo",
    ],
    "tieba.PostInfoContent": ["postContent", "postType"],
    "tieba.BazhuSign": ["desc"],
    "tieba.NewGodInfo": ["status", "fieldName"],
    "tieba.Anti": ["tbs"],
    "tieba.getDislikeList.ForumList": ["forumId", "forumName", "avatar", "memberCount", "postNum", "threadNum"],
    // ---- response data messages ----
    "tieba.hotThreadList.HotThreadListResponseData": ["topicList", "threadInfo", "hotThreadTabInfo"],
    "tieba.topicList.TopicListResponseData": ["topicBang", "topicManual", "mediaTopic", "tabList", "frsTabTopic", "topicList"],
    "tieba.pbPage.PbPageResponseData": ["thread", "postList", "userList", "page", "forum", "anti", "firstFloorPost"],
    "tieba.pbFloor.PbFloorResponseData": ["subpostList", "page", "thread", "forum"],
    "tieba.personalized.PersonalizedResponseData": ["threadList", "threadPersonalized"],
    "tieba.userLike.UserLikeResponseData": ["threadInfo", "pageTag", "hasMore", "requestUnix"],
    "tieba.generalTabList.GeneralTabListResponseData": ["generalList", "hasMore", "userList", "sortType"],
    "tieba.frsPage.FrsPageResponseData": ["forum", "page", "threadList", "userList", "anti", "navTabInfo"],
    "tieba.profile.ProfileResponseData": ["user"],
    "tieba.getUserInfo.GetUserInfoResponseData": ["user"],
    "tieba.userPost.UserPostResponseData": ["postList"],
    "tieba.searchSug.SearchSugResponseData": ["list", "forumList"],
    "tieba.getDislikeList.GetDislikeListResponseData": ["forumList", "hasMore", "curPage"],
    // 权威 singular 键（重建后的描述符，2026-08-25）：getBawuInfo 的响应字段
    // 是 bawu_team_info（单数 BawuTeam），不再是旧的重复 bawuTeamList；成员页
    // 走 repeated MemberGroupInfo（member_group_info）；吧规详情只保留真实验证
    // 过的 forum/title/preface/rules/bazhu，去掉凭空捏造的 ruleHtml 四键。
    "tieba.getBawuInfo.GetBawuInfoResponseData": ["bawuTeamInfo"],
    "tieba.getMemberInfo.GetMemberInfoResponseData": ["memberGroupInfo"],
    "tieba.forumRuleDetail.ForumRuleDetailResponseData": ["forum", "title", "preface", "rules", "bazhu"],
    "tieba.getHistoryForum.GetHistoryForumResponseData": ["forumList"],
    "tieba.forumRecommend.ForumRecommendResponseData": ["likeForum"],
    // ---- small nested types used by bawu/member ----
    "tieba.BawuTeam": ["totalNum", "bawuTeamList"],
    "tieba.BawuRoleDes": ["roleName", "roleInfo"],
    "tieba.BawuRoleInfoPub": ["forumId", "userId", "roleId", "roleName", "portrait", "userLevel", "levelName", "userName", "nameShow"],
    // 成员分组（MemberGroupInfo，package tieba）：repeated BawuRoleInfoPub 的
    // 成员明细由上面 BawuRoleInfoPub 白名单裁剪；组级仅保留类型/人数/列表。
    "tieba.MemberGroupInfo": ["memberGroupType", "memberGroupNum", "memberGroupList"],
    "tieba.forumRecommend.LikeForumRec": ["forumId", "forumName", "avatar", "memberCount", "threadCount", "isLike", "levelId"],
  ]

  /// Repeated-field length caps, keyed by message path → field name → max.
  /// Mirrors helpers' `rawSubPosts.slice(0, 3)` preview cap.
  private let caps: [String: [String: Int]] = [
    "tieba.SubPost": ["subPostList": 3],
  ]

  init(registry: TiebaProtoRegistry = .shared) {
    self.registry = registry
  }

  /// Prune `object` (decoded at `messagePath`) to the render whitelist.
  /// Unknown/unlisted message types are returned unchanged (safe default).
  func project(_ object: [String: Any], messagePath: String) -> [String: Any] {
    guard let message = try? registry.message(path: messagePath) else { return object }
    // 字段名索引在 registry.walk() 一次性构建（initialize 时），热路径不再
    // 每消息重建字典（旧实现为每次 project 都 O(fields) 重建 fieldByName）。
    let fieldByName = message.fieldByName
    let whitelist = whitelists[messagePath]
    let capMap = caps[messagePath]

    var result: [String: Any] = [:]
    for (key, value) in object {
      if let whitelist = whitelist, !whitelist.contains(key) { continue }
      guard let field = fieldByName[key] else {
        // Should not happen (decoder only emits schema fields), keep value.
        result[key] = value
        continue
      }
      result[key] = projectedValue(value, field: field, messagePath: messagePath, cap: capMap?[key])
    }
    return result
  }

  /// Project a single value: recurse into message-typed fields, apply the
  /// length cap to capped repeated lists, and pass everything else through.
  private func projectedValue(
    _ value: Any,
    field: TiebaProtoField,
    messagePath: String,
    cap: Int?
  ) -> Any {
    guard let nested = try? registry.resolveMessage(typeName: field.type, currentPath: messagePath) else {
      return value
    }
    if field.repeated {
      guard let array = value as? [Any] else { return value }
      let projected = array.map { projectAny($0, messagePath: nested.path) }
      if let cap, projected.count > cap {
        return Array(projected.prefix(cap))
      }
      return projected
    }
    guard let dict = value as? [String: Any] else { return value }
    return project(dict, messagePath: nested.path)
  }

  private func projectAny(_ value: Any, messagePath: String) -> Any {
    guard let dict = value as? [String: Any] else { return value }
    return project(dict, messagePath: messagePath)
  }
}
