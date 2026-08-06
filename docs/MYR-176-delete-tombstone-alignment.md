# MYR-176 Delete and Tombstone Alignment

## Baseline

- Ticket: MYR-176, Slice 1 — Identity-targeted delete incorporation and tombstone semantics.
- MyRAM baseline: `a46f7742383c8216013d06f0c3018a34246a7a24`.
- Blacksmith instruction revision: `5aa30c8a0d072a05a02ea019da0b899ea81c9890`.
- Review date: 2026-08-06.
- Production activation remains deferred to MYR-179.

## Approved external-reference review

# MYR-176 Delete and Tombstone Alignment Review

## Reviewed revisions

- Reference A: 64248a12829d04f62ddf3230c6c592f6226b57ab
- Reference B: cdeb8053c3aa2510189429d717ab09e70f134716
- Reference C: 5fa067b182ddda3ea2477c4d5e4054da7318973f
- Reference D: 89c162d3c1ae02c426c9002419aef0814e779ed8
- Reference E: 26f9425ef74d45937e00d6c8ec2e8bb12889013d

## Review conclusions

| Behavior | External behavior reviewed | MyRAM requirement | Decision | Adopt or diverge | Compatibility, storage, recovery, and convergence impact | Production location | Exact proving tests |
|---|---|---|---|---|---|---|---|
| Identity-targeted deletion | Reviewed sequence-editing mechanisms identify deleted structural content through stable internal identities or operation-relative positions rather than reinterpreting the receiver's current visible offset. | Delete captured element identities, never current visible offsets. | Use validated `SyncTextElementIDSpan` values as the sole deletion authority after capture. | Adopt the stable-identity mechanism; diverge by representing contiguous targets as MyRAM-specific compact identity spans over immutable runs. | Prevents offset drift and receiver-side retargeting. Preserves deterministic replay across peers without changing the compatibility payload fields. | `SyncTextSequenceState.incorporating(delete:)` | `testCapturedIdentityDeletionIgnoresLaterInsertedIdentity` |
| Tombstone retention and visibility | Reviewed mechanisms preserve causal or structural information for deleted content while excluding it from materialized visible text. | Retain immutable runs and hidden structural identity indefinitely. | Convert only targeted visible fragment portions to `.tombstone`; leave runs and untargeted fragments unchanged. | Adopt retained structural identity; diverge by keeping tombstones indefinitely during this migration instead of introducing causal garbage collection. | Increases retained storage but preserves anchors, replay determinism, and recovery information. No persistence-schema change occurs in Slice 1. | deletion fragment projection | `testMiddleDeletionCreatesTombstoneWithoutChangingRuns` |
| Repeated deletion idempotence | Reviewed deletion mechanisms treat repeated removal of the same structural target as an already-satisfied terminal state. | Repeated and partial-repeat delivery is terminal and idempotent. | Reapplying a delete to tombstoned identities returns an equal state; mixed visible and tombstoned targets affect only the visible portions. | Adopt terminal deletion semantics without adding a sequence-state applied-delete ledger. | Avoids duplicate-delivery divergence and avoids new durable metadata. Higher layers may still deduplicate operation envelopes independently. | deletion fragment projection | `testRepeatedAndPartiallyRepeatedDeletionIsIdempotent` |
| Insert-versus-delete concurrency | Reviewed structural-editing behavior keeps concurrently inserted identities outside the captured deletion target and orders them through stable structural anchors. | Supported permutations converge exactly. | A delete affects only captured identities; an inserted run not named by the delete remains visible in either supported incorporation order. | Adopt identity-scoped concurrency semantics and existing deterministic insertion ordering. | Produces equal runs, fragments, visible text, visible count, and tombstone count for supported delivery permutations. Missing dependencies remain deferred work. | insertion and deletion incorporation | `testInsertAfterDeletedAnchorConvergesAcrossDeliveryOrder` |
| Deleted-anchor resolution | Reviewed mechanisms retain enough structural information for later operations to reference positions associated with deleted content. | Later insertion may use retained deleted identity. | Keep deleted elements in immutable runs and structural fragments so durable anchor lookup remains valid. | Adopt retained-anchor behavior. | Preserves out-of-order recovery and prevents deletion from invalidating dependent insertions. Storage remains intentionally retained. | durable anchor lookup | `testInsertAfterDeletedAnchorConvergesAcrossDeliveryOrder` |
| Missing target behavior | Reviewed dependency-aware mechanisms distinguish a structurally valid reference whose owning operation has not arrived from malformed or impossible references. | Missing operation returns only `missingDeleteDependency`. | Return `missingDeleteDependency` for the first target span whose operation ID is absent. | Adopt explicit missing-dependency classification; defer persistence and retry to MYR-177. | Supports eventual recovery without treating temporary ordering as corruption. No queue or retry behavior is added in Slice 1. | deletion preflight | `testDeletionErrorsAreExactAndLeaveInputUnchanged` |
| Impossible target classification | Reviewed mechanisms reject malformed ranges or invalid structural boundaries rather than waiting indefinitely for data that cannot make the reference valid. | Bounds and Unicode failures remain nondeferrable and distinct. | Return exact range and Unicode-boundary errors using deterministic first-failure precedence, with no partial application. | Adopt distinct nondeferrable classification and immutable failure behavior. | Prevents poisoned operations from entering the dependency queue and preserves the complete input state for recovery or diagnostics. | deletion preflight | `testDeletionErrorsAreExactAndLeaveInputUnchanged` |
| Indefinite tombstone retention | Reviewed systems may retain deletion metadata permanently or compact it only under a separately established causal-stability and peer-retirement policy. | No compaction, pruning, or causal-GC path in MYR-176. | Retain every tombstone indefinitely for this migration. | Deliberate divergence from any reference mechanism that performs safe causal garbage collection. | Storage can grow with historical deletions, but compatibility and convergence do not depend on unimplemented acknowledgement, peer-retirement, or stability assumptions. | absence audit | static scope audit |
| Compact run and fragment representation | Reviewed implementations separate durable operation or run data from compact materialization metadata rather than storing one heavyweight object per visible character. | Preserve compact immutable runs and visibility fragments. | Keep immutable run text once and represent visibility through coalesced structural fragments split only at deletion boundaries. | Adopt compact structural representation; diverge through MyRAM's run-plus-fragment model and contiguous identity spans. | Bounds work and storage to runs, fragments, and target spans while preserving deterministic projection and retained identity. | existing sequence-state representation | bounded-work test |

