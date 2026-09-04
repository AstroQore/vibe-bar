import XCTest
@testable import VibeBarCore

/// The strings live in `vibe-bar-i18n` and arrive as a package; what this
/// app owns is the choice of language and the promise that everything it
/// declares about languages — `AppLocalization.supported`, `AppLanguage`,
/// `Info.plist` — agrees with what the package actually ships. The package's
/// own tests hold key parity and placeholder parity across its locales.
final class LocalizationCatalogTests: XCTestCase {
    /// `Tests/VibeBarCoreTests/<this file>` → three levels up.
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }


    // MARK: - The catalog and the code agree on what exists

    func testSupportedLanguagesMatchTheSharedCatalogue() {
        XCTAssertEqual(
            Set(AppLocalization.supported), Set(L10n.availableLocales),
            "AppLocalization.supported and the vibe-bar-i18n package disagree about which languages ship"
        )
        XCTAssertEqual(
            Set(AppLanguage.allCases.compactMap(\.localizationCode)), Set(AppLocalization.supported),
            "AppLanguage offers a language the build does not ship, or misses one it does"
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
            declared.map(Set.init), Set(AppLocalization.supported),
            "Resources/Info.plist CFBundleLocalizations is out of step with AppLocalization.supported"
        )
        XCTAssertEqual(parsed?["CFBundleDevelopmentRegion"] as? String, AppLocalization.fallback)
    }

    // MARK: - Behaviour

    func testAnExplicitOverrideWinsOverTheSystemLanguage() {
        let restore = AppLocalization.languageOverride
        defer { AppLocalization.languageOverride = restore }

        AppLocalization.languageOverride = .simplifiedChinese
        XCTAssertEqual(AppLocalization.resolvedLanguageCode, "zh-Hans")
        XCTAssertEqual(L10n.Common.refresh, "刷新")

        AppLocalization.languageOverride = .english
        XCTAssertEqual(AppLocalization.resolvedLanguageCode, "en")
        XCTAssertEqual(L10n.Common.refresh, "Refresh")
    }

    /// `.system` resolves against the process's preferred languages rather
    /// than against bundle-resolution behaviour that differs between a
    /// packaged `.app` and an `xctest` run.
    func testSystemLanguageMatchesOnLanguageAndScript() {
        XCTAssertEqual(AppLocalization.bestMatch(for: ["en-US"]), "en")
        XCTAssertEqual(AppLocalization.bestMatch(for: ["zh-Hans-CN", "en-US"]), "zh-Hans")
        XCTAssertEqual(AppLocalization.bestMatch(for: ["fr-FR", "zh-Hans-US"]), "zh-Hans")
        // Traditional is a different catalog. Serving Simplified to a
        // Traditional reader is worse than serving English.
        XCTAssertNil(AppLocalization.bestMatch(for: ["zh-Hant-TW"]))
        XCTAssertNil(AppLocalization.bestMatch(for: ["de-DE", "ja-JP"]))
    }

    // MARK: - Plurals

    /// English needs `one` and `other`; Chinese has only `other`. The
    /// mechanism is a `.stringsdict`, so this is really asserting that
    /// Foundation is selecting the category rather than that our text is
    /// spelled right.
    func testPluralsSelectPerLanguageCategory() {
        let restore = AppLocalization.languageOverride
        defer { AppLocalization.languageOverride = restore }

        AppLocalization.languageOverride = .english
        XCTAssertEqual(L10n.Common.Updated.minutesAgo(minutes: 1), "Updated 1 minute ago")
        XCTAssertEqual(L10n.Common.Updated.minutesAgo(minutes: 7), "Updated 7 minutes ago")

        AppLocalization.languageOverride = .simplifiedChinese
        XCTAssertEqual(L10n.Common.Updated.minutesAgo(minutes: 1), "1 分钟前更新")
        XCTAssertEqual(L10n.Common.Updated.minutesAgo(minutes: 7), "7 分钟前更新")
    }

    /// The bug this covers: a plural variable mixed in with explicitly
    /// positioned arguments used to be fed the first argument — a quota's
    /// name — and fell through to `other` for every count.
    func testAPluralInASentenceWithOtherArgumentsCountsTheRightOne() {
        let restore = AppLocalization.languageOverride
        defer { AppLocalization.languageOverride = restore }

        AppLocalization.languageOverride = .english
        XCTAssertEqual(
            L10n.ResetHistory.Verdict.wasteful(label: "Anthropic · Claude · Weekly", count: 1),
            "Anthropic · Claude · Weekly refilled once with more than half unused."
        )
        XCTAssertEqual(
            L10n.ResetHistory.Verdict.wasteful(label: "Anthropic · Claude · Weekly", count: 3),
            "Anthropic · Claude · Weekly refilled 3 times with more than half unused."
        )
    }

    // MARK: - The translated / untranslated split

    /// The quota axis is a contract shared with Vibe Bar Desktop
    /// (`docs/contracts/quota-naming-v1.json`), so its values are never
    /// translated. Generic window words are, on the way to the screen —
    /// and that is the whole of the difference.
    func testOnlyGenericWindowWordsAreTranslatedOnTheQuotaAxis() {
        let restore = AppLocalization.languageOverride
        defer { AppLocalization.languageOverride = restore }
        AppLocalization.languageOverride = .simplifiedChinese

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
        let restore = AppLocalization.languageOverride
        defer { AppLocalization.languageOverride = restore }
        AppLocalization.languageOverride = .simplifiedChinese

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
        let restore = AppLocalization.languageOverride
        defer { AppLocalization.languageOverride = restore }
        AppLocalization.languageOverride = .simplifiedChinese

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

    /// A quota label has one renderer and several readers, and the readers
    /// get forgotten one at a time — the field picker, the rename dialog's
    /// placeholder, the calendar entry, the menu-bar composer. Each one that
    /// reads `title` raw is a Chinese screen with an English quota name on
    /// it, which is how three of them were found. `displayTitle` is the one
    /// renderer; this pins what it must do.
    func testAComposedFieldTitleIsResolvedPartByPart() {
        let restore = AppLocalization.languageOverride
        defer { AppLocalization.languageOverride = restore }
        AppLocalization.languageOverride = .simplifiedChinese

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

        AppLocalization.languageOverride = .english
        XCTAssertEqual(option("All Models · Weekly", default: "Weekly").displayTitle,
                       "All Models · Weekly")
    }

    /// A machine-readable identifier inside a translated sentence stays
    /// as it arrived. The Relay's error codes and per-source statuses are
    /// wire vocabulary — `network_timeout` is something a person greps for
    /// and a support thread quotes, not something a translator improves —
    /// so the copy around them moves and they do not.
    func testAWireIdentifierSurvivesInsideATranslatedSentence() {
        let restore = AppLocalization.languageOverride
        defer { AppLocalization.languageOverride = restore }

        AppLocalization.languageOverride = .simplifiedChinese
        let line = L10n.Settings.Remote.statusWithCode(
            title: L10n.Settings.Remote.Sync.timeout, code: "network_timeout"
        )
        XCTAssertTrue(line.contains("network_timeout"), "the error code was altered: \(line)")
        XCTAssertTrue(line.contains("Relay 连接超时"), "the sentence stayed English: \(line)")
        XCTAssertFalse(
            line.contains("Relay connection timed out"),
            "the English diagnosis survived into the Chinese pane: \(line)"
        )

        let capsule = L10n.Popover.Machines.labelWithStatus(label: "Claude", status: "ok")
        XCTAssertEqual(capsule, "Claude · ok", "a wire status is not copy")
    }

    /// Every Relay status code this build knows must resolve, and a code it
    /// does not know must still produce a sentence — an unrecognized code
    /// arriving from a newer Relay cannot leave the pane blank.
    func testEveryRemoteSyncStatusResolvesAndTheFallbackIsNotEmpty() {
        let restore = AppLocalization.languageOverride
        defer { AppLocalization.languageOverride = restore }

        for language in [AppLanguage.english, .simplifiedChinese] {
            AppLocalization.languageOverride = language
            // The package holds every key to parity across its locales; what
            // this app has to hold is that the sentence an unknown code falls
            // back to is a sentence in every language it ships.
            XCTAssertFalse(L10n.Settings.Remote.Sync.unknown.isEmpty)
            XCTAssertFalse(L10n.Settings.Remote.Sync.unknownDetail.isEmpty)
            XCTAssertNotEqual(L10n.Settings.Remote.Sync.unknown, "settings.remote.sync.unknown")
        }
    }

}
