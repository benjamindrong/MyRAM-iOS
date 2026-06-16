import Foundation
import NearbySyncCore
import SwiftData

struct MyRAMSyncApplyResult {
    var shouldRefreshActiveNote = false
    var deletedCurrentNoteID: UUID?
    var currentFolderReplacementID: UUID?
    var preservedConflicts: [SyncConflictVersion] = []
}

@MainActor
final class MyRAMSyncChangeApplier {
    private let context: ModelContext
    private let conflictStore: SyncConflictStore
    private(set) var syncConflicts: [SyncConflictVersion]
    private var newlyPreservedConflicts: [SyncConflictVersion] = []

    init(context: ModelContext, conflictStore: SyncConflictStore) {
        self.context = context
        self.conflictStore = conflictStore
        syncConflicts = conflictStore.activeConflicts()
    }

    func refreshConflicts() {
        syncConflicts = conflictStore.activeConflicts()
    }

    func apply(
        _ changes: [SyncChange],
        activeNoteID: UUID?,
        currentNoteID: UUID?,
        currentFolderID: UUID?
    ) -> MyRAMSyncApplyResult {
        refreshConflicts()
        newlyPreservedConflicts = []
        var result = MyRAMSyncApplyResult()

        for change in changes.sorted(by: syncApplyOrder) {
            switch change.entityType {
            case .collection:
                result.currentFolderReplacementID = result.currentFolderReplacementID
                    ?? applyIncomingFolderChange(change, currentFolderID: currentFolderID)
            case .item:
                let noteResult = applyIncomingNoteChange(change, activeNoteID: activeNoteID, currentNoteID: currentNoteID)
                result.shouldRefreshActiveNote = result.shouldRefreshActiveNote || noteResult.shouldRefreshActiveNote
                result.deletedCurrentNoteID = result.deletedCurrentNoteID ?? noteResult.deletedCurrentNoteID
            case .marker:
                if applyIncomingPinnedThoughtChange(change, activeNoteID: activeNoteID) {
                    result.shouldRefreshActiveNote = true
                }
            case .attachment:
                if applyIncomingPhotoAttachmentChange(change, activeNoteID: activeNoteID) {
                    result.shouldRefreshActiveNote = true
                }
            case .conflict:
                if applyIncomingConflictChange(change) {
                    result.shouldRefreshActiveNote = true
                }
            }
        }

        result.preservedConflicts = newlyPreservedConflicts

        return result
    }

    private func syncApplyOrder(_ lhs: SyncChange, _ rhs: SyncChange) -> Bool {
        if lhs.entityType.applyPriority == rhs.entityType.applyPriority {
            return lhs.updatedAt < rhs.updatedAt
        }
        return lhs.entityType.applyPriority < rhs.entityType.applyPriority
    }

    private func applyIncomingNoteChange(
        _ change: SyncChange,
        activeNoteID: UUID?,
        currentNoteID: UUID?
    ) -> MyRAMSyncApplyResult {
        guard let payload = try? MyRAMSyncPayloadCoding.decodeNote(from: change.payload) else {
            return MyRAMSyncApplyResult()
        }

        if change.operation == .delete {
            guard let note = fetchNote(withID: payload.id),
                  payload.deletedAt != nil,
                  note.modifiedAt <= payload.modifiedAt else { return MyRAMSyncApplyResult() }
            if preserveNoteDeleteConflictsIfNeeded(note: note, payload: payload) {
                return MyRAMSyncApplyResult(shouldRefreshActiveNote: activeNoteID == payload.id)
            }
            note.deletedAt = payload.deletedAt
            note.modifiedAt = payload.modifiedAt
            return MyRAMSyncApplyResult(
                shouldRefreshActiveNote: activeNoteID == payload.id,
                deletedCurrentNoteID: currentNoteID == payload.id ? payload.id : nil
            )
        }

        let existingNote = fetchNote(withID: payload.id)
        let note = existingNote ?? Note(title: payload.title, content: payload.content, folder: nil)
        if existingNote == nil {
            note.id = payload.id
            context.insert(note)
        } else if note.modifiedAt > payload.modifiedAt {
            return MyRAMSyncApplyResult()
        }

        applyTextPayload(
            to: note,
            payload: payload,
            isNewEntity: existingNote == nil
        )
        note.isPinned = payload.isPinned
        note.createdAt = payload.createdAt
        note.modifiedAt = max(note.modifiedAt, payload.modifiedAt)
        note.deletedAt = payload.deletedAt
        note.folder = payload.folderID.flatMap(fetchFolder(withID:))
        return MyRAMSyncApplyResult(shouldRefreshActiveNote: activeNoteID == payload.id)
    }

