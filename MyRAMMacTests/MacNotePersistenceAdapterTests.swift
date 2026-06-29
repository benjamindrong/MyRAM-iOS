import AppKit
import SwiftData
import XCTest
@testable import MyRAMMac

@MainActor
final class MacNotePersistenceAdapterTests: XCTestCase {
    func testLoadDefaultNoteCreatesNoteWhenStoreIsEmpty() throws {
        let container = try makeInMemoryContainer()
        let adapter = MacNotePersistenceAdapter(context: container.mainContext)

        let note = try adapter.loadDefaultNote()

        XCTAssertEqual(note.title, "")
        XCTAssertEqual(note.content, "")
        XCTAssertNil(note.deletedAt)
    }

    func testLoadDefaultNoteReturnsMostRecentlyModifiedNonDeletedNote() throws {
        let container = try makeInMemoryContainer()
        let context = container.mainContext
        let olderNote = Note(title: "Older", content: "Older body")
        olderNote.modifiedAt = Date(timeIntervalSince1970: 100)
        let newerNote = Note(title: "Newer", content: "Newer body")
        newerNote.modifiedAt = Date(timeIntervalSince1970: 200)
        context.insert(olderNote)
        context.insert(newerNote)
        try context.save()

        let loadedNote = try MacNotePersistenceAdapter(context: context).loadDefaultNote()

        XCTAssertEqual(loadedNote.id, newerNote.id)
    }

    func testLoadDefaultNoteIgnoresDeletedNotes() throws {
        let container = try makeInMemoryContainer()
        let context = container.mainContext
        let deletedNote = Note(title: "Deleted", content: "Deleted body")
        deletedNote.modifiedAt = Date(timeIntervalSince1970: 300)
        deletedNote.deletedAt = Date()
        let activeNote = Note(title: "Active", content: "Active body")
        activeNote.modifiedAt = Date(timeIntervalSince1970: 100)
        context.insert(deletedNote)
        context.insert(activeNote)
        try context.save()

        let loadedNote = try MacNotePersistenceAdapter(context: context).loadDefaultNote()

        XCTAssertEqual(loadedNote.id, activeNote.id)
    }

    func testSavePersistsPlainTextMirrorAndRichTextData() throws {
        let container = try makeInMemoryContainer()
        let context = container.mainContext
        let note = Note(title: "Saved", content: "")
        context.insert(note)
        try context.save()

        let attributedText = NSMutableAttributedString(string: "Saved body")
        attributedText.addAttribute(
            .underlineStyle,
            value: NSUnderlineStyle.single.rawValue,
            range: NSRange(location: 0, length: attributedText.length)
        )

        try MacNotePersistenceAdapter(context: context).save(note: note, attributedContent: attributedText)

        XCTAssertEqual(note.content, "Saved body")
        XCTAssertNotNil(note.richTextContentData)
        let decodedText = MacNotePersistenceAdapter(context: context).attributedContent(for: note)
        XCTAssertEqual(decodedText.string, "Saved body")
        XCTAssertEqual(
            decodedText.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int,
            NSUnderlineStyle.single.rawValue
        )
    }

    func testSavePreservesExplicitNonDefaultColor() throws {
        let container = try makeInMemoryContainer()
        let context = container.mainContext
        let note = Note(title: "Explicit color", content: "")
        context.insert(note)
        try context.save()

        let attributedText = NSMutableAttributedString(string: "Red text")
        attributedText.addAttribute(
            .foregroundColor,
            value: NSColor.systemRed,
            range: NSRange(location: 0, length: attributedText.length)
        )

        let adapter = MacNotePersistenceAdapter(context: context)
        try adapter.save(note: note, attributedContent: attributedText)
        let decodedText = adapter.attributedContent(for: note)

        XCTAssertNotNil(decodedText.attribute(.foregroundColor, at: 0, effectiveRange: nil))
    }

    func testSavePreservesExplicitBlackForegroundColor() throws {
        try assertForegroundColorSurvivesRoundTrip(NSColor.black)
    }

    func testSavePreservesExplicitWhiteForegroundColor() throws {
        try assertForegroundColorSurvivesRoundTrip(NSColor.white)
    }

    func testSavePreservesExplicitGrayForegroundColor() throws {
        try assertForegroundColorSurvivesRoundTrip(NSColor.gray)
    }

    func testSavePreservesExplicitGrayscaleDecorationColors() throws {
        try assertDecorationColorSurvivesRoundTrip(NSColor.black)
        try assertDecorationColorSurvivesRoundTrip(NSColor.white)
        try assertDecorationColorSurvivesRoundTrip(NSColor.gray)
    }

