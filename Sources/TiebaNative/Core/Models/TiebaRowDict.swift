import UIKit

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
