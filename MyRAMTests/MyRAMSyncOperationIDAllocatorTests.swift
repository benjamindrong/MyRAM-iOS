import Foundation
import XCTest
import AnchoredSequenceCore

#if os(macOS)
@testable import MyRAMMac
#else
@testable import MyRAM
#endif

final class MyRAMSyncOperationIDAllocatorTests: XCTestCase {
    func testConstructionIsLazyAndUnavailableStorageFailsClosed() async throws {
        let productionDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?
            .appendingPathComponent("MyRAM", isDirectory: true)
            .appendingPathComponent(
                FileBackedSyncOperationIDReservationStore.protectedDirectoryName,
                isDirectory: true
            )
        let before = productionDirectory.map(pathSnapshot)
        let providerCalls = InvocationCounter()

        _ = MyRAMSyncOperationIDAllocator.shared
        _ = FileBackedSyncOperationIDReservationStore()
        let store = FileBackedSyncOperationIDReservationStore(
            applicationSupportDirectoryProvider: {
                providerCalls.record()
                return nil
            }
        )
        let allocator = MyRAMSyncOperationIDAllocator(transactionStore: store)

        XCTAssertEqual(providerCalls.count, 0)
        XCTAssertEqual(productionDirectory.map(pathSnapshot), before)

        do {
            _ = try await allocator.reserveOperationID()
            XCTFail("Reservation should fail when Application Support is unavailable")
        } catch {
            XCTAssertEqual(
                error as? SyncOperationIDReservationStoreError,
                .storageUnavailable
            )
        }
        XCTAssertEqual(providerCalls.count, 1)
        XCTAssertEqual(productionDirectory.map(pathSnapshot), before)
    }

