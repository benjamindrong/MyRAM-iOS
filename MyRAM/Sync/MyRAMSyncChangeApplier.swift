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
    private let isTextApplicationUnsafe: (SyncConflictEntityType, UUID, SyncConflictField) -> Bool
    private(set) var syncConflicts: [SyncConflictVersion]
    private var newlyPreservedConflicts: [SyncConflictVersion] = []

    init(
        context: ModelContext,
        conflictStore: SyncConflictStore,
        isTextApplicationUnsafe: @escaping (SyncConflictEntityType, UUID, SyncConflictField) -> Bool = { _, _, _ in false }
    ) {
        self.context = context
        self.conflictStore = conflictStore
        self.isTextApplicationUnsafe = isTextApplicationUnsafe
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
        if lhs.isResolvedConflictMetadata != rhs.isResolvedConflictMetadata {
            return lhs.isResolvedConflictMetadata
        }
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
            if shouldFreezeIncomingNotePayload(note: note, payload: payload, originDeviceID: change.originDeviceID) {
                preserveIncomingNoteTextConflictsIfNeeded(note: note, payload: payload, originDeviceID: change.originDeviceID)
                return MyRAMSyncApplyResult(shouldRefreshActiveNote: activeNoteID == payload.id)
            }
            if preserveNoteDeleteConflictsIfNeeded(note: note, payload: payload, originDeviceID: change.originDeviceID) {
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
        let isNewNote = existingNote == nil
        if existingNote == nil {
            note.id = payload.id
            context.insert(note)
        } else if note.modifiedAt > payload.modifiedAt {
            return MyRAMSyncApplyResult()
        }

        if !isNewNote,
           shouldFreezeIncomingNotePayload(note: note, payload: payload, originDeviceID: change.originDeviceID) {
            preserveIncomingNoteTextConflictsIfNeeded(note: note, payload: payload, originDeviceID: change.originDeviceID)
            return MyRAMSyncApplyResult(shouldRefreshActiveNote: activeNoteID == payload.id)
        }

        applyTextPayload(
            to: note,
            payload: payload,
            isNewEntity: existingNote == nil,
            originDeviceID: change.originDeviceID
        )
        note.isPinned = payload.isPinned
        note.createdAt = payload.createdAt
        note.modifiedAt = isNewNote ? payload.modifiedAt : max(note.modifiedAt, payload.modifiedAt)
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
        let isNewFolder = existingFolder == nil
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
        folder.modifiedAt = isNewFolder ? payload.modifiedAt : max(folder.modifiedAt, payload.modifiedAt)
        folder.parentFolder = payload.parentFolderID.flatMap(fetchFolder(withID:))
        return nil
    }

    private func applyIncomingPinnedThoughtChange(_ change: SyncChange, activeNoteID: UUID?) -> Bool {
        guard let payload = try? MyRAMSyncPayloadCoding.decodePinnedThought(from: change.payload) else { return false }

        if change.operation == .delete && payload.isDeleted {
            guard let thought = fetchPinnedThought(withID: payload.id),
                  thought.modifiedAt <= payload.modifiedAt else { return false }
            if shouldFreezeIncomingPinnedThoughtPayload(thought: thought, payload: payload, originDeviceID: change.originDeviceID) {
                preserveIncomingPinnedTextConflictIfNeeded(
                    thought: thought,
                    payload: payload,
                    originDeviceID: change.originDeviceID
                )
                return activeNoteID == thought.note?.id
            }
            if preservePinnedThoughtDeleteConflictIfNeeded(
                thought: thought,
                payload: payload,
                originDeviceID: change.originDeviceID
            ) {
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
        let isNewThought = existingThought == nil
        if existingThought == nil {
            thought.id = payload.id
            context.insert(thought)
            savePinnedTextBaseline(thoughtID: thought.id, payload: payload, originDeviceID: change.originDeviceID)
        } else if thought.modifiedAt > payload.modifiedAt {
            return false
        }

        if !isNewThought,
           shouldFreezeIncomingPinnedThoughtPayload(thought: thought, payload: payload, originDeviceID: change.originDeviceID) {
            preserveIncomingPinnedTextConflictIfNeeded(
                thought: thought,
                payload: payload,
                originDeviceID: change.originDeviceID
            )
            return activeNoteID == thought.note?.id || activeNoteID == payload.noteID
        }

        if preservePinnedTextConflictIfNeeded(thought: thought, payload: payload, originDeviceID: change.originDeviceID) {
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
        thought.modifiedAt = isNewThought ? payload.modifiedAt : max(thought.modifiedAt, payload.modifiedAt)
        thought.note = destinationNote
        savePinnedTextBaseline(thoughtID: thought.id, payload: payload, originDeviceID: change.originDeviceID)
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

    private func applyTextPayload(
        to note: Note,
        payload: MyRAMNoteSyncPayload,
        isNewEntity: Bool,
        originDeviceID: String
    ) {
        if isNewEntity {
            // First sight of a remote note establishes the remote baseline. The
            // user's later local edits are compared against this before conflicting.
            note.title = payload.title
            note.content = payload.content
            note.richTextContentData = payload.richTextContentData
            saveNoteTitleBaseline(note: note, payload: payload, originDeviceID: originDeviceID)
            saveNoteContentBaseline(note: note, payload: payload, originDeviceID: originDeviceID)
            return
        }

        applyOrPreserveNoteText(note: note, payload: payload, originDeviceID: originDeviceID)
    }

    private func shouldFreezeIncomingNotePayload(
        note: Note,
        payload: MyRAMNoteSyncPayload,
        originDeviceID: String
    ) -> Bool {
        if hasActiveNoteTextConflict(noteID: note.id) {
            return true
        }

        if note.title != payload.title,
           noteTitleResolution(note: note, payload: payload, originDeviceID: originDeviceID).freezesOrdinaryPayload {
            return true
        }

        if (note.content != payload.content || note.richTextContentData != payload.richTextContentData),
           noteContentResolution(note: note, payload: payload, originDeviceID: originDeviceID).freezesOrdinaryPayload {
            return true
        }

        return false
    }

    private func preserveIncomingNoteTextConflictsIfNeeded(
        note: Note,
        payload: MyRAMNoteSyncPayload,
        originDeviceID: String
    ) {
        if note.title != payload.title,
           noteTitleResolution(note: note, payload: payload, originDeviceID: originDeviceID) == .conflict {
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

        if note.content != payload.content || note.richTextContentData != payload.richTextContentData,
           noteContentResolution(note: note, payload: payload, originDeviceID: originDeviceID) == .conflict {
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
    }

    private func hasActiveNoteTextConflict(noteID: UUID) -> Bool {
        conflictStore.hasActiveConflict(entityType: .note, entityID: noteID, field: .noteTitle)
            || conflictStore.hasActiveConflict(entityType: .note, entityID: noteID, field: .noteContent)
    }

    // Sync text is intentionally local-first. An incoming device event may create
    // text for a brand-new entity, but it must not replace, remove, or delete
    // existing editable text. When incoming note titles, note body text, folder
    // titles, or pinned text diverge from local state, keep the user's current
    // text untouched and save the remote version for non-blocking review.
    private func applyOrPreserveNoteText(note: Note, payload: MyRAMNoteSyncPayload, originDeviceID: String) {
        if note.title != payload.title {
            switch gatedRemoteTextResolution(
                entityType: .note,
                entityID: note.id,
                field: .noteTitle,
                localText: note.title,
                localData: nil,
                remoteBaseText: payload.baseTitle,
                remoteBaseData: nil,
                remoteText: payload.title,
                remoteData: nil,
                originDeviceID: originDeviceID
            ) {
            case .apply(let text):
                note.title = text
                saveNoteTitleBaseline(note: note, payload: payload, originDeviceID: originDeviceID)
            case .deferIncoming:
                break
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
            saveNoteTitleBaseline(note: note, payload: payload, originDeviceID: originDeviceID)
        }

        if note.content != payload.content || note.richTextContentData != payload.richTextContentData {
            switch gatedRemoteTextResolution(
                entityType: .note,
                entityID: note.id,
                field: .noteContent,
                localText: note.content,
                localData: note.richTextContentData,
                remoteBaseText: payload.baseContent,
                remoteBaseData: payload.baseRichTextContentData,
                remoteText: payload.content,
                remoteData: payload.richTextContentData,
                originDeviceID: originDeviceID
            ) {
            case .apply(let text):
                note.content = text
                note.richTextContentData = text == payload.content ? payload.richTextContentData : note.richTextContentData
                saveNoteContentBaseline(note: note, payload: payload, originDeviceID: originDeviceID)
            case .deferIncoming:
                break
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
            saveNoteContentBaseline(note: note, payload: payload, originDeviceID: originDeviceID)
        }
    }

    private func noteTitleResolution(
        note: Note,
        payload: MyRAMNoteSyncPayload,
        originDeviceID: String
    ) -> RemoteTextResolution {
        gatedRemoteTextResolution(
            entityType: .note,
            entityID: note.id,
            field: .noteTitle,
            localText: note.title,
            localData: nil,
            remoteBaseText: payload.baseTitle,
            remoteBaseData: nil,
            remoteText: payload.title,
            remoteData: nil,
            originDeviceID: originDeviceID
        )
    }

    private func noteContentResolution(
        note: Note,
        payload: MyRAMNoteSyncPayload,
        originDeviceID: String
    ) -> RemoteTextResolution {
        gatedRemoteTextResolution(
            entityType: .note,
            entityID: note.id,
            field: .noteContent,
            localText: note.content,
            localData: note.richTextContentData,
            remoteBaseText: payload.baseContent,
            remoteBaseData: payload.baseRichTextContentData,
            remoteText: payload.content,
            remoteData: payload.richTextContentData,
            originDeviceID: originDeviceID
        )
    }

    private func gatedRemoteTextResolution(
        entityType: SyncConflictEntityType,
        entityID: UUID,
        field: SyncConflictField,
        localText: String,
        localData: Data?,
        remoteBaseText: String? = nil,
        remoteBaseData: Data? = nil,
        remoteText: String,
        remoteData: Data?,
        originDeviceID: String
    ) -> RemoteTextResolution {
        if conflictStore.hasActiveConflict(entityType: entityType, entityID: entityID, field: field) {
            return .conflict
        }

        if isTextApplicationUnsafe(entityType, entityID, field),
           isSameBaselineRemoteText(
            entityType: entityType,
            entityID: entityID,
            field: field,
            remoteBaseText: remoteBaseText,
            remoteBaseData: remoteBaseData,
            originDeviceID: originDeviceID
           ) {
            return hasLocalTextDivergedFromRemoteBase(
                entityType: entityType,
                entityID: entityID,
                field: field,
                localText: localText,
                localData: localData,
                remoteBaseText: remoteBaseText,
                remoteBaseData: remoteBaseData,
                originDeviceID: originDeviceID
            ) ? .conflict : .deferIncoming
        }

        let resolution = remoteTextResolution(
            entityType: entityType,
            entityID: entityID,
            field: field,
            localText: localText,
            localData: localData,
            remoteBaseText: remoteBaseText,
            remoteBaseData: remoteBaseData,
            remoteText: remoteText,
            remoteData: remoteData,
            originDeviceID: originDeviceID
        )
        if case .apply(let text) = resolution,
           text != localText,
           isTextApplicationUnsafe(entityType, entityID, field) {
            return .conflict
        }
        return resolution
    }

    private func isSameBaselineRemoteText(
        entityType: SyncConflictEntityType,
        entityID: UUID,
        field: SyncConflictField,
        remoteBaseText: String?,
        remoteBaseData: Data?,
        originDeviceID: String
    ) -> Bool {
        selectedBaseline(
            entityType: entityType,
            entityID: entityID,
            field: field,
            remoteBaseText: remoteBaseText,
            remoteBaseData: remoteBaseData,
            originDeviceID: originDeviceID
        ).matchesIncomingBase
    }

    private func hasLocalTextDivergedFromRemoteBase(
        entityType: SyncConflictEntityType,
        entityID: UUID,
        field: SyncConflictField,
        localText: String,
        localData: Data?,
        remoteBaseText: String?,
        remoteBaseData: Data?,
        originDeviceID: String
    ) -> Bool {
        selectedBaseline(
            entityType: entityType,
            entityID: entityID,
            field: field,
            remoteBaseText: remoteBaseText,
            remoteBaseData: remoteBaseData,
            originDeviceID: originDeviceID
        ).localHasDiverged(text: localText, data: localData)
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
        remoteData: Data?,
        originDeviceID: String
    ) -> RemoteTextResolution {
        let baseline = selectedBaseline(
            entityType: entityType,
            entityID: entityID,
            field: field,
            remoteBaseText: remoteBaseText,
            remoteBaseData: remoteBaseData,
            originDeviceID: originDeviceID
        )

        if localData != baseline.data || remoteData != baseline.data {
            if localText == baseline.text {
                return .apply(remoteText)
            }
            return .conflict
        }

        switch SyncThreeWayTextMergePolicy.merge(base: baseline.text, local: localText, remote: remoteText) {
        case .apply(let text), .merged(let text):
            return .apply(text)
        case .noOp:
            return .apply(localText)
        case .conflict:
            return .conflict
        }
    }

    private func selectedBaseline(
        entityType: SyncConflictEntityType,
        entityID: UUID,
        field: SyncConflictField,
        remoteBaseText: String?,
        remoteBaseData: Data?,
        originDeviceID: String
    ) -> SyncTextSelectedBaseline {
        SyncTextBaselineSelector.select(
            trackedBaseline: conflictStore.remoteBaseline(
                entityType: entityType,
                entityID: entityID,
                field: field
            )?.syncTextBaseline,
            incomingBaseText: remoteBaseText,
            incomingBaseData: remoteBaseData,
            incomingOriginDeviceID: originDeviceID
        )
    }

    private func canApplyRemoteText(
        entityType: SyncConflictEntityType,
        entityID: UUID,
        field: SyncConflictField,
        localText: String,
        localData: Data?,
        remoteBaseText: String? = nil,
        remoteBaseData: Data? = nil,
        originDeviceID: String
    ) -> Bool {
        let baseline = conflictStore.remoteBaseline(entityType: entityType, entityID: entityID, field: field)
        return remoteTextResolution(
            entityType: entityType,
            entityID: entityID,
            field: field,
            localText: localText,
            localData: localData,
            remoteBaseText: remoteBaseText,
            remoteBaseData: remoteBaseData,
            remoteText: baseline?.text ?? remoteBaseText ?? localText,
            remoteData: baseline?.richTextContentData ?? remoteBaseData,
            originDeviceID: originDeviceID
        ) != .conflict
    }

    private func saveNoteTitleBaseline(note: Note, payload: MyRAMNoteSyncPayload, originDeviceID: String) {
        conflictStore.saveNoteTitleBaseline(
            noteID: note.id,
            title: payload.title,
            modifiedAt: payload.modifiedAt,
            originDeviceID: originDeviceID
        )
    }

    private func saveNoteContentBaseline(note: Note, payload: MyRAMNoteSyncPayload, originDeviceID: String) {
        conflictStore.saveNoteContentBaseline(
            noteID: note.id,
            content: payload.content,
            richTextContentData: payload.richTextContentData,
            modifiedAt: payload.modifiedAt,
            originDeviceID: originDeviceID
        )
    }

    private func savePinnedTextBaseline(
        thoughtID: UUID,
        payload: MyRAMPinnedThoughtSyncPayload,
        originDeviceID: String
    ) {
        conflictStore.savePinnedTextBaseline(
            thoughtID: thoughtID,
            text: payload.text,
            modifiedAt: payload.modifiedAt,
            originDeviceID: originDeviceID
        )
    }

    private func applyIncomingConflictChange(_ change: SyncChange) -> Bool {
        guard let payload = try? MyRAMSyncPayloadCoding.decodeSyncConflict(from: change.payload) else { return false }
        switch payload.action {
        case .preserved:
            guard let conflict = payload.conflict else { return false }
            syncConflicts = conflictStore.preserve(normalizedIncomingConflict(conflict))
            return true
        case .resolved:
            // Resolved metadata carries the winning text. Apply that winner
            // before clearing the local review row so peers converge.
            if let conflict = payload.conflict,
               let resolvedText = payload.resolvedText,
               !applyResolvedConflictText(conflict, resolvedText: resolvedText, baseText: payload.baseText) {
                return false
            }
            if let conflict = payload.conflict {
                syncConflicts = conflictStore.removeResolvedConflict(conflict)
            } else {
                syncConflicts = conflictStore.removeConflict(id: payload.conflictID)
            }
            return true
        }
    }

    private func applyResolvedConflictText(
        _ conflict: SyncConflictVersion,
        resolvedText: String,
        baseText: String?
    ) -> Bool {
        guard let localText = currentText(for: conflict) else {
            return true
        }

        switch SyncThreeWayTextMergePolicy.merge(base: baseText, local: localText, remote: resolvedText) {
        case .apply(let text), .merged(let text):
            applyResolvedText(text, conflict: conflict)
            return true
        case .noOp:
            saveResolvedTextBaseline(resolvedText, conflict: conflict)
            return true
        case .conflict:
            applyResolvedText(resolvedText, conflict: conflict)
            return true
        }
    }

    private func applyResolvedText(_ text: String, conflict: SyncConflictVersion) {
        switch conflict.field {
        case .noteTitle:
            guard let note = fetchNote(withID: conflict.entityID) else { return }
            note.title = text
            note.modifiedAt = Date()
            saveResolvedTextBaseline(text, conflict: conflict)

        case .noteContent:
            guard let note = fetchNote(withID: conflict.entityID) else { return }
            let previousContent = note.content
            note.content = text
            if text == conflict.remoteText {
                note.richTextContentData = RichTextContentCodec.sanitizedConflictRichTextData(
                    conflict.remoteRichTextContentData,
                    plainText: conflict.remoteText
                )
            } else if previousContent != text {
                note.richTextContentData = nil
            }
            note.modifiedAt = Date()
            saveResolvedTextBaseline(text, conflict: conflict)

        case .folderTitle:
            guard let folder = fetchFolder(withID: conflict.entityID) else { return }
            folder.name = text
            folder.modifiedAt = Date()

        case .pinnedText:
            guard let thought = fetchPinnedThought(withID: conflict.entityID) else { return }
            thought.text = text
            thought.modifiedAt = Date()
            thought.note?.modifiedAt = thought.modifiedAt
            saveResolvedTextBaseline(text, conflict: conflict)
        }
    }

    private func saveResolvedTextBaseline(_ text: String, conflict: SyncConflictVersion) {
        // Resolved metadata is terminal for this text value. Even when the
        // visible text already matches, the baseline must advance or the next
        // ordinary edit will compare against the stale pre-conflict version.
        switch conflict.field {
        case .noteTitle:
            guard let note = fetchNote(withID: conflict.entityID) else { return }
            conflictStore.saveNoteTitleBaseline(
                noteID: note.id,
                title: text,
                modifiedAt: note.modifiedAt,
                originDeviceID: nil
            )

        case .noteContent:
            guard let note = fetchNote(withID: conflict.entityID) else { return }
            conflictStore.saveNoteContentBaseline(
                noteID: note.id,
                content: text,
                richTextContentData: note.richTextContentData,
                modifiedAt: note.modifiedAt,
                originDeviceID: nil
            )

        case .folderTitle:
            break

        case .pinnedText:
            guard let thought = fetchPinnedThought(withID: conflict.entityID) else { return }
            conflictStore.savePinnedTextBaseline(
                thoughtID: thought.id,
                text: text,
                modifiedAt: thought.modifiedAt,
                originDeviceID: nil
            )
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
        payload: MyRAMPinnedThoughtSyncPayload,
        originDeviceID: String
    ) -> Bool {
        guard thought.text != payload.text else { return false }
        switch gatedRemoteTextResolution(
            entityType: .pinnedThought,
            entityID: thought.id,
            field: .pinnedText,
            localText: thought.text,
            localData: nil,
            remoteBaseText: payload.baseText,
            remoteBaseData: nil,
            remoteText: payload.text,
            remoteData: nil,
            originDeviceID: originDeviceID
        ) {
        case .apply(let text):
            thought.text = text
            savePinnedTextBaseline(thoughtID: thought.id, payload: payload, originDeviceID: originDeviceID)
            return false
        case .deferIncoming:
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

    private func shouldFreezeIncomingPinnedThoughtPayload(
        thought: PinnedThought,
        payload: MyRAMPinnedThoughtSyncPayload,
        originDeviceID: String
    ) -> Bool {
        if conflictStore.hasActiveConflict(entityType: .pinnedThought, entityID: thought.id, field: .pinnedText) {
            return true
        }
        guard thought.text != payload.text else { return false }
        return pinnedTextResolution(
            thought: thought,
            payload: payload,
            originDeviceID: originDeviceID
        ).freezesOrdinaryPayload
    }

    private func preserveIncomingPinnedTextConflictIfNeeded(
        thought: PinnedThought,
        payload: MyRAMPinnedThoughtSyncPayload,
        originDeviceID: String
    ) {
        guard thought.text != payload.text,
              pinnedTextResolution(
                thought: thought,
                payload: payload,
                originDeviceID: originDeviceID
              ) == .conflict else { return }
        preserveSyncConflict(
            entityType: .pinnedThought,
            entityID: thought.id,
            noteID: thought.note?.id ?? payload.noteID,
            field: .pinnedText,
            localText: thought.text,
            remoteText: payload.text,
            remoteModifiedAt: payload.modifiedAt
        )
    }

    private func pinnedTextResolution(
        thought: PinnedThought,
        payload: MyRAMPinnedThoughtSyncPayload,
        originDeviceID: String
    ) -> RemoteTextResolution {
        gatedRemoteTextResolution(
            entityType: .pinnedThought,
            entityID: thought.id,
            field: .pinnedText,
            localText: thought.text,
            localData: nil,
            remoteBaseText: payload.baseText,
            remoteBaseData: nil,
            remoteText: payload.text,
            remoteData: nil,
            originDeviceID: originDeviceID
        )
    }

    private func preserveNoteDeleteConflictsIfNeeded(
        note: Note,
        payload: MyRAMNoteSyncPayload,
        originDeviceID: String
    ) -> Bool {
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
                remoteBaseData: nil,
                originDeviceID: originDeviceID
            )
        let bodyDiverged = (note.content != payload.content || note.richTextContentData != payload.richTextContentData)
            && !canApplyRemoteText(
                entityType: .note,
                entityID: note.id,
                field: .noteContent,
                localText: note.content,
                localData: note.richTextContentData,
                remoteBaseText: payload.baseContent,
                remoteBaseData: payload.baseRichTextContentData,
                originDeviceID: originDeviceID
            )
        guard titleDiverged || bodyDiverged else { return false }
        applyOrPreserveNoteText(note: note, payload: payload, originDeviceID: originDeviceID)
        return true
    }

    private func preserveFolderDeleteConflictIfNeeded(folder: Folder, payload: MyRAMFolderSyncPayload) -> Bool {
        preserveFolderTitleConflictIfNeeded(folder: folder, payload: payload)
    }

    private func preservePinnedThoughtDeleteConflictIfNeeded(
        thought: PinnedThought,
        payload: MyRAMPinnedThoughtSyncPayload,
        originDeviceID: String
    ) -> Bool {
        preservePinnedTextConflictIfNeeded(
            thought: thought,
            payload: payload,
            originDeviceID: originDeviceID
        )
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
        let conflictsBeforePreserve = syncConflicts
        syncConflicts = conflictStore.preserve(conflict)
        if syncConflicts != conflictsBeforePreserve {
            newlyPreservedConflicts.append(conflict)
        }
    }

    private func normalizedIncomingConflict(_ conflict: SyncConflictVersion) -> SyncConflictVersion {
        guard let currentLocalText = currentText(for: conflict) else {
            return conflict
        }
        let normalizedConflict = SyncTextConflictVersion(
            id: conflict.id,
            entityType: conflict.entityType.syncEntityType,
            entityID: conflict.entityID.uuidString,
            fieldID: conflict.field.rawValue,
            contextID: conflict.noteID?.uuidString,
            localText: conflict.localText,
            remoteText: conflict.remoteText,
            remoteData: conflict.remoteRichTextContentData,
            remoteUpdatedAt: conflict.remoteModifiedAt,
            preservedAt: conflict.preservedAt,
            expiresAt: conflict.expiresAt
        ).normalizedForPeerPreservedConflict(currentLocalText: currentLocalText)

        return SyncConflictVersion(
            id: normalizedConflict.id,
            entityType: conflict.entityType,
            entityID: conflict.entityID,
            noteID: conflict.noteID,
            field: conflict.field,
            localText: normalizedConflict.localText,
            remoteText: normalizedConflict.remoteText,
            remoteRichTextContentData: normalizedConflict.remoteData,
            remoteModifiedAt: normalizedConflict.remoteUpdatedAt,
            preservedAt: normalizedConflict.preservedAt,
            expiresAt: normalizedConflict.expiresAt
        )
    }

    private func currentText(for conflict: SyncConflictVersion) -> String? {
        switch conflict.field {
        case .noteTitle:
            return fetchNote(withID: conflict.entityID)?.title
        case .noteContent:
            return fetchNote(withID: conflict.entityID)?.content
        case .folderTitle:
            return fetchFolder(withID: conflict.entityID)?.name
        case .pinnedText:
            return fetchPinnedThought(withID: conflict.entityID)?.text
        }
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

private extension SyncChange {
    var isResolvedConflictMetadata: Bool {
        guard entityType == .conflict,
              let payload = try? MyRAMSyncPayloadCoding.decodeSyncConflict(from: payload) else {
            return false
        }
        return payload.action == .resolved
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
    case deferIncoming
    case conflict

    var freezesOrdinaryPayload: Bool {
        switch self {
        case .apply:
            false
        case .deferIncoming, .conflict:
            true
        }
    }
}
