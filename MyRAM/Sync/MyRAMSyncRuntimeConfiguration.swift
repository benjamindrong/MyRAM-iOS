import Foundation
import CryptoKit
@preconcurrency import MultipeerConnectivity

/// An immutable diagnostic mode belonging only to the isolated Verification apps.
/// Defaults/preferences and launch arguments cannot enable it in a production app.
struct MyRAMSyncRuntimeConfiguration {
    static let transportOnlyKey = "MyRAMVerificationTransportOnly"
    static let offlineRestoreKey = "MyRAMVerificationOfflineRestore"
    // A bundle may advertise only the service assigned to its registered verification profile.
    static let verificationServicesByBundleID: [String: String] = [
        "com.northsignalstudio.myram.verification": "myram-verify",
        "com.northsignalstudio.myram.mac.verification": "myram-verify",
        "com.northsignalstudio.myram.myr227.verification": "myr227-sync",
        "com.northsignalstudio.myram.mac.myr227.verification": "myr227-sync",
        "com.northsignalstudio.myram.myr227.test.verification": "myr227-test",
        "com.northsignalstudio.myram.mac.myr227.test.verification": "myr227-test"
    ]
    static let verificationBundleIDs = Set(verificationServicesByBundleID.keys)

    enum ConfigurationError: Error {
        case transportOnlyRequiresVerificationIdentity
        case invalidTransportOnlyValue
        case offlineRestoreRequiresVerificationIdentity
        case invalidOfflineRestoreValue
        case invalidVerificationNamespace
    }

    enum AdmissionError: Error { case applicationSyncDisabled }

    var allowsRetainedDeletedNoteInspection: Bool { recordsTransportDiagnostics }

    let applicationSyncEnabled: Bool
    let recordsTransportDiagnostics: Bool
    let verificationServiceType: String?
    let isOfflineRestoreVerification: Bool

    init(bundleIdentifier: String?, bonjourServices: [String]?, transportOnlyValue: Any?, offlineRestoreValue: Any? = nil) throws {
        let registeredService = Self.verificationServicesByBundleID[bundleIdentifier ?? ""]
        // An incomplete verification identity cannot silently use production networking.
        if let registeredService, bonjourServices != ["_\(registeredService)._tcp"] {
            throw ConfigurationError.invalidVerificationNamespace
        }
        let isolated = registeredService != nil
        verificationServiceType = registeredService
        recordsTransportDiagnostics = isolated
        if let offlineRestoreValue {
            guard isolated else { throw ConfigurationError.offlineRestoreRequiresVerificationIdentity }
            guard let offlineRestore = offlineRestoreValue as? Bool else {
                throw ConfigurationError.invalidOfflineRestoreValue
            }
            isOfflineRestoreVerification = offlineRestore
        } else {
            isOfflineRestoreVerification = false
        }
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
                transportOnlyValue: bundle.object(forInfoDictionaryKey: transportOnlyKey),
                offlineRestoreValue: bundle.object(forInfoDictionaryKey: offlineRestoreKey)
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
struct MyRAMSyncTransportDiagnostics: Sendable {
    private let enabled: Bool
    private let mode: String
    private let incarnation = UUID().uuidString

    init(configuration: MyRAMSyncRuntimeConfiguration) {
        enabled = configuration.recordsTransportDiagnostics
        mode = configuration.applicationSyncEnabled ? "application" : "transportOnly"
    }

    func record(_ event: String, session: MCSession? = nil, peer: MCPeerID? = nil, detail: String? = nil, owner: AnyObject? = nil, context: Data? = nil) {
        guard enabled else { return }
        let value: [String: Any] = [
            "event": event, "mode": mode, "incarnation": incarnation,
            "session": session.map { String(describing: ObjectIdentifier($0)) } ?? "",
            "owner": owner.map { String(describing: ObjectIdentifier($0)) } ?? "",
            "peerObject": peer.map { String(describing: ObjectIdentifier($0)) } ?? "",
            "contextSHA256": context.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? "",
            "pid": ProcessInfo.processInfo.processIdentifier,
            "at": Date().timeIntervalSince1970,
            "local": session.map { identity($0.myPeerID) } ?? "",
            "peer": peer.map(identity) ?? "",
            "members": session?.connectedPeers.map(identity).sorted() ?? [],
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
