import Foundation

struct SyncConvergenceRewriteSafetyInput: Equatable {
    let noteID: UUID
    let sourceBatchID: UUID?
    let priorBody: String
    let candidateBody: String
    let deleteEvidence: [SyncConvergenceDeleteEvidence]
    let context: SyncConvergenceRewriteContext
}

struct SyncConvergenceDeleteEvidence: Equatable {
    let operationIdentity: OperationIdentityPayload
    let utf16Offset: Int
    let utf16Length: Int
    let expectedText: String
    let baseContentHash: String?
    let resultContentHash: String?
}

enum SyncConvergenceRewriteContext: Equatable {
    case plannerMerge
    case reconciliation
    case postCommitPresentation
    case retry
    case relaunch
    case editorFallback
    case legacyPlatformApply
}

struct SyncConvergenceRewriteSafetyReceipt: Codable, Equatable, Sendable {
    let noteID: UUID
    let priorBodyHash: String
    let candidateBodyHash: String
    let consumedDeleteIdentities: [OperationIdentityPayload]
}

enum SyncConvergenceUnsafeRewriteReason: Equatable {
    case duplicateDeleteIdentity
    case malformedDeleteEvidence
    case unprovenTextLoss
}

enum SyncConvergenceRewriteSafetyResult: Equatable {
    case safe(SyncConvergenceRewriteSafetyReceipt)
    case unsafe(SyncConvergenceUnsafeRewriteReason)
}

/// Proves that a recovery-only whole-body replacement cannot silently discard
/// text. Evidence is consumed in local working state for this validation only.
struct SyncConvergenceRewriteSafetyPolicy {
    func validate(_ input: SyncConvergenceRewriteSafetyInput) -> SyncConvergenceRewriteSafetyResult {
        let priorHash = SyncBatchContentHash.sha256Hex(for: input.priorBody)
        let candidateHash = SyncBatchContentHash.sha256Hex(for: input.candidateBody)
        if input.priorBody == input.candidateBody {
            return .safe(receipt(input, priorHash: priorHash, candidateHash: candidateHash, consumed: []))
        }

        var identities = Set<String>()
        for evidence in input.deleteEvidence {
            guard identities.insert(evidence.operationIdentity.planIdentityKey).inserted else {
                return .unsafe(.duplicateDeleteIdentity)
            }
            guard evidence.utf16Offset >= 0,
                  evidence.utf16Length > 0,
                  !evidence.expectedText.isEmpty,
                  evidence.expectedText.utf16.count == evidence.utf16Length,
                  input.priorBody.range(of: evidence.expectedText) != nil else {
                return .unsafe(.malformedDeleteEvidence)
            }
        }

        let deficit = characterDeficit(prior: input.priorBody, candidate: input.candidateBody)
        if deficit.isEmpty {
            return .safe(receipt(input, priorHash: priorHash, candidateHash: candidateHash, consumed: []))
        }

        guard let consumed = consumeEvidence(
            input.deleteEvidence.sorted(by: evidenceOrder),
            index: 0,
            remaining: deficit
        ) else { return .unsafe(.unprovenTextLoss) }
        return .safe(receipt(input, priorHash: priorHash, candidateHash: candidateHash, consumed: consumed))
    }

    private func receipt(
        _ input: SyncConvergenceRewriteSafetyInput,
        priorHash: String,
        candidateHash: String,
        consumed: [OperationIdentityPayload]
    ) -> SyncConvergenceRewriteSafetyReceipt {
        SyncConvergenceRewriteSafetyReceipt(
            noteID: input.noteID,
            priorBodyHash: priorHash,
            candidateBodyHash: candidateHash,
            consumedDeleteIdentities: consumed
        )
    }

    private func characterDeficit(prior: String, candidate: String) -> [Character: Int] {
        let priorCounts = characterCounts(prior)
        let candidateCounts = characterCounts(candidate)
        return priorCounts.reduce(into: [:]) { result, entry in
            let missing = entry.value - candidateCounts[entry.key, default: 0]
            if missing > 0 { result[entry.key] = missing }
        }
    }

    private func characterCounts(_ text: String) -> [Character: Int] {
        text.reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }

    private func consumeEvidence(
        _ evidence: [SyncConvergenceDeleteEvidence],
        index: Int,
        remaining: [Character: Int]
    ) -> [OperationIdentityPayload]? {
        if remaining.isEmpty { return [] }
        guard index < evidence.count else { return nil }
        let counts = characterCounts(evidence[index].expectedText)
        if counts.allSatisfy({ remaining[$0.key, default: 0] >= $0.value }) {
            var reduced = remaining
            for (character, count) in counts {
                reduced[character, default: 0] -= count
                if reduced[character] == 0 { reduced.removeValue(forKey: character) }
            }
            if let tail = consumeEvidence(evidence, index: index + 1, remaining: reduced) {
                return [evidence[index].operationIdentity] + tail
            }
        }
        return consumeEvidence(evidence, index: index + 1, remaining: remaining)
    }

    private func evidenceOrder(_ lhs: SyncConvergenceDeleteEvidence, _ rhs: SyncConvergenceDeleteEvidence) -> Bool {
        lhs.operationIdentity.planIdentityKey < rhs.operationIdentity.planIdentityKey
    }
}
