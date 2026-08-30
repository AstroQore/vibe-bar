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
    let schemaValue = object["schemaVersion"]
    let revisionValue = object["revision"]
    let schemaPresent = schemaValue != nil
    let revisionPresent = revisionValue != nil
    guard schemaPresent == revisionPresent else { throw Error.invalidEnvelope }
    let schemaVersion: Int
    let revision: UInt64
    switch (schemaPresent, revisionPresent) {
    case (false, false):
      schemaVersion = 0
      revision = 0
    default:
      let version = try strictInt(schemaValue, error: .invalidSchemaVersion)
      guard version == 1 else { throw Error.unsupportedSchema(version) }
      schemaVersion = version
      revision = try strictUInt64(revisionValue)
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

  private static func strictInt(_ value: Any?, error: Error) throws -> Int {
    guard let number = value as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID(), !CFNumberIsFloatType(number),
      let parsed = Int(number.stringValue), String(parsed) == number.stringValue
    else { throw error }
    return parsed
  }

  private static func strictUInt64(_ value: Any?) throws -> UInt64 {
    guard let number = value as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID(), !CFNumberIsFloatType(number),
      let parsed = UInt64(number.stringValue), String(parsed) == number.stringValue
    else { throw Error.invalidRevision }
    return parsed
  }
}
