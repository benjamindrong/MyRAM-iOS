# MYR-132 Deterministic Offline Edit Convergence

**Status:** Approved and frozen governing handoff
**Implementation shape:** Three ordered PRs
**Design gate:** The 20-item checkpoint must be approved before PR 2 implementation begins

## Objective

Implement deterministic convergence for concurrent offline note body and title edits through stable per-operation base hashes, emitter-encoded canonical replay ordering, a shared cross-platform convergence core, bounded reconstructable per-note history, idempotent SwiftData-authoritative merge commits, deterministic title resolution, and the documented degraded reconciliation path.

Preserve matching-base and legacy positional behavior.

Never blind-apply a mismatched hashed operation. Normal conflict merges must not echo outgoing edits. Whole-note rewrites must use the MYR-131 fallback reload path rather than the incremental selected-editor bridge.

MYR-132 remains one governing Jira ticket, but implementation must land through three independently reviewable and revertible PRs.

## Frozen-Spec Rule

This document is now the authoritative implementation handoff.

All implementation PRs and the design checkpoint must cite this frozen version.

Do not continue expanding this specification during implementation unless code discovery exposes a correctness defect, a data-loss risk, an incompatibility with the actual persistence model, or a requirement that is impossible under current platform constraints.

Stylistic improvements, speculative abstractions, adjacent cleanup, and unrelated sync enhancements are not grounds to revise this handoff.

Any material design change requires:

1. a concrete code-level finding
2. an explanation of why the frozen rule cannot be implemented safely
3. an explicit amendment to MYR-132
4. updated tests and rejection criteria
5. approval before implementation proceeds

## Tech-Debt Controls

MYR-132 must reduce existing duplication where convergence correctness depends on it, but must not become a general sync rewrite.

### Required Debt Reduction

The implementation must:

- extract one shared convergence, ordering, reconstruction, and merge-planning core
- avoid adding a third implementation beside the existing Mac and iPhone appliers
- add iPhone rollback protection sufficient for MYR-132 correctness
- replace cross-store atomicity claims with explicit idempotency
- keep transactionally significant incorporation state in SwiftData
- document any temporary capability gates or deferred-cleanup behavior
- remove implementation duplication introduced by MYR-132 before each PR merges

### Prohibited Debt Creation

Reject implementation that:

- duplicates ordering logic between platforms
- duplicates hash or reconstruction logic
- embeds merge policy directly in editor controllers
- creates platform-specific history schemas
- introduces unbounded retry, history, or reconciliation state
- depends on undocumented queue behavior
- relies on comments instead of tests for idempotency
- adds compatibility branches without a removal or permanence decision
- leaves temporary PR-phase behavior enabled after the corresponding later PR lands
- introduces large abstractions with no current MYR-132 consumer
- hides unresolved correctness work behind TODOs

### Debt Discovered But Outside Scope

When implementation reveals adjacent debt that is not necessary for MYR-132 correctness:

- do not fold it into the current PR
- document it in the PR description
- create a separate follow-up ticket when warranted
- keep MYR-132's behavior unchanged

Examples include broad queue redesign, generic transaction frameworks, unrelated editor refactors, rich-text merge improvements, general conflict UI redesign, multi-peer sync architecture, and transport protocol cleanup unrelated to convergence.

## Scope Boundaries

### In Scope

- two-device offline body convergence
- deterministic title LWW
- body base hashes
- deterministic batch sequencing
- mixed legacy/new ordering
- reconstructable bounded history
- retained incorporated remote operations
- idempotent merge commits
- rollback and retry safety
- no-echo merge application
- degraded full-content reconciliation
- reconciliation episode lifecycle
- iOS and native macOS parity
- MYR-131 editor routing
- schema-version-1 compatibility

### Out Of Scope

