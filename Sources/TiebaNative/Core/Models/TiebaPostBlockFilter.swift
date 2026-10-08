import UIKit
import Nuke

struct TiebaPostBlockFilter: Sendable {
  /// NSRegularExpression 未标 Sendable 但线程安全（Apple 文档）；跨线程只读。
  struct Word: @unchecked Sendable {
    var keyword = ""
    var regex: NSRegularExpression?
    var whitelist = false
  }

  /// **正则**词（字面量词不进这张表，见下面两条交替正则）。
  var words: [Word] = []
  /// 字面量词按白/黑名单各合成一条交替正则（TiebaBlockStore.compiledLiteralAlternation）。
  /// [算法审查 40] 本类型的最热调用点是 TiebaPostRowText:68 —— **每个正文段**都过一遍屏蔽表，
  /// 整页测量里是 O(行 × 段 × 词 × 长度)；合成一条后与词数无关（实测 20 词 11.5ms → 0.41ms/64 行）。
  var whitelistLiterals: NSRegularExpression?
  var blacklistLiterals: NSRegularExpression?
  var users: [(uid: String, name: String)] = []

  /// 词表为空（正则词与字面量都没有）⇒ 调用方可早退，省掉一次正则扫描。
  /// [算法审查 40 §4.E] Explore 页与消息页收敛到本类型后，用它替代原来各自的 `words.isEmpty`。
  var isEmpty: Bool { words.isEmpty && whitelistLiterals == nil && blacklistLiterals == nil }

  static func load() -> TiebaPostBlockFilter {
    let stored: [TiebaBlockedWord] = TiebaBlockStore.words().filter { !$0.keyword.isEmpty }
    var filter = TiebaPostBlockFilter()
    // 只有正则词留在逐条表里：编译走 BlockStore 的记忆化（整页测量每行都调 load，正则只编一次）。
    filter.words = stored.compactMap { word in
      guard word.isRegex == true else { return nil }
      return Word(
        keyword: word.keyword,
        regex: TiebaBlockStore.compiledRegex(pattern: word.keyword),
        whitelist: word.isWhitelist
      )
    }
    filter.whitelistLiterals = TiebaBlockStore.compiledLiteralAlternation(
      stored.filter { $0.isRegex != true && $0.isWhitelist }.map(\.keyword)
    )
    filter.blacklistLiterals = TiebaBlockStore.compiledLiteralAlternation(
      stored.filter { $0.isRegex != true && !$0.isWhitelist }.map(\.keyword)
    )
    filter.users = TiebaBlockStore.users().map { ($0.uid, $0.username ?? "") }
    return filter
  }

  func isContentBlocked(_ text: String) -> Bool {
    guard !text.isEmpty else { return false }
    let range = NSRange(text.startIndex..., in: text)
    func regexHit(_ word: Word) -> Bool {
      word.regex?.firstMatch(in: text, range: range) != nil
    }
    // 语义与改前逐行等价：任一白名单词命中 → 放行；否则任一黑名单词命中 → 屏蔽。
    // 字面量走一条交替正则，正则词仍逐条测（顺序无关，判据只看"有没有命中"）。
    if whitelistLiterals?.firstMatch(in: text, range: range) != nil { return false }
    for word in words where word.whitelist && regexHit(word) { return false }
    if blacklistLiterals?.firstMatch(in: text, range: range) != nil { return true }
    return words.contains { !$0.whitelist && regexHit($0) }
  }

  func isUserBlocked(uid: String, name: String) -> Bool {
    users.contains { $0.uid == uid || (!name.isEmpty && $0.name == name) }
  }
}
