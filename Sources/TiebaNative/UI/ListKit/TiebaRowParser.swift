// 从 TiebaRowMetrics.swift 拆出（H10 千行文件拆分）：行级共享工具（TextKit 测量 / 字典取值）+ 字典解析 + 兜底。
// 纯搬运：整类型逐字搬走；唯一改动 = TiebaFeedRowParser 的访问级从 private 放开到 internal
//（它现在被另一个文件里的 TiebaFeedRowModel 调用；这是本次拆分里唯一一处访问级调整）。

import UIKit

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
