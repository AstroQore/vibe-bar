import AppKit
import XCTest

final class ProviderIconResourcesTests: XCTestCase {
    func testProviderIconSVGsExistAndLoad() throws {
        let root = try repoRoot()
        let resources = root
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("ProviderIcons", isDirectory: true)

        let slugs = [
            "codex",
            "claude",
            "alibaba",
            "gemini",
            "antigravity",
            "copilot",
            "zai",
            "minimax",
            "kimi",
            "cursor",
            "mimo",
            "iflytek",
            "tencentHunyuan",
            "volcengine"
        ]

        for slug in slugs {
            let url = resources.appendingPathComponent("ProviderIcon-\(slug).svg")
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: url.path),
                "Missing SVG for \(slug)"
            )
            XCTAssertNotNil(NSImage(contentsOf: url), "Could not load SVG for \(slug)")
        }
    }

    private func repoRoot() throws -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<12 {
            let candidate = dir.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return dir
            }
            dir.deleteLastPathComponent()
        }
        throw NSError(
            domain: "ProviderIconResourcesTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not locate repo root from \(#filePath)"]
        )
    }
}
