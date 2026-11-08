import AppKit
import Foundation
import XCTest
@testable import MyRAMMac

@MainActor
final class MacMarkdownPreviewDocumentBuilderTests: XCTestCase {
    private let fixture = """
    # Heading One

    First paragraph with *emphasis*, **strong text**, ***bold italic text***, `inline code`, and a [link](https://example.com).

    Second paragraph.

    1. Ordered first
    2. Ordered second
       - Nested bullet

    > Quoted text

    ```swift
    let value = 1
    print(value)
    ```
    """

    func testBuildProducesOneSemanticDocumentWithDeterministicVisibleText() throws {
        let parser = MarkdownPreviewParser()
        let parsed = parser.parseDocument(fixture)
        guard case .rendered(let projectedDocument) = parsed else {
            return XCTFail("Fixture must render")
        }
        let nestedMetadata = try XCTUnwrap(
            projectedDocument.blocks.compactMap { block -> MarkdownListMetadata? in
                guard case .unorderedListItem(let metadata) = block.kind else { return nil }
                return metadata
            }.first
        )
        XCTAssertEqual(nestedMetadata.depth, 2)

        let document = MacMarkdownPreviewDocumentBuilder(parser: parser).build(source: fixture)
        let expectedCopiedListSubstring =
            "1.\tOrdered first\n" +
            "2.\tOrdered second\n" +
            "    •\tNested bullet"

        XCTAssertTrue(document.string.contains("Heading One\n\nFirst paragraph"))
        XCTAssertTrue(document.string.contains(expectedCopiedListSubstring))
        XCTAssertTrue(document.string.contains("Nested bullet\n\nQuoted text"))
        XCTAssertTrue(document.string.contains("Quoted text\n\nlet value = 1\nprint(value)"))
        XCTAssertFalse(document.string.contains("# Heading"))
        XCTAssertFalse(document.string.contains("**strong"))
        XCTAssertFalse(document.string.contains("```"))
        XCTAssertEqual(
            MacMarkdownPreviewDocumentBuilder().build(source: "Only paragraph").string,
            "Only paragraph",
            "The builder must not append a synthetic final separator"
        )
    }

