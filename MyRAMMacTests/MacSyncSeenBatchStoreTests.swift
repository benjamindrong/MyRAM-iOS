import XCTest
@testable import MyRAMMac

final class MacSyncSeenBatchStoreTests: XCTestCase {
    func testMarkSeenPersistsBatchIDAcrossStoreInstances() {
        let defaults = makeDefaults()
        let batchID = UUID(uuidString: "00000000-0000-0000-0000-000000001001")!

        MacSyncSeenBatchStore(defaults: defaults).markSeen(batchID)

        XCTAssertTrue(MacSyncSeenBatchStore(defaults: defaults).hasSeen(batchID))
    }

    func testUnseenBatchIDReturnsFalse() {
        let store = MacSyncSeenBatchStore(defaults: makeDefaults())

        XCTAssertFalse(store.hasSeen(UUID(uuidString: "00000000-0000-0000-0000-000000001002")!))
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "MacSyncSeenBatchStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
