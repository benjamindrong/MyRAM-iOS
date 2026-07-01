#if os(macOS)
import Foundation

struct MacSyncDeviceIdentity: Equatable {
    static let deviceIDKey = "myram.sync.deviceID"

    let id: MacSyncDeviceID
    let displayName: String
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
}
#endif
