import XCTest
@testable import MyRAMMac

@MainActor
final class MacSyncConvergencePresentationAdapterTests: XCTestCase {
    func testIncrementalForNonSelectedNoteRefreshesMetadataWithoutEditorMutation() async {
        let noteID = Self.uuid(1)
        let recorder = PresentationSurfaceRecorder(selectedNoteID: nil, currentEditorBody: nil)
        let adapter = MacSyncConvergencePresentationAdapter(surface: recorder.surface())

        let result = await adapter.refreshPresentation(for: request(noteID: noteID, routing: .incremental, body: "Hello!"))

        XCTAssertEqual(result, .verifiedComplete)
        XCTAssertEqual(recorder.refreshCount, 1)
        XCTAssertTrue(recorder.appliedIncremental.isEmpty)
        XCTAssertEqual(recorder.reloadCount, 0)
    }

    func testIncrementalForSelectedSafeEditorAppliesAndVerifiesAuthoritativeBody() async {
        let noteID = Self.uuid(2)
        let recorder = PresentationSurfaceRecorder(selectedNoteID: noteID, currentEditorBody: "Hello!")
        recorder.applyResult = EditorRemoteBatchApplyResult(appliedCount: 1, disposition: .applied)
        let adapter = MacSyncConvergencePresentationAdapter(surface: recorder.surface())

        let result = await adapter.refreshPresentation(for: request(noteID: noteID, routing: .incremental, body: "Hello!"))

        XCTAssertEqual(result, .verifiedComplete)
        XCTAssertEqual(recorder.appliedIncremental.map(\.noteID), [noteID])
        XCTAssertEqual(recorder.appliedIncremental.first?.authoritativeBody, "Hello!")
        XCTAssertEqual(recorder.refreshCount, 1)
    }

    func testIncrementalUnsafeEditorRemainsPendingWithoutApplying() async {
        let noteID = Self.uuid(3)
        let recorder = PresentationSurfaceRecorder(selectedNoteID: noteID, hasUnsavedChanges: true, currentEditorBody: "local")
        let adapter = MacSyncConvergencePresentationAdapter(surface: recorder.surface())

        let result = await adapter.refreshPresentation(for: request(noteID: noteID, routing: .incremental, body: "remote"))

        XCTAssertEqual(result, .stillPending)
        XCTAssertTrue(recorder.appliedIncremental.isEmpty)
        XCTAssertEqual(recorder.refreshCount, 1)
    }

    func testIncrementalReloadRequiredRemainsPending() async {
        let noteID = Self.uuid(4)
        let recorder = PresentationSurfaceRecorder(selectedNoteID: noteID, currentEditorBody: "Hello")
        recorder.applyResult = EditorRemoteBatchApplyResult(appliedCount: 0, disposition: .requiresReload(.editorUnavailable))
        let adapter = MacSyncConvergencePresentationAdapter(surface: recorder.surface())

        let result = await adapter.refreshPresentation(for: request(noteID: noteID, routing: .incremental, body: "Hello!"))

        XCTAssertEqual(result, .stillPending)
    }

    func testNoneRefreshesMetadataWithoutRewritingSelectedEditorBody() async {
        let noteID = Self.uuid(5)
        let recorder = PresentationSurfaceRecorder(selectedNoteID: noteID, currentEditorBody: "mounted")
        let adapter = MacSyncConvergencePresentationAdapter(surface: recorder.surface())

        let result = await adapter.refreshPresentation(for: request(noteID: noteID, routing: .none, body: "authoritative"))

        XCTAssertEqual(result, .verifiedComplete)
        XCTAssertEqual(recorder.refreshCount, 1)
        XCTAssertTrue(recorder.appliedIncremental.isEmpty)
        XCTAssertEqual(recorder.reloadCount, 0)
    }


    func testIncrementalMalformedOperationPayloadFails() async {
        let noteID = Self.uuid(9)
        let recorder = PresentationSurfaceRecorder(selectedNoteID: noteID, currentEditorBody: "Hello!")
        let adapter = MacSyncConvergencePresentationAdapter(surface: recorder.surface())
        var malformed = request(noteID: noteID, routing: .incremental, body: "Hello!")
        malformed = SyncConvergencePresentationRequest(
            incorporationIdentity: malformed.incorporationIdentity,
            noteID: malformed.noteID,
            routing: malformed.routing,
            expectedPreBodyHash: malformed.expectedPreBodyHash,
            committedPostBodyHash: malformed.committedPostBodyHash,
            incrementalOperations: [malformed.incrementalOperations[0].withoutInsertedText()],
            rewriteSafetyReceipt: malformed.rewriteSafetyReceipt,
            committedNote: malformed.committedNote,
            committedBodyHash: malformed.committedBodyHash,
            committedTitle: malformed.committedTitle
        )

        let result = await adapter.refreshPresentation(for: malformed)

        XCTAssertEqual(result, .failed)
        XCTAssertTrue(recorder.appliedIncremental.isEmpty)
    }

