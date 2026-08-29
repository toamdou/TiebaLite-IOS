import Foundation

enum TiebaProtoError: LocalizedError {
  case invalidDescriptor
  case messageNotFound(String)
  case invalidPayload(String)
  case invalidWire(String)
  /// SwiftProtobuf 生成代码抛出的原始错误（typed throws 包装层，保留原文）
  case swiftProtobuf(String)

  var errorDescription: String? {
    switch self {
    case .invalidDescriptor:
      return "Invalid protobuf descriptor JSON"
    case .messageNotFound(let path):
      return "Protobuf message not found: \(path)"
    case .invalidPayload(let reason):
      return "Invalid protobuf payload: \(reason)"
    case .invalidWire(let reason):
      return "Invalid protobuf wire data: \(reason)"
    case .swiftProtobuf(let reason):
      return "SwiftProtobuf: \(reason)"
    }
  }
}

struct TiebaProtoField {
  let name: String
  let id: Int
  let type: String
  let repeated: Bool
  let protoName: String
}

struct TiebaProtoMessage {
  let path: String
  let fields: [Int: TiebaProtoField]
  /// name → field 索引。walk() 一次性构建（initialize 时），
  /// 投影器 project() 按名查字段直接用，不再每消息重建。
  let fieldByName: [String: TiebaProtoField]
  /// protoName → field 索引（仅当 protoName 非空且 ≠ name）。
  /// SwiftProtobuf 的 JSON 键可能用 proto 原名（如 "_client_type"），
  /// 解码时按此反查回 canonical name。
  let fieldByProtoName: [String: TiebaProtoField]
}

/// protos.json 描述符注册表（2026-08-29 角色变化）：
/// wire 解码/编码已由 SwiftProtobuf 生成代码接管（TiebaSwiftProtoCodec），
/// 本注册表仅保留描述符模型，供解码输出的 int64/enum 归一化按 schema
/// 还原旧解码器的输出形状（数字/枚举值），JS 映射层零改动。
/// 并发契约：initialize 一次性建表（启动期，先于任何请求），之后只读；
/// resolveCache/enumCache 由各自 NSLock 保护（热路径双锁）。Swift 6 下以
/// @unchecked Sendable 声明该不变量。
final class TiebaProtoRegistry: @unchecked Sendable {
  static let shared = TiebaProtoRegistry()

  private var root: [String: Any] = [:]
  private var messages: [String: TiebaProtoMessage] = [:]
  private var resolveCache: [String: ResolveResult] = [:]
  private var enumCache: [String: [String: Int]?] = [:]
  private let resolveLock = NSLock()
  private let enumLock = NSLock()

  private enum ResolveResult {
    case message(TiebaProtoMessage)
    case notFound
  }

