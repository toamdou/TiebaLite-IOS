// 路由路径段编码（encodeURIComponent 等价字符集）。吧名/关键词里的 ? # / % 不编码
// 会被 TiebaRouteTable.parse 的首个 ? 切成查询串、命中别的路由；解析端
// removingPercentEncoding 会还原，所以编码是单向且安全的。
//
// 类型化路由落地后只剩两处消费者：深链拼查询串（TiebaNavigator.open(url:)）与
// TiebaRoute.signature（连点去重）；本地跳转走类型化参数，不再经过字符串。
import Foundation

enum TiebaRoutePath {
  private static let segmentAllowed = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()"
  )

  /// 一段路径值（吧名 / uid / 关键词）→ 可安全拼进 path 的形式。
  static func segment(_ raw: String) -> String {
    raw.addingPercentEncoding(withAllowedCharacters: segmentAllowed) ?? raw
  }

  /// 表单体编码（application/x-www-form-urlencoded）：按 key 排序后
  /// `k=v&k=v`。三类调用方（门面 postForm / 社交签名 POST / 关注列表抓取）原先
  /// 各写一份同样的链，收敛到这里。
  ///
  /// 排序是刻意的：签名（TiebaSigner.signParams）内部自己排一次，但请求体也排
  /// 一次让同参数的两次请求字节一致，便于对照取证。
  static func formBody(_ fields: [String: String]) -> String {
    fields
      .sorted { $0.key < $1.key }
      .map { "\($0.key)=\(segment($0.value))" }
      .joined(separator: "&")
  }
}