- OT
- CRDTs
- version vectors
- live collaborative typing
- cursor or selection synchronization
- multi-device causality beyond the current two-device model
- rich-text conflict merging
- MYR-124 implementation
- Mac Catalyst
- legacy conflict-engine resurrection
- unrelated queue architecture replacement
- generic persistence or transaction frameworks
- general editor decomposition
- user-facing conflict-resolution workflows beyond the required degraded status
- automatic clock-skew correction
- transport acknowledgements added solely for reconciliation completion

Any proposed work outside this boundary requires a separate ticket unless it is demonstrably necessary to prevent MYR-132 data loss.

## Accepted Ordering Trade-Off

The replay and LWW key begins with `modifiedAt`.

A device with a systematically fast clock may therefore win competing edits more often.

That behavior is accepted for the current two-device design.

Do not compensate for clock skew ad hoc. Changing causality or timestamp semantics requires a separate design ticket.

## Branch And PR Strategy

Use separate branches for the three PRs:

1. `MYR-132-1-Additive-schema-hashing-detection`
2. `MYR-132-2-Shared-history-deterministic-merge`
3. `MYR-132-3-Degraded-reconciliation`

Each branch must begin from the correct merged predecessor:

- PR 1 branches from current `main`
- PR 2 branches from `main` after PR 1 merges
- PR 3 branches from `main` after PR 2 merges

Do not maintain three long-lived parallel branches that duplicate evolving code.

Before each branch:

- update local `main` from remote
- create and verify the branch
- push the branch before implementation
- ask before GitHub or pull-request operations

## Delivery Plan

### PR 1 - Additive Schema, Hashing, Ordering, And Mismatch Detection

Add the wire metadata and mismatch detection needed for deterministic convergence without changing successful matching-base or legacy behavior.

PR 1 must not leave distributed builds in a state where hashed mismatches permanently stall unless that behavior is explicitly capability-gated or PR 2 ships in the same release.

Keep:

```swift
SyncBatchEnvelope.currentSchemaVersion == 1
```

Add new fields as optional schema-version-1 fields. Do not bump the envelope schema version.

Do not duplicate metadata already present on `SyncBatch`: batch ID, origin device ID, and batch creation date.

Add only genuinely new wire state:

- `baseContentHash` on each body operation
- persisted per-device monotonic `batchSequence`
- full-content reconciliation operation shape

Use the operation's array position as its stable operation index unless the current encoding cannot preserve that position.

Add one shared UTF-8 SHA-256 implementation used by iOS and native macOS. Do not use Swift `Hasher`.

Each body operation carries the hash of the body immediately before that individual operation was generated. Sequential operations within a batch form a hash chain:

1. Hash the current body.
2. Generate the operation.
3. Update the working body.
4. Hash that result before generating the next operation.

During queue drain, cache the current hash per note and recompute it only when that note's body changes.

For new batches, order by:

1. `modifiedAt`
2. `originDeviceID`
3. canonical batch-order value
4. stable batch ID
5. operation index

The canonical new-batch order value is the emitter's persisted monotonic `batchSequence`.

The sequence must survive relaunch, increase monotonically for one device identity, be persisted before or atomically with batch creation, reset only when device identity also changes, and never be independently synthesized by a receiver.

Sequence reservation durability covers crashes and ordinary application operation under the selected durability policy. Manual deletion, replacement, or modification of pristine application-support sequence state is outside scope. An existing corruption latch survives later counter deletion, but deliberate removal of all pristine counter and guard state cannot be distinguished from a fresh installation.

PR #76 follow-up clarification: PR 1 durability means process-crash durability after successful file persistence and explicit failure reporting when persistence fails. It does not claim power-loss atomicity across filesystem and SwiftData stores.

PR #76 follow-up clarification: sequence corruption handling is fail-closed. A malformed latch is corruption, not absence; the store must rewrite the identity-keyed sequence-less latch before returning confirmed corruption, and failed latch persistence returns a transient sequence failure without allocating or advancing a counter.

A merge may contain both legacy batches and sequenced batches. Define one shared total-order representation, such as:

```swift
enum CanonicalBatchOrder: Comparable {
    case legacy(createdAt: Date, batchID: UUID)
    case sequenced(sequence: UInt64)
}
```