    private func applyIncomingFolderChange(_ change: SyncChange, currentFolderID: UUID?) -> UUID? {
        guard let payload = try? MyRAMSyncPayloadCoding.decodeFolder(from: change.payload) else { return nil }

        if change.operation == .delete && payload.isDeleted {
            guard let folder = fetchFolder(withID: payload.id),
                  folder.modifiedAt <= payload.modifiedAt else { return nil }
            if preserveFolderDeleteConflictIfNeeded(folder: folder, payload: payload) {
                return nil
            }
            let replacementFolderID = currentFolderID == folder.id ? folder.parentFolder?.id : nil
            context.delete(folder)
            return replacementFolderID
        }

        let existingFolder = fetchFolder(withID: payload.id)
        let folder = existingFolder ?? Folder(name: payload.name)
        if existingFolder == nil {
            folder.id = payload.id
            context.insert(folder)
        } else if folder.modifiedAt > payload.modifiedAt {
            return nil
        }

        if preserveFolderTitleConflictIfNeeded(folder: folder, payload: payload) {
            return nil
        }
        folder.createdAt = payload.createdAt
        folder.modifiedAt = max(folder.modifiedAt, payload.modifiedAt)
        folder.parentFolder = payload.parentFolderID.flatMap(fetchFolder(withID:))
        return nil
    }

    private func applyIncomingPinnedThoughtChange(_ change: SyncChange, activeNoteID: UUID?) -> Bool {
        guard let payload = try? MyRAMSyncPayloadCoding.decodePinnedThought(from: change.payload) else { return false }

        if change.operation == .delete && payload.isDeleted {
            guard let thought = fetchPinnedThought(withID: payload.id),
                  thought.modifiedAt <= payload.modifiedAt else { return false }
            if preservePinnedThoughtDeleteConflictIfNeeded(thought: thought, payload: payload) {
                return activeNoteID == thought.note?.id
            }
            let note = thought.note
            note?.pinnedThoughts.removeAll { $0.id == thought.id }
            context.delete(thought)
            reorderPinnedThoughts(for: note)
            return activeNoteID == note?.id
        }

        let existingThought = fetchPinnedThought(withID: payload.id)
        let thought = existingThought ?? PinnedThought(text: payload.text, order: payload.order)
        if existingThought == nil {
            thought.id = payload.id
            context.insert(thought)
            savePinnedTextBaseline(thoughtID: thought.id, payload: payload)
        } else if thought.modifiedAt > payload.modifiedAt {
            return false
        }

        if preservePinnedTextConflictIfNeeded(thought: thought, payload: payload) {
            return activeNoteID == thought.note?.id || activeNoteID == payload.noteID
        }

        let previousNoteID = thought.note?.id
        let destinationNote = payload.noteID.flatMap(fetchNote(withID:))
        if previousNoteID != destinationNote?.id {
            thought.note?.pinnedThoughts.removeAll { $0.id == thought.id }
        }
        thought.order = payload.order
        thought.isCollapsed = payload.isCollapsed
        thought.createdAt = payload.createdAt
        thought.modifiedAt = max(thought.modifiedAt, payload.modifiedAt)
        thought.note = destinationNote
        savePinnedTextBaseline(thoughtID: thought.id, payload: payload)
        if let destinationNote,
           !destinationNote.pinnedThoughts.contains(where: { $0.id == thought.id }) {
            destinationNote.pinnedThoughts.append(thought)
        }
        return activeNoteID == previousNoteID || activeNoteID == destinationNote?.id
    }

