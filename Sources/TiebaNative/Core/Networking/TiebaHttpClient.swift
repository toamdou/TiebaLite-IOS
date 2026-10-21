// 统一 HTTP 通道（JSON / form / multipart / HTML / proto）
//
// 2026-09-13 合并：原 TiebaHttpClient 与 TiebaNativeClient 是两套 URLSession 栈
// （各自 ephemeral 配置、各自 continuation、各自 tasks+lock+cancel、各自一份
// host 白名单），注释自认"两处必须同步修改"。现在只有这一条通道。
//
// 2026-10 [性能]：
//   - 同 key 在途请求合并：URL + method + body SHA256 + 全部显式 headers +
//     超时/网络策略。Cookie/Authorization 等鉴权头在 headers 哈希内，不会把
//     不同账号的请求合并；任一调用方取消只减少 waiter，最后一个 waiter 才
//     取消底层 Task，其他调用方仍能拿到同一结果。
//   - API session 关闭自动 Cookie 处理（Cookie 由调用方显式构造），复用同一
//     URLSession 让 HTTP/2 自行多路复用；提供 waitsForConnectivity 开关。
//   - 单例 NWPathMonitor 只提供快照，不按请求创建；超时按网络类型调整。
import Foundation
import CryptoKit
#if DEBUG
import os
private let tiebaNetworkPerfLog = Logger(subsystem: "com.tiebalite.app", category: "network-perf")
private let tiebaNetworkSignposter = OSSignposter(subsystem: "com.tiebalite.app", category: "network-perf")
#endif

/// raw 通道的错误（multipart 构造 / host 门禁）。strict 入口的状态码错误是
/// TiebaClientError.httpStatus（见 TiebaNativeClient）。
enum TiebaHttpError: LocalizedError {
  case invalidUrl
  case disallowedHost
  case invalidFormPart(String)
  case unsupportedFileUri(String)

  var errorDescription: String? {
    switch self {
    case .invalidUrl:
      return "Invalid request URL"
    case .disallowedHost:
      return "Request host is not allowed"
    case .invalidFormPart(let detail):
      return "Invalid multipart form part: \(detail)"
    case .unsupportedFileUri(let uri):
      return "Unsupported multipart file URI: \(uri)"
    }
  }
}

/// 原始响应。Sendable：跨 await 边界传回，不含非 Sendable 的 HTTPURLResponse。
///
/// bodyData 是唯一存储形态，body 是兼容旧调用点的按需 UTF-8 视图：新增调用点
/// 可直接把 bodyData 交给 JSONSerialization，避免 Data -> String -> Data 往返。
/// headers 的 key 已小写化且不含 set-cookie：CFNetwork 把多条 Set-Cookie 折成
/// ", " 连接的单个值，混进字典后无法还原逐条；cookie 单独走 setCookies。
struct TiebaHttpRawResponse: Sendable {
  let status: Int
  let statusText: String
  let headers: [String: String]
  let setCookies: [String]
  let bodyData: Data

  var body: String {
    String(data: bodyData, encoding: .utf8) ?? String(decoding: bodyData, as: UTF8.self)
  }
}

/// multipart 零件。自由字典先解成这个 Sendable 值结构再进 async 发送链
/// （Swift 6 region 检查不接受非 Sendable 值跨并发边界）。
struct TiebaHttpFormPart: Sendable {
  let name: String
  let value: String?
  let fileUri: String?
  let fileName: String?
  let mimeType: String?
}

private struct TiebaHttpTransportResponse: Sendable {
  let data: Data
  let statusCode: Int
  let headers: [String: String]
  let setCookies: [String]
}

private struct TiebaRequestKey: Hashable, Sendable {
  let method: String
  let url: String
  let headersHash: String
  let bodyHash: String
  let timeoutMillis: Int
  let cachePolicyRaw: Int
  let networkServiceTypeRaw: Int
  let waitsForConnectivity: Bool
  let requestFlags: UInt8
}

