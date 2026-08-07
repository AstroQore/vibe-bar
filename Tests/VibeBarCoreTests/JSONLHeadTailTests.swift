import XCTest
@testable import VibeBarCore

final class JSONLHeadTailTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeBarJSONLHeadTailTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ lines: [String], name: String = "log.jsonl") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func text(_ data: [Data]) -> [String] {
        data.map { String(decoding: $0, as: UTF8.self) }
    }

    func testSmallFileIsReadWhole() throws {
        let url = try write((0..<5).map { "{\"i\":\($0)}" })
        XCTAssertLessThanOrEqual(JSONLHeadTail.fileSize(url), JSONLHeadTail.wholeFileThreshold)

        XCTAssertEqual(text(JSONLHeadTail.headLines(url: url, count: 2)), ["{\"i\":0}", "{\"i\":1}"])
        XCTAssertEqual(text(JSONLHeadTail.tailLines(url: url, count: 2)), ["{\"i\":3}", "{\"i\":4}"])
        XCTAssertEqual(JSONLHeadTail.lineCountIfSmall(url: url), 5)
    }

    func testHeadAndTailClampToAvailableLines() throws {
        let url = try write(["{\"i\":0}", "{\"i\":1}"])
        XCTAssertEqual(text(JSONLHeadTail.headLines(url: url, count: 10)).count, 2)
        XCTAssertEqual(text(JSONLHeadTail.tailLines(url: url, count: 10)).count, 2)
    }

    func testFinalLineWithoutTrailingNewlineIsReturned() throws {
        let url = directory.appendingPathComponent("no-newline.jsonl")
        try "{\"i\":0}\n{\"i\":1}".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(text(JSONLHeadTail.tailLines(url: url, count: 1)), ["{\"i\":1}"])
        XCTAssertEqual(text(JSONLHeadTail.headLines(url: url, count: 5)).count, 2)
    }

    func testLargeFileTailSeeksAndDropsThePartialFirstLine() throws {
        // ~100 KB: well past the 16 KB whole-read threshold, so the tail
        // window opens in the middle of a line.
        let padding = String(repeating: "x", count: 40)
        let lines = (0..<2_000).map { "{\"i\":\($0),\"pad\":\"\(padding)\"}" }
        let url = try write(lines, name: "big.jsonl")
        XCTAssertGreaterThan(JSONLHeadTail.fileSize(url), JSONLHeadTail.wholeFileThreshold)

        let tail = text(JSONLHeadTail.tailLines(url: url, count: 3))
        XCTAssertEqual(tail, Array(lines.suffix(3)))
        for line in tail {
            XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(line.utf8)),
                            "tail window must never hand back a truncated line")
        }

        // Every line inside the seeked window has to be intact, not just
        // the last few — and the window stays capped at the threshold
        // however many lines the caller asks for.
        let window = JSONLHeadTail.tailLines(url: url, count: 5_000)
        XCTAssertGreaterThan(window.count, 100)
        XCTAssertLessThan(window.count, lines.count)
        XCTAssertEqual(text(window), Array(lines.suffix(window.count)))
        for line in window {
            XCTAssertNotNil(try? JSONSerialization.jsonObject(with: line))
        }

        XCTAssertNil(JSONLHeadTail.lineCountIfSmall(url: url),
                     "large files must report an unknown count rather than being read whole")
        XCTAssertEqual(text(JSONLHeadTail.headLines(url: url, count: 2)), Array(lines.prefix(2)))
    }

    func testMissingFileYieldsNothing() {
        let url = directory.appendingPathComponent("absent.jsonl")
        XCTAssertTrue(JSONLHeadTail.headLines(url: url, count: 3).isEmpty)
        XCTAssertTrue(JSONLHeadTail.tailLines(url: url, count: 3).isEmpty)
        XCTAssertNil(JSONLHeadTail.lineCountIfSmall(url: url))
    }

    func testBlankLinesAreSkipped() throws {
        let url = try write(["{\"i\":0}", "", "{\"i\":1}", "", ""])
        XCTAssertEqual(text(JSONLHeadTail.headLines(url: url, count: 5)), ["{\"i\":0}", "{\"i\":1}"])
        XCTAssertEqual(text(JSONLHeadTail.tailLines(url: url, count: 5)), ["{\"i\":0}", "{\"i\":1}"])
        XCTAssertEqual(JSONLHeadTail.lineCountIfSmall(url: url), 2)
    }
}
