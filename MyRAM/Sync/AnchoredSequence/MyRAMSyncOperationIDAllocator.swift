import Foundation
import AnchoredSequenceCore

protocol SyncOperationIDReserving: Sendable {
    func reserveOperationID() async throws -> SyncOperationID
}

protocol SyncOperationIDReservationTransacting: Sendable {
    func reserveNextOperationID() throws -> SyncOperationID
}

actor MyRAMSyncOperationIDAllocator: SyncOperationIDReserving {
    static let shared = MyRAMSyncOperationIDAllocator(
        transactionStore: FileBackedSyncOperationIDReservationStore()
    )

    private let transactionStore: any SyncOperationIDReservationTransacting

    init(transactionStore: any SyncOperationIDReservationTransacting) {
        self.transactionStore = transactionStore
    }

    func reserveOperationID() async throws -> SyncOperationID {
        // The store owns the entire durable transaction; the actor intentionally caches nothing.
        try transactionStore.reserveNextOperationID()
    }
}
