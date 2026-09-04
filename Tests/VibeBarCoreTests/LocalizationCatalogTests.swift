import XCTest
@testable import VibeBarCore

/// The localization catalog is authored as JSON and shipped as
/// `.strings` / `.stringsdict` / generated Swift. Three artefacts derived
/// from one source is three chances to drift, so — the same way
/// `QuotaNamingContractTests` guards the naming contract — this runs the
/// generator and compares rather than reimplementing its rules in Swift
/// and getting a second thing to keep in step.
///
/// The generated files stay checked in. A build that needs Python to
/// produce a resource is a build that breaks on a fresh machine, and the
/// catalog is about to move into a repository shared with the
/// cross-platform client, where "run this script first" is a worse
/// contract still.
final class LocalizationCatalogTests: XCTestCase {
    /// `Tests/VibeBarCoreTests/<this file>` → three levels up.
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var catalogDirectory: URL {
        repositoryRoot.appendingPathComponent("Resources/i18n")
    }

    // MARK: - The generated artefacts match the JSON

    func testGeneratedCatalogsAreWhatTheGeneratorProduces() throws {
        guard let python = try locatePython() else {
            throw XCTSkip("no python3 on PATH; the generator cannot be re-run here")
        }
        let process = Process()
        process.executableURL = python
        process.arguments = [
            repositoryRoot
                .appendingPathComponent("Scripts/build_localizations.py").path,
            "--check",
        ]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = Pipe()
        try process.run()
        let message = String(
            data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
        ) ?? ""
        process.waitUntilExit()
        XCTAssertEqual(
            process.terminationStatus, 0,
            """
            The shipped string catalogs no longer match Resources/i18n. Run \
            Scripts/build_localizations.py. \(message)
            """
        )
    }

    // MARK: - The catalog and the code agree on what exists

    func testEveryCatalogKeyResolvesInEveryShippedLanguage() throws {
        let restore = L10n.languageOverride
        defer { L10n.languageOverride = restore }

        XCTAssertFalse(L10n.allKeys.isEmpty, "the generated key list is empty")
        for language in [AppLanguage.english, .simplifiedChinese] {
            L10n.languageOverride = language
            for key in L10n.allKeys where !L10n.pluralKeys.contains(key) {
                // A miss returns the key itself, which is the one thing a
                // user must never see.
                XCTAssertNotEqual(
                    L10n.string(key), key,
                    "\(key) does not resolve in \(language.rawValue)"
                )
            }
        }
    }

    func testSupportedLanguagesMatchTheShippedCatalogs() throws {
        let files = try FileManager.default
            .contentsOfDirectory(at: catalogDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix("_") }
            .map { $0.deletingPathExtension().lastPathComponent }
        XCTAssertEqual(
            Set(files), Set(L10n.supported),
            "L10n.supported and Resources/i18n disagree about which languages ship"
        )
        XCTAssertTrue(
            L10n.supported.contains(L10n.fallback),
            "the fallback language is not one of the shipped ones"
        )
    }

    /// The bundle metadata is the other half: `CFBundleLocalizations` is
    /// what puts Vibe Bar in Language & Region › Applications, and a
    /// language shipped without being declared there is invisible to the
    /// system control even though the strings are present.
    func testInfoPlistDeclaresEveryShippedLanguage() throws {
        let plist = repositoryRoot.appendingPathComponent("Resources/Info.plist")
        let contents = try Data(contentsOf: plist)
        let parsed = try PropertyListSerialization.propertyList(
            from: contents, options: [], format: nil
        ) as? [String: Any]
        let declared = parsed?["CFBundleLocalizations"] as? [String]
        XCTAssertEqual(
            declared.map(Set.init), Set(L10n.supported),
            "Resources/Info.plist CFBundleLocalizations is out of step with L10n.supported"
        )
        XCTAssertEqual(parsed?["CFBundleDevelopmentRegion"] as? String, L10n.fallback)
    }

    // MARK: - Behaviour

