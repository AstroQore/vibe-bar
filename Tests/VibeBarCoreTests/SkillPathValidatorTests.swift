import XCTest
@testable import VibeBarCore

final class SkillPathValidatorTests: XCTestCase {
    func testAcceptsOrdinarySingleComponentNames() {
        let accepted = [
            "a",
            "my-skill",
            "my_skill",
            "my.skill",
            "MySkill",
            "skill123",
            "skill with space",
            "日本語スキル",
            "skill:with-colon",
            "skill-"
        ]
        for name in accepted {
            XCTAssertTrue(SkillPathValidator.isValid(name), "expected \(name) to be valid")
            XCTAssertNoThrow(try SkillPathValidator.validate(directoryName: name))
        }
    }

    func testRejectsEmptySeparatorsDotsAndHiddenNames() {
        let rejected = [
            "",
            ".",
            "..",
            "...",
            ".hidden",
            ".DS_Store",
            "/",
            "\\",
            "a/b",
            "../evil",
            "..%2Fevil/..",
            "a\\b",
            "/absolute",
            "trailing/",
            "nested/dir/name"
        ]
        for name in rejected {
            XCTAssertFalse(SkillPathValidator.isValid(name), "expected \(name) to be rejected")
        }
    }

    func testRejectsControlCharacters() {
        let rejected = [
            "line\nbreak",
            "tab\tseparated",
            "carriage\rreturn",
            "null\u{0}byte",
            "delete\u{7F}char",
            "\u{1}"
        ]
        for name in rejected {
            XCTAssertFalse(SkillPathValidator.isValid(name), "expected control char in \(name.debugDescription) to be rejected")
        }
    }

    func testValidateThrowsInvalidDirectoryName() {
        XCTAssertThrowsError(try SkillPathValidator.validate(directoryName: "../escape")) { error in
            XCTAssertEqual(error as? SkillError, .invalidDirectoryName("../escape"))
        }
    }
}
