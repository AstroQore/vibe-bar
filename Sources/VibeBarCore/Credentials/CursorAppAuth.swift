import Foundation
import SQLite3

/// Read-only view of Cursor.app's local login session.
///
/// Cursor stores its access token in the VS Code-style global state database.
/// Vibe Bar never refreshes or rewrites that token: it only derives the
/// first-party `WorkosCursorSessionToken` cookie accepted by cursor.com.
struct CursorAppAuthSession: Sendable, Equatable {
    let accessToken: String

    var identity: CursorAppAuthIdentity? {
        try? CursorAppAuthIdentity(jwt: accessToken)
    }

    func isUsable(now: Date = Date()) -> Bool {
        guard let identity, let expiresAt = identity.expiresAt else { return false }
        return !identity.userID.isEmpty && expiresAt.timeIntervalSince(now) > 60
    }

    func cookieHeader() throws -> String {
        let identity = try CursorAppAuthIdentity(jwt: accessToken)
        guard !identity.userID.isEmpty else { throw CursorAppAuthError.missingUserID }
        return "WorkosCursorSessionToken=\(identity.userID)%3A%3A\(accessToken)"
    }
}

struct CursorAppAuthIdentity: Sendable, Equatable {
    let userID: String
    let email: String?
    let expiresAt: Date?

    init(jwt: String) throws {
        let components = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 2 else { throw CursorAppAuthError.invalidJWT }

        var payload = String(components[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw CursorAppAuthError.invalidJWT
        }

        let subject = (object["sub"] as? String) ?? ""
        let candidate = subject.split(separator: "|", omittingEmptySubsequences: true).last.map(String.init) ?? ""
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard !candidate.isEmpty,
              candidate.unicodeScalars.allSatisfy(allowed.contains)
        else {
            throw CursorAppAuthError.missingUserID
        }

        self.userID = candidate
        self.email = (object["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.expiresAt = (object["exp"] as? NSNumber).map {
            Date(timeIntervalSince1970: $0.doubleValue)
        }
    }
}

enum CursorAppAuthError: Error {
    case invalidJWT
    case missingUserID
    case sqlite(String)
}

/// Opens Cursor.app's global-state SQLite database strictly read-only.
struct CursorAppAuthStore: Sendable {
    private let dbPath: String

    init(
        homeDirectory: String = RealHomeDirectory.path,
        dbPath: String? = nil
    ) {
        self.dbPath = dbPath ?? URL(fileURLWithPath: homeDirectory, isDirectory: true)
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
            .path
    }

    func loadSession(now: Date = Date()) throws -> CursorAppAuthSession? {
        guard FileManager.default.fileExists(atPath: dbPath),
              let token = try value(for: "cursorAuth/accessToken")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty
        else {
            return nil
        }
        let session = CursorAppAuthSession(accessToken: token)
        return session.isUsable(now: now) ? session : nil
    }

    private func value(for key: String) throws -> String? {
        do {
            return try value(for: key, immutable: false)
        } catch {
            let walMissing = !FileManager.default.fileExists(atPath: dbPath + "-wal")
                && !FileManager.default.fileExists(atPath: dbPath + "-shm")
            guard walMissing else { throw error }
            return try value(for: key, immutable: true)
        }
    }

    private func value(for key: String, immutable: Bool) throws -> String? {
        var database: OpaquePointer?
        let databaseURL = URL(fileURLWithPath: dbPath, isDirectory: false).absoluteURL
        let filename = immutable ? "\(databaseURL.absoluteString)?immutable=1" : dbPath
        let flags = immutable ? SQLITE_OPEN_READONLY | SQLITE_OPEN_URI : SQLITE_OPEN_READONLY
        guard sqlite3_open_v2(filename, &database, flags, nil) == SQLITE_OK else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(database)
            throw CursorAppAuthError.sqlite(message)
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 250)

        let sql = "SELECT value FROM ItemTable WHERE key = ? LIMIT 1;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw CursorAppAuthError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, cursorSQLiteTransient)

        switch sqlite3_step(statement) {
        case SQLITE_DONE:
            return nil
        case SQLITE_ROW:
            switch sqlite3_column_type(statement, 0) {
            case SQLITE_TEXT:
                guard let bytes = sqlite3_column_text(statement, 0) else { return nil }
                return String(cString: bytes)
            case SQLITE_BLOB:
                guard let bytes = sqlite3_column_blob(statement, 0) else { return nil }
                let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
                return String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .utf16LittleEndian)
            default:
                return nil
            }
        default:
            throw CursorAppAuthError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
    }
}

private let cursorSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
