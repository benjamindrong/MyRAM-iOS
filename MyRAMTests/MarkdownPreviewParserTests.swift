import Foundation
import XCTest
#if os(macOS)
@testable import MyRAMMac
#else
@testable import MyRAM
#endif

// MARK: - MYR-195 Slice 2: Final Parser contract tests (§6 & §11)

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

    // MARK: 7. Innermost list container style precedence (ordered outer -> unordered inner)
    func testNestedUnorderedListInsideOrderedListUsesUnorderedStyle() {
        let source = "1. Outer\n   - Inner"
        let result = parser.parseDocument(source)
        guard case .rendered(let doc) = result else {
            return XCTFail("Expected rendered")
        }
        XCTAssertGreaterThanOrEqual(doc.blocks.count, 2)
        let innerBlock = doc.blocks.last!
        if case .unorderedListItem(let meta) = innerBlock.kind {
            XCTAssertEqual(meta.style, .unordered, "Innermost container MUST take precedence as unordered style")
        } else {
            XCTFail("Nested unordered item inside ordered item MUST classify as .unorderedListItem, got \(innerBlock.kind)")
        }
    }

    // MARK: 8. Foundation-projected list restarts
    func testSeparateListsAtSameDepthRestartCounterAtOne() {
        let source = "1. List A Item 1\n\nParagraph\n\n1. List B Item 1"
        guard case .rendered(let doc) = parser.parseDocument(source) else {
            return XCTFail("Expected rendered")
        }
        let listBlocks = doc.blocks.filter {
            if case .orderedListItem = $0.kind { return true }; return false
        }
        XCTAssertEqual(listBlocks.count, 2)
        
        if case .orderedListItem(let meta1) = listBlocks[0].kind {
            XCTAssertEqual(meta1.style, .ordered(ordinal: 1))
        }
        if case .orderedListItem(let meta2) = listBlocks[1].kind {
            XCTAssertEqual(meta2.style, .ordered(ordinal: 1), "Separate list B MUST restart counter at 1")
        }
    }

    func testNestedOrderedListPreservesOuterAndInnerOrdinals() {
        let source = "1. Outer\n   1. Inner 1\n   2. Inner 2"
        guard case .rendered(let doc) = parser.parseDocument(source) else {
            return XCTFail("Expected rendered")
        }

        let metadata = doc.blocks.compactMap { block -> MarkdownListMetadata? in
            guard case .orderedListItem(let metadata) = block.kind else { return nil }
            return metadata
        }
        XCTAssertEqual(
            metadata.map(\.style),
            [.ordered(ordinal: 1), .ordered(ordinal: 1), .ordered(ordinal: 2)]
        )
        XCTAssertEqual(metadata.map(\.depth), [1, 2, 2])
    }

    func testMissingOrNonpositiveOrdinalDoesNotFabricateNumberedItem() {
        let orderedContainer = PresentationIntent(.orderedList, identity: 1)
        XCTAssertEqual(
            MarkdownBlockKind(from: orderedContainer),
            .paragraph,
            "An ordered container without a Foundation list-item ordinal MUST remain ordinary content"
        )

        let invalidListItem = PresentationIntent(
            .listItem(ordinal: 0),
            identity: 2,
            parent: orderedContainer
        )
        XCTAssertEqual(
            MarkdownBlockKind(from: invalidListItem),
            .paragraph,
            "A nonpositive Foundation ordinal MUST not be projected as a fabricated numbered item"
        )
    }

    // MARK: 9. Block quote
    func testBlockQuoteProducesBlockQuoteBlock() {
        let result = parser.parseDocument("> A quote")
        guard case .rendered(let doc) = result else {
            return XCTFail("Expected rendered")
        }
        XCTAssertEqual(doc.blocks.count, 1)
        XCTAssertEqual(doc.blocks[0].kind, .blockQuote)
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

    // MARK: 11. Empty source
    func testEmptySourceProducesEmptyDocument() {
        let result = parser.parseDocument("")
        guard case .rendered(let doc) = result else {
            return XCTFail("Empty source must not produce plain-text fallback")
        }
        XCTAssertTrue(doc.blocks.isEmpty, "Empty source produces an empty document")
    }

    // MARK: 12. Forced parser failure returns exact plain-text fallback
    func testForcedParserFailureReturnsExactSource() {
        struct MockError: Error {}
        let failingParser = MarkdownPreviewParser(parseOperation: { _ in throw MockError() })
        let source = "  # Leading and trailing spaces \n\r\n Unicode: 🎉  "
        
        let result = failingParser.parse(source)
        XCTAssertEqual(result, .plainText(source), "Forced parser failure MUST return exact unmodified source")
        
        let docResult = failingParser.parseDocument(source)
        XCTAssertEqual(docResult, .plainTextFallback(source), "Forced parser failure MUST return exact plainTextFallback")
    }

    // MARK: 13. Adjacent paragraphs remain distinct blocks
    func testAdjacentParagraphsRemainDistinctBlocks() {
        let source = "First paragraph.\n\nSecond paragraph."
        guard case .rendered(let doc) = parser.parseDocument(source) else {
            return XCTFail("Expected rendered")
        }
        XCTAssertEqual(doc.blocks.count, 2, "Adjacent paragraphs must produce TWO distinct blocks")
        XCTAssertEqual(doc.blocks[0].kind, .paragraph)
        XCTAssertEqual(doc.blocks[1].kind, .paragraph)
    }

    // MARK: 14. Unknown Foundation presentation intent maps to .paragraph
    func testUnknownPresentationIntentMapsToParagraphKind() {
        let kind = MarkdownBlockKind(from: nil)
        XCTAssertEqual(kind, .paragraph, "nil intent must map to .paragraph")
    }

    // MARK: 15. Foundation list ordinal characterization on deployment SDK (§10.5 & §7 Sixth Remediation)
    func testFoundationListOrdinalCharacterizationOnDeploymentSDK() {
        let testCases: [(source: String, expectedListItems: Int, description: String)] = [
            ("1. First\n2. Second", 2, "Simple ordered list"),
            ("1. Outer\n   1. Inner 1\n   2. Inner 2", 3, "Nested ordered list"),
            ("1. List A\n\nParagraph\n\n1. List B", 2, "Separated ordered lists"),
            ("1. Outer\n   - Inner bullet", 2, "Ordered outer with unordered inner"),
            ("- Outer bullet\n   1. Inner item", 2, "Unordered outer with ordered inner")
        ]

        for testCase in testCases {
            let attributed: AttributedString
            do {
                attributed = try AttributedString(markdown: testCase.source, options: .init(interpretedSyntax: .full))
            } catch {
                XCTFail("Foundation Markdown parsing failed for '\(testCase.description)': \(error)")
                continue
            }

            var observedOrdinals: [Int] = []
            for run in attributed.runs {
                if let intent = run.presentationIntent {
                    for component in intent.components {
                        if case .listItem(let ordinal) = component.kind {
                            observedOrdinals.append(ordinal)
                            XCTAssertGreaterThan(
                                ordinal,
                                0,
                                "Foundation list item ordinal MUST be positive (> 0) for '\(testCase.description)' on deployment SDK"
                            )
                        }
                    }
                }
            }
            XCTAssertFalse(
                observedOrdinals.isEmpty,
                "Foundation MUST produce at least one .listItem component for '\(testCase.description)'"
            )

            let doc = MarkdownPreviewDocument(from: attributed)
            let listBlockCount = doc.blocks.filter { block in
                switch block.kind {
                case .orderedListItem, .unorderedListItem:
                    return true
                default:
                    return false
                }
            }.count

            XCTAssertEqual(
                listBlockCount,
                testCase.expectedListItems,
                "Foundation document projection MUST produce exactly \(testCase.expectedListItems) list item blocks for '\(testCase.description)'"
            )
        }
    }
}
