// 帖子详情数据访问（原 src/services/api/endpoints/thread.ts 的 pbPage）。
// 与 TiebaForumAPI 同一条 v12 proto 传输；本文件解码生成类型后直接产出**类型化**
// 视图模型（原生页面不再需要 JSON 字典/描述符注册表，也就不再依赖 JS 的 protoInitialize）。
import Foundation
import SwiftProtobuf

// MARK: - 视图模型

enum TiebaThreadContentSegment: Sendable {
  case text(String)
  case emoji(String)
  case emoticon(name: String, src: String)
  case image(TiebaThreadImage)
  case video(TiebaThreadVideo)
  case audio(src: String, duration: Double)
  case link(text: String, url: String)
  case at(uid: String, text: String)
}

struct TiebaThreadImage: Sendable {
  var src = ""
  var originSrc = ""
  var width = 0.0
  var height = 0.0
  var isGif = false
  var isLongPic = false
  var showOriginalBtn = false

  var aspect: Double {
    width > 0 && height > 0 ? width / height : 1
  }

  /// 竖长图（MediaPager.tsx:121 LONG_IMAGE_RATIO = 2.4）。
  var isTall: Bool {
    width > 0 && height > 0 && height / width > 2.4
  }
}

struct TiebaThreadVideo: Sendable {
  var src = ""
  var poster = ""
  var width = 280.0
  var height = 158.0

  var aspect: Double {
    width > 0 && height > 0 ? width / height : 16.0 / 9.0
  }
}

struct TiebaThreadSubPost: Sendable {
  var id = ""
  var authorId = ""
  var authorName = ""
  var authorNameShow = ""
  var authorPortrait = ""
  var authorLevel = 0
  var content: [TiebaThreadContentSegment] = []
  var createTimeMs = 0.0

  var displayName: String {
    authorNameShow.isEmpty ? authorName : authorNameShow
  }
}

struct TiebaThreadPost: Sendable {
  var id = ""
  var floor = 0
  var authorId = ""
  var authorName = ""
  var authorNameShow = ""
  var authorPortrait = ""
  var authorLevel = 0
  /// 该吧等级头衔（User.level_name，服务端随作者一起下发，如「F2.8」）。
  var authorLevelName = ""
  var content: [TiebaThreadContentSegment] = []
  var createTimeMs = 0.0
  var ipLocation = ""
  var subPosts: [TiebaThreadSubPost] = []
  var subPostNum = 0
  var agreeNum = 0
  var isAgree = false

  var displayName: String {
    authorNameShow.isEmpty ? authorName : authorNameShow
  }

  var images: [TiebaThreadImage] {
    content.compactMap {
      if case .image(let image) = $0 { return image }
      return nil
    }
  }

  /// contentToText（src/utils/index.ts）：@ 带前缀，文本类段拼接，媒体段跳过。
  var plainText: String {
    content.map { segment in
      switch segment {
      case .text(let text), .emoji(let text), .emoticon(let text, _): return text
      case .at(_, let text): return "@\(text)"
      case .link(let text, _): return text
      case .image, .video, .audio: return ""
      }
    }.joined()
  }
}

struct TiebaThreadInfo: Sendable {
  var id = ""
  var title = ""
  var forumId = ""
  var forumName = ""
  var forumAvatar = ""
  var authorId = ""
  var authorName = ""
  var authorNameShow = ""
  var authorPortrait = ""
  var authorLevel = 0
  var authorIp = ""
  var replyNum = 0
  var viewNum = 0
  var zanNum = 0
  var hasAgree = false
  var createTimeMs = 0.0
  var firstPostId = ""

  var displayName: String {
    authorNameShow.isEmpty ? authorName : authorNameShow
  }
}

struct TiebaThreadPage: Sendable {
  var thread: TiebaThreadInfo?
  var posts: [TiebaThreadPost] = []
  var current = 1
  var total = 0
  var hasMore = false
}

/// 楼中楼一页：floorPost = 目标楼层本体（nil = 服务端未下发）。
struct TiebaThreadFloorPage: Sendable {
  var floorPost: TiebaThreadPost?
  var subPosts: [TiebaThreadPost] = []
  var current = 1
  var total = 0
  var hasMore = false
}

// MARK: - 数据访问

