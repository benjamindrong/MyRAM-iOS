import Foundation
import SwiftData

struct SyncConflictRestoreResult {
    var conflicts: [SyncConflictVersion]
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

    func markReviewed(_ conflict: SyncConflictVersion, activeNoteID: UUID?) -> SyncConflictRestoreResult? {
        let now = Date()
        var result = SyncConflictRestoreResult(conflicts: store.activeConflicts())

        switch conflict.field {
        case .noteTitle, .noteContent:
            guard let note = fetchNote(withID: conflict.entityID) else { return nil }
            note.modifiedAt = now
            result.note = note
            result.folder = note.folder
            result.shouldRefreshActiveNote = activeNoteID == note.id

        case .folderTitle:
            guard let folder = fetchFolder(withID: conflict.entityID) else { return nil }
            folder.modifiedAt = now
            result.folder = folder

        case .pinnedText:
            guard let thought = fetchPinnedThought(withID: conflict.entityID) else { return nil }
            thought.modifiedAt = now
            thought.note?.modifiedAt = now
            result.pinnedThought = thought
            result.note = thought.note
            result.folder = thought.note?.folder
            result.shouldRefreshActiveNote = activeNoteID == thought.note?.id
        }

        try? context.save()
        result.conflicts = store.removeConflict(id: conflict.id)
        return result
    }

    func restore(_ conflict: SyncConflictVersion, activeNoteID: UUID?) -> SyncConflictRestoreResult? {
        let now = Date()
        var result = SyncConflictRestoreResult(conflicts: store.activeConflicts())

        switch conflict.field {
        case .noteTitle:
            guard let note = fetchNote(withID: conflict.entityID) else { return nil }
            note.title = conflict.remoteText
            note.modifiedAt = now
            result.note = note
            result.folder = note.folder
            result.shouldRefreshActiveNote = activeNoteID == note.id

        case .noteContent:
            guard let note = fetchNote(withID: conflict.entityID) else { return nil }
            note.content = conflict.remoteText
            note.richTextContentData = conflict.remoteRichTextContentData
            note.modifiedAt = now
            result.note = note
            result.folder = note.folder
            result.shouldRefreshActiveNote = activeNoteID == note.id

        case .folderTitle:
            guard let folder = fetchFolder(withID: conflict.entityID) else { return nil }
            folder.name = conflict.remoteText
            folder.modifiedAt = now
            result.folder = folder

        case .pinnedText:
            guard let thought = fetchPinnedThought(withID: conflict.entityID) else { return nil }
            thought.text = conflict.remoteText
            thought.modifiedAt = now
            thought.note?.modifiedAt = now
            result.pinnedThought = thought
            result.note = thought.note
            result.folder = thought.note?.folder
            result.shouldRefreshActiveNote = activeNoteID == thought.note?.id
        }

        try? context.save()
        result.conflicts = store.removeConflict(id: conflict.id)
        return result
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