  func initialize(json: String) throws(TiebaProtoError) {
    guard
      let data = json.data(using: .utf8),
      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      throw TiebaProtoError.invalidDescriptor
    }
    root = object
    messages = [:]
    resolveCache = [:]
    enumCache = [:]
    walk(object, path: "")
  }

  private func walk(_ object: [String: Any], path: String) {
    guard let nested = object["nested"] as? [String: Any] else { return }
    for (key, value) in nested {
      let fullPath = path.isEmpty ? key : "\(path).\(key)"
      guard let child = value as? [String: Any] else { continue }
      if let rawFields = child["fields"] as? [String: Any] {
        var fields: [Int: TiebaProtoField] = [:]
        for (fieldName, raw) in rawFields {
          guard
            let field = raw as? [String: Any],
            let id = field["id"] as? NSNumber
          else {
            continue
          }
          fields[id.intValue] = TiebaProtoField(
            name: fieldName,
            id: id.intValue,
            type: field["type"] as? String ?? "string",
            repeated: (field["rule"] as? String) == "repeated",
            protoName: field["protoName"] as? String ?? fieldName
          )
        }
        var fieldsByName: [String: TiebaProtoField] = [:]
        var fieldsByProtoName: [String: TiebaProtoField] = [:]
        for field in fields.values {
          fieldsByName[field.name] = field
          if !field.protoName.isEmpty && field.protoName != field.name {
            fieldsByProtoName[field.protoName] = field
          }
        }
        messages[fullPath] = TiebaProtoMessage(
          path: fullPath, fields: fields,
          fieldByName: fieldsByName, fieldByProtoName: fieldsByProtoName
        )
      }
      walk(child, path: fullPath)
    }
  }

  func message(path: String) throws(TiebaProtoError) -> TiebaProtoMessage {
    guard let message = messages[path] else {
      throw TiebaProtoError.messageNotFound(path)
    }
    return message
  }

  func resolveMessage(typeName: String, currentPath: String) throws(TiebaProtoError) -> TiebaProtoMessage {
    let trimmed = typeName.hasPrefix(".") ? String(typeName.dropFirst()) : typeName
    // Absolute paths are already unique; relative names depend on the namespace.
    let key = trimmed.contains(".") ? trimmed : "\(currentPath)|\(trimmed)"

    resolveLock.lock()
    let cached = resolveCache[key]
    resolveLock.unlock()
    if let cached {
      switch cached {
      case .message(let message):
        return message
      case .notFound:
        throw TiebaProtoError.messageNotFound(trimmed)
      }
    }

    do {
      let resolved: TiebaProtoMessage
      if trimmed.contains(".") {
        resolved = try message(path: trimmed)
      } else {
        resolved = try resolveRelative(typeName: trimmed, currentPath: currentPath)
      }
      cache(key, .message(resolved))
      return resolved
    } catch {
      // Negative results are cached too: string/bytes fields probe resolveMessage
      // on every length-delimited read, and repeating the namespace fallback scan
      // on every miss is the hottest decode path.
      cache(key, .notFound)
      throw error
    }
  }

  private func cache(_ key: String, _ result: ResolveResult) {
    resolveLock.lock()
    resolveCache[key] = result
    resolveLock.unlock()
  }

  private func resolveRelative(typeName: String, currentPath: String) throws(TiebaProtoError) -> TiebaProtoMessage {
    var namespace = currentPath
    while true {
      let candidate = namespace.isEmpty ? typeName : "\(namespace).\(typeName)"
      if let message = messages[candidate] {
        return message
      }
      guard let dot = namespace.lastIndex(of: ".") else { break }
      namespace = String(namespace[..<dot])
    }
    if let message = messages[typeName] {
      return message
    }
    throw TiebaProtoError.messageNotFound(typeName)
  }

  /// 枚举值表（名字 → 数值）。供 SwiftProtobuf JSON 输出的 enum 值名归一化。
  func resolveEnumValues(typeName: String, currentPath: String) throws(TiebaProtoError) -> [String: Int] {
    let trimmed = typeName.hasPrefix(".") ? String(typeName.dropFirst()) : typeName
    let key = trimmed.contains(".") ? trimmed : "\(currentPath)|\(trimmed)"

    enumLock.lock()
    let cached = enumCache[key]
    enumLock.unlock()
    if let cached {
      if let values = cached {
        return values
      }
      throw TiebaProtoError.messageNotFound(trimmed)
    }

    do {
      let values = try resolveEnumValuesUncached(typeName: trimmed, currentPath: currentPath)
      enumLock.lock()
      enumCache[key] = values
      enumLock.unlock()
      return values
    } catch {
      enumLock.lock()
      enumCache[key] = nil
      enumLock.unlock()
      throw error
    }
  }

  private func resolveEnumValuesUncached(typeName: String, currentPath: String) throws(TiebaProtoError) -> [String: Int] {
    var namespace = currentPath
    while true {
      let candidate = namespace.isEmpty ? typeName : "\(namespace).\(typeName)"
      if let values = enumValues(atPath: candidate) {
        return values
      }
      guard let dot = namespace.lastIndex(of: ".") else { break }
      namespace = String(namespace[..<dot])
    }
    if let values = enumValues(atPath: typeName) {
      return values
    }
    throw TiebaProtoError.messageNotFound(typeName)
  }

  private func enumValues(atPath path: String) -> [String: Int]? {
    guard let obj = nestedObject(atPath: path), let raw = obj["values"] as? [String: NSNumber] else {
      return nil
    }
    var values: [String: Int] = [:]
    for (name, number) in raw {
      values[name] = number.intValue
    }
    return values
  }

  private func nestedObject(atPath path: String) -> [String: Any]? {
    var node: [String: Any] = root
    let parts = path.split(separator: ".").map(String.init)
    guard !parts.isEmpty else { return nil }
    for (i, part) in parts.enumerated() {
      guard let nested = node["nested"] as? [String: Any], let child = nested[part] as? [String: Any] else {
        return nil
      }
      if i == parts.count - 1 {
        return child
      }
      node = child
    }
    return nil
  }
}
