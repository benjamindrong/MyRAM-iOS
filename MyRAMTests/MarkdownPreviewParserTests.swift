import Foundation
import XCTest
#if os(macOS)
@testable import MyRAMMac
#else
@testable import MyRAM
#endif

// MARK: - MYR-195 Slice 2: Parser contract tests (§14.1 & Remediation A/E)

final class MarkdownPreviewParserTests: XCTestCase {
    private let parser = MarkdownPreviewParser()

    // MARK: 1. Heading
    func testHeadingProducesHeadingBlock() {
        let result = parser.parseDocument("# Heading One")
        guard case .rendered(let doc) = result else {
            return XCTFail("Expected rendered, got fallback")
        }
        XCTAssertEqual(doc.blocks.count, 1)
        XCTAssertEqual(doc.blocks[0].kind, .heading(level: 1))
        XCTAssertEqual(String(doc.blocks[0].content.characters), "Heading One")
    }

    // MARK: 2. Paragraph
    func testParagraphProducesParagraphBlock() {
        let result = parser.parseDocument("Just a paragraph.")
        guard case .rendered(let doc) = result else {
            return XCTFail("Expected rendered")
        }
        XCTAssertEqual(doc.blocks.count, 1)
        XCTAssertEqual(doc.blocks[0].kind, .paragraph)
        XCTAssertEqual(String(doc.blocks[0].content.characters), "Just a paragraph.")
    }

    // MARK: 3 & 4. Emphasis and strong (inline — remain attributed, not block cases)
    func testEmphasisAndStrongAreInlineAttributes() {
        let result = parser.parse("*em* and **strong**")
        guard case .rendered(let attributed) = result else {
            return XCTFail("Expected rendered")
        }
        let plain = String(attributed.characters)
        XCTAssertTrue(plain.contains("em"), "Emphasis text should be present")
        XCTAssertTrue(plain.contains("strong"), "Strong text should be present")
    }

    // MARK: 5. Ordered list items retain separate block identities and ordinals
    func testOrderedListProducesSeparateOrderedListItemBlocks() {
        let result = parser.parseDocument("1. First\n2. Second")
        guard case .rendered(let doc) = result else {
            return XCTFail("Expected rendered")
        }
        XCTAssertEqual(doc.blocks.count, 2, "Ordered list must produce TWO distinct blocks")
        
        if case .orderedListItem(let meta1) = doc.blocks[0].kind {
            XCTAssertEqual(meta1.style, .ordered(ordinal: 1))
            XCTAssertEqual(String(doc.blocks[0].content.characters), "First")
        } else {
            XCTFail("First item must be .orderedListItem with ordinal 1")
        }

        if case .orderedListItem(let meta2) = doc.blocks[1].kind {
            XCTAssertEqual(meta2.style, .ordered(ordinal: 2))
            XCTAssertEqual(String(doc.blocks[1].content.characters), "Second")
        } else {
            XCTFail("Second item must be .orderedListItem with ordinal 2")
        }
    }

    // MARK: 6. Unordered list items retain separate block identities and bullet style
    func testUnorderedListProducesSeparateUnorderedListItemBlocks() {
        let result = parser.parseDocument("- Alpha\n- Beta")
        guard case .rendered(let doc) = result else {
            return XCTFail("Expected rendered")
        }
        XCTAssertEqual(doc.blocks.count, 2, "Unordered list must produce TWO distinct blocks")

        if case .unorderedListItem(let meta1) = doc.blocks[0].kind {
            XCTAssertEqual(meta1.style, .unordered)
            XCTAssertEqual(String(doc.blocks[0].content.characters), "Alpha")
        } else {
            XCTFail("First item must be .unorderedListItem")
        }

        if case .unorderedListItem(let meta2) = doc.blocks[1].kind {
            XCTAssertEqual(meta2.style, .unordered)
            XCTAssertEqual(String(doc.blocks[1].content.characters), "Beta")
        } else {
            XCTFail("Second item must be .unorderedListItem")
        }
    }

    // MARK: 7. Link and destination (inline — remains attributed)
    func testLinkIsInlineAndParseSucceeds() {
        let result = parser.parse("[Apple](https://apple.com)")
        guard case .rendered(let attributed) = result else {
            return XCTFail("Expected rendered")
        }
        let plain = String(attributed.characters)
        XCTAssertTrue(plain.contains("Apple"), "Link label should be in attributed content")
    }

    // MARK: 8. Block quote
    func testBlockQuoteProducesBlockQuoteBlock() {
        let result = parser.parseDocument("> A quote")
        guard case .rendered(let doc) = result else {
            return XCTFail("Expected rendered")
        }
        XCTAssertEqual(doc.blocks.count, 1)
        XCTAssertEqual(doc.blocks[0].kind, .blockQuote)
    }

    // MARK: 9. Inline code (inline — remains attributed)
    func testInlineCodeIsInlineAttribute() {
        let result = parser.parse("Use `inline` code here.")
        if case .rendered = result {
            // Success
        } else {
            XCTFail("Inline code should not force plain-text fallback")
        }
    }

    // MARK: 10. Fenced code block
    func testFencedCodeBlockProducesCodeBlock() {
        let source = "```swift\nlet x = 1\n```"
        let result = parser.parseDocument(source)
        guard case .rendered(let doc) = result else {
            return XCTFail("Expected rendered")
        }
        XCTAssertEqual(doc.blocks.count, 1)
        XCTAssertEqual(doc.blocks[0].kind, .codeBlock)
    }

