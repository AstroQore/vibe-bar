import Foundation
import SQLite3

/// Minimal SQLite plumbing shared by the two usage-timeline stores.
///
/// Not an actor: each store actor owns exactly one instance, so all access is
/// already serialized. The connection is opened with FULLMUTEX anyway so a
/// stray hop can never corrupt the handle.
final class TimelineSQLite {
    let handle: OpaquePointer
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init?(url: URL) {
        var opened: OpaquePointer?
        guard sqlite3_open_v2(
            url.path,
            &opened,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let opened else {
            if opened != nil { sqlite3_close_v2(opened) }
            return nil
        }
        sqlite3_busy_timeout(opened, 5_000)
        handle = opened
    }

    func close() {
        sqlite3_close_v2(handle)
    }

    @discardableResult
    func exec(_ sql: String) -> Bool {
        sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK
    }

    func prepare(_ sql: String) -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            if statement != nil { sqlite3_finalize(statement) }
            return nil
        }
        return statement
    }

    var userVersion: Int32 {
        get {
            guard let statement = prepare("PRAGMA user_version") else { return 0 }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
            return sqlite3_column_int(statement, 0)
        }
        set {
            exec("PRAGMA user_version = \(newValue)")
        }
    }

    func bindText(_ statement: OpaquePointer, _ index: Int32, _ value: String) {
        sqlite3_bind_text(statement, index, value, -1, transient)
    }

    func bindDouble(_ statement: OpaquePointer, _ index: Int32, _ value: Double) {
        sqlite3_bind_double(statement, index, value)
    }

    func bindOptionalDouble(_ statement: OpaquePointer, _ index: Int32, _ value: Double?) {
        if let value {
            sqlite3_bind_double(statement, index, value)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    func bindOptionalInt(_ statement: OpaquePointer, _ index: Int32, _ value: Int?) {
        if let value {
            sqlite3_bind_int64(statement, index, Int64(value))
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    func columnText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let raw = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: raw)
    }

    func columnOptionalDouble(_ statement: OpaquePointer, _ index: Int32) -> Double? {
        sqlite3_column_type(statement, index) == SQLITE_NULL
            ? nil
            : sqlite3_column_double(statement, index)
    }

    func columnOptionalInt(_ statement: OpaquePointer, _ index: Int32) -> Int? {
        sqlite3_column_type(statement, index) == SQLITE_NULL
            ? nil
            : Int(sqlite3_column_int64(statement, index))
    }
}
