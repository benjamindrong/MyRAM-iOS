import Foundation

enum SyncBatchAnchoredPayloadCapability {
    static let isEnabled = true
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

/// Applies the single production anchored-capability state at every side-effecting batch boundary.
enum SyncBatchAnchoredPayloadPolicy {
    static func validateTransportEncode(_ batch: SyncBatch) throws {
        try validate(batch, boundary: .transportEncode, activationEnabled: SyncBatchAnchoredPayloadCapability.isEnabled)
    }

    static func validateOutbound(_ batch: SyncBatch) throws {
        try validate(batch, boundary: .outboundController, activationEnabled: SyncBatchAnchoredPayloadCapability.isEnabled)
    }

    static func validateInbound(_ batch: SyncBatch) throws {
        try validate(batch, boundary: .inboundController, activationEnabled: SyncBatchAnchoredPayloadCapability.isEnabled)
    }

    static func validateDurableAdmission(_ batch: SyncBatch) throws {
        try validate(batch, boundary: .durableQueue, activationEnabled: SyncBatchAnchoredPayloadCapability.isEnabled)
    }

    static func validateConvergence(_ batch: SyncBatch) throws {
        try validate(batch, boundary: .convergence, activationEnabled: SyncBatchAnchoredPayloadCapability.isEnabled)
    }

    static func validateRecovery(_ batch: SyncBatch) throws {
        try validate(batch, boundary: .recovery, activationEnabled: SyncBatchAnchoredPayloadCapability.isEnabled)
    }

    static func validateOffsetReplay(_ batch: SyncBatch) throws {
        try validate(batch, boundary: .offsetReplay, activationEnabled: SyncBatchAnchoredPayloadCapability.isEnabled)
    }

    static func validateApply(_ batch: SyncBatch) throws {
        try validate(batch, boundary: .apply, activationEnabled: SyncBatchAnchoredPayloadCapability.isEnabled)
    }

    static func validateCore(
        _ batch: SyncBatch,
        boundary: SyncBatchAnchoredPayloadPolicyError.Boundary,
        activationEnabled: Bool
    ) throws {
        try validate(batch, boundary: boundary, activationEnabled: activationEnabled)
    }

    static func validateDurableAdmissionCore(
        _ batch: SyncBatch,
        activationEnabled: Bool
    ) throws {
        try validateCore(batch, boundary: .durableQueue, activationEnabled: activationEnabled)
    }

    static func validateConvergenceCore(_ batch: SyncBatch, activationEnabled: Bool) throws {
        try validateCore(batch, boundary: .convergence, activationEnabled: activationEnabled)
    }

    static func validateRecoveryCore(_ batch: SyncBatch, activationEnabled: Bool) throws {
        try validateCore(batch, boundary: .recovery, activationEnabled: activationEnabled)
    }

    private static func validate(
        _ batch: SyncBatch,
        boundary: SyncBatchAnchoredPayloadPolicyError.Boundary,
        activationEnabled: Bool
    ) throws {
        switch batch.bodyOperationRepresentation {
        case .mixed:
            throw SyncBatchAnchoredPayloadPolicyError.mixedBodyOperationRepresentations(
                boundary: boundary
            )
        case .anchored where !activationEnabled:
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

/// Shared MYR-178 authority for current/sequential anchorless replay eligibility.
/// Slice 2 requires the positive token before any direct raw-offset replay.
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

    static func evaluate(
        change: SyncBatchChange,
        authoritativeBodyHash: String
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
        case .noteCreated, .noteTitleChanged, .noteBodyTextInsertedAnchored,
             .noteBodyTextDeletedAnchored, .noteBodyReconciled, .noteLifecycleChanged:
            return .notAnchorlessBodyOperation
        }
        guard let declaredBaseContentHash else {
            return .unavailableEvidence(noteID: noteID)
        }
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

    static func requireEligibility(
        change: SyncBatchChange,
        authoritativeBody: String
    ) throws -> SyncBatchAnchorlessReplayEligibility {
        try requireEligibility(
            change: change,
            authoritativeBodyHash: SyncBatchContentHash.sha256Hex(for: authoritativeBody)
        )
    }

    static func requireEligibility(
        change: SyncBatchChange,
        authoritativeBodyHash: String
    ) throws -> SyncBatchAnchorlessReplayEligibility {
        switch evaluate(change: change, authoritativeBodyHash: authoritativeBodyHash) {
        case .eligible(let eligibility):
            return eligibility
        case .unavailableEvidence(let noteID):
            throw SyncBatchApplyPreflightError.unavailableAnchorlessBaseEvidence(noteID: noteID)
        case .divergentBase(let noteID, let declared, let actual):
            throw SyncBatchApplyPreflightError.mismatchedBaseContentHash(
                noteID: noteID,
                expected: declared,
                actual: actual
            )
        case .notAnchorlessBodyOperation:
            throw SyncBatchApplyPreflightError.invalidAnchorlessReplayEligibility(noteID: change.noteID)
        }
    }

    static func validate(
        eligibility: SyncBatchAnchorlessReplayEligibility,
        for change: SyncBatchChange,
        authoritativeBody: String
    ) throws {
        let authoritativeBodyHash = SyncBatchContentHash.sha256Hex(for: authoritativeBody)
        guard eligibility.change == change,
              eligibility.authoritativeBodyHash == authoritativeBodyHash else {
            throw SyncBatchApplyPreflightError.invalidAnchorlessReplayEligibility(noteID: change.noteID)
        }
    }
}
