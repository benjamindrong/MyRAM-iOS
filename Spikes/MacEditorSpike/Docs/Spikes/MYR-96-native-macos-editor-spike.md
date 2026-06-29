# MYR-96 Native macOS Editor Spike

Note: This document is historical. The current desktop strategy was superseded by the native macOS direction established in MYR-104+ and formalized by MYR-110. Mac Catalyst is no longer the active desktop support path.

## Purpose

Prototype a minimal native macOS editor surface using AppKit `NSTextView` so large-note drag selection and edge auto-scroll can be compared against the Catalyst editor behavior observed in MYR-95.

## Scope

- Native AppKit shell only.
- Generated large attributed note fixture.
- Rich-text attributes include fonts, paragraph styles, emphasis, links, underline, and list-like indentation.
- No MyRAM persistence, sync, search, attachment, intelligence, folder, or complete product UI work.

## Manual Evaluation Checklist

1. From `Spikes/MacEditorSpike`, run `swift run MyRAMMacEditorSpike`.
2. Click near the top of the generated note.
3. Drag-select downward through multiple sections.
4. Hold the pointer near the bottom edge of the visible editor.
5. Record whether edge auto-scroll starts promptly, remains smooth, stalls, jumps, or loses selection state.
6. Repeat upward from a lower section and compare the behavior.
7. Compare observations against Catalyst TextKit2 and forced TextKit1 behavior from MYR-95.

## Decision Output

Record one recommendation before closing the spike:

- Keep Catalyst as the Mac path for now.
- Start staged native macOS editor migration with shared MyRAM core models.
- Investigate larger architectural changes such as document chunking or custom editor behavior.

## Findings

Not evaluated yet. This project provides the native AppKit data point needed for manual large-selection testing.
