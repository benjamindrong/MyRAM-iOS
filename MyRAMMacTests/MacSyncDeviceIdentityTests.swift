import AnchoredSequenceCore
@preconcurrency import MultipeerConnectivity
import SwiftData
import XCTest
@testable import MyRAMMac

@MainActor
final class MacSyncTransportLifecycleTests: XCTestCase {
    @MainActor
    func testMYR233TerminalShutdownStopsDiscoveryBeforeDisconnectAndCannotRestart() throws {
        let container = try makeContainer()
        var events: [String] = []
        let controller = makeLifecycleController(container: container) { events.append($0) }
        controller.startNetworkingIfNeeded()
        controller.startNetworkingIfNeeded()
        controller.stopNetworking()
        controller.stopNetworking()
        controller.startNetworkingIfNeeded()
        XCTAssertEqual(events, ["advertise", "browse", "stopAdvertise", "stopBrowse", "disconnect"])
        XCTAssertFalse(controller.hasConnectedPeers)
    }

    @MainActor
    func testMYR233ShutdownBeforeStartupCannotOpenTransport() throws {
        let container = try makeContainer()
        var events: [String] = []
        let controller = makeLifecycleController(container: container) { events.append($0) }
        controller.stopNetworking()
        controller.startNetworkingIfNeeded()
        XCTAssertEqual(events, ["stopAdvertise", "stopBrowse", "disconnect"])
    }

    @MainActor
    func testMYR233QueuedDiscoveryAndInvitationCannotReopenRetiredOwner() async throws {
        let container = try makeContainer()
        var events: [String] = []
        let controller = makeLifecycleController(container: container) { events.append($0) }
        let local = MCPeerID(displayName: "local")
        let remote = MCPeerID(displayName: "remote|myr233-replacement")
        let browser = MCNearbyServiceBrowser(peer: local, serviceType: "myram-verify")
        let advertiser = MCNearbyServiceAdvertiser(peer: local, discoveryInfo: nil, serviceType: "myram-verify")
        let finished = expectation(description: "Queued invitation is rejected")
        controller.browser(browser, foundPeer: remote, withDiscoveryInfo: nil)
        controller.advertiser(advertiser, didReceiveInvitationFromPeer: remote, withContext: nil) { accepted, session in
            XCTAssertFalse(accepted)
            XCTAssertNil(session)
            finished.fulfill()
        }
        controller.stopNetworking()
        controller.invite(MacSyncDiscoveredPeer(peerID: remote, deviceID: "myr233-replacement", displayName: "remote"))
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertTrue(controller.availablePeers.isEmpty)
        XCTAssertEqual(events, ["stopAdvertise", "stopBrowse", "disconnect"])
        XCTAssertTrue(controller.unsentBatchQueueSnapshotForTesting().pendingBatches.isEmpty)
    }

    @MainActor
    func testMYR233RapidOwnerReplacementCannotReviveOldTransport() throws {
        let container = try makeContainer()
        var events: [String] = []
        let retired = makeLifecycleController(container: container) { events.append("old:" + $0) }
        retired.startNetworkingIfNeeded()
        retired.stopNetworking()
        let replacement = makeLifecycleController(container: container) { events.append("new:" + $0) }
        replacement.startNetworkingIfNeeded()
        retired.startNetworkingIfNeeded()
        replacement.startNetworkingIfNeeded()
        XCTAssertEqual(events, ["old:advertise", "old:browse", "old:stopAdvertise", "old:stopBrowse", "old:disconnect", "new:advertise", "new:browse"])
        replacement.stopNetworking()
    }

    func testMYR233DisconnectReconnectKeepsTheRunningOwner() async throws {
        let container = try makeContainer()
        var events: [String] = []
        let controller = makeLifecycleController(container: container) { events.append($0) }
        controller.startNetworkingIfNeeded()
        let local = MCPeerID(displayName: "local")
        let remote = MCPeerID(displayName: "remote|myr233-reconnect")
        let session = MCSession(peer: local, securityIdentity: nil, encryptionPreference: .required)
        controller.session(session, peer: remote, didChange: .notConnected)
        // Let the production delegate's main-actor hop finish before reconnecting.
        await Task.yield()
        controller.startNetworkingIfNeeded()
        controller.invite(MacSyncDiscoveredPeer(peerID: remote, deviceID: "myr233-reconnect", displayName: "remote"))
        XCTAssertEqual(events, ["advertise", "browse", "invite"])
        controller.stopNetworking()
    }

