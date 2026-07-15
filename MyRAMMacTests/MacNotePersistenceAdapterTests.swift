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

    func testLoadNotesCreatingFirstIfNeededCreatesNoteWhenStoreIsEmpty() throws {
        let container = try makeInMemoryContainer()
        let adapter = MacNotePersistenceAdapter(context: container.mainContext)

        let notes = try adapter.loadNotesCreatingFirstIfNeeded()

        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes.first?.title, "")
        XCTAssertEqual(notes.first?.content, "")
        XCTAssertNil(notes.first?.deletedAt)
    }

    func testLoadNotesReturnsOnlyNonDeletedNotes() throws {
        let container = try makeInMemoryContainer()
        let context = container.mainContext
        let activeNote = Note(title: "Active", content: "Active body")
        let deletedNote = Note(title: "Deleted", content: "Deleted body")
        deletedNote.deletedAt = Date()
        context.insert(activeNote)
        context.insert(deletedNote)
        try context.save()

        let notes = try MacNotePersistenceAdapter(context: context).loadNotes()

        XCTAssertEqual(notes.map(\.id), [activeNote.id])
    }

    func testLoadNotesSortsByModifiedAtDescending() throws {
        let container = try makeInMemoryContainer()
        let context = container.mainContext
        let oldestNote = Note(title: "Oldest", content: "")
        oldestNote.modifiedAt = Date(timeIntervalSince1970: 100)
        let newestNote = Note(title: "Newest", content: "")
        newestNote.modifiedAt = Date(timeIntervalSince1970: 300)
        let middleNote = Note(title: "Middle", content: "")
        middleNote.modifiedAt = Date(timeIntervalSince1970: 200)
        context.insert(oldestNote)
        context.insert(newestNote)
        context.insert(middleNote)
        try context.save()

        let notes = try MacNotePersistenceAdapter(context: context).loadNotes()

        XCTAssertEqual(notes.map(\.id), [newestNote.id, middleNote.id, oldestNote.id])
    }

    func testLoadNotesUsesDeterministicTieBreakersForEqualModifiedAtValues() throws {
        let container = try makeInMemoryContainer()
        let context = container.mainContext
        let sharedModifiedAt = Date(timeIntervalSince1970: 500)
        let sharedCreatedAt = Date(timeIntervalSince1970: 400)
        let lowerIDNote = Note(title: "Lower", content: "")
        lowerIDNote.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        lowerIDNote.modifiedAt = sharedModifiedAt
        lowerIDNote.createdAt = sharedCreatedAt
        let higherIDNote = Note(title: "Higher", content: "")
        higherIDNote.id = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        higherIDNote.modifiedAt = sharedModifiedAt
        higherIDNote.createdAt = sharedCreatedAt
        let newerCreatedAtNote = Note(title: "Created Later", content: "")
        newerCreatedAtNote.id = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        newerCreatedAtNote.modifiedAt = sharedModifiedAt
        newerCreatedAtNote.createdAt = Date(timeIntervalSince1970: 450)
        context.insert(higherIDNote)
        context.insert(newerCreatedAtNote)
        context.insert(lowerIDNote)
        try context.save()

        let notes = try MacNotePersistenceAdapter(context: context).loadNotes()

        XCTAssertEqual(notes.map(\.id), [newerCreatedAtNote.id, lowerIDNote.id, higherIDNote.id])
    }

    func testCreateNotePersistsBlankNonDeletedNote() throws {
        let container = try makeInMemoryContainer()
        let context = container.mainContext
        let adapter = MacNotePersistenceAdapter(context: context)

        let note = try adapter.createNote()
        let loadedNotes = try adapter.loadNotes()

        XCTAssertEqual(loadedNotes.map(\.id), [note.id])
        XCTAssertEqual(note.title, "")
        XCTAssertEqual(note.content, "")
        XCTAssertNil(note.deletedAt)
    }

    func testLoadNoteReturnsMatchingNonDeletedNote() throws {
        let container = try makeInMemoryContainer()
        let context = container.mainContext
        let matchingNote = Note(title: "Match", content: "Match body")
        let otherNote = Note(title: "Other", content: "Other body")
        let deletedNote = Note(title: "Deleted", content: "Deleted body")
        deletedNote.deletedAt = Date()
        context.insert(matchingNote)
        context.insert(otherNote)
        context.insert(deletedNote)
        try context.save()

        let adapter = MacNotePersistenceAdapter(context: context)

        XCTAssertEqual(try adapter.loadNote(id: matchingNote.id)?.id, matchingNote.id)
        XCTAssertNil(try adapter.loadNote(id: deletedNote.id))
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


    func testPrepareLocalNoteEditCapturesBodyChangesWithoutPersisting() throws {
        let container = try makeInMemoryContainer()
        let context = container.mainContext
        let note = Note(title: "Draft", content: "Hello")
        let originalModifiedAt = Date(timeIntervalSince1970: 100)
        note.modifiedAt = originalModifiedAt
        context.insert(note)
        try context.save()
        let adapter = MacNotePersistenceAdapter(context: context)

        let prepared = try adapter.prepareLocalNoteEdit(
            noteID: note.id,
            proposedAttributedContent: NSAttributedString(string: "Hello world")
        )

        XCTAssertEqual(note.content, "Hello")
        XCTAssertEqual(note.modifiedAt, originalModifiedAt)
        XCTAssertEqual(prepared.previousBody, "Hello")
        XCTAssertEqual(prepared.proposedBody, "Hello world")
        XCTAssertTrue(prepared.hasBodyMutation)
        XCTAssertEqual(prepared.capturedChanges.map(\.change), try SyncBatchNoteChangeCapture.capturedBodyChanges(
            noteID: note.id,
            oldBody: "Hello",
            newBody: "Hello world",
            modifiedAt: prepared.modifiedAt
        ).map(\.change))
        XCTAssertTrue(prepared.capturedChanges.allSatisfy { $0.evidence != nil })
    }

    func testPrepareLocalNoteEditCapturesMultiOperationBodySequence() throws {
        let container = try makeInMemoryContainer()
        let context = container.mainContext
        let note = Note(title: "Draft", content: "ab-cd-ef")
        context.insert(note)
        try context.save()

        let prepared = try MacNotePersistenceAdapter(context: context).prepareLocalNoteEdit(
            noteID: note.id,
            proposedAttributedContent: NSAttributedString(string: "ax-cd-yf")
        )

        XCTAssertGreaterThan(prepared.capturedChanges.count, 1)
        var body = "ab-cd-ef"
        for capturedChange in prepared.capturedChanges {
            XCTAssertEqual(capturedChange.evidence?.preBodyHash, SyncBatchContentHash.sha256Hex(for: body))
            body = try SyncConvergenceLocalEvidenceCapture.apply(capturedChange.change, to: body)
            XCTAssertEqual(capturedChange.evidence?.postBodyHash, SyncBatchContentHash.sha256Hex(for: body))
        }
        XCTAssertEqual(body, "ax-cd-yf")
    }

    func testPersistPreparedLocalNoteEditAppliesOnlyPreparedFields() throws {
        let container = try makeInMemoryContainer()
        let context = container.mainContext
        let note = Note(title: "Draft", content: "Before")
        note.modifiedAt = Date(timeIntervalSince1970: 100)
        context.insert(note)
        try context.save()
        let adapter = MacNotePersistenceAdapter(context: context)
        let prepared = try adapter.prepareLocalNoteEdit(
            noteID: note.id,
            proposedAttributedContent: NSAttributedString(string: "After")
        )

        try adapter.persistPreparedLocalNoteEdit(prepared)

        XCTAssertEqual(note.title, prepared.proposedTitle)
        XCTAssertEqual(note.content, "After")
        XCTAssertEqual(note.modifiedAt, prepared.modifiedAt)
        XCTAssertEqual(note.richTextContentData, prepared.proposedRichTextContentData)
    }

    func testFailedPreparedSaveRestoresTargetFieldsWithoutSavingUnrelatedDirtyState() throws {
        let container = try makeInMemoryContainer()
        let context = container.mainContext
        context.autosaveEnabled = false
        let target = Note(title: "Target", content: "Before")
        target.modifiedAt = Date(timeIntervalSince1970: 100)
        let unrelated = Note(title: "Unrelated", content: "Original")
        context.insert(target)
        context.insert(unrelated)
        try context.save()

        unrelated.content = "Dirty but unsaved"
        var saveAttempts = 0
        let adapter = MacNotePersistenceAdapter(context: context, saveOperation: { _ in
            saveAttempts += 1
            throw MacNotePersistenceAdapterTestError.injectedSaveFailure
        })
        let prepared = try adapter.prepareLocalNoteEdit(
            noteID: target.id,
            proposedAttributedContent: NSAttributedString(string: "After")
        )

        XCTAssertThrowsError(try adapter.persistPreparedLocalNoteEdit(prepared))
        XCTAssertEqual(target.title, "Target")
        XCTAssertEqual(target.content, "Before")
        XCTAssertEqual(target.modifiedAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(unrelated.content, "Dirty but unsaved")
        XCTAssertTrue(context.hasChanges)
        XCTAssertEqual(saveAttempts, 1, "Failure recovery must not issue a second shared-context save.")
    }

    func testPrepareLocalNoteEditRichTextOnlyChangeHasNoAuthoritativeMutation() throws {
        let container = try makeInMemoryContainer()
        let context = container.mainContext
        let note = Note(title: "Styled", content: "Same")
        context.insert(note)
        try context.save()
        let styled = NSMutableAttributedString(string: "Same")
        styled.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 0, length: styled.length))

        let prepared = try MacNotePersistenceAdapter(context: context).prepareLocalNoteEdit(
            noteID: note.id,
            proposedAttributedContent: styled
        )

        XCTAssertFalse(prepared.hasAnyAuthoritativeMutation)
        XCTAssertFalse(prepared.hasBodyMutation)
        XCTAssertTrue(prepared.capturedChanges.isEmpty)
        XCTAssertNotEqual(prepared.previousRichTextContentData, prepared.proposedRichTextContentData)
    }

    func testPrepareLocalNoteEditMissingNoteThrowsSemanticFailure() throws {
        let container = try makeInMemoryContainer()
        let missingID = UUID(uuidString: "00000000-0000-0000-0000-000000000404")!

        XCTAssertThrowsError(
            try MacNotePersistenceAdapter(context: container.mainContext).prepareLocalNoteEdit(
                noteID: missingID,
                proposedAttributedContent: NSAttributedString(string: "Missing")
            )
        ) { error in
            XCTAssertEqual(error as? MacPendingSaveFailure, .noteMissing(noteID: missingID))
        }
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

    func testSavePersistsNilRichTextDataForEmptyAttributedContent() throws {
        let container = try makeInMemoryContainer()
        let context = container.mainContext
        let note = Note(title: "Empty", content: "Existing")
        note.richTextContentData = Data("existing rtf".utf8)
        context.insert(note)
        try context.save()

        try MacNotePersistenceAdapter(context: context).save(
            note: note,
            attributedContent: NSAttributedString(string: "")
        )

        XCTAssertEqual(note.content, "")
        XCTAssertNil(note.richTextContentData)
    }

    func testSavePersistsRTFDataForNonEmptyStyledContent() throws {
        let container = try makeInMemoryContainer()
        let context = container.mainContext
        let note = Note(title: "Styled", content: "")
        context.insert(note)
        try context.save()

        let attributedText = NSMutableAttributedString(string: "Styled body")
        let fullRange = NSRange(location: 0, length: attributedText.length)
        attributedText.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 18), range: fullRange)
        attributedText.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: fullRange)

        let adapter = MacNotePersistenceAdapter(context: context)
        try adapter.save(note: note, attributedContent: attributedText)

        XCTAssertNotNil(note.richTextContentData)
        let decodedText = adapter.attributedContent(for: note)
        XCTAssertEqual(decodedText.string, "Styled body")
        let font = try XCTUnwrap(decodedText.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold))
        try assertColor(decodedText.attribute(.foregroundColor, at: 0, effectiveRange: nil), matches: .systemBlue)
    }

    func testSaveRemovesAutoDisplayColorAndMarkerFromPersistedRTF() throws {
        let container = try makeInMemoryContainer()
        let context = container.mainContext
        let note = Note(title: "Auto", content: "")
        context.insert(note)
        try context.save()

        let attributedText = NSMutableAttributedString(string: "Auto body")
        let fullRange = NSRange(location: 0, length: attributedText.length)
        attributedText.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 18), range: fullRange)
        attributedText.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: fullRange)
        attributedText.addAttribute(.foregroundColor, value: NSColor.textColor, range: fullRange)
        attributedText.addAttribute(.autoTextColorDisplay, value: true, range: fullRange)

        try MacNotePersistenceAdapter(context: context).save(note: note, attributedContent: attributedText)

        XCTAssertEqual(note.content, "Auto body")
        let decodedText = try decodeRawStoredRTF(from: note)
        XCTAssertEqual(decodedText.string, "Auto body")
        XCTAssertNil(decodedText.attribute(.foregroundColor, at: 0, effectiveRange: nil))
        XCTAssertNil(decodedText.attribute(.autoTextColorDisplay, at: 0, effectiveRange: nil))
        XCTAssertNotNil(decodedText.attribute(.font, at: 0, effectiveRange: nil))
        XCTAssertEqual(decodedText.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int, NSUnderlineStyle.single.rawValue)
    }

    func testSavePreservesExplicitColorBesideAutoText() throws {
        let container = try makeInMemoryContainer()
        let context = container.mainContext
        let note = Note(title: "Mixed", content: "")
        context.insert(note)
        try context.save()

        let attributedText = NSMutableAttributedString(string: "AB")
        attributedText.addAttribute(.foregroundColor, value: NSColor.textColor, range: NSRange(location: 0, length: 1))
        attributedText.addAttribute(.autoTextColorDisplay, value: true, range: NSRange(location: 0, length: 1))
        attributedText.addAttribute(.foregroundColor, value: NSColor.systemRed, range: NSRange(location: 1, length: 1))

        try MacNotePersistenceAdapter(context: context).save(note: note, attributedContent: attributedText)

        let decodedText = try decodeRawStoredRTF(from: note)
        XCTAssertNil(decodedText.attribute(.foregroundColor, at: 0, effectiveRange: nil))
        try assertColor(decodedText.attribute(.foregroundColor, at: 1, effectiveRange: nil), matches: .systemRed)
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

    private func decodeRawStoredRTF(from note: Note) throws -> NSAttributedString {
        let data = try XCTUnwrap(note.richTextContentData)
        return try NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
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

private enum MacNotePersistenceAdapterTestError: Error {
    case injectedSaveFailure
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
