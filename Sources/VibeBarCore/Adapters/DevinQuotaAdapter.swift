import Foundation

/// Cognition · Devin quota adapter.
///
/// Devin's CLI keeps the account's `GetUserStatus` answer on disk at
/// `~/.cache/devin/cli/user_status.<identity>.bin` — the same answer its own
/// `/usage` view draws from — and refreshes it while Devin runs (the desktop
/// app's local agent runs the CLI too). Reading that file is the whole
/// adapter: no network, no credential, and nothing that would have to pose as
/// Devin's own client. The cost is freshness: the quota is as recent as
/// Devin's last run, and `queriedAt` carries the cache's own timestamp so the
/// card says exactly that.
///
/// Nothing is written.
public struct DevinQuotaAdapter: QuotaAdapter {
    public let tool: ToolType = .devin

    private let homeDirectory: String

    public init(homeDirectory: String = RealHomeDirectory.path) {
        self.homeDirectory = homeDirectory
    }

    public func fetch(for account: AccountIdentity) async throws -> AccountQuota {
        guard let cache = DevinUserStatusCache.newest(homeDirectory: homeDirectory) else {
            throw QuotaError.noCredential
        }
        let snapshot = try DevinPlanStatusParser.parse(payload: cache.payload)
        return AccountQuota(
            accountId: account.id,
            tool: .devin,
            buckets: snapshot.buckets,
            plan: snapshot.planName ?? account.plan,
            email: account.email,
            queriedAt: cache.fetchedAt
        )
    }
}

/// `~/.cache/devin/cli/user_status.<identity digest>.bin`: a small JSON
/// envelope `{version, identity_digest, fetched_at_secs, payload}` whose
/// `payload` is the base64 protobuf `UserStatus`. One file per signed-in
/// identity; the newest fetch is the account in use.
public enum DevinUserStatusCache {
    public struct Entry: Sendable {
        public let fetchedAt: Date
        public let payload: Data
    }

    static let relativeDirectory = ".cache/devin/cli"
    /// A status file is a few hundred kilobytes; anything far larger is not
    /// one.
    static let maxBytes = 8 * 1_048_576

    public static func directory(homeDirectory: String) -> URL {
        URL(fileURLWithPath: homeDirectory, isDirectory: true)
            .appendingPathComponent(relativeDirectory, isDirectory: true)
    }

    public static func exists(homeDirectory: String = RealHomeDirectory.path) -> Bool {
        !candidateFiles(homeDirectory: homeDirectory).isEmpty
    }

    public static func newest(homeDirectory: String = RealHomeDirectory.path) -> Entry? {
        candidateFiles(homeDirectory: homeDirectory)
            .compactMap(read)
            .max { $0.fetchedAt < $1.fetchedAt }
    }

    static func candidateFiles(homeDirectory: String) -> [URL] {
        let directory = directory(homeDirectory: homeDirectory)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { $0.hasPrefix("user_status.") && $0.hasSuffix(".bin") }
            .map { directory.appendingPathComponent($0) }
    }

    static func read(_ url: URL) -> Entry? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.intValue, size > 0, size <= maxBytes,
              let data = try? Data(contentsOf: url)
        else { return nil }
        return parse(envelope: data)
    }

    static func parse(envelope data: Data) -> Entry? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let encoded = root["payload"] as? String,
              let payload = Data(base64Encoded: encoded),
              let seconds = (root["fetched_at_secs"] as? NSNumber)?.doubleValue, seconds > 0
        else { return nil }
        return Entry(fetchedAt: Date(timeIntervalSince1970: seconds), payload: payload)
    }
}

/// Decodes the plan half of Devin's `UserStatus` protobuf. Only numbers and
/// the plan's display name are read; the message also carries the account's
/// identity, which never leaves the parse.
///
/// `UserStatus` field 13 is `PlanStatus`:
/// - `1` `PlanInfo` → `2` plan name ("Pro")
/// - `14` / `15` daily / weekly quota **remaining** percent
/// - `17` / `18` daily / weekly reset, unix seconds
///
/// proto3 does not write zero, so a spent window arrives with its reset but no
/// percent. A window with neither is one the plan does not have (Max, for
/// example, has only the weekly one).
public enum DevinPlanStatusParser {
    public struct Snapshot: Sendable, Equatable {
        public let buckets: [QuotaBucket]
        public let planName: String?
    }

    static let dailyRemainingField = 14
    static let weeklyRemainingField = 15
    static let dailyResetField = 17
    static let weeklyResetField = 18

    public static func parse(payload: Data) throws -> Snapshot {
        guard let status = ProtobufFields(payload),
              let planStatus = status.message(13).flatMap(ProtobufFields.init)
        else { throw QuotaError.parseFailure("Devin plan status is not readable") }

        let planName = planStatus.message(1)
            .flatMap(ProtobufFields.init)?
            .string(2)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var buckets: [QuotaBucket] = []
        if let bucket = window(
            id: "daily", title: "Daily", seconds: 86_400,
            remaining: planStatus.varint(dailyRemainingField),
            reset: planStatus.varint(dailyResetField)
        ) {
            buckets.append(bucket)
        }
        if let bucket = window(
            id: "weekly", title: "Weekly", seconds: 604_800,
            remaining: planStatus.varint(weeklyRemainingField),
            reset: planStatus.varint(weeklyResetField)
        ) {
            buckets.append(bucket)
        }
        guard !buckets.isEmpty else {
            throw QuotaError.parseFailure("Devin plan status has no quota windows")
        }
        return Snapshot(buckets: buckets, planName: planName?.isEmpty == false ? planName : nil)
    }

    private static func window(
        id: String,
        title: String,
        seconds: Int,
        remaining: UInt64?,
        reset: UInt64?
    ) -> QuotaBucket? {
        guard remaining != nil || reset != nil else { return nil }
        let left = min(100, Double(remaining ?? 0))
        return QuotaBucket(
            id: id,
            title: title,
            shortLabel: title,
            usedPercent: 100 - left,
            resetAt: reset.flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil },
            rawWindowSeconds: seconds
        )
    }
}

/// The last occurrence of each top-level field in one protobuf message —
/// enough to read a handful of scalar and nested fields without generated
/// code. Malformed input yields `nil` rather than a partial read.
struct ProtobufFields {
    private var varints: [Int: UInt64] = [:]
    private var bytes: [Int: Data] = [:]

    init?(_ data: Data) {
        let buffer = [UInt8](data)
        var index = 0
        while index < buffer.count {
            guard let key = Self.varint(buffer, &index) else { return nil }
            let field = Int(key >> 3)
            switch key & 7 {
            case 0:
                guard let value = Self.varint(buffer, &index) else { return nil }
                varints[field] = value
            case 1:
                guard index + 8 <= buffer.count else { return nil }
                index += 8
            case 2:
                guard let length = Self.varint(buffer, &index), length <= UInt64(buffer.count - index) else {
                    return nil
                }
                let end = index + Int(length)
                bytes[field] = Data(buffer[index..<end])
                index = end
            case 5:
                guard index + 4 <= buffer.count else { return nil }
                index += 4
            default:
                return nil
            }
        }
    }

    func varint(_ field: Int) -> UInt64? { varints[field] }
    func message(_ field: Int) -> Data? { bytes[field] }
    func string(_ field: Int) -> String? { bytes[field].flatMap { String(data: $0, encoding: .utf8) } }

    private static func varint(_ buffer: [UInt8], _ index: inout Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while index < buffer.count, shift < 64 {
            let byte = buffer[index]
            index += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        return nil
    }
}
