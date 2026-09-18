// 帖子行模型 + 高度缓存（thread/[id] 原生页）：与 TiebaRowMetrics 同架构——
// 原生 VC 在后台队列一次性测量整页，行视图按 (pageKey, index) 同步取模型。
//
// 行高只在这里算一次；TiebaPostRowView 只按 model.plan 摆 frame（测多少画多少）。
// 页面数据是原生类型（TiebaThreadPost），不经过 JS 字典。
import UIKit
import Nuke

// MARK: - 显示偏好（每次整页 prepare 现读，过渡期只读共享偏好）

struct TiebaPostPreferences: Sendable {
  var showIpLocation = true
  var showLevelBadge = true
  /// 等级徽标后面接头衔名（如「Lv.5 F2.8」；头衔随作者字段下发）。
  var showLevelTitle = false
  var showBothUsername = false
  var fontScale: CGFloat = 1
  var hideMedia = false
  var blockVideo = false
  var imageDarkenWhenNight = false
  var imageLoadType = "smart_origin"
  var dataSaverMode = "high"
  var isNight = false
  var timestampStyle = "relative"
  var videoAutoplay = false
  /// 1px hairline：trait 的 displayScale 只在 UIKit 上下文非 0（测量在后台队列），
  /// 所以由主线程的 load() 取好、随偏好一起传入（UIScreen.main 自 iOS 26 废弃）。
  var hairline: CGFloat = 1.0 / 3.0

  @MainActor
  static func load() -> TiebaPostPreferences {
    var prefs = TiebaPostPreferences()
    prefs.showIpLocation = TiebaPreferenceSnapshot.bool("showIpLocation", default: true)
    prefs.showLevelBadge = TiebaPreferenceSnapshot.bool("showLevelBadge", default: true)
    prefs.showLevelTitle = TiebaPreferenceSnapshot.bool("showLevelTitle", default: false)
    prefs.showBothUsername = TiebaPreferenceSnapshot.bool("showBothUsername", default: false)
    prefs.fontScale = CGFloat(Double(TiebaPreferenceSnapshot.string("fontScale") ?? "") ?? 1)
    prefs.hideMedia = TiebaPreferenceSnapshot.bool("hideMedia", default: false)
    prefs.blockVideo = TiebaPreferenceSnapshot.bool("blockVideo", default: false)
    prefs.imageDarkenWhenNight = TiebaPreferenceSnapshot.bool("imageDarkenWhenNight", default: false)
    prefs.imageLoadType = TiebaPreferenceSnapshot.string("imageLoadType") ?? "smart_origin"
    prefs.dataSaverMode = TiebaPreferenceSnapshot.string("dataSaverMode") ?? "high"
    prefs.timestampStyle = TiebaPreferenceSnapshot.string("timestampStyle") ?? "relative"
    prefs.videoAutoplay = TiebaPreferenceSnapshot.bool("videoAutoplay", default: false)
    prefs.hairline = 1 / max(UITraitCollection.current.displayScale, 1)
    prefs.isNight = TiebaNavigator.shared.chromeTheme.dark
    return prefs
  }

  var fontScaleClamped: CGFloat { min(max(fontScale, 0.8), 2.0) }
}

// MARK: - 屏蔽过滤（BlockManager.shouldBlockContent / shouldBlockUser 的原生等价）

struct TiebaPostBlockFilter: Sendable {
  /// NSRegularExpression 未标 Sendable 但线程安全（Apple 文档）；跨线程只读。
  struct Word: @unchecked Sendable {
    var keyword = ""
    var regex: NSRegularExpression?
    var whitelist = false
  }

  var words: [Word] = []
  var users: [(uid: String, name: String)] = []

  static func load() -> TiebaPostBlockFilter {
    var filter = TiebaPostBlockFilter()
    filter.words = TiebaBlockStore.words().compactMap { word in
      guard !word.keyword.isEmpty else { return nil }
      return Word(
        keyword: word.keyword,
        regex: word.isRegex == true ? try? NSRegularExpression(pattern: word.keyword) : nil,
        whitelist: word.isWhitelist
      )
    }
    filter.users = TiebaBlockStore.users().map { ($0.uid, $0.username ?? "") }
    return filter
  }

  func isContentBlocked(_ text: String) -> Bool {
    guard !text.isEmpty else { return false }
    var hit = false
    for word in words {
      let matched = word.regex.map {
        $0.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
      } ?? text.contains(word.keyword)
      guard matched else { continue }
      if word.whitelist { return false }
      hit = true
    }
    return hit
  }

  func isUserBlocked(uid: String, name: String) -> Bool {
    users.contains { $0.uid == uid || (!name.isEmpty && $0.name == name) }
  }
}

// MARK: - 富文本装配

struct TiebaPostTextBuild {
  var attributed: NSAttributedString?
  var hasBlockedTip = false
  var missingEmoticons: [String] = []
}

/// 内联段 → NSAttributedString（表情文本拆包 / 屏蔽过滤 / @·外链跳转属性）。
enum TiebaPostRowText {
  static func build(
    _ post: TiebaThreadPost,
    preferences: TiebaPostPreferences,
    blockFilter: TiebaPostBlockFilter,
    palette: TiebaFeedRowPalette
  ) -> TiebaPostTextBuild {
    buildContent(
      post.content,
      preferences: preferences,
      blockFilter: blockFilter,
      palette: palette
    ).build
  }

