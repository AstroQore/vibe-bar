import CryptoKit
import Foundation
import XCTest

@testable import VibeBarCore

final class SharedStoreContractTests: XCTestCase {
  func testRegistryCoversEverySharedStoreExactlyOnce() {
    let contracts = SharedStoreContractRegistry.all
    XCTAssertEqual(Set(contracts.map(\.storeID)), Set(SharedStoreID.allCases))
    XCTAssertEqual(contracts.count, SharedStoreID.allCases.count)
  }

  func testEveryUnknownVersionFailsClosed() {
    for contract in SharedStoreContractRegistry.all {
      XCTAssertEqual(contract.unknownVersionPolicy, .failClosed, "\(contract.storeID.rawValue)")
      XCTAssertFalse(contract.writerRoles.isEmpty, "\(contract.storeID.rawValue)")
    }
  }

  func testExportFixtureIsStableAndPathFree() throws {
    let first = try SharedStoreContractRegistry.exportFixtureJSON()
    let second = try SharedStoreContractRegistry.exportFixtureJSON()
    XCTAssertEqual(first, second)
    let text = try XCTUnwrap(String(data: first, encoding: .utf8))
    XCTAssertFalse(text.contains("/Users/"))
    XCTAssertFalse(text.contains(".vibebar"))
    XCTAssertTrue(text.contains("\"protocolVersion\":1"))
    XCTAssertTrue(text.contains("\"unknownVersionPolicy\":\"fail_closed\""))
    let fixture = fixtureURL()
    let checksum = fixture.deletingPathExtension().appendingPathExtension("json.sha256")
    if ProcessInfo.processInfo.environment["VIBEBAR_WRITE_CONTRACT_FIXTURE"] == "1" {
      try FileManager.default.createDirectory(
        at: fixture.deletingLastPathComponent(), withIntermediateDirectories: true)
      try first.write(to: fixture, options: .atomic)
      let line = "\(sha256(first))  \(fixture.lastPathComponent)\n"
      try Data(line.utf8).write(to: checksum, options: .atomic)
    }
    XCTAssertEqual(try Data(contentsOf: fixture), first)
    XCTAssertEqual(
      try String(contentsOf: checksum, encoding: .utf8),
      "\(sha256(first))  \(fixture.lastPathComponent)\n")
  }

  func testImportantCurrentVersionsAreRecorded() {
    XCTAssertEqual(SharedStoreContractRegistry.contract(for: .scanCache).currentSchemaVersion, 7)
    XCTAssertEqual(SharedStoreContractRegistry.contract(for: .usageEvents).currentSchemaVersion, 4)
    XCTAssertEqual(SharedStoreContractRegistry.contract(for: .sessionIndex).currentSchemaVersion, 5)
    XCTAssertEqual(SharedStoreContractRegistry.contract(for: .fillTimeline).currentSchemaVersion, 1)
    XCTAssertEqual(
      SharedStoreContractRegistry.contract(for: .forecastTimeline).currentSchemaVersion, 1)
    XCTAssertEqual(
      SharedStoreContractRegistry.contract(for: .pricingSources).currentSchemaVersion, 1)
  }

  func testEndpointLocatorsNeverMasqueradeAsFilesystemStores() {
    let vault = SharedStoreContractRegistry.contract(for: .credentialVault)
    XCTAssertEqual(vault.locatorKind, .keychainItem)
    XCTAssertEqual(vault.keychainService, "com.astroqore.VibeBar.credential-vault")
    XCTAssertEqual(vault.keychainAccount, "vault-v1")
    XCTAssertEqual(vault.shareEligibility, .endpointOnly)
    let socket = SharedStoreContractRegistry.contract(for: .mcpSocket)
    XCTAssertEqual(socket.locatorKind, .endpoint)
    XCTAssertEqual(socket.relativeLocator, "mcp.sock")
    XCTAssertEqual(socket.endpointProtocol, "mcp-jsonrpc")
    XCTAssertEqual(socket.endpointVersion, MCPServer.protocolVersion)
    XCTAssertEqual(socket.endpointVersion, "2025-06-18")
    XCTAssertEqual(socket.shareEligibility, .endpointOnly)
  }

  func testLeaseRecordFixtureIsCanonical() throws {
    let record = SharedStoreLeaseRecord(
      role: .quotaCollector,
      pid: 42,
      startedAt: 1_700_000_000_000,
      clientID: "fixture-client"
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(record)
    let fixture = fixtureURL().deletingLastPathComponent()
      .appendingPathComponent("shared-store-lease-record-v1.json")
    let checksum = fixture.deletingPathExtension().appendingPathExtension("json.sha256")
    if ProcessInfo.processInfo.environment["VIBEBAR_WRITE_CONTRACT_FIXTURE"] == "1" {
      try data.write(to: fixture, options: .atomic)
      try Data("\(sha256(data))  \(fixture.lastPathComponent)\n".utf8).write(
        to: checksum, options: .atomic)
    }
    XCTAssertEqual(try Data(contentsOf: fixture), data)
    XCTAssertEqual(
      try String(contentsOf: checksum, encoding: .utf8),
      "\(sha256(data))  \(fixture.lastPathComponent)\n")
  }

  private func fixtureURL() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("docs/contracts/shared-store-contract-v1.json")
  }

  private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
