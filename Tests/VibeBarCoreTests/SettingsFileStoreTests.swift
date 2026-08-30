import Darwin
import Foundation
import VibeBarPOSIX
import XCTest

@testable import VibeBarCore

final class SettingsFileStoreTests: XCTestCase {
  func testLeaseRequiredAndRawBytesAreWrittenWithPrivateMode() throws {
    let root = try syntheticRoot()
    let base = root
    let url = base.appendingPathComponent("settings.json")
    let bytes = Data("{\"unknown\":123456789012345678901234567890}".utf8)
    let lease = try SharedStoreLeaseBatch.acquireNativeWriter(dataRootURL: base, clientID: "test")
    try VibeBarLocalStore.writeSettingsData(bytes, to: url, base: base, lease: lease)
    XCTAssertEqual(try Data(contentsOf: url), bytes)
    XCTAssertEqual(
      try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600)
  }

  func testSymlinkDestinationFailsClosedAndHardlinkReplacementLeavesExternalFile() throws {
    let root = try syntheticRoot()
    let base = root
    let lease = try SharedStoreLeaseBatch.acquireNativeWriter(dataRootURL: base, clientID: "test")
    let url = base.appendingPathComponent("settings.json")
    let external = root.appendingPathComponent("external.json")
    try Data("external".utf8).write(to: external)
    try FileManager.default.createSymbolicLink(at: url, withDestinationURL: external)
    XCTAssertThrowsError(
      try VibeBarLocalStore.writeSettingsData(Data("new".utf8), to: url, base: base, lease: lease))
    try FileManager.default.removeItem(at: url)
    try Data("old".utf8).write(to: url)
    let hardTarget = root.appendingPathComponent("hard-target.json")
    XCTAssertEqual(
      url.path.withCString { source in
        hardTarget.path.withCString { target in link(source, target) }
      }, 0)
    try VibeBarLocalStore.writeSettingsData(
      Data("replacement".utf8), to: url, base: base, lease: lease)
    XCTAssertEqual(try Data(contentsOf: hardTarget), Data("old".utf8))
  }

  func testFsyncErrorsAreClassifiedBeforeAndAfterRename() throws {
    let root = try syntheticRoot()
    let base = root
    let lease = try SharedStoreLeaseBatch.acquireNativeWriter(dataRootURL: base, clientID: "test")
    let url = base.appendingPathComponent("settings.json")
    try Data("old".utf8).write(to: url)
    vb_test_fail_fsync_after(1)
    XCTAssertThrowsError(
      try VibeBarLocalStore.writeSettingsData(Data("new".utf8), to: url, base: base, lease: lease)
    ) { error in
      XCTAssertTrue(error is VibeBarLocalStore.SettingsFileStoreError)
    }
    XCTAssertEqual(try Data(contentsOf: url), Data("old".utf8))
    vb_test_fail_fsync_after(2)
    XCTAssertThrowsError(
      try VibeBarLocalStore.writeSettingsData(Data("new".utf8), to: url, base: base, lease: lease)
    ) { error in
      guard case .postRenameUnconfirmed = error as? VibeBarLocalStore.SettingsFileStoreError else {
        return XCTFail("expected post-rename uncertainty, got \(error)")
      }
    }
    XCTAssertEqual(try Data(contentsOf: url), Data("new".utf8))
  }

  func testLeaseCannotAuthorizeAnotherRootOrWrongDestination() throws {
    let rootA = try syntheticRoot()
    let rootB = try syntheticRoot()
    let lease = try SharedStoreLeaseBatch.acquireNativeWriter(dataRootURL: rootA, clientID: "test")
    XCTAssertThrowsError(
      try VibeBarLocalStore.writeSettingsData(
        Data("x".utf8), to: rootB.appendingPathComponent("settings.json"), base: rootB, lease: lease
      )
    ) { XCTAssertEqual($0 as? VibeBarLocalStore.SettingsFileStoreError, .leaseRequired) }
    let wrong = try SharedStoreLeaseBatch.acquireForTesting(
      dataRootURL: rootA, stores: [.quotaCache], role: .quotaCollector, maintenance: false,
      clientID: "test")
    XCTAssertThrowsError(
      try VibeBarLocalStore.writeSettingsData(
        Data("x".utf8), to: rootA.appendingPathComponent("settings.json"), base: rootA, lease: wrong
      )
    ) { XCTAssertEqual($0 as? VibeBarLocalStore.SettingsFileStoreError, .leaseRequired) }
  }

  func testPrecommitFailureLeavesNoSettingsTempFiles() throws {
    let root = try syntheticRoot()
    let lease = try SharedStoreLeaseBatch.acquireNativeWriter(dataRootURL: root, clientID: "test")
    vb_test_fail_fsync_after(1)
    XCTAssertThrowsError(
      try VibeBarLocalStore.writeSettingsData(
        Data("x".utf8), to: root.appendingPathComponent("settings.json"), base: root, lease: lease))
    let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
    XCTAssertFalse(names.contains { $0.hasPrefix(".settings.") && $0.hasSuffix(".tmp") })
  }

  func testReplacementAfterLeaseCannotRedirectStableRootDescriptor() throws {
    let root = try syntheticRoot()
    let replacement = try syntheticRoot()
    let lease = try SharedStoreLeaseBatch.acquireNativeWriter(dataRootURL: root, clientID: "test")
    let moved = root.deletingLastPathComponent().appendingPathComponent(
      "moved-\(UUID().uuidString)")
    try FileManager.default.moveItem(at: root, to: moved)
    try FileManager.default.createSymbolicLink(at: root, withDestinationURL: replacement)
    try VibeBarLocalStore.writeSettingsData(
      Data("original".utf8), to: root.appendingPathComponent("settings.json"), base: root,
      lease: lease)
    XCTAssertEqual(
      try Data(contentsOf: moved.appendingPathComponent("settings.json")), Data("original".utf8))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: replacement.appendingPathComponent("settings.json").path))
  }

  private func syntheticRoot() throws -> URL {
    let temporaryPath = FileManager.default.temporaryDirectory.path
    let physicalPath = temporaryPath.hasPrefix("/var/") ? "/private" + temporaryPath : temporaryPath
    let root = URL(fileURLWithPath: physicalPath).appendingPathComponent(
      "VibeBarLease-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    return root
  }
}