The design checkpoint must freeze the cross-form comparison. It must be deterministic, identical on both platforms, independent of receive order, independent of local state, and stable across relaunch.

A valid form is:

1. `modifiedAt`
2. `originDeviceID`
3. fixed order-kind discriminator
4. type-specific value
5. stable batch ID
6. operation index

Do not compare a date and an integer sequence without an explicit cross-form rule.

Apply behavior:

- Matching base hash: use today's positional path.
- Missing base hash: use today's legacy path.
- Mismatched hashed operation: never blind-apply.

Before PR 2 is active:

- retain the mismatched batch durably
- do not mark it seen
- do not partially apply it
- block later same-note operations behind it
- leave it available for PR 2

Interim release policy:

- ship PRs 1 and 2 in the same release, or
- keep hashed emission and mismatch refusal behind one capability gate until PR 2 is ready

Do not distribute hashed operations to peers that cannot safely process mismatches.

Amendment for PR #76 remediation: hashed body-operation emission and mismatch refusal remain capability-gated until PR 3 is available, unless the release explicitly accepts persistent note-scoped stalls for unreconstructable replacement-derived bases during the PR 2-PR 3 interval. This amendment is driven by the concrete finding that PR 2 cannot reconstruct a base containing an untransmitted replacement operation.

Deferring a batch because one note mismatches may also delay unrelated-note operations in that batch and later FIFO batches. This is an accepted temporary PR 1 limitation.

Before PR 1 merges, confirm that the durable queue preserves deferred batches across relaunch, does not discard them because of ordinary caps, and tolerates the expected temporary accumulation.

PR #76 follow-up clarification: incoming queue enqueue must be transactional at the queue abstraction boundary. A failed enqueue persistence attempt must restore the in-memory pending list to the pre-enqueue state and surface a typed persistence error. Both platforms must classify queue capacity, queue persistence, mismatched-base, unsupported-reconciliation, and generic save failures distinctly enough for tests and visible status.

Do not introduce partial-batch splitting solely for this temporary phase unless required to prevent data loss.

PR 1 tests must prove matching-base behavior is unchanged, legacy hash-less behavior is unchanged, mismatched hashed operations do not apply, mismatched batches remain queued and unseen, later same-note operations do not pass the mismatch, multi-note batch deferral behaves as documented, per-operation hashes form the correct chain, hash caching avoids repeated hashing of unchanged content, old schema-version-1 payloads decode, new optional fields decode under schema version 1, no schema bump is required, batch sequence survives relaunch, device identity reset also resets sequence identity, and mixed legacy/new ordering is total and cross-platform identical.

### PR 2 - Shared History, Deterministic Merge, Title Convergence, Rollback, And No Echo

Add the shared convergence core and persistence needed to process reconstructable hashed mismatches safely.

PR 2 must include normal merge suppression. A merge engine that echoes outgoing edits must not land.

Extract one platform-neutral core responsible for stable hashing, canonical replay keys, mixed legacy/new ordering, base reconstruction, retained-history replay, matching-base detection, conflict-merge planning, deterministic operation union, title LWW, incorporation bookkeeping, compaction decisions, and retry and idempotency decisions.

Platform adapters may handle only SwiftData access, editor update routing, RTF clearing or encoding, controller integration, and platform notifications.

Do not implement independent merge algorithms in the Mac and iPhone appliers.

A transaction cannot span SwiftData, file-backed queues, and `UserDefaults`. Move authoritative convergence state into SwiftData: snapshots, retained local operations, retained incorporated remote operations, reconstruction metadata, incorporated batch IDs, ordering metadata, winning title key, compaction state, and reconciliation episode state needed by PR 3.

The SwiftData save is the authoritative merge commit.

Idempotent commit protocol:

