# MYR-132 PR 2 Plan — Shared History and Deterministic Merge

## Status and sequencing

PR 1 has merged into `main` as:

`3fce8cb MYR-132-1-Additive-schema-hashing-detection (#76)`

That merged state includes the PR 1 remediation work, including nested-drain protection, latch hardening, and `docs/MYR-132-PR1-remediation.md`.

The next required artifact is the approved 20-item design checkpoint from the frozen MYR-132 handoff.

The remaining delivery sequence is:

1. Draft the PR 2 design checkpoint.
2. Resolve and approve all 20 checkpoint items.
3. Update local `main` to the latest merged state.
4. Create `MYR-132-2-Shared-history-deterministic-merge` from `main`.
5. Ask before performing any GitHub or pull-request operation.
6. Push the new branch before implementation begins.
7. Implement PR 2 strictly against the approved checkpoint.

No PR 2 implementation branch should be created before the checkpoint is approved.

---

## Objective

PR 2 adds the shared convergence core and authoritative persistence required to resolve **reconstructable hashed mismatches** deterministically.

It introduces:

* bounded retained history
* content snapshots
* base reconstruction
* canonical operation replay
* deterministic body merge planning
* persisted title LWW
* idempotent SwiftData incorporation
* rollback and retry safety
* no-echo merge application
* equivalent iPhone and native macOS behavior

PR 2 does not implement degraded reconciliation for unreconstructable bases. That remains PR 3.

The PR 1 capability gate for hashed emission and mismatch refusal remains disabled until PR 3 is available, unless a release explicitly accepts persistent note-scoped stalls during the PR 2–PR 3 interval.

---

## 1. Build one shared convergence core

Extract one platform-neutral convergence core.

It owns:

* stable hashing
* canonical replay-key construction
* mixed legacy/sequenced ordering
* matching-base classification
* base reconstruction
* nearest-snapshot selection
* retained-history replay
* deterministic operation-union construction
* conflict-merge planning
* title LWW decisions
* incorporation and idempotency decisions
* compaction eligibility
* protected-base decisions
* retry and failure classification

Do not implement separate body-merge algorithms in the Mac and iPhone appliers.

Platform adapters may own only:

* SwiftData fetching and mutation
* dedicated context creation
* editor update routing
* selected-note refresh
* RTF clearing or encoding
* controller integration
* platform notifications and user-visible errors

---

## 2. Make SwiftData the authoritative convergence store

Move transactionally significant convergence state into SwiftData.

Persist at least:

* content snapshots keyed by stable body hash
* retained local body operations
* retained incorporated remote operations
* reconstruction and ancestry metadata
* canonical ordering metadata
* incorporated batch records
* persisted winning title key
* history-compaction state
* the reconciliation-episode state required by PR 3

The file-backed incoming queue is transport-retention state.

Legacy seen-batch stores or `UserDefaults` bookkeeping are compatibility or cleanup state only. They are not authoritative once SwiftData incorporation records exist.

The successful SwiftData save is the authoritative merge commit.

---

## 3. Define an immutable merge plan

Before mutating managed models, build a complete immutable in-memory merge plan.

The plan should contain enough information to validate and apply the transaction without recomputing policy during mutation, including:

* candidate incoming batches
* affected notes
* reconstructed base bodies
* canonical ordered operation unions
* final body per note
* body hash results
* title winner decisions
* snapshots and history records to add
* incorporated batch records to add
* compaction actions
* editor-routing decisions
* queue entries eligible for post-commit cleanup

A corrupt, incomplete, internally inconsistent, or impossible merge plan must never be partially applied.

---

## 4. Use an explicit idempotent commit protocol

The complete PR 2 protocol is:

1. Read the durable incoming queue.
2. Consult authoritative SwiftData incorporated-batch records.
3. Exclude batches already incorporated.
4. Identify candidate batches and affected notes.
5. Build the complete merge plan in memory.
6. Validate reconstruction, replay, title, history, and compaction decisions.
7. Apply body, title, history, snapshots, and incorporation records to a dedicated SwiftData context.
8. Save SwiftData once.
9. Treat the successful SwiftData save as the authoritative incorporation commit.
10. Remove incorporated queue entries only after the save.
11. Update legacy `UserDefaults` or seen-batch bookkeeping afterward if still required.
12. Leave failed queue or legacy-bookkeeping cleanup pending.
13. On retry or relaunch, consult SwiftData incorporation records before applying anything.
14. Never reapply an incorporated batch.
15. Retry queue cleanup idempotently.
16. Retry legacy bookkeeping cleanup idempotently if it remains necessary.

Queue deletion is cleanup, not the authoritative commit.

A crash or failure after the SwiftData save but before queue cleanup must produce a harmless retry:

* the queue entry may still exist
* SwiftData proves it was incorporated
* the batch is not applied again
* cleanup is retried

### Legacy seen-batch decision

The design checkpoint must explicitly decide the fate of:

* `MacSyncSeenBatchStore`
* `SyncBatchSeenBatchStore`

The accepted options are:

1. remove them from authoritative decision-making and retain them temporarily as post-commit compatibility bookkeeping, with a documented removal point; or
2. eliminate them in PR 2 if all callers can safely rely on SwiftData incorporation records.

Do not allow the legacy stores to disagree with SwiftData in a way that can cause reapplication or skipped incorporation.

---

## 5. Reuse PR 1’s typed failure-classification precedent

PR 2 must extend the failure-classification discipline established in PR 1 without creating a duplicated or contradictory taxonomy.

PR 1 already ships:

```swift
enum SyncBatchDrainFailureKind {
    case mismatchedBase
    case unsupportedReconciliation
    case persistence
    case queueCapacity
    case queuePersistence
    case unexpected
}
```

It also ships shared classification and user-facing message mapping.

The PR 2 checkpoint must explicitly choose one of these architectures:

1. extend `SyncBatchDrainFailureKind` so it remains the single authoritative failure taxonomy; or
2. define a convergence-core result or failure type and provide one exhaustive mapping into `SyncBatchDrainFailureKind` at the drain or platform boundary.

Do not allow two overlapping authoritative taxonomies.

Any convergence-core type proposed during the checkpoint is draft input only. Its names and cases are not final until the checkpoint ratifies:

* ownership
* mapping
* retry semantics
* controller behavior
* user-visible status behavior

### Preserve PR 1 queue-failure distinctions

PR 2 must preserve the distinct handling already required for:

* `queueCapacity`
* `queuePersistence`
* generic SwiftData persistence failure
* unsupported reconciliation
* unexpected failure

Queue-capacity and queue-persistence failures must not be collapsed into a generic `transientPersistence` case.

Transport retention and authoritative SwiftData incorporation are separate durability domains and must remain separately classified.

### Mismatched-base transition

The checkpoint must explicitly state that, under PR 2:

* a reconstructable `mismatchedBase` is no longer a terminal drain failure
* it becomes the trigger for deterministic reconstruction and merge planning
* existing PR 1 mismatch-blocked batches must transition into PR 2 merge handling after upgrade
* an unreconstructable base remains deferred and queued until PR 3 can resolve it

The existing `mismatchedBase` classification may remain relevant for:

* pre-PR-2 compatibility paths
* failure to enter convergence handling
* controller mapping before reconstructability has been determined

Its final role must be explicit.

### Required per-case behavior table

The checkpoint must include an exhaustive table for every failure or deferred outcome.

For each case, define:

* whether the batch remains queued
* whether it remains unseen
* whether retry is automatic
* whether retry can produce a different result without new evidence
* whether later same-note operations are blocked
* whether unrelated-note FIFO may continue
* whether the note enters a deferred state
* whether the result fails closed
* whether user-visible status is surfaced
* whether queue cleanup is attempted
* whether legacy bookkeeping cleanup is attempted
* whether the batch may ever be reapplied

At minimum, the table must resolve these semantic categories:

| Category | Required behavior |
|---|---|
| Transient SwiftData fetch/save failure | Retryable; no authoritative incorporation; queue remains intact |
| Queue-capacity failure | Distinct transport-retention failure; preserve PR 1 handling |
| Queue-persistence failure | Distinct transport-retention failure; preserve PR 1 handling |
| Post-commit queue-cleanup failure | Commit remains authoritative; never reapply; retry cleanup idempotently |
| Legacy bookkeeping failure | Commit remains authoritative; never reapply; retry or remove compatibility bookkeeping |
| Reconstructable mismatch | Enter deterministic merge planning; not a failure |
| Unreconstructable base | Defer note; remain queued and unseen; block later same-note work |
| Unsupported pre-PR-3 reconciliation | Defer note; remain queued and unseen; block later same-note work |
| Corrupt history | Fail closed; do not reconstruct, synthesize, or reapply |
| Invalid merge plan | Reject before mutation; deterministic failure; do not blindly retry without changed evidence or code |
| Inconsistent incorporation state | Fail closed; never reapply; require explicit recovery or diagnostic resolution |
| Unexpected failure | Preserve queue; classify and surface without partial incorporation |

### Corrupt history versus inconsistent incorporation state

The checkpoint must distinguish these cases by evidence.

`corruptHistory` means retained reconstruction data is malformed, contradictory, incomplete in a way that violates declared invariants, or cannot be replayed safely.

Examples include:

* impossible ancestry
* malformed operation metadata
* contradictory snapshot hashes
* canonical ordering metadata that cannot be interpreted
* replay reaching a body different from the declared base hash

`inconsistentIncorporationState` means authoritative incorporation evidence contradicts the observed note, history, snapshot, title-winner, or queue state.

Examples include:

* a batch is recorded as incorporated but required committed history is absent
* an incorporation record exists but the committed note hash contradicts its recorded result
* duplicate authoritative records disagree about the same batch identity
* cleanup state implies an incorporated batch may be applied again

Required behavior for `inconsistentIncorporationState`:

* fail closed
* defer the affected note
* never reapply the batch
* block later same-note operations
* preserve all available evidence
* surface a typed diagnostic state
* require explicit repair, migration, or checkpoint-defined recovery logic

The system must prefer a stalled note over violating the invariant that an incorporated batch is never applied twice.

---

## 6. Use a dedicated convergence context

Use a dedicated SwiftData `ModelContext` where feasible.

The checkpoint must define:

* context ownership
* actor or queue isolation
* autosave policy
* how objects are refetched into the convergence context
* how immutable pre-merge state is captured
* when managed models begin mutation
* how save failures are handled
* how editor-facing contexts observe the committed result

Disable autosave where supported for the convergence transaction.

Build and validate the full result before mutation.

Save once.

Do not rely solely on `context.rollback()` as the correctness mechanism. The immutable plan and authoritative incorporation records are primary; rollback is additional protection.

iPhone must receive rollback and retry guarantees equivalent to native macOS.

---

## 7. Persist reconstructable bounded history

Persist:

* stable-hash content snapshots
* local operations
* incorporated remote operations
* operation ordering metadata
* enough ancestry or reconstruction metadata to locate a usable base

Previously incorporated remote operations must remain available after their incoming queue entries are removed.

Do not assume all related operations arrive in one session or one queue-drain attempt.

A future incoming operation may declare a base that contains remote operations incorporated during an earlier session.

---

## 8. Reconstruct from the nearest usable snapshot

For a mismatched hashed operation:

1. Use the incoming `baseContentHash` as the reconstruction target.
2. Locate the nearest retained usable snapshot at or before that target.
3. Gather the retained operations required to reach the target.
4. Include retained local operations.
5. Include retained incorporated remote operations.
6. Include applicable queued same-note operations.
7. Sort the complete union using the canonical replay key.
8. Replay using the established UTF-16 clamping and `expectedText` behavior.
9. Verify that replay reaches the declared base hash.
10. Build the deterministic final body.
11. Validate the final body before persistence.

Do not infer a missing base from the current note body merely because replay fails.

Do not process later same-note operations against a partially reconstructed state.

---

## 9. Preserve unrelated-note FIFO behavior

A mismatched batch may contain multiple notes, and later queue entries may contain both related and unrelated changes.

The checkpoint must define the smallest safe queue-selection rule that:

