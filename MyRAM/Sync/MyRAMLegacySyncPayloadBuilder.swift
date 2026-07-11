import Foundation
import NearbySyncCore

enum MyRAMLegacySyncPayloadBuilder {
    static func notePayload(note: Note, conflictStore: SyncConflictStore) -> MyRAMNoteSyncPayload {
        let titleBaseline = conflictStore.remoteBaseline(entityType: .note, entityID: note.id, field: .noteTitle)
        let contentBaseline = conflictStore.remoteBaseline(entityType: .note, entityID: note.id, field: .noteContent)
        return MyRAMNoteSyncPayload(
            note: note,
            baseTitle: titleBaseline?.text,
            baseContent: contentBaseline?.text,
            baseRichTextContentData: contentBaseline?.richTextContentData
        )
    }

    static func pinnedThoughtPayload(
        thought: PinnedThought,
        conflictStore: SyncConflictStore,
        isDeleted: Bool = false
    ) -> MyRAMPinnedThoughtSyncPayload {
        let baseline = conflictStore.remoteBaseline(entityType: .pinnedThought, entityID: thought.id, field: .pinnedText)
        return MyRAMPinnedThoughtSyncPayload(thought: thought, isDeleted: isDeleted, baseText: baseline?.text)
    }

    static func change(
        note: Note,
        operation: SyncOperation,
        conflictStore: SyncConflictStore,
        updatedAt: Date? = nil,
        originDeviceID: String
    ) throws -> SyncChange {
        try change(
            entityType: .item,
            entityID: note.id,
            operation: operation,
            payload: MyRAMSyncPayloadCoding.encode(notePayload(note: note, conflictStore: conflictStore)),
            updatedAt: updatedAt ?? note.modifiedAt,
            originDeviceID: originDeviceID
        )
    }

    static func change(folder: Folder, updatedAt: Date? = nil, originDeviceID: String) throws -> SyncChange {
        try change(
            entityType: .collection,
            entityID: folder.id,
            payload: MyRAMSyncPayloadCoding.encode(MyRAMFolderSyncPayload(folder: folder)),
            updatedAt: updatedAt ?? folder.modifiedAt,
            originDeviceID: originDeviceID
        )
    }

    static func change(
        thought: PinnedThought,
        conflictStore: SyncConflictStore,
        updatedAt: Date? = nil,
        originDeviceID: String
    ) throws -> SyncChange {
        try change(
            entityType: .marker,
            entityID: thought.id,
            payload: MyRAMSyncPayloadCoding.encode(
                pinnedThoughtPayload(thought: thought, conflictStore: conflictStore)
            ),
            updatedAt: updatedAt ?? thought.modifiedAt,
            originDeviceID: originDeviceID
        )
    }

    static func change(
        attachment: NotePhotoAttachment,
        updatedAt: Date,
        originDeviceID: String
    ) throws -> SyncChange {
        try change(
            entityType: .attachment,
            entityID: attachment.id,
            payload: MyRAMSyncPayloadCoding.encode(MyRAMPhotoAttachmentSyncPayload(attachment: attachment)),
            updatedAt: updatedAt,
            originDeviceID: originDeviceID
        )
    }

    static func change(
        entityType: SyncEntityType,
        entityID: UUID,
        operation: SyncOperation = .upsert,
        payload: Data,
        updatedAt: Date,
        originDeviceID: String
    ) throws -> SyncChange {
        SyncChange(
            entityType: entityType,
            entityID: entityID.uuidString,
            operation: operation,
            payload: payload,
            updatedAt: updatedAt,
            originDeviceID: originDeviceID
        )
    }
}