    func testAnExplicitOverrideWinsOverTheSystemLanguage() {
        let restore = L10n.languageOverride
        defer { L10n.languageOverride = restore }

        L10n.languageOverride = .simplifiedChinese
        XCTAssertEqual(L10n.resolvedLanguageCode, "zh-Hans")
        XCTAssertEqual(L10n.Common.refresh, "刷新")

        L10n.languageOverride = .english
        XCTAssertEqual(L10n.resolvedLanguageCode, "en")
        XCTAssertEqual(L10n.Common.refresh, "Refresh")
    }

    /// `.system` resolves against the process's preferred languages rather
    /// than against bundle-resolution behaviour that differs between a
    /// packaged `.app` and an `xctest` run.
    func testSystemLanguageMatchesOnLanguageAndScript() {
        XCTAssertEqual(L10n.bestMatch(for: ["en-US"]), "en")
        XCTAssertEqual(L10n.bestMatch(for: ["zh-Hans-CN", "en-US"]), "zh-Hans")
        XCTAssertEqual(L10n.bestMatch(for: ["fr-FR", "zh-Hans-US"]), "zh-Hans")
        // Traditional is a different catalog. Serving Simplified to a
        // Traditional reader is worse than serving English.
        XCTAssertNil(L10n.bestMatch(for: ["zh-Hant-TW"]))
        XCTAssertNil(L10n.bestMatch(for: ["de-DE", "ja-JP"]))
    }

    /// A translation that is missing a key would be caught by the
    /// generator, but the runtime still has to fall back rather than show
    /// the reader a dotted identifier.
    func testAMissingKeyFallsBackToTheKeyItselfRatherThanCrashing() {
        let restore = L10n.languageOverride
        defer { L10n.languageOverride = restore }
        L10n.languageOverride = .simplifiedChinese
        XCTAssertEqual(L10n.string("quota.thisKeyDoesNotExist"), "quota.thisKeyDoesNotExist")
    }

    // MARK: - Plurals

    /// English needs `one` and `other`; Chinese has only `other`. The
    /// mechanism is a `.stringsdict`, so this is really asserting that
    /// Foundation is selecting the category rather than that our text is
    /// spelled right.
    func testPluralsSelectPerLanguageCategory() {
        let restore = L10n.languageOverride
        defer { L10n.languageOverride = restore }

        L10n.languageOverride = .english
        XCTAssertEqual(L10n.Common.updatedMinutesAgo(minutes: 1), "Updated 1 minute ago")
        XCTAssertEqual(L10n.Common.updatedMinutesAgo(minutes: 7), "Updated 7 minutes ago")

        L10n.languageOverride = .simplifiedChinese
        XCTAssertEqual(L10n.Common.updatedMinutesAgo(minutes: 1), "1 分钟前更新")
        XCTAssertEqual(L10n.Common.updatedMinutesAgo(minutes: 7), "7 分钟前更新")
    }

    /// The bug this covers: a plural variable mixed in with explicitly
    /// positioned arguments used to be fed the first argument — a quota's
    /// name — and fell through to `other` for every count.
    func testAPluralInASentenceWithOtherArgumentsCountsTheRightOne() {
        let restore = L10n.languageOverride
        defer { L10n.languageOverride = restore }

        L10n.languageOverride = .english
        XCTAssertEqual(
            L10n.Quota.resetHistoryVerdictWasteful(label: "Anthropic · Claude · Weekly", count: 1),
            "Anthropic · Claude · Weekly refilled once with more than half unused."
        )
        XCTAssertEqual(
            L10n.Quota.resetHistoryVerdictWasteful(label: "Anthropic · Claude · Weekly", count: 3),
            "Anthropic · Claude · Weekly refilled 3 times with more than half unused."
        )
    }

    // MARK: - The translated / untranslated split

    /// The quota axis is a contract shared with Vibe Bar Desktop
    /// (`docs/contracts/quota-naming-v1.json`), so its values are never
    /// translated. Generic window words are, on the way to the screen —
    /// and that is the whole of the difference.
    func testOnlyGenericWindowWordsAreTranslatedOnTheQuotaAxis() {
        let restore = L10n.languageOverride
        defer { L10n.languageOverride = restore }
        L10n.languageOverride = .simplifiedChinese

        XCTAssertEqual(QuotaGroupLabelLocalizer.display("Weekly"), "每周")
        XCTAssertEqual(QuotaGroupLabelLocalizer.display("5 Hours"), "5 小时")
        XCTAssertEqual(QuotaGroupLabelLocalizer.display("All Models"), "全部模型")

        // Model, product and discovered-bucket names come back untouched.
        for identifier in [
            "Sonnet", "Opus", "Fable", "Codex Spark", "Gemini Models",
            "Claude & GPT Models", "Cursor Models", "gpt-5.5",
        ] {
            XCTAssertEqual(
                QuotaGroupLabelLocalizer.display(identifier), identifier,
                "\(identifier) is a name, not copy"
            )
            XCTAssertFalse(QuotaGroupLabelLocalizer.isTranslated(identifier))
        }
    }

