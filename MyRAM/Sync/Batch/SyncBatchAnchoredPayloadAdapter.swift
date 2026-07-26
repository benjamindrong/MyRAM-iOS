import AnchoredSequenceCore
import Foundation

struct SyncBatchNoteBodyTextInsertedAnchoredChange:
    Codable,
    Equatable,
    Sendable
{
    let noteID: UUID
    let utf16Offset: Int
    let text: String
    let modifiedAt: Date
    let baseContentHash: String?
    let payload: SyncTextInsertOperationPayload

    fileprivate init(
        noteID: UUID,
        utf16Offset: Int,
        text: String,
        modifiedAt: Date,
        baseContentHash: String?,
        payload: SyncTextInsertOperationPayload
    ) {
        self.noteID = noteID
        self.utf16Offset = utf16Offset
        self.text = text
        self.modifiedAt = modifiedAt
        self.baseContentHash = baseContentHash
        self.payload = payload
    }
}

struct SyncBatchNoteBodyTextDeletedAnchoredChange:
    Codable,
    Equatable,
    Sendable
{
    let noteID: UUID
    let utf16Offset: Int
    let utf16Length: Int
    let expectedText: String?
    let modifiedAt: Date
    let baseContentHash: String?
    let payload: SyncTextDeleteOperationPayload

    fileprivate init(
        noteID: UUID,
        utf16Offset: Int,
        utf16Length: Int,
        expectedText: String?,
        modifiedAt: Date,
        baseContentHash: String?,
        payload: SyncTextDeleteOperationPayload
    ) {
        self.noteID = noteID
        self.utf16Offset = utf16Offset
        self.utf16Length = utf16Length
        self.expectedText = expectedText
        self.modifiedAt = modifiedAt
        self.baseContentHash = baseContentHash
        self.payload = payload
    }
}

enum SyncBatchAnchoredPayloadAdapterError: Error, Equatable, Sendable {
    case emptyInsertedText
    case mismatchedBaseContentHash(expected: String, actual: String)
    case expectedTextUTF16LengthMismatch(declared: Int, actual: Int)
    case expectedTextMismatch(noteID: UUID)
}

/// Translates validated structural identity into MyRAM-owned batch values
/// without reserving identity, mutating sequence state, or admitting a batch.
enum SyncBatchAnchoredPayloadAdapter {
    static func makeInsertedChange(
        noteID: UUID,
        utf16Offset: Int,
        text: String,
        modifiedAt: Date,
        baseContentHash: String?,
        operationID: SyncOperationID,
        state: SyncTextSequenceState
    ) throws -> SyncBatchChange {
        guard !text.isEmpty else {
            throw SyncBatchAnchoredPayloadAdapterError.emptyInsertedText
        }
        try validateBaseContentHash(baseContentHash, visibleText: state.visibleText)
        let payload = try state.insertOperationPayload(
            operationID: operationID,
            atVisibleUTF16Offset: utf16Offset
        )
        return .noteBodyTextInsertedAnchored(
            SyncBatchNoteBodyTextInsertedAnchoredChange(
                noteID: noteID,
                utf16Offset: utf16Offset,
                text: text,
                modifiedAt: modifiedAt,
                baseContentHash: baseContentHash,
                payload: payload
            )
        )
    }

    static func makeDeletedChange(
        noteID: UUID,
        utf16Offset: Int,
        utf16Length: Int,
        expectedText: String?,
        modifiedAt: Date,
        baseContentHash: String?,
        operationID: SyncOperationID,
        state: SyncTextSequenceState
    ) throws -> SyncBatchChange {
        let range = try checkedRange(offset: utf16Offset, length: utf16Length)
        let payload = try state.deleteOperationPayload(
            operationID: operationID,
            inVisibleUTF16Range: range
        )
        try validateBaseContentHash(baseContentHash, visibleText: state.visibleText)

        if let expectedText {
            guard expectedText.utf16.count == utf16Length else {
                throw SyncBatchAnchoredPayloadAdapterError.expectedTextUTF16LengthMismatch(
                    declared: utf16Length,
                    actual: expectedText.utf16.count
                )
            }
            let authoritativeText = (state.visibleText as NSString).substring(
                with: NSRange(location: utf16Offset, length: utf16Length)
            )
            guard expectedText == authoritativeText else {
                throw SyncBatchAnchoredPayloadAdapterError.expectedTextMismatch(noteID: noteID)
            }
        }

        return .noteBodyTextDeletedAnchored(
            SyncBatchNoteBodyTextDeletedAnchoredChange(
                noteID: noteID,
                utf16Offset: utf16Offset,
                utf16Length: utf16Length,
                expectedText: expectedText,
                modifiedAt: modifiedAt,
                baseContentHash: baseContentHash,
                payload: payload
            )
        )
    }

    private static func checkedRange(offset: Int, length: Int) throws -> Range<Int> {
        guard offset >= 0 else {
            throw SyncTextSequenceStateError.negativeRangeOffset(offset)
        }
        guard length > 0 else {
            throw SyncTextSequenceStateError.nonpositiveRangeLength(length)
        }
        let (end, overflow) = offset.addingReportingOverflow(length)
        guard !overflow else {
            throw SyncTextSequenceStateError.rangeOverflow(
                startOffset: offset,
                utf16Length: length
            )
        }
        return offset..<end
    }

    private static func validateBaseContentHash(
        _ declaredHash: String?,
        visibleText: String
    ) throws {
        guard let declaredHash else { return }
        let actualHash = SyncBatchContentHash.sha256Hex(for: visibleText)
        guard declaredHash == actualHash else {
            throw SyncBatchAnchoredPayloadAdapterError.mismatchedBaseContentHash(
                expected: declaredHash,
                actual: actualHash
            )
        }
    }
}
