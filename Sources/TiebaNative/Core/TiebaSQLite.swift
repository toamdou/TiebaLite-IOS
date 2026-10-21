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
import Foundation
import SQLite3
import os

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

/// 绑定参数（真 Sendable 值）。`[[String: Any]]` 在**进锁前**翻译成它：
/// 锁内只出现值类型——这条设计早于 TiebaMutex shim（当时用标准库 Mutex，闭包结果要求
/// sending，捕获非 Sendable 的 Any 字典会被 region-isolation 拒绝；`-typecheck` 看不到
/// 这类诊断）。shim 只放宽约束，不改这个更安全的写法。
private enum SQLiteBindValue: Sendable {
  case null
  case text(String)
  case integer(Int64)
  case double(Double)
  case blob(Data)

  /// 与旧 bindLocked 逐行等价：缺 "v" / NSNull / 既非 String 又非 NSNumber → NULL。
  /// 参数顺序 = 数组顺序（下标即绑定位置）。
  static func from(_ raw: Any?) -> SQLiteBindValue {
    guard let raw, !(raw is NSNull) else { return .null }
    if let data = raw as? Data { return .blob(data) }
    if let text = raw as? String { return .text(text) }
    if let number = raw as? NSNumber {
      // JS 里所有数字都是 Double；整数值（时间戳毫秒）绑 int64，其余绑 double，
      // 与列亲和性配合得到与 expo-sqlite 相同的落盘类型。
      let value = number.doubleValue
      if value.rounded() == value, abs(value) < 9_007_199_254_740_992 {
        return .integer(Int64(value))
      }
      return .double(value)
    }
    return .null
  }
}

/// 列值（真 Sendable 值）。同上：锁内只产生它，出了锁再装箱成 `Any`。
private enum SQLiteColumnValue: Sendable {
  case null
  case text(String)
  case real(Double)
  case blob(Data)

  var anyValue: Any {
    switch self {
    case .null: return NSNull()
    case .text(let value): return value
    case .real(let value): return value
    case .blob(let value): return value
    }
  }
}

// 共享 SQLite 原语（TiebaSQLite 与 TiebaKvStore 各自手写了一份 → 收敛到这里）
//
// 两条连接打开的是同一个库文件（见文件头）：open 失败收尾 / bind / 列读取 /
// 错误文案共用这一份实现。开库 PRAGMA 分成两组，由 open(path:profile:) **一处**
// 给出——两组参数刻意不同（用途不同，见 Profile 的注释），但来源只有一个，
// 不会出现"改了一条忘另一条"导致同一故障在两条路径上表现不同。
// 调用方仍各自持有锁串行化自己连接上的语句执行。
enum TiebaSQLiteCoreError: LocalizedError {
  /// `systemErrno` 取自失败的句柄（`sqlite3_system_errno`，**关句柄之前**读）。
  /// 打开阀门要用它区分「删库能修」与「删库也没用」—— 见 `TiebaSQLiteOpenValve`。
  case open(detail: String, systemErrno: Int32)

  var detail: String {
    switch self {
    case .open(let detail, _): return detail
    }
  }

  var systemErrno: Int32 {
    switch self {
    case .open(_, let systemErrno): return systemErrno
    }
  }

  var errorDescription: String? { detail }
}

/// 打开失败的「计数阀门」。
///
/// 问题：一次打不开 ≠ 库坏了。锁屏数据保护、瞬时锁竞争、句柄耗尽都会让
/// `sqlite3_open_v2` 失败，而旧实现把 `openFailure` 记成永久状态（`openFailure != nil`
/// 之后整进程直接返回 nil），于是「屏幕锁着的那一瞬间碰了一次 KV」会让偏好与账号
/// 元数据**整个进程不可用**。
///
/// 修法（对齐上游 `SqliteValueBox` 的三段式）：
///   ① **按 errno 过滤**：删库也修不好的错误（权限、句柄/内存/磁盘耗尽、被信号打断）
///      不计数 —— 计数只该记「文件本身可能坏了」这一类；
///   ② **连续失败计数落盘**（`<db>-open-failures`，原子写）：跨进程也生效，
///      一次成功打开即清零；
///   ③ 达到阈值才**删库重建**，并且删主库时必须连 `-wal` / `-shm` 一起删
///      —— 只删主库会让新连接配上旧 WAL 索引。
///
/// 所有权：只有库的 owner（`TiebaKvStore`）可以调 `recordFailureAndShouldWipe` /
/// `removeDatabaseFiles`。非 owner 连接（`TiebaSQLite` 的迁移/历史表）只把 errno
/// 往上抛，不碰文件。
enum TiebaSQLiteOpenValve {
  /// 连续失败到这个数才判定「库真坏了」。
  static let wipeThreshold = 3