    // MARK: 11. Mixed constructs
    func testMixedConstructsParsedWithoutFallback() {
        let source = """
        # Heading

        Paragraph with *em*, **strong**, and [link](https://example.com).

        > Block quote

        1. First
        2. Second

        - Alpha
        - Beta

        Use `inline code`.

        ```swift
        let value = "fenced code"
        ```
        """
        let result = parser.parseDocument(source)
        if case .plainTextFallback = result {
            XCTFail("Mixed constructs must not fall back to plain text")
        }
    }

    // MARK: 12. Empty source
    func testEmptySourceProducesEmptyDocument() {
        let result = parser.parseDocument("")
        guard case .rendered(let doc) = result else {
            return XCTFail("Empty source must not produce plain-text fallback")
        }
        XCTAssertTrue(doc.blocks.isEmpty, "Empty source produces an empty document")
    }

    // MARK: 13. Unicode, combining marks, supplementary scalars
    func testUnicodeParsesWithoutFallback() {
        let source = "Emoji: 🎉 Combining: é\u{0301} Supplementary: 𝄞"
        let result = parser.parseDocument(source)
        if case .plainTextFallback = result {
            XCTFail("Unicode source must not fall back to plain text")
        }
    }

    // MARK: 14. CRLF source
    func testCRLFSourceParsedWithoutFallback() {
        let source = "# Heading\r\n\r\nParagraph."
        let result = parser.parseDocument(source)
        if case .plainTextFallback = result {
            XCTFail("CRLF source must not fall back to plain text")
        }
    }

    // MARK: 15 & 16. Injected forced parser failure returns exact plain-text fallback
    func testForcedParserFailureReturnsExactSource() {
        struct MockError: Error {}
        let failingParser = MarkdownPreviewParser(parseOperation: { _ in throw MockError() })
        let source = "  # Leading and trailing spaces \n\r\n Unicode: 🎉  "
        
        let result = failingParser.parse(source)
        XCTAssertEqual(result, .plainText(source), "Forced parser failure MUST return exact unmodified source")
        
        let docResult = failingParser.parseDocument(source)
        XCTAssertEqual(docResult, .plainTextFallback(source), "Forced parser failure MUST return exact plainTextFallback")
    }

    // MARK: 17. Sibling paragraphs remain distinct blocks
    func testAdjacentParagraphsRemainDistinctBlocks() {
        let source = "First paragraph.\n\nSecond paragraph."
        guard case .rendered(let doc) = parser.parseDocument(source) else {
            return XCTFail("Expected rendered")
        }
        XCTAssertEqual(doc.blocks.count, 2, "Adjacent paragraphs must produce TWO distinct blocks")
        XCTAssertEqual(doc.blocks[0].kind, .paragraph)
        XCTAssertEqual(doc.blocks[1].kind, .paragraph)
    }

    // MARK: 18. Deterministic repeated parsing
    func testDeterministicRepeatedParsing() {
        let source = "# Test\n\nParagraph."
        let first = parser.parseDocument(source)
        let second = parser.parseDocument(source)
        XCTAssertEqual(first, second, "Repeated parsing must be deterministic")
    }

    // MARK: 19. Presentation intent projection permits only six block kinds
    func testProjectionOnlyProducesSixPermittedBlockKinds() {
        let source = """
        # Heading

        Paragraph.

        > Quote

        1. Ordered

        - Unordered

        ```
        code
        ```
        """
        guard case .rendered(let doc) = parser.parseDocument(source) else { return }
        for block in doc.blocks {
            switch block.kind {
            case .paragraph, .heading, .orderedListItem, .unorderedListItem, .blockQuote, .codeBlock:
                break // All permitted
            }
        }
    }

    // MARK: 20. Unknown Foundation presentation intent maps to .paragraph
    func testUnknownPresentationIntentMapsToParagraphKind() {
        var counters: [Int: Int] = [:]
        let kind = MarkdownBlockKind(from: nil, listCounters: &counters)
        XCTAssertEqual(kind, .paragraph, "nil intent must map to .paragraph")
    }
}

// MARK: - Presentation policy tests (§14.2)

final class MarkdownPreviewPresentationTests: XCTestCase {
    func testReminderCopyIsExact() {
        XCTAssertEqual(
            MarkdownPreviewCopy.reminder,
            "Markdown Preview only renders formatting written as Markdown syntax. " +
            "Formatting applied with MyRAM's rich-text controls will not appear here " +
            "or in exported .md files."
        )
    }

    func testMarkdownEditorModeEnumCases() {
        XCTAssertEqual(MarkdownEditorMode.edit.rawValue, "edit")
        XCTAssertEqual(MarkdownEditorMode.preview.rawValue, "preview")
        XCTAssertEqual(MarkdownEditorMode.edit.id, .edit)
    }

    func testFallbackResultPreservesExactSource() {
        let source = "## Source text\n\nWith content."
        let fallback = MarkdownPreviewResult.plainTextFallback(source)
        if case .plainTextFallback(let s) = fallback {
            XCTAssertEqual(s, source)
        }
    }

    func testEmptyDocumentHasNoBlocks() {
        XCTAssertTrue(MarkdownPreviewDocument.empty.blocks.isEmpty)
    }
}
