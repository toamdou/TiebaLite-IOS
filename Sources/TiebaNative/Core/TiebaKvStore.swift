// ============================================================
// TiebaKvStore —— 同步键值存储（替代 react-native-mmkv，顺带拔掉 nitro-modules）
//
// 2026-09-12：react-native-mmkv v4 是 App 内最后一个 nitro-modules 消费者
// （包清单见 review-reports/nitro-usage-eval-2026-08-26.md），整包删除后 KV 层
// 由本文件接管。JS 门面签名不变（src/services/storage/unifiedDb.ts 的
// kvGetSync / kvSetSync / kvRemoveSync / kvBatchSync / getAllKeysSync /
// clearAllKvSync），偏好、账号元数据、屏蔽列表、各类磁盘缓存等消费方零改动。
//
// 为什么落回统一 SQLite（tiebalite.db）的 kv 表，而不是 UserDefaults / 新开库：
// 1. 全 App 只留一个存储系统。kv 表本来就是这套键值层的家：2026-08-25 有过一次
//    「SQLite kv 表 → MMKV」的搬运（unifiedDb.ts 的 drainSqliteKvTableIntoMmkv…），
//    现在把方向反过来就行——表结构 / 迁移标记 / clear 语义全部沿用，不新增数据槽；
// 2. UserDefaults/plist 是第二个并行存储（无事务、无跨进程一致语义，还要再写一份
//    导入导出与清理逻辑），与「收敛到单一存储」的目标相悖；
// 3. 库文件与 JS 侧 expo-sqlite 打开的是同一个（$(Documents)/SQLite/tiebalite.db）：
//    search_history / visit_history 仍在同一库里，kv 只是其中一张表——不引入第二个
//    文件、第二套备份/清理路径。
//
// ⚠️ 因此本文件与 expo-sqlite 各持一条到同一文件的连接，靠三件事避免互相打脸：
//   a. 打开即设 busy_timeout：短事务撞锁时等待，而不是直接 SQLITE_BUSY 失败；
//   b. 双方各自 best-effort 打开 WAL（读不阻塞写；任一连接成功即对库文件生效）；
//   c. 本文件所有写都是单条语句的短事务（批量走一个显式事务），不长时间持锁。
//
// 数据迁移（旧 MMKV 文件 → kv 表；一次性、幂等、非破坏）：
//   旧数据在 $(Documents)/mmkv/tiebalite.kv（+ .crc）。MMKV 代码删除后没人能读它，
//   所以这里按 MMKVCore 2.4.0 的落盘格式自带一个只读解析器（见 LegacyMmkvFile）：
//   主文件头 4 字节后是数据区，数据区是 protobuf 风格 varint 长度前缀的 key/value
//   串（值是 UTF-8 文本，长度 0 = 墓碑即删除），完整性用 .crc 里的 CRC32(zlib)
//   校验，校验不过按 MMKV::checkDataValid 的顺序退回 lastConfirmed 快照。
//   导入只在标记键 @tiebalite:mmkv_import_v1 不存在时跑一次，逐条按文件顺序 apply
//   （后写覆盖先写，与 MMKV 内存字典的语义一致），数据与标记同事务提交。
//   ⚠️ 旧文件一个字节都不删（回滚快照，与 kv 表当年被留作回滚快照同理）；标记
//   还负责防「清空复活」——kvClear 全清时强制保留它（见 clear）。
//   ⚠️ 解析失败（文件损坏/格式不符）**不写标记**：宁可下次启动再试，也不把
//   「没导成功」记成「已导入」，否则用户的账号/偏好就永久丢了。
//
// ⚠️ 导入在后台执行（2026-09-13 起）：首帧不再被「开库 + 建表 + 全量解码」
//   阻塞。标记命中 / 旧文件不存在仍是同步快路径；确需全量解码时置
//   legacyImportState = .running，后台完成 upsert。为不改变语义：
//   - 写（set/remove/batchWrite/clear）在导入完成前排队等待——否则导入会按文件
//     顺序把窗口内刚写的新值覆盖回旧值（旧实现靠"导入先于一切写"避免）；
//   - lookup() 在导入未完成/失败时对缺失键报 .unavailable 而非 .missing，
//     防止把"还没导进来"当成"确证为空"（purgeOrphanedSession 据此会删凭据）。
//
// 并发：SQLite 系统库是 serialized 线程模式，这里再用一把 NSLock 串行化
// 「同一条连接上的语句执行」。@JS 同步成员在 JS 线程被调用，读是主键索引点查
// （微秒级），不需要 MMKV 那样的 mmap 常驻。
// ============================================================
import Foundation
import SQLite3
import Dispatch
import os

