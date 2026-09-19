// 帖级写操作（原 src/services/api/endpoints/thread.ts 的 agree 等）：签名表单 POST，
// 传输统一走 TiebaSocialAPI.signedPost（同一份 common params + st 参数 + sign + 头，
// 参数/头/签名与 JS signed 变体逐项对齐；op_type 与 RN 语义相反：RN 1=赞 → 服务端 0）。
import Foundation

enum TiebaThreadActionAPI {
  /// 点赞/取消（obj_type=3 帖级，post_id 用首楼 id；obj_type=1 楼级，post_id 用楼层 id）。
  /// 服务端 op_type 与 UI 语义相反：赞 = 0、取消 = 1（与 JS agree 同翻转）。
  static func setAgree(threadId: String, postId: String, agree: Bool, objType: Int = 3) async throws {
    guard !threadId.isEmpty, !postId.isEmpty else { throw TiebaForumAPIError.invalidResponse }
    let snapshot = TiebaBackgroundSnapshot.shared
    // tbs 缺失就续期（TiebaSession.requireTbs → /c/s/login，与原 JS requireTbs 逐路径一致；
    // 续期失败才抛"缺少 tbs"）。
    var fields: [String: String] = [
      "thread_id": threadId,
      "post_id": postId,
      "agree_type": "2",
      "obj_type": String(objType),
      "op_type": agree ? "0" : "1",
      "tbs": try await TiebaSession.requireTbs(),
    ]
    if !snapshot.stoken.isEmpty { fields["stoken"] = snapshot.stoken }
    _ = try await TiebaSocialAPI.signedPost(path: "/c/c/agree/opAgree", fields: fields)
  }

  /// 收藏 / 取消收藏（原 JS addStore / removeStore；fid=null 与 user_id 逐字段一致）。
  /// addstore 带 tbs（Kotlin 权威 `(data, tbs, stoken)`；JS 期漏了它，其注释自陈的
  /// "伪成功"即缺 tbs 的表现）。tbs 缺失一律走续期，见 requireTbs 的说明。
  static func setStore(threadId: String, firstPostId: String, store: Bool) async throws {
    guard !threadId.isEmpty else { throw TiebaForumAPIError.invalidResponse }
    let snapshot = TiebaBackgroundSnapshot.shared
    let tbs = try await TiebaSession.requireTbs()
    if store {
      let data = "[{\"tid\":\"\(threadId)\",\"pid\":\"\(firstPostId.isEmpty ? "0" : firstPostId)\",\"status\":1}]"
      _ = try await TiebaSocialAPI.signedPost(
        path: "/c/c/post/addstore",
        fields: ["data": data, "tbs": tbs]
      )
    } else {
      _ = try await TiebaSocialAPI.signedPost(path: "/c/c/post/rmstore", fields: [
        "tid": threadId, "fid": "null", "tbs": tbs, "user_id": snapshot.uid,
      ])
    }
  }

  /// 删除帖子（postId 空）或楼层（isfloor=1）。
  static func delete(
    threadId: String,
    forumId: String,
    forumName: String,
    postId: String?
  ) async throws {
    let tbs = try await TiebaSession.requireTbs()
    if let postId, !postId.isEmpty {
      _ = try await TiebaSocialAPI.signedPost(path: "/c/c/bawu/delpost", fields: [
        "fid": forumId, "word": forumName, "z": threadId, "pid": postId,
        "isfloor": "1", "src": "1", "is_vipdel": "0", "delete_my_post": "1",
        "tbs": tbs,
      ])
    } else {
      _ = try await TiebaSocialAPI.signedPost(path: "/c/c/bawu/delthread", fields: [
        "fid": forumId, "word": forumName, "z": threadId,
        "src": "1", "is_vipdel": "0", "delete_my_thread": "1", "tbs": tbs,
      ])
    }
  }

  /// 删除楼中楼回复（原 JS delPost 的 isfloor=false：subpost 不是楼层）。
  static func deleteReply(
    threadId: String,
    forumId: String,
    forumName: String,
    postId: String
  ) async throws {
    guard !threadId.isEmpty, !postId.isEmpty else { throw TiebaForumAPIError.invalidResponse }
    _ = try await TiebaSocialAPI.signedPost(path: "/c/c/bawu/delpost", fields: [
      "fid": forumId, "word": forumName, "z": threadId, "pid": postId,
      "isfloor": "0", "src": "1", "is_vipdel": "0", "delete_my_post": "1",
      "tbs": try await TiebaSession.requireTbs(),
    ])
  }
}
