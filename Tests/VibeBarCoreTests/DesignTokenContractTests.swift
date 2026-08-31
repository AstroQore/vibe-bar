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

    private func fillTimelineSource() throws -> String {
        try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Sources/VibeBarApp/Views/FillTimelineChart.swift"),
            encoding: .utf8
        )
    }

    /// The reset-history bars use their own five-colour palette, not
    /// `Theme.providerAccent`. Both clients draw the same chart, so the palette
    /// belongs in the contract like the rest — and one case per line makes it
    /// easy to add a provider here and forget the other client entirely.
    func testResetHistoryAccentsMatchTheContract() throws {
        let source = try fillTimelineSource()
        let contractAccents = try XCTUnwrap(
            contract()["resetHistoryAccent"] as? [String: String]
        )

        let block = try XCTUnwrap(slice(
            source,
            from: "private static func accent(for tool: ToolType)",
            to: "private static let timestampFormatter"
        ))
        var found: [String: String] = [:]
        for line in block.split(separator: "\n") {
            guard let red = capture(line, #"red: ([\d.]+)"#),
                  let green = capture(line, #"green: ([\d.]+)"#),
                  let blue = capture(line, #"blue: ([\d.]+)"#)
            else { continue }
            let colour = hex(red, green, blue)
            if line.contains("default:") {
                found["default"] = colour
                continue
            }
            // One case can name several tools: `case .gemini, .antigravity:`.
            guard let cases = capture(line, #"case ([^:]+):"#) else { continue }
            for tool in cases.split(separator: ",") {
                found[tool.trimmingCharacters(in: CharacterSet(charactersIn: " ."))] = colour
            }
        }

        XCTAssertFalse(found.isEmpty, "no reset-history accents were parsed")
        XCTAssertEqual(
            Set(found.keys), Set(contractAccents.keys),
            "the contract and the chart disagree about which tools have an accent"
        )
        for (tool, colour) in found {
            XCTAssertEqual(
                contractAccents[tool], colour,
                "reset-history accent for \(tool) drifted from the chart"
            )
        }
        // The fallback is what an unlisted provider gets in both clients, so a
        // missing one would silently give them different colours.
        XCTAssertNotNil(found["default"], "the fallback accent must be in the contract")
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
    /// the other. Each token is read from its own declaration inside
    /// `Theme.Card`: a repository-wide search for the value would pass while
    /// stale, because `sectionPadding` and `workbenchMinPadding` are both 16.
    func testCardRecipeMatchesTheContract() throws {
        let source = try themeSource()
        let cardBlock = try XCTUnwrap(slice(source, from: "enum Card {", to: "struct Density"))
        let card = try XCTUnwrap(contract()["card"] as? [String: Any])

        var declared: [String: Double] = [:]
        for line in cardBlock.split(separator: "\n") {
            guard let name = capture(line, #"static let (\w+)"#),
                  let value = capture(line, #"=\s*([\d.]+)"#),
                  let number = Double(value)
            else { continue }
            declared[name] = number
        }

        // Every token the contract publishes must exist in Theme.Card with
        // that exact value, and nothing may be published that is not there.
        for (key, published) in card {
            let asDouble = (published as? Double) ?? Double(published as? Int ?? -1)
            guard let source = declared[key] else {
                XCTFail("the contract publishes card.\(key), which Theme.Card does not declare")
                continue
            }
            XCTAssertEqual(source, asDouble, "card.\(key) drifted from Theme.Card")
        }
        for key in ["fillOpacity", "strokeOpacity", "hairlineWidth",
                    "workbenchMinPadding", "workbenchMinCornerRadius"] {
            XCTAssertNotNil(card[key], "the contract does not publish card.\(key)")
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