/// 跨桥错误：@JS throws 成员的 errorDescription 会成为 JS 侧 Error.message
/// （与 TiebaCookieError 同义，1.0 Function 的抛出也走同一条路）。
enum TiebaKvError: LocalizedError {
  case databaseUnavailable(String)
  case statementFailed(String)
  case invalidBatchEntry

  var errorDescription: String? {
    switch self {
    case .databaseUnavailable(let detail):
      return "KV store unavailable: \(detail)"
    case .statementFailed(let detail):
      return "KV statement failed: \(detail)"
    case .invalidBatchEntry:
      return "kvBatchWrite entries must be { key: string, value: string | null }"
    }
  }
}

/// 读结果三态（112）：missing 才是「确证不存在/为空」，unavailable 表示读不出来
/// ——库不可用、打开粘滞失败、旧 MMKV 导入还没完成/失败（缺失键未必真缺失）。
/// get() 沿用 nil 合并两态；需要区分的地方（清理、账号列表重写）用 lookup()。
enum TiebaKvReadResult {
  case value(String)
  case missing
  case unavailable(String)
}

/// 同步 KV。实例被 JS 桥线程（@JS 同步成员）长期共享，故 @unchecked Sendable：
/// 全部可变状态是 SQLite 连接句柄、失败标记与导入状态，都归 `lock` 保护；
/// 其余存储属性是初始化后不变的 let。@unchecked 是如实的「手动串行化」声明。
final class TiebaKvStore: @unchecked Sendable {
  static let shared = TiebaKvStore()

  /// 库文件：与 unifiedDb.ts 的 DB_NAME 一致。expo-sqlite 把相对库名解析到
  /// $(Documents)/SQLite/<name>（见其 pathUtils.createDatabasePath +
  /// defaultDatabaseDirectory），本文件必须落在同一个绝对路径上。
  private static let databaseDirectory = "SQLite"
  private static let databaseName = "tiebalite.db"

  /// 旧 MMKV 实例：createMMKV({ id: 'tiebalite.kv' })。react-native-mmkv 的
  /// HybridMMKVPlatformContext 在 Documents 下拼 "mmkv"，文件名就是 mmapID。
  private static let legacyMmkvDirectory = "mmkv"
  private static let legacyMmkvID = "tiebalite.kv"

  /// 一次性导入标记（存 kv 表自身）。内部记账键：JS 不感知，kvClear 全清时
  /// 强制保留——否则清空数据后下次启动会把旧 MMKV 文件重新灌回来（清空复活）。
  static let legacyImportFlagKey = "@tiebalite:mmkv_import_v1"

  /// 孤儿登录态清理标记（Keychain 凭据存活但沙盒被清空的卸载重装场景）：
  /// 与导入标记同理，属"一次性迁移标记"，清数据时同样必须保留。
  static let orphanPurgeFlagKey = "@tiebalite:orphan_purge_v1"

  /// 任何"全清/重置"都必须保留的内部标记键：删掉它们会让一次性迁移重新执行
  /// （旧 MMKV 复活、或重跑孤儿登录态清理）。
  static let internalMarkerKeys: [String] = [legacyImportFlagKey, orphanPurgeFlagKey]

  /// 关键事件日志（导入结果/降级警告；低频，不刷屏）。
  private static let log = Logger(subsystem: "com.tiebalite.app", category: "kv")