  static func buildContent(
    _ content: [TiebaThreadContentSegment],
    preferences: TiebaPostPreferences,
    blockFilter: TiebaPostBlockFilter,
    palette: TiebaFeedRowPalette,
    isSubPost: Bool = false
  ) -> (build: TiebaPostTextBuild, images: [TiebaThreadImage]) {
    let scale = preferences.fontScaleClamped
    let fontSize = (isSubPost ? 14 : 15) * scale
    let lineHeight = (isSubPost ? 20 : 22) * scale
    let paragraph = NSMutableParagraphStyle()
    paragraph.minimumLineHeight = lineHeight
    paragraph.maximumLineHeight = lineHeight
    // 楼中楼预览恒两行截断（UILabel 的 numberOfLines 之外还看段落样式这一项），
    // 楼层正文按字换行（截断交给行高的最大行数）。
    paragraph.lineBreakMode = isSubPost ? .byTruncatingTail : .byWordWrapping
    let base: [NSAttributedString.Key: Any] = [
      .font: UIFont.systemFont(ofSize: fontSize, weight: .medium),
      .foregroundColor: palette.text,
      .paragraphStyle: paragraph,
    ]
    var build = TiebaPostTextBuild()
    var images: [TiebaThreadImage] = []
    let result = NSMutableAttributedString()

    for segment in content {
      switch segment {
      case .image(let image):
        images.append(image)
        continue
      case .video, .audio:
        continue
      default:
        break
      }
      if blockFilter.isContentBlocked(segmentText(segment)) {
        if !build.hasBlockedTip { build.hasBlockedTip = true }
        continue
      }
      switch segment {
      case .text(let text):
        for part in splitEmoticons(text) {
          switch part {
          case .text(let value):
            result.append(NSAttributedString(string: value, attributes: base))
          case .emoticon(let name, let src):
            appendEmoticon(result, src: src, fontSize: fontSize, lineHeight: lineHeight, base: base, missing: &build.missingEmoticons)
            _ = name
          }
        }
      case .emoji(let text):
        result.append(NSAttributedString(string: text, attributes: base))
      case .emoticon(_, let src):
        appendEmoticon(result, src: src, fontSize: fontSize, lineHeight: lineHeight, base: base, missing: &build.missingEmoticons)
      case .link(let text, let url):
        let label = text.isEmpty ? url : text
        appendLink(result, text: label, target: .link(url), attributes: base, palette: palette)
      case .at(let uid, let text):
        appendLink(result, text: "@\(text)", target: .user(uid), attributes: base, palette: palette, underlined: false)
      case .image, .video, .audio:
        break
      }
    }
    build.attributed = result.length > 0 ? result : nil
    return (build, images)
  }

  private enum LinkTarget {
    case link(String)
    case user(String)

    var url: URL? {
      switch self {
      case .link(let raw):
        let encoded = raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? raw
        return URL(string: "tieba-native://link?url=\(encoded)")
      case .user(let uid):
        let encoded = uid.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? uid
        return URL(string: "tieba-native://user?uid=\(encoded)")
      }
    }
  }

  private static func appendLink(
    _ result: NSMutableAttributedString,
    text: String,
    target: LinkTarget,
    attributes: [NSAttributedString.Key: Any],
    palette: TiebaFeedRowPalette,
    underlined: Bool = true
  ) {
    var attrs = attributes
    attrs[.foregroundColor] = palette.primary
    if underlined { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
    if let url = target.url { attrs[.link] = url }
    result.append(NSAttributedString(string: text, attributes: attrs))
  }

  // MARK: 表情

  enum TextPart {
    case text(String)
    case emoticon(name: String, src: String)
  }

  /// 文本段拆包（#(名) / (#名) / [名]），未知名保留原文（richTextRuns.ts 同规则）。
  /// 一次正则左到右取最左匹配，替代逐字符 prefix 扫描（大段文本 O(n²)）。
  static func splitEmoticons(_ text: String) -> [TextPart] {
    guard !text.isEmpty else { return [] }
    var parts: [TextPart] = []
    let source = text as NSString
    var location = 0
    while let match = emoticonPattern.firstMatch(
      in: text,
      range: NSRange(location: location, length: source.length - location)
    ) {
      if match.range.location > location {
        parts.append(.text(source.substring(with: NSRange(
          location: location,
          length: match.range.location - location
        ))))
      }
      let name = name(in: match, source: source)
      if let number = TiebaViewModelMapper.emoticonNumber(named: name) {
        parts.append(.emoticon(name: name, src: TiebaViewModelMapper.buildEmoticonSrc(number)))
      } else {
        parts.append(.text(source.substring(with: match.range)))
      }
      location = match.range.location + match.range.length
    }
    if location < source.length { parts.append(.text(source.substring(from: location))) }
    return parts.isEmpty ? [.text(text)] : parts
  }

  /// 三个候选组都至少 1 字符：匹配长度 ≥ 3，循环必然前进（无空匹配死循环）。
  private static let emoticonPattern = try! NSRegularExpression(
    pattern: "#\\(([^)]+)\\)|\\(#([^)]+)\\)|\\[([^\\]]+)\\]"
  )

  private static func name(in match: NSTextCheckingResult, source: NSString) -> String {
    for group in 1...3 where match.range(at: group).location != NSNotFound {
      return source.substring(with: match.range(at: group))
    }
    return ""
  }

  private static func appendEmoticon(
    _ result: NSMutableAttributedString,
    src: String,
    fontSize: CGFloat,
    lineHeight: CGFloat,
    base: [NSAttributedString.Key: Any],
    missing: inout [String]
  ) {
    guard !src.isEmpty else { return }
    let size = min(fontSize + 3, max(16, lineHeight - 4))
    let attachment = NSTextAttachment()
    attachment.bounds = CGRect(x: 0, y: -3, width: size, height: size)
    if let image = TiebaEmoticonCache.shared.image(src: src) {
      attachment.image = image
    } else {
      attachment.image = TiebaEmoticonCache.shared.placeholder(size: size)
      if !missing.contains(src) { missing.append(src) }
    }
    result.append(NSAttributedString(attachment: attachment))
    result.append(NSAttributedString(string: " ", attributes: base))
  }

  // MARK: 块媒体 / 展示 URL

  static func video(_ post: TiebaThreadPost) -> TiebaThreadVideo? {
    for segment in post.content {
      if case .video(let video) = segment { return video }
    }
    return nil
  }

  static func audio(_ post: TiebaThreadPost) -> (src: String, duration: Double)? {
    for segment in post.content {
      if case .audio(let src, let duration) = segment { return (src, duration) }
    }
    return nil
  }

  /// 列表展示档：all_origin 用原图，其余用服务端大图（src）。
  static func displayURL(_ image: TiebaThreadImage, preferences: TiebaPostPreferences) -> URL? {
    if preferences.imageLoadType == "all_no" { return nil }
    let raw = preferences.imageLoadType == "all_origin"
      ? (image.originSrc.isEmpty ? image.src : image.originSrc)
      : (image.src.isEmpty ? image.originSrc : image.src)
    return TiebaPhotoItem.normalizedURL(raw)
  }

  private static func segmentText(_ segment: TiebaThreadContentSegment) -> String {
    switch segment {
    case .text(let text), .emoji(let text): return text
    case .emoticon(let name, _): return name
    case .link(let text, let url): return text.isEmpty ? url : text
    case .at(_, let text): return text
    case .image, .video, .audio: return ""
    }
  }
}

/// 表情图缓存 + 异步加载：走 TiebaNuke 管线（Referer/磁盘缓存/同 URL 合并），
/// 内存档由 Nuke ImageCache 承担（不再自建 NSCache）。占位图同尺寸先行，
/// 到达后由行视图重建富文本——首次渲染的同步路径与旧的 NSCache 查询同形。
final class TiebaEmoticonCache: @unchecked Sendable {
  static let shared = TiebaEmoticonCache()

