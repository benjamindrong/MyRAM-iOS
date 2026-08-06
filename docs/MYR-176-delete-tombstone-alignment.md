# MYR-176 Delete and Tombstone Alignment

## Baseline

- Ticket: MYR-176, Slice 1 — Identity-targeted delete incorporation and tombstone semantics.
- MyRAM baseline: `a46f7742383c8216013d06f0c3018a34246a7a24`.
- Blacksmith instruction revision: `5aa30c8a0d072a05a02ea019da0b899ea81c9890`.
- Review date: 2026-08-06.
- Production activation remains deferred to MYR-179.

## Reviewed revisions

- Reference A: `64248a12829d04f62ddf3230c6c592f6226b57ab`
- Reference B: `cdeb8053c3aa2510189429d717ab09e70f134716`
- Reference C: `5fa067b182ddda3ea2477c4d5e4054da7318973f`
- Reference D: `89c162d3c1ae02c426c9002419aef0814e779ed8`
- Reference E: `26f9425ef74d45937e00d6c8ec2e8bb12889013d`

## Review conclusions

| Behavior | External behavior reviewed | MyRAM requirement | Adopted mechanism or divergence | Compatibility, storage, recovery, and convergence impact | Exact production location | Exact proving evidence |
|---|---|---|---|---|---|---|
| Identity-targeted deletion | Stable structural identities or operation-relative positions identify deleted content without receiver-side visible-offset reinterpretation. | Delete captured element identities and never retarget against current visible offsets. | Adopt stable identity targeting through validated `SyncTextElementIDSpan` values. | Prevents offset drift and receiver-side retargeting while preserving the existing payload contract. | `SyncTextSequenceState.incorporating(delete:)` and `SyncTextSequenceState.incorporatingDeleteWithMetrics(_:)` | `SyncTextSequenceDeletionTests.testCapturedIdentityDeletionIgnoresLaterInsertedIdentity`; `SyncTextSequenceDeletionRemediationTests.testMultiRunCaptureAndIncorporationTargetsExactIdentities` |
| Tombstone retention and visibility | Deleted content remains structurally represented while being excluded from visible materialization. | Retain immutable runs and deleted structural identity indefinitely. | Convert only targeted visible fragment portions to `.tombstone`; leave runs and untargeted portions unchanged. | Preserves anchors, replay determinism, and recovery information without changing persistence schema in Slice 1. | `SyncTextSequenceState.incorporatingDeleteWithMetrics(_:)` | `SyncTextSequenceDeletionTests.testMiddleDeletionCreatesTombstoneWithoutChangingRuns`; `SyncTextSequenceDeletionRemediationTests.testFullRunDeletionRetainsRunAndAllElementIdentities` |
| Repeated deletion idempotence | Repeating deletion of an already deleted structural target is an already-satisfied terminal operation. | Repeated and partially repeated delivery must be idempotent without a sequence-state delete ledger. | Tombstone visibility is terminal; already tombstoned intersections remain tombstoned and produce an equal state when nothing visible changes. | Avoids duplicate-delivery divergence and avoids new durable metadata. | `SyncTextSequenceState.incorporatingDeleteWithMetrics(_:)` | `SyncTextSequenceDeletionTests.testRepeatedAndPartiallyRepeatedDeletionIsIdempotent` |
| Insert-versus-delete concurrency | Concurrent insertions retain identities outside the captured deletion target and remain ordered by stable anchors. | Supported delivery permutations must converge exactly. | Delete only captured identities and preserve inserted identities not named by the delete payload. | Produces equal runs, fragments, visible text, visible count, and tombstone count for supported permutations. | `SyncTextSequenceState.incorporating(insert:insertedText:)` and `SyncTextSequenceState.incorporatingDeleteWithMetrics(_:)` | `SyncTextSequenceDeletionTests.testInsertAfterDeletedAnchorConvergesAcrossDeliveryOrder` |
| Deleted-anchor resolution | Deleted structural positions remain available for later dependent operations. | A later insertion may anchor to a retained deleted identity. | Keep deleted elements in immutable runs and tombstoned fragments so durable anchor lookup remains valid. | Preserves out-of-order recovery and prevents deletion from invalidating dependent insertions. | `SyncTextSequenceState.incorporatingDeleteWithMetrics(_:)` and existing durable anchor resolution in `SyncTextSequenceState.incorporating(insert:insertedText:)` | `SyncTextSequenceDeletionTests.testInsertAfterDeletedAnchorConvergesAcrossDeliveryOrder`; `SyncTextSequenceDeletionRemediationTests.testFullRunDeletionRetainsRunAndAllElementIdentities` |
| Missing target behavior | A structurally valid target whose owning operation has not arrived is distinct from malformed or impossible input. | Return only `missingDeleteDependency` for an absent target-owning operation. | Preflight payload spans in serialized order and throw the exact missing-dependency error before replacement construction. | Enables MYR-177 deferral and retry without treating temporary ordering as corruption. | `SyncTextSequenceState.incorporatingDeleteWithMetrics(_:)` preflight loop | `SyncTextSequenceDeletionTests.testDeletionErrorsAreExactAndLeaveInputUnchanged`; `SyncTextSequenceDeletionTests.testPreflightUsesSerializedFirstFailureAndNeverPartiallyDeletes` |
| Impossible target classification | Invalid ranges and illegal text boundaries fail immediately instead of entering dependency retry. | Bounds and lower/upper Unicode-boundary failures must remain exact and nondeferrable. | Classify range bounds before lower boundary before upper boundary for the first failing serialized span. | Prevents impossible operations from waiting indefinitely and preserves the complete input state. | `SyncTextSequenceState.incorporatingDeleteWithMetrics(_:)` preflight loop | `SyncTextSequenceDeletionTests.testDeletionErrorsAreExactAndLeaveInputUnchanged`; `SyncTextSequenceDeletionRemediationTests.testDeletionRejectsUpperBoundarySplittingSurrogatePair`; `SyncTextSequenceDeletionTests.testPreflightUsesSerializedFirstFailureAndNeverPartiallyDeletes` |
| Multi-run capture and incorporation | Structural deletion can span multiple immutable operation-owned runs without flattening identities into one visible range. | Capture exact identities across run boundaries and tombstone only those identities. | Preserve per-run spans in visible structural order and incorporate them without retargeting. | Maintains compact payloads and deterministic cross-run deletion. | `SyncTextSequenceState.elementIDSpans(inVisibleUTF16Range:)`, `SyncTextSequenceState.deleteOperationPayload(operationID:inVisibleUTF16Range:formatVersion:)`, and `SyncTextSequenceState.incorporatingDeleteWithMetrics(_:)` | `SyncTextSequenceDeletionRemediationTests.testMultiRunCaptureAndIncorporationTargetsExactIdentities` |
| Indefinite retention | Safe compaction requires a separate causal-stability and peer-retirement policy. | Add no compaction, pruning, garbage collection, or prefix advancement in MYR-176. | Deliberately retain every tombstone for this migration. | Storage grows with deletion history, but peers cannot diverge because one peer removed identities another still references. | No compaction path is added; `SyncTextSequenceState.incorporatingDeleteWithMetrics(_:)` preserves `runs` unchanged and emits retained tombstone fragments. | `SyncTextSequenceDeletionRemediationTests.testFullRunDeletionRetainsRunAndAllElementIdentities`; PR changed-file audit confirms no compaction API or persistence path was added. |
| Compact run and fragment representation | Durable run text is stored once and visibility is represented through compact structural metadata. | Preserve immutable runs and coalesced visibility fragments. | Keep run text unchanged, split only at target boundaries, and coalesce adjacent fragments with matching operation ID and visibility. | Bounds work and storage to runs, fragments, and target spans while retaining identity. | local `appendFragment(operationID:startOffset:utf16Length:visibility:)` inside `SyncTextSequenceState.incorporatingDeleteWithMetrics(_:)` | `SyncTextSequenceDeletionTests.testLargeFragmentedDeletionUsesBoundedIterativeWork` |

