import Foundation

enum SyncBatchNoteChangeCapture {
    static func noteCreated(
        noteID: UUID,
        title: String,
        body: String,
        folderID: UUID?,
        createdAt: Date,
        modifiedAt: Date
    ) -> SyncBatchChange {
        .noteCreated(
            SyncBatchNoteCreatedChange(
                noteID: noteID,
                title: title,
                body: body,
                folderID: folderID,
                createdAt: createdAt,
                modifiedAt: modifiedAt
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
            return .noteBodyTextInserted(
                SyncBatchNoteBodyTextInsertedChange(
                    noteID: noteID,
                    utf16Offset: prefixLength,
                    text: (newBody as NSString).substring(with: range),
                    modifiedAt: modifiedAt
                )
            )
        }

        if insertedLength == 0, deletedLength > 0,
           let range = oldBody.syncBatchSafeUTF16Range(location: prefixLength, length: deletedLength) {
            return .noteBodyTextDeleted(
                SyncBatchNoteBodyTextDeletedChange(
                    noteID: noteID,
                    utf16Offset: prefixLength,
                    utf16Length: deletedLength,
                    expectedText: (oldBody as NSString).substring(with: range),
                    modifiedAt: modifiedAt
                )
            )
        }

        // Replacement or multi-region edits have no MYR-122 operation. Skipping
        // avoids manufacturing a positional range with destructive semantics.
        return nil
    }
}
