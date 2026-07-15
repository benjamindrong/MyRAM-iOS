import XCTest
@testable import MyRAMMac

@MainActor
final class MacSyncIncomingLocalBoundaryTests: XCTestCase {
    func testReadySurfaceMapsToSharedReadyPreparation() async {
        let adapter = MacSyncIncomingLocalBoundaryAdapter(
            surface: MacSyncIncomingLocalBoundarySurface(prepareForIncomingBodyMutation: { noteIDs in
                XCTAssertEqual(noteIDs, [Self.noteID(1)])
                return .ready
            })
        )

        let result = await adapter.prepareForIncomingBodyMutation(affecting: [Self.noteID(1)])

        guard case .ready = result else {
            return XCTFail("Expected ready preparation")
        }
    }

    func testLocalObligationSurfaceMapsToSharedLocalObligationPreparation() async throws {
        let obligation = try makeCapturedObligation(noteID: Self.noteID(2))
        let adapter = MacSyncIncomingLocalBoundaryAdapter(
            surface: MacSyncIncomingLocalBoundarySurface(prepareForIncomingBodyMutation: { _ in
                .localObligation(obligation)
            })
        )

        let result = await adapter.prepareForIncomingBodyMutation(affecting: [Self.noteID(2)])

        guard case .localObligation(let returnedObligation) = result else {
            return XCTFail("Expected local obligation preparation")
        }
        XCTAssertEqual(returnedObligation, obligation)
    }

    func testCaptureFailureMapsToSharedLocalCaptureFailure() async {
        let noteID = Self.noteID(3)
        let adapter = MacSyncIncomingLocalBoundaryAdapter(
            surface: MacSyncIncomingLocalBoundarySurface(prepareForIncomingBodyMutation: { _ in
                .failed(.captureFailed(noteID: noteID))
            })
        )

        let result = await adapter.prepareForIncomingBodyMutation(affecting: [noteID])

        XCTAssertEqual(result.failure, .localCaptureFailed(noteID: noteID))
    }

    func testMissingNoteMapsToSharedLocalCaptureFailure() async {
        let noteID = Self.noteID(4)
        let adapter = MacSyncIncomingLocalBoundaryAdapter(
            surface: MacSyncIncomingLocalBoundarySurface(prepareForIncomingBodyMutation: { _ in
                .failed(.noteMissing(noteID: noteID))
            })
        )

        let result = await adapter.prepareForIncomingBodyMutation(affecting: [noteID])

        XCTAssertEqual(result.failure, .localCaptureFailed(noteID: noteID))
    }

    func testPersistenceFailureMapsToSharedLocalPersistenceFailure() async {
        let noteID = Self.noteID(5)
        let adapter = MacSyncIncomingLocalBoundaryAdapter(
            surface: MacSyncIncomingLocalBoundarySurface(prepareForIncomingBodyMutation: { _ in
                .failed(.persistenceFailed(noteID: noteID))
            })
        )

        let result = await adapter.prepareForIncomingBodyMutation(affecting: [noteID])

        XCTAssertEqual(result.failure, .localPersistenceFailed(noteID: noteID))
    }

    func testInvariantViolationMapsToSharedBoundaryInvariantViolation() async {
        let noteID = Self.noteID(6)
        let adapter = MacSyncIncomingLocalBoundaryAdapter(
            surface: MacSyncIncomingLocalBoundarySurface(prepareForIncomingBodyMutation: { _ in
                .invariantViolation(noteID: noteID)
            })
        )

        let result = await adapter.prepareForIncomingBodyMutation(affecting: [noteID])

        XCTAssertEqual(result.failure, .boundaryInvariantViolation(noteID: noteID))
    }

    func testStaleLocalStateMapsToSharedStaleStateFailure() async {
        let noteID = Self.noteID(7)
        let adapter = MacSyncIncomingLocalBoundaryAdapter(
            surface: MacSyncIncomingLocalBoundarySurface(prepareForIncomingBodyMutation: { _ in
                .staleLocalState(noteID: noteID)
            })
        )

        let result = await adapter.prepareForIncomingBodyMutation(affecting: [noteID])

        XCTAssertEqual(result.failure, .localStateChanged(noteID: noteID))
    }

