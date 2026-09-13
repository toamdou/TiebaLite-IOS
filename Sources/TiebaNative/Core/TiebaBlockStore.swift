import Foundation
import os

private let blockLog = Logger(subsystem: "com.tiebalite.app", category: "block-store")

/// 本地屏蔽项（原 src/utils/BlockManager.ts 的落盘格式：统一 SQLite kv 表的
/// 逐项键 `@tiebalite:blocked_word:<id>` / `@tiebalite:blocked_user:<uid>`，
/// 值为 JSON；旧版数组键在读取时一次性迁移，与 JS readBlockedItems 同语义）。
struct TiebaBlockedWord: Codable, Equatable {
  var id: String
  var keyword: String
  var isRegex: Bool?
  var category: String?

  var isWhitelist: Bool { category == "whitelist" }
}

struct TiebaBlockedUser: Codable, Equatable {
  var id: String
  var uid: String
  var username: String?
}

enum TiebaBlockStore {
  private static let wordPrefix = "@tiebalite:blocked_word:"
  private static let userPrefix = "@tiebalite:blocked_user:"
  private static let legacyWordsKey = "@tiebalite:blocked_words"
  private static let legacyUsersKey = "@tiebalite:blocked_users"

  static func words() -> [TiebaBlockedWord] {
    load(prefix: wordPrefix, legacyKey: legacyWordsKey) { $0.id }
  }

  static func users() -> [TiebaBlockedUser] {
    load(prefix: userPrefix, legacyKey: legacyUsersKey) { $0.uid }
  }

  static func add(word: TiebaBlockedWord) throws {
    try write(word, key: wordPrefix + word.id)
  }

  static func removeWord(id: String) throws {
    try TiebaKvStore.shared.remove(key: wordPrefix + id)
  }

  static func add(user: TiebaBlockedUser) throws {
    guard !users().contains(where: { $0.uid == user.uid }) else { return }
    try write(user, key: userPrefix + user.uid)
  }

  static func removeUser(uid: String) throws {
    try TiebaKvStore.shared.remove(key: userPrefix + uid)
  }

  // MARK: - 读写

  private static func write<T: Encodable>(_ item: T, key: String) throws {
    let encoder = JSONEncoder()
    guard let data = try? encoder.encode(item), let text = String(data: data, encoding: .utf8) else {
      throw TiebaKvError.statementFailed("encode \(key)")
    }
    try TiebaKvStore.shared.set(key: key, value: text)
  }

  /// 逐项键 + 旧数组键合并（按主键去重）；旧键存在时迁到逐项键并删除，
  /// 否则删除一项后旧数组会在下次读取时把它复活。
  private static func load<T: Codable>(
    prefix: String,
    legacyKey: String,
    primary: (T) -> String
  ) -> [T] {
    let store = TiebaKvStore.shared
    let decoder = JSONDecoder()
    var items: [T] = []
    var seen = Set<String>()

    func decode(_ raw: String?) -> T? {
      guard let raw, let data = raw.data(using: .utf8) else { return nil }
      return try? decoder.decode(T.self, from: data)
    }

    // 前缀 SQL 查询（116）：此前 allKeys() 全表取回 + 逐键 get + Swift 侧过滤，
    // 进入 feed/消息/资料页都会跑一遍。
    for key in store.keys(prefix: prefix) {
      guard let item = decode(store.get(key: key)) else { continue }
      let value = primary(item)
      if !value.isEmpty, seen.insert(value).inserted { items.append(item) }
    }

    if let raw = store.get(key: legacyKey), let data = raw.data(using: .utf8),
      let legacy = try? decoder.decode([T].self, from: data)
    {
      var writes: [(key: String, value: String?)] = []
      for item in legacy {
        let value = primary(item)
        guard !value.isEmpty, seen.insert(value).inserted else { continue }
        items.append(item)
        if let encoded = try? JSONEncoder().encode(item) {
          writes.append((prefix + value, String(data: encoded, encoding: .utf8)))
        }
      }
      writes.append((legacyKey, nil))
      do {
        try store.batchWrite(writes)
      } catch {
        // 迁移写失败不致命（旧数组键留着，下次读取重跑），但不能无声。
        blockLog.error("blocked items migration failed: \(error.localizedDescription, privacy: .public)")
      }
    }
    return items
  }
}
