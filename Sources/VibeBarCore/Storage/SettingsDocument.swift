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

  private let objectData: Data

  private init(schemaVersion: Int, revision: UInt64, typed: AppSettings, objectData: Data) {
    self.schemaVersion = schemaVersion
    self.revision = revision
    self.typed = typed
    self.objectData = objectData
  }

  /// The canonical raw JSON object. Unknown top-level and nested values are
  /// retained because patches operate on this raw object, not AppSettings.
  public var rawJSON: Data { objectData }

  /// Decodes v1 or legacy v0 (missing schemaVersion/revision). This performs
  /// only typed projection and never persists migration results.
  public static func parse(_ data: Data) throws -> SettingsDocument {
    guard data.count <= maxBytes else { throw Error.tooLarge }
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw Error.nonObject
    }
    let schemaTokens = try topLevelValueTokens(data, key: "schemaVersion")
    let revisionTokens = try topLevelValueTokens(data, key: "revision")
    guard schemaTokens.count <= 1, revisionTokens.count <= 1 else { throw Error.invalidEnvelope }
    let schemaPresent = object.keys.contains("schemaVersion")
    let revisionPresent = object.keys.contains("revision")
    guard schemaPresent == !schemaTokens.isEmpty, revisionPresent == !revisionTokens.isEmpty else {
      throw Error.invalidEnvelope
    }
    guard schemaPresent == revisionPresent else { throw Error.invalidEnvelope }
    let schemaVersion: Int
    let revision: UInt64
    switch (schemaPresent, revisionPresent) {
    case (false, false):
      schemaVersion = 0
      revision = 0
    default:
      let version = try strictInt(schemaTokens.first, error: .invalidSchemaVersion)
      guard version == 1 else { throw Error.unsupportedSchema(version) }
      schemaVersion = version
      revision = try strictUInt64(revisionTokens.first)
    }
    var projectionObject = object
    projectionObject.removeValue(forKey: "schemaVersion")
    projectionObject.removeValue(forKey: "revision")
    let projectionData = try JSONSerialization.data(withJSONObject: projectionObject)
    guard let decoded = try? JSONDecoder().decode(AppSettings.self, from: projectionData) else {
      throw Error.invalidSettings
    }
    let typed = SettingsStore.migrated(decoded)
    let canonical = try canonicalData(object)
    return SettingsDocument(
      schemaVersion: schemaVersion, revision: revision, typed: typed, objectData: canonical)
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
    let baseObject = try object(base)
    let currentObject = try object(current)
    let desiredObject = try object(desired)
    for key in ["schemaVersion", "revision"] {
      if !jsonEqual(value(baseObject, key), value(desiredObject, key)) {
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
      if jsonEqual(d, b) {
        continue
      } else if jsonEqual(c, b) {
        if !jsonEqual(c, d) { changed = true }
        if let d { result[key] = d } else { result.removeValue(forKey: key) }
      } else if jsonEqual(c, d) {
        continue
      } else {
        conflicts.append(key)
      }
    }
    guard conflicts.isEmpty else { throw Error.conflict(conflicts) }
    if !changed { return current }
    guard current.revision < UInt64.max else { throw Error.revisionOverflow }
    result["schemaVersion"] = 1
    result["revision"] = NSNumber(value: current.revision + 1)
    let data = try canonicalData(result)
    return try parse(data)
  }

  private static func object(_ document: SettingsDocument) throws -> [String: Any] {
    guard let value = try JSONSerialization.jsonObject(with: document.objectData) as? [String: Any]
    else {
      throw Error.nonObject
    }
    return value
  }

  private static func value(_ object: [String: Any], _ key: String) -> Any? {
    object[key]
  }

  private static func jsonEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil): return true
    case (nil, _), (_, nil): return false
    default:
      guard let left = try? canonicalData(["v": lhs!]),
        let right = try? canonicalData(["v": rhs!])
      else { return false }
      return left == right
    }
  }

  private static func canonicalData(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
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

  /// Returns exact raw JSON value tokens for one top-level key. Foundation
  /// normalizes `-0` to NSNumber(0), so protocol integers must be validated
  /// before that sign information is lost. Nested keys and quoted text are
  /// intentionally ignored; duplicate protocol keys fail closed at the caller.
  private static func topLevelValueTokens(_ data: Data, key: String) throws -> [String] {
    var scanner = TopLevelJSONScanner(bytes: Array(data))
    return try scanner.valueTokens(for: key)
  }

  private struct TopLevelJSONScanner {
    let bytes: [UInt8]
    var index = 0

    mutating func valueTokens(for target: String) throws -> [String] {
      skipWhitespace()
      guard take(0x7B) else { throw Error.invalidEnvelope }  // {
      var tokens: [String] = []
      while true {
        skipWhitespace()
        if take(0x7D) { return tokens }  // }
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
        if decodedKey == target {
          let token = String(decoding: bytes[valueStart..<index], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
          tokens.append(token)
        }
        skipWhitespace()
        if take(0x2C) { continue }  // ,
        guard take(0x7D) else { throw Error.invalidEnvelope }  // }
        return tokens
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
