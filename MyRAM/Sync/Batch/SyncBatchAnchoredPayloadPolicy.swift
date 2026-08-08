import Foundation

enum SyncBatchAnchoredPayloadCapability {
    static let isEnabled = false
}

enum SyncBatchBodyOperationRepresentation: Equatable, Sendable {
    case none
    case legacy
    case anchored
    case mixed
}

enum SyncBatchAnchoredPayloadPolicyError: Error, Equatable, Sendable {
    enum Boundary: Equatable, Sendable {
        case transportEncode
        case outboundController
        case inboundController
        case durableQueue
        case convergence
        case recovery
        case offsetReplay
        case apply
    }

    case anchoredPayloadDisabled(boundary: Boundary, noteID: UUID)
    case mixedBodyOperationRepresentations(boundary: Boundary)
}

/// Keeps the Stage 1 capability dark at every side-effecting batch boundary.
enum SyncBatchAnchoredPayloadPolicy {
    static func validateTransportEncode(_ batch: SyncBatch) throws {
        try validate(batch, boundary: .transportEncode)
    }

    static func validateOutbound(_ batch: SyncBatch) throws {
        try validate(batch, boundary: .outboundController)
    }

    static func validateInbound(_ batch: SyncBatch) throws {
        try validate(batch, boundary: .inboundController)
    }

    static func validateDurableAdmission(_ batch: SyncBatch) throws {
        try validate(batch, boundary: .durableQueue)
    }

    static func validateConvergence(_ batch: SyncBatch) throws {
        try validate(batch, boundary: .convergence)
    }

    static func validateRecovery(_ batch: SyncBatch) throws {
        try validate(batch, boundary: .recovery)
    }

    static func validateOffsetReplay(_ batch: SyncBatch) throws {
        try validate(batch, boundary: .offsetReplay)
    }

    static func validateApply(_ batch: SyncBatch) throws {
        try validate(batch, boundary: .apply)
    }

    private static func validate(
        _ batch: SyncBatch,
        boundary: SyncBatchAnchoredPayloadPolicyError.Boundary
    ) throws {
        switch batch.bodyOperationRepresentation {
        case .mixed:
            throw SyncBatchAnchoredPayloadPolicyError.mixedBodyOperationRepresentations(
                boundary: boundary
            )
        case .anchored where !SyncBatchAnchoredPayloadCapability.isEnabled:
            guard let noteID = batch.changes.first(where: {
                $0.bodyOperationRepresentation == .anchored
            })?.noteID else {
                preconditionFailure("Anchored classification must identify an anchored change")
            }
            throw SyncBatchAnchoredPayloadPolicyError.anchoredPayloadDisabled(
                boundary: boundary,
                noteID: noteID
            )
        case .none, .legacy, .anchored:
            return
        }
    }
}

extension SyncBatch {
    var bodyOperationRepresentation: SyncBatchBodyOperationRepresentation {
        var sawLegacy = false
        var sawAnchored = false

        for change in changes {
            switch change.bodyOperationRepresentation {
            case .legacy:
                sawLegacy = true
            case .anchored:
                sawAnchored = true
            case .none:
                continue
            case .mixed:
                preconditionFailure("One change cannot contain mixed representations")
            }
            if sawLegacy && sawAnchored {
                return .mixed
            }
        }

        if sawAnchored {
            return .anchored
        }
        if sawLegacy {
            return .legacy
        }
        return .none
    }
}

// MYR-178 Slice 1 dark anchorless compatibility decision
struct SyncBatchAnchorlessReplayEligibility: Equatable, Sendable {
    let change: SyncBatchChange
    let authoritativeBodyHash: String

    fileprivate init(change: SyncBatchChange, authoritativeBodyHash: String) {
        self.change = change
        self.authoritativeBodyHash = authoritativeBodyHash
    }
}

enum SyncBatchAnchorlessCompatibilityDecision: Equatable, Sendable {
    case eligible(SyncBatchAnchorlessReplayEligibility)
    case unavailableEvidence(noteID: UUID)
    case divergentBase(
        noteID: UUID,
        declaredBaseContentHash: String,
        authoritativeBodyHash: String
    )
    case notAnchorlessBodyOperation
}

/// Side-effect-free classification only. Slice 1 intentionally has no production callers.
/// Slice 2 will make the positive eligibility value mandatory at direct raw-offset replay.
enum SyncBatchAnchorlessCompatibilityEvaluator {
    static func evaluate(
        change: SyncBatchChange,
        authoritativeBody: String
    ) -> SyncBatchAnchorlessCompatibilityDecision {
        let noteID: UUID
        let declaredBaseContentHash: String?

        switch change {
        case .noteBodyTextInserted(let insert):
            noteID = insert.noteID
            declaredBaseContentHash = insert.baseContentHash
        case .noteBodyTextDeleted(let delete):
            noteID = delete.noteID
            declaredBaseContentHash = delete.baseContentHash
        case .noteCreated,
             .noteTitleChanged,
             .noteBodyTextInsertedAnchored,
             .noteBodyTextDeletedAnchored,
             .noteBodyReconciled,
             .noteLifecycleChanged:
            return .notAnchorlessBodyOperation
        }

        guard let declaredBaseContentHash else {
            return .unavailableEvidence(noteID: noteID)
        }

        let authoritativeBodyHash = SyncBatchContentHash.sha256Hex(for: authoritativeBody)
        guard declaredBaseContentHash == authoritativeBodyHash else {
            return .divergentBase(
                noteID: noteID,
                declaredBaseContentHash: declaredBaseContentHash,
                authoritativeBodyHash: authoritativeBodyHash
            )
        }

        return .eligible(SyncBatchAnchorlessReplayEligibility(
            change: change,
            authoritativeBodyHash: authoritativeBodyHash
        ))
    }
}
