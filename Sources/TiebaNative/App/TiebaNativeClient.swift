// 贴吧 v12 协议的表单 / proto 门面（签名、multipart、Cookie 头在这里构造）。
//
// 2026-09-13：URLSession 栈已并入 TiebaHttpClient（唯一 session + 唯一 host
// 白名单 + async data(for:) 取消传播）。本文件只保留协议相关部分：错误类型、
// 签名器、请求装配；postForm/postProto 是 TiebaHttpClient.sendData 的薄封装。
import Foundation
import CryptoKit

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

  /// MD5（协议要求，算法无法更换）：走 CryptoKit `Insecure.MD5`
  ///（CommonCrypto 的 CC_MD5 自 iOS 13 起废弃，SDK 会报 deprecation）。
  static func md5Hex(_ input: String) -> String {
    Insecure.MD5.hash(data: Data(input.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
  }

  static func signFields(_ fields: [[String]], secret: String = secret) -> String {
    let sorted = fields.sorted { $0[0] < $1[0] }
    let raw = sorted.map { "\($0[0])=\($0[1])" }.joined()
    return md5Hex(raw + secret).lowercased()
  }

  /// 参数签名：与前台 src/services/api/sign.ts 的 signParams 逐字节一致——
  /// **无分隔符**拼接（key1=value1key2=value2…）。2026-08-27 JS 侧已修
  /// （join('&') 与服务端不符恒错，登录 110001 根因；Python 参考实现对照
  /// 验证）；原生此函数当时漏修，导致后台 BGTask（c/s/msg 通知轮询、
  /// c/c/forum/msign 自动签到）全部带错签名：服务端 HTTP 200 + error_code
  /// 静默拒绝、无日志（2026-08-31 核实修复）。
  static func signParams(_ params: [String: String], secret: String = secret) -> String {
    let sorted = params.sorted { $0.key < $1.key }
    let raw = sorted.map { "\($0.key)=\($0.value)" }.joined()
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

/// 表单 / proto 门面。无状态（请求装配都是局部变量），Sendable 如实声明。
final class TiebaNativeClient: Sendable {
  static let shared = TiebaNativeClient()

  private init() {}

  /// requestId：历史取消登记表的键；发送走 TiebaHttpClient.sendData（async
  /// data(for:)，Task 取消即取消请求），该参数保留只为不改动既有调用点。
  func postForm(
    urlString: String,
    fields: [String: String],
    includeCommon: Bool,
    includeSign: Bool,
    requestId _: String,
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
    let encoded = body
      .sorted { $0.key < $1.key }
      .map { "\($0.key)=\(TiebaRoutePath.segment($0.value))" }
      .joined(separator: "&")
    guard let data = encoded.data(using: .utf8), let url = URL(string: urlString) else {
      throw TiebaClientError.invalidUrl
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = timeout
    request.httpBody = data
    apply(headers, to: &request)
    request.setValue(buildCookieHeader(), forHTTPHeaderField: "Cookie")

    let responseData = try await TiebaHttpClient.shared.sendData(request)
    guard
      let object = try JSONSerialization.jsonObject(with: responseData) as? [String: Any]
    else {
      throw TiebaClientError.invalidResponse
    }
    return object
  }

  /// requestId：同 postForm（历史参数，无行为）。
  func postProto(
    urlString: String,
    headers: [String: String],
    formFields: [[String]],
    protoData: Data,
    skipSign: Bool,
    requestId _: String,
    timeout: Double
  ) async throws -> Data {
    guard let url = URL(string: urlString) else {
      throw TiebaClientError.invalidUrl
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
    return try await TiebaHttpClient.shared.sendData(request)
  }

  private func apply(_ headers: [String: String], to request: inout URLRequest) {
    for (key, value) in headers {
      request.setValue(value, forHTTPHeaderField: key)
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
