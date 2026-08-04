# MYR-175 Slice 1 Exact-Head Verification Rerun

- Candidate head: `3dbfcff9053fc38b980738cad9bcea603e7c99c1`
- Baseline: `e51ccca9ff6a77c8648e365b6569313c55c1e9d4`
- Signing: disabled for hosted-runner builds and tests

## Outcomes
```text
environment=failure
package_focused=success
package_complete=success
ios_tests=failure
mac_tests=failure
ios_build=failure
mac_build=failure
audits=failure
```

## Observed summaries
```text
** BUILD FAILED **
** TEST FAILED **
** BUILD FAILED **
** TEST FAILED **
Test Suite 'SyncActorSequenceReservationTests' passed at 2026-08-04 14:55:28.637.
	 Executed 6 tests, with 0 failures (0 unexpected) in 0.001 (0.001) seconds
Test Suite 'SyncSequenceIdentityTests' passed at 2026-08-04 14:55:28.641.
	 Executed 14 tests, with 0 failures (0 unexpected) in 0.003 (0.004) seconds
Test Suite 'SyncTextLegacyBootstrapTests' passed at 2026-08-04 14:55:28.781.
	 Executed 11 tests, with 0 failures (0 unexpected) in 0.140 (0.140) seconds
Test Suite 'SyncTextOperationPayloadTests' passed at 2026-08-04 14:55:28.916.
	 Executed 26 tests, with 0 failures (0 unexpected) in 0.134 (0.135) seconds
Test Suite 'SyncTextSequenceStateTests' passed at 2026-08-04 14:55:29.357.
	 Executed 19 tests, with 0 failures (0 unexpected) in 0.440 (0.441) seconds
Test Suite 'AnchoredSequenceCorePackageTests.xctest' passed at 2026-08-04 14:55:29.357.
	 Executed 76 tests, with 0 failures (0 unexpected) in 0.719 (0.721) seconds
Test Suite 'All tests' passed at 2026-08-04 14:55:29.357.
	 Executed 76 tests, with 0 failures (0 unexpected) in 0.719 (0.722) seconds
Test Suite 'SyncTextSequenceStateTests' passed at 2026-08-04 14:55:26.653.
	 Executed 19 tests, with 0 failures (0 unexpected) in 0.402 (0.403) seconds
Test Suite 'AnchoredSequenceCorePackageTests.xctest' passed at 2026-08-04 14:55:26.653.
	 Executed 19 tests, with 0 failures (0 unexpected) in 0.402 (0.403) seconds
Test Suite 'Selected tests' passed at 2026-08-04 14:55:26.653.
	 Executed 19 tests, with 0 failures (0 unexpected) in 0.402 (0.405) seconds
```
