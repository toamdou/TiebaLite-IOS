import ExpoModulesCore
import Foundation
import UIKit
import Darwin

public final class TiebaSystemModule: Module {
  private var powerStateObserver: NSObjectProtocol?
  private var memoryWarningObserver: NSObjectProtocol?

  public func definition() -> ModuleDefinition {
    Name("TiebaSystem")

    Events("onLowPowerModeChange", "onMemoryWarning")

    // Snapshot read — the current low power state. The event stream below
    // keeps JS subscribers in sync afterwards, so JS never needs to poll.
    AsyncFunction("getLowPowerMode") { () -> Bool in
      ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    // ── 诊断日志（闪退/信号崩溃/主线程卡死/JS 错误）──
    // 采集侧（信号处理器/RunLoop 心跳）仅 Release 安装，见文件底部；
    // 这里是查询/管理面，所有结果走原始类型（JSON 字符串），避免复杂
    // 序列化在无编译器验证下踩坑。旧二进制缺这些函数时 JS 侧有特性检测兜底。
    Function("listDiagnosticLogs") { () -> String in
      DiagnosticLogCenter.listAsJSON()
    }
    Function("readDiagnosticLog") { (name: String) -> String in
      try DiagnosticLogCenter.read(name)
    }
    Function("deleteDiagnosticLogs") { (names: [String]) -> Bool in
      DiagnosticLogCenter.delete(names)
      return true
    }
    Function("clearDiagnosticLogs") { () -> Bool in
      DiagnosticLogCenter.clearAll()
      return true
    }
    Function("appendJsError") { (summary: String) -> Bool in
      DiagnosticLogCenter.appendJsError(summary)
      return true
    }

    // Observers are attached only while at least one JS listener exists
    // (StartObserving/StopObserving pair), so a silent app holds no
    // NotificationCenter slots. All notifications are delivered on the main
    // thread, which matches the JS event delivery path.
    StartObserving {
      // Low Power Mode toggle: Settings → Battery, Control Center, or the
      // automatic 20% / 80% prompt. NSProcessInfo is the single source of
      // truth for the state.
      self.powerStateObserver = NotificationCenter.default.addObserver(
        forName: NSProcessInfo.powerStateDidChangeNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        self?.sendEvent(
          "onLowPowerModeChange",
          ["enabled": ProcessInfo.processInfo.isLowPowerModeEnabled]
        )
      }

      // iOS memory warning — the system asks for a cooperative purge before
      // it starts terminating our app. JS responds by clearing the
      // expo-image memory cache (see src/app/_layout.tsx).
      self.memoryWarningObserver = NotificationCenter.default.addObserver(
        forName: UIApplication.didReceiveMemoryWarningNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        self?.sendEvent("onMemoryWarning")
      }
    }

    StopObserving {
      stopObserving(&self.powerStateObserver)
      stopObserving(&self.memoryWarningObserver)
    }
  }

  private func stopObserving(_ observer: inout NSObjectProtocol?) {
    if let observer {
      NotificationCenter.default.removeObserver(observer)
    }
    observer = nil
  }
}

// ══════════════════════════════════════════════════════════════
// 诊断日志（闪退 / 信号崩溃 / 主线程卡死 / JS 错误）
//
// 采集侧仅 Release 安装（#if !DEBUG 整体编译剔除，Debug 零足迹）：
// AppDelegate 在 didFinishLaunching 用 NSClassFromString 运行时查找本文件
// 导出的 TiebaSystemCrashReporter（@objc 类，避免跨 pod import 模块名硬编码）。
//
// 崩溃写盘设计：
// - NSException 路径运行在普通上下文 → 直接写富文本 crash-<时间戳>.log；
// - Unix 信号路径只做 async-signal-safe 家族操作（open/write/close/
//   backtrace_symbols_fd/signal/raise），路径与头部缓冲在安装期预建、
//   处理器内零分配；写入固定名 pending-signal.log，下次启动转正为
//   signal-<时间戳>.log。写完恢复默认处理器并重抛，系统照常产出 .ips。
//
// 卡死检测：主线程 RunLoop 心跳（observer 回调 = 一条 Int64 赋值）+ 后台
// 1Hz 校对；阈值 4s、上报冷却 60s、需连续两拍确认（滤掉回前台瞬间的假阳性）；
// 进后台暂停计时（后台主 RunLoop 本就不跑）。
//
// 轮转：启动时 pending 转正 + 清理 >14 天 / >20 个文件 / 总量 >5MB（最旧优先）。
// ══════════════════════════════════════════════════════════════

public enum DiagnosticLogCenter {
  static let maxFileCount = 20
  static let maxTotalBytes = 5 * 1024 * 1024
  static let maxAgeSeconds: TimeInterval = 14 * 24 * 3600
  static let jsErrorRotateBytes = 256 * 1024

