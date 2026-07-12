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

    static func bodyTextChanges(
        noteID: UUID,
        oldBody: String,
        newBody: String,
        modifiedAt: Date,
        bodyHashCapabilityEnabled: Bool = SyncBatchBodyHashCapability.defaultEnabled
    ) throws -> [SyncBatchChange] {
        try SyncBatchBodyEditScript.changes(
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
        guard let changes = try? bodyTextChanges(
            noteID: noteID,
            oldBody: oldBody,
            newBody: newBody,
            modifiedAt: modifiedAt,
            bodyHashCapabilityEnabled: bodyHashCapabilityEnabled
        ) else {
            return nil
        }
        return changes.count == 1 ? changes[0] : nil
    }
}

enum SyncBatchBodyEditScript {
    enum CaptureError: Error, Equatable {
        case invalidUTF16Boundary
        case emptyChangedBodyScript
        case editScriptTooLarge
        case replayMismatch
    }

    private static let maxDiffCells = 250_000

    static func changes(
        noteID: UUID,
        oldBody: String,
        newBody: String,
        modifiedAt: Date,
        bodyHashCapabilityEnabled: Bool
    ) throws -> [SyncBatchChange] {
        guard oldBody != newBody else { return [] }

        let oldCharacters = Array(oldBody)
        let newCharacters = Array(newBody)
        var prefixCount = 0
        while prefixCount < oldCharacters.count,
              prefixCount < newCharacters.count,
              oldCharacters[prefixCount] == newCharacters[prefixCount] {
            prefixCount += 1
        }

        var oldSuffixStart = oldCharacters.count
        var newSuffixStart = newCharacters.count
        while oldSuffixStart > prefixCount,
              newSuffixStart > prefixCount,
              oldCharacters[oldSuffixStart - 1] == newCharacters[newSuffixStart - 1] {
            oldSuffixStart -= 1
            newSuffixStart -= 1
        }

        let oldMiddle = Array(oldCharacters[prefixCount..<oldSuffixStart])
        let newMiddle = Array(newCharacters[prefixCount..<newSuffixStart])
        let utf16Offset = utf16Length(of: oldCharacters[..<prefixCount])

        let changes: [SyncBatchChange]
        if oldMiddle.isEmpty {
            changes = [
                makeInsert(
                    noteID: noteID,
                    offset: utf16Offset,
                    text: String(newMiddle),
                    modifiedAt: modifiedAt,
                    baseBody: oldBody,
                    bodyHashCapabilityEnabled: bodyHashCapabilityEnabled
                )
            ]
        } else if newMiddle.isEmpty {
            changes = [
                makeDelete(
                    noteID: noteID,
                    offset: utf16Offset,
                    text: String(oldMiddle),
                    modifiedAt: modifiedAt,
                    baseBody: oldBody,
                    bodyHashCapabilityEnabled: bodyHashCapabilityEnabled
                )
            ]
        } else {
            changes = try scriptedChanges(
                noteID: noteID,
                oldBody: oldBody,
                oldMiddle: oldMiddle,
                newMiddle: newMiddle,
                middleOffset: utf16Offset,
                modifiedAt: modifiedAt,
                bodyHashCapabilityEnabled: bodyHashCapabilityEnabled
            )
        }

        guard !changes.isEmpty else {
            throw CaptureError.emptyChangedBodyScript
        }
        let replayedBody = try changes.reduce(oldBody) { body, change in
            try SyncConvergenceLocalEvidenceCapture.apply(change, to: body)
        }
        guard replayedBody == newBody else {
            throw CaptureError.replayMismatch
        }
        return changes
    }