    func testFirstReservationPreparesProtectedDirectoryBeforeCreatingFiles() throws {
        let root = try makeTemporaryApplicationSupportDirectory()
        let observer = ProtectedDirectoryPreparationObserver()
        let actorID = uuid("00000000-0000-0000-0000-000000000001")
        let store = makeStore(
            root: root,
            uuidProvider: { actorID },
            protectedDirectoryPreparer: { directory in
                try observer.prepare(directory)
            }
        )

        let first = try store.reserveNextOperationID()
        let second = try store.reserveNextOperationID()
        let directory = protectedDirectory(in: root)
        let lockURL = directory.appendingPathComponent(
            FileBackedSyncOperationIDReservationStore.lockFileName
        )
        let stateURL = directory.appendingPathComponent(
            FileBackedSyncOperationIDReservationStore.stateFileName
        )

        XCTAssertEqual(first, SyncOperationID(deviceID: actorID, localCounter: 0))
        XCTAssertEqual(second, SyncOperationID(deviceID: actorID, localCounter: 1))
        XCTAssertEqual(observer.invocationCount, 2)
        XCTAssertTrue(observer.firstInvocationSawNoTransactionFiles)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateURL.path))
        XCTAssertEqual(try backupExclusionValue(for: directory), true)
    }

    func testProtectedDirectoryFailureCreatesNoTransactionFilesOrActor() throws {
        let root = try makeTemporaryApplicationSupportDirectory()
        let uuidCalls = InvocationCounter()
        let store = makeStore(
            root: root,
            uuidProvider: {
                uuidCalls.record()
                return UUID()
            },
            protectedDirectoryPreparer: { _ in
                throw TestFailure.injected
            }
        )

        XCTAssertThrowsError(try store.reserveNextOperationID()) { error in
            XCTAssertEqual(
                error as? SyncOperationIDReservationStoreError,
                .backupExclusionFailed
            )
        }

        let directory = protectedDirectory(in: root)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(
                FileBackedSyncOperationIDReservationStore.lockFileName
            ).path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(
                FileBackedSyncOperationIDReservationStore.stateFileName
            ).path
        ))
        XCTAssertEqual(uuidCalls.count, 0)
    }

    func testFirstAndSequentialReservationsPersistCanonicalRecord() throws {
        let root = try makeTemporaryApplicationSupportDirectory()
        let actorID = uuid("00000000-0000-0000-0000-0000000000A1")
        let uuidCalls = InvocationCounter()
        let store = makeStore(
            root: root,
            uuidProvider: {
                uuidCalls.record()
                return actorID
            }
        )

        let first = try store.reserveNextOperationID()
        let firstRecord = try Data(contentsOf: stateURL(in: root))
        let second = try store.reserveNextOperationID()

        XCTAssertEqual(first, SyncOperationID(deviceID: actorID, localCounter: 0))
        XCTAssertEqual(second, SyncOperationID(deviceID: actorID, localCounter: 1))
        XCTAssertEqual(
            firstRecord,
            Data(
                "{\"actorID\":\"00000000-0000-0000-0000-0000000000a1\",\"formatVersion\":1,\"lastReservedCounter\":0}"
                    .utf8
            )
        )
        XCTAssertEqual(try persistedRecord(at: stateURL(in: root)).lastReservedCounter, 1)
        XCTAssertEqual(uuidCalls.count, 1)
    }

    func testRecreatedAllocatorAdvancesExistingActor() async throws {
        let root = try makeTemporaryApplicationSupportDirectory()
        let actorID = uuid("00000000-0000-0000-0000-000000000001")
        let firstAllocator = MyRAMSyncOperationIDAllocator(
            transactionStore: makeStore(root: root, uuidProvider: { actorID })
        )

        let first = try await firstAllocator.reserveOperationID()
        let restartedAllocator = MyRAMSyncOperationIDAllocator(
            transactionStore: makeStore(root: root, uuidProvider: { UUID() })
        )
        let second = try await restartedAllocator.reserveOperationID()

        XCTAssertEqual(first, SyncOperationID(deviceID: actorID, localCounter: 0))
        XCTAssertEqual(second, SyncOperationID(deviceID: actorID, localCounter: 1))
    }

    func testConcurrentCallsThroughOneAllocatorAreUniqueAndContiguous() async throws {
        let root = try makeTemporaryApplicationSupportDirectory()
        let actorID = uuid("00000000-0000-0000-0000-000000000001")
        let allocator = MyRAMSyncOperationIDAllocator(
            transactionStore: makeStore(root: root, uuidProvider: { actorID })
        )

        let operationIDs = try await reserveConcurrently(count: 40) {
            try await allocator.reserveOperationID()
        }

        assertContiguous(operationIDs, count: 40, actorID: actorID)
    }

    func testDistinctAllocatorsSharingRealStoreSerializeOneContiguousSequence() async throws {
        let root = try makeTemporaryApplicationSupportDirectory()
        let actorA = uuid("00000000-0000-0000-0000-00000000000A")
        let actorB = uuid("00000000-0000-0000-0000-00000000000B")
        let allocatorA = MyRAMSyncOperationIDAllocator(
            transactionStore: makeStore(root: root, uuidProvider: { actorA })
        )
        let allocatorB = MyRAMSyncOperationIDAllocator(
            transactionStore: makeStore(root: root, uuidProvider: { actorB })
        )

        let operationIDs = try await reserveConcurrently(count: 40) { index in
            if index.isMultiple(of: 2) {
                return try await allocatorA.reserveOperationID()
            }
            return try await allocatorB.reserveOperationID()
        }

        assertContiguous(operationIDs, count: 40, actorID: operationIDs[0].deviceID)
        XCTAssertTrue([actorA, actorB].contains(operationIDs[0].deviceID))
    }

    func testLockCoversAuthoritativeLoadThroughVerification() async throws {
        let root = try makeTemporaryApplicationSupportDirectory()
        let pause = TransactionPause()
        let actorID = uuid("00000000-0000-0000-0000-000000000001")
        let allocatorA = MyRAMSyncOperationIDAllocator(
            transactionStore: makeStore(
                root: root,
                uuidProvider: { actorID },
                testHook: { stage in
                    if stage == .afterAuthoritativeLoad {
                        pause.pauseTransaction()
                    }
                }
            )
        )
        let allocatorB = MyRAMSyncOperationIDAllocator(
            transactionStore: makeStore(root: root, uuidProvider: { UUID() })
        )

        let firstTask = Task { try await allocatorA.reserveOperationID() }
        XCTAssertTrue(pause.waitUntilPaused())

        let secondStarted = DispatchSemaphore(value: 0)
        let secondCompleted = DispatchSemaphore(value: 0)
        let secondTask = Task {
            secondStarted.signal()
            defer { secondCompleted.signal() }
            return try await allocatorB.reserveOperationID()
        }
        XCTAssertEqual(secondStarted.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(secondCompleted.wait(timeout: .now() + 0.1), .timedOut)

        pause.resumeTransaction()
        let results = try await [firstTask.value, secondTask.value]

        XCTAssertEqual(Set(results.map(\.deviceID)), [actorID])
        XCTAssertEqual(results.map(\.localCounter).sorted(), [0, 1])
    }

    func testConcurrentFirstUseSelectsOneAuthoritativeActor() async throws {
        let root = try makeTemporaryApplicationSupportDirectory()
        let pause = TransactionPause()
        let actorA = uuid("00000000-0000-0000-0000-00000000000A")
        let actorB = uuid("00000000-0000-0000-0000-00000000000B")
        let allocatorA = MyRAMSyncOperationIDAllocator(
            transactionStore: makeStore(
                root: root,
                uuidProvider: { actorA },
                testHook: { stage in
                    if stage == .afterAuthoritativeLoad {
                        pause.pauseTransaction()
                    }
                }
            )
        )
        let actorBCalls = InvocationCounter()
        let allocatorB = MyRAMSyncOperationIDAllocator(
            transactionStore: makeStore(
                root: root,
                uuidProvider: {
                    actorBCalls.record()
                    return actorB
                }
            )
        )

        let firstTask = Task { try await allocatorA.reserveOperationID() }
        XCTAssertTrue(pause.waitUntilPaused())
        let secondTask = Task { try await allocatorB.reserveOperationID() }
        pause.resumeTransaction()
        let results = try await [firstTask.value, secondTask.value]

        XCTAssertEqual(Set(results.map(\.deviceID)), [actorA])
        XCTAssertEqual(results.map(\.localCounter).sorted(), [0, 1])
        XCTAssertEqual(actorBCalls.count, 0)
    }

    func testFailureBeforeInstallationAllowsUncommittedCounterToBeRetried() throws {
        let root = try makeTemporaryApplicationSupportDirectory()
        let actorID = uuid("00000000-0000-0000-0000-000000000001")
        let failingStore = makeStore(
            root: root,
            uuidProvider: { actorID },
            testHook: throwingHook(at: .beforeStateInstallation)
        )

        XCTAssertThrowsError(try failingStore.reserveNextOperationID())
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL(in: root).path))

        let retried = try makeStore(
            root: root,
            uuidProvider: { actorID }
        ).reserveNextOperationID()
        XCTAssertEqual(retried, SyncOperationID(deviceID: actorID, localCounter: 0))
    }

    func testFailureAfterInstallationLeavesProtectedGapOnRetry() throws {
        let root = try makeTemporaryApplicationSupportDirectory()
        let actorID = uuid("00000000-0000-0000-0000-000000000001")
        let failingStore = makeStore(
            root: root,
            uuidProvider: { actorID },
            testHook: throwingHook(at: .afterStateInstallation)
        )

        XCTAssertThrowsError(try failingStore.reserveNextOperationID())
        XCTAssertEqual(try persistedRecord(at: stateURL(in: root)).lastReservedCounter, 0)
        XCTAssertEqual(try backupExclusionValue(for: protectedDirectory(in: root)), true)

        let retried = try makeStore(
            root: root,
            uuidProvider: { UUID() }
        ).reserveNextOperationID()
        XCTAssertEqual(retried, SyncOperationID(deviceID: actorID, localCounter: 1))
    }

    func testFailureAfterVerificationDoesNotReuseCommittedReservation() throws {
        let root = try makeTemporaryApplicationSupportDirectory()
        let actorID = uuid("00000000-0000-0000-0000-000000000001")
        let failingStore = makeStore(
            root: root,
            uuidProvider: { actorID },
            testHook: throwingHook(at: .afterVerification)
        )

        XCTAssertThrowsError(try failingStore.reserveNextOperationID())

        let retried = try makeStore(
            root: root,
            uuidProvider: { UUID() }
        ).reserveNextOperationID()
        XCTAssertEqual(retried, SyncOperationID(deviceID: actorID, localCounter: 1))
    }

    func testInvalidRecordsFailClosedWithoutReplacingStateOrCreatingActor() throws {
        let invalidRecords: [(Data, SyncOperationIDReservationStoreError)] = [
            (Data("not-json".utf8), .corrupt),
            (
                Data(
                    "{\"actorID\":\"not-a-uuid\",\"formatVersion\":1,\"lastReservedCounter\":3}"
                        .utf8
                ),
                .corrupt
            ),
            (
                Data(
                    "{\"actorID\":\"00000000-0000-0000-0000-0000000000AA\",\"formatVersion\":1,\"lastReservedCounter\":3}"
                        .utf8
                ),
                .corrupt
            ),
            (
                Data("{\"formatVersion\":2,\"futureState\":true}".utf8),
                .unsupportedVersion(2)
            )
        ]

        for (index, invalidRecord) in invalidRecords.enumerated() {
            let root = try makeTemporaryApplicationSupportDirectory(suffix: "-\(index)")
            let directory = protectedDirectory(in: root)
            try prepareProtectedTestDirectory(directory)
            let stateURL = stateURL(in: root)
            try invalidRecord.0.write(to: stateURL)
            let uuidCalls = InvocationCounter()
            let store = makeStore(
                root: root,
                uuidProvider: {
                    uuidCalls.record()
                    return UUID()
                }
            )

            XCTAssertThrowsError(try store.reserveNextOperationID()) { error in
                XCTAssertEqual(
                    error as? SyncOperationIDReservationStoreError,
                    invalidRecord.1,
                    "Invalid-record case \(index) returned the wrong error"
                )
            }
            XCTAssertEqual(try Data(contentsOf: stateURL), invalidRecord.0)
            XCTAssertEqual(uuidCalls.count, 0)
        }
    }

    func testMissingRecordAfterPriorUseCreatesNewActorAtCounterZero() throws {
        let root = try makeTemporaryApplicationSupportDirectory()
        let actorA = uuid("00000000-0000-0000-0000-00000000000A")
        let actorB = uuid("00000000-0000-0000-0000-00000000000B")
        let provider = OrderedUUIDProvider([actorA, actorB])
        let store = makeStore(root: root, uuidProvider: { provider.next() })

        let first = try store.reserveNextOperationID()
        try FileManager.default.removeItem(at: stateURL(in: root))
        let second = try store.reserveNextOperationID()

        XCTAssertEqual(first, SyncOperationID(deviceID: actorA, localCounter: 0))
        XCTAssertEqual(second, SyncOperationID(deviceID: actorB, localCounter: 0))
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockURL(in: root).path))
    }

    func testExhaustionPreservesMaximumRecord() throws {
        let root = try makeTemporaryApplicationSupportDirectory()
        let actorID = uuid("00000000-0000-0000-0000-000000000001")
        let data = Data(
            "{\"actorID\":\"\(actorID.uuidString.lowercased())\",\"formatVersion\":1,\"lastReservedCounter\":\(UInt64.max)}"
                .utf8
        )
        try prepareProtectedTestDirectory(protectedDirectory(in: root))
        try data.write(to: stateURL(in: root))

        XCTAssertThrowsError(
            try makeStore(root: root, uuidProvider: { UUID() }).reserveNextOperationID()
        ) { error in
            XCTAssertEqual(
                error as? SyncActorSequenceReservationError,
                .counterExhausted(actorID: actorID)
            )
        }
        XCTAssertEqual(try Data(contentsOf: stateURL(in: root)), data)
    }

    func testDirectoryAndLockRemainStableAcrossAtomicStateReplacement() throws {
        let root = try makeTemporaryApplicationSupportDirectory()
        let actorID = uuid("00000000-0000-0000-0000-000000000001")
        let store = makeStore(root: root, uuidProvider: { actorID })

        _ = try store.reserveNextOperationID()
        let directory = protectedDirectory(in: root)
        let lockURL = lockURL(in: root)
        let initialLockIdentifier = try resourceIdentifier(for: lockURL)
        _ = try store.reserveNextOperationID()
        _ = try store.reserveNextOperationID()

        XCTAssertEqual(protectedDirectory(in: root), directory)
        XCTAssertEqual(self.lockURL(in: root), lockURL)
        XCTAssertEqual(try resourceIdentifier(for: lockURL), initialLockIdentifier)
        XCTAssertEqual(try persistedRecord(at: stateURL(in: root)).lastReservedCounter, 2)
        XCTAssertEqual(try backupExclusionValue(for: directory), true)
    }

    private func makeStore(
        root: URL,
        uuidProvider: @escaping @Sendable () -> UUID,
        testHook: @escaping SyncOperationIDReservationTestHook = { _ in }
    ) -> FileBackedSyncOperationIDReservationStore {
        FileBackedSyncOperationIDReservationStore(
            applicationSupportDirectoryProvider: { root },
            uuidProvider: uuidProvider,
            testHook: testHook
        )
    }

    private func makeStore(
        root: URL,
        uuidProvider: @escaping @Sendable () -> UUID,
        protectedDirectoryPreparer: @escaping ProtectedDirectoryPreparing,
        testHook: @escaping SyncOperationIDReservationTestHook = { _ in }
    ) -> FileBackedSyncOperationIDReservationStore {
        FileBackedSyncOperationIDReservationStore(
            applicationSupportDirectoryProvider: { root },
            protectedDirectoryPreparer: protectedDirectoryPreparer,
            uuidProvider: uuidProvider,
            testHook: testHook
        )
    }

    private func makeTemporaryApplicationSupportDirectory(
        suffix: String = ""
    ) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MyRAMSyncOperationIDAllocatorTests-\(UUID())\(suffix)",
            isDirectory: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }

    private func protectedDirectory(in root: URL) -> URL {
        root.appendingPathComponent("MyRAM", isDirectory: true)
            .appendingPathComponent(
                FileBackedSyncOperationIDReservationStore.protectedDirectoryName,
                isDirectory: true
            )
    }

    private func stateURL(in root: URL) -> URL {
        protectedDirectory(in: root).appendingPathComponent(
            FileBackedSyncOperationIDReservationStore.stateFileName
        )
    }

    private func lockURL(in root: URL) -> URL {
        protectedDirectory(in: root).appendingPathComponent(
            FileBackedSyncOperationIDReservationStore.lockFileName
        )
    }

    private func throwingHook(
        at expectedStage: SyncOperationIDReservationTestStage
    ) -> SyncOperationIDReservationTestHook {
        { stage in
            if stage == expectedStage {
                throw TestFailure.injected
            }
        }
    }

    private func reserveConcurrently(
        count: Int,
        reservation: @escaping @Sendable () async throws -> SyncOperationID
    ) async throws -> [SyncOperationID] {
        try await reserveConcurrently(count: count) { _ in
            try await reservation()
        }
    }

    private func reserveConcurrently(
        count: Int,
        reservation: @escaping @Sendable (Int) async throws -> SyncOperationID
    ) async throws -> [SyncOperationID] {
        try await withThrowingTaskGroup(of: SyncOperationID.self) { group in
            for index in 0..<count {
                group.addTask {
                    try await reservation(index)
                }
            }

            var operationIDs: [SyncOperationID] = []
            for try await operationID in group {
                operationIDs.append(operationID)
            }
            return operationIDs
        }
    }

    private func assertContiguous(
        _ operationIDs: [SyncOperationID],
        count: Int,
        actorID: UUID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(Set(operationIDs).count, count, file: file, line: line)
        XCTAssertEqual(Set(operationIDs.map(\.deviceID)), [actorID], file: file, line: line)
        XCTAssertEqual(
            operationIDs.map(\.localCounter).sorted(),
            (0..<count).map(UInt64.init),
            file: file,
            line: line
        )
    }

    private func persistedRecord(at url: URL) throws -> TestPersistedRecord {
        try JSONDecoder().decode(TestPersistedRecord.self, from: Data(contentsOf: url))
    }

    private func prepareProtectedTestDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        var mutableDirectory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutableDirectory.setResourceValues(values)
        XCTAssertEqual(try backupExclusionValue(for: directory), true)
    }

    private func backupExclusionValue(for url: URL) throws -> Bool? {
        try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
    }

    private func resourceIdentifier(for url: URL) throws -> AnyHashable? {
        try url.resourceValues(forKeys: [.fileResourceIdentifierKey])
            .fileResourceIdentifier as? AnyHashable
    }

    private func pathSnapshot(_ url: URL) -> PathSnapshot {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return PathSnapshot(exists: false, modificationDate: nil)
        }
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return PathSnapshot(
            exists: true,
            modificationDate: values?.contentModificationDate
        )
    }

    private func uuid(_ value: String) -> UUID {
        UUID(uuidString: value)!
    }
}

