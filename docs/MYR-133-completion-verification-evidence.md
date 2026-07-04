# MYR-133 PR 2d Completion Verification Evidence

## Scope

MYR-133 is the completion checkpoint for the settled MYR-132 PR 2d post-commit cleanup and presentation contract. This pass preserves the production architecture and adds focused verification for executor state coverage, final-CAS retry behavior, retained immutable work payloads, payload validation, and stable work-payload encoding.

The corrective slice after commit `6b1017e` fixes two defects found in that verification evidence:

- The representative golden encoded invalid incremental offsets. The golden now replays insert `"B"` at UTF-16 offset `1` and insert `"C"` at UTF-16 offset `2`, proving the decoded operations produce `"ABC"` and match the committed post-body hash.
- The payload validator previously skipped hash-chain comparisons when an incremental operation omitted a base hash. Incremental entries now fail closed when the first base hash is missing while an expected pre-hash exists, or when any later operation omits the previous-result base hash.

The production fix is validation-only. It does not change the persistence format or executor behavior. Malformed payloads that previously skipped chain validation are now rejected.

No live drain/controller integration was added. No per-domain CAS boundary was introduced. No production visibility was broadened for tests.

## Phase 1 Inventory

Production post-commit surface:

- `MyRAM/Sync/Convergence/SyncConvergencePostCommitTypes.swift`
- `MyRAM/Sync/Convergence/SyncConvergencePostCommitExecutor.swift`
- `MyRAM/Sync/Convergence/SwiftDataSyncConvergencePostCommitStore.swift`
- `MyRAM/Sync/Convergence/SyncConvergencePostCommitGating.swift`
- `MyRAM/Sync/Convergence/SyncConvergencePersistenceTransaction.swift`

CAS immutable root projection:

- `batchID`
- `originDeviceID`
- `createdAt`
- `batchSequence`
- `schemaVersion`
- `committedAt`
- `canonicalPayloadDigest`
- `canonicalPayloadDigestFormatVersion`
- `committedResultDigest`
- `committedResultDigestFormatVersion`
- `committedAtOrderingPayloadData`
- `affectedNotesPayloadData`
- `authoritativeChildCount`
- `authoritativeChildBytes`
- `authoritativeChildrenDigest`
- `postCommitWorkPayloadData`

Mutable CAS payload:

- `postCommitStatePayloadData`

Load-time identity validation fields:

- root `batchID`
- root and persisted identity canonical payload digest/version
- root and persisted identity committed-result digest/version
- operation identity row `identityKey`
- operation identity row `batchID`
- operation identity row `noteID`
- operation identity row `operationIndex`
- operation identity row byte count
- decoded canonical replay key
- decoded operation identity payload

Executor persistence model:

- Queue cleanup, legacy cleanup, and presentation refresh run in deterministic queue, legacy, presentation order.
- The executor accumulates completed domains in memory.
- One final compare-and-set persists the accumulated mutable-state result.
- If the final CAS fails, all originally pending domains remain retryable and `.postCommitStatePersistence` is reported.

Target membership decision:

- `SyncConvergencePostCommitTests` is compiled into both `MyRAMTests` and `MyRAMMacTests`.
- `SyncConvergenceFoundationTests` and `SyncBatchPayloadCompatibilityTests` are currently iOS-test-target members only.
- This PR keeps those foundation/compatibility suites iOS-only and verifies native macOS shared post-commit behavior through `MyRAMMacTests/SyncConvergencePostCommitTests`.
- Adding broad foundation/compatibility target membership to native macOS is intentionally not mixed into this verification pass because it changes project membership and may require portability work outside the PR 2d post-commit contract.

## Requirement Matrix