    private static func scriptedChanges(
        noteID: UUID,
        oldBody: String,
        oldMiddle: [Character],
        newMiddle: [Character],
        middleOffset: Int,
        modifiedAt: Date,
        bodyHashCapabilityEnabled: Bool
    ) throws -> [SyncBatchChange] {
        let matches = try lcsMatches(oldMiddle, newMiddle)
        var oldCursor = 0
        var newCursor = 0
        var currentOffset = middleOffset
        var currentBody = oldBody
        var changes: [SyncBatchChange] = []

        for match in matches + [(oldMiddle.count, newMiddle.count)] {
            let oldGap = Array(oldMiddle[oldCursor..<match.oldIndex])
            let newGap = Array(newMiddle[newCursor..<match.newIndex])
            if !oldGap.isEmpty {
                let deletedText = String(oldGap)
                let change = makeDelete(
                    noteID: noteID,
                    offset: currentOffset,
                    text: deletedText,
                    modifiedAt: modifiedAt,
                    baseBody: currentBody,
                    bodyHashCapabilityEnabled: bodyHashCapabilityEnabled
                )
                currentBody = try SyncConvergenceLocalEvidenceCapture.apply(change, to: currentBody)
                changes.append(change)
            }
            if !newGap.isEmpty {
                let insertedText = String(newGap)
                let change = makeInsert(
                    noteID: noteID,
                    offset: currentOffset,
                    text: insertedText,
                    modifiedAt: modifiedAt,
                    baseBody: currentBody,
                    bodyHashCapabilityEnabled: bodyHashCapabilityEnabled
                )
                currentBody = try SyncConvergenceLocalEvidenceCapture.apply(change, to: currentBody)
                currentOffset += insertedText.utf16.count
                changes.append(change)
            }
            if match.oldIndex < oldMiddle.count {
                currentOffset += String(oldMiddle[match.oldIndex]).utf16.count
                oldCursor = match.oldIndex + 1
                newCursor = match.newIndex + 1
            }
        }

        return changes
    }

    private static func lcsMatches(
        _ oldCharacters: [Character],
        _ newCharacters: [Character]
    ) throws -> [(oldIndex: Int, newIndex: Int)] {
        guard oldCharacters.count * newCharacters.count <= maxDiffCells else {
            throw CaptureError.editScriptTooLarge
        }
        var table = Array(
            repeating: Array(repeating: 0, count: newCharacters.count + 1),
            count: oldCharacters.count + 1
        )
        if !oldCharacters.isEmpty, !newCharacters.isEmpty {
            for oldIndex in stride(from: oldCharacters.count - 1, through: 0, by: -1) {
                for newIndex in stride(from: newCharacters.count - 1, through: 0, by: -1) {
                    if oldCharacters[oldIndex] == newCharacters[newIndex] {
                        table[oldIndex][newIndex] = table[oldIndex + 1][newIndex + 1] + 1
                    } else {
                        table[oldIndex][newIndex] = max(table[oldIndex + 1][newIndex], table[oldIndex][newIndex + 1])
                    }
                }
            }
        }

        var oldIndex = 0
        var newIndex = 0
        var matches: [(oldIndex: Int, newIndex: Int)] = []
        while oldIndex < oldCharacters.count, newIndex < newCharacters.count {
            if oldCharacters[oldIndex] == newCharacters[newIndex] {
                matches.append((oldIndex, newIndex))
                oldIndex += 1
                newIndex += 1
            } else if table[oldIndex + 1][newIndex] >= table[oldIndex][newIndex + 1] {
                oldIndex += 1
            } else {
                newIndex += 1
            }
        }
        return matches
    }

    private static func makeInsert(
        noteID: UUID,
        offset: Int,
        text: String,
        modifiedAt: Date,
        baseBody: String,
        bodyHashCapabilityEnabled: Bool
    ) -> SyncBatchChange {
        .noteBodyTextInserted(
            SyncBatchNoteBodyTextInsertedChange(
                noteID: noteID,
                utf16Offset: offset,
                text: text,
                modifiedAt: modifiedAt,
                baseContentHash: bodyHashCapabilityEnabled ? SyncBatchContentHash.sha256Hex(for: baseBody) : nil
            )
        )
    }

    private static func makeDelete(
        noteID: UUID,
        offset: Int,
        text: String,
        modifiedAt: Date,
        baseBody: String,
        bodyHashCapabilityEnabled: Bool
    ) -> SyncBatchChange {
        .noteBodyTextDeleted(
            SyncBatchNoteBodyTextDeletedChange(
                noteID: noteID,
                utf16Offset: offset,
                utf16Length: text.utf16.count,
                expectedText: text,
                modifiedAt: modifiedAt,
                baseContentHash: bodyHashCapabilityEnabled ? SyncBatchContentHash.sha256Hex(for: baseBody) : nil
            )
        )
    }

    private static func utf16Length<C: Collection>(of characters: C) -> Int where C.Element == Character {
        characters.reduce(0) { partial, character in
            partial + String(character).utf16.count
        }
    }
}