    func testIncrementalPostApplyBodyMismatchFails() async {
        let noteID = Self.uuid(10)
        let recorder = PresentationSurfaceRecorder(selectedNoteID: noteID, currentEditorBody: "wrong")
        recorder.applyResult = EditorRemoteBatchApplyResult(appliedCount: 1, disposition: .applied)
        let adapter = MacSyncConvergencePresentationAdapter(surface: recorder.surface())

        let result = await adapter.refreshPresentation(for: request(noteID: noteID, routing: .incremental, body: "right"))

        XCTAssertEqual(result, .failed)
    }

    func testWholeNoteFallbackReloadBodyMismatchFails() async {
        let noteID = Self.uuid(11)
        let recorder = PresentationSurfaceRecorder(selectedNoteID: noteID, currentEditorBody: "wrong")
        let adapter = MacSyncConvergencePresentationAdapter(surface: recorder.surface())

        let result = await adapter.refreshPresentation(for: request(noteID: noteID, routing: .wholeNoteFallback, body: "right"))

        XCTAssertEqual(result, .failed)
        XCTAssertEqual(recorder.reloadCount, 1)
    }

    func testWholeNoteFallbackReloadsAndVerifiesAuthoritativeBody() async {
        let noteID = Self.uuid(6)
        let recorder = PresentationSurfaceRecorder(selectedNoteID: noteID, currentEditorBody: "remote")
        let adapter = MacSyncConvergencePresentationAdapter(surface: recorder.surface())

        let result = await adapter.refreshPresentation(for: request(noteID: noteID, routing: .wholeNoteFallback, body: "remote"))

        XCTAssertEqual(result, .verifiedComplete)
        XCTAssertEqual(recorder.reloads.map(\.noteID), [noteID])
        XCTAssertEqual(recorder.reloads.first?.authoritativeBody, "remote")
    }

    func testWholeNoteFallbackWithoutReceiptFails() async {
        let noteID = Self.uuid(7)
        let recorder = PresentationSurfaceRecorder(selectedNoteID: noteID, currentEditorBody: "remote")
        let adapter = MacSyncConvergencePresentationAdapter(surface: recorder.surface())

        let result = await adapter.refreshPresentation(for: request(noteID: noteID, routing: .wholeNoteFallback, body: "remote", includeReceipt: false))

        XCTAssertEqual(result, .failed)
        XCTAssertEqual(recorder.reloadCount, 0)
    }

    func testWholeNoteFallbackUnsafeEditorRemainsPending() async {
        let noteID = Self.uuid(8)
        let recorder = PresentationSurfaceRecorder(selectedNoteID: noteID, hasUnsavedChanges: true, currentEditorBody: "local")
        let adapter = MacSyncConvergencePresentationAdapter(surface: recorder.surface())

        let result = await adapter.refreshPresentation(for: request(noteID: noteID, routing: .wholeNoteFallback, body: "remote"))

        XCTAssertEqual(result, .stillPending)
        XCTAssertEqual(recorder.reloadCount, 0)
    }

    private func operationIdentity(kind: String) -> OperationIdentityPayload {
        let batchID = Self.uuid(100)
        let originDeviceID = Self.uuid(101)
        return OperationIdentityPayload(
            batchID: batchID,
            originDeviceID: originDeviceID,
            operationIndex: 0,
            operationKind: kind,
            canonicalReplayKey: CanonicalReplayKeyPayload(
                modifiedAtBitPattern: SyncConvergenceDateBits.bitPattern(for: Date(timeIntervalSince1970: 10)),
                originDeviceIDLowercase: originDeviceID.uuidString.lowercased(),
                batchOrderKind: .sequenced,
                legacyCreatedAtBitPattern: nil,
                sequence: 1,
                batchIDLowercase: batchID.uuidString.lowercased(),
                operationIndex: 0
            )
        )
    }

