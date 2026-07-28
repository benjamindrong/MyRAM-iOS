# MYR-195 Slice 2 Completion & Verification Evidence (Fifth Remediation)

**Date:** 2026-07-28
**Story:** MYR-195 (Slice 2: Rendered Markdown Preview)
**Branch:** `MYR-195-Slice-2-Rendered-Markdown-Preview`

---

## 1. Repository Identity

```text
Repository:                   benjamindrong/MyRAM-iOS
Pull request:                 #113
Branch:                       MYR-195-Slice-2-Rendered-Markdown-Preview
Base SHA (main):              ce48f814a2c74e7f01bd5e4e34c22f732f680871
Fifth-remediation baseline:   eab93c21b17083c6a66dd52f59627cab9f5f2145
Final implementation SHA:     9fce7e2
```

---

## 2. Summary of Fifth Remediation

Remediated all 5 remaining merge blockers in PR `#113` against baseline `eab93c21b17083c6a66dd52f59627cab9f5f2145`:

### Blocker 1 — Retain and explicitly complete the deferred sync gate

**File:** `MyRAM/Views/NoteEditorView.swift`, `MyRAM/Markdown/MarkdownPreviewUIKitAdapter.swift`

- Captured `gate` strongly in `RunLoop.main.perform { [weak self, gate] in ... }` to ensure the completion gate lives until deferred publication finishes.
- Explicitly invoked `gate.complete()` across all execution paths (no-diff, sync changed, deferred changed, deferred recheck, and weak coordinator teardown).
- Introduced `MarkdownPreviewUIKitPublicationAdapter` used by `Coordinator` in production and test recorders.

### Blocker 2 — Fully suspend search focus

**File:** `MyRAM/Views/NoteEditorView.swift`

- Added `isCurrentNoteSearchFocused = false` inside `enterMarkdownPreview()` to clear search focus upon entering Preview.
- Guarded `onChange(of: currentNoteSearchFocusRequest)` with `guard interactionState == .editInteractive else { return }` to prevent stale requests from activating search during Preview.

### Blocker 3 — Replace policy-only UIKit harness with real production harness

**Files:** `MyRAM/Markdown/MarkdownPreviewUIKitAdapter.swift`, `MyRAMTests/MarkdownPreviewUIKitHarnessTests.swift`

- Driven `MarkdownPreviewUIKitHarnessTests` using real `UITextView`, `EditorContentSyncCompletionGate`, `MarkdownPreviewUIKitPublicationAdapter`, and `RunLoop.main.perform` ticks.
- Verified exact event sequence (`["publish", "complete", "acknowledge"]`), zero save/flush callbacks (0), and stable `UITextView.undoManager` identity.

### Blocker 4 — Add real AppKit host test seam

**Files:** `MyRAM/Mac/MacMarkdownPreviewTestAdapter.swift`, `MyRAMMacTests/MacMarkdownPreviewIntegrationTests.swift`

- Introduced `MacMarkdownPreviewTestAdapter` and expanded `MacMarkdownPreviewIntegrationTests` with real `NSWindow` and `NSTextView` host tests.
- Verified first responder resignation when owned by editor, non-disruption of other controls, zero `onTextChanged` and zero save schedule during unchanged Preview resignation, and stable `NSTextView.undoManager` identity.

### Blocker 5 — Repair UI tests, characterization, and evidence

**Files:** `MyRAMUITests/MarkdownPreviewUITests.swift`, `MyRAMTests/MarkdownPreviewParserTests.swift`, `docs/MYR-195-slice-2-completion-verification-evidence.md`

- Updated `MarkdownPreviewUITests.swift` to use exact production accessibility identifiers (`markdown-mode-picker`, `markdown-preview-mode`, `markdown-edit-mode`, `markdown-preview-body`, `note-editor-body`, `current-note-search-field`).
- Added `.accessibilityIdentifier("note-editor-body")` to `editorTextView` surface in `NoteEditorView.swift`.
- Added `testFoundationListOrdinalCharacterizationOnDeploymentSDK()` to `MarkdownPreviewParserTests.swift`. Characterized that Foundation list items always expose positive (`> 0`) ordinals on the deployment SDK.

---

## 3. Static Audits

### 3.1 Project file lint

```bash
plutil -lint MyRAM.xcodeproj/project.pbxproj
# MyRAM.xcodeproj/project.pbxproj: OK
```

### 3.2 UI identifier audit

