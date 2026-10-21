// 页面级持久缓存：动态页/吧页/帖子页/用户资料共用一张带索引的 SQLite 表。
//
// 设计取舍：
// - 只存“网络原始 Data”或调用方已归一化的 JSON Data，不把页面模型塞进全局
//   字典；读命中后的反序列化在 Task.detached 上做，主线程只等 await。
// - cache_key 是主键，单页点查；page_key/account_key/fetched_at 与
//   account_key/kind/last_access_at 各有索引，不做全表扫描。
// - accountKey 来自当前登录 uid（空账号 = anon），避免切号串缓存。
// - TTL 分 fresh / maxStale 两档；调用方可先拿 stale 立即渲染，再后台刷新。
// - 容量按 tieba_page_cache.byte_count 汇总，超出 32MB 时后台按 last_access_at
//   淘汰；淘汰不阻塞保存调用方。
import Foundation
#if DEBUG
import os
private let tiebaPageCacheLog = Logger(subsystem: "com.tiebalite.app", category: "page-cache")
#endif

enum TiebaPageCacheKind: String, Sendable {
  case feed
  case forum
  case thread
  case user

  /// 网络刷新后可直接信任的时间窗。
  var freshTTL: TimeInterval {
    switch self {
    case .feed: return 30 * 60
    case .forum: return 2 * 60
    case .thread: return 90
    case .user: return 10 * 60
    }
  }

  /// 网络失败/首屏 seed 时仍可展示的上限；超过即视为无缓存。
  var maxStale: TimeInterval {
    switch self {
    case .feed, .forum, .thread, .user: return 24 * 60 * 60
    }
  }
}

struct TiebaPageCacheScope: Hashable, Sendable {
  let kind: TiebaPageCacheKind
  let accountKey: String
  let pageKey: String

  var storageKey: String {
    "\(kind.rawValue)\u{1F}\(accountKey)\u{1F}\(pageKey)"
  }
}

struct TiebaPageCacheEntry: Sendable {
  let payload: Data
  let fetchedAt: Int64
  let expiresAt: Int64
  let lastAccessAt: Int64

  func isFresh(at milliseconds: Int64 = TiebaPageCache.nowMilliseconds()) -> Bool {
    milliseconds <= expiresAt
  }
}

final class TiebaPageCache: @unchecked Sendable {
  static let shared = TiebaPageCache()

  private static let maxBytes = 32 * 1024 * 1024
  private static let targetBytesAfterPrune = 28 * 1024 * 1024
  private static let pruneInterval: TimeInterval = 60

  private let seededScopes = TiebaMutex<Set<String>>([])
  private let revalidatingScopes = TiebaMutex<Set<String>>([])
  private let pruneState = TiebaMutex<(scheduled: Bool, lastPruneAt: TimeInterval)>((false, 0))

  private init() {
    // 首次访问本单例时做一次后台预算检查，用于覆盖“上次退出前已超预算、
    // 这次还没发生新写入”的场景。
    Task.detached(priority: .utility) { [weak self] in
      self?.pruneIfNeeded()
    }
  }

