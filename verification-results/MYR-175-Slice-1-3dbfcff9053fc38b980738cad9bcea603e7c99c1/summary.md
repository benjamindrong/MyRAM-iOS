# MYR-175 Slice 1 Exact-Head Verification

- Candidate head: `3dbfcff9053fc38b980738cad9bcea603e7c99c1`
- Baseline: `e51ccca9ff6a77c8648e365b6569313c55c1e9d4`
- Sibling dependency: `4ab9eb91e6390947a7a2e9a4c2ec74012b4bc0e2`

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

## Observed command summaries
```text
** BUILD FAILED **
** BUILD FAILED **
** TEST FAILED **
Test Suite 'SyncActorSequenceReservationTests' passed at 2026-08-04 14:49:28.177.
	 Executed 6 tests, with 0 failures (0 unexpected) in 0.002 (0.002) seconds
Test Suite 'SyncSequenceIdentityTests' passed at 2026-08-04 14:49:28.182.
	 Executed 14 tests, with 0 failures (0 unexpected) in 0.005 (0.005) seconds
Test Suite 'SyncTextLegacyBootstrapTests' passed at 2026-08-04 14:49:28.387.
	 Executed 11 tests, with 0 failures (0 unexpected) in 0.204 (0.205) seconds
Test Suite 'SyncTextOperationPayloadTests' passed at 2026-08-04 14:49:28.548.
	 Executed 26 tests, with 0 failures (0 unexpected) in 0.159 (0.161) seconds
Test Suite 'SyncTextSequenceStateTests' passed at 2026-08-04 14:49:29.027.
	 Executed 19 tests, with 0 failures (0 unexpected) in 0.479 (0.479) seconds
Test Suite 'AnchoredSequenceCorePackageTests.xctest' passed at 2026-08-04 14:49:29.027.
	 Executed 76 tests, with 0 failures (0 unexpected) in 0.848 (0.852) seconds
Test Suite 'All tests' passed at 2026-08-04 14:49:29.027.
	 Executed 76 tests, with 0 failures (0 unexpected) in 0.848 (0.854) seconds
Test Suite 'SyncTextSequenceStateTests' passed at 2026-08-04 14:49:25.871.
	 Executed 19 tests, with 0 failures (0 unexpected) in 0.361 (0.361) seconds
Test Suite 'AnchoredSequenceCorePackageTests.xctest' passed at 2026-08-04 14:49:25.871.
	 Executed 19 tests, with 0 failures (0 unexpected) in 0.361 (0.362) seconds
Test Suite 'Selected tests' passed at 2026-08-04 14:49:25.871.
	 Executed 19 tests, with 0 failures (0 unexpected) in 0.361 (0.363) seconds
```