private struct TiebaInFlightEntry: Sendable {
  let id: UUID
  let task: Task<TiebaHttpTransportResponse, Error>
  var waiters: Int
}

/// URLSessionDataTask 的取消把手。Task 取消时只做一次 cancel，不跨 actor 传递
/// Foundation 任务对象；手工串行化由 NSLock 保证。
private final class TiebaURLSessionTaskBox: @unchecked Sendable {
  private let lock = NSLock()
  private var task: URLSessionDataTask?
  private var cancellationRequested = false

  func install(_ task: URLSessionDataTask) {
    lock.lock()
    self.task = task
    let shouldCancel = cancellationRequested
    lock.unlock()
    if shouldCancel {
      task.cancel()
    }
  }

  func cancel() {
    lock.lock()
    cancellationRequested = true
    let task = self.task
    lock.unlock()
    task?.cancel()
  }
}

/// 等一个共享 Task 的值，同时让当前 waiter 的取消立即返回。共享 Task 本身
/// 不随单个 waiter 取消；它由 TiebaHttpClient 的 waiter 计数决定是否取消。
private final class TiebaTaskValueWaiter<Success: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Success, Error>?
  private var storedResult: Result<Success, Error>?

  func install(_ continuation: CheckedContinuation<Success, Error>) {
    lock.lock()
    if let result = storedResult {
      lock.unlock()
      continuation.resume(with: result)
      return
    }
    self.continuation = continuation
    lock.unlock()
  }

  func resume(with result: Result<Success, Error>) {
    lock.lock()
    if storedResult != nil {
      lock.unlock()
      return
    }
    storedResult = result
    let continuation = self.continuation
    self.continuation = nil
    lock.unlock()
    continuation?.resume(with: result)
  }
}

/// 跨线程单例：唯一可变容器全部由 TiebaMutex 串行化；URLSession 自身 thread-safe。
final class TiebaHttpClient: @unchecked Sendable {
  static let shared = TiebaHttpClient()

  private let waitingSession: URLSession
  private let immediateSession: URLSession
  private let waitsForConnectivityEnabled = TiebaMutex<Bool>(false)
  private let inFlight = TiebaMutex<[TiebaRequestKey: TiebaInFlightEntry]>([:])

  private init() {
    // ephemeral 且显式清空 cookie storage / 禁止自动 cookie：
    // Cookie 由调用方按协议显式构造（Cookie 头），两侧不互相依赖。
    // 同一个 session 服务所有请求，HTTP/2 由系统按 ALPN 自动多路复用。
    let waitingConfiguration = Self.makeSessionConfiguration(waitsForConnectivity: true)
    let immediateConfiguration = Self.makeSessionConfiguration(waitsForConnectivity: false)
    waitingSession = URLSession(configuration: waitingConfiguration)
    immediateSession = URLSession(configuration: immediateConfiguration)
    waitingSession.sessionDescription = "TiebaNative API (waits for connectivity)"
    immediateSession.sessionDescription = "TiebaNative API (immediate)"
  }

  /// waitsForConnectivity 是 session 级选项；预建两条 session，切换只改读指针，
  /// 不在请求途中重建 session，也不打断已有连接池/在途请求。
  static func setWaitsForConnectivity(_ enabled: Bool) {
    shared.waitsForConnectivityEnabled.withLock { $0 = enabled }
  }

