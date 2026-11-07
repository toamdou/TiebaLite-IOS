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

  /// 解析帖级写操作（点赞/收藏）真正的首楼 post id。
  ///
  /// 服务端帖级接口（obj_type=3）要求 `post_id` 是**首楼的 post id**，不是帖子 id：
  /// 拿帖子 id 顶上会回"该楼层不存在"。但推荐流/列表卡的 ThreadInfo 不回
  /// first_post_id(40)，映射层又不做兜底——卡片的 firstPostId 基本恒为空，
  /// 旧实现用帖子 id 兜底，点赞就 100% 失败（issue #13：分享按钮右侧红心；
  /// 帖子页底栏之所以成功，是因为 mainPost.id 就是真首楼 pid）。
  ///
  /// 这里按需拉一次帖子第 1 页，从 floor == 1 的楼里取 pid。`known` 不是真首楼 pid
  /// （空/"0"/等于帖子 id）时一律视为缺失。帖子页数据本身走 TiebaPageCache（SWR），
  /// 已经打开过的帖子直接命中缓存，不会重复请求。
  static func resolveThreadFirstPostId(threadId: String, known: String = "") async -> String? {
    guard !threadId.isEmpty else { return nil }
    if isUsableFirstFloorPostId(known, threadId: threadId) { return known }
    guard let page = try? await TiebaThreadAPI.page(
      threadId: threadId,
      page: 1,
      postId: nil,
      seeLz: false,
      sort: .asc
    ) else { return nil }
    if let first = page.posts.first(where: { $0.floor == 1 })?.id,
       isUsableFirstFloorPostId(first, threadId: threadId) {
      return first
    }
    if let fromThread = page.thread?.firstPostId,
       isUsableFirstFloorPostId(fromThread, threadId: threadId) {
      return fromThread
    }
    return nil
  }

  /// 真首楼 pid 判据：非空、非 "0"、且不等于帖子 id（等于帖子 id 说明是映射层兜底值）。
  private static func isUsableFirstFloorPostId(_ value: String, threadId: String) -> Bool {
    !value.isEmpty && value != "0" && value != threadId
  }

  /// 收藏 / 取消收藏（原 JS addStore / removeStore；fid=null 与 user_id 逐字段一致）。
  /// addstore 带 tbs（Kotlin 权威 `(data, tbs, stoken)`；JS 期漏了它，其注释自陈的
  /// "伪成功"即缺 tbs 的表现）。tbs 缺失一律走续期，见 requireTbs 的说明。
  /// stoken 两个分支都带（Kotlin 两个接口都有该 @Field）；非 stoken 用户本来就没有，
  /// 缺失即不带，不阻断。
  static func setStore(threadId: String, firstPostId: String, store: Bool) async throws {
    guard !threadId.isEmpty else { throw TiebaForumAPIError.invalidResponse }
    let snapshot = TiebaBackgroundSnapshot.shared
    let tbs = try await TiebaSession.requireTbs()
    if store {
      let data = "[{\"tid\":\"\(threadId)\",\"pid\":\"\(firstPostId.isEmpty ? "0" : firstPostId)\",\"status\":1}]"
      var fields = ["data": data, "tbs": tbs]
      if !snapshot.stoken.isEmpty { fields["stoken"] = snapshot.stoken }
      _ = try await TiebaSocialAPI.signedPost(path: "/c/c/post/addstore", fields: fields)
    } else {
      var fields = ["tid": threadId, "fid": "null", "tbs": tbs, "user_id": snapshot.uid]
      if !snapshot.stoken.isEmpty { fields["stoken"] = snapshot.stoken }
      _ = try await TiebaSocialAPI.signedPost(path: "/c/c/post/rmstore", fields: fields)
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
