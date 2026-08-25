# MYR-180 Stage 2 Aggregate Structural Alignment

## Authority and consumed artifacts

This is the final aggregate external-reference alignment and deliberate-divergence record for Stage 2. It consumes the committed final records produced by MYR-175 through MYR-179 rather than reconstructing their decisions from Jira comments or PR prose.

Consumed committed artifacts:

- `docs/MYR-175-structural-insert-alignment.md`
- `docs/MYR-175-completion-verification-evidence.md`
- `docs/MYR-176-delete-tombstone-alignment.md`
- `docs/MYR-176-completion-verification-evidence.md`
- `docs/MYR-177-dependency-bootstrap-alignment.md`
- `docs/MYR-177-completion-verification-evidence.md`
- `docs/MYR-178-anchorless-compatibility-preservation.md`
- `docs/MYR-179-activation-alignment.md`
- `docs/MYR-179-completion-verification-evidence.md`
- `docs/MYR-180-slice-1-offset-rebase-retirement-audit.md`

The approved external structural-editing reference set remains external to this repository. This record intentionally names neither those repositories nor their locations. Only the neutral behaviors adopted or deliberately diverged from are recorded here.

## Final Stage 2 structural authority

Anchored work and pre-migration anchorless compatibility are separate proof domains.

Anchored V2 note-body work uses structural operation and element identity as the sole placement/deletion authority. It cannot fall back to raw visible offsets, UTF-16 offset rebasing, body similarity, substring repair, or reconstructed positional placement. The active structural route is capture → V2 transport → anchored convergence planning/recovery → structural replay → atomic body/sequence persistence → recovery durability → presentation/queue/acknowledgement completion.

Pre-migration anchorless work remains isolated behind the MYR-178 exact-base evidence contract. Current-body positional replay requires exact matching-base eligibility. Divergent work can enter historical replay only after exact historical-base reconstruction. Unproven or unreconstructable work remains recoverable and durably retained rather than being guessed into place.

MYR-180 Slice 1 confirmed that the remaining UTF-16 rebase algorithm is reachable only in that reconstructed legacy conflict domain. It renamed/narrowed the surface instead of deleting required compatibility behavior. Anchored structural planning is disjoint from it.

## Adopted mechanisms

### Same-anchor and concurrent insertion ordering

Established behavior: stable operation identity, rather than receipt order, determines concurrent structural placement.

MyRAM adoption:

- Same-gap sibling materialization is deterministic and independent of delivery order.
- The structural subtree rooted at each sibling remains contiguous.
- Canonical run storage remains separate from visible same-anchor sibling materialization.

Production locations:

- `Packages/AnchoredSequenceCore/Sources/AnchoredSequenceCore/SyncOperationIDOrder.swift`
- `Packages/AnchoredSequenceCore/Sources/AnchoredSequenceCore/SyncTextSequenceState.swift`
- `MyRAM/Sync/Batch/SyncBatchAnchoredInsertReplay.swift`

Exact proving evidence:

- `SyncTextSequenceStateTests.testSameAnchorSiblingOrderingIsIndependentOfInputPermutation`
- `SyncTextSequenceStateTests.testSameAnchorSiblingSubtreesRemainContiguous`
- `SyncBatchAnchoredInsertReplayTests.testSameAnchorReplayConvergesAcrossArrivalOrders`
- `MYR180DeterministicTwoReplicaAcceptanceTests.testGONEHAHAOfflineEditsConvergeAcrossTransportArrivalOrderAndPersistenceRestart`

Compatibility/migration impact: existing compact runs/fragments and persisted format remain intact. Peers with the same structural state derive one visible projection regardless of arrival order.

### Sibling and subtree placement

Established behavior: descendants remain attached to structural ancestry rather than participating in one global visible-offset sort.

MyRAM adoption: exact durable gaps identify insertion origin, same-anchor sibling roots are ordered deterministically, and iterative structural traversal keeps descendants with their root subtree.

Production locations:

- `SyncTextSequenceState.incorporating(insert:insertedText:)`
- `SyncTextSequenceStateValidator.makeGapIndex`
- `SyncTextSequenceStateValidator.deriveStructuralSpans`

