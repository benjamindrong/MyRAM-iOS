#if os(macOS)
// AppKit provides macOS RTF decoding/encoding support for NSAttributedString.
import AppKit
import Foundation
import SwiftData

@MainActor
final class MacSyncBatchApplier {
    private let context: ModelContext
    private let seenBatchStore: MacSyncSeenBatchStore
    private let performSave: () throws -> Void

    init(
        context: ModelContext,
        seenBatchStore: MacSyncSeenBatchStore = MacSyncSeenBatchStore(),
        performSave: (() throws -> Void)? = nil
    ) {
        self.context = context
        self.seenBatchStore = seenBatchStore
        self.performSave = performSave ?? { try context.save() }
    }

    func apply(_ batch: MacSyncBatch) throws -> MacAppliedSyncBatch {
        guard !seenBatchStore.hasSeen(batch.id) else {
            return MacAppliedSyncBatch(batchID: batch.id, changes: [])
        }

        var rollbackSnapshots: [UUID: NoteRollbackSnapshot] = [:]
        do {
            var appliedChanges: [MacAppliedSyncChange] = []
            for change in batch.changes {
                if let appliedChange = try apply(change, rollbackSnapshots: &rollbackSnapshots) {
                    appliedChanges.append(appliedChange)
                }
            }

            try performSave()
            seenBatchStore.markSeen(batch.id)
            return MacAppliedSyncBatch(batchID: batch.id, changes: appliedChanges)
        } catch {
            // Both mechanisms are needed: rollback() discards unsaved changes, but the main
            // context's autosave can persist mid-apply mutations before performSave() throws,
            // and the snapshots restore those. noteCreated needs no snapshot because the
            // exists-guard makes re-applying it on retry idempotent.
            context.rollback()
            rollbackSnapshots.values.forEach { $0.restore() }
            throw error
        }
    }

    private func apply(
        _ change: MacSyncChange,
        rollbackSnapshots: inout [UUID: NoteRollbackSnapshot]
    ) throws -> MacAppliedSyncChange? {
        switch change {
        case .noteCreated(let change):
            return try applyNoteCreated(change)
        case .noteTitleChanged(let change):
            return try applyTitleChanged(change, rollbackSnapshots: &rollbackSnapshots)
        case .noteBodyTextInserted(let change):
            return try applyBodyTextInserted(change, rollbackSnapshots: &rollbackSnapshots)
        case .noteBodyTextDeleted(let change):
            return try applyBodyTextDeleted(change, rollbackSnapshots: &rollbackSnapshots)
        case .noteBodyReconciled(let change):
            throw SyncBatchApplyPreflightError.unsupportedReconciliation(noteID: change.noteID)
        }
    }

    private func applyNoteCreated(_ change: MacSyncNoteCreatedChange) throws -> MacAppliedSyncChange? {
        guard try loadNote(id: change.noteID) == nil else { return nil }

        let note = Note(title: change.title, content: change.body, folder: try loadFolder(id: change.folderID))
        note.id = change.noteID
        note.createdAt = change.createdAt
        note.modifiedAt = change.modifiedAt
        context.insert(note)
        return .noteCreated(
            MacAppliedNoteCreated(
                noteID: change.noteID,
                title: change.title,
                body: change.body,
                modifiedAt: change.modifiedAt
            )
        )
    }

    private func applyTitleChanged(
        _ change: MacSyncNoteTitleChangedChange,
        rollbackSnapshots: inout [UUID: NoteRollbackSnapshot]
    ) throws -> MacAppliedSyncChange? {
        guard let note = try loadNote(id: change.noteID) else { return nil }

        captureRollbackSnapshot(for: note, in: &rollbackSnapshots)
        note.title = change.title
        note.modifiedAt = change.modifiedAt
        return .titleChanged(
            MacAppliedTitleChanged(
                noteID: change.noteID,
                title: change.title,
                modifiedAt: change.modifiedAt
            )
        )
    }