    func testMYR233TransportOnlyRetainsMPCAndPreservesPersistedQueue() async throws {
        let container = try makeContainer()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundlePath = directory.appendingPathComponent("Diagnostic.bundle")
        try FileManager.default.createDirectory(at: bundlePath, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.northsignalstudio.myram.mac.verification",
            "NSBonjourServices": ["_myram-verify._tcp"],
            MyRAMSyncRuntimeConfiguration.transportOnlyKey: true
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: bundlePath.appendingPathComponent("Info.plist"))
        let queueURL = directory.appendingPathComponent("unsent.json")
        let batch = SyncBatch(id: UUID(), originDeviceID: UUID(), createdAt: .now, changes: [])
        try FileBackedSyncBatchQueue(fileURL: queueURL).enqueueDurably(batch)
        let original = try Data(contentsOf: queueURL)
        let remote = MCPeerID(displayName: "remote|transport-only")
        var events: [String] = []
        let controller = MacSyncBatchController(
            context: container.mainContext,
            conflictStore: SyncConflictStore(fileURL: directory.appendingPathComponent("conflicts.json")),
            unsentBatchQueueFileURL: queueURL, startsNetworking: false,
            configurationBundle: try XCTUnwrap(Bundle(path: bundlePath.path)),
            identityProvider: { MacSyncDeviceIdentity(id: UUID(), displayName: "Transport test") },
            startAdvertisingOperation: { events.append("advertise") },
            startBrowsingOperation: { events.append("browse") },
            connectedPeersProvider: { [remote] },
            sendBatchDataOperation: { _, _, _ in XCTFail("Application send in transport-only mode") },
            invitePeerOperation: { _, _, _ in events.append("invite") }
        )
        XCTAssertFalse(controller.applicationSyncEnabled)
        controller.startNetworkingIfNeeded()
        controller.startNetworkingIfNeeded()
        // Invitation handling still belongs to the retained MPC session.
        let advertiser = MCNearbyServiceAdvertiser(peer: MCPeerID(displayName: "test"), discoveryInfo: nil, serviceType: "myram-verify")
        let invited = expectation(description: "Transport invitation accepted")
        controller.advertiser(advertiser, didReceiveInvitationFromPeer: remote, withContext: nil) { accepted, session in
            XCTAssertTrue(accepted)
            XCTAssertNotNil(session)
            invited.fulfill()
        }
        await fulfillment(of: [invited], timeout: 2)
        let session = MCSession(peer: MCPeerID(displayName: "local"), securityIdentity: nil, encryptionPreference: .required)
        controller.session(session, peer: remote, didChange: .connected)
        let data = try MultipeerSyncMessageCoding.encodeBatch(batch)
        controller.session(session, didReceive: data, fromPeer: remote)
        controller.flushPendingBatch()
        await controller.beginReconnectBootstrapForTesting(to: remote)
        await controller.resumeBootstrapAfterConflictResolution()
        do {
            try await controller.acceptLocalBatch(batch)
            XCTFail("Suppressed admission must not report success")
        } catch {
            XCTAssertTrue(error is MyRAMSyncRuntimeConfiguration.AdmissionError)
        }
        await Task.yield()
        XCTAssertEqual(events, ["advertise", "browse"])
        XCTAssertEqual(try Data(contentsOf: queueURL), original)
        XCTAssertNil(controller.bootstrapStateForTesting(peerDeviceID: "transport-only"))
        controller.stopNetworking()
    }