  private static func makeSessionConfiguration(waitsForConnectivity: Bool) -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = 180
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.httpCookieAcceptPolicy = .never
    configuration.waitsForConnectivity = waitsForConnectivity
    // iOS 10 起普通 HTTP 会忽略 pipelining 开关；保留无副作用，HTTP/2 复用由
    // 系统按 TLS ALPN 与单连接多流自动完成，httpMaximumConnectionsPerHost 仅兜底 H1。
    configuration.httpShouldUsePipelining = true
    configuration.httpMaximumConnectionsPerHost = 6
    return configuration
  }

  /// raw 入口：发一次请求并原样回传响应（不过滤状态码）。formParts 非空即
  /// multipart（文件按 URI 读盘、boundary 在这里构造）；否则 body 按 UTF-8
  /// 字符串直传。二者互斥——调用方保证同一请求只有一种体。
  ///
  /// requestId 参数已无行为（旧的取消登记表键）：取消现在由 Task 取消传播。
  /// 保留参数是为了不改动本文件之外的既有调用点。
  func send(
    urlString: String,
    method: String,
    headers: [String: String],
    body: String?,
    formParts: [TiebaHttpFormPart],
    requestId _: String,
    timeoutMs: Double?
  ) async throws -> TiebaHttpRawResponse {
    guard let url = URL(string: urlString) else {
      throw TiebaHttpError.invalidUrl
    }
    guard tiebaIsValidUrl(urlString, validSchemes: ["http": true, "https": true]) else {
      throw TiebaHttpError.invalidUrl
    }
    guard Self.isAllowedHost(url) else {
      throw TiebaHttpError.disallowedHost
    }

    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = max(1, (timeoutMs ?? 15000) / 1000)
    for (key, value) in headers {
      request.setValue(value, forHTTPHeaderField: key)
    }
    if formParts.isEmpty == false {
      let (data, contentType) = try buildMultipartBody(formParts)
      request.httpBody = data
      request.setValue(contentType, forHTTPHeaderField: "Content-Type")
    } else if let body {
      request.httpBody = Data(body.utf8)
    }

    let response = try await perform(request)
    return TiebaHttpRawResponse(
      status: response.statusCode,
      statusText: HTTPURLResponse.localizedString(forStatusCode: response.statusCode),
      headers: response.headers,
      setCookies: response.setCookies,
      bodyData: response.data
    )
  }

  /// 严格入口（TiebaNativeClient 的 form/proto 通道）：非 2xx 抛
  /// TiebaClientError.httpStatus；host 白名单在发送核心里统一执行。
  func sendData(_ request: URLRequest) async throws -> Data {
    guard let url = request.url, Self.isAllowedHost(url) else {
      throw TiebaClientError.disallowedHost
    }
    let response = try await perform(request)
    guard (200..<300).contains(response.statusCode) else {
      throw TiebaClientError.httpStatus(response.statusCode)
    }
    return response.data
  }

  // MARK: - 发送核心

  private func perform(_ originalRequest: URLRequest) async throws -> TiebaHttpTransportResponse {
    var request = originalRequest
    let waitsForConnectivity = waitsForConnectivityEnabled.withLock { $0 }
    let baseTimeout = request.timeoutInterval > 0 ? request.timeoutInterval : 15
    request.timeoutInterval = TiebaNetworkMonitor.shared.adjustedTimeout(
      base: baseTimeout,
      maximum: 180
    )
    // API 均为用户可见交互：交给系统 responsiveData 调度提示；真正任务优先级
    // 由下面的 URLSessionDataTask.priority 按当前 Swift Task 优先级设置。
    request.networkServiceType = .responsiveData

    do {
      if let key = Self.coalescingKey(for: request, waitsForConnectivity: waitsForConnectivity) {
        return try await coalescedPerform(
          request: request,
          key: key,
          waitsForConnectivity: waitsForConnectivity
        )
      }
      return try await transport(
        request,
        session: waitsForConnectivity ? waitingSession : immediateSession
      )
    } catch let error as TiebaClientError {
      throw error
    } catch is CancellationError {
      throw TiebaClientError.cancelled
    } catch let error as NSError where error.code == NSURLErrorCancelled {
      throw TiebaClientError.cancelled
    }
  }

  private func coalescedPerform(
    request: URLRequest,
    key: TiebaRequestKey,
    waitsForConnectivity: Bool
  ) async throws -> TiebaHttpTransportResponse {
    let acquisition = inFlight.withLock { table -> (entry: TiebaInFlightEntry, isDedupeHit: Bool) in
      if var existing = table[key] {
        existing.waiters += 1
        table[key] = existing
        return (existing, true)
      }
      let id = UUID()
      let task = Task<TiebaHttpTransportResponse, Error> {
        defer {
          self.finishInFlight(key: key, id: id)
        }
        let session = waitsForConnectivity ? self.waitingSession : self.immediateSession
        return try await self.transport(request, session: session)
      }
      let entry = TiebaInFlightEntry(id: id, task: task, waiters: 1)
      table[key] = entry
      return (entry, false)
    }

#if DEBUG
    if acquisition.isDedupeHit {
      let path = request.url?.path ?? ""
      tiebaNetworkPerfLog.debug("request dedupe hit path=\(path, privacy: .public)")
    }
#endif

    defer {
      releaseWaiter(key: key, id: acquisition.entry.id)
    }
    return try await Self.awaitShared(acquisition.entry.task)
  }

  private func finishInFlight(key: TiebaRequestKey, id: UUID) {
    inFlight.withLock { table in
      if table[key]?.id == id {
        table.removeValue(forKey: key)
      }
    }
  }

  private func releaseWaiter(key: TiebaRequestKey, id: UUID) {
    var taskToCancel: Task<TiebaHttpTransportResponse, Error>?
    inFlight.withLock { table in
      guard var entry = table[key], entry.id == id else { return }
      entry.waiters -= 1
      if entry.waiters <= 0 {
        table.removeValue(forKey: key)
        taskToCancel = entry.task
      } else {
        table[key] = entry
      }
    }
    // 最后一个等待者离开才取消底层网络；有别的 waiter 时共享 Task 保留。
    taskToCancel?.cancel()
  }

  private static func awaitShared(
    _ task: Task<TiebaHttpTransportResponse, Error>
  ) async throws -> TiebaHttpTransportResponse {
    let waiter = TiebaTaskValueWaiter<TiebaHttpTransportResponse>()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<TiebaHttpTransportResponse, Error>) in
        waiter.install(continuation)
        Task {
          do {
            let value = try await task.value
            waiter.resume(with: .success(value))
          } catch {
            waiter.resume(with: .failure(error))
          }
        }
      }
    } onCancel: {
      waiter.resume(with: .failure(CancellationError()))
    }
  }

  private static func coalescingKey(
    for request: URLRequest,
    waitsForConnectivity: Bool
  ) -> TiebaRequestKey? {
    // body stream 无法在不消费流的前提下做稳定哈希；这类请求不参与合并。
    guard request.httpBodyStream == nil else { return nil }
    let headers = request.allHTTPHeaderFields ?? [:]
    let canonicalHeaders = headers
      .map { (key: $0.key.lowercased(), value: $0.value) }
      .sorted { $0.key < $1.key }
      .map { "\($0.key):\($0.value)" }
      .joined(separator: "\n")
    let body = request.httpBody ?? Data()
    return TiebaRequestKey(
      method: (request.httpMethod ?? "GET").uppercased(),
      url: request.url?.absoluteString ?? "",
      headersHash: sha256Hex(Data(canonicalHeaders.utf8)),
      bodyHash: sha256Hex(body),
      timeoutMillis: Int((request.timeoutInterval * 1000).rounded()),
      cachePolicyRaw: Int(request.cachePolicy.rawValue),
      networkServiceTypeRaw: Int(request.networkServiceType.rawValue),
      waitsForConnectivity: waitsForConnectivity,
      requestFlags: requestFlags(request)
    )
  }

  private static func requestFlags(_ request: URLRequest) -> UInt8 {
    var flags: UInt8 = 0
    if request.allowsCellularAccess { flags |= 1 << 0 }
    if request.allowsExpensiveNetworkAccess { flags |= 1 << 1 }
    if request.allowsConstrainedNetworkAccess { flags |= 1 << 2 }
    if request.httpShouldHandleCookies { flags |= 1 << 3 }
    return flags
  }

  private static func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private func transport(
    _ request: URLRequest,
    session: URLSession
  ) async throws -> TiebaHttpTransportResponse {
#if DEBUG
    let started = DispatchTime.now().uptimeNanoseconds
    let signpostID = tiebaNetworkSignposter.makeSignpostID()
    let interval = tiebaNetworkSignposter.beginInterval("TiebaHTTPRequest", id: signpostID)
    defer {
      tiebaNetworkSignposter.endInterval("TiebaHTTPRequest", interval)
    }
#endif

    let taskPriority = Self.urlSessionTaskPriority(Task.currentPriority)
    let cancellationBox = TiebaURLSessionTaskBox()
    let response = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<TiebaHttpTransportResponse, Error>) in
        let task = session.dataTask(with: request) { data, urlResponse, error in
          if let error {
            continuation.resume(throwing: error)
            return
          }
          guard let http = urlResponse as? HTTPURLResponse else {
            continuation.resume(throwing: TiebaClientError.invalidResponse)
            return
          }
          continuation.resume(returning: TiebaHttpTransportResponse(
            data: data ?? Data(),
            statusCode: http.statusCode,
            headers: Self.lowercasedHeaders(http),
            setCookies: Self.setCookieStrings(http, url: request.url)
          ))
        }
        task.priority = taskPriority
        cancellationBox.install(task)
        task.resume()
      }
    } onCancel: {
      cancellationBox.cancel()
    }