  private static func markerPath(_ dbPath: String) -> String {
    dbPath + "-open-failures"
  }

  /// 删文件修不了的 errno 不计数。与上游 `shouldCountOpenFailure` 同一张表。
  static func shouldCount(systemErrno: Int32) -> Bool {
    switch systemErrno {
    case EPERM, EACCES, EMFILE, ENFILE, ENOMEM, ENOSPC, EAGAIN, EINTR:
      return false
    default:
      // 0 = 拿不到 errno（SQLite 自己的错误，不是系统调用失败）→ 计。
      return true
    }
  }

  static func consecutiveFailures(_ dbPath: String) -> Int {
    guard let text = try? String(contentsOfFile: markerPath(dbPath), encoding: .utf8) else {
      return 0
    }
    return Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
  }

  /// 一次成功即清零。
  static func clear(_ dbPath: String) {
    try? FileManager.default.removeItem(atPath: markerPath(dbPath))
  }

  /// 记一次失败，并回答「是否该重建」。**只允许 owner 调用。**
  static func recordFailureAndShouldWipe(_ dbPath: String, systemErrno: Int32) -> Bool {
    guard shouldCount(systemErrno: systemErrno) else { return false }
    let failures = consecutiveFailures(dbPath) + 1
    try? Data(String(failures).utf8).write(
      to: URL(fileURLWithPath: markerPath(dbPath)),
      options: .atomic
    )
    return failures >= wipeThreshold
  }

  /// 主库必须与 `-wal` / `-shm` / 计数文件一起删。
  static func removeDatabaseFiles(_ dbPath: String) {
    for suffix in ["", "-wal", "-shm", "-open-failures"] {
      try? FileManager.default.removeItem(atPath: dbPath + suffix)
    }
  }
}

enum TiebaSQLiteCore {
  /// 开库档位。两条连接打开同一个库文件，但用途不同，PRAGMA 组因此不同；
  /// 具体语句集中在 open 里的 applyPragmas，调用方只选档位、不写 PRAGMA。
  enum Profile {
    /// 同步 KV（TiebaKvStore）。在 JS 线程被同步调用、只跑单条语句的短事务，
    /// 存的多是偏好/账号元数据/可重建的缓存 —— 所以 `synchronous=NORMAL`
    /// （WAL 的标准搭配）：app 崩溃仍一致，只有掉电可能丢最后一笔提交，
    /// 省掉每次 COMMIT 的 fsync。这与"JS 线程上等 fsync"的代价直接相关。
    case keyValueStore
    /// 关系表连接（search_history / visit_history）与迁移连接。历史记录是用户
    /// 可见且删了就没了的数据，schema 变更更不能半途而废 —— 所以**不降档**，
    /// 保持 SQLite 默认的 `synchronous=FULL`，宁可每次提交多一次 fsync。
    /// 这两类写入都不在 JS 线程的同步热路径上（关系表走 AsyncFunction 队列，
    /// 迁移在 utility 队列），多一次 fsync 不会卡 UI。
    case relational
  }

  /// SQLITE_TRANSIENT：让 SQLite 复制绑定值（Swift 侧临时 C 串不能传 STATIC）。
  /// 用函数而不是 static let 常量：@convention(c) 函数指针不是 Sendable，
  /// 存成全局量要 nonisolated(unsafe) 才能过编译；每次现算一个常量字面量既没有
  /// 共享状态，也不需要任何绕过（编译器会折叠成同一个值）。
  static func transient() -> sqlite3_destructor_type {
    unsafeBitCast(-1, to: sqlite3_destructor_type.self)
  }