    private func applyIncomingPhotoAttachmentChange(_ change: SyncChange, activeNoteID: UUID?) -> Bool {
        guard let payload = try? MyRAMSyncPayloadCoding.decodePhotoAttachment(from: change.payload) else { return false }

        if change.operation == .delete || payload.isDeleted {
            guard let attachment = fetchPhotoAttachment(withID: payload.id) else { return false }
            let note = attachment.note
            note?.photoAttachments.removeAll { $0.id == attachment.id }
            context.delete(attachment)
            return activeNoteID == note?.id
        }

        guard let destinationNote = payload.noteID.flatMap(fetchNote(withID:)) else { return false }
        let previousAttachment = fetchPhotoAttachment(withID: payload.id)
        let attachment = previousAttachment ?? NotePhotoAttachment(
            imageData: payload.imageData,
            note: destinationNote
        )

        if attachment.id != payload.id {
            attachment.id = payload.id
            context.insert(attachment)
        } else if attachment.note?.id != destinationNote.id {
            attachment.note?.photoAttachments.removeAll { $0.id == attachment.id }
        }

        attachment.imageData = payload.imageData
        attachment.createdAt = payload.createdAt
        attachment.note = destinationNote
        if !destinationNote.photoAttachments.contains(where: { $0.id == attachment.id }) {
            destinationNote.photoAttachments.append(attachment)
        }
        return activeNoteID == destinationNote.id
    }

    private func applyTextPayload(to note: Note, payload: MyRAMNoteSyncPayload, isNewEntity: Bool) {
        if isNewEntity {
            // First sight of a remote note establishes the remote baseline. The
            // user's later local edits are compared against this before conflicting.
            note.title = payload.title
            note.content = payload.content
            note.richTextContentData = payload.richTextContentData
            saveNoteTitleBaseline(note: note, payload: payload)
            saveNoteContentBaseline(note: note, payload: payload)
            return
        }

        applyOrPreserveNoteText(note: note, payload: payload)
    }

    // Sync text is intentionally local-first. An incoming device event may create
    // text for a brand-new entity, but it must not replace, remove, or delete
    // existing editable text. When incoming note titles, note body text, folder
    // titles, or pinned text diverge from local state, keep the user's current
    // text untouched and save the remote version for non-blocking review.
    private func applyOrPreserveNoteText(note: Note, payload: MyRAMNoteSyncPayload) {
        if note.title != payload.title {
            switch remoteTextResolution(
                entityType: .note,
                entityID: note.id,
                field: .noteTitle,
                localText: note.title,
                localData: nil,
                remoteBaseText: payload.baseTitle,
                remoteBaseData: nil,
                remoteText: payload.title,
                remoteData: nil
            ) {
            case .apply(let text):
                note.title = text
                saveNoteTitleBaseline(note: note, payload: payload)
            case .conflict:
                preserveSyncConflict(
                    entityType: .note,
                    entityID: note.id,
                    noteID: note.id,
                    field: .noteTitle,
                    localText: note.title,
                    remoteText: payload.title,
                    remoteModifiedAt: payload.modifiedAt
                )
            }
        } else {
            saveNoteTitleBaseline(note: note, payload: payload)
        }

        if note.content != payload.content || note.richTextContentData != payload.richTextContentData {
            switch remoteTextResolution(
                entityType: .note,
                entityID: note.id,
                field: .noteContent,
                localText: note.content,
                localData: note.richTextContentData,
                remoteBaseText: payload.baseContent,
                remoteBaseData: payload.baseRichTextContentData,
                remoteText: payload.content,
                remoteData: payload.richTextContentData
            ) {
            case .apply(let text):
                note.content = text
                note.richTextContentData = text == payload.content ? payload.richTextContentData : note.richTextContentData
                saveNoteContentBaseline(note: note, payload: payload)
            case .conflict:
                preserveSyncConflict(
                    entityType: .note,
                    entityID: note.id,
                    noteID: note.id,
                    field: .noteContent,
                    localText: note.content,
                    remoteText: payload.content,
                    remoteRichTextContentData: payload.richTextContentData,
                    remoteModifiedAt: payload.modifiedAt
                )
            }
        } else {
            saveNoteContentBaseline(note: note, payload: payload)
        }
    }