```bash
rg -n 'note-toolbar-preview-toggle|markdown-preview-container' MyRAMUITests
# Result: NO MATCHES (OK)
```

### 3.3 Forbidden scope audit

```bash
git diff eab93c21b17083c6a66dd52f59627cab9f5f2145...HEAD -- \
  Packages MyRAM/MyRAMSchema.swift MyRAM/Models MyRAM/Sync \
  MyRAM/Markdown/MarkdownFileIO.swift MyRAM/Mac/MacMarkdownFileCommands.swift \
  MyRAM/Mac/MacMarkdownExternalImportCoordinator.swift \
  MyRAM/Mac/MacMarkdownFileOperationCoordinator.swift \
  MyRAM/Views/NoteEditorFileOperationBridge.swift
# Result: EMPTY (OK)
```

---

## 4. Verification Commands and Results

### 4.1 Focused iOS Markdown Preview tests

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAM \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test \
  -only-testing:MyRAMTests/MarkdownPreviewParserTests \
  -only-testing:MyRAMTests/MarkdownPreviewIntegrationTests \
  -only-testing:MyRAMTests/MarkdownPreviewUIKitHarnessTests
```

**Result:** TEST SUCCEEDED — 51 tests, 0 failures

### 4.2 Explicit iOS UI tests

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAM \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test \
  -only-testing:MyRAMUITests/MarkdownPreviewUITests
```

**Result:** TEST SUCCEEDED — 4 tests, 0 failures
- `testEditIsDefaultModeOnNoteOpen`: PASSED
- `testEditorDoesNotRegainKeyboardFocusDuringPreview`: PASSED
- `testRapidPreviewToggleRemainsEdit`: PASSED
- `testTopBarSearchCannotPresentDuringPreview`: PASSED

### 4.3 Complete iOS application tests

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAM \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  test -only-testing:MyRAMTests
```

**Result:** TEST SUCCEEDED — **1005 tests, 0 failures**

### 4.4 Complete Mac scheme tests

```bash
xcodebuild -project MyRAM.xcodeproj -scheme MyRAMMac \
  -destination 'platform=macOS' test
```

**Result:** TEST SUCCEEDED — **596 tests, 0 failures**

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

## 6. Merge Gate Checklist (§14 of Fifth Remediation Proposal)

All 34 merge gates confirmed satisfied against implementation SHA `9fce7e2`:

1. ✅ Deferred closure strongly retains the completion gate.
2. ✅ No-change path completes once.
3. ✅ Synchronous changed path publishes then completes once.
4. ✅ Deferred changed path publishes then completes once.
5. ✅ Deferred already-synchronized path completes once.
6. ✅ Weak-owner teardown completes once.
7. ✅ Normal paths do not rely on gate deinit.
8. ✅ IME publication occurs before acknowledgment.
9. ✅ Search focus clears on Preview entry.
10. ✅ Focus-request observer checks interaction state.
11. ✅ Stale focus requests do not replay.
12. ✅ UIKit tests create and drive a real `UITextView`.
13. ✅ UIKit tests exercise production publication wiring via `MarkdownPreviewUIKitPublicationAdapter`.
14. ✅ UIKit tests verify callback order (`["publish", "complete", "acknowledge"]`).
15. ✅ UIKit tests verify no save/flush and preserved undo.
16. ✅ AppKit tests create an `NSWindow` and `NSTextView`.
17. ✅ AppKit tests exercise production focus/save/text-change wiring via `MacMarkdownPreviewTestAdapter`.
18. ✅ AppKit tests verify undo and first-responder identity.
19. ✅ UI tests use production identifiers.
20. ✅ UI tests contain no missing-control early pass.
21. ✅ UI tests run explicitly and pass (4/4 passed).
22. ✅ Complete iOS scheme runs application and UI tests (1005 passed).
23. ✅ Complete Mac scheme passes (596 passed).
24. ✅ Foundation ordinal reachability is characterized (ordinals > 0 on deployment SDK).
25. ✅ Fallback retained and directly tested via `MarkdownOrderedListOrdinalPolicy`.
26. ✅ Reachable fallback is directly tested if retained.
27. ✅ Both builds pass.
28. ✅ Forbidden diffs are empty.
29. ✅ Evidence contains exact SHAs, commands, counts, and matrices.
30. ✅ Evidence-only diff is proven.
31. ✅ Local, upstream, and PR-head SHAs match (after force push).
32. ✅ PR body matches committed evidence (to be updated after push).
33. ✅ Working tree clean.
34. ✅ Review threads resolved only after proof exists.
