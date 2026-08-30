import Foundation
import VibeBarPOSIX
import XCTest

@testable import VibeBarCore

final class SharedStoreLeaseTests: XCTestCase {
  private var directory: URL!
  override func setUpWithError() throws {
    let temporaryPath = FileManager.default.temporaryDirectory.path
    let physicalPath = temporaryPath.hasPrefix("/var/") ? "/private" + temporaryPath : temporaryPath
    directory = URL(fileURLWithPath: physicalPath).appendingPathComponent(
      "VibeBarLease-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }
  override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

  func testSameStoreIsExclusiveAndReleaseAllowsTakeover() throws {
    let one = try writer([.quotaCache])
    XCTAssertThrowsError(try writer([.quotaCache])) {
      XCTAssertEqual($0 as? SharedStoreLeaseError, .busy)
    }
    one.release()
    try writer([.quotaCache]).release()
  }
  func testRealChildProcessSeesFlockBusy() throws {
    let lease = try writer([.quotaCache])
    let path = directory.appendingPathComponent("run/quota_cache.lock").path
    XCTAssertEqual(path.withCString { vb_test_child_cannot_flock($0) }, 0)
    lease.release()
  }
  func testChildBarrierMatrixUsesRealProcess() throws {
    let run = directory.appendingPathComponent("run")
    let barrier = run.appendingPathComponent("barrier.lock").path
    let other = run.appendingPathComponent("quota_field_registry.lock").path
    try writer([.quotaFieldRegistry]).release()
    let writerLease = try writer([.quotaCache])
    XCTAssertEqual(vb_test_child_lock_pair(barrier, other, 0), 0)
    XCTAssertEqual(vb_test_child_lock_pair(barrier, other, 1), 1)
    writerLease.release()
    let maintenanceLease = try maintenance([.quotaCache])
    XCTAssertEqual(vb_test_child_lock_pair(barrier, other, 0), 1)
    maintenanceLease.release()
  }
  func testRustProbeInteroperabilityWhenConfigured() throws {
    guard
      let executable = ProcessInfo.processInfo.environment["VIBEBAR_RUST_LEASE_PROBE"],
      FileManager.default.isExecutableFile(atPath: executable)
    else {
      throw XCTSkip("set VIBEBAR_RUST_LEASE_PROBE to the Desktop synthetic probe binary")
    }

    let writerLease = try writer([.quotaCache])
    XCTAssertEqual(try runRustProbe(executable, store: "service_status"), 0)
    writerLease.release()

    let maintenanceLease = try maintenance([.quotaCache])
    XCTAssertEqual(try runRustProbe(executable, store: "service_status"), 3)
    maintenanceLease.release()

    let holder = try startRustProbe(
      executable, store: "quota_cache", extra: ["--mode", "hold", "--milliseconds", "1500"])
    let record = directory.appendingPathComponent("run/quota_cache.record")
    for _ in 0..<100 where !FileManager.default.fileExists(atPath: record.path) {
      usleep(10_000)
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: record.path))
    XCTAssertThrowsError(try writer([.quotaCache])) {
      XCTAssertEqual($0 as? SharedStoreLeaseError, .busy)
    }
    holder.waitUntilExit()
    XCTAssertEqual(holder.terminationStatus, 0)
  }
  func testDifferentStoresRunInParallel() throws {
    let one = try writer([.quotaCache])
    let two = try writer([.quotaFieldRegistry])
    one.release()
    two.release()
  }
  func testMaintenanceBarrierFencesAllWriters() throws {
    let writerLease = try writer([.quotaCache])
    XCTAssertThrowsError(try maintenance([.quotaCache])) {
      XCTAssertEqual($0 as? SharedStoreLeaseError, .busy)
    }
    writerLease.release()
    let maintenanceLease = try maintenance([.quotaCache, .quotaFieldRegistry])
    XCTAssertThrowsError(try writer([.quotaFieldRegistry])) {
      XCTAssertEqual($0 as? SharedStoreLeaseError, .busy)
    }
    maintenanceLease.release()
  }
  func testFixedStoreOrderAndConcurrentReleaseAreSafe() throws {
    let one = try writer([.quotaFieldRegistry, .quotaCache])
    XCTAssertEqual(one.stores, [.quotaCache, .quotaFieldRegistry])
    DispatchQueue.concurrentPerform(iterations: 32) { _ in one.release() }
    try writer([.quotaCache, .quotaFieldRegistry]).release()
  }
  func testSymlinkRootAndLeafFailClosed() throws {
    let target = directory.appendingPathComponent("target")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    let linked = directory.appendingPathComponent("linked")
    try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: target)
    XCTAssertThrowsError(try Self.acquire(linked, [.quotaCache]))
    let run = directory.appendingPathComponent("run")
    try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
    let lock = run.appendingPathComponent("quota_cache.lock")
    try FileManager.default.createSymbolicLink(
      at: lock, withDestinationURL: directory.appendingPathComponent("x"))
    XCTAssertThrowsError(try writer([.quotaCache])) {
      XCTAssertEqual($0 as? SharedStoreLeaseError, .symlinkDetected)
    }
  }
  func testHardLinkedLockIsRejectedWithoutChangingExternalMode() throws {
    let run = directory.appendingPathComponent("run")
    try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
    let external = directory.appendingPathComponent("external")
    try Data("external".utf8).write(to: external)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: external.path)
    try FileManager.default.linkItem(
      at: external, to: run.appendingPathComponent("quota_cache.lock"))