  private let lock = NSLock()
  private var database: OpaquePointer?
  /// 打开失败的描述：命中后本进程不再重试（避免每次 kv 调用都撞一次磁盘错误），
  /// 但也不吞——写操作会把它抛给 JS。
  private var openFailure: String?

  /// 旧 MMKV 导入状态（见文件头）。idle → running → done / failed 单向流转；
  /// failed 本进程不重试（下次启动再来），但 lookup 会如实报 unavailable。
  private enum LegacyImportState {
    case idle
    case running
    case done
    case failed
  }

  private var legacyImportState = LegacyImportState.idle
  /// 后台导入完成信号：写操作在 running 期间 wait（等导入落库后再写，避免旧值
  /// 覆盖新写）。DispatchGroup 用后即空，后续 wait 立即返回。
  private let legacyImportGate = DispatchGroup()

  private init() {}

  // MARK: - 对外 API（全部同步；调用方在锁内收敛）

  /// 读一个键。不存在 → nil；库不可用/语句失败也 → nil。
  /// 读不抛错是刻意的：kv 读遍布启动链路（clientId / uid / 账号列表 / 偏好），
  /// 一次磁盘级故障不该把无关流程一起打断；写路径才抛错（写失败必须被看见）。
  func get(key: String) -> String? {
    lock.withLock {
      guard let db = openLocked() else { return nil }
      return queryStringLocked(db, key: key)
    }
  }

  /// 读一个键并区分「确证没有」与「读不出来」（112）。会做破坏性决策的调用方
  /// （孤儿会话清理、账号列表重写）必须用它，不能拿 get() == nil 当空。
  func lookup(key: String) -> TiebaKvReadResult {
    lock.withLock {
      guard let db = openLocked() else {
        return .unavailable(openFailure ?? "database unavailable")
      }
      if let value = queryStringLocked(db, key: key) { return .value(value) }
      switch legacyImportState {
      case .running:
        return .unavailable("legacy mmkv import in progress")
      case .failed:
        return .unavailable("legacy mmkv import failed")
      case .idle, .done:
        return .missing
      }
    }
  }

  /// 写一个键（upsert）。失败抛错。
  func set(key: String, value: String) throws {
    lock.lock()
    defer { lock.unlock() }
    let db = try openOrThrowLocked()
    waitForLegacyImportLocked()
    try upsertLocked(db, key: key, value: value)
  }

  /// 删一个键。删不存在的键是 no-op（与 MMKV remove 一致）。失败抛错。
  func remove(key: String) throws {
    lock.lock()
    defer { lock.unlock() }
    let db = try openOrThrowLocked()
    waitForLegacyImportLocked()
    try deleteLocked(db, key: key)
  }

  /// 全部键（含内部标记键，与 MMKV getAllKeys 同形）。前缀过滤/排序留在 JS
  /// 门面（getAllKeysSync 的 .filter(...).sort()），这里只管取全量。
  /// 库不可用 → 空数组（读语义，同上）。
  func allKeys() -> [String] {
    lock.withLock {
      guard let db = openLocked() else { return [] }
      return keysLocked(db, sql: "SELECT key FROM kv;", bind: { _ in })
    }
  }

  /// 前缀键（屏蔽列表这类逐项键的读取）：走 substr 比较而不是全表取回再
  /// Swift 侧 hasPrefix 过滤（116）。库不可用/导入未完成 → 空数组。
  func keys(prefix: String) -> [String] {
    lock.withLock {
      guard let db = openLocked() else { return [] }
      return keysLocked(db, sql: "SELECT key FROM kv WHERE substr(key, 1, ?1) = ?2;") { statement in
        // substr 第三参按 Unicode 码点算，与 prefix.unicodeScalars.count 对齐。
        TiebaSQLiteCore.bind(statement, 1, prefix.unicodeScalars.count)
        TiebaSQLiteCore.bind(statement, 2, prefix)
      }
    }
  }