    @MainActor
    private func makeLifecycleController(
        container: ModelContainer, event: @escaping (String) -> Void
    ) -> MacSyncBatchController {
        MacSyncBatchController(
            context: container.mainContext,
            conflictStore: SyncConflictStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("MYR233-lifecycle-\(UUID().uuidString).json")),
            unsentBatchQueueFileURL: nil,
            startsNetworking: false,
            identityProvider: { MacSyncDeviceIdentity(id: UUID(), displayName: "Lifecycle test") },
            startAdvertisingOperation: { event("advertise") },
            startBrowsingOperation: { event("browse") },
            stopAdvertisingOperation: { event("stopAdvertise") },
            stopBrowsingOperation: { event("stopBrowse") },
            disconnectSessionOperation: { event("disconnect") },
            invitePeerOperation: { _, _, _ in event("invite") }
        )
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(MyRAMModelRegistry.models)
        let configuration = ModelConfiguration(
            "MYR233-lifecycle-\(UUID().uuidString)", schema: schema, isStoredInMemoryOnly: true
        )
        return try ModelContainer(for: schema, configurations: configuration)
    }
}

final class MacSyncDeviceIdentityTests: XCTestCase {
    func testMYR233ProductionCannotEnableTransportOnlyMode() throws {
        for id in ["com.northsignalstudio.myram", "com.northsignalstudio.myram.dev",
                   "com.northsignalstudio.myram.mac", "com.northsignalstudio.myram.mac.dev", "unknown"] {
            XCTAssertTrue(try MyRAMSyncRuntimeConfiguration(bundleIdentifier: id, bonjourServices: nil, transportOnlyValue: nil).applicationSyncEnabled)
            for value in [true, false] {
                XCTAssertThrowsError(try MyRAMSyncRuntimeConfiguration(bundleIdentifier: id, bonjourServices: ["_myram-verify._tcp"], transportOnlyValue: value))
            }
        }
    }

    func testMYR233TransportOnlyRequiresExactVerificationIdentityAndNamespace() throws {
        for id in MyRAMSyncRuntimeConfiguration.verificationBundleIDs {
            let mode = try MyRAMSyncRuntimeConfiguration(bundleIdentifier: id, bonjourServices: ["_myram-verify._tcp"], transportOnlyValue: true)
            XCTAssertFalse(mode.applicationSyncEnabled)
            XCTAssertThrowsError(try mode.requireApplicationSync())
            XCTAssertTrue(mode.recordsTransportDiagnostics)
            for namespace in [nil, ["_myram-sync._tcp"], ["_myram-verify._tcp", "_myram-sync._tcp"]] as [[String]?] {
                XCTAssertThrowsError(try MyRAMSyncRuntimeConfiguration(bundleIdentifier: id, bonjourServices: namespace, transportOnlyValue: true))
            }
            XCTAssertThrowsError(try MyRAMSyncRuntimeConfiguration(bundleIdentifier: id, bonjourServices: ["_myram-verify._tcp"], transportOnlyValue: "true"))
            let normal = try MyRAMSyncRuntimeConfiguration(bundleIdentifier: id, bonjourServices: ["_myram-verify._tcp"], transportOnlyValue: nil)
            XCTAssertTrue(normal.applicationSyncEnabled)
            XCTAssertTrue(normal.recordsTransportDiagnostics)
            XCTAssertNoThrow(try normal.requireApplicationSync())
        }
    }

    func testVerificationFixtureIdentityPersistsAndRebindsEveryProviderBeforePeerConstruction() throws {
        let defaults = makeDefaults()
        defaults.set(UUID().uuidString, forKey: MacSyncDeviceIdentity.deviceIDKey)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).bundle")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: path) }
        let fixtureID = UUID(uuidString: "5CF4DFED-1278-4D5C-BB0A-D63DC5866DC2")!
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.northsignalstudio.myram.mac.verification",
            "MyRAMVerificationFixtureDeviceID": fixtureID.uuidString
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: path.appendingPathComponent("Info.plist"))
        let bundle = try XCTUnwrap(Bundle(path: path.path))
        let first = MacSyncDeviceIdentityProvider(defaults: defaults, bundle: bundle).currentIdentity()
        XCTAssertEqual(first.id, fixtureID)
        XCTAssertEqual(defaults.string(forKey: MacSyncDeviceIdentity.deviceIDKey), fixtureID.uuidString)
        defaults.set(UUID().uuidString, forKey: MacSyncDeviceIdentity.deviceIDKey)
        let recreated = MacSyncDeviceIdentityProvider(defaults: defaults, bundle: bundle).currentIdentity()
        XCTAssertEqual(recreated.id, fixtureID)
        XCTAssertTrue(recreated.peerDisplayName.hasSuffix("|\(fixtureID.uuidString)"))
    }

    func testMacProductionBundleRejectsFixtureIdentityWithoutChangingExistingDefaults() {
        let defaults = makeDefaults()
        let existing = UUID().uuidString
        defaults.set(existing, forKey: MacSyncDeviceIdentity.deviceIDKey)
        for bundleID in ["com.northsignalstudio.myram.mac", "com.northsignalstudio.myram.mac.dev"] {
            XCTAssertThrowsError(try MyRAMSyncDeviceIdentityStore.resolve(
                defaults: defaults, bundleIdentifier: bundleID, configuredDeviceID: UUID().uuidString
            ))
            XCTAssertEqual(defaults.string(forKey: MacSyncDeviceIdentity.deviceIDKey), existing)
        }
    }

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