    private static func uuid(_ suffix: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))!
    }

    private func request(
        noteID: UUID,
        routing: SyncConvergencePresentationRouting,
        body: String,
        includeReceipt: Bool = true
    ) -> SyncConvergencePresentationRequest {
        let preBody = "base"
        let preHash = SyncBatchContentHash.sha256Hex(for: preBody)
        let postHash = SyncBatchContentHash.sha256Hex(for: body)
        let operations: [SyncConvergencePostCommitWorkPayloadV1.IncrementalOperationPayload]
        if routing == .incremental {
            operations = [
                SyncConvergencePostCommitWorkPayloadV1.IncrementalOperationPayload(
                    noteID: noteID,
                    operationIndex: 0,
                    kind: .insert,
                    utf16Offset: preBody.utf16.count,
                    utf16Length: nil,
                    text: "!",
                    expectedText: nil,
                    baseContentHash: preHash,
                    resultContentHash: postHash,
                    operationIdentity: operationIdentity(kind: "insert")
                )
            ]
        } else {
            operations = []
        }
        let receipt = includeReceipt && routing == .wholeNoteFallback
            ? SyncConvergenceRewriteSafetyReceipt(
                noteID: noteID,
                priorBodyHash: preHash,
                candidateBodyHash: postHash,
                consumedDeleteIdentities: []
            )
            : nil

        return SyncConvergencePresentationRequest(
            incorporationIdentity: SyncConvergencePersistedIncorporationIdentity(
                batchID: Self.uuid(102),
                canonicalPayloadDigest: String(repeating: "a", count: 64),
                canonicalPayloadDigestFormatVersion: 1,
                committedResultDigest: String(repeating: "b", count: 64),
                committedResultDigestFormatVersion: 1
            ),
            noteID: noteID,
            routing: routing,
            expectedPreBodyHash: routing == .none ? nil : preHash,
            committedPostBodyHash: postHash,
            incrementalOperations: operations,
            rewriteSafetyReceipt: receipt,
            committedNote: SyncConvergenceMutableNoteRecord(
                noteID: noteID,
                folderID: nil,
                title: "Title",
                body: body,
                createdAt: Date(timeIntervalSince1970: 1),
                modifiedAt: Date(timeIntervalSince1970: 20)
            ),
            committedBodyHash: postHash,
            committedTitle: "Title"
        )
    }
}


private extension SyncConvergencePostCommitWorkPayloadV1.IncrementalOperationPayload {
    func withoutInsertedText() -> Self {
        SyncConvergencePostCommitWorkPayloadV1.IncrementalOperationPayload(
            noteID: noteID,
            operationIndex: operationIndex,
            kind: kind,
            utf16Offset: utf16Offset,
            utf16Length: utf16Length,
            text: nil,
            expectedText: expectedText,
            baseContentHash: baseContentHash,
            resultContentHash: resultContentHash,
            operationIdentity: operationIdentity
        )
    }
}

@MainActor
private final class PresentationSurfaceRecorder {
    struct IncrementalCall: Equatable {
        let noteID: UUID
        let authoritativeBody: String
    }

    struct ReloadCall: Equatable {
        let noteID: UUID
        let authoritativeBody: String
    }

    var applyResult = EditorRemoteBatchApplyResult(appliedCount: 0, disposition: .noApplicableMutations)
    var refreshCount = 0
    var appliedIncremental: [IncrementalCall] = []
    var reloads: [ReloadCall] = []
    var reloadResult = true
    private let selectedNoteID: UUID?
    private let hasUnsavedChanges: Bool
    private let currentEditorBody: String?

    init(selectedNoteID: UUID?, hasUnsavedChanges: Bool = false, currentEditorBody: String?) {
        self.selectedNoteID = selectedNoteID
        self.hasUnsavedChanges = hasUnsavedChanges
        self.currentEditorBody = currentEditorBody
    }

    var reloadCount: Int { reloads.count }

    func surface() -> MacSyncConvergencePresentationSurface {
        MacSyncConvergencePresentationSurface(
            selectedNoteID: { self.selectedNoteID },
            hasUnsavedChanges: { self.hasUnsavedChanges },
            refreshNotesList: { self.refreshCount += 1 },
            applyIncremental: { actions, noteID, authoritativeBody in
                self.appliedIncremental.append(IncrementalCall(noteID: noteID, authoritativeBody: authoritativeBody))
                XCTAssertFalse(actions.isEmpty)
                return self.applyResult
            },
            reloadSelectedEditor: { noteID, authoritativeBody in
                self.reloads.append(ReloadCall(noteID: noteID, authoritativeBody: authoritativeBody))
                return self.reloadResult
            },
            currentEditorBody: { self.currentEditorBody }
        )
    }
}
