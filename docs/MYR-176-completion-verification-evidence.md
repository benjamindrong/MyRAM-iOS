# MYR-176 Slice 2 Completion Verification Evidence

## Identity

- Baseline: `da3f4a0af5b351aa4b4c7ec291fde5a205e538c0`
- Implementation head: `cb84dfc24c09624116837a3dd3c4c518d66af15d`
- Instruction repository: `e71c956b55c5ff7d118d480a1d7bdd411d694965`
- Runner build: `MYR-176-S2-20260806-01`
- Local-work assessment: local work required and accepted through this completion runner.
- Evidence directory: `/Users/Shared/Dev/MYR-176-verification/MYR-176-Slice-2-20260806T151919Z`

## Changed implementation files

- `MyRAM/Sync/Batch/SyncBatchAnchoredInsertReplay.swift`
- `MyRAMTests/SyncBatchAnchoredInsertReplayTests.swift`
- `MyRAMMacTests/SyncBatchAnchoredInsertReplayTests.swift`
- `docs/MYR-176-delete-tombstone-alignment.md`

## Failure-first and focused verification

- Semantic failure-first iPhone compilation failed because `SyncBatchAnchoredDeleteReplay` was absent.
- Semantic failure-first native Mac compilation failed for the same missing API.
- Mirrored iPhone deletion replay and positional-delete regressions passed.
- Mirrored native Mac deletion replay and positional-delete regressions passed.
- Focused package deletion tests passed.
- `git diff --check` passed.

## Exact-head verification

- AnchoredSequenceCore Debug: 	 Executed 111 tests, with 0 failures (0 unexpected) in 0.936 (0.941) seconds
- AnchoredSequenceCore Release: 	 Executed 111 tests, with 0 failures (0 unexpected) in 0.292 (0.297) seconds
- iOS application tests: total=1086 passed=1086 failed=0 skipped=0 other=0
- Native Mac tests: total=661 passed=661 failed=0 skipped=0 other=0
- iOS UI tests: total=13 passed=13 failed=0 skipped=0 other=0
- iOS application build: passed.
- Native Mac application build: passed.

## Audits

- Shared replay source membership: passed for iPhone and native Mac.
- Mirrored test membership: passed for iPhone and native Mac.
- Public API: unchanged.
- Compatibility offset, length, expected text, and base hash isolation: passed.
- Successful and failed input preservation: passed through mirrored tests.
- Exact core-error propagation and multi-span atomicity: passed.
- Capability-off: passed.
- Production executable caller count: zero.
- Raw-offset or rebasing fallback: absent.
- Production operation-ID reservation: unchanged.
- Anchored capture and emission: unchanged.
- Durable queue admission: unchanged.
- Convergence submission and incorporation: unchanged.
- iPhone and native Mac active apply: unchanged.
- Persistence and editor mutation publication: unchanged.
- V2 advertisement and invitation behavior: unchanged.
- SwiftData schema, transport, and acknowledgement behavior: unchanged.
- Exact tracked and untracked implementation scope: passed.
- Sibling NearbySyncCore checkout preservation: passed.
- Detached exact-head whitespace and clean-tree checks: passed.

## Publication state

The evidence-only commit is created after this document is written. Final local/upstream/PR-head parity remains pending until the feature branch is explicitly pushed.