  private let lock = NSLock()
  private var placeholderCache: (size: CGFloat, image: UIImage)?

  private init() {}

  /// 同步查询（文本测量在后台队列也会调）：命中 Nuke 内存缓存才有图。
  func image(src: String) -> UIImage? {
    guard let request = Self.request(for: src) else { return nil }
    return TiebaNuke.pipeline.cache[request]?.image
  }

  func placeholder(size: CGFloat) -> UIImage {
    lock.withLock {
      if let placeholderCache, placeholderCache.size == size { return placeholderCache.image }
      let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
      let image = renderer.image { context in
        UIColor.systemGray5.setFill()
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
      }
      placeholderCache = (size, image)
      return image
    }
  }

  /// 完成回调在主线程（Nuke 闭包固定 MainActor），且**每个请求都会回调**：命中
  /// 内存缓存、已由其它楼层在途的 URL 也回调——旧实现命中缓存/在途就 continue，
  /// 光有首个请求者重建富文本，滚动后露出的同表情楼层永远停在灰占位。
  func load(_ srcs: [String], completion: @escaping @MainActor () -> Void) {
    for src in srcs where !src.isEmpty {
      guard let request = Self.request(for: src) else { continue }
      // 去重交给 Nuke：它按 URL 合并同 URL 请求并自带内存缓存（不再自建 Set）。
      TiebaNuke.pipeline.loadImage(with: request) { _ in
        completion()
      }
    }
  }

  /// 与 load 的管线请求同键（secureURL + 无处理器），image(src:) 才能命中缓存。
  private static func request(for src: String) -> ImageRequest? {
    guard !src.isEmpty, let url = URL(string: src) else { return nil }
    return ImageRequest(url: TiebaNuke.secureURL(url))
  }
}

/// 被隐藏媒体的占位条（hideMedia / blockVideo）。
struct TiebaPostMediaPlaceholder: Sendable {
  var icon: String
  var text: String
}

// MARK: - 行模型

final class TiebaPostRowModel: @unchecked Sendable {
  let pageKey: String
  let index: Int
  let post: TiebaThreadPost
  let isMain: Bool
  let isLz: Bool
  let canDelete: Bool
  let threadAuthorId: String
  let toolbar: TiebaPostToolbarModel?
  let preferences: TiebaPostPreferences
  let blockFilter: TiebaPostBlockFilter
  let palette: TiebaFeedRowPalette
  let containerWidth: CGFloat
  let measuredHeight: CGFloat
  let plan: TiebaPostRowPlan

  let avatarURL: URL?
  let nameText: String
  let metaText: String
  let levelText: String?
  /// 放不下时的退档（「Lv.5」），见 TiebaPostRowPlan 的徽标测量。
  let levelShortText: String?
  let levelColor: UIColor?
  let images: [TiebaThreadImage]
  let imagesHidden: Bool
  let video: TiebaThreadVideo?
  let videoPlaceholder: TiebaPostMediaPlaceholder?
  let audio: (src: String, duration: Double)?
  let forumName: String
  let showsBlockedTip: Bool
  /// 主贴卡标题（回复行为 nil）。不带前景色：颜色走 titleLabel.textColor 现取色板，
  /// 与已知主贴占位卡同一套（主题切换时两者同时变色）。
  let titleText: NSAttributedString?

  private let textBuild: TiebaPostTextBuild
  private let subPostBuilds: [TiebaPostTextBuild]
  private let cachedText: NSAttributedString?
  private let cachedSubTexts: [NSAttributedString?]

  /// 表情图到达后的"占位图 → 真图"版本（一次性；见 upgradeTexts()）。
  /// nonisolated(unsafe)+锁：写发生在主线程的表情回调，读可能来自行视图的贴模型。
  private let upgradeLock = NSLock()
  nonisolated(unsafe) private var upgraded: (text: NSAttributedString?, subs: [NSAttributedString?])?

  var contentText: NSAttributedString? { upgraded?.text ?? cachedText }
  var subPostTexts: [NSAttributedString?] { upgraded?.subs ?? cachedSubTexts }
  /// 升级过之后不再报"缺表情"：再问一次也只会把同一份文本重排一遍。
  var missingEmoticons: [String] {
    upgradeLock.lock()
    defer { upgradeLock.unlock() }
    guard upgraded == nil else { return [] }
    return textBuild.missingEmoticons + subPostBuilds.flatMap(\.missingEmoticons)
  }

  /// 表情图到达后重建正文 + 楼中楼（尺寸不变，行高不变）。**结果缓存回模型**：
  /// 一行当天会有 N 个表情请求各回调一次，且滚走再滚回来还会再问一次——
  /// 不缓存就是每次重排一遍正文（正文那趟才是最贵的一笔）。
  func upgradeTexts() -> (text: NSAttributedString?, subs: [NSAttributedString?]) {
    upgradeLock.lock()
    defer { upgradeLock.unlock() }
    if let upgraded { return upgraded }
    let built = (text: rebuiltText() ?? cachedText, subs: rebuiltSubTexts())
    upgraded = built
    return built
  }

  /// 表情图到达后重建（尺寸不变，行高不变）。
  func rebuiltText() -> NSAttributedString? {
    TiebaPostRowText.build(
      post,
      preferences: preferences,
      blockFilter: blockFilter,
      palette: palette
    ).attributed
  }

  /// 表情图到达后重建楼中楼预览（subPostTexts 是建模型时固化的占位图版本）；
  /// 尺寸不变、行高不变。
  func rebuiltSubTexts() -> [NSAttributedString?] {
    post.subPosts.map {
      TiebaPostRowText.buildContent(
        $0.content,
        preferences: preferences,
        blockFilter: blockFilter,
        palette: palette,
        isSubPost: true
      ).build.attributed
    }
  }

  var prefetchURLs: [URL] {
    var urls: [URL] = []
    if let avatarURL { urls.append(avatarURL) }
    for image in images {
      if let url = TiebaPostRowText.displayURL(image, preferences: preferences) { urls.append(url) }
    }
    return urls
  }


