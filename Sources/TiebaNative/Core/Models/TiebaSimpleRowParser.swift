import UIKit
import Nuke
import NukeExtensions

nonisolated enum TiebaSimpleRowParser {
  /// 取值/URL 规整的实现在 TiebaRowDict（全仓唯一一份）；本入口保留给既有调用方。
  static func string(_ value: Any?) -> String? {
    TiebaRowDict.string(value)
  }

  static func nonEmpty(_ value: Any?) -> String? {
    TiebaRowDict.nonEmpty(value)
  }

  static func double(_ value: Any?) -> Double? {
    TiebaRowDict.double(value)
  }

  static func bool(_ value: Any?) -> Bool? {
    TiebaRowDict.bool(value)
  }

  /// portrait 尾部 "?" 后的加密段裁剪（原 JS cleanPortrait）。
  static func cleanPortrait(_ raw: String) -> String {
    guard let index = raw.firstIndex(of: "?") else { return raw }
    return String(raw[raw.startIndex..<index])
  }

  /// 头像 URL：完整 URL / 本地 URI 直通，portrait id 拼 himg 前缀
  /// （src/utils/index.ts getAvatarUrl；实现在 TiebaRowDict）。
  static func avatarURL(_ portrait: String) -> URL? {
    TiebaRowDict.avatarURL(portrait)
  }
}
