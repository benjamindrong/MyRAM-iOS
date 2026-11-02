import AnchoredSequenceCore
import Foundation
import NearbySyncCore
import SwiftData

typealias NoteLegacyFormattingProjectionOperation =
    @Sendable (Data, String) async -> NoteStructuralFormattingProjection?

typealias NoteStructuralFormattingCacheRenderOperation =
    @Sendable (SyncTextSequenceState, SyncTextMarkState) async throws -> Data?

/// Immutable, lossless evidence for a structurally valid local body/history mismatch.
/// Capturing this value performs no persistence, authority change or networking.
/// A future resolution must durably retain this exact snapshot, including raw mark
/// and sequence bytes, and prove queue ownership before changing either authority.
struct NoteLocalDivergenceSnapshot: Codable, Equatable, Sendable {
    let noteID: UUID
    let savedTitle: String
    let savedBody: String
    let savedRichTextContentData: Data?
    let savedIsPinned: Bool?
    let savedCreatedAt: Date
    let savedModifiedAt: Date
    let savedDeletedAt: Date?
    let savedFolderID: UUID?
    let sequenceVisibleText: String
    let sequenceFormatVersion: Int
    let sequenceRevision: UInt64
    let sequenceVisibleUTF16Count: Int
    let sequenceTombstonedUTF16Count: Int
    let sequencePayloadByteCount: Int
    let sequencePayloadData: Data
    let markFormatVersion: Int
    let markRevision: UInt64
    let markStatePayloadData: Data
}

/// Explicit owner choice bound to one immutable, previously archived divergence snapshot.
/// This is an uncommitted intent, never permission for a background authority change.
enum NoteLocalDivergenceResolutionChoice: String, Codable, Equatable, Sendable {
    case keepSavedBody
    case keepAnchoredHistory
}

struct NoteLocalDivergenceResolutionIntent: Codable, Equatable, Sendable {
    let noteID: UUID
    let evidenceIndex: Int
    let choice: NoteLocalDivergenceResolutionChoice
}

/// One prepared queue preimage bound to a single, explicit owner choice.
/// This record is proof of persistence, not a cross-store commit receipt.
struct NoteLocalDivergenceQueuePreparation: Codable, Equatable {
    let intent: NoteLocalDivergenceResolutionIntent
    let ownership: NoteLocalDivergenceQueueOwnershipEvidence
}

/// A read-only candidate for an explicit owner decision. Constructing it never
/// changes Note, CRDT, marks, queues or sync admission. A separate journaled
/// transaction must still prove durable queue ownership before applying it.
struct NoteLocalDivergenceResolutionPlan: Equatable, Sendable {
    let original: NoteLocalDivergenceSnapshot
    let choice: NoteLocalDivergenceResolutionChoice
    let finalBody: String
    let finalState: SyncTextSequenceState
    let finalMarkState: SyncTextMarkState
    let capturedChanges: [SyncConvergenceCapturedLocalChange]
}

/// Recovered before any SwiftData or queue write: exact proposed authority bytes
/// and the captured operations that would make the saved text authoritative.
/// This is a write-ahead *preparation*, never a completed commit or sync receipt.
struct NoteLocalDivergenceCommitPreparation: Codable, Equatable {
    let intent: NoteLocalDivergenceResolutionIntent
    let finalBody: String
    let finalSequencePayloadData: Data
    let finalSequenceVisibleUTF16Count: Int
    let finalSequenceTombstonedUTF16Count: Int
    let finalMarkStatePayloadData: Data
    let capturedChanges: [SyncConvergenceCapturedLocalChange]
}

/// The note-state commit receipt never authorizes queue cleanup or sync resume.
/// The unfinished owner intent survives both phases until all queue obligations
/// are separately reconciled.
enum NoteLocalDivergenceNoteCommitPhase: String, Codable {
    case started
    case noteSaved
}

struct NoteLocalDivergenceNoteCommitProgress: Codable, Equatable {
    let intent: NoteLocalDivergenceResolutionIntent
    let phase: NoteLocalDivergenceNoteCommitPhase
}

/// Final evidence that a no-write queue reconciliation was completed after the
/// owner-approved note pair was durably verified. The original snapshot and
/// queue preimage are retained, not consumed.
struct NoteLocalDivergenceCompletionReceipt: Codable, Equatable {
    let intent: NoteLocalDivergenceResolutionIntent
}

/// An immutable, append-only ledger of local note/body versus anchored-history evidence.
/// Neither a captured snapshot nor this ledger authorizes choosing a winner or resuming sync.
struct NoteLocalDivergenceEvidenceEnvelope: Codable, Equatable {
    static let supportedVersion = 1

    let formatVersion: Int
    var snapshots: [NoteLocalDivergenceSnapshot]
    // Optional for backward decoding of v1 evidence archives written before
    // explicit user resolution could be represented.
    var resolutionIntents: [NoteLocalDivergenceResolutionIntent]? = nil
    // Old v1 archives have no queue preparation. Never infer one from intent.
    var queuePreparations: [NoteLocalDivergenceQueuePreparation]? = nil
    // Compatible with older v1 archives. Never infer transaction authority
    // from the mere presence of an owner choice or a queue preimage.
    var commitPreparations: [NoteLocalDivergenceCommitPreparation]? = nil
    // A noteSaved receipt is never a completed cross-store transaction.
    var noteCommitProgress: [NoteLocalDivergenceNoteCommitProgress]? = nil
    // Optional for all previously written v1 ledgers. Never infer completion
    // from a noteSaved phase, an empty queue, or an owner choice alone.
    var completionReceipts: [NoteLocalDivergenceCompletionReceipt]? = nil

    static let empty = Self(formatVersion: supportedVersion, snapshots: [])