  init(
    pageKey: String,
    index: Int,
    post: TiebaThreadPost,
    isMain: Bool,
    canDelete: Bool,
    threadAuthorId: String,
    toolbar: TiebaPostToolbarModel?,
    preferences: TiebaPostPreferences,
    blockFilter: TiebaPostBlockFilter,
    palette: TiebaFeedRowPalette,
    forumName: String,
    containerWidth: CGFloat,
    title: String = ""
  ) {
    self.pageKey = pageKey
    self.index = index
    self.post = post
    self.isMain = isMain
    self.isLz = !post.authorId.isEmpty && post.authorId == threadAuthorId
    self.canDelete = canDelete
    self.threadAuthorId = threadAuthorId
    self.toolbar = toolbar
    self.preferences = preferences
    self.blockFilter = blockFilter
    self.palette = palette
    self.containerWidth = TiebaLayout.quantize(containerWidth)
    self.forumName = forumName
    self.images = post.images
    self.imagesHidden = preferences.hideMedia
    self.video = preferences.hideMedia || preferences.blockVideo ? nil : TiebaPostRowText.video(post)
    self.videoPlaceholder = TiebaPostRowLayout.mediaPlaceholder(
      hasVideo: TiebaPostRowText.video(post) != nil,
      preferences: preferences
    )
    self.audio = TiebaPostRowText.audio(post)

    let build = TiebaPostRowText.build(
      post,
      preferences: preferences,
      blockFilter: blockFilter,
      palette: palette
    )
    self.textBuild = build
    self.showsBlockedTip = build.hasBlockedTip
    self.subPostBuilds = post.subPosts.map {
      TiebaPostRowText.buildContent(
        $0.content,
        preferences: preferences,
        blockFilter: blockFilter,
        palette: palette,
        isSubPost: true
      ).build
    }
    self.cachedText = build.attributed
    self.cachedSubTexts = subPostBuilds.map(\.attributed)
    self.avatarURL = TiebaSimpleRowParser.avatarURL(post.authorPortrait)
    self.nameText = post.displayName.isEmpty ? "吧友" : post.displayName
    self.levelShortText =
      preferences.showLevelBadge && post.authorLevel > 0 ? "Lv.\(post.authorLevel)" : nil
    // 头衔（User.level_name，随作者下发）：只在开关打开且徽标在时接在 Lv 后面。
    // ⚠️ 变量名不许叫 title —— 本 init 有个 title 参数（主贴卡的帖名），
    // 撞名会把卡片标题顶成头衔（2026-09-18 用户复报的"主贴卡标题变成等级标记"）。
    let levelTitle = post.authorLevelName.trimmingCharacters(in: .whitespacesAndNewlines)
    self.levelText =
      preferences.showLevelTitle && !levelTitle.isEmpty && self.levelShortText != nil
      ? "\(self.levelShortText ?? "") \(levelTitle)"
      : self.levelShortText
    self.levelColor = TiebaPostRowLayout.levelColor(post.authorLevel)
    self.metaText = TiebaPostRowLayout.metaText(
      post: post,
      isMain: isMain,
      preferences: preferences
    )
    self.likeText = post.agreeNum > 0 ? TiebaForumFormat.count(post.agreeNum) : ""
    self.titleText =
      isMain && !title.isEmpty
      ? TiebaSimpleText.makeAttributed(
        text: title,
        font: TiebaPostRowLayout.titleFont,
        lineHeight: TiebaPostRowLayout.titleLineHeight,
        truncating: TiebaPostRowLayout.titleLineLimit > 0
      )
      : nil
    // plan 只依赖上面这些已就位的值（自身尚未初始化完，不能把 self 传出去）。
    let plan = TiebaPostRowPlan(TiebaPostRowPlanInputs(
      containerWidth: self.containerWidth,
      isMain: isMain,
      post: post,
      titleText: self.titleText,
      nameText: self.nameText,
      levelText: self.levelText,
      levelShortText: self.levelShortText,
      isLz: self.isLz,
      metaText: self.metaText,
      likeText: self.likeText,
      contentText: build.attributed,
      subPostTexts: self.cachedSubTexts,
      showsBlockedTip: build.hasBlockedTip,
      hairline: preferences.hairline,
      fontScale: Double(preferences.fontScaleClamped),
      images: self.images,
      imagesHidden: self.imagesHidden,
      video: self.video,
      videoPlaceholder: self.videoPlaceholder,
      audio: self.audio,
      toolbar: toolbar
    ))
    self.plan = plan
    self.measuredHeight = plan.rowHeight
  }

  /// 单行替换（点赞/取消只改本行状态）：页/行/配色/偏好等全部沿用旧模型，只换
  /// post。整页 publish 会把每层楼的富文本装配与 TextKit 测量全部重跑一遍。
  convenience init(replacing model: TiebaPostRowModel, post: TiebaThreadPost) {
    self.init(
      pageKey: model.pageKey,
      index: model.index,
      post: post,
      isMain: model.isMain,
      canDelete: model.canDelete,
      threadAuthorId: model.threadAuthorId,
      toolbar: model.toolbar,
      preferences: model.preferences,
      blockFilter: model.blockFilter,
      palette: model.palette,
      forumName: model.forumName,
      containerWidth: model.containerWidth,
      title: model.titleText?.string ?? ""
    )
  }

  let likeText: String
}

/// 主贴行底部的回复工具栏（原 ThreadHeader 的 Reply Toolbar）。
struct TiebaPostToolbarModel: Sendable {
  var replyNum = 0
  var pageLabel: String?
  var seeLz = false
  var reverse = false
}

// MARK: - 测量缓存

final class TiebaPostRowMetrics: @unchecked Sendable {
  static let shared = TiebaPostRowMetrics()

  private struct Page {
    var models: [TiebaPostRowModel]
  }

  /// 整页缓存（LRU + 在显页跳过）：四族度量缓存共用 TiebaPageStore。
  private let pages = TiebaPageStore<String, Page>(pinKey: { $0 })

  private init() {}

  /// 整页发布（调用方在后台队列执行；返回后 row/rowCount 立即可查）。
  func prepare(pageKey: String, models: [TiebaPostRowModel]) {
    guard !pageKey.isEmpty else { return }
    pages.publish(Page(models: models), forKey: pageKey)
  }

  func row(pageKey: String, index: Int) -> TiebaPostRowModel? {
    guard let page = pages.value(forKey: pageKey), page.models.indices.contains(index) else {
      return nil
    }
    return page.models[index]
  }

  /// 单行替换（点赞等只重建本行；行数不变，调用方随后 setPage 重配可见行）。
  func replace(pageKey: String, index: Int, model: TiebaPostRowModel) {
    pages.mutate(pageKey) { page in
      guard page.models.indices.contains(index) else { return }
      page.models[index] = model
    }
  }

