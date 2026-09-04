import SwiftData
import XCTest
@testable import MyRAM

@MainActor
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
        let differentIncoming = try makeIntent(incomingText: "different")
        let differentLocal = try makeIntent(localText: "different-local")

        XCTAssertNotEqual(first.conflictID, differentIncoming.conflictID)
        XCTAssertNotEqual(first.materializationID, differentIncoming.materializationID)
        XCTAssertNotEqual(first.conflictID, differentLocal.conflictID)
        XCTAssertNotEqual(first.materializationID, differentLocal.materializationID)
    }

    func testPreparingVisibleResolvedOrderingAndTerminalNonRecreation() throws {
        let store = makeStore()
        let intent = try makeIntent()

        XCTAssertEqual(store.materializeLifecycleConflicts([intent], now: intent.preservedAt), .verifiedComplete)
        XCTAssertTrue(store.activeConflicts(now: intent.preservedAt).isEmpty)
        XCTAssertEqual(store.authorizeLifecyclePublication([intent]), .verifiedComplete)
        XCTAssertEqual(store.activeConflicts(now: intent.preservedAt).map(\.id), [intent.conflictID])

        try store.markLifecycleResolvedChecked(id: intent.conflictID)
        XCTAssertTrue(store.activeConflicts(now: intent.preservedAt).isEmpty)
        XCTAssertEqual(store.materializeLifecycleConflicts([intent], now: intent.preservedAt), .verifiedComplete)
        XCTAssertTrue(store.activeConflicts(now: intent.preservedAt).isEmpty)
    }

    func testPublicationFailsClosedWhenExpectedLifecycleStateIsMissing() throws {
        let store = makeStore()
        let intent = try makeIntent()

        XCTAssertEqual(store.authorizeLifecyclePublication([intent]), .failed)
        XCTAssertTrue(store.activeConflicts(now: intent.preservedAt).isEmpty)
    }

    func testPublicationFailsClosedUntilEveryExpectedFieldReceiptExists() throws {
        let store = makeStore()
        let body = try makeIntent(field: .noteContent)
        let title = try makeIntent(
            field: .noteTitle,
            localText: "local title",
            incomingText: "incoming title"
        )

        XCTAssertEqual(store.materializeLifecycleConflicts([body], now: body.preservedAt), .verifiedComplete)
        XCTAssertEqual(store.authorizeLifecyclePublication([body, title]), .failed)
        XCTAssertTrue(store.activeConflicts(now: body.preservedAt).isEmpty)

        XCTAssertEqual(store.materializeLifecycleConflicts([title], now: title.preservedAt), .verifiedComplete)
        XCTAssertEqual(store.authorizeLifecyclePublication([body, title]), .verifiedComplete)
        XCTAssertEqual(Set(store.activeConflicts(now: body.preservedAt).map(\.id)), Set([body.conflictID, title.conflictID]))
    }

    func testPreparingCrashWindowsRetrySameIntentWithoutPrematureVisibility() throws {
        for failedWrite in [2, 3] {
            let probe = MYR184LifecycleFileIOProbe(failOnWrite: failedWrite)
            let store = makeStore(fileIO: probe.fileIO)
            let intent = try makeIntent()

            XCTAssertEqual(store.materializeLifecycleConflicts([intent], now: intent.preservedAt), .failed)
            XCTAssertTrue(store.activeConflicts(now: intent.preservedAt).isEmpty)

            probe.failOnWrite = nil
            XCTAssertEqual(store.materializeLifecycleConflicts([intent], now: intent.preservedAt), .verifiedComplete)
            XCTAssertTrue(store.activeConflicts(now: intent.preservedAt).isEmpty)
            XCTAssertEqual(store.authorizeLifecyclePublication([intent]), .verifiedComplete)
            XCTAssertEqual(store.activeConflicts(now: intent.preservedAt).map(\.id), [intent.conflictID])
        }
    }

    func testContradictoryVisibleReceiptFailsClosed() throws {
        let store = makeStore()
        let intent = try makeIntent()
        XCTAssertEqual(store.materializeLifecycleConflicts([intent], now: intent.preservedAt), .verifiedComplete)

        let snapshot = try store.snapshot()
        guard case .present(let lifecycleData) = snapshot.lifecycle,
              var json = String(data: lifecycleData, encoding: .utf8) else {
            return XCTFail("expected persisted lifecycle state")
        }
        XCTAssertTrue(json.contains("\"visible\""))
        json = json.replacingOccurrences(of: "\"visible\"", with: "\"resolved\"")
        try store.restore(SyncConflictStoreSnapshot(
            textConflicts: snapshot.textConflicts,
            baselines: snapshot.baselines,
            lifecycle: .present(Data(json.utf8))
        ))

        XCTAssertEqual(store.authorizeLifecyclePublication([intent]), .failed)
        XCTAssertTrue(store.activeConflicts(now: intent.preservedAt).isEmpty)
    }

    func testPublishedLifecycleConflictIgnoresStaleCachedConflictList() throws {
        let store = makeStore()
        let intent = try makeIntent()
        let container = try ModelContainer(
            for: Schema(MyRAMModelRegistry.models),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let note = Note(title: "Local", content: "local")
        note.id = intent.identity.noteID
        context.insert(note)
        try context.save()
        let service = MyRAMSyncConflictService(context: context, store: store)

        XCTAssertEqual(store.materializeLifecycleConflicts([intent], now: intent.preservedAt), .verifiedComplete)
        XCTAssertTrue(service.activeConflicts(for: note, in: []).isEmpty)

        XCTAssertEqual(store.authorizeLifecyclePublication([intent]), .verifiedComplete)
        XCTAssertEqual(service.activeConflicts(for: note, in: []).map(\.id), [intent.conflictID])
    }

    private func makeStore(fileIO: SyncConflictStore.FileIO = .live) -> SyncConflictStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        return SyncConflictStore(
            fileURL: directory.appendingPathComponent("conflicts.json"),
            fileIO: fileIO
        )
    }

    private func makeIntent(
        committedResultDigest: String = String(repeating: "b", count: 64),
        field: SyncConflictField = .noteContent,
        localText: String = "local",
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
            field: field,
            localText: localText,
            localData: nil,
            incomingText: incomingText,
            incomingData: nil,
            incomingModifiedAt: Date(timeIntervalSince1970: 10),
            preservedAt: Date(timeIntervalSince1970: 3_999_996_400),
            expiresAt: Date(timeIntervalSince1970: 4_000_000_000)
        )
    }
}

private final class MYR184LifecycleFileIOProbe {
    var failOnWrite: Int?
    private var writeCount = 0
    private var dataByPath: [String: Data] = [:]

    init(failOnWrite: Int?) {
        self.failOnWrite = failOnWrite
    }

    lazy var fileIO = SyncConflictStore.FileIO(
        fileExists: { [weak self] path in
            self?.dataByPath[path] != nil
        },
        readData: { [weak self] url in
            guard let data = self?.dataByPath[url.path] else {
                throw CocoaError(.fileNoSuchFile)
            }
            return data
        },
        createDirectory: { _ in },
        writeData: { [weak self] data, url in
            guard let self else { throw CocoaError(.fileWriteUnknown) }
            writeCount += 1
            if failOnWrite == writeCount {
                throw CocoaError(.fileWriteUnknown)
            }
            dataByPath[url.path] = data
        },
        removeItem: { [weak self] url in
            self?.dataByPath.removeValue(forKey: url.path)
        }
    )
}
