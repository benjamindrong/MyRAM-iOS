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

## iOS Runtime Notes

- Suggestion generation runs fully on-device via `NaturalLanguage` (`NLTagger`, `NLLanguageRecognizer`) and `NSDataDetector`.
- Rule evaluation is local and deterministic against `note_intelligence_rules.v1.json` (with an embedded fallback copy for offline resilience).
- The iOS suggestion pipeline does not call network APIs or rely on remote services.

## Rule/Spec Version Bump Process

1. Copy current artifacts and increment version suffixes:
- `note_intelligence_rules.v{N+1}.json`
- `contracts/note_intelligence_input.schema.v{N+1}.json`
- `contracts/note_intelligence_output.schema.v{N+1}.json`

2. Update `spec_version`, labels/rules, and any condition semantics in the new rule artifact.

3. Add/update fixture corpus under `fixtures/v{N+1}/` with expected labels.

4. Keep prior versions immutable for backward compatibility and release traceability.

5. Update cross-platform evaluators to consume the new version explicitly, then rerun fixture parity tests before release.
