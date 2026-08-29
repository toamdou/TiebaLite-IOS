import Foundation
import CommonCrypto

enum TiebaClientError: LocalizedError {
  case invalidUrl
  case invalidMultipart
  case httpStatus(Int)
  case cancelled
  case invalidResponse
  case disallowedHost

  var errorDescription: String? {
    switch self {
    case .invalidUrl:
      return "Invalid request URL"
    case .invalidMultipart:
      return "Failed to build multipart body"
    case .httpStatus(let status):
      return "HTTP \(status)"
    case .cancelled:
      return "Request cancelled"
    case .invalidResponse:
      return "Invalid response data"
    case .disallowedHost:
      return "Request host is not allowed"
    }
  }
}

enum TiebaSigner {
  static let secret = "tiebaclient!!!"
  static let boundary = "--------7da3d81520810*"

  static func md5Hex(_ input: String) -> String {
    let data = Data(input.utf8)
    var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
    _ = data.withUnsafeBytes { bytes in
      CC_MD5(bytes.baseAddress, CC_LONG(data.count), &digest)
    }
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  static func signFields(_ fields: [[String]], secret: String = secret) -> String {
    let sorted = fields.sorted { $0[0] < $1[0] }
    let raw = sorted.map { "\($0[0])=\($0[1])" }.joined()
    return md5Hex(raw + secret).lowercased()
  }

  static func signParams(_ params: [String: String], secret: String = secret) -> String {
    let sorted = params.sorted { $0.key < $1.key }
    let raw = sorted.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
    return md5Hex(raw + secret).lowercased()
  }

  static func buildMultipartBody(
    formFields: [[String]],
    protoData: Data,
    skipSign: Bool
  ) throws -> Data {
    let boundary = TiebaSigner.boundary
    var body = Data()

    let allFields: [[String]]
    if skipSign {
      allFields = formFields
    } else {
      let sign = TiebaSigner.signFields(formFields)
      allFields = formFields + [["sign", sign]]
    }

    func append(_ string: String) {
      body.append(Data(string.utf8))
    }

    for field in allFields {
      guard field.count == 2 else {
        throw TiebaClientError.invalidMultipart
      }
      append("--\(boundary)\r\n")
      append("Content-Disposition: form-data; name=\"\(field[0])\"\r\n\r\n")
      append(field[1])
      append("\r\n")
    }

    append("--\(boundary)\r\n")
    append("Content-Disposition: form-data; name=\"data\"; filename=\"file\"\r\n\r\n")
    body.append(protoData)
    append("\r\n--\(boundary)--\r\n")
    return body
  }
}

/// 跨线程单例：`tasks` 字典由 `lock` 串行化，URLSession 自身 thread-safe。
/// Swift 6 下以 @unchecked Sendable 声明该不变量（所有共享状态有锁保护）。
final class TiebaNativeClient: @unchecked Sendable {
  static let shared = TiebaNativeClient()

  private let session: URLSession
  private var tasks: [String: URLSessionDataTask] = [:]
  private let lock = NSLock()

  private init() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 15
    configuration.timeoutIntervalForResource = 30
    configuration.httpShouldUsePipelining = true
    configuration.waitsForConnectivity = false
    session = URLSession(configuration: configuration)
  }

  func cancel(requestId: String) {
    lock.lock()
    let task = tasks.removeValue(forKey: requestId)
    lock.unlock()
    task?.cancel()
  }

