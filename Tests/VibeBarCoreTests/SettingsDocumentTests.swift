import XCTest
@testable import VibeBarCore

/// Settings are one file with two writers — this app and Vibe Bar Desktop —
/// and, across versions, two vocabularies. Both make a whole-file rewrite
/// lossy, so these cover what a write is allowed to touch.
final class SettingsDocumentTests: XCTestCase {
    private func object(_ json: String) -> SettingsDocument.Object {
        SettingsDocument.object(from: Data(json.utf8)) ?? [:]
    }

    // MARK: - What a write may change

    /// The case that motivates all of this: a key this build has never heard
    /// of, written by another client or a newer version, must survive a write
    /// from a build that cannot decode it.
    func testAKeyThisBuildDoesNotKnowSurvivesAWrite() {
        let baseline = object(#"{"displayMode":"remaining","futureSetting":{"a":1}}"#)
        // What an encoded `AppSettings` looks like in a build that has never
        // heard of `futureSetting`: the key is simply not mentioned.
        let mine = object(#"{"displayMode":"used"}"#)
        let merged = SettingsDocument.merge(
            baseline: baseline, mine: mine, theirs: baseline, owned: ["displayMode"]
        )

        XCTAssertEqual(merged["displayMode"] as? String, "used")
        XCTAssertNotNil(merged["futureSetting"], "a key we cannot decode was deleted")
    }

    /// The same absence, from a build that *does* know the key: then it is a
    /// removal and has to reach the file.
    func testAKeyThisBuildKnowsIsRemovedWhenItGoesMissing() {
        let baseline = object(#"{"displayMode":"remaining","futureSetting":{"a":1}}"#)
        let mine = object(#"{"displayMode":"used"}"#)
        let merged = SettingsDocument.merge(
            baseline: baseline, mine: mine, theirs: baseline,
            owned: ["displayMode", "futureSetting"]
        )

        XCTAssertNil(merged["futureSetting"])
    }

    /// The other client's edit, made while this process was running, is still
    /// there afterwards.
    func testAnotherClientsEditSurvivesThisOnesWrite() {
        let baseline = object(#"{"displayMode":"remaining","refreshIntervalSeconds":600}"#)
        let mine = object(#"{"displayMode":"used","refreshIntervalSeconds":600}"#)
        let theirs = object(#"{"displayMode":"remaining","refreshIntervalSeconds":120}"#)

        let merged = SettingsDocument.merge(baseline: baseline, mine: mine, theirs: theirs)

        XCTAssertEqual(merged["displayMode"] as? String, "used", "our own edit was dropped")
        XCTAssertEqual(
            merged["refreshIntervalSeconds"] as? Int, 120,
            "the other client's edit was overwritten by a value we never touched"
        )
    }

    /// A write that changed nothing changes nothing, however far the file has
    /// moved on. Coalesced writes fire on a timer, and one arriving after
    /// another client wrote must not undo it.
    func testAWriteThatChangedNothingLeavesTheFileAlone() {
        let baseline = object(#"{"displayMode":"remaining"}"#)
        let theirs = object(#"{"displayMode":"used","newKey":true}"#)

        let merged = SettingsDocument.merge(baseline: baseline, mine: baseline, theirs: theirs)

        XCTAssertEqual(merged as NSDictionary, theirs as NSDictionary)
    }

    /// Removing a setting is an edit like any other, and has to reach the file
    /// rather than being read as "unchanged".
    func testRemovingAKeyRemovesIt() {
        let baseline = object(#"{"displayMode":"remaining","customLabels":{"a":"b"}}"#)
        let mine = object(#"{"displayMode":"remaining"}"#)

        let merged = SettingsDocument.merge(
            baseline: baseline, mine: mine, theirs: baseline,
            owned: ["displayMode", "customLabels"]
        )

        XCTAssertNil(merged["customLabels"])
    }

    func testNestedValuesCompareByContentNotIdentity() {
        let baseline = object(#"{"miniWindow":{"fields":["a","b"],"size":{"w":1}}}"#)
        let same = object(#"{"miniWindow":{"size":{"w":1},"fields":["a","b"]}}"#)
        XCTAssertTrue(SettingsDocument.changedKeys(from: baseline, to: same).isEmpty)

        let different = object(#"{"miniWindow":{"fields":["a"],"size":{"w":1}}}"#)
        XCTAssertEqual(
            SettingsDocument.changedKeys(from: baseline, to: different), ["miniWindow"]
        )
    }

    /// An absent key, a present key and an explicit null are three different
    /// statements about a setting.
    func testAbsentAndNullAreNotTheSame() {
        XCTAssertFalse(SettingsDocument.equal(nil, NSNull()))
        XCTAssertTrue(SettingsDocument.equal(NSNull(), NSNull()))
        XCTAssertTrue(SettingsDocument.equal(nil, nil))
    }

    // MARK: - What the user should be told

    /// Only where both sides changed the same key does anyone lose an edit.
    func testOnlyTheSameKeyChangedTwiceIsAConflict() {
        let baseline = object(#"{"displayMode":"remaining","refreshIntervalSeconds":600}"#)
        let mine = object(#"{"displayMode":"used","refreshIntervalSeconds":600}"#)
        let theirs = object(#"{"displayMode":"remaining","refreshIntervalSeconds":120}"#)

        XCTAssertTrue(
            SettingsDocument.conflictingKeys(baseline: baseline, mine: mine, theirs: theirs).isEmpty,
            "editing different settings is not a conflict"
        )
    }

    func testTheSameKeyChangedToTheSameValueIsNotAConflict() {
        let baseline = object(#"{"displayMode":"remaining"}"#)
        let agreed = object(#"{"displayMode":"used"}"#)
        XCTAssertTrue(
            SettingsDocument.conflictingKeys(baseline: baseline, mine: agreed, theirs: agreed)
                .isEmpty,
            "both clients asking for the same thing is agreement, not a conflict"
        )
    }

    func testTheSameKeyChangedTwoWaysIsAConflict() {
        let baseline = object(#"{"displayMode":"remaining"}"#)
        let mine = object(#"{"displayMode":"used"}"#)
        let theirs = object(#"{"displayMode":"forecast"}"#)

        XCTAssertEqual(
            SettingsDocument.conflictingKeys(baseline: baseline, mine: mine, theirs: theirs),
            ["displayMode"]
        )
    }

    // MARK: - Round trip

    /// The bytes a merged write produces are the shape the rest of the app
    /// already writes, so nothing downstream can tell the two apart.
    func testMergedBytesKeepTheFormatTheRestOfTheAppUses() throws {
        let merged = object(#"{"b":2,"a":1}"#)
        let data = try SettingsDocument.data(from: merged)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\n"), "expected pretty-printed output")
        XCTAssertLessThan(
            try XCTUnwrap(text.range(of: "\"a\"")).lowerBound,
            try XCTUnwrap(text.range(of: "\"b\"")).lowerBound,
            "expected sorted keys"
        )
    }

    /// A file that is not an object at all reads as nothing, so a caller falls
    /// back to its defaults rather than treating a corrupt file as "every
    /// setting was cleared" and writing that back.
    func testAFileThatIsNotAnObjectReadsAsNothing() {
        XCTAssertNil(SettingsDocument.object(from: Data("[1,2,3]".utf8)))
        XCTAssertNil(SettingsDocument.object(from: Data("not json".utf8)))
    }
}
