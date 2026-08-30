import Foundation

/// A lossless, product-disabled document engine for the shared settings file.
/// It deliberately does not acquire a lease or write a file; the future writer
/// will use this value only after it has obtained the settings lease.
public struct SettingsDocument: Sendable {
  private static let maxBytes = 8 * 1024 * 1024

  public enum Error: Swift.Error, Equatable, Sendable {
    case nonObject
    case tooLarge
    case invalidSchemaVersion
    case invalidEnvelope
    case unsupportedSchema(Int)
    case invalidRevision
    case revisionOverflow
    case reservedFieldPatch(String)
    case conflict([String])
    case invalidSettings
  }

  public let schemaVersion: Int
  public let revision: UInt64
  public let typed: AppSettings

  private let rawFields: [String: String]

  private init(
    schemaVersion: Int, revision: UInt64, typed: AppSettings, rawFields: [String: String]
  ) {
    self.schemaVersion = schemaVersion
    self.revision = revision
    self.typed = typed
    self.rawFields = rawFields
  }

  /// The canonical raw JSON object. Unknown top-level and nested values are
  /// retained because patches operate on this raw object, not AppSettings.
  public var rawJSON: Data { Self.encode(fields: rawFields) }

  /// Returns a full desired document by cloning every raw field and replacing
  /// one top-level value token. Callers use this rather than constructing a
  /// partial document, so unknown values remain present during three-way merge.
  public func replacingRawValue(_ value: Data?, forKey key: String) throws -> SettingsDocument {
    guard key != "schemaVersion", key != "revision" else {
      throw Error.reservedFieldPatch(key)
    }
    var fields = rawFields
    if let value {
      guard let text = String(data: value, encoding: .utf8) else { throw Error.invalidSettings }
      let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !token.isEmpty,
        (try? JSONSerialization.jsonObject(
          with: Data(token.utf8), options: [.fragmentsAllowed])) != nil
      else { throw Error.invalidSettings }
      fields[key] = token
    } else {
      fields.removeValue(forKey: key)
    }
    return try Self.parse(Self.encode(fields: fields))
  }

