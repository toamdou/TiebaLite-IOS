import Foundation

/// proto 传输管线的公开门面：Nitro 混合体（tieba-proto-nitro pod）经此复用
/// 与 Expo 桥通道（TiebaNativeModule.protoPost）完全一致的
/// 客户端（含 host 白名单/签名/Cookie）→ 解码 → 白名单投影 链路。
/// 本类型在 tieba-native 模块内实现，故可直接引用各 internal 类型。
public enum TiebaProtoPipeline {
  public static func post(
    url: String,
    headers: [String: String],
    formFields: [[String]],
    body: Data,
    skipSign: Bool,
    responseType: String,
    requestId: String,
    timeoutMs: Double
  ) async throws -> String {
    let responseData = try await TiebaNativeClient.shared.postProto(
      urlString: url,
      headers: headers,
      formFields: formFields,
      protoData: body,
      skipSign: skipSign,
      requestId: requestId,
      timeout: timeoutMs
    )
    // 与 Expo 通道同构：后台队列 SwiftProtobuf 解码（全字段，无投影）后序列化为 JSON。
    // 解码+序列化都在 detached 内完成，跨界只传 Sendable 的 String。
    return try await Task.detached(priority: .userInitiated) {
      let decoded = try TiebaSwiftProto.decode(messagePath: responseType, bytes: responseData)
      let jsonData = try JSONSerialization.data(withJSONObject: decoded)
      return String(data: jsonData, encoding: .utf8) ?? "{}"
    }.value
  }
}
