import AnchoredSequenceCore
import Foundation
import XCTest
@testable import MyRAMMac

final class SyncBatchTransportAdmissionPlannerTests: XCTestCase {
    func testDurableAdmissionMatrix() {
        XCTAssertEqual(
            SyncBatchTransportAdmissionPlanner.durableAdmission(
                representation: .none,
                activationEnabled: false
            ),
            .admitV1
        )
        XCTAssertEqual(
            SyncBatchTransportAdmissionPlanner.durableAdmission(
                representation: .legacy,
                activationEnabled: false
            ),
            .admitV1
        )
        XCTAssertEqual(
            SyncBatchTransportAdmissionPlanner.durableAdmission(
                representation: .anchored,
                activationEnabled: false
            ),
            .reject(.anchoredPayloadDisabled)
        )
        XCTAssertEqual(
            SyncBatchTransportAdmissionPlanner.durableAdmission(
                representation: .anchored,
                activationEnabled: true
            ),
            .admitV2
        )
        XCTAssertEqual(
            SyncBatchTransportAdmissionPlanner.durableAdmission(
                representation: .mixed,
                activationEnabled: true
            ),
            .reject(.mixedBodyOperationRepresentations)
        )
    }

    func testV1RoutingBroadcastsEveryConnectedEntry() {
        XCTAssertEqual(
            SyncBatchTransportAdmissionPlanner.outboundRouting(
                representation: .legacy,
                activationEnabled: false,
                connectedPeers: []
            ),
            .withhold(.noConnectedPeers)
        )
        XCTAssertEqual(
            SyncBatchTransportAdmissionPlanner.outboundRouting(
                representation: .legacy,
                activationEnabled: false,
                connectedPeers: [peer(index: 0), peer(index: 1)]
            ),
            .sendToAllConnectedPeers
        )
    }

    func testV2RoutingMatrix() {
        XCTAssertEqual(
            SyncBatchTransportAdmissionPlanner.outboundRouting(
                representation: .anchored,
                activationEnabled: false,
                connectedPeers: [peer(index: 0, supportsV2: true)]
            ),
            .withhold(.anchoredPayloadDisabled)
        )
        XCTAssertEqual(
            SyncBatchTransportAdmissionPlanner.outboundRouting(
                representation: .anchored,
                activationEnabled: true,
                connectedPeers: []
            ),
            .withhold(.noConnectedPeers)
        )
        XCTAssertEqual(
            SyncBatchTransportAdmissionPlanner.outboundRouting(
                representation: .anchored,
                activationEnabled: true,
                connectedPeers: [peer(index: 0), peer(index: 1)]
            ),
            .withhold(.requiresExactlyOneConnectedPeer)
        )
        XCTAssertEqual(
            SyncBatchTransportAdmissionPlanner.outboundRouting(
                representation: .anchored,
                activationEnabled: true,
                connectedPeers: [
                    peer(index: 0, deviceID: "duplicate", supportsV2: true),
                    peer(index: 1, deviceID: "duplicate", supportsV2: true)
                ]
            ),
            .withhold(.requiresExactlyOneConnectedPeer)
        )
        XCTAssertEqual(
            SyncBatchTransportAdmissionPlanner.outboundRouting(
                representation: .anchored,
                activationEnabled: true,
                connectedPeers: [peer(index: 0)]
            ),
            .withhold(.peerLacksExplicitCurrentSessionV2Support)
        )
        XCTAssertEqual(
            SyncBatchTransportAdmissionPlanner.outboundRouting(
                representation: .anchored,
                activationEnabled: true,
                connectedPeers: [peer(index: 0, supportsV2: true)]
            ),
            .sendToPeer(transportIndex: 0)
        )
    }

    func testMixedRoutingIsWithheld() {
        XCTAssertEqual(
            SyncBatchTransportAdmissionPlanner.outboundRouting(
                representation: .mixed,
                activationEnabled: true,
                connectedPeers: [peer(index: 0, supportsV2: true)]
            ),
            .withhold(.mixedBodyOperationRepresentations)
        )
    }

    func testInboundAdmissionMatrix() {
        XCTAssertEqual(
            SyncBatchTransportAdmissionPlanner.inboundAdmission(
                schemaVersion: .v1,
                activationEnabled: false,
                hasExplicitCurrentSessionV2Support: false
            ),
            .admitV1
        )
        XCTAssertEqual(
            SyncBatchTransportAdmissionPlanner.inboundAdmission(
                schemaVersion: .v2,
                activationEnabled: false,
                hasExplicitCurrentSessionV2Support: false
            ),
            .reject(.peerLacksExplicitCurrentSessionV2Support)
        )
        XCTAssertEqual(
            SyncBatchTransportAdmissionPlanner.inboundAdmission(
                schemaVersion: .v2,
                activationEnabled: false,
                hasExplicitCurrentSessionV2Support: true
            ),
            .reject(.anchoredPayloadDisabled)
        )
        XCTAssertEqual(
            SyncBatchTransportAdmissionPlanner.inboundAdmission(
                schemaVersion: .v2,
                activationEnabled: true,
                hasExplicitCurrentSessionV2Support: true
            ),
            .admitV2
        )
    }

