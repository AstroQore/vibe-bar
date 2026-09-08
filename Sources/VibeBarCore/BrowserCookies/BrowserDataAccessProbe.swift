import Foundation
import SweetCookieKit

/// A point-in-time file read check, not a TCC authorization query. No cookies
/// are decoded, returned or logged. Run only after an explicit user action.
public struct BrowserDataAccessProbe: Sendable {
    public enum Status: String, Sendable {
        case readable, denied, missing, failed, partial
    }

    private let homeDirectory: String
    private let listDirectory: @Sendable (String) throws -> [String]
    private let readFile: @Sendable (String) throws -> Void

    public init(
        homeDirectory: String = RealHomeDirectory.path,
        listDirectory: @escaping @Sendable (String) throws -> [String] = {
            try FileManager.default.contentsOfDirectory(atPath: $0)
        },
        readFile: @escaping @Sendable (String) throws -> Void = {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: $0))
            defer { try? handle.close() }
            _ = try handle.read(upToCount: 1)
        }
    ) {
        self.homeDirectory = homeDirectory
        self.listDirectory = listDirectory
        self.readFile = readFile
    }

    public func check(_ browser: Browser) -> Status {
        if browser == .safari {
            return combine([
                checkFile("\(homeDirectory)/Library/Cookies/Cookies.binarycookies"),
                checkFile("\(homeDirectory)/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies")
            ])
        }
        let root: String
        let gecko = browser.usesGeckoProfileStore
        if let relative = browser.chromiumProfileRelativePath {
            root = "\(homeDirectory)/Library/Application Support/\(relative)"
        } else if let folder = browser.geckoProfilesFolder {
            root = "\(homeDirectory)/Library/Application Support/\(folder)/Profiles"
        } else {
            return .failed
        }
        do {
            // Enumerate first: fileExists() silently turns permission errors
            // into false and would misreport a protected store as missing.
            let names = try listDirectory(root)
            let profiles = names.filter {
                gecko || $0 == "Default" || $0.hasPrefix("Profile ") || $0.hasPrefix("user-")
            }
            var results: [Status] = []
            for profile in profiles {
                let base = "\(root)/\(profile)"
                if gecko {
                    results.append(checkFile("\(base)/cookies.sqlite"))
                } else {
                    results.append(combine([
                        checkFile("\(base)/Cookies"),
                        checkFile("\(base)/Network/Cookies")
                    ]))
                }
            }
            return combine(results)
        } catch {
            return Self.classify(error)
        }
    }

    private func checkFile(_ path: String) -> Status {
        do {
            try readFile(path)
            return .readable
        } catch {
            return Self.classify(error)
        }
    }

    private func combine(_ results: [Status]) -> Status {
        let readable = results.contains(.readable) || results.contains(.partial)
        let inaccessible = results.contains(.denied) || results.contains(.failed) || results.contains(.partial)
        if readable { return inaccessible ? .partial : .readable }
        if results.contains(.denied) { return .denied }
        if results.contains(.failed) { return .failed }
        return .missing
    }

    private static func classify(_ error: Error) -> Status {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain {
            if error.code == NSFileReadNoPermissionError { return .denied }
            if error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError { return .missing }
        }
        if error.domain == NSPOSIXErrorDomain {
            if error.code == Int(EACCES) || error.code == Int(EPERM) { return .denied }
            if error.code == Int(ENOENT) || error.code == Int(ENOTDIR) { return .missing }
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return classify(underlying)
        }
        return .failed
    }
}