@MainActor
final class MyRAMMacSyncBenchmarkProductionTelemetryTests: XCTestCase {
    func testControllerRecordsConnectionSendAndAcknowledgementLifecycle() async throws {
        let directory = try benchmarkDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = MyRAMSyncBenchmarkRecorder(
            enabled: true,
            platform: .macOS,
            deviceID: "local-mac",
            runID: "production-seam",
            outputDirectoryURL: directory
        )
        MyRAMSyncBenchmarkTelemetry.shared.replaceRecorderForTesting(recorder)
        defer { MyRAMSyncBenchmarkTelemetry.shared.replaceRecorderForTesting(nil) }

        let peer = MCPeerID(displayName: "Remote|telemetry-peer")
        let queueURL = directory.appendingPathComponent("unsent.json")
        let container = try makeContainer()
        var sends: [Data] = []
        let controller = MacSyncBatchController(
            context: container.mainContext,
            unsentBatchQueueFileURL: queueURL,
            startsNetworking: false,
            identityProvider: {
                MacSyncDeviceIdentity(
                    id: UUID(uuidString: "21800000-0000-0000-0000-000000000010")!,
                    displayName: "Telemetry Mac"
                )
            },
            connectedPeersProvider: { [peer] },
            sendBatchDataOperation: { data, _, _ in sends.append(data) }
        )
        controller.recordBootstrapCapabilityForTesting(nil, forPeerDeviceID: "telemetry-peer")
        let dummySession = MCSession(
            peer: MCPeerID(displayName: "Local|local-mac"),
            securityIdentity: nil,
            encryptionPreference: .required
        )
        controller.session(dummySession, peer: peer, didChange: .connecting)

        let batch = makeBatch(idSuffix: 2181)
        try await controller.acceptLocalBatch(batch)
        let acknowledgementData = try MultipeerSyncMessageCoding.encode(
            kind: .batchAcknowledgement,
            payload: JSONEncoder().encode(SyncBatchAcknowledgement(batchID: batch.id))
        )
        controller.session(dummySession, didReceive: acknowledgementData, fromPeer: peer)
        await waitUntil {
            FileBackedSyncBatchQueue(fileURL: queueURL).pendingBatches.isEmpty
        }

        let events = try events(from: recorder)
        let batchID = String(describing: batch.id)
        XCTAssertTrue(events.contains {
            $0.eventType == .peerConnectionState &&
            $0.peerDeviceID == "telemetry-peer" &&
            $0.outcome == "connecting"
        })
        XCTAssertTrue(events.contains {
            $0.eventType == .batchSendStarted &&
            $0.batchID == batchID &&
            $0.peerDeviceID == "telemetry-peer"
        })
        XCTAssertTrue(events.contains {
            $0.eventType == .batchSendSucceeded &&
            $0.batchID == batchID &&
            $0.peerDeviceID == "telemetry-peer"
        })
        XCTAssertTrue(events.contains {
            $0.eventType == .batchAcknowledgementReceived &&
            $0.batchID == batchID &&
            $0.peerDeviceID == "telemetry-peer"
        })
        XCTAssertTrue(events.contains {
            $0.eventType == .batchDequeued && $0.batchID == batchID
        })
        XCTAssertFalse(sends.isEmpty)
    }

