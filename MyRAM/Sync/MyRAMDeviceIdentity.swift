import Foundation
import MultipeerConnectivity
import UIKit

enum MyRAMSyncBenchmarkEnduranceIOSIsolation {
    static func activateOrFailIfRequested(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) {
        guard MyRAMSyncBenchmarkConfiguration.isEnduranceRequested(environment: environment) else {
            return
        }

        guard case .valid(let launch) = MyRAMSyncBenchmarkConfiguration.enduranceLaunchValidation(
            environment: environment,
            arguments: arguments
        ) else {
            fatalError("Unsafe BEN-36 endurance launch rejected before MyRAM state initialization.")
        }

        let originalHome = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let isolatedHome = originalHome
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("MyRAMSyncEndurance", isDirectory: true)
            .appendingPathComponent(safePathComponent(launch.runID), isDirectory: true)
            .appendingPathComponent("Home", isDirectory: true)

        do {
            try FileManager.default.createDirectory(
                at: isolatedHome,
                withIntermediateDirectories: true
            )
        } catch {
            fatalError("Unable to create the isolated BEN-36 iOS home: \(error.localizedDescription)")
        }

        setenv("HOME", isolatedHome.path, 1)
        setenv("CFFIXED_USER_HOME", isolatedHome.path, 1)

        guard let supportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first,
              isDescendant(supportDirectory, of: isolatedHome) else {
            fatalError("BEN-36 iOS endurance home isolation could not be verified.")
        }

        print("[MyRAM Sync Endurance] isolated iOS home: \(isolatedHome.path)")
    }

    private static func safePathComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let mapped = value.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(String(scalar)) : "_"
        }
        let result = String(mapped)
        return result.isEmpty ? "unnamed-run" : result
    }

    private static func isDescendant(_ candidate: URL, of parent: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let parentPath = parent.standardizedFileURL.path
        return candidatePath == parentPath || candidatePath.hasPrefix(parentPath + "/")
    }
}

enum MyRAMDeviceIdentity {
    private static let deviceIDKey = "myram.sync.deviceID"
    private static let enduranceDeviceID = "B3600000-0000-0000-0000-000000000001"
    static let maximumPeerDisplayNameUTF8ByteCount = 63

    static func currentDeviceID() -> String {
        let deviceID: String
        if MyRAMSyncBenchmarkConfiguration.enduranceLaunch() != nil {
            deviceID = enduranceDeviceID
        } else if let existing = UserDefaults.standard.string(forKey: deviceIDKey),
                  UUID(uuidString: existing) != nil {
            deviceID = existing
        } else {
            let created = UUID().uuidString
            UserDefaults.standard.set(created, forKey: deviceIDKey)
            deviceID = created
        }

        MyRAMSyncBenchmarkTelemetry.shared.configure(
            platform: .iOS,
            deviceID: deviceID
        )
        return deviceID
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
        MyRAMSyncBenchmarkTelemetry.shared.record(
            .peerObserved,
            peerDeviceID: deviceID
        )
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
