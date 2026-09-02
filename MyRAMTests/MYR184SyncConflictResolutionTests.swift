import XCTest
@testable import MyRAM

final class MYR184SyncConflictResolutionTests: XCTestCase {
    func testDeferredResolutionExactRedeliveryIsIdempotentAndContradictionFailsClosed() throws {
        let store = SyncConflictStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
                .appendingPathComponent("conflicts.json")
        )
        let id = UUID(uuidString: "12345678-1234-8234-9234-123456789abc")!
        let first = conflict(id: id, remoteText: "winner", preservedAt: 10, expiresAt: 20)
        let redelivery = conflict(id: id, remoteText: "winner", preservedAt: 30, expiresAt: 40)

        try store.persistDeferredRemoteLifecycleResolutionChecked(first)
        try store.persistDeferredRemoteLifecycleResolutionChecked(redelivery)
        XCTAssertThrowsError(
            try store.persistDeferredRemoteLifecycleResolutionChecked(
                conflict(id: id, remoteText: "contradiction", preservedAt: 30, expiresAt: 40)
            )
        )
    }

    func testMalformedVersion8ResolutionFailsClosed() throws {
        let malformed = conflict(
            id: UUID(uuidString: "12345678-1234-8234-9234-123456789abc")!,
            remoteText: "winner",
            preservedAt: 10,
            expiresAt: 20,
            noteID: nil
        )
        XCTAssertThrowsError(try SyncDeferredRemoteLifecycleResolution(conflict: malformed, receivedAt: Date()).validate())
    }

    private func conflict(
        id: UUID,
        remoteText: String,
        preservedAt: TimeInterval,
        expiresAt: TimeInterval,
        noteID: UUID? = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    ) -> SyncConflictVersion {
        let entityID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        return SyncConflictVersion(
            id: id,
            entityType: .note,
            entityID: entityID,
            noteID: noteID,
            field: .noteContent,
            localText: "local",
            remoteText: remoteText,
            remoteModifiedAt: Date(timeIntervalSince1970: 5),
            preservedAt: Date(timeIntervalSince1970: preservedAt),
            expiresAt: Date(timeIntervalSince1970: expiresAt)
        )
    }
}