| Requirement | Code/Test Location | Verification |
|---|---|---|
| Preserve settled PR 2d production architecture | Narrow validation-only production change in `MyRAM/Sync/Convergence/SyncConvergencePostCommitTypes.swift` | Focused post-commit suites passed |
| Fake CAS preserves immutable work bytes | `MyRAMTests/SyncConvergencePostCommitTests.swift` `testFakeStoreCASPreservesImmutableWorkPayloadAfterPartialClear`, `FakePostCommitStore.currentWorkPayloadData` | iOS/macOS post-commit suites |
| Eight pending-state executor matrix with legacy adapter | `testEightPendingStateMatrixWithLegacyAdapterPinsSingleCASEffects` | Pins queue -> legacy -> presentation order, exact queue and legacy work, full presentation request equality, one CAS for changed states, and no CAS for complete roots |
| Legacy pending with nil adapter remains pending | `testEightPendingStateMatrixWithoutLegacyAdapterLeavesLegacyPending`, `testLegacyTrueWithoutAdapterRemainsPending` | iOS/macOS post-commit suites |
| Final CAS failure leaves original domains retryable, then fresh-store retry converges | `testFinalCASFailureThenFreshStoreRetryRerunsIdempotentWorkAndCompletes` | Reconstructs retry state and work by decoding persisted root payload bytes, then re-runs queue, legacy, and presentation work from persisted all-pending state |
| Completed roots remain no-op | `testCompletedPostCommitStateDoesNotCallAdaptersOrWrite` | iOS/macOS post-commit suites |
| Caller-regenerated plans do not suppress persisted work | `testCallerPlansCannotSuppressPersistedQueueOrPresentationWork` | iOS/macOS post-commit suites |
| Presentation requests use authoritative committed state and deterministic order | `testPresentationRequestsUseAuthoritativeCommittedStateInDeterministicOrder` | Pins complete incremental and whole-note-fallback requests in deterministic note order |
| Missing work payload fails before adapters | `testPrePayloadPendingRootFailsClosedBeforeAdapters` | iOS/macOS post-commit suites |
| Payload rejects malformed nested operation identity | `testPostCommitPayloadRejectsMalformedOperationIdentity` | iOS/macOS post-commit suites |
| Payload rejects hash-chain discontinuity | `testPostCommitPayloadRejectsOperationHashChainMismatch` | iOS/macOS post-commit suites |
| Payload rejects missing first base hash when expected pre-hash exists | `testPostCommitPayloadRejectsMissingFirstBaseHashWhenExpectedPreHashExists` | iOS/macOS post-commit suites |
| Payload rejects missing intermediate base hash | `testPostCommitPayloadRejectsMissingIntermediateBaseHash` | iOS/macOS post-commit suites |
| Payload allows absent expected pre-state with absent first base hash | `testPostCommitPayloadAllowsMissingExpectedPreHashAndMissingFirstBaseHash` | iOS/macOS post-commit suites |
| Payload rejects contradictory presentation entries | `testPostCommitPayloadValidationMatrixRejectsContradictoryPresentationEntries` | iOS/macOS post-commit suites |
| Executable replay-verified representative work-payload golden | `testRepresentativeWorkPayloadGoldenDigestPinsStableEncoding` | Golden SHA-256 `9cd2489d7c1338e54c0db95eabf20e5a98c8fefc872e4b02665ce3a678e1e3e5` |
| Deterministic all-idempotent payload digest | `testAllIdempotentRetainedBodyDeliveryPersistsWithoutPresentationWork` | Golden SHA-256 `7441711fd109820ef330485c1e431b8f75b2c1d99037855189ed213b16d7e50b` |
| Partial and full clear reload from fresh SwiftData contexts | `testSwiftDataStoreReloadsAfterPartialAndFullClearWithRetainedWorkPayload` | iOS/macOS post-commit suites |
| Tombstone cleanup ignores regenerated caller-plan content | `testTombstoneCleanupRemovesOnlyVerifiedSourceBatchID` | iOS/macOS post-commit suites |

## Commands Run

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAM -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test -only-testing:MyRAMTests/SyncConvergencePostCommitTests/testRepresentativeWorkPayloadGoldenDigestPinsStableEncoding
```

Exit code: 65. Purpose: captured the new golden digest before replacing the placeholder. Executed 1 test, 1 failure, 0 skips.

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAM -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test -only-testing:MyRAMTests/SyncConvergencePostCommitTests
```

Exit code: 65. Purpose: caught incorrect matrix expectations. Executed 22 tests, 8 failures, 0 skips.

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAM -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test -only-testing:MyRAMTests/SyncConvergencePostCommitTests
```

Exit code: 0. Executed 22 tests, 0 failures, 0 skips. Final result: `** TEST SUCCEEDED **`.

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAMMac -destination 'platform=macOS' test -only-testing:MyRAMMacTests/SyncConvergencePostCommitTests
```

Exit code: 0. Executed 22 tests, 0 failures, 0 skips. Final result: `** TEST SUCCEEDED **`.

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAM -destination 'generic/platform=iOS Simulator' build
```

Exit code: 0. Final result: `** BUILD SUCCEEDED **`.

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAMMac -destination 'platform=macOS' build
```

Exit code: 0. Final result: `** BUILD SUCCEEDED **`.

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAM -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test -only-testing:MyRAMTests/SyncConvergencePlanningTests -only-testing:MyRAMTests/SyncConvergenceIncorporationTests -only-testing:MyRAMTests/SyncConvergencePostCommitTests -only-testing:MyRAMTests/SyncConvergenceFoundationTests -only-testing:MyRAMTests/SyncBatchPayloadCompatibilityTests -only-testing:MyRAMTests/SyncBatchUnsentQueueTests
```

Exit code: 0. Executed 180 tests, 0 failures, 0 skips. Final result: `** TEST SUCCEEDED **`.

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAMMac -destination 'platform=macOS' test -only-testing:MyRAMMacTests/SyncConvergencePlanningTests -only-testing:MyRAMMacTests/SyncConvergenceIncorporationTests -only-testing:MyRAMMacTests/SyncConvergencePostCommitTests -only-testing:MyRAMMacTests/SyncBatchUnsentQueueTests
```