  /// Decodes v1 or legacy v0 (missing schemaVersion/revision). This performs
  /// only typed projection and never persists migration results.
  public static func parse(_ data: Data) throws -> SettingsDocument {
    guard data.count <= maxBytes else { throw Error.tooLarge }
    guard !containsTrailingComma(data) else { throw Error.invalidEnvelope }
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw Error.nonObject
    }
    let rawFields = try topLevelFields(data)
    let schemaToken = rawFields["schemaVersion"]
    let revisionToken = rawFields["revision"]
    let schemaPresent = schemaToken != nil
    let revisionPresent = revisionToken != nil
    guard schemaPresent == revisionPresent else { throw Error.invalidEnvelope }
    let schemaVersion: Int
    let revision: UInt64
    switch (schemaPresent, revisionPresent) {
    case (false, false):
      schemaVersion = 0
      revision = 0
    default:
      let version = try strictInt(schemaToken, error: .invalidSchemaVersion)
      guard version == 1 else { throw Error.unsupportedSchema(version) }
      schemaVersion = version
      revision = try strictUInt64(revisionToken)
    }
    var projectionObject = object
    projectionObject.removeValue(forKey: "schemaVersion")
    projectionObject.removeValue(forKey: "revision")
    let projectionData = try JSONSerialization.data(withJSONObject: projectionObject)
    guard let decoded = try? JSONDecoder().decode(AppSettings.self, from: projectionData) else {
      throw Error.invalidSettings
    }
    let typed = SettingsStore.migrated(decoded)
    return SettingsDocument(
      schemaVersion: schemaVersion, revision: revision, typed: typed, rawFields: rawFields)
  }

  /// Applies a top-level three-way patch. A key changes only when current
  /// still equals base; an already-applied desired value is idempotent.
  /// schemaVersion and revision are protocol-owned and cannot be patched.
  public static func patch(
    base: SettingsDocument,
    current: SettingsDocument,
    desired: SettingsDocument
  ) throws -> SettingsDocument {
    guard base.schemaVersion <= 1, current.schemaVersion <= 1, desired.schemaVersion <= 1 else {
      throw Error.unsupportedSchema(
        max(base.schemaVersion, current.schemaVersion, desired.schemaVersion))
    }
    let baseObject = base.rawFields
    let currentObject = current.rawFields
    let desiredObject = desired.rawFields
    for key in ["schemaVersion", "revision"] {
      if baseObject[key] != desiredObject[key] {
        throw Error.reservedFieldPatch(key)
      }
    }
    var result = currentObject
    var conflicts: [String] = []
    var changed = false
    let keys = Set(baseObject.keys).union(currentObject.keys).union(desiredObject.keys)
      .subtracting(["schemaVersion", "revision"])
    for key in keys.sorted() {
      let b = baseObject[key]
      let c = currentObject[key]
      let d = desiredObject[key]
      // A caller that did not change a key cannot conflict with a concurrent
      // writer that did; leave the current value untouched.
      if d == b {
        continue
      } else if c == b {
        if c != d { changed = true }
        if let d { result[key] = d } else { result.removeValue(forKey: key) }
      } else if c == d {
        continue
      } else {
        conflicts.append(key)
      }
    }
    guard conflicts.isEmpty else { throw Error.conflict(conflicts) }
    if !changed { return current }
    guard current.revision < UInt64.max else { throw Error.revisionOverflow }
    result["schemaVersion"] = "1"
    result["revision"] = String(current.revision + 1)
    let data = Self.encode(fields: result)
    return try parse(data)
  }

  private static func encode(fields: [String: String]) -> Data {
    var data = Data("{".utf8)
    for (index, key) in fields.keys.sorted().enumerated() {
      if index > 0 { data.append(0x2C) }
      let keyData = try! JSONSerialization.data(withJSONObject: [key], options: [.fragmentsAllowed])
      data.append(keyData.dropFirst().dropLast())
      data.append(Data(":\(fields[key]!)".utf8))
    }
    data.append(0x7D)
    return data
  }

  private static func strictInt(_ token: String?, error: Error) throws -> Int {
    guard let token, token.allSatisfy(\.isNumber), !token.isEmpty,
      let parsed = Int(token), String(parsed) == token
    else { throw error }
    return parsed
  }

  private static func strictUInt64(_ token: String?) throws -> UInt64 {
    guard let token, token.allSatisfy(\.isNumber), !token.isEmpty,
      let parsed = UInt64(token), String(parsed) == token
    else { throw Error.invalidRevision }
    return parsed
  }

  /// Returns exact raw JSON value tokens for every top-level key. Duplicate
  /// decoded keys fail closed, including differently escaped spellings.
  private static func topLevelFields(_ data: Data) throws -> [String: String] {
    var scanner = TopLevelJSONScanner(bytes: Array(data))
    return try scanner.fields()
  }

  /// Foundation accepts trailing commas even though RFC 8259 and Rust's parser
  /// reject them. Scan outside strings so both clients fail closed on the same
  /// top-level or nested malformed shape.
  private static func containsTrailingComma(_ data: Data) -> Bool {
    let bytes = Array(data)
    var index = 0
    var inString = false
    var escaped = false
    while index < bytes.count {
      let byte = bytes[index]
      if inString {
        if escaped {
          escaped = false
        } else if byte == 0x5C {
          escaped = true
        } else if byte == 0x22 {
          inString = false
        }
        index += 1
        continue
      }
      if byte == 0x22 {
        inString = true
      } else if byte == 0x2C {
        var next = index + 1
        while next < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[next]) {
          next += 1
        }
        if next < bytes.count, bytes[next] == 0x7D || bytes[next] == 0x5D { return true }
      }
      index += 1
    }
    return false
  }

  private struct TopLevelJSONScanner {
    let bytes: [UInt8]
    var index = 0

    mutating func fields() throws -> [String: String] {
      skipWhitespace()
      guard take(0x7B) else { throw Error.invalidEnvelope }  // {
      var fields: [String: String] = [:]
      while true {
        skipWhitespace()
        if take(0x7D) { return fields }  // }
        let keyStart = index
        try skipString()
        let keyData = Data(bytes[keyStart..<index])
        guard let decodedKey = try? JSONDecoder().decode(String.self, from: keyData) else {
          throw Error.invalidEnvelope
        }
        skipWhitespace()
        guard take(0x3A) else { throw Error.invalidEnvelope }  // :
        skipWhitespace()
        let valueStart = index
        try skipValue()
        let token = String(decoding: bytes[valueStart..<index], as: UTF8.self)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        guard fields.updateValue(token, forKey: decodedKey) == nil else {
          throw Error.invalidEnvelope
        }
        skipWhitespace()
        if take(0x2C) { continue }  // ,
        guard take(0x7D) else { throw Error.invalidEnvelope }  // }
        skipWhitespace()
        guard index == bytes.count else { throw Error.invalidEnvelope }
        return fields
      }
    }

    mutating func skipValue() throws {
      guard index < bytes.count else { throw Error.invalidEnvelope }
      if bytes[index] == 0x22 {  // "
        try skipString()
        return
      }
      if bytes[index] == 0x7B || bytes[index] == 0x5B {  // { or [
        var closers: [UInt8] = [bytes[index] == 0x7B ? 0x7D : 0x5D]
        index += 1
        while let closer = closers.last {
          guard index < bytes.count else { throw Error.invalidEnvelope }
          switch bytes[index] {
          case 0x22:
            try skipString()
          case 0x7B:
            closers.append(0x7D)
            index += 1
          case 0x5B:
            closers.append(0x5D)
            index += 1
          case let byte where byte == closer:
            closers.removeLast()
            index += 1
          default:
            index += 1
          }
        }
        return
      }
      while index < bytes.count, bytes[index] != 0x2C, bytes[index] != 0x7D {
        index += 1
      }
    }

    mutating func skipString() throws {
      guard take(0x22) else { throw Error.invalidEnvelope }
      while index < bytes.count {
        let byte = bytes[index]
        index += 1
        if byte == 0x22 { return }
        if byte == 0x5C {  // backslash escape
          guard index < bytes.count else { throw Error.invalidEnvelope }
          index += 1
        }
      }
      throw Error.invalidEnvelope
    }

    mutating func skipWhitespace() {
      while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) {
        index += 1
      }
    }

    mutating func take(_ byte: UInt8) -> Bool {
      guard index < bytes.count, bytes[index] == byte else { return false }
      index += 1
      return true
    }
  }
}