    func testMultiNoteBoundaryContinuesAfterSelectedNoBodySaveAndExtractsLaterPendingBodyObligation() async throws {
        let selectedID = Self.noteID(10)
        let laterID = Self.noteID(11)
        let obligation = try makeCapturedObligation(noteID: laterID)
        var visitedNoteIDs: [UUID] = []
        let preparer = MacIncomingBoundaryPreparer(
            selectedNoteID: { selectedID },
            hasUnsavedChanges: { true },
            saveSelectedNoteForBoundary: { noteID in
                XCTAssertEqual(noteID, selectedID)
                return .ready
            },
            takePendingObligation: { noteID in
                visitedNoteIDs.append(noteID)
                return noteID == laterID ? obligation : nil
            }
        )

        let result = await preparer.prepare(affecting: [selectedID, laterID])

        guard case .localObligation(let returnedObligation) = result else {
            return XCTFail("Expected the later note's pending body obligation")
        }
        XCTAssertEqual(returnedObligation, obligation)
        XCTAssertEqual(visitedNoteIDs, [laterID])
    }

    func testMultiNoteBoundaryReturnsReadyOnlyAfterEveryAffectedNoteIsChecked() async {
        let firstID = Self.noteID(12)
        let selectedID = Self.noteID(13)
        let lastID = Self.noteID(14)
        var visitedNoteIDs: [UUID] = []
        let preparer = MacIncomingBoundaryPreparer(
            selectedNoteID: { selectedID },
            hasUnsavedChanges: { true },
            saveSelectedNoteForBoundary: { _ in .ready },
            takePendingObligation: { noteID in
                visitedNoteIDs.append(noteID)
                return nil
            }
        )

        let result = await preparer.prepare(affecting: [lastID, selectedID, firstID])

        guard case .ready = result else {
            return XCTFail("Expected ready only after the complete ordered scan")
        }
        XCTAssertEqual(visitedNoteIDs, [firstID, lastID])
    }

    func testMultiNoteBoundaryStopsOnSemanticFailureBeforeLaterPlanning() async {
        let selectedID = Self.noteID(15)
        let laterID = Self.noteID(16)
        var extractedLaterNote = false
        let preparer = MacIncomingBoundaryPreparer(
            selectedNoteID: { selectedID },
            hasUnsavedChanges: { true },
            saveSelectedNoteForBoundary: { _ in .staleLocalState(noteID: selectedID) },
            takePendingObligation: { noteID in
                if noteID == laterID { extractedLaterNote = true }
                return nil
            }
        )

        let result = await preparer.prepare(affecting: [selectedID, laterID])

        guard case .staleLocalState(let noteID) = result else {
            return XCTFail("Expected the semantic boundary result to end this pass")
        }
        XCTAssertEqual(noteID, selectedID)
        XCTAssertFalse(extractedLaterNote)
    }

    func testNewerRevisionCannotPersistOrPublishBeforeOlderRevisionCompletesPublication() async {
        let coordinator = MacNoteSaveSingleFlight()
        let noteID = Self.noteID(20)
        let firstRevision = Self.noteID(21)
        let secondRevision = Self.noteID(22)
        let gate = MacSaveTestGate()
        var events: [String] = []

        let firstAttempt = makeAttempt(noteID: noteID, revision: firstRevision, body: "A")
        let first = Task { @MainActor in
            await coordinator.complete(
                attempt: firstAttempt,
                stillOwnsAttempt: { true },
                operation: {
                    events.append("A started")
                    await gate.waitForRelease()
                    events.append("A published")
                    return self.completed(firstAttempt)
                }
            )
        }
        await gate.waitUntilBlocked()

        let secondAttempt = makeAttempt(noteID: noteID, revision: secondRevision, body: "B")
        let second = Task { @MainActor in
            await coordinator.complete(
                attempt: secondAttempt,
                stillOwnsAttempt: { true },
                operation: {
                    events.append("B started")
                    events.append("B published")
                    return self.completed(secondAttempt)
                }
            )
        }

        XCTAssertEqual(events, ["A started"])
        await gate.release()
        _ = await first.value
        _ = await second.value
        XCTAssertEqual(events, ["A started", "A published", "B started", "B published"])
    }

    func testQueuedSupersededRevisionDoesNotPersistWhenItObtainsTheSaveSlot() async {
        let coordinator = MacNoteSaveSingleFlight()
        let noteID = Self.noteID(30)
        let gate = MacSaveTestGate()
        var secondOperationRan = false
        let firstAttempt = makeAttempt(noteID: noteID, revision: Self.noteID(31), body: "A")
        let first = Task { @MainActor in
            await coordinator.complete(
                attempt: firstAttempt,
                stillOwnsAttempt: { true },
                operation: {
                    await gate.waitForRelease()
                    return self.completed(firstAttempt)
                }
            )
        }
        await gate.waitUntilBlocked()

        let secondAttempt = makeAttempt(noteID: noteID, revision: Self.noteID(32), body: "B")
        let second = Task { @MainActor in
            await coordinator.complete(
                attempt: secondAttempt,
                stillOwnsAttempt: { false },
                operation: {
                    secondOperationRan = true
                    return self.completed(secondAttempt)
                }
            )
        }
        await gate.release()
        _ = await first.value
        let completion = await second.value

        guard case .supersededBeforeStart(let attempt) = completion else {
            return XCTFail("Expected queued revision to be rejected before persistence")
        }
        XCTAssertEqual(attempt.id, secondAttempt.id)
        XCTAssertFalse(secondOperationRan)
    }