## Deliberate divergences

### Indefinite tombstone retention

- Concrete MyRAM requirement: retain tombstones indefinitely during the anchored migration.
- Reason for divergence: compaction would require an approved causal-stability, acknowledgement, and peer-retirement contract that MYR-176 does not define.
- Impact: deletion history consumes retained storage, but anchors remain recoverable and convergence does not depend on unimplemented peer-state assumptions.
- Exact production location: `SyncTextSequenceState.incorporatingDeleteWithMetrics(_:)` preserves `runs` unchanged and emits tombstone fragments.
- Exact evidence: `SyncTextSequenceDeletionRemediationTests.testFullRunDeletionRetainsRunAndAllElementIdentities` and `SyncTextSequenceDeletionTests.testInsertAfterDeletedAnchorConvergesAcrossDeliveryOrder`.

### MyRAM-specific compact identity spans

- Concrete MyRAM requirement: capture exact `SyncTextElementID` ranges while preserving the established immutable-run representation.
- Reason for divergence: the reviewed systems use different document APIs and internal encodings that cannot be imported without replacing MyRAM's structural model.
- Impact: contiguous spans avoid per-element payload expansion and remain deterministic against immutable runs.
- Exact production location: `SyncTextDeleteOperationPayload.deletedElementIDSpans`, `SyncTextSequenceState.elementIDSpans(inVisibleUTF16Range:)`, and `SyncTextSequenceState.incorporatingDeleteWithMetrics(_:)`.
- Exact evidence: `SyncTextSequenceDeletionRemediationTests.testMultiRunCaptureAndIncorporationTargetsExactIdentities`, `SyncTextSequenceDeletionTests.testCapturedIdentityDeletionIgnoresLaterInsertedIdentity`, and `SyncTextSequenceDeletionTests.testLargeFragmentedDeletionUsesBoundedIterativeWork`.

