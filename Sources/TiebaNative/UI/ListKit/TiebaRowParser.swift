// 从 TiebaRowMetrics.swift 拆出（H10 千行文件拆分）：行级共享工具（TextKit 测量 / 字典取值）+ 字典解析 + 兜底。
// 纯搬运：整类型逐字搬走；唯一改动 = TiebaFeedRowParser 的访问级从 private 放开到 internal
//（它现在被另一个文件里的 TiebaFeedRowModel 调用；这是本次拆分里唯一一处访问级调整）。

import UIKit

nonisolated enum TiebaRowText {
  /// 调用方保证在测量队列上；maxLines = 0 表示不限行数（NSTextContainer 语义）。
  static func measureHeight(_ attributed: NSAttributedString, width: CGFloat, maxLines: Int) -> CGFloat {
    measure(attributed, width: width, maxLines: maxLines).height
  }

  // ── 可复用 TextKit 栈 ──
  // 整页 prepare 逐行调 measure：信息流一行 2-3 处、一页 60+ 次；帖子页 400 楼
  // publish 数百次。每次新建 NSTextStorage+NSLayoutManager+NSTextContainer 的
  // 三件套分配与 layoutManager 冷启动是排版之外的纯开销（NSLayoutManager 属重
  // 对象）。测量恒在串行队列/后台 prepare 内执行（见 prepareFeedRowsBlocking 的
  // 契约），同一时刻只有一个调用方——按持锁换取单套栈复用即可，高度/截断判据
  // 不变。锁同时保护"递归进入 measure"（TextKit 回调不会再进 measure，防御）。
  private static let measureStackLock = NSLock()
  nonisolated(unsafe) private static var measureStorage: NSTextStorage?
  nonisolated(unsafe) private static var measureLayoutManager: NSLayoutManager?
  nonisolated(unsafe) private static var measureContainer: NSTextContainer?

  /// 高度（ceil 后的块高）+ **未取整**的 usedRect 高（阶段 0 的绘制期自然高）+
  /// 是否真被 maxLines 截断（同一趟布局里判：截断时可见字形范围盖不到
  /// 末字形）。三个值同出一趟布局、零额外排版。折叠判据必须用"真截断"，
  /// 不能只比字数。
  static func measure(
    _ attributed: NSAttributedString,
    width: CGFloat,
    maxLines: Int
  ) -> (height: CGFloat, exactHeight: CGFloat, truncated: Bool) {
    guard attributed.length > 0, width > 0 else { return (0, 0, false) }
    measureStackLock.lock()
    defer { measureStackLock.unlock() }
    let storage: NSTextStorage
    let layoutManager: NSLayoutManager
    let container: NSTextContainer
    if let reusableStorage = measureStorage,
      let reusableLayout = measureLayoutManager,
      let reusableContainer = measureContainer
    {
      storage = reusableStorage
      layoutManager = reusableLayout
      container = reusableContainer
    } else {
      storage = NSTextStorage(attributedString: attributed)
      layoutManager = NSLayoutManager()
      container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
      storage.addLayoutManager(layoutManager)
      layoutManager.addTextContainer(container)
      measureStorage = storage
      measureLayoutManager = layoutManager
      measureContainer = container
    }
    storage.setAttributedString(attributed)
    container.size = CGSize(width: width, height: .greatestFiniteMagnitude)
    container.maximumNumberOfLines = maxLines
    container.lineBreakMode = .byTruncatingTail
    layoutManager.ensureLayout(for: container)
    // 阶段 0：**未取整**的 usedRect 高。绘制期旧实现那一趟 boundingRect 量出来的就是
    // 它；存下来供垂直居中直接取用 ⇒ 绘制期不再排版第二遍。这里绝不能 ceil：frame
    // 高是 ceil 过的，旧的居中偏移 (frame.height - used)/2 ∈ [0, 0.5) 全靠它复刻
    //（换成 ceil 值会让偏移变 0，整段文字上移最多 0.5pt，不是逐像素一致）。
    let exactHeight = layoutManager.usedRect(for: container).height
    // ceil：避免 22.0001 → 22 后 UILabel 最后一行被裁掉半像素。
    let height = ceil(exactHeight)
    // 截断判据（截断态才给「加载更多」）——**不能**比 glyphRange(for:)：容器把整段字形都算作
    // 「在容器里」，限行只体现在排版出的**行数**上（实测：216 字限 4 行时 glyphRange 仍报
    // 216/216）。这里问 NSLayoutManager 本人：最后一行有没有被截掉的字形。
    //（改前那一版恒为 false ⇒ 长文永远不长出展开入口，用户 2026-10-06 报「没有加载更多按钮」。）
    var truncated = false
    if maxLines > 0, layoutManager.numberOfGlyphs > 0 {
      var lastLineStart = 0
      layoutManager.enumerateLineFragments(
        forGlyphRange: NSRange(location: 0, length: layoutManager.numberOfGlyphs)
      ) { _, _, _, range, _ in
        lastLineStart = range.location
      }
      truncated = layoutManager.truncatedGlyphRange(
        inLineFragmentForGlyphAt: lastLineStart
      ).length > 0
    }
    return (height, exactHeight, truncated)
  }

  /// 单行文本宽（徽章内联定位用；不改行高）。
  static func singleLineWidth(_ text: String, font: UIFont) -> CGFloat {
    guard !text.isEmpty else { return 0 }
    return ceil((text as NSString).size(withAttributes: [.font: font]).width)
  }
}

