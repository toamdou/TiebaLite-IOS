// 用户主页 / 收藏页的数据访问：原 JS endpoints/user.ts 的 profile / userPost /
// userLikeForum、social.ts 的粉丝关注、thread.ts 的收藏列表、thread.ts 的关注 /
// 取关、misc.ts 的拉黑。
//
// 两条既有通道复用，不新开第三条：proto 走 TiebaForumAPI.protoPost（强类型
// 编解码，不依赖 JS 回填的 protos 描述符），表单走 TiebaSocialAPI 的签名通道
// （commonParams + st 参数 + sign，与 JS signed variant 逐参数一致）。行字典一律
// 经 TiebaViewModelMapper.mapProtoThread（与信息流/话题页同一份映射）。
import Foundation
import SwiftProtobuf
import os

// MARK: - 视图模型

struct TiebaProfileDetail {
  var uid = ""
  var name = ""
  var nameShow = ""
  var portrait = ""
  var sex = 0
  var intro = ""
  var fansNum = 0
  var concernNum = 0
  var totalAgreeNum = 0
  var postNum = 0
  var likedForumNum = 0
  var ipLocation = ""
  var tbAge = ""
  var tiebaUid = ""
  var bazhuDesc = ""
  var godFieldName = ""
  var godStatus = 0
  /// 已关注此用户（proto hasConcerned != 0）
  var isConcerned = false

  var displayName: String {
    if !nameShow.isEmpty { return nameShow }
    if !name.isEmpty { return name }
    return "用户"
  }

  var uidText: String { tiebaUid.isEmpty ? uid : tiebaUid }
}

struct TiebaProfileForum {
  var forumId = ""
  var forumName = ""
  var avatar = ""
  var levelName = ""
}

struct TiebaProfileSocialUser {
  var uid = ""
  var portrait = ""
  var userName = ""
  var nickName = ""

  var displayName: String {
    if !nickName.isEmpty { return nickName }
    if !userName.isEmpty { return userName }
    return uid
  }
}

enum TiebaProfileError: LocalizedError {
  case missingTbs
  case message(String)

  var errorDescription: String? {
    switch self {
    case .missingTbs: return "缺少 tbs，无法执行此操作，请刷新页面后重试"
    case .message(let text): return text
    }
  }
}

// MARK: - 数据访问

enum TiebaProfileAPI {
  static let postPageSize = 20
  static let socialPageSize = 20
  private static let favoritePageSize = 50

  // MARK: 资料卡

  static func profile(uid: String) async throws -> TiebaProfileDetail {
    guard !uid.isEmpty else { throw TiebaForumAPIError.invalidURL }
    let selfUid = TiebaBackgroundSnapshot.shared.uid
    let isSelf = selfUid.isEmpty || selfUid == uid
    let data = try await TiebaForumAPI.protoPost(
      path: "/c/u/user/profile",
      cmd: "303012&format=protobuf"
    ) { common in
      var body = Tieba_Profile_ProfileRequestData()
      body.common = common
      body.uid = Int64(selfUid.isEmpty ? uid : selfUid) ?? Int64(uid) ?? 0
      body.friendUid = isSelf ? 0 : (Int64(uid) ?? 0)
      body.friendUidPortrait = ""
      body.hasPlist_p = 1
      body.isFromUsercenter = 1
      body.isGuest = isSelf ? 0 : 1
      body.needPostCount = 1
      body.page = 1
      body.pn = 1
      body.qType = 0
      body.rn = UInt32(postPageSize)
      body.scrW = 1170
      body.scrH = 2532
      body.scrDip = 3
      var wrapper = Tieba_Profile_ProfileRequest()
      wrapper.data = body
      return wrapper
    }
    let response = try Tieba_Profile_ProfileResponse(serializedBytes: data)
    if response.hasError, response.error.errorCode != 0 {
      throw TiebaViewModelError(
        code: Double(response.error.errorCode),
        message: response.error.errorMsg
      )
    }
    guard response.hasData else { throw TiebaForumAPIError.invalidResponse }
    let user = response.data.user

    var detail = TiebaProfileDetail()
    let rawUid = String(user.id)
    detail.uid = rawUid == "0" ? uid : rawUid
    detail.name = user.name
    detail.nameShow = user.nameShow
    detail.portrait = user.portrait
    detail.sex = Int(user.sex)
    detail.intro = user.intro
    detail.fansNum = Int(user.fansNum)
    detail.concernNum = Int(user.concernNum)
    detail.totalAgreeNum = Int(user.totalAgreeNum)
    detail.postNum = Int(user.postNum)
    detail.likedForumNum = Int(user.myLikeNum)
    detail.ipLocation = user.ipAddress
    detail.tbAge = user.tbAge
    detail.tiebaUid = user.tiebaUid.isEmpty ? detail.uid : user.tiebaUid
    detail.isConcerned = user.hasConcerned_p != 0
    if user.hasBazhuGrade { detail.bazhuDesc = user.bazhuGrade.desc }
    if user.hasNewGodData {
      detail.godStatus = Int(user.newGodData.status)
      detail.godFieldName = user.newGodData.fieldName
    }
    return detail
  }

