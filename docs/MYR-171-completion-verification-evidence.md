# MYR-171 Completion Verification Evidence

## Scope and verdict

MYR-171 is delivered in three ordered slices: portable anchored payload primitives, dark MyRAM payload and boundary wiring, and this final legacy-compatibility closure.

Final verdict: the three slices form a verified dark delivery. Anchored payloads remain disabled and fail closed at active transport/application boundaries. Slice 3 changes only the iOS compatibility test source and this evidence document.

## Verified identities

| Identity | Value |
|---|---|
| Refreshed baseline SHA | `3869daefe0001f0320a715c1b48295fefa1429d3` |
| Slice 3 branch | `MYR-171-slice-3-payload-compatibility-closure` |
| Verified compatibility-test blob | `b45af6d5f364e9fbb4a624fa32f90ec738cad841` |
| Xcode version and build | Xcode 26.5; build `17F42` |
| Swift version | Apple Swift 6.3.2 (`swiftlang-6.3.2.1.108 clang-2100.1.1.101`), target `x86_64-apple-macosx26.0` |
| iOS simulator | iPhone 17 Pro; iOS 26.5; `5B32FB38-E96C-4C25-8831-6C848CD66124` |

A commit cannot contain its own SHA, and this evidence file exists before PR creation. The final Slice 3 commit SHA and PR number therefore belong in the PR body and final handoff metadata after they exist, not in this committed document. Post-commit verification must prove that `HEAD:MyRAMTests/SyncBatchPayloadCompatibilityTests.swift` has the verified compatibility-test blob recorded above.

## Slice inventory

| Slice | Delivery | Identity |
|---|---|---|
| Slice 1 | Portable anchored payload primitives | PR #108; merge `adea8a45ed1f399915558f315dcec717f063babd` |
| Slice 2 | Dark MyRAM adapters and boundaries | PR #109; merge `3869daefe0001f0320a715c1b48295fefa1429d3` |
| Slice 3 | Independent V1 compatibility proof and completion evidence | Branch and verified test-source blob above; commit and PR deferred to publication metadata |

## Architecture decisions

- `AnchoredSequenceCore` owns the platform-neutral schema and compact delete-span representation.
- MyRAM owns conversion adapters and the hard-disabled capability policy.
- Legacy and anchored payload cases remain explicit. Insertions retain both left and right boundaries.
- Both envelope layers and the outer batch message kind remain V1; MYR-171 introduces no envelope V2.
- MYR-173 owns activation. MYR-174 owns negotiation, rollout, and any canonical or transport-compatibility change.
- Default `JSONEncoder` keyed-object order is not a canonical byte contract. Slice 3 compares parsed JSON recursively while preserving array order, keys, values, case tags, nesting, null presence, and scalar types.
- The outer base64 payload is decoded and structurally compared as nested JSON. No `.sortedKeys` or production encoder change is introduced.
- The frozen legacy JSON is one known decode vector, not the only valid legacy byte encoding.

## Exact Slice 3 compatibility tests

- `testCapabilityOffProductionCaptureCreatesOnlyLegacyBodyCases`
- `testCapabilityOffCurrentSixCaseBatchStructurallyEqualsLegacyV1`
- `testCapabilityOffCurrentSixCaseBatchEnvelopeStructurallyEqualsLegacyV1`
- `testCapabilityOffCurrentSixCaseMultipeerEnvelopeIsRecursivelyCompatibleWithLegacyV1`
- `testCapabilityOffSixCaseEncodingRemainsStructurallyStableAcrossRepeatedInvocations`
- `testCurrentDecoderReadsLegacyV1SixCaseFixture`
- `testLegacyV1DecoderReadsCurrentCapabilityOffSixCaseFixture`
- `testLegacyV1CompatibilityFixtureRetainsAllSixCasesAndUTF16Evidence`
- `testLegacyTransportConstantsRemainV1`

Both independent final compatibility invocations executed 33 tests with 0 failures and ended with `** TEST SUCCEEDED **`.

## Requirement-to-evidence map

| Requirement | Evidence |
|---|---|
| New fields encode and decode | Slice 1 package payload tests and the complete package suite |
| Portable package ownership | `AnchoredSequenceCore` dependency and prohibited-import audits |
| MyRAM adapter ownership | Existing adapter tests and unchanged application target membership |
| Six legacy cases decode both directions | Independent legacy DTO tests using fixed note, folder, body insert/delete, reconciliation, and lifecycle cases |
| Exact V1 JSON shape | Structural batch and inner-envelope comparisons plus explicit key, case-tag, nesting, omitted-null, and scalar-type assertions |
| Complete outer compatibility | Exact outer kind/schema checks followed by base64 payload decoding and recursive nested-JSON comparison |
| Known legacy decode vector | Frozen six-case JSON fixture decoded by current and independent legacy models without a canonical-byte claim |
| UTF-16 evidence | Supplementary scalar fixture preserves exact insertion offset and deletion length |
| Malformed payload rejection | Existing package and application malformed-boundary tests |
| Dark capability and fail-closed application | Capability-off capture test, anchored transport rejection, iOS applier tests, and active native-Mac controller/coordinator tests |
| Ordered completion | Slice 1 and Slice 2 merged before the Slice 3 baseline |

## Command-level verification

All commands ran from `/Users/Shared/Development/XcodeProjects/MyRAM`. Xcode test/build commands ran sequentially.