1. Read the durable incoming queue.
2. Identify candidate batches and notes.
3. Build and validate the complete merge plan in memory.
4. Apply body, title, history, and incorporation records to a dedicated SwiftData context.
5. Save SwiftData once.
6. Remove incorporated queue entries only after the save.
7. Update legacy `UserDefaults` bookkeeping afterward if still required.
8. Leave failed cleanup pending.
9. On retry or relaunch, consult SwiftData incorporation records.
10. Never reapply an incorporated batch.
11. Retry cleanup idempotently.

Queue deletion is cleanup, not the authoritative commit.

Use a dedicated convergence context where feasible and disable autosave where supported. Before managed-model mutation, build the full result in memory, capture immutable pre-merge state, and minimize the mutation window. Save once. Do not rely only on `context.rollback()`. Add equivalent rollback protection to iPhone rather than preserving the current weaker behavior.

Persist content snapshots keyed by stable hash, local operation history, incorporated remote operation history, ordering metadata, incorporated batch records, title winner metadata, and compaction state.

Reconstruct from the nearest usable retained snapshot at or before the target state. Replay the complete retained union required to reach the declared hash. Previously incorporated remote operations must remain available for later-session batches whose bases include them. Do not assume all related batches arrive together.

Define an explicit per-note bound using snapshot generations, operation count, byte budget, or a documented combination.

Protect bases referenced by durable incoming batches, bases referenced by durable outgoing batches, operations needed for partial-session delivery, recently incorporated remote operations still needed for reconstruction, and idempotent retry state.

Do not compact merely because a batch was sent or removed from the queue.

On mismatch, use the incoming base hash as the anchor, inspect pending incoming batches before removing anything, gather queued same-note operations, include retained local operations, include retained incorporated remote operations, sort the full union canonically, replay using current clamping and `expectedText` guards, preserve unrelated-note FIFO behavior, and do not process later same-note operations against partial state.

Build and validate the final body before persistence.

Until PR 3, unreconstructable bases and reconciliation operations must remain queued and unseen, block later same-note processing, and must not be blind-applied or reinterpreted as ordinary operations.

Hash-anchored merge application must emit zero outgoing body operations, zero replacement operations, bypass local edit capture, and avoid creating a new sync batch. This applies to selected and non-selected notes.

Matching-base operation uses the incremental selected-editor path. Conflict merge uses the MYR-131 whole-note fallback reload. Do not route conflict merges through the incremental bridge.

Use strict persisted LWW for every title operation. Apply an incoming title only when its complete canonical key exceeds the persisted winning title key. Lower key is ignored. Exact duplicate identity is idempotent. Higher key applies and persists. Do not infer concurrency from receive order or timestamp proximity. Legacy and sequenced title operations must share the same mixed-form total order.

PR 2 tests must prove shared-anchor reconstruction from both device perspectives, nearest-snapshot reconstruction, retained remote operations survive queue removal, partial delivery across sessions and relaunch remains reconstructable, two offline batches per device converge, mixed legacy/new operations have one order, equal-time same-device batches remain ordered, concurrent insert scenarios converge, insert/delete scenarios converge conservatively, surviving inserted text appears exactly once, normal merges emit zero outgoing operations, matching-base selected-note operations remain incremental, conflict merges use fallback reload, title LWW rejects older winners, legacy and sequenced titles share one order, SwiftData failures restore body, title, history, and incorporation state, iPhone has equivalent rollback guarantees, failed queue cleanup cannot cause reapplication, committed queued batches are skipped after relaunch, unreconstructable bases remain deferred, pre-PR-3 reconciliations remain queued and unseen, later same-note operations cannot pass deferred reconciliation, history stays bounded, and protected bases survive compaction.

### PR 3 - Degraded Reconciliation And Episode Lifecycle

Implement the bounded-history pressure valve and the only permitted outgoing-emission exceptions.

When a declared base cannot be reconstructed, do not positional-apply. Construct the deterministic lossless fallback body, preserve all recoverable text, use an explicit visible separator or equivalent boundary, expose MYR-132-specific degraded state, and route through whole-note fallback reload.

Do not use or resurrect `SyncConflictStore`, `MyRAMSyncConflictService`, legacy conflict views, or the legacy conflict engine.