  // MARK: 用户帖子 / 回复

  /// hasMore 判据与旧页一致：整页 20 条即认为还有下一页。
  static func posts(
    uid: String,
    page: Int,
    isThread: Bool,
    detail: TiebaProfileDetail?
  ) async throws -> (rows: [[String: Any]], hasMore: Bool) {
    guard !uid.isEmpty else { return ([], false) }
    let data = try await TiebaForumAPI.protoPost(
      path: "/c/u/feed/userpost",
      cmd: "303002&format=protobuf"
    ) { common in
      var body = Tieba_UserPost_UserPostRequestData()
      body.common = common
      body.uid = Int64(uid) ?? 0
      body.rn = UInt32(postPageSize)
      body.isThread = isThread ? 1 : 0
      body.needContent = 1
      body.pn = UInt32(clamping: page)
      body.scrW = 1170
      body.scrH = 2532
      body.scrDip = 3
      body.qType = 0
      body.isViewCard = 0
      body.subtype = 0
      var wrapper = Tieba_UserPost_UserPostRequest()
      wrapper.data = body
      return wrapper
    }
    let response = try Tieba_UserPost_UserPostResponse(serializedBytes: data)
    if response.hasError, response.error.errorCode != 0 {
      throw TiebaViewModelError(
        code: Double(response.error.errorCode),
        message: response.error.errorMsg
      )
    }
    guard response.hasData else { throw TiebaForumAPIError.invalidResponse }
    let list = response.data.postList
    let rows = list.compactMap { postRow($0, uid: uid, detail: detail) }
    return (rows, list.count >= postPageSize)
  }

  /// 单条用户内容 → 信息流行字典。直读生成类型（不再走 jsonUTF8Data →
  /// JSONSerialization → mapper 按 JSON 键猜字段）；行 shape 仍由 mapProtoThread
  /// 产出，与信息流/话题页同一份映射。
  private static func postRow(
    _ raw: Tieba_PostInfoList,
    uid: String,
    detail: TiebaProfileDetail?
  ) -> [String: Any]? {
    let threadRaw = raw.threadID == 0 ? raw.postID : raw.threadID
    guard threadRaw != 0 else { return nil }
    var row = TiebaViewModelMapper.mapProtoThread(mapperInput(raw))
    guard !row.isEmpty else { return nil }
    // 行 key 与跳转都用 threadId（回复行共享同一主题帖；postId 只作首楼锚点）。
    row["id"] = String(threadRaw)
    row["threadId"] = String(threadRaw)
    row["firstPostId"] = String(raw.postID)
    if TiebaSimpleRowParser.nonEmpty(row["title"]) == nil {
      row["title"] = raw.content.flatMap { $0.postContent }.map(\.text).joined()
    }
    row["authorId"] = raw.userID != 0 ? String(raw.userID) : uid
    row["authorName"] = raw.userName.isEmpty ? (detail?.name ?? "") : raw.userName
    row["authorNameShow"] = raw.nameShow.isEmpty
      ? (raw.userName.isEmpty ? (detail?.displayName ?? "") : raw.userName)
      : raw.nameShow
    row["authorPortrait"] = raw.userPortrait.isEmpty
      ? (detail?.portrait ?? "")
      : raw.userPortrait
    row["authorIP"] = raw.ip
    return row
  }

