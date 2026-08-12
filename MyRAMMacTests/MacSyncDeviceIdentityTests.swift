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

    func testPeerDisplayNamePreservesShortNameAndFullUUID() {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000123")!
        let identity = MacSyncDeviceIdentity(id: id, displayName: "Test Mac")

        XCTAssertEqual(identity.peerDisplayName, "Test Mac|\(id.uuidString)")
        XCTAssertEqual(identity.peerDisplayName.split(separator: "|", maxSplits: 1).last, Substring(id.uuidString))
    }

    func testPeerDisplayNameAcceptsExactUTF8BoundaryWithoutShortening() {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000123")!
        let name = String(repeating: "A", count: 26)
        let identity = MacSyncDeviceIdentity(id: id, displayName: name)

        XCTAssertEqual(identity.peerDisplayName, "\(name)|\(id.uuidString)")
        XCTAssertEqual(
            identity.peerDisplayName.utf8.count,
            MacSyncDeviceIdentity.maximumPeerDisplayNameUTF8ByteCount
        )
    }

    func testPeerDisplayNameBoundsLongASCIINameWithoutChangingUUID() {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000123")!
        let identity = MacSyncDeviceIdentity(
            id: id,
            displayName: String(repeating: "A", count: 100)
        )

        XCTAssertEqual(identity.peerDisplayName, "\(String(repeating: "A", count: 26))|\(id.uuidString)")
        XCTAssertLessThanOrEqual(
            identity.peerDisplayName.utf8.count,
            MacSyncDeviceIdentity.maximumPeerDisplayNameUTF8ByteCount
        )
        XCTAssertTrue(identity.peerDisplayName.hasSuffix("|\(id.uuidString)"))
    }

    func testPeerDisplayNameBoundsLongMultibyteNameAtCharacterBoundary() {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000123")!
        let identity = MacSyncDeviceIdentity(
            id: id,
            displayName: String(repeating: "é", count: 100)
        )

        XCTAssertEqual(identity.peerDisplayName, "\(String(repeating: "é", count: 13))|\(id.uuidString)")
        XCTAssertLessThanOrEqual(
            identity.peerDisplayName.utf8.count,
            MacSyncDeviceIdentity.maximumPeerDisplayNameUTF8ByteCount
        )
        XCTAssertTrue(identity.peerDisplayName.hasSuffix("|\(id.uuidString)"))
    }

    func testCurrentIdentityWhitespaceOnlyHostNameUsesSafeMacFallback() {
        let defaults = makeDefaults()
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000123")!
        let identity = MacSyncDeviceIdentityProvider(
            defaults: defaults,
            hostNameProvider: { "  \n\t " },
            uuidProvider: { id }
        ).currentIdentity()

        XCTAssertEqual(identity.displayName, "Mac")
        XCTAssertEqual(identity.peerDisplayName, "Mac|\(id.uuidString)")
        XCTAssertLessThanOrEqual(
            identity.peerDisplayName.utf8.count,
            MacSyncDeviceIdentity.maximumPeerDisplayNameUTF8ByteCount
        )
    }

    func testPeerDisplayNameFallsBackWhenFirstHostCharacterCannotFit() {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000123")!
        let oversizedCharacter = String(repeating: "👩🏽‍💻", count: 2)
        let identity = MacSyncDeviceIdentity(id: id, displayName: oversizedCharacter)

        XCTAssertTrue(identity.peerDisplayName.hasSuffix("|\(id.uuidString)"))
        XCTAssertLessThanOrEqual(
            identity.peerDisplayName.utf8.count,
            MacSyncDeviceIdentity.maximumPeerDisplayNameUTF8ByteCount
        )
        XCTAssertFalse(identity.peerDisplayName.split(separator: "|", maxSplits: 1)[0].isEmpty)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "MacSyncDeviceIdentityTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