    func testControllerRecordsInboundCaptureConvergenceAndAcknowledgement() async throws {
        let directory = try benchmarkDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = MyRAMSyncBenchmarkRecorder(
            enabled: true,
            platform: .macOS,
            deviceID: "local-mac",
            runID: "production-seam",
            outputDirectoryURL: directory
        )
        MyRAMSyncBenchmarkTelemetry.shared.replaceRecorderForTesting(recorder)
        defer { MyRAMSyncBenchmarkTelemetry.shared.replaceRecorderForTesting(nil) }

        let peer = MCPeerID(displayName: "Remote|inbound-peer")
        let container = try makeContainer()
        var sends: [Data] = []
        let controller = MacSyncBatchController(
            context: container.mainContext,
            unsentBatchQueueFileURL: directory.appendingPathComponent("unsent-inbound.json"),
            startsNetworking: false,
            identityProvider: {
                MacSyncDeviceIdentity(
                    id: UUID(uuidString: "21800000-0000-0000-0000-000000000012")!,
                    displayName: "Telemetry Mac"
                )
            },
            connectedPeersProvider: { [peer] },
            sendBatchDataOperation: { data, _, _ in sends.append(data) }
        )
        let coordinator = MacSyncConvergenceCoordinator(
            context: container.mainContext,
            syncController: controller,
            presentationSurface: MacSyncConvergencePresentationSurface(
                selectedNoteID: { nil },
                hasUnsavedChanges: { false },
                refreshNotesList: {},
                closeRemovedSelectedEditor: { _ in },
                applyIncremental: { _, _, _ in
                    EditorRemoteBatchApplyResult(
                        appliedCount: 0,
                        disposition: .noApplicableMutations
                    )
                },
                reloadSelectedEditor: { _ in true },
                currentEditorBody: { nil }
            ),
            incomingBoundarySurface: MacSyncIncomingLocalBoundarySurface(
                prepareForIncomingBodyMutation: { _ in .ready }
            ),
            pendingIncomingQueueFileURL: directory.appendingPathComponent("pending-inbound.json"),
            localObligationQueueFileURL: directory.appendingPathComponent("obligations-inbound.json")
        )
        controller.recordBootstrapCapabilityForTesting(
            "1",
            forPeerDeviceID: "inbound-peer"
        )
        let note = Note(title: "Telemetry fixture", content: "")
        note.id = UUID(uuidString: "21800000-0000-0000-0000-000000000030")!
        container.mainContext.insert(note)
        try container.mainContext.save()
        let batch = SyncBatch(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000002183")!,
            originDeviceID: UUID(uuidString: "21800000-0000-0000-0000-000000000020")!,
            createdAt: Date(timeIntervalSince1970: 2_183),
            changes: [
                .noteBodyTextInserted(.init(
                    noteID: note.id,
                    utf16Offset: 0,
                    text: "A",
                    modifiedAt: Date(timeIntervalSince1970: 2_183),
                    baseContentHash: SyncBatchContentHash.sha256Hex(for: "")
                ))
            ]
        )
        let data = try MultipeerSyncMessageCoding.encodeBatch(batch)
        let dummySession = MCSession(
            peer: MCPeerID(displayName: "Local|local-mac"),
            securityIdentity: nil,
            encryptionPreference: .required
        )

        controller.session(dummySession, didReceive: data, fromPeer: peer)
        await waitUntil { !sends.isEmpty }

        let acknowledgementData = try XCTUnwrap(sends.first)
        let acknowledgementMessage = try MultipeerSyncMessageCoding.decodeMessage(
            from: acknowledgementData
        )
        XCTAssertEqual(acknowledgementMessage.kind, .batchAcknowledgement)
        XCTAssertEqual(
            try JSONDecoder().decode(
                SyncBatchAcknowledgement.self,
                from: acknowledgementMessage.payload
            ).batchID,
            batch.id
        )

        let batchID = String(describing: batch.id)
        let lifecycle = try events(from: recorder).filter {
            $0.batchID == batchID && $0.peerDeviceID == "inbound-peer"
        }
        XCTAssertEqual(
            lifecycle.map(\.eventType),
            [
                .batchReceived,
                .batchCaptureCompleted,
                .batchConvergenceCompleted,
                .batchAcknowledgementSent,
            ]
        )
        XCTAssertEqual(
            lifecycle.map(\.outcome),
            [nil, "captured", "acknowledgementPermitted", nil]
        )
        XCTAssertEqual(coordinator.pendingIncomingBatchCount, 0)
    }

