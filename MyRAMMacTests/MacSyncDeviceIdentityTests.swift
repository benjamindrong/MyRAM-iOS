import AnchoredSequenceCore
import XCTest
@testable import MyRAMMac

final class MacSyncDeviceIdentityTests: XCTestCase {
    func testCurrentIdentityReusesExistingStableDeviceIDKey() {
        let defaults = makeDefaults()
        let existingID = UUID(uuidString: "00000000-0000-0000-0000-000000000123")!
        defaults.set(existingID.uuidString, forKey: MacSyncDeviceIdentity.deviceIDKey)

        let identity = MacSyncDeviceIdentityProvider(
            defaults: defaults,
            hostNameProvider: { "Test Mac" },
            uuidProvider: { UUID(uuidString: "00000000-0000-0000-0000-000000000999")! }
        ).currentIdentity()

        XCTAssertEqual(MacSyncDeviceIdentity.deviceIDKey, "myram.sync.deviceID")
        XCTAssertEqual(identity.id, existingID)
        XCTAssertEqual(identity.displayName, "Test Mac")
    }

    func testCurrentIdentityCreatesAndStoresDeviceIDWhenMissing() {
        let defaults = makeDefaults()
        let generatedID = UUID(uuidString: "00000000-0000-0000-0000-000000000456")!

        let identity = MacSyncDeviceIdentityProvider(
            defaults: defaults,
            hostNameProvider: { nil },
            uuidProvider: { generatedID }
        ).currentIdentity()

        XCTAssertEqual(identity.id, generatedID)
        XCTAssertEqual(identity.displayName, "Mac")
        XCTAssertEqual(defaults.string(forKey: MacSyncDeviceIdentity.deviceIDKey), generatedID.uuidString)
    }

    func testPeerDisplayNamePreservesShortNameAndFullUUID() {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000123")!
        let identity = MacSyncDeviceIdentity(id: id, displayName: "Test Mac")

        XCTAssertEqual(identity.peerDisplayName, "Test Mac|\(id.uuidString)")
        XCTAssertEqual(
            String(identity.peerDisplayName.split(separator: "|", maxSplits: 1).last ?? ""),
            id.uuidString
        )
    }

    func testPeerDisplayNameAcceptsExactUTF8BoundaryWithoutShortening() {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000123")!
        let name = String(repeating: "A", count: 26)
        let identity = MacSyncDeviceIdentity(id: id, displayName: name)

        XCTAssertEqual(identity.peerDisplayName, "\(name)|\(id.uuidString)")
        XCTAssertEqual(
            identity.peerDisplayName.utf8.count,
            MacSyncDeviceIdentity.maximumPeerDisplayNameUTF8ByteCount
        )
    }

    func testPeerDisplayNameBoundsLongASCIINameWithoutChangingUUID() {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000123")!
        let identity = MacSyncDeviceIdentity(
            id: id,
            displayName: String(repeating: "A", count: 100)
        )

        XCTAssertEqual(identity.peerDisplayName, "\(String(repeating: "A", count: 26))|\(id.uuidString)")
        XCTAssertLessThanOrEqual(
            identity.peerDisplayName.utf8.count,
            MacSyncDeviceIdentity.maximumPeerDisplayNameUTF8ByteCount
        )
        XCTAssertTrue(identity.peerDisplayName.hasSuffix("|\(id.uuidString)"))
    }

    func testPeerDisplayNameBoundsLongMultibyteNameAtCharacterBoundary() {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000123")!
        let identity = MacSyncDeviceIdentity(
            id: id,
            displayName: String(repeating: "é", count: 100)
        )

        XCTAssertEqual(identity.peerDisplayName, "\(String(repeating: "é", count: 13))|\(id.uuidString)")
        XCTAssertLessThanOrEqual(
            identity.peerDisplayName.utf8.count,
            MacSyncDeviceIdentity.maximumPeerDisplayNameUTF8ByteCount
        )
        XCTAssertTrue(identity.peerDisplayName.hasSuffix("|\(id.uuidString)"))
    }

    func testCurrentIdentityWhitespaceOnlyHostNameUsesSafeMacFallback() {
        let defaults = makeDefaults()
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000123")!
        let identity = MacSyncDeviceIdentityProvider(
            defaults: defaults,
            hostNameProvider: { "  \n\t " },
            uuidProvider: { id }
        ).currentIdentity()

        XCTAssertEqual(identity.displayName, "Mac")
        XCTAssertEqual(identity.peerDisplayName, "Mac|\(id.uuidString)")
        XCTAssertLessThanOrEqual(
            identity.peerDisplayName.utf8.count,
            MacSyncDeviceIdentity.maximumPeerDisplayNameUTF8ByteCount
        )
    }