  static func logsDir() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("TiebaLogs", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
  }

  static func stamp(_ date: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
    return formatter.string(from: date)
  }

  private static func machineModel() -> String {
    var sysInfo = utsname()
    uname(&sysInfo)
    let bytes = withUnsafeBytes(of: &sysInfo.machine) { raw in
      raw.map { UInt8($0) }.prefix(while: { $0 != 0 })
    }
    return String(decoding: bytes, as: UTF8.self)
  }

  /// 设备/版本环境头（崩溃与卡死日志共用）
  static func environmentHeader(kind: String) -> String {
    let proc = ProcessInfo.processInfo
    let ver = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"
    let build = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "?"
    var freeGB = -1.0
    if let values = try? URL(fileURLWithPath: NSHomeDirectory())
      .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
      let bytes = values.volumeAvailableCapacityForImportantUsage {
      freeGB = Double(bytes) / 1_073_741_824
    }
    return """
    kind: \(kind)
    time: \(stamp())
    app: \(ver) (\(build))
    ios: \(proc.operatingSystemVersionString)
    model: \(machineModel())
    uptime_s: \(Int(proc.systemUptime))
    disk_free_gb: \(String(format: "%.1f", freeGB))
    ---
    """
  }

  static func isSafeName(_ name: String) -> Bool {
    !name.isEmpty && !name.contains("/") && !name.contains("..")
  }

  // ── 查询/管理面（JS 调用；结果走原始类型，序列化零风险）──

  static func listAsJSON() -> String {
    let fm = FileManager.default
    guard let items = try? fm.contentsOfDirectory(
      at: logsDir(),
      includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
    ) else { return "[]" }
    var entries: [[String: Any]] = []
    for url in items where url.pathExtension.lowercased() == "log" {
      let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
      entries.append([
        "name": url.lastPathComponent,
        "size": values?.fileSize ?? 0,
        "mtimeMs": Int64((values?.contentModificationDate ?? .distantPast).timeIntervalSince1970 * 1000),
      ])
    }
    entries.sort {
      ($0["mtimeMs"] as? Int64 ?? 0) > ($1["mtimeMs"] as? Int64 ?? 0)
    }
    guard let data = try? JSONSerialization.data(withJSONObject: entries),
          let json = String(data: data, encoding: .utf8) else { return "[]" }
    return json
  }

  static func read(_ name: String) throws -> String {
    guard isSafeName(name) else { return "" }
    return try String(contentsOf: logsDir().appendingPathComponent(name), encoding: .utf8)
  }

  static func delete(_ names: [String]) {
    let fm = FileManager.default
    for name in names where isSafeName(name) {
      try? fm.removeItem(at: logsDir().appendingPathComponent(name))
    }
  }

  static func clearAll() {
    let fm = FileManager.default
    guard let items = try? fm.contentsOfDirectory(at: logsDir(), includingPropertiesForKeys: nil) else { return }
    for url in items { try? fm.removeItem(at: url) }
  }

