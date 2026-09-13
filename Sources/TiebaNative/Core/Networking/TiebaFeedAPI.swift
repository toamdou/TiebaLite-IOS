// 发现页数据访问：推荐（proto cmd=309264）/ 关注（309474）信息流、热榜（309661）、
// 不感兴趣上报，以及首页 SWR 快照（与 JS 共用的 KV 键，只读）。
// 行字典一律经 TiebaViewModelMapper（与帖子页/话题页同一份信息流映射）。
import Foundation
import UIKit

enum TiebaFeedAPI {
  struct FeedPage {
    var items: [[String: Any]] = []
    var hasMore = false
  }

  struct UserLikePage {
    var items: [[String: Any]] = []
    var pageTag = ""
    var hasMore = false
  }

  struct Hot {
    struct Topic {
      var id = ""
      var name = ""
    }

    struct Tab {
      var code = ""
      var name = ""
    }

    struct Thread {
      var row: [String: Any] = [:]
      var hotNum = 0.0
      var agreeNum = 0.0
    }

    var topics: [Topic] = []
    var tabs: [Tab] = []
    var threads: [Thread] = []
    var hasMoreTopics = false
  }

  /// 推荐页容量（与 JS PERSONALIZED_PAGE_SIZE 同值：无 page 字段，翻页按条目数判）。
  static let personalizedPageSize = 11
  private static let snapshotKey = "@tiebalite:feed_snapshot_v1"

  /// 关注流增量时间戳（对齐 JS feed.ts 的模块级 lastSuccessRequestUnix）。
  nonisolated(unsafe) private static var lastUserLikeUnix = 0

  // MARK: - 推荐 / 关注

  static func personalized(loadType: Int, page: Int) async throws -> FeedPage {
    let data = try await TiebaForumAPI.protoPost(path: "/c/f/excellent/personalized", cmd: "309264") { common in
      var body = Tieba_PersonalizedRequestData()
      body.common = common
      body.loadType = UInt32(clamping: loadType)
      body.pn = UInt32(clamping: page)
      body.pageThreadCount = UInt32(personalizedPageSize)
      body.qType = 1
      body.newNetType = 1
      body.scrDip = 3
      body.scrH = 2532
      body.scrW = 1170
      body.appPos.apMac = "02:00:00:00:00:00"
      body.appPos.apConnected = true
      body.appPos.coordinateType = "BD09LL"
      var request = Tieba_PersonalizedRequest()
      request.data = body
      return request
    }
    let decoded = try TiebaSwiftProto.decode(
      messagePath: "tieba.personalized.PersonalizedResponse",
      bytes: data
    )
    try TiebaViewModelMapper.assertProtoSuccess(decoded)
    let items = TiebaViewModelMapper.mapResponse(
      mapper: "feedThreadList",
      decoded: decoded,
      options: [:]
    ) as? [[String: Any]] ?? []
    return FeedPage(items: items, hasMore: items.count >= personalizedPageSize)
  }

  static func userLike(pageTag: String, loadType: Int) async throws -> UserLikePage {
    let unix = lastUserLikeUnix
    let data = try await TiebaForumAPI.protoPost(path: "/c/f/concern/userlike", cmd: "309474") { common in
      var body = Tieba_UserLike_UserLikeRequestData()
      body.common = common
      body.pageTag = pageTag
      body.lastRequestUnix = UInt64(max(unix, 0))
      body.followType = 1
      body.loadType = Int32(clamping: loadType)
      var request = Tieba_UserLike_UserLikeRequest()
      request.data = body
      return request
    }
    let decoded = try TiebaSwiftProto.decode(
      messagePath: "tieba.userLike.UserLikeResponse",
      bytes: data
    )
    try TiebaViewModelMapper.assertProtoSuccess(decoded)
    let mapped = TiebaViewModelMapper.mapResponse(
      mapper: "userLike",
      decoded: decoded,
      options: [:]
    ) as? [String: Any] ?? [:]
    if let next = TiebaSimpleRowParser.double(mapped["requestUnix"]), next > 0 {
      lastUserLikeUnix = Int(next)
    }
    return UserLikePage(
      items: mapped["items"] as? [[String: Any]] ?? [],
      pageTag: mapped["pageTag"] as? String ?? "",
      hasMore: mapped["hasMore"] as? Bool ?? false
    )
  }

  // MARK: - 热榜

