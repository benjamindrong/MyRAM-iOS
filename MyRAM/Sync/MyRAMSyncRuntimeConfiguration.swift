import Foundation
import CryptoKit
@preconcurrency import MultipeerConnectivity

/// An immutable diagnostic mode belonging only to the isolated Verification apps.
/// Defaults/preferences and launch arguments cannot enable it in a production app.
struct MyRAMSyncRuntimeConfiguration {
    static let transportOnlyKey = "MyRAMVerificationTransportOnly"
    static let verificationBundleIDs: Set<String> = [
        "com.northsignalstudio.myram.verification",
        "com.northsignalstudio.myram.mac.verification"
    ]

    enum ConfigurationError: Error {
        case transportOnlyRequiresVerificationIdentity
        case invalidTransportOnlyValue
    }

    enum AdmissionError: Error { case applicationSyncDisabled }

    let applicationSyncEnabled: Bool
    let recordsTransportDiagnostics: Bool

    init(bundleIdentifier: String?, bonjourServices: [String]?, transportOnlyValue: Any?) throws {
        let isolated = Self.verificationBundleIDs.contains(bundleIdentifier ?? "")
            && bonjourServices == ["_myram-verify._tcp"]
        recordsTransportDiagnostics = isolated
        guard let transportOnlyValue else {
            applicationSyncEnabled = true
            return
        }
        guard isolated else {
            throw ConfigurationError.transportOnlyRequiresVerificationIdentity
        }
        guard let transportOnly = transportOnlyValue as? Bool else {
            throw ConfigurationError.invalidTransportOnlyValue
        }
        applicationSyncEnabled = !transportOnly
    }

    static func current(bundle: Bundle = .main) -> Self {
        do {
            return try Self(
                bundleIdentifier: bundle.bundleIdentifier,
                bonjourServices: bundle.object(forInfoDictionaryKey: "NSBonjourServices") as? [String],
                transportOnlyValue: bundle.object(forInfoDictionaryKey: transportOnlyKey)
            )
        } catch {
            preconditionFailure("Invalid Verification transport configuration: \(error)")
        }
    }

    func requireApplicationSync() throws {
        guard applicationSyncEnabled else { throw AdmissionError.applicationSyncDisabled }
    }
}

/// Logs the existing MPC owner; does not create or control a transport.
struct MyRAMSyncTransportDiagnostics {
    private let enabled: Bool
    private let mode: String
    private let incarnation = UUID().uuidString

    init(configuration: MyRAMSyncRuntimeConfiguration) {
        enabled = configuration.recordsTransportDiagnostics
        mode = configuration.applicationSyncEnabled ? "application" : "transportOnly"
    }

    func record(_ event: String, session: MCSession, peer: MCPeerID? = nil, detail: String? = nil) {
        guard enabled else { return }
        let value: [String: Any] = [
            "event": event, "mode": mode, "incarnation": incarnation,
            "session": String(describing: ObjectIdentifier(session)),
            "pid": ProcessInfo.processInfo.processIdentifier,
            "at": Date().timeIntervalSince1970,
            "local": identity(session.myPeerID),
            "peer": peer.map(identity) ?? "",
            "members": session.connectedPeers.map(identity).sorted(),
            "detail": detail ?? ""
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: .sortedKeys),
              let text = String(data: data, encoding: .utf8) else { return }
        NSLog("MYR233_TRANSPORT %@", text)
    }

    private func identity(_ peer: MCPeerID) -> String {
        guard let archive = try? NSKeyedArchiver.archivedData(withRootObject: peer, requiringSecureCoding: true) else {
            return "\(peer.displayName)#archive-unavailable"
        }
        let digest = SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()
        return "\(peer.displayName)#\(digest)"
    }
}