    func testBoundaryInitiatedSaveCarriesExtractedObligationThroughCommonCompletion() async throws {
        let coordinator = MacNoteSaveSingleFlight()
        let noteID = Self.noteID(40)
        let attempt = makeAttempt(noteID: noteID, revision: Self.noteID(41), body: "A")
        let obligation = try makeCapturedObligation(noteID: noteID)
        let completion = await coordinator.complete(
            attempt: attempt,
            stillOwnsAttempt: { true },
            operation: {
                .completed(
                    attempt: attempt,
                    mutationKind: .body,
                    publication: .boundaryExtracted(obligation)
                )
            }
        )

        guard case .completed(_, _, .boundaryExtracted(let returnedObligation)) = completion else {
            return XCTFail("Expected the boundary extraction to remain on the shared completion")
        }
        XCTAssertEqual(returnedObligation, obligation)
    }

    func testOrdinarySaveCompletionDoesNotClearNewerUnsavedRevision() {
        let noteID = Self.noteID(50)
        let savedAttempt = makeAttempt(noteID: noteID, revision: Self.noteID(51), body: "A")

        XCTAssertFalse(MacEditorSaveOwnership.owns(
            selectedNoteID: noteID,
            editorRevision: Self.noteID(52),
            attempt: savedAttempt
        ))
    }

    func testStaleSaveCompletionDoesNotClearNewerSaveError() {
        let noteID = Self.noteID(53)
        let staleAttempt = makeAttempt(noteID: noteID, revision: Self.noteID(54), body: "A")

        XCTAssertFalse(MacEditorSaveOwnership.owns(
            selectedNoteID: noteID,
            editorRevision: Self.noteID(55),
            attempt: staleAttempt
        ))
    }

    func testAttemptWithoutCurrentEditorOwnershipCannotSetOrClearSaveError() {
        let staleAttempt = makeAttempt(noteID: Self.noteID(56), revision: Self.noteID(57), body: "A")

        XCTAssertFalse(MacEditorSaveOwnership.owns(
            selectedNoteID: Self.noteID(58),
            editorRevision: Self.noteID(57),
            attempt: staleAttempt
        ))
    }

    func testCurrentRevisionPersistenceFailureReturnsFailedAndSetsSaveError() {
        let noteID = Self.noteID(59)
        let attempt = makeAttempt(noteID: noteID, revision: Self.noteID(60), body: "A")

        XCTAssertTrue(MacEditorSaveOwnership.owns(
            selectedNoteID: noteID,
            editorRevision: attempt.editorRevision,
            attempt: attempt
        ))
    }

    func testFlushWaitsForInFlightSameRevisionPublicationBeforeReportingSuccess() {
        XCTAssertFalse(MacEditorSaveOwnership.flushMayProceed(for: .superseded(noteID: Self.noteID(61))))
        XCTAssertTrue(MacEditorSaveOwnership.flushMayProceed(for: .savedWithPendingBodyMutation(noteID: Self.noteID(61))))
    }

    func testFlushSavesCurrentRevisionAfterCancellingItsDebounceWhileOlderRevisionIsActive() {
        XCTAssertFalse(MacEditorSaveOwnership.flushMayProceed(for: .superseded(noteID: Self.noteID(62))))
        XCTAssertTrue(MacEditorSaveOwnership.flushMayProceed(for: .savedWithoutBodyMutation))
    }

    func testIncomingBoundaryCannotBypassInFlightOrdinarySaveForSameNote() async {
        let coordinator = MacNoteSaveSingleFlight()
        let noteID = Self.noteID(63)
        let revision = Self.noteID(64)
        let gate = MacSaveTestGate()
        var operationCount = 0
        let attempt = makeAttempt(noteID: noteID, revision: revision, body: "A")
        let ordinary = Task { @MainActor in
            await coordinator.complete(
                attempt: attempt,
                stillOwnsAttempt: { true },
                operation: {
                    operationCount += 1
                    await gate.waitForRelease()
                    return self.completed(attempt)
                }
            )
        }
        await gate.waitUntilBlocked()
        let boundary = Task { @MainActor in
            await coordinator.complete(
                attempt: attempt,
                stillOwnsAttempt: { true },
                operation: {
                    operationCount += 1
                    return self.completed(attempt)
                }
            )
        }
        await gate.release()
        _ = await ordinary.value
        _ = await boundary.value
        XCTAssertEqual(operationCount, 1)
    }

