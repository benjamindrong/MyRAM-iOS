import AnchoredSequenceCore
import Foundation

struct SyncConvergenceCapturedLocalChange: Codable, Equatable, Sendable {
    let change: SyncBatchChange
    let evidence: SyncConvergenceCapturedChangeEvidence?
}

struct SyncConvergenceCapturedChangeEvidence: Codable, Equatable, Sendable {
    let noteID: UUID
    let preBodyHash: String
    let postBodyHash: String
    let preBodySnapshot: String?
    let postBodySnapshot: String?
    let insertedText: String?
    let deletedText: String?
}

enum SyncConvergenceLocalObligationEvidence: Codable, Equatable, Sendable {
    case captured([SyncConvergenceCapturedLocalChange])
    case legacyMissing
}

struct SyncConvergenceLocalObligation: Codable, Equatable, Identifiable, Sendable {
    let batch: SyncBatch
    let evidence: SyncConvergenceLocalObligationEvidence

    var id: UUID { batch.id }
    var createdAt: Date { batch.createdAt }
    var batchSequence: UInt64? { batch.batchSequence }
    var changes: [SyncBatchChange] { batch.changes }

    init(batch: SyncBatch, capturedChanges: [SyncConvergenceCapturedLocalChange]) {
        self.batch = batch
        self.evidence = .captured(capturedChanges)
    }

    init(legacyBatch batch: SyncBatch) {
        self.batch = batch
        self.evidence = .legacyMissing
    }
}

enum SyncConvergenceLocalEvidenceCaptureError: Error, Equatable {
    case missingBodyEvidence(noteID: UUID)
    case invalidBodyOperation(noteID: UUID)
    case mismatchedBaseHash(noteID: UUID)
    case continuityViolation(noteID: UUID)
    case indexedChangeMismatch(batchID: UUID)
}

enum SyncConvergenceLocalEvidenceCapture {
    static func capturedChange(
        for change: SyncBatchChange,
        preBody: String?,
        postBody: String?
    ) throws -> SyncConvergenceCapturedLocalChange {
        switch change {
        case .noteBodyTextInserted, .noteBodyTextDeleted:
            guard let preBody, let postBody else {
                throw SyncConvergenceLocalEvidenceCaptureError.missingBodyEvidence(noteID: noteID(for: change))
            }
            let replayedPostBody = try apply(change, to: preBody)
            guard replayedPostBody == postBody else {
                throw SyncConvergenceLocalEvidenceCaptureError.invalidBodyOperation(noteID: noteID(for: change))
            }
            let preBodyHash = SyncBatchContentHash.sha256Hex(for: preBody)
            if let declaredBaseHash = baseContentHash(for: change), declaredBaseHash != preBodyHash {
                throw SyncConvergenceLocalEvidenceCaptureError.mismatchedBaseHash(noteID: noteID(for: change))
            }
            let evidence = SyncConvergenceCapturedChangeEvidence(
                noteID: noteID(for: change),
                preBodyHash: preBodyHash,
                postBodyHash: SyncBatchContentHash.sha256Hex(for: postBody),
                preBodySnapshot: preBody,
                postBodySnapshot: postBody,
                insertedText: insertedText(for: change),
                deletedText: deletedText(for: change)
            )
            return SyncConvergenceCapturedLocalChange(change: change, evidence: evidence)
        case .noteBodyTextInsertedAnchored, .noteBodyTextDeletedAnchored:
            throw SyncConvergenceLocalEvidenceCaptureError.invalidBodyOperation(noteID: change.noteID)
        case .noteCreated, .noteTitleChanged, .noteBodyReconciled, .noteLifecycleChanged:
            return SyncConvergenceCapturedLocalChange(change: change, evidence: nil)
        }
    }

    static func capturedAnchoredChange(
        for change: SyncBatchChange,
        structuralPreState: SyncTextSequenceState,
        structuralPostState: SyncTextSequenceState
    ) throws -> SyncConvergenceCapturedLocalChange {
        let replayedState: SyncTextSequenceState
        switch change {
        case .noteBodyTextInsertedAnchored(let inserted):
            replayedState = try SyncBatchAnchoredInsertReplay.applying(
                inserted,
                to: structuralPreState
            ).sequenceState
        case .noteBodyTextDeletedAnchored(let deleted):
            replayedState = try SyncBatchAnchoredDeleteReplay.applying(
                deleted,
                to: structuralPreState
            ).sequenceState
        default:
            throw SyncConvergenceLocalEvidenceCaptureError.invalidBodyOperation(noteID: change.noteID)
        }
        guard replayedState == structuralPostState else {
            throw SyncConvergenceLocalEvidenceCaptureError.invalidBodyOperation(noteID: change.noteID)
        }
        let preBody = structuralPreState.visibleText
        let postBody = structuralPostState.visibleText
        let preHash = SyncBatchContentHash.sha256Hex(for: preBody)
        if let declared = change.baseContentHash, declared != preHash {
            throw SyncConvergenceLocalEvidenceCaptureError.mismatchedBaseHash(noteID: change.noteID)
        }
        return SyncConvergenceCapturedLocalChange(
            change: change,
            evidence: SyncConvergenceCapturedChangeEvidence(
                noteID: change.noteID,
                preBodyHash: preHash,
                postBodyHash: SyncBatchContentHash.sha256Hex(for: postBody),
                preBodySnapshot: preBody,
                postBodySnapshot: postBody,
                insertedText: insertedText(for: change),
                deletedText: deletedText(for: change)
            )
        )
    }

