# MYR-132 PR 2 Design Checkpoint

Status: checkpoint ready for review; implementation and the proposed frozen-handoff amendment still require explicit approval.

Authoritative sources:

- `docs/MYR-132-frozen-handoff.md`
- `docs/MYR-132-PR1-remediation.md`
- Merged PR 1 code and tests, including `SyncBatchPayload.swift`, `FileBackedSyncBatchQueue.swift`, `SyncBatchSeenBatchStore.swift`, `IPhoneSyncBatchApplier.swift`, `MacSyncBatchApplier.swift`, `MacSyncBatchController.swift`, `NotesViewModel.swift`, `SyncBatchPayloadCompatibilityTests.swift`, `IPhoneSyncBatchApplierTests.swift`, and `MacSyncBatchControllerTests.swift`

This checkpoint preserves the frozen 20-item structure from `docs/MYR-132-frozen-handoff.md`. It resolves PR 2 architecture only. It does not authorize implementation, branch creation, pushing, pull-request work, production capability changes, or edits to `docs/MYR-132-frozen-handoff.md`.

## Global Decisions

- Every incoming batch uses one SwiftData-authoritative incorporation path in PR 2, including matching-base hashed operations, reconstructable mismatches, legacy hash-less operations, title-only batches, and multi-note batches.
- A successful SwiftData save is the authoritative incorporation commit.
- `SyncBatchBodyHashCapability.defaultEnabled == false` remains in effect throughout PR 2. Hashed body-operation emission and mismatch refusal remain gated until PR 3 is available, unless a separate release decision explicitly accepts persistent note-scoped stalls caused by unreconstructable replacement-derived bases.
- PR 2 may implement and test reconstruction, deterministic merge, blocked-batch upgrade handling, and hash-aware convergence under controlled tests. PR 2 does not authorize enabling hashed body-operation emission in production.
- Queue deletion, legacy seen-store writes, and presentation verification are post-commit work.
- Presentation work required by an incorporation is recorded as pending in the same authoritative save; clearing that pending state is idempotent follow-up work.
- Legacy seen stores never cause a batch to be skipped or reapplied.
- Matching-base selected-note body changes still use incremental editor routing, but only inside the SwiftData-authoritative path.
- Conflict merge results use the MYR-131 whole-note fallback reload path.
- The outer convergence transaction acquires scoped no-echo suppression before managed mutation and before `context.save()`. Suppression remains active through save observation, presentation, refresh, RTF handling, revision updates, and editor verification.
- History capacity is calculated during immutable planning before authoritative mutation.
- Queue enqueue failures, convergence transaction outcomes, post-commit pending work, presentation retry, and durable diagnostics are separate outcome domains.
- iOS 17 and macOS 14 compatibility requires synthetic unique keys instead of unsupported composite uniqueness or index declarations.
- Transactionally significant evidence payloads are explicitly classified as authoritative, derived and rebuildable, independently protected evidence, or ephemeral/presentation-only state. No semantic fact may have two authoritative persisted representations.
- `operationIndex` is the global zero-based position in the transport batch's flat `changes` array. It is unique within the batch across all notes and is used consistently by replay keys, persistence keys, digest payloads, and operation identities.
- Canonical incorporation digests are load-bearing evidence. The incoming-batch payload digest and committed-result digest use explicit versioned normalized payloads, a custom versioned length-prefixed canonical binary byte format, shared PR 1 SHA-256, exact ordering-significant date bit patterns, stable numeric discriminator domains, explicit optional absence semantics, and golden byte/hash vectors. They never hash raw transport JSON bytes or mutable post-commit state.
- One digest format version uniquely identifies the complete immutable digest contract: normalized semantic schema, field order, primitive encoding, enum discriminator assignments, optional encoding, collection ordering, date representation, canonical byte generation, and SHA-256 hexadecimal representation. A format-version bump is required whenever any of those rules changes. There is no separately persisted encoder-version axis in PR 2.
- Duplicate comparison dispatches on the digest format version already stored in the full record or tombstone. Historical digest-format implementations are compatibility code while that format can exist in persisted full records or tombstones. Unsupported stored digest formats block safely as `.failedBeforeCommit(.unsupportedDigestFormat(...))` without reapplication or false contradiction.
- `IncorporatedSyncBatch.canonicalPayloadDigest` and `IncorporatedBatchTombstone.canonicalPayloadDigest` are the same computed value. Compaction copies the digest and digest-format version from the full record; it never recomputes old digests from compacted, incomplete, mutable, or lossy evidence.
- Full incorporation evidence means the root `IncorporatedSyncBatch` plus every exclusive note-effect, operation-identity, body/title/creation-result, blocking-reference, reconciliation-candidate, and contradiction-diagnostic child record attributable only to that incorporation. It compacts atomically to one fixed-size tombstone in one SwiftData save after all protection clears.
- Permanent fixed-size incorporation tombstones are a proposed frozen-handoff amendment and remain blocked until explicitly approved.

## 1. SwiftData history, incorporation, title-winner, and episode models

**Frozen requirement**
PR 2 must move authoritative convergence state into SwiftData: snapshots, retained local operations, retained incorporated remote operations, reconstruction metadata, incorporated batch IDs, ordering metadata, winning title key, compaction state, and PR 3 episode state.

**Repository evidence**
`PersistenceManager.swift` currently creates a schema containing only `Folder`, `Note`, `NotePhotoAttachment`, and `PinnedThought`. `SyncBatchSeenBatchStore.swift` stores seen batch IDs in `UserDefaults`. `MacSyncSeenBatchStore.swift` is a typealias to the same store. `SyncBatchPayload.swift` contains optional PR 1 hash and ordering metadata but no authoritative SwiftData convergence models.

**Ratified decision**
Add SwiftData models with single-column synthetic unique keys.

`NoteContentSnapshot`

- `snapshotKey: String` with `@Attribute(.unique)`, built by `ConvergenceKey.v1Snapshot(noteID:contentHash:)`
- `id: UUID`
- `noteID: UUID`
- `contentHash: String`
- `body: String`
- `bodyUTF8ByteCount: Int`
- `generation: Int`
- `createdAt: Date`
- query predicates use ordinary stored properties: `noteID`, `contentHash`, `generation`

`RetainedBodyOperation`

- `operationKey: String` with `@Attribute(.unique)`, built by `ConvergenceKey.v1Operation(batchID:operationIndex:)`
- `id: UUID`
- `noteID: UUID`
- `batchID: UUID`
- `originDeviceID: UUID`
- `operationIndex: Int`
- `operationKindRaw: String` with values `insert` or `delete`
- `utf16Offset: Int`
- `utf16Length: Int?`
- `text: String?`
- `expectedText: String?`
- `baseContentHash: String?`
- `resultContentHash: String?`
- `modifiedAt: Date`
- `modifiedAtBitPattern: UInt64`; authoritative ordering identity for `modifiedAt`
- `canonicalReplayKeyPayload: CanonicalReplayKeyPayload`
- `sourceRaw: String` with values `local` or `remote`
- `payloadUTF8ByteCount: Int`

`IncorporatedSyncBatch`

- `batchKey: String` with `@Attribute(.unique)`, built by `ConvergenceKey.v1Batch(batchID:)`; authoritative identity
- `id: UUID`; storage identity only
- `batchID: UUID`; authoritative identity
- `originDeviceID: UUID`; authoritative origin identity
- `createdAt: Date`; display/debug convenience, not ordering or identity authority
- `createdAtBitPattern: UInt64`; authoritative batch timestamp identity
- `batchSequence: UInt64?`; authoritative sequence metadata
- `schemaVersion: Int`; authoritative schema metadata
- `committedAt: Date`; display/debug convenience, not ordering or identity authority
- `committedAtBitPattern: UInt64`; authoritative committed timestamp identity
- `canonicalPayloadDigest: String`; authoritative semantic digest, lowercase 64-character SHA-256 hexadecimal
- `canonicalPayloadDigestFormatVersion: Int`; authoritative digest format version
- `committedResultDigest: String`; authoritative committed-effect digest, lowercase 64-character SHA-256 hexadecimal
- `committedResultDigestFormatVersion: Int`; authoritative digest format version
- `affectedNotesPayload: AffectedNotesPayload`; derived, non-authoritative, rebuildable affected-note summary used only for bounded lookup, routing, accounting, and validation
- `authoritativeChildCount: Int`; derived, non-authoritative, rebuildable summary
- `authoritativeChildBytes: Int`; derived, non-authoritative, rebuildable summary counted only as root bytes
- `authoritativeChildrenDigest: String`; derived, non-authoritative, rebuildable aggregate digest of authoritative children for validation
- `postCommitStatePayload: PostCommitStatePayload`; authoritative post-commit cleanup and presentation state, excluded from semantic digests

The root is authoritative only for batch ID and synthetic batch key, origin-device identity, schema and sequence metadata, canonical payload digest and digest-format version, committed-result digest and digest-format version, committed timestamp evidence, post-commit cleanup and presentation state, and stable relationships or keys used to locate authoritative child evidence. It must not contain independent authoritative copies of operation identities, per-note body results, per-note title results, note-creation results, affected-note membership, blocking references, reconciliation candidates, or contradiction evidence.

`IncorporatedBatchTombstone`

- `tombstoneKey: String` with `@Attribute(.unique)`, built by `ConvergenceKey.v1BatchTombstone(batchID:)`
- `id: UUID`
- `batchID: UUID`
- `originDeviceID: UUID`
- `canonicalPayloadDigest: String`
- `canonicalPayloadDigestFormatVersion: Int`
- `schemaVersion: Int`
- `committedResultDigest: String`
- `committedResultDigestFormatVersion: Int`
- `committedAtOrderingPayload: CommittedAtOrderingPayload`
- `tombstoneFormatVersion: Int`
- fixed maximum encoded size: 512 bytes

`IncorporatedBatchNoteEffect`

- `effectKey: String` with `@Attribute(.unique)`, built by `ConvergenceKey.v1BatchNoteEffect(batchID:noteID:)`
- `id: UUID`
- `batchID: UUID`
- `noteID: UUID`
- `preBodyHash: String?`
- `postBodyHash: String?`
- `preTitleKeyPayload: CanonicalReplayKeyPayload?`
- `postTitleKeyPayload: CanonicalReplayKeyPayload?`

`IncorporatedBatchNoteEffect`, together with corresponding result children, owns the authoritative affected-note membership for an incorporated batch. `affectedNotesPayload` in the root is a derived summary only. The canonical payload and committed-result digests independently commit to affected-note semantics, but digest values do not replace queryable authoritative child records.

`IncorporatedBatchOperationIdentity`

- `identityKey: String` with `@Attribute(.unique)`, built by `ConvergenceKey.v1BatchOperationIdentity(batchID:operationIndex:)`
- `id: UUID`
- `batchID: UUID`
- `noteID: UUID`
- `operationIdentityPayload: OperationIdentityPayload`
- `canonicalReplayKeyPayload: CanonicalReplayKeyPayload`
- `payloadUTF8ByteCount: Int`

`IncorporatedBatchOperationIdentity` owns authoritative operation identities. Its `identityKey` uses `(batchID, operationIndex)`. `noteID` is descriptive and queryable evidence only; it is not part of uniqueness. If stored `noteID` disagrees with the indexed flat-array change, the record is corrupt history, not a parallel identity namespace.

`IncorporatedBatchResultEvidence`

- `resultEvidenceKey: String` with `@Attribute(.unique)`, built by `ConvergenceKey.v1BatchResultEvidence(batchID:noteID:kind:)`
- `id: UUID`
- `batchID: UUID`
- `noteID: UUID`
- `resultKindRaw: String` with values `body`, `title`, or `creation`
- `bodyResultEvidencePayload: BodyResultEvidencePayload?`
- `titleResultEvidencePayload: TitleResultEvidencePayload?`
- `creationResultEvidencePayload: CreationResultEvidencePayload?`
- `payloadUTF8ByteCount: Int`

`IncorporatedBatchResultEvidence` owns authoritative body, title, and note-creation result evidence.

`IncorporationBlockingReference`

- `blockingReferenceKey: String` with `@Attribute(.unique)`, built by `ConvergenceKey.v1IncorporationBlockingReference(batchID:blockingBatchID:noteID:)`
- `id: UUID`
- `batchID: UUID`
- `blockingBatchID: UUID`
- `noteID: UUID`
- `blockingBatchReference: BlockingBatchReference`
- `payloadUTF8ByteCount: Int`

`IncorporationBlockingReference` owns incorporation-scoped blocking evidence only when that evidence is not independently owned by durable note diagnostics.

`IncorporationContradictionDiagnostic`

- `contradictionKey: String` with `@Attribute(.unique)`, built by `ConvergenceKey.v1IncorporationContradiction(batchID:noteID:)`
- `id: UUID`
- `batchID: UUID`
- `noteID: UUID?`
- `diagnosticEvidencePayload: DiagnosticEvidencePayload`
- `payloadUTF8ByteCount: Int`

`IncorporationContradictionDiagnostic` owns authoritative variable contradiction evidence unless a separate durable diagnostic owner protects the same evidence.

`NoteTitleWinner`

- `titleWinnerKey: String` with `@Attribute(.unique)`, built by `ConvergenceKey.v1TitleWinner(noteID:)`
- `id: UUID`
- `noteID: UUID`
- `title: String`
- `canonicalReplayKeyPayload: CanonicalReplayKeyPayload`
- `operationIdentityPayload: OperationIdentityPayload`
- `updatedAt: Date`; display/debug convenience only
- `updatedAtBitPattern: UInt64`; authoritative update ordering identity when equality or ordering is needed

`NoteHistoryCompactionState`