  /// JS 错误追加（Release 才真正写入）。单文件超 256KB 归档为 .old 后续写。
  static func appendJsError(_ summary: String) {
#if !DEBUG
    let fm = FileManager.default
    let file = logsDir().appendingPathComponent("jserror.log")
    if let attrs = try? fm.attributesOfItem(atPath: file.path),
       let size = attrs[.size] as? Int, size > jsErrorRotateBytes {
      let archived = logsDir().appendingPathComponent("jserror.old.log")
      try? fm.removeItem(at: archived)
      try? fm.moveItem(at: file, to: archived)
    }
    let clean = summary.replacingOccurrences(of: "\n", with: " ")
    let line = "\(stamp()) \(clean)\n"
    if let handle = FileHandle(forWritingAtPath: file.path) {
      defer { try? handle.close() }
      try? handle.seekToEnd()
      try? handle.write(contentsOf: Data(line.utf8))
    } else {
      try? Data(line.utf8).write(to: file)
    }
#endif
  }

  // ── 写入面（捕获器专用）──

  static func writeExceptionLog(_ exception: NSException) {
    let body = environmentHeader(kind: "crash")
      + "exception: \(exception.name.rawValue)\n"
      + "reason: \(exception.reason ?? "-")\n"
      + "stack:\n"
      + exception.callStackSymbols.joined(separator: "\n")
      + "\n"
    try? Data(body.utf8).write(to: logsDir().appendingPathComponent("crash-\(stamp()).log"))
  }

  static func writeHangLog(stalledNs: UInt64) {
    let body = environmentHeader(kind: "hang")
      + "main_thread_stalled_ms: \(stalledNs / 1_000_000)\n"
      + "note: 冻结中的主线程栈无法安全抓取，v1 仅记录事件\n"
    try? Data(body.utf8).write(to: logsDir().appendingPathComponent("hang-\(stamp()).log"))
  }

  /// 启动轮转：pending 信号日志转正 → 过期清理 → 数量/总量上限（最旧优先）
  static func rotateIfNeeded() {
    let fm = FileManager.default
    let dir = logsDir()
    let pending = dir.appendingPathComponent("pending-signal.log")
    if fm.fileExists(atPath: pending.path) {
      try? fm.moveItem(at: pending, to: dir.appendingPathComponent("signal-\(stamp()).log"))
    }
    guard let items = try? fm.contentsOfDirectory(
      at: dir,
      includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
    ) else { return }
    var kept: [(url: URL, mtime: Date, size: Int)] = []
    for url in items where url.pathExtension.lowercased() == "log" {
      let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
      let mtime = values?.contentModificationDate ?? .distantPast
      if mtime.timeIntervalSinceNow < -maxAgeSeconds {
        try? fm.removeItem(at: url)
      } else {
        kept.append((url, mtime, values?.fileSize ?? 0))
      }
    }
    kept.sort { $0.mtime < $1.mtime }
    var totalBytes = kept.reduce(0) { $0 + $1.size }
    while kept.count > maxFileCount || (!kept.isEmpty && totalBytes > maxTotalBytes) {
      let removed = kept.removeFirst()
      totalBytes -= removed.size
      try? fm.removeItem(at: removed.url)
    }
  }
}

/// 运行时由 AppDelegate 查找调用（NSClassFromString("TiebaSystemCrashReporter")）。
@objc(TiebaSystemCrashReporter)
public final class TiebaSystemCrashReporter: NSObject {
  private static var installed = false

  @objc public static func install() {
#if !DEBUG
    guard !installed else { return }
    installed = true
    DiagnosticLogCenter.rotateIfNeeded()
    TiebaSystemHangDetector.shared.start()
    prepareSignalBuffers()
    NSSetUncaughtExceptionHandler(tiebaUncaughtExceptionHandler)
    for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP] {
      signal(sig, tiebaSignalHandler)
    }
#endif
  }
}

// ── 主线程卡死检测 ──

final class TiebaSystemHangDetector {
  static let shared = TiebaSystemHangDetector()