Maintain at most one active unresolved reconciliation episode per note.

Episode resolution must be note-scoped, survive relaunch, be independent of receive order, not require equal last-agreed hashes, group crossing candidates from the same unresolved divergence, and distinguish later independent divergence after completion.

Do not use a device-local random UUID as the sole authoritative identity.

Persist episode generation or durable equivalent, unresolved/completed status, whether this device emitted, local candidate identity and body hash, observed peer candidates, winning candidate, self-completion evidence, and fresh agreed hash.

Reconciliation operations carry full replacement body, resulting stable hash, canonical replay metadata, stable batch and operation identity, and note-scoped episode-resolution metadata.

Resolve candidates by the same canonical LWW key.

Reconciliation rules:

- Winning incoming candidate: apply, commit, emit nothing.
- Newer local state wins and this device has not emitted: emit one counter-reconciliation.
- Each device emits at most once per logical episode.
- Normal one-sided exchange emits at most two operations.
- Applying a winner never recursively emits.
- Winner establishes a fresh agreed base.
- Later ordinary edits return to matching-base behavior.

An emitter whose own candidate wins may receive no reconciliation response. Its episode must complete when a later accepted incoming same-note operation proves peer adoption by declaring a base that equals the emitted fresh hash or is reconstructably descended from it.

Self-completion must commit with the accepted incoming operation, emit nothing, survive relaunch, and allow a later independent divergence to open a new generation.

Do not self-complete from elapsed time, transport delivery, unrelated-note traffic, or an explicit acknowledgement added solely for this purpose.

When both devices degrade before exchanging candidates, each emits one initial reconciliation, each associates the peer candidate with the active unresolved note episode, both compare the same two keys, both choose the same winner, neither emits a counter because each already emitted once, and both complete after committing the winner.

Expected dual-degraded crossing result: two total emitted operations, zero counters, byte-identical body, fresh matching hash, completed episode on both devices, and no dependency on equal prior history views.

Use whole-note fallback reload for degraded fallback bodies, reconciliation replacements, and counter-reconciliation replacements. Normal matching-base operations remain incremental.

PR 3 tests must prove lossless fallback construction, MYR-132-specific degraded state, legacy conflict services are never invoked, one-sided initial reconciliation, deterministic winner selection, winning apply emits nothing, exactly one permitted counter, one emission per device per episode, relaunch preserves emission state, unequal prior hashes still group crossing candidates, peer identities do not create false episodes, completed episodes allow later generations, dual-degraded crossing produces two initials and zero counters, emitter remains unresolved before peer-adoption evidence, equal-base evidence self-completes, descendant-base evidence self-completes, unrelated activity, time, and transport do not complete, self-completion survives relaunch, stale episodes do not suppress future reconciliation, both devices finish byte-identical, later edits return to matching-base behavior, all reconciliation whole-note paths use fallback reload, and self-completion and winning application emit nothing.

## Design Checkpoint Before PR 2

The next artifact must be a dedicated design checkpoint document resolving:

1. SwiftData history, incorporation, title-winner, and episode models
2. dedicated `ModelContext` and autosave policy
3. immutable merge-plan representation
4. authoritative incorporated-batch record
5. post-commit queue cleanup
6. iPhone rollback
7. shared convergence-core API
8. canonical replay-key representation
9. exact mixed legacy/sequenced ordering
10. monotonic sequence persistence
11. device-identity reset semantics
12. history bounds
13. protected-base rules
14. persisted title LWW
15. unreconstructable and reconciliation deferral
16. degraded-status surface
17. episode grouping, receiving completion, emitter self-completion, and later generation
18. dual-degraded crossing with unequal history views
19. relaunch preservation of episode state and evidence
20. accepted `modifiedAt` clock-skew behavior

This checkpoint is a hard gate before PR 2 implementation.

The checkpoint must prefer the smallest architecture that satisfies the frozen requirements. It must not propose speculative frameworks or adjacent refactors.

## Verification

Each PR must pass its focused tests before merge.