enum TiebaThreadAPI {
  static func page(
    threadId: String,
    page: Int,
    postId: String?,
    seeLz: Bool,
    sort: TiebaThreadSort
  ) async throws -> TiebaThreadPage {
    guard !threadId.isEmpty else { throw TiebaForumAPIError.invalidURL }
    let data = try await TiebaForumAPI.protoPost(path: "/c/f/pb/page", cmd: "302001&format=protobuf") { common in
      var request = Tieba_PbPage_PbPageRequestData()
      request.common = common
      request.kz = Int64(threadId) ?? 0
      if let postId, let pid = Int64(postId) { request.pid = pid }
      request.pn = Int32(page)
      // r = 排序档位（热门 2 / 正序 0 / 倒序 1），服务端自己在 pb_sort_info 里列的
      // 就是这三档（实测：热门档回的是按热度重排、不带楼层的列表）。
      request.r = Int32(sort.rawValue)
      request.lz = seeLz ? 1 : 0
      // 与 JS encodePbPageRequest 的非零常量逐项一致（其余保持 proto 默认 0）。
      request.rn = 15
      request.withFloor = 1
      request.floorRn = 4
      request.floorSortType = 1
      request.qType = 2
      request.sourceType = 2
      request.objParam1 = "10"
      request.scrW = 1170
      request.scrH = 2532
      request.scrDip = 3
      var wrapper = Tieba_PbPage_PbPageRequest()
      wrapper.data = request
      return wrapper
    }
    let response = try Tieba_PbPage_PbPageResponse(serializedBytes: data)
    if response.hasError, response.error.errorCode != 0 {
      throw TiebaViewModelError(
        code: Double(response.error.errorCode),
        message: response.error.errorMsg
      )
    }
    guard response.hasData else { throw TiebaForumAPIError.invalidResponse }
    return makePage(response.data, threadId: threadId, page: page)
  }

  /// 楼中楼（原 endpoints/thread.ts 的 pbFloor，cmd=302002）：floorPost = 目标
  /// 楼层本体（楼中楼页顶部父楼的权威来源），subPosts 按时间升序分页。
  static func floor(
    threadId: String,
    postId: String,
    forumId: String,
    page: Int
  ) async throws -> TiebaThreadFloorPage {
    guard !threadId.isEmpty, !postId.isEmpty else { throw TiebaForumAPIError.invalidURL }
    let data = try await TiebaForumAPI.protoPost(path: "/c/f/pb/floor", cmd: "302002&format=protobuf") { common in
      var request = Tieba_PbFloor_PbFloorRequestData()
      request.common = common
      request.kz = Int64(threadId) ?? 0
      request.pid = Int64(postId) ?? 0
      request.pn = Int32(page)
      request.forumID = Int64(forumId) ?? 0
      // 与 JS encodePbFloorRequest 的非零常量逐项一致（其余保持 proto 默认 0）。
      request.scrW = 1170
      request.scrH = 2532
      request.scrDip = 3
      request.isCommReverse = 0
      request.oriUgcType = 0
      var wrapper = Tieba_PbFloor_PbFloorRequest()
      wrapper.data = request
      return wrapper
    }
    let response = try Tieba_PbFloor_PbFloorResponse(serializedBytes: data)
    if response.hasError, response.error.errorCode != 0 {
      throw TiebaViewModelError(
        code: Double(response.error.errorCode),
        message: response.error.errorMsg
      )
    }
    guard response.hasData else { throw TiebaForumAPIError.invalidResponse }
    return makeFloorPage(response.data, threadId: threadId, page: page)
  }

  // MARK: - 映射（语义对齐 JS thread.ts 的 pbPage 投影；本页直接读生成类型）

