# Agent Instructions

## Git and PR Workflow

- Never commit or push directly to `main`.
- Always create a feature branch from current `main` for ticket work.
- Branch names should follow the existing ticket format used by the repo, e.g. `MYR-2-Improve-editor-usability`.
- Push feature branches only.
- Open a PR for all changes.
- Do not force push unless the user explicitly approves it in the current chat.
- If a push is rejected, fetch and reconcile with the remote first, then use a normal push when possible.
- Do not amend commits after a PR is open unless the user explicitly asks for history cleanup.
- Before any push, verify and state the current branch and destination ref.
- If there is any uncertainty about whether a command will rewrite history or affect `main`, stop and ask first.

## Commit Messages

- Follow the existing ticket-prefix style in the repo.
- Commit subjects must be specific to the implementation and should not simply duplicate the PR title.
- Use an extended commit body whenever the change has meaningful context, user-facing behavior, risk, or verification.
- Prefer small, coherent commits.
- Follow-up bug fixes should be separate commits, not amendments, unless the user explicitly requests cleanup.

Preferred commit format:

```text
TICKET-N Specific implementation summary

### Changes
- Concrete change 1
- Concrete change 2

### Why
Short explanation of the user problem or technical reason.

### Verification
- Command, build, or test that passed
```

## Pull Requests

- PR descriptions belong in the PR body, not in comments.
- Use PR comments only for discussion, review replies, temporary status updates, or follow-up notes.
- PR titles should be ticket-level summaries and may be broader than individual commit subjects.
- PR bodies should summarize the full ticket/change set across all relevant commits.

Preferred PR body format:

```markdown
### Changes
- Ticket-level change 1
- Ticket-level change 2

### Tech
- Implementation detail 1
- Implementation detail 2

### Verification
- Command, build, or test that passed
```

## Default Behavior

- Be conservative with Git history.
- Preserve useful history over making it artificially tidy.
- Never rewrite shared history without explicit approval.
- When working across multiple repos or platforms for one ticket, keep ticket/PR naming aligned but make commit subjects specific to each platform's implementation.