* gathers all necessary same-note operations for reconstruction
* does not apply later same-note operations against incomplete state
* preserves unrelated-note FIFO behavior
* does not silently split batches in a way that breaks idempotency
* records exactly which batch identities were incorporated

The shared core must make this selection deterministically.

---

## 10. Define canonical replay ordering once

All operation replay and title resolution must use one shared canonical representation.

It must cover:

* legacy batches
* sequenced batches
* equal timestamps
* equal origin devices
* stable batch-ID tie-breaking
* operation array index

The order must be:

* deterministic
* identical on iPhone and Mac
* independent of receive order
* independent of local state
* stable across relaunch

Do not duplicate ordering logic in platform adapters.

---

## 11. Implement deterministic body merge planning

For reconstructable mismatches:

* reconstruct the declared common base
* gather the complete retained operation union
* sort canonically
* replay conservatively
* preserve valid inserted text exactly once
* honor deletion `expectedText` guards
* produce one deterministic final body on both devices

The planner must return a complete result before SwiftData mutation begins.

PR 2 is not an OT or CRDT implementation.

---

## 12. Enforce strict no-echo merge application

A normal hash-anchored conflict merge must emit:

* zero outgoing body operations
* zero replacement operations
* zero new sync batches

Application must bypass local capture for:

* selected notes
* non-selected notes
* iPhone
* native macOS

Normal merge suppression is a merge-blocking requirement. A merge engine that echoes cannot land.

---

## 13. Route editor updates correctly

Use two distinct editor paths:

### Matching-base operations

Continue using the incremental selected-editor path.

### Conflict merges

Use the MYR-131 whole-note fallback reload path.

Do not route a whole-body conflict result through the incremental selected-editor bridge.

The same routing rule applies on both platforms.

---

## 14. Persist deterministic title LWW

Every title operation uses strict persisted last-writer-wins based on its complete canonical key.

Behavior:

* lower key than persisted winner: ignore
* exact same operation identity: idempotent no-op
* higher key: apply and persist as the new winner

Do not infer concurrency from:

* receive order
* timestamp proximity
* current UI state

Legacy and sequenced title operations must use the same mixed-form total order.

Title winner metadata must participate in the same authoritative SwiftData commit as body and incorporation state.

---

## 15. Bound history explicitly

The checkpoint must select a concrete per-note bound using one or more of:

* snapshot generations
* operation count
* byte budget

The rule must be deterministic and testable.

Do not use an informal “recent enough” policy.

---

## 16. Protect reconstructability during compaction

Compaction must preserve:

* bases referenced by durable incoming batches
* bases referenced by durable outgoing batches
* operations required for partial-session delivery
* recently incorporated remote operations needed by future bases
* idempotent retry state
* snapshots or operations needed by currently deferred batches

Do not compact merely because:

* a batch was transmitted
* a queue entry was removed
* an operation was incorporated once

The checkpoint must define how protected-base references are discovered and when they may be released.

---

## 17. Defer unreconstructable and reconciliation cases until PR 3

Until PR 3:

* unreconstructable bases remain queued
* reconciliation operations remain queued
* deferred batches remain unseen
* later same-note operations remain blocked
* nothing is blind-applied
* reconciliation payloads are not reinterpreted as positional operations

The shared core should return typed deferred outcomes rather than treating these as generic exceptions.

Because PR 2 cannot resolve bases containing untransmitted replacement edits, the PR 1 body-hash capability gate remains disabled until PR 3 unless the release explicitly accepts those stalls.

---

## 18. Keep PR 3 episode state compatible

PR 2 persists the reconciliation-episode state required by PR 3, but does not implement degraded reconciliation behavior.

The checkpoint must freeze enough of the model to support:

* note-scoped episode generations
* unresolved and completed states
* local and peer candidate identities
* winning candidate metadata
* emission state
* self-completion evidence
* fresh agreed hashes

Do not implement PR 3’s candidate emission or winner protocol early.

---

## 19. Required PR 2 tests

PR 2 must prove:

* shared-anchor reconstruction from both device perspectives
* nearest-snapshot reconstruction
* retained remote operations survive queue removal
* partial delivery across sessions remains reconstructable
* relaunch preserves reconstruction capability
* two offline batches per device converge
* mixed legacy and sequenced operations share one order
* equal-time same-device batches remain ordered
* concurrent inserts converge
* insert/delete combinations converge conservatively
* surviving inserted text appears exactly once
* normal conflict merges emit no outgoing operations
* matching-base selected-note operations remain incremental
* conflict merges use whole-note fallback reload
* title LWW rejects lower keys
* title LWW accepts higher keys
* duplicate title identities are idempotent
* legacy and sequenced titles share one order
* SwiftData save failure restores or avoids mutation of body, title, history, and incorporation state
* iPhone has equivalent rollback guarantees
* failed queue cleanup cannot cause reapplication
* failed legacy seen-store cleanup cannot cause reapplication
* cleanup retries idempotently
* committed queued batches are skipped after relaunch
* transient persistence failures remain retryable
* corrupt history fails closed
* invalid merge plans apply nothing
* unreconstructable bases remain deferred
* pre-PR-3 reconciliations remain queued and unseen
* later same-note operations cannot pass deferred work
* history remains bounded
* protected bases survive compaction
* failure classification is shared and compatible with PR 1’s typed error model

---

## 20. Required design checkpoint

Before implementation, produce a dedicated checkpoint resolving:

1. SwiftData history, incorporation, title-winner, and episode models
2. dedicated `ModelContext` and autosave policy
3. immutable merge-plan representation
4. authoritative incorporated-batch record
5. post-commit queue cleanup
6. iPhone rollback
7. shared convergence-core API
8. canonical replay-key representation
9. exact mixed legacy/sequenced ordering
10. monotonic sequence persistence assumptions inherited from PR 1
11. device-identity reset semantics
12. history bounds
13. protected-base rules
14. persisted title LWW
15. unreconstructable and reconciliation deferral
16. degraded-status surface
17. episode grouping, receiver completion, emitter self-completion, and later generations
18. dual-degraded crossing with unequal history views
19. relaunch preservation of episode state and evidence
20. accepted `modifiedAt` clock-skew behavior

The checkpoint’s opening framing must also explicitly resolve:

* the full 16-step idempotent commit and cleanup protocol
* the role or removal of both legacy seen-batch stores
* idempotent retry of queue cleanup
* idempotent retry of any retained legacy bookkeeping
* whether `SyncBatchDrainFailureKind` is extended or remains the platform-facing mapped taxonomy
* the exhaustive mapping between convergence outcomes and drain failures
* preservation of distinct `queueCapacity` and `queuePersistence` cases
* the transition of reconstructable `mismatchedBase` from failure into merge handling
* the required per-case controller-behavior table
* retry versus deterministic deferral versus fail-closed behavior
* evidence distinguishing `corruptHistory` from `inconsistentIncorporationState`
* the invariant that inconsistent incorporation state can never permit reapplication
* a shared typed failure model derived from PR 1’s precedent
* fail-closed handling for corrupt history, invalid plans, and ambiguous incorporation state
* branch creation only after checkpoint approval
* branch push before implementation
* explicit approval before GitHub or pull-request operations

This checkpoint is a hard gate.

Prefer the smallest architecture that satisfies these requirements. Do not introduce speculative frameworks or unrelated refactors.

---

## Acceptance criteria

PR 2 is complete when:

* one shared core plans convergence for both platforms
* SwiftData incorporation records are authoritative
* the full merge result is validated before managed-model mutation
* SwiftData is saved once per authoritative merge commit
* queue cleanup occurs only after commit
* failed queue cleanup retries idempotently
* failed legacy bookkeeping retries idempotently or the legacy stores are removed
* incorporated batches can never be reapplied after relaunch
* PR 2 failures use a typed model compatible with PR 1
* transient failures remain retryable
* corrupt history and invalid plans fail closed
* reconstructable mismatches converge deterministically
* unreconstructable bases remain safely deferred
* title LWW is persisted and deterministic
* history remains bounded without deleting protected bases
* normal merges emit no outgoing edits
* matching-base operations remain incremental
* conflict merges use whole-note fallback reload
* iPhone and Mac have equivalent rollback and retry guarantees
* PR 3 behavior remains out of scope