    func testControllerDefersPermittedAcknowledgementUntilPeerReconnects() async throws {
        let directory = try benchmarkDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = MyRAMSyncBenchmarkRecorder(
            enabled: true,
            platform: .macOS,
            deviceID: "local-mac",
            runID: "ack-reconnect",
            outputDirectoryURL: directory
        )
        MyRAMSyncBenchmarkTelemetry.shared.replaceRecorderForTesting(recorder)
        defer { MyRAMSyncBenchmarkTelemetry.shared.replaceRecorderForTesting(nil) }

        let peer = MCPeerID(displayName: "Remote|ack-reconnect-peer")
        let container = try makeContainer()
        var connectedPeers: [MCPeerID] = []
        var sends: [Data] = []
        let controller = MacSyncBatchController(
            context: container.mainContext,
            unsentBatchQueueFileURL: directory.appendingPathComponent("unsent-ack-reconnect.json"),
            startsNetworking: false,
            identityProvider: {
                MacSyncDeviceIdentity(
                    id: UUID(uuidString: "23000000-0000-0000-0000-000000000012")!,
                    displayName: "Telemetry Mac"
                )
            },
            connectedPeersProvider: { connectedPeers },
            sendBatchDataOperation: { data, _, _ in sends.append(data) }
        )
        let coordinator = MacSyncConvergenceCoordinator(
            context: container.mainContext,
            syncController: controller,
            presentationSurface: MacSyncConvergencePresentationSurface(
                selectedNoteID: { nil },
                hasUnsavedChanges: { false },
                refreshNotesList: {},
                closeRemovedSelectedEditor: { _ in },
                applyIncremental: { _, _, _ in
                    EditorRemoteBatchApplyResult(
                        appliedCount: 0,
                        disposition: .noApplicableMutations
                    )
                },
                reloadSelectedEditor: { _ in true },
                currentEditorBody: { nil }
            ),
            incomingBoundarySurface: MacSyncIncomingLocalBoundarySurface(
                prepareForIncomingBodyMutation: { _ in .ready }
            ),
            pendingIncomingQueueFileURL: directory.appendingPathComponent("pending-ack-reconnect.json"),
            localObligationQueueFileURL: directory.appendingPathComponent("obligations-ack-reconnect.json")
        )
        _ = coordinator
        let note = Note(title: "ACK reconnect fixture", content: "")
        note.id = UUID(uuidString: "23000000-0000-0000-0000-000000000030")!
        container.mainContext.insert(note)
        try container.mainContext.save()
        let batch = SyncBatch(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000002301")!,
            originDeviceID: UUID(uuidString: "23000000-0000-0000-0000-000000000020")!,
            createdAt: Date(timeIntervalSince1970: 2_301),
            changes: [
                .noteBodyTextInserted(.init(
                    noteID: note.id,
                    utf16Offset: 0,
                    text: "A",
                    modifiedAt: Date(timeIntervalSince1970: 2_301),
                    baseContentHash: SyncBatchContentHash.sha256Hex(for: "")
                ))
            ]
        )
        let data = try MultipeerSyncMessageCoding.encodeBatch(batch)
        let dummySession = MCSession(
            peer: MCPeerID(displayName: "Local|local-mac"),
            securityIdentity: nil,
            encryptionPreference: .required
        )

        controller.session(dummySession, didReceive: data, fromPeer: peer)
        let batchID = String(describing: batch.id)
        await waitUntil {
            guard let recordedEvents = try? self.events(from: recorder) else { return false }
            return recordedEvents.contains {
                $0.eventType == .batchAcknowledgementDeferred &&
                $0.batchID == batchID &&
                $0.peerDeviceID == "ack-reconnect-peer" &&
                $0.outcome == "peerNotConnected"
            }
        }
        XCTAssertTrue(sends.isEmpty)
        XCTAssertFalse(try events(from: recorder).contains {
            $0.eventType == .batchAcknowledgementSendFailed && $0.batchID == batchID
        })

        connectedPeers = [peer]
        controller.session(dummySession, peer: peer, didChange: .connected)
        await waitUntil {
            sends.contains { data in
                (try? MultipeerSyncMessageCoding.decodeMessage(from: data).kind)
                    == .batchAcknowledgement
            }
        }

        let acknowledgements = try sends.compactMap { data -> SyncBatchAcknowledgement? in
            let message = try MultipeerSyncMessageCoding.decodeMessage(from: data)
            guard message.kind == .batchAcknowledgement else { return nil }
            return try JSONDecoder().decode(SyncBatchAcknowledgement.self, from: message.payload)
        }
        XCTAssertEqual(acknowledgements, [SyncBatchAcknowledgement(batchID: batch.id)])
        let finalEvents = try events(from: recorder)
        XCTAssertTrue(finalEvents.contains {
            $0.eventType == .batchAcknowledgementSent &&
            $0.batchID == batchID &&
            $0.peerDeviceID == "ack-reconnect-peer"
        })
        XCTAssertFalse(finalEvents.contains {
            $0.eventType == .batchAcknowledgementSendFailed && $0.batchID == batchID
        })
    }