  /// Tieba_PostInfoList → mapProtoThread 的输入字典。键取生成类型字段，
  /// 不再经过 proto3 JSON 往返（省一次序列化 + 键名反查）。
  private static func mapperInput(_ raw: Tieba_PostInfoList) -> [String: Any] {
    var input: [String: Any] = [
      "id": String(raw.threadID != 0 ? raw.threadID : raw.postID),
      "threadId": String(raw.threadID),
      "firstPostId": String(raw.postID),
      "title": raw.title,
      "forumId": raw.forumID == 0 ? "" : String(raw.forumID),
      "forumName": raw.forumName,
      "replyNum": Int(raw.replyNum),
      "createTime": Int(raw.createTime),
      "abstract": raw.abstract,
      "media": mediaRows(raw.media),
    ]
    var author: [String: Any] = [
      "name": raw.userName,
      "portrait": raw.userPortrait,
      "ip": raw.ip,
    ]
    if !raw.nameShow.isEmpty { author["nameShow"] = raw.nameShow }
    if raw.userID != 0 { author["id"] = String(raw.userID) }
    input["author"] = author
    return input
  }

  /// Tieba_Media → mapMediaList 输入（键名与 proto3 JSON 同形，mapper 的
  /// 兜底链原样生效；userPost 的 media 只有图片类型）。
  private static func mediaRows(_ media: [Tieba_Media]) -> [[String: Any]] {
    media.map { item in
      [
        "type": Int(item.type),
        "bigPic": item.bigPic,
        "srcPic": item.srcPic,
        "originPic": item.originPic,
        "dynamicPic": item.dynamicPic,
        "width": Int(item.width),
        "height": Int(item.height),
        "isLongPic": Int(item.isLongPic),
        "showOriginalBtn": Int(item.showOriginalBtn),
      ]
    }
  }

  // MARK: 关注的吧

  static func likedForums(
    uid: String,
    page: Int
  ) async throws -> (items: [TiebaProfileForum], hasMore: Bool) {
    let myUid = TiebaBackgroundSnapshot.shared.uid
    let isSelf = myUid.isEmpty || myUid == uid
    var fields = ["page_no": String(page), "page_size": "50"]
    if !myUid.isEmpty { fields["uid"] = myUid }
    if !isSelf {
      fields["friend_uid"] = uid
      fields["is_guest"] = "1"
    }
    let body: [String: Any]
    do {
      body = try await TiebaSocialAPI.signedPost(path: "/c/f/forum/like", fields: fields)
    } catch TiebaForumAPIError.api(let code, _) where code == 110001 {
      // 服务端对「未登录」与「对方隐私设置」都回 110001：按登录态给可读提示。
      throw TiebaProfileError.message(
        myUid.isEmpty ? "请先登录后查看 TA 关注的吧" : "由于对方的隐私设置，无法查看 TA 关注的吧"
      )
    }
    let data = (body["data"] as? [String: Any]) ?? body
    let list = (data["forum_list"] as? [[String: Any]])
      ?? (body["forum_list"] as? [[String: Any]])
      ?? []
    let items = list.map { raw -> TiebaProfileForum in
      var forum = TiebaProfileForum()
      forum.forumId = TiebaJSON.string(raw, "forum_id", "forumId", "fid") ?? ""
      forum.forumName = TiebaJSON.string(raw, "forum_name", "forumName") ?? ""
      forum.avatar = TiebaJSON.string(raw, "avatar") ?? ""
      forum.levelName = TiebaJSON.string(raw, "level_name", "levelName") ?? ""
      return forum
    }.filter { !$0.forumName.isEmpty }
    return (items, TiebaJSON.int(data, "has_more", "hasMore") == 1)
  }

  // MARK: 粉丝 / 关注

  static func socialList(
    uid: String,
    fans: Bool,
    page: Int
  ) async throws -> (items: [TiebaProfileSocialUser], hasMore: Bool) {
    let target = uid.isEmpty ? TiebaBackgroundSnapshot.shared.uid : uid
    let body = try await TiebaSocialAPI.signedPost(
      path: fans ? "/c/u/fans/page" : "/c/u/follow/followList",
      fields: ["pn": String(page), "uid": target]
    )
    let data = (body["data"] as? [String: Any]) ?? body
    let list = (data["user_list"] as? [[String: Any]])
      ?? (data["users"] as? [[String: Any]])
      ?? (data["list"] as? [[String: Any]])
      ?? []
    let items = list.map { raw -> TiebaProfileSocialUser in
      var user = TiebaProfileSocialUser()
      user.uid = TiebaJSON.string(raw, "id", "uid") ?? ""
      user.portrait = TiebaSimpleRowParser.cleanPortrait(TiebaJSON.string(raw, "portrait") ?? "")
      user.userName = TiebaJSON.string(raw, "name", "user_name") ?? ""
      user.nickName = TiebaJSON.string(raw, "name_show", "nick_name_new", "nickName") ?? ""
      return user
    }.filter { !$0.uid.isEmpty }
    return (items, TiebaJSON.int(data, "has_more", "hasMore") == 1)
  }