## Deliberate divergences

### Indefinite tombstone retention

- Concrete MyRAM requirement: Keep tombstones indefinitely during the anchored migration.
- Why the reviewed mechanism is not adopted unchanged: Any compaction mechanism would require a separately approved causal-stability, acknowledgement, and peer-retirement contract that MYR-176 does not define.
- Compatibility, storage, recovery, and convergence impact: Storage grows with deletion history, but anchors remain recoverable and peers do not diverge because one peer compacted identities another peer still references.
- Exact production location: No compaction path is added; deletion incorporation preserves immutable runs and tombstoned fragments.
- Exact proving tests: full-run retention, deleted-anchor insertion, repeated deletion, convergence permutations, and static absence audits.

### MyRAM-specific identity spans

- Concrete MyRAM requirement: Capture and replay exact `SyncTextElementID` ranges while retaining the existing immutable-run representation.
- Why the reviewed mechanism is not adopted unchanged: The reviewed systems expose different document APIs and internal encodings that cannot be imported directly without replacing MyRAM's established structural model.
- Compatibility, storage, recovery, and convergence impact: Compact contiguous spans preserve the current payload contract, avoid per-element payload expansion, and remain deterministic against immutable runs.
- Exact production location: `SyncTextDeleteOperationPayload.deletedElementIDSpans` and `SyncTextSequenceState.incorporating(delete:)`.
- Exact proving tests: multi-run capture, later-insert isolation, exact error classification, bounded-work evidence, and delivery-order convergence.

### Explicit deletion error taxonomy

- Concrete MyRAM requirement: MYR-177 must defer only temporarily missing deletion targets and must not queue impossible targets.
- Why the reviewed mechanism is not adopted unchanged: Reference-specific error and synchronization APIs do not map one-to-one to MyRAM's package boundary and staged migration ownership.
- Compatibility, storage, recovery, and convergence impact: Exact errors preserve recovery intent without adding persistence in Slice 1 and prevent malformed operations from waiting indefinitely.
- Exact production location: deletion preflight in `SyncTextSequenceState.incorporating(delete:)`.
- Exact proving tests: `testDeletionErrorsAreExactAndLeaveInputUnchanged`.

## Deferred ownership

- MYR-177: persistence, deferral, and retry for `missingDeleteDependency`.
- MYR-179: atomic production activation.
- MYR-180: aggregate alignment and live convergence closure.

## Slice 1 implementation boundary

Implemented:

- exact identity-targeted deletion incorporation;
- complete deterministic target preflight;
- retained immutable runs and indefinite tombstones;
- repeated and partial-repeat idempotence;
- deleted-anchor insertion;
- supported insert-versus-delete convergence;
- exact missing, bounds, and Unicode error classifications;
- internal non-timing bounded-work metrics.

Deferred:

- missing-dependency persistence and retry: MYR-177;
- MyRAM-owned dark replay and cross-host tests: MYR-176 Slice 2;
- production activation and atomic persistence: MYR-179;
- aggregate alignment and live convergence: MYR-180.