Exit code: 0. Executed 139 tests, 0 failures, 0 skips. Final result: `** TEST SUCCEEDED **`.

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAM -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test -only-testing:MyRAMTests/SyncConvergencePostCommitTests -only-testing:MyRAMTests/SyncConvergenceIncorporationTests/testAllIdempotentRetainedBodyDeliveryPersistsWithoutPresentationWork
```

Exit code: 0. Executed 26 tests, 0 failures, 0 skips. Final result: `** TEST SUCCEEDED **`.

## Final Remediation Verification

Verified implementation SHA: `036f38e8d4ef57777076698907c229bcbda81280`

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAM -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test -only-testing:MyRAMTests/SyncConvergencePostCommitTests/testEightPendingStateMatrixWithLegacyAdapterPinsSingleCASEffects -only-testing:MyRAMTests/SyncConvergencePostCommitTests/testPresentationRequestsUseAuthoritativeCommittedStateInDeterministicOrder -only-testing:MyRAMTests/SyncConvergencePostCommitTests/testFinalCASFailureThenFreshStoreRetryRerunsIdempotentWorkAndCompletes
```

Commit SHA: `036f38e8d4ef57777076698907c229bcbda81280`. Exit code: 0. Executed 3 tests, 0 failures, 0 skips. Final result: `** TEST SUCCEEDED **`.

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAMMac -destination 'platform=macOS' test -only-testing:MyRAMMacTests/SyncConvergencePostCommitTests/testEightPendingStateMatrixWithLegacyAdapterPinsSingleCASEffects -only-testing:MyRAMMacTests/SyncConvergencePostCommitTests/testPresentationRequestsUseAuthoritativeCommittedStateInDeterministicOrder -only-testing:MyRAMMacTests/SyncConvergencePostCommitTests/testFinalCASFailureThenFreshStoreRetryRerunsIdempotentWorkAndCompletes
```

Commit SHA: `036f38e8d4ef57777076698907c229bcbda81280`. Exit code: 0. Executed 3 tests, 0 failures, 0 skips. Final result: `** TEST SUCCEEDED **`.

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAM -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test -only-testing:MyRAMTests/SyncConvergencePlanningTests -only-testing:MyRAMTests/SyncConvergenceIncorporationTests -only-testing:MyRAMTests/SyncConvergencePostCommitTests -only-testing:MyRAMTests/SyncConvergenceFoundationTests -only-testing:MyRAMTests/SyncBatchPayloadCompatibilityTests -only-testing:MyRAMTests/SyncBatchUnsentQueueTests
```

Commit SHA: `036f38e8d4ef57777076698907c229bcbda81280`. Exit code: 0. Executed 180 tests, 0 failures, 0 skips. Final result: `** TEST SUCCEEDED **`.

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAMMac -destination 'platform=macOS' test -only-testing:MyRAMMacTests/SyncConvergencePlanningTests -only-testing:MyRAMMacTests/SyncConvergenceIncorporationTests -only-testing:MyRAMMacTests/SyncConvergencePostCommitTests -only-testing:MyRAMMacTests/SyncBatchUnsentQueueTests
```

Commit SHA: `036f38e8d4ef57777076698907c229bcbda81280`. Exit code: 0. Executed 139 tests, 0 failures, 0 skips. Final result: `** TEST SUCCEEDED **`.

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAM -destination 'generic/platform=iOS Simulator' build
```

Commit SHA: `036f38e8d4ef57777076698907c229bcbda81280`. Exit code: 0. Final result: `** BUILD SUCCEEDED **`.

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAMMac -destination 'platform=macOS' build
```

Commit SHA: `036f38e8d4ef57777076698907c229bcbda81280`. Exit code: 0. Final result: `** BUILD SUCCEEDED **`.

```bash
git diff --check
```

Commit SHA: `036f38e8d4ef57777076698907c229bcbda81280`. Exit code: 0.

## Remaining MYR-133 Coverage Not Completed In This Pass

The attached MYR-133 proposal is broader than this initial implementation pass. These items still need additional work before claiming full ticket completion:

- Real behavioral Path B proof for every PR 2 planner shape.
- Full routed-note construction negative matrix at incorporation boundary.
- Full operation identity construction-time and authoritative-row corruption matrix.
- Per-field stale-CAS matrix against SwiftData roots.
- Remaining Phase 7 and Phase 9 load, save, reload, adapter-failure, and crash-window coverage beyond the fresh-store final-CAS retry added here.
- Final-head evidence from an approved commit.
- Inherited PR 2d review-thread disposition.
- Complete ticket-wide requirement mapping.