  func postForm(
    urlString: String,
    fields: [String: String],
    includeCommon: Bool,
    includeSign: Bool,
    requestId: String,
    timeout: Double
  ) async throws -> [String: Any] {
    let headers = [
      "User-Agent": "tieba/12.41.7.1",
      "Accept-Language": "zh-CN,zh;q=0.9",
      "Accept": "application/json",
      "Accept-Encoding": "gzip",
      "Connection": "keep-alive",
      "Charset": "UTF-8",
      "Content-Type": "application/x-www-form-urlencoded"
    ]
    var body = fields
    if includeCommon {
      body = TiebaBackgroundSnapshot.shared.commonParams().merging(body) { _, new in new }
    }
    if includeSign {
      body["sign"] = TiebaSigner.signParams(body)
    }
    let formAllowed = CharacterSet(
      charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )
    let encoded = body
      .sorted { $0.key < $1.key }
      .map {
        "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? $0.value)"
      }
      .joined(separator: "&")
    guard let data = encoded.data(using: .utf8), let url = URL(string: urlString) else {
      throw TiebaClientError.invalidUrl
    }
    guard isAllowedHost(url) else {
      throw TiebaClientError.disallowedHost
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = timeout
    request.httpBody = data
    apply(headers, to: &request)
    request.setValue(buildCookieHeader(), forHTTPHeaderField: "Cookie")

    let responseData = try await perform(request, requestId: requestId)
    guard
      let object = try JSONSerialization.jsonObject(with: responseData) as? [String: Any]
    else {
      throw TiebaClientError.invalidResponse
    }
    return object
  }

  func postProto(
    urlString: String,
    headers: [String: String],
    formFields: [[String]],
    protoData: Data,
    skipSign: Bool,
    requestId: String,
    timeout: Double
  ) async throws -> Data {
    guard let url = URL(string: urlString) else {
      throw TiebaClientError.invalidUrl
    }
    guard isAllowedHost(url) else {
      throw TiebaClientError.disallowedHost
    }
    let body = try TiebaSigner.buildMultipartBody(
      formFields: formFields,
      protoData: protoData,
      skipSign: skipSign
    )
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = timeout
    request.httpBody = body
    request.setValue("multipart/form-data; boundary=\(TiebaSigner.boundary)", forHTTPHeaderField: "Content-Type")
    // URLSession transparently decompresses gzip responses when advertised.
    // Headers passed in from JS may override this (e.g. "gzip, deflate").
    request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
    apply(headers, to: &request)
    return try await perform(request, requestId: requestId)
  }

  /// Defense-in-depth: `postProto` builds the request from a URL/headers
  /// supplied by JS, so an injected JS payload could otherwise steer the
  /// native client at any host (e.g. exfiltrate a signed request to a
  /// third-party endpoint). Only Baidu hosts (anything under *.baidu.com) and
  /// loopback addresses for local debugging are allowed; anything else fails
  /// closed. `postForm` passes through the same gate even though its callers
  /// are native-only. This is a host allow-list only — TLS cert pinning is
  /// intentionally out of scope for this round.
  private func isAllowedHost(_ url: URL) -> Bool {
    guard let host = url.host else { return false }
    let lower = host.lowercased()
    if lower == "localhost" || lower == "127.0.0.1" || lower == "::1" {
      return true
    }
    return lower == "baidu.com" || lower.hasSuffix(".baidu.com")
  }

  private func apply(_ headers: [String: String], to request: inout URLRequest) {
    for (key, value) in headers {
      request.setValue(value, forHTTPHeaderField: key)
    }
  }

  private func perform(_ request: URLRequest, requestId: String) async throws -> Data {
    // 取消传播：调用方 Task 取消（JS AbortController / 组件卸载）时取消在途
    // URLSessionDataTask 并清掉字典条目，而不是让请求跑满超时才释放。
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let task = session.dataTask(with: request) { data, response, error in
          self.lock.lock()
          self.tasks.removeValue(forKey: requestId)
          self.lock.unlock()

          if let error = error {
            if (error as NSError).code == NSURLErrorCancelled {
              continuation.resume(throwing: TiebaClientError.cancelled)
            } else {
              continuation.resume(throwing: error)
            }
            return
          }
          guard
            let response = response as? HTTPURLResponse,
            let data = data
          else {
            continuation.resume(throwing: TiebaClientError.invalidResponse)
            return
          }
          guard (200..<300).contains(response.statusCode) else {
            continuation.resume(throwing: TiebaClientError.httpStatus(response.statusCode))
            return
          }
          continuation.resume(returning: data)
        }

        lock.lock()
        tasks[requestId] = task
        lock.unlock()
        task.resume()
      }
    } onCancel: {
      // 与 continuation 体并发执行：锁内取出任务并取消（取消先于注册发生时
      // 此处取到 nil，任务随后照常启动——resume 对被取消的 Task 无害，请求
      // 完成时 continuation 照常结算，调用方已取消则结果被丢弃）。
      lock.lock()
      let task = tasks.removeValue(forKey: requestId)
      lock.unlock()
      task?.cancel()
    }
  }

  private func buildCookieHeader() -> String {
    let snapshot = TiebaBackgroundSnapshot.shared
    var parts: [String] = []
    if !snapshot.bduss.isEmpty {
      parts.append("BDUSS=\(snapshot.bduss)")
    }
    if !snapshot.stoken.isEmpty {
      parts.append("STOKEN=\(snapshot.stoken)")
    }
    return parts.joined(separator: "; ")
  }
}