- `compactionKey: String` with `@Attribute(.unique)`, built by `ConvergenceKey.v1Compaction(noteID:)`
- `id: UUID`
- `noteID: UUID`
- `oldestRetainedGeneration: Int`
- `newestRetainedGeneration: Int`
- `retainedOperationCount: Int`
- `retainedOperationBytes: Int`
- `retainedSnapshotCount: Int`
- `retainedSnapshotBytes: Int`
- `fullIncorporationEvidenceBytes: Int`
- `episodeEvidenceBytes: Int`
- `diagnosticEvidenceBytes: Int`
- `cleanupEvidenceBytes: Int`
- `pressureStateRaw: String?`
- `updatedAt: Date`

`ConvergenceNoteDiagnosticState`

- `diagnosticKey: String` with `@Attribute(.unique)`, built by `ConvergenceKey.v1Diagnostic(noteID:)`
- `id: UUID`
- `noteID: UUID`
- `statusRaw: String`
- `blockingReferenceCount: Int`; derived summary only
- `diagnosticEvidencePayload: DiagnosticEvidencePayload`
- `createdAt: Date`
- `createdAtBitPattern: UInt64`
- `updatedAt: Date`
- `updatedAtBitPattern: UInt64`

`ConvergenceBlockingBatchReference`

- `blockingReferenceKey: String` with `@Attribute(.unique)`, built by `ConvergenceKey.v1DiagnosticBlockingReference(noteID:blockingBatchID:affectedNoteID:)`
- `id: UUID`
- `noteID: UUID`
- `blockingBatchID: UUID`
- `affectedNoteID: UUID`
- `originDeviceID: UUID`
- `queuePosition: Int`
- `blockingBatchReferencePayload: BlockingBatchReference`
- `payloadUTF8ByteCount: Int`

`ConvergenceBlockingBatchReference` owns queryable diagnostic blocking evidence. `ConvergenceNoteDiagnosticState.blockingReferenceCount` is a derived summary and is rebuildable from child records.

`ReconciliationEpisode`

- `episodeKey: String` with `@Attribute(.unique)`, built by `ConvergenceKey.v1Episode(noteID:generation:)`
- `id: UUID`
- `noteID: UUID`
- `generation: Int`
- `stateRaw: String` with values `unresolved` or `completed`
- `logicalGroupingPayload: EpisodeGroupingPayload`
- `didEmitLocalCandidate: Bool`
- `freshAgreedHash: String?`
- `completedAt: Date?`
- `completedAtBitPattern: UInt64?`

`ReconciliationCandidateRecord`

- `candidateKey: String` with `@Attribute(.unique)`, built by `ConvergenceKey.v1ReconciliationCandidate(noteID:generation:candidateIdentity:)`
- `id: UUID`
- `noteID: UUID`
- `generation: Int`
- `candidateRoleRaw: String` with values `local`, `peer`, or `winner`
- `candidateIdentity: String`
- `candidateEvidence: ReconciliationCandidateEvidence`
- `payloadUTF8ByteCount: Int`

`ReconciliationCompletionEvidenceRecord`

- `completionEvidenceKey: String` with `@Attribute(.unique)`, built by `ConvergenceKey.v1ReconciliationCompletionEvidence(noteID:generation:kind:)`
- `id: UUID`
- `noteID: UUID`
- `generation: Int`
- `kindRaw: String` with values `receivingCompletion` or `emitterSelfCompletion`
- `receivingCompletionEvidence: ReceivingCompletionEvidencePayload?`
- `emitterSelfCompletionEvidence: EmitterSelfCompletionEvidencePayload?`
- `payloadUTF8ByteCount: Int`

Reconciliation candidates and completion evidence are child records because PR 3 must query, deduplicate, protect, release, and compact individual candidates and completion evidence independently.

Query acceleration uses stored fields and bounded result sizes, not unsupported SwiftData index promises. Fetch-before-insert is not the sole correctness mechanism; synthetic keys are unique, deterministic, versioned, and migrated deterministically. Duplicate same-evidence records are idempotent; duplicate contradictory authoritative evidence fails closed as `.failedBeforeCommit(.inconsistentIncorporationState(noteID: ...))`. Key decoding, derived-summary mismatch with valid authoritative children, or unsupported non-incorporation payload versions are `.failedBeforeCommit(.corruptHistory(noteID: ...))`.

Duplicate comparison uses stored-version dispatch, not per-batch migration records. When a delayed duplicate arrives, the service reads the stored digest and stored format version, selects the historical digest implementation identified by that format version, computes the incoming batch digest under that exact version, and compares like-for-like. A matching digest is an identical duplicate and may run cleanup or presentation retry only. A different digest under the same supported stored format version is inconsistent incorporation and fails closed. An unsupported stored format version is `.failedBeforeCommit(.unsupportedDigestFormat(noteID:batchID:formatVersion:))`; no authoritative application occurs, the queue entry and unseen state remain, affected-note work is blocked, unrelated disjoint-note progress may continue, and the full record or tombstone is not deleted or rewritten. Old tombstone digests are never recomputed or rewritten merely because a newer format exists.

**Implementation consequence**
Every successfully applied incoming batch creates an `IncorporatedSyncBatch`, including matching-base, legacy hash-less, title-only, note-creation, and multi-note batches. Full incorporation evidence compacts to a permanent fixed-size tombstone after all protection sources clear. The permanent tombstone ledger requires the proposed frozen-handoff amendment before implementation.

**Required tests**
Model persistence and relaunch, synthetic key determinism, key collision resistance across valid inputs, duplicate same-evidence idempotency, duplicate contradictory authoritative evidence fail-closed, deterministic migration from absent synthetic keys, byte-stable evidence payload round trips, affected-note membership has one authoritative owner, root affected-note summary is derived and rebuildable, derived-summary mismatch is corrupt history rather than inconsistent incorporation, full root-plus-exclusive-child record compaction to tombstone, tombstone fixed-size enforcement, tombstone duplicate skip, tombstone contradictory collision, full record and tombstone carry identical payload digest and digest-format version, unsupported digest versions block safely without false contradiction, historical digest-format implementation retention, and prohibition on variable-sized tombstone evidence.

## 2. dedicated `ModelContext` and autosave policy

**Frozen requirement**
Use a dedicated convergence context where feasible, disable autosave where supported, refetch objects into that context, build immutable state before mutation, save once, and provide equivalent iPhone and Mac rollback.

**Repository evidence**
`IPhoneSyncBatchApplier` mutates its supplied `ModelContext` directly and then marks a legacy seen store. `MacSyncBatchApplier` mutates its supplied context but adds manual rollback snapshots. `NotesViewModel` and `MacSyncBatchController` already serialize drain entry with reentrancy flags added by PR 1 remediation.

**Ratified decision**
Create `SyncConvergenceService`, `@MainActor`, owned by `NotesViewModel` on iPhone and `MacSyncBatchController` on native Mac. Each drain transaction creates one fresh `ModelContext` from the app `ModelContainer`, sets `autosaveEnabled = false`, refetches all required managed records by stable IDs, applies one validated immutable plan under suppression, saves once, and discards the context.

All incoming batches route through this service in PR 2. Matching-base and legacy application may choose an incremental body-apply mode, but incorporation and idempotency do not bypass SwiftData convergence records.

Planning input is copied into immutable structs before mutation. Concurrent drains are serialized by the controller admission flag and a service-level transaction guard. Context creation, fetch, and save failures produce pre-commit transaction failures and do not persist diagnostic state in the failing store.

The outer convergence transaction acquires a scoped suppression token immediately before managed mutation and before `context.save()`. Suppression remains active through authoritative context mutation, save, main/editor-context observation, selected-note incremental application, whole-note fallback reload, non-selected-note refresh, RTF clearing or regeneration, revision-counter updates, and editor-content verification.

For every commit requiring presentation, `PostCommitStatePayload.presentationRefreshPending` is set to `true` in the authoritative save together with affected note IDs, committed body hashes, committed title evidence where relevant, required routing category, whether whole-note fallback is required, and durable presentation-verification evidence. After successful suppressed presentation and verification, a follow-up idempotent save clears the pending flag.

**Implementation consequence**
iPhone receives Mac-equivalent rollback by avoiding authoritative main-context mutation before validation. Save-triggered observation cannot echo because suppression is already active. Crash after commit before presentation leaves presentation pending for retry without reapplying the batch.

**Required tests**
Concurrent drains cannot interleave one note's transaction, save failure leaves no authoritative mutation and releases suppression, save-triggered observation occurs under suppression, `@Query` and main-context refresh cannot emit outgoing capture, nested rejection cannot clear the outer token, refresh-only retry acquires a new token, presentation pending is written in the authoritative commit, crash before presentation survives relaunch, pending-clear save failure is harmless, and iPhone/Mac guarantees match.

## 3. immutable merge-plan representation

**Frozen requirement**
Build a complete immutable merge plan before managed mutation. Invalid plans apply nothing.

**Repository evidence**
`SyncBatchDrainCoordinator` currently applies each first queued batch directly and removes it after apply succeeds. There is no plan object.

**Ratified decision**
Create `SyncConvergencePlan` with candidate complete batch IDs, already incorporated cleanup-only batch IDs, deferred complete batch IDs, affected note IDs derived from authoritative note-effect/result children or the incoming flat changes array before commit, reconstructed bases, operation unions, final bodies/hashes, title decisions, snapshots, retained operations, incorporation records, diagnostics, post-commit state, presentation plan, cleanup plans, projected post-compaction history state, and validation digest.

The plan contains projected post-commit snapshot count, operation count, snapshot bytes, operation bytes, full incorporation evidence bytes, episode evidence bytes, diagnostic evidence bytes, cleanup evidence bytes, tombstone creation or verification actions, root records to delete, exclusive child records to delete, protected child records to preserve, before/after per-note byte accounting, expected payload and result digests, authoritative child counts/bytes/digest, derived summary validation, contradiction checks, protected-record calculations, final retained state, and a validation digest. Validation rejects before mutation if final projected retained state exceeds hard limits or if any plan would partially incorporate one transport batch.

Compaction planning is safe to retry after any failed pre-save attempt. A compaction plan must identify every child model as exclusively owned full incorporation evidence, independently protected reconstruction history, independently protected diagnostic evidence, independently protected episode evidence, or shared evidence referenced by multiple incorporation records. Cascading delete rules are disallowed unless the implementation proves they cannot delete independently protected evidence.

**Implementation consequence**
Compaction and tombstone eligibility are planned before authoritative mutation. Invalid plans apply nothing, delete nothing, and do not route editor presentation.

**Required tests**
Invalid plan applies nothing, projected post-commit size is validated before save, hard-limit overflow defers before mutation, full evidence does not grow indefinitely, protected full incorporation records do not compact prematurely, affected-note selection uses authoritative child membership for persisted incorporations, compaction plans include root and every exclusive child, preserved child classifications are honored, compaction validation digest is byte-stable, derived summaries reconstruct from authoritative children, and every invalidity category is rejected deterministically.

## 4. authoritative incorporated-batch record

**Frozen requirement**
SwiftData incorporation records are authoritative. Queue deletion is cleanup, not commit.

**Repository evidence**
Current application checks `seenBatchStore.hasSeen` before applying and calls `markSeen` after `context.save()`. That legacy-only authority is unsafe after PR 2.

**Ratified decision**
`IncorporatedSyncBatch.batchKey` derived from `batchID` is the authoritative root identity while protection sources exist. Origin device, created date, sequence, canonical payload digest plus digest-format version, committed-result digest plus digest-format version, schema evidence, and committed timestamp evidence live on the root. Operation identities, affected-note membership, body/title/creation results, blocking references, reconciliation candidates, and variable contradiction evidence live in normalized authoritative children. A batch ID collision with different comparable authoritative semantic evidence is `.failedBeforeCommit(.inconsistentIncorporationState(noteID: ...))`. A derived-root-summary mismatch with internally valid authoritative children and digests is `.failedBeforeCommit(.corruptHistory(noteID: ...))` and may be safely rebuilt from those children.

After full-evidence protection sources clear, compact the root `IncorporatedSyncBatch` and every exclusive full-evidence child into `IncorporatedBatchTombstone`. The tombstone stores only fixed-size identity and digest evidence: batch ID, origin device ID, canonical payload digest, canonical payload digest format version, schema version, committed-result digest, committed-result digest format version, committed-at ordering evidence, and tombstone format version. The tombstone prevents delayed duplicate reapplication, skips identical duplicates, and fails closed on contradictory duplicates.

Atomic compaction uses one dedicated plan and one SwiftData save. The transaction must refetch the full incorporation root, refetch every child record owned by or exclusively attributable to it, verify that all protection sources have cleared, validate the root identity and digests, validate every authoritative child, rebuild the authoritative affected-note set from note-effect/result children, validate derived `affectedNotesPayload`, validate child counts, byte totals, and summary digest, repair only safely rebuildable summaries, fail closed on missing or contradictory authoritative children, construct the tombstone by copying the root's existing canonical semantic digests and versions, check for an existing tombstone, verify an existing same-evidence tombstone idempotently, fail closed if an existing tombstone contradicts the full record, insert the tombstone if absent, delete the root full record, delete all unprotected exclusive full-evidence child records, retain any separately protected history, episode, diagnostic, or shared evidence records, update per-note compaction accounting, and save once. A tombstone must not be created in one save while full evidence is deleted in a later save. Compaction must not choose between competing root and child copies because only one authoritative representation may exist.

Dual full-record and tombstone states are defined exactly:

- Same-evidence full record and tombstone: if batch identity, canonical payload digest plus digest-format version, committed-result digest plus digest-format version, origin evidence, schema evidence, and committed ordering evidence match exactly, treat the state as idempotently incomplete. The next compaction attempt may delete the remaining full record and eligible children in one save.
- Contradictory full record and tombstone: if comparable evidence differs, fail closed as `.failedBeforeCommit(.inconsistentIncorporationState(noteID: ...))`, delete neither record, preserve diagnostic evidence, never reapply the batch, and block affected-note work under existing fail-closed rules.
- Tombstone without full record: treat as successfully compacted authoritative incorporation identity.
- Full record without tombstone: treat as uncompacted authoritative full evidence.

Permanent compact tombstone retention is the proposed default because the current protocol has no transport acknowledgement, no globally bounded duplicate-delivery window, and no safe expiry horizon. This is a proposed amendment to the frozen handoff and is not effective until explicitly approved.

**Implementation consequence**
A queued residue after save but before cleanup cannot apply matching-base, legacy, title-only, note-creation, or conflict-merge work twice. Deleting full records and exclusive children is allowed only by atomic compaction to fixed-size tombstones; deleting tombstones is prohibited without a future approved protocol amendment. Rebuilding a derived root summary cannot change canonical payload digest, committed-result digest, full-evidence ownership, or semantic contradiction decisions.

**Required tests**
Matching-base retry after save before queue cleanup does not reapply, legacy seen-only residue cannot skip first incorporation, SwiftData incorporated residue cannot reapply, affected-note membership has one authoritative owner, root `affectedNotesPayload` is derived and rebuildable, root affected-note mismatch is corrupt history rather than inconsistent incorporation, multi-note selection uses authoritative child membership, authoritative child evidence reconstructs every derived summary, no semantic evidence has two authoritative persisted copies, contradictory authoritative children fail closed, full root and every exclusive child compact after queue/presentation/legacy/history protection release, no orphaned `IncorporatedBatchNoteEffect` remains, independently protected history survives compaction, independently protected diagnostics survive compaction, same-evidence dual record is repaired idempotently, contradictory dual record fails closed, tombstone-only state skips delayed duplicate application, full-record-only state remains authoritative, tombstone encoding respects 512-byte limit, tombstones contain no variable-sized evidence, relaunch preserves tombstones, stored-version duplicate comparison preserves tombstone identity and digests, compaction save failure preserves the full record and children, repeated compaction attempts are idempotent, and full-evidence child counts and bytes remain bounded.

## 5. post-commit queue cleanup

**Frozen requirement**
Remove committed queue entries only after the SwiftData save. Cleanup failure cannot cause reapplication.

**Repository evidence**
`FileBackedSyncBatchQueue.remove` persists deletion best-effort. The queue stores complete `SyncBatch` values.

**Ratified decision**
Only complete incorporated batch IDs are cleanup-eligible. Queue cleanup failure is post-commit pending work, represented by `PostCommitStatePayload.queueCleanupPending`, not by a pre-commit convergence failure. Legacy cleanup failure is represented by `legacyCleanupPending`. Presentation pending is independent and is set during the authoritative commit when presentation work is required.

Queue cleanup may proceed independently of presentation success because incorporation is committed and presentation retry is idempotent. Full incorporation evidence remains protected until queue cleanup, legacy cleanup, presentation verification, retained-history need, episode references, diagnostic references, and contradiction needs have cleared.

**Implementation consequence**
Cleanup retry consults SwiftData first, skips application, and removes only complete incorporated batches. Presentation retry does not block queue cleanup and never replays operations.

**Required tests**
Crash/relaunch after save before cleanup, queue cleanup failure leaves commit authoritative, cleanup retry is idempotent, cleanup never removes partial batch effects, queue cleanup proceeds despite presentation pending, and full records do not compact before cleanup and presentation protections clear.

## 6. iPhone rollback

**Frozen requirement**
Add iPhone rollback and retry guarantees equivalent to native Mac.

**Repository evidence**
Mac has rollback snapshots around mutation; iPhone does not.

**Ratified decision**
All iPhone incoming batch application routes through `SyncConvergenceService` with a dedicated autosave-disabled context and pre-save suppression. The old iPhone applier cannot remain the authoritative path for matching-base or legacy incoming batches in PR 2.

**Implementation consequence**
iPhone never marks only legacy seen state for a successfully applied PR 2 incoming batch. The authoritative save covers body, title, history, diagnostics, incorporation, presentation pending, and post-commit state.

**Required tests**
iPhone save failure leaves body, title, history, diagnostics, presentation state, and incorporation unchanged; suppression releases on save failure; iPhone matching-base application still routes selected-editor updates incrementally after commit under suppression.

## 7. shared convergence-core API

**Frozen requirement**
One platform-neutral core owns convergence policy. Platform adapters own only SwiftData access, editor routing, selected-note refresh, RTF handling, notifications, and user-visible status.

**Repository evidence**
PR 1 already centralizes hash, preflight, ordering, and drain failure classification in shared code. Platform appliers still duplicate mutation policy.

**Ratified decision**
Add a Foundation-only `SyncConvergenceCore` with:

- `selectCandidates(input:) -> SyncConvergenceSelection`
- `plan(input:) -> SyncConvergenceOutcome`
- `validate(plan:) -> SyncConvergenceValidationResult`
- `buildCleanupOnlyPlan(input:) -> SyncConvergenceCleanupPlan`

Adapter-level committed application uses scoped suppression:

```swift
protocol SyncConvergenceApplying {
    func applyCommittedPlan(
        _ plan: SyncConvergenceCommittedPlan,
        under suppression: SyncCaptureSuppressionToken
    ) throws
}
```

The exact protocol name may change, but semantics are fixed: suppression is owned by the outer convergence transaction, starts before managed mutation and save, remains active through save observation and presentation, and is released only by the owner token. A nested or rejected drain cannot clear suppression owned by an outer application. Presentation-only retry reacquires suppression. Applying an incorporated batch a second time is prohibited even when presentation retry is needed.

**Implementation consequence**
No merge, ordering, title, no-echo, candidate-selection, or idempotency policy lives in `NotesViewModel`, `MacSyncBatchController`, or editor views.

**Required tests**
Shared-core candidate and planning tests; no duplicated ordering logic; zero outgoing insert/delete operations; zero outgoing replacement operations; zero newly enqueued sync batches; save observation suppression; matching-base suppression; conflict-merge suppression; selected and non-selected note suppression; nested drain ownership; presentation-only retry suppression; iPhone/Mac parity.

## 8. canonical replay-key representation

**Frozen requirement**
All operation replay and title resolution use one shared canonical representation covering legacy batches, sequenced batches, equal timestamps, equal origins, stable batch IDs, and operation indexes.

**Repository evidence**
`SyncBatchReplayKey` already compares `modifiedAt`, `originDeviceID`, `batchOrder`, `stableBatchID`, and `operationIndex`. `CanonicalBatchOrder` is shared. `SyncBatchPayload.swift` defines one flat `SyncBatch.changes` array and `SyncBatchReplayKey(batch:change:operationIndex:)`. `SyncBatchUnsentQueueTests.swift` and `SyncBatchPayloadCompatibilityTests.swift` construct replay keys from `batch.changes[0]`, `batch.changes[1]`, and explicit operation indexes, confirming the index is the flat-array position and is not scoped per note.

**Ratified decision**
Retain `SyncBatchReplayKey` as the canonical replay and title LWW key. Persist ordering-significant dates by exact runtime comparison identity using `timeIntervalSinceReferenceDate.bitPattern` stored as `UInt64`, not integer milliseconds.

`CanonicalReplayKeyPayload`:

- `version: Int`
- `modifiedAtBitPattern: UInt64`
- `originDeviceIDLowercase: String`
- `batchOrderKind: String`
- `legacyCreatedAtBitPattern: UInt64?`
- `sequence: UInt64?`
- `batchIDLowercase: String`
- `operationIndex: Int`

This bit-pattern representation also applies to candidate replay keys, title-winner canonical keys, operation identity evidence, episode candidate ordering evidence, and completion-ordering evidence where equality matters. Display-only diagnostic dates may use less exact representation only when they do not participate in equality, ordering, identity, hashing, or contradiction detection.

`operationIndex` is the zero-based position of the operation's `SyncBatchChange` in the transport batch's single flat `changes` array. It is global across every note represented by that batch and does not restart for each note. The synthetic operation identity remains `(batchID, operationIndex)`. Do not add `noteID` or a second change index unless a future wire schema introduces nested operation arrays.

Use this same global operation index consistently in `SyncBatchReplayKey`, `RetainedBodyOperation.operationKey`, `IncorporatedBatchOperationIdentity.identityKey`, `OperationIdentityPayload`, canonical payload-digest normalization, committed-result digest normalization, title operation identity, reconstruction history, and duplicate detection. `IncorporatedBatchOperationIdentity.noteID` is descriptive and queryable evidence only. A stored `noteID` that disagrees with the indexed flat-array change is `.failedBeforeCommit(.corruptHistory(noteID: ...))` and must not create a parallel identity namespace.

**Implementation consequence**
Body replay and title LWW cannot diverge by comparator implementation, and persisted replay keys compare the same as pre-persistence runtime keys.

**Required tests**
Sub-millisecond date distinctions survive round trip, replay ordering unchanged after encode/decode, legacy `createdAt` ordering survives round trip, title-winner equality survives round trip, exact duplicate operation remains idempotent, persisted key compared with full-precision incoming key matches pre-persistence comparison, bit-pattern encoding is byte-stable, one multi-note batch has globally unique indexes, note A at index 0 and note B at index 1 produce distinct keys, indexes never restart by note, replay key, retained-operation key, child identity key, and digest payload use the same index, stored noteID disagreement fails as corruption, reordering the flat array changes operation identities and payload digest, and relaunch preserves identities.

## 9. exact mixed legacy/sequenced ordering

**Frozen requirement**
Freeze cross-form comparison. It must be deterministic, identical on both platforms, independent of receive order, independent of local state, and stable across relaunch.

**Repository evidence**
Current `CanonicalBatchOrder` uses a fixed discriminator: legacy sorts before sequenced when earlier replay key fields tie.

**Ratified decision**
Keep current order:

1. `modifiedAt`
2. `originDeviceID`
3. fixed order-kind discriminator, legacy `0`, sequenced `1`
4. type-specific value, legacy `createdAt` plus legacy batch ID or sequenced `batchSequence`
5. stable batch ID
6. operation index

**Implementation consequence**
No date/integer direct comparison and no receiver-synthesized sequence.

**Required tests**
Mixed legacy/sequenced body replay, title LWW, equal timestamps including sub-millisecond differences, equal origin, equal or absent sequence, stable batch ID tie-break, operation index ordering, serialization and relaunch.

## 10. monotonic sequence persistence

**Frozen requirement**
Emitter sequence survives relaunch, increases monotonically for one device identity, is persisted before or atomically with batch creation, resets only when device identity changes, and is never synthesized by a receiver.

**Repository evidence**
`SyncBatchSequenceStore` persists counters and latches. PR 1 tests cover relaunch, gaps, transient failure, confirmed corruption, and device identity reset.

**Ratified decision**
Retain `SyncBatchSequenceStore`. PR 2 consumes emitted sequence metadata but does not change reservation semantics.

**Implementation consequence**
Receivers treat missing sequence as legacy order and never repair or synthesize sequence values.

**Required tests**
Existing PR 1 sequence tests remain required; PR 2 adds reconstruction and title ordering with sequenced and sequence-less batches.

## 11. device-identity reset semantics

**Frozen requirement**
Sequence reset is tied to device identity reset.

**Repository evidence**
PR 1 tests show confirmed corruption latches an identity into sequence-less mode and a new identity starts a new namespace.

**Ratified decision**
Retain device-identity namespace semantics. Convergence records store origin device ID and sequence evidence for ordering and diagnostics only.

**Implementation consequence**
PR 2 cannot independently reset or reinterpret sequence state.

**Required tests**
Identity reset preserves ordering determinism and does not collide synthetic canonical keys.

## 12. history bounds

**Frozen requirement**
Define deterministic, testable per-note bounds using snapshot generations, operation count, byte budget, or a documented combination. Do not use unbounded state.

**Repository evidence**
No retained history exists today. `SyncBatchNoteChangeCapture` emits insert/delete operations and skips replacements, so PR 2 must be able to defer unreconstructable cases.

**Ratified decision**
History and full incorporation evidence capacity is evaluated during planning before mutation.

Soft ceilings per note:

- snapshots: 8
- retained body operations: 512
- snapshot body bytes: 1,048,576
- retained operation payload bytes: 1,048,576
- full incorporation evidence bytes: 262,144
- reconciliation episode records: 3 completed generations plus 1 active generation
- diagnostic evidence bytes: 65,536
- cleanup evidence bytes: 65,536

Hard ceilings per note:

- snapshots: 12
- retained body operations: 768
- snapshot body bytes: 1,572,864
- retained operation payload bytes: 1,572,864
- full incorporation evidence bytes: 524,288
- reconciliation episode records: 5 completed generations plus 1 active generation
- diagnostic evidence bytes: 131,072
- cleanup evidence bytes: 131,072

OR semantics trigger compaction when any soft ceiling is exceeded. Hard ceilings reject or defer before save when projected final state after planned compaction would exceed any hard ceiling. Full incorporation evidence is compactable to tombstones; tombstones are permanent fixed-size idempotency records and are not reconstruction, reconciliation, diagnostic, or history evidence.

`NoteHistoryCompactionState.fullIncorporationEvidenceBytes` is per note, while one full incorporation record can affect multiple notes. PR 2 uses conservative multi-note accounting: charge the full encoded root-and-exclusive-child byte total to every affected note until the full record compacts to a tombstone. This intentionally overcounts, but it is deterministic, safe, simple, independent of note ordering, and resistant to under-accounting. Count each authoritative child exactly once, count derived root summaries only as root bytes, and do not count the same semantic payload in both root and child form. Calculate conservative per-note full-evidence charging from root bytes plus authoritative exclusive-child bytes. Independently protected evidence is charged to its independent owning category. Rebuilding a derived root summary does not change semantic digest values or full-evidence ownership. When compaction succeeds, remove the full charge from every affected note. The permanent tombstone is not charged to per-note reconstruction-history budgets; it is accounted for under the separately proposed global idempotency-ledger amendment.

