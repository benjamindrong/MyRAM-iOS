import Foundation

enum IPhoneSyncBatchCaptureHook {
    static func noteCreated(_ note: Note) -> SyncBatchChange {
        SyncBatchNoteChangeCapture.noteCreated(
            noteID: note.id,
            title: note.title,
            body: note.content,
            folderID: note.folder?.id,
            createdAt: note.createdAt,
            modifiedAt: note.modifiedAt
        )
    }

    static func lifecycleChanged(_ note: Note) -> SyncBatchChange {
        .noteLifecycleChanged(SyncBatchNoteLifecycleChangedChange(
            noteID: note.id,
            deletedAt: note.deletedAt,
            modifiedAt: note.modifiedAt,
            title: note.title,
            body: note.content,
            baseTitleHash: SyncBatchContentHash.sha256Hex(for: note.title),
            baseBodyHash: SyncBatchContentHash.sha256Hex(for: note.content)
        ))
    }

    static func titleChanged(noteID: UUID, oldTitle: String, newTitle: String, modifiedAt: Date) -> SyncBatchChange? {
        SyncBatchNoteChangeCapture.titleChanged(noteID: noteID, oldTitle: oldTitle, newTitle: newTitle, modifiedAt: modifiedAt)
    }

    static func bodyTextChanges(
        noteID: UUID,
        oldBody: String,
        newBody: String,
        modifiedAt: Date,
        bodyHashCapabilityEnabled: Bool = SyncBatchBodyHashCapability.defaultEnabled
    ) throws -> [SyncBatchChange] {
        try SyncBatchNoteChangeCapture.bodyTextChanges(
            noteID: noteID,
            oldBody: oldBody,
            newBody: newBody,
            modifiedAt: modifiedAt,
            bodyHashCapabilityEnabled: bodyHashCapabilityEnabled
        )
    }

    static func bodyTextChanged(
        noteID: UUID,
        oldBody: String,
        newBody: String,
        modifiedAt: Date,
        bodyHashCapabilityEnabled: Bool = SyncBatchBodyHashCapability.defaultEnabled
    ) -> SyncBatchChange? {
        let changes = try? SyncBatchNoteChangeCapture.bodyTextChanges(
            noteID: noteID,
            oldBody: oldBody,
            newBody: newBody,
            modifiedAt: modifiedAt,
            bodyHashCapabilityEnabled: bodyHashCapabilityEnabled
        )
        return changes?.onlyElement
    }
}

private extension Array {
    var onlyElement: Element? {
        count == 1 ? self[0] : nil
    }
}
