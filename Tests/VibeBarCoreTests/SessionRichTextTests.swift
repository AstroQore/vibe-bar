import AppKit
import XCTest
@testable import VibeBarCore

/// The attributed text the conversation pane draws prompts and answers
/// with, its cache, and the contents column's measured previews.
final class SessionRichTextTests: XCTestCase {
    private func text(_ markdown: String, size: CGFloat = 13) -> NSAttributedString {
        SessionRichText.make(SessionMarkdown.document(from: markdown), fontSize: size).attributed
    }

    private func blocks(_ string: NSAttributedString) -> [NSTextBlock] {
        var out: [NSTextBlock] = []
        string.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: string.length)) { value, _, _ in
            if let style = value as? NSParagraphStyle { out += style.textBlocks }
        }
        return out
    }

    func testOneStringCarriesEveryBlock() {
        let source = """
        ## Result

        The window is **bounded** and `extendEarlier()` pages.

        - one
        - two

        ```swift
        let a = 1
        ```

        | A | B |
        |---|---|
        | 1 | 2 |
        | 3 | 4 |

        ---

        Done.
        """
        let string = text(source)
        XCTAssertTrue(string.string.contains("Result"))
        XCTAssertFalse(string.string.contains("**"), "emphasis is drawn, not shown")
        XCTAssertFalse(string.string.contains("```"))
        XCTAssertFalse(string.string.hasSuffix("\n"))
        let all = blocks(string)
        let cells = all.compactMap { $0 as? NSTextTableBlock }
        // Header plus two rows, two columns.
        XCTAssertEqual(Set(cells.map { "\($0.startingRow),\($0.startingColumn)" }).count, 6)
        XCTAssertEqual(Set(cells.map { ObjectIdentifier($0.table) }).count, 1)
        XCTAssertTrue(all.contains { $0 is SessionRoundedTextBlock }, "the code block is a card")
        // The heading is bold and larger than the body.
        let heading = string.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(heading)
        XCTAssertGreaterThan(heading?.pointSize ?? 0, 13)
        XCTAssertTrue(heading?.fontDescriptor.symbolicTraits.contains(.bold) ?? false)
        // Inline code is monospaced.
        let code = (string.string as NSString).range(of: "extendEarlier()")
        let codeFont = string.attribute(.font, at: code.location, effectiveRange: nil) as? NSFont
        XCTAssertTrue(codeFont?.fontDescriptor.symbolicTraits.contains(.monoSpace) ?? false)
    }

    func testOnlyWebLinksStayLinks() {
        let string = text("[site](https://example.com) and [file](file:///etc/hosts)")
        var links: [URL] = []
        string.enumerateAttribute(.link, in: NSRange(location: 0, length: string.length)) { value, _, _ in
            if let url = value as? URL { links.append(url) }
        }
        XCTAssertEqual(links, [URL(string: "https://example.com")!])
    }

    func testListItemsHangUnderTheirText() {
        let string = text("- a long item that wraps\n- another")
        let style = string.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertGreaterThan(style?.headIndent ?? 0, 0)
    }

    func testTheCacheHandsOutOneStringPerTextAndSize() {
        let cache = SessionMarkdownCache()
        let first = cache.richText(for: "Hello **there**", size: 13)
        let again = cache.richText(for: "Hello **there**", size: 13)
        let larger = cache.richText(for: "Hello **there**", size: 15)
        XCTAssertEqual(first, again)
        XCTAssertTrue(first.attributed === again.attributed)
        XCTAssertNotEqual(first, larger)
        XCTAssertEqual(first.source, "Hello **there**")
        // Building rich text is not a second Markdown request.
        XCTAssertEqual(cache.counters.misses, 0)
        XCTAssertEqual(cache.counters.hits, 0)
        _ = cache.document(for: "Hello **there**")
        XCTAssertEqual(cache.counters.hits, 1)
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
        let short = outline(0, "Short", .human)
        let long = outline(1, String(repeating: "A longer prompt preview ", count: 4), .human)
        let none = outline(2, nil, .automation)
        let entries = SessionConversationTOCEntry.measuredEntries(from: [short, long, none])
        XCTAssertGreaterThan(entries[0].previewWidth, 0)
        XCTAssertGreaterThan(entries[1].previewWidth, entries[0].previewWidth * 4)
        XCTAssertEqual(entries[2].previewWidth, 0)
        XCTAssertEqual(entries.map(\.ordinal), [1, 2, 3])
    }
}
