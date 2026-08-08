# MYR-177 Dependency and Bootstrap Alignment

## Scope

This record covers MYR-177 Slice 1 and Slice 2: durable structural-dependency recovery, deterministic retry, bootstrap admission and conflict isolation, explicit structural-foundation presence, and dark completion integration.

The approved reference set remains pinned to the exact revisions reviewed for MYR-177:

- Reference A: `64248a12829d04f62ddf3230c6c592f6226b57ab`
- Reference B: `cdeb8053c3aa2510189429d717ab09e70f134716`
- Reference C: `5fa067b182ddda3ea2477c4d5e4054da7318973f`
- Reference D: `89c162d3c1ae02c426c9002419aef0814e779ed8`
- Reference E: `26f9425ef74d45937e00d6c8ec2e8bb12889013d`

Repository names, organizations, URLs, and copied external source remain intentionally omitted. Slice 2 carries these approved revisions forward without substituting later or inferred reference content.

## External-reference traceability

The neutral behavior mapping below records the approved observations used by MYR-177 and the deliberate MyRAM adaptations. It does not claim source equivalence between the references and MyRAM.

| MYR-177 behavior | Approved reference behavior reviewed | MyRAM adoption or deliberate divergence | Persistence / compatibility / recovery impact | Production location | Exact proof | Deferred owner |
|---|---|---|---|---|---|---|
| Out-of-order insertion anchors | References D and E preserve stable structural/element identity and anchor metadata instead of treating current visible offsets as authority. | Adopt stable element identity and defer only exact `missingAnchorDependency`; never reconstruct a positional anchor. | Exact original anchored insertion remains recoverable across restart; legacy offsets remain compatibility-only. | `SyncBatchAnchoredRecoveryTypes.swift`; `SyncBatchAnchoredRecoveryPlanner.swift` | `testInitialMissingInsertionCreatesExactWaitingRecord`; `testInsertionRetriesAfterParentArrivalAndProducesRemovalPlan`; native Mac mirrored recovery test | MYR-179 production wiring |
| Out-of-order deletion targets | References D and E retain deleted structural identity rather than removing all evidence of deleted content. | Adopt operation-identity-targeted waiting for exact `missingDeleteDependency`; retain tombstones as structural availability. | Delete intent survives restart without retargeting spans or using visible text. | `SyncBatchAnchoredRecoveryTypes.swift`; `SyncBatchAnchoredRecoveryPlanner.swift` | `testDeletionWaitsForTargetThenTombstonesIt`; native Mac exact-range deletion retry | MYR-179 production wiring |
| Durable unresolved operation and payload preservation | References A and B separate durable synchronization/document state from transient orchestration; Reference D keeps stable operation identity through causal processing. | Store the exact validated anchored change in a narrowly owned versioned recovery record rather than persisting peer-session state or whole-document change chunks. | Recovery records are deterministic, restartable, and collision-protected. The dark recovery-store format is independent of transport and SwiftData schema. | `SyncBatchAnchoredRecoveryTypes.swift`; `FileBackedSyncBatchAnchoredRecoveryStore.swift` | deterministic store round-trip, same-key collision, corruption/version, and write-rollback tests | MYR-179 consumes the durable plan/store contract |
| Dependency indexing and chained retry | Reference D records explicit causal dependencies rather than repeatedly polling all state. | Adopt an operation-ID-indexed deterministic worklist. Deliberately retain durable waiting instead of a volatile/timer-only queue. | No arbitrary expiry; newly exposed operations can progress a bounded dependency chain and exact reindexing survives restart. | `SyncBatchAnchoredRecoveryPlanner.swift` | `testRetryReindexesFromOneMissingAnchorToAnother`; `testMultiLevelInsertionChainProgressesInOneDeterministicPlan`; deterministic ordering tests | MYR-179 schedules production retries |
| Duplicate delivery and identity collision | References A and D preserve stable change/operation identities; Reference B protects durable state from replacement until the replacement is safely committed. | Preserve core duplicate validation. Add only a narrow applied-equivalence exception when an existing durable recovery record proves interrupted cleanup; same identity with different content remains terminal. | Prevents duplicate visible application while preserving collision evidence and existing durable data. | `SyncBatchAnchoredRecoveryPlanner.swift`; `FileBackedSyncBatchAnchoredRecoveryStore.swift` | fresh duplicate-run, interrupted-cleanup applied-equivalence, non-equivalent collision, conflicting-redelivery tests | MYR-179 acknowledgement/cleanup ordering |
| State committed before recovery cleanup | Reference B persists replacement document state before discarding incremental recovery material; Reference A separates durable state from transient session progress. | Adopt the same ordering invariant for future activation: plan, persist application state, durably mutate recovery store, then acknowledge. Slice 2 does not activate it. | A crash or write failure after application commit leaves the recovery record available for exact applied-equivalence cleanup. | immutable commit plan plus file-backed recovery store | `testFileBackedInterruptedCleanupSurvivesRestartAndCleansUpExactly`; write-failure rollback tests | MYR-179 transaction wiring and acknowledgement |
| Restart and interrupted-transition recovery | References A and B reconstruct synchronization state from durable state after interruption rather than trusting transient in-memory progress. | Rebuild the deterministic recovery snapshot/index from the versioned recovery file and retain explicit unhealthy-state handling. | Missing, corrupt, unsupported-version, and failed-write states remain distinguishable; no silent record loss. | `FileBackedSyncBatchAnchoredRecoveryStore.swift` | restart, corruption, unsupported-version, full-replacement, rollback tests | MYR-179 active recovery entry point |
| Malformed and impossible structural references | References D and E preserve structural identities and do not make visible-offset repair authoritative for structural edits. | Deliberately classify only the two locked missing-dependency errors as waitable. Every other current/future structural validation failure is typed terminal unless separately reviewed. | Prevents malformed anchors/delete ranges from being normalized into a different operation. | recovery error classification and planner | out-of-bounds anchor, impossible delete range, terminal-transition tests | Separately reviewed future change if allowlist expands |
| Dependency deferral versus content/rewrite conflict | Reference C separates host synchronization ownership, persistence, and UI publication concerns; D/E keep structural causality distinct from visible-text placement. | Keep structural waiting, terminal structural failure, and bootstrap-content conflict as separate lifecycle states. Never route bootstrap conflicts through generic rewrite-safety handling. | Conflict evidence is durable without changing transport, editor, or acknowledgement behavior. | `SyncBatchAnchoredRecoveryTypes.swift`; planner | bootstrap lifecycle invariant tests; rewrite/activation audits | MYR-179 production consumption; later UI work if approved |
| Immediate bootstrap-content conflict | References C, D, and E support preserving existing durable/structural authority instead of rebuilding it from current visible text when histories differ. | A bootstrap is admissible only with no established foundation, idempotent only when the canonical structural state is already represented, otherwise an immediate bootstrap-content conflict. | Rejected bootstrap cannot mutate structural state or expose its operation; exact conflict evidence is persisted in the recovery store. | `SyncTextLegacyBootstrap.swift`; recovery types/planner | same-visible-text/different-structure conflict; different bootstrap against established bootstrap; conflict persistence/restart/write-failure tests | MYR-179 consumes outcome; no user-facing UI in MYR-177 |
| Late bootstrap after ordinary edits | References D and E preserve edit structure/identity rather than authorizing a later whole-body snapshot to replace that structure. | Deliberately treat any non-equivalent edited structural state as bootstrap conflict. | Existing edits stay authoritative; bootstrap cannot reset the note to its earlier snapshot. | `SyncBatchAnchoredRecoveryPlanner.swift` | `SyncBatchAnchoredBootstrapConflictCoverageTests.testLateBootstrapAfterOrdinaryEditCreatesConflict` in `SyncBatchTransportAdmissionPlannerTests.swift` on iOS and native Mac | MYR-179 production activation |
| Late bootstrap after tombstones | References D and E retain deleted structural history. | Reject a bootstrap when the established state contains non-equivalent tombstone history; preserve that history as conflict evidence. | Prevents deleted content resurrection. | recovery types/planner | tombstone-history conflict/non-resurrection tests on iOS and native Mac | MYR-179 production activation |
| Indefinite ordinary deferral | Reference D models causal dependencies explicitly; approved review did not establish durable safety for dropping valid unresolved operations on a timer. | Deliberately add no arbitrary timeout or expiry. | A valid waiting record remains durable until its dependency arrives or later replay yields a typed terminal result. | recovery store/planner | restart and deterministic retry tests; no-expiry source audit | MYR-179 retry scheduling |
| Host and activation separation | Reference C separates host persistence/synchronization ownership from presentation publication. | Keep one shared dark planner/recovery representation for iPhone and native Mac; do not activate queue admission, convergence, persistence, editors, or acknowledgements. | No transport, acknowledgement, SwiftData schema, or live behavior compatibility change. | shared `MyRAM/Sync/Batch` sources | mirrored host tests plus capability-off/zero-reachability/transport/schema audits | MYR-179 activation; MYR-180 live two-device closure |

