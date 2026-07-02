# MYR-132 PR 1 Review Remediation

This document is the approved remediation plan for PR #76. It preserves PR 1 scope: additive schema-version-1 metadata, stable content hashing, deterministic batch sequencing and ordering, matching-base and legacy positional behavior, and durable mismatch detection/deferral.

Do not implement PR 2 reconstruction, deterministic merge, history persistence, title convergence, or PR 3 degraded reconciliation in this remediation.

## Required Changes

- Add one shared full-batch in-memory preflight engine used by iPhone and native macOS.
- Simulate existing notes from persisted content and newly created notes from `noteCreated.body`.
- Process batch changes in order, including mixed hash-less and hashed body operations.
- Validate `baseContentHash` against the current simulated working body only when the body-hash capability is enabled.
- Simulate successful positional operations with the same UTF-16 clamping, safe insertion, safe range, deletion, and `expectedText` behavior as the real appliers.
- Leave simulated state unchanged when the real applier would skip an operation.
- Reject unsupported reconciliation operations.
- Perform no managed-model mutation until the complete batch passes preflight.
- Add shared per-note hash caching inside the preflight path.
- Introduce an incoming queue policy that never silently evicts existing queued batches, preserves FIFO order, deduplicates by batch ID, persists across relaunch, and returns explicit capacity or persistence errors.
- Surface queue and sequence errors on both platforms.
- Add one shared capability policy controlling body-hash emission and mismatch refusal. The capability remains disabled until PR 3 unless the release explicitly accepts persistent note-scoped stalls during the PR 2-PR 3 interval.
- Keep `batchSequence` emission independent of the body-hash capability gate.
- Replace `UserDefaults` sequence allocation with a serialized durable reservation store.
- Distinguish successful reservation, transient reservation failure, confirmed corruption, and already-latched sequence-less identity.
- On transient sequence failure, emit only the affected batch with `batchSequence = nil`, surface an error, preserve counter/latch state, and retry later.
- On confirmed corruption, durably latch the current device identity into sequence-less mode using a marker independent of the counter file.
- Allow sequence reservation gaps after successful reservation; never reuse a sequence within the supported threat model.
- Document that manual deletion, replacement, or modification of pristine application-support sequence state is outside scope.

## Tests

Coverage must include:

- matching-base behavior unchanged
- legacy hash-less behavior unchanged
- mismatched hashed operations do not apply
- mismatched batches remain queued and unseen
- later same-note operations cannot pass a mismatch
- multi-note deferral delays the complete batch
- valid same-note hash chains pass preflight
- invalid chains fail without mutation
- new-note creation followed by body operations passes preflight
- mixed hash-less and hashed operations advance working state correctly
- skipped operations do not advance working state
- existing capture produces correct hash chains when the capability is enabled
- hash caching avoids repeated work
- old schema-version-1 payloads decode
- new optional fields decode without a schema bump
- sequence reservation survives relaunch
- abandoned reservations create gaps
- identity changes create independent sequence namespaces
- transient reservation failure degrades only one batch and retries later
- confirmed corruption enters durable sequence-less mode
- counter deletion or repair cannot bypass an existing corruption latch
- sequence-less fallback does not affect body hashing
- mixed legacy and sequenced ordering remains total
- replay ordering is identical across platforms
- Mac and iPhone have equivalent preflight and queue-blocking behavior
- incoming deferred batches are never silently evicted
- capacity and persistence failures are surfaced on both platforms

## Acceptance Criteria

The remediation is complete when neither platform mutates managed state before complete chained preflight passes, deferred queued batches are never silently evicted, queue-capacity and persistence failures are visible, distributed PR 1 builds cannot stall from skipped replacements while the gate is disabled, `batchSequence` remains independent of body hashing, unchanged content is not repeatedly hashed, sequence reservation is durable before use, transient sequence failures affect only the current reservation, confirmed corruption creates an identity-keyed sequence-less latch, only a new device identity resumes sequencing after corruption, matching-base and legacy positional behavior remain unchanged, `SyncBatchEnvelope.currentSchemaVersion` remains `1`, and PR 2/PR 3 behavior remains out of scope.
