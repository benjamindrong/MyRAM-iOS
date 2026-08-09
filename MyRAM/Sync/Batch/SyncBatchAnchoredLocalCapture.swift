import AnchoredSequenceCore
import Foundation

struct SyncBatchAnchoredLocalCaptureResult: Equatable, Sendable {
    let capturedChanges: [SyncConvergenceCapturedLocalChange]
    let finalState: SyncTextSequenceState
}

enum SyncBatchAnchoredLocalCaptureError: Error, Equatable {
    case initialBodyMismatch
    case unsupportedEditOperation
    case finalBodyMismatch
}

/// Converts the existing sequential local edit script into anchored operations while
/// advancing the authoritative structural candidate after every primitive operation.
enum SyncBatchAnchoredLocalCapture {
    static func capture(
        noteID: UUID,
        oldBody: String,
        newBody: String,
        modifiedAt: Date,
        initialState: SyncTextSequenceState,
        operationIDReserver: any SyncOperationIDReserving
    ) async throws -> SyncBatchAnchoredLocalCaptureResult {
        guard initialState.visibleText == oldBody else {
            throw SyncBatchAnchoredLocalCaptureError.initialBodyMismatch
        }
        let script = try SyncBatchNoteChangeCapture.bodyTextChanges(
            noteID: noteID,
            oldBody: oldBody,
            newBody: newBody,
            modifiedAt: modifiedAt,
            bodyHashCapabilityEnabled: true
        )
        var candidate = initialState
        var captured: [SyncConvergenceCapturedLocalChange] = []
        for operation in script {
            let operationID = try await operationIDReserver.reserveOperationID()
            let anchored: SyncBatchChange
            let next: SyncTextSequenceState
            switch operation {
            case .noteBodyTextInserted(let inserted):
                anchored = try SyncBatchAnchoredPayloadAdapter.makeInsertedChange(
                    noteID: noteID,
                    utf16Offset: inserted.utf16Offset,
                    text: inserted.text,
                    modifiedAt: inserted.modifiedAt,
                    baseContentHash: inserted.baseContentHash,
                    operationID: operationID,
                    state: candidate
                )
                guard case .noteBodyTextInsertedAnchored(let value) = anchored else {
                    throw SyncBatchAnchoredLocalCaptureError.unsupportedEditOperation
                }
                next = try SyncBatchAnchoredInsertReplay.applying(value, to: candidate).sequenceState
            case .noteBodyTextDeleted(let deleted):
                anchored = try SyncBatchAnchoredPayloadAdapter.makeDeletedChange(
                    noteID: noteID,
                    utf16Offset: deleted.utf16Offset,
                    utf16Length: deleted.utf16Length,
                    expectedText: deleted.expectedText,
                    modifiedAt: deleted.modifiedAt,
                    baseContentHash: deleted.baseContentHash,
                    operationID: operationID,
                    state: candidate
                )
                guard case .noteBodyTextDeletedAnchored(let value) = anchored else {
                    throw SyncBatchAnchoredLocalCaptureError.unsupportedEditOperation
                }
                next = try SyncBatchAnchoredDeleteReplay.applying(value, to: candidate).sequenceState
            default:
                throw SyncBatchAnchoredLocalCaptureError.unsupportedEditOperation
            }
            captured.append(try SyncConvergenceLocalEvidenceCapture.capturedAnchoredChange(
                for: anchored,
                structuralPreState: candidate,
                structuralPostState: next
            ))
            candidate = next
        }
        guard candidate.visibleText == newBody else {
            throw SyncBatchAnchoredLocalCaptureError.finalBodyMismatch
        }
        return SyncBatchAnchoredLocalCaptureResult(capturedChanges: captured, finalState: candidate)
    }
}
