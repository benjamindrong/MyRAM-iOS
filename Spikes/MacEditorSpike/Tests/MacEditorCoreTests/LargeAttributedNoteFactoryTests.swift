import AppKit
import XCTest
@testable import MacEditorCore

final class LargeAttributedNoteFactoryTests: XCTestCase {
    func testGeneratedNoteIsLargeEnoughForSelectionStress() {
        let note = LargeAttributedNoteFactory.makeSampleNote(sectionCount: 120)

        XCTAssertGreaterThan(note.length, 80_000)
        XCTAssertTrue(note.string.contains("Selection stress section 120"))
    }

    func testGeneratedNoteContainsRepresentativeRichTextAttributes() {
        let note = LargeAttributedNoteFactory.makeSampleNote(sectionCount: 3)
        let fullRange = NSRange(location: 0, length: note.length)
        var foundLink = false
        var foundUnderline = false
        var foundParagraphStyle = false
        var foundMonospacedFont = false

        note.enumerateAttributes(in: fullRange) { attributes, _, _ in
            foundLink = foundLink || attributes[.link] != nil
            foundUnderline = foundUnderline || attributes[.underlineStyle] != nil
            foundParagraphStyle = foundParagraphStyle || attributes[.paragraphStyle] != nil

            if let font = attributes[.font] as? NSFont {
                foundMonospacedFont = foundMonospacedFont || font.fontDescriptor.symbolicTraits.contains(.monoSpace)
            }
        }

        XCTAssertTrue(foundLink)
        XCTAssertTrue(foundUnderline)
        XCTAssertTrue(foundParagraphStyle)
        XCTAssertTrue(foundMonospacedFont)
    }
}
