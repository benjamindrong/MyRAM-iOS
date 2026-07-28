# MYR-195 Slice 2 Completion & Verification Evidence (Final Remediation)

**Date:** 2026-07-27
**Story:** MYR-195 (Slice 2: Rendered Markdown Preview)
**Branch:** `MYR-195-Slice-2-Rendered-Markdown-Preview`
**Base SHA (`main`):** `ce48f814a2c74e7f01bd5e4e34c22f732f680871`
**Final Remediation Baseline SHA:** `7bfce7c8ea45bd25ef62d88242e1f85239b07fee`

---

## 1. Summary of Final Remediation

Remediated all 7 remaining review blockers for PR `#113`:

1. **Innermost List Style Precedence (`MarkdownPreview.swift`):**
   - Derived marker style from the **innermost** list container in `PresentationIntent.components` (`listContainers.first`).
   - Nested unordered lists inside ordered containers (e.g. `1. Outer\n   - Inner`) render correctly as `•` with depth 2 indentation.

2. **Container-Scoped Fallback List Counters (`MarkdownPreview.swift`):**
   - Keyed ordered list fallback counters by `MarkdownOrderedListCounterKey(containerIdentity: Int, depth: Int)`.
   - Separate ordered lists at the same nesting depth independently restart numbering at `1`.

3. **Deferred Main-Actor Focus Acknowledgment (`MarkdownPreviewModePolicy.swift`, `NoteEditorView.swift`):**
   - Dispatched focus resignation acknowledgments via `MarkdownPreviewAcknowledgmentDispatcher` onto the main actor.
   - Prevents synchronous SwiftUI `@State` (`markdownEditorMode`) mutations during `updateUIView` or delegate execution cycles.

4. **Hidden-Editor Focus Command Isolation (`NoteEditorView.swift`):**
   - Consumed `keyboardFocusToggleToken` alongside formatting tokens when `markdownEditorMode == .preview`.
   - Prevents hidden editor from calling `becomeFirstResponder()` or replaying focus commands upon return to Edit mode.

5. **IME & Marked-Text Exactly-Once Resignation Contract (`MarkdownPreviewModePolicy.swift`, `NoteEditorView.swift`):**
   - Evaluated `MarkdownPreviewResignationPolicy.disposition(isPreviewResignation:boundPlainText:nativePlainText:)`.
   - **Unchanged text:** Updates string binding and dispatches deferred acknowledgment without running `syncContent`.
   - **IME-finalized text mutation:** Publishes final user edit **exactly once** via `syncContent(from:)`, does NOT force immediate persistence flush or extra revision bump, and acknowledges focus resignation after state accepts the mutation.

6. **Complete 6-Entry-Point Search Isolation (`MarkdownPreviewModePolicy.swift`, `NoteEditorView.swift`):**
   - Suspended search controls presentation (`isCurrentNoteSearchPresented`), body highlight application (`selectedBodySearchRange`), and search focus (`isCurrentNoteSearchFocused = false`) across all 6 entry points while retaining stored query text.

7. **Pure Production Seam Types (`MarkdownPreviewModePolicy.swift`):**
   - Extracted `MarkdownPreviewSelectionPolicy`, `MarkdownPreviewAcknowledgmentDispatcher`, `MarkdownPreviewResignationPolicy`, `MarkdownPreviewCommandConsumptionPolicy`, and `MarkdownPreviewSearchInteractionPolicy` as pure production types.
   - Unit tests exercise these production types directly without exposing private view types.

---

## 2. Verification Results

### Build Verification
- **iOS App Target (`MyRAM`):** BUILD SUCCEEDED
- **Mac App Target (`MyRAMMac`):** BUILD SUCCEEDED

### Test Execution
- **iOS Scheme Tests (`MyRAMTests`):** PASSED (976 tests executed, 0 failures)
  - `MarkdownPreviewParserTests` (14 tests passed)
  - `MarkdownPreviewIntegrationTests` (7 tests passed)
- **Mac Scheme Tests (`MyRAMMacTests`):** PASSED (582 tests executed, 0 failures)
  - `MarkdownPreviewParserTests` (14 tests passed)
  - `MacMarkdownPreviewIntegrationTests` (4 tests passed)

---

## 3. Static Audits & Compliance

1. **Project File Lint:** `plutil -lint MyRAM.xcodeproj/project.pbxproj` → OK
2. **Forbidden Diff Audit:** No modifications to `Packages/`, `MyRAMSchema.swift`, `Models/`, `Sync/`, or Slice 1 File-I/O infrastructure.
3. **Forbidden API Audit:** No `WKWebView`, `AsyncImage`, `URLSession`, or remote loading APIs used.
4. **Parser Ownership Audit:** `richTextContentData` and `note.content` are not inputs to `MarkdownPreviewView` or `MarkdownPreviewParser`.
5. **Mode Persistence Audit:** Mode is not `Codable`, not stored in `AppStorage`, and not added to `Note`.

---

## 4. Manual Verification Matrix

| Target | Scenario | Result |
|---|---|---|
| iOS | Innermost list style precedence (Ordered outer -> Unordered inner renders as bullet) | PASS |
| iOS | Container-scoped counters (Two separate ordered lists at same depth start at 1) | PASS |
| iOS | Focus resignation acknowledges asynchronously without synchronous @State mutation | PASS |
| iOS | Hidden editor ignores keyboard focus requests in Preview | PASS |
| iOS | IME marked-text edit publishes exactly once during resignation without forced flush | PASS |
| iOS | Search controls & highlights hidden across all 6 entry points; query preserved | PASS |
| macOS | Same-note reload preserves Preview mode | PASS |
| macOS | Different note selection resets mode to Edit | PASS |
| macOS | AppKit focus resignation does not call `onTextChanged` or schedule save | PASS |

---

## 5. Verification Sign-off

- Working tree: Clean
- Project file lint: OK
- All 34 merge gates (§16 of final proposal): SATISFIED
