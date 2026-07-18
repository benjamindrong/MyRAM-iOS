import Foundation
import AnchoredSequenceCore
import Darwin

typealias ApplicationSupportDirectoryProviding = @Sendable () -> URL?
typealias ProtectedDirectoryPreparing = @Sendable (URL) throws -> Void
typealias SyncOperationIDReservationTestHook =
    @Sendable (SyncOperationIDReservationTestStage) throws -> Void

enum SyncOperationIDReservationTestStage: Equatable, Sendable {
    case afterAuthoritativeLoad
    case beforeStateInstallation
    case afterStateInstallation
    case afterVerification
}

enum SyncOperationIDReservationStoreError: Error, Equatable, Sendable {
    case storageUnavailable
    case backupExclusionFailed
    case transactionLockFailed
    case unsupportedVersion(Int)
    case corrupt
    case persistenceFailed
    case verificationFailed
}

struct FileBackedSyncOperationIDReservationStore:
    SyncOperationIDReservationTransacting,
    Sendable
{
    static let protectedDirectoryName = "AnchoredSequenceActor"
    static let stateFileName = "actor-state.json"
    static let lockFileName = "reservation.lock"

    private let applicationSupportDirectoryProvider: ApplicationSupportDirectoryProviding
    private let protectedDirectoryPreparer: ProtectedDirectoryPreparing
    private let uuidProvider: @Sendable () -> UUID
    private let testHook: SyncOperationIDReservationTestHook

    init(
        applicationSupportDirectoryProvider: @escaping ApplicationSupportDirectoryProviding = {
            FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
        },
        protectedDirectoryPreparer: @escaping ProtectedDirectoryPreparing = { url in
            try FileBackedSyncOperationIDReservationStore.prepareProtectedDirectory(at: url)
        },
        uuidProvider: @escaping @Sendable () -> UUID = { UUID() },
        testHook: @escaping SyncOperationIDReservationTestHook = { _ in }
    ) {
        self.applicationSupportDirectoryProvider = applicationSupportDirectoryProvider
        self.protectedDirectoryPreparer = protectedDirectoryPreparer
        self.uuidProvider = uuidProvider
        self.testHook = testHook
    }

    func reserveNextOperationID() throws -> SyncOperationID {
        guard let applicationSupportDirectory = applicationSupportDirectoryProvider() else {
            throw SyncOperationIDReservationStoreError.storageUnavailable
        }

        let protectedDirectory = applicationSupportDirectory
            .appendingPathComponent("MyRAM", isDirectory: true)
            .appendingPathComponent(Self.protectedDirectoryName, isDirectory: true)
        try prepareDirectory(at: protectedDirectory)

        let stateURL = protectedDirectory.appendingPathComponent(Self.stateFileName)
        let lockURL = protectedDirectory.appendingPathComponent(Self.lockFileName)

        return try withExclusiveTransactionLock(lockURL: lockURL) {
            let persistedState = try loadState(from: stateURL)
            try testHook(.afterAuthoritativeLoad)

            let currentState = persistedState ?? SyncActorSequenceState(actorID: uuidProvider())
            let reservation = try currentState.reservingNext()
            let encodedState = try encode(reservation.advancedState)

            try testHook(.beforeStateInstallation)
            do {
                try encodedState.write(to: stateURL, options: .atomic)
            } catch {
                throw SyncOperationIDReservationStoreError.persistenceFailed
            }
            try testHook(.afterStateInstallation)

            try synchronizeFile(at: stateURL)
            try verify(reservation.advancedState, at: stateURL)
            try testHook(.afterVerification)

            return reservation.operationID
        }
    }

    private func prepareDirectory(at url: URL) throws {
        do {
            try protectedDirectoryPreparer(url)
        } catch let error as SyncOperationIDReservationStoreError {
            throw error
        } catch {
            throw SyncOperationIDReservationStoreError.backupExclusionFailed
        }
    }

    private static func prepareProtectedDirectory(at url: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
        } catch {
            throw SyncOperationIDReservationStoreError.storageUnavailable
        }

        do {
            var mutableURL = url
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try mutableURL.setResourceValues(values)

            let verifiedValues = try url.resourceValues(
                forKeys: [.isExcludedFromBackupKey]
            )
            guard verifiedValues.isExcludedFromBackup == true else {
                throw SyncOperationIDReservationStoreError.backupExclusionFailed
            }
        } catch let error as SyncOperationIDReservationStoreError {
            throw error
        } catch {
            throw SyncOperationIDReservationStoreError.backupExclusionFailed
        }
    }

    private func withExclusiveTransactionLock<T>(
        lockURL: URL,
        _ body: () throws -> T
    ) throws -> T {
        let descriptor = lockURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            throw SyncOperationIDReservationStoreError.transactionLockFailed
        }
        defer { _ = close(descriptor) }

        guard flock(descriptor, LOCK_EX) == 0 else {
            throw SyncOperationIDReservationStoreError.transactionLockFailed
        }
        // The stable sidecar remains locked across authoritative reload and final verification.
        defer { _ = flock(descriptor, LOCK_UN) }

        return try body()
    }

    private func loadState(from url: URL) throws -> SyncActorSequenceState? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw SyncOperationIDReservationStoreError.corrupt
        }
        return try decodeState(from: data)
    }

    private func decodeState(from data: Data) throws -> SyncActorSequenceState {
        let decoder = JSONDecoder()
        let header: PersistedSyncActorSequenceHeader
        do {
            header = try decoder.decode(PersistedSyncActorSequenceHeader.self, from: data)
        } catch {
            throw SyncOperationIDReservationStoreError.corrupt
        }

        guard header.formatVersion == PersistedSyncActorSequenceStateV1.currentVersion else {
            throw SyncOperationIDReservationStoreError.unsupportedVersion(header.formatVersion)
        }

        let record: PersistedSyncActorSequenceStateV1
        do {
            record = try decoder.decode(PersistedSyncActorSequenceStateV1.self, from: data)
        } catch {
            throw SyncOperationIDReservationStoreError.corrupt
        }

        guard
            record.formatVersion == PersistedSyncActorSequenceStateV1.currentVersion,
            let actorID = UUID(uuidString: record.actorID),
            record.actorID == actorID.uuidString.lowercased()
        else {
            throw SyncOperationIDReservationStoreError.corrupt
        }

        return SyncActorSequenceState(
            actorID: actorID,
            lastReservedCounter: record.lastReservedCounter
        )
    }

    private func encode(_ state: SyncActorSequenceState) throws -> Data {
        guard let lastReservedCounter = state.lastReservedCounter else {
            throw SyncOperationIDReservationStoreError.persistenceFailed
        }

        let record = PersistedSyncActorSequenceStateV1(
            formatVersion: PersistedSyncActorSequenceStateV1.currentVersion,
            actorID: state.actorID.uuidString.lowercased(),
            lastReservedCounter: lastReservedCounter
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            return try encoder.encode(record)
        } catch {
            throw SyncOperationIDReservationStoreError.persistenceFailed
        }
    }

    private func synchronizeFile(at url: URL) throws {
        do {
            let handle = try FileHandle(forWritingTo: url)
            do {
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
        } catch {
            throw SyncOperationIDReservationStoreError.persistenceFailed
        }
    }

    private func verify(_ expectedState: SyncActorSequenceState, at url: URL) throws {
        do {
            let data = try Data(contentsOf: url)
            let persistedState = try decodeState(from: data)
            guard persistedState == expectedState else {
                throw SyncOperationIDReservationStoreError.verificationFailed
            }
        } catch {
            throw SyncOperationIDReservationStoreError.verificationFailed
        }
    }
}

private struct PersistedSyncActorSequenceHeader: Decodable {
    let formatVersion: Int
}

private struct PersistedSyncActorSequenceStateV1: Codable, Equatable {
    static let currentVersion = 1

    let formatVersion: Int
    let actorID: String
    let lastReservedCounter: UInt64
}
