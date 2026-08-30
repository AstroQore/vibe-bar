import CryptoKit
import Foundation
import XCTest

@testable import VibeBarCore

final class SettingsDocumentTests: XCTestCase {
  func testLegacyV0DefaultsMetadataAndOnlyProjectsMigration() throws {
    let document = try SettingsDocument.parse(
      Data(contentsOf: fixture("settings-document-v0-legacy.json")))
    XCTAssertEqual(document.schemaVersion, 0)
    XCTAssertEqual(document.revision, 0)
    XCTAssertEqual(document.typed.displayMode, .used)
    XCTAssertTrue(document.rawJSON.contains(Data("future".utf8)))
  }

  func testV1PreservesUnknownTopLevelAndNestedFields() throws {
    let document = try SettingsDocument.parse(
      Data(contentsOf: fixture("settings-document-v1-unknown.json")))
    XCTAssertEqual(document.schemaVersion, 1)
    XCTAssertEqual(document.revision, 7)
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: document.rawJSON) as? [String: Any])
    XCTAssertEqual((object["future"] as? [String: Any])?["keep"] as? String, "yes")
    XCTAssertEqual(
      ((object["future"] as? [String: Any])?["futureNested"] as? [String: Any])?["revision"]
        as? String,
      "opaque")
    XCTAssertEqual(
      (((object["menuBarItems"] as? [[String: Any]])?.first?["futureNested"] as? [String: Any])?[
        "schemaVersion"] as? String),
      "opaque")
    XCTAssertEqual(object["topLevelUnknown"] as? String, "keep-me")
    XCTAssertTrue(
      document.rawJSON.contains(Data("12345678901234567890123456789012345678901234567890".utf8)))
    XCTAssertTrue(
      document.rawJSON.contains(Data("0.12345678901234567890123456789012345678901234567890".utf8)))
    let desired = try document.replacingRawValue(
      Data("\"used\"".utf8), forKey: "displayMode")
    let patched = try SettingsDocument.patch(base: document, current: document, desired: desired)
    XCTAssertTrue(
      patched.rawJSON.contains(Data("12345678901234567890123456789012345678901234567890".utf8)))
    XCTAssertTrue(
      patched.rawJSON.contains(Data("0.12345678901234567890123456789012345678901234567890".utf8)))
  }

  func testInvalidShapeSchemaAndRevisionFailClosed() {
    for data in [Data("[]".utf8), Data("null".utf8)] {
      XCTAssertThrowsError(try SettingsDocument.parse(data))
    }
    XCTAssertThrowsError(try SettingsDocument.parse(Data("{\"schemaVersion\":2}".utf8)))
    XCTAssertThrowsError(try SettingsDocument.parse(Data("{\"revision\":true}".utf8)))
    XCTAssertThrowsError(try SettingsDocument.parse(Data("{\"revision\":-1}".utf8)))
    XCTAssertThrowsError(try SettingsDocument.parse(Data("{\"schemaVersion\":1}".utf8)))
    XCTAssertThrowsError(try SettingsDocument.parse(Data("{\"revision\":1}".utf8)))
    XCTAssertThrowsError(
      try SettingsDocument.parse(Data("{\"schemaVersion\":1,\"revision\":1.0}".utf8)))
    XCTAssertThrowsError(
      try SettingsDocument.parse(
        Data("{\"schemaVersion\":1,\"revision\":18446744073709551616}".utf8)))
    XCTAssertThrowsError(
      try SettingsDocument.parse(Data("{\"schemaVersion\":1,\"revision\":true}".utf8)))
    XCTAssertThrowsError(
      try SettingsDocument.parse(Data("{\"schemaVersion\":1,\"revision\":-0}".utf8)))
    XCTAssertThrowsError(
      try SettingsDocument.parse(
        Data("{\"schemaVersion\":1,\"revision\":1,\"revision\":2}".utf8)))
    XCTAssertThrowsError(
      try SettingsDocument.parse(Data("{\"schemaVersion\":1,\"revision\":1,}".utf8)))
    XCTAssertThrowsError(
      try SettingsDocument.parse(
        Data("{\"schemaVersion\":1,\"revision\":1,\"future\":[1,2,]}".utf8)))
    XCTAssertThrowsError(
      try SettingsDocument.parse(
        Data("{\"schemaVersion\":1,\"revision\":1,\"\\u0072evision\":2}".utf8)))
    XCTAssertThrowsError(
      try SettingsDocument.parse(Data(repeating: 0x20, count: 8 * 1024 * 1024 + 1)))
    XCTAssertNoThrow(
      try SettingsDocument.parse(
        Data(
          "{\"schemaVersion\":1,\"revision\":1,\"future\":{\"revision\":\"opaque\",\"schemaVersion\":\"opaque\"},\"text\":\"revision schemaVersion\"}"
            .utf8)))
  }

  func testNonConflictingThreeWayPatchAdvancesRevisionAndIsLossless() throws {
    let base = try parse(
      "{\"displayMode\":\"used\",\"future\":{\"keep\":true},\"revision\":2,\"schemaVersion\":1}")
    let current = try parse(
      "{\"displayMode\":\"used\",\"future\":{\"keep\":true},\"revision\":3,\"schemaVersion\":1}")
    let desired = try parse(
      "{\"displayMode\":\"used\",\"future\":{\"keep\":false},\"revision\":2,\"schemaVersion\":1}")
    let result = try SettingsDocument.patch(base: base, current: current, desired: desired)
    XCTAssertEqual(result.revision, 4)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: result.rawJSON) as? [String: Any])
    XCTAssertEqual(object["displayMode"] as? String, "used")
    XCTAssertEqual((object["future"] as? [String: Any])?["keep"] as? Bool, false)
  }

  func testAlreadyAppliedPatchIsIdempotent() throws {
    let base = try parse("{\"displayMode\":\"remaining\",\"revision\":2,\"schemaVersion\":1}")
    let current = try parse("{\"displayMode\":\"used\",\"revision\":3,\"schemaVersion\":1}")
    let desired = try parse("{\"displayMode\":\"used\",\"revision\":2,\"schemaVersion\":1}")
    let result = try SettingsDocument.patch(base: base, current: current, desired: desired)
    XCTAssertEqual(result.revision, 3)
    XCTAssertEqual(result.typed.displayMode, .used)
  }

  func testExplicitDesiredOmissionRemovesAKey() throws {
    let base = try parse(
      "{\"displayMode\":\"remaining\",\"future\":{\"keep\":true},\"revision\":1,\"schemaVersion\":1}"
    )
    let desired = try parse(
      "{\"displayMode\":\"remaining\",\"revision\":1,\"schemaVersion\":1}")
    let result = try SettingsDocument.patch(base: base, current: base, desired: desired)
    XCTAssertEqual(result.revision, 2)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: result.rawJSON) as? [String: Any])
    XCTAssertNil(object["future"])
  }

  func testUntouchedConcurrentKeyIsNotAConflict() throws {
    let base = try parse(
      "{\"displayMode\":\"remaining\",\"future\":true,\"revision\":1,\"schemaVersion\":1}")
    let current = try parse(
      "{\"displayMode\":\"used\",\"future\":true,\"revision\":2,\"schemaVersion\":1}")
    let desired = try parse(
      "{\"displayMode\":\"remaining\",\"future\":false,\"revision\":1,\"schemaVersion\":1}")
    let result = try SettingsDocument.patch(base: base, current: current, desired: desired)
    XCTAssertEqual(result.revision, 3)
    XCTAssertEqual(result.typed.displayMode, .used)
  }

  func testDivergentTopLevelKeysProduceStructuredConflict() throws {
    let base = try parse(
      "{\"displayMode\":\"remaining\",\"refreshIntervalSeconds\":600,\"revision\":1,\"schemaVersion\":1}"
    )
    let current = try parse(
      "{\"displayMode\":\"remaining\",\"refreshIntervalSeconds\":300,\"revision\":2,\"schemaVersion\":1}"
    )
    let desired = try parse(
      "{\"displayMode\":\"remaining\",\"refreshIntervalSeconds\":900,\"revision\":1,\"schemaVersion\":1}"
    )
    do {
      _ = try SettingsDocument.patch(base: base, current: current, desired: desired)
      XCTFail("expected conflict")
    } catch let error as SettingsDocument.Error {
      XCTAssertEqual(error, .conflict(["refreshIntervalSeconds"]))
    } catch {
      XCTFail("unexpected error: \(error)")
    }
  }

  func testFixtureVectorsDriveBothPatchOutcomes() throws {
    let data = try Data(contentsOf: fixture("settings-document-vectors.json"))
    let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    for (name, expectedConflict) in [("nonConflict", false), ("conflict", true)] {
      let vector = try XCTUnwrap(root[name] as? [String: Any])
      let base = try document(vector, key: "base")
      let current = try document(vector, key: "current")
      let desired = try document(vector, key: "desired")
      do {
        let result = try SettingsDocument.patch(base: base, current: current, desired: desired)
        XCTAssertFalse(expectedConflict)
        XCTAssertEqual(result.revision, 4)
        if name == "nonConflict" {
          XCTAssertEqual(result.typed.displayMode, .used)
          XCTAssertEqual(result.typed.refreshIntervalSeconds, 900)
          let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: result.rawJSON) as? [String: Any])
          XCTAssertEqual((object["future"] as? [String: Any])?["keep"] as? Bool, true)
        }
      } catch let error as SettingsDocument.Error {
        XCTAssertTrue(expectedConflict)
        XCTAssertEqual(error, .conflict(["refreshIntervalSeconds"]))
      }
    }
  }

  func testFixtureSHA256SidecarsMatch() throws {
    for name in [
      "settings-document-v0-legacy.json", "settings-document-v1-unknown.json",
      "settings-document-vectors.json",
    ] {
      let data = try Data(contentsOf: fixture(name))
      let expected = try String(contentsOf: fixture(name + ".sha256"), encoding: .utf8)
        .split(separator: " ").first.map(String.init)
      XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), expected)
    }
  }

  func testProtocolMetadataCannotBePatched() throws {
    let base = try parse("{\"displayMode\":\"remaining\",\"revision\":1,\"schemaVersion\":1}")
    let current = base
    let desired = try parse("{\"displayMode\":\"remaining\",\"revision\":99,\"schemaVersion\":1}")
    do {
      _ = try SettingsDocument.patch(base: base, current: current, desired: desired)
      XCTFail("expected reserved-field error")
    } catch let error as SettingsDocument.Error {
      XCTAssertEqual(error, .reservedFieldPatch("revision"))
    } catch {
      XCTFail("unexpected error: \(error)")
    }
  }

  func testRevisionOverflowFailsClosed() throws {
    let base = try parse(
      "{\"displayMode\":\"remaining\",\"revision\":18446744073709551614,\"schemaVersion\":1}")
    let current = try parse(
      "{\"displayMode\":\"remaining\",\"revision\":18446744073709551615,\"schemaVersion\":1}")
    let desired = try parse(
      "{\"displayMode\":\"used\",\"revision\":18446744073709551614,\"schemaVersion\":1}")
    do {
      _ = try SettingsDocument.patch(base: base, current: current, desired: desired)
      XCTFail("expected revision overflow")
    } catch let error as SettingsDocument.Error {
      XCTAssertEqual(error, .revisionOverflow)
    }
  }

  private func parse(_ string: String) throws -> SettingsDocument {
    try SettingsDocument.parse(Data(string.utf8))
  }
  private func document(_ object: [String: Any], key: String) throws -> SettingsDocument {
    let value = try XCTUnwrap(object[key])
    return try SettingsDocument.parse(
      JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
  }
  private func fixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("docs/contracts/").appendingPathComponent(name)
  }
}
