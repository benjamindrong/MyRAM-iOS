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