  private let thresholdNs: UInt64 = 4_000_000_000
  private let reportCooldownNs: UInt64 = 60_000_000_000
  // 主线程写、后台队列读的启发式整数：竞态最坏只是漏拍/多拍一次，无需锁
  private var heartbeat: UInt64 = 0
  private var lastReportAt: UInt64 = 0
  private var consecutiveStalls = 0
  private var paused = false
  private var observer: CFRunLoopObserver?
  private var timer: DispatchSourceTimer?

  func start() {
    let activity = CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.afterWaiting.rawValue
    let obs = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, activity, true, 0) {
      [weak self] _, _ in
      self?.heartbeat = DispatchTime.now().uptimeNanoseconds
    }
    CFRunLoopAddObserver(CFRunLoopGetMain(), obs, CFRunLoopMode.commonModes)
    observer = obs
    heartbeat = DispatchTime.now().uptimeNanoseconds

    // 进后台暂停：后台主 RunLoop 本就不跑，不暂停则回前台必误报一次巨长卡死
    let center = NotificationCenter.default
    center.addObserver(
      forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      self.paused = true
      self.consecutiveStalls = 0
      self.heartbeat = DispatchTime.now().uptimeNanoseconds
    }
    center.addObserver(
      forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      self.heartbeat = DispatchTime.now().uptimeNanoseconds
      self.paused = false
    }

    let source = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
    source.schedule(deadline: .now() + 1.0, repeating: 1.0)
    source.setEventHandler { [weak self] in self?.checkOnQueue() }
    source.resume()
    timer = source
  }

  private func checkOnQueue() {
    guard !paused, heartbeat != 0 else {
      consecutiveStalls = 0
      return
    }
    let now = DispatchTime.now().uptimeNanoseconds
    let gap = now - heartbeat
    if gap >= thresholdNs {
      // 连续两拍都超阈值才认定：滤掉「进程恢复瞬间读到陈旧心跳」的假阳性
      consecutiveStalls += 1
      if consecutiveStalls >= 2, now - lastReportAt >= reportCooldownNs {
        lastReportAt = now
        DiagnosticLogCenter.writeHangLog(stalledNs: gap)
      }
    } else {
      consecutiveStalls = 0
    }
  }
}

// ── 崩溃处理器（顶层 C 兼容函数，不可捕获上下文）──

#if !DEBUG
private var g_pendingSignalPath: [CChar] = []
private var g_signalHeader: [UInt8] = []

private func tiebaUncaughtExceptionHandler(_ exception: NSException) {
  DiagnosticLogCenter.writeExceptionLog(exception)
}

/// 信号处理器：只用 async-signal-safe 家族。时间戳无法安全格式化，
/// 固定名 pending 文件由下次启动转正。写毕恢复默认处理器并重抛，
/// 让系统照常生成 .ips 报告。
private func tiebaSignalHandler(_ sig: Int32) {
  let fd = open(g_pendingSignalPath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
  if fd >= 0 {
    g_signalHeader.withUnsafeBufferPointer { buf in
      if let base = buf.baseAddress {
        _ = write(fd, base, buf.count)
      }
    }
    // 信号编号手写十进制（无 snprintf）
    var n = sig
    var digits: [UInt8] = []
    repeat {
      digits.append(UInt8(48 + n % 10))
      n /= 10
    } while n > 0
    digits.append(UInt8(ascii: "\n"))
    digits.withUnsafeBufferPointer { buf in
      if let base = buf.baseAddress {
        _ = write(fd, base, buf.count)
      }
    }
    var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 128)
    let depth = backtrace(&frames, 128)
    if depth > 1 {
      backtrace_symbols_fd(&frames, depth, fd)
    }
    close(fd)
  }
  signal(sig, SIG_DFL)
  raise(sig)
}

private func prepareSignalBuffers() {
  let pending = DiagnosticLogCenter.logsDir().appendingPathComponent("pending-signal.log")
  g_pendingSignalPath = Array(pending.path.utf8CString)
  g_signalHeader = Array(DiagnosticLogCenter.environmentHeader(kind: "signal-crash").utf8)
}
#endif
