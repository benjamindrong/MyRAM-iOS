#if os(macOS)
import Combine
import Foundation

enum MacStartupNetworkingPolicy {
    static let hostedTestModeEnvironmentKey = "MYRAM_HOSTED_TEST_MODE"
    static let disablePeerDiscoveryEnvironmentKey = "MYRAM_DISABLE_PEER_DISCOVERY_FOR_TESTS"

    static func isHostedTest(
        environment: [String: String],
        isXCTestRuntimeLoaded: Bool
    ) -> Bool {
        environment[hostedTestModeEnvironmentKey] == "1"
            || environment["XCTestConfigurationFilePath"] != nil
            || isXCTestRuntimeLoaded
    }

    static func shouldStartNetworking(
        environment: [String: String],
        isXCTestRuntimeLoaded: Bool
    ) -> Bool {
        !isHostedTest(
            environment: environment,
            isXCTestRuntimeLoaded: isXCTestRuntimeLoaded
        ) && environment[disablePeerDiscoveryEnvironmentKey] != "1"
    }

    static var shouldStartNetworkingInCurrentProcess: Bool {
        shouldStartNetworking(
            environment: ProcessInfo.processInfo.environment,
            isXCTestRuntimeLoaded: NSClassFromString("XCTestCase") != nil
        )
    }
}

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
    private let startsNetworking: Bool
    private var startupTask: Task<Void, Never>?

    init(startsNetworking: Bool = MacStartupNetworkingPolicy.shouldStartNetworkingInCurrentProcess) {
        self.startsNetworking = startsNetworking
    }

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
                if self?.startsNetworking == true {
                    actions.startNetworkingIfNeeded()
                }
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
