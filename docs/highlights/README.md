# Highlights Interaction Spec

## Goal

Highlights give a note a lightweight RAM layer: a small set of high-value text snippets that stay easy to see and act on without turning fast note capture into a structured list workflow.

The main note body remains the default place for free-text capture. Highlights are an optional layer for things the user wants to keep visible, revisit, or organize above the normal flow of text.

## Interaction Principles

- Capture stays fast. Users can keep typing free-form text without choosing a structure first.
- Highlighting is additive. A highlight surfaces or preserves an important idea; it does not require rewriting the note.
- Structure is local. Highlights organize the current note, not the entire notebook.
- The note body remains authoritative. Highlights should never hide, delete, or silently mutate note body content unless the user explicitly chooses that action.

## Placement

Highlights appear inside the note editor above the main note body and below the note title/top controls.

When a note has highlights, the editor layout is:

1. Note title and top actions.
2. Highlights section.
3. Main note body.
4. Keyboard/editor controls.

The highlights section should stay visually distinct from the body but not dominate the page. It should read as a compact working memory area, not a separate document.

In note previews or note list summaries, highlights may appear above the body excerpt when space allows. They should not replace the title or the body excerpt.

## Main Body Interaction

Highlights do not require all note content to become list items in v1.

The note body remains a rich free-text field. Users can write paragraphs, fragments, lists, pasted text, journal entries, meeting notes, or messy capture without converting the note into blocks.

Highlights can be created from:

- selected text in the note body
- a manual add action in the highlights section
- note-intelligence suggestions

When a user highlights selected body text in v1, the selected text should remain in the note body by default. The highlight is a surfaced copy/reference-style item, not a destructive move. A future version may add explicit "move to highlight" behavior, but v1 should avoid surprising content removal.

Editing a highlight changes the highlight only. It does not automatically rewrite matching text in the body.

Removing a highlight removes it from the highlights section only. It does not delete note body text.

## Edit Behavior

Each highlight has editable text.

Primary edit behavior:

- Tap a highlight to focus/edit it inline.
- Save edits when focus leaves the field or the user confirms through the keyboard.
- Empty highlights should be removed after confirmation or when the user explicitly deletes/removes them.

Editing should support plain text in v1. Rich text inside highlights is out of scope unless it already falls out naturally from shared editor components without extra complexity.

Highlights should support enough text for a concise thought, but they are not meant to become full note bodies. Long highlights can wrap and expand while editing.

## Expand and Collapse Behavior

The highlights section has two display states:

- Collapsed: shows a compact preview of highlights.
- Expanded: shows all highlights with editing/reordering affordances.

Default state:

- If a note has one to three highlights, show them expanded by default.
- If a note has more than three highlights, show the section collapsed by default with the highest-priority items visible.
- Remember the user's expanded/collapsed preference per note during the current session if practical.

Collapsed state:

- Shows the first few highlights in priority order.
- Shows a count when additional highlights are hidden.
- Does not block access to the main note body.

Expanded state:

- Shows all highlights.
- Enables editing, reorder, and unpin controls.
- Should avoid covering active body text. Expansion should push the body down instead of overlaying it.

## Reorder Behavior

Highlights have a user-controlled order.

Reordering behavior:

- In expanded state, users can drag highlights to reorder them.
- Reordering updates the highlight order for that note.
- Order is preserved across app launches.

The first highlights are treated as highest priority for collapsed previews and note list/preview surfaces.

If drag-to-reorder is not available on a platform in the first implementation pass, a simpler move-up/move-down fallback is acceptable, but the data model should still preserve explicit ordering.

## Unpin Behavior

Each highlight can be removed from the highlights section.

Remove behavior:

- Remove removes the text from the highlights section.
- Remove does not delete or alter text in the main note body.
- If the highlight was manually created and exists only as highlight text, removing it removes that highlight record.
- If the highlight was created from selected body text, the original body text remains untouched.

Destructive actions should be clear. A future delete action may remove the highlight entirely, but v1 can use remove as the primary removal action.

## Empty State

Notes without highlights should not show a large empty highlights section.

The add/highlight entry point should remain available through contextual actions, note body selection actions, or a compact add control when appropriate.

## Non-Goal

Highlights do not require all thoughts to become list items.

Highlights are not a replacement for the note body. They are a selective layer for important thoughts. The user should be able to write a full note as free text, highlight zero or more important pieces, and continue writing without managing a block/list structure.

This keeps MyRAM aligned with fast capture while still introducing the RAM concept in a focused, reversible way.

## Implementation Notes

The follow-up implementation ticket should introduce:

- persistent highlight records or fields linked to a note
- stable ordering
- collapsed/expanded section state
- add/edit/remove interactions
- reorder behavior or a platform-appropriate fallback
- preview/list rendering hooks where appropriate

The implementation should avoid coupling highlight edits to automatic note body rewrites in v1.

## Terminology Note

The current SwiftData model and export manifest still use `PinnedThought`/`pinnedThoughts`. User-facing terminology should say "Highlight" or "Highlights"; storage and migration renames should be handled separately if they become necessary.