  private static func makePage(
    _ data: Tieba_PbPage_PbPageResponseData,
    threadId: String,
    page: Int
  ) -> TiebaThreadPage {
    var result = TiebaThreadPage()
    let users = userMap(data.userList)


    var posts = data.postList.map { post($0, threadId: threadId, users: users) }
    // firstFloorPost 恒并入头部（倒序时楼主楼可能只在这里下发）；按 id 去重。
    if data.hasFirstFloorPost, data.firstFloorPost.id != 0 || !data.firstFloorPost.content.isEmpty {
      let first = post(data.firstFloorPost, threadId: threadId, users: users)
      if !posts.contains(where: { $0.id == first.id }) {
        posts.insert(first, at: 0)
      }
    }
    result.posts = posts
    if data.hasThread {
      result.thread = thread(data.thread, forum: data.hasForum ? data.forum : nil)
      // 主贴图片兜底（"只有标题+图片"的帖子）：首楼正文里没有图片/视频段时，图片
      // 取线程级字段——信息流卡片读的就是 thread.media，列表看得见图、点进来必然
      // 也看得见（2026-09-15 用户报"外面有图、点进去没有"）。两个线程级字段服务端
      // 不保证都下发，故按 media → firstPostContent（首楼全文）顺序取第一个有图的。
      // 只补第一页的主贴（floor == 1，与详情页钉主贴同一判据）。
      if page == 1, let index = result.posts.firstIndex(where: { $0.floor == 1 }) {
        appendMainPostImages(
          to: &result.posts[index],
          media: data.thread.media,
          firstPostContent: data.thread.firstPostContent
        )
      }
    }

    let current = data.page.currentPage > 0 ? Int(data.page.currentPage) : page
    let total = data.page.totalPage > 0 ? Int(data.page.totalPage) : Int(data.page.totalCount)
    result.current = current
    result.total = total
    result.hasMore = total > 0 ? current < total : data.page.hasMore_p == 1
    return result
  }

  /// 首楼正文无图片/视频段时补图片段：先按线程级 media（含宽高，与信息流同源），
  /// 空则退 firstPostContent 里的图片段。正文里已有图片或视频就不补——视频贴的
  /// media 是同一支视频的封面，补上去会多出一张静止图。
  private static func appendMainPostImages(
    to post: inout TiebaThreadPost,
    media: [Tieba_Media],
    firstPostContent: [Tieba_PbContent]
  ) {
    let hasVisual = post.content.contains {
      switch $0 {
      case .image, .video: return true
      default: return false
      }
    }
    guard !hasVisual else { return }
    // media 优先（带宽高、与信息流卡片同一份数据）；它没图才退 firstPostContent。
    var images = media.compactMap(image)
    if images.isEmpty {
      images = content(firstPostContent).compactMap {
        if case .image(let image) = $0 { return image }
        return nil
      }
    }
    guard !images.isEmpty else { return }
    post.content.append(contentsOf: images.map { .image($0) })
  }

  /// 线程级 media → 图片段。字段语义与正文图片段同一套：src = 显示档、originSrc =
  /// 「查看原图」档（media 的 bigPic/srcPic/originPic 对应图床的大/小/原图三档）。
  private static func image(_ media: Tieba_Media) -> TiebaThreadImage? {
    let display = firstNonEmpty(media.bigPic, media.srcPic, media.originPic)
    guard !display.isEmpty else { return nil }
    var image = TiebaThreadImage()
    image.src = display
    image.originSrc = firstNonEmpty(media.originPic, media.bigPic, media.srcPic)
    image.isGif = [media.dynamicPic, media.originPic, media.bigPic, media.srcPic]
      .contains { TiebaViewModelMapper.hasGifSuffix($0) }
    image.width = media.width == 0 ? 300 : Double(media.width)
    image.height = media.height == 0 ? 300 : Double(media.height)
    image.isLongPic = media.isLongPic != 0
    image.showOriginalBtn = media.showOriginalBtn != 0
    return image
  }

  private static func makeFloorPage(
    _ data: Tieba_PbFloor_PbFloorResponseData,
    threadId: String,
    page: Int
  ) -> TiebaThreadFloorPage {
    var result = TiebaThreadFloorPage()
    // 楼层本体：用户表不随本响应下发（与 JS mapProtoPosts([data.post]) 同路径，
    // author 只从内嵌对象取）。
    if data.hasPost, data.post.id != 0 || !data.post.content.isEmpty {
      result.floorPost = post(data.post, threadId: threadId, users: [:])
    }
    result.subPosts = data.subpostList.compactMap(subPost)
    let current = data.page.currentPage > 0 ? Int(data.page.currentPage) : page
    let total = data.page.totalPage > 0 ? Int(data.page.totalPage) : Int(data.page.totalCount)
    result.current = current
    result.total = total
    result.hasMore = total > 0 ? current < total : data.page.hasMore_p == 1
    return result
  }

