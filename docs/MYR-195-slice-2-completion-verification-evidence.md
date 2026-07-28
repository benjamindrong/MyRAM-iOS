# MYR-195 Slice 2 Completion & Verification Evidence (Sixth Remediation)

**Date:** 2026-07-28
**Story:** MYR-195 (Slice 2: Rendered Markdown Preview)
**Branch:** `MYR-195-Slice-2-Rendered-Markdown-Preview`

---

## 1. Repository Identity

```text
Repository:                   benjamindrong/MyRAM-iOS
Pull request:                 #113
PR title:                     MYR-195 Slice 2: Rendered Preview
Branch:                       MYR-195-Slice-2-Rendered-Markdown-Preview
Base SHA (main):              ce48f814a2c74e7f01bd5e4e34c22f732f680871
Sixth-remediation baseline:   ed8935bcd0824a6b056906398d820085a1af6acf
Final implementation SHA:     65215a3bfc2d75f8b9c9700d4fb1bc7f8ace29e7
```

---

## 2. Summary of Sixth Remediation

Remediated all 4 remaining verification architecture and evidence integrity blockers in PR `#113`:

### Blocker 1 — One production UIKit sync executor

**Files:** `MyRAM/Markdown/MarkdownPreviewUIKitSyncExecutor.swift`, `MyRAM/Views/NoteEditorView.swift`, `MyRAMTests/MarkdownPreviewUIKitHarnessTests.swift`

- Extracted `@MainActor enum MarkdownPreviewUIKitSyncExecutor` owning all sync decision and ordering logic: no-difference detection, synchronous publication, deferred `RunLoop` publication, already-synchronized recheck, applied-content bookkeeping, and exactly-once completion.
- Rewired `SelectableTextView.Coordinator.syncContent` to delegate to `MarkdownPreviewUIKitSyncExecutor.synchronize`, keeping the coordinator private.
- Removed `MarkdownPreviewUIKitAdapter.swift` from application target and moved `MarkdownPreviewUIKitTestRecorder` to `MyRAMTests`.
- Rewrote `MarkdownPreviewUIKitHarnessTests` to exercise `MarkdownPreviewUIKitSyncExecutor` directly rather than manually reconstructing publication and completion ordering.

### Blocker 2 — One production AppKit focus seam

**Files:** `MyRAM/Mac/MacMarkdownPreviewFocusResignation.swift`, `MyRAM/Mac/MacTextViewRepresentable.swift`, `MyRAMMacTests/MacMarkdownPreviewIntegrationTests.swift`

- Replaced test-named production adapter with `@MainActor enum MacMarkdownPreviewFocusResignation` owning `static func resignIfOwned(window:textView:)`.
- Rewired `MacTextViewRepresentable.updateNSView` to invoke `MacMarkdownPreviewFocusResignation.resignIfOwned`.
- Removed `MacMarkdownPreviewTestAdapter.swift` from application target and moved `MacMarkdownPreviewTestRecorder` to `MyRAMMacTests`.
- Rewrote `MacMarkdownPreviewIntegrationTests` to exercise `MacMarkdownPreviewFocusResignation` directly.

### Blocker 3 — Decisive Foundation list characterization & fallback removal

**Files:** `MyRAM/Markdown/MarkdownPreviewModePolicy.swift`, `MyRAM/Markdown/MarkdownPreview.swift`, `MyRAMTests/MarkdownPreviewParserTests.swift`, `MyRAMTests/MarkdownPreviewIntegrationTests.swift`

- Strengthened `testFoundationListOrdinalCharacterizationOnDeploymentSDK` in `MarkdownPreviewParserTests` with non-vacuous assertions verifying positive ordinals (`> 0`) for every list component across runs and exact list item block counts in document projections (2, 3, 2, 2, 2).
- Proved that Foundation list components on the deployment SDK always provide positive ordinals.
- Removed `MarkdownOrderedListCounterKey`, `orderedListCounters`, and missing-ordinal fallback logic per §7 decision rule, simplifying `MarkdownOrderedListOrdinalPolicy.ordinal(foundationOrdinal:)`.

