# MYR-175 Completion Verification Evidence

## Identity

- Ticket: MYR-175 — Implement structural insert replay and same-anchor ordering.
- Slice: 3 — Dark replay integration and completion evidence.
- Branch: `MYR-175-Slice-3-Dark-replay-integration-and-completion-evidence`.
- Refreshed baseline: `6fdc9ec1d6ec7d89488fd0de56a0d07829e134b0`.
- Instruction repository revision: `5aa30c8a0d072a05a02ea019da0b899ea81c9890`.
- Tested implementation head: `c6b2737468a779be556a1fb303612ad4d2b48016`.
- Tested implementation tree: `99cac213f425155d539394f22795a4f4de270009`.
- NearbySyncCore revision: `4ab9eb91e6390947a7a2e9a4c2ec74012b4bc0e2`.
- Verification date: 2026-08-06.

The local verified worktree produced tree `99cac213f425155d539394f22795a4f4de270009`, exactly matching the pushed tested implementation head. The remote feature-branch head also matched `c6b2737468a779be556a1fb303612ad4d2b48016` before this evidence-only commit.

## Implementation inventory

The tested implementation head changes:

- `MyRAM/Sync/Batch/SyncBatchAnchoredInsertReplay.swift`
- `MyRAMTests/SyncBatchAnchoredInsertReplayTests.swift`
- `MyRAMMacTests/SyncBatchAnchoredInsertReplayTests.swift`
- `MyRAM.xcodeproj/project.pbxproj`
- `MyRAMMacTests/MacSyncBatchControllerTests.swift`

No active applier, convergence, controller, persistence, queue, transport, acknowledgement, editor, SwiftData model, or package implementation source changed in Slice 3.

## Requirement mapping

| Requirement | Production location | Test or audit evidence |
|---|---|---|
| Shared iPhone and native Mac replay | `SyncBatchAnchoredInsertReplay.applying`; dual application-target membership | Mirrored replay suites; PBX target-membership audit |
| Delegate to package structural incorporation | Single `state.incorporating(insert:insertedText:)` call | Static single-call audit and all focused replay tests |
| Return resulting state and derived visible text | `SyncBatchAnchoredInsertReplayResult` | `testEmptyAndMidRunReplayReturnDerivedVisibleTextWithoutMutatingInput` |
| Preserve exact package errors | No catch or translation in replay source | `testCoreErrorsEscapeUnchangedAndPreserveInputState` |
| Empty, mid-run, same-anchor, and tombstoned replay | Shared replay seam | Five focused tests in each host target |
| Ignore compatibility offset and hash | Replay source reads only payload and text | `testCompatibilityOffsetAndHashDoNotAffectReplay`; forbidden-field audit |
| Preserve input state on failure | Immutable package incorporation result | `testCoreErrorsEscapeUnchangedAndPreserveInputState` |
| Keep production anchored traffic dark | No production caller; capability remains disabled | Zero-caller audit; capability-off audit; existing iPhone and Mac admission regressions |
| Preserve legacy positional insertion | No active positional-path changes | Existing iPhone positional regressions and complete host suites |
| Preserve target isolation | Explicit PBX memberships | `testSyncTargetMembershipIncludesSharedCaptureAndMacPresentationTests` |

## Verification commands and outcomes

### Package verification

```bash
swift test --package-path Packages/AnchoredSequenceCore
swift test -c release --package-path Packages/AnchoredSequenceCore
```

- Debug: 100 passed, 0 failed.
- Release: 100 passed, 0 failed.

### Focused replay verification

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAM -destination "id=$SIM_UDID" -only-testing:MyRAMTests/SyncBatchAnchoredInsertReplayTests test
xcodebuild -project MyRAM.xcodeproj -scheme MyRAMMac -destination 'platform=macOS' -only-testing:MyRAMMacTests/SyncBatchAnchoredInsertReplayTests test
```

- iPhone focused replay suite: passed.
- Native Mac focused replay suite: passed.

### Complete host suites

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAM -destination "id=$SIM_UDID" -only-testing:MyRAMTests test
xcodebuild -project MyRAM.xcodeproj -scheme MyRAMMac -destination 'platform=macOS' -only-testing:MyRAMMacTests test
```

- iOS application tests: 1,079 passed, 0 failed, 0 skipped.
- Native Mac tests: 654 passed, 0 failed, 0 skipped.
- iOS result bundle: `/tmp/MYR-175-Slice-3-local-20260806T041652Z/DerivedData/iOS-full/Logs/Test/Test-MyRAM-2026.08.05_23-19-13--0500.xcresult`.
- Native Mac result bundle: `/tmp/MYR-175-Slice-3-local-20260806T041652Z/DerivedData/Mac-full/Logs/Test/Test-MyRAMMac-2026.08.05_23-19-59--0500.xcresult`.

### UI suite

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAM -destination "id=$SIM_UDID" -only-testing:MyRAMUITests test
```

- MyRAMUITests: 13 passed, 0 failed, 0 skipped.
- UI result bundle: `/tmp/MYR-175-Slice-3-local-20260806T041652Z/myram-ui-tests.xcresult`.

### Application builds

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAM -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project MyRAM.xcodeproj -scheme MyRAMMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

- iOS Simulator application build: passed.
- Native Mac application build: passed.

## Static and compatibility audits

Observed results:

- `plutil -lint MyRAM.xcodeproj/project.pbxproj`: passed.
- `git diff --check`: passed.
- Replay source target memberships: present in both application targets.
- Mirrored test memberships: present only in intended test targets.
- Replay-source references to compatibility metadata, SwiftData, `ModelContext`, raw-offset helpers, and active application layers: 0.
- Structural incorporation calls in replay source: exactly 1.
- Production callers of `SyncBatchAnchoredInsertReplay`: 0.
- `SyncBatchAnchoredPayloadCapability.isEnabled == false`: exactly 1 declaration observed.
- Retired `MacSyncBatchApplier` and its tests remain excluded from native Mac target membership.
- NearbySyncCore remained at `4ab9eb91e6390947a7a2e9a4c2ec74012b4bc0e2` with a clean working tree.
- Local verified tree equals tested implementation tree: passed.
- Remote branch head equals tested implementation head before evidence publication: passed.

## Evidence classification

### OBSERVED

- Package Debug and Release suites passed 100/100 each.
- Focused iPhone and native Mac replay suites passed.
- Complete iOS application tests passed 1,079/1,079.
- Complete native Mac tests passed 654/654.
- MyRAMUITests passed 13/13.
- Both application builds passed.
- Exact local tree and pushed tested-head tree matched.
- Capability remained disabled and replay had zero production callers.
- Sibling transport revision and working tree remained unchanged.

### NOT OBSERVED

- The exact iPhone simulator name and UDID were selected dynamically by the local runner but were not retained in the pasted completion transcript. Exact result-bundle paths and the `id=$SIM_UDID` destination form were retained.
- No remote CI run of the complete Xcode matrix is claimed; the complete matrix was local.
- This document does not record its own commit SHA, final PR head, PR number, or post-publication parity because those values do not exist until after this evidence commit.

### NOT REACHABLE IN TEST ENVIRONMENT

- Production anchored replay, persistence, convergence incorporation, queue admission, and editor publication are intentionally unreachable because no production caller exists and anchored capability remains disabled.
- Manual UI behavior is not applicable to this pure, unreachable replay seam.

## Completion boundary

MYR-175 establishes and verifies structural insertion ordering, durable-gap incorporation, canonical capture, and a shared dark replay seam. It does not activate anchored production behavior. MYR-179 remains responsible for production wiring and atomic activation; MYR-177 remains responsible for dependency persistence and retry.
