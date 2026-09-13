// ============================================================
// TiebaSQLite —— 系统 libsqlite3 的异步查询门面（替代 expo-sqlite）
//
// 存储裁决：**不新增存储路径**。全 App 只有一个库文件
// $(Documents)/SQLite/tiebalite.db（与 TiebaKvStore 同一个绝对路径）：
//   - kv 表（偏好/账号元数据/屏蔽列表）由 TiebaKvStore 走它自己的连接同步读写；
//   - search_history / visit_history（关系型查询）由本文件走第二条连接。
// 这两张关系表的 schema 由本文件自愈（建连接时 CREATE IF NOT EXISTS + 旧表
// 缺列 ALTER，与迁移前 unifiedDb.createSchemaAsync 同形），不依赖 JS 迁移动过库。
// 两条连接到同一个文件，与迁移前（TiebaKvStore + expo-sqlite）的连接数完全一致
// ——没有第三个存储系统、没有第二个文件。第三方扩展没有共享句柄的入口
//（TiebaKvStore.database 是 private，本文件不越权改它），故沿用"多连接到同库"的
// 既有形态，靠三件事避免打脸（与 TiebaKvStore 文件头 a/b/c 同款）：
//   a. 打开即设 busy_timeout：短事务撞锁时等待而不是立刻 SQLITE_BUSY；
//   b. 各自 best-effort 打开 WAL（任一连接成功即对库文件生效）；
//   c. 本文件所有写都是短事务（显式事务只在 withTransaction 期间持有）。
//
// 为什么需要这层门面：unifiedDb.ts 的 getDbAsync() 被 searchHistory.ts /
// visitHistory.ts 当 expo SQLiteDatabase 用（runAsync / getAllAsync /
// getFirstAsync / execAsync / withTransactionAsync）。这里把同名同签名的
// 方法在原生实现，那两个消费方零改动——SQL 文本、参数顺序、事务边界全部照旧。
//
// SQLite 原语逐条对齐 expo-sqlite 的可观察行为：
//   - 参数绑定：text 用 SQLITE_TRANSIENT（Swift C 串生命周期只到语句执行完）、
//     整数值的 number 绑 int64（日期毫秒），非整数绑 double，null/缺失绑 NULL；
//   - 列值：text → String、integer/real → Double（JS 里都是 number）、null →
//     NSNull；blob 本仓零消费（历史/偏好全是文本与数字），返回 NSNull；
//   - 事务：BEGIN IMMEDIATE（与 TiebaKvStore 一致，立刻拿写锁排队），
//     commit/rollback 由 JS 的 withTransaction 驱动；嵌套靠深度计数收敛；
//   - execAsync：多语句串行执行、丢弃结果行（PRAGMA journal_mode=WAL 这类
//     语句也是靠它执行的）。
//
// 线程：全部入口是 1.0 AsyncFunction（整段在 expo.modules.AsyncFunctionQueue
// 上跑，不占 JS 线程），连接由一把 NSLock 串行化语句执行；SQLite 自身是
// serialized 线程模式（FULLMUTEX）。
// ============================================================
import Foundation
import SQLite3

enum TiebaSQLiteError: LocalizedError {
  case databaseUnavailable(String)
  case statementFailed(String)

  var errorDescription: String? {
    switch self {
    case .databaseUnavailable(let detail):
      return "SQLite database unavailable: \(detail)"
    case .statementFailed(let detail):
      return "SQLite statement failed: \(detail)"
    }
  }
}

/// 连接 + 事务深度。句柄只在本类型的锁内使用。
private final class TiebaSQLiteConnection {
  let handle: OpaquePointer
  var transactionDepth = 0

  init(handle: OpaquePointer) {
    self.handle = handle
  }
}

// ============================================================
// 共享 SQLite 原语（TiebaSQLite 与 TiebaKvStore 各自手写了一份 → 收敛到这里）
//
// 两条连接打开的是同一个库文件（见文件头），开库参数/open 失败收尾/bind/列读取
// /错误文案必须逐字一致，否则同一故障在两条路径上表现不同。调用方仍各自持有
// NSLock 串行化自己连接上的语句执行。
// ============================================================
enum TiebaSQLiteCoreError: LocalizedError {
  case open(String)