| Command | Exit | Observed count and result |
|---|---:|---|
| `xcodebuild -version` | 0 | Xcode 26.5, build `17F42` |
| `xcrun swift --version` | 0 | Apple Swift 6.3.2; target `x86_64-apple-macosx26.0` |
| Section 15 available-iPhone selection and `xcrun simctl bootstatus 5B32FB38-E96C-4C25-8831-6C848CD66124 -b` | 0 | Selected iPhone 17 Pro, iOS 26.5; boot finished |
| `(cd Packages/AnchoredSequenceCore && swift test --filter SyncTextOperationPayloadTests)` | 0 | 26 tests, 0 failures; passed |
| `(cd Packages/AnchoredSequenceCore && swift test)` | 0 | 71 tests, 0 failures; passed |
| `xcodebuild -project MyRAM.xcodeproj -scheme MyRAM -destination 'platform=iOS Simulator,id=5B32FB38-E96C-4C25-8831-6C848CD66124' test -only-testing:MyRAMTests/SyncBatchPayloadCompatibilityTests` (first independent invocation) | 0 | 33 tests, 0 failures; `** TEST SUCCEEDED **` |
| Same compatibility command (second independent invocation) | 0 | 33 tests, 0 failures; `** TEST SUCCEEDED **` |
| `xcodebuild -project MyRAM.xcodeproj -scheme MyRAM -destination 'platform=iOS Simulator,id=5B32FB38-E96C-4C25-8831-6C848CD66124' test -only-testing:MyRAMTests/SyncBatchAnchoredPayloadTests -only-testing:MyRAMTests/MyRAMSyncControllerTests -only-testing:MyRAMTests/IPhoneSyncBatchApplierTests` | 0 | 53 tests, 0 failures; `** TEST SUCCEEDED **` |
| `xcodebuild -project MyRAM.xcodeproj -scheme MyRAMMac -destination 'platform=macOS' test -only-testing:MyRAMMacTests/MacSyncBatchControllerTests -only-testing:MyRAMMacTests/MacSyncConvergenceCoordinatorTests` | 0 | 19 tests, 0 failures; `** TEST SUCCEEDED **` |
| `xcodebuild -project MyRAM.xcodeproj -scheme MyRAM -destination 'platform=iOS Simulator,id=5B32FB38-E96C-4C25-8831-6C848CD66124' test` (initial attempt) | 65 | `MyRAMTests` passed 914/914. Three UI tests passed; two UI cases could not initialize because a cloned simulator's `launchd_sim` stopped responding and Accessibility loading timed out. Infrastructure failure; `** TEST FAILED **`. |
| Same complete iOS command after restarting only the selected simulator, without erasing it | 0 | Finalized xcresult: 920 tests, 0 failures, 0 skipped; `** TEST SUCCEEDED **` |
| `xcodebuild -project MyRAM.xcodeproj -scheme MyRAMMac -destination 'platform=macOS' test` | 0 | 530 tests, 0 failures; `** TEST SUCCEEDED **` |
| `xcodebuild -project MyRAM.xcodeproj -scheme MyRAM -destination 'generic/platform=iOS Simulator' build` | 0 | `** BUILD SUCCEEDED **`; existing AppIntents metadata-skip warning only |
| `xcodebuild -project MyRAM.xcodeproj -scheme MyRAMMac -destination 'platform=macOS' build` | 0 | `** BUILD SUCCEEDED **`; existing AppIntents metadata-skip warning only |
| `git hash-object MyRAMTests/SyncBatchPayloadCompatibilityTests.swift` | 0 | `b45af6d5f364e9fbb4a624fa32f90ec738cad841` |

## Staged static and scope audits

The first complete cached audit passed. Its exact staged file list was:

- `MyRAMTests/SyncBatchPayloadCompatibilityTests.swift`
- `docs/MYR-171-completion-verification-evidence.md`

Observed audit results:

- `git diff --cached --check` passed, and the staged diff was exactly two files.
- No production, package, native-Mac test, UI-test, or project-file change was staged.
- `plutil -lint MyRAM.xcodeproj/project.pbxproj` reported `OK`.
- `AnchoredSequenceCore` had no prohibited platform or application imports.
- Both envelope schema constants remained `1`; the outer kind remained `myram.batchSync.v1`; no V2 value was present.
- `SyncBatchAnchoredPayloadCapability.isEnabled` remained `false`, with no production `true` assignment.
- Production capture referenced no anchored change case or anchored adapter.
- Active-Mac exclusion assertions for the obsolete applier and its tests remained present.
- The evidence identity scan found verified compatibility-test blob `b45af6d5f364e9fbb4a624fa32f90ec738cad841`.

Manual target-membership review and the successful builds/tests confirmed:

- `SyncBatchAnchoredPayloadAdapter.swift` and `SyncBatchAnchoredPayloadPolicy.swift` remain in both application source phases.
- `SyncBatchPayloadCompatibilityTests.swift` remains only in the `MyRAMTests` source phase.
- `MacSyncBatchControllerTests.swift` and `MacSyncConvergenceCoordinatorTests.swift` remain in `MyRAMMacTests`.
- The obsolete Mac applier and its tests remain outside the active native-Mac source phases.
- No `AnchoredSequenceCore` source is compiled directly into an application or test target.
- `MyRAMUITests` gained no source or dependency, and this Markdown file has no target membership.

This evidence update changes one staged file, so the entire cached audit must pass again from the beginning before commit.

## Non-goals and remaining ownership

This slice does not activate anchored payloads, negotiate capabilities, structurally incorporate or replay anchored operations, change UI behavior, migrate persisted data, introduce canonical encoding, or change production wire output. Those responsibilities remain outside MYR-171 under MYR-173 and MYR-174.

No private comparison repository is named or linked in this evidence.