  static func hotThreadList(tabCode: String) async throws -> Hot {
    let data = try await TiebaForumAPI.protoPost(path: "/c/f/forum/hotThreadList", cmd: "309661") { common in
      var body = Tieba_HotThreadList_HotThreadListRequestData()
      body.common = common
      body.tabID = "1"
      body.tabCode = tabCode
      var request = Tieba_HotThreadList_HotThreadListRequest()
      request.data = body
      return request
    }
    let decoded = try TiebaSwiftProto.decode(
      messagePath: "tieba.hotThreadList.HotThreadListResponse",
      bytes: data
    )
    try TiebaViewModelMapper.assertProtoSuccess(decoded)
    guard let root = decoded["data"] as? [String: Any] else { return Hot() }

    var hot = Hot()
    for raw in (root["topicList"] as? [Any]) ?? [] {
      guard let item = raw as? [String: Any] else { continue }
      var topic = Hot.Topic()
      topic.id = TiebaSimpleRowParser.string(item["topicId"] ?? item["topic_id"]) ?? ""
      topic.name = TiebaSimpleRowParser.string(item["topicName"] ?? item["topic_name"]) ?? ""
      if !topic.id.isEmpty, !topic.name.isEmpty { hot.topics.append(topic) }
    }
    for raw in (root["hotThreadTabInfo"] as? [Any]) ?? [] {
      guard let item = raw as? [String: Any] else { continue }
      var tab = Hot.Tab()
      tab.code = TiebaSimpleRowParser.string(item["tabCode"] ?? item["tab_code"]) ?? ""
      tab.name = TiebaSimpleRowParser.string(item["tabName"] ?? item["tab_name"]) ?? ""
      if !tab.code.isEmpty, !tab.name.isEmpty { hot.tabs.append(tab) }
    }
    for raw in (root["threadInfo"] as? [Any]) ?? [] {
      guard let item = raw as? [String: Any] else { continue }
      var row = TiebaViewModelMapper.mapProtoThread(item)
      guard !row.isEmpty else { continue }
      // 吧名/吧头像兜底（同 TiebaFeedRowBuilder.make：热榜行同样缺 avatar）。
      let forum = TiebaFeedRowFallback.resolve(row)
      if !forum.name.isEmpty { row["forumName"] = forum.name }
      if !forum.avatar.isEmpty { row["forumAvatar"] = forum.avatar }
      var thread = Hot.Thread(row: row)
      thread.hotNum = TiebaSimpleRowParser.double(item["hotNum"] ?? item["hot_num"]) ?? 0
      let agree = item["agree"] as? [String: Any]
      thread.agreeNum = TiebaSimpleRowParser.double(
        item["agreeNum"] ?? item["agree_num"] ?? agree?["agreeNum"] ?? agree?["agree_num"]
      ) ?? 0
      hot.threads.append(thread)
    }
    // 话题只展示前 8 个（与旧页 slice(0, 8) 同）。
    hot.hasMoreTopics = hot.topics.count > 8
    return hot
  }

  // MARK: - 不感兴趣

  static func submitDislike(threadId: String, dislikeIds: String, forumId: String) async throws {
    let payload: [String: Any] = [
      "tid": threadId,
      "dislike_ids": dislikeIds,
      "fid": forumId,
      "click_time": Int(Date().timeIntervalSince1970 * 1000),
      "extra": "",
    ]
    guard let jsonData = try? JSONSerialization.data(withJSONObject: [payload]),
      let json = String(data: jsonData, encoding: .utf8)
    else { return }
    _ = try await TiebaSocialAPI.signedPost(
      path: "/c/c/excellent/submitDislike",
      fields: ["dislike": json, "dislike_from": "homepage"]
    )
  }

  // MARK: - 首屏 SWR 快照（JS 在推荐 page=1 成功后写入，原生只读）

  static func cachedSnapshot() -> [[String: Any]] {
    guard let raw = TiebaKvStore.shared.get(key: snapshotKey),
      let data = raw.data(using: .utf8),
      let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else { return [] }
    return list.filter { ($0["threadInfo"] as? [String: Any])?["id"] is String }
  }
}

/// 信息流行字典：ThreadInfo 映射输出 + 行级偏好（键名与 TiebaRowMetrics 的解析键对应）。
enum TiebaFeedRowBuilder {
  struct Options {
    var hideMedia = false
    var showIpLocation = true
    var showBothUsername = false
    var fontScale = 1.0
    var timestampStyle = "relative"
    var closeMenuOptions: [String] = ["block", "copy-title"]
    var imageContextMenu = false

    /// 每次出现现读偏好：过渡期原生只读共享偏好，不做订阅（见 TiebaPreferenceSnapshot）。
    static func current() -> Options {
      Options(
        hideMedia: TiebaPreferenceSnapshot.bool("hideMedia", default: false),
        showIpLocation: TiebaPreferenceSnapshot.bool("showIpLocation", default: true),
        showBothUsername: TiebaPreferenceSnapshot.bool("showBothUsername", default: false),
        fontScale: Double(TiebaPreferenceSnapshot.string("fontScale") ?? "") ?? 1,
        timestampStyle: TiebaPreferenceSnapshot.string("timestampStyle") ?? "relative"
      )
    }
  }

