import XCTest
import SQLite3
@testable import VibeBarCore

final class CursorAppAuthTests: XCTestCase {
    func testReadsUsableSessionAndBuildsFirstPartyCookie() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeBarCursorAuth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("state.vscdb")
        let token = try makeJWT(expiration: Date(timeIntervalSince1970: 2_000_000_000))
        try writeDatabase(database, token: token)

        let session = try XCTUnwrap(
            CursorAppAuthStore(dbPath: database.path).loadSession(
                now: Date(timeIntervalSince1970: 1_900_000_000)
            )
        )
        XCTAssertEqual(session.identity?.userID, "user_fixture")
        XCTAssertEqual(session.identity?.email, "cursor@example.invalid")
        XCTAssertEqual(
            try session.cookieHeader(),
            "WorkosCursorSessionToken=user_fixture%3A%3A\(token)"
        )
    }

    func testExpiredSessionFailsClosed() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeBarCursorAuthExpired-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("state.vscdb")
        try writeDatabase(
            database,
            token: makeJWT(expiration: Date(timeIntervalSince1970: 1_800_000_000))
        )

        XCTAssertNil(try CursorAppAuthStore(dbPath: database.path).loadSession(
            now: Date(timeIntervalSince1970: 1_900_000_000)
        ))
    }

    private func writeDatabase(_ url: URL, token: String) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(
            sqlite3_exec(database, "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value BLOB);", nil, nil, nil),
            SQLITE_OK
        )
        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(database, "INSERT INTO ItemTable(key, value) VALUES(?, ?);", -1, &statement, nil),
            SQLITE_OK
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, "cursorAuth/accessToken", -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, token, -1, SQLITE_TRANSIENT)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
    }

    private func makeJWT(expiration: Date) throws -> String {
        let header = try JSONSerialization.data(withJSONObject: ["alg": "none"])
        let payload = try JSONSerialization.data(withJSONObject: [
            "sub": "auth0|user_fixture",
            "email": "cursor@example.invalid",
            "exp": expiration.timeIntervalSince1970
        ])
        return "\(base64URL(header)).\(base64URL(payload)).signature"
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
