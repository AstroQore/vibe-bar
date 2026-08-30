import Darwin
import Foundation
import VibeBarPOSIX

public struct SharedStoreLeaseRecord: Codable, Equatable, Sendable {
  public static let version = 1
  public let version: Int
  public let role: SharedStoreLeaseRole
  public let pid: Int32
  public let startedAt: Int64
  public let clientID: String

  public init(role: SharedStoreLeaseRole, pid: Int32, startedAt: Int64, clientID: String) {
    self.version = Self.version
    self.role = role
    self.pid = pid
    self.startedAt = startedAt
    self.clientID = clientID
  }
}

public enum SharedStoreLeaseError: Error, Equatable, Sendable {
  case busy
  case notEligible(SharedStoreID)
  case invalidRole
  case symlinkDetected
  case invalidClientID
  case io(operation: String, code: Int32)
}

/// Batch RAII lease. A writer holds the global barrier shared plus sorted
/// per-store exclusive locks; maintenance holds the barrier exclusive first.
public final class SharedStoreLeaseBatch: @unchecked Sendable {
  public let stores: [SharedStoreID]
  public let role: SharedStoreLeaseRole
  private let state = NSLock()
  private var locks: [LockHandle]?
  private var runFD: Int32?
  private static let heldLock = NSLock()
  private nonisolated(unsafe) static var heldExclusive: Set<String> = []

  private init(
    stores: [SharedStoreID], role: SharedStoreLeaseRole, runFD: Int32, locks: [LockHandle]
  ) {
    self.stores = stores
    self.role = role
    self.runFD = runFD
    self.locks = locks
  }
  deinit { release() }

  /// No current legacy store is authorized. Retrofit will change its
  /// contract eligibility only together with its writer implementation.
  public static func acquireWriter(
    dataRootURL: URL, stores: [SharedStoreID], role: SharedStoreLeaseRole, clientID: String
  ) throws -> SharedStoreLeaseBatch {
    guard let first = stores.first else { throw SharedStoreLeaseError.invalidRole }
    throw SharedStoreLeaseError.notEligible(first)
  }

  /// Test-only raw protocol seam. Product code must use `acquireWriter`.
  static func acquireForTesting(
    dataRootURL: URL, stores: [SharedStoreID], role: SharedStoreLeaseRole, maintenance: Bool,
    clientID: String, pid: Int32 = getpid(), startedAt: Date = Date()
  ) throws -> SharedStoreLeaseBatch {
    guard !stores.isEmpty else { throw SharedStoreLeaseError.invalidRole }
    guard validClientID(clientID) else { throw SharedStoreLeaseError.invalidClientID }
    if let endpoint = stores.first(where: {
      SharedStoreContractRegistry.contract(for: $0).shareEligibility == .endpointOnly
    }) {
      throw SharedStoreLeaseError.notEligible(endpoint)
    }
    if maintenance && role != .migrator && role != .pruner {
      throw SharedStoreLeaseError.invalidRole
    }
    if !maintenance
      && stores.contains(where: {
        !SharedStoreContractRegistry.contract(for: $0).writerRoles.contains(role)
      })
    {
      throw SharedStoreLeaseError.invalidRole
    }
    let rootFD = vb_open_directory_nofollow(dataRootURL.path)
    guard rootFD >= 0 else { throw error("open_data_root") }
    defer { Darwin.close(rootFD) }
    guard vb_mkdirat_private(rootFD, "run") == 0 else { throw error("mkdirat_run") }
    let runFD = vb_openat_directory_nofollow(rootFD, "run")
    guard runFD >= 0 else { throw error("openat_run") }
    guard vb_fchmod_directory(runFD) == 0 else {
      Darwin.close(runFD)
      throw error("chmod_run")
    }

    let sorted = Array(Set(stores)).sorted { $0.rawValue < $1.rawValue }
    let record = SharedStoreLeaseRecord(
      role: role, pid: pid,
      startedAt: Int64((startedAt.timeIntervalSince1970 * 1_000).rounded(.down)), clientID: clientID
    )
    var acquired: [LockHandle] = []
    do {
      acquired.append(
        try acquireLock(
          runFD: runFD, name: "barrier", mode: maintenance ? .exclusive : .shared, record: nil))
      for store in sorted {
        acquired.append(
          try acquireLock(runFD: runFD, name: store.rawValue, mode: .exclusive, record: record))
      }
      return SharedStoreLeaseBatch(stores: sorted, role: role, runFD: runFD, locks: acquired)
    } catch {
      for name in acquired.compactMap(\.recordName) {
        _ = name.withCString { vb_unlinkat_file(runFD, $0) }
      }
      for lock in acquired.reversed() { lock.release() }
      Darwin.close(runFD)
      throw error
    }
  }

  public func release() {
    state.lock()
    let held = locks
    let directory = runFD
    locks = nil
    runFD = nil
    state.unlock()
    if let directory, let held {
      for name in held.compactMap(\.recordName) {
        _ = name.withCString { vb_unlinkat_file(directory, $0) }
      }
    }
    if let held {
      for lock in held.reversed() { lock.release() }
    }
    if let directory { _ = Darwin.close(directory) }
  }

