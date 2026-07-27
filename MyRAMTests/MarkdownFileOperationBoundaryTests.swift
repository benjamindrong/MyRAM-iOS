import Foundation
import XCTest
@testable import MyRAM

@MainActor
final class MarkdownFileOperationBoundaryTests: XCTestCase {
    func testBridgeReturnsNoActiveEditorWithoutInventingSave() {
        XCTAssertEqual(NoteEditorFileOperationBridge().flushActiveEditor(), .noActiveEditor)
    }

    func testBridgeFlushesCurrentRegistration() {
        let bridge = NoteEditorFileOperationBridge()
        let noteID = UUID()
        bridge.register(noteID: noteID) { .succeeded(noteID: noteID) }

        XCTAssertEqual(bridge.flushActiveEditor(), .succeeded(noteID: noteID))
    }

    func testStaleUnregisterCannotClearNewerEditor() {
        let bridge = NoteEditorFileOperationBridge()
        let oldID = UUID()
        let currentID = UUID()
        bridge.register(noteID: oldID) { .succeeded(noteID: oldID) }
        bridge.register(noteID: currentID) { .succeeded(noteID: currentID) }

        bridge.unregister(noteID: oldID)

        XCTAssertEqual(bridge.flushActiveEditor(), .succeeded(noteID: currentID))
    }

    func testFlushFailurePreventsReadAndConsumption() {
        let noteID = UUID()
        let bridge = NoteEditorFileOperationBridge()
        bridge.register(noteID: noteID) {
            .failed(noteID: noteID, message: "Injected failure")
        }
        var didRead = false
        var didConsume = false
        let coordinator = MarkdownImportOperationCoordinator(
            classifier: MarkdownFileClassifier(contentTypeProvider: { _ in
                MarkdownFileClassifier.markdownContentType
            }),
            reader: MarkdownFileReader(dataLoader: { _ in
                didRead = true
                return Data()
            })
        )

        XCTAssertThrowsError(try coordinator.perform(
            url: URL(fileURLWithPath: "/tmp/Blocked.md"),
            flushBridge: bridge,
            consume: { _ in
                didConsume = true
            }
        )) {
            XCTAssertEqual(
                $0 as? MarkdownImportOperationError,
                .sourceFlushFailed("Injected failure")
            )
        }
        XCTAssertFalse(didRead)
        XCTAssertFalse(didConsume)
    }

    func testSuccessfulFlushPrecedesReadAndConsumption() throws {
        var events: [String] = []
        let noteID = UUID()
        let bridge = NoteEditorFileOperationBridge()
        bridge.register(noteID: noteID) {
            events.append("flush")
            return .succeeded(noteID: noteID)
        }
        let coordinator = MarkdownImportOperationCoordinator(
            classifier: MarkdownFileClassifier(contentTypeProvider: { _ in
                MarkdownFileClassifier.markdownContentType
            }),
            reader: MarkdownFileReader(dataLoader: { _ in
                events.append("read")
                return Data("body".utf8)
            })
        )

        let source = try coordinator.perform(
            url: URL(fileURLWithPath: "/tmp/Allowed.md"),
            flushBridge: bridge,
            consume: { document in
                events.append("consume")
                return document.source
            }
        )

        XCTAssertEqual(source, "body")
        XCTAssertEqual(events, ["flush", "read", "consume"])
    }

    func testTypeOnlyRoutingDoesNotReadFileBody() {
        var didRead = false
        let classifier = MarkdownFileClassifier(contentTypeProvider: { _ in
            MarkdownFileClassifier.markdownContentType
        })
        _ = MarkdownFileReader(dataLoader: { _ in
            didRead = true
            return Data()
        })

        XCTAssertEqual(classifier.kind(for: URL(fileURLWithPath: "/tmp/External.data")), .markdown)
        XCTAssertFalse(didRead)
    }

    func testExportFlushFailurePreventsSourceCapture() {
        var didCaptureSource = false

        XCTAssertThrowsError(
            try MarkdownExportPreparationCoordinator().prepare(
                flush: {
                    .failed(noteID: UUID(), message: "Injected failure")
                },
                snapshot: {
                    didCaptureSource = true
                    return (title: "Draft", source: "Unsaved")
                }
            )
        ) { error in
            XCTAssertEqual(error as? MarkdownExportPreparationError, .sourceFlushFailed)
        }
        XCTAssertFalse(didCaptureSource)
    }

    func testExportCapturesLatestRawSourceOnlyAfterSuccessfulFlush() throws {
        var rawSource = "Before"
        var events: [String] = []

        let prepared = try MarkdownExportPreparationCoordinator().prepare(
            flush: {
                events.append("flush")
                rawSource = "Latest\r\n**literal**"
                return .succeeded(noteID: UUID())
            },
            snapshot: {
                events.append("snapshot")
                return (title: "Roadmap.md", source: rawSource)
            }
        )

        XCTAssertEqual(events, ["flush", "snapshot"])
        XCTAssertEqual(prepared.filename, "Roadmap.md")
        XCTAssertEqual(prepared.data, Data("Latest\r\n**literal**".utf8))
    }
}
