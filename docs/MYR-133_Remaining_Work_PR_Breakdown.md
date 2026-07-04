# MYR-133 — Remaining Work Breakdown

## Purpose

MYR-133 still contains several substantial verification workstreams. Completing all remaining requirements in one pull request would create an oversized review surface, make failures harder to isolate, and encourage unrelated test infrastructure to become coupled.

Keep **MYR-133 as the umbrella completion ticket** and deliver the remaining work through focused linked tasks and pull requests.

---

## Completed Corrective Slice

The current corrective slice is complete and should remain independent.

### Covered

- Stable representative work-payload golden
- Executable incremental replay verification
- Fail-closed missing hash-chain validation
- Eight-state executor order and CAS behavior
- Exact queue, legacy, and presentation adapter work
- Fresh-store retry after final CAS failure
- Deterministic all-idempotent payload audit
- Corrective-slice command and commit evidence

### Scope boundary

This slice does **not** complete MYR-133. The remaining work below is broader ticket-level verification.

---

# Remaining PR Breakdown

## PR 2 — Planner and Routed-Note Construction

### Goal

Prove that every supported planner shape produces the correct persisted post-commit state and exact routed-note work.

### Coverage

- Run the real planner for every finalized PR 2 planning shape.
- Prove `retryLegacyCleanup == false`.
- Incorporate representative plans and decode persisted state/work.
- Prove `legacyCleanupPending == false`.
- Prove `legacyCleanupRequired == false`.

### Planner shapes

- Matching-base incremental
- All-idempotent
- Mixed idempotent plus executable operation
- Creation-only
- Creation-plus-body
- Title-only
- Reconstructed conflict
- Compatibility/no-op
- Any other supported finalized route

### Routed-note matrix

- Zero routed notes persists zero presentation entries.
- One routed note persists exactly one entry.
- Multiple routed notes persist exactly the same note-ID set.
- Mixed `.none`, `.incremental`, and `.wholeNoteFallback` routes persist only non-`.none` entries.
- Missing note plan fails before commit.
- Duplicate note plan fails before commit.
- Contradictory route/effect fails before commit.
- Incremental route without executable operations is rejected or normalized according to the settled contract.
- Whole-note fallback with incremental operations is rejected.
- Entry and operation ordering are deterministic.

### Scope boundary

Keep this PR centered on planner and incorporation construction behavior. Do not add SwiftData CAS or crash-window infrastructure.

---

## PR 3 — Operation Identity Validation Matrix

### Goal

Complete construction-time, payload, persisted-row, and load-time identity verification.

### Positive coverage

- Valid authoritative identity
- Correct note ownership
- Correct replay-key linkage
- Correct persisted identity row
- Correct operation hash chain

### Negative coverage

- Missing authoritative identity
- Duplicate batch/index identity
- Wrong batch ID
- Wrong origin device ID
- Negative operation index
- Out-of-range operation index
- Wrong operation kind
- Wrong note ID
- Same-kind identities swapped across two notes
- Replay-key batch mismatch
- Replay-key origin mismatch
- Replay-key operation-index mismatch
- Replay-key note mismatch where resolvable
- Malformed or noncanonical UUID strings
- Wrong persisted row note ID
- Wrong persisted row batch ID
- Wrong persisted row operation index
- Wrong persisted row kind
- Wrong persisted identity bytes
- Missing persisted identity row
- Duplicate persisted identity rows or equivalent fail-closed corruption fixture
- Operation base/result hash-chain mismatch
- First-operation pre-hash mismatch
- Final-operation result-hash mismatch

### Required invariants

- Malformed identities fail before presentation work is returned.
- Construction-time defects fail before commit.
- No partial note, evidence, queue, root, or identity-row mutation occurs.

### Scope boundary

Do not mix the per-field immutable-root CAS matrix into this PR.

---

## PR 4 — Immutable-Root CAS Matrix

### Goal

Prove every immutable root field participates in compare-and-set validation.

### Per-field stale-root cases

Mutate each field independently after load and before CAS:

- Batch ID or source identity where fixture permits
- Origin device ID
- Schema version
- Canonical payload digest
- Canonical payload digest format version
- Committed-result digest
- Committed-result digest format version
- Affected-note IDs bytes
- Authoritative child count
- Authoritative child bytes
- Authoritative children digest
- Committed-at value
- Committed-at ordering payload bytes
- Immutable post-commit work payload bytes
- Any other field included in the production root snapshot

### Additional cases

- Stale prior mutable state fails CAS.
- Byte-identical immutable root plus matching prior state succeeds.
- Failed CAS performs no partial mutation.
- Partial clear preserves immutable work bytes.
- Complete clear preserves immutable work bytes.
- Fresh-context reload preserves unchanged work bytes.

### Scope boundary

Keep the PR centered on the SwiftData store and immutable-root contract. Do not add broad adapter failure matrices.

---

## PR 5 — Failure-Injection Infrastructure and Domain Independence

### Goal

Build reusable test doubles and prove independent retry behavior for queue, legacy, presentation, load, and persistence failures.

### Fake-store capabilities

- Load failure
- Missing root
- Tombstone path
- Malformed state bytes
- Malformed work bytes
- Contradictory pending/work state
- Stale CAS
- Immutable-root mismatch
- Save failure
- Successful partial completion followed by fresh-context reload

### Adapter capabilities

