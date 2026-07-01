#if os(macOS)
import Foundation

struct MacSyncSeenBatchStore {
    static let seenBatchIDsKey = "myram.macSync.seenBatchIDs"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func hasSeen(_ batchID: MacSyncBatchID) -> Bool {
        seenBatchIDStrings.contains(batchID.uuidString)
    }

    func markSeen(_ batchID: MacSyncBatchID) {
        var seenIDs = seenBatchIDStrings
        seenIDs.insert(batchID.uuidString)
        // TODO: Add size or age-based pruning before production transport can grow this indefinitely.
        defaults.set(Array(seenIDs).sorted(), forKey: Self.seenBatchIDsKey)
    }

    private var seenBatchIDStrings: Set<String> {
        Set(defaults.stringArray(forKey: Self.seenBatchIDsKey) ?? [])
    }
}
#endif
