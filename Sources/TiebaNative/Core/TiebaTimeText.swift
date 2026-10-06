import Foundation

/// 全仓**唯一**的时间文案实现。
///
/// 收敛前有 4 份相对时间实现（`TiebaRowParser` / `TiebaPostTimeText` / `TiebaSearchAPI` /
/// `TiebaTimeLabel`），其中搜索列表那份漏了「昨天 HH:mm」分支，与 JS utils relativeTime 不一致：
/// 同一条帖子在信息流里显示「昨天 14:03」、在搜索结果里显示「1天前」。这里按 JS 语义统一。
enum TiebaTimeText {
  /// JS utils relativeTime（src/utils/index.ts:59）逐分支等价。
  static func relative(ms: Double) -> String {
    guard ms >= 946_684_800_000 else { return "" }
    let diff = max(0, Date().timeIntervalSince1970 * 1000 - ms)
    let minute = 60_000.0, hour = 3_600_000.0, day = 86_400_000.0
    if diff < minute { return "刚刚" }
    if diff < hour { return "\(Int(diff / minute))分钟前" }
    if diff < day { return "\(Int(diff / hour))小时前" }
    let then = Date(timeIntervalSince1970: ms / 1000)
    if Calendar.current.isDateInYesterday(then) {
      return "昨天 \(TiebaDateFormats.fixed("HH:mm").string(from: then))"
    }
    if diff < 7 * day { return "\(Int(diff / day))天前" }
    return TiebaDateFormats.fixed("yyyy-MM-dd").string(from: then)
  }

  /// JS utils absoluteTime（src/utils/index.ts:81）。
  static func absolute(ms: Double) -> String {
    guard ms >= 946_684_800_000 else { return "" }
    return TiebaDateFormats.fixed("yyyy-MM-dd HH:mm").string(from: Date(timeIntervalSince1970: ms / 1000))
  }

  /// 用户偏好档（设置→时间显示 timestampStyle）二选一 —— 原 `TiebaTimeLabel.label`。
  static func label(ms: Double) -> String {
    TiebaPreferenceSnapshot.string("timestampStyle") == "absolute" ? absolute(ms: ms) : relative(ms: ms)
  }

  /// 帖子行档（行级偏好 timestampStyle）—— 原 `TiebaPostTimeText.label`。
  static func label(ms: Double, style: String) -> String {
    style == "absolute" ? absolute(ms: ms) : relative(ms: ms)
  }
}

/// 全仓**唯一**的 DateFormatter 构造入口：固定 en_US_POSIX + Gregorian（不受用户地区/佛历影响）。
///
/// 收敛前 8 处各建各的（同一份配置抄 8 遍，每处还各写一段"为什么必须静态复用"的注释）。
/// 依据（SDK 原文 NSDateFormatter.h:158）：iOS 7 起 NSDateFormatter 线程安全，建好后只调
/// `string(from:)`、不再改动，因此按 (格式, 时区) 缓存复用即可。
enum TiebaDateFormats {
  private static let lock = NSLock()
  /// 跨线程读写由 lock 保护；DateFormatter 本身 Sendable。
  nonisolated(unsafe) private static var cache: [String: DateFormatter] = [:]

  static func fixed(_ format: String, timeZone: TimeZone? = nil) -> DateFormatter {
    let key = timeZone.map { "\(format)|\($0.identifier)" } ?? format
    lock.lock()
    defer { lock.unlock() }
    if let hit = cache[key] { return hit }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    if let timeZone { formatter.timeZone = timeZone }
    formatter.dateFormat = format
    cache[key] = formatter
    return formatter
  }
}
