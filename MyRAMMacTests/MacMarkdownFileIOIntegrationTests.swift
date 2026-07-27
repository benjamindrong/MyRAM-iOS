import Foundation
import XCTest
@testable import MyRAMMac

@MainActor
final class MacMarkdownFileIOIntegrationTests: XCTestCase {
    func testImportFlushFailureBlocksPanelReadPersistencePublicationAndSelection() async {
        var events: [String] = []

        do {
            _ = try await MacMarkdownFileOperationCoordinator().performImport(
                flush: {
                    events.append("flush")
                    return false
                },
                selectSource: {
                    events.append("panel")
                    return URL(fileURLWithPath: "/tmp/blocked.md")
                },
                consume: { _ in
                    events.append("consume")
                    return Note()
                },
                publish: { _ in events.append("publish") },
                present: { _ in events.append("select") }
            )
            XCTFail("Expected the failed flush to stop import")
        } catch {
            XCTAssertEqual(error as? MacMarkdownFileOperationError, .sourceFlushFailed)
        }

        XCTAssertEqual(events, ["flush"])
    }

    func testImportPublishesAndSelectsOnlyAfterCommittedConsumption() async throws {
        var events: [String] = []
        let importedNote = Note(title: "Imported", content: "Exact body")

        let result = try await MacMarkdownFileOperationCoordinator().performImport(
            flush: {
                events.append("flush")
                return true
            },
            selectSource: {
                events.append("panel")
                return URL(fileURLWithPath: "/tmp/imported.md")
            },
            consume: { _ in
                events.append("commit")
                return importedNote
            },
            publish: { note in
                XCTAssertEqual(note.id, importedNote.id)
                events.append("publish")
            },
            present: { note in
                XCTAssertEqual(note.id, importedNote.id)
                events.append("select")
            }
        )

        guard case .importedAndPresented(let presentedNote) = result else {
            return XCTFail("Expected committed note to be presented")
        }
        XCTAssertEqual(presentedNote.id, importedNote.id)
        XCTAssertEqual(events, ["flush", "panel", "commit", "publish", "select"])
    }

    func testImportCancellationStopsBeforeConsumptionWithoutError() async throws {
        var didConsume = false

        let result = try await MacMarkdownFileOperationCoordinator().performImport(
            flush: { true },
            selectSource: { nil },
            consume: { _ in
                didConsume = true
                return Note()
            },
            publish: { _ in },
            present: { _ in }
        )

        guard case .cancelled = result else {
            return XCTFail("Expected cancellation")
        }
        XCTAssertFalse(didConsume)
    }

    func testCommittedImportPresentationFailureReturnsNonRetryableCommittedOutcome() async throws {
        var events: [String] = []
        var importCount = 0
        let importedNote = Note(title: "Imported", content: "Exact body")

        let result = try await MacMarkdownFileOperationCoordinator().performImport(
            flush: {
                events.append("flush")
                return true
            },
            selectSource: {
                events.append("source")
                return URL(fileURLWithPath: "/tmp/imported.md")
            },
            consume: { _ in
                importCount += 1
                events.append("commit")
                return importedNote
            },
            publish: { _ in events.append("publish") },
            present: { _ in
                events.append("present")
                throw MacMarkdownTestError.presentationFailed
            }
        )

        guard case .importedButPresentationFailed(let committedNote, let message) = result else {
            return XCTFail("Expected committed-but-not-presented outcome")
        }
        XCTAssertEqual(committedNote.id, importedNote.id)
        XCTAssertFalse(message.isEmpty)
        XCTAssertEqual(importCount, 1)
        XCTAssertEqual(events, ["flush", "source", "commit", "publish", "present"])
    }

    // MARK: - Coordinator: single-scene basics (regression 8.5)

    func testCoordinatorQueuedURLWaitsForStartupReadiness() {
        let coordinator = MacMarkdownExternalImportCoordinator()
        let sceneID = UUID()
        let url = URL(fileURLWithPath: "/tmp/Startup.md")
        coordinator.enqueue(url: url, sceneID: sceneID)

        XCTAssertNil(
            coordinator.claimNext(sceneID: sceneID, startupIsReady: false)
        )
        XCTAssertEqual(coordinator.pendingRequests.count, 1)

        let claimed = coordinator.claimNext(sceneID: sceneID, startupIsReady: true)
        XCTAssertNotNil(claimed)
        XCTAssertEqual(claimed?.url, url)
    }