  var detail: String {
    switch self {
    case .open(let detail): return detail
    }
  }

  var errorDescription: String? { detail }
}

enum TiebaSQLiteCore {
  /// SQLITE_TRANSIENT：让 SQLite 复制绑定值（Swift 侧临时 C 串不能传 STATIC）。
  /// nonisolated(unsafe)：函数指针类型的静态常量，只读、无并发风险。
  nonisolated(unsafe) static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

  /// 打开一条连接：建目录 + open_v2(FULLMUTEX) + busy_timeout(1s)。
  /// 失败时关闭半开句柄并抛错误（详情给调用方包成各自门面的错误类型）。
  static func open(path: String) throws -> OpaquePointer {
    try FileManager.default.createDirectory(
      at: URL(fileURLWithPath: path).deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    var handle: OpaquePointer?
    let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
      let detail = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
      if let handle { sqlite3_close_v2(handle) }
      throw TiebaSQLiteCoreError.open(detail)
    }
    // 与另一条连接撞锁时等待而不是立刻失败；上限 1s：极端情况下对方的同步
    // 事务可能正占着 JS 线程，等太久等于把 UI 卡住。
    sqlite3_busy_timeout(handle, 1000)
    return handle
  }

  static func errorMessage(_ db: OpaquePointer) -> String {
    String(cString: sqlite3_errmsg(db))
  }

  /// prepare 一条语句；失败返回 nil（错误详情用 errorMessage 取）。
  static func prepare(_ db: OpaquePointer, _ sql: String) -> OpaquePointer? {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
    return statement
  }

  /// 单语句执行（prepare → bind → step(DONE)）；失败返回错误描述，成功 nil。
  static func execute(
    _ db: OpaquePointer,
    _ sql: String,
    bind: (OpaquePointer) -> Void
  ) -> String? {
    guard let statement = prepare(db, sql) else { return errorMessage(db) }
    defer { sqlite3_finalize(statement) }
    bind(statement)
    guard sqlite3_step(statement) == SQLITE_DONE else { return errorMessage(db) }
    return nil
  }

  static func bind(_ statement: OpaquePointer, _ index: Int32, _ value: String) {
    sqlite3_bind_text(statement, index, value, -1, transient)
  }

  static func bind(_ statement: OpaquePointer, _ index: Int32, _ value: Int) {
    sqlite3_bind_int64(statement, index, Int64(value))
  }

  /// NULL → nil；用 column_bytes 而不是 cString，避免值里出现 NUL 时被截断。
  static func columnString(_ statement: OpaquePointer, _ index: Int32) -> String? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL,
          let bytes = sqlite3_column_text(statement, index) else { return nil }
    let count = Int(sqlite3_column_bytes(statement, index))
    return String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
  }
}

/// 同步查询门面。@unchecked Sendable：全部可变状态（连接表）归 `lock` 保护，
/// 与 TiebaKvStore 同款"手动串行化"声明。
final class TiebaSQLite: @unchecked Sendable {
  static let shared = TiebaSQLite()

  /// 库目录/默认库名与 TiebaKvStore 逐字一致（同一个文件）。
  private static let databaseDirectory = "SQLite"
  static let mainDatabase = "tiebalite.db"

  /// 关系型表 schema，与迁移前 unifiedDb.createSchemaAsync 的 visit_history /
  /// search_history 两段逐字一致。老版本设备上的 tiebalite.db 可能只有 kv 表
  ///（JS 建表没跑过 / 库被重建），所以每次建连接都补一次，查表不再 no such table。
  private static let relationalSchema = """
    CREATE TABLE IF NOT EXISTS search_history (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      forum_id TEXT NOT NULL DEFAULT '',
      keyword TEXT NOT NULL,
      timestamp INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_search_history_scope_time
      ON search_history(forum_id, timestamp DESC, id DESC);
    CREATE TABLE IF NOT EXISTS visit_history (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      type TEXT NOT NULL,
      thread_id TEXT NOT NULL DEFAULT '',
      forum_id TEXT NOT NULL DEFAULT '',
      forum_name TEXT NOT NULL DEFAULT '',
      avatar TEXT NOT NULL DEFAULT '',
      title TEXT NOT NULL DEFAULT '',
      author_name TEXT NOT NULL DEFAULT '',
      author_portrait TEXT NOT NULL DEFAULT '',
      timestamp INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_visit_history_type_time
      ON visit_history(type, timestamp DESC, id DESC);
    """