#if DEBUG
    let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
    if elapsedMs >= 1500 {
      let path = request.url?.path ?? ""
      tiebaNetworkPerfLog.debug(
        "slow http request path=\(path, privacy: .public) ms=\(elapsedMs, privacy: .public)"
      )
    }
#endif
    return response
  }

  private static func urlSessionTaskPriority(_ priority: TaskPriority) -> Float {
    if priority >= .high { return 0.75 }
    if priority >= .medium { return 0.5 }
    return 0.25
  }

  /// host 白名单（全仓唯一一份）：url 可能来自 JS 注入的请求描述，不设门禁
  /// 就能把带 Cookie 的请求改道第三方；白名单外一律 fail closed，仅放行
  /// *baidu.com 与 loopback 调试地址。
  private static func isAllowedHost(_ url: URL) -> Bool {
    guard let host = url.host else { return false }
    let lower = host.lowercased()
    if lower == "localhost" || lower == "127.0.0.1" || lower == "::1" {
      return true
    }
    return lower == "baidu.com" || lower.hasSuffix(".baidu.com")
  }

  // MARK: - 响应头

  /// 全量头小写化；set-cookie 剔除（见 TiebaHttpRawResponse 注释）。
  private static func lowercasedHeaders(_ response: HTTPURLResponse) -> [String: String] {
    var out: [String: String] = [:]
    for (key, value) in response.allHeaderFields {
      guard let key = key as? String else { continue }
      let lower = key.lowercased()
      if lower == "set-cookie" { continue }
      out[lower] = String(describing: value)
    }
    return out
  }

  /// 逐条还原 Set-Cookie。CFNetwork 在 allHeaderFields 与
  /// value(forHTTPHeaderField:) 里都把多条折成 ", " 连接的单个值；按逗号硬切会
  /// 切碎 Expires 里的日期（"Expires=Wed, 21 Oct ..."）。Foundation 的 cookie
  /// 解析器本来就是干这个的，用它还原成逐条后拼回 name=value。
  private static func setCookieStrings(_ response: HTTPURLResponse, url: URL?) -> [String] {
    // value(forHTTPHeaderField:) 大小写不敏感；补一层 allHeaderFields 扫描是因为
    // 个别 CFNetwork 版本对重复头只在字典里保留值（字典键大小写随服务端）。
    var raw: String?
    if let direct = response.value(forHTTPHeaderField: "Set-Cookie") {
      raw = direct
    } else {
      for (key, value) in response.allHeaderFields where (key as? String)?.lowercased() == "set-cookie" {
        raw = String(describing: value)
      }
    }
    guard let raw else { return [] }
    guard let url else { return [raw] }
    let parsed = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": raw], for: url)
    if parsed.isEmpty { return [raw] }
    return parsed.map { "\($0.name)=\($0.value)" }
  }

  // MARK: - multipart

  /// 拼 multipart 体：formParts 的文件部件在这里读盘。
  /// 调用方在后台任务上调用，Data(contentsOf:) 不占主线程。
  private func buildMultipartBody(_ parts: [TiebaHttpFormPart]) throws -> (Data, String) {
    let boundary = "TiebaNative-\(UUID().uuidString)"
    let crlf = "\r\n"
    var body = Data()

    func append(_ string: String) {
      body.append(Data(string.utf8))
    }

    for part in parts {
      guard !part.name.isEmpty else {
        throw TiebaHttpError.invalidFormPart("missing name")
      }
      append("--\(boundary)\(crlf)")
      if let fileUri = part.fileUri, !fileUri.isEmpty {
        let fileName = part.fileName ?? "file"
        // 调用方显式给了就用（显式优先），否则按文件名扩展名查 TiebaMimeTypes 全表。
        // 不让系统 UTType 单独决定：服务端/分享进来的冷门扩展名（sdc / kpr / pcf.Z …）
        // 它查不到，而 multipart 的 Content-Type 一旦错，接收侧就按错误类型处理。
        let mimeType = part.mimeType ?? Self.mimeType(forFileName: fileName)
        append("Content-Disposition: form-data; name=\"\(part.name)\"; filename=\"\(fileName)\"\(crlf)")
        append("Content-Type: \(mimeType)\(crlf)\(crlf)")
        body.append(try readFileData(fileUri))
      } else {
        append("Content-Disposition: form-data; name=\"\(part.name)\"\(crlf)\(crlf)")
        append(part.value ?? "")
      }
      append(crlf)
    }
    append("--\(boundary)--\(crlf)")
    return (body, "multipart/form-data; boundary=\(boundary)")
  }

  /// 文件部件的 Content-Type：按扩展名查 TiebaMimeTypes（304 条全表，内部自带 UTType 兜底），
  /// 表里也没有才退回 application/octet-stream。扩展名统一小写后再查：服务端给的
  /// 文件名常是 IMG_0001.JPG 这种大写形态，而表是大小写敏感的。
  private static func mimeType(forFileName fileName: String) -> String {
    let fileExtension = URL(fileURLWithPath: fileName).pathExtension.lowercased()
    guard !fileExtension.isEmpty, let mime = TiebaMimeTypes.mimeType(forExtension: fileExtension) else {
      return "application/octet-stream"
    }
    return mime
  }

  /// 只支持本地文件（file:// 或绝对路径）——当前 multipart 调用点是头像上传。
  /// http(s) 的文件部件不做静默支持：抛错比悄悄多一次网络请求更好定位。
  private func readFileData(_ uriString: String) throws -> Data {
    if uriString.hasPrefix("http://") || uriString.hasPrefix("https://") {
      throw TiebaHttpError.unsupportedFileUri(uriString)
    }
    let url: URL
    if uriString.hasPrefix("file://") {
      if let parsed = URL(string: uriString) {
        url = parsed
      } else {
        // 路径含空格/中文时 URL(string:) 可能返回 nil（RFC 3986 不认裸空格）：
        // 去掉 scheme 后按文件路径构造（URL(fileURLWithPath:) 会做百分号编码）。
        url = URL(fileURLWithPath: String(uriString.dropFirst("file://".count)))
      }
    } else if uriString.hasPrefix("/") {
      url = URL(fileURLWithPath: uriString)
    } else {
      throw TiebaHttpError.unsupportedFileUri(uriString)
    }
    do {
      return try Data(contentsOf: url)
    } catch {
      throw TiebaHttpError.invalidFormPart(
        "cannot read file \(url.lastPathComponent): \(error.localizedDescription)"
      )
    }
  }
}