    func testCoordinatorQueuedErrorPausesLaterURLUntilAcknowledgment() {
        let coordinator = MacMarkdownExternalImportCoordinator()
        let sceneID = UUID()
        let firstURL = URL(fileURLWithPath: "/tmp/A.md")
        let secondURL = URL(fileURLWithPath: "/tmp/B.md")
        coordinator.enqueue(url: firstURL, sceneID: sceneID)
        coordinator.enqueue(url: secondURL, sceneID: sceneID)

        let first = coordinator.claimNext(sceneID: sceneID, startupIsReady: true)
        let firstID = try! XCTUnwrap(first).id
        coordinator.complete(requestID: firstID, errorMessage: "A failed")

        XCTAssertNil(coordinator.claimNext(sceneID: sceneID, startupIsReady: true))
        XCTAssertEqual(coordinator.pendingRequests.count, 1)
        XCTAssertEqual(coordinator.pendingError?.message, "A failed")

        coordinator.acknowledgeError(sceneID: sceneID)

        let second = coordinator.claimNext(sceneID: sceneID, startupIsReady: true)
        XCTAssertNotNil(second)
        XCTAssertEqual(second?.url, secondURL)
        XCTAssertNil(coordinator.pendingError)
        XCTAssertTrue(coordinator.pendingRequests.isEmpty)
    }

    func testCoordinatorLaterSuccessCannotClearUnacknowledgedError() {
        let coordinator = MacMarkdownExternalImportCoordinator()
        let sceneID = UUID()
        let urlA = URL(fileURLWithPath: "/tmp/A.md")
        let urlB = URL(fileURLWithPath: "/tmp/B.md")
        coordinator.enqueue(url: urlA, sceneID: sceneID)
        let first = coordinator.claimNext(sceneID: sceneID, startupIsReady: true)!
        coordinator.complete(requestID: first.id, errorMessage: "First failure")

        // Stale or wrong-ID completion must not clear the error.
        coordinator.complete(requestID: UUID(), errorMessage: nil)
        XCTAssertEqual(coordinator.pendingError?.message, "First failure")

        // Enqueueing a second URL must not clear the error.
        coordinator.enqueue(url: urlB, sceneID: sceneID)
        XCTAssertEqual(coordinator.pendingError?.message, "First failure")
    }

    func testAcknowledgeErrorRequiresPresentingSceneOwnership() {
        let coordinator = MacMarkdownExternalImportCoordinator()
        let sceneA = UUID()
        let sceneB = UUID()
        let urlA = URL(fileURLWithPath: "/tmp/A.md")
        coordinator.enqueue(url: urlA, sceneID: sceneA)
        let requestA = coordinator.claimNext(sceneID: sceneA, startupIsReady: true)!
        coordinator.complete(requestID: requestA.id, errorMessage: "Scene A Error")

        // Non-presenting scene B tries to acknowledge
        coordinator.acknowledgeError(sceneID: sceneB)
        XCTAssertEqual(coordinator.pendingError?.message, "Scene A Error")
        XCTAssertEqual(coordinator.pendingError?.presentingSceneID, sceneA)

        // Presenting scene A acknowledges
        coordinator.acknowledgeError(sceneID: sceneA)
        XCTAssertNil(coordinator.pendingError)
    }

    // MARK: - 8.1 Two-scene global gate

