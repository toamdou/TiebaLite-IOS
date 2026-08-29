import Foundation
import SwiftProtobuf

/// SwiftProtobuf 完全替换层（2026-08-29）：
/// - wire 解码/编码全部走 protoc 生成的强类型代码（tbclient 权威 schema，
///   src/services/api/protos_src），手写 wire 解码器与白名单投影器已删除——
///   "投影剥字段"（alaInfo/forumLoc）这类结构性 bug 不复存在。
/// - JS 侧桥接保持不变：protoPost 返回 JSON 字符串；新增 protoEncode 同步编码。
/// - int64/enum 输出保真：proto3 JSON 会把 int64 发成字符串、enum 发成名字，
///   这里用 protos.json 描述符（protoInitialize 注入）做类型驱动归一化，
///   输出与旧解码器逐形状一致（数字/枚举值），JS 映射层零改动。
enum TiebaSwiftProto {
  struct Entry {
    /// wire bytes → proto3 JSON bytes
    let decodeJSON: (Data) throws(TiebaProtoError) -> Data
    /// proto3 JSON 字符串（可含未知字段/驼峰键）→ wire bytes
    let encodeWire: (String) throws(TiebaProtoError) -> Data
  }

  private static func entry<T: SwiftProtobuf.Message>(_ type: T.Type) -> Entry {
    Entry(
      decodeJSON: { data in
        do {
          return try type.init(serializedData: data).jsonUTF8Bytes()
        } catch {
          // typed throws 包装：JS 桥只看 errorDescription，原文保留在参数里
          throw TiebaProtoError.swiftProtobuf("decode: \(error)")
        }
      },
      encodeWire: { json in
        do {
          var options = SwiftProtobuf.JSONDecodingOptions()
          options.ignoreUnknownFields = true
          return try type.init(jsonString: json, options: options).serializedData()
        } catch {
          throw TiebaProtoError.swiftProtobuf("encode: \(error)")
        }
      }
    )
  }

  /// messagePath（与 JS protoClient responseType 完全一致）→ 生成类型入口。
  private static let entries: [String: Entry] = [
    "tieba.frsPage.FrsPageRequest": entry(Tieba_FrsPage_FrsPageRequest.self),
    "tieba.frsPage.FrsPageResponse": entry(Tieba_FrsPage_FrsPageResponse.self),
    "tieba.pbPage.PbPageRequest": entry(Tieba_PbPage_PbPageRequest.self),
    "tieba.pbPage.PbPageResponse": entry(Tieba_PbPage_PbPageResponse.self),
    "tieba.pbFloor.PbFloorRequest": entry(Tieba_PbFloor_PbFloorRequest.self),
    "tieba.pbFloor.PbFloorResponse": entry(Tieba_PbFloor_PbFloorResponse.self),
    "tieba.profile.ProfileRequest": entry(Tieba_Profile_ProfileRequest.self),
    "tieba.profile.ProfileResponse": entry(Tieba_Profile_ProfileResponse.self),
    // ⚠️ personalized 包段与消息名重复，生成器折叠为 Tieba_PersonalizedRequest/Response
    "tieba.personalized.PersonalizedRequest": entry(Tieba_PersonalizedRequest.self),
    "tieba.personalized.PersonalizedResponse": entry(Tieba_PersonalizedResponse.self),
    "tieba.userLike.UserLikeRequest": entry(Tieba_UserLike_UserLikeRequest.self),
    "tieba.userLike.UserLikeResponse": entry(Tieba_UserLike_UserLikeResponse.self),
    "tieba.userPost.UserPostRequest": entry(Tieba_UserPost_UserPostRequest.self),
    "tieba.userPost.UserPostResponse": entry(Tieba_UserPost_UserPostResponse.self),
    "tieba.searchSug.SearchSugRequest": entry(Tieba_SearchSug_SearchSugRequest.self),
    "tieba.searchSug.SearchSugResponse": entry(Tieba_SearchSug_SearchSugResponse.self),
    "tieba.getBawuInfo.GetBawuInfoRequest": entry(Tieba_GetBawuInfo_GetBawuInfoRequest.self),
    "tieba.getBawuInfo.GetBawuInfoResponse": entry(Tieba_GetBawuInfo_GetBawuInfoResponse.self),
    "tieba.getMemberInfo.GetMemberInfoRequest": entry(Tieba_GetMemberInfo_GetMemberInfoRequest.self),
    "tieba.getMemberInfo.GetMemberInfoResponse": entry(Tieba_GetMemberInfo_GetMemberInfoResponse.self),
    "tieba.forumRuleDetail.ForumRuleDetailRequest": entry(Tieba_ForumRuleDetail_ForumRuleDetailRequest.self),
    "tieba.forumRuleDetail.ForumRuleDetailResponse": entry(Tieba_ForumRuleDetail_ForumRuleDetailResponse.self),
    "tieba.generalTabList.GeneralTabListRequest": entry(Tieba_GeneralTabList_GeneralTabListRequest.self),
    "tieba.generalTabList.GeneralTabListResponse": entry(Tieba_GeneralTabList_GeneralTabListResponse.self),
    "tieba.getDislikeList.GetDislikeListRequest": entry(Tieba_GetDislikeList_GetDislikeListRequest.self),
    "tieba.getDislikeList.GetDislikeListResponse": entry(Tieba_GetDislikeList_GetDislikeListResponse.self),
    "tieba.getForumDetail.GetForumDetailRequest": entry(Tieba_GetForumDetail_GetForumDetailRequest.self),
    "tieba.getForumDetail.GetForumDetailResponse": entry(Tieba_GetForumDetail_GetForumDetailResponse.self),
    "tieba.getUserInfo.GetUserInfoRequest": entry(Tieba_GetUserInfo_GetUserInfoRequest.self),
    "tieba.getUserInfo.GetUserInfoResponse": entry(Tieba_GetUserInfo_GetUserInfoResponse.self),
    "tieba.hotThreadList.HotThreadListRequest": entry(Tieba_HotThreadList_HotThreadListRequest.self),
    "tieba.hotThreadList.HotThreadListResponse": entry(Tieba_HotThreadList_HotThreadListResponse.self),
    "tieba.topicList.TopicListRequest": entry(Tieba_TopicList_TopicListRequest.self),
    "tieba.topicList.TopicListResponse": entry(Tieba_TopicList_TopicListResponse.self),
  ]