  // MARK: 收藏

  static func favorites(page: Int) async throws -> (rows: [[String: Any]], hasMore: Bool) {
    let offset = max(0, page - 1) * favoritePageSize
    let body = try await TiebaSocialAPI.signedPost(
      path: "/c/f/post/threadstore",
      fields: [
        "rn": String(favoritePageSize),
        "offset": String(offset),
        "user_id": TiebaBackgroundSnapshot.shared.uid,
      ]
    )
    let data = (body["data"] as? [String: Any]) ?? body
    let list = (data["store_list"] as? [[String: Any]])
      ?? (body["store_list"] as? [[String: Any]])
      ?? (body["store_thread"] as? [[String: Any]])
      ?? []
    return (list.map(favoriteRow), TiebaJSON.int(data, "has_more", "hasMore") == 1)
  }

  /// 收藏项 → 信息流行字典（原 favoriteToThreadInfo：服务端 store_list 不带图，
  /// mediaList 由本地快照合并；尺寸缺失走 300×300 方图兜底而非 1×1）。
  static func favoriteRow(_ raw: [String: Any]) -> [String: Any] {
    let tid = TiebaJSON.string(raw, "tid", "id", "thread_id") ?? ""
    let author = raw["author"] as? [String: Any] ?? [:]
    let replyNum = TiebaJSON.double(raw, "latest_reply_num", "latestReplyNum") ?? 0
    let updateMs = toMillis(TiebaJSON.double(raw, "update_time", "updateTime") ?? 0)
    let collectMs = toMillis(TiebaJSON.double(raw, "collect_time", "collectTime") ?? 0)
    var row: [String: Any] = [
      "kind": TiebaKindRowKind.feed.rawValue,
      "id": tid,
      "threadId": tid,
      "firstPostId": TiebaJSON.string(raw, "post_id", "postId", "pid") ?? "",
      "title": TiebaJSON.string(raw, "title", "thread_title") ?? "",
      "forumId": TiebaJSON.string(raw, "forum_id", "forumId", "fid") ?? "",
      "forumName": TiebaJSON.string(raw, "forum_name", "forumName", "fname") ?? "",
      "forumAvatar": "",
      "authorId": "",
      "authorName": TiebaJSON.string(author, "name_show", "name")
        ?? TiebaJSON.string(raw, "author_name", "authorName") ?? "",
      "authorNameShow": "",
      "authorPortrait": TiebaJSON.string(author, "user_portrait", "portrait")
        ?? TiebaJSON.string(raw, "author_portrait", "authorPortrait") ?? "",
      "authorIP": "",
      "replyNum": replyNum,
      "viewNum": 0,
      "zanNum": 0,
      "shareNum": 0,
      "hasAgree": false,
      "lastTime": updateMs > 0 ? updateMs : collectMs,
      "createTime": collectMs,
      "isVideo": false,
      "mediaList": [],
      "abstract": "",
      "expanded": false,
      "isShareThread": false,
      "timeType": "last",
      "showForumPill": true,
      "hideActions": true,
      "imageContextMenu": true,
      // 原 TweetCard 未传 onMenuAction → 不渲染右上角 ×。
      "closeMenuOptions": [] as [String],
    ]
    row.merge(TiebaFeedRowPreferences.current()) { _, new in new }
    return row
  }

  static func removeFavorite(tid: String) async throws {
    try await TiebaThreadActionAPI.setStore(threadId: tid, firstPostId: "", store: false)
  }

  // MARK: 关注 / 拉黑

  static func follow(portrait: String, follow: Bool) async throws {
    guard !portrait.isEmpty else { throw TiebaForumAPIError.invalidURL }
    let tbs = TiebaBackgroundSnapshot.shared.tbs
    guard !tbs.isEmpty else { throw TiebaProfileError.missingTbs }
    var fields = [
      "portrait": portrait, "tbs": tbs,
      "from_type": "2", "in_live": "0", "authsid": "null",
    ]
    if !follow { fields["timestamp"] = String(Int(Date().timeIntervalSince1970 * 1000)) }
    _ = try await TiebaSocialAPI.signedPost(
      path: follow ? "/c/c/user/follow" : "/c/c/user/unfollow",
      fields: fields
    )
  }