    func testTwoSceneGlobalGateBlocksSuccessorUntilAcknowledgment() {
        let coordinator = MacMarkdownExternalImportCoordinator()
        let sceneA = UUID()
        let sceneB = UUID()
        let urlA = URL(fileURLWithPath: "/tmp/A.md")
        let urlB = URL(fileURLWithPath: "/tmp/B.md")

        // Step 1–3: scene A fails.
        coordinator.enqueue(url: urlA, sceneID: sceneA)
        let requestA = coordinator.claimNext(sceneID: sceneA, startupIsReady: true)!
        coordinator.complete(requestID: requestA.id, errorMessage: "Read error")

        // Step 4: enqueue valid request B for scene B.
        coordinator.enqueue(url: urlB, sceneID: sceneB)

        // Step 5: scene B cannot claim B before acknowledgment.
        XCTAssertNil(coordinator.claimNext(sceneID: sceneB, startupIsReady: true))

        // Step 6: original error is unchanged.
        XCTAssertEqual(coordinator.pendingError?.message, "Read error")

        // Step 7: presentation ownership moved to scene B without clearing error.
        XCTAssertTrue(coordinator.shouldPresentError(in: sceneB))
        XCTAssertFalse(coordinator.shouldPresentError(in: sceneA))
        XCTAssertEqual(coordinator.pendingError?.message, "Read error")

        // Step 8: acknowledge.
        coordinator.acknowledgeError(sceneID: sceneB)
        XCTAssertNil(coordinator.pendingError)

        // Step 9: scene B can now claim B.
        let requestB = coordinator.claimNext(sceneID: sceneB, startupIsReady: true)
        XCTAssertNotNil(requestB)
        XCTAssertEqual(requestB?.url, urlB)

        // Step 10–11: complete B successfully; claimed and completed exactly once.
        coordinator.complete(requestID: requestB!.id, errorMessage: nil)
        XCTAssertNil(coordinator.activeRequest)
        XCTAssertNil(coordinator.pendingError)
        XCTAssertTrue(coordinator.pendingRequests.isEmpty)
    }

    // MARK: - 8.2 Cross-scene active-operation ownership

    func testSceneBCannotClaimWhileSceneAIsActive() {
        let coordinator = MacMarkdownExternalImportCoordinator()
        let sceneA = UUID()
        let sceneB = UUID()

        // Step 1: scene A claims request A.
        coordinator.enqueue(url: URL(fileURLWithPath: "/tmp/A.md"), sceneID: sceneA)
        let requestA = coordinator.claimNext(sceneID: sceneA, startupIsReady: true)!
        XCTAssertNotNil(coordinator.activeRequest)

        // Step 2–3: scene B enqueues B; cannot claim while A is active.
        coordinator.enqueue(url: URL(fileURLWithPath: "/tmp/B.md"), sceneID: sceneB)
        XCTAssertNil(coordinator.claimNext(sceneID: sceneB, startupIsReady: true))

        // Step 4: complete A.
        coordinator.complete(requestID: requestA.id, errorMessage: nil)
        XCTAssertNil(coordinator.activeRequest)

        // Step 5: B becomes claimable exactly once.
        let requestB = coordinator.claimNext(sceneID: sceneB, startupIsReady: true)
        XCTAssertNotNil(requestB)
        // Claiming again yields nil (already active).
        XCTAssertNil(coordinator.claimNext(sceneID: sceneB, startupIsReady: true))
    }

    // MARK: - 8.3 Arrival ordering

    func testArrivalOrderingAndTargetSceneLocking() {
        let coordinator = MacMarkdownExternalImportCoordinator()
        let sceneA = UUID()
        let sceneB = UUID()
        let sceneC = UUID()
        let urlA = URL(fileURLWithPath: "/tmp/A.md")
        let urlB = URL(fileURLWithPath: "/tmp/B.md")
        let urlC = URL(fileURLWithPath: "/tmp/C.md")

        // Step 1: enqueue A, B, C for different scenes.
        coordinator.enqueue(url: urlA, sceneID: sceneA)
        coordinator.enqueue(url: urlB, sceneID: sceneB)
        coordinator.enqueue(url: urlC, sceneID: sceneC)

        // Step 2: B and C cannot bypass A — only scene A can claim first.
        XCTAssertNil(coordinator.claimNext(sceneID: sceneB, startupIsReady: true))
        XCTAssertNil(coordinator.claimNext(sceneID: sceneC, startupIsReady: true))

        // Step 3: each request is granted only to its target scene.
        let claimedA = coordinator.claimNext(sceneID: sceneA, startupIsReady: true)!
        XCTAssertEqual(claimedA.url, urlA)
        XCTAssertEqual(claimedA.sceneID, sceneA)
        coordinator.complete(requestID: claimedA.id, errorMessage: nil)

        let claimedB = coordinator.claimNext(sceneID: sceneB, startupIsReady: true)!
        XCTAssertEqual(claimedB.url, urlB)
        XCTAssertEqual(claimedB.sceneID, sceneB)
        coordinator.complete(requestID: claimedB.id, errorMessage: nil)

        let claimedC = coordinator.claimNext(sceneID: sceneC, startupIsReady: true)!
        XCTAssertEqual(claimedC.url, urlC)
        XCTAssertEqual(claimedC.sceneID, sceneC)
        coordinator.complete(requestID: claimedC.id, errorMessage: nil)

        // Step 4: completion order follows queue order; queue is now empty.
        XCTAssertTrue(coordinator.pendingRequests.isEmpty)
        XCTAssertNil(coordinator.activeRequest)
        XCTAssertNil(coordinator.pendingError)
    }