  /// 批量写（旧 kvBatchSync 的语义：value == nil = 删除）。整批一个事务：
  /// 半途失败回滚整批，不会出现「前几条生效、后几条丢失」。
  func batchWrite(_ writes: [(key: String, value: String?)]) throws {
    lock.lock()
    defer { lock.unlock() }
    let db = try openOrThrowLocked()
    waitForLegacyImportLocked()
    try inTransactionLocked(db) {
      for write in writes {
        if let value = write.value {
          try self.upsertLocked(db, key: write.key, value: value)
        } else {
          try self.deleteLocked(db, key: write.key)
        }
      }
    }
  }

  /// 清理。prefix == nil = 全清；否则只删该前缀的键。
  /// preserveKeys 之外，内部标记键（旧 MMKV 导入标记、孤儿登录态清理标记）
  /// **永远**保留：全清后又
  /// 从旧文件把数据灌回来是明确的 bug（unifiedDb.ts 的旧注释叫「清空复活」）。
  /// 失败抛错（这是用户显式动作，不能假装成功）。
  func clear(prefix: String?, preserveKeys: [String]) throws {
    lock.lock()
    defer { lock.unlock() }
    let db = try openOrThrowLocked()
    // 等待导入完成再清：否则后台导入会把清掉的数据又写回来（清空复活）。
    waitForLegacyImportLocked()
    // 去重 + 过滤空串：key NOT IN 列表里有重复不影响语义，但绑定参数少一点好。
    var preserved = Set(preserveKeys.filter { !$0.isEmpty })
    preserved.formUnion(Self.internalMarkerKeys)
    // sorted()：占位符编号按这个顺序生成，绑定必须同序（Set 本身无序）。
    let preservedKeys = preserved.sorted()

    var sql = "DELETE FROM kv WHERE key NOT IN (\(preservedKeys.indices.map { "?\($0 + 1)" }.joined(separator: ", ")))"
    if prefix != nil {
      sql += " AND substr(key, 1, ?\(preservedKeys.count + 1)) = ?\(preservedKeys.count + 2)"
    }
    guard let statement = TiebaSQLiteCore.prepare(db, sql) else {
      throw TiebaKvError.statementFailed(TiebaSQLiteCore.errorMessage(db))
    }
    defer { sqlite3_finalize(statement) }
    for (offset, key) in preservedKeys.enumerated() {
      TiebaSQLiteCore.bind(statement, Int32(offset + 1), key)
    }
    if let prefix {
      // substr 的第三参是「字符数」：SQLite 对 TEXT 按 Unicode 码点算，
      // 与 Swift 的 unicodeScalars.count 对齐（grapheme count 对组合字符会少算）。
      TiebaSQLiteCore.bind(statement, Int32(preservedKeys.count + 1), prefix.unicodeScalars.count)
      TiebaSQLiteCore.bind(statement, Int32(preservedKeys.count + 2), prefix)
    }
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw TiebaKvError.statementFailed(TiebaSQLiteCore.errorMessage(db))
    }
  }

  /// 旧 MMKV 文件 → kv 表（一次性、幂等、非破坏）。首次 kv 访问时自动排入后台
  /// 导入；显式调用会等待完成再返回，便于验证迁移结果（重复调用只是查一次标记）。
  /// 返回 true = 已完成（含「旧文件本来就不存在」）。
  @discardableResult
  func importLegacyMmkvIfNeeded() -> Bool {
    lock.lock()
    guard openLocked() != nil else {
      lock.unlock()
      return false
    }
    if legacyImportState == .running {
      lock.unlock()
      legacyImportGate.wait()
      lock.lock()
    }
    let done = legacyImportState == .done
    lock.unlock()
    return done
  }

  // MARK: - 打开 / 建表 / WAL / 导入调度

  private var documentsURL: URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
  }

  private var databaseURL: URL {
    documentsURL
      .appendingPathComponent(Self.databaseDirectory, isDirectory: true)
      .appendingPathComponent(Self.databaseName)
  }

  private var legacyMmkvURL: URL {
    documentsURL
      .appendingPathComponent(Self.legacyMmkvDirectory, isDirectory: true)
      .appendingPathComponent(Self.legacyMmkvID)
  }

  /// 懒打开（首次调用发生在 JS 线程，@JS 同步成员）。返回 nil = 库不可用，
  /// 原因记在 openFailure / 日志里。建表/导入失败也走 catch：连接必须关掉并把
  /// database 复原，否则下次调用会拿一条半初始化的句柄继续用。
  private func openLocked() -> OpaquePointer? {
    if let database { return database }
    if openFailure != nil { return nil }
    do {
      let handle = try TiebaSQLiteCore.open(path: databaseURL.path)
      database = handle
      // 表结构与 unifiedDb.ts 的 createSchemaAsync 逐字一致（同一张表，两边
      // 谁先建都得到同一形状；列/约束不同会在这里暴露成 SQL 错误而不是静默分歧）。
      if let failure = TiebaSQLiteCore.execute(handle, """
        CREATE TABLE IF NOT EXISTS kv (
          key TEXT PRIMARY KEY NOT NULL,
          value TEXT NOT NULL
        );
        """, bind: { _ in }) {
        throw TiebaKvError.statementFailed(failure)
      }
      enableWALLocked(handle)
      scheduleLegacyImportLocked(handle)
      return handle
    } catch {
      if let handle = database {
        sqlite3_close_v2(handle)
        database = nil
      }
      let detail = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
      Self.log.error("kv open failed: \(detail, privacy: .public)")
      openFailure = detail
      return nil
    }
  }

  private func openOrThrowLocked() throws -> OpaquePointer {
    guard let db = openLocked() else {
      throw TiebaKvError.databaseUnavailable(openFailure ?? "unknown")
    }
    return db
  }

  /// WAL：两条连接读写同一库时读不阻塞写。单条 PRAGMA，失败只记日志——
  /// 回滚日志模式下靠 busy_timeout 也能跑，只是写-写撞车时表现为等待。
  private func enableWALLocked(_ db: OpaquePointer) {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, "PRAGMA journal_mode = WAL;", -1, &statement, nil) == SQLITE_OK,
          let statement else { return }
    defer { sqlite3_finalize(statement) }
    if sqlite3_step(statement) == SQLITE_ROW {
      let mode = TiebaSQLiteCore.columnString(statement, 0) ?? "unknown"
      if mode.lowercased() != "wal" {
        Self.log.notice("journal_mode=\(mode, privacy: .public) (WAL 未生效，并发写可能等待)")
      }
    }
  }

  /// 首次导入调度（见文件头）：标记命中 / 旧文件不存在是同步快路径，全量解码
  /// 排后台。调用方须已持有 lock。
  private func scheduleLegacyImportLocked(_ db: OpaquePointer) {
    guard legacyImportState == .idle else { return }
    // 稳态零成本：标记命中就结束（一次主键点查）。
    if queryStringLocked(db, key: Self.legacyImportFlagKey) != nil {
      legacyImportState = .done
      return
    }
    guard FileManager.default.fileExists(atPath: legacyMmkvURL.path) else {
      // 全新安装（没有旧文件）：直接落标记，免得每次启动都 stat。
      writeImportFlagLocked(db, count: 0, note: "no-legacy-file")
      legacyImportState = .done
      return
    }
    legacyImportState = .running
    legacyImportGate.enter()
    let mainFile = legacyMmkvURL
    let metaFile = URL(fileURLWithPath: mainFile.path + ".crc")
    Task.detached(priority: .utility) { [weak self] in
      guard let self else { return }
      // 解码（读盘 + CRC32）在锁外做；只有 upsert 事务持锁。
      let entries = LegacyMmkvFile.decode(mainFile: mainFile, metaFile: metaFile)
      self.lock.withLock {
        if let entries {
          if let failure = self.applyLegacyEntriesLocked(entries) {
            // 事务已回滚（数据与标记都没落），保持旧文件原样，下次启动重试。
            self.legacyImportState = .failed
            Self.log.error("legacy mmkv import failed, rolled back: \(failure, privacy: .public)")
          } else {
            Self.log.notice("imported \(entries.count, privacy: .public) legacy mmkv entries into kv table")
            self.legacyImportState = .done
          }
        } else {
          // ⚠️ 解析失败不写标记：下次启动再试，绝不把「没导成功」记成「已导入」。
          Self.log.error("legacy mmkv decode failed; keeping files and retrying on next launch")
          self.legacyImportState = .failed
        }
      }
      self.legacyImportGate.leave()
    }
  }

  /// 顺序敏感：MMKV 是 append-only 日志，同一个键可能先写后删（或反过来），
  /// 按文件顺序 apply 才与它的内存字典一致（后写覆盖先写）。调用方须已持 lock。
  /// 返回 nil = 成功；否则为回滚后的错误描述。
  private func applyLegacyEntriesLocked(_ entries: [(key: String, value: String?)]) -> String? {
    guard let db = database else { return "database closed before import" }
    do {
      try inTransactionLocked(db) {
        for entry in entries {
          if let value = entry.value {
            try self.upsertLocked(db, key: entry.key, value: value)
          } else {
            try self.deleteLocked(db, key: entry.key)
          }
        }
        self.writeImportFlagLocked(db, count: entries.count, note: nil)
      }
      return nil
    } catch {
      return (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
  }

  /// 标记与数据同事务写入：要么「数据 + 已导入」一起可见，要么都不可见。
  private func writeImportFlagLocked(_ db: OpaquePointer, count: Int, note: String?) {
    let timestamp = Int(Date().timeIntervalSince1970 * 1000)
    let noteSuffix = note.map { ",\"note\":\"\($0)\"" } ?? ""
    let value = "{\"migratedAt\":\(timestamp),\"count\":\(count)\(noteSuffix)}"
    do {
      try upsertLocked(db, key: Self.legacyImportFlagKey, value: value)
    } catch {
      // 标记写失败不是致命：下次启动导入会重跑，而 upsert/墓碑的语义保证
      // 重跑是幂等的（同值覆盖、删除重复执行结果相同）。
      Self.log.error("failed to persist legacy import flag")
    }
  }

  /// 导入未完成时写操作必须等待（见文件头）。调用方须已持 lock；等待期间
  /// 释放锁让后台导入跑完（DispatchGroup 一旦清空，后续 wait 立即返回）。
  private func waitForLegacyImportLocked() {
    while legacyImportState == .running {
      lock.unlock()
      legacyImportGate.wait()
      lock.lock()
    }
  }

  // MARK: - SQLite 原语（调用方须已持有 lock）

  private func queryStringLocked(_ db: OpaquePointer, key: String) -> String? {
    guard let statement = TiebaSQLiteCore.prepare(db, "SELECT value FROM kv WHERE key = ?1;") else {
      return nil
    }
    defer { sqlite3_finalize(statement) }
    TiebaSQLiteCore.bind(statement, 1, key)
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    return TiebaSQLiteCore.columnString(statement, 0)
  }

  private func keysLocked(
    _ db: OpaquePointer,
    sql: String,
    bind: (OpaquePointer) -> Void
  ) -> [String] {
    guard let statement = TiebaSQLiteCore.prepare(db, sql) else { return [] }
    defer { sqlite3_finalize(statement) }
    bind(statement)
    var keys: [String] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      if let key = TiebaSQLiteCore.columnString(statement, 0) { keys.append(key) }
    }
    return keys
  }

  private func upsertLocked(_ db: OpaquePointer, key: String, value: String) throws {
    let failure = TiebaSQLiteCore.execute(
      db,
      "INSERT OR REPLACE INTO kv (key, value) VALUES (?1, ?2);",
      bind: { statement in
        TiebaSQLiteCore.bind(statement, 1, key)
        TiebaSQLiteCore.bind(statement, 2, value)
      }
    )
    if let failure { throw TiebaKvError.statementFailed(failure) }
  }

  private func deleteLocked(_ db: OpaquePointer, key: String) throws {
    let failure = TiebaSQLiteCore.execute(
      db,
      "DELETE FROM kv WHERE key = ?1;",
      bind: { statement in TiebaSQLiteCore.bind(statement, 1, key) }
    )
    if let failure { throw TiebaKvError.statementFailed(failure) }
  }

  /// BEGIN IMMEDIATE：立刻拿写锁（与 expo-sqlite 的写事务排队而不是等 COMMIT
  /// 时才失败），失败回滚后把原始错误抛出去。
  private func inTransactionLocked(_ db: OpaquePointer, _ work: () throws -> Void) throws {
    if let failure = TiebaSQLiteCore.execute(db, "BEGIN IMMEDIATE;", bind: { _ in }) {
      throw TiebaKvError.statementFailed(failure)
    }
    do {
      try work()
      if let failure = TiebaSQLiteCore.execute(db, "COMMIT;", bind: { _ in }) {
        throw TiebaKvError.statementFailed(failure)
      }
    } catch {
      _ = TiebaSQLiteCore.execute(db, "ROLLBACK;", bind: { _ in })
      throw error
    }
  }
}

