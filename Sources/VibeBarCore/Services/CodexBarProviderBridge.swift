import Foundation

/// Read-only compatibility bridge for providers implemented by an installed
/// CodexBar CLI but not yet native to Vibe Bar.
///
/// CodexBar's `dashboard` command is its stable machine contract. Calling it
/// avoids importing the upstream plugin runtime, QuickJS host, credential
/// registry, and dozens of provider-specific settings types just to expose the
/// already-configured providers on this Mac. Native Vibe Bar providers are
/// filtered out so this never overrides their account, hierarchy, Keychain,
/// history, or refresh semantics.
public actor CodexBarProviderBridge {
    public struct Snapshot: Sendable {
        public let generatedAt: Date
        public let version: String?
        public let providers: [Provider]
    }

    public struct Provider: Sendable, Identifiable {
        public let id: String
        public let name: String
        public let source: String
        public let windows: [Window]
    }

    public struct Window: Sendable, Identifiable {
        public let id: String
        public let label: String
        public let usedPercent: Double
        public let resetAt: Date?
    }

    public enum BridgeError: Error, LocalizedError, Sendable {
        case notInstalled
        case commandFailed
        case invalidPayload
        case payloadTooLarge

        public var errorDescription: String? {
            switch self {
            case .notInstalled: "CodexBar CLI is not installed."
            case .commandFailed: "CodexBar could not refresh its provider dashboard."
            case .invalidPayload: "CodexBar returned an unsupported dashboard payload."
            case .payloadTooLarge: "CodexBar returned a dashboard payload that was too large."
            }
        }
    }

    public static let shared = CodexBarProviderBridge()

    /// Provider ids Vibe Bar already owns natively. Keep this explicit: ids
    /// describe upstream surfaces, not vendor names (`grok` and `xai`,
    /// `codex` and `openai`, remain intentionally distinct).
    private static let nativeProviderIDs: Set<String> = [
        "codex", "claude", "cursor", "opencodego", "alibaba",
        "alibabatokenplan", "gemini", "antigravity", "copilot", "zai",
        "minimax", "kimi", "kilo", "kiro", "ollama", "openrouter",
        "mimo", "warp", "grok",
    ]

    private static let maximumPayloadBytes = 8 * 1024 * 1024

    public nonisolated static var isInstalled: Bool {
        !DemoMode.isEnabled && binaryPath != nil
    }

    public func fetch(timeout: TimeInterval = 55) async throws -> Snapshot {
        guard !DemoMode.isEnabled else { throw BridgeError.notInstalled }
        guard let binary = Self.binaryPath else { throw BridgeError.notInstalled }
        let result = try await ProcessRunner.run(
            binary: binary,
            arguments: [
                "dashboard",
                "--identity", "redacted",
                "--timeout", String(Int(max(5, timeout - 5))),
            ],
            timeout: timeout,
            label: "CodexBar provider bridge"
        )
        guard result.terminationStatus == 0 else { throw BridgeError.commandFailed }
        guard let data = result.stdout.data(using: .utf8),
              data.count <= Self.maximumPayloadBytes
        else { throw BridgeError.payloadTooLarge }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: raw) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: raw) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date")
        }
        guard let payload = try? decoder.decode(DashboardPayload.self, from: data),
              payload.schemaVersion == 1
        else { throw BridgeError.invalidPayload }

        let providers = payload.providers.compactMap { provider -> Provider? in
            guard provider.enabled,
                  !Self.nativeProviderIDs.contains(provider.id.lowercased())
            else { return nil }
            let windows = provider.windows.compactMap { window -> Window? in
                guard window.idle != true, window.usedPercent.isFinite else { return nil }
                return Window(
                    id: "\(provider.id):\(window.kind):\(window.label)",
                    label: window.label,
                    usedPercent: max(0, min(100, window.usedPercent)),
                    resetAt: window.resetAt
                )
            }
            guard !windows.isEmpty else { return nil }
            return Provider(
                id: provider.id,
                name: provider.name,
                source: provider.source,
                windows: windows
            )
        }
        return Snapshot(
            generatedAt: payload.generatedAt,
            version: payload.host.codexBarVersion,
            providers: providers
        )
    }

    private nonisolated static var binaryPath: String? {
        let candidates = [
            "/opt/homebrew/bin/codexbar",
            "/usr/local/bin/codexbar",
            "/usr/bin/codexbar",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private struct DashboardPayload: Decodable {
        let schemaVersion: Int
        let generatedAt: Date
        let host: Host
        let providers: [ProviderPayload]
    }

    private struct Host: Decodable {
        let codexBarVersion: String?
    }

    private struct ProviderPayload: Decodable {
        let id: String
        let name: String
        let enabled: Bool
        let source: String
        let windows: [WindowPayload]
    }

    private struct WindowPayload: Decodable {
        let kind: String
        let label: String
        let usedPercent: Double
        let resetAt: Date?
        let idle: Bool?
    }
}