    // MARK: - 8.4 Error preservation

    func testErrorPreservationUnderAllNonAcknowledgmentOperations() {
        let coordinator = MacMarkdownExternalImportCoordinator()
        let sceneA = UUID()
        let sceneB = UUID()

        // Establish an unacknowledged error.
        coordinator.enqueue(url: URL(fileURLWithPath: "/tmp/A.md"), sceneID: sceneA)
        let requestA = coordinator.claimNext(sceneID: sceneA, startupIsReady: true)!
        coordinator.complete(requestID: requestA.id, errorMessage: "Injected")
        let originalError = coordinator.pendingError

        // Enqueueing another URL must not clear the error.
        coordinator.enqueue(url: URL(fileURLWithPath: "/tmp/B.md"), sceneID: sceneB)
        XCTAssertEqual(coordinator.pendingError?.message, originalError?.message)

        // A completion call for a non-active (stale) request ID must not clear the error.
        coordinator.complete(requestID: UUID(), errorMessage: nil)
        XCTAssertEqual(coordinator.pendingError?.message, originalError?.message)

        // A claim attempt from another scene must not clear the error.
        XCTAssertNil(coordinator.claimNext(sceneID: sceneB, startupIsReady: true))
        XCTAssertEqual(coordinator.pendingError?.message, originalError?.message)

        // A successful-looking completion for the wrong ID must not clear the error.
        coordinator.complete(requestID: UUID(), errorMessage: nil)
        XCTAssertEqual(coordinator.pendingError?.message, originalError?.message)
    }

    // MARK: - Scene-local File-Operation Seam Tests

    func testSceneLocalFileOperationStateLifecycleAndPanelErrorRecording() {
        var state = MacSceneLocalFileOperationState()

        XCTAssertFalse(state.isOperationInProgress)
        XCTAssertNil(state.panelErrorMessage)

        // beginOperation sets busy flag
        XCTAssertTrue(state.beginOperation())
        XCTAssertTrue(state.isOperationInProgress)

        // Overlapping beginOperation while busy is rejected
        XCTAssertFalse(state.beginOperation())

        // finishOperation clears busy flag and stores panel error message
        state.finishOperation(errorMessage: "Panel Import Failed")
        XCTAssertFalse(state.isOperationInProgress)
        XCTAssertEqual(state.panelErrorMessage, "Panel Import Failed")

        // clearPanelError clears the panel error message
        state.clearPanelError()
        XCTAssertNil(state.panelErrorMessage)
    }

    func testMacMarkdownCommandActionsBuilderEvaluatesSceneLocalStateOnly() {
        // Ready, no selection, idle
        let actionsNoSelection = MacMarkdownCommandActionsBuilder.build(
            isReady: true,
            hasSelectedNote: false,
            isOperationInProgress: false,
            importMarkdown: {},
            exportMarkdown: {}
        )
        XCTAssertTrue(actionsNoSelection.canImport)
        XCTAssertFalse(actionsNoSelection.canExport)

        // Ready, with selection, idle
        let actionsIdle = MacMarkdownCommandActionsBuilder.build(
            isReady: true,
            hasSelectedNote: true,
            isOperationInProgress: false,
            importMarkdown: {},
            exportMarkdown: {}
        )
        XCTAssertTrue(actionsIdle.canImport)
        XCTAssertTrue(actionsIdle.canExport)

        // Busy in current scene -> both disabled
        let actionsBusy = MacMarkdownCommandActionsBuilder.build(
            isReady: true,
            hasSelectedNote: true,
            isOperationInProgress: true,
            importMarkdown: {},
            exportMarkdown: {}
        )
        XCTAssertFalse(actionsBusy.canImport)
        XCTAssertFalse(actionsBusy.canExport)

        // Startup not ready -> both disabled
        let actionsNotReady = MacMarkdownCommandActionsBuilder.build(
            isReady: false,
            hasSelectedNote: true,
            isOperationInProgress: false,
            importMarkdown: {},
            exportMarkdown: {}
        )
        XCTAssertFalse(actionsNotReady.canImport)
        XCTAssertFalse(actionsNotReady.canExport)
    }

