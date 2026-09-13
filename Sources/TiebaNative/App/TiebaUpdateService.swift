// ============================================================
// TiebaUpdateService —— 「检查更新」的原生实现（原 src/services/update/releaseService.ts
// + src/stores/updateStore.ts 的页面侧子集）
//
// 数据源：GitHub Releases 的 latest API（唯一来源）。限流/网络失败直接抛错，
// 不做 atom feed 兜底（2026-09-13 审查：手写 XML/正则/HTML 反转义的降级链与
// "拒绝一切兜底"冲突，已删）。地址是本应用的 toamdou/TiebaLite-IOS ——
// 与本应用（RN-Swift）的仓库不同名，是既有事实，不要改。
//
// 安全约束（发请求前一律校验，与 JS assertAllowedReleaseUrl 同义）：
// 只允许 https；host 必须命中白名单（GitHub）——白名单之外的 host 一律拒绝
// （内网/本机地址天然不在白名单，不再单独识别）。错误文案逐字保留
// （会出现在"检查失败：…"里）。
//
// 与 JS 的差异（本文件刻意保留的取舍）：
//   - 网络失败文案：JS 走 RN fetch，抛的是 "Network request failed"；这里把
//     URLError 也归一成同一句（用户可见文案不变），其余错误用原样描述。
//   - JSON 解析失败：JS 的 SyntaxError 细节（"JSON Parse error: …"）不复刻，
//     统一 "JSON Parse error"（GitHub 返回非 JSON 才会出现，属罕见路径）。
//   - 版本号来源：JS 是 TiebaPlatform.appVersion() || APP_VERSION（常量）；
//     这里直接读 Info.plist 的 CFBundleShortVersionString（同一字段，
//     与 TiebaSystemUI.swift 的 TiebaAppInfo 同源），空串回落 "1.0.0"。
//     ⚠️ 刻意不 import TiebaAppInfo：本文件要保持"可裸 swiftc 单测"的零依赖。
//
// 线程：TiebaReleaseAPI 全是 nonisolated（网络与解析在协作线程池）；
// TiebaUpdateService 是 @MainActor 的页面状态容器（原 zustand updateStore 的
// 页面侧状态：status / release / hasUpdate / currentVersion / error）。
// ============================================================
import Foundation

/// 跨桥/网络错误的统一载体：errorDescription 即界面展示文案（与 JS 侧
/// `e instanceof Error ? e.message` 同义）。
struct TiebaUpdateError: LocalizedError {
  let message: String

  var errorDescription: String? { message }
}

/// 最新 Release（原 releaseService 的 ReleaseInfo，字段一一对应）。
struct TiebaReleaseInfo: Sendable {
  /// tag 去掉前缀 v 的版本号
  var version: String
  var tag: String
  var name: String
  /// Release 说明（用户写的日志，markdown 原文）
  var notes: String
  var publishedAt: String?
  /// Release 页面地址（已校验）
  var url: String
  var prerelease: Bool
}

/// 页面状态（原 updateStore 的 status 联合类型）。
enum TiebaUpdateStatus: String, Sendable {
  case idle
  case checking
  case done
  case error
}

// MARK: - 数据源

enum TiebaReleaseAPI {
  /// 仓库 Releases API（latest，唯一数据源）
  static let latestAPI = "https://api.github.com/repos/toamdou/TiebaLite-IOS/releases/latest"
  /// 仓库 Releases 页面：关于页「在浏览器中打开 Release 页面」行的静态目标
  /// （release 为空时才会用到，服务内部不再回落）。
  static let releasesPage = "https://github.com/toamdou/TiebaLite-IOS/releases"

  private static let allowedHosts: Set<String> = ["api.github.com", "github.com", "www.github.com"]
  /// APP_VERSION（src/constants/app.ts）同值：读不到构建版本时的回落常量。
  private static let fallbackAppVersion = "1.0.0"

  // MARK: 版本号

  /// 当前应用版本（Info.plist CFBundleShortVersionString → CFBundleVersion →
  /// 常量），去掉前缀 v——与 JS currentAppVersion() 同一条链。
  static func currentVersion() -> String {
    let info = Bundle.main.infoDictionary
    var raw = (info?["CFBundleShortVersionString"] as? String) ?? ""
    if raw.isEmpty { raw = (info?["CFBundleVersion"] as? String) ?? "" }
    if raw.isEmpty { raw = fallbackAppVersion }
    return stripLeadingV(raw)
  }

  /// a 是否比 b 新（按数字段比较；预发布后缀视为不大于同号正式版）。
  static func isNewer(_ a: String, than b: String) -> Bool {
    let x = versionSegments(a)
    let y = versionSegments(b)
    for index in 0..<max(x.count, y.count) {
      let xi = index < x.count ? x[index] : 0
      let yi = index < y.count ? y[index] : 0
      if xi != yi { return xi > yi }
    }
    return false
  }

  private static func stripLeadingV(_ value: String) -> String {
    guard let first = value.first, first == "v" || first == "V" else { return value }
    return String(value.dropFirst())
  }

  /// JS `v.split(/[.+\-]/).map(parseInt)`：无数字前缀的段记 0。
  private static func versionSegments(_ value: String) -> [Int] {
    stripLeadingV(value).components(separatedBy: CharacterSet(charactersIn: ".+-")).map { part in
      var digits = ""
      for character in part {
        guard character.isNumber else { break }
        digits.append(character)
      }
      return Int(digits) ?? 0
    }
  }

