import Foundation
@preconcurrency import MultipeerConnectivity

/// Owns the persistent identity used by peer discovery and durable sync obligations.
enum MyRAMSyncDeviceIdentityStore {
    static let deviceIDKey = "myram.sync.deviceID"
    static let verificationFixtureKey = "MyRAMVerificationFixtureDeviceID"
    static let transportPeerIDKey = "myram.sync.mpcPeerID"

    enum ConfigurationError: Error {
        case fixtureIdentityRequiresVerificationBundle
        case invalidFixtureIdentity
        case invalidTransportPeerArchive
    }

    /// MPC identity is opaque: recreating the same display name creates a different peer.
    /// Keep its archive in the same app-scoped defaults owner as the logical identity.
    static func currentPeerID(displayName: String, defaults: UserDefaults = .standard) -> MCPeerID {
        do {
            return try resolvePeerID(displayName: displayName, defaults: defaults)
        } catch {
            preconditionFailure("Invalid persistent MPC identity: \(error)")
        }
    }

    static func resolvePeerID(displayName: String, defaults: UserDefaults) throws -> MCPeerID {
        if let stored = defaults.object(forKey: transportPeerIDKey) {
            guard let archive = stored as? Data,
                  let peer = try NSKeyedUnarchiver.unarchivedObject(ofClass: MCPeerID.self, from: archive) else {
                throw ConfigurationError.invalidTransportPeerArchive
            }
            if peer.displayName == displayName { return peer }
        }
        let peer = MCPeerID(displayName: displayName)
        let archive = try NSKeyedArchiver.archivedData(withRootObject: peer, requiringSecureCoding: true)
        defaults.set(archive, forKey: transportPeerIDKey)
        return peer
    }

    static func currentID(
        defaults: UserDefaults = .standard,
        bundle: Bundle = .main,
        uuidProvider: () -> UUID = UUID.init
    ) -> String {
        do {
            return try resolve(
                defaults: defaults,
                bundleIdentifier: bundle.bundleIdentifier,
                configuredDeviceID: bundle.object(forInfoDictionaryKey: verificationFixtureKey),
                uuidProvider: uuidProvider
            )
        } catch {
            preconditionFailure("Invalid Verification sync identity configuration: \(error)")
        }
    }

    static func resolve(
        defaults: UserDefaults,
        bundleIdentifier: String?,
        configuredDeviceID: Any?,
        uuidProvider: () -> UUID = UUID.init
    ) throws -> String {
        if let configuredDeviceID {
            guard bundleIdentifier == "com.northsignalstudio.myram.verification"
                    || bundleIdentifier == "com.northsignalstudio.myram.mac.verification" else {
                throw ConfigurationError.fixtureIdentityRequiresVerificationBundle
            }
            guard let value = configuredDeviceID as? String, let fixtureID = UUID(uuidString: value) else {
                throw ConfigurationError.invalidFixtureIdentity
            }
            // Establish through the defaults owner before any peer/queue reader runs.
            // The generated app configuration remains authoritative after relaunch.
            if defaults.string(forKey: deviceIDKey) != fixtureID.uuidString {
                defaults.set(fixtureID.uuidString, forKey: deviceIDKey)
            }
            return fixtureID.uuidString
        }

        if let value = defaults.string(forKey: deviceIDKey), UUID(uuidString: value) != nil {
            return value
        }
        let created = uuidProvider()
        defaults.set(created.uuidString, forKey: deviceIDKey)
        return created.uuidString
    }
}