    func testExternalErrorInOneSceneDoesNotDisableFileMenuInAnotherScene() {
        let coordinator = MacMarkdownExternalImportCoordinator()
        let sceneA = UUID()
        let sceneB = UUID()

        // Scene A fails external import -> pendingError is active
        coordinator.enqueue(url: URL(fileURLWithPath: "/tmp/A.md"), sceneID: sceneA)
        let requestA = coordinator.claimNext(sceneID: sceneA, startupIsReady: true)!
        coordinator.complete(requestID: requestA.id, errorMessage: "Scene A External Error")

        XCTAssertNotNil(coordinator.pendingError)
        XCTAssertTrue(coordinator.shouldPresentError(in: sceneA))
        XCTAssertFalse(coordinator.shouldPresentError(in: sceneB))

        // External claim gate holds for Scene B
        XCTAssertNil(coordinator.claimNext(sceneID: sceneB, startupIsReady: true))

        // Production seam check: Scene B's command actions depend ONLY on Scene B's readiness, selection, and local busy state
        let sceneBActions = MacMarkdownCommandActionsBuilder.build(
            isReady: true,
            hasSelectedNote: true,
            isOperationInProgress: false,
            importMarkdown: {},
            exportMarkdown: {}
        )
        XCTAssertTrue(sceneBActions.canImport, "Scene B File-menu import must remain enabled despite Scene A external error")
        XCTAssertTrue(sceneBActions.canExport, "Scene B File-menu export must remain enabled despite Scene A external error")
    }

    func testExportFlushFailureBlocksSourceReadPanelAndWrite() async {
        var events: [String] = []

        do {
            _ = try await MacMarkdownFileOperationCoordinator().performExport(
                flush: {
                    events.append("flush")
                    return false
                },
                loadSource: {
                    events.append("load")
                    return MacMarkdownExportSource(title: "Draft", source: "Body")
                },
                selectDestination: { _ in
                    events.append("panel")
                    return URL(fileURLWithPath: "/tmp/blocked.md")
                },
                write: { _, _ in events.append("write") }
            )
            XCTFail("Expected the failed flush to stop export")
        } catch {
            XCTAssertEqual(error as? MacMarkdownFileOperationError, .sourceFlushFailed)
        }

        XCTAssertEqual(events, ["flush"])
    }

    func testExportLoadsLatestCanonicalSourceAfterFlushAndWritesExactRawBody() async throws {
        var canonicalBody = "Before"
        var suggestedFilename: String?
        var writtenSource: String?

        let exported = try await MacMarkdownFileOperationCoordinator().performExport(
            flush: {
                canonicalBody = "Latest\r\n**raw** 👩🏽‍💻"
                return true
            },
            loadSource: {
                MacMarkdownExportSource(title: "Roadmap.md", source: canonicalBody)
            },
            selectDestination: { filename in
                suggestedFilename = filename
                return URL(fileURLWithPath: "/tmp/roadmap.md")
            },
            write: { source, _ in
                writtenSource = source
            }
        )

        XCTAssertTrue(exported)
        XCTAssertEqual(suggestedFilename, "Roadmap.md")
        XCTAssertEqual(writtenSource, "Latest\r\n**raw** 👩🏽‍💻")
        XCTAssertEqual(MarkdownFileWriter.encodedData(for: try XCTUnwrap(writtenSource)), Data(canonicalBody.utf8))
    }

    func testExportCancellationDoesNotWrite() async throws {
        var didWrite = false

        let exported = try await MacMarkdownFileOperationCoordinator().performExport(
            flush: { true },
            loadSource: {
                MacMarkdownExportSource(title: "Draft", source: "Body")
            },
            selectDestination: { _ in nil },
            write: { _, _ in didWrite = true }
        )

        XCTAssertFalse(exported)
        XCTAssertFalse(didWrite)
    }
}

private enum MacMarkdownTestError: Error {
    case presentationFailed
}
