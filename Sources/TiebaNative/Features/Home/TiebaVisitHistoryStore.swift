// 浏览记录 / 收藏图片快照的读写（原 src/services/storage/visitHistory.ts +
// favoriteImages.ts）。**不新增存储路径**：浏览记录就是全 App 唯一的
// tiebalite.db 的 visit_history 表（帖子页已在写，见 TiebaThreadViewController），
// 收藏图片快照是同一个 KV 的 favorite_images 键。
// 旧版独立库 tiebalite_visit_history.db 一次性并进来（原 JS 的
// migrateLegacySqliteTablesAsync）：老设备不并库 = 历史读不到，搬完删旧库防"清空复活"。
import Foundation
import os

struct TiebaHistoryEntry {
  var rowId: Int64 = 0
  /// "thread" | "forum"
  var type = "thread"
  var threadId = ""
  var forumId = ""
  var forumName = ""
  var avatar = ""
  var title = ""
  var authorName = ""
  var authorPortrait = ""
  var timestamp: Double = 0

  /// 展示/去重 id（原 rowToItem：吧记录优先 forum_id，帖记录优先 thread_id）。
  var id: String {
    if type == "forum" {
      if !forumId.isEmpty { return forumId }
      if !forumName.isEmpty { return forumName }
      return String(rowId)
    }
    return threadId.isEmpty ? String(rowId) : threadId
  }

  /// 去重键（原 dedupe：type + (threadId | forumName | id)）。
  var dedupeKey: String {
    let tail = threadId.isEmpty ? (forumName.isEmpty ? id : forumName) : threadId
    return "\(type)-\(tail)"
  }
}

enum TiebaVisitHistoryStore {
  private static let columns =
    "id, type, thread_id, forum_id, forum_name, avatar, title, author_name, author_portrait, timestamp"

  /// 每类历史的上限（117）：读带 LIMIT，超出即在同一次后台任务里淘汰旧行。
  /// 500 远超正常翻页需求，同时把"历史无上限增长"封顶。
  private static let maxRows = 500

  /// 旧版独立库文件名（与 JS migrateLegacySqliteTablesAsync 逐字一致）。
  private static let legacyDatabase = "tiebalite_visit_history.db"
  private static let migrationLock = NSLock()
  /// nonisolated(unsafe)：只在 migrationLock 内读写（进程内一次，失败下次启动再试）。
  nonisolated(unsafe) private static var migrationAttempted = false
  private static let log = Logger(subsystem: "com.tiebalite.app", category: "visit-history")

  /// 记录列表（按时间倒序 + 去重；与旧页 getVisitHistory 同一查询）。
  /// 缺表/缺列（老设备遗留库）按"没有记录"返回：页面给空态而非整屏加载失败。
  static func list(type: String) async throws -> [TiebaHistoryEntry] {
    try await Task.detached(priority: .userInitiated) { () -> [TiebaHistoryEntry] in
      migrateLegacyDatabaseIfNeeded()
      let rows: [[String: Any]]
      do {
        // 按类过滤 + LIMIT：历史只增不减，全表 SELECT 会随使用无限变慢（117）。
        if type == "all" {
          rows = try TiebaSQLite.shared.query(
            database: TiebaSQLite.mainDatabase,
            sql: "SELECT \(columns) FROM visit_history ORDER BY timestamp DESC, id DESC LIMIT \(maxRows)",
            params: []
          )
        } else {
          rows = try TiebaSQLite.shared.query(
            database: TiebaSQLite.mainDatabase,
            sql: "SELECT \(columns) FROM visit_history WHERE type = ? ORDER BY timestamp DESC, id DESC LIMIT \(maxRows)",
            params: [["v": type]]
          )
        }
      } catch {
        guard isSchemaMismatch(error) else { throw error }
        log.error("visit_history unreadable, showing empty: \(error.localizedDescription, privacy: .public)")
        return []
      }
      if rows.count >= maxRows { evictOverflow() }
      var seen = Set<String>()
      var result: [TiebaHistoryEntry] = []
      for row in rows {
        let entry = makeEntry(row)
        if type == "all" || entry.type == type {
          guard seen.insert(entry.dedupeKey).inserted else { continue }
          result.append(entry)
        } else {
          // 去重按全表口径（同一帖/吧的跨类型重复不该出现，这里保持一致）。
          seen.insert(entry.dedupeKey)
        }
      }
      return result
    }.value
  }