private enum TestFailure: Error {
    case injected
}

private struct TestPersistedRecord: Decodable {
    let actorID: String
    let formatVersion: Int
    let lastReservedCounter: UInt64
}

private struct PathSnapshot: Equatable {
    let exists: Bool
    let modificationDate: Date?
}

private final class InvocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.withLock { value }
    }

    func record() {
        lock.withLock {
            value += 1
        }
    }
}

private final class OrderedUUIDProvider: @unchecked Sendable {
    private let lock = NSLock()
    private let values: [UUID]
    private var nextIndex = 0

    init(_ values: [UUID]) {
        precondition(!values.isEmpty)
        self.values = values
    }

    func next() -> UUID {
        lock.withLock {
            let value = values[min(nextIndex, values.count - 1)]
            nextIndex += 1
            return value
        }
    }
}

private final class TransactionPause: @unchecked Sendable {
    private let paused = DispatchSemaphore(value: 0)
    private let resume = DispatchSemaphore(value: 0)

    func pauseTransaction() {
        paused.signal()
        _ = resume.wait(timeout: .now() + 5)
    }

    func waitUntilPaused() -> Bool {
        paused.wait(timeout: .now() + 2) == .success
    }

    func resumeTransaction() {
        resume.signal()
    }
}

private final class ProtectedDirectoryPreparationObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var firstSawNoFiles = false

    var invocationCount: Int {
        lock.withLock { calls }
    }

    var firstInvocationSawNoTransactionFiles: Bool {
        lock.withLock { firstSawNoFiles }
    }

    func prepare(_ directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        var mutableDirectory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutableDirectory.setResourceValues(values)
        guard try directory.resourceValues(
            forKeys: [.isExcludedFromBackupKey]
        ).isExcludedFromBackup == true else {
            throw TestFailure.injected
        }

        let lockExists = FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(
                FileBackedSyncOperationIDReservationStore.lockFileName
            ).path
        )
        let stateExists = FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(
                FileBackedSyncOperationIDReservationStore.stateFileName
            ).path
        )
        lock.withLock {
            if calls == 0 {
                firstSawNoFiles = !lockExists && !stateExists
            }
            calls += 1
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