  static func setBlack(uid: String, black: Bool) async throws {
    guard !uid.isEmpty else { throw TiebaForumAPIError.invalidURL }
    let tbs = TiebaBackgroundSnapshot.shared.tbs
    guard !tbs.isEmpty else { throw TiebaProfileError.missingTbs }
    _ = try await TiebaSocialAPI.signedPost(
      path: "/c/c/user/setUserBlack",
      fields: ["black_uid": uid, "tbs": tbs, "perm_list": black ? "1,2,3" : ""]
    )
  }

  // MARK: 辅助

  /// 行级显示偏好（现读；键名 = TiebaRowMetrics 的解析键）。
  static func rowPreferences() -> [String: Any] { TiebaFeedRowPreferences.current() }

  /// 服务端时间戳容错：秒 → 毫秒（原 storeTimestamp 同判据）。
  static func toMillis(_ raw: Double) -> Double {
    guard raw.isFinite, raw > 0 else { return 0 }
    return raw >= 1e11 ? raw : raw * 1000
  }

}

/// 信息流行字典下发的偏好键（TiebaFeedRowBuilder.make 只在已有 ThreadInfo 时
/// 可用；本文件的行来自表单 JSON，需要同一组键）。
enum TiebaFeedRowPreferences {
  static func current() -> [String: Any] {
    [
      "hideMedia": TiebaPreferenceSnapshot.bool("hideMedia", default: false),
      "showIpLocation": TiebaPreferenceSnapshot.bool("showIpLocation", default: true),
      "showBothUsername": TiebaPreferenceSnapshot.bool("showBothUsername", default: false),
      "fontScale": Double(TiebaPreferenceSnapshot.string("fontScale") ?? "") ?? 1,
      "timestampStyle": TiebaPreferenceSnapshot.string("timestampStyle") ?? "relative",
    ]
  }
}

// MARK: - 吧头像缓存（原 src/stores/forumAvatarCache.ts）

/// 全站统一吧头像缓存：与 JS 同一份 KV 键（forum_avatars_v1，值 {key:{avatar,ts}}），
/// 键 = forumId 优先、缺失退 `n:<吧名>`。页面读内存/KV 直查；未命中按吧名实时拉
/// （TiebaSearchAPI.forums，2 并发 + 120ms 间隔，失败静默）。
final class TiebaForumAvatarCache: @unchecked Sendable {
  static let shared = TiebaForumAvatarCache()

  private static let diskKey = "forum_avatars_v1"
  private static let concurrency = 2
  private static let perForumDelayMs = 120
  private static let log = Logger(subsystem: "com.tiebalite.app", category: "forum-avatar-cache")

  /// 条目上限：按"见过的吧"增长，见过几千个吧就是几千条；到顶按 ts 淘汰最旧的四分之一。
  private static let maxEntries = 500
  /// 写盘合并窗口：头像是一个个到的（每个之间还有 120ms 节流），逐条全表重写是
  /// O(n) 次编码；改成最多 1s 写一次。
  private static let persistInterval: TimeInterval = 1

  private let lock = NSLock()
  private var memory: [String: String] = [:]
  private var inflight: Set<String> = []
  private var diskLoaded = false
  private var lastPersistAt: TimeInterval = 0
  private var persistScheduled = false

  private init() {}

  /// 取号盒子：cursor 需跨 addTask 传递，锁已保证互斥，故按本仓惯例声明 @unchecked Sendable。
  private final class CursorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var cursor = 0

