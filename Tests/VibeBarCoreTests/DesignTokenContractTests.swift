import XCTest

/// The visual tokens are shared with Vibe Bar Desktop through
/// `docs/contracts/design-tokens-v1.json`. Nothing generates one from the
/// other, so without a check the two drift: a provider that is teal here and
/// green there is two providers as far as the reader is concerned.
///
/// `Theme` lives in the app target, which no test target can import, so this
/// compares the contract against the source text instead. That is the right
/// comparison anyway — the question is whether the file and the table agree.
final class DesignTokenContractTests: XCTestCase {
    /// `Tests/VibeBarCoreTests/<this file>` → three levels up.
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func contract() throws -> [String: Any] {
        let url = repositoryRoot.appendingPathComponent("docs/contracts/design-tokens-v1.json")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func themeSource() throws -> String {
        try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Sources/VibeBarApp/Views/Theme.swift"),
            encoding: .utf8
        )
    }

    /// Every provider accent in `Theme.providerAccent` appears in the contract
    /// with the same colour, and the contract names no provider the theme has
    /// dropped.
    func testProviderAccentsMatchTheContract() throws {
        let source = try themeSource()
        let contractAccents = try XCTUnwrap(
            contract()["providerAccent"] as? [String: Any]
        )

        let block = try XCTUnwrap(slice(
            source,
            from: "static func providerAccent",
            to: "private static var adaptiveNeutralAccent"
        ))
        var found: [String: String] = [:]
        for line in block.split(separator: "\n") {
            guard let tool = capture(line, #"case \.(\w+):"#),
                  let red = capture(line, #"red: ([\d.]+)"#),
                  let green = capture(line, #"green: ([\d.]+)"#),
                  let blue = capture(line, #"blue: ([\d.]+)"#)
            else { continue }
            found[tool] = hex(red, green, blue)
        }
        // Grok resolves per appearance, so the contract stores two values.
        XCTAssertNotNil(contractAccents["grok"] as? [String: String],
                        "grok is appearance-dependent and must carry both values")

        for (tool, colour) in found {
            XCTAssertEqual(
                contractAccents[tool] as? String, colour,
                "\(tool) drifted from docs/contracts/design-tokens-v1.json"
            )
        }
        let contractNames = Set(contractAccents.keys)
        let themeNames = Set(found.keys).union(["grok"])
        XCTAssertEqual(
            contractNames, themeNames,
            "the contract and Theme.providerAccent list different providers"
        )
    }

    /// The quota bar thresholds and colours are what the other client draws
    /// with, so a change here that is not mirrored there shows the same
    /// number in two different colours.
    func testQuotaBarColoursMatchTheContract() throws {
        let source = try themeSource()
        let bar = try XCTUnwrap(slice(
            source, from: "static func barColor", to: "static let barTrack"
        ))
        let colours = matches(bar, #"red: ([\d.]+), green: ([\d.]+), blue: ([\d.]+)"#)
            .map { hex($0[0], $0[1], $0[2]) }
        XCTAssertEqual(colours.count, 6, "expected three colours for each display mode")

        let quotaBar = try XCTUnwrap(contract()["quotaBar"] as? [String: Any])
        let remaining = try XCTUnwrap(quotaBar["remaining"] as? [String: Any])
        let used = try XCTUnwrap(quotaBar["used"] as? [String: Any])

        XCTAssertEqual(remaining["critical"] as? String, colours[0])
        XCTAssertEqual(remaining["warning"] as? String, colours[1])
        XCTAssertEqual(remaining["ok"] as? String, colours[2])
        XCTAssertEqual(used["critical"] as? String, colours[3])
        XCTAssertEqual(used["warning"] as? String, colours[4])
        XCTAssertEqual(used["ok"] as? String, colours[5])

        // The thresholds matter as much as the colours: the same hue at a
        // different cut-off is still a visible disagreement.
        XCTAssertTrue(bar.contains("percent < 10"), "remaining critical threshold moved")
        XCTAssertTrue(bar.contains("percent < 30"), "remaining warning threshold moved")
        XCTAssertTrue(bar.contains("percent >= 90"), "used critical threshold moved")
        XCTAssertTrue(bar.contains("percent >= 70"), "used warning threshold moved")
        XCTAssertEqual(remaining["criticalBelow"] as? Int, 10)
        XCTAssertEqual(remaining["warningBelow"] as? Int, 30)
        XCTAssertEqual(used["criticalAtOrAbove"] as? Int, 90)
        XCTAssertEqual(used["warningAtOrAbove"] as? Int, 70)
    }

    /// Grok resolves per appearance, so both halves must come from
    /// `adaptiveNeutralAccent` rather than being typed in. The first version
    /// of this contract had a hand-written light value that did not match the
    /// source, and nothing here noticed.
    func testGrokAccentMatchesBothAppearances() throws {
        let source = try themeSource()
        let block = try XCTUnwrap(slice(
            source, from: "private static var adaptiveNeutralAccent", to: "static func barColor"
        ))
        let values = matches(block, #"srgbRed: ([\d.]+), green: ([\d.]+), blue: ([\d.]+)"#)
            .map { hex($0[0], $0[1], $0[2]) }
        XCTAssertEqual(values.count, 2, "expected a dark and a light value")

        let accents = try XCTUnwrap(contract()["providerAccent"] as? [String: Any])
        let grok = try XCTUnwrap(accents["grok"] as? [String: String])
        XCTAssertEqual(grok["dark"], values[0])
        XCTAssertEqual(grok["light"], values[1])
    }

    /// The card recipe is what makes a card in one client look like a card in
    /// the other. It is published, so it has to be checked.
    func testCardRecipeMatchesTheContract() throws {
        let source = try themeSource()
        let card = try XCTUnwrap(contract()["card"] as? [String: Any])
        for (key, expected) in [
            ("fillOpacity", "0.6"),
            ("strokeOpacity", "0.4"),
            ("hairlineWidth", "0.5"),
            ("workbenchMinCornerRadius", "16"),
        ] {
            XCTAssertTrue(
                source.contains("static let \(key)") && source.contains("= \(expected)"),
                "Theme.Card.\(key) is no longer \(expected)"
            )
            let value = card[key]
            let asDouble = (value as? Double) ?? Double(value as? Int ?? -1)
            XCTAssertEqual(
                asDouble, Double(expected),
                "card.\(key) drifted from docs/contracts/design-tokens-v1.json"
            )
        }
    }

    /// The bar track sits behind every quota bar in both clients, and the
    /// source slice the colour test reads deliberately stops before it.
    func testBarTrackOpacityMatchesTheContract() throws {
        let source = try themeSource()
        let opacity = try XCTUnwrap(
            capture(Substring(source), #"barTrack = Color\.primary\.opacity\(([\d.]+)\)"#)
        )
        let quotaBar = try XCTUnwrap(contract()["quotaBar"] as? [String: Any])
        XCTAssertEqual(
            quotaBar["trackOpacity"] as? Double, Double(opacity),
            "trackOpacity drifted from Theme.barTrack"
        )
    }

    // MARK: - Helpers

    private func slice(_ text: String, from: String, to: String) -> String? {
        guard let start = text.range(of: from), let end = text.range(of: to) else { return nil }
        return String(text[start.lowerBound..<end.lowerBound])
    }

    private func capture(_ line: Substring, _ pattern: String) -> String? {
        matches(String(line), pattern).first?.first
    }

    private func matches(_ text: String, _ pattern: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).map { match in
            (1..<match.numberOfRanges).compactMap { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) }
            }
        }
    }

    private func hex(_ red: String, _ green: String, _ blue: String) -> String {
        let channels = [red, green, blue].map { component -> Int in
            Int((Double(component) ?? 0) * 255 + 0.5)
        }
        return String(format: "#%02X%02X%02X", channels[0], channels[1], channels[2])
    }
}