Exact proving evidence:

- canonical gap/cursor and permutation tests recorded in `docs/MYR-175-structural-insert-alignment.md`
- `SyncBatchAnchoredInsertReplayTests.testSameAnchorReplayConvergesAcrossArrivalOrders`

Compatibility/migration impact: no receiver-side reinterpretation of an incoming anchor and no schema expansion.

### Identity-targeted deletion and tombstone retention

Established behavior: deletions target stable structural identity and deleted structure remains available to causally dependent edits.

MyRAM adoption: deletion payloads carry `SyncTextElementIDSpan` targets. Incorporation tombstones only those identities, leaves immutable runs intact, and is idempotent on repeated delivery.

Production locations:

- `SyncTextSequenceState.elementIDSpans(inVisibleUTF16Range:)`
- `SyncTextSequenceState.incorporating(delete:)`
- `MyRAM/Sync/Batch/SyncBatchAnchoredInsertReplay.swift` (`SyncBatchAnchoredDeleteReplay`)

Exact proving evidence:

- `SyncTextSequenceDeletionTests.testCapturedIdentityDeletionIgnoresLaterInsertedIdentity`
- `SyncTextSequenceDeletionTests.testRepeatedAndPartiallyRepeatedDeletionIsIdempotent`
- `SyncBatchAnchoredDeleteReplayTests.testRepeatedAndPartiallyRepeatedReplayIsIdempotent`

Compatibility/migration impact: tombstones retain history and therefore storage, but dependent anchors cannot be invalidated by deletion. No compaction contract is introduced.

### Insert-versus-delete convergence

Established behavior: deletion of captured identities does not erase concurrently inserted identities that were not targeted.

MyRAM adoption: insertion and deletion are independent structural operations; a delete is never retargeted through the current visible text.

Production locations:

- `SyncTextSequenceState.incorporating(insert:insertedText:)`
- `SyncTextSequenceState.incorporating(delete:)`
- `SyncBatchAnchoredInsertReplay`
- `SyncBatchAnchoredDeleteReplay`

Exact proving evidence:

- `SyncTextSequenceDeletionTests.testInsertAfterDeletedAnchorConvergesAcrossDeliveryOrder`
- `SyncBatchAnchoredDeleteReplayTests.testInsertDeleteReplayConvergesAcrossArrivalOrders`
- `SyncBatchAnchoredDeleteReplayTests.testInsertionCanUseDeletedAnchor`

Compatibility/migration impact: delivery permutations converge without raw-offset repair, while tombstoned identity remains a valid anchor.

### Missing-anchor deferral and deterministic retry

Established behavior: temporary structural dependency absence is distinct from malformed input and survives interruption.

MyRAM adoption: only exact missing insertion/deletion dependency errors enter durable waiting. Exact validated anchored changes are retained and indexed by missing operation identity; arrival, restart, and reindexing retry deterministically.

Production locations:

- `MyRAM/Sync/Batch/SyncBatchAnchoredRecoveryTypes.swift`
- `MyRAM/Sync/Batch/SyncBatchAnchoredRecoveryPlanner.swift`
- `MyRAM/Sync/Batch/FileBackedSyncBatchAnchoredRecoveryStore.swift`

Exact proving evidence:

- `SyncBatchAnchoredRecoveryPlannerTests.testRetryReindexesFromOneMissingAnchorToAnother`
- `SyncBatchAnchoredRecoveryPlannerTests.testMultiLevelInsertionChainProgressesInOneDeterministicPlan`
- file-backed restart/interrupted-cleanup tests named in `docs/MYR-177-dependency-bootstrap-alignment.md`

Compatibility/migration impact: no timeout, guessed offset, or lossy queue cleanup is added. Unresolved valid operations remain recoverable.

### Impossible-reference and bootstrap-content conflict classification

Established behavior: malformed structural references and conflicting snapshots are not repaired into a different edit.

MyRAM adoption:

- missing dependencies are waitable only through the locked missing-dependency classifications;
- impossible ranges/references remain terminal structural failures;
- non-equivalent bootstrap against established structural state is a distinct durable bootstrap-content conflict;
- later bootstrap cannot replace ordinary edit or tombstone history.

