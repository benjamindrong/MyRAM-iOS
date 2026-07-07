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

    @discardableResult
    func apply(_ batch: SyncBatch) throws -> [AppliedEditorMutationBatch] {
        guard !seenBatchStore.hasSeen(batch.id) else { return [] }

        try SyncBatchPreflight(bodyHashCapabilityEnabled: bodyHashCapabilityEnabled).validate(batch: batch) { [weak self] noteID in
            try self?.loadNote(id: noteID)?.content
        }

        var noteOrder: [UUID] = []
        var mutationsByNoteID: [UUID: [AppliedEditorMutation]] = [:]
        for change in batch.changes {
            if let mutation = try apply(change) {
                let noteID = mutation.noteID
                if mutationsByNoteID[noteID] == nil {
                    noteOrder.append(noteID)
                }
                mutationsByNoteID[noteID, default: []].append(mutation)
            }
        }

        try context.save()
        seenBatchStore.markSeen(batch.id)

        return try noteOrder.compactMap { noteID in
            guard let mutations = mutationsByNoteID[noteID],
                  !mutations.isEmpty,
                  let note = try loadNote(id: noteID) else {
                return nil
            }
            return AppliedEditorMutationBatch(
                noteID: noteID,
                mutations: mutations,
                authoritativeBody: note.content
            )
        }
    }

    private func apply(_ change: SyncBatchChange) throws -> AppliedEditorMutation? {
        switch change {
        case .noteCreated(let change):
            try applyNoteCreated(change)
            return nil
        case .noteTitleChanged(let change):
            try applyTitleChanged(change)
            return nil
        case .noteBodyTextInserted(let change):
            return try applyBodyTextInserted(change)
        case .noteBodyTextDeleted(let change):
            return try applyBodyTextDeleted(change)
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

    private func applyBodyTextInserted(_ change: SyncBatchNoteBodyTextInsertedChange) throws -> AppliedEditorMutation? {
        guard let note = try loadNote(id: change.noteID), !change.text.isEmpty else { return nil }

        let clampedOffset = note.content.syncBatchClampedUTF16Offset(change.utf16Offset)
        let insertionOffset = note.content.syncBatchSafeInsertionOffset(fallingForwardFrom: clampedOffset)
        note.content = note.content.syncBatchInserting(change.text, atUTF16Offset: insertionOffset)
        note.richTextContentData = nil
        note.modifiedAt = change.modifiedAt
        return .bodyInsertion(AppliedEditorBodyInsertion(
            noteID: change.noteID,
            utf16Offset: insertionOffset,
            text: change.text,
            modifiedAt: change.modifiedAt
        ))
    }

    private func applyBodyTextDeleted(_ change: SyncBatchNoteBodyTextDeletedChange) throws -> AppliedEditorMutation? {
        guard let note = try loadNote(id: change.noteID),
              change.utf16Length > 0,
              let range = note.content.syncBatchSafeUTF16Range(location: change.utf16Offset, length: change.utf16Length) else {
            return nil
        }

        let targetText = (note.content as NSString).substring(with: range)
        if let expectedText = change.expectedText, targetText != expectedText {
            return nil
        }

        note.content = (note.content as NSString).replacingCharacters(in: range, with: "")
        note.richTextContentData = nil
        note.modifiedAt = change.modifiedAt
        return .bodyDeletion(AppliedEditorBodyDeletion(
            noteID: change.noteID,
            range: range,
            deletedText: targetText,
            modifiedAt: change.modifiedAt
        ))
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