## Durable recovery and interruption ordering

Slice 1 established a versioned file-backed recovery store, exact anchored-change preservation, deterministic restart reconstruction, persisted store health, compare-and-swap transitions, atomic replacement, and rollback on write failure.

The ordering contract remains:

1. plan without mutation;
2. persist application state;
3. durably apply recovery-store transitions;
4. acknowledge only after both boundaries succeed.

Slice 2 does not activate that transaction. MYR-179 remains responsible for production application-state persistence, recovery cleanup ordering, publication, and acknowledgement.

Production locations:

- `MyRAM/Sync/Batch/SyncBatchAnchoredRecoveryTypes.swift`
- `MyRAM/Sync/Batch/SyncBatchAnchoredRecoveryPlanner.swift`
- `MyRAM/Sync/Batch/FileBackedSyncBatchAnchoredRecoveryStore.swift`

Representative retained tests:

- `SyncBatchAnchoredRecoveryPlannerTests.testFileBackedInterruptedCleanupSurvivesRestartAndCleansUpExactly`
- `SyncBatchAnchoredRecoveryStoreTests.testWriteFailureRollsBackMemoryAndDiskAndMarksWriteFailure`
- `SyncBatchAnchoredRecoveryStoreTests.testCorruptAndUnsupportedVersionRemainDistinct`