  func rowCount(pageKey: String) -> Int {
    pages.value(forKey: pageKey)?.models.count ?? 0
  }
}

// MARK: - 布局常量

enum TiebaPostRowLayout {
  static let cardMarginH: CGFloat = 10
  static let cardMarginV: CGFloat = 4
  static let cardPadding: CGFloat = 16
  static let cardRadius: CGFloat = 16
  static let avatarSide: CGFloat = 36
  static let avatarSideMain: CGFloat = 40
  static let avatarGap: CGFloat = 10
  static let nameRowGap: CGFloat = 3
  static let authorBottom: CGFloat = 12
  static let levelGap: CGFloat = 6
  static let actionGap: CGFloat = 12
  static let mediaGap: CGFloat = 12
  static let imageRadius: CGFloat = 10
  static let stripHeight: CGFloat = 160
  static let stripSpacing: CGFloat = 6
  static let longImageHeight: CGFloat = 300
  static let singleImageMaxHeight: CGFloat = 520
  static let maxImages = 9
  static let audioHeight: CGFloat = 52
  static let subPostTop: CGFloat = 10
  static let subPostDividerGap: CGFloat = 8
  /// 主贴回复工具栏（ThreadHeader.replyToolbar：paddingVertical 12×2 + 药丸 30）。
  static let toolbarHeight: CGFloat = 54

  static var nameFont: UIFont { TiebaSimpleText.font(size: 15, weight: .semibold) }
  static var nameFontMain: UIFont { TiebaSimpleText.font(size: 16, weight: .semibold) }
  /// 主贴卡标题（仅主贴行）：与已知主贴占位卡 knownTitle 逐项同尺（17pt/22pt/3 行），
  /// 首包落地换卡时标题原地接管，下面的作者行/正文不位移。
  static var titleFont: UIFont { TiebaSimpleText.font(size: 17, weight: .medium) }
  static let titleLineHeight: CGFloat = 22
  /// 标题**不限行**（0 = 不截断）：用户 2026-09-17 报"长标题被截断、显示不全"。
  /// 占位卡（TiebaThreadKnownPostView）的行数必须与这里一致，换卡才不跳。
  static let titleLineLimit = 0
  static var metaFont: UIFont { TiebaSimpleText.font(size: 12, weight: .regular) }
  static var badgeFont: UIFont { TiebaSimpleText.font(size: 11, weight: .bold) }
  static var lzFont: UIFont { TiebaSimpleText.font(size: 11, weight: .semibold) }
  static var actionFont: UIFont { TiebaSimpleText.font(size: 12, weight: .medium) }
  static var moreFont: UIFont { TiebaSimpleText.font(size: 13, weight: .semibold) }
  static var pillFont: UIFont { TiebaSimpleText.font(size: 13, weight: .semibold) }
  static var subPostNameFont: UIFont { TiebaSimpleText.font(size: 14, weight: .semibold) }
  static var replyCountFont: UIFont { TiebaSimpleText.font(size: 15, weight: .semibold) }

  /// 楼中楼预览的行盒高度（与 buildContent(isSubPost:) 的 20×scale 同值）。
  static func subPostLineHeight(_ scale: Double) -> CGFloat { ceil(20 * scale) }

  /// 名字标签必须与正文文本框共用同一行盒，否则正文首行会掉到名字右下角。
  static func subPostNameParagraph(_ scale: Double) -> NSParagraphStyle {
    let paragraph = NSMutableParagraphStyle()
    paragraph.minimumLineHeight = 20 * scale
    paragraph.maximumLineHeight = 20 * scale
    paragraph.lineBreakMode = .byTruncatingTail
    return paragraph
  }

  /// hideMedia / blockVideo 的占位条（无视频/未屏蔽 → nil）。
  static func mediaPlaceholder(
    hasVideo: Bool,
    preferences: TiebaPostPreferences
  ) -> TiebaPostMediaPlaceholder? {
    guard hasVideo else { return nil }
    if preferences.hideMedia { return TiebaPostMediaPlaceholder(icon: "video", text: "[视频]") }
    if preferences.blockVideo { return TiebaPostMediaPlaceholder(icon: "video.slash", text: "[视频已屏蔽]") }
    return nil
  }

  static func metaText(post: TiebaThreadPost, isMain: Bool, preferences: TiebaPostPreferences) -> String {
    let time = TiebaPostTimeText.label(ms: post.createTimeMs, style: preferences.timestampStyle)
    var parts: [String] = []
    if !time.isEmpty { parts.append(time) }
    if !isMain, post.floor > 0 { parts.append("\(post.floor)楼") }
    if preferences.showIpLocation, !post.ipLocation.isEmpty {
      parts.append("IP属地：\(post.ipLocation)")
    }
    return parts.joined(separator: " · ")
  }

  /// Kotlin getIconColorByLevel + greifyColor(0.2)（等级色字 + 25% 透明底）。
  static func levelColor(_ level: Int) -> UIColor? {
    guard level > 0 else { return nil }
    let base: (CGFloat, CGFloat, CGFloat)
    switch level {
    case ...3: base = (0x2F, 0xBE, 0xAB)
    case ...9: base = (0x3A, 0xA7, 0xE9)
    case ...15: base = (0xFF, 0xA1, 0x26)
    case ...18: base = (0xFF, 0x9C, 0x19)
    default: base = (0xB7, 0xBC, 0xB6)
    }
    var (h, s, v) = rgbToHSV(base)
    s = max(0, s - 0.2)
    v = max(0, v - 0.2 / 3)
    return hsvToColor(h, s, v)
  }

  private static func rgbToHSV(_ rgb: (CGFloat, CGFloat, CGFloat)) -> (CGFloat, CGFloat, CGFloat) {
    let (r, g, b) = (rgb.0 / 255, rgb.1 / 255, rgb.2 / 255)
    let maxValue = max(r, g, b), minValue = min(r, g, b), delta = maxValue - minValue
    var h: CGFloat = 0
    if delta != 0 {
      if maxValue == r { h = ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
      else if maxValue == g { h = (b - r) / delta + 2 }
      else { h = (r - g) / delta + 4 }
      h *= 60
      if h < 0 { h += 360 }
    }
    return (h, maxValue == 0 ? 0 : delta / maxValue, maxValue)
  }

  private static func hsvToColor(_ h: CGFloat, _ s: CGFloat, _ v: CGFloat) -> UIColor {
    let c = v * s
    let x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1))
    let m = v - c
    let rgb: (CGFloat, CGFloat, CGFloat)
    switch h {
    case ..<60: rgb = (c, x, 0)
    case ..<120: rgb = (x, c, 0)
    case ..<180: rgb = (0, c, x)
    case ..<240: rgb = (0, x, c)
    case ..<300: rgb = (x, 0, c)
    default: rgb = (c, 0, x)
    }
    return UIColor(red: rgb.0 + m, green: rgb.1 + m, blue: rgb.2 + m, alpha: 1)
  }
}