    func validate() throws {
        guard formatVersion == Self.supportedVersion else {
            throw NoteLocalDivergenceEvidenceStoreError.unsupportedVersion(formatVersion)
        }
        for (index, snapshot) in snapshots.enumerated() {
            guard snapshot.sequencePayloadByteCount == snapshot.sequencePayloadData.count,
                  snapshot.sequenceVisibleUTF16Count >= 0,
                  snapshot.sequenceTombstonedUTF16Count >= 0,
                  !NoteSequenceStateExactText.matches(
                    snapshot.savedBody, snapshot.sequenceVisibleText
                  ),
                  !snapshots.prefix(index).contains(snapshot) else {
                throw NoteLocalDivergenceEvidenceStoreError.corruptArchive
            }
        }
        var intendedNoteIDs = Set<UUID>()
        for intent in resolutionIntents ?? [] {
            guard snapshots.indices.contains(intent.evidenceIndex),
                  snapshots[intent.evidenceIndex].noteID == intent.noteID,
                  intendedNoteIDs.insert(intent.noteID).inserted else {
                throw NoteLocalDivergenceEvidenceStoreError.corruptArchive
            }
        }
        var preparedNoteIDs = Set<UUID>()
        for prepared in queuePreparations ?? [] {
            guard (resolutionIntents ?? []).contains(prepared.intent),
                  preparedNoteIDs.insert(prepared.intent.noteID).inserted else {
                throw NoteLocalDivergenceEvidenceStoreError.corruptArchive
            }
        }
        var commitPreparedNoteIDs = Set<UUID>()
        for prepared in commitPreparations ?? [] {
            guard (queuePreparations ?? []).contains(where: { $0.intent == prepared.intent }),
                  snapshots.indices.contains(prepared.intent.evidenceIndex),
                  commitPreparedNoteIDs.insert(prepared.intent.noteID).inserted else {
                throw NoteLocalDivergenceEvidenceStoreError.corruptArchive
            }
            let snapshot = snapshots[prepared.intent.evidenceIndex]
            let chosenBody = prepared.intent.choice == .keepSavedBody
                ? snapshot.savedBody : snapshot.sequenceVisibleText
            guard prepared.finalBody == chosenBody,
                  prepared.finalMarkStatePayloadData == snapshot.markStatePayloadData,
                  prepared.finalSequenceVisibleUTF16Count == chosenBody.utf16.count,
                  prepared.finalSequenceTombstonedUTF16Count >= snapshot.sequenceTombstonedUTF16Count,
                  (prepared.intent.choice != .keepAnchoredHistory || (
                    prepared.finalSequencePayloadData == snapshot.sequencePayloadData &&
                    prepared.finalSequenceTombstonedUTF16Count == snapshot.sequenceTombstonedUTF16Count &&
                    prepared.capturedChanges.isEmpty
                  )) else {
                throw NoteLocalDivergenceEvidenceStoreError.corruptArchive
            }
        }
        var progressedNoteIDs = Set<UUID>()
        for progress in noteCommitProgress ?? [] {
            guard (commitPreparations ?? []).contains(where: {
                $0.intent == progress.intent
            }), progressedNoteIDs.insert(progress.intent.noteID).inserted else {
                throw NoteLocalDivergenceEvidenceStoreError.corruptArchive
            }
        }
        var completedNoteIDs = Set<UUID>()
        for receipt in completionReceipts ?? [] {
            guard let prepared = (commitPreparations ?? []).first(where: {
                $0.intent == receipt.intent
            }),
                  (noteCommitProgress ?? []).contains(where: {
                      $0.intent == receipt.intent && $0.phase == .noteSaved
                  }),
                  receipt.intent.choice == .keepAnchoredHistory,
                  prepared.capturedChanges.isEmpty,
                  completedNoteIDs.insert(receipt.intent.noteID).inserted else {
                throw NoteLocalDivergenceEvidenceStoreError.corruptArchive
            }
        }
    }
}

enum NoteLocalDivergenceEvidenceStoreError: Error, Equatable {
    case unsupportedVersion(Int)
    case corruptArchive
    case staleSnapshot
    case snapshotNotPreserved
    case conflictingResolution
    case unresolvedResolutionIntent
    case conflictingQueueOwnership
    case unresolvedCapturedResolutionChanges
    case persistenceFailed
}

struct NoteLocalDivergenceEvidenceFileIO: Sendable {
    var fileExists: @Sendable (URL) -> Bool
    var readData: @Sendable (URL) throws -> Data
    var createDirectory: @Sendable (URL) throws -> Void
    var writeData: @Sendable (Data, URL) throws -> Void

    static let live = Self(
        fileExists: { FileManager.default.fileExists(atPath: $0.path) },
        readData: { try Data(contentsOf: $0) },
        createDirectory: {
            try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true)
        },
        writeData: { data, url in try data.write(to: url, options: [.atomic]) }
    )
}

/// Serialized on the same persistence actor as the structural snapshot source.
/// The archive never updates the note, sequence, formatting, queues or networking.
@NoteSequenceStatePersistenceActor
final class NoteLocalDivergenceEvidenceStore {
    private let fileURL: URL
    private let fileIO: NoteLocalDivergenceEvidenceFileIO

    init(
        fileURL: URL = NoteLocalDivergenceEvidenceStore.defaultFileURL(),
        fileIO: NoteLocalDivergenceEvidenceFileIO = .live
    ) {
        self.fileURL = fileURL
        self.fileIO = fileIO
    }

    /// Preserve only a currently verified local divergence. Never overwrite an
    /// earlier generation from the same note; it may contain unsent user work.
    @discardableResult
    func preserve(
        _ snapshot: NoteLocalDivergenceSnapshot,
        checkedBy migrator: NoteSequenceStateBootstrapMigrator
    ) throws -> Bool {
        guard try migrator.revalidateDivergenceSnapshot(snapshot) else {
            throw NoteLocalDivergenceEvidenceStoreError.staleSnapshot
        }
        var envelope = try loadEnvelope()
        if envelope.snapshots.contains(snapshot) {
            return false
        }
        envelope.snapshots.append(snapshot)
        try saveEnvelope(envelope)
        // A late local mutation cannot make the captured evidence authoritative.
        guard try migrator.revalidateDivergenceSnapshot(snapshot) else {
            throw NoteLocalDivergenceEvidenceStoreError.staleSnapshot
        }
        return true
    }

