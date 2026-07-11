import XCTest
@testable import MyRAM

final class IPhoneSyncBatchAccumulatorTests: XCTestCase {
    func testChangesAppendToPendingBatchAndPreserveOrdering() async {
        let accumulator = makeAccumulator()
        let firstChange = titleChange("First")
        let secondChange = titleChange("Second")
        let start = Date(timeIntervalSince1970: 100)

        await accumulator.record(firstChange, at: start)
        await accumulator.record(secondChange, at: start.addingTimeInterval(1))
        let batch = await accumulator.takeReadyBatch(at: start.addingTimeInterval(5))

        XCTAssertEqual(batch?.changes, [firstChange, secondChange])
    }

    func testCapturedBodyEvidenceSurvivesPendingBatchEmission() async throws {
        let accumulator = makeAccumulator()
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-000000124201")!
        let change = SyncBatchChange.noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
            noteID: noteID,
            utf16Offset: "Hello".utf16.count,
            text: " world",
            modifiedAt: Date(timeIntervalSince1970: 20),
            baseContentHash: SyncBatchContentHash.sha256Hex(for: "Hello")
        ))
        let capturedChange = try SyncConvergenceLocalEvidenceCapture.capturedChange(
            for: change,
            preBody: "Hello",
            postBody: "Hello world"
        )
        let start = Date(timeIntervalSince1970: 120)

        await accumulator.record(capturedChange, at: start)
        let obligation = await accumulator.takeReadyBatch(at: start.addingTimeInterval(5))

        XCTAssertEqual(obligation?.batch.changes, [change])
        guard case .captured(let capturedChanges) = obligation?.evidence else {
            return XCTFail("Expected captured local evidence")
        }
        XCTAssertEqual(capturedChanges, [capturedChange])
        XCTAssertEqual(capturedChanges.first?.evidence?.preBodyHash, SyncBatchContentHash.sha256Hex(for: "Hello"))
        XCTAssertEqual(capturedChanges.first?.evidence?.postBodyHash, SyncBatchContentHash.sha256Hex(for: "Hello world"))
    }

    func testQuietWindowRearmsAndBatchIDStaysStable() async {
        let accumulator = makeAccumulator()
        let start = Date(timeIntervalSince1970: 200)

        await accumulator.record(titleChange("First"), at: start)
        let originalBatchID = await accumulator.pendingBatchID()
        let originalReadyAt = await accumulator.pendingReadyAt()

        await accumulator.record(titleChange("Second"), at: start.addingTimeInterval(2))
        let rearmedBatchID = await accumulator.pendingBatchID()
        let rearmedReadyAt = await accumulator.pendingReadyAt()

        XCTAssertEqual(rearmedBatchID, originalBatchID)
        XCTAssertEqual(originalReadyAt, start.addingTimeInterval(3))
        XCTAssertEqual(rearmedReadyAt, start.addingTimeInterval(5))
        let earlyBatch = await accumulator.takeReadyBatch(at: start.addingTimeInterval(4))
        let readyBatch = await accumulator.takeReadyBatch(at: start.addingTimeInterval(5))
        XCTAssertNil(earlyBatch)
        XCTAssertNotNil(readyBatch)
    }

    func testCaptureRecordsSupportedNoteOperations() {
        let note = Note(title: "Created", content: "Body")
        note.id = UUID(uuidString: "00000000-0000-0000-0000-000000124001")!

        XCTAssertEqual(
            IPhoneSyncBatchCaptureHook.noteCreated(note),
            .noteCreated(
                SyncBatchNoteCreatedChange(
                    noteID: note.id,
                    title: "Created",
                    body: "Body",
                    folderID: nil,
                    createdAt: note.createdAt,
                    modifiedAt: note.modifiedAt
                )
            )
        )

        XCTAssertEqual(
            IPhoneSyncBatchCaptureHook.titleChanged(
                noteID: note.id,
                oldTitle: "Created",
                newTitle: "Renamed",
                modifiedAt: Date(timeIntervalSince1970: 1)
            ),
            .noteTitleChanged(
                SyncBatchNoteTitleChangedChange(
                    noteID: note.id,
                    title: "Renamed",
                    modifiedAt: Date(timeIntervalSince1970: 1)
                )
            )
        )

        XCTAssertEqual(
            IPhoneSyncBatchCaptureHook.bodyTextChanged(
                noteID: note.id,
                oldBody: "A😀B",
                newBody: "A😀xB",
                modifiedAt: Date(timeIntervalSince1970: 2),
                bodyHashCapabilityEnabled: true
            ),
            .noteBodyTextInserted(
                SyncBatchNoteBodyTextInsertedChange(
                    noteID: note.id,
                    utf16Offset: 3,
                    text: "x",
                    modifiedAt: Date(timeIntervalSince1970: 2),
                    baseContentHash: SyncBatchContentHash.sha256Hex(for: "A😀B")
                )
            )
        )

        XCTAssertEqual(
            IPhoneSyncBatchCaptureHook.bodyTextChanged(
                noteID: note.id,
                oldBody: "abcdef",
                newBody: "abef",
                modifiedAt: Date(timeIntervalSince1970: 3),
                bodyHashCapabilityEnabled: true
            ),
            .noteBodyTextDeleted(
                SyncBatchNoteBodyTextDeletedChange(
                    noteID: note.id,
                    utf16Offset: 2,
                    utf16Length: 2,
                    expectedText: "cd",
                    modifiedAt: Date(timeIntervalSince1970: 3),
                    baseContentHash: SyncBatchContentHash.sha256Hex(for: "abcdef")
                )
            )
        )
    }

    func testBatchSequenceIsAssignedWhenPendingBatchStarts() async {
        let accumulator = IPhoneSyncBatchAccumulator(
            originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-000000124103")!,
            quietWindow: 3,
            batchIDProvider: { UUID(uuidString: "00000000-0000-0000-0000-000000124104")! },
            batchSequenceProvider: { .reserved(42) }
        )
        let start = Date(timeIntervalSince1970: 500)

        await accumulator.record(titleChange("First"), at: start)
        await accumulator.record(titleChange("Second"), at: start.addingTimeInterval(1))
        let batch = await accumulator.takeReadyBatch(at: start.addingTimeInterval(5))

        XCTAssertEqual(batch?.batchSequence, 42)
    }

    func testTakePendingBatchNowCapturesBeforeQuietWindowAndPreservesIdentity() async {
        let accumulator = IPhoneSyncBatchAccumulator(
            originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-000000124106")!,
            quietWindow: 3,
            batchIDProvider: { UUID(uuidString: "00000000-0000-0000-0000-000000124107")! },
            batchSequenceProvider: { .reserved(43) }
        )
        let start = Date(timeIntervalSince1970: 600)
        let firstChange = titleChange("First")
        let secondChange = titleChange("Second")

        await accumulator.record(firstChange, at: start)
        await accumulator.record(secondChange, at: start.addingTimeInterval(1))

        let batch = await accumulator.takePendingBatchNow()

        XCTAssertEqual(batch?.id, UUID(uuidString: "00000000-0000-0000-0000-000000124107")!)
        XCTAssertEqual(batch?.createdAt, start)
        XCTAssertEqual(batch?.batchSequence, 43)
        XCTAssertEqual(batch?.changes, [firstChange, secondChange])
        let pendingBatchID = await accumulator.pendingBatchID()
        XCTAssertNil(pendingBatchID)
    }

    func testTakePendingBatchNowClearsBatchSoReadyEmissionCannotReplayIt() async {
        let accumulator = makeAccumulator()
        let start = Date(timeIntervalSince1970: 700)

        await accumulator.record(titleChange("First"), at: start)
        let captured = await accumulator.takePendingBatchNow()
        await accumulator.emitReadyBatches(at: start.addingTimeInterval(5))
        let replayed = await accumulator.takeReadyBatch(at: start.addingTimeInterval(5))

        XCTAssertNotNil(captured)
        XCTAssertNil(replayed)
    }

    func testAmbiguousReplacementIsSkipped() {
        XCTAssertNil(
            IPhoneSyncBatchCaptureHook.bodyTextChanged(
                noteID: UUID(uuidString: "00000000-0000-0000-0000-000000124002")!,
                oldBody: "abc",
                newBody: "axc",
                modifiedAt: Date(timeIntervalSince1970: 4)
            )
        )
    }

    private func makeAccumulator() -> IPhoneSyncBatchAccumulator {
        IPhoneSyncBatchAccumulator(
            originDeviceID: UUID(uuidString: "00000000-0000-0000-0000-000000124003")!,
            quietWindow: 3,
            batchIDProvider: { UUID(uuidString: "00000000-0000-0000-0000-000000124004")! }
        )
    }

    private func titleChange(_ title: String) -> SyncBatchChange {
        .noteTitleChanged(
            SyncBatchNoteTitleChangedChange(
                noteID: UUID(uuidString: "00000000-0000-0000-0000-000000124005")!,
                title: title,
                modifiedAt: Date(timeIntervalSince1970: 10)
            )
        )
    }
}