  /// wire bytes → 归一化后的字典（int64→Number、enum 名→值，对齐旧解码器输出形状）
  static func decode(messagePath: String, bytes: Data) throws(TiebaProtoError) -> [String: Any] {
    guard let entry = entries[messagePath] else {
      throw TiebaProtoError.messageNotFound(messagePath)
    }
    let json = try entry.decodeJSON(bytes)
    let obj: Any
    do {
      obj = try JSONSerialization.jsonObject(with: json)
    } catch {
      throw TiebaProtoError.invalidPayload("json: \(error.localizedDescription)")
    }
    return try normalize(obj, messagePath: messagePath) as? [String: Any] ?? [:]
  }

  /// JS 对象 JSON 字符串 → wire bytes（base64 由桥接层负责）。
  /// 键名规整：应用侧键 = protos.json 的 name（如 "_clientType"），而
  /// SwiftProtobuf 的 proto3-JSON 名按 protobuf ToJsonName 算法生成，
  /// 前导下划线字段会变成 "ClientType" 风格，直接按名匹配会静默丢字段。
  /// encode 前统一把键换成 proto 原名（SwiftProtobuf 接受 proto 名）。
  static func encodeJSON(messagePath: String, json: String) throws(TiebaProtoError) -> Data {
    guard let entry = entries[messagePath] else {
      throw TiebaProtoError.messageNotFound(messagePath)
    }
    let message = try TiebaProtoRegistry.shared.message(path: messagePath)
    guard let raw = json.data(using: .utf8) else {
      throw TiebaProtoError.invalidPayload("json parse failed")
    }
    let obj: [String: Any]
    do {
      guard let parsed = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
        throw TiebaProtoError.invalidPayload("json parse failed")
      }
      obj = parsed
    } catch let error as TiebaProtoError {
      throw error
    } catch {
      throw TiebaProtoError.invalidPayload("json parse failed: \(error.localizedDescription)")
    }
    let renamed = renameKeysIn(obj, message: message)
    let data = try JSONSerialization.data(withJSONObject: renamed)
    guard let renamedJSON = String(data: data, encoding: .utf8) else {
      throw TiebaProtoError.invalidPayload("json stringify failed")
    }
    return try entry.encodeWire(renamedJSON)
  }

  // ── 键名规整（encode 侧）──
  // 递归：对象键 → protoName（空则保持），message 字段递归、repeated 逐元素。

  private static func renameKeysIn(_ value: Any, message: TiebaProtoMessage) -> Any {
    guard let dict = value as? [String: Any] else { return value }
    var out: [String: Any] = [:]
    for (key, val) in dict {
      guard let field = message.fieldByName[key] else {
        out[key] = val // 描述符外键：透传（ignoreUnknownFields 兜底）
        continue
      }
      let newKey = field.protoName.isEmpty ? key : field.protoName
      if field.repeated, let arr = val as? [Any] {
        out[newKey] = arr.map { renameSingle($0, field: field, message: message) }
      } else {
        out[newKey] = renameSingle(val, field: field, message: message)
      }
    }
    return out
  }

  private static func renameSingle(_ v: Any, field: TiebaProtoField, message: TiebaProtoMessage) -> Any {
    guard
      let dict = v as? [String: Any],
      let sub = try? TiebaProtoRegistry.shared.resolveMessage(typeName: field.type, currentPath: message.path)
    else {
      return v
    }
    return renameKeysIn(dict, message: sub)
  }

  // ── 描述符驱动归一化 ──
  // SwiftProtobuf 的 proto3 JSON：int64/uint64 → 字符串、enum → 值名、
  // 默认值字段省略。旧手写解码器输出：全数字 → NSNumber、enum → 数值。
  // 这里按 protos.json 描述符（protoInitialize 注入 TiebaProtoRegistry）
  // 逐字段还原旧形状，JS 映射层零改动。

  private static let scalar64: Set<String> = [
    "int64", "uint64", "sint64", "fixed64", "sfixed64",
  ]
  private static let scalars: Set<String> = [
    "double", "float", "int32", "uint32", "sint32", "fixed32", "sfixed32",
    "bool", "string", "bytes",
  ]

  private static func normalize(_ value: Any, messagePath: String) throws(TiebaProtoError) -> Any {
    let message = try TiebaProtoRegistry.shared.message(path: messagePath)
    return normalizeObject(value, message: message)
  }

  private static func normalizeObject(_ obj: Any, message: TiebaProtoMessage) -> Any {
    guard let dict = obj as? [String: Any] else { return obj }
    var out: [String: Any] = [:]
    for (key, value) in dict {
      // SwiftProtobuf JSON 键 = ToJsonName 规则（"_client_type" → "ClientType"），
      // 可能与 protos.json name 不一致：先用 name 查，再按 protoName 反查。
      let field = message.fieldByName[key] ?? message.fieldByProtoName[key]
      guard let field else {
        // 描述符外字段（生成的 JSON 不会产生，防御性透传）
        out[key] = value
        continue
      }
      if field.repeated, let array = value as? [Any] {
        out[field.name] = array.map { normalizeSingle($0, field: field, containingPath: message.path) }
      } else {
        out[field.name] = normalizeSingle(value, field: field, containingPath: message.path)
      }
    }
    return out
  }

  private static func normalizeSingle(_ value: Any, field: TiebaProtoField, containingPath: String) -> Any {
    if scalar64.contains(field.type) {
      if let s = value as? String, let v = Int64(s) {
        return NSNumber(value: v)
      }
      return value
    }
    if scalars.contains(field.type) {
      return value
    }
    // enum：proto3 JSON 发值名（字符串）→ 按描述符枚举表转数值
    if let s = value as? String,
       let values = try? TiebaProtoRegistry.shared.resolveEnumValues(typeName: field.type, currentPath: containingPath),
       let num = values[s] {
      return NSNumber(value: num)
    }
    // message：递归
    if let dict = value as? [String: Any],
       let msg = try? TiebaProtoRegistry.shared.resolveMessage(typeName: field.type, currentPath: containingPath) {
      return normalizeObject(dict, message: msg)
    }
    return value
  }
}