/// 行字典取值（JS 桥字典的宽容读取 + 头像/URL 规整）：TiebaFeedRowParser 与
/// TiebaSimpleRowParser 都转发到这里，规则只有这一份。
nonisolated enum TiebaRowDict {
  static func string(_ value: Any?) -> String? {
    guard let value, !(value is NSNull) else { return nil }
    if let string = value as? String { return string }
    if let number = value as? NSNumber {
      if CFGetTypeID(number) == CFBooleanGetTypeID() {
        return number.boolValue ? "true" : "false"
      }
      return number.stringValue
    }
    return nil
  }

  static func nonEmpty(_ value: Any?) -> String? {
    guard let string = string(value), !string.isEmpty else { return nil }
    return string
  }

  /// 可见文案（缺省 = ""）：非空**且含非空白字符**才算有值。
  /// 与 nonEmpty 的分工：需要「有这段内容」的渲染输入（标题/摘要）用它 —— 纯空白的串
  /// 排出来是一行高度却没有字形，留着就是一条无内容的空白（见 TiebaFeedRowModel 正文段）。
  static func visible(_ value: Any?) -> String {
    guard let string = nonEmpty(value),
          string.contains(where: { !$0.isWhitespace }) else { return "" }
    return string
  }

  static func double(_ value: Any?) -> Double? {
    guard let value, !(value is NSNull) else { return nil }
    if let number = value as? NSNumber { return number.doubleValue }
    if let string = value as? String { return Double(string) }
    return nil
  }

  static func bool(_ value: Any?) -> Bool? {
    guard let value, !(value is NSNull) else { return nil }
    if let bool = value as? Bool { return bool }
    if let number = value as? NSNumber { return number.boolValue }
    if let string = value as? String { return (string as NSString).boolValue }
    return nil
  }

  /// http / 协议相对 → https（ATS 禁明文；thumbnailUrl 同语义），并建 URL。
  /// URL(string:) 拒绝非 ASCII：失败时按 percent-encoding 兜底。
  static func sanitizedURL(_ raw: String) -> URL? {
    guard !raw.isEmpty else { return nil }
    var value = raw
    if value.hasPrefix("//") {
      value = "https:" + value
    } else if value.hasPrefix("http://") {
      value = "https://" + value.dropFirst("http://".count)
    }
    if let url = URL(string: value) { return url }
    guard let encoded = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
      return nil
    }
    return URL(string: encoded)
  }

  /// getAvatarUrl（src/utils/index.ts:115）：完整 URL 直通；本地 URI 直通；
  /// portrait id 拼 himg.bdimg.com 前缀。
  static func avatarURL(_ portrait: String) -> URL? {
    guard !portrait.isEmpty else { return nil }
    if portrait.hasPrefix("file://") || portrait.hasPrefix("ph://") {
      return URL(string: portrait)
    }
    if portrait.hasPrefix("http://") || portrait.hasPrefix("https://") {
      return sanitizedURL(portrait)
    }
    return sanitizedURL("https://himg.bdimg.com/sys/portrait/item/\(portrait)")
  }
}

