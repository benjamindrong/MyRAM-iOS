import Foundation
import SwiftData

@NoteSequenceStatePersistenceActor
final class NoteSequenceStateBootstrapMigrator {
    private let container: ModelContainer
    private let allowsExistingStateReplacement: Bool
    private let beforeEachNote: @Sendable (UUID) throws -> Void

    init(
        container: ModelContainer,
        allowsExistingStateReplacement: Bool = !SyncBatchAnchoredPayloadCapability.isEnabled,
        beforeEachNote: @escaping @Sendable (UUID) throws -> Void = { _ in }
    ) {
        self.container = container
        self.allowsExistingStateReplacement = allowsExistingStateReplacement
        self.beforeEachNote = beforeEachNote
    }

    func runToCompletion() async throws {
        let enumerationContext = ModelContext(container)
        enumerationContext.autosaveEnabled = false
        let noteIDs = try enumerationContext.fetch(FetchDescriptor<Note>())
            .map(\.id)
            .sorted {
                $0.uuidString.lowercased() < $1.uuidString.lowercased()
            }

        let store = SwiftDataNoteSequenceStateStore(container: container)
        for noteID in noteIDs {
            try beforeEachNote(noteID)
            if allowsExistingStateReplacement {
                _ = try await store.ensureBootstrapStateForCurrentBody(noteID: noteID)
                continue
            }

            switch try await store.load(noteID: noteID) {
            case .missing:
                _ = try await store.loadOrBootstrap(noteID: noteID)
            case .present:
                break
            }
        }
    }
}