    static func validate(obligation: SyncConvergenceLocalObligation) throws -> [SyncConvergenceCapturedLocalChange] {
        try SyncBatchAnchoredPayloadPolicy.validateOffsetReplay(obligation.batch)
        guard case .captured(let capturedChanges) = obligation.evidence else { return [] }
        guard obligation.batch.changes.count == capturedChanges.count else {
            throw SyncConvergenceLocalEvidenceCaptureError.indexedChangeMismatch(batchID: obligation.batch.id)
        }

        var lastPostHashByNoteID: [UUID: String] = [:]
        for (index, capturedChange) in capturedChanges.enumerated() {
            guard obligation.batch.changes[index] == capturedChange.change else {
                throw SyncConvergenceLocalEvidenceCaptureError.indexedChangeMismatch(batchID: obligation.batch.id)
            }

            guard let evidence = capturedChange.evidence else { continue }
            guard evidence.noteID == noteID(for: capturedChange.change) else {
                throw SyncConvergenceLocalEvidenceCaptureError.invalidBodyOperation(noteID: noteID(for: capturedChange.change))
            }
            if let previousPostHash = lastPostHashByNoteID[evidence.noteID],
               previousPostHash != evidence.preBodyHash {
                throw SyncConvergenceLocalEvidenceCaptureError.continuityViolation(noteID: evidence.noteID)
            }
            if let preBody = evidence.preBodySnapshot,
               SyncBatchContentHash.sha256Hex(for: preBody) != evidence.preBodyHash {
                throw SyncConvergenceLocalEvidenceCaptureError.invalidBodyOperation(noteID: evidence.noteID)
            }
            if let postBody = evidence.postBodySnapshot,
               SyncBatchContentHash.sha256Hex(for: postBody) != evidence.postBodyHash {
                throw SyncConvergenceLocalEvidenceCaptureError.invalidBodyOperation(noteID: evidence.noteID)
            }
            if let preBody = evidence.preBodySnapshot,
               let postBody = evidence.postBodySnapshot {
                switch capturedChange.change {
                case .noteBodyTextInsertedAnchored(let inserted):
                    guard evidence.insertedText == inserted.text,
                          postBody.utf16.count == preBody.utf16.count + inserted.text.utf16.count else {
                        throw SyncConvergenceLocalEvidenceCaptureError.invalidBodyOperation(noteID: evidence.noteID)
                    }
                case .noteBodyTextDeletedAnchored(let deleted):
                    guard evidence.deletedText == deleted.expectedText,
                          postBody.utf16.count + deleted.utf16Length == preBody.utf16.count else {
                        throw SyncConvergenceLocalEvidenceCaptureError.invalidBodyOperation(noteID: evidence.noteID)
                    }
                default:
                    guard try apply(capturedChange.change, to: preBody) == postBody else {
                        throw SyncConvergenceLocalEvidenceCaptureError.invalidBodyOperation(noteID: evidence.noteID)
                    }
                }
            }
            if let declaredBaseHash = baseContentHash(for: capturedChange.change),
               declaredBaseHash != evidence.preBodyHash {
                throw SyncConvergenceLocalEvidenceCaptureError.mismatchedBaseHash(noteID: evidence.noteID)
            }
            lastPostHashByNoteID[evidence.noteID] = evidence.postBodyHash
        }
        return capturedChanges
    }

    static func apply(_ change: SyncBatchChange, to body: String) throws -> String {
        switch change {
        case .noteBodyTextInserted(let inserted):
            guard let range = body.syncBatchSafeUTF16Range(location: inserted.utf16Offset, length: 0) else {
                throw SyncConvergenceLocalEvidenceCaptureError.invalidBodyOperation(noteID: inserted.noteID)
            }
            let mutable = NSMutableString(string: body)
            mutable.insert(inserted.text, at: range.location)
            return String(mutable)
        case .noteBodyTextDeleted(let deleted):
            guard let range = body.syncBatchSafeUTF16Range(
                location: deleted.utf16Offset,
                length: deleted.utf16Length
            ) else {
                throw SyncConvergenceLocalEvidenceCaptureError.invalidBodyOperation(noteID: deleted.noteID)
            }
            let deletedText = (body as NSString).substring(with: range)
            guard deleted.expectedText == nil || deleted.expectedText == deletedText else {
                throw SyncConvergenceLocalEvidenceCaptureError.invalidBodyOperation(noteID: deleted.noteID)
            }
            let mutable = NSMutableString(string: body)
            mutable.deleteCharacters(in: range)
            return String(mutable)
        case .noteBodyTextInsertedAnchored, .noteBodyTextDeletedAnchored:
            throw SyncConvergenceLocalEvidenceCaptureError.invalidBodyOperation(
                noteID: change.noteID
            )
        case .noteCreated, .noteTitleChanged, .noteBodyReconciled, .noteLifecycleChanged:
            return body
        }
    }

    static func noteID(for change: SyncBatchChange) -> UUID {
        change.noteID
    }

    static func baseContentHash(for change: SyncBatchChange) -> String? {
        change.baseContentHash
    }

    static func insertedText(for change: SyncBatchChange) -> String? {
        switch change {
        case .noteBodyTextInserted(let payload): payload.text
        case .noteBodyTextInsertedAnchored(let payload): payload.text
        default: nil
        }
    }

    static func deletedText(for change: SyncBatchChange) -> String? {
        switch change {
        case .noteBodyTextDeleted(let payload): payload.expectedText
        case .noteBodyTextDeletedAnchored(let payload): payload.expectedText
        default: nil
        }
    }

    static func isBodyTextOperation(_ change: SyncBatchChange) -> Bool {
        switch change {
        case .noteBodyTextInserted, .noteBodyTextDeleted,
             .noteBodyTextInsertedAnchored, .noteBodyTextDeletedAnchored:
            true
        case .noteCreated, .noteTitleChanged, .noteBodyReconciled, .noteLifecycleChanged:
            false
        }
    }
}
