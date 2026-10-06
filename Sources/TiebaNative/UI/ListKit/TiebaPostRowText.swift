// 从 TiebaPostRowMetrics.swift 拆出（H10 千行文件拆分）：富文本装配 + 表情 RunDelegate + 表情缓存。
// 纯搬运：整类型逐字搬走（不改访问级、不改一行逻辑），因此 private 类型仍然合法。

// MARK: - 富文本装配

import UIKit
import Nuke

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
      // [接线 TiebaEmoji] U+FE0F（变体选择符）不可见，却能被插进关键词中间绕过屏蔽词
      //（「广\u{FE0F}告」）；strippedEmoji 正是去掉全部 U+FE0F，匹配前先归一化。
      if blockFilter.isContentBlocked(segmentText(segment).strippedEmoji) {
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
        // [接线 URL 安全] 只有真的是可打开的 http/https/tonsite 链接才挂 .link 属性；
        // javascript:/data:/无 host 之流降级成普通文字（不给可点入口）。
        // 归一化同时解决旧代码的老问题：服务端给的裸域名（www.xxx.com）没有协议，
        // TiebaLinkOpener 拿不到 host → 点了打不开。
        if let target = linkTarget(url) {
          appendLink(result, text: label, target: .link(target), attributes: base, palette: palette)
        } else {
          result.append(NSAttributedString(string: label, attributes: base))
        }
      case .at(let uid, let text):
        // text 自带 "@"（服务端语义，见 TiebaViewModelMapper.atDisplayText），这里不再拼一个。
        appendLink(result, text: TiebaViewModelMapper.atDisplayText(text), target: .user(uid), attributes: base, palette: palette, underlined: false)
      case .image, .video, .audio:
        break
      }
    }
    build.attributed = result.length > 0 ? result : nil
    return (build, images)
  }

  /// [接线 URL 安全] 外链归一化：`tiebaExplicitUrl` 补协议 → `tiebaIsValidUrl` 校验；
  /// 直接解析失败（含空格/中文等未转义字符）时用 `tiebaUrlEncodedStringFromString` 转义后重试。
  /// 返回 nil = 不是可打开的链接，调用方按普通文字渲染。
  static func linkTarget(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let explicit = tiebaExplicitUrl(trimmed)
    if tiebaIsValidUrl(explicit) { return explicit }
    let encoded = tiebaUrlEncodedStringFromString(trimmed)
    let encodedExplicit = tiebaExplicitUrl(encoded)
    if tiebaIsValidUrl(encodedExplicit) { return encodedExplicit }
    return nil
  }

  private enum LinkTarget {
    case link(String)
    case user(String)

    var url: URL? {
      switch self {
      // [采用] 编码集用 \`.tiebaURLQueryValueAllowed\`（移植自 上游 UrlEscaping.swift:21-31），
      // **不是** \`.urlQueryAllowed\` —— 后者不转义 \`&\` 与 \`=\`，会把参数值里的 \`&\` 当成参数边界。
      // 已实测复现：url 值含 \`?pn=2&see_lz=1\` 时，旧写法回读只剩 \`?pn=2\`（静默丢参数）。
      case .link(let raw):
        let encoded = raw.addingPercentEncoding(withAllowedCharacters: .tiebaURLQueryValueAllowed) ?? raw
        return URL(string: "tieba-native://link?url=\(encoded)")
      case .user(let uid):
        let encoded = uid.addingPercentEncoding(withAllowedCharacters: .tiebaURLQueryValueAllowed) ?? uid
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

/// 表情附件的 run delegate 数据（宽 / 上伸 / 下伸）。
private final class TiebaEmoticonRunDelegate {
  let width: CGFloat
  let ascent: CGFloat
  let descent: CGFloat

  init(width: CGFloat, ascent: CGFloat, descent: CGFloat) {
    self.width = width
    self.ascent = ascent
    self.descent = descent
  }
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
    // [表情附件] \u{FFFC} 占位 + .attachment(UIImage) + CTRunDelegate：这一套 TextKit 与 CoreText 都认，
    // 测量（TextNode）与绘制（TextNode）因此同源，不必再分两套富文本。
    // 上下伸按 TextKit 的 NSTextAttachment bounds(0, -3, size, size) 折算：ascent = size-3、descent = 3。
    // [必守] alwaysOriginal：TextNode 对非 alwaysOriginal 的附件按当前文字色着色调（实测会画成黑块），
    // 而表情必须原样上色 —— 这条同时是绘制正确性与旧 UITextView 行为的对拍项。
    let image: UIImage
    if let loaded = TiebaEmoticonCache.shared.image(src: src) {
      image = loaded
    } else {
      image = TiebaEmoticonCache.shared.placeholder(size: size)
      if !missing.contains(src) { missing.append(src) }
    }
    // [回归修复] 绘制尺寸必须等于目标点尺寸：旧 NSTextAttachment 是按 bounds(0,-3,size,size) **缩放**画的，
    // 图片自身点尺寸无关紧要；TextNode 的 draw 则直接按 `image.size` 落地。贴吧表情原图是几十 pt 的位图，
    // 直接挂上去就画成原尺寸 —— 表现为「表情过大 + 盖住后面的字（看着没跟在字符后面）+ 超出 22pt 行盒
    // 被行视图裁掉四角」。这里先把图贴到目标点尺寸（绘制宽 = CTRunDelegate 前进宽 = 旧 bounds 边长）。
    result.append(NSAttributedString(
      string: "\u{FFFC}",
      attributes: emoticonAttributes(
        image: emoticonImage(image, pointSize: size).withRenderingMode(.alwaysOriginal),
        size: size,
        base: base
      )
    ))
    result.append(NSAttributedString(string: " ", attributes: base))
  }

  /// 把表情图贴到**目标点尺寸**：只改 scale，不重绘、不丢像素（image.size = 像素宽 / 新 scale = pointSize）。
  /// 与旧 `NSTextAttachment` 的 bounds 缩放同语义 —— 那套参数是对的，缺的只是这套引擎按 image.size 画。
  private static func emoticonImage(_ image: UIImage, pointSize: CGFloat) -> UIImage {
    guard pointSize > 0, image.size.width > 0, abs(image.size.width - pointSize) > 0.01,
          let cgImage = image.cgImage else { return image }
    return UIImage(
      cgImage: cgImage,
      scale: image.scale * (image.size.width / pointSize),
      orientation: image.imageOrientation
    )
  }

  /// FFFC 那一个字符的属性：.attachment 给绘制用，CTRunDelegate 给 CoreText 定宽与上下伸。
  private static func emoticonAttributes(
    image: UIImage,
    size: CGFloat,
    base: [NSAttributedString.Key: Any]
  ) -> [NSAttributedString.Key: Any] {
    var attributes = base
    attributes[.attachment] = image
    var callbacks = emoticonRunDelegateCallbacks
    let data = TiebaEmoticonRunDelegate(width: size, ascent: size - 3, descent: 3)
    if let delegate = CTRunDelegateCreate(&callbacks, Unmanaged.passRetained(data).toOpaque()) {
      attributes[NSAttributedString.Key(kCTRunDelegateAttributeName as String)] = delegate
    }
    return attributes
  }

  /// CTRunDelegate 是 C 回调：数据用 Unmanaged 传，dealloc 里 release（不引入 second 份宽高来源）。
  private static var emoticonRunDelegateCallbacks: CTRunDelegateCallbacks {
    CTRunDelegateCallbacks(
      version: kCTRunDelegateVersion1,
      dealloc: { refCon in Unmanaged<TiebaEmoticonRunDelegate>.fromOpaque(refCon).release() },
      getAscent: { refCon in Unmanaged<TiebaEmoticonRunDelegate>.fromOpaque(refCon).takeUnretainedValue().ascent },
      getDescent: { refCon in Unmanaged<TiebaEmoticonRunDelegate>.fromOpaque(refCon).takeUnretainedValue().descent },
      getWidth: { refCon in Unmanaged<TiebaEmoticonRunDelegate>.fromOpaque(refCon).takeUnretainedValue().width }
    )
  }

  // MARK: 正文测量（TextNode）

  /// 正文 / 楼中楼高度 = TextNode 的排版高度（与绘制同源，不再走 TextKit 的 second 份测量）。
  /// - Parameters:
  ///   - maxLines: 0 = 不限行（主贴正文）；2 = 楼中楼预览两行截断（truncationType = .end，与 UILabel 的 byTruncatingTail 同口径）。
  ///   - lineSpacing: TextNode 的行距因子，由目标行高反推（见 TiebaTextLineMetrics），测量与绘制必须同一值。
  /// 约束高度给 .greatestFiniteMagnitude：行数由 maximumNumberOfLines 决定，不能由「量出来的高度」反过来限制排版。
  static func measureBody(
    _ attributed: NSAttributedString,
    width: CGFloat,
    maxLines: Int,
    lineSpacing: CGFloat
  ) -> CGFloat {
    guard attributed.length > 0, width > 0 else { return 0 }
    let layout = TiebaTextNode.calculateLayout(
      attributedString: attributed,
      minimumNumberOfLines: 0,
      maximumNumberOfLines: maxLines,
      truncationType: .end,
      backgroundColor: nil,
      constrainedSize: CGSize(width: width, height: .greatestFiniteMagnitude),
      alignment: .natural,
      verticalAlignment: .top,
      lineSpacingFactor: lineSpacing,
      cutout: nil,
      insets: .zero,
      lineColor: nil,
      textShadowColor: nil,
      textShadowBlur: nil,
      textStroke: nil,
      displaySpoilers: false,
      displayEmbeddedItemsUnderSpoilers: false,
      customTruncationToken: nil
    )
    return layout.size.height
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

  /// 列表展示档：all_origin 用原图，其余用服务端显示档（src = cdn_src，对 GIF
  /// 即 g=0 静态档；CDN 的 sign 绑定变换段，客户端不许改写，见 TiebaNuke「GIF
  /// 三档」注）。
  static func displayURL(_ image: TiebaThreadImage, preferences: TiebaPostPreferences) -> URL? {
    if preferences.imageLoadType == "all_no" { return nil }
    let raw = preferences.imageLoadType == "all_origin"
      ? (image.originSrc.isEmpty ? image.src : image.originSrc)
      : (image.src.isEmpty ? image.originSrc : image.src)
    return TiebaPhotoItem.normalizedURL(raw)
  }

  /// GIF 判定候选链（列表行用；按可靠度排序，去重由 TiebaNuke.firstGIFURL 做）。
  ///
  /// 线上取证（2026-10-06，用户报的 p/11060036651 全量 29 图 / 25 张动图）：
  /// - 动图档 big_cdn_src（w=1920）对动图 **25/25** 返回 image/gif，且 HEAD 头与 GET
  ///   字节魔数 116/116 无分歧（同一 URL 的 HEAD/GET 不会不一致）；
  /// - 显示档 cdn_src（g=0 档）只有 **10/25** 是动图字节，其余 15 张是静态 JPEG
  ///   —— 谁拿它做判定，谁就漏判六成；
  /// - 原图档 origin_src 对动图 **25/25** 命中（与动图档同字节）。
  ///
  /// 因此口径：**有独立动图档 → 只探它**（一张图一次 HEAD，列表探测流量与改动前一致）；
  /// 只有"服务端没给动图档、bigSrc 回落到显示档"时才补一次原图档，
  /// 堵住"显示档是静态 JPEG"这条结构性漏判。
  static func gifProbeCandidates(_ image: TiebaThreadImage) -> [URL?] {
    let display = image.src.isEmpty ? nil : TiebaPhotoItem.normalizedURL(image.src)
    let animated = image.bigSrc.isEmpty ? nil : TiebaPhotoItem.normalizedURL(image.bigSrc)
    let origin = image.originSrc.isEmpty ? nil : TiebaPhotoItem.normalizedURL(image.originSrc)
    guard let animated, animated != display else {
      return [display, origin]
    }
    return [animated]
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