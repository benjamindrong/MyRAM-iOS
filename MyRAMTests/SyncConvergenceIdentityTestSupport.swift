import Foundation
import MultipeerConnectivity
import XCTest
#if os(macOS)
@testable import MyRAMMac
#else
@testable import MyRAM
#endif

enum TestOptionalReplacement<Value> {
    case preserve
    case replace(Value?)

    func resolve(_ current: Value?) -> Value? {
        switch self {
        case .preserve:
            return current
        case .replace(let value):
            return value
        }
    }
}

extension OperationIdentityPayload {
    func replacingForTest(
        version: Int? = nil,
        batchID: UUID? = nil,
        originDeviceID: UUID? = nil,
        operationIndex: Int? = nil,
        operationKind: String? = nil,
        canonicalReplayKey: CanonicalReplayKeyPayload? = nil
    ) -> OperationIdentityPayload {
        OperationIdentityPayload(
            version: version ?? self.version,
            batchID: batchID ?? UUID(uuidString: batchIDLowercase)!,
            originDeviceID: originDeviceID ?? UUID(uuidString: originDeviceIDLowercase)!,
            operationIndex: operationIndex ?? self.operationIndex,
            operationKind: operationKind ?? self.operationKind,
            canonicalReplayKey: canonicalReplayKey ?? self.canonicalReplayKey
        )
    }

    func replacingRawStringsForTest(
        batchIDLowercase: String? = nil,
        originDeviceIDLowercase: String? = nil,
        canonicalReplayKeyBatchIDLowercase: String? = nil,
        canonicalReplayKeyOriginDeviceIDLowercase: String? = nil
    ) throws -> OperationIdentityPayload {
        let rawReplayKey = RawCanonicalReplayKeyPayload(
            version: canonicalReplayKey.version,
            modifiedAtBitPattern: canonicalReplayKey.modifiedAtBitPattern,
            originDeviceIDLowercase: canonicalReplayKeyOriginDeviceIDLowercase ?? canonicalReplayKey.originDeviceIDLowercase,
            batchOrderKind: canonicalReplayKey.batchOrderKind,
            legacyCreatedAtBitPattern: canonicalReplayKey.legacyCreatedAtBitPattern,
            sequence: canonicalReplayKey.sequence,
            batchIDLowercase: canonicalReplayKeyBatchIDLowercase ?? canonicalReplayKey.batchIDLowercase,
            operationIndex: canonicalReplayKey.operationIndex
        )
        let rawIdentity = RawOperationIdentityPayload(
            version: version,
            batchIDLowercase: batchIDLowercase ?? self.batchIDLowercase,
            originDeviceIDLowercase: originDeviceIDLowercase ?? self.originDeviceIDLowercase,
            operationIndex: operationIndex,
            operationKind: operationKind,
            canonicalReplayKey: rawReplayKey
        )
        return try SyncConvergenceStableEncoding.decode(
            OperationIdentityPayload.self,
            from: SyncConvergenceStableEncoding.encode(rawIdentity)
        )
    }
}

extension CanonicalReplayKeyPayload {
    func replacingForTest(
        version: Int? = nil,
        modifiedAtBitPattern: UInt64? = nil,
        originDeviceID: UUID? = nil,
        batchOrderKind: BatchOrderKind? = nil,
        legacyCreatedAtBitPattern: TestOptionalReplacement<UInt64> = .preserve,
        sequence: TestOptionalReplacement<UInt64> = .preserve,
        batchID: UUID? = nil,
        operationIndex: Int? = nil
    ) -> CanonicalReplayKeyPayload {
        CanonicalReplayKeyPayload(
            version: version ?? self.version,
            modifiedAtBitPattern: modifiedAtBitPattern ?? self.modifiedAtBitPattern,
            originDeviceIDLowercase: (originDeviceID ?? UUID(uuidString: originDeviceIDLowercase)!).uuidString.lowercased(),
            batchOrderKind: batchOrderKind ?? self.batchOrderKind,
            legacyCreatedAtBitPattern: legacyCreatedAtBitPattern.resolve(self.legacyCreatedAtBitPattern),
            sequence: sequence.resolve(self.sequence),
            batchIDLowercase: (batchID ?? UUID(uuidString: batchIDLowercase)!).uuidString.lowercased(),
            operationIndex: operationIndex ?? self.operationIndex
        )
    }
}

private struct RawOperationIdentityPayload: Codable {
    let version: Int
    let batchIDLowercase: String
    let originDeviceIDLowercase: String
    let operationIndex: Int
    let operationKind: String
    let canonicalReplayKey: RawCanonicalReplayKeyPayload
}

private struct RawCanonicalReplayKeyPayload: Codable {
    let version: Int
    let modifiedAtBitPattern: UInt64
    let originDeviceIDLowercase: String
    let batchOrderKind: CanonicalReplayKeyPayload.BatchOrderKind
    let legacyCreatedAtBitPattern: UInt64?
    let sequence: UInt64?
    let batchIDLowercase: String
    let operationIndex: Int
}

#if !os(macOS)
final class MyRAMDeviceIdentityTests: XCTestCase {
    private let deviceID = "00000000-0000-0000-0000-000000000123"