// ============================================================
// MMKV 落盘格式的只读解析（MMKVCore 2.4.0）
//
// 依据（删包前从 ios/Pods/MMKVCore/Core 逐行核对，非猜测）：
//   - MMKV_IO.cpp readActualSize/loadFromFile：数据区 = 主文件偏移 Fixed32Size(=4)
//     起、长度 = 元信息 actualSize（version >= MMKVVersionActualSize(3)；更老
//     的文件长度写在主文件头 4 字节）；
//   - MMKVMetaInfo.hpp / MMKVMetaInfo::write：.crc 文件就是 MMKVMetaInfo 的
//     memcpy 落盘：crc(0) version(4) sequence(8) iv(12..27) actualSize(28)
//     lastActualSize(32) lastCRCDigest(36)；
//   - MiniPBCoder::writeRootObject/decodeOneMap + CodedInputData：数据区 =
//     varint(容器字节数) 后跟若干「varint(keyLen) keyBytes varint(valueLen)
//     valueBytes」，valueLen == 0 是墓碑（删除）；循环读到数据区结束；
//   - MMKV::checkFileCRCValid：CRC32(zlib, 初始 0) 覆盖数据区。
// ============================================================
private enum LegacyMmkvFile {
  /// 主文件数据区偏移（MMKV.h 的 Fixed32Size / MMKVPredef.h pbFixed32Size）。
  static let dataOffset = 4
  /// .crc（MMKVMetaInfo）里的字段偏移。
  static let metaCRCOffset = 0
  static let metaVersionOffset = 4
  static let metaActualSizeOffset = 28
  static let metaLastActualSizeOffset = 32
  static let metaLastCRCOffset = 36
  /// version >= 3 时 actualSize 才在元信息里（MMKVVersionActualSize）。
  static let versionWithMetaActualSize: UInt32 = 3
  /// 版本号上限防御：未来格式变了就宁可判失败，也不按旧布局瞎读。
  static let versionSaneLimit: UInt32 = 64

