import SwiftData
import XCTest
@testable import MyRAMMac

@MainActor
final class MacStartupCoordinatorTests: XCTestCase {
    func testMacStartupMigrationPrecedesLoadCreationConvergenceNetworkingAndEditorExposure() async {
        let coordinator = MacStartupCoordinator(startsNetworking: true)
        var events: [String] = []

        coordinator.startIfNeeded(actions: .init(
            migrateNoteSequenceStates: { events.append("migration") },
            loadNotesCreatingFirstIfNeeded: { events.append("load-or-create") },
            configureConvergenceIfNeeded: { events.append("configure-convergence") },
            startNetworkingIfNeeded: { events.append("networking") },
            resumePendingConvergence: { events.append("resume-convergence") }
        ))
        await waitUntil { coordinator.state == .ready }

        XCTAssertEqual(
            events,
            [
                "migration",
                "load-or-create",
                "configure-convergence",
                "networking",
                "resume-convergence"
            ]
        )
        XCTAssertEqual(coordinator.state, .ready)
    }

    func testMacStartupHostedTestDefaultKeepsPeerDiscoveryUnavailable() async {
        let coordinator = MacStartupCoordinator()
        var events: [String] = []

        coordinator.startIfNeeded(actions: .init(
            migrateNoteSequenceStates: { events.append("migration") },
            loadNotesCreatingFirstIfNeeded: { events.append("load-or-create") },
            configureConvergenceIfNeeded: { events.append("configure-convergence") },
            startNetworkingIfNeeded: { events.append("networking") },
            resumePendingConvergence: { events.append("resume-convergence") }
        ))
        await waitUntil { coordinator.state == .ready }

        XCTAssertEqual(
            events,
            [
                "migration",
                "load-or-create",
                "configure-convergence",
                "resume-convergence"
            ]
        )
        XCTAssertEqual(coordinator.state, .ready)
    }

    func testMacStartupNetworkingPolicyDisablesNetworkingForXCTestEnvironment() {
        XCTAssertFalse(
            MacStartupNetworkingPolicy.shouldStartNetworking(
                environment: ["XCTestConfigurationFilePath": "/tmp/MyRAMMacTests.xctestconfiguration"]
            )
        )
    }

    func testMacStartupNetworkingPolicyKeepsNetworkingEnabledOutsideXCTest() {
        XCTAssertTrue(
            MacStartupNetworkingPolicy.shouldStartNetworking(environment: [:])
        )
    }

    func testMacStartupMigrationFailureKeepsCreationEditingConvergenceAndNetworkingUnavailable() async {
        let coordinator = MacStartupCoordinator()
        var events: [String] = []

        coordinator.startIfNeeded(actions: .init(
            migrateNoteSequenceStates: {
                events.append("migration")
                throw MacStartupTestError.injected
            },
            loadNotesCreatingFirstIfNeeded: { events.append("load-or-create") },
            configureConvergenceIfNeeded: { events.append("configure-convergence") },
            startNetworkingIfNeeded: { events.append("networking") },
            resumePendingConvergence: { events.append("resume-convergence") }
        ))
        await waitUntil {
            if case .failed = coordinator.state { return true }
            return false
        }

        XCTAssertEqual(events, ["migration"])
        guard case .failed = coordinator.state else {
            return XCTFail("The Mac editor gate must remain closed after migration failure")
        }
    }

    func testMacStartupRepeatedAppearancesShareOneBootstrapFlight() async {
        let coordinator = MacStartupCoordinator()
        let gate = MacStartupTestGate()
        var migrationCalls = 0
        var readyCalls = 0
        let actions = MacStartupCoordinator.Actions(
            migrateNoteSequenceStates: {
                migrationCalls += 1
                await gate.wait()
            },
            loadNotesCreatingFirstIfNeeded: { readyCalls += 1 },
            configureConvergenceIfNeeded: {},
            startNetworkingIfNeeded: {},
            resumePendingConvergence: {}
        )

        coordinator.startIfNeeded(actions: actions)
        coordinator.startIfNeeded(actions: actions)
        await waitUntil { migrationCalls == 1 }
        gate.release()
        await waitUntil { coordinator.state == .ready }
        coordinator.startIfNeeded(actions: actions)

        XCTAssertEqual(migrationCalls, 1)
        XCTAssertEqual(readyCalls, 1)
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<1_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Condition did not become true", file: file, line: line)
    }
}

@MainActor
private final class MacStartupTestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false

    func wait() async {
        if isReleased { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

private enum MacStartupTestError: Error {
    case injected
}
