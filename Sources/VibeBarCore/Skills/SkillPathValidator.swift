import Foundation

/// Gatekeeper for every skill directory name that reaches the filesystem.
///
/// A skill name must be exactly one path component. Rejecting `..`, embedded
/// separators, and leading dots here is what lets the sync engine treat
/// `<root>/<name>` as guaranteed-inside-`<root>` before it does anything
/// destructive; the write-root assertion in the engine is the second line of
/// defense, not the first.
public enum SkillPathValidator {
    public static func validate(directoryName: String) throws {
        guard isValid(directoryName) else {
            throw SkillError.invalidDirectoryName(directoryName)
        }
    }

    public static func isValid(_ directoryName: String) -> Bool {
        guard !directoryName.isEmpty else { return false }
        guard directoryName != "." && directoryName != ".." else { return false }
        guard !directoryName.hasPrefix(".") else { return false }
        guard !directoryName.contains("/") && !directoryName.contains("\\") else { return false }
        for scalar in directoryName.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F { return false }
        }
        return true
    }
}
