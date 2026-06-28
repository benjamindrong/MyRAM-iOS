# MyRAM Development Instructions

## Development Goal

Build MyRAM as a user-controlled external-memory notes app. The product should support fast capture, reliable retrieval, and low-pressure organization.

## Desktop Build Direction

The first mac desktop build uses the existing iOS app target with Mac Catalyst enabled. This keeps the current UIKit-backed editor, sharing flow, SwiftData models, and SwiftUI screens on one implementation path while desktop-specific behavior is still being defined.

Do not exclude Intel architecture support from the desktop build unless a ticket explicitly narrows support. A 2019 Intel Mac should remain supported when it runs the required macOS version for the APIs used by the app.

If the desktop app later needs AppKit-native behavior that Catalyst cannot provide cleanly, add a dedicated macOS target behind a separate ticket and keep platform-specific code isolated.

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
