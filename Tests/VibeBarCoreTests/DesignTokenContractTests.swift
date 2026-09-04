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

    /// The verdict colours. Two of them carry a distinction the reader would
    /// otherwise lose: `enough` is green and `surplus` blue, because "it will
    /// last" and "you have paid for capacity you will not use" are different
    /// pieces of news. A client that collapses them into one severity says
    /// less than this one does.
    func testForecastVerdictColoursMatchTheContract() throws {
        let source = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Sources/VibeBarApp/Views/QuotaForecastRow.swift"),
            encoding: .utf8
        )
        let contractColours = try XCTUnwrap(
            contract()["forecastVerdict"] as? [String: String]
        )
        let block = try XCTUnwrap(slice(
            source, from: "enum QuotaForecastPalette", to: "\n}"
        ))
        var found: [String: String] = [:]
        for line in block.split(separator: "\n") {
            guard let verdict = capture(line, #"case \.(\w+):"#),
                  let red = capture(line, #"red: ([\d.]+)"#),
                  let green = capture(line, #"green: ([\d.]+)"#),
                  let blue = capture(line, #"blue: ([\d.]+)"#)
            else { continue }
            found[verdict] = hex(red, green, blue)
        }

        XCTAssertEqual(Set(found.keys), Set(contractColours.keys))
        for (verdict, colour) in found {
            XCTAssertEqual(contractColours[verdict], colour,
                           "the \(verdict) colour drifted from the palette")
        }
        XCTAssertNotEqual(
            contractColours["enough"], contractColours["surplus"],
            "these say different things and must not share a colour"
        )
        // `learning` deliberately has none: it takes the secondary text colour,
        // because a verdict with no evidence behind it should not look like one.
        XCTAssertNil(contractColours["learning"])
    }

    /// Every provider accent in `Theme.providerAccent` appears in the contract
    /// with the same colour, and the contract names no provider the theme has
    /// dropped.
    func testProviderAccentsMatchTheContract() throws {
        let source = try themeSource()
        let contractAccents = try XCTUnwrap(
            contract()["providerAccent"] as? [String: Any]
        )
        // Not literals in the palette, so the `red:`/`green:`/`blue:` scrape
        // below cannot see them.
        let appearanceDependentAccents: Set<String> = ["grok", "cursor"]

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
        // The SpaceXAI family's two neutrals resolve per appearance, so the
        // contract stores both values for each rather than one hex.
        for tool in appearanceDependentAccents {
            XCTAssertNotNil(contractAccents[tool] as? [String: String],
                            "\(tool) is appearance-dependent and must carry both values")
        }

        for (tool, colour) in found {
            XCTAssertEqual(
                contractAccents[tool] as? String, colour,
                "\(tool) drifted from docs/contracts/design-tokens-v1.json"
            )
        }
        let contractNames = Set(contractAccents.keys)
        let themeNames = Set(found.keys).union(appearanceDependentAccents)
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

    /// The SpaceXAI family's two neutrals resolve per appearance, so both
    /// halves of each must come from its own declaration rather than being
    /// typed in. The first version of this contract had a hand-written light
    /// value for Grok that did not match the source, and nothing here noticed.
    func testTheAppearanceDependentAccentsMatchBothAppearances() throws {
        let source = try themeSource()
        // Each is sliced to the *next* declaration: sharing one slice would
        // let either one's pair satisfy the other's assertion.
        let neutrals: [(tool: String, from: String, to: String)] = [
            ("grok",
             "private static var adaptiveNeutralAccent",
             "private static var adaptiveInkAccent"),
            ("cursor",
             "private static var adaptiveInkAccent",
             "static func barColor"),
        ]
        let accents = try XCTUnwrap(contract()["providerAccent"] as? [String: Any])
        for neutral in neutrals {
            let block = try XCTUnwrap(slice(source, from: neutral.from, to: neutral.to))
            let values = matches(block, #"srgbRed: ([\d.]+), green: ([\d.]+), blue: ([\d.]+)"#)
                .map { hex($0[0], $0[1], $0[2]) }
            XCTAssertEqual(values.count, 2, "\(neutral.tool): expected a dark and a light value")

            let contractValue = try XCTUnwrap(accents[neutral.tool] as? [String: String])
            XCTAssertEqual(contractValue["dark"], values[0], neutral.tool)
            XCTAssertEqual(contractValue["light"], values[1], neutral.tool)
        }
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

    /// The text between two markers, with the end looked for *after* the
    /// start. Searching the whole file for the end marker meant a common one
    /// like a closing brace matched something earlier and crashed on an
    /// inverted range, rather than returning nil the way a caller expects.
    private func slice(_ text: String, from: String, to: String) -> String? {
        guard let start = text.range(of: from) else { return nil }
        guard let end = text.range(of: to, range: start.upperBound..<text.endIndex) else {
            return nil
        }
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