Production locations:

- `SyncTextSequenceStateError`
- `SyncBatchAnchoredRecoveryPlanner`
- `SyncTextLegacyBootstrap`

Exact proving evidence:

- insertion/deletion exact-error tests identified in MYR-175/MYR-176 records
- `SyncBatchAnchoredBootstrapConflictCoverageTests.testDifferentBootstrapAgainstEstablishedBootstrapCreatesConflict`
- `SyncBatchAnchoredBootstrapConflictCoverageTests.testLateBootstrapAfterOrdinaryEditCreatesConflict`
- tombstone-history conflict/non-resurrection recovery tests

Compatibility/migration impact: conflicts remain observable/recoverable without replacing established structure or changing transport/SwiftData schemas.

### Legacy anchorless replay isolation

Established behavior: a positional operation is safe only against the exact body that gave the position meaning.

MyRAM adoption: `SyncBatchAnchorlessCompatibilityEvaluator` is the direct current-body eligibility authority. Positive eligibility requires exact declared-base hash proof. Divergent current-body work can be replayed only after exact historical-base reconstruction; unavailable evidence and unreconstructable bases remain retained/recoverable.

Production locations:

- `MyRAM/Sync/Batch/SyncBatchAnchoredPayloadPolicy.swift`
- `MyRAM/Sync/Convergence/SyncConvergencePlanner.swift`
- `SyncOperationReplayEngine.planMatchingBase`
- the narrowly named reconstructed legacy conflict replay path

Exact proving evidence:

- MYR-178 matching/mismatch/hashless classification tests
- MYR-178 real controller resend/redelivery acknowledgement tests
- MYR-180 Slice 1 unchanged legacy concurrent-edit/rebase regressions
- MYR-180 anchored-route bypass regression

Compatibility/migration impact: legitimate pre-migration traffic is preserved without allowing legacy positional logic to become an anchored fallback.

### Visible materialization and rich-text positioning boundary

Established behavior: structural state is authoritative for ordering/identity while host presentation owns platform text application.

MyRAM adoption: structural runs/fragments derive authoritative visible text. Host presentation/editor seams consume committed results after persistence/recovery durability; retained compatibility offsets are not structural authority.

Production locations:

- `SyncTextSequenceState.visibleText`
- `SyncConvergencePostCommitExecutor`
- iPhone convergence/presentation path in `NotesViewModel`
- native Mac `MacSyncConvergencePresentationAdapter` and `MacEditorSyncBridge`

Exact proving evidence:

- fragment projection and structural equality tests from MYR-175/MYR-176
- MYR-179 post-commit ordering/presentation tests
- MYR-179 exact-candidate iOS and Mac suites

Compatibility/migration impact: rich-text/editor positioning remains host-owned after authoritative structural convergence; no structural identity is inferred from presentation offsets.

### Atomic activation consistency across capture, transport, persistence, replay, iPhone, and native Mac

Established behavior: one activated representation should remain coherent through the full synchronization lifecycle and success effects should occur only after durable commit.

MyRAM adoption: `SyncBatchAnchoredPayloadCapability.isEnabled` is the sole production activation source. V2 admission, operation-ID reservation, structural capture/replay, convergence persistence, recovery transition, presentation, queue cleanup, and acknowledgement are ordered behind that authority.

Production locations:

- `SyncBatchAnchoredPayloadCapability.isEnabled`
- `SyncBatchAnchoredLocalCapture`
- `SyncBatchTransportAdmissionPlanner`
- `SyncConvergenceRuntime`
- `SwiftDataSyncConvergencePersistenceTransaction`
- `SyncConvergencePostCommitExecutor`
- `MyRAMSyncController`
- `MacSyncBatchController`

Exact proving evidence:

- MYR-179 focused activation/persistence/controller/coordinator matrices
- complete iOS application/UI and native Mac suites recorded in `docs/MYR-179-completion-verification-evidence.md`
- activated V2 outer/inner transport round-trip in `SyncBatchEnvelopeV2Tests.testOuterV1CarriesInnerV2ThroughActivatedProductionTransport`
- deterministic Stage 2 two-replica acceptance test

