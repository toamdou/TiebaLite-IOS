import Foundation
import SwiftProtobuf

/// SwiftProtobuf 完全替换层（2026-08-29）：
/// - wire 解码全部走 protoc 生成的强类型代码（tbclient 权威 schema，
///   src/services/api/protos_src），手写 wire 解码器与白名单投影器已删除——
///   "投影剥字段"（alaInfo/forumLoc）这类结构性 bug 不复存在。
/// - int64/enum 输出保真：proto3 JSON 会把 int64 发成字符串、enum 发成名字，
///   这里用 proto-descriptors.json 描述符做类型驱动归一化，输出与旧解码器
///   逐形状一致（数字/枚举值），映射层零改动。
/// - 2026-09-13：encodeJSON/renameKeysIn（JSON → wire，含键名规整）删除——全仓
///   0 调用方，请求方向一律用生成类型直接构造。
enum TiebaSwiftProto {
  /// wire bytes → proto3 JSON bytes
  private typealias DecodeJSON = (Data) throws -> Data

  private static func entry<T: SwiftProtobuf.Message>(_ type: T.Type) -> DecodeJSON {
    { data in try type.init(serializedData: data).jsonUTF8Bytes() }
  }

  /// messagePath（与 JS protoClient responseType 完全一致）→ 生成类型入口。
  ///
  /// nonisolated(unsafe)：字典类型（entry 闭包）不是 Sendable，但本表是**静态
  /// 初始化时构建一次、之后只读**——decode 一处查表，没有任何写入路径（本文件
  /// 也无 extension 扩容入口）。表内闭包全部由 entry(_:) 生成、无捕获（只包
  /// type.init），每次调用只操作各自的局部变量，跨线程并发调用安全。以后若要
  /// "运行时注册新 messagePath"，必须给本表加锁或换成 OSAllocatedUnfairLock
  /// 保护的容器，不能继续依赖这条注释。
  nonisolated(unsafe) private static let entries: [String: DecodeJSON] = [
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
  static func decode(messagePath: String, bytes: Data) throws -> [String: Any] {
    guard let decode = entries[messagePath] else {
      throw TiebaProtoError.messageNotFound(messagePath)
    }
    let json = try decode(bytes)
    let obj = try JSONSerialization.jsonObject(with: json)
    return try normalize(obj, messagePath: messagePath) as? [String: Any] ?? [:]
  }

  // ── 描述符驱动归一化 ──
  // SwiftProtobuf 的 proto3 JSON：int64/uint64 → 字符串、enum → 值名、默认值字段省略；
  // 映射层要的是应用侧形状（数字、enum 数值），按描述符逐字段还原。

  private static let scalar64: Set<String> = [
    "int64", "uint64", "sint64", "fixed64", "sfixed64",
  ]
  private static let scalars: Set<String> = [
    "double", "float", "int32", "uint32", "sint32", "fixed32", "sfixed32",
    "bool", "string", "bytes",
  ]

  private static func normalize(_ value: Any, messagePath: String) throws -> Any {
    let message = try TiebaProtoRegistry.shared.message(path: messagePath)
    return normalizeObject(value, message: message)
  }

  private static func normalizeObject(_ obj: Any, message: TiebaProtoMessage) -> Any {
    guard let dict = obj as? [String: Any] else { return obj }
    var out: [String: Any] = [:]
    for (key, value) in dict {
      // SwiftProtobuf JSON 键 = ToJsonName 规则（"_client_type" → "ClientType"、
      // "_abstract" → "Abstract"），可能与 protos.json name 不一致：先按 name
      // 查、再按 protoName 反查、最后按 JSON 键反查（2026-08-30 补：前导下划线
      // 字段/ snake_case protoName 的 JSON 键两头都不沾，此前透传致 JS 摘要落空）。
      let field = message.fieldByName[key] ?? message.fieldByProtoName[key] ?? message.fieldByJSONName[key]
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
