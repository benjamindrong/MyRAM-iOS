import SwiftUI
import SwiftData
import NearbySyncCore
@preconcurrency import MultipeerConnectivity
import XCTest
@testable import MyRAMMac

private func makeMYR184TestConflictStore() -> SyncConflictStore {
    SyncConflictStore(
        fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("conflicts.json")
    )
}

extension MacLegacySyncReceiver {
    convenience init(
        context: ModelContext,
        appliedStore: MacLegacyAppliedChangeStoring = FileBackedMacLegacyAppliedChangeStore(),
        performSave: (() throws -> Void)? = nil
    ) {
        self.init(
            context: context,
            conflictStore: makeMYR184TestConflictStore(),
            appliedStore: appliedStore,
            performSave: performSave
        )
    }
}

extension MacSyncBatchController {
    convenience init(
        context: ModelContext,
        unsentBatchQueueFileURL: URL? = nil,
        unsentBatchQueue: FileBackedSyncBatchQueue? = nil,
        startsNetworking: Bool = true,
        identityProvider: () -> MacSyncDeviceIdentity = { MacSyncDeviceIdentityProvider().currentIdentity() },
        legacyReceiver: MacLegacySyncReceiver? = nil,
        startAdvertisingOperation: (() -> Void)? = nil,
        startBrowsingOperation: (() -> Void)? = nil,
        connectedPeersProvider: (() -> [MCPeerID])? = nil,
        sendBatchDataOperation: ((Data, [MCPeerID], MCSessionSendDataMode) throws -> Void)? = nil,
        invitePeerOperation: ((MCPeerID, Data, TimeInterval) -> Void)? = nil
    ) {
        self.init(
            context: context,
            conflictStore: makeMYR184TestConflictStore(),
            unsentBatchQueueFileURL: unsentBatchQueueFileURL,
            unsentBatchQueue: unsentBatchQueue,
            startsNetworking: startsNetworking,
            identityProvider: identityProvider,
            legacyReceiver: legacyReceiver,
            startAdvertisingOperation: startAdvertisingOperation,
            startBrowsingOperation: startBrowsingOperation,
            connectedPeersProvider: connectedPeersProvider,
            sendBatchDataOperation: sendBatchDataOperation,
            invitePeerOperation: invitePeerOperation
        )
    }
}

extension MacSyncConvergenceCoordinator {
    convenience init(
        context: ModelContext,
        syncController: MacSyncBatchController,
        presentationSurface: MacSyncConvergencePresentationSurface,
        incomingBoundarySurface: MacSyncIncomingLocalBoundarySurface,
        pendingIncomingQueueFileURL: URL? = SyncBatchQueueFileLocation.pendingIncoming(for: .nativeMac),
        localObligationQueueFileURL: URL? = SyncBatchQueueFileLocation.pendingLocalConvergence(for: .nativeMac)
    ) {
        self.init(
            context: context,
            syncController: syncController,
            conflictStore: makeMYR184TestConflictStore(),
            presentationSurface: presentationSurface,
            incomingBoundarySurface: incomingBoundarySurface,
            pendingIncomingQueueFileURL: pendingIncomingQueueFileURL,
            localObligationQueueFileURL: localObligationQueueFileURL
        )
    }
}

@MainActor
final class MYR184MacSyncConflictTests: XCTestCase {
    func testNativeMacConflictSurfaceConstructsWithSharedStore() {
        let store = makeMYR184TestConflictStore()
        _ = MacSyncConflictSummaryView(store: store) { _, _ in }
        XCTAssertTrue(store.activeConflicts().isEmpty)
    }

    func testNativeMacControllerRetainsCanonicalSharedStore() throws {
        let store = makeMYR184TestConflictStore()
        let container = try ModelContainer(
            for: Schema(MyRAMModelRegistry.models),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let controller = MacSyncBatchController(
            context: ModelContext(container),
            conflictStore: store,
            startsNetworking: false
        )

        XCTAssertTrue(controller.conflictStore === store)
    }
}
