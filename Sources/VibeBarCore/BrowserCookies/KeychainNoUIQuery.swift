import Foundation
import Darwin
import LocalAuthentication
import Security

/// Apply the "no UI, no prompt" knobs to a `SecItemCopyMatching`
/// query. Used by `KeychainAccessPreflight` and the misc-providers'
/// Keychain-backed caches so an idle background refresh never pops a
/// system Keychain dialog at the user.
///
/// Ported from codexbar `KeychainNoUIQuery.swift` (vibe-bar is
/// macOS-only, so the cross-platform `#if` is dropped).
enum KeychainNoUIQuery {
    private static let uiFailPolicy = KeychainNoUIQuery.resolveUIFailPolicy()

    static func apply(to query: inout [String: Any]) {
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context

        // Some macOS versions still surface an Allow/Deny prompt with
        // `interactionNotAllowed` alone. Pinning the "fail" UI policy
        // closes that gap at the cost of resolving a soft-deprecated
        // Security symbol at runtime instead of compile time.
        query[kSecUseAuthenticationUI as String] = uiFailPolicy as CFString
    }

    private static func resolveUIFailPolicy() -> String {
        let securityPath = "/System/Library/Frameworks/Security.framework/Security"
        guard let handle = dlopen(securityPath, RTLD_NOW) else {
            return "u_AuthUIF"
        }
        defer { dlclose(handle) }

        guard let symbol = dlsym(handle, "kSecUseAuthenticationUIFail") else {
            return "u_AuthUIF"
        }
        let valuePointer = symbol.assumingMemoryBound(to: CFString?.self)
        return (valuePointer.pointee as String?) ?? "u_AuthUIF"
    }
}
