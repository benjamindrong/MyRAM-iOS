#if os(macOS)
import Combine
import Foundation

@MainActor
final class MacStartupCoordinator: ObservableObject {
    enum State: Equatable {
        case idle
        case running
        case ready
        case failed(String)
    }

    struct Actions {
        var migrateNoteSequenceStates: @MainActor () async throws -> Void
        var loadNotesCreatingFirstIfNeeded: @MainActor () throws -> Void
        var configureConvergenceIfNeeded: @MainActor () -> Void
        var startNetworkingIfNeeded: @MainActor () -> Void
        var resumePendingConvergence: @MainActor () -> Void
    }

    @Published private(set) var state: State = .idle
    private var startupTask: Task<Void, Never>?

    deinit {
        startupTask?.cancel()
    }

    /// Retains one startup flight so transient view appearances cannot restart migration.
    func startIfNeeded(actions: Actions) {
        guard state == .idle else { return }
        state = .running
        startupTask = Task { @MainActor [weak self] in
            do {
                try await actions.migrateNoteSequenceStates()
                try actions.loadNotesCreatingFirstIfNeeded()
                actions.configureConvergenceIfNeeded()
                actions.startNetworkingIfNeeded()
                actions.resumePendingConvergence()
                self?.state = .ready
            } catch {
                self?.state = .failed(
                    "Unable to prepare MyRAM: \(error.localizedDescription)"
                )
            }
            self?.startupTask = nil
        }
    }
}
#endif
