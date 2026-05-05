import Foundation

public enum ClaudeWebCookieStore {
    private static let service = "Vibe Bar Claude Web Cookies"
    private static let account = "claude.ai"

    public static func readCookieHeader() throws -> String {
        if let header = candidateCookieHeaders().first {
            return header
        }
        throw QuotaError.noCredential
    }

    public static func candidateCookieHeaders() -> [String] {
        var headers: [String] = []
        appendCookieHeader(try? VibeBarLocalStore.readString(from: VibeBarLocalStore.claudeCookieURL), to: &headers)
        appendCookieHeader(try? KeychainStore.readString(service: service, account: account), to: &headers)
        return unique(headers)
    }

    public static func writeCookieHeader(_ header: String) throws {
        let trimmed = normalizedCookieHeader(from: header)
        guard !trimmed.isEmpty else { throw QuotaError.noCredential }
        try VibeBarLocalStore.writeString(trimmed, to: VibeBarLocalStore.claudeCookieURL)
        try? KeychainStore.deleteItem(service: service, account: account)
    }

    public static func hasCookieHeader() -> Bool {
        (try? readCookieHeader()) != nil
    }

    public static func deleteCookieHeader() throws {
        try VibeBarLocalStore.deleteFile(at: VibeBarLocalStore.claudeCookieURL)
        try VibeBarLocalStore.deleteFile(at: VibeBarLocalStore.claudeOrganizationIDURL)
        try? KeychainStore.deleteItem(service: service, account: account)
    }

    public static func readOrganizationID() -> String? {
        guard let raw = try? VibeBarLocalStore.readString(from: VibeBarLocalStore.claudeOrganizationIDURL) else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func writeOrganizationID(_ organizationID: String) throws {
        let trimmed = organizationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try VibeBarLocalStore.writeString(trimmed, to: VibeBarLocalStore.claudeOrganizationIDURL)
    }

    public static func sessionKeyHeader(from header: String) -> String? {
        for pair in cookiePairs(from: header) where pair.name == "sessionKey" {
            let value = pair.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            return "sessionKey=\(value)"
        }
        return nil
    }

    public static func normalizedCookieHeader(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.localizedCaseInsensitiveContains("Cookie:") {
            return trimmed
                .replacingOccurrences(of: "Cookie:", with: "", options: [.caseInsensitive])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    private static func appendCookieHeader(_ raw: String?, to headers: inout [String]) {
        guard let raw else { return }
        let header = normalizedCookieHeader(from: raw)
        guard !header.isEmpty else { return }
        if let sessionOnly = sessionKeyHeader(from: header) {
            headers.append(sessionOnly)
        }
        headers.append(header)
    }

    private static func cookiePairs(from header: String) -> [(name: String, value: String)] {
        normalizedCookieHeader(from: header)
            .split(separator: ";")
            .compactMap { part in
                let pieces = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard pieces.count == 2 else { return nil }
                return (
                    name: pieces[0].trimmingCharacters(in: .whitespacesAndNewlines),
                    value: pieces[1].trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
    }

    private static func unique(_ headers: [String]) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for header in headers where seen.insert(header).inserted {
            out.append(header)
        }
        return out
    }
}
