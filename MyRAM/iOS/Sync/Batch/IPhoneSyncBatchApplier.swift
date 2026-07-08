import Foundation
import SwiftData

struct IPhoneSyncBatchApplyResult: Equatable {
    enum Disposition: Equatable {
        case applied
        case alreadySeen
    }

    let disposition: Disposition
    let editorMutationBatches: [AppliedEditorMutationBatch]
    let appliedTitleChanges: [AppliedSyncBatchTitleChange]
}

struct AppliedSyncBatchTitleChange: Equatable {
    let noteID: UUID
    let title: String
}

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
    func apply(_ batch: SyncBatch) throws -> IPhoneSyncBatchApplyResult {
        guard !seenBatchStore.hasSeen(batch.id) else {
            return IPhoneSyncBatchApplyResult(
                disposition: .alreadySeen,
                editorMutationBatches: [],
                appliedTitleChanges: []
            )
        }

        try SyncBatchPreflight(bodyHashCapabilityEnabled: bodyHashCapabilityEnabled).validate(batch: batch) { [weak self] noteID in
            try self?.loadNote(id: noteID)?.content
        }

        var noteOrder: [UUID] = []
        var mutationsByNoteID: [UUID: [AppliedEditorMutation]] = [:]
        var titleOrder: [UUID] = []
        var titleByNoteID: [UUID: String] = [:]
        for change in batch.changes {
            let result = try apply(change)
            if let titleChange = result.titleChange {
                if titleByNoteID[titleChange.noteID] == nil {
                    titleOrder.append(titleChange.noteID)
                }
                titleByNoteID[titleChange.noteID] = titleChange.title
            }
            if let mutation = result.editorMutation {
                let noteID = mutation.noteID
                if mutationsByNoteID[noteID] == nil {
                    noteOrder.append(noteID)
                }
                mutationsByNoteID[noteID, default: []].append(mutation)
            }
        }

        try context.save()
        seenBatchStore.markSeen(batch.id)

        let editorMutationBatches: [AppliedEditorMutationBatch] = try noteOrder.compactMap { noteID in
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

        let titleChanges = titleOrder.compactMap { noteID -> AppliedSyncBatchTitleChange? in
            guard let title = titleByNoteID[noteID] else { return nil }
            return AppliedSyncBatchTitleChange(noteID: noteID, title: title)
        }

        return IPhoneSyncBatchApplyResult(
            disposition: .applied,
            editorMutationBatches: editorMutationBatches,
            appliedTitleChanges: titleChanges
        )
    }

    private func apply(_ change: SyncBatchChange) throws -> AppliedSyncBatchChangeResult {
        switch change {
        case .noteCreated(let change):
            try applyNoteCreated(change)
            return AppliedSyncBatchChangeResult()
        case .noteTitleChanged(let change):
            return AppliedSyncBatchChangeResult(titleChange: try applyTitleChanged(change))
        case .noteBodyTextInserted(let change):
            return AppliedSyncBatchChangeResult(editorMutation: try applyBodyTextInserted(change))
        case .noteBodyTextDeleted(let change):
            return AppliedSyncBatchChangeResult(editorMutation: try applyBodyTextDeleted(change))
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

    private func applyTitleChanged(_ change: SyncBatchNoteTitleChangedChange) throws -> AppliedSyncBatchTitleChange? {
        guard let note = try loadNote(id: change.noteID) else { return nil }

        note.title = change.title
        note.modifiedAt = change.modifiedAt
        return AppliedSyncBatchTitleChange(noteID: change.noteID, title: change.title)
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

private struct AppliedSyncBatchChangeResult {
    var editorMutation: AppliedEditorMutation?
    var titleChange: AppliedSyncBatchTitleChange?
}