// MARK: - 字典解析（JS 视图模型 → 行模型）

/// 输入 = mapProtoThread / mapFeedThreadItems 的输出字典（helpers.ts），
/// 键名与 src/types/index.ts ThreadInfo 一致。所有字段都可缺省，缺失走与
/// TweetCard 相同的兜底值。通用取值/测量在 TiebaRowDict / TiebaRowText。
nonisolated enum TiebaFeedRowParser {
  static func dictionary(_ value: Any?) -> [String: Any]? {
    guard let value, !(value is NSNull) else { return nil }
    return value as? [String: Any]
  }

  static func array(_ value: Any?) -> [Any]? {
    guard let value, !(value is NSNull) else { return nil }
    return value as? [Any]
  }

  /// JS weightedTextLength（TweetCard.tsx:88）：CJK 记 1、其余记 0.5。
  static func weightedTextLength(_ parts: String?...) -> CGFloat {
    var total: CGFloat = 0
    for part in parts {
      guard let part else { continue }
      for scalar in part.unicodeScalars {
        total += scalar.value > 0xFF ? 1 : 0.5
      }
    }
    return total
  }

  static func parseMedia(_ raw: [String: Any]) -> [TiebaFeedRowMedia] {
    guard let list = array(raw["mediaList"]) else { return [] }
    var result: [TiebaFeedRowMedia] = []
    for element in list {
      guard let item = dictionary(element) else { continue }
      let type = TiebaRowDict.string(item["type"]) ?? "image"
      guard type == "image" else { continue }
      let display = TiebaRowDict.nonEmpty(item["src"])
        ?? TiebaRowDict.nonEmpty(item["smallSrc"])
        ?? TiebaRowDict.nonEmpty(item["originSrc"]) ?? ""
      guard !display.isEmpty else { continue }
      let width = TiebaRowDict.double(item["width"]) ?? 0
      let height = TiebaRowDict.double(item["height"]) ?? 0
      let resolvedWidth = width > 0 ? width : 300
      let resolvedHeight = height > 0 ? height : 300
      let isLong = resolvedHeight / resolvedWidth > Double(TiebaFeedRowLayout.longImageRatio)
      // smallSrc（映射自 Media.src_pic）在 feed 语义里是动图档：GIF 时它是唯一的
      // 动图字节来源；静图它与显示档近似。originSrc 是真正的原图，单独保留。
      result.append(TiebaFeedRowMedia(
        url: TiebaRowDict.sanitizedURL(display),
        animatedURL: TiebaRowDict.nonEmpty(item["smallSrc"]).flatMap(TiebaRowDict.sanitizedURL),
        originURL: TiebaRowDict.nonEmpty(item["originSrc"]).flatMap(TiebaRowDict.sanitizedURL),
        isLong: isLong,
        showOriginalBtn: TiebaRowDict.bool(item["showOriginalBtn"]) == true,
        width: resolvedWidth,
        height: resolvedHeight
      ))
    }
    return result
  }

  /// 视频 poster（MediaPager 的 videoPoster 分支），仅图片数为 0 时绘制。
  static func parseVideoPoster(_ raw: [String: Any]) -> URL? {
    guard let list = array(raw["mediaList"]) else { return nil }
    for element in list {
      guard let item = dictionary(element),
            TiebaRowDict.string(item["type"]) == "video" else { continue }
      if let poster = TiebaRowDict.nonEmpty(item["poster"]) {
        return TiebaRowDict.sanitizedURL(poster)
      }
      if let src = TiebaRowDict.nonEmpty(item["src"]) {
        return TiebaRowDict.sanitizedURL(src)
      }
    }
    return nil
  }

  /// contentToText（src/utils/index.ts:17）：富文本 runs → 纯文本。
  static func contentToText(_ value: Any?) -> String {
    if let string = value as? String { return string }
    guard let segments = array(value) else { return "" }
    var text = ""
    for segment in segments {
      guard let item = dictionary(segment) else { continue }
      let kind = TiebaRowDict.string(item["type"]) ?? ""
      switch kind {
      case "at":
        text += TiebaViewModelMapper.atDisplayText(TiebaRowDict.string(item["text"]) ?? "")
      case "link", "topic", "emoticon", "text", "emoji":
        text += TiebaRowDict.string(item["text"]) ?? ""
      default:
        break
      }
    }
    return text
  }
}

