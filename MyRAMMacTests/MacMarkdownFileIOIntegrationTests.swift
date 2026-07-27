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

    func testQueuedErrorPausesLaterURLUntilAcknowledgment() throws {
        let firstURL = URL(fileURLWithPath: "/tmp/A.md")
        let secondURL = URL(fileURLWithPath: "/tmp/B.md")
        var queue = MacMarkdownOpenURLQueue()
        queue.enqueue(firstURL)
        queue.enqueue(secondURL)

        XCTAssertEqual(
            queue.takeNextIfReady(startupIsReady: true, operationIsInProgress: false),
            firstURL
        )
        queue.recordCompletion(errorMessage: "A failed")

        XCTAssertNil(
            queue.takeNextIfReady(startupIsReady: true, operationIsInProgress: false)
        )
        XCTAssertEqual(queue.pendingURLs, [secondURL])
        XCTAssertEqual(queue.errorMessage, "A failed")

        queue.acknowledgeError()

        XCTAssertEqual(
            queue.takeNextIfReady(startupIsReady: true, operationIsInProgress: false),
            secondURL
        )
        XCTAssertNil(queue.errorMessage)
        XCTAssertTrue(queue.pendingURLs.isEmpty)
    }

    func testLaterSuccessCannotClearUnacknowledgedQueuedError() {
        var queue = MacMarkdownOpenURLQueue()
        queue.recordCompletion(errorMessage: "First failure")
        queue.recordCompletion(errorMessage: nil)

        XCTAssertEqual(queue.errorMessage, "First failure")
    }

    func testQueuedURLWaitsForStartupReadiness() {
        let url = URL(fileURLWithPath: "/tmp/Startup.md")
        var queue = MacMarkdownOpenURLQueue()
        queue.enqueue(url)

        XCTAssertNil(
            queue.takeNextIfReady(startupIsReady: false, operationIsInProgress: false)
        )
        XCTAssertEqual(queue.pendingURLs, [url])
        XCTAssertEqual(
            queue.takeNextIfReady(startupIsReady: true, operationIsInProgress: false),
            url
        )
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