  /// 楼中楼行：与主帖共用同一套内容解码；楼层/属地不适用（旧页行只显示时间）。
  private static func subPost(_ raw: Tieba_SubPostList) -> TiebaThreadPost? {
    guard raw.id != 0 || !raw.content.isEmpty else { return nil }
    var post = TiebaThreadPost()
    post.id = String(raw.id)
    post.createTimeMs = TiebaViewModelMapper.toMillis(Double(raw.time))
    post.content = content(raw.content)
    post.agreeNum = Int(raw.agree.agreeNum)
    post.isAgree = raw.agree.hasAgree_p == 1
    let authorId = raw.authorID != 0 ? raw.authorID : raw.author.id
    let author = raw.hasAuthor ? raw.author : Tieba_User()
    post.authorId = String(authorId)
    post.authorName = author.name
    post.authorNameShow = author.nameShow.isEmpty ? author.name : author.nameShow
    post.authorPortrait = author.portrait
    post.authorLevel = Int(author.levelID)
    post.authorLevelName = author.levelName
    return post
  }

  private static func userMap(_ users: [Tieba_User]) -> [String: Tieba_User] {
    var map: [String: Tieba_User] = [:]
    for user in users where user.id != 0 {
      map[String(user.id)] = user
    }
    return map
  }

  /// IP 属地：服务端下发的是 ip_address(127)，ip(28) 多为空；JS 的兜底链同样先取
  /// ipAddress 再落回 ip。
  private static func authorIp(_ author: Tieba_User) -> String {
    author.ipAddress.isEmpty ? author.ip : author.ipAddress
  }

  private static func thread(_ raw: Tieba_ThreadInfo, forum: Tieba_SimpleForum?) -> TiebaThreadInfo {
    var info = TiebaThreadInfo()
    info.id = String(raw.id != 0 ? raw.id : raw.threadID)
    info.title = raw.title
    info.forumId = String(raw.forumID != 0 ? raw.forumID : (forum?.id ?? 0))
    info.forumName = raw.forumName.isEmpty ? (forum?.name ?? "") : raw.forumName
    info.forumAvatar = forum?.avatar ?? ""
    let author = raw.hasAuthor ? raw.author : Tieba_User()
    info.authorId = String(author.id != 0 ? author.id : raw.authorID)
    info.authorName = author.name
    info.authorNameShow = author.nameShow.isEmpty ? author.name : author.nameShow
    info.authorPortrait = author.portrait
    info.authorLevel = Int(author.levelID)
    info.authorIp = authorIp(author)
    info.replyNum = Int(raw.replyNum)
    info.viewNum = Int(raw.viewNum)
    info.zanNum = Int(raw.agreeNum)
    info.hasAgree = raw.agree.hasAgree_p == 1
    info.createTimeMs = TiebaViewModelMapper.toMillis(Double(raw.createTime))
    info.firstPostId = String(raw.firstPostID != 0 ? raw.firstPostID : raw.id)
    return info
  }

  private static func post(
    _ raw: Tieba_Post,
    threadId: String,
    users: [String: Tieba_User]
  ) -> TiebaThreadPost {
    var post = TiebaThreadPost()
    post.id = String(raw.id)
    post.floor = Int(raw.floor)
    post.createTimeMs = TiebaViewModelMapper.toMillis(Double(raw.time))
    post.content = content(raw.content)
    post.subPostNum = Int(raw.subPostNumber)
    post.agreeNum = Int(raw.agree.agreeNum)
    post.isAgree = raw.agree.hasAgree_p == 1

    let authorId = raw.authorID != 0 ? raw.authorID : raw.author.id
    let author = raw.hasAuthor ? raw.author : (users[String(authorId)] ?? Tieba_User())
    post.authorId = String(authorId)
    post.authorName = author.name
    post.authorNameShow = author.nameShow.isEmpty ? author.name : author.nameShow
    post.authorPortrait = author.portrait
    post.authorLevel = Int(author.levelID)
    post.authorLevelName = author.levelName
    post.ipLocation = authorIp(author)

    // UI 预览最多 3 条楼中楼（完整楼中楼走楼中楼页）。
    let subPosts = raw.hasSubPostList ? raw.subPostList.subPostList : []
    post.subPosts = subPosts.prefix(3).compactMap { sub in
      guard sub.id != 0 || !sub.content.isEmpty else { return nil }
      var item = TiebaThreadSubPost()
      item.id = String(sub.id)
      let subAuthorId = sub.authorID != 0 ? sub.authorID : sub.author.id
      let subAuthor = sub.hasAuthor ? sub.author : (users[String(subAuthorId)] ?? Tieba_User())
      item.authorId = String(subAuthorId)
      item.authorName = subAuthor.name
      item.authorNameShow = subAuthor.nameShow.isEmpty ? subAuthor.name : subAuthor.nameShow
      item.authorPortrait = subAuthor.portrait
      item.authorLevel = Int(subAuthor.levelID)
      item.content = content(sub.content)
      item.createTimeMs = TiebaViewModelMapper.toMillis(Double(sub.time))
      _ = threadId
      return item
    }
    return post
  }