### Explicit deletion error taxonomy

- Concrete MyRAM requirement: MYR-177 must defer only temporarily missing deletion targets and must not queue impossible targets.
- Reason for divergence: reference-specific error and synchronization APIs do not map one-to-one to MyRAM's package boundary and staged migration ownership.
- Impact: exact errors preserve recovery intent without adding persistence in Slice 1 and prevent malformed operations from waiting indefinitely.
- Exact production location: `SyncTextSequenceStateError` deletion cases and the preflight loop in `SyncTextSequenceState.incorporatingDeleteWithMetrics(_:)`.
- Exact evidence: `SyncTextSequenceDeletionTests.testDeletionErrorsAreExactAndLeaveInputUnchanged`, `SyncTextSequenceDeletionRemediationTests.testDeletionRejectsUpperBoundarySplittingSurrogatePair`, and `SyncTextSequenceDeletionTests.testPreflightUsesSerializedFirstFailureAndNeverPartiallyDeletes`.

## Slice 1 implementation boundary

Implemented:

- exact identity-targeted deletion incorporation;
- complete deterministic target preflight;
- retained immutable runs and indefinite tombstones;
- repeated and partial-repeat idempotence;
- deleted-anchor insertion;
- supported insert-versus-delete convergence;
- exact missing, bounds, and lower/upper Unicode error classifications;
- multi-run capture and incorporation coverage;
- internal non-timing bounded-work metrics.

Deferred:

- missing-dependency persistence and retry: MYR-177;
- MyRAM-owned dark replay and cross-host tests: MYR-176 Slice 2;
- production activation and atomic persistence: MYR-179;
- aggregate alignment and live convergence: MYR-180.