/// 吧名/吧头像回填（原 search.ts 的 `forum_name ?? forumInfo?.forum_name` +
/// feed.ts:97-118 backfillForumAvatars 的唯一落点）：各页行字典的吧名键位不同、
/// 服务端 personalized/动态流恒不下发吧头像，缺名会让度量判据
/// （showForumPill && !forumName.isEmpty）把整块徽章判为不渲染。
/// 头像回填只读全站缓存 KV（forum_avatars_v1，无网络副作用），已有值不覆盖。
nonisolated enum TiebaFeedRowFallback {
  struct Resolved {
    var name = ""
    var avatar = ""
  }

  static func resolve(_ row: [String: Any]) -> Resolved {
    let name = forumName(row)
    return Resolved(name: name, avatar: forumAvatar(row, forumName: name))
  }

  /// 吧名逐键兜底（含 mapProtoThread 的 fname / forumInfo.name / forum.name 变体）。
  static func forumName(_ row: [String: Any]) -> String {
    let forumInfo = row["forumInfo"] as? [String: Any]
    let forumInfoSnake = row["forum_info"] as? [String: Any]
    let forum = row["forum"] as? [String: Any]
    let candidates: [Any?] = [
      row["forumName"], row["forum_name"], row["fname"],
      forumInfo?["forum_name"], forumInfo?["forumName"], forumInfo?["name"],
      forumInfoSnake?["forum_name"], forumInfoSnake?["forumName"], forumInfoSnake?["name"],
      forum?["forumName"], forum?["forum_name"], forum?["name"],
    ]
    for candidate in candidates {
      if let text = TiebaRowDict.nonEmpty(candidate) { return text }
    }
    return ""
  }

  /// 吧头像：行内已有值直通；缺失按 forumId 优先、退 `n:<吧名>` 读 KV 缓存。
  static func forumAvatar(_ row: [String: Any], forumName: String) -> String {
    let forumInfo = row["forumInfo"] as? [String: Any]
    let forumInfoSnake = row["forum_info"] as? [String: Any]
    let forum = row["forum"] as? [String: Any]
    let candidates: [Any?] = [
      row["forumAvatar"], row["forum_avatar"],
      forumInfo?["avatar"], forumInfoSnake?["avatar"], forum?["avatar"],
    ]
    for candidate in candidates {
      if let text = TiebaRowDict.nonEmpty(candidate) { return text }
    }
    let forumId = TiebaRowDict.string(row["forumId"] ?? row["forum_id"] ?? row["fid"]) ?? ""
    guard !forumId.isEmpty || !forumName.isEmpty,
          let key = TiebaForumAvatarCache.key(forumId: forumId, forumName: forumName)
    else { return "" }
    return TiebaForumAvatarCache.shared.cached(key: key)
  }
}
