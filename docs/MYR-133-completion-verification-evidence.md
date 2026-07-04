# MYR-133 PR 2d Completion Verification Evidence

## Scope

MYR-133 is the completion checkpoint for the settled MYR-132 PR 2d post-commit cleanup and presentation contract. This pass preserves the production architecture and adds focused verification for executor state coverage, final-CAS retry behavior, retained immutable work payloads, payload validation, and stable work-payload encoding.

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
| Preserve settled PR 2d production architecture | No production file changes | Focused post-commit suites passed |
| Fake CAS preserves immutable work bytes | `MyRAMTests/SyncConvergencePostCommitTests.swift` `testFakeStoreCASPreservesImmutableWorkPayloadAfterPartialClear`, `FakePostCommitStore.currentWorkPayloadData` | iOS/macOS post-commit suites |
| Eight pending-state executor matrix with legacy adapter | `testEightPendingStateMatrixWithLegacyAdapterPinsSingleCASEffects` | iOS/macOS post-commit suites |
| Legacy pending with nil adapter remains pending | `testEightPendingStateMatrixWithoutLegacyAdapterLeavesLegacyPending`, `testLegacyTrueWithoutAdapterRemainsPending` | iOS/macOS post-commit suites |
| Single final CAS failure leaves original domains retryable | `testFinalCASFailureLeavesAllOriginallyPendingFlagsRetryable` | iOS/macOS post-commit suites |
| Completed roots remain no-op | `testCompletedPostCommitStateDoesNotCallAdaptersOrWrite` | iOS/macOS post-commit suites |
| Caller-regenerated plans do not suppress persisted work | `testCallerPlansCannotSuppressPersistedQueueOrPresentationWork` | iOS/macOS post-commit suites |
| Presentation requests use authoritative committed state and deterministic order | `testPresentationRequestsUseAuthoritativeCommittedStateInDeterministicOrder` | iOS/macOS post-commit suites |
| Missing work payload fails before adapters | `testPrePayloadPendingRootFailsClosedBeforeAdapters` | iOS/macOS post-commit suites |
| Payload rejects malformed nested operation identity | `testPostCommitPayloadRejectsMalformedOperationIdentity` | iOS/macOS post-commit suites |
| Payload rejects hash-chain discontinuity | `testPostCommitPayloadRejectsOperationHashChainMismatch` | iOS/macOS post-commit suites |
| Payload rejects contradictory presentation entries | `testPostCommitPayloadValidationMatrixRejectsContradictoryPresentationEntries` | iOS/macOS post-commit suites |
| Stable representative work-payload golden | `testRepresentativeWorkPayloadGoldenDigestPinsStableEncoding` | Golden SHA-256 `84537b46126b0a68e0c9920e02c1666d14ba90f2c48b15b83910d888bf60ac67` |
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

Exit code: 0. Executed 177 tests, 0 failures, 0 skips. Final result: `** TEST SUCCEEDED **`.

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAMMac -destination 'platform=macOS' test -only-testing:MyRAMMacTests/SyncConvergencePlanningTests -only-testing:MyRAMMacTests/SyncConvergenceIncorporationTests -only-testing:MyRAMMacTests/SyncConvergencePostCommitTests -only-testing:MyRAMMacTests/SyncBatchUnsentQueueTests
```

Exit code: 0. Executed 136 tests, 0 failures, 0 skips. Final result: `** TEST SUCCEEDED **`.

```bash
git diff --check
```

Exit code: 0.

## Remaining MYR-133 Coverage Not Completed In This Pass

The attached MYR-133 proposal is broader than this initial implementation pass. These items still need additional work before claiming full ticket completion:

- Real behavioral Path B proof for every PR 2 planner shape.
- Full routed-note construction negative matrix at incorporation boundary.
- Full operation identity construction-time and authoritative-row corruption matrix.
- Per-field stale-CAS matrix against SwiftData roots.
- Full failure and crash-window matrix beyond final-CAS failure.
- Final-head evidence from an approved commit.
- Inherited PR 2d review-thread disposition.