Compatibility/migration impact: one atomic production mode replaces the earlier dark seams without changing SwiftData schema, acknowledgement wire format, or `NearbySyncCore`.

### Obsolete offset-rebase retirement

Established structural behavior: anchored operations derive placement from identity, not transformed visible offsets.

MyRAM adoption: MYR-180 Slice 1 audited every remaining rebase helper and proved the algorithm is still required only inside exact-historical-base pre-migration anchorless conflict replay. The generic names were retired/narrowed; the required compatibility algorithm was preserved.

Production location:

- legacy reconstructed-conflict helpers in `SyncConvergencePlanner.swift`
- anchored work remains routed through `SyncConvergenceAnchoredBatchPlanner`

Exact proving evidence:

- `SyncConvergencePlanningTests.testConcurrentInsertsRebaseOffsetsInsteadOfCorruptingLaterText`
- `SyncConvergencePlanningTests.testConcurrentDeleteRebasesLaterInsertOffsetBackward`
- `SyncConvergencePlanningTests.testConcurrentEditsConvergeToIdenticalBodyRegardlessOfWhichSideIsLocal`
- `SyncConvergencePlanningTests.testMYR180AnchoredStructuralPlanningBypassesLegacyConflictRebasePath`

Compatibility/migration impact: no anchored offset fallback remains, while safe MYR-178 historical compatibility is not destroyed by cleanup.

## Deliberate divergences

### Locked same-anchor comparator

MyRAM requirement: among siblings occupying the same exact structural gap, larger `localCounter` materializes first; equal counters use raw RFC 4122 device bytes ascending.

Why not adopt an external comparator unchanged: the approved references establish stable identity/deterministic placement but do not define MyRAM's application-specific comparator contract.

Impact: canonical run serialization is unchanged; all peers implementing Stage 2 derive the same sibling projection. The deterministic `GONE` / `HAHA` acceptance freezes this comparator result before convergence: with fixed counters 1 and 2, the expected visible body is `HAHAGONE`.

Production location: `SyncOperationIDSameAnchorSiblingOrder` and the exact-gap ordering path in `SyncTextSequenceStateValidator`.

Targeted verification: MYR-175 comparator/permutation tests and `MYR180DeterministicTwoReplicaAcceptanceTests.testGONEHAHAOfflineEditsConvergeAcrossTransportArrivalOrderAndPersistenceRestart`.

Required Stage 2 acceptance evidence: deterministic two-replica production-seam transport/replay/persistence/restart test; no human-operated UI choreography remains part of the final acceptance contract.

### Indefinite tombstone retention

MyRAM requirement: retain deletion identity during this migration until a separately approved causal-stability/peer-retirement contract exists.

Why not adopt compaction: safe compaction requires information Stage 2 does not possess.

Impact: storage can grow with deletion history, but anchors cannot disappear while peers may still reference them.

Production location: structural deletion incorporation preserves immutable runs and emits tombstone fragments.

Targeted verification: full-run retention, deleted-anchor insertion, and insert/delete convergence tests from MYR-176.

### Durable explicit recovery lifecycle

MyRAM requirement: restartable missing-dependency and conflict handling must be independently observable and must not rely on transient peer-session state.

Why not copy an external recovery representation: the reference systems use different persistence/document boundaries. MyRAM retains a narrow versioned recovery record containing exact validated structural work and evidence.

Impact: waiting, terminal structural failure, and bootstrap-content conflict remain distinct and restartable without SwiftData schema or transport changes.

Production location: MYR-177 recovery types/planner/file-backed store.

Targeted verification: deterministic retry, restart, corruption/version, transition rollback, bootstrap conflict, and interrupted-cleanup tests.

### Guarded anchorless compatibility retained after structural activation

MyRAM requirement: pre-migration payloads cannot be discarded merely because V2 anchored structural work is active.

Why not remove all positional replay: exact-base legacy payloads and exactly reconstructed historical conflicts remain valid compatibility work. Deleting that path would violate MYR-178 and strand legitimate persisted traffic.