    XCTAssertThrowsError(try writer([.quotaCache]))
    let attributes = try FileManager.default.attributesOfItem(atPath: external.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o644)
  }
  func testRecordPermissionsAndStaleRecordDoNotAuthorize() throws {
    let run = directory.appendingPathComponent("run")
    try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
    try Data("stale".utf8).write(to: run.appendingPathComponent("quota_cache.record"))
    let lease = try writer([.quotaCache])
    let attributes = try FileManager.default.attributesOfItem(
      atPath: run.appendingPathComponent("quota_cache.record").path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    lease.release()
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: run.appendingPathComponent("quota_cache.record").path))
  }
  func testDirectoryFsyncFailureRollsBackRenamedRecord() throws {
    vb_test_fail_fsync_after(2)
    XCTAssertThrowsError(try writer([.quotaCache]))
    vb_test_fail_fsync_after(0)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("run/quota_cache.record").path))
  }
  func testLegacyStoresCannotReceiveProductionAuthorization() {
    XCTAssertThrowsError(
      try SharedStoreLeaseBatch.acquireWriter(
        dataRootURL: directory, stores: [.quotaCache], role: .quotaCollector, clientID: "desktop")
    ) { XCTAssertEqual($0 as? SharedStoreLeaseError, .notEligible(.quotaCache)) }
  }
  func testTestingSeamRejectsUnauthorizedRole() {
    XCTAssertThrowsError(try Self.acquire(directory, [.quotaCache], role: .mcpOwner)) {
      XCTAssertEqual($0 as? SharedStoreLeaseError, .invalidRole)
    }
  }
  func testTestingSeamRejectsEndpoints() {
    XCTAssertThrowsError(try Self.acquire(directory, [.mcpSocket])) {
      XCTAssertEqual($0 as? SharedStoreLeaseError, .notEligible(.mcpSocket))
    }
  }

  private func writer(_ stores: [SharedStoreID]) throws -> SharedStoreLeaseBatch {
    try Self.acquire(directory, stores)
  }
  private func maintenance(_ stores: [SharedStoreID]) throws -> SharedStoreLeaseBatch {
    try Self.acquire(directory, stores, role: .migrator, maintenance: true)
  }
  private static func acquire(
    _ root: URL, _ stores: [SharedStoreID], role: SharedStoreLeaseRole = .quotaCollector,
    maintenance: Bool = false
  ) throws -> SharedStoreLeaseBatch {
    try SharedStoreLeaseBatch.acquireForTesting(
      dataRootURL: root, stores: stores, role: role, maintenance: maintenance, clientID: "test")
  }

  private func runRustProbe(_ executable: String, store: String) throws -> Int32 {
    let process = try startRustProbe(executable, store: store)
    process.waitUntilExit()
    return process.terminationStatus
  }

  private func startRustProbe(
    _ executable: String, store: String, extra: [String] = []
  ) throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments =
      ["--root", directory.path, "--store", store]
      + (extra.isEmpty ? ["--mode", "try"] : extra)
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    return process
  }
}