  /// 删除若干行（单条 IN 批量，与原 removeVisit 一次写库同法）。
  static func remove(rowIds: [Int64]) async throws {
    guard !rowIds.isEmpty else { return }
    let placeholders = rowIds.map { _ in "?" }.joined(separator: ", ")
    try await Task.detached(priority: .userInitiated) {
      _ = try TiebaSQLite.shared.run(
        database: TiebaSQLite.mainDatabase,
        sql: "DELETE FROM visit_history WHERE id IN (\(placeholders))",
        params: rowIds.map { ["v": $0] }
      )
    }.value
  }

  /// 清空某一类（type 为空 = 全清）。
  static func clear(type: String) async throws {
    try await Task.detached(priority: .userInitiated) {
      if type.isEmpty {
        _ = try TiebaSQLite.shared.run(
          database: TiebaSQLite.mainDatabase,
          sql: "DELETE FROM visit_history",
          params: []
        )
      } else {
        _ = try TiebaSQLite.shared.run(
          database: TiebaSQLite.mainDatabase,
          sql: "DELETE FROM visit_history WHERE type = ?",
          params: [["v": type]]
        )
      }
    }.value
  }

  /// 回填老记录缺失的作者信息（只补空字段，与原 updateThreadAuthorInfo 同 SQL）。
  static func updateAuthorInfo(
    threadId: String,
    authorName: String,
    authorPortrait: String,
    forumName: String
  ) async {
    guard !threadId.isEmpty else { return }
    await Task.detached(priority: .utility) {
      _ = try? TiebaSQLite.shared.run(
        database: TiebaSQLite.mainDatabase,
        sql: """
          UPDATE visit_history SET
            author_name = CASE WHEN author_name = '' THEN ? ELSE author_name END,
            author_portrait = CASE WHEN author_portrait = '' THEN ? ELSE author_portrait END,
            forum_name = CASE WHEN forum_name = '' THEN ? ELSE forum_name END
          WHERE type = 'thread' AND thread_id = ?
          """,
        params: [
          ["v": authorName], ["v": authorPortrait], ["v": forumName], ["v": threadId],
        ]
      )
    }.value
  }

  // MARK: - 旧版独立库并库（一次性；原 JS migrateLegacySqliteTablesAsync）

  /// 把 tiebalite_visit_history.db 的行并进统一库，成功即删旧库——不删则
  /// "清空历史"后下次启动旧行复活。失败只记日志不重试（下次启动再试）。
  private static func migrateLegacyDatabaseIfNeeded() {
    migrationLock.withLock {
      guard !migrationAttempted else { return }
      migrationAttempted = true
      guard TiebaSQLite.shared.databaseExists(named: legacyDatabase) else { return }
      do {
        let rows = try TiebaSQLite.shared.query(
          database: legacyDatabase,
          sql: "SELECT * FROM visit_history ORDER BY timestamp DESC, id DESC",
          params: []
        )
        if !rows.isEmpty {
          try TiebaSQLite.shared.begin(database: TiebaSQLite.mainDatabase)
          do {
            for row in rows { try mergeLegacyRow(row) }
            try TiebaSQLite.shared.commit(database: TiebaSQLite.mainDatabase)
          } catch {
            try? TiebaSQLite.shared.rollback(database: TiebaSQLite.mainDatabase)
            throw error
          }
        }
        try? TiebaSQLite.shared.deleteDatabase(named: legacyDatabase)
      } catch {
        log.error("legacy visit history merge failed: \(error.localizedDescription, privacy: .public)")
      }
    }
  }