    private func peer(
        index: Int,
        deviceID: String? = nil,
        supportsV2: Bool = false
    ) -> SyncBatchTransportPeer {
        SyncBatchTransportPeer(
            transportIndex: index,
            stableDeviceID: deviceID ?? "peer-\(index)",
            hasExplicitCurrentSessionV2Support: supportsV2
        )
    }
}

final class SyncBatchAnchoredBootstrapConflictCoverageTests: XCTestCase {
    private let noteID = UUID(
        uuidString: "17710000-0000-0000-0000-000000000001"
    )!
    private let deviceID = UUID(
        uuidString: "17710000-0000-0000-0000-000000000002"
    )!
    private let modifiedAt = Date(timeIntervalSince1970: 1_771)

    func testDifferentBootstrapAgainstEstablishedBootstrapCreatesConflict() throws {
        let establishedBootstrap = try bootstrapChange(body: "A")
        guard case .bootstrap(let establishedValue) = establishedBootstrap else {
            return XCTFail("Expected established bootstrap change")
        }
        let establishedState = try establishedValue.makeDescriptor().state
        let incomingBootstrap = try bootstrapChange(body: "B")

        let plan = try SyncBatchAnchoredRecoveryPlanner.planInitialDelivery(
            change: incomingBootstrap,
            foundation: .established(establishedState),
            recoverySnapshot: emptyRecoverySnapshot()
        )

        XCTAssertEqual(plan.finalFoundation, .established(establishedState))
        XCTAssertFalse(plan.didChangeApplicationState)
        XCTAssertTrue(plan.structurallyAvailableOperationIDs.isEmpty)
        guard case .insertExpectedAbsent(let record) = plan.recoveryStoreTransitions.first,
              case .bootstrapContentConflict(let conflict) = record.lifecycle else {
            return XCTFail("Expected bootstrap-content conflict")
        }
        XCTAssertEqual(record.change, incomingBootstrap)
        XCTAssertEqual(conflict.reason, .nonEquivalentEstablishedState)
        XCTAssertEqual(
            try conflict.establishedState.makeValidatedSequenceState(),
            establishedState
        )
    }

    func testLateBootstrapAfterOrdinaryEditCreatesConflict() throws {
        let bootstrap = try bootstrapChange(body: "A")
        guard case .bootstrap(let bootstrapValue) = bootstrap else {
            return XCTFail("Expected bootstrap change")
        }
        let bootstrapState = try bootstrapValue.makeDescriptor().state
        let edit = try insertionChange(
            state: bootstrapState,
            offset: 1,
            text: "B",
            counter: 110
        )
        let editedState = try SyncBatchAnchoredRecoveryReplay.apply(
            edit,
            to: bootstrapState
        )

        let plan = try SyncBatchAnchoredRecoveryPlanner.planInitialDelivery(
            change: bootstrap,
            foundation: .established(editedState),
            recoverySnapshot: emptyRecoverySnapshot()
        )

        XCTAssertEqual(plan.finalFoundation, .established(editedState))
        XCTAssertEqual(plan.visibleText, "AB")
        XCTAssertFalse(plan.didChangeApplicationState)
        XCTAssertTrue(plan.structurallyAvailableOperationIDs.isEmpty)
        guard case .insertExpectedAbsent(let record) = plan.recoveryStoreTransitions.first,
              case .bootstrapContentConflict(let conflict) = record.lifecycle else {
            return XCTFail("Expected late-bootstrap content conflict")
        }
        XCTAssertEqual(record.change, bootstrap)
        XCTAssertEqual(conflict.reason, .nonEquivalentEstablishedState)
        XCTAssertEqual(
            try conflict.establishedState.makeValidatedSequenceState(),
            editedState
        )
    }

    private func bootstrapChange(body: String) throws -> SyncBatchAnchoredRecoveryChange {
        .bootstrap(
            try SyncBatchAnchoredBootstrapChange(
                noteID: noteID,
                body: body,
                formatVersion: .v1
            )
        )
    }

    private func insertionChange(
        state: SyncTextSequenceState,
        offset: Int,
        text: String,
        counter: UInt64
    ) throws -> SyncBatchAnchoredRecoveryChange {
        let batchChange = try SyncBatchAnchoredPayloadAdapter.makeInsertedChange(
            noteID: noteID,
            utf16Offset: offset,
            text: text,
            modifiedAt: modifiedAt,
            baseContentHash: nil,
            operationID: SyncOperationID(
                deviceID: deviceID,
                localCounter: counter
            ),
            state: state
        )
        guard case .noteBodyTextInsertedAnchored(let change) = batchChange else {
            throw CoverageError.unexpectedChange
        }
        return .insertion(change)
    }

    private func emptyRecoverySnapshot() -> SyncBatchAnchoredRecoveryStoreSnapshot {
        SyncBatchAnchoredRecoveryStoreSnapshot(records: [], health: .healthy)
    }

    private enum CoverageError: Error {
        case unexpectedChange
    }
}