  private enum Mode { case shared, exclusive }
  private final class LockHandle {
    private let state = NSLock()
    private var fd: Int32?
    fileprivate let recordName: String?
    private let heldKey: String?
    init(fd: Int32, recordName: String?, heldKey: String?) {
      self.fd = fd
      self.recordName = recordName
      self.heldKey = heldKey
    }
    func release() {
      state.lock()
      let descriptor = fd
      fd = nil
      state.unlock()
      guard let descriptor else { return }
      _ = vb_flock_unlock(descriptor)
      _ = Darwin.close(descriptor)
      if let heldKey { SharedStoreLeaseBatch.releaseHeldKey(heldKey) }
    }
  }

  private static func acquireLock(
    runFD: Int32, name: String, mode: Mode, record: SharedStoreLeaseRecord?
  ) throws -> LockHandle {
    let lockName = "\(name).lock"
    try rejectSymlink(runFD: runFD, name: lockName)
    let fd = lockName.withCString { vb_openat_lock_nofollow(runFD, $0) }
    guard fd >= 0 else { throw error("openat_lock") }
    guard vb_fchmod_private(fd) == 0 else {
      Darwin.close(fd)
      throw error("chmod_lock")
    }
    guard vb_fd_is_regular(fd) != 0 else {
      Darwin.close(fd)
      throw error("fstat_regular_lock")
    }
    let heldKey: String?
    if mode == .exclusive {
      var device: UInt64 = 0
      var inode: UInt64 = 0
      guard vb_fd_identity(fd, &device, &inode) == 0 else {
        Darwin.close(fd)
        throw error("fstat_lock")
      }
      let key = "\(device):\(inode)"
      guard reserveHeldKey(key) else {
        Darwin.close(fd)
        throw SharedStoreLeaseError.busy
      }
      heldKey = key
    } else {
      heldKey = nil
    }
    let outcome =
      mode == .shared ? vb_flock_shared_nonblocking(fd) : vb_flock_exclusive_nonblocking(fd)
    guard outcome == 0 else {
      let code = errno
      if let heldKey { releaseHeldKey(heldKey) }
      Darwin.close(fd)
      if code == EWOULDBLOCK || code == EAGAIN { throw SharedStoreLeaseError.busy }
      throw SharedStoreLeaseError.io(operation: "flock", code: code)
    }
    let recordName = record.map { _ in "\(name).record" }
    do {
      if let record, let recordName {
        try writeRecord(record, runFD: runFD, name: recordName)
      }
    } catch {
      if let recordName {
        _ = recordName.withCString { vb_unlinkat_file(runFD, $0) }
      }
      if let heldKey { releaseHeldKey(heldKey) }
      _ = vb_flock_unlock(fd)
      Darwin.close(fd)
      throw error
    }
    return LockHandle(fd: fd, recordName: recordName, heldKey: heldKey)
  }

  private static func writeRecord(_ record: SharedStoreLeaseRecord, runFD: Int32, name: String)
    throws
  {
    try rejectSymlink(runFD: runFD, name: name)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(record)
    let temp = ".\(name).\(UUID().uuidString).tmp"
    let fd = temp.withCString { vb_openat_new_private(runFD, $0) }
    guard fd >= 0 else { throw error("openat_record") }
    defer {
      Darwin.close(fd)
      _ = temp.withCString { vb_unlinkat_file(runFD, $0) }
    }
    guard vb_fchmod_private(fd) == 0 else { throw error("chmod_record") }
    try writeAll(data, fd: fd)
    guard vb_fsync_fd(fd) == 0 else { throw error("fsync_record") }
    guard
      temp.withCString({ from in
        name.withCString { to in vb_renameat_same_directory(runFD, from, to) }
      }) == 0
    else { throw error("renameat_record") }
    guard vb_fsync_fd(runFD) == 0 else { throw error("fsync_run") }
  }

  private static func writeAll(_ data: Data, fd: Int32) throws {
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let result = vb_write_bytes(
          fd, bytes.baseAddress!.advanced(by: offset), Int32(bytes.count - offset))
        if result > 0 {
          offset += Int(result)
          continue
        }
        if result < 0 && errno == EINTR { continue }
        throw error("write_record")
      }
    }
  }

  private static func rejectSymlink(runFD: Int32, name: String) throws {
    let result = name.withCString { vb_is_symlink_at(runFD, $0) }
    if result == 1 { throw SharedStoreLeaseError.symlinkDetected }
    if result == -1 && errno != ENOENT { throw error("fstatat") }
  }
  private static func validClientID(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 128
      && value.unicodeScalars.allSatisfy { $0.value >= 0x21 && $0.value <= 0x7E }
  }
  private static func error(_ operation: String) -> SharedStoreLeaseError {
    .io(operation: operation, code: errno)
  }
  private static func reserveHeldKey(_ key: String) -> Bool {
    heldLock.lock()
    defer { heldLock.unlock() }
    return heldExclusive.insert(key).inserted
  }
  private static func releaseHeldKey(_ key: String) {
    heldLock.lock()
    heldExclusive.remove(key)
    heldLock.unlock()
  }
}