- Queue failure before removal
- Queue partial-removal failure where supported
- Legacy `.stillPending`
- Legacy `.failed`
- Presentation `.stillPending`
- Presentation `.failed`
- Failure before external action
- Failure during external action
- External action succeeds but final CAS fails

### Required invariants

- One domain’s failure does not re-pend a completed domain.
- One domain’s failure does not clear another pending domain.
- Successful external work remains safely retryable.
- Immutable work bytes never change during mutable-state persistence.
- Same-context and fresh-context retry behavior are both covered.

### Scope boundary

This PR establishes the reusable failure fixtures needed by the crash-window PR. Avoid duplicating crash scenarios here unless required to validate the infrastructure itself.

---

## PR 6 — Crash and Relaunch Windows

### Goal

Pin interruption behavior across every meaningful executor boundary using the failure infrastructure from PR 5.

### Crash windows

- Before external work
- After external work but before final CAS
- After final CAS but before the caller observes completion
- Relaunch after failed persistence
- Relaunch after successful external work
- Relaunch with already-completed idempotent external effects

### Architecture note

MYR-133 mentions:

> after one domain CAS but before the next domain

The settled executor performs **one final CAS per execution pass**, not one CAS per domain. This case should be documented as **not applicable under the preserved architecture** rather than simulated through a per-domain CAS redesign.

### Required invariants

- Pending work is never lost.
- No completed mutable state is rolled backward.
- Retries do not create unrecoverable committed state.
- Non-idempotent effects are not duplicated.
- Any adapter idempotency dependency is explicit in the test name and fixture.
- Fresh-context and relaunch simulations use persisted bytes, not reused decoded objects.

### Scope boundary

Do not alter executor persistence architecture to make crash cases easier to test.

---

## PR 7 — Final Completion Evidence

### Goal

Close MYR-133 with complete ticket-wide evidence after all implementation PRs are merged.

### Required content

- Complete requirement-to-code/test matrix
- Final planner-shape coverage
- Final routed-note matrix
- Final identity matrix
- Final immutable-root CAS matrix
- Final failure and crash-window matrix
- Stable golden and deterministic audit results
- Explicit unchanged production-contract list
- Foundation and queue regression coverage
- iOS and native macOS verification
- Review-thread disposition for inherited PR 2d comments
- Explicit confirmation that no active drain/controller integration was added unless separately scoped

### Verification commands

Run from the exact final implementation head:

```bash
xcodebuild   -project MyRAM.xcodeproj   -scheme MyRAM   -destination 'generic/platform=iOS Simulator'   build
```

```bash
xcodebuild   -project MyRAM.xcodeproj   -scheme MyRAMMac   -destination 'platform=macOS'   build
```

```bash
xcodebuild   -project MyRAM.xcodeproj   -scheme MyRAM   -destination 'platform=iOS Simulator,name=<available simulator>'   test   <all required only-testing filters>
```

```bash
xcodebuild   -project MyRAM.xcodeproj   -scheme MyRAMMac   -destination 'platform=macOS'   test   <all required only-testing filters>
```

```bash
git diff --check
```

For every command, record:

- Exact command
- Exit code
- Test count
- Failure count
- Skip count
- Final result line
- Verified implementation commit SHA

### Completion rule

Only this final PR may claim full MYR-133 completion.

---

# Dependency Order

```text
Current corrective slice
        ↓
PR 2 — Planner and routed-note construction
        ↓
PR 3 — Operation identity validation
        ↓
PR 4 — Immutable-root CAS matrix
        ↓
PR 5 — Failure-injection infrastructure
        ↓
PR 6 — Crash and relaunch windows
        ↓
PR 7 — Final completion evidence
```

## Rationale

- Planner and routing coverage establishes valid persisted fixtures.
- Identity coverage builds on those finalized routed operations.
- CAS coverage then protects the complete immutable root shape.
- Failure infrastructure depends on stable store and executor fixtures.
- Crash-window tests reuse the failure infrastructure.
- Final evidence should be generated only after all behavioral slices are merged.

---

# Jira Structure

Keep **MYR-133** as the umbrella ticket.

Create linked implementation tasks for:

MYR-134 — planner and routed-note construction
MYR-135 — operation identity matrix
MYR-136 — immutable-root stale-CAS matrix
MYR-137 — failure-injection coverage
MYR-138 — crash and relaunch verification
MYR-139 — final completion evidence

Use the project’s next available issue numbers rather than literal letter suffixes if Jira does not support them.

Each task should:

- Relate to MYR-133.
- Preserve the settled PR 2d architecture.
- Own one reviewable PR.
- Update the central completion evidence incrementally.
- State explicitly that it does not complete MYR-133 unless it is the final evidence task.

---

# Cross-PR Guardrails

Every PR must:

- Avoid redesigning the settled executor and persistence architecture.
- Avoid per-domain CAS.
- Keep immutable work bytes unchanged as pending flags clear.
- Use real planner/incorporation behavior where required.
- Fail closed on malformed persisted evidence.
- Include focused iOS and native macOS verification.
- Record exact command results and the verified implementation SHA.
- Leave unrelated remaining-work rows explicit.
- Avoid claiming full MYR-133 completion before PR 7.

---

# Overall Assessment

A meaningful amount of MYR-133 remains. The work is appropriate for **six additional focused PRs**, not one large completion PR.

The recommended sequence minimizes fixture churn, keeps reviews comprehensible, and lets each slice establish reusable evidence for the next.
