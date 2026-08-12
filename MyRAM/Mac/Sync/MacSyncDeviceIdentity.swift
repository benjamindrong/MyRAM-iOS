#if os(macOS)
import Foundation

struct MacSyncDeviceIdentity: Equatable {
    static let deviceIDKey = "myram.sync.deviceID"
    static let maximumPeerDisplayNameUTF8ByteCount = 63

    let id: MacSyncDeviceID
    let displayName: String

    var peerDisplayName: String {
        let suffix = "|\(id.uuidString)"
        let prefixByteBudget = max(
            0,
            Self.maximumPeerDisplayNameUTF8ByteCount - suffix.utf8.count
        )
        let resolvedDisplayName =
            displayName.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Mac"
        let boundedDisplayName = resolvedDisplayName.prefixFittingUTF8ByteCount(prefixByteBudget)
        let prefix = boundedDisplayName.nilIfEmpty
            ?? "Mac".prefixFittingUTF8ByteCount(prefixByteBudget)

        return prefix + suffix
    }
}

struct MacSyncDeviceIdentityProvider {
    private let defaults: UserDefaults
    private let hostNameProvider: () -> String?
    private let uuidProvider: () -> UUID

    init(
        defaults: UserDefaults = .standard,
        hostNameProvider: @escaping () -> String? = { Host.current().localizedName },
        uuidProvider: @escaping () -> UUID = UUID.init
    ) {
        self.defaults = defaults
        self.hostNameProvider = hostNameProvider
        self.uuidProvider = uuidProvider
    }

    func currentIdentity() -> MacSyncDeviceIdentity {
        MacSyncDeviceIdentity(
            id: storedDeviceID(),
            displayName: hostNameProvider()?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Mac"
        )
    }

    private func storedDeviceID() -> UUID {
        if let storedValue = defaults.string(forKey: MacSyncDeviceIdentity.deviceIDKey),
           let storedID = UUID(uuidString: storedValue) {
            return storedID
        }

        let newID = uuidProvider()
        defaults.set(newID.uuidString, forKey: MacSyncDeviceIdentity.deviceIDKey)
        return newID
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }

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
#endif