  /// 返回 nil = 无法可信解码（文件缺失/损坏/CRC 全不匹配）。调用方据此
  /// 不写导入标记。解码成功时返回顺序敏感的 entry 序列（value == nil 为墓碑）。
  static func decode(mainFile: URL, metaFile: URL) -> [(key: String, value: String?)]? {
    guard let meta = try? Data(contentsOf: metaFile), meta.count >= metaLastCRCOffset + 4,
          let main = try? Data(contentsOf: mainFile), main.count > dataOffset else { return nil }

    let version = readUInt32(meta, metaVersionOffset)
    guard version <= versionSaneLimit else { return nil }

    // 空库是合法状态（写过又全删、或从未写过）：没有条目可导，返回空序列
    // （导入方落标记）。不能当损坏——否则空库设备每次启动都重试一遍。
    // 判定与 MMKV::readActualSize 一致：v3+ 看元信息，更老的看主文件头。
    if version >= versionWithMetaActualSize {
      if readUInt32(meta, metaActualSizeOffset) == 0 { return [] }
    } else if readUInt32(main, 0) == 0 {
      return []
    }

    // 候选数据长度按 MMKV checkDataValid 的顺序：
    //   1. 元信息 actualSize（正常路径）；
    //   2. 主文件头的老式长度（降级后再升级的库）；
    //   3. lastConfirmed 快照（上次写盘中途崩溃的恢复位置）。
    var candidates: [(size: Int, crc: UInt32)] = []
    if version >= versionWithMetaActualSize {
      candidates.append((Int(readUInt32(meta, metaActualSizeOffset)), readUInt32(meta, metaCRCOffset)))
      candidates.append((Int(readUInt32(main, 0)), readUInt32(meta, metaCRCOffset)))
      candidates.append(
        (Int(readUInt32(meta, metaLastActualSizeOffset)), readUInt32(meta, metaLastCRCOffset))
      )
    } else {
      candidates.append((Int(readUInt32(main, 0)), readUInt32(meta, metaCRCOffset)))
    }

    for candidate in candidates {
      let size = candidate.size
      guard size > 0, size + dataOffset <= main.count else { continue }
      guard crc32(main, offset: dataOffset, length: size) == candidate.crc else { continue }
      return decodePayload(main, offset: dataOffset, length: size)
    }
    return nil
  }

