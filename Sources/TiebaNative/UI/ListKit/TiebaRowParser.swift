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
    let visible = layoutManager.glyphRange(for: container)
    // 阶段 0：**未取整**的 usedRect 高。绘制期旧实现那一趟 boundingRect 量出来的就是
    // 它；存下来供垂直居中直接取用 ⇒ 绘制期不再排版第二遍。这里绝不能 ceil：frame
    // 高是 ceil 过的，旧的居中偏移 (frame.height - used)/2 ∈ [0, 0.5) 全靠它复刻
    //（换成 ceil 值会让偏移变 0，整段文字上移最多 0.5pt，不是逐像素一致）。
    let exactHeight = layoutManager.usedRect(for: container).height
    // ceil：避免 22.0001 → 22 后 UILabel 最后一行被裁掉半像素。
    let height = ceil(exactHeight)
    let truncated = maxLines > 0 && visible.upperBound < layoutManager.numberOfGlyphs
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

  /// JS relativeTime（src/utils/index.ts:59）。
  static func relativeTime(ms: Double) -> String {
    guard ms > 0, ms >= 946_684_800_000 else { return "" }
    let nowMs = Date().timeIntervalSince1970 * 1000
    let diff = max(0, nowMs - ms)
    let minute = 60_000.0
    let hour = 60 * minute
    let day = 24 * hour
    if diff < minute { return "刚刚" }
    if diff < hour { return "\(Int(diff / minute))分钟前" }
    if diff < day { return "\(Int(diff / hour))小时前" }
    let date = Date(timeIntervalSince1970: ms / 1000)
    let calendar = Calendar.current
    let startOfToday = calendar.startOfDay(for: Date())
    let startOfThen = calendar.startOfDay(for: date)
    if let yesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday),
       calendar.isDate(startOfThen, inSameDayAs: yesterday) {
      return "昨天 \(clockFormatter.string(from: date))"
    }
    if diff < 7 * day { return "\(Int(diff / day))天前" }
    return dayOnlyFormatter.string(from: date)
  }

  /// JS absoluteTime（src/utils/index.ts:81）。
  static func absoluteTime(ms: Double) -> String {
    guard ms > 0, ms >= 946_684_800_000 else { return "" }
    return absoluteTimeFormatter.string(from: Date(timeIntervalSince1970: ms / 1000))
  }

  // 三个格式化档按需缓存（与 TiebaPostRowMetrics 同款）。
  // DateFormatter 的构造要解析 locale/历法/时区，是重对象；而行模型是**逐行**构造的，
  // 现建现用等于每页几十次纯浪费（且测量跑在 .userInitiated 的后台任务上，与滚动抢 CPU）。
  // 线程安全依据（SDK 原文）：NSDateFormatter.h:158 "On iOS 7 and later NSDateFormatter is
  // thread safe"，且该类型标了 NS_SWIFT_SENDABLE —— 建好后只调 string(from:)、不再改动。
  // 地区/历法固定，避免佛历等脏输出。
  private static let clockFormatter = timeFormatter("HH:mm")
  private static let dayOnlyFormatter = timeFormatter("yyyy-MM-dd")
  private static let absoluteTimeFormatter = timeFormatter("yyyy-MM-dd HH:mm")

  private static func timeFormatter(_ format: String) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.dateFormat = format
    return formatter
  }

  /// mediaList → 图片数组（type=="image"）。显示档 = src（服务端 big_pic，对
  /// GIF 即 g=0 静态压缩档）；动图档 = smallSrc（服务端 src_pic，GIF 动图字节）。
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
