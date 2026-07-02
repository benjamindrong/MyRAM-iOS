import Foundation
import SwiftData

@MainActor
final class IPhoneSyncBatchApplier {
    private let context: ModelContext
    private let seenBatchStore: SyncBatchSeenBatchStore
    private let bodyHashCapabilityEnabled: Bool

    init(
        context: ModelContext,
        seenBatchStore: SyncBatchSeenBatchStore = SyncBatchSeenBatchStore(),
        bodyHashCapabilityEnabled: Bool = SyncBatchBodyHashCapability.defaultEnabled
    ) {
        self.context = context
        self.seenBatchStore = seenBatchStore
        self.bodyHashCapabilityEnabled = bodyHashCapabilityEnabled
    }

    func apply(_ batch: SyncBatch) throws {
        guard !seenBatchStore.hasSeen(batch.id) else { return }

        try SyncBatchPreflight(bodyHashCapabilityEnabled: bodyHashCapabilityEnabled).validate(batch: batch) { [weak self] noteID in
            try self?.loadNote(id: noteID)?.content
        }

        for change in batch.changes {
            try apply(change)
        }

        try context.save()
        seenBatchStore.markSeen(batch.id)
    }

    private func apply(_ change: SyncBatchChange) throws {
        switch change {
        case .noteCreated(let change):
            try applyNoteCreated(change)
        case .noteTitleChanged(let change):
            try applyTitleChanged(change)
        case .noteBodyTextInserted(let change):
            try applyBodyTextInserted(change)
        case .noteBodyTextDeleted(let change):
            try applyBodyTextDeleted(change)
        case .noteBodyReconciled(let change):
            throw SyncBatchApplyPreflightError.unsupportedReconciliation(noteID: change.noteID)
        }
    }

    private func applyNoteCreated(_ change: SyncBatchNoteCreatedChange) throws {
        guard try loadNote(id: change.noteID) == nil else { return }

        let note = Note(title: change.title, content: change.body, folder: try loadFolder(id: change.folderID))
        note.id = change.noteID
        note.createdAt = change.createdAt
        note.modifiedAt = change.modifiedAt
        context.insert(note)
    }

    private func applyTitleChanged(_ change: SyncBatchNoteTitleChangedChange) throws {
        guard let note = try loadNote(id: change.noteID) else { return }

        note.title = change.title
        note.modifiedAt = change.modifiedAt
    }

    private func applyBodyTextInserted(_ change: SyncBatchNoteBodyTextInsertedChange) throws {
        guard let note = try loadNote(id: change.noteID), !change.text.isEmpty else { return }

        let clampedOffset = note.content.syncBatchClampedUTF16Offset(change.utf16Offset)
        let insertionOffset = note.content.syncBatchSafeInsertionOffset(fallingForwardFrom: clampedOffset)
        note.content = note.content.syncBatchInserting(change.text, atUTF16Offset: insertionOffset)
        note.richTextContentData = nil
        note.modifiedAt = change.modifiedAt
    }

    private func applyBodyTextDeleted(_ change: SyncBatchNoteBodyTextDeletedChange) throws {
        guard let note = try loadNote(id: change.noteID),
              change.utf16Length > 0,
              let range = note.content.syncBatchSafeUTF16Range(location: change.utf16Offset, length: change.utf16Length) else {
            return
        }

        let targetText = (note.content as NSString).substring(with: range)
        if let expectedText = change.expectedText, targetText != expectedText {
            return
        }

        note.content = (note.content as NSString).replacingCharacters(in: range, with: "")
        note.richTextContentData = nil
        note.modifiedAt = change.modifiedAt
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
        // Missing folders fall back to root so incoming notes are preserved.
        return try context.fetch(descriptor).first
    }

}