## Structural identity and deterministic retry

MYR-177 continues to treat stable operation and element identity, not visible offsets, as replay authority. Recovery preserves complete missing insertion anchors and missing deletion-target operation IDs. Tombstoned runs remain structurally represented and can satisfy dependencies.

Slice 2 retains the Slice 1 bounded worklist and extends initial planning so a newly represented operation can progress newly satisfiable waiting records in the same immutable plan. Reindexing remains exact when replay reveals another dependency, and transition collapse is still computed against the original durable snapshot.

Representative tests:

- `SyncBatchAnchoredRecoveryPlannerTests.testRetryReindexesFromOneMissingAnchorToAnother`
- `SyncBatchAnchoredRecoveryPlannerTests.testMultiLevelInsertionChainProgressesInOneDeterministicPlan`
- `SyncBatchAnchoredRecoveryPlannerTests.testSameAnchorSnapshotOrderDoesNotChangePlan`
- `SyncBatchAnchoredRecoveryPlannerTests.testNonemptyBootstrapUnblocksWaitingDependentInSameInitialPlan`
- `SyncBatchAnchoredRecoveryTests.testNativeMacBootstrapUnblocksWaitingDependentInSamePlan`

## Duplicate and collision semantics preserved from Slice 1

Slice 2 preserves the merged Slice 1 rules exactly:

- fresh structural duplicates retain normal `AnchoredSequenceCore` validation;
- applied equivalence is available only when an existing durable recovery record proves interrupted cleanup;
- same-key/different-content redelivery of a waiting record terminalizes the original stored change as identity collision;
- conflicting redelivery against an already-terminal record cannot rewrite the durable terminal record.

Bootstrap handling does not weaken these rules or reuse applied-equivalence as general duplicate acceptance.

