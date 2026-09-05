#if os(macOS)
import Foundation

enum MyRAMSyncBenchmarkEnduranceMacIsolation {
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
            fatalError("Unable to create the isolated BEN-36 macOS home: \(error.localizedDescription)")
        }

        setenv("HOME", isolatedHome.path, 1)
        setenv("CFFIXED_USER_HOME", isolatedHome.path, 1)

        guard let supportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first,
              isDescendant(supportDirectory, of: isolatedHome) else {
            fatalError("BEN-36 macOS endurance home isolation could not be verified.")
        }

        print("[MyRAM Sync Endurance] isolated macOS home: \(isolatedHome.path)")
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
        let identity = MacSyncDeviceIdentity(
            id: storedDeviceID(),
            displayName: hostNameProvider()?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Mac"
        )
        MyRAMSyncBenchmarkTelemetry.shared.configure(
            platform: .macOS,
            deviceID: identity.id.uuidString
        )
        return identity
    }

    private func storedDeviceID() -> UUID {
        let resolvedDeviceIDKey = MyRAMSyncBenchmarkConfiguration.enduranceUserDefaultsKey(
            MacSyncDeviceIdentity.deviceIDKey
        )
        if let storedValue = defaults.string(forKey: resolvedDeviceIDKey),
           let storedID = UUID(uuidString: storedValue) {
            return storedID
        }

        let newID = uuidProvider()
        defaults.set(newID.uuidString, forKey: resolvedDeviceIDKey)
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