    /// A composed label has to be resolved part by part. Whole-string lookup
    /// leaves "All Models · Weekly" in English — both halves are in the table
    /// and the joined string is not — and a word-by-word rule would split
    /// "All Models" and translate neither half.
    func testComposedLabelsAreResolvedPartByPart() {
        let restore = L10n.languageOverride
        defer { L10n.languageOverride = restore }
        L10n.languageOverride = .simplifiedChinese

        XCTAssertEqual(
            QuotaGroupLabelLocalizer.displayComposed("All Models · Weekly"),
            "全部模型 · 每周"
        )
        // The product name survives; only the window word moves.
        XCTAssertEqual(
            QuotaGroupLabelLocalizer.displayComposed("GPT-5.3 Codex Spark · 5 Hours"),
            "GPT-5.3 Codex Spark · 5 小时"
        )
        XCTAssertEqual(
            QuotaGroupLabelLocalizer.displayComposed("Claude · Weekly · Sonnet"),
            "Claude · 每周 · Sonnet"
        )
        // A label with no separator is one part, so the two agree everywhere
        // a simple label is drawn.
        for label in ["Weekly", "All Models", "Sonnet", "gpt-5.5", ""] {
            XCTAssertEqual(
                QuotaGroupLabelLocalizer.displayComposed(label),
                QuotaGroupLabelLocalizer.display(label)
            )
        }
    }

    /// A measurement an adapter composed is copy, and it cannot be listed in
    /// the table because it is not a fixed string. MiniMax's percentage-only
    /// plans emit "90% left · 5 hours" as a bucket's contract `groupTitle`,
    /// and a Chinese reader was getting "90% left · 5 小时" — the window half
    /// translated, the sentence half not.
    func testMeasuredPartsAreTranslatedAndNamesAreNot() {
        let restore = L10n.languageOverride
        defer { L10n.languageOverride = restore }
        L10n.languageOverride = .simplifiedChinese

        XCTAssertEqual(
            QuotaGroupLabelLocalizer.displayComposed("90% left · 5 hours"),
            "剩余 90% · 5 小时"
        )
        XCTAssertEqual(QuotaGroupLabelLocalizer.display("0% left"), "剩余 0%")
        XCTAssertTrue(QuotaGroupLabelLocalizer.isTranslated("100% left"))

        // The match is whole-part and digits-only, so it reaches no name and
        // no label that merely mentions the word.
        for identifier in [
            "Fable 90% left", "90% left over", "% left", "ninety% left",
            "1000% left", "90 % left", "90%left", "Sonnet",
        ] {
            XCTAssertEqual(
                QuotaGroupLabelLocalizer.display(identifier), identifier,
                "\(identifier) is not a measured part"
            )
            XCTAssertFalse(QuotaGroupLabelLocalizer.isTranslated(identifier))
        }
    }

    /// Every glossary term is a name the app is allowed to print verbatim.
    /// If one of them ever became a catalog *value*, the two would be
    /// saying different things about the same word.
    func testGlossaryTermsAreNeverCatalogValues() throws {
        let glossary = try JSONSerialization.jsonObject(
            with: Data(contentsOf: catalogDirectory.appendingPathComponent("_glossary.json"))
        ) as? [String: Any] ?? [:]
        let terms = glossary
            .filter { !["schema", "note", "rules"].contains($0.key) }
            .compactMap { $0.value as? [String] }
            .flatMap { $0 }
        XCTAssertFalse(terms.isEmpty, "the glossary is empty")

        let restore = L10n.languageOverride
        defer { L10n.languageOverride = restore }
        L10n.languageOverride = .simplifiedChinese
        for term in terms {
            for key in L10n.allKeys where !L10n.pluralKeys.contains(key) {
                XCTAssertNotEqual(
                    L10n.string(key), term,
                    "\(key) is exactly the glossary term \(term); a name does not need a key"
                )
            }
        }
    }