    func snapshots(for noteID: UUID) throws -> [NoteLocalDivergenceSnapshot] {
        try loadEnvelope().snapshots.filter { $0.noteID == noteID }
    }
    /// Records a deliberately selected choice, but does not mutate note, CRDT,
    /// formatting, outbound queues, or the sync admission gate. The caller must
    /// have durably preserved this exact evidence generation first.
    @discardableResult
    func prepareOwnerSelectedResolution(
        snapshot: NoteLocalDivergenceSnapshot,
        choice: NoteLocalDivergenceResolutionChoice,
        checkedBy migrator: NoteSequenceStateBootstrapMigrator
    ) throws -> Bool {
        guard try migrator.revalidateDivergenceSnapshot(snapshot) else {
            throw NoteLocalDivergenceEvidenceStoreError.staleSnapshot
        }
        var envelope = try loadEnvelope()
        guard let index = envelope.snapshots.firstIndex(of: snapshot) else {
            throw NoteLocalDivergenceEvidenceStoreError.snapshotNotPreserved
        }
        let proposed = NoteLocalDivergenceResolutionIntent(
            noteID: snapshot.noteID,
            evidenceIndex: index,
            choice: choice
        )
        if let existing = (envelope.resolutionIntents ?? []).first(where: {
            $0.noteID == snapshot.noteID
        }) {
            guard existing == proposed else {
                throw NoteLocalDivergenceEvidenceStoreError.conflictingResolution
            }
            return false
        }
        envelope.resolutionIntents = (envelope.resolutionIntents ?? []) + [proposed]
        try saveEnvelope(envelope)
        // A concurrently modified note is never certified as ready for a
        // follow-on resolution, even when the intent was already written.
        guard try migrator.revalidateDivergenceSnapshot(snapshot) else {
            throw NoteLocalDivergenceEvidenceStoreError.staleSnapshot
        }
        return true
    }

    func preparedResolution(for noteID: UUID) throws -> NoteLocalDivergenceResolutionIntent? {
        try loadEnvelope().resolutionIntents?.first { $0.noteID == noteID }
    }

    /// Queue ownership must come from the health-checked recovery owner while
    /// sync is suspended. Once archived, re-capture and compare before any
    /// future SwiftData or queue mutation; changed pending work is a blocker.
    @discardableResult
    func prepareQueueOwnership(
        for snapshot: NoteLocalDivergenceSnapshot,
        ownership: NoteLocalDivergenceQueueOwnershipEvidence,
        checkedBy migrator: NoteSequenceStateBootstrapMigrator
    ) throws -> Bool {
        guard try migrator.revalidateDivergenceSnapshot(snapshot) else {
            throw NoteLocalDivergenceEvidenceStoreError.staleSnapshot
        }
        var envelope = try loadEnvelope()
        guard let index = envelope.snapshots.firstIndex(of: snapshot),
              let intent = (envelope.resolutionIntents ?? []).first(where: {
                  $0.noteID == snapshot.noteID && $0.evidenceIndex == index
              }) else {
            throw NoteLocalDivergenceEvidenceStoreError.unresolvedResolutionIntent
        }
        let proposed = NoteLocalDivergenceQueuePreparation(
            intent: intent,
            ownership: ownership
        )
        if let existing = (envelope.queuePreparations ?? []).first(where: {
            $0.intent.noteID == snapshot.noteID
        }) {
            guard existing == proposed else {
                throw NoteLocalDivergenceEvidenceStoreError.conflictingQueueOwnership
            }
            return false
        }
        envelope.queuePreparations = (envelope.queuePreparations ?? []) + [proposed]
        try saveEnvelope(envelope)
        guard try migrator.revalidateDivergenceSnapshot(snapshot) else {
            throw NoteLocalDivergenceEvidenceStoreError.staleSnapshot
        }
        return true
    }

    func preparedQueueOwnership(
        for noteID: UUID
    ) throws -> NoteLocalDivergenceQueuePreparation? {
        try loadEnvelope().queuePreparations?.first { $0.intent.noteID == noteID }
    }

    /// Freeze the already-reviewed owner choice as an immutable, replayable
    /// write-ahead preparation. No Note, CRDT, queue or networking is changed.
    /// Later transaction execution must re-check the exact queue preimage and
    /// note/mark snapshot before any authority mutation.
    func prepareCommit(
        for snapshot: NoteLocalDivergenceSnapshot,
        checkedBy migrator: NoteSequenceStateBootstrapMigrator
    ) async throws -> NoteLocalDivergenceCommitPreparation {
        guard try migrator.revalidateDivergenceSnapshot(snapshot) else {
            throw NoteLocalDivergenceEvidenceStoreError.staleSnapshot
        }
        let envelope = try loadEnvelope()
        guard let index = envelope.snapshots.firstIndex(of: snapshot),
              let queuePreparation = (envelope.queuePreparations ?? []).first(where: {
                  $0.intent.noteID == snapshot.noteID && $0.intent.evidenceIndex == index
              }) else {
            throw NoteLocalDivergenceEvidenceStoreError.conflictingQueueOwnership
        }

        // Never generate fresh operation identities on a replay. Those from the
        // original prepared plan are the only identities a future commit can use.
        if let existing = (envelope.commitPreparations ?? []).first(where: {
            $0.intent.noteID == snapshot.noteID
        }) {
            guard existing.intent == queuePreparation.intent else {
                throw NoteLocalDivergenceEvidenceStoreError.conflictingResolution
            }
            return existing
        }

        let plan = try await migrator.makeOwnerResolutionPlan(
            for: snapshot, choice: queuePreparation.intent.choice
        )
        // Choosing existing anchored history must retain its exact original
        // bytes, even if a future codec encoder would normalize them.
        let encoded: Data
        if plan.choice == .keepAnchoredHistory {
            encoded = snapshot.sequencePayloadData
        } else {
            encoded = try NoteSequenceStatePersistenceCodec.encode(
                state: plan.finalState, noteID: snapshot.noteID
            )
        }
        let prepared = NoteLocalDivergenceCommitPreparation(
            intent: queuePreparation.intent,
            finalBody: plan.finalBody,
            finalSequencePayloadData: encoded,
            finalSequenceVisibleUTF16Count: plan.finalState.visibleUTF16Count,
            finalSequenceTombstonedUTF16Count: plan.finalState.tombstonedUTF16Count,
            finalMarkStatePayloadData: snapshot.markStatePayloadData,
            capturedChanges: plan.capturedChanges
        )
        var updated = try loadEnvelope()
        guard updated == envelope,
              try migrator.revalidateDivergenceSnapshot(snapshot) else {
            throw NoteLocalDivergenceEvidenceStoreError.staleSnapshot
        }
        updated.commitPreparations = (updated.commitPreparations ?? []) + [prepared]
        try saveEnvelope(updated)
        guard try migrator.revalidateDivergenceSnapshot(snapshot) else {
            throw NoteLocalDivergenceEvidenceStoreError.staleSnapshot
        }
        return prepared
    }

    func preparedCommit(for noteID: UUID) throws -> NoteLocalDivergenceCommitPreparation? {
        try loadEnvelope().commitPreparations?.first { $0.intent.noteID == noteID }
    }

