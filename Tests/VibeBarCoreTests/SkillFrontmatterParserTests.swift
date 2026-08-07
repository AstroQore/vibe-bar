import XCTest
@testable import VibeBarCore

final class SkillFrontmatterParserTests: XCTestCase {
    func testParsesDoubleQuotedScalars() {
        let parsed = SkillFrontmatterParser.parse("""
        ---
        name: "lark-base"
        description: "Base operations: tables, fields, records."
        ---

        # body
        """)
        XCTAssertEqual(parsed.name, "lark-base")
        XCTAssertEqual(parsed.description, "Base operations: tables, fields, records.")
    }

    func testParsesSingleQuotedAndPlainScalars() {
        let parsed = SkillFrontmatterParser.parse("""
        ---
        name: 'quoted-name'
        description: plain description without quotes
        ---
        """)
        XCTAssertEqual(parsed.name, "quoted-name")
        XCTAssertEqual(parsed.description, "plain description without quotes")
    }

    func testParsesFoldedDescription() {
        let parsed = SkillFrontmatterParser.parse("""
        ---
        name: check-work
        description: >
          Check your work with a verification subagent that reviews diffs,
          runs builds and tests, and evaluates correctness.
        metadata:
          short-description: "Verify changes with a subagent"
        ---
        """)
        XCTAssertEqual(parsed.name, "check-work")
        XCTAssertEqual(
            parsed.description,
            "Check your work with a verification subagent that reviews diffs, runs builds and tests, and evaluates correctness."
        )
    }

    func testParsesStrippedFoldedAndLiteralBlocks() {
        let stripped = SkillFrontmatterParser.parse("""
        ---
        description: >-
          first line
          second line
        ---
        """)
        XCTAssertEqual(stripped.description, "first line second line")

        let literal = SkillFrontmatterParser.parse("""
        ---
        description: |
          first line
          second line
        ---
        """)
        XCTAssertEqual(literal.description, "first line second line")
    }

    func testSkipsNestedKeysAndUnknownTopLevelKeys() {
        let parsed = SkillFrontmatterParser.parse("""
        ---
        name: nested-skill
        version: 1.2.3
        metadata:
          requires:
            bins: ["lark-cli"]
          name: not-the-skill-name
        ---
        """)
        XCTAssertEqual(parsed.name, "nested-skill")
        XCTAssertNil(parsed.description)
    }

    func testToleratesByteOrderMarkAndCRLF() {
        let parsed = SkillFrontmatterParser.parse("\u{FEFF}---\r\nname: bom-skill\r\ndescription: with CRLF\r\n---\r\n")
        XCTAssertEqual(parsed.name, "bom-skill")
        XCTAssertEqual(parsed.description, "with CRLF")
    }

    func testReturnsEmptyWithoutFrontmatter() {
        XCTAssertEqual(SkillFrontmatterParser.parse("# just markdown\n\nname: not-frontmatter\n"), .empty)
        XCTAssertEqual(SkillFrontmatterParser.parse(""), .empty)
    }

    func testMissingFieldsStayNil() {
        let parsed = SkillFrontmatterParser.parse("""
        ---
        name: only-a-name
        ---
        """)
        XCTAssertEqual(parsed.name, "only-a-name")
        XCTAssertNil(parsed.description)
    }

    func testReadsFromDisk() throws {
        let home = try SkillTestHome()
        let directory = try home.makeSSOTSkill("disk-skill", name: "disk-skill", description: "read from a file")
        let parsed = SkillFrontmatterParser.parse(contentsOf: directory.appendingPathComponent("SKILL.md"))
        XCTAssertEqual(parsed.name, "disk-skill")
        XCTAssertEqual(parsed.description, "read from a file")

        let missing = SkillFrontmatterParser.parse(contentsOf: directory.appendingPathComponent("NOPE.md"))
        XCTAssertEqual(missing, .empty)
    }
}
