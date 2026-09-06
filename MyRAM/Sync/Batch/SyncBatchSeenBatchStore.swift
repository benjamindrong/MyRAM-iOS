import Foundation

struct SyncBatchSeenBatchStore {
    static let defaultSeenBatchIDsKey = "myram.syncBatch.seenBatchIDs"

    private let defaults: UserDefaults
    private let key: String
    private let maximumStoredBatchIDs: Int

    init(
        defaults: UserDefaults = .standard,
        key: String = MyRAMSyncBenchmarkConfiguration.enduranceUserDefaultsKey(Self.defaultSeenBatchIDsKey),
        maximumStoredBatchIDs: Int = 2_000
    ) {
        self.defaults = defaults
        self.key = key
        self.maximumStoredBatchIDs = maximumStoredBatchIDs
    }

    func hasSeen(_ batchID: SyncBatchID) -> Bool {
        seenBatchIDStrings.contains(batchID.uuidString)
    }

    func markSeen(_ batchID: SyncBatchID) {
        var seenIDs = orderedSeenBatchIDStrings.filter { $0 != batchID.uuidString }
        seenIDs.append(batchID.uuidString)
        if seenIDs.count > maximumStoredBatchIDs {
            seenIDs.removeFirst(seenIDs.count - maximumStoredBatchIDs)
        }
        defaults.set(seenIDs, forKey: key)
    }

    private var seenBatchIDStrings: Set<String> {
        Set(orderedSeenBatchIDStrings)
    }

    private var orderedSeenBatchIDStrings: [String] {
        defaults.stringArray(forKey: key) ?? []
    }
}