## Deterministic bootstrap descriptor and foundation admission

`AnchoredSequenceCore` exposes `SyncTextLegacyBootstrapDescriptor`, containing the deterministic synthetic bootstrap `operationID` and canonical `SyncTextSequenceState`.

Identity derivation is versioned and based on the note ID plus exact UTF-16 body. Empty content produces canonical `.empty` sequence state while the descriptor still deterministically derives its synthetic identity. The approved Slice 2 foundation contract remains deliberately minimal:

- `.absent`
- `.established(SyncTextSequenceState)`

An absent foundation is not an established empty document. An admissible empty bootstrap therefore transitions `.absent` to `.established(.empty)` and reports an application-state change. A subsequent equivalent empty bootstrap against that established empty foundation is idempotent and reports no application-state change. This is the approved dark foundation representation; MYR-177 does not add a second provenance store or SwiftData field for empty bootstrap identity.

Ordinary anchored insertion, deletion, dependency retry, and restart recovery require `.established` and fail closed with `missingStructuralFoundation(noteID:)` when the foundation is absent.

## Bootstrap classification and conflict isolation

A validated bootstrap change stores the note ID, exact body, supported format version, and core-derived operation ID. Construction and decoding recompute the descriptor identity and reject unsupported or tampered input.

Classification is structural:

- absent foundation: admissible;
- established state exactly equal to the canonical bootstrap state: idempotent;
- any other established structural state: bootstrap-content conflict.

Visible-text equality does not establish equivalence. A different canonical bootstrap, later ordinary edit history, or tombstoned history therefore conflicts rather than replacing established structure. Rejected bootstrap exposes no structural operation and does not enter dependency waiting or rewrite-safety handling.

Representative tests:

- `SyncBatchAnchoredRecoveryPlannerTests.testEquivalentNonemptyBootstrapIsIdempotentAndExposesRepresentedOperation`
- `SyncBatchAnchoredRecoveryPlannerTests.testSameVisibleTextWithDifferentStructureCreatesBootstrapConflict`
- `SyncBatchAnchoredRecoveryPlannerTests.testTombstoneHistoryConflictsAndLateBootstrapCannotResurrectContent`
- `SyncBatchAnchoredBootstrapConflictCoverageTests.testDifferentBootstrapAgainstEstablishedBootstrapCreatesConflict` in both host transport-admission test files
- `SyncBatchAnchoredBootstrapConflictCoverageTests.testLateBootstrapAfterOrdinaryEditCreatesConflict` in both host transport-admission test files

## Recovery-owned structural conflict evidence

Bootstrap conflicts persist the exact validated incoming bootstrap change plus recovery-owned structural evidence for the established sequence state. Evidence contains run operation IDs, insertion-origin endpoints, exact run text, fragment operation IDs, fragment ranges, and visibility/tombstone state.

Evidence reconstruction passes through normal `SyncTextInsertionOrigin`, `SyncTextSequenceRun`, `SyncTextSequenceFragment`, and `SyncTextSequenceState` validation. The representation does not depend on SwiftData records, revision fields, or sequence-persistence payload metadata.

Conflict reasons remain intentionally minimal:

- `nonEquivalentEstablishedState`
- `tombstoneHistory`

Persisted reason and evidence must agree; malformed or forged mismatches are rejected.

## Host and activation boundaries

The Slice 2 planner and recovery types remain shared source used by the iPhone and native Mac targets. No duplicated platform production implementation is introduced.

The production activation boundary remains unchanged:

- anchored capability remains disabled;
- the dark recovery planner has no active production caller;
- no anchored queue admission, capture, emission, convergence submission, editor publication, persistence wiring, or acknowledgement is added;
- no raw-offset fallback or general replay-time `baseContentHash` gate is introduced;
- SwiftData schema and transport formats remain unchanged.

MYR-179 remains the sole production activation boundary. MYR-180 remains responsible for live two-device closure.

Exact-head target membership, zero-production-reachability, capability, transport, schema, editor, acknowledgement, offset/hash, `NearbySyncCore`, and changed-scope audits remain required by the Slice 2 local completion runner.
