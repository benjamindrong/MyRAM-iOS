# Note Intelligence Spec v1

This directory defines the shared, versioned rule spec artifacts for note intelligence.

## Purpose

The spec is the source of truth for cross-platform suggestion behavior so iOS and Android can produce the same labels from equivalent canonical inputs.

## Files

- `note_intelligence_rules.v1.json`: Rule definitions and output labels.
- `contracts/note_intelligence_input.schema.v1.json`: Canonical input contract.
- `contracts/note_intelligence_output.schema.v1.json`: Canonical output contract.
- `fixtures/v1/*.json`: Deterministic input/output examples for parity tests.

## v1 Labels

- `possible_task`
- `possible_event`
- `reminder_candidate`
- `idea`
- `journal_entry`
- `high_revisit_value`
- `merge_candidate`

## Rules Philosophy

- Suggestions only; no automatic actions.
- Optional and user-controlled.
- On-device processing.
- Rule conditions should stay deterministic and auditable.
