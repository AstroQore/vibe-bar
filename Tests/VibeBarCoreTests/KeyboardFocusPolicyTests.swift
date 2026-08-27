import XCTest

/// Source-level checks for the keyboard focus policy in `VibeBarApp`.
///
/// The App target is an executable, so its views cannot be imported here;
/// these tests read the sources instead. What they pin down:
///
/// 1. Every presentation — the two hosting roots plus every `.sheet` and
///    `.popover` — opts into `vibeBarNoInitialFocus()`, so no surface opens
///    with a control pre-selected. Adding a presentation without the policy
///    breaks the count on purpose.
/// 2. The policy clears only the initial responder. It must never reorder
///    or rebuild the key-view loop, and never watch key-window changes —
///    that is what keeps Tab/arrow navigation intact and keeps an app
///    switch from erasing a text field the user is editing.
/// 3. No product control opts out of keyboard navigation with
///    `.focusable(false)`. Suppressing the system focus ring is the job of
///    the container-level `vibeBarControlFocus()` plus the focus hairline
///    in `VibeBarButtonStyle`, not of removing controls from the loop.
final class KeyboardFocusPolicyTests: XCTestCase {
    func testEveryPresentationOptsIntoTheInitialFocusPolicy() throws {
        let sources = try appSources()

        let presentationCount = sources.values.reduce(into: 0) { count, source in
            count += source.numberOfOccurrences(of: ".sheet(isPresented")
            count += source.numberOfOccurrences(of: ".popover(isPresented")
        }

        // The two AppKit hosting roots that can become key: the menu-bar
        // popover and the Workbench window. The mini window's hosting root
        // is deliberately absent — its panel is borderless and
        // non-activating, so it never receives an initial responder.
        let popoverHost = try XCTUnwrap(sources["StatusItemController.swift"])
        let workbenchHost = try XCTUnwrap(sources["WorkbenchWindowController.swift"])
        let miniWindowHost = try XCTUnwrap(sources["MiniQuotaWindowController.swift"])
        XCTAssertEqual(popoverHost.numberOfOccurrences(of: ".vibeBarNoInitialFocus()"), 1)
        XCTAssertEqual(workbenchHost.numberOfOccurrences(of: ".vibeBarNoInitialFocus()"), 1)
        XCTAssertEqual(miniWindowHost.numberOfOccurrences(of: ".vibeBarNoInitialFocus()"), 0)
        let hostingRootCount = 2

        let policyCount = sources.values.reduce(0) {
            $0 + $1.numberOfOccurrences(of: ".vibeBarNoInitialFocus()")
        }

        XCTAssertEqual(
            policyCount,
            presentationCount + hostingRootCount,
            "Every hosting root, sheet, and popover must attach .vibeBarNoInitialFocus() "
                + "to its content (and nothing else should)."
        )
    }

    func testPolicyClearsOnlyTheResponderAndLeavesTraversalIntact() throws {
        let sources = try appSources()
        let source = try XCTUnwrap(sources["InitialFocusPolicy.swift"])

        XCTAssertTrue(source.contains("makeFirstResponder(nil)"))
        XCTAssertFalse(source.contains("initialFirstResponder"))
        XCTAssertFalse(source.contains("nextKeyView"))
        XCTAssertFalse(source.contains("didBecomeKeyNotification"))
    }

    func testNoProductControlOptsOutOfKeyboardNavigation() throws {
        let root = try repoRoot().appendingPathComponent("Sources", isDirectory: true)
        for (file, source) in try swiftSources(under: root) {
            XCTAssertEqual(
                source.numberOfOccurrences(of: ".focusable(false)"),
                0,
                "\(file) removes a control from keyboard navigation; use the "
                    + "container-level vibeBarControlFocus() and VibeBarButtonStyle instead."
            )
        }
    }

    // MARK: - Source loading

    private func appSources() throws -> [String: String] {
        let root = try repoRoot().appendingPathComponent("Sources/VibeBarApp", isDirectory: true)
        return try swiftSources(under: root)
    }

    private func swiftSources(under root: URL) throws -> [String: String] {
        let files = try FileManager.default.subpathsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".swift") }
        XCTAssertFalse(files.isEmpty, "No Swift sources under \(root.path)")
        return try Dictionary(uniqueKeysWithValues: files.map { relative in
            let url = root.appendingPathComponent(relative)
            return (url.lastPathComponent, try String(contentsOf: url, encoding: .utf8))
        })
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
            domain: "KeyboardFocusPolicyTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not locate repo root from \(#filePath)"]
        )
    }
}

private extension String {
    func numberOfOccurrences(of needle: String) -> Int {
        components(separatedBy: needle).count - 1
    }
}