    /// Atomically records that a previously prepared, owner-approved note
    /// mutation has begun, then applies the exact planned SwiftData pair.
    /// The queue recapture closure MUST be owned by the suspended recovery
    /// coordinator. No queues are replaced, acknowledged or transmitted.
    /// A crash after SwiftData save but before receipt persistence is replayed
    /// by checking the exact target bytes before attempting another write.
    func commitPreparedNote(
        for snapshot: NoteLocalDivergenceSnapshot,
        checkedBy migrator: NoteSequenceStateBootstrapMigrator,
        recaptureQueueOwnership: @MainActor () async throws -> NoteLocalDivergenceQueueOwnershipEvidence
    ) async throws -> Bool {
        let preflight = try loadEnvelope()
        guard let index = preflight.snapshots.firstIndex(of: snapshot),
              let queue = (preflight.queuePreparations ?? []).first(where: {
                  $0.intent.noteID == snapshot.noteID && $0.intent.evidenceIndex == index
              }),
              let prepared = (preflight.commitPreparations ?? []).first(where: {
                  $0.intent == queue.intent
              }) else {
            throw NoteLocalDivergenceEvidenceStoreError.conflictingQueueOwnership
        }

        // Always validate *all* durable obligations while outgoing and incoming
        // work remain suspended. A changed acknowledgement or admission must
        // not be erased by a stale queue preimage.
        let observed = try await recaptureQueueOwnership()
        guard observed == queue.ownership else {
            throw NoteLocalDivergenceEvidenceStoreError.conflictingQueueOwnership
        }
        var current = try loadEnvelope()
        guard current == preflight else {
            throw NoteLocalDivergenceEvidenceStoreError.conflictingQueueOwnership
        }
        let phase = (current.noteCommitProgress ?? []).first {
            $0.intent.noteID == snapshot.noteID
        }?.phase

        if phase == .noteSaved {
            // A recorded success can only be rechecked, never replayed over
            // a changed note. This also verifies the paired structural marks.
            return try migrator.applyPreparedNoteCommit(
                prepared, expected: snapshot, allowMutation: false
            )
        }
        if phase == nil {
            guard try migrator.revalidateDivergenceSnapshot(snapshot) else {
                throw NoteLocalDivergenceEvidenceStoreError.staleSnapshot
            }
            current.noteCommitProgress = (current.noteCommitProgress ?? []) + [
                NoteLocalDivergenceNoteCommitProgress(
                    intent: prepared.intent, phase: .started
                )
            ]
            try saveEnvelope(current)
        }

        let changed = try migrator.applyPreparedNoteCommit(
            prepared, expected: snapshot
        )
        var saved = try loadEnvelope()
        guard saved.noteCommitProgress?.contains(where: {
            $0.intent == prepared.intent && $0.phase == .started
        }) == true else {
            throw NoteLocalDivergenceEvidenceStoreError.corruptArchive
        }
        saved.noteCommitProgress = saved.noteCommitProgress?.map {
            $0.intent == prepared.intent
                ? NoteLocalDivergenceNoteCommitProgress(
                    intent: prepared.intent, phase: .noteSaved
                ) : $0
        }
        try saveEnvelope(saved)
        return changed
    }

    func noteCommitPhase(
        for noteID: UUID
    ) throws -> NoteLocalDivergenceNoteCommitPhase? {
        try loadEnvelope().noteCommitProgress?.first {
            $0.intent.noteID == noteID
        }?.phase
    }

    /// Only a zero-operation owner choice with no note-specific pending queue
    /// work can complete without rewriting queue ownership. Other cases keep
    /// their original queues, prepared operations, and global sync barrier.
    /// The caller supplies the suspended coordinator's fresh health-checked
    /// note-specific ownership preflight; this actor never clears queues.
    func finalizePreparedCleanQueueResolution(
        for snapshot: NoteLocalDivergenceSnapshot,
        checkedBy migrator: NoteSequenceStateBootstrapMigrator,
        verifyQueueOwnership: @MainActor () async throws -> Void
    ) async throws -> Bool {
        let preflight = try loadEnvelope()
        guard let index = preflight.snapshots.firstIndex(of: snapshot),
              let queue = (preflight.queuePreparations ?? []).first(where: {
                  $0.intent.noteID == snapshot.noteID && $0.intent.evidenceIndex == index
              }),
              let prepared = (preflight.commitPreparations ?? []).first(where: {
                  $0.intent == queue.intent
              }),
              (preflight.noteCommitProgress ?? []).contains(where: {
                  $0.intent == prepared.intent && $0.phase == .noteSaved
              }) else {
            throw NoteLocalDivergenceEvidenceStoreError.unresolvedResolutionIntent
        }
        guard prepared.intent.choice == .keepAnchoredHistory,
              prepared.capturedChanges.isEmpty else {
            throw NoteLocalDivergenceEvidenceStoreError.unresolvedCapturedResolutionChanges
        }
        if (preflight.completionReceipts ?? []).contains(where: {
            $0.intent == prepared.intent
        }) {
            return false
        }

        try await verifyQueueOwnership()
        // The commit must be physically present in SwiftData, including raw
        // CRDT bytes and marks. No replay or implicit replacement is allowed.
        _ = try migrator.applyPreparedNoteCommit(
            prepared, expected: snapshot, allowMutation: false
        )
        var current = try loadEnvelope()
        guard current == preflight else {
            throw NoteLocalDivergenceEvidenceStoreError.conflictingQueueOwnership
        }
        current.completionReceipts = (current.completionReceipts ?? []) + [
            NoteLocalDivergenceCompletionReceipt(intent: prepared.intent)
        ]
        try saveEnvelope(current)
        return true
    }

    /// Any unfinished intent requires queue/authority recovery before sync is
    /// admitted, even if the note body happens to match its anchored history.
    /// Errors remain distinct from an empty ledger and must fail closed.
    func hasUnfinishedResolutionIntents() throws -> Bool {
        try !unfinishedResolutionNoteIDs().isEmpty
    }

    /// Read before startup migration. A note with an unfinished intent is
    /// protected even when a partial SwiftData commit made its body match
    /// anchored history; only queue reconciliation may release it.
    func unfinishedResolutionNoteIDs() throws -> Set<UUID> {
        let envelope = try loadEnvelope()
        let completed = Set((envelope.completionReceipts ?? []).map { $0.intent.noteID })
        return Set((envelope.resolutionIntents ?? []).map(\.noteID)).subtracting(completed)
    }


