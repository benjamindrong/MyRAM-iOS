import Foundation

enum SyncBatchDeliveryRepresentation: Equatable, Sendable {
    case v1Compatible
    case anchoredV2
    case structuralMarkV3
    case invalidMixedRepresentation
}

enum SyncBatchDeliveryPartitionPlanner {
    static func classification(
        of changes: [SyncBatchChange]
    ) -> SyncBatchDeliveryRepresentation {
        var sawStructuralMarks = false
        var sawNonStructuralMarks = false
        var sawLegacyBody = false
        var sawAnchoredBody = false

        for change in changes {
            if case .noteStructuralMarksChanged = change {
                sawStructuralMarks = true
                continue
            }
            sawNonStructuralMarks = true
            switch change.bodyOperationRepresentation {
            case .none:
                break
            case .legacy:
                sawLegacyBody = true
            case .anchored:
                sawAnchoredBody = true
            case .mixed:
                return .invalidMixedRepresentation
            }
        }

        if sawStructuralMarks && sawNonStructuralMarks {
            return .invalidMixedRepresentation
        }
        if sawStructuralMarks {
            return .structuralMarkV3
        }
        if sawLegacyBody && sawAnchoredBody {
            return .invalidMixedRepresentation
        }
        if sawAnchoredBody {
            return .anchoredV2
        }
        return .v1Compatible
    }

    static func partition(
        _ capturedChanges: [SyncConvergenceCapturedLocalChange]
    ) -> (
        compatible: [SyncConvergenceCapturedLocalChange],
        structuralMarks: [SyncConvergenceCapturedLocalChange]
    )? {
        var compatible: [SyncConvergenceCapturedLocalChange] = []
        var structuralMarks: [SyncConvergenceCapturedLocalChange] = []

        for captured in capturedChanges {
            if case .noteStructuralMarksChanged = captured.change {
                structuralMarks.append(captured)
            } else {
                compatible.append(captured)
            }
        }

        guard classification(of: compatible.map(\.change)) != .invalidMixedRepresentation else {
            return nil
        }
        return (compatible, structuralMarks)
    }
}

enum SyncBatchDurableAdmissionDecision: Equatable, Sendable {
    enum RejectionReason: Equatable, Sendable {
        case anchoredPayloadDisabled
        case structuralMarkPayloadDisabled
        case mixedBodyOperationRepresentations
    }

    case admitV1
    case admitV2
    case admitV3
    case reject(RejectionReason)
}

struct SyncBatchTransportPeer: Equatable, Sendable {
    let transportIndex: Int
    let stableDeviceID: String
    let hasExplicitCurrentSessionV2Support: Bool
    let hasExplicitCurrentSessionStructuralMarkSupport: Bool

    init(
        transportIndex: Int,
        stableDeviceID: String,
        hasExplicitCurrentSessionV2Support: Bool,
        hasExplicitCurrentSessionStructuralMarkSupport: Bool = false
    ) {
        self.transportIndex = transportIndex
        self.stableDeviceID = stableDeviceID
        self.hasExplicitCurrentSessionV2Support = hasExplicitCurrentSessionV2Support
        self.hasExplicitCurrentSessionStructuralMarkSupport =
            hasExplicitCurrentSessionStructuralMarkSupport
    }
}

enum SyncBatchOutboundRoutingDecision: Equatable, Sendable {
    enum WithholdReason: Equatable, Sendable {
        case noConnectedPeers
        case anchoredPayloadDisabled
        case structuralMarkPayloadDisabled
        case requiresExactlyOneConnectedPeer
        case requiresExactlyOneStructuralMarkCapablePeer
        case peerLacksExplicitCurrentSessionV2Support
        case peerLacksExplicitCurrentSessionStructuralMarkSupport
        case mixedBodyOperationRepresentations
    }

    case sendToAllConnectedPeers
    case sendToPeer(transportIndex: Int)
    case withhold(WithholdReason)
}

enum SyncBatchInboundAdmissionDecision: Equatable, Sendable {
    enum RejectionReason: Equatable, Sendable {
        case peerLacksExplicitCurrentSessionV2Support
        case peerLacksExplicitCurrentSessionStructuralMarkSupport
        case anchoredPayloadDisabled
        case structuralMarkPayloadDisabled
    }

    case admitV1
    case admitV2
    case admitV3
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

