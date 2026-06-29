import XCTest
@testable import MyRAMMac

final class MacEditorSampleDocumentTests: XCTestCase {
    func testDefaultSampleTextIsNonEmpty() {
        XCTAssertFalse(MacEditorSampleDocument.makeSampleText().isEmpty)
    }

    func testDefaultSampleTextIsLargeEnoughForManualEditorVerification() {
        let sampleText = MacEditorSampleDocument.makeSampleText()

        XCTAssertGreaterThan(sampleText.count, 50_000)
        XCTAssertGreaterThan(sampleText.components(separatedBy: .newlines).count, 1_000)
    }

    func testDefaultSampleTextHasSubstantialSectionStructure() {
        let sampleText = MacEditorSampleDocument.makeSampleText()
        let sectionMarkerCount = sampleText.components(separatedBy: "Selection stress section").count - 1
        let checkpointCount = sampleText.components(separatedBy: "Manual checkpoint").count - 1

        XCTAssertEqual(sectionMarkerCount, MacEditorSampleDocument.defaultSectionCount)
        XCTAssertEqual(checkpointCount, MacEditorSampleDocument.defaultSectionCount)
    }

    func testSampleTextGenerationIsDeterministicForSameSectionCount() {
        XCTAssertEqual(
            MacEditorSampleDocument.makeSampleText(sectionCount: 12),
            MacEditorSampleDocument.makeSampleText(sectionCount: 12)
        )
    }

    func testGeneratedSampleTextIncludesRepeatedSectionMarkers() {
        let sampleText = MacEditorSampleDocument.makeSampleText(sectionCount: 3)

        XCTAssertTrue(sampleText.contains("Selection stress section 1"))
        XCTAssertTrue(sampleText.contains("Selection stress section 2"))
        XCTAssertTrue(sampleText.contains("Selection stress section 3"))
    }

    func testGeneratedSampleTextIncludesParagraphAndListStructure() {
        let sampleText = MacEditorSampleDocument.makeSampleText(sectionCount: 1)

        XCTAssertTrue(sampleText.contains("\n\n- Keep this native editor separate"))
        XCTAssertTrue(sampleText.contains("\n- Verify typing, scrolling, selection"))
        XCTAssertTrue(sampleText.contains("\n\nManual checkpoint 1:"))
    }

    func testZeroSectionCountReturnsEmptyText() {
        XCTAssertEqual(MacEditorSampleDocument.makeSampleText(sectionCount: 0), "")
    }

    func testNegativeSectionCountReturnsEmptyText() {
        XCTAssertEqual(MacEditorSampleDocument.makeSampleText(sectionCount: -1), "")
    }
}