    private func remoteTextResolution(
        entityType: SyncConflictEntityType,
        entityID: UUID,
        field: SyncConflictField,
        localText: String,
        localData: Data?,
        remoteBaseText: String? = nil,
        remoteBaseData: Data? = nil,
        remoteText: String,
        remoteData: Data?
    ) -> RemoteTextResolution {
        if localData != remoteBaseData || remoteData != remoteBaseData {
            if localText == remoteBaseText && localData == remoteBaseData {
                return .apply(remoteText)
            }
            return .conflict
        }

        let baseText = remoteBaseText ?? conflictStore.remoteBaseline(
            entityType: entityType,
            entityID: entityID,
            field: field
        )?.text

        switch SyncThreeWayTextMergePolicy.merge(base: baseText, local: localText, remote: remoteText) {
        case .apply(let text), .merged(let text):
            return .apply(text)
        case .noOp:
            return .apply(localText)
        case .conflict:
            return .conflict
        }
    }

    private func canApplyRemoteText(
        entityType: SyncConflictEntityType,
        entityID: UUID,
        field: SyncConflictField,
        localText: String,
        localData: Data?,
        remoteBaseText: String? = nil,
        remoteBaseData: Data? = nil
    ) -> Bool {
        let baseline = conflictStore.remoteBaseline(entityType: entityType, entityID: entityID, field: field)
        return remoteTextResolution(
            entityType: entityType,
            entityID: entityID,
            field: field,
            localText: localText,
            localData: localData,
            remoteBaseText: remoteBaseText ?? baseline?.text,
            remoteBaseData: remoteBaseData ?? baseline?.richTextContentData,
            remoteText: baseline?.text ?? remoteBaseText ?? localText,
            remoteData: baseline?.richTextContentData ?? remoteBaseData
        ) != .conflict
    }

    private func saveNoteTitleBaseline(note: Note, payload: MyRAMNoteSyncPayload) {
        conflictStore.saveNoteTitleBaseline(
            noteID: note.id,
            title: payload.title,
            modifiedAt: payload.modifiedAt
        )
    }

    private func saveNoteContentBaseline(note: Note, payload: MyRAMNoteSyncPayload) {
        conflictStore.saveNoteContentBaseline(
            noteID: note.id,
            content: payload.content,
            richTextContentData: payload.richTextContentData,
            modifiedAt: payload.modifiedAt
        )
    }

    private func savePinnedTextBaseline(thoughtID: UUID, payload: MyRAMPinnedThoughtSyncPayload) {
        conflictStore.savePinnedTextBaseline(
            thoughtID: thoughtID,
            text: payload.text,
            modifiedAt: payload.modifiedAt
        )
    }

    private func applyIncomingConflictChange(_ change: SyncChange) -> Bool {
        guard let payload = try? MyRAMSyncPayloadCoding.decodeSyncConflict(from: change.payload) else { return false }
        switch payload.action {
        case .preserved:
            guard let conflict = payload.conflict else { return false }
            syncConflicts = conflictStore.preserve(conflict)
            return true
        case .resolved:
            if let conflict = payload.conflict {
                syncConflicts = conflictStore.removeResolvedConflict(conflict)
            } else {
                syncConflicts = conflictStore.removeConflict(id: payload.conflictID)
            }
            return true
        }
    }

    private func preserveFolderTitleConflictIfNeeded(folder: Folder, payload: MyRAMFolderSyncPayload) -> Bool {
        guard folder.name != payload.name else { return false }
        preserveSyncConflict(
            entityType: .folder,
            entityID: folder.id,
            noteID: nil,
            field: .folderTitle,
            localText: folder.name,
            remoteText: payload.name,
            remoteModifiedAt: payload.modifiedAt
        )
        return true
    }

    private func preservePinnedTextConflictIfNeeded(
        thought: PinnedThought,
        payload: MyRAMPinnedThoughtSyncPayload
    ) -> Bool {
        guard thought.text != payload.text else { return false }
        switch remoteTextResolution(
            entityType: .pinnedThought,
            entityID: thought.id,
            field: .pinnedText,
            localText: thought.text,
            localData: nil,
            remoteBaseText: payload.baseText,
            remoteBaseData: nil,
            remoteText: payload.text,
            remoteData: nil
        ) {
        case .apply(let text):
            thought.text = text
            savePinnedTextBaseline(thoughtID: thought.id, payload: payload)
            return false
        case .conflict:
            break
        }
        preserveSyncConflict(
            entityType: .pinnedThought,
            entityID: thought.id,
            noteID: thought.note?.id ?? payload.noteID,
            field: .pinnedText,
            localText: thought.text,
            remoteText: payload.text,
            remoteModifiedAt: payload.modifiedAt
        )
        return true
    }

