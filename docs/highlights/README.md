# Pinned Text Interaction Spec

## Goal

Pinned Text gives a note a lightweight reference layer: a small set of selected text snippets that stay easy to see and act on without turning fast note capture into a structured list workflow.

The main note body remains the default place for free-text capture. Pinned Text is an optional layer for text the user wants to keep visible, revisit, or organize above the normal flow of the note.

## Interaction Principles

- Capture stays fast. Users can keep typing free-form text without choosing a structure first.
- Pinning text is additive. A pinned text item surfaces selected text without requiring the user to rewrite the note.
- Structure is local. Pinned Text organizes the current note, not the entire notebook.
- The note body remains authoritative. Pinned Text should never hide, delete, or silently mutate note body content unless the user explicitly chooses that action.

## Placement

Pinned Text appears inside the note editor above the main note body and below the note title/top controls.

When a note has pinned text, the editor layout is:

1. Note title and top actions.
2. Pinned section.
3. Main note body.
4. Keyboard/editor controls.

The pinned section should stay visually distinct from the body but not dominate the page. It should read as a compact reference area, not a separate document.

In note previews or note list summaries, pinned text may appear above the body excerpt when space allows. It should not replace the title or the body excerpt.

## Main Body Interaction

Pinned Text does not require all note content to become list items in v1.

The note body remains a rich free-text field. Users can write paragraphs, fragments, lists, pasted text, journal entries, meeting notes, or messy capture without converting the note into blocks.

Pinned Text can be created from:

- selected text in the note body
- a manual add action in the pinned section
- note-intelligence suggestions

When a user pins selected body text in v1, the selected text should remain in the note body by default. The pinned text item is a surfaced copy/reference-style item, not a destructive move. A future version may add explicit "move to pinned text" behavior, but v1 should avoid surprising content removal.

Editing a pinned text item changes the pinned text only. It does not automatically rewrite matching text in the body.

Unpinning text removes it from the pinned section only. It does not delete note body text.

## Edit Behavior

Each pinned text item has editable text.

Primary edit behavior:

- Tap a pinned text item to focus/edit it inline.
- Save edits when focus leaves the field or the user confirms through the keyboard.
- Empty pinned text items should be removed after confirmation or when the user explicitly deletes/removes them.

Editing should support plain text in v1. Rich text inside pinned text is out of scope unless it already falls out naturally from shared editor components without extra complexity.

Pinned text should support enough text for a concise excerpt, but it is not meant to become a full note body. Long pinned text can wrap and expand while editing.

## Expand and Collapse Behavior

The pinned section has two display states:

- Collapsed: shows a compact preview of pinned text.
- Expanded: shows all pinned text with editing/reordering affordances.

Default state:

- If a note has one to three pinned text items, show them expanded by default.
- If a note has more than three pinned text items, show the section collapsed by default with the first items visible.
- Remember the user's expanded/collapsed preference per note during the current session if practical.

Collapsed state:

- Shows the first few pinned text items in order.
- Shows a count when additional pinned text is hidden.
- Does not block access to the main note body.

Expanded state:

- Shows all pinned text.
- Enables editing, reorder, and unpin controls.
- Should avoid covering active body text. Expansion should push the body down instead of overlaying it.

## Reorder Behavior

Pinned text has a user-controlled order.

Reordering behavior:

- In expanded state, users can drag pinned text items to reorder them.
- Reordering updates the pinned text order for that note.
- Order is preserved across app launches.

The first pinned text items appear first in collapsed previews and note list/preview surfaces.

If drag-to-reorder is not available on a platform in the first implementation pass, a simpler move-up/move-down fallback is acceptable, but the data model should still preserve explicit ordering.

## Unpin Behavior

Each pinned text item can be removed from the pinned section.

Remove behavior:

- Unpin removes the text from the pinned section.
- Remove does not delete or alter text in the main note body.
- If the pinned text item was manually created and exists only in the pinned section, removing it removes that pinned text record.
- If the pinned text item was created from selected body text, the original body text remains untouched.

Destructive actions should be clear. A future delete action may remove the pinned text item entirely, but v1 can use unpin as the primary removal action.

## Empty State

Notes without pinned text should not show a large empty pinned section.

The pin entry point should remain available through contextual actions, note body selection actions, or a compact add control when appropriate.

## Non-Goal

Pinned Text does not require all note content to become list items.

Pinned Text is not a replacement for the note body. The user should be able to write a full note as free text, pin zero or more excerpts, and continue writing without managing a block/list structure.

This keeps MyRAM aligned with fast capture while keeping the pinned section focused and reversible.

## Implementation Notes

The follow-up implementation ticket should introduce:

- persistent pinned text records or fields linked to a note
- stable ordering
- collapsed/expanded section state
- add/edit/remove interactions
- reorder behavior or a platform-appropriate fallback
- preview/list rendering hooks where appropriate

The implementation should avoid coupling pinned text edits to automatic note body rewrites in v1.

## Terminology Note

The current SwiftData model and export manifest still use `PinnedThought`/`pinnedThoughts`. User-facing terminology should say "Pinned" or "Pinned Text"; storage and migration renames should be handled separately if they become necessary.
