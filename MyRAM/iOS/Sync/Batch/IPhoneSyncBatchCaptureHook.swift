import Foundation

enum IPhoneSyncBatchCaptureHook {
    static func noteCreated(_ note: Note) -> SyncBatchChange {
        .noteCreated(
            SyncBatchNoteCreatedChange(
                noteID: note.id,
                title: note.title,
                body: note.content,
                folderID: note.folder?.id,
                createdAt: note.createdAt,
                modifiedAt: note.modifiedAt
            )
        )
    }

    static func titleChanged(noteID: UUID, oldTitle: String, newTitle: String, modifiedAt: Date) -> SyncBatchChange? {
        guard oldTitle != newTitle else { return nil }
        return .noteTitleChanged(
            SyncBatchNoteTitleChangedChange(
                noteID: noteID,
                title: newTitle,
                modifiedAt: modifiedAt
            )
        )
    }

    static func bodyTextChanged(noteID: UUID, oldBody: String, newBody: String, modifiedAt: Date) -> SyncBatchChange? {
        guard oldBody != newBody else { return nil }

        let oldUTF16 = Array(oldBody.utf16)
        let newUTF16 = Array(newBody.utf16)
        var prefixLength = 0
        while prefixLength < oldUTF16.count,
              prefixLength < newUTF16.count,
              oldUTF16[prefixLength] == newUTF16[prefixLength] {
            prefixLength += 1
        }

        var oldSuffixIndex = oldUTF16.count
        var newSuffixIndex = newUTF16.count
        while oldSuffixIndex > prefixLength,
              newSuffixIndex > prefixLength,
              oldUTF16[oldSuffixIndex - 1] == newUTF16[newSuffixIndex - 1] {
            oldSuffixIndex -= 1
            newSuffixIndex -= 1
        }

        let deletedLength = oldSuffixIndex - prefixLength
        let insertedLength = newSuffixIndex - prefixLength

        if deletedLength == 0, insertedLength > 0,
           let range = newBody.syncBatchSafeUTF16Range(location: prefixLength, length: insertedLength) {
            let insertedText = (newBody as NSString).substring(with: range)
            return .noteBodyTextInserted(
                SyncBatchNoteBodyTextInsertedChange(
                    noteID: noteID,
                    utf16Offset: prefixLength,
                    text: insertedText,
                    modifiedAt: modifiedAt
                )
            )
        }

        if insertedLength == 0, deletedLength > 0,
           let range = oldBody.syncBatchSafeUTF16Range(location: prefixLength, length: deletedLength) {
            let deletedText = (oldBody as NSString).substring(with: range)
            return .noteBodyTextDeleted(
                SyncBatchNoteBodyTextDeletedChange(
                    noteID: noteID,
                    utf16Offset: prefixLength,
                    utf16Length: deletedLength,
                    expectedText: deletedText,
                    modifiedAt: modifiedAt
                )
            )
        }

        // Replacement or multi-region edits have no MYR-122 operation. Skipping
        // avoids manufacturing a positional range with destructive semantics.
        return nil
    }
}