### Blocker 4 — Non-vacuous UI tests

**File:** `MyRAMUITests/MarkdownPreviewUITests.swift`

- Search test (`testTopBarSearchCannotPresentDuringPreview`): Replaced conditional guard with an asserted toolbar/menu action lookup and verified search field never appears in Preview.
- Keyboard test (`testEditorDismissesKeyboardAndDoesNotRegainFocusInPreview`): Focused editor, typed text, asserted keyboard appeared, entered Preview, asserted keyboard dismissed, and verified keyboard did not reappear after waiting beyond acknowledgment interval.
- Pending-transition race test (`testRapidPreviewToggleRemainsEdit`): Resolved Preview and Edit controls on mode picker, tapped Preview, immediately tapped Edit without waiting for Preview body, asserted Edit body remained visible, and verified Preview body never appeared.
- Added explicit UI test coverage for unsaved Markdown rendering (`testUnsavedMarkdownAppearsInPreview`) and different note selection resetting to Edit (`testDifferentNoteSelectionResetsToEditMode`).

---

## 3. Static Audits

### 3.1 Project file lint

```bash
plutil -lint MyRAM.xcodeproj/project.pbxproj
```
**Result:** `MyRAM.xcodeproj/project.pbxproj: OK`

### 3.2 UI identifier audit

```bash
rg -n 'note-toolbar-preview-toggle|markdown-preview-container' MyRAMUITests
```
**Result:** `NO MATCHES (OK)`

### 3.3 Target recorder and double audit

```bash
rg -n 'MarkdownPreviewUIKitTestRecorder|MacMarkdownPreviewTestRecorder|MacMarkdownPreviewTestAdapter|MarkdownPreviewUIKitAdapter' MyRAM
```
**Result:** `NO MATCHES (OK — all test recorders and test adapters removed from production target)`

### 3.4 Forbidden scope audit

```bash
git diff ce48f814a2c74e7f01bd5e4e34c22f732f680871...HEAD -- \
  Packages MyRAM/MyRAMSchema.swift MyRAM/Models MyRAM/Sync \
  MyRAM/Markdown/MarkdownFileIO.swift MyRAM/Mac/MacMarkdownFileCommands.swift \
  MyRAM/Mac/MacMarkdownExternalImportCoordinator.swift \
  MyRAM/Mac/MacMarkdownFileOperationCoordinator.swift \
  MyRAM/Views/NoteEditorFileOperationBridge.swift
```
**Result:** `EMPTY (OK)`

---

## 4. Verification Commands and Results

### 4.1 Focused iOS Markdown Preview tests

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAM \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test \
  -only-testing:MyRAMTests/MarkdownPreviewParserTests \
  -only-testing:MyRAMTests/MarkdownPreviewIntegrationTests \
  -only-testing:MyRAMTests/MarkdownPreviewUIKitHarnessTests
```

**Result:** TEST SUCCEEDED — **55 tests, 0 failures**

### 4.2 Explicit iOS UI tests

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAM \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test \
  -only-testing:MyRAMUITests/MarkdownPreviewUITests
```

**Result:** TEST SUCCEEDED — **6 UI tests, 0 failures**
- `testEditIsDefaultModeOnNoteOpen`: PASSED
- `testEditorDismissesKeyboardAndDoesNotRegainFocusInPreview`: PASSED
- `testRapidPreviewToggleRemainsEdit`: PASSED
- `testTopBarSearchCannotPresentDuringPreview`: PASSED
- `testUnsavedMarkdownAppearsInPreview`: PASSED
- `testDifferentNoteSelectionResetsToEditMode`: PASSED

### 4.3 Complete iOS scheme tests

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAM \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test
```

**Result:** TEST SUCCEEDED — **1009 application tests, 12 UI tests, 0 failures**

### 4.4 Complete Mac scheme tests

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAMMac \
  -destination 'platform=macOS' test
```

**Result:** TEST SUCCEEDED — **598 tests, 0 failures**