  /// 打开一条连接：建目录 + open_v2(FULLMUTEX) + busy_timeout(1s) + 该档位的
  /// PRAGMA 组。失败时关闭半开句柄并抛错误（详情给调用方包成各自门面的错误类型）。
  ///
  /// 不含 `journal_mode = WAL`：它是库文件级属性、切换时要拿库文件锁，
  /// 由各调用方在自己的初始化流程里设（TiebaKvStore.enableWALLocked /
  /// TiebaSQLite.openLocked），时机跟着各自的建表/导入顺序走。这里不设，
  /// 也不塞进任何事务——事务里切 journal_mode 会直接失败。
  static func open(path: String, profile: Profile) throws -> OpaquePointer {
    try FileManager.default.createDirectory(
      at: URL(fileURLWithPath: path).deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    var handle: OpaquePointer?
    let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
      let detail = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
      // errno 必须在关句柄**之前**读：`sqlite3_system_errno` 读的是句柄上记的
      // 最近一次系统调用错误，`sqlite3_close_v2` 之后句柄失效、读到的是垃圾。
      let systemErrno = handle.map { sqlite3_system_errno($0) } ?? 0
      if let handle { sqlite3_close_v2(handle) }
      throw TiebaSQLiteCoreError.open(detail: detail, systemErrno: systemErrno)
    }
    // 与另一条连接撞锁时等待而不是立刻失败；上限 1s：极端情况下对方的同步
    // 事务可能正占着 JS 线程，等太久等于把 UI 卡住。
    sqlite3_busy_timeout(handle, 1000)
    applyPragmas(handle, profile: profile)
    // schema 升级不在 open 热路径同步执行：新 IPA 覆盖安装后先让 UI/登录态 KV
    // 原样打开旧库，迁移由 TiebaDatabaseSchema.startBackgroundMigration() 在
    // utility 队列完成。缓存表在迁移完成前自动 miss，登录/关注列表不受阻塞。
    // 已升级过的库只做一次 PRAGMA user_version 点查，让二级启动立刻可用缓存。
    if URL(fileURLWithPath: path).lastPathComponent == TiebaDatabaseSchema.mainDatabaseName {
      TiebaDatabaseSchema.markCacheSchemaReadyIfCurrent(handle: handle)
    }
    return handle
  }

  /// 开库 PRAGMA 组（两条连接唯一的来源）。
  ///
  /// 全部 best-effort：PRAGMA 失败不该让连接不可用（回滚日志模式下靠
  /// busy_timeout 也能跑），与改动前一致。
  private static func applyPragmas(_ db: OpaquePointer, profile: Profile) {
    switch profile {
    case .keyValueStore:
      // 唯一降档的地方。理由见 Profile.keyValueStore：KV 在 JS 线程同步调用，
      // 每次 COMMIT 都 fsync 会直接变成掉帧。
      _ = executeScript(db, "PRAGMA synchronous = NORMAL;")
    case .relational:
      // 刻意不写 synchronous：保持 SQLite 默认（FULL）。写一行 FULL 只是把
      // 默认值抄一遍，反而会在未来默认值变化时造成"以为显式声明过"的误解。
      break
    }
    // 临时表与排序中间结果放内存：这两条连接的临时数据都很小，落盘只多一次
    // I/O，还会把临时文件写进备份/清理要扫的目录。
    _ = executeScript(db, "PRAGMA temp_store = MEMORY;")
    switch profile {
    case .keyValueStore:
      // 页缓存按 KiB 显式给出（负数 = KiB）。默认值随 SQLite 编译选项漂移，
      // 写死让"KV 常驻多少内存"可预期：KV 是点查为主的热路径，给 8 MiB。
      _ = executeScript(db, "PRAGMA cache_size = -8000;")
    case .relational:
      // 关系表查询是范围扫（history 列表），2 MiB（SQLite 的默认值）够用；
      // 与 KV 同库同进程，总内存要留出余量。
      _ = executeScript(db, "PRAGMA cache_size = -2000;")
    }
    // 关掉 mmap：同一个文件上两条连接若映射档位不同，页的可见性就依赖各自的
    // 映射状态，出现"另一条连接刚提交的数据本连接读不到"这类难复现的问题；
    // 另外 mmap 页在 iOS 上算进进程内存且不受 cache_size 约束，被系统回收时
    // 也无法按缓存逐出。全关 = 两条连接走同一套 read() 路径。
    _ = executeScript(db, "PRAGMA mmap_size = 0;")
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
    sqlite3_bind_text(statement, index, value, -1, transient())
  }

  static func bind(_ statement: OpaquePointer, _ index: Int32, _ value: Int) {
    sqlite3_bind_int64(statement, index, Int64(value))
  }

  /// 多语句脚本执行（sqlite3_exec）。返回 nil 表示成功，否则是 SQLite 错误文本。
  /// 迁移与 schema bootstrap 使用；SQL 均来自本文件静态常量或整数版本号拼接。
  static func executeScript(_ db: OpaquePointer, _ sql: String) -> String? {
    var errorPointer: UnsafeMutablePointer<CChar>?
    let status = sqlite3_exec(db, sql, nil, nil, &errorPointer)
    if status == SQLITE_OK { return nil }
    let detail = errorPointer.map { String(cString: $0) } ?? errorMessage(db)
    if let errorPointer { sqlite3_free(errorPointer) }
    return detail
  }

  /// NULL → nil；用 column_bytes 而不是 cString，避免值里出现 NUL 时被截断。
  static func columnString(_ statement: OpaquePointer, _ index: Int32) -> String? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL,
          let bytes = sqlite3_column_text(statement, index) else { return nil }
    let count = Int(sqlite3_column_bytes(statement, index))
    return String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
  }
}