  static func make(thread: [String: Any], options: Options, expanded: Bool = false) -> [String: Any] {
    var row = thread
    // 吧名/吧头像回填（原 search.ts 的 forum_name ?? forumInfo.forum_name 与
    // feed.ts:97-118 backfillForumAvatars 的统一落点；服务端 forumInfo 恒空，
    // 缺名会让度量把整块吧徽章判为不渲染）。
    let forum = TiebaFeedRowFallback.resolve(thread)
    if !forum.name.isEmpty { row["forumName"] = forum.name }
    if !forum.avatar.isEmpty { row["forumAvatar"] = forum.avatar }
    row["kind"] = TiebaKindRowKind.feed.rawValue
    row["timeType"] = "create"
    row["expanded"] = expanded
    row["hideMedia"] = options.hideMedia
    row["showIpLocation"] = options.showIpLocation
    row["showBothUsername"] = options.showBothUsername
    row["fontScale"] = options.fontScale
    row["timestampStyle"] = options.timestampStyle
    row["closeMenuOptions"] = options.closeMenuOptions
    row["imageContextMenu"] = options.imageContextMenu
    row["showForumPill"] = true
    return row
  }
}

/// 信息流图片的「保存照片 / 分享照片」（原 JS PostImageContextMenu 的水印 + 相册 + 分享）。
@MainActor
enum TiebaFeedImageActions {
  static func save(url: String, forumName: String?, presenter: UIViewController?) {
    Task { @MainActor in
      do {
        let file = try await prepare(url: url, forumName: forumName)
        try await TiebaPhotoLibrary.saveFile(uri: file.absoluteString)
        TiebaSceneHaptics.fire("action-success")
        showToast("保存成功", on: presenter)
      } catch {
        TiebaSceneHaptics.fire("action-fail")
        showAlert(title: "保存失败", message: error.localizedDescription, on: presenter)
      }
    }
  }

  static func share(url: String, forumName: String?, presenter: UIViewController?, sourceRect: CGRect) {
    Task { @MainActor in
      do {
        let file = try await prepare(url: url, forumName: forumName)
        guard let presenter else { return }
        TiebaShareSheet.present(
          fileURL: file,
          dialogTitle: watermarkText(forumName: forumName).isEmpty
            ? "分享图片" : "分享图片 — \(watermarkText(forumName: forumName))",
          from: presenter,
          sourceRect: sourceRect
        )
      } catch {
        TiebaSceneHaptics.fire("action-fail")
        showAlert(title: "分享失败", message: error.localizedDescription, on: presenter)
      }
    }
  }

  /// 源图落到临时文件；有水印偏好时渲染水印（TiebaImageWatermark）。
  private static func prepare(url: String, forumName: String?) async throws -> URL {
    guard let target = URL(string: url) else { throw TiebaPhotoBrowserError.invalidImageData }
    // 走 TiebaPhotoBrowser 暴露的 Nuke 取数入口：Referer 注入 + DataCache 与
    // 查看器同一条管线；不要手写 URLSession（贴吧图床防盗链，且会分裂缓存）。
    let data = try await TiebaPhotoBrowserImageLoader.data(target)
    let temp = FileManager.default.temporaryDirectory
      .appendingPathComponent("feed-image-\(UUID().uuidString).jpg")
    try data.write(to: temp, options: .atomic)
    let text = watermarkText(forumName: forumName)
    guard !text.isEmpty else { return temp }
    let output = try await TiebaImageWatermark.applyWatermark(sourceUri: temp.absoluteString, text: text)
    guard let url = URL(string: output) else { return temp }
    return url
  }

  /// 与 JS resolveWatermarkText 同判据：username = 当前账号昵称，forum_name = 吧名。
  static func watermarkText(forumName: String?) -> String {
    guard TiebaPreferenceSnapshot.bool("imageWatermarkEnabled", default: false) else { return "" }
    switch TiebaPreferenceSnapshot.string("imageWatermark") ?? "none" {
    case "username": return accountName()
    case "forum_name": return forumName ?? ""
    default: return ""
    }
  }