After PR 3, run native macOS and active iOS builds and full test suites:

```bash
xcodebuild -project MyRAM.xcodeproj \
  -scheme MyRAMMac \
  -destination 'platform=macOS' \
  build

xcodebuild -project MyRAM.xcodeproj \
  -scheme MyRAMMac \
  -destination 'platform=macOS' \
  test
```

Run the corresponding active iOS scheme build and test commands.

Manual verification must cover original A/B offline repro, reversed and equal timestamps, skewed clocks, mixed legacy/sequenced batches, multiple offline batches, partial delivery across relaunch, concurrent and stale title operations, queue-cleanup failure, PR 2 deferral behavior, one-sided reconciliation, emitter self-completion, new divergence after completion, counter-reconciliation, unequal-history dual degradation, crossing candidates, relaunch during an episode, and later matching-base incremental sync.

## Global Rejection Criteria

Reject any PR that:

- expands MYR-132 into a general sync rewrite
- includes unrelated cleanup without a demonstrated correctness dependency
- introduces speculative abstractions with no current consumer
- duplicates convergence logic across platforms
- leaves new TODO-based correctness debt
- changes schema version for optional fields
- duplicates existing batch metadata
- lacks one total mixed-form order
- changes `modifiedAt` precedence ad hoc
- blind-applies a mismatch
- loses deferred batches
- permits later same-note processing past an unresolved operation
- rewinds to an unverified shadow
- claims cross-store atomicity
- treats queue deletion as the commit
- cannot retry cleanup safely
- reapplies incorporated batches
- relies only on `context.rollback()`
- leaves iPhone rollback weaker
- drops incorporated remote history prematurely
- assumes simultaneous delivery
- retains unbounded state
- lets normal merges echo
- routes whole-note rewrites incrementally
- applies reconciliation before support exists
- permits older titles to overwrite newer winners
- resurrects the legacy conflict engine
- requires equal prior hashes for episode grouping
- uses only device-local episode IDs
- leaves winning emitters unresolved indefinitely
- completes episodes from time, transport, or unrelated activity
- loses completion evidence across relaunch
- suppresses future episodes because an old one remained open
- emits more than once per device per episode
- recursively echoes reconciliation
- mishandles dual-degraded crossing
- loses or duplicates surviving text
- introduces OT, CRDTs, version vectors, rich-text merging, Mac Catalyst work, or multi-peer causality

## Approved Amendment - Permanent Compact Idempotency Ledger

PR 2 code discovery confirms that the never-reapply invariant requires durable retention of incorporated batch identities. The current protocol contains no transport acknowledgement, globally bounded duplicate-delivery window, or other evidence that would make deletion of an old incorporated identity safe. Deleting all evidence for an incorporated batch could allow a delayed queue residue, restored backup, compatibility retry, or duplicate transport delivery to apply that batch again.

PR 2 may therefore retain one permanent compact fixed-size tombstone per incorporated batch as an explicit exception to the global rejection criterion against unbounded state. This exception applies only to the irreducible batch-identity idempotency ledger. Full incorporation evidence, retained operations, snapshots, diagnostics, cleanup state, presentation state, and reconciliation evidence remain deterministically bounded and compactable.

Each tombstone must have a versioned fixed maximum encoded size and retain only the batch identity and digests required to skip identical duplicates and fail closed on contradictory collisions. Tombstones may not retain note bodies, titles, operation arrays, variable-sized diagnostics, or other historical payloads. Tombstone deletion requires a future approved protocol amendment establishing a safe acknowledgement or expiry horizon.

Permanent tombstone compatibility also requires retaining the complete historical digest-format implementation for every digest format version still present in full incorporation records or tombstones. That implementation includes the normalized semantic schema, numeric discriminator assignments, exact field order, primitive encoding, canonical byte generation, and SHA-256 hexadecimal representation. Historical digest-format implementations become compatibility code with golden-vector tests and may not be removed, rewritten, or used to rewrite old tombstone digests without a future approved migration or protocol amendment.
