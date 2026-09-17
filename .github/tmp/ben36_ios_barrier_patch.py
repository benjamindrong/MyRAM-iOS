#!/usr/bin/env python3
from pathlib import Path
import sys

root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path.cwd()
source_path = root / "MyRAM/iOS/Sync/Batch/IPhoneSyncBatchAccumulator.swift"
source = source_path.read_text(encoding="utf-8")

old_final = '''        recorder.record(.phase, phase: "finalDrain", operationCount: operation, outcome: "started")
        let finalQueueDepth = await waitForIOSDrain(
            state: state,
            timeoutSeconds: MyRAMSyncBenchmarkEnduranceWorkload.finalDrainSeconds
        )
        let notes = state.vm.fetchSearchableNotes()
        let digests = benchmarkDigests(notes: notes, runID: launch.runID)
        let hasExpectedNotes = expectedTitlesObserved(digests, runID: launch.runID)
        let locallyComplete = failed == 0
            && finalQueueDepth == 0
            && state.syncController.hasConnectedPeers
            && ordinaryRoutingReady(state: state)
            && hasExpectedNotes
'''

new_final = '''        guard let finalizationNote = state.vm.refreshedNote(withID: noteIDs[0]) else {
            finishFailure(
                recorder: recorder,
                launch: launch,
                startedAt: startedAt,
                attempted: attempted,
                committed: committed,
                failed: failed,
                state: state,
                detail: "unable to load iOS finalization marker note"
            )
            return
        }
        let finalizationBody = MyRAMSyncBenchmarkEnduranceWorkload.bodyByAppendingCompletionMarker(
            finalizationNote.content,
            runID: launch.runID,
            platform: .iOS
        )
        if finalizationBody != finalizationNote.content {
            guard await state.vm.commitNoteEditForProduction(
                finalizationNote,
                title: finalizationNote.title,
                content: finalizationBody
            ) else {
                finishFailure(
                    recorder: recorder,
                    launch: launch,
                    startedAt: startedAt,
                    attempted: attempted,
                    committed: committed,
                    failed: failed,
                    state: state,
                    detail: "unable to commit iOS finalization marker"
                )
                return
            }
        }
        recorder.record(
            .phase,
            phase: "finalizationBarrier",
            operationCount: operation,
            outcome: "localMarkerCommitted"
        )
        recorder.record(.phase, phase: "finalDrain", operationCount: operation, outcome: "started")
        let finalQueueDepth = await waitForIOSFinalDrain(
            state: state,
            runID: launch.runID,
            timeoutSeconds: MyRAMSyncBenchmarkEnduranceWorkload.finalDrainSeconds
        )
        let notes = state.vm.fetchSearchableNotes()
        let digests = benchmarkDigests(notes: notes, runID: launch.runID)
        let hasExpectedNotes = expectedTitlesObserved(digests, runID: launch.runID)
        let completionBarrierSatisfied = MyRAMSyncBenchmarkEnduranceWorkload.completionBarrierSatisfied(
            noteBodiesByTitle: benchmarkNoteBodies(notes: notes, runID: launch.runID),
            runID: launch.runID
        )
        let locallyComplete = failed == 0
            && finalQueueDepth == 0
            && state.syncController.hasConnectedPeers
            && ordinaryRoutingReady(state: state)
            && hasExpectedNotes
            && completionBarrierSatisfied
'''

if source.count(old_final) != 1:
    raise SystemExit(f"expected exactly one active iOS final-drain block, found {source.count(old_final)}")
source = source.replace(old_final, new_final, 1)

drain_anchor = '''    private func waitForIOSDrain(
        state: NotesListState,
        timeoutSeconds: Int
    ) async -> Int {
'''
final_drain_helper = '''    private func waitForIOSFinalDrain(
        state: NotesListState,
        runID: String,
        timeoutSeconds: Int
    ) async -> Int {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        var stableZeroSamples = 0
        var lastDepth = state.syncController.unsentBatchQueueSnapshot().pendingBatches.count
        while Date() < deadline, !Task.isCancelled {
            lastDepth = state.syncController.unsentBatchQueueSnapshot().pendingBatches.count
            let notes = state.vm.fetchSearchableNotes()
            let barrierSatisfied = MyRAMSyncBenchmarkEnduranceWorkload.completionBarrierSatisfied(
                noteBodiesByTitle: benchmarkNoteBodies(notes: notes, runID: runID),
                runID: runID
            )
            if lastDepth == 0,
               state.syncController.hasConnectedPeers,
               ordinaryRoutingReady(state: state),
               barrierSatisfied {
                stableZeroSamples += 1
                if stableZeroSamples >= 5 { return 0 }
            } else {
                stableZeroSamples = 0
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return lastDepth
    }

'''
if source.count(drain_anchor) != 1:
    raise SystemExit(f"expected exactly one iOS drain helper anchor, found {source.count(drain_anchor)}")
source = source.replace(drain_anchor, final_drain_helper + drain_anchor, 1)

expected_anchor = '''    private func expectedTitlesObserved(
        _ digests: [MyRAMSyncBenchmarkEnduranceNoteDigest],
        runID: String
    ) -> Bool {
'''
bodies_helper = '''    private func benchmarkNoteBodies(
        notes: [Note],
        runID: String
    ) -> [String: String] {
        let prefix = "BEN36-\\(runID)-"
        var bodies: [String: String] = [:]
        for note in notes where note.deletedAt == nil && note.title.hasPrefix(prefix) {
            bodies[note.title] = note.content
        }
        return bodies
    }

'''
if source.count(expected_anchor) != 1:
    raise SystemExit(f"expected exactly one expected-title helper anchor, found {source.count(expected_anchor)}")
source = source.replace(expected_anchor, bodies_helper + expected_anchor, 1)
source_path.write_text(source, encoding="utf-8")

test_path = root / "MyRAMTests/IPhoneSyncBatchAccumulatorTests.swift"
tests = test_path.read_text(encoding="utf-8")
if tests.startswith("import XCTest\n"):
    tests = "import Foundation\n" + tests

test_anchor = '''    func testChangesAppendToPendingBatchAndPreserveOrdering() async {
'''
regression = '''    func testEnduranceRoutingGatedIOSDriverRequiresTwoSidedFinalizationBarrier() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repo.appendingPathComponent("MyRAM/iOS/Sync/Batch/IPhoneSyncBatchAccumulator.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("bodyByAppendingCompletionMarker("))
        XCTAssertTrue(source.contains("phase: \\\"finalizationBarrier\\\""))
        XCTAssertTrue(source.contains("waitForIOSFinalDrain("))
        XCTAssertTrue(source.contains("completionBarrierSatisfied("))
    }

'''
if "testEnduranceRoutingGatedIOSDriverRequiresTwoSidedFinalizationBarrier" in tests:
    raise SystemExit("regression test already exists")
if tests.count(test_anchor) != 1:
    raise SystemExit(f"expected exactly one test insertion anchor, found {tests.count(test_anchor)}")
tests = tests.replace(test_anchor, regression + test_anchor, 1)
test_path.write_text(tests, encoding="utf-8")
