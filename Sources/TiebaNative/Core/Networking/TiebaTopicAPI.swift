// 话题详情（原 src/services/api/endpoints/misc.ts 的 topicDetail）：tieba.baidu.com 的
// web JSON 端点（无 common params / 无签名，仅 Cookie 认证），行字典由
// TiebaViewModelMapper.mapProtoThread 生成 —— 与 info 流卡片同一份映射。
import Foundation

struct TiebaTopicDetail {
  struct Forum {
    var name = ""
    var avatar = ""
  }

  /// 话题信息（proto 原始字段 snake_case；缺失 = 降级成居中标题页头）。
  var hasInfo = false
  var discussNum: Double?
  var desc: String?

  var forums: [Forum] = []
  /// 行视图模型（mapProtoThread 输出，视图键名与 src/types ThreadInfo 一致）。
  var threads: [[String: Any]] = []
  /// 与旧页同判据：本页条数 >= 10（rn）即认为还有下一页。
  var hasMore = false
}

enum TiebaTopicAPI {
  static func detail(topicId: String, topicName: String, page: Int) async throws -> TiebaTopicDetail {
    let body = try await webGET(
      path: "/mo/q/newtopic/topicDetail",
      query: [
        "topic_id": topicId,
        "topic_name": topicName,
        "is_new": "1",
        "is_share": "1",
        "pn": String(page),
        "rn": "10",
      ]
    )
    let data = (body["data"] as? [String: Any]) ?? body
    let info = (data["topic_info"] ?? data["topicInfo"]) as? [String: Any]

    var detail = TiebaTopicDetail()
    detail.hasInfo = info != nil
    detail.discussNum = TiebaSimpleRowParser.double(
      info?["discuss_num"] ?? info?["discussNum"]
    )
    detail.desc = TiebaSimpleRowParser.nonEmpty(
      info?["topic_desc"] ?? info?["topicDesc"] ?? info?["desc"]
    )
    detail.forums = forums(from: data, info: info)

    // relate_thread.thread_list 优先；话题页不做 ala_info 广告过滤（与旧 Kotlin/JS 一致）。
    let relate = data["relate_thread"] as? [String: Any]
    let rawThreads = (relate?["thread_list"] as? [Any]) ?? (data["thread_list"] as? [Any]) ?? []
    for item in rawThreads {
      guard let raw = item as? [String: Any] else { continue }
      let model = TiebaViewModelMapper.mapProtoThread(raw["thread_info"] ?? raw)
      guard !model.isEmpty else { continue }
      detail.threads.append(model)
    }
    detail.hasMore = detail.threads.count >= 10
    return detail
  }

  /// 相关吧：老/新 proto 与 web 形状共存（forum_name / forumName / name 三种键）。
  private static func forums(from data: [String: Any], info: [String: Any]?) -> [TiebaTopicDetail.Forum] {
    let raw =
      data["relate_forum"] ?? data["relateForum"] ?? data["related_forum"]
      ?? info?["relate_forum"] ?? info?["relateForum"]
    // 数组或对象（对象取 values，对齐旧页 Object.values 分支）。
    let list: [Any]
    if let array = raw as? [Any] {
      list = array
    } else if let object = raw as? [String: Any] {
      list = Array(object.values)
    } else {
      return []
    }
    return list.compactMap { element in
      guard let item = element as? [String: Any] else { return nil }
      guard let name = TiebaSimpleRowParser.nonEmpty(
        item["forum_name"] ?? item["forumName"] ?? item["name"]
      ) else { return nil }
      var forum = TiebaTopicDetail.Forum()
      forum.name = name
      forum.avatar = TiebaSimpleRowParser.string(item["avatar"] ?? item["pic"]) ?? ""
      return forum
    }
  }

  // MARK: - 传输

  /// web 通道：common headers + auth cookie（与 JS tiebaWebClient 的 web variant 同值）。
  private static func webGET(path: String, query: [String: String]) async throws -> [String: Any] {
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
      requestId: "native-topic-\(UUID().uuidString)",
      timeoutMs: 15000
    )
    guard (200..<300).contains(response.status) else { throw TiebaForumAPIError.http(response.status) }
    guard let data = response.body.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { throw TiebaForumAPIError.invalidResponse }
    return object
  }
}
