// ============================================================
// 统一 HTTP 通道（JSON / form / multipart / HTML / proto）
//
// 2026-09-13 合并：原 TiebaHttpClient 与 TiebaNativeClient 是两套 URLSession 栈
// （各自 ephemeral 配置、各自 continuation、各自 tasks+lock+cancel、各自一份
// host 白名单），注释自认"两处必须同步修改"。现在只有这一条通道：
//   - send(...)      raw 入口：不过滤状态码，原样回传 status/headers/body；
//   - sendData(...)  严格入口：host 白名单 + 非 2xx 抛 TiebaClientError.httpStatus，
//                    供 TiebaNativeClient 的 postForm/postProto 复用。
// 两个入口共用同一 session 与同一份 isAllowedHost。
//
// 取消：发送核心用 iOS 15+ 的 URLSession.data(for:)，Task 取消即取消在途请求，
// NSURLErrorCancelled 归一成 TiebaClientError.cancelled；手写 continuation +
// tasks 字典 + NSLock 的取消登记表已删除（取消先于注册的竞态随之消失）。
//
// 响应体编码：明文 UTF-8（非法字节用替换字符兜底），不是 base64。
// ============================================================
import Foundation

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
/// headers 的 key 已小写化且**不含 set-cookie**：CFNetwork 把多条 Set-Cookie
/// 折成 ", " 连接的单个值，混进字典后无法还原逐条；cookie 单独走 setCookies。
struct TiebaHttpRawResponse: Sendable {
  let status: Int
  let statusText: String
  let headers: [String: String]
  let setCookies: [String]
  let body: String
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

/// 跨线程单例：唯一存储属性是 URLSession（自身 thread-safe，Foundation 未在
/// 本 SDK 的公开接口标注 Sendable），@unchecked 是如实的"手动串行化"声明。
final class TiebaHttpClient: @unchecked Sendable {
  static let shared = TiebaHttpClient()

  private let session: URLSession

  private init() {
    // ephemeral：不落磁盘缓存，也不读写 HTTPCookieStorage.shared——Cookie 由
    // 调用方显式构造（Cookie 头 / WK 存储见 TiebaCookieStore），两侧不互相依赖。
    // 超时：每单 timeoutInterval 由调用方覆盖；资源级 180s 兜底慢网络下的大图
    // 上传（JS 时代的上传客户端超时 60s，30s 资源上限会误杀）。
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = 180
    // 不配 URLCache：API 全是 POST，HTTP 语义下本就不可缓存（缓存都在应用层 KV/SWR）；
    // 显式置 nil 与 Nuke 侧（TiebaNuke 的 urlCache = nil）同一口径，避免系统默认
    // 内存 URLCache 意外参与。
    // 不设 httpShouldUsePipelining：iOS 10 起系统忽略它，HTTP/2 多路复用自己生效。
    configuration.urlCache = nil
    configuration.waitsForConnectivity = false
    session = URLSession(configuration: configuration)
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
    guard Self.isAllowedHost(url) else {
      throw TiebaHttpError.disallowedHost
    }

    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = max(1, (timeoutMs ?? 15000) / 1000)
    for (key, value) in headers {
      request.setValue(value, forHTTPHeaderField: key)
    }
    if !formParts.isEmpty {
      let (data, contentType) = try buildMultipartBody(formParts)
      request.httpBody = data
      // 在 headers 之后 setValue：boundary 必须来自真实拼出的 body，覆盖调用方
      // 可能带的 Content-Type。
      request.setValue(contentType, forHTTPHeaderField: "Content-Type")
    } else if let body {
      request.httpBody = Data(body.utf8)
    }

    let (data, http) = try await perform(request)
    return TiebaHttpRawResponse(
      status: http.statusCode,
      statusText: HTTPURLResponse.localizedString(forStatusCode: http.statusCode),
      headers: Self.lowercasedHeaders(http),
      setCookies: Self.setCookieStrings(http, url: url),
      // 非法 UTF-8 字节用替换字符兜底（String(data:) 会返回 nil）：宁可有损文本
      // 也不要空响应体——JSON 解析失败会保留原文。
      body: String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    )
  }

  /// 严格入口（TiebaNativeClient 的 form/proto 通道）：非 2xx 抛
  /// TiebaClientError.httpStatus；host 白名单在发送核心里统一执行。
  func sendData(_ request: URLRequest) async throws -> Data {
    guard let url = request.url, Self.isAllowedHost(url) else {
      throw TiebaClientError.disallowedHost
    }
    let (data, http) = try await perform(request)
    guard (200..<300).contains(http.statusCode) else {
      throw TiebaClientError.httpStatus(http.statusCode)
    }
    return data
  }

  // MARK: - 发送核心

  private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    do {
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        throw TiebaClientError.invalidResponse
      }
      return (data, http)
    } catch is CancellationError {
      throw TiebaClientError.cancelled
    } catch let error as NSError where error.code == NSURLErrorCancelled {
      // Task 取消 / 在途取消统一归一，调用方按 TiebaClientError.cancelled 分支。
      throw TiebaClientError.cancelled
    }
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
        let mimeType = part.mimeType ?? "application/octet-stream"
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
