import Foundation
import NearbySyncCore
import SwiftData

struct SyncConflictRestoreResult {
    var conflicts: [SyncConflictVersion]
    var resolution: SyncTextConflictResolution
    var note: Note?
    var folder: Folder?
    var pinnedThought: PinnedThought?
    var shouldRefreshActiveNote = false
}

@MainActor
final class MyRAMSyncConflictService {
    private let context: ModelContext
    private let store: SyncConflictStore

    init(context: ModelContext, store: SyncConflictStore) {
        self.context = context
        self.store = store
    }

    func activeConflicts() -> [SyncConflictVersion] {
        store.activeConflicts()
    }

    func activeConflicts(for note: Note, in conflicts: [SyncConflictVersion]) -> [SyncConflictVersion] {
        conflicts.filter { conflict in
            conflict.noteID == note.id || (conflict.entityType == .note && conflict.entityID == note.id)
        }
    }

    func keepLocal(_ conflict: SyncConflictVersion, activeNoteID: UUID?) -> SyncConflictRestoreResult? {
        resolve(
            conflict,
            choice: .keepLocal(
                currentLocalText: currentText(for: conflict),
                currentLocalData: currentData(for: conflict)
            ),
            activeNoteID: activeNoteID
        )
    }

    func acceptIncoming(_ conflict: SyncConflictVersion, activeNoteID: UUID?) -> SyncConflictRestoreResult? {
        resolve(conflict, choice: .acceptIncoming, activeNoteID: activeNoteID)
    }

    func saveMergedText(
        _ conflict: SyncConflictVersion,
        text: String,
        activeNoteID: UUID?
    ) -> SyncConflictRestoreResult? {
        resolve(
            conflict,
            choice: .merged(text: text, data: nil),
            activeNoteID: activeNoteID
        )
    }

    private func resolve(
        _ conflict: SyncConflictVersion,
        choice: SyncTextConflictResolutionChoice,
        activeNoteID: UUID?
    ) -> SyncConflictRestoreResult? {
        let now = Date()
        let resolution = SyncTextConflictResolver.resolve(conflict.syncTextConflict, choice: choice)
        var result = SyncConflictRestoreResult(conflicts: store.activeConflicts(), resolution: resolution)

        switch conflict.field {
        case .noteTitle:
            guard let note = fetchNote(withID: conflict.entityID) else { return nil }
            note.title = resolution.resolvedText
            note.modifiedAt = now
            result.note = note
            result.folder = note.folder
            result.shouldRefreshActiveNote = activeNoteID == note.id

        case .noteContent:
            guard let note = fetchNote(withID: conflict.entityID) else { return nil }
            let previousContent = note.content
            note.content = resolution.resolvedText
            if resolution.usesRemoteData {
                note.richTextContentData = RichTextContentCodec.sanitizedConflictRichTextData(
                    resolution.resolvedData,
                    plainText: resolution.resolvedText
                )
            } else if previousContent != resolution.resolvedText {
                note.richTextContentData = resolution.resolvedData
            }
            note.modifiedAt = now
            result.note = note
            result.folder = note.folder
            result.shouldRefreshActiveNote = activeNoteID == note.id

        case .folderTitle:
            guard let folder = fetchFolder(withID: conflict.entityID) else { return nil }
            folder.name = resolution.resolvedText
            folder.modifiedAt = now
            result.folder = folder

        case .pinnedText:
            guard let thought = fetchPinnedThought(withID: conflict.entityID) else { return nil }
            thought.text = resolution.resolvedText
            thought.modifiedAt = now
            thought.note?.modifiedAt = now
            result.pinnedThought = thought
            result.note = thought.note
            result.folder = thought.note?.folder
            result.shouldRefreshActiveNote = activeNoteID == thought.note?.id
        }

        try? context.save()
        result.conflicts = store.removeResolvedConflict(conflict)
        return result
    }

    func markReviewed(_ conflict: SyncConflictVersion, activeNoteID: UUID?) -> SyncConflictRestoreResult? {
        keepLocal(conflict, activeNoteID: activeNoteID)
    }

    func discard(_ conflict: SyncConflictVersion, activeNoteID: UUID?) -> SyncConflictRestoreResult? {
        keepLocal(conflict, activeNoteID: activeNoteID)
    }

    func restore(_ conflict: SyncConflictVersion, activeNoteID: UUID?) -> SyncConflictRestoreResult? {
        acceptIncoming(conflict, activeNoteID: activeNoteID)
    }

    private func currentText(for conflict: SyncConflictVersion) -> String {
        switch conflict.field {
        case .noteTitle:
            fetchNote(withID: conflict.entityID)?.title ?? conflict.localText
        case .noteContent:
            fetchNote(withID: conflict.entityID)?.content ?? conflict.localText
        case .folderTitle:
            fetchFolder(withID: conflict.entityID)?.name ?? conflict.localText
        case .pinnedText:
            fetchPinnedThought(withID: conflict.entityID)?.text ?? conflict.localText
        }
    }

    private func currentData(for conflict: SyncConflictVersion) -> Data? {
        switch conflict.field {
        case .noteContent:
            fetchNote(withID: conflict.entityID)?.richTextContentData
        case .noteTitle, .folderTitle, .pinnedText:
            nil
        }
    }

    private func fetchNote(withID noteID: UUID) -> Note? {
        let descriptor = FetchDescriptor<Note>(
            predicate: #Predicate { note in
                note.id == noteID
            }
        )
        return (try? context.fetch(descriptor))?.first
    }

    private func fetchFolder(withID folderID: UUID) -> Folder? {
        let descriptor = FetchDescriptor<Folder>(
            predicate: #Predicate { folder in
                folder.id == folderID
            }
        )
        return (try? context.fetch(descriptor))?.first
    }

    private func fetchPinnedThought(withID thoughtID: UUID) -> PinnedThought? {
        let descriptor = FetchDescriptor<PinnedThought>(
            predicate: #Predicate { thought in
                thought.id == thoughtID
            }
        )
        return (try? context.fetch(descriptor))?.first
    }
}
