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

    func testBoundaryPreparerContinuesAfterSelectedNoBodyResult() async throws {
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
}

private extension SyncConvergenceIncomingLocalBoundaryPreparation {
    var failure: SyncConvergenceIncomingLocalBoundaryFailure? {
        guard case .failed(let failure) = self else { return nil }
        return failure
    }
}