    private func preserveNoteDeleteConflictsIfNeeded(note: Note, payload: MyRAMNoteSyncPayload) -> Bool {
        // A remote delete should not be blocked just because the sender included
        // newer text. It is a conflict only when local text diverged from the
        // last remote baseline.
        let titleDiverged = note.title != payload.title
            && !canApplyRemoteText(
                entityType: .note,
                entityID: note.id,
                field: .noteTitle,
                localText: note.title,
                localData: nil,
                remoteBaseText: payload.baseTitle,
                remoteBaseData: nil
            )
        let bodyDiverged = (note.content != payload.content || note.richTextContentData != payload.richTextContentData)
            && !canApplyRemoteText(
                entityType: .note,
                entityID: note.id,
                field: .noteContent,
                localText: note.content,
                localData: note.richTextContentData,
                remoteBaseText: payload.baseContent,
                remoteBaseData: payload.baseRichTextContentData
            )
        guard titleDiverged || bodyDiverged else { return false }
        applyOrPreserveNoteText(note: note, payload: payload)
        return true
    }

    private func preserveFolderDeleteConflictIfNeeded(folder: Folder, payload: MyRAMFolderSyncPayload) -> Bool {
        preserveFolderTitleConflictIfNeeded(folder: folder, payload: payload)
    }

    private func preservePinnedThoughtDeleteConflictIfNeeded(
        thought: PinnedThought,
        payload: MyRAMPinnedThoughtSyncPayload
    ) -> Bool {
        preservePinnedTextConflictIfNeeded(thought: thought, payload: payload)
    }

    private func preserveSyncConflict(
        entityType: SyncConflictEntityType,
        entityID: UUID,
        noteID: UUID?,
        field: SyncConflictField,
        localText: String,
        remoteText: String,
        remoteRichTextContentData: Data? = nil,
        remoteModifiedAt: Date
    ) {
        let now = Date()
        guard let preservedConflict = SyncTextConflictPolicy.conflictIfTextDiverged(
            entityType: entityType.syncEntityType,
            entityID: entityID.uuidString,
            fieldID: field.rawValue,
            localText: localText,
            remoteText: remoteText,
            remoteData: remoteRichTextContentData,
            remoteUpdatedAt: remoteModifiedAt,
            preservedAt: now
        ) else { return }

        let conflict = SyncConflictVersion(
            entityType: entityType,
            entityID: entityID,
            noteID: noteID,
            field: field,
            localText: localText,
            remoteText: remoteText,
            remoteRichTextContentData: remoteRichTextContentData,
            remoteModifiedAt: remoteModifiedAt,
            preservedAt: preservedConflict.preservedAt,
            expiresAt: preservedConflict.expiresAt
        )
        syncConflicts = conflictStore.preserve(conflict)
        newlyPreservedConflicts.append(conflict)
    }

    private func reorderPinnedThoughts(for note: Note?) {
        guard let note else { return }
        let sorted = note.pinnedThoughts.sorted {
            if $0.order != $1.order {
                return $0.order < $1.order
            }
            return $0.createdAt < $1.createdAt
        }
        for (index, thought) in sorted.enumerated() {
            thought.order = index
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

    private func fetchPhotoAttachment(withID attachmentID: UUID) -> NotePhotoAttachment? {
        let descriptor = FetchDescriptor<NotePhotoAttachment>(
            predicate: #Predicate { attachment in
                attachment.id == attachmentID
            }
        )
        return (try? context.fetch(descriptor))?.first
    }
}

private extension SyncEntityType {
    var applyPriority: Int {
        switch self {
        case .collection:
            0
        case .item:
            1
        case .marker:
            2
        case .attachment:
            3
        case .conflict:
            4
        }
    }
}

private extension SyncConflictEntityType {
    var syncEntityType: SyncEntityType {
        switch self {
        case .note:
            .item
        case .folder:
            .collection
        case .pinnedThought:
            .marker
        }
    }
}

private enum RemoteTextResolution: Equatable {
    case apply(String)
    case conflict
}