enum TiebaDatabaseMigrationError: LocalizedError {
  case unknownVersion(Int)
  case failed(version: Int, detail: String)

  var errorDescription: String? {
    switch self {
    case .unknownVersion(let version):
      return "Unknown database schema migration version: \(version)"
    case .failed(let version, let detail):
      return "Database migration v\(version) failed: \(detail)"
    }
  }
}

/// 统一 SQLite schema 版本与迁移注册表。
///
/// 规则：
/// - PRAGMA user_version 是唯一版本号，所有连接（KV / 关系表 / 页面缓存）共享；
/// - 迁移只能追加、必须幂等；新版本只允许在事务成功后才推进 user_version；
/// - 首次从旧版本升级前用 sqlite3_backup 做一致性备份（WAL 中的已提交页也包含）；
/// - 备份失败不阻断纯 append-only DDL，但会记录 error；迁移失败则 ROLLBACK 并抛错，
///   旧表/旧数据保持原样，下次启动重试。
enum TiebaDatabaseSchema {
  static let currentVersion = 3
  static let mainDatabaseName = TiebaSQLite.mainDatabase
  static let pageCacheTable = "tieba_page_cache"
  static let forumAvatarTable = "tieba_forum_avatar_cache"

  private static let migrationGate = TiebaMutex<Bool>(false)
  private static let migrationLaunchGate = TiebaMutex<Bool>(false)
  /// 新缓存表可用性：迁移完成前所有 page cache/avatar table 调用直接 miss。
  /// 登录态 KV/关注缓存走旧表，不需要等这个标记，所以升级不会挡住首屏内容。
  private static let cacheSchemaReady = TiebaMutex<Bool>(false)
  private static let log = Logger(subsystem: "com.tiebalite.app", category: "sqlite-migration")

  static var isCacheSchemaReady: Bool {
    cacheSchemaReady.withLock { $0 }
  }

  /// 已是最新版本时无需等后台迁移；open 路径只付一次 PRAGMA 点查。
  static func markCacheSchemaReadyIfCurrent(handle db: OpaquePointer) {
    guard let version = try? userVersion(db), version >= currentVersion else { return }
    cacheSchemaReady.withLock { $0 = true }
  }

  private static var mainDatabasePath: String {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("SQLite", isDirectory: true)
      .appendingPathComponent(mainDatabaseName)
      .path
  }

  /// 覆盖安装后的数据库升级入口：调用即返回，迁移在 utility 队列执行。
  /// 不把迁移放进 open()，避免首个 KV 读（登录态/关注列表）被 DDL/备份阻塞。
  static func startBackgroundMigration() {
    let shouldStart = migrationLaunchGate.withLock { started -> Bool in
      guard started == false else { return false }
      started = true
      return true
    }
    guard shouldStart else { return }
    Task.detached(priority: .utility) {
      let path = mainDatabasePath
      // 重试上限仍是 3 次；间隔指数退避（250ms 起、翻倍、封顶 8s）并加 ±20% 抖动。
      // 抖动不是装饰：KV 连接与这条迁移连接打的是同一个库文件，固定间隔会让
      // "撞锁 → 同时重试 → 再次撞锁"变成共振，退避+抖动把两次尝试错开。
      // 取消检查放在每轮开头；sleep 用 `try await` 让 CancellationError 正常
      // 传播（以前是 `try?`，连取消一起吞掉，任务被取消后还会继续睡、继续开库）。
      var attempt = 0
      var delayMilliseconds = 250.0
      while attempt < 3 {
        if Task.isCancelled { return }
        do {
          // 迁移连接与关系表连接同档（耐久优先）：它要写 schema 与 user_version，
          // 不值得为省 fsync 冒"改了一半"的风险；也不在 JS 同步热路径上。
          let handle = try TiebaSQLiteCore.open(path: path, profile: .relational)
          defer { sqlite3_close_v2(handle) }
          sqlite3_busy_timeout(handle, 3000)
          _ = TiebaSQLiteCore.executeScript(handle, "PRAGMA journal_mode = WAL;")
          try migrateIfNeeded(handle: handle, path: path)
          cacheSchemaReady.withLock { $0 = true }
          log.notice("database schema ready at v\(currentVersion, privacy: .public)")
          return
        } catch {
          attempt += 1
          if attempt >= 3 {
            log.error("background schema migration failed after retries: \(error.localizedDescription, privacy: .public)")
            return
          }
          let jittered = delayMilliseconds * Double.random(in: 0.8...1.2)
          try await Task.sleep(for: .milliseconds(jittered))
          delayMilliseconds = min(delayMilliseconds * 2, 8000)
        }
      }
    }
  }