// MARK: - 时间文案（共享工具：相对/绝对两种风格一套实现）

/// JS utils relativeTime / absoluteTime 逐分支等价。
///
/// formatter 静态复用：本方法在后台测量队列与主线程都会被调（metaText 每次
/// publish 跑 400 楼，publish 又随每次点赞触发；旧实现每次调用都 alloc 一个
/// DateFormatter，连"刚刚"分支也建）。DateFormatter 自 iOS 7 起线程安全，且
/// dateFormat 只在构造时设定一次，运行期不再改。
enum TiebaPostTimeText {
  static func label(ms: Double, style: String) -> String {
    guard ms > 946_684_800_000 else { return "" }
    let date = Date(timeIntervalSince1970: ms / 1000)
    if style == "absolute" { return absoluteFormatter.string(from: date) }
    let diff = max(0, Date().timeIntervalSince1970 - ms / 1000)
    if diff < 60 { return "刚刚" }
    if diff < 3600 { return "\(Int(diff / 60))分钟前" }
    if diff < 86_400 { return "\(Int(diff / 3600))小时前" }
    if Calendar.current.isDateInYesterday(date) {
      return "昨天 \(clockFormatter.string(from: date))"
    }
    if diff < 7 * 86_400 { return "\(Int(diff / 86_400))天前" }
    return dayFormatter.string(from: date)
  }

  private static let absoluteFormatter = formatter("yyyy-MM-dd HH:mm")
  private static let clockFormatter = formatter("HH:mm")
  private static let dayFormatter = formatter("yyyy-MM-dd")

  /// 地区/历法固定，避免佛历等脏输出。
  private static func formatter(_ format: String) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.dateFormat = format
    return formatter
  }
}

// MARK: - 帧计划（测量与绘制共用；单位 = 行坐标）

/// plan 的输入快照（模型 init 里在自身未初始化完时传递）。
struct TiebaPostRowPlanInputs {
  var containerWidth: CGFloat
  var isMain: Bool
  var post: TiebaThreadPost
  /// 帖子标题（只有主贴行用；楼中楼父卡不显示标题）。
  var titleText: NSAttributedString?
  var nameText: String
  var levelText: String?
  var levelShortText: String?
  var isLz: Bool
  var metaText: String
  var likeText: String
  var contentText: NSAttributedString?
  var subPostTexts: [NSAttributedString?]
  var showsBlockedTip: Bool
  var hairline: CGFloat
  var fontScale: Double
  var images: [TiebaThreadImage]
  var imagesHidden: Bool
  var video: TiebaThreadVideo?
  var videoPlaceholder: TiebaPostMediaPlaceholder?
  var audio: (src: String, duration: Double)?
  var toolbar: TiebaPostToolbarModel?
}

struct TiebaPostRowPlan {
  var rowHeight: CGFloat = 0
  var cardFrame: CGRect = .zero
  var titleFrame: CGRect?
  var avatarFrame: CGRect = .zero
  var nameFrame: CGRect = .zero
  var levelFrame: CGRect?
  /// 徽标实际渲染的文案（放不下头衔时退成「Lv.N」，见下方测量）。
  var levelRenderText: String?
  var lzFrame: CGRect?
  var metaFrame: CGRect = .zero
  var menuFrame: CGRect = .zero
  var likeFrame: CGRect = .zero
  var likeIconFrame: CGRect = .zero
  var likeCountFrame: CGRect?
  var textFrame: CGRect?
  var blockedTipFrame: CGRect?
  var imagesFrame: CGRect?
  var imageItemFrames: [CGRect] = []
  var imagePlaceholderFrames: [CGRect] = []
  var videoFrame: CGRect?
  var videoPlaceholderFrame: CGRect?
  var audioFrame: CGRect?
  var subPostsFrame: CGRect?
  var subPostDividerFrames: [CGRect] = []
  var subPostNameFrames: [CGRect] = []
  var subPostTextFrames: [CGRect] = []
  var subPostsMoreFrame: CGRect?
  var toolbarFrame: CGRect?
  var toolbarTextFrame: CGRect?
  var toolbarSeeLzFrame: CGRect?
  var toolbarSortFrame: CGRect?

