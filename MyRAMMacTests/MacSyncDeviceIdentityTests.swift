import XCTest
@testable import MyRAMMac

final class MacSyncDeviceIdentityTests: XCTestCase {
    func testCurrentIdentityReusesExistingStableDeviceIDKey() {
        let defaults = makeDefaults()
        let existingID = UUID(uuidString: "00000000-0000-0000-0000-000000000123")!
        defaults.set(existingID.uuidString, forKey: MacSyncDeviceIdentity.deviceIDKey)

        let identity = MacSyncDeviceIdentityProvider(
            defaults: defaults,
            hostNameProvider: { "Test Mac" },
            uuidProvider: { UUID(uuidString: "00000000-0000-0000-0000-000000000999")! }
        ).currentIdentity()

        XCTAssertEqual(MacSyncDeviceIdentity.deviceIDKey, "myram.sync.deviceID")
        XCTAssertEqual(identity.id, existingID)
        XCTAssertEqual(identity.displayName, "Test Mac")
    }

    func testCurrentIdentityCreatesAndStoresDeviceIDWhenMissing() {
        let defaults = makeDefaults()
        let generatedID = UUID(uuidString: "00000000-0000-0000-0000-000000000456")!

        let identity = MacSyncDeviceIdentityProvider(
            defaults: defaults,
            hostNameProvider: { nil },
            uuidProvider: { generatedID }
        ).currentIdentity()

        XCTAssertEqual(identity.id, generatedID)
        XCTAssertEqual(identity.displayName, "Mac")
        XCTAssertEqual(defaults.string(forKey: MacSyncDeviceIdentity.deviceIDKey), generatedID.uuidString)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "MacSyncDeviceIdentityTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