    func testVerificationFixtureIdentityOwnsDefaultsBeforePeerReadersAndAfterRelaunch() throws {
        let suite = "MYR233.identity.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("B0F701B7-7744-4236-8805-E140C4004A14", forKey: "myram.sync.deviceID")
        let trusted = Data("preserved Verification pairing".utf8)
        defaults.set(trusted, forKey: "myram.sync.trustedPeers")
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).bundle")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: path) }
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.northsignalstudio.myram.verification",
            "MyRAMVerificationFixtureDeviceID": "94C3C1CC-4FD0-4E55-97E3-3AAD33F24B8B"
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: path.appendingPathComponent("Info.plist"))
        let bundle = try XCTUnwrap(Bundle(path: path.path))
        let first = MyRAMDeviceIdentity.currentDeviceID(defaults: defaults, bundle: bundle)
        XCTAssertEqual(first, "94C3C1CC-4FD0-4E55-97E3-3AAD33F24B8B")
        XCTAssertEqual(defaults.string(forKey: "myram.sync.deviceID"), first)
        let recreated = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertEqual(MyRAMDeviceIdentity.currentDeviceID(defaults: recreated, bundle: bundle), first)
        recreated.set("B0F701B7-7744-4236-8805-E140C4004A14", forKey: "myram.sync.deviceID")
        XCTAssertEqual(MyRAMDeviceIdentity.currentDeviceID(defaults: recreated, bundle: bundle), first)
        XCTAssertEqual(recreated.data(forKey: "myram.sync.trustedPeers"), trusted)
    }

    func testFixtureConfigurationRejectsProductionAndMalformedIdentityWithoutWritingDefaults() throws {
        let suite = "MYR233.identity.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(deviceID, forKey: "myram.sync.deviceID")
        for bundleID in ["com.northsignalstudio.myram", "com.northsignalstudio.myram.dev",
                         "com.northsignalstudio.myram.verification.widget"] {
            XCTAssertThrowsError(try MyRAMSyncDeviceIdentityStore.resolve(
                defaults: defaults, bundleIdentifier: bundleID, configuredDeviceID: deviceID
            ))
        }
        for value in ["invalid", 123] as [Any] {
            XCTAssertThrowsError(try MyRAMSyncDeviceIdentityStore.resolve(
                defaults: defaults, bundleIdentifier: "com.northsignalstudio.myram.verification",
                configuredDeviceID: value
            ))
        }
        XCTAssertEqual(defaults.string(forKey: "myram.sync.deviceID"), deviceID)
    }

    func testProductionIdentityKeepsExistingStringAndCreatesOnlyWhenMissingOrInvalid() throws {
        let suite = "MYR233.identity.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let retained = "94c3c1cc-4fd0-4e55-97e3-3aad33f24b8b"
        defaults.set(retained, forKey: "myram.sync.deviceID")
        XCTAssertEqual(try MyRAMSyncDeviceIdentityStore.resolve(
            defaults: defaults, bundleIdentifier: "com.northsignalstudio.myram",
            configuredDeviceID: nil, uuidProvider: { XCTFail("Existing ID must be retained"); return UUID() }
        ), retained)
        defaults.set("invalid", forKey: "myram.sync.deviceID")
        let created = UUID()
        XCTAssertEqual(try MyRAMSyncDeviceIdentityStore.resolve(
            defaults: defaults, bundleIdentifier: "com.northsignalstudio.myram",
            configuredDeviceID: nil, uuidProvider: { created }
        ), created.uuidString)
        XCTAssertEqual(defaults.string(forKey: "myram.sync.deviceID"), created.uuidString)
    }

    func testSimulatorStyleDeviceNameFitsMCPeerIDWithoutChangingDeviceID() {
        let displayName = MyRAMDeviceIdentity.boundedDisplayName(
            "MYR-180-S2-20260824T010103Z",
            deviceID: deviceID
        )
        let peerDisplayName = "\(displayName)|\(deviceID)"

        XCTAssertEqual(displayName, "MYR-180-S2-20260824T010103")
        XCTAssertEqual(peerDisplayName.utf8.count, MyRAMDeviceIdentity.maximumPeerDisplayNameUTF8ByteCount)
        XCTAssertTrue(peerDisplayName.hasSuffix("|\(deviceID)"))
        XCTAssertEqual(MCPeerID(displayName: peerDisplayName).displayName, peerDisplayName)
    }

    func testMultibyteDeviceNameIsBoundedAtCharacterBoundary() {
        let displayName = MyRAMDeviceIdentity.boundedDisplayName(
            String(repeating: "é", count: 100),
            deviceID: deviceID
        )
        let peerDisplayName = "\(displayName)|\(deviceID)"

        XCTAssertEqual(displayName, String(repeating: "é", count: 13))
        XCTAssertEqual(peerDisplayName.utf8.count, MyRAMDeviceIdentity.maximumPeerDisplayNameUTF8ByteCount)
        XCTAssertEqual(MCPeerID(displayName: peerDisplayName).displayName, peerDisplayName)
    }

    func testWhitespaceOnlyDeviceNameUsesSafeFallback() {
        let displayName = MyRAMDeviceIdentity.boundedDisplayName(
            "  \n\t ",
            deviceID: deviceID
        )
        let peerDisplayName = "\(displayName)|\(deviceID)"

        XCTAssertEqual(displayName, "iPhone")
        XCTAssertLessThanOrEqual(peerDisplayName.utf8.count, MyRAMDeviceIdentity.maximumPeerDisplayNameUTF8ByteCount)
        XCTAssertEqual(MCPeerID(displayName: peerDisplayName).displayName, peerDisplayName)
    }
}
#endif
