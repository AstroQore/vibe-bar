import CoreGraphics
import XCTest
@testable import VibeBarCore

/// The turn text the conversation pane draws, as Core prepares it: a
/// renderer the pane supplies (in the app, `SessionRichTextBuilder`, which
/// has no test target and is held to its contract by the compiler) run off
/// the main actor, cached per text and size; and the contents column's
/// measured previews.
final class SessionRichTextTests: XCTestCase {
    /// Stands in for the app's attributed string.
    final class Rendered: @unchecked Sendable {
        let size: CGFloat
        let source: String
        init(size: CGFloat, source: String) {
            self.size = size
            self.source = source
        }
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        var count: Int { lock.withLock { _count } }
        func bump() { lock.withLock { _count += 1 } }
    }

    func testTheCacheRendersOncePerTextAndSize() {
        let cache = SessionMarkdownCache()
        let renders = Counter()
        let render: (SessionMarkdownDocument, CGFloat) -> AnyObject = { document, size in
            renders.bump()
            return Rendered(size: size, source: document.source)
        }
        let first = cache.rendered(for: "Hello **there**", size: 13, render: render)
        let again = cache.rendered(for: "Hello **there**", size: 13, render: render)
        let larger = cache.rendered(for: "Hello **there**", size: 15, render: render)
        XCTAssertEqual(first, again)
        XCTAssertTrue(first.object === again.object)
        XCTAssertNotEqual(first, larger)
        XCTAssertEqual(renders.count, 2)
        XCTAssertEqual(first.source, "Hello **there**")
        XCTAssertEqual((larger.object as? Rendered)?.size, 15)
        // Rendering is not a second Markdown request.
        XCTAssertEqual(cache.counters.misses, 0)
        XCTAssertEqual(cache.counters.hits, 0)
        _ = cache.document(for: "Hello **there**")
        XCTAssertEqual(cache.counters.hits, 1)
    }

    func testPresentationsCarryRenderedTextOnlyWithARenderer() {
        let turn = SessionStructure.Turn(
            index: 0,
            turnID: "t0",
            status: .completed,
            prompt: SessionStructure.Prompt(origin: .human, text: "  Ask  ", preview: "Ask"),
            steps: [],
            counts: SessionStructure.TurnCounts(),
            finalAnswer: "**Done**"
        )
        let cache = SessionMarkdownCache()
        let plain = SessionTurnPresentation.make(turn, markdown: cache)
        XCTAssertNotNil(plain.answer)
        XCTAssertNil(plain.answerText)
        XCTAssertNil(plain.promptText)

        let style = SessionRichTextStyle(promptSize: 12, answerSize: 16)
        let drawn = SessionTurnPresentation.make(turn, markdown: cache, style: style) { document, size in
            Rendered(size: size, source: document.source)
        }
        XCTAssertEqual((drawn.promptText?.object as? Rendered)?.size, 12)
        XCTAssertEqual((drawn.answerText?.object as? Rendered)?.size, 16)
        XCTAssertEqual(drawn.promptText?.source, "Ask", "trimmed, as the document is")
        XCTAssertEqual(drawn.answerText?.source, "**Done**")
    }

    func testOnlyWebLinksStayLinks() {
        let blocks = SessionMarkdown.document(from: "[site](https://example.com) and [file](file:///etc/hosts)").blocks
        guard case let .paragraph(text) = blocks.first else { return XCTFail("expected a paragraph") }
        XCTAssertEqual(text.runs.compactMap(\.link), [URL(string: "https://example.com")!])
    }

    func testContentsPreviewsAreMeasuredWithTheEntries() {
        func outline(_ index: Int, _ preview: String?, _ origin: SessionStructure.PromptOrigin) -> SessionTurnOutline {
            SessionTurnOutline(turn: SessionStructure.Turn(
                index: index,
                turnID: "t\(index)",
                status: .completed,
                prompt: SessionStructure.Prompt(origin: origin, text: preview, preview: preview),
                steps: [],
                counts: SessionStructure.TurnCounts()
            ))
        }
        let turns = [outline(0, "Short", .human), outline(1, "A longer prompt preview", .human), outline(2, nil, .automation)]
        let measured = SessionConversationTOCEntry.measuredEntries(from: turns) { Double($0.count) * 6 }
        XCTAssertEqual(measured.map(\.previewWidth), [30, 138, 0])
        XCTAssertEqual(measured.map(\.ordinal), [1, 2, 3])
        let unmeasured = SessionConversationTOCEntry.measuredEntries(from: turns, measure: nil)
        XCTAssertEqual(unmeasured.map(\.previewWidth), [0, 0, 0], "without a measure the column measures on its own")
    }
}