    func testControllerRecordsTransportFailureWithoutSuccess() async throws {
        let directory = try benchmarkDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = MyRAMSyncBenchmarkRecorder(
            enabled: true,
            platform: .macOS,
            deviceID: "local-mac",
            outputDirectoryURL: directory
        )
        MyRAMSyncBenchmarkTelemetry.shared.replaceRecorderForTesting(recorder)
        defer { MyRAMSyncBenchmarkTelemetry.shared.replaceRecorderForTesting(nil) }

        let peer = MCPeerID(displayName: "Remote|failing-peer")
        let container = try makeContainer()
        let controller = MacSyncBatchController(
            context: container.mainContext,
            unsentBatchQueueFileURL: directory.appendingPathComponent("unsent-failure.json"),
            startsNetworking: false,
            identityProvider: {
                MacSyncDeviceIdentity(
                    id: UUID(uuidString: "21800000-0000-0000-0000-000000000011")!,
                    displayName: "Telemetry Mac"
                )
            },
            connectedPeersProvider: { [peer] },
            sendBatchDataOperation: { _, _, _ in throw TelemetryTestError.injected }
        )
        controller.recordBootstrapCapabilityForTesting(nil, forPeerDeviceID: "failing-peer")
        let batch = makeBatch(idSuffix: 2182)

        try await controller.acceptLocalBatch(batch)

        let events = try events(from: recorder)
        let batchID = String(describing: batch.id)
        XCTAssertTrue(events.contains {
            $0.eventType == .batchSendStarted && $0.batchID == batchID
        })
        XCTAssertTrue(events.contains {
            $0.eventType == .batchSendFailed && $0.batchID == batchID
        })
        XCTAssertFalse(events.contains {
            $0.eventType == .batchSendSucceeded && $0.batchID == batchID
        })
        XCTAssertEqual(
            FileBackedSyncBatchQueue(
                fileURL: directory.appendingPathComponent("unsent-failure.json")
            ).pendingBatches,
            [batch]
        )
    }

    private func makeBatch(idSuffix: Int) -> SyncBatch {
        SyncBatch(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", idSuffix))!,
            originDeviceID: UUID(uuidString: "21800000-0000-0000-0000-000000000020")!,
            createdAt: Date(timeIntervalSince1970: TimeInterval(idSuffix)),
            changes: []
        )
    }

    private func benchmarkDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MYR-218-Mac-production-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(MyRAMModelRegistry.models)
        let configuration = ModelConfiguration(
            "MYR-218-Mac-production-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        return try ModelContainer(for: schema, configurations: configuration)
    }

    private func events(
        from recorder: MyRAMSyncBenchmarkRecorder
    ) throws -> [MyRAMSyncBenchmarkEvent] {
        MyRAMSyncBenchmarkTelemetry.shared.flushForTesting()
        let artifactURL = try XCTUnwrap(recorder.artifactURL)
        let data = try Data(contentsOf: artifactURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try data.split(separator: 0x0A).map {
            try decoder.decode(MyRAMSyncBenchmarkEvent.self, from: Data($0))
        }
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            await Task.yield()
        }
    }

    private enum TelemetryTestError: Error {
        case injected
    }
}
