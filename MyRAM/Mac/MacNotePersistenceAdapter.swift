#if os(macOS)
import AppKit
import AnchoredSequenceCore
import Foundation
import SwiftData

@MainActor
final class MacNotePersistenceAdapter {
    private let context: ModelContext
    private let saveOperation: (ModelContext) throws -> Void

    init() {
        self.context = PersistenceManager.shared.context
        self.saveOperation = { try $0.save() }
    }

    init(
        context: ModelContext,
        saveOperation: @escaping (ModelContext) throws -> Void = { try $0.save() }
    ) {
        self.context = context
        self.saveOperation = saveOperation
    }

    func loadNotes() throws -> [Note] {
        let descriptor = FetchDescriptor<Note>(
            predicate: #Predicate { note in
                note.deletedAt == nil
            }
        )

        return try context.fetch(descriptor).sortedByMacSelectionOrder()
    }

    func loadNotesCreatingFirstIfNeeded() throws -> [Note] {
        let notes = try loadNotes()
        guard notes.isEmpty else { return notes }

        return [try createNote()]
    }

    func loadNote(id: UUID) throws -> Note? {
        let descriptor = FetchDescriptor<Note>(
            predicate: #Predicate { note in
                note.id == id && note.deletedAt == nil
            }
        )

        return try context.fetch(descriptor).first
    }

    func loadDefaultNote() throws -> Note {
        if let note = try loadNotes().first {
            return note
        }

        return try createNote()
    }

    func createNote(
        title: String = "",
        body: String = "",
        richTextContentData: Data? = nil
    ) throws -> Note {
        let note = Note(title: title, content: body)
        note.richTextContentData = richTextContentData
        do {
            let prepared = try NoteSequenceStateBootstrapPersistence.prepareInitialState(
                noteID: note.id,
                body: note.content
            )
            _ = try NoteSequenceStateFullBodyIntegration.insertNewNote(
                note,
                preparedState: prepared,
                in: context
            )
            try saveOperation(context)
            return note
        } catch {
            context.rollback()
            throw error
        }
    }

    func attributedContent(for note: Note) -> NSAttributedString {
        // Decode intentionally stays local to the Mac adapter: the Mac fallback omits
        // a base font because NSTextView manages its own defaults, while the editor
        // codec requires UIKit fallback attributes.
        if let richTextContentData = note.richTextContentData,
           let attributedText = try? NSAttributedString(
            data: richTextContentData,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
           ) {
            return attributedText
        }

        return NSAttributedString(string: note.content)
    }


    func prepareLocalNoteEdit(
        noteID: UUID,
        proposedAttributedContent: NSAttributedString
    ) throws -> MacPreparedLocalNoteEdit {
        precondition(!SyncBatchAnchoredPayloadCapability.isEnabled)
        return try prepareLegacyLocalNoteEdit(
            noteID: noteID,
            proposedAttributedContent: proposedAttributedContent
        )
    }

    func prepareProductionLocalNoteEdit(
        noteID: UUID,
        proposedAttributedContent: NSAttributedString
    ) async throws -> MacPreparedLocalNoteEdit {
        try await prepareLocalNoteEditCore(
            noteID: noteID,
            proposedAttributedContent: proposedAttributedContent,
            activationEnabled: SyncBatchAnchoredPayloadCapability.isEnabled,
            operationIDReserver: MyRAMSyncOperationIDAllocator.shared
        )
    }

    func prepareLocalNoteEditCore(
        noteID: UUID,
        proposedAttributedContent: NSAttributedString,
        activationEnabled: Bool,
        operationIDReserver: any SyncOperationIDReserving
    ) async throws -> MacPreparedLocalNoteEdit {
        guard activationEnabled else {
            return try prepareLegacyLocalNoteEdit(
                noteID: noteID,
                proposedAttributedContent: proposedAttributedContent
            )
        }
        guard let note = try loadNote(id: noteID) else {
            throw MacPendingSaveFailure.noteMissing(noteID: noteID)
        }

        let modifiedAt = Date()
        let proposedBody = proposedAttributedContent.string
        let proposedRichTextContentData = RTFCoding.encode(proposedAttributedContent)
        let titleChange = SyncBatchNoteChangeCapture.titleChanged(
            noteID: note.id,
            oldTitle: note.title,
            newTitle: note.title,
            modifiedAt: modifiedAt
        ).map { SyncConvergenceCapturedLocalChange(change: $0, evidence: nil) }
        let snapshot = try NoteSequenceStateFullBodyIntegration.loadMutationSnapshot(for: note, in: context)
        let capture = try await SyncBatchAnchoredLocalCapture.capture(
            noteID: note.id,
            oldBody: snapshot.body,
            newBody: proposedBody,
            modifiedAt: modifiedAt,
            initialState: snapshot.state,
            operationIDReserver: operationIDReserver
        )

        return MacPreparedLocalNoteEdit(
            noteID: note.id,
            modifiedAt: modifiedAt,
            previousTitle: note.title,
            previousBody: note.content,
            previousRichTextContentData: note.richTextContentData,
            previousModifiedAt: note.modifiedAt,
            proposedTitle: note.title,
            proposedBody: proposedBody,
            proposedRichTextContentData: proposedRichTextContentData,
            capturedChanges: (titleChange.map { [$0] } ?? []) + capture.capturedChanges,
            hasTitleMutation: titleChange != nil,
            hasBodyMutation: !capture.capturedChanges.isEmpty,
            structuralSnapshot: snapshot,
            finalStructuralState: capture.finalState
        )
    }

    private func prepareLegacyLocalNoteEdit(
        noteID: UUID,
        proposedAttributedContent: NSAttributedString
    ) throws -> MacPreparedLocalNoteEdit {
        guard let note = try loadNote(id: noteID) else {
            throw MacPendingSaveFailure.noteMissing(noteID: noteID)
        }
        let modifiedAt = Date()
        let proposedBody = proposedAttributedContent.string
        let proposedRichTextContentData = RTFCoding.encode(proposedAttributedContent)
        let titleChange = SyncBatchNoteChangeCapture.titleChanged(
            noteID: note.id,
            oldTitle: note.title,
            newTitle: note.title,
            modifiedAt: modifiedAt
        ).map { SyncConvergenceCapturedLocalChange(change: $0, evidence: nil) }
        let bodyChanges = try SyncBatchNoteChangeCapture.capturedBodyChanges(
            noteID: note.id,
            oldBody: note.content,
            newBody: proposedBody,
            modifiedAt: modifiedAt,
            bodyHashCapabilityEnabled: true
        )
        return MacPreparedLocalNoteEdit(
            noteID: note.id,
            modifiedAt: modifiedAt,
            previousTitle: note.title,
            previousBody: note.content,
            previousRichTextContentData: note.richTextContentData,
            previousModifiedAt: note.modifiedAt,
            proposedTitle: note.title,
            proposedBody: proposedBody,
            proposedRichTextContentData: proposedRichTextContentData,
            capturedChanges: (titleChange.map { [$0] } ?? []) + bodyChanges,
            hasTitleMutation: titleChange != nil,
            hasBodyMutation: !bodyChanges.isEmpty,
            structuralSnapshot: nil,
            finalStructuralState: nil
        )
    }

    func persistPreparedLocalNoteEdit(_ prepared: MacPreparedLocalNoteEdit) throws {
        guard let note = try loadNote(id: prepared.noteID) else {
            throw MacPendingSaveFailure.noteMissing(noteID: prepared.noteID)
        }

        let currentTitle = note.title
        let currentBody = note.content
        let currentRichTextContentData = note.richTextContentData
        let currentModifiedAt = note.modifiedAt
        var didStageStructuralMutation = false

        do {
            note.title = prepared.proposedTitle
            if let snapshot = prepared.structuralSnapshot,
               let finalState = prepared.finalStructuralState {
                _ = try NoteSequenceStateFullBodyIntegration.stageSuppliedStateMutation(
                    of: note,
                    expected: snapshot,
                    newBody: prepared.proposedBody,
                    finalState: finalState,
                    in: context
                )
                didStageStructuralMutation = true
            } else {
                note.content = prepared.proposedBody
            }
            note.richTextContentData = prepared.proposedRichTextContentData
            note.modifiedAt = prepared.modifiedAt
            try saveOperation(context)
        } catch {
            // Restore only the fields mutated by this save so unrelated pending context work is preserved.
            var structuralRestorationError: Error?
            if didStageStructuralMutation,
               let snapshot = prepared.structuralSnapshot,
               let finalState = prepared.finalStructuralState {
                do {
                    try NoteSequenceStateFullBodyIntegration.restoreSuppliedStateMutationAfterFailedSave(
                        of: note,
                        expected: snapshot,
                        failedFinalState: finalState,
                        in: context
                    )
                } catch {
                    structuralRestorationError = error
                }
            }
            note.title = currentTitle
            note.content = currentBody
            note.richTextContentData = currentRichTextContentData
            note.modifiedAt = currentModifiedAt
            if let structuralRestorationError {
                throw structuralRestorationError
            }
            throw error
        }
    }

    func save(note: Note, attributedContent: NSAttributedString) throws {
        guard note.deletedAt == nil else {
            throw MacNotePersistenceError.deletedNote
        }

        let storageText = MacEditorTextColorPolicy.sanitizedForPersistence(attributedContent)
        assert(storageText.string == attributedContent.string, "Mac Auto-color persistence sanitization changed note text")
        note.content = storageText.string
        note.richTextContentData = RTFCoding.encode(storageText)
        note.modifiedAt = .now
        try context.save()
    }
}