    /// A quota label has one renderer and several readers, and the readers
    /// get forgotten one at a time — the field picker, the rename dialog's
    /// placeholder, the calendar entry, the menu-bar composer. Each one that
    /// reads `title` raw is a Chinese screen with an English quota name on
    /// it, which is how three of them were found. `displayTitle` is the one
    /// renderer; this pins what it must do.
    func testAComposedFieldTitleIsResolvedPartByPart() {
        let restore = L10n.languageOverride
        defer { L10n.languageOverride = restore }
        L10n.languageOverride = .simplifiedChinese

        func option(_ title: String, default label: String) -> MenuBarFieldOption {
            MenuBarFieldOption(
                id: "f", tool: .claude, bucketId: "b", title: title, defaultLabel: label
            )
        }

        // Both halves are generic window words, so both translate.
        XCTAssertEqual(option("All Models · Weekly", default: "Weekly").displayTitle,
                       "全部模型 · 每周")
        // A model name is a name: only the window half moves.
        XCTAssertEqual(option("GPT-5.3 Codex Spark · 5 Hours", default: "5 Hours").displayTitle,
                       "GPT-5.3 Codex Spark · 5 小时")
        XCTAssertEqual(option("Weekly", default: "Weekly").displayDefaultLabel, "每周")
        XCTAssertEqual(option("Sonnet", default: "Sonnet").displayDefaultLabel, "Sonnet")

        // The stored value is a naming-contract value and never moves.
        XCTAssertEqual(option("All Models · Weekly", default: "Weekly").title,
                       "All Models · Weekly")

        L10n.languageOverride = .english
        XCTAssertEqual(option("All Models · Weekly", default: "Weekly").displayTitle,
                       "All Models · Weekly")
    }

    /// A machine-readable identifier inside a translated sentence stays
    /// as it arrived. The Relay's error codes and per-source statuses are
    /// wire vocabulary — `network_timeout` is something a person greps for
    /// and a support thread quotes, not something a translator improves —
    /// so the copy around them moves and they do not.
    func testAWireIdentifierSurvivesInsideATranslatedSentence() {
        let restore = L10n.languageOverride
        defer { L10n.languageOverride = restore }

        L10n.languageOverride = .simplifiedChinese
        let line = L10n.Settings.remoteStatusWithCode(
            title: L10n.Settings.remoteSyncTimeout, code: "network_timeout"
        )
        XCTAssertTrue(line.contains("network_timeout"), "the error code was altered: \(line)")
        XCTAssertTrue(line.contains("Relay 连接超时"), "the sentence stayed English: \(line)")
        XCTAssertFalse(
            line.contains("Relay connection timed out"),
            "the English diagnosis survived into the Chinese pane: \(line)"
        )

        let capsule = L10n.Popover.machinesLabelWithStatus(label: "Claude", status: "ok")
        XCTAssertEqual(capsule, "Claude · ok", "a wire status is not copy")
    }

    /// Every Relay status code this build knows must resolve, and a code it
    /// does not know must still produce a sentence — an unrecognized code
    /// arriving from a newer Relay cannot leave the pane blank.
    func testEveryRemoteSyncStatusResolvesAndTheFallbackIsNotEmpty() {
        let restore = L10n.languageOverride
        defer { L10n.languageOverride = restore }

        for language in [AppLanguage.english, .simplifiedChinese] {
            L10n.languageOverride = language
            for key in L10n.allKeys where key.hasPrefix("settings.remote.sync.") {
                let value = L10n.string(key)
                XCTAssertNotEqual(value, key, "\(key) does not resolve in \(language.rawValue)")
                XCTAssertFalse(value.isEmpty)
            }
            XCTAssertFalse(L10n.Settings.remoteSyncUnknown.isEmpty)
            XCTAssertFalse(L10n.Settings.remoteSyncUnknownDetail.isEmpty)
        }
    }

    private func locatePython() throws -> URL? {
        for candidate in ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"] {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }
}
