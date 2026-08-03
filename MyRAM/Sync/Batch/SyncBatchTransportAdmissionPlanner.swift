import Foundation

enum SyncBatchDurableAdmissionDecision: Equatable, Sendable {
    enum RejectionReason: Equatable, Sendable {
        case anchoredPayloadDisabled
        case mixedBodyOperationRepresentations
    }

    case admitV1
    case admitV2
    case reject(RejectionReason)
}

struct SyncBatchTransportPeer: Equatable, Sendable {
    let transportIndex: Int
    let stableDeviceID: String
    let hasExplicitCurrentSessionV2Support: Bool
}

enum SyncBatchOutboundRoutingDecision: Equatable, Sendable {
    enum WithholdReason: Equatable, Sendable {
        case noConnectedPeers
        case anchoredPayloadDisabled
        case requiresExactlyOneConnectedPeer
        case peerLacksExplicitCurrentSessionV2Support
        case mixedBodyOperationRepresentations
    }

    case sendToAllConnectedPeers
    case sendToPeer(transportIndex: Int)
    case withhold(WithholdReason)
}

enum SyncBatchInboundAdmissionDecision: Equatable, Sendable {
    enum RejectionReason: Equatable, Sendable {
        case peerLacksExplicitCurrentSessionV2Support
        case anchoredPayloadDisabled
    }

    case admitV1
    case admitV2
    case reject(RejectionReason)
}

enum SyncBatchTransportAdmissionPlanner {
    static func durableAdmission(
        representation: SyncBatchBodyOperationRepresentation,
        activationEnabled: Bool
    ) -> SyncBatchDurableAdmissionDecision {
        switch representation {
        case .none, .legacy:
            return .admitV1
        case .anchored where activationEnabled:
            return .admitV2
        case .anchored:
            return .reject(.anchoredPayloadDisabled)
        case .mixed:
            return .reject(.mixedBodyOperationRepresentations)
        }
    }

    static func outboundRouting(
        representation: SyncBatchBodyOperationRepresentation,
        activationEnabled: Bool,
        connectedPeers: [SyncBatchTransportPeer]
    ) -> SyncBatchOutboundRoutingDecision {
        switch representation {
        case .none, .legacy:
            guard !connectedPeers.isEmpty else {
                return .withhold(.noConnectedPeers)
            }
            return .sendToAllConnectedPeers

        case .anchored:
            guard activationEnabled else {
                return .withhold(.anchoredPayloadDisabled)
            }
            guard !connectedPeers.isEmpty else {
                return .withhold(.noConnectedPeers)
            }
            guard connectedPeers.count == 1 else {
                return .withhold(.requiresExactlyOneConnectedPeer)
            }
            guard let peer = connectedPeers.first,
                  peer.hasExplicitCurrentSessionV2Support else {
                return .withhold(
                    .peerLacksExplicitCurrentSessionV2Support
                )
            }
            return .sendToPeer(transportIndex: peer.transportIndex)

        case .mixed:
            return .withhold(.mixedBodyOperationRepresentations)
        }
    }

    static func inboundAdmission(
        schemaVersion: SyncBatchEnvelopeSchemaVersion,
        activationEnabled: Bool,
        hasExplicitCurrentSessionV2Support: Bool
    ) -> SyncBatchInboundAdmissionDecision {
        switch schemaVersion {
        case .v1:
            return .admitV1
        case .v2:
            guard hasExplicitCurrentSessionV2Support else {
                return .reject(
                    .peerLacksExplicitCurrentSessionV2Support
                )
            }
            guard activationEnabled else {
                return .reject(.anchoredPayloadDisabled)
            }
            return .admitV2
        }
    }
}