If soft ceilings remain exceeded but hard ceilings are not exceeded, persist `historyPressure` and defer new convergence that would add history. While under pressure, cleanup, compaction, presentation retry, already-incorporated cleanup-only work, and tombstone compaction may proceed. Already committed evidence remains preserved, but it cannot authorize unlimited future commits.

Numeric values are implementation choices. Permanent compact tombstone retention is a proposed frozen-handoff amendment.

**Implementation consequence**
The system never commits first and then discovers required state cannot be bounded, except that permanent fixed-size tombstones are retained only if the proposed amendment is approved.

**Required tests**
Pre-commit compaction planning, projected post-commit validation, count and byte enforcement, soft pressure, hard-limit deferral before save, repeated deferred batches cannot grow state without bound, one multi-note batch is fully charged to every affected note, successful compaction removes the charge from every affected note, byte accounting does not double-count root and child evidence, derived-summary rebuild does not change ownership or digest values, full incorporation evidence remains bounded, tombstone encoding respects fixed maximum, and protected history remains intact while new growth stops.

## 13. protected-base rules

**Frozen requirement**
Compaction must preserve bases referenced by durable incoming batches, durable outgoing batches, partial-session delivery, incorporated remote operations needed by future incoming bases, deferred work, idempotent cleanup state, and current reconstruction plans.

**Repository evidence**
Incoming and outgoing queues persist complete `SyncBatch` payloads. PR 1 queue remediation preserves FIFO and does not silently evict incoming deferred batches.

**Ratified decision**
Protection discovery:

- durable incoming queue: all queued body `baseContentHash` values, reconciliation hashes, and queued operation result hashes that can become bases
- durable outgoing queue: all unsent operation bases and result hashes
- deferred incoming work: blocking batch references in durable diagnostic state
- incorporated remote history: remote result hashes that may be ancestors of queued, deferred, outgoing, cleanup, or episode evidence
- current merge plan: all target, base, result, and title evidence until commit or abort
- pending queue cleanup: incorporated batch result evidence until cleanup succeeds
- pending legacy cleanup: incorporation evidence until legacy cleanup succeeds or legacy cleanup is removed
- pending presentation refresh: final committed body hash and editor-routing evidence until refresh verifies
- PR 3 episode evidence: candidate, winning, predecessor, divergence, adoption, and fresh agreed hashes
- contradiction diagnostics: full incorporation evidence until investigation no longer requires variable-sized evidence

A protected hash maps to `NoteContentSnapshot.contentHash`. If the snapshot is absent, the operation chain from the nearest retained prior snapshot through the protected hash is pinned. Entire ancestry between protected snapshots is pinned. Queue enumeration failure, malformed evidence, or contradictory protection evidence fails closed and prevents compaction.

Full incorporation records are protected until queue cleanup, legacy cleanup, presentation verification, reconstruction/history need, episode references, diagnostic references, and contradiction needs all clear. Only then may they compact to tombstones.

Child ownership classification is fixed:

- `IncorporatedBatchNoteEffect`: exclusively owned full incorporation evidence unless a future schema explicitly promotes a note effect into independently protected reconstruction history.
- Operation-identity child records: exclusively owned full incorporation evidence when they only prove this batch's operation identities; independently protected reconstruction history when a retained operation chain references them by stable key.
- Body/title/creation result children: exclusively owned full incorporation evidence when they only prove this batch's commit effects; independently protected reconstruction history or title authority when referenced by retained history, `NoteTitleWinner`, diagnostics, presentation pending, or episode evidence.
- Blocking references: independently protected diagnostic evidence while represented in `ConvergenceNoteDiagnosticState`; otherwise exclusively owned full incorporation evidence.
- Reconciliation candidate records: independently protected episode evidence when attached to a `ReconciliationEpisode`; otherwise exclusive full incorporation evidence only if they exist solely to explain this incorporation.
- Contradiction diagnostics: independently protected diagnostic evidence while needed for fail-closed investigation; exclusively owned full incorporation evidence only when tied to a same-evidence compactable full record and not referenced by durable diagnostic state.
- Shared evidence referenced by multiple incorporation records is never deleted by root compaction.

Evidence-authority table:

| Evidence | Authoritative owner | Derived copy allowed | Disagreement behavior |
|---|---|---|---|
| Batch identity and semantic digests | `IncorporatedSyncBatch` or tombstone | No competing authority | Contradictory authoritative records fail closed |
| Affected-note membership | Normalized note-effect/result children | Root `affectedNotesPayload` summary | Rebuild summary or classify as corrupt history |
| Operation identities | `IncorporatedBatchOperationIdentity` | Count or aggregate digest only | Rebuild summary or classify as corrupt history |
| Body/title/creation results | `IncorporatedBatchResultEvidence` | Bounded root summary only | Rebuild summary or classify as corrupt history |
| Blocking evidence | Durable diagnostic owner or exclusive incorporation child | No second authoritative copy | Owner-specific protection rules |
| Contradiction evidence | Durable contradiction/diagnostic child | Bounded status summary | Preserve until explicit repair |
| Reconciliation candidates | Episode child when episode-owned; exclusive incorporation child otherwise | No duplicate authority | Ownership classification controls compaction |

**Implementation consequence**
No history or full incorporation evidence is released merely because a batch was transmitted, incorporated once, or removed from the incoming queue. Tombstone deletion remains prohibited absent future approved protocol amendment.

**Required tests**
Protected incoming/outgoing/deferred/cleanup/presentation/episode chains survive, queue enumeration failure fails closed, contradictory protection evidence fails closed, protected full records do not compact prematurely, full records and exclusive children compact once all protections release, child ownership classification prevents deletion of independently protected evidence, blocking and candidate evidence have one defined owner, deleting exclusive children leaves no duplicate authoritative root payload, and partial-session delivery remains reconstructable.

## 14. persisted title LWW

**Frozen requirement**
Every title operation uses strict persisted last-writer-wins based on the complete canonical key.

**Repository evidence**
Current iPhone and Mac appliers overwrite title directly without persisted title-winner metadata.

**Ratified decision**
Use `NoteTitleWinner`. Lower canonical key is ignored. Exact same operation identity is idempotent. Higher canonical key applies and persists. Title, title winner, history, diagnostics, incorporation, and presentation pending commit in one SwiftData save.

**Implementation consequence**
Receive order, UI state, timestamp proximity, and current title equality never replace operation identity. Full-precision date bit patterns preserve exact title operation identity after relaunch.

**Required tests**
Lower key ignored, same identity idempotent, higher key wins, legacy and sequenced titles share one order, title commit rolls back with body/history/incorporation, and title-winner equality survives encode/decode.

## 15. unreconstructable and reconciliation deferral

**Frozen requirement**
Until PR 3, unreconstructable bases and reconciliation operations remain queued and unseen, block later same-note processing, and are not blind-applied.

**Repository evidence**
`SyncBatchDrainFailureKind` currently includes `.mismatchedBase` and `.unsupportedReconciliation`. `SyncBatchPreflight` rejects mismatched hashes only when the capability is enabled. `SyncBatchBodyHashCapability.defaultEnabled` is currently `false`.

**Ratified decision**
`SyncBatchBodyHashCapability.defaultEnabled == false` remains in effect throughout PR 2. Hashed emission and mismatch refusal stay gated until PR 3 is available unless a separate release decision explicitly accepts persistent note-scoped stalls.

A reconstructable mismatch is not a failure after reconstruction eligibility is established. It enters planning. Unreconstructable base is `SyncConvergenceOutcome.deferred(.unreconstructableBase(noteID:batchID:baseContentHash:))`. Unsupported reconciliation is `SyncConvergenceOutcome.deferred(.unsupportedReconciliation(noteID:batchID:))`. History pressure is `SyncConvergenceOutcome.deferred(.historyPressure(noteID:blockingBatchID:))`.

Deferred outcomes are successful non-application outcomes: they retain queue entries, preserve unseen state, block later same-note work, and may allow unrelated disjoint-note progress by the deterministic selection rule.

Unsupported historical digest formats are pre-commit transaction failures, not deferred reasons and not contradictions. `.failedBeforeCommit(.unsupportedDigestFormat(noteID:batchID:formatVersion:))` leaves the complete batch queued and unseen, blocks every affected note represented by the complete batch, allows unrelated disjoint-note progress, preserves diagnostic evidence, and may retry automatically after upgrade or restored historical digest-format implementation support.

**Implementation consequence**
PR 2 can process previously queued hash-bearing batches under controlled tests and upgrade PR 1 blocked batches when reconstructable. PR 2 does not enable production hashed body-operation emission.

**Required tests**
Default capability remains disabled, enabling the gate is not part of PR 2, previously queued hash-bearing batches can be processed under controlled tests, reconstructable mismatch merges, unreconstructable remains queued and unseen, unsupported reconciliation remains queued and unseen, unsupported digest format remains queued and unseen without false contradiction, later same-note work cannot pass, unrelated disjoint-note progress follows the selection rule, deferred-reason equality is deterministic, exhaustive switching covers every deferred case, controller mappings cover every deferred case, durable-diagnostic conversion covers every deferred case, and retry-evidence tests exist for every deferred case.

## 16. degraded-status surface

**Frozen requirement**
PR 2 must not implement PR 3 degraded reconciliation behavior, but must surface safe deferred state.

**Repository evidence**
Current visible messages are produced by `SyncBatchDrainFailureClassifier.userMessage`. No durable note-scoped convergence diagnostics exist.

**Ratified decision**
Persist deterministic or post-commit states in `ConvergenceNoteDiagnosticState`:

- `unreconstructableBase`
- `unsupportedReconciliation`
- `corruptHistory`
- `invalidMergePlan` when safely persisted outside the failed transaction or on a later diagnostic pass
- `inconsistentIncorporationState`
- `unsupportedDigestFormat`
- `historyPressure`
- `queueCleanupPending`
- `legacyCleanupPending`
- `presentationRefreshPending`

Do not persist `transientPersistence`; context creation, fetch, save, unexpected transient service errors, queue capacity, and queue persistence remain ephemeral controller state because a failing persistence path cannot reliably persist evidence of itself.

Precedence: inconsistent incorporation, unsupported digest format, corrupt history, invalid merge plan, history pressure, unsupported reconciliation, unreconstructable base, presentation refresh pending, queue cleanup pending, legacy cleanup pending. Ephemeral errors clear after successful retry. Durable deferred states clear only when evidence resolves. Cleanup states clear only after cleanup succeeds. Presentation state clears only after editor state is verified refreshed. Fail-closed states do not auto-clear merely because a drain reruns.

**Implementation consequence**
User-visible status is derived from durable diagnostics plus ephemeral controller state with deterministic precedence.

**Required tests**
Fetch/save failure does not require diagnostic persistence, transient controller status clears after success, durable states survive relaunch, unsupported digest format has a user-visible message distinct from corrupt history, inconsistent incorporation, and unsupported reconciliation, fail-closed states do not clear accidentally, cleanup and presentation states clear only after successful completion.

## 17. episode grouping, receiving completion, emitter self-completion, and later generation

**Frozen requirement**
PR 2 freezes the PR 3 episode schema and evidence needed for grouping, receiving completion, emitter self-completion, and later generations.

**Repository evidence**
`noteBodyReconciled` exists in the payload but is unsupported by current appliers. The frozen handoff rejects a device-local random UUID as sole episode identity.

**Ratified decision**
Local storage identity is `(noteID, generation)` encoded as `episodeKey`, but that is not the cross-device logical grouping authority.

PR 3 reconciliation operation metadata must carry note ID, candidate replay key, candidate batch ID and operation index, candidate body hash, declared divergence/base evidence, predecessor or agreed-hash evidence when available, emitter-local generation as non-authoritative evidence, and logical grouping key derived from stable candidate evidence.

`EpisodeGroupingPayload` stores `version`, `logicalGroupingKey`, `noteID`, `declaredDivergenceHash`, `predecessorHash`, `emitterDeviceID`, `emitterGeneration`, and `firstCandidateIdentity`.

Completed episode retention is an implementation choice: retain 3 completed generations per note as the soft ceiling and 5 completed generations as the hard ceiling, subject to protection overrides and global bounded-state accounting.

**Implementation consequence**
PR 3 can complete emitters and receivers without relying on matching local generation counters or random device-local IDs.

**Required tests**
Local generation is not sole grouping authority, receiving-completion evidence survives relaunch, emitter self-completion evidence survives relaunch, completed episodes allow later generations, protected episodes override ordinary retention, and episode hard-limit overflow defers before mutation.

## 18. dual-degraded crossing with unequal history views

**Frozen requirement**
PR 3 must handle crossing degraded candidates even when devices have unequal prior history views. PR 2 must preserve the schema and grouping evidence needed for that.

**Repository evidence**
Current reconciliation operations are decoded but rejected as unsupported.

**Ratified decision**
Cross-device grouping is based on note ID plus candidate identity, candidate body hash, replay key, declared divergence/base evidence, and predecessor/agreed-hash evidence when present. Local generation is stored but non-authoritative.

Decision table:

| Case | PR 3 schema behavior frozen by PR 2 |
|---|---|
| Receiver has matching active unresolved episode | Attach candidate if grouping evidence overlaps active episode evidence. |
| Receiver has no active episode | Create next local generation using incoming logical grouping evidence. |
| Receiver has completed episode only | Reject as stale if evidence is covered by completed fresh agreed hash; otherwise create later generation. |
| Receiver has newer active episode | Reject stale candidate unless evidence proves it belongs to newer active divergence. |
| Candidate belongs to stale prior divergence | Preserve diagnostic evidence; do not reopen completed episode. |
| Two initial candidates cross with unequal history views | Store both under the same logical grouping when candidate/divergence evidence overlaps note-scoped unresolved divergence. |
| Local generation numbers differ | Ignore numeric equality for grouping; retain as non-authoritative evidence only. |

**Implementation consequence**
PR 2 still queues reconciliation unseen; it does not implement winner selection.

**Required tests**
Crossing candidates can join one logical episode, stale candidates cannot reopen completed episodes, later divergence opens a new generation, receiver without episode creates corresponding episode, relaunch preserves grouping evidence.

## 19. relaunch preservation of episode state and evidence

**Frozen requirement**
Episode state and evidence survive relaunch.

**Repository evidence**
The file-backed queue persists pending incoming batches, but no SwiftData episode state exists.

**Ratified decision**
All episode scaffolding, diagnostic state, cleanup pending state, presentation refresh pending state, full incorporation evidence, and tombstones are SwiftData-persisted. Relaunch loads those records before candidate selection and before cleanup-only or presentation-only retry.

Every authoritative incorporation commit requiring presentation initially persists `presentationRefreshPending = true`. A full relaunch may naturally rebuild the editor from committed state, but pending state is still verified and cleared deterministically. Current selection is recalculated during retry rather than stored as object identity.

**Implementation consequence**
No in-memory-only evidence is authoritative. Crash after commit before presentation, or after presentation before pending-clear save, is harmless and does not permit operation replay.

**Required tests**
Relaunch preserves deferred state, cleanup pending state, presentation pending state, episode grouping evidence, receiving-completion evidence, emitter self-completion evidence, tombstones, crash-before-presentation retry, crash-after-presentation-before-clear retry, selection changes between commit and retry, and successful verification clears pending state.

## 20. accepted `modifiedAt` clock-skew behavior

**Frozen requirement**
Replay and LWW key begins with `modifiedAt`; fast clocks may win more often; no ad hoc correction.

**Repository evidence**
`SyncBatchReplayKey` currently compares `modifiedAt` first.

**Ratified decision**
Retain the accepted trade-off exactly.

**Implementation consequence**
No PR 2 clock-skew compensation.

**Required tests**
Skewed timestamps order by `modifiedAt`, title/body behavior match the same key, and bit-pattern persistence does not change ordering.

## Outcome Type Structure

Use these exact outcome domains consistently:

```swift
enum SyncBatchQueueFailure {
    case capacity
    case persistence
}

enum SyncConvergenceOutcome {
    case committed(SyncConvergenceCommitSummary)
    case alreadyIncorporated(SyncConvergenceCleanupPlan)
    case deferred(SyncConvergenceDeferredReason)
    case failedBeforeCommit(SyncConvergenceTransactionFailure)
}

enum SyncConvergenceDeferredReason: Equatable {
    case unreconstructableBase(
        noteID: UUID,
        batchID: UUID,
        baseContentHash: String
    )
    case unsupportedReconciliation(
        noteID: UUID,
        batchID: UUID
    )
    case historyPressure(
        noteID: UUID,
        blockingBatchID: UUID?
    )
}

enum SyncConvergenceTransactionFailure {
    case swiftDataFetch
    case swiftDataSave
    case corruptHistory(noteID: UUID?)
    case invalidMergePlan(noteID: UUID?)
    case inconsistentIncorporationState(noteID: UUID?)
    case unsupportedDigestFormat(
        noteID: UUID?,
        batchID: UUID,
        formatVersion: Int
    )
    case unexpected
}
```

`unsupportedDigestFormat` means no authoritative application occurs, the queue entry remains, unseen state remains, all notes affected by the complete batch become blocked, unrelated disjoint-note progress may continue, durable diagnostics record the unsupported version, automatic retry may occur after upgrade or restored compatibility support, it is not contradictory incorporation, and it cannot delete the full record, tombstone, or queued duplicate.

Post-commit pending work is not a pre-commit failure:

```swift
struct SyncConvergencePostCommitState {
    var queueCleanupPending: Bool
    var legacyCleanupPending: Bool
    var presentationRefreshPending: Bool
}
```

## Outcome Ownership Table

| Event/outcome | Owning subsystem | Authoritative type | Commit occurred | Persisted state | Controller mapping | Retry owner | User-visible status |
|---|---|---|---|---|---|---|---|
| queue capacity | receive/queue boundary | `SyncBatchQueueFailure.capacity` | no | no | `.queueCapacity` | receive boundary | queue full |
| queue persistence | receive/queue boundary | `SyncBatchQueueFailure.persistence` | no | no | `.queuePersistence` | receive boundary | queue persistence |
| matching-base committed | convergence service | `SyncConvergenceOutcome.committed` | yes | incorporation, presentation pending, history, post-commit state | success | cleanup/presentation | none unless pending |
| conflict merge committed | convergence service | `SyncConvergenceOutcome.committed` | yes | incorporation, presentation pending, history, post-commit state | success | cleanup/presentation | none unless pending |
| already incorporated | convergence service | `SyncConvergenceOutcome.alreadyIncorporated` | prior | existing incorporation or tombstone | success with cleanup-only | cleanup/presentation | pending if failure |
| SwiftData fetch failure | convergence service | `.failedBeforeCommit(.swiftDataFetch)` | no | no | `.persistence` | drain retry | transient persistence |
| SwiftData save failure | convergence service | `.failedBeforeCommit(.swiftDataSave)` | no | no authoritative mutation | `.persistence` | drain retry | transient persistence |
| unreconstructable base | convergence core | `.deferred(.unreconstructableBase(noteID:batchID:baseContentHash:))` | no application | durable diagnostic if possible | no failure kind | drain after new evidence | unreconstructable |
| unsupported reconciliation | convergence core | `.deferred(.unsupportedReconciliation(noteID:batchID:))` | no application | durable diagnostic if possible | no failure kind after convergence classification | PR 3/new evidence | unsupported reconciliation |
| corrupt history | convergence core | `.failedBeforeCommit(.corruptHistory(noteID: ...))` | no | durable diagnostic when a separate diagnostic save is safe; otherwise ephemeral until the next diagnostic pass | `.corruptHistory` | explicit repair/new evidence | corrupt history |
| invalid plan | convergence core | `.failedBeforeCommit(.invalidMergePlan(noteID: ...))` | no | durable diagnostic when a separate diagnostic save is safe; otherwise ephemeral until the next diagnostic pass | `.invalidMergePlan` | code/new evidence | invalid plan |
| inconsistent incorporation | convergence service | `.failedBeforeCommit(.inconsistentIncorporationState(noteID: ...))` | no implicated application | durable diagnostic | `.inconsistentIncorporationState` | explicit repair | incorporation diagnostic |
| unsupported digest format | convergence service | `.failedBeforeCommit(.unsupportedDigestFormat(noteID:batchID:formatVersion:))` | no | durable diagnostic | `.unsupportedDigestFormat` | upgrade/restored historical digest-format implementation | unsupported digest format |
| history pressure | convergence core | `.deferred(.historyPressure(noteID:blockingBatchID:))` | no new history | durable diagnostic | no failure kind | cleanup/compaction | history pressure |
| queue cleanup pending | post-commit cleanup | `SyncConvergencePostCommitState.queueCleanupPending` | yes | post-commit state | success with status | cleanup retry | cleanup pending |
| legacy cleanup pending | post-commit cleanup | `SyncConvergencePostCommitState.legacyCleanupPending` | yes | post-commit state | success with status | cleanup retry | cleanup pending |
| presentation refresh pending | presentation adapter | `SyncConvergencePostCommitState.presentationRefreshPending` | yes | post-commit state | success with status | presentation retry | refresh pending |
| unexpected failure | convergence service | `.failedBeforeCommit(.unexpected)` | no unless explicitly known committed | no or diagnostic if safe | `.unexpected` | drain retry/diagnostic | unexpected |

## Exhaustive SyncBatchDrainFailureKind Mapping

Existing cases retained:

- `.queueCapacity`: from `SyncBatchQueueFailure.capacity`
- `.queuePersistence`: from `SyncBatchQueueFailure.persistence`
- `.persistence`: from `.failedBeforeCommit(.swiftDataFetch)` and `.failedBeforeCommit(.swiftDataSave)`
- `.unsupportedReconciliation`: retained for pre-PR-2 compatibility paths before convergence classification
- `.mismatchedBase`: retained for pre-PR-2 compatibility paths before reconstructability classification
- `.unexpected`: from `.failedBeforeCommit(.unexpected)`

Proposed PR 2 extensions:

- `.corruptHistory`: from `.failedBeforeCommit(.corruptHistory(noteID: ...))`
- `.invalidMergePlan`: from `.failedBeforeCommit(.invalidMergePlan(noteID: ...))`
- `.inconsistentIncorporationState`: from `.failedBeforeCommit(.inconsistentIncorporationState(noteID: ...))`
- `.unsupportedDigestFormat`: from `.failedBeforeCommit(.unsupportedDigestFormat(noteID:batchID:formatVersion:))`

No failure kind is produced for successful commits, already-incorporated cleanup-only, queue cleanup pending after commit, legacy cleanup pending after commit, presentation refresh pending after commit, unreconstructable deferred state, unsupported reconciliation deferred state after convergence classification, or history pressure deferred state.

## No-Echo Lifecycle Table

| Path | Suppression owner | Acquisition before mutation/save | Authoritative save | Context observation | Presentation route | Verification | Release | Nested-drain behavior | Presentation-retry behavior |
|---|---|---|---|---|---|---|---|---|---|
| matching-base selected note | outer convergence transaction token | before managed mutation | under suppression | under suppression | incremental selected-editor apply | displayed hash/key verified | after verification or pending state saved | nested/rejected drain cannot clear token | retry acquires new token |
| matching-base non-selected note | outer convergence transaction token | before managed mutation | under suppression | under suppression | model/revision refresh | committed model hash verified | after verification or pending state saved | nested/rejected drain cannot clear token | retry emits nothing |
| legacy hash-less selected note | outer convergence transaction token | before managed mutation | under suppression | under suppression | existing safe incremental/fallback route as planned | displayed content verified | after verification or pending state saved | nested/rejected drain cannot clear token | retry presentation only |
| conflict merge selected note | outer convergence transaction token | before managed mutation | under suppression | under suppression | MYR-131 whole-note fallback reload | displayed hash verified | after verification or pending state saved | nested/rejected drain cannot clear token | retry fallback reload only |
| conflict merge non-selected note | outer convergence transaction token | before managed mutation | under suppression | under suppression | model refresh only | committed model hash verified | after verification or pending state saved | nested/rejected drain cannot clear token | retry emits nothing |
| title-only change | outer convergence transaction token | before managed mutation | under suppression | under suppression | title/list refresh | title winner key verified | after verification or pending state saved | nested/rejected drain cannot clear token | retry title/list verification |
| presentation-only retry | presentation retry token | before refresh attempt | prior commit already exists | under suppression | route recalculated from current selection | pending flag cleared only after verification | after verification or pending remains | cannot clear other token | no merge rebuild or replay |
| already-incorporated cleanup-only | cleanup service token only if presentation pending | before presentation retry if needed | prior commit already exists | under suppression only if presentation pending | none unless presentation pending | cleanup/presentation verified | after cleanup/presentation attempt | no operation application | cleanup and presentation retry only |

## Post-Commit State Table

| State | Set during authoritative commit | Cleared by | Survives relaunch | Permits queue cleanup | Permits full-record compaction | May replay operation |
|---|---:|---|---:|---:|---:|---:|
| presentation pending at commit | yes when presentation required | suppressed presentation verification follow-up save | yes | yes | no | no |
| presentation verified | no, derived from pending cleared | verification hash/key match | yes as absence of pending | yes | yes if other protections clear | no |
| queue cleanup pending | yes until queue removal succeeds | queue cleanup success | yes | retry target | no | no |
| legacy cleanup pending | yes if legacy write/removal needed | legacy cleanup success or removal | yes | yes | no | no |
| full incorporation evidence protection | yes while dependencies exist | protection release and tombstone creation | yes | yes | no until released | no |
| tombstone eligibility | planned before commit or compaction | creation of `IncorporatedBatchTombstone` | yes | yes | yes after tombstone | no |

## Incorporation Retention Table

| Record tier | Included records | Retention | Maximum encoded size | Compaction |
|---|---|---|---:|---|
| Full incorporation evidence | Root identity/digest/post-commit state plus derived summaries, and exclusive authoritative note-effect, operation-identity, body/title/creation-result, blocking-reference, reconciliation-candidate, and contradiction-evidence children | Until all protection clears | 16 KiB per batch root payload plus bounded exclusive child totals charged to every affected note without double-counting semantic evidence | Validate/repair derived summaries, then atomically replace by one tombstone and delete exclusive children in one save |
| Independent protected evidence | History, diagnostic, episode, presentation, cleanup, or shared children with independent protection | According to their own bounds | According to the owning category | Not deleted by root compaction |
| Tombstone | Fixed-size identity and digests only | Permanent under proposed amendment | 512 bytes | Never deleted under current protocol |

## Absolute History-Bound Table