  static let visitHistoryColumns: [(name: String, definition: String)] = [
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

  static func migrateIfNeeded(handle db: OpaquePointer, path: String) throws {
    try migrationGate.withLock { _ in
      let fromVersion = try userVersion(db)
      guard fromVersion < currentVersion else { return }
      if try hasUserTables(db) {
        do {
          try backupBeforeMigration(db: db, path: path, fromVersion: fromVersion)
        } catch {
          log.error("database backup before migration failed: \(error.localizedDescription, privacy: .public)")
        }
      }

      if let failure = TiebaSQLiteCore.executeScript(db, "BEGIN IMMEDIATE;") {
        throw TiebaDatabaseMigrationError.failed(version: fromVersion, detail: failure)
      }
      var version = fromVersion
      do {
        while version < currentVersion {
          let next = version + 1
          try applyMigration(version: next, db: db)
          if let failure = TiebaSQLiteCore.executeScript(db, "PRAGMA user_version = \(next);") {
            throw TiebaDatabaseMigrationError.failed(version: next, detail: failure)
          }
          version = next
        }
        if let failure = TiebaSQLiteCore.executeScript(db, "COMMIT;") {
          throw TiebaDatabaseMigrationError.failed(version: currentVersion, detail: failure)
        }
        log.notice("database migrated from v\(fromVersion, privacy: .public) to v\(currentVersion, privacy: .public)")
      } catch {
        _ = TiebaSQLiteCore.executeScript(db, "ROLLBACK;")
        if let migrationError = error as? TiebaDatabaseMigrationError {
          throw migrationError
        }
        throw TiebaDatabaseMigrationError.failed(
          version: version + 1,
          detail: error.localizedDescription
        )
      }
    }
  }

  private static func applyMigration(version: Int, db: OpaquePointer) throws {
    switch version {
    case 1:
      try migrateBaseline(db)
    case 2:
      try migratePageCache(db)
    case 3:
      try migrateForumAvatarCache(db)
    default:
      throw TiebaDatabaseMigrationError.unknownVersion(version)
    }
  }

  private static func migrateBaseline(_ db: OpaquePointer) throws {
    let sql = """
      CREATE TABLE IF NOT EXISTS kv (
        key TEXT PRIMARY KEY NOT NULL,
        value TEXT NOT NULL
      );
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
    try execute(db, sql, version: 1)
    try ensureColumns(db, table: "visit_history", columns: visitHistoryColumns, version: 1)
  }

  private static func migratePageCache(_ db: OpaquePointer) throws {
    let sql = """
      CREATE TABLE IF NOT EXISTS \(pageCacheTable) (
        cache_key TEXT PRIMARY KEY NOT NULL,
        kind TEXT NOT NULL,
        account_key TEXT NOT NULL,
        page_key TEXT NOT NULL,
        payload BLOB NOT NULL,
        fetched_at INTEGER NOT NULL,
        expires_at INTEGER NOT NULL,
        last_access_at INTEGER NOT NULL,
        byte_count INTEGER NOT NULL
      );
      CREATE INDEX IF NOT EXISTS idx_tieba_page_cache_scope_fresh
        ON \(pageCacheTable)(page_key, account_key, fetched_at DESC);
      CREATE INDEX IF NOT EXISTS idx_tieba_page_cache_account_kind_access
        ON \(pageCacheTable)(account_key, kind, last_access_at DESC);
      CREATE INDEX IF NOT EXISTS idx_tieba_page_cache_expiry
        ON \(pageCacheTable)(expires_at);
      """
    try execute(db, sql, version: 2)
  }

  private static func migrateForumAvatarCache(_ db: OpaquePointer) throws {
    let sql = """
      CREATE TABLE IF NOT EXISTS \(forumAvatarTable) (
        cache_key TEXT PRIMARY KEY NOT NULL,
        avatar TEXT NOT NULL,
        fetched_at INTEGER NOT NULL,
        last_access_at INTEGER NOT NULL
      );
      CREATE INDEX IF NOT EXISTS idx_tieba_forum_avatar_access
        ON \(forumAvatarTable)(last_access_at DESC);
      """
    try execute(db, sql, version: 3)
  }

  private static func execute(_ db: OpaquePointer, _ sql: String, version: Int) throws {
    if let failure = TiebaSQLiteCore.executeScript(db, sql) {
      throw TiebaDatabaseMigrationError.failed(version: version, detail: failure)
    }
  }

  private static func ensureColumns(
    _ db: OpaquePointer,
    table: String,
    columns: [(name: String, definition: String)],
    version: Int
  ) throws {
    let existing = Set(try columnNames(db, table: table))
    for column in columns where existing.contains(column.name) == false {
      try execute(
        db,
        "ALTER TABLE \(table) ADD COLUMN \(column.name) \(column.definition);",
        version: version
      )
    }
  }

  private static func columnNames(_ db: OpaquePointer, table: String) throws -> [String] {
    guard let statement = TiebaSQLiteCore.prepare(db, "PRAGMA table_info(\(table));") else {
      throw TiebaDatabaseMigrationError.failed(version: currentVersion, detail: TiebaSQLiteCore.errorMessage(db))
    }
    defer { sqlite3_finalize(statement) }
    var names: [String] = []
    while true {
      let step = sqlite3_step(statement)
      if step == SQLITE_ROW {
        if let text = TiebaSQLiteCore.columnString(statement, 1) {
          names.append(text)
        }
      } else if step == SQLITE_DONE {
        return names
      } else {
        throw TiebaDatabaseMigrationError.failed(version: currentVersion, detail: TiebaSQLiteCore.errorMessage(db))
      }
    }
  }

  private static func userVersion(_ db: OpaquePointer) throws -> Int {
    guard let statement = TiebaSQLiteCore.prepare(db, "PRAGMA user_version;") else {
      throw TiebaDatabaseMigrationError.failed(version: 0, detail: TiebaSQLiteCore.errorMessage(db))
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else {
      throw TiebaDatabaseMigrationError.failed(version: 0, detail: TiebaSQLiteCore.errorMessage(db))
    }
    return Int(sqlite3_column_int64(statement, 0))
  }

  private static func hasUserTables(_ db: OpaquePointer) throws -> Bool {
    guard let statement = TiebaSQLiteCore.prepare(
      db,
      "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' LIMIT 1;"
    ) else {
      throw TiebaDatabaseMigrationError.failed(version: currentVersion, detail: TiebaSQLiteCore.errorMessage(db))
    }
    defer { sqlite3_finalize(statement) }
    return sqlite3_step(statement) == SQLITE_ROW
  }

  /// 用户显式“清除全部数据”时删除迁移备份（备份同样包含登录/历史等用户数据）。
  static func removeMigrationBackups(forDatabasePath path: String) {
    let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
      .appendingPathComponent("Backups", isDirectory: true)
    guard let files = try? FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil
    ) else { return }
    for file in files where file.lastPathComponent.hasPrefix("tiebalite-before-v") {
      try? FileManager.default.removeItem(at: file)
    }
  }

  private static func backupBeforeMigration(
    db: OpaquePointer,
    path: String,
    fromVersion: Int
  ) throws {
    let sourceURL = URL(fileURLWithPath: path)
    let backupDirectory = sourceURL.deletingLastPathComponent()
      .appendingPathComponent("Backups", isDirectory: true)
    try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
    let destinationURL = backupDirectory
      .appendingPathComponent("tiebalite-before-v\(currentVersion)-from-v\(fromVersion).db")
    if FileManager.default.fileExists(atPath: destinationURL.path) {
      try FileManager.default.removeItem(at: destinationURL)
    }

    var destination: OpaquePointer?
    let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(destinationURL.path, &destination, flags, nil) == SQLITE_OK,
          let destination else {
      if let destination { sqlite3_close_v2(destination) }
      throw TiebaDatabaseMigrationError.failed(
        version: fromVersion,
        detail: "backup open failed: \(TiebaSQLiteCore.errorMessage(db))"
      )
    }
    defer { sqlite3_close_v2(destination) }
    guard let backup = sqlite3_backup_init(destination, "main", db, "main") else {
      throw TiebaDatabaseMigrationError.failed(
        version: fromVersion,
        detail: "backup init failed: \(TiebaSQLiteCore.errorMessage(destination))"
      )
    }
    let step = sqlite3_backup_step(backup, -1)
    let finish = sqlite3_backup_finish(backup)
    guard step == SQLITE_DONE, finish == SQLITE_OK else {
      throw TiebaDatabaseMigrationError.failed(
        version: fromVersion,
        detail: "backup step=\(step) finish=\(finish)"
      )
    }
    log.notice(
      "database migration backup: \(destinationURL.lastPathComponent, privacy: .public)"
    )
  }
}

/// 同步查询门面。并发：全部可变状态（连接表）由 Mutex 保护——真并发安全，
/// 不需要 @unchecked Sendable 的人工声明（连接里的 transactionDepth 也是可变的，
/// 所以整张表一起串行化，而不是只锁字典本身）。
final class TiebaSQLite: Sendable {
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

  /// 库名 → 连接。
  private let connections = TiebaMutex<[String: TiebaSQLiteConnection]>([:])

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
    try connections.withLock { table in
      // 取连接：命中直接用；未命中建一条并登记（登记必须发生在 Mutex 闭包内）。
      // 这里不用「把表 inout 传给助手」的写法：inout sending 参数在闭包返回时
      // 仍可达，会触发 region-isolation 报错（-typecheck 看不出来）。
      let connection: TiebaSQLiteConnection
      if let cached = table[database] {
        connection = cached
      } else {
        let created = try openLocked(database)
        table[database] = created
        connection = created
      }
      try execLocked(connection.handle, sql: sql)
    }
  }

  func run(database: String, sql: String, params: [[String: Any]]) throws -> (lastInsertRowId: Int64, changes: Int) {
    let values = params.map { SQLiteBindValue.from($0["v"]) }
    return try connections.withLock { table in
      let connection: TiebaSQLiteConnection
      if let cached = table[database] {
        connection = cached
      } else {
        let created = try openLocked(database)
        table[database] = created
        connection = created
      }
      let statement = try prepareLocked(connection.handle, sql: sql)
      defer { sqlite3_finalize(statement) }
      bindLocked(statement, values: values)
      guard sqlite3_step(statement) == SQLITE_DONE else {
        throw TiebaSQLiteError.statementFailed(Self.errorMessage(connection.handle))
      }
      return (sqlite3_last_insert_rowid(connection.handle), Int(sqlite3_changes(connection.handle)))
    }
  }

  func query(database: String, sql: String, params: [[String: Any]]) throws -> [[String: Any]] {
    let values = params.map { SQLiteBindValue.from($0["v"]) }
    let rows: [[String: SQLiteColumnValue]] = try connections.withLock { table in
      // 取连接（登记须在 Mutex 闭包内；不用 inout sending 的写法，理由见 exec）。
      let connection: TiebaSQLiteConnection
      if let cached = table[database] {
        connection = cached
      } else {
        let created = try openLocked(database)
        table[database] = created
        connection = created
      }
      let statement = try prepareLocked(connection.handle, sql: sql)
      defer { sqlite3_finalize(statement) }
      bindLocked(statement, values: values)
      var rows: [[String: SQLiteColumnValue]] = []
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
    // Any 装箱放在锁外：锁内只出现 Sendable 值，出锁后再翻成 [[String: Any]]
    return rows.map { row in row.mapValues(\.anyValue) }
  }

  func queryFirst(database: String, sql: String, params: [[String: Any]]) throws -> [String: Any]? {
    let values = params.map { SQLiteBindValue.from($0["v"]) }
    let row: [String: SQLiteColumnValue]? = try connections.withLock { table in
      // 取连接（登记须在 Mutex 闭包内；不用 inout sending 的写法，理由见 exec）。
      let connection: TiebaSQLiteConnection
      if let cached = table[database] {
        connection = cached
      } else {
        let created = try openLocked(database)
        table[database] = created
        connection = created
      }
      let statement = try prepareLocked(connection.handle, sql: sql)
      defer { sqlite3_finalize(statement) }
      bindLocked(statement, values: values)
      let step = sqlite3_step(statement)
      if step == SQLITE_ROW {
        return Self.rowDictionary(statement)
      }
      if step == SQLITE_DONE {
        return nil
      }
      throw TiebaSQLiteError.statementFailed(Self.errorMessage(connection.handle))
    }
    return row.map { $0.mapValues(\.anyValue) }
  }

  // MARK: - 事务（JS 的 withTransactionAsync 驱动）

  func begin(database: String) throws {
    try connections.withLock { table in
      // 取连接（登记须在 Mutex 闭包内；不用 inout sending 的写法，理由见 exec）。
      let connection: TiebaSQLiteConnection
      if let cached = table[database] {
        connection = cached
      } else {
        let created = try openLocked(database)
        table[database] = created
        connection = created
      }
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
    try connections.withLock { table in
      guard let connection = table[database], connection.transactionDepth > 0 else { return }
      connection.transactionDepth -= 1
      if connection.transactionDepth == 0 {
        try execLocked(connection.handle, sql: "COMMIT;")
      } else {
        try execLocked(connection.handle, sql: "RELEASE tieba_nested;")
      }
    }
  }

  func rollback(database: String) throws {
    try connections.withLock { table in
      guard let connection = table[database], connection.transactionDepth > 0 else { return }
      connection.transactionDepth = 0
      do {
        try execLocked(connection.handle, sql: "ROLLBACK;")
      } catch {
        // ROLLBACK 自己失败 ⇒ 这个事务状态已不可信。若把连接留在表里，下一次
        // `BEGIN IMMEDIATE` 会永久报 "cannot start a transaction within a transaction"，
        // 而那个报错与真因无关（调用方看到的是"事务里还能再开事务"）。
        // 摘掉连接并关闭：sqlite3_close_v2 会替我们回滚未完成事务，下次访问重开一个
        // 干净连接。原始 ROLLBACK 错误照抛，不吞。
        table.removeValue(forKey: database)
        sqlite3_close_v2(connection.handle)
        throw error
      }
    }
  }

  /// 关闭连接（遗留库迁移读完就关，回收句柄）。
  func close(database: String) {
    connections.withLock { table in
      guard let connection = table.removeValue(forKey: database) else { return }
      sqlite3_close_v2(connection.handle)
    }
  }

  /// 删除库文件（含 -wal/-shm）。legacy 迁移把旧库并进统一库后调用。
  func deleteDatabase(named name: String) throws {
    try connections.withLock { table in
      if let connection = table.removeValue(forKey: name) {
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

  /// 打开一条新连接（WAL + schema 自愈）。**不碰连接表**：登记由调用方在
  /// Mutex 闭包内完成（见 public API 里的注释）。
  private func openLocked(_ database: String) throws -> TiebaSQLiteConnection {
    let handle: OpaquePointer
    do {
      handle = try TiebaSQLiteCore.open(
        path: databaseURL(named: database).path,
        profile: .relational
      )
    } catch let error as TiebaSQLiteCoreError {
      throw TiebaSQLiteError.databaseUnavailable(error.detail)
    }
    let connection = TiebaSQLiteConnection(handle: handle)
    // WAL：两条连接读写同库时读不阻塞写。必须排在下面的 schema 自愈之前——
    // journal_mode 是库文件级属性，已有写事务时再切换会失败，而建表就是写。
    // 失败不阻断（回滚日志模式下靠 busy_timeout 也能跑）——与 TiebaKvStore 同款。
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
    return connection
  }

  /// 旧库缺失列补齐（ALTER 只加不删；NOT NULL 必须带默认值 SQLite 才收）。
  /// 覆盖 v1 起全部业务列：老 unified 库只差 author_portrait，更老的库可能差更多。
  private static let visitHistoryColumns = TiebaDatabaseSchema.visitHistoryColumns

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

  private func bindLocked(_ statement: OpaquePointer, values: [SQLiteBindValue]) {
    for (offset, value) in values.enumerated() {
      let index = Int32(offset + 1)
      switch value {
      case .null:
        sqlite3_bind_null(statement, index)
      case .text(let text):
        TiebaSQLiteCore.bind(statement, index, text)
      case .integer(let number):
        sqlite3_bind_int64(statement, index, number)
      case .double(let number):
        sqlite3_bind_double(statement, index, number)
      case .blob(let data):
        data.withUnsafeBytes { raw in
          _ = sqlite3_bind_blob(
            statement,
            index,
            raw.baseAddress,
            Int32(raw.count),
            TiebaSQLiteCore.transient()
          )
        }
      }
    }
  }

  /// 一行 → 字典（列名 → SQLiteColumnValue，出锁时才装箱成 String / Double / NSNull）。
  private static func rowDictionary(_ statement: OpaquePointer) -> [String: SQLiteColumnValue] {
    var row: [String: SQLiteColumnValue] = [:]
    for index in 0..<sqlite3_column_count(statement) {
      guard let namePointer = sqlite3_column_name(statement, index) else { continue }
      let name = String(cString: namePointer)
      switch sqlite3_column_type(statement, index) {
      case SQLITE_INTEGER, SQLITE_FLOAT:
        row[name] = .real(sqlite3_column_double(statement, index))
      case SQLITE_TEXT:
        // column_bytes 而不是 cString：值里出现 NUL 时不被截断（core 内同款）。
        // 旧实现里 columnString 返回 nil 会装箱成 NSNull，这里保持同一语义。
        if let text = TiebaSQLiteCore.columnString(statement, index) {
          row[name] = .text(text)
        } else {
          row[name] = .null
        }
      case SQLITE_BLOB:
        let count = Int(sqlite3_column_bytes(statement, index))
        if count == 0 {
          row[name] = .blob(Data())
        } else if let bytes = sqlite3_column_blob(statement, index) {
          row[name] = .blob(Data(bytes: bytes, count: count))
        } else {
          row[name] = .null
        }
      default:
        // BLOB / NULL：本仓无 blob 列，统一给 NSNull（null 语义）。
        row[name] = .null
      }
    }
    return row
  }

  private static func errorMessage(_ db: OpaquePointer) -> String {
    TiebaSQLiteCore.errorMessage(db)
  }
}