  /// 单行并库：统一库已有同键（type + 帖 id / 吧名）就跳过，旧行不得覆盖或
  /// 降级新记录；旧表可能没有的列在 SELECT * 里缺失 → 按空串落库。
  private static func mergeLegacyRow(_ row: [String: Any]) throws {
    let type = text(row["type"]) == "forum" ? "forum" : "thread"
    let keyColumn = type == "forum" ? "forum_name" : "thread_id"
    let keyValue = text(row[keyColumn])
    if !keyValue.isEmpty {
      let existing = try? TiebaSQLite.shared.queryFirst(
        database: TiebaSQLite.mainDatabase,
        sql: "SELECT id FROM visit_history WHERE type = ? AND \(keyColumn) = ? LIMIT 1",
        params: [["v": type], ["v": keyValue]]
      )
      if existing != nil { return }
    }
    _ = try TiebaSQLite.shared.run(
      database: TiebaSQLite.mainDatabase,
      sql: """
        INSERT INTO visit_history (
          type, thread_id, forum_id, forum_name, avatar, title, author_name, author_portrait, timestamp
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
      params: [
        ["v": type],
        ["v": text(row["thread_id"])],
        ["v": text(row["forum_id"])],
        ["v": text(row["forum_name"])],
        ["v": text(row["avatar"])],
        ["v": text(row["title"])],
        ["v": text(row["author_name"])],
        ["v": text(row["author_portrait"])],
        ["v": TiebaJSON.doubleValue(row["timestamp"]) ?? 0],
      ]
    )
  }

  /// schema 级错误（no such table / no such column）：读不出来按空历史显示。
  private static func isSchemaMismatch(_ error: Error) -> Bool {
    let message = error.localizedDescription.lowercased()
    return message.contains("no such table") || message.contains("no such column")
  }

  /// 淘汰超出上限的旧行（每类保留最新 maxRows 条，排序与 list 同口径）。
  /// 维护动作失败不影响本次读取（下次 list 再试），但必须留日志。
  private static func evictOverflow() {
    for type in ["thread", "forum"] {
      do {
        _ = try TiebaSQLite.shared.run(
          database: TiebaSQLite.mainDatabase,
          sql: """
            DELETE FROM visit_history WHERE type = ? AND id NOT IN (
              SELECT id FROM visit_history WHERE type = ? ORDER BY timestamp DESC, id DESC LIMIT ?
            )
            """,
          params: [["v": type], ["v": type], ["v": maxRows]]
        )
      } catch {
        log.error("visit_history eviction failed: \(error.localizedDescription, privacy: .public)")
      }
    }
  }

  // MARK: - 收藏图片快照（KV 键与 JS favoriteImages.ts 同一份）

  private static let favoriteImagesKey = "@tiebalite:favorite_images_v1"

  static func favoriteImages(tid: String) -> [String] {
    favoriteImagesMap()[tid] ?? []
  }

  /// 全量快照（一次读、按需取，避免逐行重复解析 JSON）。
  static func favoriteImagesMap() -> [String: [String]] {
    guard let raw = TiebaKvStore.shared.get(key: favoriteImagesKey),
      let data = raw.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: [String]]
    else { return [:] }
    return object
  }

  static func removeFavoriteImages(tid: String) {
    var map = favoriteImagesMap()
    guard map[tid] != nil else { return }
    map.removeValue(forKey: tid)
    guard let data = try? JSONSerialization.data(withJSONObject: map),
      let text = String(data: data, encoding: .utf8)
    else { return }
    do {
      try TiebaKvStore.shared.set(key: favoriteImagesKey, value: text)
    } catch {
      log.error("favorite images snapshot write failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  // MARK: - 行解析

  private static func makeEntry(_ row: [String: Any]) -> TiebaHistoryEntry {
    var entry = TiebaHistoryEntry()
    entry.rowId = Int64(TiebaJSON.doubleValue(row["id"]) ?? 0)
    entry.type = text(row["type"]) == "forum" ? "forum" : "thread"
    entry.threadId = text(row["thread_id"])
    entry.forumId = text(row["forum_id"])
    entry.forumName = text(row["forum_name"])
    entry.avatar = text(row["avatar"])
    entry.title = text(row["title"])
    entry.authorName = text(row["author_name"])
    entry.authorPortrait = text(row["author_portrait"])
    entry.timestamp = TiebaJSON.doubleValue(row["timestamp"]) ?? 0
    return entry
  }

  /// 列值 → 非空串（SQLite 列可能是 text/int/real，TiebaJSON 统一处理）。
  private static func text(_ value: Any?) -> String {
    TiebaJSON.stringValue(value) ?? ""
  }
}