    func next(of pending: [(key: String, name: String)]) -> (key: String, name: String)? {
      lock.withLock {
        guard cursor < pending.count else { return nil }
        defer { cursor += 1 }
        return pending[cursor]
      }
    }
  }

  /// 预热（启动时调用）：把磁盘缓存**在后台**读进内存，别让首个 cell 的
  /// `cached(key:)` 在主线程解析整张表（原来首次访问就是主线程 parse 全表 JSON）。
  func warmUp() {
    DispatchQueue.global(qos: .utility).async { [weak self] in
      guard let self else { return }
      self.lock.withLock { self.loadDiskLocked() }
    }
  }

  /// 统一键：forumId 非空且非 "0" → 原样，否则 `n:<吧名>`；两者都无 → nil。
  static func key(forumId: String, forumName: String) -> String? {
    let id = forumId.trimmingCharacters(in: .whitespaces)
    if !id.isEmpty, id != "0" { return id }
    let name = forumName.trimmingCharacters(in: .whitespaces)
    return name.isEmpty ? nil : "n:\(name)"
  }

  func cached(key: String) -> String {
    lock.withLock {
      loadDiskLocked()
      return memory[key] ?? ""
    }
  }

  /// 幂等补齐（已缓存/在途跳过）；拉到新头像后在主线程回调 onUpdate。
  func ensure(entries: [(key: String, name: String)], onUpdate: @escaping @MainActor () -> Void) {
    let pending: [(key: String, name: String)] = lock.withLock {
      loadDiskLocked()
      var result: [(key: String, name: String)] = []
      for entry in entries where !entry.name.isEmpty {
        guard memory[entry.key] == nil, !inflight.contains(entry.key) else { continue }
        inflight.insert(entry.key)
        result.append(entry)
      }
      return result
    }
    guard !pending.isEmpty else { return }
    Task.detached(priority: .utility) { [weak self] in
      guard let self else { return }
      // 取号改成 Sendable 盒子：cursor 要跨 addTask 传递，sending 闭包只接受 Sendable 捕获。
      let cursor = CursorBox()
      func worker() async {
        while let entry = cursor.next(of: pending) {
          var avatar = ""
          if let hits = try? await TiebaSearchAPI.forums(keyword: entry.name), !hits.isEmpty {
            let hit = hits.first { $0.name == entry.name } ?? hits[0]
            avatar = TiebaSimpleRowParser.string(hit.row["avatar"]) ?? ""
          }
          if self.commit(key: entry.key, avatar: avatar) {
            await MainActor.run { onUpdate() }
          }
          try? await Task.sleep(nanoseconds: UInt64(Self.perForumDelayMs) * 1_000_000)
        }
      }
      await withTaskGroup(of: Void.self) { group in
        for _ in 0..<Self.concurrency { group.addTask { await worker() } }
      }
    }
  }

  /// 写入内存 + 落盘；无头像 = 只解除在途标记（下次进入还会重试）。
  private func commit(key: String, avatar: String) -> Bool {
    lock.withLock {
      inflight.remove(key)
      guard !avatar.isEmpty, memory[key] != avatar else { return false }
      memory[key] = avatar
      schedulePersistLocked()
      return true
    }
  }

  private func loadDiskLocked() {
    guard !diskLoaded else { return }
    diskLoaded = true
    guard let raw = TiebaKvStore.shared.get(key: Self.diskKey),
      let data = raw.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return }
    for (key, value) in object {
      guard let entry = value as? [String: Any],
        let avatar = entry["avatar"] as? String, !avatar.isEmpty
      else { continue }
      memory[key] = avatar
    }
  }

  /// 合并写盘：窗口内的多次提交只落一次盘（口径见 persistInterval）。
  private func schedulePersistLocked() {
    let now = ProcessInfo.processInfo.systemUptime
    if now - lastPersistAt >= Self.persistInterval {
      persistLocked()
      return
    }
    guard !persistScheduled else { return }
    persistScheduled = true
    let delay = Self.persistInterval - (now - lastPersistAt)
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
      guard let self else { return }
      self.lock.withLock {
        self.persistScheduled = false
        self.persistLocked()
      }
    }
  }

  private func persistLocked() {
    lastPersistAt = ProcessInfo.processInfo.systemUptime
    // 容量上限：到顶淘汰四分之一（按键序近似最旧；头像这层不需要精确 LRU，
    // 只要别无界增长——被淘汰的条目下次进页面会重新拉一次）。
    if memory.count > Self.maxEntries {
      for key in memory.keys.prefix(Self.maxEntries / 4) {
        memory.removeValue(forKey: key)
      }
    }
    let payload = memory.mapValues {
      ["avatar": $0, "ts": Int(Date().timeIntervalSince1970 * 1000)] as [String: Any]
    }
    guard let data = try? JSONSerialization.data(withJSONObject: payload),
      let text = String(data: data, encoding: .utf8)
    else { return }
    do {
      try TiebaKvStore.shared.set(key: Self.diskKey, value: text)
    } catch {
      Self.log.error("avatar cache write failed: \(error.localizedDescription, privacy: .public)")
    }
  }
}