  // MARK: 拉取

  /// 拉取最新 Release（GitHub API，唯一来源）。失败直接抛（限流/断网都不换数据源）。
  static func fetchLatest() async throws -> TiebaReleaseInfo {
    let url = try assertAllowed(latestAPI)
    var request = URLRequest(url: url)
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    let (data, response) = try await send(request)
    guard (200...299).contains(response.statusCode) else {
      throw TiebaUpdateError(message: "GitHub 返回 \(response.statusCode)")
    }
    guard let object = try? JSONSerialization.jsonObject(with: data),
      let json = object as? [String: Any]
    else {
      throw TiebaUpdateError(message: "JSON Parse error")
    }
    let tag = json["tag_name"] as? String ?? ""
    let rawName = jsString(json["name"])
    guard let rawPageURL = json["html_url"] as? String else {
      throw TiebaUpdateError(message: "Release 缺少 html_url")
    }
    return TiebaReleaseInfo(
      version: stripLeadingV(tag.isEmpty ? rawName : tag),
      tag: tag,
      name: (json["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? tag,
      notes: (json["body"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
      publishedAt: json["published_at"] as? String,
      // html_url 同样过校验：白名单外/非 https 一律大声失败（不静默换目标）。
      url: try assertAllowed(rawPageURL).absoluteString,
      prerelease: json["prerelease"] as? Bool ?? false
    )
  }

  /// URLSession 出口：URLError 归一成 RN fetch 的网络失败文案（"Network request
  /// failed"）——这是用户唯一能看到的网络错误字符串，必须与迁移前逐字一致。
  private static func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        throw TiebaUpdateError(message: "Network request failed")
      }
      return (data, http)
    } catch is URLError {
      throw TiebaUpdateError(message: "Network request failed")
    }
  }

  // MARK: URL 校验（原 releaseService.assertAllowedReleaseUrl）

  /// 校验 URL 可安全访问（https + GitHub 白名单），返回规范化 URL。
  /// 判序与 JS 逐条一致：解析失败 → 协议非 https → host 缺失 → 白名单。
  /// 白名单外一律拒绝——本机/内网地址天然不在白名单，不再单独识别。
  static func assertAllowed(_ raw: String) throws -> URL {
    guard let components = URLComponents(string: raw), let scheme = components.scheme, !scheme.isEmpty else {
      throw TiebaUpdateError(message: "更新地址无效")
    }
    guard scheme.lowercased() == "https" else {
      throw TiebaUpdateError(message: "更新地址仅允许 https")
    }
    guard let host = components.host, !host.isEmpty, let url = components.url else {
      throw TiebaUpdateError(message: "更新地址无效")
    }
    let normalizedHost = host.lowercased()
    guard allowedHosts.contains(normalizedHost) else {
      throw TiebaUpdateError(message: "更新地址 host 不在白名单（\(normalizedHost)）")
    }
    return url
  }

  // MARK: 文本处理

  /// JS `String(x ?? '')`：字符串原样，数字走十进制文本，其余空串。
  private static func jsString(_ value: Any?) -> String {
    if let text = value as? String { return text }
    if let number = value as? NSNumber { return number.stringValue }
    return ""
  }
}

// MARK: - 页面状态容器

/// 原 src/stores/updateStore.ts 的**页面侧**状态（唯一消费方 settings/about 已原生）。
/// 保留为单例：与 zustand store 语义一致——离开页面再回来时，上一次的检查结果还在
/// （旧页面读的就是同一个 store 实例）。
///
/// ⚠️ updateStore.ts 本身**没有删**：src/navigation/useAppBootstrap.ts 还用它做
/// "启动时自动检测更新"（maybeAutoCheck）。本类只覆盖关于页手动检查这条链；
/// 启动自动检测的原生接法（本类已有全部状态，只差一个启动调用点）是后续任务。
@MainActor
final class TiebaUpdateService {
  static let shared = TiebaUpdateService()

  private(set) var status: TiebaUpdateStatus = .idle
  private(set) var release: TiebaReleaseInfo?
  private(set) var hasUpdate = false
  /// 当前应用版本（检查时快照，供界面显示）——原 updateStore.currentVersion
  private(set) var currentVersion = TiebaReleaseAPI.currentVersion()
  private(set) var error: String?

  private var observers: [UUID: () -> Void] = [:]

  private init() {}

  /// 订阅状态变化（原 zustand store 的 subscribe；关于页与结果弹窗各一份）。
  func addObserver(_ block: @escaping () -> Void) -> UUID {
    let token = UUID()
    observers[token] = block
    return token
  }

  func removeObserver(_ token: UUID) {
    observers.removeValue(forKey: token)
  }

  /// 检查更新（重复点击时直接返回，与 updateStore.check 的 `status === 'checking'`
  /// 早退同义——调用方仍然会弹结果弹窗，即"正在检查更新…"那一态）。
  func check() async {
    guard status != .checking else { return }
    let snapshotVersion = TiebaReleaseAPI.currentVersion()
    status = .checking
    error = nil
    currentVersion = snapshotVersion
    notify()
    do {
      let latest = try await TiebaReleaseAPI.fetchLatest()
      release = latest
      hasUpdate = TiebaReleaseAPI.isNewer(latest.version, than: snapshotVersion)
      status = .done
    } catch {
      self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
      status = .error
    }
    notify()
  }

  private func notify() {
    for block in observers.values { block() }
  }
}