    func testPeerDisplayNameFallsBackWhenFirstHostCharacterCannotFit() {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000123")!
        let oversizedCharacter = "a" + String(repeating: "\u{0301}", count: 20)
        let identity = MacSyncDeviceIdentity(id: id, displayName: oversizedCharacter)

        XCTAssertEqual(oversizedCharacter.count, 1)
        XCTAssertGreaterThan(oversizedCharacter.utf8.count, 26)
        XCTAssertEqual(identity.peerDisplayName, "Mac|\(id.uuidString)")
        XCTAssertLessThanOrEqual(
            identity.peerDisplayName.utf8.count,
            MacSyncDeviceIdentity.maximumPeerDisplayNameUTF8ByteCount
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "MacSyncDeviceIdentityTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

final class MYR180DeterministicTwoReplicaAcceptanceTests: XCTestCase {
    private let noteID = UUID(uuidString: "18020000-0000-0000-0000-000000000001")!
    private let macDeviceID = UUID(uuidString: "18020000-0000-0000-0000-000000000002")!
    private let simulatorDeviceID = UUID(uuidString: "18020000-0000-0000-0000-000000000003")!

    private var goneOperationID: SyncOperationID {
        SyncOperationID(deviceID: macDeviceID, localCounter: 1)
    }

    private var hahaOperationID: SyncOperationID {
        SyncOperationID(deviceID: simulatorDeviceID, localCounter: 2)
    }

    func testGONEHAHAOfflineEditsConvergeAcrossTransportArrivalOrderAndPersistenceRestart() throws {
        let baseState = SyncTextSequenceState.empty
        let goneBatch = try makeBatch(
            id: UUID(uuidString: "18020000-0000-0000-0000-000000000010")!,
            deviceID: macDeviceID,
            operationID: goneOperationID,
            text: "GONE",
            createdAt: Date(timeIntervalSince1970: 1_800)
        )
        let hahaBatch = try makeBatch(
            id: UUID(uuidString: "18020000-0000-0000-0000-000000000011")!,
            deviceID: simulatorDeviceID,
            operationID: hahaOperationID,
            text: "HAHA",
            createdAt: Date(timeIntervalSince1970: 1_801)
        )

        XCTAssertTrue(SyncBatchAnchoredPayloadCapability.isEnabled)

        let transportedGone = try transportRoundTrip(goneBatch)
        let transportedHaha = try transportRoundTrip(hahaBatch)
        let gone = try anchoredInsert(from: transportedGone)
        let haha = try anchoredInsert(from: transportedHaha)

        XCTAssertEqual(gone.payload.operationID, goneOperationID)
        XCTAssertEqual(haha.payload.operationID, hahaOperationID)
        XCTAssertEqual(gone.payload.anchor.kind, .empty)
        XCTAssertEqual(haha.payload.anchor.kind, .empty)

        let macLocal = try SyncBatchAnchoredInsertReplay.applying(gone, to: baseState)
        let simulatorLocal = try SyncBatchAnchoredInsertReplay.applying(haha, to: baseState)
        XCTAssertEqual(macLocal.visibleText, "GONE")
        XCTAssertEqual(simulatorLocal.visibleText, "HAHA")

        let macConverged = try SyncBatchAnchoredInsertReplay.applying(
            haha,
            to: macLocal.sequenceState
        )
        let simulatorConverged = try SyncBatchAnchoredInsertReplay.applying(
            gone,
            to: simulatorLocal.sequenceState
        )

        let frozenExpectedBody = "HAHAGONE"
        XCTAssertEqual(macConverged.visibleText, frozenExpectedBody)
        XCTAssertEqual(simulatorConverged.visibleText, frozenExpectedBody)
        XCTAssertEqual(macConverged.sequenceState, simulatorConverged.sequenceState)
        XCTAssertEqual(macConverged.sequenceState.visibleUTF16Count, frozenExpectedBody.utf16.count)
        XCTAssertEqual(macConverged.sequenceState.tombstonedUTF16Count, 0)
        XCTAssertEqual(macConverged.sequenceState.runs.count, 2)
        XCTAssertEqual(macConverged.sequenceState.fragments.count, 2)
        XCTAssertTrue(macConverged.sequenceState.runs.map(\.operationID).contains(goneOperationID))
        XCTAssertTrue(macConverged.sequenceState.runs.map(\.operationID).contains(hahaOperationID))

        let macPersisted = try persistedPayload(for: macConverged.sequenceState)
        let simulatorPersisted = try persistedPayload(for: simulatorConverged.sequenceState)
        XCTAssertEqual(macPersisted, simulatorPersisted)

        let macReloaded = try reload(macPersisted, expectedState: macConverged.sequenceState)
        let simulatorReloaded = try reload(
            simulatorPersisted,
            expectedState: simulatorConverged.sequenceState
        )
        XCTAssertEqual(macReloaded, simulatorReloaded)
        XCTAssertEqual(macReloaded.visibleText, frozenExpectedBody)
        XCTAssertEqual(macReloaded.visibleUTF16Count, frozenExpectedBody.utf16.count)
        XCTAssertEqual(macReloaded.tombstonedUTF16Count, 0)
    }

    private func makeBatch(
        id: UUID,
        deviceID: UUID,
        operationID: SyncOperationID,
        text: String,
        createdAt: Date
    ) throws -> SyncBatch {
        let change = try SyncBatchAnchoredPayloadAdapter.makeInsertedChange(
            noteID: noteID,
            utf16Offset: 0,
            text: text,
            modifiedAt: createdAt,
            baseContentHash: SyncBatchContentHash.sha256Hex(for: ""),
            operationID: operationID,
            state: .empty
        )
        return SyncBatch(
            id: id,
            originDeviceID: deviceID,
            createdAt: createdAt,
            batchSequence: 1,
            changes: [change]
        )
    }

    private func transportRoundTrip(_ batch: SyncBatch) throws -> SyncBatch {
        let wireData = try MultipeerSyncMessageCoding.encodeBatch(batch)
        let outer = try MultipeerSyncMessageCoding.decodeMessage(from: wireData)
        XCTAssertEqual(outer.kind, .batchSync)
        XCTAssertTrue(outer.canDecodeWithCurrentSchema)
        let inner = try MultipeerSyncMessageCoding.decodeBatchPayload(outer.payload)
        XCTAssertEqual(inner.schemaVersion, .v2)
        XCTAssertEqual(inner.batch, batch)
        return inner.batch
    }

    private func anchoredInsert(
        from batch: SyncBatch
    ) throws -> SyncBatchNoteBodyTextInsertedAnchoredChange {
        guard batch.changes.count == 1,
              case .noteBodyTextInsertedAnchored(let change) = batch.changes[0] else {
            throw AcceptanceError.expectedSingleAnchoredInsert
        }
        return change
    }

    private func persistedPayload(for state: SyncTextSequenceState) throws -> Data {
        try NoteSequenceStatePersistenceCodec.encode(state: state, noteID: noteID)
    }

    private func reload(
        _ payload: Data,
        expectedState: SyncTextSequenceState
    ) throws -> SyncTextSequenceState {
        let record = NoteSequenceStateRecord(
            noteID: noteID,
            formatVersion: NoteSequenceStatePersistenceCodec.formatVersion,
            revision: 2,
            visibleUTF16Count: expectedState.visibleUTF16Count,
            tombstonedUTF16Count: expectedState.tombstonedUTF16Count,
            payloadByteCount: payload.count,
            statePayloadData: payload
        )
        return try NoteSequenceStatePersistenceCodec.decodeStructurallyValidatedState(
            record: record,
            noteID: noteID
        )
    }

    private enum AcceptanceError: Error {
        case expectedSingleAnchoredInsert
    }
}

final class MyRAMMacSyncBenchmarkRecorderTests: XCTestCase {
    func testMacRecorderWritesMacPlatformSessionMetadata() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MYR-218-Mac-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let recorder = MyRAMSyncBenchmarkRecorder(
            enabled: true,
            platform: .macOS,
            deviceID: "mac-device",
            runID: "live-convergence-01",
            outputDirectoryURL: directory
        )
        recorder.record(.sessionStarted)
        recorder.flushForTesting()

        let artifactURL = try XCTUnwrap(recorder.artifactURL)
        let rawData = try Data(contentsOf: artifactURL)
        let line = try XCTUnwrap(rawData.split(separator: 0x0A).first)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let event = try decoder.decode(MyRAMSyncBenchmarkEvent.self, from: Data(line))

        XCTAssertEqual(event.platform, .macOS)
        XCTAssertEqual(event.deviceID, "mac-device")
        XCTAssertEqual(event.runID, "live-convergence-01")
        XCTAssertEqual(event.eventType, .sessionStarted)
    }
}