| Category | Soft count | Hard count | Soft bytes | Hard bytes | Protection sources | Compaction order | Pre-commit rejection/defer |
|---|---:|---:|---:|---:|---|---|---|
| snapshots | 8 | 12 | 1,048,576 | 1,572,864 | queued bases, outgoing bases, plan hashes, cleanup, episodes | oldest unprotected generation | defer if hard exceeded after compaction |
| retained operations | 512 | 768 | 1,048,576 | 1,572,864 | reconstruction chains, queued/deferred/outgoing descendants | oldest unprotected complete chain | defer if hard exceeded |
| full incorporation evidence | bounded by protection | bounded by hard bytes | 262,144 per note, charging full root-plus-exclusive-child bytes to every affected note | 524,288 per note, charging full root-plus-exclusive-child bytes to every affected note | idempotency, pending cleanup, presentation, history, diagnostics, episode evidence | atomically compact released root plus exclusive children to tombstone | defer new full evidence if hard exceeded |
| incorporation tombstones | unbounded count by proposed amendment | unbounded count by proposed amendment | 512 bytes each | 512 bytes each | never-reapply invariant | none | amendment approval required |
| title winners | 1 per note | 1 per note | small fixed payload | small fixed payload | current title authority | replace by higher key only | invalid duplicate fails closed |
| diagnostics | 1 active per note | 1 active plus bounded archived evidence | 65,536 | 131,072 | fail-closed evidence, deferred blockers | superseded unprotected evidence first | defer new evidence if hard exceeded |
| cleanup state | pending records only | pending plus contradiction evidence | 65,536 | 131,072 | queue/legacy/presentation pending | clear after success | no new history-producing work if hard exceeded |
| reconciliation episodes | 3 completed + 1 active | 5 completed + 1 active | included in episode evidence bytes | included in episode evidence bytes | active, queued reconciliation, stale detection | oldest completed unprotected | defer opening new episode if hard exceeded |
| reconciliation candidates/evidence | bounded inside episodes | bounded inside episodes | 65,536 per note | 131,072 per note | active episode, completion evidence, stale rejection | unprotected completed evidence | defer if hard exceeded |

## Evidence Payload Contracts

All persisted evidence payloads are versioned and explicitly classified as authoritative, derived and rebuildable, independently protected evidence, or ephemeral/presentation-only state. No semantic fact may have two authoritative persisted representations. Unknown non-digest evidence versions and malformed payloads fail closed as `.failedBeforeCommit(.corruptHistory(noteID: ...))`, except contradictory decoded authoritative incorporation evidence, which is `.failedBeforeCommit(.inconsistentIncorporationState(noteID: ...))`. Unsupported stored digest formats use `.failedBeforeCommit(.unsupportedDigestFormat(noteID:batchID:formatVersion:))`.

- `CanonicalBatchDigestPayloadV1`: normalized incoming batch semantics used for `canonicalPayloadDigest`; encoded only by `CanonicalDigestEncoderV1`.
- `CanonicalCommittedResultDigestPayloadV1`: normalized authoritative commit effects used for `committedResultDigest`; encoded only by `CanonicalDigestEncoderV1`.
- `CanonicalReplayKeyPayload`: authoritative replay/title key fields with exact date bit patterns.
- `CommittedAtOrderingPayload`: committed timestamp bit pattern and batch identity evidence.
- `OperationIdentityPayload`: batch ID, origin device ID, operation index, operation kind, canonical replay key.
- `AffectedNotesPayload`: derived, non-authoritative sorted affected-note UUID summary, rebuildable from authoritative note-effect/result children.
- `BodyResultEvidencePayload`: authoritative only when stored in `IncorporatedBatchResultEvidence`; derived if embedded in a summary.
- `TitleResultEvidencePayload`: authoritative only when stored in `IncorporatedBatchResultEvidence`; derived if embedded in a summary.
- `CreationResultEvidencePayload`: authoritative only when stored in `IncorporatedBatchResultEvidence`; note-creation result identity, created note ID, final title key, final body hash, and folder identity committed by the batch.
- `PostCommitStatePayload`: authoritative post-commit queue cleanup, legacy cleanup, presentation refresh, routing, verification, and attempt-count state; excluded from semantic digests.
- `DiagnosticEvidencePayload`: authoritative only when stored in durable diagnostic or contradiction children; derived if represented as bounded root status.
- `BlockingBatchReference`: batch ID, origin device ID, affected note IDs, queue position evidence.
- `EpisodeGroupingPayload`: logical grouping fields listed in item 17.
- `ReconciliationCandidateEvidence`: candidate replay key, batch ID, operation index, body hash, divergence evidence, emitter identity, non-authoritative emitter generation.
- `ReceivingCompletionEvidencePayload`: accepted operation identity, equal-base or descendant-base evidence, fresh agreed hash.
- `EmitterSelfCompletionEvidencePayload`: emitted candidate identity, adoption-proving operation identity, equal-base or descendant-base evidence, fresh agreed hash.

Blocking batch references, reconciliation candidate evidence, and reconciliation completion evidence are always modeled as SwiftData child records because PR 2 and PR 3 must query, deduplicate, protect, release, and compact those records individually. Remaining encoded payloads are justified only when they are loaded with their owning record, are not queried independently, and are bounded by the history/evidence ceilings above.

Canonical payload digest:

```swift
struct CanonicalBatchDigestPayloadV1 {
    let schemaVersion: Int
    let batchID: UUID
    let originDeviceID: UUID
    let createdAtBitPattern: UInt64
    let batchSequence: UInt64?
    let orderedChanges: [CanonicalChangeDigestPayloadV1]
}
```

`CanonicalChangeDigestPayloadV1` includes the exact immutable wire-semantic fields from the merged PR 1 `SyncBatchChange` payload types. The V1 variants are `noteTitleChanged`, `noteBodyTextInserted`, `noteBodyTextDeleted`, `noteBodyReconciled`, and `noteCreated`. The normalized representation distinguishes note creations with different titles, initial bodies, folders, `createdAt` bit patterns, or `modifiedAt` bit patterns, and it distinguishes a missing optional folder from an explicitly present folder ID. Inserted body text is not assumed to represent a created note's complete initial body. Note creation is its own wire-semantic operation and is normalized explicitly.

`canonicalPayloadDigest` is computed from normalized incoming wire semantics. `committedResultDigest` is computed from normalized authoritative committed effects. Neither digest depends on root-versus-child persistence layout. `affectedNotesPayload` does not independently define digest semantics. Derived summaries are excluded unless explicitly included as normalized semantic fields in the digest contract. Rebuilding a summary cannot change either digest.

Canonical digest byte format:

`CanonicalPayloadDigestFormatV1` and `CanonicalCommittedResultDigestFormatV1` are the V1 historical digest implementations. The stored digest format version uniquely identifies both normalized semantics and canonical byte encoding. There is no separately persisted encoder version. Each implementation emits fields in fixed schema-defined order using a custom length-prefixed canonical binary format:

- version and discriminator: `UInt32` big-endian
- signed integer, including Swift `Int` values normalized for digest input: `Int64` two's-complement big-endian
- nonnegative count, length, and index fields: `UInt64` big-endian unless the schema explicitly names a narrower type
- `UInt64`: fixed-width big-endian
- Boolean: `0x00` or `0x01`
- UUID: 16 raw UUID bytes
- string: `UInt64` UTF-8 byte count followed by UTF-8 bytes
- raw data: `UInt64` byte count followed by bytes
- optional absent: `0x00`
- optional present: `0x01` followed by encoded value
- array: `UInt64` element count followed by elements in semantic order
- set/map: canonical sort, then count and values
- enum: fixed discriminator followed by associated fields
- ordering-significant `Date`: `timeIntervalSinceReferenceDate.bitPattern` as big-endian `UInt64`

The encoder rejects lengths exceeding implementation limits, duplicate map keys, unsupported discriminators, unknown schema versions, and invalid normalized input.

Discriminator-domain rules:

- each discriminator domain is explicitly named
- discriminator values are `UInt32` big-endian
- values are permanent within a format version
- removed variants leave reserved values; values are never reused
- unknown values are rejected
- new variants require unused values
- changing a value or field sequence requires a new digest format version
- a discriminator is encoded exactly once for one semantic branch
- subtype discriminators are allowed only for an independent nested choice

No redundant subtype discriminator exists in V1 unless listed in a named domain table. Body insert and body delete are separate outer change variants and therefore do not receive another body-operation discriminator. Reconciliation replacement and note creation likewise do not receive redundant subtype discriminators in V1.

Change-variant discriminator domain:

| Change variant | Discriminator |
|---|---:|
| title change | `0x00000001` |
| body insert | `0x00000002` |
| body delete | `0x00000003` |
| reconciliation replacement | `0x00000004` |
| note creation | `0x00000005` |

Committed-note-result discriminator domain:

| Result variant | Discriminator |
|---|---:|
| body result | `0x00000001` |
| title result | `0x00000002` |
| note-creation result | `0x00000003` |
| reconciliation result | `0x00000004` |

Replay order-kind discriminator domain:

| Order kind | Discriminator |
|---|---:|
| legacy | `0x00000001` |
| sequenced | `0x00000002` |

Operation-kind discriminator domain:

| Operation kind | Discriminator |
|---|---:|
| title | `0x00000001` |
| body insert | `0x00000002` |
| body delete | `0x00000003` |
| reconciliation | `0x00000004` |
| note creation | `0x00000005` |

Title-result discriminator domain:

| Title result variant | Discriminator |
|---|---:|
| winning title | `0x00000001` |

Canonical payload field order:

1. digest payload schema version
2. batch schema version
3. batch ID UUID bytes
4. origin device ID UUID bytes
5. `createdAtBitPattern`
6. optional `batchSequence`
7. flat ordered changes array

Every `CanonicalChangeDigestPayloadV1` begins with exactly one `UInt32` change-variant discriminator. That single discriminator fully selects the field layout.

Title change, discriminator `0x00000001`:

1. note ID UUID bytes
2. global operation index as `UInt64`
3. operation `modifiedAt` bit pattern as `UInt64`
4. title string

Body insert, discriminator `0x00000002`:

1. note ID UUID bytes
2. global operation index as `UInt64`
3. operation `modifiedAt` bit pattern as `UInt64`
4. UTF-16 location as `Int64`
5. inserted text
6. optional base content hash

Body delete, discriminator `0x00000003`:

1. note ID UUID bytes
2. global operation index as `UInt64`
3. operation `modifiedAt` bit pattern as `UInt64`
4. UTF-16 location as `Int64`
5. UTF-16 length as `Int64`
6. optional expected deleted text
7. optional base content hash

Reconciliation replacement, discriminator `0x00000004`:

1. note ID UUID bytes
2. global operation index as `UInt64`
3. operation `modifiedAt` bit pattern as `UInt64`
4. replacement body
5. replacement content hash

Note creation, discriminator `0x00000005`:

1. note ID UUID bytes
2. global operation index as `UInt64`
3. operation `modifiedAt` bit pattern as `UInt64`
4. initial title
5. initial body
6. optional folder ID using the standard optional discriminator plus UUID bytes
7. creation `createdAt` bit pattern as `UInt64`

Canonicalization rules:

- use the shared PR 1 SHA-256 implementation over canonical bytes
- persist lowercase hexadecimal digests, exactly 64 ASCII characters, with no prefix or separators
- persist only the digest-format version; it uniquely identifies semantics and byte encoding
- never hash raw transport JSON bytes
- arrays preserve semantic operation order
- sets and maps sort by explicit canonical keys before encoding
- UUIDs encode as 16 raw bytes in digests; lowercase canonical strings are used only in non-digest textual payloads
- ordering-significant dates use exact `Double.bitPattern` values
- enum cases use explicit stable discriminators
- absent optional values are encoded explicitly as absent according to the versioned normalized schema
- no locale-sensitive formatting
- no object identity or platform-specific representation
- the digest-payload version is included in the hashed bytes
- golden vectors test exact canonical bytes and SHA-256 output directly

Canonical committed-result digest:

```swift
struct CanonicalCommittedResultDigestPayloadV1 {
    let batchID: UUID
    let committedNoteResults: [CanonicalCommittedNoteResultV1]
}
```

`CanonicalCommittedResultDigestPayloadV1` contains immutable authoritative commit effects only: sorted affected note IDs represented by committed result records, committed final body hashes, committed title-winner identities and canonical keys, incorporated operation identities, committed note-creation result identity where applicable, and immutable reconciliation result identity where applicable.

Committed-result field order:

1. digest payload schema version
2. batch ID UUID bytes
3. committed-note-result array sorted by note ID, then committed-note-result discriminator, then global operation index where present

Every committed note-result variant begins with exactly one committed-note-result discriminator. Discriminator values are local to the committed-note-result domain and are independent of identical numeric values in other domains.

Body result, discriminator `0x00000001`:

1. note ID UUID bytes
2. optional pre-body hash
3. final body hash
4. incorporated operation identities in global operation-index order

Title result, discriminator `0x00000002`:

1. note ID UUID bytes
2. winning operation identity
3. winning canonical replay key
4. final title value

Note-creation result, discriminator `0x00000003`:

1. created note ID UUID bytes
2. optional committed folder ID
3. committed final body hash
4. committed title-winner operation identity
5. committed title-winner canonical replay key
6. creation operation identity

Reconciliation result, discriminator `0x00000004`:

1. note ID UUID bytes
2. accepted operation identity
3. committed final body hash
4. replacement content hash

PR 2 does not apply reconciliation commits in production, but V1 intentionally reserves and defines the reconciliation-result discriminator and field sequence so golden vectors can lock the contract before PR 3.

Operation identity field order inside either digest:

1. operation-kind discriminator from the operation-kind domain
2. batch ID UUID bytes
3. origin device ID UUID bytes
4. global operation index as `UInt64`
5. canonical replay key

Canonical replay-key field order inside either digest:

1. `modifiedAtBitPattern`
2. origin device ID UUID bytes
3. replay order-kind discriminator
4. if legacy: legacy `createdAtBitPattern`, then batch ID UUID bytes
5. if sequenced: `batchSequence` as `UInt64`
6. stable batch ID UUID bytes
7. global operation index as `UInt64`