    func testMalformedRichTextDataFallsBackToPlainText() throws {
        let container = try makeInMemoryContainer()
        let note = Note(title: "Fallback", content: "Plain fallback")
        note.richTextContentData = Data("not rtf".utf8)

        let attributedText = MacNotePersistenceAdapter(context: container.mainContext).attributedContent(for: note)

        XCTAssertEqual(attributedText.string, "Plain fallback")
    }

    func testSaveUpdatesModifiedAt() throws {
        let container = try makeInMemoryContainer()
        let context = container.mainContext
        let note = Note(title: "Timestamp", content: "")
        let originalModifiedAt = Date(timeIntervalSince1970: 100)
        note.modifiedAt = originalModifiedAt
        context.insert(note)
        try context.save()

        try MacNotePersistenceAdapter(context: context).save(
            note: note,
            attributedContent: NSAttributedString(string: "Updated")
        )

        XCTAssertGreaterThan(note.modifiedAt, originalModifiedAt)
    }

    func testSavingDeletedNoteThrows() throws {
        let container = try makeInMemoryContainer()
        let context = container.mainContext
        let note = Note(title: "Deleted", content: "Original")
        note.deletedAt = Date()
        context.insert(note)
        try context.save()

        XCTAssertThrowsError(
            try MacNotePersistenceAdapter(context: context).save(
                note: note,
                attributedContent: NSAttributedString(string: "Changed")
            )
        ) { error in
            XCTAssertEqual(error as? MacNotePersistenceError, .deletedNote)
        }
        XCTAssertEqual(note.content, "Original")
    }

    private func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema([
            Folder.self,
            Note.self,
            NotePhotoAttachment.self,
            PinnedThought.self
        ])
        let configuration = ModelConfiguration(
            "MacNotePersistenceAdapterTests",
            schema: schema,
            isStoredInMemoryOnly: true
        )

        return try ModelContainer(
            for: Folder.self,
            Note.self,
            NotePhotoAttachment.self,
            PinnedThought.self,
            configurations: configuration
        )
    }

    private func assertForegroundColorSurvivesRoundTrip(
        _ color: NSColor,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let decodedText = try roundTripAttributedText(
            color: color,
            colorKey: .foregroundColor
        )

        try assertColor(
            decodedText.attribute(.foregroundColor, at: 0, effectiveRange: nil),
            matches: color,
            file: file,
            line: line
        )
    }

    private func assertDecorationColorSurvivesRoundTrip(
        _ color: NSColor,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let underlineText = try roundTripAttributedText(
            color: color,
            colorKey: .underlineColor,
            styleKey: .underlineStyle
        )
        try assertColor(
            underlineText.attribute(.underlineColor, at: 0, effectiveRange: nil),
            matches: color,
            file: file,
            line: line
        )

        let strikethroughText = try roundTripAttributedText(
            color: color,
            colorKey: .strikethroughColor,
            styleKey: .strikethroughStyle
        )
        try assertColor(
            strikethroughText.attribute(.strikethroughColor, at: 0, effectiveRange: nil),
            matches: color,
            file: file,
            line: line
        )
    }

    private func roundTripAttributedText(
        color: NSColor,
        colorKey: NSAttributedString.Key,
        styleKey: NSAttributedString.Key? = nil
    ) throws -> NSAttributedString {
        let container = try makeInMemoryContainer()
        let context = container.mainContext
        let note = Note(title: "Explicit color", content: "")
        context.insert(note)
        try context.save()

        let attributedText = NSMutableAttributedString(string: "Color")
        let fullRange = NSRange(location: 0, length: attributedText.length)
        attributedText.addAttribute(colorKey, value: color, range: fullRange)
        if let styleKey {
            attributedText.addAttribute(styleKey, value: NSUnderlineStyle.single.rawValue, range: fullRange)
        }

        let adapter = MacNotePersistenceAdapter(context: context)
        try adapter.save(note: note, attributedContent: attributedText)
        return adapter.attributedContent(for: note)
    }

    private func assertColor(
        _ value: Any?,
        matches expectedColor: NSColor,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let decodedColor = try XCTUnwrap(value as? NSColor, file: file, line: line)
        let decodedComponents = try XCTUnwrap(decodedColor.macTestRGBAValues, file: file, line: line)
        let expectedComponents = try XCTUnwrap(expectedColor.macTestRGBAValues, file: file, line: line)

        XCTAssertEqual(decodedComponents.red, expectedComponents.red, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(decodedComponents.green, expectedComponents.green, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(decodedComponents.blue, expectedComponents.blue, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(decodedComponents.alpha, expectedComponents.alpha, accuracy: 0.01, file: file, line: line)
    }
}

private extension NSColor {
    var macTestRGBAValues: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)? {
        guard let color = usingColorSpace(.deviceRGB) ?? usingColorSpace(.sRGB) else {
            return nil
        }

        return (
            red: color.redComponent,
            green: color.greenComponent,
            blue: color.blueComponent,
            alpha: color.alphaComponent
        )
    }
}