Impact: two positional proof domains remain isolated from anchored structural authority. Unproven work stays queued instead of being mutated or acknowledged.

Production location: `SyncBatchAnchorlessCompatibilityEvaluator`, exact-base replay, and narrowly scoped reconstructed legacy conflict replay.

Targeted verification: MYR-178 compatibility/retransmission tests plus MYR-180 Slice 1 legacy convergence and anchored-bypass regressions.

### MyRAM atomic activation and post-commit ordering

MyRAM requirement: structural persistence, recovery durability, editor publication, queue cleanup, and acknowledgement must not expose partial success.

Why not adopt a reference lifecycle unchanged: host persistence, SwiftData, acknowledgement, and editor publication are MyRAM-specific boundaries.

Impact: activation is one capability decision and success effects are ordered after durable structural application/recovery. V1 compatibility and existing schemas remain preserved.

Production location: MYR-179 activation planner, convergence transaction/runtime/post-commit executor, and both host controllers.

Targeted verification: MYR-179 activation matrices, rollback/restart tests, complete host suites, and Stage 2 deterministic transport/replay/persistence acceptance.

## Deterministic Stage 2 convergence acceptance

The user-directed final acceptance replaces the repeatedly defective human-operated terminal/UI choreography with a deterministic two-replica production-seam proof. It preserves the actual convergence question while removing the user from the verification mechanism.

Scenario:

1. Both replicas begin from the same empty structural note.
2. Mac replica captures an anchored root insertion `GONE` with fixed operation identity `(Mac device, counter 1)`.
3. Simulator replica independently captures an anchored root insertion `HAHA` with fixed operation identity `(Simulator device, counter 2)`.
4. Each batch is encoded by activated `MultipeerSyncMessageCoding.encodeBatch`, decoded through the production outer message and V2 inner batch envelope, and verified unchanged.
5. Each replica first applies its own operation while isolated.
6. Mac then receives `HAHA`; simulator then receives `GONE`, producing opposite arrival orders.
7. Before asserting convergence, the locked comparator freezes the expected body as `HAHAGONE` because counter 2 precedes counter 1 for the same root gap.
8. Both replicas must produce exactly equal `SyncTextSequenceState` values, not merely equal text.
9. The converged state must contain both operation identities exactly once, two visible fragments, no tombstones, no dropped or duplicated text, and the expected UTF-16 count.
10. Both states are encoded by `NoteSequenceStatePersistenceCodec`; canonical payload bytes must match.
11. Each payload is decoded through `NoteSequenceStatePersistenceCodec.decodeStructurallyValidatedState`, representing restart persistence; both restarted states must remain exactly equal and materialize `HAHAGONE`.

Exact proving test:

`MYR180DeterministicTwoReplicaAcceptanceTests.testGONEHAHAOfflineEditsConvergeAcrossTransportArrivalOrderAndPersistenceRestart`

The previously observed 94 Mac pending-incoming identities are historical pre-existing anchorless compatibility backlog, not Stage 2 acceptance work. The validated collector classified them as the preserved baseline. The deterministic acceptance creates no runtime queue residue and does not mutate, delete, reset, or reinterpret that historical state. MYR-178 compatibility tests remain the authority proving such unproven historical work is retained rather than unsafely replayed or acknowledged.

## Stage 2 conclusion

The aggregate record establishes one coherent boundary:

- anchored insert/delete placement and convergence are structural and identity-based;
- missing structural dependencies and conflicts are durably recoverable without positional repair;
- pre-migration anchorless replay remains separately guarded by exact-base proof;
- atomic activation carries the structural contract through transport, persistence, presentation, cleanup, and acknowledgement on iPhone and native Mac;
- the only remaining offset-rebase behavior is explicitly legacy reconstructed-conflict compatibility and is unreachable from anchored work;
- the deterministic `GONE` / `HAHA` acceptance proves the historical corruption shape cannot depend on arrival order and survives transport encoding plus persisted-state restart.

No additional structural ordering, deletion, tombstone, dependency, bootstrap, materialization, persistence, transport, or acknowledgement mechanism is introduced by MYR-180 Slice 2.