  /// 账号昵称：冷启动档案缓存（AuthSecureStorage 的无凭据缓存，与 JS 同一份 KV）。
  private static func accountName() -> String {
    guard let raw = TiebaKvStore.shared.get(key: "@tiebalite:account_profile_cache_v1"),
      let data = raw.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return "" }
    return object["name"] as? String ?? object["nameShow"] as? String ?? ""
  }

  private static func showToast(_ text: String, on presenter: UIViewController?) {
    guard let presenter else { return }
    let pill = TiebaPhotoBrowserPillView()
    presenter.view.addSubview(pill)
    pill.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      pill.centerXAnchor.constraint(equalTo: presenter.view.centerXAnchor),
      pill.bottomAnchor.constraint(
        equalTo: presenter.view.safeAreaLayoutGuide.bottomAnchor,
        constant: -24
      ),
    ])
    pill.showResult(success: true, text: text)
  }

  private static func showAlert(title: String, message: String, on presenter: UIViewController?) {
    guard let presenter, presenter.presentedViewController == nil else { return }
    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "好", style: .default))
    presenter.present(alert, animated: true)
  }
}

/// 通用行字典的主题色（行字典的 colors 子字典只认 hex/rgba 串；映射与吧务页同）。
@MainActor
enum TiebaRowTheme {
  static func colors() -> [String: String] {
    let palette = TiebaSimpleRowPalette.default
    let dark = TiebaNavigator.shared.chromeTheme.dark
    let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)

    func hex(_ color: UIColor) -> String {
      let resolved = color.resolvedColor(with: traits)
      var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
      resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
      if a >= 0.999 {
        return String(
          format: "#%02X%02X%02X",
          Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded())
        )
      }
      return String(
        format: "rgba(%d,%d,%d,%.2f)",
        Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()), a
      )
    }

    let tint = TiebaNavigator.shared.chromeTheme.tint
    return [
      "primary": hex(tint),
      "primarySoft": hex(tint.withAlphaComponent(0.12)),
      "card": hex(palette.base.card),
      "groupFill": hex(palette.groupFill),
      "surfaceSecondary": hex(palette.surfaceSecondary),
      "textTertiary": hex(palette.base.textTertiary),
      "textDisabled": hex(palette.textDisabled),
      "divider": hex(palette.divider),
      "chevronColor": hex(palette.textDisabled),
      "borderColor": hex(palette.divider),
    ]
  }
}

/// 信息流过滤（对齐 JS FeedContent.visibleItems：广告/直播开关 + 屏蔽词/屏蔽用户）。
enum TiebaFeedFilter {
  static func visible(_ items: [[String: Any]], filterAds: Bool) -> [[String: Any]] {
    // 一页一次：屏蔽词在这里预编译（此前逐行逐词现编 NSRegularExpression，
    // O(行×词) 次编译；正则只编一次）。
    let rules = Rules.load()
    let users = TiebaBlockStore.users()
    return items.filter { item in
      guard let thread = item["threadInfo"] as? [String: Any] else { return true }
      if filterAds, TiebaViewModelMapper.isAdThreadInfo(thread) { return false }
      if !rules.isEmpty {
        let text = "\(thread["title"] as? String ?? "") \(thread["abstract"] as? String ?? "")"
        if rules.blocks(text) { return false }
      }
      if !users.isEmpty {
        let uid = thread["authorId"] as? String ?? ""
        let name = thread["authorName"] as? String ?? ""
        if users.contains(where: { $0.uid == uid || (!name.isEmpty && $0.username == name) }) {
          return false
        }
      }
      return true
    }
  }

  /// 页级屏蔽词表（正则已编译）；匹配判据与 BlockManager.shouldBlockContent 同。
  private struct Rules {
    private struct Word {
      let keyword: String
      let isRegex: Bool
      /// isRegex 且编译成功时非 nil；编译失败按"不匹配"处理（迁移前同判据）。
      let regex: NSRegularExpression?
      let whitelist: Bool
    }

    private let words: [Word]
    var isEmpty: Bool { words.isEmpty }

    static func load() -> Rules {
      Rules(words: TiebaBlockStore.words().compactMap { word in
        guard !word.keyword.isEmpty else { return nil }
        return Word(
          keyword: word.keyword,
          isRegex: word.isRegex == true,
          regex: word.isRegex == true ? try? NSRegularExpression(pattern: word.keyword) : nil,
          whitelist: word.isWhitelist
        )
      })
    }

    /// 白名单命中即放行；黑名单按子串 / 正则。
    func blocks(_ content: String) -> Bool {
      if words.contains(where: { $0.whitelist && matches(content, $0) }) { return false }
      return words.contains { !$0.whitelist && matches(content, $0) }
    }

    private func matches(_ content: String, _ word: Word) -> Bool {
      guard word.isRegex else { return content.contains(word.keyword) }
      guard let regex = word.regex else { return false }
      let range = NSRange(content.startIndex..<content.endIndex, in: content)
      return regex.firstMatch(in: content, range: range) != nil
    }
  }
}