  static func nowMilliseconds() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1000)
  }

  static func currentAccountKey() -> String {
    let uid = TiebaBackgroundSnapshot.shared.uid.trimmingCharacters(in: .whitespacesAndNewlines)
    return uid.isEmpty ? "anon" : uid
  }

  static func scope(kind: TiebaPageCacheKind, pageKey: String) -> TiebaPageCacheScope {
    TiebaPageCacheScope(
      kind: kind,
      accountKey: currentAccountKey(),
      pageKey: pageKey
    )
  }

  /// 异步读/写回来时账号可能已切换；page cache 只能使用发起时同一账号的数据。
  static func isScopeCurrent(_ scope: TiebaPageCacheScope) -> Bool {
    currentAccountKey() == scope.accountKey
  }

  /// 只有传输层/服务端 5xx/响应损坏才回退旧缓存；取消与业务错误必须原样上抛，
  /// 不能让用户点了取消或登录过期后看到一份旧页面当成成功。
  static func shouldFallbackToCache(_ error: Error) -> Bool {
    if error is CancellationError { return false }
    if let error = error as? TiebaClientError {
      switch error {
      case .httpStatus(let status): return status >= 500
      case .invalidResponse: return true
      case .cancelled, .invalidUrl, .invalidMultipart, .disallowedHost: return false
      }
    }
    if let error = error as? TiebaForumAPIError {
      switch error {
      case .http(let status): return status >= 500
      case .invalidResponse: return true
      case .api, .invalidURL: return false
      }
    }
    if error is TiebaProtoError { return true }
    if let error = error as? URLError {
      switch error.code {
      case .timedOut, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet,
        .dnsLookupFailed, .cannotFindHost, .secureConnectionFailed, .dataNotAllowed,
        .internationalRoamingOff, .callIsActive:
        return true
      default:
        return false
      }
    }
    return false
  }

  /// 本进程内同一 scope 只允许一次“缓存优先”首读。之后同一页面的刷新/重进
  /// 直接走网络，避免下拉刷新被缓存挡住；新进程冷启动再按 seed 规则命中。
  func takeInitialSeed(scope: TiebaPageCacheScope) -> Bool {
    seededScopes.withLock { scopes in
      if scopes.count > 2048 {
        scopes.removeAll(keepingCapacity: true)
      }
      return scopes.insert(scope.storageKey).inserted
    }
  }

  /// 后台 revalidate 单飞：同一 scope 同一时刻只起一条刷新任务。
  func beginRevalidation(scope: TiebaPageCacheScope) -> Bool {
    revalidatingScopes.withLock { scopes in
      if scopes.count > 256 {
        scopes.removeAll(keepingCapacity: true)
      }
      return scopes.insert(scope.storageKey).inserted
    }
  }

  func endRevalidation(scope: TiebaPageCacheScope) {
    _ = revalidatingScopes.withLock { $0.remove(scope.storageKey) }
  }

  func load(
    scope: TiebaPageCacheScope,
    maxStale: TimeInterval,
    touch: Bool = true
  ) async -> TiebaPageCacheEntry? {
    guard TiebaDatabaseSchema.isCacheSchemaReady else { return nil }
    let started = DispatchTime.now().uptimeNanoseconds
    let entry = await Task.detached(priority: .userInitiated) {
      Self.readEntry(scope: scope, maxStale: maxStale, touch: touch)
    }.value
#if DEBUG
    let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
    tiebaPageCacheLog.debug(
      "page cache \(entry == nil ? "miss" : "hit", privacy: .public) kind=\(scope.kind.rawValue, privacy: .public) key=\(scope.pageKey, privacy: .public) ms=\(elapsedMs, privacy: .public)"
    )
#endif
    return entry
  }

  func store(
    scope: TiebaPageCacheScope,
    payload: Data,
    ttl: TimeInterval
  ) {
    guard TiebaDatabaseSchema.isCacheSchemaReady else { return }
    guard payload.isEmpty == false, payload.count <= Self.maxBytes else { return }
    let now = Self.nowMilliseconds()
    let expiresAt = now + Int64(max(ttl, 1) * 1000)
    let byteCount = payload.count + scope.storageKey.utf8.count + 64
    let params: [[String: Any]] = [
      ["v": scope.storageKey],
      ["v": scope.kind.rawValue],
      ["v": scope.accountKey],
      ["v": scope.pageKey],
      ["v": payload],
      ["v": now],
      ["v": expiresAt],
      ["v": now],
      ["v": byteCount],
    ]
    let sql = """
      INSERT INTO \(TiebaDatabaseSchema.pageCacheTable)
        (cache_key, kind, account_key, page_key, payload, fetched_at, expires_at, last_access_at, byte_count)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
      ON CONFLICT(cache_key) DO UPDATE SET
        kind = excluded.kind,
        account_key = excluded.account_key,
        page_key = excluded.page_key,
        payload = excluded.payload,
        fetched_at = excluded.fetched_at,
        expires_at = excluded.expires_at,
        last_access_at = excluded.last_access_at,
        byte_count = excluded.byte_count;
      """
    do {
      _ = try TiebaSQLite.shared.run(
        database: TiebaDatabaseSchema.mainDatabaseName,
        sql: sql,
        params: params
      )
      schedulePrune()
    } catch {
#if DEBUG
      tiebaPageCacheLog.error(
        "page cache write failed kind=\(scope.kind.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
#endif
    }
  }

  func storeInBackground(
    scope: TiebaPageCacheScope,
    payload: Data,
    ttl: TimeInterval
  ) {
    Task.detached(priority: .utility) { [weak self] in
      self?.store(scope: scope, payload: payload, ttl: ttl)
    }
  }

  func remove(scope: TiebaPageCacheScope) {
    guard TiebaDatabaseSchema.isCacheSchemaReady else { return }
    _ = try? TiebaSQLite.shared.run(
      database: TiebaDatabaseSchema.mainDatabaseName,
      sql: "DELETE FROM \(TiebaDatabaseSchema.pageCacheTable) WHERE cache_key = ?1;",
      params: [["v": scope.storageKey]]
    )
  }

  /// DEBUG 轻量指标：页面缓存反序列化在 detached task 完成后回填耗时。
  /// Release 版本函数体为空，不产生日志/I/O。
  static func debugDidDecode(kind: TiebaPageCacheKind, pageKey: String, started: UInt64) {
#if DEBUG
    let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
    tiebaPageCacheLog.debug(
      "page cache deserialize kind=\(kind.rawValue, privacy: .public) key=\(pageKey, privacy: .public) ms=\(elapsedMs, privacy: .public)"
    )
#endif
  }

  // MARK: - 单页读取 / LRU

  private static func readEntry(
    scope: TiebaPageCacheScope,
    maxStale: TimeInterval,
    touch: Bool
  ) -> TiebaPageCacheEntry? {
    let sql = """
      SELECT payload, fetched_at, expires_at, last_access_at
      FROM \(TiebaDatabaseSchema.pageCacheTable)
      WHERE cache_key = ?1
      LIMIT 1;
      """
    guard let row = try? TiebaSQLite.shared.queryFirst(
      database: TiebaDatabaseSchema.mainDatabaseName,
      sql: sql,
      params: [["v": scope.storageKey]]
    ),
      let payload = row["payload"] as? Data,
      let fetchedAt = int64(row["fetched_at"]),
      let expiresAt = int64(row["expires_at"]),
      let lastAccessAt = int64(row["last_access_at"])
    else { return nil }

    let now = nowMilliseconds()
    let age = now - fetchedAt
    // 允许 5 秒时钟回拨容差；超过 maxStale 直接当 miss，避免展示远古页面。
    guard age >= -5_000, age <= Int64(maxStale * 1000) else { return nil }
    // LRU touch 最多 60s 一次，避免每个命中都产生一条写事务。
    if touch, now - lastAccessAt > 60_000 {
      _ = try? TiebaSQLite.shared.run(
        database: TiebaDatabaseSchema.mainDatabaseName,
        sql: "UPDATE \(TiebaDatabaseSchema.pageCacheTable) SET last_access_at = ?1 WHERE cache_key = ?2;",
        params: [["v": now], ["v": scope.storageKey]]
      )
    }
    return TiebaPageCacheEntry(
      payload: payload,
      fetchedAt: fetchedAt,
      expiresAt: expiresAt,
      lastAccessAt: lastAccessAt
    )
  }

  private func schedulePrune() {
    let now = Date().timeIntervalSince1970
    let shouldSchedule = pruneState.withLock { state -> Bool in
      guard state.scheduled == false else { return false }
      guard now - state.lastPruneAt >= Self.pruneInterval else { return false }
      state.scheduled = true
      return true
    }
    guard shouldSchedule else { return }
    Task.detached(priority: .utility) { [weak self] in
      guard let self else { return }
      self.pruneIfNeeded()
      self.pruneState.withLock { state in
        state.scheduled = false
        state.lastPruneAt = Date().timeIntervalSince1970
      }
    }
  }

  private func pruneIfNeeded() {
    guard TiebaDatabaseSchema.isCacheSchemaReady else { return }
    let sumSQL = """
      SELECT COALESCE(SUM(byte_count), 0) AS total_bytes
      FROM \(TiebaDatabaseSchema.pageCacheTable);
      """
    guard let sumRow = try? TiebaSQLite.shared.queryFirst(
      database: TiebaDatabaseSchema.mainDatabaseName,
      sql: sumSQL,
      params: []
    ), let total = Self.int64(sumRow["total_bytes"]) else { return }
#if DEBUG
    if total <= Self.maxBytes {
      tiebaPageCacheLog.debug("page cache db_bytes=\(total, privacy: .public)")
      return
    }
#else
    guard total > Self.maxBytes else { return }
#endif

    // 用窗口函数按 LRU 序累计 byte_count，一次删除最老的一段直到回到目标预算。
    // 删除在后台执行；命中路径永远只走主键点查。
    let bytesToRemove = max(total - Int64(Self.targetBytesAfterPrune), 0)
    let pruneSQL = """
      WITH oldest AS (
        SELECT cache_key, byte_count,
               SUM(byte_count) OVER (ORDER BY last_access_at ASC, cache_key ASC) AS cumulative_bytes
        FROM \(TiebaDatabaseSchema.pageCacheTable)
      )
      DELETE FROM \(TiebaDatabaseSchema.pageCacheTable)
      WHERE cache_key IN (
        SELECT cache_key FROM oldest WHERE cumulative_bytes - byte_count < ?1
      );
      """
    _ = try? TiebaSQLite.shared.run(
      database: TiebaDatabaseSchema.mainDatabaseName,
      sql: pruneSQL,
      params: [["v": bytesToRemove]]
    )
#if DEBUG
    let after = (try? TiebaSQLite.shared.queryFirst(
      database: TiebaDatabaseSchema.mainDatabaseName,
      sql: sumSQL,
      params: []
    ))?["total_bytes"].flatMap(Self.int64) ?? 0
    tiebaPageCacheLog.debug(
      "page cache pruned before_bytes=\(total, privacy: .public) after_bytes=\(after, privacy: .public)"
    )
#endif
  }

  private static func int64(_ value: Any?) -> Int64? {
    if let value = value as? Int64 { return value }
    if let value = value as? Int { return Int64(value) }
    if let value = value as? Double { return Int64(value) }
    if let value = value as? NSNumber { return value.int64Value }
    return nil
  }
}
