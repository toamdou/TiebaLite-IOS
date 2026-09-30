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

  /// 进程内缓存：words()/users() 在每次页面加载/行测量都会读（Explore 首屏与
  /// 翻页、消息页、帖子行测量），SQLite 扫描 + 逐项 JSON 解码不该重复付。
  /// 写入口只有下面 add/remove 四个方法（legacy 迁移写发生在首次 load 内、
  /// 缓存赋值之前），写时失效即可。
  private static let cacheLock = NSLock()
  nonisolated(unsafe) private static var cachedWords: [TiebaBlockedWord]?
  nonisolated(unsafe) private static var cachedUsers: [TiebaBlockedUser]?

  /// 正则屏蔽词的编译记忆化：NSRegularExpression 编译是百 μs 级，同一 keyword
  /// 会被多个消费方反复编译（feed 页过滤、帖子行测量、消息页），按 keyword 只编
  /// 一次；编译失败的记 nil，坏词不再反复撞编译。条目数以屏蔽词表为上界。
  nonisolated(unsafe) private static var regexCache: [String: NSRegularExpression?] = [:]

  static func words() -> [TiebaBlockedWord] {
    cacheLock.withLock {
      if let cached = cachedWords { return cached }
      let loaded = load(prefix: wordPrefix, legacyKey: legacyWordsKey) { (word: TiebaBlockedWord) in word.id }
      cachedWords = loaded
      return loaded
    }
  }

  static func users() -> [TiebaBlockedUser] {
    cacheLock.withLock {
      if let cached = cachedUsers { return cached }
      let loaded = load(prefix: userPrefix, legacyKey: legacyUsersKey) { (user: TiebaBlockedUser) in user.uid }
      cachedUsers = loaded
      return loaded
    }
  }

  static func add(word: TiebaBlockedWord) throws {
    try write(word, key: wordPrefix + word.id)
    invalidateWords()
  }

  static func removeWord(id: String) throws {
    try TiebaKvStore.shared.remove(key: wordPrefix + id)
    invalidateWords()
  }

  static func add(user: TiebaBlockedUser) throws {
    guard !users().contains(where: { $0.uid == user.uid }) else { return }
    try write(user, key: userPrefix + user.uid)
    invalidateUsers()
  }

  static func removeUser(uid: String) throws {
    try TiebaKvStore.shared.remove(key: userPrefix + uid)
    invalidateUsers()
  }

  /// 屏蔽词正则的共享编译入口（各消费方的 load 路径都走这里）。
  static func compiledRegex(pattern: String) -> NSRegularExpression? {
    regexCacheLock.withLock {
      if let cached = regexCache[pattern] { return cached }
      // NSRegularExpression 未标 Sendable 但线程安全（Apple 文档），跨线程只读。
      let compiled = try? NSRegularExpression(pattern: pattern) as NSRegularExpression?
      regexCache[pattern] = compiled
      return compiled
    }
  }

  private static let regexCacheLock = NSLock()

  /// 屏蔽表变更计数：消费方（吧页行派发缓存）以此为缓存键的一部分，屏蔽增删
  /// 后旧派发结果自动失效。
  static var changeVersion: Int {
    cacheLock.withLock { changeCount }
  }

  nonisolated(unsafe) private static var changeCount = 0

  private static func invalidateWords() {
    cacheLock.withLock {
      cachedWords = nil
      changeCount &+= 1
    }
  }

  private static func invalidateUsers() {
    cacheLock.withLock {
      cachedUsers = nil
      changeCount &+= 1
    }
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

    // 键值对单条 range 查询（GLOB 前缀走主键索引）：替代 keys(prefix:) 的
    // substr 全索引扫描 + 逐键 get 的 N+1（每键一轮 prepare/step/finalize）。
    for (_, raw) in store.scan(prefix: prefix) {
      guard let item = decode(raw) else { continue }
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
