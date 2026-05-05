import Foundation

public enum EmailMasker {
    public static func mask(_ email: String?) -> String {
        guard let raw = email?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return ""
        }
        guard let atIdx = raw.firstIndex(of: "@") else {
            let first = raw.first.map { String($0) } ?? ""
            return first + String(repeating: "•", count: max(0, raw.count - 1))
        }

        let localPart = String(raw[raw.startIndex..<atIdx])
        let domainPart = String(raw[raw.index(after: atIdx)...])

        guard let firstChar = localPart.first else {
            return "•@\(domainPart)"
        }

        if localPart.count <= 1 {
            return "\(firstChar)@\(domainPart)"
        }

        let bulletCount = max(4, min(localPart.count - 1, 4))
        let bullets = String(repeating: "•", count: bulletCount)
        return "\(firstChar)\(bullets)@\(domainPart)"
    }

    public static func maybeMask(_ email: String?, showFull: Bool) -> String {
        if showFull { return email ?? "" }
        return mask(email)
    }
}
