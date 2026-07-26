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


    func testSharedCapturedBodyChangesReturnEvidenceChain() throws {
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-00000012420F")!

        let captured = try SyncBatchNoteChangeCapture.capturedBodyChanges(
            noteID: noteID,
            oldBody: "ab-cd-ef",
            newBody: "ax-cd-yf",
            modifiedAt: Date(timeIntervalSince1970: 21),
            bodyHashCapabilityEnabled: true
        )

        XCTAssertEqual(captured.count, 4)
        var body = "ab-cd-ef"
        for capturedChange in captured {
            XCTAssertEqual(capturedChange.evidence?.preBodyHash, SyncBatchContentHash.sha256Hex(for: body))
            body = try SyncConvergenceLocalEvidenceCapture.apply(capturedChange.change, to: body)
            XCTAssertEqual(capturedChange.evidence?.postBodyHash, SyncBatchContentHash.sha256Hex(for: body))
        }
        XCTAssertEqual(body, "ax-cd-yf")
    }

    func testSharedCapturedBodyChangesReturnEmptyForNoOp() throws {
        let captured = try SyncBatchNoteChangeCapture.capturedBodyChanges(
            noteID: UUID(uuidString: "00000000-0000-0000-0000-000000124210")!,
            oldBody: "same",
            newBody: "same",
            modifiedAt: Date(timeIntervalSince1970: 22),
            bodyHashCapabilityEnabled: true
        )

        XCTAssertTrue(captured.isEmpty)
    }


    func testIPhoneBodyCaptureMatchesSharedCapturedOperationSequence() throws {
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-000000124211")!
        let modifiedAt = Date(timeIntervalSince1970: 23)
        let oldBody = "ab-cd-ef"
        let newBody = "ax-cd-yf"

        let iPhoneOperations = try IPhoneSyncBatchCaptureHook.bodyTextChanges(
            noteID: noteID,
            oldBody: oldBody,
            newBody: newBody,
            modifiedAt: modifiedAt,
            bodyHashCapabilityEnabled: true
        )
        let sharedCaptured = try SyncBatchNoteChangeCapture.capturedBodyChanges(
            noteID: noteID,
            oldBody: oldBody,
            newBody: newBody,
            modifiedAt: modifiedAt,
            bodyHashCapabilityEnabled: true
        )

        XCTAssertEqual(sharedCaptured.map(\.change), iPhoneOperations)
        var body = oldBody
        for capturedChange in sharedCaptured {
            XCTAssertEqual(capturedChange.evidence?.preBodyHash, SyncBatchContentHash.sha256Hex(for: body))
            body = try SyncConvergenceLocalEvidenceCapture.apply(capturedChange.change, to: body)
            XCTAssertEqual(capturedChange.evidence?.postBodyHash, SyncBatchContentHash.sha256Hex(for: body))
        }
        XCTAssertEqual(body, newBody)
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

    func testTakePendingObligationIfAffectingFlushesWholePendingBatchForMatchingNote() async throws {
        let accumulator = makeAccumulator()
        let noteAID = UUID(uuidString: "00000000-0000-0000-0000-000000124301")!
        let noteBID = UUID(uuidString: "00000000-0000-0000-0000-000000124302")!
        let noteAChange = SyncBatchChange.noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange(
            noteID: noteAID,
            utf16Offset: 1,
            text: "!",
            modifiedAt: Date(timeIntervalSince1970: 1),
            baseContentHash: SyncBatchContentHash.sha256Hex(for: "A")
        ))
        let noteBChange = titleChange("B")
        let capturedNoteAChange = try SyncConvergenceLocalEvidenceCapture.capturedChange(
            for: noteAChange,
            preBody: "A",
            postBody: "A!"
        )

        await accumulator.record(capturedNoteAChange, at: Date(timeIntervalSince1970: 1))
        await accumulator.record(noteBChange, at: Date(timeIntervalSince1970: 2))

        let hasPendingNoteABodyChange = await accumulator.containsPendingBodyChange(for: noteAID)
        let hasPendingNoteBBodyChange = await accumulator.containsPendingBodyChange(for: noteBID)
        XCTAssertTrue(hasPendingNoteABodyChange)
        XCTAssertFalse(hasPendingNoteBBodyChange)
        let obligation = await accumulator.takePendingObligationIfAffecting(noteID: noteAID)
        let pendingBatchID = await accumulator.pendingBatchID()

        XCTAssertEqual(obligation?.changes, [noteAChange, noteBChange])
        XCTAssertNil(pendingBatchID)
    }

    func testTakePendingObligationIfAffectingLeavesUnrelatedPendingBatchAlone() async {
        let accumulator = makeAccumulator()
        let unrelatedNoteID = UUID(uuidString: "00000000-0000-0000-0000-000000124303")!

        await accumulator.record(titleChange("A"), at: Date(timeIntervalSince1970: 1))
        let obligation = await accumulator.takePendingObligationIfAffecting(noteID: unrelatedNoteID)
        let pendingBatchID = await accumulator.pendingBatchID()

        XCTAssertNil(obligation)
        XCTAssertNotNil(pendingBatchID)
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

    func testBodyReplacementEmitsContinuousDeleteInsertChain() throws {
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-000000124002")!
        let changes = try IPhoneSyncBatchCaptureHook.bodyTextChanges(
            noteID: noteID,
            oldBody: "abc",
            newBody: "axc",
            modifiedAt: Date(timeIntervalSince1970: 4),
            bodyHashCapabilityEnabled: true
        )

        XCTAssertEqual(changes.count, 2)
        guard case .noteBodyTextDeleted(let deletion) = changes[0],
              case .noteBodyTextInserted(let insertion) = changes[1] else {
            return XCTFail("Expected replacement to delete before inserting")
        }
        XCTAssertEqual(deletion.noteID, noteID)
        XCTAssertEqual(deletion.utf16Offset, 1)
        XCTAssertEqual(deletion.utf16Length, 1)
        XCTAssertEqual(deletion.expectedText, "b")
        XCTAssertEqual(deletion.baseContentHash, SyncBatchContentHash.sha256Hex(for: "abc"))
        XCTAssertEqual(insertion.noteID, noteID)
        XCTAssertEqual(insertion.utf16Offset, 1)
        XCTAssertEqual(insertion.text, "x")
        XCTAssertEqual(insertion.baseContentHash, SyncBatchContentHash.sha256Hex(for: "ac"))
        let replay = try changes.reduce("abc") { body, change in
            try SyncConvergenceLocalEvidenceCapture.apply(change, to: body)
        }
        XCTAssertEqual(replay, "axc")
    }

    func testSeparatedBodyReplacementsPreserveUnchangedInterior() throws {
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-000000124003")!
        let changes = try IPhoneSyncBatchCaptureHook.bodyTextChanges(
            noteID: noteID,
            oldBody: "ab-cd-ef",
            newBody: "ax-cd-yf",
            modifiedAt: Date(timeIntervalSince1970: 5),
            bodyHashCapabilityEnabled: true
        )

        XCTAssertEqual(changes.count, 4)
        XCTAssertEqual(try changes.reduce("ab-cd-ef") { try SyncConvergenceLocalEvidenceCapture.apply($1, to: $0) }, "ax-cd-yf")
        let deletedTexts = changes.compactMap { change -> String? in
            guard case .noteBodyTextDeleted(let deletion) = change else { return nil }
            return deletion.expectedText
        }
        XCTAssertEqual(deletedTexts, ["b", "e"])
        XCTAssertFalse(deletedTexts.contains("-cd-"))
    }

    func testBodyReplacementUsesUTF16OffsetsForEmojiAndComposedUnicode() throws {
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-000000124004")!
        let oldBody = "A😀e\u{301}B"
        let newBody = "A😇e\u{301}B"
        let changes = try IPhoneSyncBatchCaptureHook.bodyTextChanges(
            noteID: noteID,
            oldBody: oldBody,
            newBody: newBody,
            modifiedAt: Date(timeIntervalSince1970: 6),
            bodyHashCapabilityEnabled: true
        )

        guard case .noteBodyTextDeleted(let deletion) = changes.first else {
            return XCTFail("Expected unicode replacement to start with deletion")
        }
        XCTAssertEqual(deletion.utf16Offset, "A".utf16.count)
        XCTAssertEqual(deletion.utf16Length, "😀".utf16.count)
        XCTAssertEqual(try changes.reduce(oldBody) { try SyncConvergenceLocalEvidenceCapture.apply($1, to: $0) }, newBody)
    }

    func testLargeBodyReplacementEmitsValidConvergenceWork() throws {
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-000000124006")!
        let oldBody = String(repeating: "a", count: 600)
        let newBody = String(repeating: "b", count: 600)

        let changes = try IPhoneSyncBatchCaptureHook.bodyTextChanges(
            noteID: noteID,
            oldBody: oldBody,
            newBody: newBody,
            modifiedAt: Date(timeIntervalSince1970: 7),
            bodyHashCapabilityEnabled: true
        )

        XCTAssertEqual(changes.count, 2)
        assertEvidenceChain(changes, oldBody: oldBody, newBody: newBody)
        guard case .noteBodyTextDeleted(let deletion) = changes[0],
              case .noteBodyTextInserted(let insertion) = changes[1] else {
            return XCTFail("Expected no-common large replacement to delete then insert")
        }
        XCTAssertEqual(deletion.expectedText, oldBody)
        XCTAssertEqual(insertion.text, newBody)
    }

    func testSeparatedBodyReplacementsBeyondFiveHundredCharactersPreserveInterior() throws {
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-000000124007")!
        let interior = String(repeating: "m", count: 520)
        let oldBody = "a\(interior)b"
        let newBody = "x\(interior)y"

        let changes = try IPhoneSyncBatchCaptureHook.bodyTextChanges(
            noteID: noteID,
            oldBody: oldBody,
            newBody: newBody,
            modifiedAt: Date(timeIntervalSince1970: 8),
            bodyHashCapabilityEnabled: true
        )

        assertEvidenceChain(changes, oldBody: oldBody, newBody: newBody)
        let deletedTexts = changes.compactMap { change -> String? in
            guard case .noteBodyTextDeleted(let deletion) = change else { return nil }
            return deletion.expectedText
        }
        XCTAssertEqual(deletedTexts, ["a", "b"])
        XCTAssertFalse(deletedTexts.contains(interior))
    }

    func testNoCommonCharacterReplacementEmitsTruthfulDeleteInsertChain() throws {
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-000000124008")!
        let changes = try IPhoneSyncBatchCaptureHook.bodyTextChanges(
            noteID: noteID,
            oldBody: "abc",
            newBody: "xyz",
            modifiedAt: Date(timeIntervalSince1970: 9),
            bodyHashCapabilityEnabled: true
        )

        XCTAssertEqual(changes.count, 2)
        assertEvidenceChain(changes, oldBody: "abc", newBody: "xyz")
        guard case .noteBodyTextDeleted(let deletion) = changes[0],
              case .noteBodyTextInserted(let insertion) = changes[1] else {
            return XCTFail("Expected no-common replacement to delete then insert")
        }
        XCTAssertEqual(deletion.expectedText, "abc")
        XCTAssertEqual(insertion.text, "xyz")
    }

    func testRepeatedCharactersProduceDeterministicEvidence() throws {
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-000000124009")!
        let first = try IPhoneSyncBatchCaptureHook.bodyTextChanges(
            noteID: noteID,
            oldBody: "aaaaabaaaaa",
            newBody: "aaaacbaaaaa",
            modifiedAt: Date(timeIntervalSince1970: 10),
            bodyHashCapabilityEnabled: true
        )
        let second = try IPhoneSyncBatchCaptureHook.bodyTextChanges(
            noteID: noteID,
            oldBody: "aaaaabaaaaa",
            newBody: "aaaacbaaaaa",
            modifiedAt: Date(timeIntervalSince1970: 10),
            bodyHashCapabilityEnabled: true
        )

        XCTAssertEqual(first, second)
        assertEvidenceChain(first, oldBody: "aaaaabaaaaa", newBody: "aaaacbaaaaa")
    }

    func testAdjacentRemovalsAreGrouped() throws {
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-00000012400A")!
        let changes = try IPhoneSyncBatchCaptureHook.bodyTextChanges(
            noteID: noteID,
            oldBody: "abcdef",
            newBody: "abef",
            modifiedAt: Date(timeIntervalSince1970: 11),
            bodyHashCapabilityEnabled: true
        )

        XCTAssertEqual(changes.count, 1)
        guard case .noteBodyTextDeleted(let deletion) = changes[0] else {
            return XCTFail("Expected adjacent removals to be grouped as one deletion")
        }
        XCTAssertEqual(deletion.expectedText, "cd")
        assertEvidenceChain(changes, oldBody: "abcdef", newBody: "abef")
    }

    func testAdjacentInsertionsAreGrouped() throws {
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-00000012400B")!
        let changes = try IPhoneSyncBatchCaptureHook.bodyTextChanges(
            noteID: noteID,
            oldBody: "abef",
            newBody: "abcdef",
            modifiedAt: Date(timeIntervalSince1970: 12),
            bodyHashCapabilityEnabled: true
        )

        XCTAssertEqual(changes.count, 1)
        guard case .noteBodyTextInserted(let insertion) = changes[0] else {
            return XCTFail("Expected adjacent insertions to be grouped as one insertion")
        }
        XCTAssertEqual(insertion.text, "cd")
        assertEvidenceChain(changes, oldBody: "abef", newBody: "abcdef")
    }

    func testChangedBodyNeverProducesEmptyOperationList() throws {
        let changes = try IPhoneSyncBatchCaptureHook.bodyTextChanges(
            noteID: UUID(uuidString: "00000000-0000-0000-0000-00000012400C")!,
            oldBody: "left",
            newBody: "right",
            modifiedAt: Date(timeIntervalSince1970: 13),
            bodyHashCapabilityEnabled: true
        )

        XCTAssertFalse(changes.isEmpty)
    }

    private func assertEvidenceChain(
        _ changes: [SyncBatchChange],
        oldBody: String,
        newBody: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var body = oldBody
        for change in changes {
            switch change {
            case .noteBodyTextInserted(let insertion):
                XCTAssertEqual(insertion.baseContentHash, SyncBatchContentHash.sha256Hex(for: body), file: file, line: line)
            case .noteBodyTextDeleted(let deletion):
                XCTAssertEqual(deletion.baseContentHash, SyncBatchContentHash.sha256Hex(for: body), file: file, line: line)
                let start = body.utf16.index(body.utf16.startIndex, offsetBy: deletion.utf16Offset)
                let end = body.utf16.index(start, offsetBy: deletion.utf16Length)
                let range = String.Index(start, within: body)!..<String.Index(end, within: body)!
                XCTAssertEqual(String(body[range]), deletion.expectedText, file: file, line: line)
            case .noteBodyTextInsertedAnchored, .noteBodyTextDeletedAnchored:
                XCTFail(
                    "Capture must remain legacy-only while anchored payloads are disabled",
                    file: file,
                    line: line
                )
            case .noteCreated, .noteTitleChanged, .noteBodyReconciled, .noteLifecycleChanged:
                XCTFail("Unexpected non-positional body change", file: file, line: line)
            }
            do {
                body = try SyncConvergenceLocalEvidenceCapture.apply(change, to: body)
            } catch {
                XCTFail("Replay failed: \(error)", file: file, line: line)
            }
        }
        XCTAssertEqual(body, newBody, file: file, line: line)
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
