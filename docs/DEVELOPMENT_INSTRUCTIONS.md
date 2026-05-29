# MyRAM Development Instructions

## Development Goal

Build MyRAM as a user-controlled external-memory notes app. The product should support fast capture, reliable retrieval, and low-pressure organization.

The current major product direction is the future **Defrag** feature.

## Non-Negotiable Product Rule

Do not build features that automatically decide user priority.

Avoid features or copy that imply the app knows what is important, urgent, or what must stay visible today.

Avoid language such as:

- "Important"
- "Urgent"
- "Must review today"
- "Top priority"
- "You need to do this"
- "This must stay visible"

Preferred language:

- "These notes may be related."
- "This looks like a quick fragment."
- "This image has text you may want to keep."
- "This note may contain a follow-up."
- "Keep this easier to find?"
- "Ignore"

The app may suggest structure, but all meaningful organization decisions should be user-approved.

## Defrag Feature Direction

Defrag should be a manually opened review mode that helps users organize scattered note content.

Defrag should look for candidate suggestions such as:

- Similar or duplicate notes
- Notes that may be about the same topic
- Very short notes that may be fragments
- Notes with attached images containing OCR text
- Loose OCR text that could be added to a note
- Possible action items inside notes
- Notes that could be bundled together
- Older notes that may be archive candidates
- Screenshots/images that may belong with existing notes

Defrag should not auto-delete, auto-archive, auto-pin, merge, rewrite, or reprioritize content without user approval.

## Suggested MVP Ticket

### Ticket: Add Defrag Review MVP

Goal:

Create a basic Defrag screen that displays candidate note organization suggestions and lets the user approve or ignore them.

## Suggested Implementation Steps

1. Add a Defrag entry point in app navigation.
2. Create a Defrag screen with suggestion cards.
3. Define a `DefragSuggestion` model.
4. Define supported suggestion types.
5. Add mock or placeholder suggestion generation first if the real data layer is not ready.
6. Add user actions.
7. Keep all actions non-destructive at first if persistence is not ready.
8. Use optional, non-authoritative wording throughout the UI.

Suggested model shape:

```kotlin
data class DefragSuggestion(
    val id: String,
    val type: DefragSuggestionType,
    val title: String,
    val description: String,
    val noteIds: List<String>,
    val suggestedAction: DefragAction?
)

enum class DefragSuggestionType {
    PossibleDuplicate,
    RelatedNotes,
    ShortFragment,
    OcrTextAvailable,
    PossibleActionItem
}

enum class DefragAction {
    Merge,
    Bundle,
    Pin,
    Archive,
    Ignore
}
```

Suggested action semantics:

- `Merge`: combine selected notes after confirmation
- `Bundle`: group related notes without destroying originals
- `Pin`: user manually keeps a note easier to access
- `Archive`: move a note out of the main view without deleting it
- `Ignore`: dismiss the suggestion

## Preferred Naming

Use:

- RAM Dump
- Defrag
- Recall
- Pinned RAM
- Keep in View
- Note Bundles
- Archive

Avoid "Active Memory" if it implies the app is deciding what should be active or important.

## UX Rules

- Suggestions are optional.
- The user must remain in control.
- Make ignoring suggestions easy.
- Make destructive actions reversible or confirmed.
- Do not shame messy notes.
- Do not frame disorganization as failure.
- Do not auto-delete anything.
- Do not auto-archive anything.
- Do not auto-pin anything.
- Do not assign priority automatically.

## Near-Term Implementation Scope

For the first pass, do not build a complex intelligent system.

Start with simple rule-based or mock suggestions:

- Notes with similar titles
- Notes created close together in time
- Notes containing repeated words or phrases
- Very short notes
- Notes with OCR text available
- Notes containing simple action-like language