    private func loadEnvelope() throws -> NoteLocalDivergenceEvidenceEnvelope {
        guard fileIO.fileExists(fileURL) else { return .empty }
        do {
            let data = try fileIO.readData(fileURL)
            let envelope = try JSONDecoder().decode(
                NoteLocalDivergenceEvidenceEnvelope.self,
                from: data
            )
            try envelope.validate()
            return envelope
        } catch let error as NoteLocalDivergenceEvidenceStoreError {
            throw error
        } catch is DecodingError {
            throw NoteLocalDivergenceEvidenceStoreError.corruptArchive
        } catch {
            throw NoteLocalDivergenceEvidenceStoreError.persistenceFailed
        }
    }

    private func saveEnvelope(_ expected: NoteLocalDivergenceEvidenceEnvelope) throws {
        try expected.validate()
        do {
            try fileIO.createDirectory(fileURL.deletingLastPathComponent())
            let bytes = try JSONEncoder().encode(expected)
            try fileIO.writeData(bytes, fileURL)
            // Never report durable preservation on a write that cannot be read back
            // with the exact same authorities, including byte-exact mark payloads.
            let persisted = try loadEnvelope()
            guard persisted == expected else {
                throw NoteLocalDivergenceEvidenceStoreError.persistenceFailed
            }
        } catch {
            throw NoteLocalDivergenceEvidenceStoreError.persistenceFailed
        }
    }

    nonisolated private static func defaultFileURL() -> URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return support
            .appendingPathComponent("MyRAM", isDirectory: true)
            .appendingPathComponent("local-divergence-evidence-v1.json")
    }
}

@NoteSequenceStatePersistenceActor
final class NoteSequenceStateBootstrapMigrator {
    private struct LegacyMarkMigrationSnapshot: Sendable {
        let noteID: UUID
        let body: String
        let sequenceRevision: UInt64
        let sequenceState: SyncTextSequenceState
        let sequencePayloadData: Data
        let markFormatVersion: Int
        let markRevision: UInt64
        let markStatePayloadData: Data
        let legacyRichTextContentData: Data?
    }

    private let container: ModelContainer
    private let allowsExistingStateReplacement: Bool
    private let operationIDReserver: any SyncOperationIDReserving
    private let legacyFormattingProjection: NoteLegacyFormattingProjectionOperation
    private let renderDerivedFormattingCache: NoteStructuralFormattingCacheRenderOperation
    private let saveOperation: @Sendable (ModelContext) throws -> Void
    private let beforeEachNote: @Sendable (UUID) throws -> Void

    init(
        container: ModelContainer,
        allowsExistingStateReplacement: Bool = !SyncBatchAnchoredPayloadCapability.isEnabled,
        operationIDReserver: any SyncOperationIDReserving = MyRAMSyncOperationIDAllocator.shared,
        legacyFormattingProjection: @escaping NoteLegacyFormattingProjectionOperation = { _, _ in nil },
        renderDerivedFormattingCache: @escaping NoteStructuralFormattingCacheRenderOperation = { _, _ in nil },
        saveOperation: @escaping @Sendable (ModelContext) throws -> Void = { try $0.save() },
        beforeEachNote: @escaping @Sendable (UUID) throws -> Void = { _ in }
    ) {
        self.container = container
        self.allowsExistingStateReplacement = allowsExistingStateReplacement
        self.operationIDReserver = operationIDReserver
        self.legacyFormattingProjection = legacyFormattingProjection
        self.renderDerivedFormattingCache = renderDerivedFormattingCache
        self.saveOperation = saveOperation
        self.beforeEachNote = beforeEachNote
    }

    func runToCompletion() async throws {
        _ = try await migrate(preservingDivergentStates: false, protectedNoteIDs: [])
    }

    /// The captured note body and its structurally valid anchored sequence are
    /// independent retained authorities until an explicit conflict resolution.
    /// A divergence is not permission to replace either representation.
    func runPreservingDivergentStates(
        protectedNoteIDs: Set<UUID> = []
    ) async throws -> Set<UUID> {
        try await migrate(
            preservingDivergentStates: true, protectedNoteIDs: protectedNoteIDs
        )
    }

    private func migrate(
        preservingDivergentStates: Bool,
        protectedNoteIDs: Set<UUID>
    ) async throws -> Set<UUID> {
        let enumerationContext = ModelContext(container)
        enumerationContext.autosaveEnabled = false
        let noteIDs = try enumerationContext.fetch(FetchDescriptor<Note>())
            .map(\.id)
            .sorted {
                $0.uuidString.lowercased() < $1.uuidString.lowercased()
            }

        let store = SwiftDataNoteSequenceStateStore(container: container)
        var divergentNoteIDs = Set<UUID>()
        for noteID in noteIDs {
            // An interrupted owner-approved commit can temporarily make
            // the visible body match while queued work is still unresolved.
            // Do not run mark migration or any note writer on that authority.
            if protectedNoteIDs.contains(noteID) {
                divergentNoteIDs.insert(noteID)
                continue
            }
            try beforeEachNote(noteID)

            if allowsExistingStateReplacement && !preservingDivergentStates {
                do {
                    _ = try await store.loadOrBootstrapForLegacyMarkMigration(
                        noteID: noteID
                    )
                } catch let error as NoteSequenceStateStoreError {
                    guard error == .corruptState else { throw error }
                    _ = try await store.ensureBootstrapStateForCurrentBody(
                        noteID: noteID
                    )
                }
            } else {
                do {
                    switch try await store.load(noteID: noteID) {
                    case .missing:
                        _ = try await store.loadOrBootstrapForLegacyMarkMigration(
                            noteID: noteID
                        )
                    case .present:
                        break
                    }
                } catch let error as NoteSequenceStateStoreError {
                    guard preservingDivergentStates,
                          error == .corruptState,
                          try hasValidSequenceWithDivergentBody(noteID: noteID) else {
                        throw error
                    }
                    divergentNoteIDs.insert(noteID)
                    continue
                }
            }

            try await migrateStructuralMarksIfNeeded(noteID: noteID)
        }
        return divergentNoteIDs
    }