  /// 数据区 → 有序 entry 序列。格式不符返回 nil（宁可整体失败，不导入半截）。
  static func decodePayload(_ data: Data, offset: Int, length: Int) -> [(key: String, value: String?)]? {
    var reader = VarintReader(bytes: [UInt8](data[offset..<(offset + length)]))
    // 顶层容器头：MiniPBCoder 写容器的子项总字节数，decodeOneMap 在 position=0
    // 时先 readInt32() 跳过它。
    guard reader.readVarint32() != nil else { return nil }

    var entries: [(key: String, value: String?)] = []
    while reader.remaining > 0 {
      guard let keyLength = reader.readVarint32(), keyLength > 0, keyLength <= reader.remaining,
            let keyBytes = reader.readBytes(keyLength),
            let valueLength = reader.readVarint32(), valueLength >= 0, valueLength <= reader.remaining,
            let valueBytes = reader.readBytes(valueLength) else { return nil }
      let key = String(decoding: keyBytes, as: UTF8.self)
      // 长度 0 = 墓碑：键被删过，导入时要同样从目标表删掉（不是「跳过」）。
      let value = valueLength == 0 ? nil : String(decoding: valueBytes, as: UTF8.self)
      entries.append((key, value))
    }
    return entries
  }

  static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
    UInt32(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) })
  }

  // MARK: CRC32（zlib 算法：反射多项式 0xEDB88320，init/xorout 全 1）

  private static let crc32Table: [UInt32] = {
    var table = [UInt32](repeating: 0, count: 256)
    for index in 0..<256 {
      var value = UInt32(index)
      for _ in 0..<8 {
        value = (value & 1) != 0 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
      }
      table[index] = value
    }
    return table
  }()

  static func crc32(_ data: Data, offset: Int, length: Int) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
      guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
      for index in offset..<(offset + length) {
        crc = (crc >> 8) ^ crc32Table[Int((crc ^ UInt32(base[index])) & 0xFF)]
      }
    }
    return crc ^ 0xFFFF_FFFF
  }

  /// protobuf 风格 varint（CodedInputData::readRawVarint32 同款）。
  private struct VarintReader {
    let bytes: [UInt8]
    private var index = 0

    init(bytes: [UInt8]) {
      self.bytes = bytes
    }

    var remaining: Int { bytes.count - index }

    mutating func readVarint32() -> Int? {
      var result: UInt32 = 0
      var shift: UInt32 = 0
      for _ in 0..<5 {
        guard index < bytes.count else { return nil }
        let byte = bytes[index]
        index += 1
        result |= UInt32(byte & 0x7F) << shift
        if byte & 0x80 == 0 {
          // 长度/计数不该超过 Int32 正区间；越界按坏数据拒绝。
          return result <= UInt32(Int32.max) ? Int(result) : nil
        }
        shift += 7
      }
      return nil
    }

    mutating func readBytes(_ count: Int) -> [UInt8]? {
      guard count >= 0, count <= remaining else { return nil }
      let slice = Array(bytes[index..<(index + count)])
      index += count
      return slice
    }
  }
}