  private let lock = NSLock()
  private var connections: [String: TiebaSQLiteConnection] = [:]

  private init() {}

  private var databaseDirectoryURL: URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent(Self.databaseDirectory, isDirectory: true)
  }

  private func databaseURL(named name: String) -> URL {
    databaseDirectoryURL.appendingPathComponent(name)
  }

  /// 库文件是否存在（遗留库迁移用：不存在的库不该被"打开即创建"造出来）。
  func databaseExists(named name: String) -> Bool {
    FileManager.default.fileExists(atPath: databaseURL(named: name).path)
  }

  // MARK: - 对外查询 API

  func exec(database: String, sql: String) throws {
    try lock.withLock {
      let connection = try openLocked(database)
      try execLocked(connection.handle, sql: sql)
    }
  }

  func run(database: String, sql: String, params: [[String: Any]]) throws -> (lastInsertRowId: Int64, changes: Int) {
    try lock.withLock {
      let connection = try openLocked(database)
      let statement = try prepareLocked(connection.handle, sql: sql)
      defer { sqlite3_finalize(statement) }
      bindLocked(statement, params: params)
      guard sqlite3_step(statement) == SQLITE_DONE else {
        throw TiebaSQLiteError.statementFailed(Self.errorMessage(connection.handle))
      }
      return (sqlite3_last_insert_rowid(connection.handle), Int(sqlite3_changes(connection.handle)))
    }
  }

  func query(database: String, sql: String, params: [[String: Any]]) throws -> [[String: Any]] {
    try lock.withLock {
      let connection = try openLocked(database)
      let statement = try prepareLocked(connection.handle, sql: sql)
      defer { sqlite3_finalize(statement) }
      bindLocked(statement, params: params)
      var rows: [[String: Any]] = []
      while true {
        let step = sqlite3_step(statement)
        if step == SQLITE_ROW {
          rows.append(Self.rowDictionary(statement))
        } else if step == SQLITE_DONE {
          return rows
        } else {
          throw TiebaSQLiteError.statementFailed(Self.errorMessage(connection.handle))
        }
      }
    }
  }

  func queryFirst(database: String, sql: String, params: [[String: Any]]) throws -> [String: Any]? {
    try lock.withLock {
      let connection = try openLocked(database)
      let statement = try prepareLocked(connection.handle, sql: sql)
      defer { sqlite3_finalize(statement) }
      bindLocked(statement, params: params)
      let step = sqlite3_step(statement)
      if step == SQLITE_ROW {
        return Self.rowDictionary(statement)
      }
      if step == SQLITE_DONE {
        return nil
      }
      throw TiebaSQLiteError.statementFailed(Self.errorMessage(connection.handle))
    }
  }

  // MARK: - 事务（JS 的 withTransactionAsync 驱动）

  func begin(database: String) throws {
    try lock.withLock {
      let connection = try openLocked(database)
      if connection.transactionDepth == 0 {
        try execLocked(connection.handle, sql: "BEGIN IMMEDIATE;")
      } else {
        // 嵌套：SQLite 没有嵌套事务，深度计数让内层退化成"参与外层事务"
        //（expo-sqlite 的 withTransactionAsync 也是这个语义）。
        try execLocked(connection.handle, sql: "SAVEPOINT tieba_nested;")
      }
      connection.transactionDepth += 1
    }
  }

  func commit(database: String) throws {
    try lock.withLock {
      guard let connection = connections[database], connection.transactionDepth > 0 else { return }
      connection.transactionDepth -= 1
      if connection.transactionDepth == 0 {
        try execLocked(connection.handle, sql: "COMMIT;")
      } else {
        try execLocked(connection.handle, sql: "RELEASE tieba_nested;")
      }
    }
  }

  func rollback(database: String) throws {
    try lock.withLock {
      guard let connection = connections[database], connection.transactionDepth > 0 else { return }
      connection.transactionDepth = 0
      // ROLLBACK 自己失败没有恢复手段（事务已不可信），原始错误照抛。
      try execLocked(connection.handle, sql: "ROLLBACK;")
    }
  }

  /// 关闭连接（遗留库迁移读完就关，回收句柄）。
  func close(database: String) {
    lock.withLock {
      guard let connection = connections.removeValue(forKey: database) else { return }
      sqlite3_close_v2(connection.handle)
    }
  }

  /// 删除库文件（含 -wal/-shm）。legacy 迁移把旧库并进统一库后调用。
  func deleteDatabase(named name: String) throws {
    try lock.withLock {
      if let connection = connections.removeValue(forKey: name) {
        sqlite3_close_v2(connection.handle)
      }
      let base = databaseURL(named: name)
      for suffix in ["", "-wal", "-shm"] {
        let url = URL(fileURLWithPath: base.path + suffix)
        if FileManager.default.fileExists(atPath: url.path) {
          try FileManager.default.removeItem(at: url)
        }
      }
    }
  }

  // MARK: - 打开 / 建连接

  private func openLocked(_ database: String) throws -> TiebaSQLiteConnection {
    if let connection = connections[database] { return connection }
    let handle: OpaquePointer
    do {
      handle = try TiebaSQLiteCore.open(path: databaseURL(named: database).path)
    } catch let error as TiebaSQLiteCoreError {
      throw TiebaSQLiteError.databaseUnavailable(error.detail)
    }
    let connection = TiebaSQLiteConnection(handle: handle)
    // WAL：两条连接读写同库时读不阻塞写。单条 PRAGMA，失败不阻断
    //（回滚日志模式下靠 busy_timeout 也能跑）——与 TiebaKvStore 同款。
    try? execLocked(handle, sql: "PRAGMA journal_mode = WAL;")
    // 统一库自愈：缺表建表（老库只有 kv）、旧表缺列补列。失败不注册连接，
    // 下次调用重试而不是拿一条 schema 不完整的连接继续跑查询。
    if database == Self.mainDatabase {
      do {
        try ensureRelationalSchemaLocked(handle)
      } catch {
        sqlite3_close_v2(handle)
        throw error
      }
    }
    connections[database] = connection
    return connection
  }

  /// 旧库缺失列补齐（ALTER 只加不删；NOT NULL 必须带默认值 SQLite 才收）。
  /// 覆盖 v1 起全部业务列：老 unified 库只差 author_portrait，更老的库可能差更多。
  private static let visitHistoryColumns: [(name: String, definition: String)] = [
    ("type", "TEXT NOT NULL DEFAULT ''"),
    ("thread_id", "TEXT NOT NULL DEFAULT ''"),
    ("forum_id", "TEXT NOT NULL DEFAULT ''"),
    ("forum_name", "TEXT NOT NULL DEFAULT ''"),
    ("avatar", "TEXT NOT NULL DEFAULT ''"),
    ("title", "TEXT NOT NULL DEFAULT ''"),
    ("author_name", "TEXT NOT NULL DEFAULT ''"),
    ("author_portrait", "TEXT NOT NULL DEFAULT ''"),
    ("timestamp", "INTEGER NOT NULL DEFAULT 0"),
  ]

  /// 建表/补列（幂等）。表名/列名全部来自本文件常量，无注入面。
  private func ensureRelationalSchemaLocked(_ db: OpaquePointer) throws {
    try execLocked(db, sql: Self.relationalSchema)
    let columns = Set(try columnNamesLocked(db, table: "visit_history"))
    for column in Self.visitHistoryColumns where !columns.contains(column.name) {
      try execLocked(
        db,
        sql: "ALTER TABLE visit_history ADD COLUMN \(column.name) \(column.definition);"
      )
    }
  }

  /// PRAGMA table_info 的列名（表名只来自本文件常量，无注入面）。
  private func columnNamesLocked(_ db: OpaquePointer, table: String) throws -> [String] {
    let statement = try prepareLocked(db, sql: "PRAGMA table_info(\(table));")
    defer { sqlite3_finalize(statement) }
    var names: [String] = []
    while true {
      let step = sqlite3_step(statement)
      if step == SQLITE_ROW {
        if let bytes = sqlite3_column_text(statement, 1) {
          let count = Int(sqlite3_column_bytes(statement, 1))
          names.append(String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self))
        }
      } else if step == SQLITE_DONE {
        return names
      } else {
        throw TiebaSQLiteError.statementFailed(Self.errorMessage(db))
      }
    }
  }

  // MARK: - SQLite 原语（调用方须已持有 lock）

  private func prepareLocked(_ db: OpaquePointer, sql: String) throws -> OpaquePointer {
    guard let statement = TiebaSQLiteCore.prepare(db, sql) else {
      throw TiebaSQLiteError.statementFailed(Self.errorMessage(db))
    }
    return statement
  }

  /// 多语句串行执行（execAsync 语义：分号切分的整段脚本，丢弃结果行）。
  /// withCString 保证游标指向的缓冲区在整个循环期间有效（sqlite3_prepare_v2
  /// 会把游标推到下一条语句，不能用临时的 NSString.utf8String）。
  private func execLocked(_ db: OpaquePointer, sql: String) throws {
    try sql.withCString { cString in
      var cursor: UnsafePointer<CChar>? = cString
      while let current = cursor, current.pointee != 0 {
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(db, current, -1, &statement, &cursor)
        guard status == SQLITE_OK else {
          if let statement { sqlite3_finalize(statement) }
          throw TiebaSQLiteError.statementFailed(Self.errorMessage(db))
        }
        guard let statement else { continue }  // 空语句/注释：游标已前移
        defer { sqlite3_finalize(statement) }
        let step = sqlite3_step(statement)
        guard step == SQLITE_DONE || step == SQLITE_ROW else {
          throw TiebaSQLiteError.statementFailed(Self.errorMessage(db))
        }
      }
    }
  }

  private func bindLocked(_ statement: OpaquePointer, params: [[String: Any]]) {
    for (offset, param) in params.enumerated() {
      let index = Int32(offset + 1)
      guard let raw = param["v"], !(raw is NSNull) else {
        sqlite3_bind_null(statement, index)
        continue
      }
      if let text = raw as? String {
        TiebaSQLiteCore.bind(statement, index, text)
      } else if let number = raw as? NSNumber {
        // JS 里所有数字都是 Double；整数值（时间戳毫秒）绑 int64，其余绑 double，
        // 与列亲和性配合得到与 expo-sqlite 相同的落盘类型。
        let value = number.doubleValue
        if value.rounded() == value, abs(value) < 9_007_199_254_740_992 {
          sqlite3_bind_int64(statement, index, Int64(value))
        } else {
          sqlite3_bind_double(statement, index, value)
        }
      } else {
        sqlite3_bind_null(statement, index)
      }
    }
  }

  /// 一行 → 字典（列名 → String / Double / NSNull）。
  private static func rowDictionary(_ statement: OpaquePointer) -> [String: Any] {
    var row: [String: Any] = [:]
    for index in 0..<sqlite3_column_count(statement) {
      guard let namePointer = sqlite3_column_name(statement, index) else { continue }
      let name = String(cString: namePointer)
      switch sqlite3_column_type(statement, index) {
      case SQLITE_INTEGER, SQLITE_FLOAT:
        row[name] = sqlite3_column_double(statement, index)
      case SQLITE_TEXT:
        // column_bytes 而不是 cString：值里出现 NUL 时不被截断（core 内同款）。
        row[name] = TiebaSQLiteCore.columnString(statement, index) ?? NSNull()
      default:
        // BLOB / NULL：本仓无 blob 列，统一给 NSNull（null 语义）。
        row[name] = NSNull()
      }
    }
    return row
  }

  private static func errorMessage(_ db: OpaquePointer) -> String {
    TiebaSQLiteCore.errorMessage(db)
  }
}
