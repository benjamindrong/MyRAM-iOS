import Foundation
import MultipeerConnectivity
import UIKit

enum MyRAMDeviceIdentity {
    private static let deviceIDKey = "myram.sync.deviceID"
    static let maximumPeerDisplayNameUTF8ByteCount = 63

    static func currentDeviceID() -> String {
        if let existing = UserDefaults.standard.string(forKey: deviceIDKey),
           let existingID = UUID(uuidString: existing) {
            return existingID.uuidString
        }

        let created = UUID().uuidString
        UserDefaults.standard.set(created, forKey: deviceIDKey)
        return created
    }

    static func currentDisplayName() -> String {
        boundedDisplayName(
            UIDevice.current.name,
            deviceID: currentDeviceID()
        )
    }

    static func boundedDisplayName(_ displayName: String, deviceID: String) -> String {
        let suffixByteCount = "|\(deviceID)".utf8.count
        let prefixByteBudget = max(
            0,
            maximumPeerDisplayNameUTF8ByteCount - suffixByteCount
        )
        let fallback = "iPhone"
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedDisplayName = trimmed.isEmpty ? fallback : trimmed
        let boundedDisplayName = resolvedDisplayName.prefixFittingUTF8ByteCount(prefixByteBudget)
        if !boundedDisplayName.isEmpty {
            return boundedDisplayName
        }
        return fallback.prefixFittingUTF8ByteCount(prefixByteBudget)
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

private extension String {
    func prefixFittingUTF8ByteCount(_ maximumByteCount: Int) -> String {
        guard maximumByteCount > 0 else { return "" }

        var result = ""
        var byteCount = 0
        for character in self {
            let characterByteCount = String(character).utf8.count
            guard byteCount + characterByteCount <= maximumByteCount else { break }
            result.append(character)
            byteCount += characterByteCount
        }
        return result
    }
}
