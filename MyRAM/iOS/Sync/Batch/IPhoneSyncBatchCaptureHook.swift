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

    static func titleChanged(noteID: UUID, oldTitle: String, newTitle: String, modifiedAt: Date) -> SyncBatchChange? {
        SyncBatchNoteChangeCapture.titleChanged(noteID: noteID, oldTitle: oldTitle, newTitle: newTitle, modifiedAt: modifiedAt)
    }

    static func bodyTextChanged(
        noteID: UUID,
        oldBody: String,
        newBody: String,
        modifiedAt: Date,
        bodyHashCapabilityEnabled: Bool = SyncBatchBodyHashCapability.defaultEnabled
    ) -> SyncBatchChange? {
        SyncBatchNoteChangeCapture.bodyTextChanged(
            noteID: noteID,
            oldBody: oldBody,
            newBody: newBody,
            modifiedAt: modifiedAt,
            bodyHashCapabilityEnabled: bodyHashCapabilityEnabled
        )
    }
}