    /// Read-only capture for an explicitly identified divergent note. Never
    /// converts an unsupported/malformed sequence into a recoverable conflict.
    func validatedDivergenceSnapshot(noteID: UUID) throws -> NoteLocalDivergenceSnapshot? {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        guard let note = try fetchNote(noteID: noteID, in: context),
              let record = try fetchRecord(noteID: noteID, in: context) else {
            return nil
        }
        let sequence = try NoteSequenceStatePersistenceCodec
            .decodeStructurallyValidatedState(record: record, noteID: noteID)
        guard !NoteSequenceStateExactText.matches(sequence.visibleText, note.content) else {
            return nil
        }
        // A text mismatch is not a recoverable local conflict when its paired
        // structural marks are corrupt, unsupported, or inconsistent. Validate
        // the whole authority before preserving it or offering a resolution.
        if record.markFormatVersion == NoteStructuralFormattingPersistence.schemaVersion {
            do {
                _ = try NoteStructuralFormattingPersistence.decode(
                    record: record,
                    pairedWith: sequence
                )
            } catch let error as NoteStructuralFormattingPersistenceError {
                switch error {
                case .unsupportedSchemaVersion(let version):
                    throw NoteSequenceStateStoreError.unsupportedMarkVersion(version)
                case .corruptPayload, .pairedValidationFailed:
                    throw NoteSequenceStateStoreError.corruptMarkState
                }
            }
        } else if record.markFormatVersion == 0 {
            guard record.markRevision == 0,
                  record.markStatePayloadData.isEmpty else {
                throw NoteSequenceStateStoreError.corruptMarkState
            }
        } else {
            throw NoteSequenceStateStoreError.unsupportedMarkVersion(
                record.markFormatVersion
            )
        }
        return NoteLocalDivergenceSnapshot(
            noteID: note.id,
            savedTitle: note.title,
            savedBody: note.content,
            savedRichTextContentData: note.richTextContentData,
            savedIsPinned: note.isPinned,
            savedCreatedAt: note.createdAt,
            savedModifiedAt: note.modifiedAt,
            savedDeletedAt: note.deletedAt,
            savedFolderID: note.folder?.id,
            sequenceVisibleText: sequence.visibleText,
            sequenceFormatVersion: record.formatVersion,
            sequenceRevision: record.revision,
            sequenceVisibleUTF16Count: record.visibleUTF16Count,
            sequenceTombstonedUTF16Count: record.tombstonedUTF16Count,
            sequencePayloadByteCount: record.payloadByteCount,
            sequencePayloadData: record.statePayloadData,
            markFormatVersion: record.markFormatVersion,
            markRevision: record.markRevision,
            markStatePayloadData: record.markStatePayloadData
        )
    }

    /// Detects stale evidence before any future explicit resolution attempt.
    /// In particular, matching visible text alone cannot authorize mutation.
    func revalidateDivergenceSnapshot(_ expected: NoteLocalDivergenceSnapshot) throws -> Bool {
        try validatedDivergenceSnapshot(noteID: expected.noteID) == expected
    }

    /// Derive a complete anchored candidate without rewriting either authority.
    /// Keeping saved text produces replayable anchored operations against the
    /// retained history; keeping history does not invent a local text operation.
    /// The original raw evidence and pending work must be durably preserved
    /// before a separate owner-authorized commit is attempted.
    func makeOwnerResolutionPlan(
        for expected: NoteLocalDivergenceSnapshot,
        choice: NoteLocalDivergenceResolutionChoice
    ) async throws -> NoteLocalDivergenceResolutionPlan {
        guard try revalidateDivergenceSnapshot(expected) else {
            throw NoteLocalDivergenceEvidenceStoreError.staleSnapshot
        }
        let context = ModelContext(container)
        context.autosaveEnabled = false
        guard let record = try fetchRecord(noteID: expected.noteID, in: context) else {
            throw NoteLocalDivergenceEvidenceStoreError.staleSnapshot
        }
        let original = try NoteSequenceStatePersistenceCodec
            .decodeStructurallyValidatedState(
                record: record, noteID: expected.noteID
            )
        let marks: SyncTextMarkState
        if record.markFormatVersion == NoteStructuralFormattingPersistence.schemaVersion {
            marks = try NoteStructuralFormattingPersistence.decode(
                record: record, pairedWith: original
            )
        } else if record.markFormatVersion == 0,
                  record.markRevision == 0,
                  record.markStatePayloadData.isEmpty {
            marks = .empty
        } else {
            throw NoteSequenceStateStoreError.corruptMarkState
        }

        let finalBody: String
        let finalState: SyncTextSequenceState
        let changes: [SyncConvergenceCapturedLocalChange]
        switch choice {
        case .keepAnchoredHistory:
            finalBody = original.visibleText
            finalState = original
            changes = []
        case .keepSavedBody:
            let captured = try await SyncBatchAnchoredLocalCapture.capture(
                noteID: expected.noteID,
                oldBody: original.visibleText,
                newBody: expected.savedBody,
                modifiedAt: expected.savedModifiedAt,
                initialState: original,
                operationIDReserver: operationIDReserver
            )
            finalBody = expected.savedBody
            finalState = captured.finalState
            changes = captured.capturedChanges
        }
        // Do not silently drop or rebuild structural marks when a chosen text
        // would make existing references invalid. Preserve the raw evidence and
        // require a separate explicit formatting reconciliation instead.
        do {
            try marks.validating(against: finalState)
        } catch {
            throw NoteSequenceStateStoreError.corruptMarkState
        }
        guard try revalidateDivergenceSnapshot(expected) else {
            throw NoteLocalDivergenceEvidenceStoreError.staleSnapshot
        }
        return NoteLocalDivergenceResolutionPlan(
            original: expected,
            choice: choice,
            finalBody: finalBody,
            finalState: finalState,
            finalMarkState: marks,
            capturedChanges: changes
        )
    }

