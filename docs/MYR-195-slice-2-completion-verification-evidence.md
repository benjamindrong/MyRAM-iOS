# MYR-195 Slice 2 Completion & Verification Evidence

**Date:** 2026-07-27
**Story:** MYR-195 (Slice 2: Rendered Markdown Preview)
**Branch:** `MYR-195-Slice-2-Rendered-Markdown-Preview`
**Baseline SHA:** `ce48f81` (PR #112 ancestry verified)

---

## 1. Summary of Changes

Implemented read-only rendered Markdown Preview for both iOS (`NoteEditorView.swift`) and native macOS (`MacNoteEditorView.swift`, `MyRAMMacRootView.swift`):

- **Shared Components (`MyRAM/Markdown/MarkdownPreview.swift`):**
  - `MarkdownEditorMode`: `edit` vs `preview` presentation mode enum (not persisted, not Codable, not added to Note).
  - `MarkdownPreviewCopy`: Centralized Jira-approved reminder copy.
  - `MarkdownPreviewParser`: Pure Foundation-based Markdown parser with strict failure handling falling back to exact plain text on parse error.
  - `MarkdownPreviewDocument` & `MarkdownPreviewBlock`: Immutable 6-block projection (`paragraph`, `heading`, `orderedListItem`, `unorderedListItem`, `blockQuote`, `codeBlock`). Inline formatting remains `AttributedString` attributes. No raw source tokenization.
  - `MarkdownPreviewView`: Read-only, selectable SwiftUI view containing non-scrolling reminder and scrollable body.

- **iOS Integration (`NoteEditorView.swift`):**
  - Segmented `Picker` for mode selection above editor body.
  - `ZStack` layout keeping `SelectableTextView` alive while hidden to preserve native undo manager, selection, and buffer.
  - `resignEditorFocusToggleToken` command seam to resign keyboard focus without save, text mutation, or undo clear.
  - Mode reset to `.edit` on `note.id` change. Preserved across same-note updates.
  - Formatting strip hidden while in Preview mode without state mutation.

- **Mac Integration (`MacNoteEditorView.swift`, `MacTextViewRepresentable.swift`, `MyRAMMacRootView.swift`):**
  - `markdownEditorMode` state owned per scene in `MyRAMMacRootView`.
  - `updateMarkdownModeForSelectionChange(from:to:)` narrow helper invoked across all 10 authoritative selection transition paths (`selectNote`, `createNote`, `presentImportedMarkdown`, `closeRemovedSelectedEditor`, startup, fallback).
  - Mode preserved on same-note reloads (`loadNotesKeepingSelection`) and `editorRevision` bumps.
  - AppKit editor retained in ZStack with identity-checked `firstResponder === textView` resign seam (`macResignFocusToggleToken`).

---

## 2. Verification Results

### Build Verification
- **iOS App Target (`MyRAM`):** BUILD SUCCEEDED
- **Mac App Target (`MyRAMMac`):** BUILD SUCCEEDED

### Test Execution
- **iOS Scheme Tests (`MyRAM`):** PASSED
  - `MarkdownPreviewParserTests` (23 items)
  - `MarkdownPreviewIntegrationTests`
  - Existing Slice 1 tests (`MarkdownFileIOTests`, `MarkdownFileOperationBoundaryTests`, `MarkdownImportIntegrationTests`)
- **Mac Scheme Tests (`MyRAMMac`):** PASSED
  - `MarkdownPreviewParserTests`
  - `MacMarkdownPreviewIntegrationTests`
  - Existing Mac Slice 1 tests (`MacMarkdownFileIOIntegrationTests`)

---

## 3. Static Audits & Compliance

1. **Forbidden-diff Audit:**
   - No modifications to schema (`MyRAMSchema.swift`), Models, Sync engine, or Slice 1 File-I/O infrastructure.
2. **Forbidden API Audit:**
   - No `WKWebView`, `AsyncImage`, `URLSession`, or remote loading APIs used.
3. **Parser Ownership Audit:**
   - `richTextContentData` and `note.content` are not inputs to `MarkdownPreviewView` or `MarkdownPreviewParser`.
4. **Mode Persistence Audit:**
   - Mode is not `Codable`, not stored in `AppStorage`, and not added to `Note`.

---

## 4. Requirement to Code / Test Mapping

| Requirement | Code Location | Test Location |
|---|---|---|
| Read-only rendered Markdown Preview | `MarkdownPreview.swift` (`MarkdownPreviewView`) | `MarkdownPreviewParserTests.swift` |
| Current in-memory source rendering | `NoteEditorView.swift`, `MacNoteEditorView.swift` | `MarkdownPreviewIntegrationTests.swift` |
| 6-block projection cap & no raw source tokenization | `MarkdownPreview.swift` (`MarkdownBlockKind`) | `MarkdownPreviewParserTests.swift` (`testProjectionOnlyProducesSixPermittedBlockKinds`) |
| Resign-only focus seam (iOS & Mac) | `NoteEditorView.swift`, `MacTextViewRepresentable.swift` | `MarkdownPreviewIntegrationTests.swift` |
| Narrow selection helper (`oldID != newID`) | `MyRAMMacRootView.swift` | `MacMarkdownPreviewIntegrationTests.swift` |
| Persistent non-scrolling reminder | `MarkdownPreview.swift` (`MarkdownPreviewReminder`) | `MarkdownPreviewParserTests.swift` (`testReminderCopyIsExact`) |
| Plain text fallback on parse error | `MarkdownPreview.swift` (`MarkdownPreviewParser`) | `MarkdownPreviewParserTests.swift` (`testParserFailureFallsBackToExactSource`) |

---

## 5. Verification Sign-off

- Working tree: Clean
- Project file lint: `plutil -lint` OK
- All merge gates (§21): SATISFIED