struct MacPreparedLocalNoteEdit {
    let noteID: UUID
    let modifiedAt: Date
    let previousTitle: String
    let previousBody: String
    let previousRichTextContentData: Data?
    let previousModifiedAt: Date
    let proposedTitle: String
    let proposedBody: String
    let proposedRichTextContentData: Data?
    let capturedChanges: [SyncConvergenceCapturedLocalChange]
    let hasTitleMutation: Bool
    let hasBodyMutation: Bool
    let structuralSnapshot: NoteSequenceStateMutationSnapshot?
    let finalStructuralState: SyncTextSequenceState?

    var hasAnyAuthoritativeMutation: Bool {
        hasTitleMutation || hasBodyMutation
    }
}

enum MacPendingSaveResult: Equatable {
    case noChanges
    case savedWithoutBodyMutation
    case savedWithPendingBodyMutation(noteID: UUID)
    case superseded(noteID: UUID)
    case failed(MacPendingSaveFailure)
}

enum MacPendingSaveFailure: Error, Equatable {
    case noteMissing(noteID: UUID)
    case captureFailed(noteID: UUID)
    case persistenceFailed(noteID: UUID)
}

enum MacNotePersistenceError: Error, Equatable {
    case deletedNote
}

private extension Array where Element == Note {
    func sortedByMacSelectionOrder() -> [Note] {
        sorted { first, second in
            if first.modifiedAt != second.modifiedAt {
                return first.modifiedAt > second.modifiedAt
            }

            if first.createdAt != second.createdAt {
                return first.createdAt > second.createdAt
            }

            // UUID string order makes equal-timestamp lists stable across fetches and test runs.
            return first.id.uuidString < second.id.uuidString
        }
    }
}
#endif
