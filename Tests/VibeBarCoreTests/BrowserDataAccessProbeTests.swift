import Foundation
import SweetCookieKit
import Testing
@testable import VibeBarCore

struct BrowserDataAccessProbeTests {
    @Test func deniedDirectoryIsNotMissing() {
        let probe = BrowserDataAccessProbe(homeDirectory: "/synthetic", listDirectory: { _ in
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        }, readFile: { _ in Issue.record("Must not read after enumeration fails") })
        #expect(probe.check(.chrome) == .denied)
    }

    @Test func absentDirectoryIsMissing() {
        let probe = BrowserDataAccessProbe(homeDirectory: "/synthetic", listDirectory: { _ in
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
        })
        #expect(probe.check(.chrome) == .missing)
    }

    @Test func existingStoreCanStillDenyReads() {
        let probe = BrowserDataAccessProbe(homeDirectory: "/synthetic", listDirectory: { _ in ["Default"] }, readFile: { _ in
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        })
        #expect(probe.check(.chrome) == .denied)
    }

    @Test func networkCookieStoreIsReadableWithMissingLegacyStore() {
        let probe = BrowserDataAccessProbe(homeDirectory: "/synthetic", listDirectory: { _ in ["Default"] }, readFile: { path in
            if !path.hasSuffix("Network/Cookies") { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT)) }
        })
        #expect(probe.check(.chrome) == .readable)
    }

    @Test func inaccessibleSecondProfileIsReported() {
        let probe = BrowserDataAccessProbe(homeDirectory: "/synthetic", listDirectory: { _ in ["Default", "Profile 1"] }, readFile: { path in
            if path.contains("Profile 1") { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)) }
        })
        #expect(probe.check(.chrome) == .partial)
    }

    @Test func unrelatedIOErrorIsNotPermissionDenial() {
        let probe = BrowserDataAccessProbe(homeDirectory: "/synthetic", listDirectory: { _ in ["Default"] }, readFile: { _ in
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
        })
        #expect(probe.check(.chrome) == .failed)
    }

    @Test func actualFileReadDoesNotModifyStore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = root.appendingPathComponent("Library/Application Support/Google/Chrome/Default/Network")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let file = profile.appendingPathComponent("Cookies")
        let contents = Data("synthetic-cookie-store".utf8)
        try contents.write(to: file)
        #expect(BrowserDataAccessProbe(homeDirectory: root.path).check(.chrome) == .readable)
        #expect(try Data(contentsOf: file) == contents)
    }
}