  private static func content(_ raw: [Tieba_PbContent]) -> [TiebaThreadContentSegment] {
    raw.compactMap { element in
      switch element.type {
      case 3, 20:
        var image = TiebaThreadImage()
        var width = Double(element.width)
        var height = Double(element.height)
        if width == 0 || height == 0 {
          let parts = element.bsize.split(separator: ",")
          if parts.count == 2 {
            width = Double(parts[0]) ?? width
            height = Double(parts[1]) ?? height
          }
        }
        image.width = width == 0 ? 300 : width
        image.height = height == 0 ? 300 : height
        image.src = firstNonEmpty(element.cdnSrc, element.bigCdnSrc, element.cdnSrcActive, element.src)
        image.originSrc = firstNonEmpty(element.originSrc, element.bigSrc, element.bigCdnSrc, element.src)
        image.isGif = [
          element.dynamic, element.cdnSrc, element.bigCdnSrc,
          element.cdnSrcActive, element.originSrc, element.bigSrc, element.src,
        ].contains { TiebaViewModelMapper.hasGifSuffix($0) }
        image.isLongPic = element.isLongPic != 0
        image.showOriginalBtn = element.showOriginalBtn != 0
        return .image(image)

      case 2:
        let name = element.c
        if !name.isEmpty, let number = TiebaViewModelMapper.emoticonNumber(named: name) {
          return .emoticon(name: name, src: TiebaViewModelMapper.buildEmoticonSrc(number))
        }
        let text = element.text
        if let number = TiebaViewModelMapper.imageEmoticonNumber(text) {
          return .emoticon(name: text, src: TiebaViewModelMapper.buildEmoticonSrc(number))
        }
        if text.hasPrefix("(#"), text.hasSuffix(")"), text.count > 3 {
          let stripped = String(text.dropFirst(2).dropLast(1))
          if !stripped.isEmpty, let number = TiebaViewModelMapper.emoticonNumber(named: stripped) {
            return .emoticon(name: stripped, src: TiebaViewModelMapper.buildEmoticonSrc(number))
          }
        }
        if let number = TiebaViewModelMapper.emoticonNumber(named: text) {
          return .emoticon(name: text, src: TiebaViewModelMapper.buildEmoticonSrc(number))
        }
        return .emoji(name.isEmpty ? text : name)

      case 1:
        return .link(text: element.text.isEmpty ? element.link : element.text, url: element.link.isEmpty ? element.text : element.link)

      case 5:
        return .video(TiebaThreadVideo(
          src: firstNonEmpty(element.link, element.src),
          poster: firstNonEmpty(element.cdnSrc, element.src),
          width: element.width == 0 ? 280 : Double(element.width),
          height: element.height == 0 ? 158 : Double(element.height)
        ))

      case 9:
        let md5 = element.voiceMd5
        let src = md5.isEmpty
          ? element.src
          : "https://tiebac.baidu.com/c/p/voice?voice_md5=\(md5)&play_from=pb_voice_play"
        return .audio(src: src, duration: Double(element.duringTime))

      case 4:
        return .at(uid: String(element.uid), text: element.text)

      default:
        return .text(element.text)
      }
    }
  }

  private static func firstNonEmpty(_ values: String...) -> String {
    values.first { !$0.isEmpty } ?? ""
  }
}