    static func durableAdmission(
        deliveryRepresentation: SyncBatchDeliveryRepresentation,
        activationEnabled: Bool,
        structuralMarkEnabled: Bool = SyncStructuralMarkTransportCapability.isEnabled
    ) -> SyncBatchDurableAdmissionDecision {
        switch deliveryRepresentation {
        case .v1Compatible:
            return .admitV1
        case .anchoredV2 where activationEnabled:
            return .admitV2
        case .anchoredV2:
            return .reject(.anchoredPayloadDisabled)
        case .structuralMarkV3 where structuralMarkEnabled:
            return .admitV3
        case .structuralMarkV3:
            return .reject(.structuralMarkPayloadDisabled)
        case .invalidMixedRepresentation:
            return .reject(.mixedBodyOperationRepresentations)
        }
    }

    static func outboundRouting(
        representation: SyncBatchBodyOperationRepresentation,
        activationEnabled: Bool,
        connectedPeers: [SyncBatchTransportPeer]
    ) -> SyncBatchOutboundRoutingDecision {
        let deliveryRepresentation: SyncBatchDeliveryRepresentation
        switch representation {
        case .none, .legacy:
            deliveryRepresentation = .v1Compatible
        case .anchored:
            deliveryRepresentation = .anchoredV2
        case .mixed:
            deliveryRepresentation = .invalidMixedRepresentation
        }
        return outboundRouting(
            deliveryRepresentation: deliveryRepresentation,
            activationEnabled: activationEnabled,
            structuralMarkEnabled: false,
            connectedPeers: connectedPeers
        )
    }

    static func outboundRouting(
        deliveryRepresentation: SyncBatchDeliveryRepresentation,
        activationEnabled: Bool,
        structuralMarkEnabled: Bool = SyncStructuralMarkTransportCapability.isEnabled,
        connectedPeers: [SyncBatchTransportPeer]
    ) -> SyncBatchOutboundRoutingDecision {
        switch deliveryRepresentation {
        case .v1Compatible:
            guard !connectedPeers.isEmpty else {
                return .withhold(.noConnectedPeers)
            }
            return .sendToAllConnectedPeers

        case .anchoredV2:
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
                return .withhold(.peerLacksExplicitCurrentSessionV2Support)
            }
            return .sendToPeer(transportIndex: peer.transportIndex)

        case .structuralMarkV3:
            guard structuralMarkEnabled else {
                return .withhold(.structuralMarkPayloadDisabled)
            }
            guard !connectedPeers.isEmpty else {
                return .withhold(.noConnectedPeers)
            }
            let capablePeers = connectedPeers.filter(
                \.hasExplicitCurrentSessionStructuralMarkSupport
            )
            guard !capablePeers.isEmpty else {
                return .withhold(
                    .peerLacksExplicitCurrentSessionStructuralMarkSupport
                )
            }
            guard capablePeers.count == 1, let peer = capablePeers.first else {
                return .withhold(.requiresExactlyOneStructuralMarkCapablePeer)
            }
            return .sendToPeer(transportIndex: peer.transportIndex)

        case .invalidMixedRepresentation:
            return .withhold(.mixedBodyOperationRepresentations)
        }
    }

    static func inboundAdmission(
        schemaVersion: SyncBatchEnvelopeSchemaVersion,
        activationEnabled: Bool,
        hasExplicitCurrentSessionV2Support: Bool,
        hasExplicitCurrentSessionStructuralMarkSupport: Bool = false,
        structuralMarkEnabled: Bool = SyncStructuralMarkTransportCapability.isEnabled
    ) -> SyncBatchInboundAdmissionDecision {
        switch schemaVersion {
        case .v1:
            return .admitV1
        case .v2:
            guard hasExplicitCurrentSessionV2Support else {
                return .reject(.peerLacksExplicitCurrentSessionV2Support)
            }
            guard activationEnabled else {
                return .reject(.anchoredPayloadDisabled)
            }
            return .admitV2
        case .v3:
            guard hasExplicitCurrentSessionStructuralMarkSupport else {
                return .reject(
                    .peerLacksExplicitCurrentSessionStructuralMarkSupport
                )
            }
            guard structuralMarkEnabled else {
                return .reject(.structuralMarkPayloadDisabled)
            }
            return .admitV3
        }
    }
}
