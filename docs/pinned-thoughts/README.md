# Pinned Thoughts Interaction Spec

## Goal

Pinned thoughts give a note a lightweight RAM layer: a small set of high-value thoughts that stay easy to see and act on without turning fast note capture into a structured list workflow.

The main note body remains the default place for free-text capture. Pinned thoughts are an optional layer for things the user wants to keep visible, revisit, or organize above the normal flow of text.

## Product Principles

- Capture stays fast. Users can keep typing free-form text without choosing a structure first.
- Pinning is additive. A pinned thought highlights or preserves an important idea; it does not require rewriting the note.
- Structure is local. Pinned thoughts organize the current note, not the entire notebook.
- The note body remains authoritative. Pinned thoughts should never hide, delete, or silently mutate note body content unless the user explicitly chooses that action.

## Placement

Pinned thoughts appear inside the note editor above the main note body and below the note title/top controls.

When a note has pinned thoughts, the editor layout is:

1. Note title and top actions.
2. Pinned thoughts section.
3. Main note body.
4. Keyboard/editor controls.

The pinned thoughts section should stay visually distinct from the body but not dominate the page. It should read as a compact working memory area, not a separate document.

In note previews or note list summaries, pinned thoughts may appear above the body excerpt when space allows. They should not replace the title or the body excerpt.

## Main Body Interaction

Pinned thoughts do not require all note content to become list items in v1.

The note body remains a rich free-text field. Users can write paragraphs, fragments, lists, pasted text, journal entries, meeting notes, or messy capture without converting the note into blocks.

Pinned thoughts can be created from:

- selected text in the note body
- a manual add action in the pinned thoughts section
- future note-intelligence suggestions

When a user pins selected body text in v1, the selected text should remain in the note body by default. The pinned thought is a surfaced copy/reference-style item, not a destructive move. A future version may add explicit "move to pinned thought" behavior, but v1 should avoid surprising content removal.

Editing a pinned thought changes the pinned thought only. It does not automatically rewrite matching text in the body.

Unpinning a thought removes it from the pinned thoughts section only. It does not delete note body text.

## Edit Behavior

Each pinned thought has editable text.

Primary edit behavior:

- Tap a pinned thought to focus/edit it inline.
- Save edits when focus leaves the field or the user confirms through the keyboard.
- Empty pinned thoughts should be removed after confirmation or when the user explicitly deletes/unpins them.

Editing should support plain text in v1. Rich text inside pinned thoughts is out of scope unless it already falls out naturally from shared editor components without extra complexity.

Pinned thoughts should support enough text for a concise thought, but they are not meant to become full note bodies. Long pinned thoughts can wrap and expand while editing.

## Expand and Collapse Behavior

The pinned thoughts section has two display states:

- Collapsed: shows a compact preview of pinned thoughts.
- Expanded: shows all pinned thoughts with editing/reordering affordances.

Default state:

- If a note has one to three pinned thoughts, show them expanded by default.
- If a note has more than three pinned thoughts, show the section collapsed by default with the highest-priority items visible.
- Remember the user's expanded/collapsed preference per note during the current session if practical.

Collapsed state:

- Shows the first few pinned thoughts in priority order.
- Shows a count when additional pinned thoughts are hidden.
- Does not block access to the main note body.

Expanded state:

- Shows all pinned thoughts.
- Enables editing, reorder, and unpin controls.
- Should avoid covering active body text. Expansion should push the body down instead of overlaying it.

## Reorder Behavior

Pinned thoughts have a user-controlled order.

Reordering behavior:

- In expanded state, users can drag pinned thoughts to reorder them.
- Reordering updates the pinned thought order for that note.
- Order is preserved across app launches.

The first pinned thoughts are treated as highest priority for collapsed previews and note list/preview surfaces.

If drag-to-reorder is not available on a platform in the first implementation pass, a simpler move-up/move-down fallback is acceptable, but the data model should still preserve explicit ordering.

## Unpin Behavior

Each pinned thought can be unpinned.

Unpin behavior:

- Unpin removes the thought from the pinned thoughts section.
- Unpin does not delete or alter text in the main note body.
- If the pinned thought was manually created and exists only as pinned thought text, unpinning removes that pinned thought record.
- If the pinned thought was created from selected body text, the original body text remains untouched.

Destructive actions should be clear. A future delete action may remove the pinned thought entirely, but v1 can use unpin as the primary removal action.

## Empty State

Notes without pinned thoughts should not show a large empty pinned thoughts section.

The add/pin entry point should remain available through contextual actions, note body selection actions, or a compact add control when appropriate.

## V1 Explicit Non-Goal

V1 does not require all thoughts to become list items.

Pinned thoughts are not a replacement for the note body. They are a selective layer for important thoughts. The user should be able to write a full note as free text, pin zero or more important pieces, and continue writing without managing a block/list structure.

This keeps MyRAM aligned with fast capture while still introducing the RAM concept in a focused, reversible way.

## Implementation Notes for MYR-44

The follow-up implementation ticket should introduce:

- persistent pinned thought records or fields linked to a note
- stable ordering
- collapsed/expanded section state
- add/edit/unpin interactions
- reorder behavior or a platform-appropriate fallback
- preview/list rendering hooks where appropriate

The implementation should avoid coupling pinned thought edits to automatic note body rewrites in v1.