    /// The SwiftData portion of a journaled resolution. This must be invoked
    /// only after the owning ledger has recorded an explicit owner decision,
    /// frozen the pending queue preimage and durably marked note commit started.
    /// It never changes queues or resumes sync. The same prepared bytes are
    /// idempotent across a crash between SwiftData save and journal update.
    func applyPreparedNoteCommit(
        _ prepared: NoteLocalDivergenceCommitPreparation,
        expected snapshot: NoteLocalDivergenceSnapshot,
        allowMutation: Bool = true
    ) throws -> Bool {
        guard prepared.intent.noteID == snapshot.noteID,
              prepared.finalMarkStatePayloadData == snapshot.markStatePayloadData,
              prepared.finalBody == (
                prepared.intent.choice == .keepSavedBody
                    ? snapshot.savedBody : snapshot.sequenceVisibleText
              ) else {
            throw NoteLocalDivergenceEvidenceStoreError.conflictingResolution
        }
        let targetRevision: UInt64
        switch prepared.intent.choice {
        case .keepAnchoredHistory:
            targetRevision = snapshot.sequenceRevision
        case .keepSavedBody:
            guard snapshot.sequenceRevision < UInt64.max else {
                throw NoteSequenceStateStoreError.persistenceFailure
            }
            targetRevision = snapshot.sequenceRevision + 1
        }
        let targetRichText: Data? = prepared.intent.choice == .keepSavedBody
            ? snapshot.savedRichTextContentData : nil

        let context = ModelContext(container)
        context.autosaveEnabled = false
        guard let note = try fetchNote(noteID: snapshot.noteID, in: context),
              let record = try fetchRecord(noteID: snapshot.noteID, in: context),
              note.title == snapshot.savedTitle,
              note.isPinned == snapshot.savedIsPinned,
              note.createdAt == snapshot.savedCreatedAt,
              note.modifiedAt == snapshot.savedModifiedAt,
              note.deletedAt == snapshot.savedDeletedAt,
              note.folder?.id == snapshot.savedFolderID,
              record.markFormatVersion == snapshot.markFormatVersion,
              record.markRevision == snapshot.markRevision,
              record.markStatePayloadData == snapshot.markStatePayloadData else {
            throw NoteLocalDivergenceEvidenceStoreError.staleSnapshot
        }

        func matchesTarget(_ note: Note, _ record: NoteSequenceStateRecord) -> Bool {
            note.content == prepared.finalBody &&
                note.richTextContentData == targetRichText &&
                record.formatVersion == snapshot.sequenceFormatVersion &&
                record.revision == targetRevision &&
                record.visibleUTF16Count == prepared.finalSequenceVisibleUTF16Count &&
                record.tombstonedUTF16Count == prepared.finalSequenceTombstonedUTF16Count &&
                record.payloadByteCount == prepared.finalSequencePayloadData.count &&
                record.statePayloadData == prepared.finalSequencePayloadData
        }

        if matchesTarget(note, record) {
            try validateCommittedResolution(record: record, prepared: prepared)
            return false
        }
        // Once a receipt says the note was durably saved, a later unexpected
        // return to its old bytes must not be silently interpreted as a retry.
        guard allowMutation,
              try revalidateDivergenceSnapshot(snapshot) else {
            throw NoteLocalDivergenceEvidenceStoreError.staleSnapshot
        }

        do {
            note.content = prepared.finalBody
            note.richTextContentData = targetRichText
            record.formatVersion = snapshot.sequenceFormatVersion
            record.revision = targetRevision
            record.visibleUTF16Count = prepared.finalSequenceVisibleUTF16Count
            record.tombstonedUTF16Count = prepared.finalSequenceTombstonedUTF16Count
            record.payloadByteCount = prepared.finalSequencePayloadData.count
            record.statePayloadData = prepared.finalSequencePayloadData
            try validateCommittedResolution(record: record, prepared: prepared)
            try saveOperation(context)
        } catch {
            context.rollback()
            throw error
        }

        // The save callback succeeding is not proof that the intended pair
        // became durable. Reopen the store before reporting the note committed.
        let verified = ModelContext(container)
        verified.autosaveEnabled = false
        guard let savedNote = try fetchNote(noteID: snapshot.noteID, in: verified),
              let savedRecord = try fetchRecord(noteID: snapshot.noteID, in: verified),
              matchesTarget(savedNote, savedRecord),
              savedNote.title == snapshot.savedTitle,
              savedNote.isPinned == snapshot.savedIsPinned,
              savedNote.createdAt == snapshot.savedCreatedAt,
              savedNote.modifiedAt == snapshot.savedModifiedAt,
              savedNote.deletedAt == snapshot.savedDeletedAt,
              savedNote.folder?.id == snapshot.savedFolderID,
              savedRecord.markStatePayloadData == snapshot.markStatePayloadData,
              savedRecord.markRevision == snapshot.markRevision,
              savedRecord.markFormatVersion == snapshot.markFormatVersion else {
            throw NoteSequenceStateStoreError.verificationFailure
        }
        try validateCommittedResolution(record: savedRecord, prepared: prepared)
        return true
    }

    private func validateCommittedResolution(
        record: NoteSequenceStateRecord,
        prepared: NoteLocalDivergenceCommitPreparation
    ) throws {
        let sequence = try NoteSequenceStatePersistenceCodec.decodeStructurallyValidatedState(
            record: record, noteID: prepared.intent.noteID
        )
        guard NoteSequenceStateExactText.matches(sequence.visibleText, prepared.finalBody) else {
            throw NoteSequenceStateStoreError.verificationFailure
        }
        if record.markFormatVersion == NoteStructuralFormattingPersistence.schemaVersion {
            _ = try NoteStructuralFormattingPersistence.decode(
                record: record, pairedWith: sequence
            )
        } else if record.markFormatVersion != 0 ||
                  record.markRevision != 0 ||
                  !record.markStatePayloadData.isEmpty {
            throw NoteSequenceStateStoreError.corruptMarkState
        }
    }

    private func hasValidSequenceWithDivergentBody(noteID: UUID) throws -> Bool {
        try validatedDivergenceSnapshot(noteID: noteID) != nil
    }