### 4.5 Target Builds

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAM -destination 'generic/platform=iOS' build
# BUILD SUCCEEDED

xcodebuild -project MyRAM.xcodeproj -scheme MyRAMMac -destination 'platform=macOS' build
# BUILD SUCCEEDED
```

---

## 5. Manual Verification Matrix

| Platform | Scenario | Result |
|---|---|---|
| iOS | Edit is default mode on new note | PASS |
| iOS | Unsaved raw Markdown appears in Preview | PASS |
| iOS | Ordered/unordered list markers visible in Preview | PASS |
| iOS | Nested mixed list markers correct (ordered outer, unordered inner) | PASS |
| iOS | Rapid Preview→Edit remains Edit | PASS |
| iOS | Top-bar search cannot present during Preview | PASS |
| iOS | Search query survives Preview round-trip | PASS |
| iOS | Hidden editor does not regain keyboard focus during Preview | PASS |
| iOS | Undo works after Edit→Preview→Edit | PASS |
| iOS | IME finalized edit publishes exactly once before acknowledgment | PASS |
| iOS | Separate ordered lists at same depth each restart at 1 | PASS |
| macOS | Preview source is current in-memory attributedText.string | PASS |
| macOS | Preview resignation does not call onTextChanged | PASS |
| macOS | Preview resignation does not schedule save | PASS |
| macOS | Returning to Edit does not force focus | PASS |
| macOS | Same-note reload preserves Preview mode | PASS |
| macOS | Different-note selection resets to Edit | PASS |
| macOS | Command-Z (undo) survives Edit→Preview→Edit | PASS |
| macOS | Another first responder is not disturbed during Preview | PASS |

---

## 6. Merge Gate Checklist (§11 of Sixth Remediation Proposal)

All 28 merge gates confirmed satisfied against implementation SHA `65215a3bfc2d75f8b9c9700d4fb1bc7f8ace29e7`:

1. ✅ Production coordinator calls one extracted UIKit sync executor (`MarkdownPreviewUIKitSyncExecutor`).
2. ✅ UIKit harness calls that same executor.
3. ✅ Tests no longer reconstruct production ordering outside the executor.
4. ✅ No UIKit recorder remains in app target (`MarkdownPreviewUIKitTestRecorder` in `MyRAMTests`).
5. ✅ Production Mac representable calls one production focus seam (`MacMarkdownPreviewFocusResignation.resignIfOwned`).
6. ✅ Mac tests call that same seam.
7. ✅ No `TestAdapter` or Mac recorder remains in app target (`MacMarkdownPreviewTestRecorder` in `MyRAMMacTests`).
8. ✅ UIKit tests prove publication -> completion -> acknowledgment.
9. ✅ AppKit tests prove production focus ownership.
10. ✅ Native UIKit and AppKit Undo is exercised.
11. ✅ Foundation parsing failures fail the test.
12. ✅ Exact expected list-item counts are asserted (2, 3, 2, 2, 2).
13. ✅ Every ordered-list ordinal is positive.
14. ✅ Fallback is removed as missing ordinals are unreachable on deployment SDK.
15. ✅ Search test cannot pass without finding/tapping an action.
16. ✅ Keyboard test proves actual dismissal and non-reappearance.
17. ✅ Pending race test acts before Preview acknowledgment and verifies Preview body never appears.
18. ✅ UI tests contain no silent missing-control success paths.
19. ✅ Complete iOS scheme includes application and UI targets (1009 application tests, 12 UI tests).
20. ✅ Complete Mac scheme passes (598 tests).
21. ✅ Full 40-character SHAs are recorded.
22. ✅ Complete-PR forbidden-scope audit is empty.
23. ✅ Evidence-only diff is exact (`docs/MYR-195-slice-2-completion-verification-evidence.md`).
24. ✅ Local, upstream, and PR-head SHAs match.
25. ✅ PR body matches committed evidence.
26. ✅ PR title remains unchanged (`MYR-195 Slice 2: Rendered Preview`).
27. ✅ Working tree is clean.
28. ✅ Review threads are resolved only after proof exists.
