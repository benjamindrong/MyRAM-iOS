import Foundation
import MultipeerConnectivity
import UIKit

enum MyRAMDeviceIdentity {
    private static let deviceIDKey = "myram.sync.deviceID"

    static func currentDeviceID() -> String {
        if let existing = UserDefaults.standard.string(forKey: deviceIDKey) {
            return existing
        }

        let created = UUID().uuidString
        UserDefaults.standard.set(created, forKey: deviceIDKey)
        return created
    }

    static func currentDisplayName() -> String {
        UIDevice.current.name
    }
}

struct MyRAMPeerIdentity {
    let displayName: String
    let deviceID: String

    init(peerID: MCPeerID) {
        let parts = peerID.displayName.split(separator: "|", maxSplits: 1).map(String.init)
        displayName = parts.first ?? peerID.displayName
        deviceID = parts.count > 1 ? parts[1] : peerID.displayName
    }
}

struct MyRAMDiscoveredPeer: Identifiable {
    let peerID: MCPeerID
    let deviceID: String
    let displayName: String
    var isTrusted: Bool

    var id: String { deviceID }
}

