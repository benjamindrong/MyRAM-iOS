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

        XCTAssertEqual(note.title, "Untitled")
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

    func testSaveStripsDefaultLookingColorsForAppearanceAwareReload() throws {
        let container = try makeInMemoryContainer()
        let context = container.mainContext
        let note = Note(title: "Auto color", content: "")
        context.insert(note)
        try context.save()

        let attributedText = NSMutableAttributedString(string: "Auto underline")
        let fullRange = NSRange(location: 0, length: attributedText.length)
        attributedText.addAttribute(.foregroundColor, value: NSColor.black, range: fullRange)
        attributedText.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: fullRange)
        attributedText.addAttribute(.underlineColor, value: NSColor.black, range: fullRange)
        attributedText.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: fullRange)
        attributedText.addAttribute(.strikethroughColor, value: NSColor.white, range: fullRange)

        let adapter = MacNotePersistenceAdapter(context: context)
        try adapter.save(note: note, attributedContent: attributedText)
        let decodedText = adapter.attributedContent(for: note)

        XCTAssertNil(decodedText.attribute(.foregroundColor, at: 0, effectiveRange: nil))
        XCTAssertNil(decodedText.attribute(.underlineColor, at: 0, effectiveRange: nil))
        XCTAssertNil(decodedText.attribute(.strikethroughColor, at: 0, effectiveRange: nil))
        XCTAssertEqual(
            decodedText.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int,
            NSUnderlineStyle.single.rawValue
        )
        XCTAssertEqual(
            decodedText.attribute(.strikethroughStyle, at: 0, effectiveRange: nil) as? Int,
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
}