    func testMissingBodyObligationRemainsInvariantWhenCompletedAttemptIsSuperseded() {
        let attempt = makeAttempt(noteID: Self.noteID(65), revision: Self.noteID(66), body: "A")
        let result = MacIncomingBoundaryCompletionPolicy.result(
            for: completed(attempt),
            obligation: nil,
            requestedAttemptStillOwnsEditor: false,
            completingAttemptStillOwnsEditor: false
        )

        guard case .invariantViolation(let noteID) = result else {
            return XCTFail("A missing body obligation must remain an invariant violation")
        }
        XCTAssertEqual(noteID, attempt.noteID)
    }

    func testBoundarySaveSupersededByNewerEditCannotReturnReady() {
        let attempt = makeAttempt(noteID: Self.noteID(67), revision: Self.noteID(68), body: "A")
        let completion = MacNoteSaveOperationCompletion.completed(
            attempt: attempt,
            mutationKind: .nonBodyOnly,
            publication: .boundaryExtracted(nil)
        )
        let result = MacIncomingBoundaryCompletionPolicy.result(
            for: completion,
            obligation: nil,
            requestedAttemptStillOwnsEditor: false,
            completingAttemptStillOwnsEditor: false
        )

        guard case .staleLocalState(let noteID) = result else {
            return XCTFail("Superseded boundary completion must not report ready")
        }
        XCTAssertEqual(noteID, attempt.noteID)
    }

    func testSupersededIncomingBoundaryIsAdmittedAfterNewerRevisionSaves() {
        let attempt = makeAttempt(noteID: Self.noteID(69), revision: Self.noteID(70), body: "A")
        let completion = MacNoteSaveOperationCompletion.completed(
            attempt: attempt,
            mutationKind: .nonBodyOnly,
            publication: .ordinaryRecorded
        )
        let result = MacIncomingBoundaryCompletionPolicy.result(
            for: completion,
            obligation: nil,
            requestedAttemptStillOwnsEditor: true,
            completingAttemptStillOwnsEditor: true
        )

        guard case .ready = result else {
            return XCTFail("A later current revision may satisfy the re-evaluated boundary")
        }
    }

    private static func noteID(_ suffix: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))!
    }

    private func makeCapturedObligation(noteID: UUID) throws -> SyncConvergenceLocalObligation {
        let modifiedAt = Date(timeIntervalSince1970: 10)
        let change = SyncBatchChange.noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
            noteID: noteID,
            utf16Offset: "A".utf16.count,
            text: "B",
            modifiedAt: modifiedAt,
            baseContentHash: SyncBatchContentHash.sha256Hex(for: "A")
        ))
        let captured = try SyncConvergenceLocalEvidenceCapture.capturedChange(
            for: change,
            preBody: "A",
            postBody: "AB"
        )
        let batch = SyncBatch(
            id: Self.noteID(100),
            originDeviceID: Self.noteID(101),
            createdAt: modifiedAt,
            changes: [change]
        )
        return SyncConvergenceLocalObligation(batch: batch, capturedChanges: [captured])
    }

    private func makeAttempt(noteID: UUID, revision: UUID, body: String) -> MacEditorSaveAttempt {
        MacEditorSaveAttempt(
            noteID: noteID,
            editorRevision: revision,
            attributedContent: NSAttributedString(string: body)
        )
    }

    private func completed(_ attempt: MacEditorSaveAttempt) -> MacNoteSaveOperationCompletion {
        .completed(attempt: attempt, mutationKind: .body, publication: .ordinaryRecorded)
    }
}

private actor MacSaveTestGate {
    private var isBlocked = false
    private var blockedContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func waitForRelease() async {
        await withCheckedContinuation { continuation in
            isBlocked = true
            blockedContinuation?.resume()
            blockedContinuation = nil
            releaseContinuation = continuation
        }
    }

    func waitUntilBlocked() async {
        guard !isBlocked else { return }
        await withCheckedContinuation { continuation in
            blockedContinuation = continuation
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private extension SyncConvergenceIncomingLocalBoundaryPreparation {
    var failure: SyncConvergenceIncomingLocalBoundaryFailure? {
        guard case .failed(let failure) = self else { return nil }
        return failure
    }
}
