import Foundation
@preconcurrency import MultipeerConnectivity
import NearbySyncCore
import XCTest
@testable import MyRAM

@MainActor
final class MYR184SyncConflictResolutionTests: XCTestCase {
    func testDeferredResolutionExactRedeliveryIsIdempotentAndContradictionFailsClosed() throws {
        let store = makeStore()
        let id = UUID(uuidString: "12345678-1234-8234-9234-123456789abc")!
        let first = conflict(id: id, remoteText: "winner", preservedAt: 10, expiresAt: 20)
        let redelivery = conflict(id: id, remoteText: "winner", preservedAt: 30, expiresAt: 40)

        try store.persistDeferredRemoteLifecycleResolutionChecked(first)
        let afterFirst = try store.snapshot().lifecycle
        try store.persistDeferredRemoteLifecycleResolutionChecked(redelivery)
        XCTAssertEqual(try store.snapshot().lifecycle, afterFirst)

        XCTAssertThrowsError(
            try store.persistDeferredRemoteLifecycleResolutionChecked(
                conflict(id: id, remoteText: "contradiction", preservedAt: 30, expiresAt: 40)
            )
        )
        XCTAssertEqual(try store.snapshot().lifecycle, afterFirst)
    }

    func testMalformedVersion8ResolutionFailsClosed() throws {
        let id = UUID(uuidString: "12345678-1234-8234-9234-123456789abc")!
        let missingNote = conflict(
            id: id,
            remoteText: "winner",
            preservedAt: 10,
            expiresAt: 20,
            noteID: nil
        )
        XCTAssertThrowsError(
            try SyncDeferredRemoteLifecycleResolution(conflict: missingNote, receivedAt: Date()).validate()
        )

        for field in [SyncConflictField.folderTitle, .pinnedText] {
            let wrongField = conflict(
                id: id,
                remoteText: "winner",
                preservedAt: 10,
                expiresAt: 20,
                field: field
            )
            XCTAssertThrowsError(
                try SyncDeferredRemoteLifecycleResolution(conflict: wrongField, receivedAt: Date()).validate()
            )
        }
    }

#if DEBUG
    func testCheckedPublicationAlreadyOwningLeaseCompletesBeforeRecovery() async throws {
        let controller = makeController()
        let lifecycleConflict = conflict(
            id: UUID(uuidString: "12345678-1234-8234-9234-123456789abc")!,
            remoteText: "winner",
            preservedAt: 10,
            expiresAt: 20
        )
        let payload = MyRAMSyncConflictPayload(
            action: .resolved,
            conflict: lifecycleConflict,
            resolvedText: "winner",
            baseText: "local",
            updatedAt: Date(timeIntervalSince1970: 50)
        )

        controller.onCheckedPublicationLeaseAcquiredForTesting = {
            await controller.suspendOutboundForRecovery()
        }

        try await controller.publishConflictResolutionChecked(payload)
        let snapshot = await controller.legacyQueueSnapshot()
        let queued = try XCTUnwrap(snapshot.pendingChanges.first)

        XCTAssertEqual(snapshot.pendingChanges.count, 1)
        XCTAssertEqual(queued.entityType, .conflict)
        XCTAssertEqual(queued.entityID, lifecycleConflict.id.uuidString)
        XCTAssertEqual(try MyRAMSyncPayloadCoding.decodeSyncConflict(from: queued.payload), payload)

        controller.resumeOutboundAfterRecovery()
    }

    func testRecoveryOwningFirstRejectsCheckedPublicationBeforeQueueMutation() async throws {
        let controller = makeController()
        let lifecycleConflict = conflict(
            id: UUID(uuidString: "12345678-1234-8234-9234-123456789abc")!,
            remoteText: "winner",
            preservedAt: 10,
            expiresAt: 20
        )
        let payload = MyRAMSyncConflictPayload(
            action: .resolved,
            conflict: lifecycleConflict,
            resolvedText: "winner",
            baseText: "local",
            updatedAt: Date(timeIntervalSince1970: 50)
        )

        controller.suspendOutboundForRecovery()
        do {
            try await controller.publishConflictResolutionChecked(payload)
            XCTFail("publication must fail while recovery owns the exclusion boundary")
        } catch {
            XCTAssertEqual(error as? CheckedConflictPublicationError, .recoveryInProgress)
        }

        let snapshot = await controller.legacyQueueSnapshot()
        XCTAssertTrue(snapshot.pendingChanges.isEmpty)
        controller.resumeOutboundAfterRecovery()
    }
#endif

    private func makeStore() -> SyncConflictStore {
        SyncConflictStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
                .appendingPathComponent("conflicts.json")
        )
    }

    private func makeController() -> MyRAMSyncController {
        MyRAMSyncController(
            unsentBatchQueueFileURL: nil,
            pendingChangesFileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
                .appendingPathComponent("pending.json"),
            startsNetworking: false,
            transport: MYR184NoopSyncTransport()
        )
    }

    private func conflict(
        id: UUID,
        remoteText: String,
        preservedAt: TimeInterval,
        expiresAt: TimeInterval,
        noteID: UUID? = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!,
        field: SyncConflictField = .noteContent
    ) -> SyncConflictVersion {
        let entityID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        return SyncConflictVersion(
            id: id,
            entityType: .note,
            entityID: entityID,
            noteID: noteID,
            field: field,
            localText: "local",
            remoteText: remoteText,
            remoteModifiedAt: Date(timeIntervalSince1970: 5),
            preservedAt: Date(timeIntervalSince1970: preservedAt),
            expiresAt: Date(timeIntervalSince1970: expiresAt)
        )
    }
}

private final class MYR184NoopSyncTransport: MyRAMSyncTransporting {
    func invite(_ peerID: MCPeerID, context: Data, timeout: TimeInterval) {}

    func connectedPeers() async -> [MCPeerID] {
        []
    }

    func send(
        _ data: Data,
        toPeers peers: [MCPeerID],
        mode: MCSessionSendDataMode
    ) async throws {}
}
