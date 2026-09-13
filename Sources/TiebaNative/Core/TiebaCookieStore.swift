// Cookie 双存储（Foundation + WKWebView）——替代 @preeternal/react-native-cookie-manager。
//
// 为什么两个存储都要管（2026-08-26 双存储拆分）：API 请求走 URLSession，只看
// NSHTTPCookieStorage；登录页 WebView 写下的 HttpOnly 凭据（BDUSS/STOKEN）落在
// WKWebsiteDataStore。任一存储漏读都会复现"WebView 登录完成后读不回凭据"。
//
// WK 存储的 API 必须在主线程调用（WebKit 的约定；旧包用 DispatchQueue.main.async
// 包了一层）。整个类型因此 @MainActor 隔离，@JS async 成员 await 进来即可——
// HTTPCookie 是 Sendable 之外的类型，主线程构造、主线程消费，不跨 actor 传递；
// 旧包 Swift 6 报的 `sending 'completion' risks causing data races`（4 处）正是
// completion 闭包跨线程捕获非 Sendable 值造成的，这里从结构上不存在该问题。
//
// WK 存储首次访问会拉起 WebContent 进程（~200MB 常驻，真机实测），所以"什么时候
// 往 WK 写"由 JS 侧 CookieService 门控（首次真正要开 WebView 前补齐），这里不做
// 任何惰性化——本文件只保证"调一次写一次、写完才 resolve"。
import Foundation
import WebKit

/// 跨桥抛错用的最小错误类型：LocalizedError 的 errorDescription 会成为 JS 侧
/// Error.message（与旧包 reject 的文案保持同义）。
struct TiebaCookieError: LocalizedError {
  let message: String

  var errorDescription: String? { message }
}

/// Cookie 存取。无状态，纯函数集合；@MainActor 只为主线程约束，不是并发限流。
@MainActor
enum TiebaCookieStore {
  /// 域名匹配（与旧包 CookieDomainLogic.isMatchingDomain 同义）：host 命中
  /// cookieDomain 本身或其子域，cookieDomain 允许带前导 "."（域 cookie）。
  /// nonisolated：WK 全量读取的 completion 可能在主线程之外回调，过滤要在
  /// 那里算（纯字符串运算，不碰任何隔离状态）。
  nonisolated static func isMatchingDomain(host: String, cookieDomain: String) -> Bool {
    var domain = cookieDomain.trimmingCharacters(in: .whitespacesAndNewlines)
    if domain.hasPrefix(".") {
      domain.removeFirst()
    }
    guard !domain.isEmpty else { return false }
    let normalizedHost = host.lowercased()
    let normalizedDomain = domain.lowercased()
    return normalizedHost == normalizedDomain || normalizedHost.hasSuffix(".\(normalizedDomain)")
  }

  /// 写一条 cookie。url 只用于域名校验——host 与 domain 不匹配时抛错（与旧包
  /// 一致：调用方的激活序列靠这个失败中止，不能吞掉去写一条永远不生效的 cookie）。
  static func set(
    urlString: String,
    name: String,
    value: String,
    domain: String,
    path: String,
    secure: Bool,
    httpOnly: Bool,
    maxAge: Double,
    webKit: Bool
  ) async throws {
    guard let url = URL(string: urlString), let host = url.host, !host.isEmpty else {
      throw TiebaCookieError(
        message: "Invalid URL: It may be missing a protocol (ex. http:// or https://)."
      )
    }
    guard !name.isEmpty else {
      throw TiebaCookieError(message: "Missing name or value")
    }
    // maxAge 直接映射为 maximumAge 字符串（旧包行为）；非有限值/超出安全整数在
    // 旧包同样抛错——Int64(_:) 对越界 Double 会陷阱，必须先钳住范围。
    guard maxAge.isFinite, abs(maxAge) <= 9_007_199_254_740_991 else {
      throw TiebaCookieError(message: "maxAge must be a finite safe integer number of seconds")
    }
    let trimmedDomain = domain.trimmingCharacters(in: .whitespacesAndNewlines)
    let effectiveDomain = trimmedDomain.isEmpty ? host : trimmedDomain
    guard isMatchingDomain(host: host, cookieDomain: effectiveDomain) else {
      throw TiebaCookieError(
        message:
          "Cookie URL host \(host) and domain \(effectiveDomain) mismatched. The cookie won't set correctly."
      )
    }

    var properties: [HTTPCookiePropertyKey: Any] = [
      .name: name,
      .value: value,
      .path: path.isEmpty ? "/" : path,
      .domain: effectiveDomain,
      // 持久化必需：没有 maximumAge/expires 的 cookie 是会话 cookie，进程重启即丢，
      // 冷启动恢复会拿不到 BDUSS/STOKEN。
      .maximumAge: String(Int64(maxAge.rounded(.towardZero))),
    ]
    if secure {
      properties[.secure] = true
    }
    if httpOnly {
      // Foundation 没有 HttpOnly 的具名 key，旧包同样用字符串键。
      properties[HTTPCookiePropertyKey("HttpOnly")] = true
    }
    guard let cookie = HTTPCookie(properties: properties) else {
      throw TiebaCookieError(message: "Unable to create cookie")
    }

    if webKit {
      // await 到 WebKit 的写入 completion：JS await 返回时 cookie 一定已落库
      // （登录轮询依赖写后读的可见性）。
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        WKWebsiteDataStore.default().httpCookieStore.setCookie(cookie) {
          continuation.resume()
        }
      }
    } else {
      HTTPCookieStorage.shared.setCookie(cookie)
    }
  }

  /// 读 cookie（name → value）。Foundation 走 cookies(for:)（Foundation 自己按
  /// 域/路径/secure 过滤）；WK 无"按 URL 过滤"的 API，只能全量读取后按域名筛
  /// ——与旧包一致（登录回调轮询依赖这条路径读到 WebView 写下的 HttpOnly 凭据）。
  static func get(urlString: String, webKit: Bool) async -> [String: String] {
    guard let url = URL(string: urlString) else { return [:] }
    if webKit {
      guard let host = url.host, !host.isEmpty else { return [:] }
      return await withCheckedContinuation {
        (continuation: CheckedContinuation<[String: String], Never>) in
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
          var result: [String: String] = [:]
          for cookie in cookies where Self.isMatchingDomain(host: host, cookieDomain: cookie.domain) {
            result[cookie.name] = cookie.value
          }
          continuation.resume(returning: result)
        }
      }
    }
    var result: [String: String] = [:]
    for cookie in HTTPCookieStorage.shared.cookies(for: url) ?? [] {
      result[cookie.name] = cookie.value
    }
    return result
  }

  /// 清空两个存储。removeData 的 completion 不带错误，本操作没有失败通道，
  /// 恒返回 true——JS 侧 `result !== false` 的校验语义保留。
  static func clearAll() async -> Bool {
    let storage = HTTPCookieStorage.shared
    storage.cookies?.forEach { storage.deleteCookie($0) }

    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      WKWebsiteDataStore.default().removeData(
        ofTypes: [WKWebsiteDataTypeCookies],
        modifiedSince: Date(timeIntervalSince1970: 0)
      ) {
        continuation.resume()
      }
    }
    return true
  }
}