    private func applyBodyTextInserted(
        _ change: MacSyncNoteBodyTextInsertedChange,
        rollbackSnapshots: inout [UUID: NoteRollbackSnapshot]
    ) throws -> MacAppliedSyncChange? {
        guard let note = try loadNote(id: change.noteID), !change.text.isEmpty else { return nil }

        try validateBaseContentHash(change.baseContentHash, for: note)
        captureRollbackSnapshot(for: note, in: &rollbackSnapshots)
        let originalContent = note.content
        let clampedOffset = originalContent.syncBatchClampedUTF16Offset(change.utf16Offset)
        let insertionOffset = originalContent.syncBatchSafeInsertionOffset(fallingForwardFrom: clampedOffset)
        note.content = originalContent.syncBatchInserting(change.text, atUTF16Offset: insertionOffset)
        updateRichTextContent(for: note, originalPlainText: originalContent) { attributedText in
            let attributes = MacRemoteInsertionAttributePolicy.attributesForRemoteInsertion(
                in: attributedText,
                at: insertionOffset
            )
            attributedText.insert(NSAttributedString(string: change.text, attributes: attributes), at: insertionOffset)
        }
        note.modifiedAt = change.modifiedAt
        return .bodyInserted(
            MacAppliedBodyInsertion(
                noteID: change.noteID,
                utf16Offset: insertionOffset,
                text: change.text,
                modifiedAt: change.modifiedAt
            )
        )
    }

    private func applyBodyTextDeleted(
        _ change: MacSyncNoteBodyTextDeletedChange,
        rollbackSnapshots: inout [UUID: NoteRollbackSnapshot]
    ) throws -> MacAppliedSyncChange? {
        guard let note = try loadNote(id: change.noteID),
              change.utf16Length > 0,
              let range = note.content.syncBatchSafeUTF16Range(location: change.utf16Offset, length: change.utf16Length) else {
            return nil
        }

        try validateBaseContentHash(change.baseContentHash, for: note)
        let targetText = (note.content as NSString).substring(with: range)
        if let expectedText = change.expectedText, targetText != expectedText {
            return nil
        }

        captureRollbackSnapshot(for: note, in: &rollbackSnapshots)
        let originalContent = note.content
        note.content = (note.content as NSString).replacingCharacters(in: range, with: "")
        updateRichTextContent(for: note, originalPlainText: originalContent) { attributedText in
            guard NSMaxRange(range) <= attributedText.length else { return }
            attributedText.deleteCharacters(in: range)
        }
        note.modifiedAt = change.modifiedAt
        return .bodyDeleted(
            MacAppliedBodyDeletion(
                noteID: change.noteID,
                range: range,
                deletedText: targetText,
                modifiedAt: change.modifiedAt
            )
        )
    }

    private func loadNote(id: UUID) throws -> Note? {
        let descriptor = FetchDescriptor<Note>(
            predicate: #Predicate { note in
                note.id == id && note.deletedAt == nil
            }
        )
        return try context.fetch(descriptor).first
    }

    private func loadFolder(id: UUID?) throws -> Folder? {
        guard let id else { return nil }
        let descriptor = FetchDescriptor<Folder>(
            predicate: #Predicate { folder in
                folder.id == id
            }
        )
        // Missing folder references intentionally fall back to root so the note is preserved.
        return try context.fetch(descriptor).first
    }

    private func captureRollbackSnapshot(
        for note: Note,
        in rollbackSnapshots: inout [UUID: NoteRollbackSnapshot]
    ) {
        guard rollbackSnapshots[note.id] == nil else { return }
        rollbackSnapshots[note.id] = NoteRollbackSnapshot(note: note)
    }

    private func updateRichTextContent(
        for note: Note,
        originalPlainText: String,
        mutation: (NSMutableAttributedString) -> Void
    ) {
        guard let richTextContentData = note.richTextContentData,
              let attributedText = try? NSMutableAttributedString(
                data: richTextContentData,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
              ),
              attributedText.string == originalPlainText else {
            // RTF is absent, stale, or cannot be decoded. Clear it so the Mac loader
            // falls back to note.content rather than displaying a mismatched rich-text body.
            note.richTextContentData = nil
            return
        }

        mutation(attributedText)
        note.richTextContentData = RTFCoding.encode(attributedText)
    }

    private func validateBaseContentHash(_ expectedHash: String?, for note: Note) throws {
        guard let expectedHash else { return }

        let actualHash = SyncBatchContentHash.sha256Hex(for: note.content)
        guard actualHash == expectedHash else {
            throw SyncBatchApplyPreflightError.mismatchedBaseContentHash(
                noteID: note.id,
                expected: expectedHash,
                actual: actualHash
            )
        }
    }
}

@MainActor
private struct NoteRollbackSnapshot {
    let note: Note
    let title: String
    let content: String
    let richTextContentData: Data?
    let modifiedAt: Date

    init(note: Note) {
        self.note = note
        title = note.title
        content = note.content
        richTextContentData = note.richTextContentData
        modifiedAt = note.modifiedAt
    }

    func restore() {
        note.title = title
        note.content = content
        note.richTextContentData = richTextContentData
        note.modifiedAt = modifiedAt
    }
}
#endif