    func testInlineTraitsCodeAndLinkAreProjectedFromParserRuns() throws {
        let document = MacMarkdownPreviewDocumentBuilder().build(source: fixture)

        assertTraits([.italicFontMask], in: "emphasis", document: document)
        assertTraits([.boldFontMask], in: "strong text", document: document)
        assertTraits([.boldFontMask, .italicFontMask], in: "bold italic text", document: document)

        let codeRange = (document.string as NSString).range(of: "inline code")
        XCTAssertNotEqual(codeRange.location, NSNotFound)
        let codeFont = try XCTUnwrap(document.attribute(.font, at: codeRange.location, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(codeFont.isFixedPitch)
        XCTAssertNotNil(document.attribute(.backgroundColor, at: codeRange.location, effectiveRange: nil))

        let linkRange = (document.string as NSString).range(of: "link")
        let link = try XCTUnwrap(document.attribute(.link, at: linkRange.location, effectiveRange: nil) as? URL)
        XCTAssertEqual(link.absoluteString, "https://example.com")
    }

    func testHeadingListQuoteAndCodeBlockAttributesAreSemantic() throws {
        let document = MacMarkdownPreviewDocumentBuilder().build(source: fixture)

        let headingRange = (document.string as NSString).range(of: "Heading One")
        let headingFont = try XCTUnwrap(document.attribute(.font, at: headingRange.location, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(
            headingFont.pointSize,
            NSFont.preferredFont(forTextStyle: .title1).pointSize,
            accuracy: 0.0001
        )
        XCTAssertTrue(NSFontManager.shared.traits(of: headingFont).contains(.boldFontMask))

        let nestedRange = (document.string as NSString).range(of: "    •\tNested bullet")
        XCTAssertNotEqual(nestedRange.location, NSNotFound)
        let listStyle = try XCTUnwrap(
            document.attribute(.paragraphStyle, at: nestedRange.location, effectiveRange: nil)
                as? NSParagraphStyle
        )
        XCTAssertGreaterThan(listStyle.headIndent, 0)
        XCTAssertEqual(listStyle.firstLineHeadIndent, 0)

        let quoteRange = (document.string as NSString).range(of: "Quoted text")
        XCTAssertNotNil(document.attribute(.backgroundColor, at: quoteRange.location, effectiveRange: nil))
        XCTAssertEqual(
            document.attribute(.foregroundColor, at: quoteRange.location, effectiveRange: nil) as? NSColor,
            NSColor.secondaryLabelColor
        )

        let codeRange = (document.string as NSString).range(of: "let value = 1")
        let codeFont = try XCTUnwrap(document.attribute(.font, at: codeRange.location, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(codeFont.isFixedPitch)
    }

    func testFailingParserPreservesExactPlainTextFallback() {
        enum ExpectedFailure: Error {
            case parse
        }
        let parser = MarkdownPreviewParser { _ in throw ExpectedFailure.parse }
        let builder = MacMarkdownPreviewDocumentBuilder(parser: parser)
        let sources = [
            "  leading and trailing  ",
            "first\r\nsecond\r\n",
            "first\n\nthird",
            "café cafe\u{301} 👩🏽‍💻",
            ""
        ]

        for source in sources {
            XCTAssertEqual(builder.build(source: source).string, source)
        }
    }

    func testTableBuildProducesNativeTextTableStructure() throws {
        let source = """
        | Name | Status |
        | --- | --- |
        | Alpha | Ready |
        | Beta | Pending |
        """

        let document = MacMarkdownPreviewDocumentBuilder().build(source: source)
        XCTAssertFalse(document.string.contains("|"), "Rendered table must not expose raw pipe syntax")
        XCTAssertTrue(document.string.contains("Name"))
        XCTAssertTrue(document.string.contains("Pending"))

        var blocks: [NSTextTableBlock] = []
        document.enumerateAttribute(
            .paragraphStyle,
            in: NSRange(location: 0, length: document.length)
        ) { value, _, _ in
            guard let style = value as? NSParagraphStyle else { return }
            blocks.append(contentsOf: style.textBlocks.compactMap { $0 as? NSTextTableBlock })
        }

        XCTAssertEqual(blocks.count, 6, "Two columns across three rows must produce six native cells")
        XCTAssertEqual(Set(blocks.map { ObjectIdentifier($0.table) }).count, 1)
        XCTAssertEqual(blocks.first?.table.numberOfColumns, 2)
        XCTAssertEqual(
            Set(blocks.map { "\($0.startingRow):\($0.startingColumn)" }),
            Set(["0:0", "0:1", "1:0", "1:1", "2:0", "2:1"])
        )

        let headerBlocks = blocks.filter { $0.startingRow == 0 }
        XCTAssertEqual(headerBlocks.count, 2)
        XCTAssertTrue(headerBlocks.allSatisfy { $0.backgroundColor != nil })

        let headerRange = (document.string as NSString).range(of: "Name")
        let headerFont = try XCTUnwrap(
            document.attribute(.font, at: headerRange.location, effectiveRange: nil) as? NSFont
        )
        XCTAssertTrue(NSFontManager.shared.traits(of: headerFont).contains(.boldFontMask))
    }

    private func assertTraits(
        _ expected: NSFontTraitMask,
        in substring: String,
        document: NSAttributedString,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let range = (document.string as NSString).range(of: substring)
        XCTAssertNotEqual(range.location, NSNotFound, file: file, line: line)
        guard range.location != NSNotFound,
              let font = document.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont else {
            return XCTFail("Missing font for \(substring)", file: file, line: line)
        }
        let traits = NSFontManager.shared.traits(of: font)
        XCTAssertTrue(traits.isSuperset(of: expected), file: file, line: line)
    }
}
