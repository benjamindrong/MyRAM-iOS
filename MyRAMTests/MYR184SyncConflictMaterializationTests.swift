import XCTest
@testable import MyRAM

final class MYR184SyncConflictMaterializationTests: XCTestCase {
    func testDeterministicIDsIgnoreReplicaSpecificCommittedResultDigest() throws {
        let first = try makeIntent(committedResultDigest: String(repeating: "1", count: 64))
        let second = try makeIntent(committedResultDigest: String(repeating: "2", count: 64))

        XCTAssertNotEqual(first.sourceIdentity, second.sourceIdentity)
        XCTAssertEqual(first.conflictID, second.conflictID)
        XCTAssertEqual(first.materializationID, second.materializationID)
        XCTAssertNotEqual(first.conflictID, first.materializationID)
    }

    func testMateriallyDifferentIdentityInputProducesDifferentIDs() throws {
        let first = try makeIntent(incomingText: "incoming")
        let second = try makeIntent(incomingText: "different")

        XCTAssertNotEqual(first.conflictID, second.conflictID)
        XCTAssertNotEqual(first.materializationID, second.materializationID)
    }

    func testPreparingVisibleResolvedOrderingAndTerminalNonRecreation() throws {
        let store = makeStore()
        let intent = try makeIntent()

        XCTAssertEqual(store.materializeLifecycleConflicts([intent], now: intent.preservedAt), .verifiedComplete)
        XCTAssertTrue(store.activeConflicts(now: intent.preservedAt).isEmpty)
        XCTAssertEqual(store.authorizeLifecyclePublication(sourceIdentity: intent.sourceIdentity), .verifiedComplete)
        XCTAssertEqual(store.activeConflicts(now: intent.preservedAt).map(\.id), [intent.conflictID])

        try store.markLifecycleResolvedChecked(id: intent.conflictID)
        XCTAssertTrue(store.activeConflicts(now: intent.preservedAt).isEmpty)
        XCTAssertEqual(store.materializeLifecycleConflicts([intent], now: intent.preservedAt), .verifiedComplete)
        XCTAssertTrue(store.activeConflicts(now: intent.preservedAt).isEmpty)
    }

    private func makeStore() -> SyncConflictStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        return SyncConflictStore(fileURL: directory.appendingPathComponent("conflicts.json"))
    }

    private func makeIntent(
        committedResultDigest: String = String(repeating: "b", count: 64),
        incomingText: String = "incoming"
    ) throws -> SyncLifecycleConflictIntent {
        let batchID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let deviceID = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
        let replay = CanonicalReplayKeyPayload(
            modifiedAtBitPattern: SyncConvergenceDateBits.bitPattern(for: Date(timeIntervalSince1970: 10)),
            originDeviceIDLowercase: deviceID.uuidString.lowercased(),
            batchOrderKind: .sequenced,
            legacyCreatedAtBitPattern: nil,
            sequence: 7,
            batchIDLowercase: batchID.uuidString.lowercased(),
            operationIndex: 0
        )
        let operation = OperationIdentityPayload(
            batchID: batchID,
            originDeviceID: deviceID,
            operationIndex: 0,
            operationKind: "fullBodyReplace",
            canonicalReplayKey: replay
        )
        let persisted = SyncConvergencePersistedIncorporationIdentity(
            batchID: batchID,
            canonicalPayloadDigest: String(repeating: "a", count: 64),
            canonicalPayloadDigestFormatVersion: 1,
            committedResultDigest: committedResultDigest,
            committedResultDigestFormatVersion: 1
        )
        return try SyncLifecycleConflictIntent(
            sourceIdentity: SyncLifecycleSourceIncorporationIdentity(persisted),
            lifecycleOperationIdentity: operation,
            noteID: UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!,
            field: .noteContent,
            localText: "local",
            localData: nil,
            incomingText: incomingText,
            incomingData: nil,
            incomingModifiedAt: Date(timeIntervalSince1970: 10),
            preservedAt: Date(timeIntervalSince1970: 20),
            expiresAt: Date(timeIntervalSince1970: 200)
        )
    }
}