    private func migrateStructuralMarksIfNeeded(
        noteID: UUID
    ) async throws {
        let snapshot = try loadLegacyMarkMigrationSnapshot(noteID: noteID)

        if snapshot.markFormatVersion == NoteStructuralFormattingPersistence.schemaVersion {
            let context = ModelContext(container)
            guard let record = try fetchRecord(noteID: noteID, in: context) else {
                throw NoteSequenceStateStoreError.expectedRowButRowIsMissing
            }
            do {
                _ = try NoteStructuralFormattingPersistence.decode(
                    record: record,
                    pairedWith: snapshot.sequenceState
                )
            } catch let error as NoteStructuralFormattingPersistenceError {
                switch error {
                case .unsupportedSchemaVersion(let version):
                    throw NoteSequenceStateStoreError.unsupportedMarkVersion(version)
                case .corruptPayload, .pairedValidationFailed:
                    throw NoteSequenceStateStoreError.corruptMarkState
                }
            }
            return
        }

        guard snapshot.markFormatVersion == 0 else {
            throw NoteSequenceStateStoreError.unsupportedMarkVersion(
                snapshot.markFormatVersion
            )
        }
        guard snapshot.markRevision == 0,
              snapshot.markStatePayloadData.isEmpty else {
            throw NoteSequenceStateStoreError.corruptMarkState
        }

        let finalMarkState = try await migratedMarkState(from: snapshot)
        let canonicalPayload: Data
        do {
            canonicalPayload = try NoteStructuralFormattingPersistence.encode(
                state: finalMarkState,
                pairedWith: snapshot.sequenceState
            )
        } catch {
            throw NoteSequenceStateStoreError.corruptMarkState
        }

        let rebuiltCache = try await renderDerivedFormattingCache(
            snapshot.sequenceState,
            finalMarkState
        )

        let context = ModelContext(container)
        context.autosaveEnabled = false
        do {
            guard let note = try fetchNote(noteID: noteID, in: context),
                  let record = try fetchRecord(noteID: noteID, in: context) else {
                throw NoteSequenceStateStoreError.expectedRowButRowIsMissing
            }

            let currentSequence = try NoteSequenceStatePersistenceCodec
                .decodeStructurallyValidatedState(
                    record: record,
                    noteID: noteID
                )
            guard record.revision == snapshot.sequenceRevision,
                  record.statePayloadData == snapshot.sequencePayloadData,
                  currentSequence == snapshot.sequenceState,
                  NoteSequenceStateExactText.matches(note.content, snapshot.body),
                  record.markFormatVersion == snapshot.markFormatVersion,
                  record.markRevision == snapshot.markRevision,
                  record.markStatePayloadData == snapshot.markStatePayloadData,
                  note.richTextContentData == snapshot.legacyRichTextContentData else {
                throw NoteSequenceStateStoreError.verificationFailure
            }

            let (nextMarkRevision, overflow) = record.markRevision
                .addingReportingOverflow(1)
            guard !overflow else {
                throw NoteSequenceStateStoreError.markRevisionExhaustion
            }

            record.markFormatVersion =
                NoteStructuralFormattingPersistence.schemaVersion
            record.markRevision = nextMarkRevision
            record.markStatePayloadData = canonicalPayload
            note.richTextContentData = rebuiltCache

            do {
                try saveOperation(context)
            } catch {
                context.rollback()
                throw NoteSequenceStateStoreError.persistenceFailure
            }
        } catch let error as NoteSequenceStateStoreError {
            if context.hasChanges {
                context.rollback()
            }
            throw error
        } catch {
            if context.hasChanges {
                context.rollback()
            }
            throw NoteSequenceStateStoreError.persistenceFailure
        }

        try verifyCommittedMigration(
            snapshot: snapshot,
            expectedMarkState: finalMarkState,
            expectedPayload: canonicalPayload,
            expectedCache: rebuiltCache
        )
    }

    private func loadLegacyMarkMigrationSnapshot(
        noteID: UUID
    ) throws -> LegacyMarkMigrationSnapshot {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        guard let note = try fetchNote(noteID: noteID, in: context),
              let record = try fetchRecord(noteID: noteID, in: context) else {
            throw NoteSequenceStateStoreError.expectedRowButRowIsMissing
        }
        let sequence = try NoteSequenceStatePersistenceCodec
            .decodeStructurallyValidatedState(
                record: record,
                noteID: noteID
            )
        guard NoteSequenceStateExactText.matches(
            sequence.visibleText,
            note.content
        ) else {
            throw NoteSequenceStateStoreError.corruptState
        }

        return LegacyMarkMigrationSnapshot(
            noteID: noteID,
            body: note.content,
            sequenceRevision: record.revision,
            sequenceState: sequence,
            sequencePayloadData: record.statePayloadData,
            markFormatVersion: record.markFormatVersion,
            markRevision: record.markRevision,
            markStatePayloadData: record.markStatePayloadData,
            legacyRichTextContentData: note.richTextContentData
        )
    }

    private func migratedMarkState(
        from snapshot: LegacyMarkMigrationSnapshot
    ) async throws -> SyncTextMarkState {
        guard let legacyData = snapshot.legacyRichTextContentData,
              let projection = await legacyFormattingProjection(
                legacyData,
                snapshot.body
              ),
              NoteSequenceStateExactText.matches(
                projection.plainText,
                snapshot.body
              ),
              NoteSequenceStateExactText.matches(
                projection.plainText,
                snapshot.sequenceState.visibleText
              ) else {
            return .empty
        }

        do {
            return try await NoteStructuralFormattingEditPlanner.prepare(
                sequence: snapshot.sequenceState,
                currentMarkState: .empty,
                desiredProjection: projection,
                operationIDReserver: operationIDReserver
            ).finalMarkState
        } catch is NoteStructuralFormattingEditPlannerError {
            return .empty
        } catch is SyncTextSequenceStateError {
            return .empty
        }
    }

    private func verifyCommittedMigration(
        snapshot: LegacyMarkMigrationSnapshot,
        expectedMarkState: SyncTextMarkState,
        expectedPayload: Data,
        expectedCache: Data?
    ) throws {
        let context = ModelContext(container)
        guard let note = try fetchNote(noteID: snapshot.noteID, in: context),
              let record = try fetchRecord(noteID: snapshot.noteID, in: context),
              record.revision == snapshot.sequenceRevision,
              record.statePayloadData == snapshot.sequencePayloadData,
              record.markFormatVersion ==
                NoteStructuralFormattingPersistence.schemaVersion,
              record.markRevision == 1,
              record.markStatePayloadData == expectedPayload,
              note.richTextContentData == expectedCache else {
            throw NoteSequenceStateStoreError.verificationFailure
        }

        let sequence = try NoteSequenceStatePersistenceCodec
            .decodeStructurallyValidatedState(
                record: record,
                noteID: snapshot.noteID
            )
        let marks: SyncTextMarkState
        do {
            marks = try NoteStructuralFormattingPersistence.decode(
                record: record,
                pairedWith: sequence
            )
        } catch {
            throw NoteSequenceStateStoreError.verificationFailure
        }
        guard sequence == snapshot.sequenceState,
              marks == expectedMarkState,
              NoteSequenceStateExactText.matches(
                note.content,
                snapshot.body
              ) else {
            throw NoteSequenceStateStoreError.verificationFailure
        }
    }

    private func fetchNote(
        noteID: UUID,
        in context: ModelContext
    ) throws -> Note? {
        let requestedNoteID = noteID
        var descriptor = FetchDescriptor<Note>(
            predicate: #Predicate { $0.id == requestedNoteID }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func fetchRecord(
        noteID: UUID,
        in context: ModelContext
    ) throws -> NoteSequenceStateRecord? {
        let requestedNoteID = noteID
        var descriptor = FetchDescriptor<NoteSequenceStateRecord>(
            predicate: #Predicate { $0.noteID == requestedNoteID }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}