  init(_ inputs: TiebaPostRowPlanInputs) {
    let width = inputs.containerWidth
    let cardW = max(width - TiebaPostRowLayout.cardMarginH * 2, 0)
    let contentX = TiebaPostRowLayout.cardMarginH + TiebaPostRowLayout.cardPadding
    let contentW = max(cardW - TiebaPostRowLayout.cardPadding * 2, 0)

    var y = TiebaPostRowLayout.cardMarginV
    let cardTop = y
    y += TiebaPostRowLayout.cardPadding

    // ── 标题（仅主贴卡）──
    // 卡片顶端第一块，下方留 authorBottom(12) —— 与已知主贴占位卡同尺同距
    //（占位卡 padding 16 / gap 12）：首包落地换卡时标题原地接管，不位移。
    if inputs.isMain, let title = inputs.titleText, title.length > 0 {
      let height = TiebaSimpleText.measureHeight(
        title,
        width: contentW,
        maxLines: TiebaPostRowLayout.titleLineLimit
      )
      titleFrame = CGRect(x: contentX, y: y, width: contentW, height: height)
      y += height + TiebaPostRowLayout.authorBottom
    }

    // ── 作者行 ──
    // 右侧操作组（⋮18 + gap12 + 点赞）按内容实测宽度占位，不能写死：固定占位会把
    // meta 行挤窄 →「时间 · 楼层 · IP属地」尾部（IP）被截断（用户报 IP 看不到）。
    let avatarSide = inputs.isMain ? TiebaPostRowLayout.avatarSideMain : TiebaPostRowLayout.avatarSide
    avatarFrame = CGRect(x: contentX, y: y, width: avatarSide, height: avatarSide)
    let nameFont = inputs.isMain ? TiebaPostRowLayout.nameFontMain : TiebaPostRowLayout.nameFont
    let nameX = contentX + avatarSide + TiebaPostRowLayout.avatarGap

    let likeText = inputs.likeText
    let likeIconSide: CGFloat = 18
    let likeGap: CGFloat = 4
    // 文本宽 +4：TextKit 取整会差半像素，不留余量尾字会被裁。
    let likeTextWidth = likeText.isEmpty
      ? 0
      : TiebaSimpleText.singleLineWidth(likeText, font: TiebaPostRowLayout.actionFont) + 4
    let likeWidth = max(likeIconSide + (likeTextWidth > 0 ? likeGap + likeTextWidth : 0), 28)
    let menuSide: CGFloat = 18
    let actionsWidth = menuSide + TiebaPostRowLayout.actionGap + likeWidth
    let actionsRight = contentX + contentW
    let nameMaxWidth = max(actionsRight - actionsWidth - TiebaPostRowLayout.levelGap - nameX, 0)
    let nameWidth = min(TiebaSimpleText.singleLineWidth(inputs.nameText, font: nameFont), nameMaxWidth)
    nameFrame = CGRect(x: nameX, y: y + 2, width: max(nameWidth, 0), height: ceil(nameFont.lineHeight))
    let badgeLimit = actionsRight - actionsWidth - 4
    var badgeX = nameFrame.maxX + TiebaPostRowLayout.levelGap
    if let levelText = inputs.levelText {
      // 头衔把徽标撑宽后可能顶到右侧操作组：先试全串，放不下退成「Lv.N」——
      // 挤昵称或整个徽标消失都会让用户少看到东西（用户 2026-09-17 要求接头衔）。
      var text = levelText
      var levelWidth = TiebaSimpleText.singleLineWidth(text, font: TiebaPostRowLayout.badgeFont) + 10
      if badgeX + levelWidth > badgeLimit, let short = inputs.levelShortText {
        let shortWidth = TiebaSimpleText.singleLineWidth(short, font: TiebaPostRowLayout.badgeFont) + 10
        if badgeX + shortWidth <= badgeLimit {
          text = short
          levelWidth = shortWidth
        }
      }
      if badgeX + levelWidth <= badgeLimit {
        levelFrame = CGRect(x: badgeX, y: y + 5, width: levelWidth, height: 15)
        levelRenderText = text
        badgeX += levelWidth + TiebaPostRowLayout.levelGap
      }
    }
    if inputs.isLz {
      let lzWidth = TiebaSimpleText.singleLineWidth("楼主", font: TiebaPostRowLayout.lzFont) + 12
      if badgeX + lzWidth <= badgeLimit {
        lzFrame = CGRect(x: badgeX, y: y + 5, width: lzWidth, height: 15)
      }
    }
    let metaFont = TiebaPostRowLayout.metaFont
    metaFrame = CGRect(
      x: nameX,
      y: y + nameFrame.height + TiebaPostRowLayout.nameRowGap + 2,
      width: nameMaxWidth,
      height: ceil(metaFont.lineHeight)
    )

    // 操作组垂直居中于作者行（PostCard authorRow alignItems: 'center'）；行右缘对齐内容右缘。
    let actionsHeight: CGFloat = 28
    let authorHeight = max(avatarSide, nameFrame.height + TiebaPostRowLayout.nameRowGap + metaFrame.height)
    let actionY = y + max((authorHeight - actionsHeight) / 2, 0)
    let actionsX = actionsRight - actionsWidth
    menuFrame = CGRect(
      x: actionsX,
      y: actionY + (actionsHeight - menuSide) / 2,
      width: menuSide,
      height: menuSide
    )
    likeFrame = CGRect(
      x: actionsX + menuSide + TiebaPostRowLayout.actionGap,
      y: actionY,
      width: likeWidth,
      height: actionsHeight
    )
    likeIconFrame = CGRect(
      x: likeFrame.minX,
      y: actionY + (actionsHeight - likeIconSide) / 2,
      width: likeIconSide,
      height: likeIconSide
    )
    if !likeText.isEmpty {
      let likeLabelHeight = ceil(TiebaPostRowLayout.actionFont.lineHeight)
      likeCountFrame = CGRect(
        x: likeIconFrame.maxX + likeGap,
        y: actionY + (actionsHeight - likeLabelHeight) / 2,
        width: max(likeWidth - likeIconSide - likeGap, 0),
        height: likeLabelHeight
      )
    }

    y = max(avatarFrame.maxY, metaFrame.maxY) + TiebaPostRowLayout.authorBottom

    // 块间距挂在"下一个块的块首"，不再挂在块尾：末尾没有块时那 12pt 会变成正文
    // 最后一行到卡底的多余空白（用户 2026-09-15 报"回复离卡底空白太多"）。
    var gap: CGFloat = 0
    func flushGap() {
      y += gap
      gap = 0
    }

    // ── 正文 / 屏蔽提示 ──
    if inputs.showsBlockedTip {
      flushGap()
      blockedTipFrame = CGRect(x: contentX, y: y, width: 92, height: 24)
      y += 24
      gap = 8
    }
    if let text = inputs.contentText, text.length > 0 {
      flushGap()
      let height = TiebaSimpleText.measureHeight(text, width: contentW, maxLines: 0)
      textFrame = CGRect(x: contentX, y: y, width: contentW, height: height)
      y += height
      gap = TiebaPostRowLayout.mediaGap
    }

    // ── 图片块（hideMedia 时逐个占位条，不挂图）──
    if inputs.imagesHidden, !inputs.images.isEmpty {
      flushGap()
      let count = min(inputs.images.count, TiebaPostRowLayout.maxImages)
      let rowHeight: CGFloat = 40
      let rowSpacing: CGFloat = 6
      var y2 = y
      for _ in 0..<count {
        imagePlaceholderFrames.append(CGRect(x: contentX, y: y2, width: contentW, height: rowHeight))
        y2 += rowHeight + rowSpacing
      }
      imagesFrame = CGRect(x: contentX, y: y, width: contentW, height: max(y2 - rowSpacing - y, 0))
      // 占位条的行距照旧算进下一个块（6+12），只是不再留在卡尾。
      y = y2 - rowSpacing
      gap = TiebaPostRowLayout.mediaGap + rowSpacing
    } else if !inputs.images.isEmpty {
      flushGap()
      if inputs.images.count == 1 {
        let image = inputs.images[0]
        let height = image.isTall
          ? TiebaPostRowLayout.longImageHeight
          : min(contentW / CGFloat(max(image.aspect, 0.01)), TiebaPostRowLayout.singleImageMaxHeight)
        let frame = CGRect(x: contentX, y: y, width: contentW, height: max(height, 1))
        imagesFrame = frame
        imageItemFrames = [CGRect(origin: .zero, size: frame.size)]
      } else {
        var x: CGFloat = 0
        var frames: [CGRect] = []
        for image in inputs.images.prefix(TiebaPostRowLayout.maxImages) {
          let itemWidth = min(max(TiebaPostRowLayout.stripHeight * CGFloat(image.aspect), 56), 300)
          frames.append(CGRect(x: x, y: 0, width: itemWidth, height: TiebaPostRowLayout.stripHeight))
          x += itemWidth + TiebaPostRowLayout.stripSpacing
        }
        imagesFrame = CGRect(x: contentX, y: y, width: contentW, height: TiebaPostRowLayout.stripHeight)
        imageItemFrames = frames
      }
      y += (imagesFrame?.height ?? 0)
      gap = TiebaPostRowLayout.mediaGap
    }

    // ── 视频 ──
    if let video = inputs.video {
      flushGap()
      let height = contentW / CGFloat(max(video.aspect, 0.01))
      videoFrame = CGRect(x: contentX, y: y, width: contentW, height: max(height, 1))
      y += max(height, 1)
      gap = TiebaPostRowLayout.mediaGap
    } else if inputs.videoPlaceholder != nil {
      flushGap()
      videoPlaceholderFrame = CGRect(x: contentX, y: y, width: contentW, height: 40)
      y += 40
      gap = TiebaPostRowLayout.mediaGap
    }

    // ── 语音 ──
    if inputs.audio != nil {
      flushGap()
      audioFrame = CGRect(x: contentX, y: y, width: contentW, height: TiebaPostRowLayout.audioHeight)
      y += TiebaPostRowLayout.audioHeight
      gap = TiebaPostRowLayout.mediaGap
    }

    // ── 楼中楼预览 ──
    let subPosts = inputs.post.subPosts
    if !subPosts.isEmpty || inputs.post.subPostNum > 0 {
      flushGap()
      y += TiebaPostRowLayout.subPostTop
      var subY = y + TiebaPostRowLayout.subPostTop
      for (idx, sub) in subPosts.enumerated() {
        if idx > 0 {
          // 分隔线上下各 subPostDividerGap：原来把 2×gap 全放在线**之下**，线就贴在
          // 上一条正文的最后一笔上（用户 2026-09-15 报"每条文字离底线太近"）。
          // 总间距仍是 2×gap，线以下的内容位置一字不动。
          subY += TiebaPostRowLayout.subPostDividerGap
          subPostDividerFrames.append(CGRect(x: contentX, y: subY, width: contentW, height: inputs.hairline))
          subY += TiebaPostRowLayout.subPostDividerGap
        }
        let nameFont = TiebaPostRowLayout.subPostNameFont
        let name = "\(sub.displayName)："
        let nameWidth = min(TiebaSimpleText.singleLineWidth(name, font: nameFont), contentW)
        // 名字与正文同一行盒（名字在左、正文在右，首行基线重合）。
        let nameLine = TiebaPostRowLayout.subPostLineHeight(inputs.fontScale)
        subPostNameFrames.append(CGRect(x: contentX, y: subY, width: nameWidth, height: nameLine))
        let textX = contentX + nameWidth + 6
        let textW = max(contentW - nameWidth - 6, 0)
        let attributed = inputs.subPostTexts.indices.contains(idx) ? inputs.subPostTexts[idx] : nil
        let height = attributed.map { TiebaSimpleText.measureHeight($0, width: textW, maxLines: 2) } ?? 0
        subPostTextFrames.append(CGRect(x: textX, y: subY, width: textW, height: height))
        subY += max(height, nameLine)
      }
      let moreText: String?
      if inputs.post.subPostNum > subPosts.count {
        moreText = "查看全部 \(inputs.post.subPostNum) 条回复"
      } else if subPosts.isEmpty {
        moreText = "查看 \(inputs.post.subPostNum) 条回复"
      } else {
        moreText = nil
      }
      if let moreText {
        subY += 8
        let moreFont = TiebaPostRowLayout.moreFont
        let moreWidth = min(TiebaSimpleText.singleLineWidth(moreText, font: moreFont), contentW)
        subPostsMoreFrame = CGRect(x: contentX, y: subY, width: moreWidth, height: ceil(moreFont.lineHeight))
        subY += subPostsMoreFrame?.height ?? 0
      }
      subPostsFrame = CGRect(x: TiebaPostRowLayout.cardMarginH, y: y, width: cardW, height: max(subY - y, 0))
      y = subY
    }

    let cardBottom = y + TiebaPostRowLayout.cardPadding
    cardFrame = CGRect(
      x: TiebaPostRowLayout.cardMarginH,
      y: cardTop,
      width: cardW,
      height: max(cardBottom - cardTop, 0)
    )

    // ── 主贴回复工具栏（卡外独立一块）──
    var bottom = cardFrame.maxY
    if inputs.toolbar != nil {
      let toolbarY = cardFrame.maxY + 8
      toolbarFrame = CGRect(
        x: TiebaPostRowLayout.cardMarginH,
        y: toolbarY,
        width: cardW,
        height: TiebaPostRowLayout.toolbarHeight
      )
      let pillFont = TiebaPostRowLayout.pillFont
      let pillHeight: CGFloat = 30
      let pillY = toolbarY + (TiebaPostRowLayout.toolbarHeight - pillHeight) / 2
      var pillX = TiebaPostRowLayout.cardMarginH + cardW - TiebaPostRowLayout.cardPadding
      let sortTitle = inputs.toolbar?.reverse == true ? "倒序" : "正序"
      let sortWidth = TiebaSimpleText.singleLineWidth(sortTitle, font: pillFont) + 28
      toolbarSortFrame = CGRect(x: pillX - sortWidth, y: pillY, width: sortWidth, height: pillHeight)
      pillX -= sortWidth + 8
      let seeLzWidth = TiebaSimpleText.singleLineWidth("只看楼主", font: pillFont) + 28
      toolbarSeeLzFrame = CGRect(x: pillX - seeLzWidth, y: pillY, width: seeLzWidth, height: pillHeight)
      let textX = TiebaPostRowLayout.cardMarginH + TiebaPostRowLayout.cardPadding
      toolbarTextFrame = CGRect(
        x: textX,
        y: toolbarY,
        width: max((toolbarSeeLzFrame?.minX ?? pillX) - textX - 8, 0),
        height: TiebaPostRowLayout.toolbarHeight
      )
      bottom = toolbarY + TiebaPostRowLayout.toolbarHeight + 8
    }
    rowHeight = bottom + TiebaPostRowLayout.cardMarginV
  }
}
