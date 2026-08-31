import XCTest
@testable import VibeBarCore

/// `SettingsDocumentTests` covers the merge itself. These cover the store's
/// *use* of it, against a real file — the claim being made is about what
/// `settings.json` looks like after a save, and a merge nothing calls would
/// pass every test in that other file.
@MainActor
final class SettingsStoreMergeTests: XCTestCase {
    private var home: URL!
    private var settingsURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("settings-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        settingsURL = home.appendingPathComponent("settings.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
        try super.tearDownWithError()
    }

    /// A `UserDefaults` the store cannot fall back onto, so a test that meant
    /// to read the file never silently reads this machine's real settings.
    private func scratchDefaults() throws -> UserDefaults {
        try XCTUnwrap(UserDefaults(suiteName: "SettingsStoreMergeTests.\(UUID().uuidString)"))
    }

    private func writeFile(_ json: String) throws {
        try Data(json.utf8).write(to: settingsURL)
    }

    private func fileObject() throws -> SettingsDocument.Object {
        try XCTUnwrap(SettingsDocument.read(from: settingsURL), "settings.json is missing or is not an object")
    }

    private func makeStore() throws -> SettingsStore {
        SettingsStore(userDefaults: try scratchDefaults(), settingsURL: settingsURL)
    }

    /// The case the whole change exists for: a key written by another client
    /// or a newer build, which `AppSettings` drops on decode, is still in the
    /// file after this build saves.
    func testAKeyThisBuildCannotDecodeSurvivesASave() throws {
        try writeFile(#"{"displayMode":"remaining","refreshIntervalSeconds":600,"futureSetting":{"a":1}}"#)

        let store = try makeStore()
        store.settings.refreshIntervalSeconds = 900
        store.flush()

        let saved = try fileObject()
        XCTAssertEqual(saved["refreshIntervalSeconds"] as? Int, 900, "our own edit did not reach the file")
        XCTAssertNotNil(
            saved["futureSetting"],
            "a key this build cannot decode was deleted by a save — settings.json is rewritten wholesale"
        )
    }

    /// An edit made by the other client *while this store was running* is not
    /// undone by the next save here. This is the one a whole-file rewrite
    /// fails even when both builds know every key.
    func testAnotherClientsEditIsNotUndoneByASaveHere() throws {
        try writeFile(#"{"displayMode":"remaining","refreshIntervalSeconds":600}"#)
        let store = try makeStore()

        // The other client changes a setting this store is not touching. The
        // store's in-memory copy still says 600.
        try writeFile(#"{"displayMode":"remaining","refreshIntervalSeconds":120}"#)

        store.settings.displayMode = .used
        store.flush()

        let saved = try fileObject()
        XCTAssertEqual(saved["displayMode"] as? String, "used", "our own edit did not reach the file")
        XCTAssertEqual(
            saved["refreshIntervalSeconds"] as? Int, 120,
            "a setting this store never touched was written back from a stale in-memory copy"
        )
    }

    /// And the mirror image: a value this store *did* change wins over the
    /// file, so the merge cannot be passing the test above by simply never
    /// writing anything.
    func testThisStoresOwnEditWinsOverTheFile() throws {
        try writeFile(#"{"displayMode":"remaining","refreshIntervalSeconds":600}"#)
        let store = try makeStore()

        store.settings.refreshIntervalSeconds = 900
        try writeFile(#"{"displayMode":"remaining","refreshIntervalSeconds":120}"#)
        store.flush()

        XCTAssertEqual(try fileObject()["refreshIntervalSeconds"] as? Int, 900)
    }

    /// A newer client's file, opened by an older build: the typed decode
    /// fails, and the fallback is defaults. Saving those over the file is the
    /// downgrade version of the loss this whole change exists to prevent, and
    /// it happens before the user has touched anything.
    func testDefaultsAreNotSavedOverAFileThisBuildCannotDecode() throws {
        let original = #"{"displayMode":"aModeFromAFutureBuild","refreshIntervalSeconds":120}"#
        try writeFile(original)

        _ = try makeStore()

        XCTAssertEqual(
            try String(contentsOf: settingsURL, encoding: .utf8), original,
            "launching wrote defaults over a file written by a newer client"
        )
    }

    /// The file is still something the store itself can read back: a merged
    /// write has to stay a decodable `AppSettings`, not just a valid object.
    func testTheMergedFileStillLoadsAsSettings() throws {
        try writeFile(#"{"displayMode":"remaining","refreshIntervalSeconds":600,"futureSetting":{"a":1}}"#)
        let store = try makeStore()
        store.settings.refreshIntervalSeconds = 900
        store.flush()

        let reloaded = SettingsStore(userDefaults: try scratchDefaults(), settingsURL: settingsURL)
        XCTAssertEqual(reloaded.settings.refreshIntervalSeconds, 900)
    }
}

/// The other half: what this store does when the file changes under it.
/// Without watching, another client's edit is invisible until the next launch
/// — the settings on screen are simply wrong, and saving them writes that
/// wrongness back for every key this store later touches.
@MainActor
final class SettingsStoreAdoptionTests: XCTestCase {
    private var home: URL!
    private var settingsURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("settings-adopt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        settingsURL = home.appendingPathComponent("settings.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
        try super.tearDownWithError()
    }

    private func makeStore() throws -> SettingsStore {
        SettingsStore(
            userDefaults: try XCTUnwrap(UserDefaults(suiteName: "adopt.\(UUID().uuidString)")),
            settingsURL: settingsURL
        )
    }

    private func writeFile(_ json: String) throws {
        try Data(json.utf8).write(to: settingsURL, options: [.atomic])
    }

    private func fileObject() throws -> SettingsDocument.Object {
        try XCTUnwrap(SettingsDocument.read(from: settingsURL), "settings.json is missing")
    }

    /// Waits for the watcher's debounce plus the hop back to the main actor.
    private func waitForAdoption(
        _ store: SettingsStore, until condition: @escaping @MainActor (SettingsStore) -> Bool
    ) {
        let met = expectation(description: "settings caught up with the file")
        met.assertForOverFulfill = false
        let deadline = Date().addingTimeInterval(3)
        func poll() {
            if condition(store) { met.fulfill(); return }
            guard Date() < deadline else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { MainActor.assumeIsolated(poll) }
        }
        poll()
        wait(for: [met], timeout: 4)
    }

    func testTakesOnAChangeMadeByAnotherWriter() throws {
        try writeFile(#"{"displayMode":"remaining","refreshIntervalSeconds":600}"#)
        let store = try makeStore()
        XCTAssertEqual(store.settings.refreshIntervalSeconds, 600)

        try writeFile(#"{"displayMode":"remaining","refreshIntervalSeconds":120}"#)

        waitForAdoption(store) { $0.settings.refreshIntervalSeconds == 120 }
        XCTAssertNil(
            store.replacedByAnotherWriter,
            "a setting this store never chose a value for was reported as a loss"
        )
    }

    /// The case that motivates the notice, and the one a naive "did my
    /// in-memory copy differ" check misses entirely: our edit was saved, so it
    /// matches the baseline, and only the record of having made it survives.
    func testReportsAnEditOfOursBeingReplaced() throws {
        try writeFile(#"{"displayMode":"remaining","refreshIntervalSeconds":600}"#)
        let store = try makeStore()

        store.settings.refreshIntervalSeconds = 900
        store.flush()

        // Another client, which loaded before that save, writes its own value.
        try writeFile(#"{"displayMode":"remaining","refreshIntervalSeconds":120}"#)

        waitForAdoption(store) { $0.replacedByAnotherWriter != nil }
        XCTAssertEqual(store.replacedByAnotherWriter?.replacedKeys, ["refreshIntervalSeconds"])
        XCTAssertEqual(store.settings.refreshIntervalSeconds, 120, "the file is the shared truth")

        store.acknowledgeExternalChange()
        XCTAssertNil(store.replacedByAnotherWriter)
    }

    /// Our own save comes back through the same watcher, and is not news.
    func testOurOwnSaveIsNotReportedAsSomeoneElsesChange() throws {
        try writeFile(#"{"displayMode":"remaining","refreshIntervalSeconds":600}"#)
        let store = try makeStore()

        store.settings.refreshIntervalSeconds = 900
        store.flush()

        let quiet = expectation(description: "nothing reported")
        quiet.isInverted = true
        let cancellable = store.$replacedByAnotherWriter.dropFirst()
            .sink { if $0 != nil { quiet.fulfill() } }
        wait(for: [quiet], timeout: 1)
        cancellable.cancel()
        XCTAssertEqual(store.settings.refreshIntervalSeconds, 900)
    }

    /// A save is coalesced over 250ms, so an external change can land while
    /// one is still in flight holding a snapshot taken before it. Left alone
    /// that snapshot writes the pre-adoption values back and undoes the other
    /// writer's edit — the merge having done its job and then been overwritten
    /// by a save that never knew.
    func testAnInFlightSaveDoesNotUndoAChangeThatLandedDuringIt() throws {
        try writeFile(#"{"displayMode":"remaining","refreshIntervalSeconds":600}"#)
        let store = try makeStore()

        // Our edit: coalesced, not yet written.
        store.settings.displayMode = .used
        // Theirs, arriving inside that window.
        try writeFile(#"{"displayMode":"remaining","refreshIntervalSeconds":120}"#)

        waitForAdoption(store) { $0.settings.refreshIntervalSeconds == 120 }
        // Long enough for the coalesced save — original or replacement — to run.
        let settled = expectation(description: "settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { settled.fulfill() }
        wait(for: [settled], timeout: 3)

        let onDisk = try XCTUnwrap(SettingsDocument.read(from: settingsURL))
        XCTAssertEqual(
            onDisk["refreshIntervalSeconds"] as? Int, 120,
            "a save from before the external change wrote the old value back"
        )
        XCTAssertEqual(
            onDisk["displayMode"] as? String, "used",
            "our own unsaved edit was dropped along with the stale snapshot"
        )
    }

    /// A newer writer can put a value in the file that this build cannot
    /// decode — a settings enum with a case added since. Treating that as
    /// "seen" would let the next save diff our old values against it and
    /// overwrite the newer writer's, which is the whole failure this change
    /// exists to prevent.
    func testAFileThisBuildCannotDecodeIsNotTakenAsSeen() throws {
        try writeFile(#"{"displayMode":"remaining","refreshIntervalSeconds":600}"#)
        let store = try makeStore()

        try writeFile(#"{"displayMode":"aModeFromAFutureBuild","refreshIntervalSeconds":120}"#)

        // Nothing to wait for — the point is that nothing happens.
        let settled = expectation(description: "settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { settled.fulfill() }
        wait(for: [settled], timeout: 3)
        XCTAssertEqual(store.settings.displayMode, .remaining, "an undecodable value was adopted")

        // The save that follows must leave the value it could not read alone.
        store.settings.refreshIntervalSeconds = 300
        store.flush()

        let onDisk = try XCTUnwrap(SettingsDocument.read(from: settingsURL))
        XCTAssertEqual(
            onDisk["displayMode"] as? String, "aModeFromAFutureBuild",
            "a value this build cannot decode was overwritten by a save"
        )
        XCTAssertEqual(onDisk["refreshIntervalSeconds"] as? Int, 300)
    }

    /// A setting adopted from the other writer is that writer's, not ours. If
    /// the next save were to claim it, the time after that they changed it we
    /// would tell the user their own choice had been replaced — about a value
    /// they never picked.
    func testASettingAdoptedFromAnotherWriterIsNotClaimedAsOurs() throws {
        try writeFile(#"{"displayMode":"remaining","refreshIntervalSeconds":600}"#)
        let store = try makeStore()

        try writeFile(#"{"displayMode":"used","refreshIntervalSeconds":600}"#)
        waitForAdoption(store) { $0.settings.displayMode == .used }
        XCTAssertNil(store.replacedByAnotherWriter)

        // A save of something else, which must not adopt authorship of theirs.
        store.settings.refreshIntervalSeconds = 300
        store.flush()

        // They change their own setting again.
        try writeFile(#"{"displayMode":"remaining","refreshIntervalSeconds":300}"#)
        waitForAdoption(store) { $0.settings.displayMode == .remaining }

        XCTAssertNil(
            store.replacedByAnotherWriter,
            "reported a loss for a setting this process never chose a value for"
        )
    }

    /// A save can beat the watcher to an external change. The save re-reads,
    /// keeps their keys, and records the result as the file it has seen — at
    /// which point the watcher has nothing left to notice, and this process
    /// shows settings the file has not held for some time.
    func testASaveThatFoldsInAnExternalChangeStillAdoptsIt() throws {
        try writeFile(#"{"displayMode":"remaining","refreshIntervalSeconds":600}"#)
        let store = try makeStore()

        // Their write, then ours before the watcher's debounce elapses.
        try writeFile(#"{"displayMode":"remaining","refreshIntervalSeconds":120}"#)
        store.settings.displayMode = .used
        store.flush()

        waitForAdoption(store) { $0.settings.refreshIntervalSeconds == 120 }
        XCTAssertEqual(store.settings.displayMode, .used, "our own edit was lost")
        XCTAssertEqual(try fileObject()["refreshIntervalSeconds"] as? Int, 120)
    }

    /// The notice is about something the user lost. A later external change
    /// that costs nothing is not news that the first one cost nothing.
    func testANoticeStandsUntilItIsAcknowledged() throws {
        try writeFile(#"{"displayMode":"remaining","refreshIntervalSeconds":600}"#)
        let store = try makeStore()

        store.settings.refreshIntervalSeconds = 900
        store.flush()
        try writeFile(#"{"displayMode":"remaining","refreshIntervalSeconds":120}"#)
        waitForAdoption(store) { $0.replacedByAnotherWriter != nil }

        // An unrelated external change, costing nothing.
        try writeFile(#"{"displayMode":"used","refreshIntervalSeconds":120}"#)
        waitForAdoption(store) { $0.settings.displayMode == .used }

        XCTAssertEqual(
            store.replacedByAnotherWriter?.replacedKeys, ["refreshIntervalSeconds"],
            "the notice was cleared by a later change that cost nothing"
        )
        store.acknowledgeExternalChange()
        XCTAssertNil(store.replacedByAnotherWriter)
    }

    /// Two losses are two things to tell the user about, not one replacing
    /// the other.
    func testASecondLossIsAddedToTheNotice() throws {
        try writeFile(#"{"displayMode":"remaining","refreshIntervalSeconds":600}"#)
        let store = try makeStore()

        store.settings.refreshIntervalSeconds = 900
        store.flush()
        try writeFile(#"{"displayMode":"remaining","refreshIntervalSeconds":120}"#)
        waitForAdoption(store) { $0.replacedByAnotherWriter != nil }

        store.settings.displayMode = .used
        store.flush()
        try writeFile(#"{"displayMode":"remaining","refreshIntervalSeconds":120}"#)
        waitForAdoption(store) { ($0.replacedByAnotherWriter?.replacedKeys.count ?? 0) > 1 }

        XCTAssertEqual(
            store.replacedByAnotherWriter?.replacedKeys,
            ["displayMode", "refreshIntervalSeconds"]
        )
    }

    /// A settings file from an older version is missing keys this build knows.
    /// Decoding materialises defaults for them, and measuring a save against
    /// the file makes every one of those look like something this process
    /// chose — so a save writes them over whatever the other client has just
    /// put there.
    ///
    /// Before the watcher runs, deliberately: once their value has been
    /// adopted it is in memory too, and the save agrees with it by accident.
    func testADefaultThisBuildFilledInIsNotTreatedAsOurChoice() throws {
        try writeFile(#"{"displayMode":"remaining"}"#)
        let store = try makeStore()
        let theirValue = !store.settings.refreshOnPopoverOpen

        // The other client sets a key our file never carried, and this store
        // saves something unrelated before hearing about it.
        try writeFile(#"{"displayMode":"remaining","refreshOnPopoverOpen":\#(theirValue)}"#)
        store.settings.refreshIntervalSeconds = 300
        store.flush()

        XCTAssertEqual(
            try fileObject()["refreshOnPopoverOpen"] as? Bool, theirValue,
            "a default this build filled in was written over the other client's value"
        )
        XCTAssertEqual(try fileObject()["refreshIntervalSeconds"] as? Int, 300)
    }

    /// Adopting the file must not schedule a save of what was just read: that
    /// would be this store answering every external edit with a write.
    func testAdoptingDoesNotWriteBack() throws {
        try writeFile(#"{"displayMode":"remaining","refreshIntervalSeconds":600}"#)
        let store = try makeStore()

        try writeFile(#"{"displayMode":"remaining","refreshIntervalSeconds":120,"futureSetting":1}"#)
        waitForAdoption(store) { $0.settings.refreshIntervalSeconds == 120 }

        // Long enough for a coalesced write to have fired had one been queued.
        let settled = expectation(description: "settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { settled.fulfill() }
        wait(for: [settled], timeout: 2)

        let onDisk = try XCTUnwrap(SettingsDocument.read(from: settingsURL))
        XCTAssertNotNil(onDisk["futureSetting"], "adopting rewrote the file and dropped a key")
    }
}

/// The sentence the user actually reads.
final class ExternalSettingsChangeSummaryTests: XCTestCase {
    private func summary(_ keys: [String]) -> String {
        SettingsStore.ExternalSettingsChange(replacedKeys: keys, observedAt: Date()).summary
    }

    func testNamesOneSettingInTheSingular() {
        XCTAssertEqual(
            summary(["refreshIntervalSeconds"]),
            "Refresh interval seconds now holds the other copy's value."
        )
    }

    func testNamesASmallHandfulInFull() {
        XCTAssertEqual(
            summary(["displayMode", "launchAtLogin"]),
            "Display mode, Launch at login now hold the other copy's value."
        )
    }

    /// A writer that replaced most of the file should not produce a paragraph.
    func testCountsTheRestOnceThereAreTooManyToRead() {
        let summary = summary(["a", "b", "c", "d", "e"])
        XCTAssertTrue(summary.hasPrefix("A, B, C and 2 more settings"), summary)
    }

    /// The notice is only published with keys in it, but the sentence should
    /// not be a fragment if that ever changes.
    func testSaysNothingWhenNothingWasReplaced() {
        XCTAssertEqual(summary([]), "")
    }

    func testKeepsAnAcronymReadable() {
        XCTAssertEqual(
            SettingsStore.ExternalSettingsChange.humanised("mcpServer"), "Mcp server"
        )
    }
}
