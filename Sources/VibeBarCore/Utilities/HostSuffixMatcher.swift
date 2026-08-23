import Foundation

/// Exact-or-subdomain matching for trusted web-login origins.
///
/// Requiring the dot boundary keeps lookalikes such as `evilkimi.com`
/// outside a `kimi.com` allowlist.
public enum HostSuffixMatcher {
    public static func matches(_ rawHost: String?, allowedSuffixes: [String]) -> Bool {
        guard let host = rawHost?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !host.isEmpty else {
            return false
        }
        return allowedSuffixes.contains { rawSuffix in
            let lowered = rawSuffix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let suffix = lowered.hasPrefix(".") ? String(lowered.dropFirst()) : lowered
            guard !suffix.isEmpty else { return false }
            return host == suffix || host.hasSuffix("." + suffix)
        }
    }
}