It excludes mutable post-commit state: cleanup state, presentation state, retry attempts, mutable diagnostics, mutable status timestamps, compaction state, and derived root summaries including `affectedNotesPayload`. `PostCommitStatePayload` must never participate in `committedResultDigest`.

Digest migration and versions:

- `canonicalPayloadDigestFormatVersion` identifies the normalized incoming payload format.
- `committedResultDigestFormatVersion` identifies the normalized committed-result format.
- comparison dispatches through the stored digest format version.
- supported historical versions compute incoming duplicate digests with the stored historical digest-format implementation.
- unknown or unsupported stored digest versions fail as `.failedBeforeCommit(.unsupportedDigestFormat(noteID:batchID:formatVersion:))` without classifying a healthy duplicate as contradictory.
- Old digest values and versions are retained permanently in full records and tombstones.
- Old tombstone digests are not recomputed from incomplete compacted evidence.
- PR 2 does not add per-batch migration records.
- Once a digest format is persisted in a full record or tombstone, its complete implementation becomes compatibility code and must retain golden-vector tests while such records can exist.
- A historical digest-format implementation cannot be removed without a future approved migration or protocol amendment.
- Tombstone digest values must never be rewritten merely because a newer format exists.

Digest-version compatibility table:

| Stored version | Implementation available | Behavior |
|---|---|---|
| Supported historical version | yes | Compute incoming digest using stored version |
| Current version | yes | Compute and compare normally |
| Unsupported historical version | no | Block without reapplication or false contradiction |
| Same version, different digest | yes | Fail closed as inconsistent incorporation |

Digest Contract Table:

| Digest | Canonical input | Excluded state | Encoding | Algorithm |
|---|---|---|---|---|
| Canonical payload digest | Immutable normalized incoming batch semantics, including note-creation title, initial body, folder identity, and other immutable creation metadata | Transport encoding and mutable state | Versioned canonical binary | Shared SHA-256 |
| Committed-result digest | Immutable authoritative committed effects, including body, title, creation, operation, and reconciliation effects | Cleanup, presentation, diagnostics, compaction, retry attempts, and derived root summaries | Versioned canonical binary | Shared SHA-256 |

Digest tests must prove raw JSON key order cannot affect the digest; semantically identical batches produce identical canonical digests; differently ordered operations produce different digests when order is semantically significant; optional absent versus present-empty values behave according to the normalized schema; sub-millisecond dates remain distinct; Unicode strings are stable; golden vectors include semantic normalized input, named digest format version, complete canonical bytes in hexadecimal, annotated offsets for top-level version, discriminator, UUIDs, lengths, optionals, dates, and strings, and expected SHA-256 for title change with discriminator `0x00000001`, body insert with `0x00000002`, body delete with `0x00000003`, reconciliation with `0x00000004`, note creation with `0x00000005`, each committed-result variant, legacy and sequenced replay order kinds, multi-note batch, absent versus present-empty optionals, sub-millisecond timestamps, Unicode strings, and differing transport JSON representations; exactly one change discriminator is encoded; redundant body, reconciliation, and creation discriminator bytes are absent; changing a discriminator changes the digest; unknown discriminators are rejected; old discriminator assignments remain stable after new variants are introduced; persistence layout and root-summary rebuilding cannot affect digest output; full record and tombstone carry the identical payload digest and digest-format version; mutable post-commit state does not alter `committedResultDigest`; cleanup attempt-count changes do not alter either digest; unsupported versions block without false contradiction; V1 tombstones compare after V2 exists; incoming duplicates are computed with the stored V1 digest-format implementation; identical V1 semantics compare equal; contradictory payload differs under V1; restored historical support enables retry; V2 does not rewrite V1 tombstones; historical golden vectors remain stable; note creations with different initial bodies, folder IDs, `createdAt`, `modifiedAt`, or titles produce different payload digests; and identical note-creation semantics produce the same digest regardless of transport JSON key ordering.

## Controller Outcome Table

| Outcome | Error/deferred | Queued | Unseen | SwiftData mutation | Editor refresh | Auto retry | Needs new evidence | Same-note blocked | Unrelated progress | Visible status | Queue cleanup | Legacy cleanup | Apply later | Reapply after commit |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---|---:|---:|---:|---:|
| matching-base success | success | no after cleanup | no | yes under suppression | incremental if selected | cleanup/presentation only | no | no | yes | none unless pending | yes | yes | no | no |
| legacy hash-less success | success | no after cleanup | no | yes under suppression | planned safe route | cleanup/presentation only | no | no | yes | none unless pending | yes | yes | no | no |
| title-only success | success | no after cleanup | no | yes under suppression | list/title refresh | cleanup/presentation only | no | no | yes | none unless pending | yes | yes | no | no |
| reconstructable mismatch success | success | no after cleanup | no | yes under suppression | whole-note reload if selected | cleanup/presentation only | no | no | yes | none unless pending | yes | yes | no | no |
| already incorporated cleanup-only | success | until cleanup | no | post-commit state only | only if presentation pending | yes | no | no | yes | cleanup/refresh pending if failure | yes | yes | no | no |
| transient fetch failure | error | yes | yes | no | no | yes | no | all affected by blocked batch | no for blocked FIFO | ephemeral persistence | no | no | yes | n/a |
| transient save failure | error | yes | yes | no authoritative | no | yes | no | all affected by blocked batch | no for blocked FIFO | ephemeral persistence | no | no | yes | n/a |
| queue capacity | error | newest not retained | yes | no | no | on receive | yes/resend | no | yes | ephemeral queue full | no | no | yes if resent | n/a |
| queue persistence | error | enqueue rollback | yes | no | no | on receive | yes/resend | no | yes | ephemeral queue persistence | no | no | yes if resent | n/a |
| queue cleanup pending | post-commit pending | yes until cleanup | no | yes | no repeat unless needed | yes | no | no | yes | cleanup pending | yes | maybe | no | no |
| legacy cleanup pending | post-commit pending | maybe | no | yes | no repeat | yes | no | no | yes | cleanup pending if surfaced | maybe | yes | no | no |
| presentation refresh pending | post-commit pending | maybe | no | yes | retry only | yes | no | no | yes | refresh pending | may proceed | may proceed | no | no |
| unreconstructable base | deferred | yes | yes | diagnostic only | no | yes | yes | all affected by deferred batch | disjoint only | durable unreconstructable | no | no | yes if evidence appears | n/a |
| unsupported reconciliation | deferred | yes | yes | diagnostic only | no | yes | PR 3/new evidence | all affected by deferred batch | disjoint only | durable unsupported | no | no | yes after PR 3 | n/a |
| corrupt history | error | yes | yes | diagnostic if possible | no | no | repair/new evidence | all affected by deferred batch | disjoint only | durable corrupt history | no | no | no until repair | n/a |
| invalid merge plan | error | yes | yes | no or diagnostic if safe | no | no | code/new evidence | all affected by deferred batch | disjoint only | invalid plan | no | no | no until resolved | n/a |
| inconsistent incorporation | error | yes | yes | diagnostic only | no | no | explicit repair | all affected by deferred batch | disjoint only | incorporation diagnostic | no | no | no | no |
| unsupported digest format | error | yes | yes | diagnostic only | no | after upgrade/restored support | historical digest-format implementation support | all affected by deferred batch | disjoint only | unsupported digest format | no | no | yes after support restored | no |
| history pressure | deferred | yes | yes | diagnostic only | no | cleanup/compaction | pressure clears | all affected by deferred batch | disjoint only | history pressure | no | no | no until pressure clears | n/a |
| unexpected | error | yes if not committed | yes if not committed | no unless known committed | no or pending | yes if safe | maybe | all affected by deferred batch | no for blocked FIFO | unexpected | no unless committed | no unless committed | yes if not committed | no if committed |

## Multi-Note Atomicity And Queue Selection

Transport batches are incorporated atomically. A batch produces one root `IncorporatedSyncBatch` plus authoritative per-note effect/result children. If any condition defers a complete multi-note transport batch, every note represented by that batch becomes blocked for later same-note processing. The complete batch remains queued, unseen, unincorporated, and ineligible for partial cleanup. For persisted incorporated evidence, affected-note membership is the set of note IDs represented by authoritative note-effect/result children. Root `affectedNotesPayload` is only a derived lookup/routing/accounting summary and does not determine multi-note atomicity, blocking, contradiction, child deletion, or tombstone rebuilding.

Candidate selection:

```text
read durable incoming queue in FIFO order
load authoritative incorporated batch records, tombstones, and note-effect/result children
partition already incorporated entries into cleanup-only work
initialize blockedNoteIDs from durable diagnostics and same-drain deferrals

for each unincorporated batch in FIFO order:
    affected = all note IDs represented by the complete batch's flat changes array

    if affected intersects blockedNoteIDs:
        leave complete batch queued and unseen
        blockedNoteIDs.formUnion(affected)
        continue

    attempt complete-batch planning

    if any note or operation prevents complete planning:
        defer the complete batch
        blockedNoteIDs.formUnion(affected)
        leave complete batch queued and unseen
        continue

    include the complete batch as a candidate

reject any plan that incorporates a subset of one transport batch
cleanup only complete incorporated batch IDs
for already incorporated records, rebuild affected notes from authoritative children
```

Later batches may pass only when their affected-note set is disjoint from the union of all affected notes belonging to every earlier deferred or blocked batch. This creates intentional transitive blocking: if `{A, B}` defers, later `B` is blocked; later `{B, C}` is blocked and blocks `C`; later `C` is blocked; disjoint `D` may proceed.

## Idempotent Commit Protocol

1. Read the durable incoming queue.
2. Read authoritative SwiftData incorporated-batch records, tombstones, and authoritative note-effect/result children.
3. For queued duplicates, compare incoming digests using the stored digest format version from the full record or tombstone; unsupported stored versions produce `unsupportedDigestFormat`.
4. Separate already-incorporated entries from unincorporated candidates.
5. Identify affected notes from incoming flat changes for uncommitted batches and from authoritative children for persisted incorporated records.
6. Select complete candidate batches deterministically.
7. Build and validate the immutable merge plan, including bounded history, root-plus-exclusive-child full-record compaction, derived-summary validation, tombstone creation or verification, suppression, and presentation-pending decisions.
8. Create the dedicated convergence context with `autosaveEnabled = false`.
9. Refetch required managed records.
10. Acquire the outer scoped no-echo suppression token.
11. Apply the validated plan.
12. Save SwiftData once with incorporation and initial `presentationRefreshPending = true` when presentation is required.
13. Treat the successful save as authoritative incorporation.
14. Allow or perform suppressed context observation and presentation.
15. Verify editor/model presentation.
16. Clear pending-presentation state in an idempotent follow-up save when verification succeeds.
17. Release suppression after verification succeeds or after pending-presentation state is preserved.
18. Remove only fully incorporated queue entries.
19. Update retained legacy bookkeeping afterward.
20. Leave failed cleanup pending.
21. On retry or relaunch, consult SwiftData records, tombstones, authoritative children, and stored digest versions before application.
22. Skip already-incorporated batches.
23. Retry queue cleanup idempotently.
24. Retry retained legacy cleanup idempotently.
25. Retry presentation refresh idempotently under a new suppression token.
26. Never route editor mutation or emit outgoing sync a second time for a committed batch.

Crash behavior:

- before mutation: no effect; retry normally
- during mutation before save: disposable context; no authoritative commit; release suppression
- after save before presentation: committed; presentation pending survives relaunch; no reapply
- after presentation before pending clear: harmless extra verification or reload may occur; no replay; no outgoing capture
- during queue cleanup: committed; retry cleanup
- during legacy cleanup: committed; retry or remove compatibility cleanup
- after cleanup before drain completion: committed and cleaned; relaunch sees no queued work or skips residue by SwiftData/tombstone

Tombstone compaction crash behavior:

- before compaction mutation: the full record remains authoritative; no tombstone exists or is required; retry normally.
- during compaction mutation before save: the disposable context contains uncommitted tombstone creation and full-evidence deletion only; the persisted full record and children remain authoritative; no authoritative child deletion occurred; retry compaction from persisted state.
- save succeeds before caller observes completion: tombstone creation and full-evidence deletion committed atomically; the tombstone is authoritative; retry sees tombstone-only state; the batch is never reapplied.
- save fails: the full record and children remain authoritative; no partial tombstone transition exists; release any maintenance guard; retry later.
- same-evidence dual state discovered: this should not arise from the single-save design, but may arise from migration, manual corruption, or a prior implementation defect. Verify evidence and repair idempotently if identical; fail closed if contradictory.

Crash tests must fault-inject failure before compaction mutation, failure after in-memory tombstone creation but before save, compaction save failure, successful save with caller interruption, retry after successful compaction, same-evidence dual-state repair, and contradictory dual-state fail-closed behavior.

## Legacy Seen Stores

`SyncBatchSeenBatchStore` and `MacSyncSeenBatchStore` are retained temporarily as post-commit compatibility bookkeeping only. They are written only after SwiftData commit, or during cleanup-only processing for an already incorporated batch. SwiftData records and tombstones always win on disagreement. Legacy seen failure cannot invalidate a commit and may only set legacy cleanup pending. Removal milestone: after PR 3, once all supported incoming application paths and compatibility windows rely on SwiftData incorporation records and tombstones.

No legacy store may cause a committed batch to reapply, cause an uncommitted batch to be skipped, or participate in authoritative incorporation decisions.

## No-Echo Acceptance Tests

PR 2 must include iPhone and native Mac tests proving:

- suppression is acquired before save
- save-triggered observation occurs under suppression
- `@Query` and main-context refresh cannot emit outgoing capture
- matching-base remote application emits zero outgoing insert/delete operations
- conflict merge application emits zero outgoing insert/delete operations
- conflict merge application emits zero replacement operations
- no new outgoing batch is created
- selected-note application is suppressed
- non-selected-note application is suppressed
- whole-note fallback reload is suppressed
- nested rejected drain does not clear outer suppression
- save failure releases suppression
- post-save refresh retry acquires a new token and emits nothing
- suppression remains active until editor verification
- suppression is restored after thrown refresh/application errors
- matching-base selected-note routing remains incremental after authoritative commit
- conflict merge selected-note routing uses whole-note fallback after authoritative commit

## Required Targeted Test Additions

Suppression:

- suppression acquired before save
- save observation cannot echo
- nested rejection cannot release outer suppression
- save failure releases suppression
- presentation retry reacquires suppression

Presentation durability:

- pending flag written in authoritative commit
- crash before presentation
- crash after presentation before pending clear
- relaunch retry
- retry does not reapply or emit

Multi-note FIFO:

- A causes `{A, B}` batch deferral
- later B remains blocked
- later `{B, C}` transitively blocks C
- disjoint D may proceed
- relaunch preserves blocking
- clearing the original dependency releases affected notes deterministically

Evidence authority:

- affected-note children are authoritative
- root affected-note payload is derived
- deterministic summary rebuilding
- cache mismatch handling
- root affected-note mismatch is corrupt history, not inconsistent incorporation
- multi-note selection uses authoritative child membership
- no duplicate authoritative payloads
- no semantic evidence has two authoritative persisted copies
- contradictory authoritative children fail closed
- no double byte accounting
- compaction uses one authority
- tombstone compaction validates the derived affected-note summary
- deleting exclusive children leaves no duplicate authoritative root payload
- blocking and candidate evidence have one defined owner

Operation identity:

- global flat-array indexing
- no per-note restart
- one multi-note batch has globally unique indexes
- note A at index 0 and note B at index 1 produce distinct keys
- common identity across replay, persistence, and digest contracts
- replay key, retained-operation key, child identity key, and digest payload use the same index
- descriptive note mismatch is corruption
- reordering the flat array changes operation identities and payload digest
- relaunch preserves identities

Incorporation compaction:

- full root plus every exclusive child compacts to tombstone in one save
- no orphaned `IncorporatedBatchNoteEffect` remains
- independently protected history survives compaction
- independently protected diagnostics survive compaction
- same-evidence dual full-record/tombstone state repairs idempotently
- contradictory dual full-record/tombstone state fails closed
- tombstone-only state skips delayed duplicate application
- full-record-only state remains authoritative
- one multi-note batch is fully charged to every affected note
- successful compaction removes the charge from every affected note
- compaction save failure preserves the full record and children
- repeated compaction attempts are idempotent
- full-evidence child counts and bytes remain bounded
- delayed duplicate is skipped
- contradictory collision fails closed
- tombstone fixed-size limit
- no variable-sized tombstone evidence
- protected full evidence remains intact

Canonical digests:

- raw JSON key order cannot affect the digest
- semantically identical batches produce identical canonical digests
- differently ordered operations produce different digests when order is semantically significant
- optional absent and present-empty values follow normalized schema semantics
- sub-millisecond dates remain distinct
- full record and tombstone carry identical payload digest and digest-format version
- mutable post-commit state does not alter `committedResultDigest`
- cleanup attempt-count changes alter neither digest
- digest encoding is byte-stable across relaunch
- unsupported digest versions block without false contradiction
- contradictory payload under the same batch ID is detected
- note creations with different initial bodies, folder IDs, `createdAt`, `modifiedAt`, or titles produce different payload digests
- identical note-creation semantics produce the same digest regardless of transport JSON key ordering

Canonical bytes:

- golden binary vectors
- exact SHA-256 vectors
- annotated offsets for top-level version, discriminator, UUIDs, lengths, optionals, dates, and strings
- Unicode stability
- absent/present-empty distinction
- operation-order significance
- transport-JSON independence
- note-creation title/body/folder distinction
- persistence-layout independence
- exact change discriminator `0x00000001` for title change
- exact change discriminator `0x00000002` for body insert
- exact change discriminator `0x00000003` for body delete
- exact change discriminator `0x00000004` for reconciliation
- exact change discriminator `0x00000005` for note creation
- each committed-result discriminator value
- legacy and sequenced replay order-kind discriminator values
- exactly one change discriminator is encoded
- redundant body/reconciliation/creation discriminator bytes are absent
- changing a discriminator changes the digest
- unknown discriminators are rejected
- old discriminator assignments remain stable after new variants are introduced

Digest compatibility:

- one format version selects exactly one digest implementation
- payload and result records persist no separate encoder version
- comparison at stored version
- V1 tombstone compared after V2 exists
- incoming duplicate is computed with V1
- identical V1 semantics compare equal
- contradictory payload differs under V1
- historical digest-format implementation retention
- unsupported-version blocking
- no false contradiction
- no compatibility dispatch depends on a second version value
- changing any canonical byte rule requires a new format version
- restored historical support enables retry
- no tombstone rewrite during upgrade
- historical golden vectors remain stable

Deferred reasons:

- `SyncConvergenceDeferredReason` equality
- exhaustive switching over every deferred case
- controller mapping for every deferred case
- durable diagnostic conversion for every deferred case
- retry evidence for every deferred case

Compaction crash behavior:

- failure before compaction mutation
- failure after in-memory tombstone creation but before save
- compaction save failure
- successful compaction save with caller interruption
- retry after successful compaction
- same-evidence dual-state repair
- contradictory dual-state fail-closed behavior

Date precision:

- sub-millisecond distinction
- replay-order round trip
- legacy-order round trip
- title-LWW equality
- exact duplicate identity

Gate policy:

- `SyncBatchBodyHashCapability.defaultEnabled` remains false
- PR 2 does not enable hashed emission
- queued hashed work can still be processed under controlled tests

Frozen amendment:

- full incorporation evidence remains bounded
- tombstone encoding respects its fixed maximum
- tombstones retain sufficient duplicate and collision evidence
- no non-idempotency history is moved into permanent tombstones

## Proposed frozen-handoff amendment

Do not edit `docs/MYR-132-frozen-handoff.md` without explicit approval. The following amendment is proposed for review and later manual application:

> **Proposed amendment - permanent compact idempotency ledger**
>
> PR 2 code discovery confirms that the never-reapply invariant requires durable retention of incorporated batch identities. The current protocol contains no transport acknowledgement, globally bounded duplicate-delivery window, or other evidence that would make deletion of an old incorporated identity safe. Deleting all evidence for an incorporated batch could allow a delayed queue residue, restored backup, compatibility retry, or duplicate transport delivery to apply that batch again.
>
> PR 2 may therefore retain one permanent compact fixed-size tombstone per incorporated batch as an explicit exception to the global rejection criterion against unbounded state. This exception applies only to the irreducible batch-identity idempotency ledger. Full incorporation evidence, retained operations, snapshots, diagnostics, cleanup state, presentation state, and reconciliation evidence remain deterministically bounded and compactable.
>
> Each tombstone must have a versioned fixed maximum encoded size and retain only the batch identity and digests required to skip identical duplicates and fail closed on contradictory collisions. Tombstones may not retain note bodies, titles, operation arrays, variable-sized diagnostics, or other historical payloads. Tombstone deletion requires a future approved protocol amendment establishing a safe acknowledgement or expiry horizon.
>
> Permanent tombstone compatibility also requires retaining the complete historical digest-format implementation for every digest format version still present in full incorporation records or tombstones. That implementation includes the normalized semantic schema, numeric discriminator assignments, exact field order, primitive encoding, canonical byte generation, and SHA-256 hexadecimal representation. Historical digest-format implementations become compatibility code with golden-vector tests and may not be removed, rewritten, or used to rewrite old tombstone digests without a future approved migration or protocol amendment.

Amendment basis:

1. Concrete code-level finding: no current acknowledgement or safe duplicate-expiry horizon exists in the current transport, queue, or seen-store implementation.
2. Correctness risk: deleting identity evidence violates the frozen never-reapply invariant.
3. Required exception: permanent fixed-size tombstones for incorporated batch identities.
4. Updated tests and rejection criteria: tombstone retention, fixed-size enforcement, collision handling, relaunch preservation, stored-version digest comparison, complete historical digest-format implementation retention, and prohibition on variable-sized payloads.
5. Approval: the amendment is not effective until explicitly approved and appended to the frozen handoff.

## Decision Ledger

| Item | Frozen requirement | Final decision | Implementation choices | Repository evidence | Required tests | Approval status |
|---|---|---|---|---|---|---|
| 1 | SwiftData convergence state | Add concrete SwiftData models plus compact tombstones with one authoritative owner for each evidence fact | root identity/digest authority, normalized child evidence authority, derived affected-note summary, one digest version for semantics and bytes, canonical length-prefixed binary digests, note-creation digest fields, tombstone size | current schema lacks convergence models | model/key/evidence-authority/payload/digest/tombstone tests | pending amendment approval |
| 2 | dedicated context/autosave | `SyncConvergenceService` per transaction, `autosaveEnabled = false`, suppression before save | `@MainActor`, fresh context per transaction | current appliers mutate supplied context | context/no-echo/presentation tests | pending |
| 3 | immutable merge plan | `SyncConvergencePlan` includes projected bounded state, validation digest, authoritative-child membership, root-plus-child compaction actions, and before/after accounting | plan fields, digest checks, summary validation, child preservation, and validation | current coordinator applies directly | invalid plan, hard-limit, compaction-plan, summary-rebuild, and validation-digest tests | pending |
| 4 | authoritative incorporation | every incoming batch creates full record plus authoritative children, later atomically compacted to tombstone | `batchKey`, `tombstoneKey`, canonical payload digest, committed-result digest, affected-note child authority, stored-version duplicate comparison, no separately persisted encoder version, permanent historical digest-format implementation support, and dual-state rules | legacy seen authority today | retry/disagreement/digest-compatibility/golden-vector/tombstone/dual-state tests | pending amendment approval |
| 5 | post-commit cleanup | cleanup and presentation pending are post-commit state | queue/legacy/presentation flags | queue remove is separate | cleanup crash/retry tests | pending |
| 6 | iPhone rollback | iPhone uses shared transaction path | no legacy-only iPhone authority | iPhone lacks rollback snapshots | iPhone save failure tests | pending |
| 7 | shared core | Foundation-only core plus scoped suppression contract | service/core APIs | shared PR 1 utilities exist | shared core and no-echo tests | pending |
| 8 | canonical replay key | retain `SyncBatchReplayKey`; persist exact date bit patterns; freeze global flat-array `operationIndex` and digest discriminator domains | `(batchID, operationIndex)` identity across replay, persistence, digest payloads, title identity, and reconstruction history; replay order-kind and operation-kind numeric tables are frozen | existing replay key and PR 1 flat `batch.changes` enumeration | encoding/relaunch/date precision/global-index/discriminator tests | pending |
| 9 | mixed ordering | legacy kind before sequenced after earlier ties | accepted current comparator | existing `CanonicalBatchOrder` | mixed ordering tests | pending |
| 10 | sequence persistence | retain `SyncBatchSequenceStore` | no receiver synthesis | PR 1 sequence store/tests | sequence replay tests | pending |
| 11 | identity reset | retain identity namespace semantics | sequence records as evidence only | PR 1 identity tests | identity ordering tests | pending |
| 12 | history bounds | pre-commit soft/hard ceilings; full evidence bounded; conservative multi-note accounting without duplicate semantic counting; tombstones permanent by amendment | numeric ceilings are implementation choices; root bytes plus authoritative exclusive-child bytes charged to every affected note | no retained history today | bound/pressure/multi-note-accounting/no-double-count/tombstone tests | pending amendment approval |
| 13 | protected bases | explicit protection discovery, child ownership classification, atomic root-plus-children compaction, derived-summary validation, and compaction crash semantics | sources, release rules, child delete/preserve rules, one authority, and single-save crash boundaries | file queues retain batches | protection/compaction/summary/crash tests | pending |
| 14 | title LWW | persist `NoteTitleWinner` | canonical key payload with bit-pattern dates | current direct overwrite | title LWW tests | pending |
| 15 | deferral and gate | reconstructable mismatch plans; unreconstructable/reconciliation defer; unsupported digest format blocks; gate remains off | default capability remains false; unsupported digest format is not contradiction | PR 1 mismatch/reconciliation classifier | gate/upgrade/defer/unsupported-digest tests | pending |
| 16 | degraded status | durable deterministic diagnostics plus ephemeral transient errors and unsupported digest-format status | status precedence, distinct message, and clearing | current messages only | status persistence and unsupported-digest mapping tests | pending |
| 17 | episode grouping/completion | local generation key plus wire-visible grouping evidence | numeric retention is implementation choice | no episode state today | episode schema/relaunch tests | pending |
| 18 | dual-degraded crossing | group by note/candidate/divergence evidence, not local generation equality | decision table | reconciliation unsupported today | crossing/stale tests | pending |
| 19 | relaunch evidence | persist episode, diagnostic, cleanup, presentation, full record, and tombstone state | load before candidate selection | queue persists but episodes do not | relaunch evidence tests | pending amendment approval |
| 20 | modifiedAt skew | retain accepted `modifiedAt` first behavior | no skew correction; bit pattern persistence | existing replay key | skew/date precision tests | pending |

## Remaining Blockers

The permanent compact idempotency tombstone exception, including retention of complete historical digest-format implementations for every format version still present in full records or tombstones, remains blocked until the proposed frozen-handoff amendment is explicitly approved and appended to `docs/MYR-132-frozen-handoff.md`.

No other unresolved design decisions remain in this checkpoint.

**Checkpoint ready for review; implementation and the proposed frozen-handoff amendment still require explicit approval.**
