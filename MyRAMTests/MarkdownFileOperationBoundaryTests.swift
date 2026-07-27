import Foundation
import XCTest
@testable import MyRAM

@MainActor
final class MarkdownFileOperationBoundaryTests: XCTestCase {
    func testExpectedNoneWithoutRegistrationReturnsNoActiveEditor() {
        XCTAssertEqual(
            NoteEditorFileOperationBridge().flushEditor(expected: .none),
            .noActiveEditor
        )
    }

    func testExpectedNoneWithRegistrationRejectsMismatchWithoutInvokingClosure() {
        let bridge = NoteEditorFileOperationBridge()
        let noteID = UUID()
        var didFlush = false
        bridge.register(noteID: noteID) {
            didFlush = true
            return .succeeded
        }

        XCTAssertEqual(
            bridge.flushEditor(expected: .none),
            .editorMismatch(expected: .none, actualNoteID: noteID)
        )
        XCTAssertFalse(didFlush)
    }

    func testMatchingExpectedEditorReturnsBridgeOwnedIdentity() {
        let bridge = NoteEditorFileOperationBridge()
        let noteID = UUID()
        bridge.register(noteID: noteID) { .succeeded }

        XCTAssertEqual(
            bridge.flushEditor(expected: .note(noteID)),
            .succeeded(noteID: noteID)
        )
    }

    func testExpectedEditorWithoutRegistrationReturnsUnavailableWithoutFlush() {
        let noteID = UUID()

        XCTAssertEqual(
            NoteEditorFileOperationBridge().flushEditor(expected: .note(noteID)),
            .expectedEditorUnavailable(noteID: noteID)
        )
    }

    func testExpectedEditorMismatchDoesNotInvokeWrongClosure() {
        let bridge = NoteEditorFileOperationBridge()
        let expectedID = UUID()
        let registeredID = UUID()
        var didFlush = false
        bridge.register(noteID: registeredID) {
            didFlush = true
            return .succeeded
        }

        XCTAssertEqual(
            bridge.flushEditor(expected: .note(expectedID)),
            .editorMismatch(
                expected: .note(expectedID),
                actualNoteID: registeredID
            )
        )
        XCTAssertFalse(didFlush)
    }

    func testBridgeAttachesIdentityToLocalFailure() {
        let bridge = NoteEditorFileOperationBridge()
        let noteID = UUID()
        bridge.register(noteID: noteID) {
            .failed(message: "Injected failure")
        }

        XCTAssertEqual(
            bridge.flushEditor(expected: .note(noteID)),
            .failed(noteID: noteID, message: "Injected failure")
        )
    }

    func testStaleUnregisterCannotClearNewerEditor() {
        let bridge = NoteEditorFileOperationBridge()
        let oldID = UUID()
        let currentID = UUID()
        bridge.register(noteID: oldID) { .succeeded }
        bridge.register(noteID: currentID) { .succeeded }

        bridge.unregister(noteID: oldID)

        XCTAssertEqual(
            bridge.flushEditor(expected: .note(currentID)),
            .succeeded(noteID: currentID)
        )
    }

    func testFlushFailurePreventsReadAndConsumptionAndPreservesDiagnosticResult() {
        let noteID = UUID()
        let bridge = NoteEditorFileOperationBridge()
        bridge.register(noteID: noteID) {
            .failed(message: "Injected failure")
        }
        var didRead = false
        var didConsume = false
        let coordinator = makeMarkdownCoordinator { _ in
            didRead = true
            return Data()
        }

        XCTAssertThrowsError(try coordinator.perform(
            url: URL(fileURLWithPath: "/tmp/Blocked.md"),
            expectedEditor: .note(noteID),
            flushBridge: bridge,
            consume: { _ in
                didConsume = true
            }
        )) {
            XCTAssertEqual(
                $0 as? MarkdownImportOperationError,
                .editorPreconditionFailed(
                    .failed(noteID: noteID, message: "Injected failure")
                )
            )
            XCTAssertEqual(
                ($0 as? LocalizedError)?.errorDescription,
                "The current note could not be saved before continuing."
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
            return .succeeded
        }
        let coordinator = makeMarkdownCoordinator { _ in
            events.append("read")
            return Data("body".utf8)
        }

        let source = try coordinator.perform(
            url: URL(fileURLWithPath: "/tmp/Allowed.md"),
            expectedEditor: .note(noteID),
            flushBridge: bridge,
            consume: { document in
                events.append("consume")
                return document.source
            }
        )

        XCTAssertEqual(source, "body")
        XCTAssertEqual(events, ["flush", "read", "consume"])
    }

    func testProductionRouterMarkdownSuccessOrdersAuthorizationBeforeBodyAndCommitEffects() throws {
        var events: [String] = []
        let noteID = UUID()
        let bridge = NoteEditorFileOperationBridge()
        bridge.register(noteID: noteID) {
            events.append("flush")
            return .succeeded
        }
        let coordinator = makeMarkdownCoordinator { _ in
            events.append("read")
            return Data("body".utf8)
        }
        let router = ExternalImportURLRouter(classifier: MarkdownFileClassifier(
            contentTypeProvider: { _ in
                events.append("classify")
                return MarkdownFileClassifier.markdownContentType
            }
        ))

        let result: ExternalImportRoutingResult<String, Void> = try router.route(
            url: URL(fileURLWithPath: "/tmp/External.data"),
            expectedEditor: .note(noteID),
            markdownCoordinator: coordinator,
            flushBridge: bridge,
            importMarkdown: { document in
                events.append(contentsOf: [
                    "commit",
                    "publish",
                    "undo",
                    "refresh",
                    "select"
                ])
                return document.source
            },
            importMyRAM: { _ in XCTFail("Unexpected .myram import") }
        )

        guard case .markdown(let source) = result else {
            return XCTFail("Expected Markdown route")
        }
        XCTAssertEqual(source, "body")
        XCTAssertEqual(events, [
            "classify",
            "flush",
            "read",
            "commit",
            "publish",
            "undo",
            "refresh",
            "select"
        ])
    }

    func testProductionRouterMarkdownFlushFailureHasZeroDownstreamEffects() {
        let noteID = UUID()
        let bridge = NoteEditorFileOperationBridge()
        bridge.register(noteID: noteID) { .failed(message: "Injected") }
        assertMarkdownRouteBlocked(
            expectedEditor: .note(noteID),
            bridge: bridge,
            expectedResult: .failed(noteID: noteID, message: "Injected")
        )
    }

    func testProductionRouterMarkdownMismatchDoesNotInvokeWrongEditorOrDownstreamEffects() {
        let expectedID = UUID()
        let actualID = UUID()
        let bridge = NoteEditorFileOperationBridge()
        var didFlush = false
        bridge.register(noteID: actualID) {
            didFlush = true
            return .succeeded
        }

        assertMarkdownRouteBlocked(
            expectedEditor: .note(expectedID),
            bridge: bridge,
            expectedResult: .editorMismatch(
                expected: .note(expectedID),
                actualNoteID: actualID
            )
        )
        XCTAssertFalse(didFlush)
    }

    func testProductionRouterMarkdownUnavailableHasZeroDownstreamEffects() {
        let expectedID = UUID()
        assertMarkdownRouteBlocked(
            expectedEditor: .note(expectedID),
            bridge: NoteEditorFileOperationBridge(),
            expectedResult: .expectedEditorUnavailable(noteID: expectedID)
        )
    }

    func testProductionRouterKeepsMyRAMOnExistingImporterPath() throws {
        var didReadMarkdown = false
        var didImportMarkdown = false
        var importedMyRAMURL: URL?
        let url = URL(fileURLWithPath: "/tmp/Archive.myram")
        let router = ExternalImportURLRouter(classifier: MarkdownFileClassifier(
            contentTypeProvider: { _ in nil }
        ))

        let result: ExternalImportRoutingResult<Void, String> = try router.route(
            url: url,
            expectedEditor: .none,
            markdownCoordinator: makeMarkdownCoordinator { _ in
                didReadMarkdown = true
                return Data()
            },
            flushBridge: NoteEditorFileOperationBridge(),
            importMarkdown: { _ in didImportMarkdown = true },
            importMyRAM: {
                importedMyRAMURL = $0
                return "myram"
            }
        )

        guard case .myram(let value) = result else {
            return XCTFail("Expected .myram route")
        }
        XCTAssertEqual(value, "myram")
        XCTAssertEqual(importedMyRAMURL, url)
        XCTAssertFalse(didReadMarkdown)
        XCTAssertFalse(didImportMarkdown)
    }

    func testProductionRouterUnsupportedInvokesNeitherImporter() {
        var didReadMarkdown = false
        var didImportMarkdown = false
        var didImportMyRAM = false
        let router = ExternalImportURLRouter(classifier: MarkdownFileClassifier(
            contentTypeProvider: { _ in nil }
        ))

        XCTAssertThrowsError(try router.route(
            url: URL(fileURLWithPath: "/tmp/Archive.txt"),
            expectedEditor: .none,
            markdownCoordinator: makeMarkdownCoordinator { _ in
                didReadMarkdown = true
                return Data()
            },
            flushBridge: NoteEditorFileOperationBridge(),
            importMarkdown: { _ in didImportMarkdown = true },
            importMyRAM: { _ in didImportMyRAM = true }
        )) {
            XCTAssertEqual(
                $0 as? ExternalImportRoutingError,
                .unsupportedFileType
            )
        }
        XCTAssertFalse(didReadMarkdown)
        XCTAssertFalse(didImportMarkdown)
        XCTAssertFalse(didImportMyRAM)
    }

    func testExportFlushFailurePreventsSourceCapture() {
        var didCaptureSource = false

        XCTAssertThrowsError(
            try MarkdownExportPreparationCoordinator().prepare(
                flush: {
                    .failed(message: "Injected failure")
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

    func testExportCapturesLatestRawSourceOnlyAfterSuccessfulLocalFlush() throws {
        var rawSource = "Before"
        var events: [String] = []

        let prepared = try MarkdownExportPreparationCoordinator().prepare(
            flush: {
                events.append("local-flush")
                rawSource = "Latest\r\n**literal**"
                return .succeeded
            },
            snapshot: {
                events.append("snapshot")
                return (title: "Roadmap.md", source: rawSource)
            }
        )

        XCTAssertEqual(events, ["local-flush", "snapshot"])
        XCTAssertEqual(prepared.filename, "Roadmap.md")
        XCTAssertEqual(prepared.data, Data("Latest\r\n**literal**".utf8))
    }

    func testExportDoesNotConsultAnotherEditorsBridgeRegistration() throws {
        let bridge = NoteEditorFileOperationBridge()
        var didInvokeBridge = false
        bridge.register(noteID: UUID()) {
            didInvokeBridge = true
            return .failed(message: "Wrong editor")
        }

        let prepared = try MarkdownExportPreparationCoordinator().prepare(
            flush: { .succeeded },
            snapshot: { (title: "Local", source: "Editor-owned") }
        )

        XCTAssertFalse(didInvokeBridge)
        XCTAssertEqual(prepared.data, Data("Editor-owned".utf8))
    }

    private func assertMarkdownRouteBlocked(
        expectedEditor: ExpectedEditor,
        bridge: NoteEditorFileOperationBridge,
        expectedResult: EditorFlushResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var bodyReadCount = 0
        var persistenceCount = 0
        var publicationCount = 0
        var undoCount = 0
        var refreshCount = 0
        var selectionCount = 0
        let router = ExternalImportURLRouter(classifier: MarkdownFileClassifier(
            contentTypeProvider: { _ in MarkdownFileClassifier.markdownContentType }
        ))

        XCTAssertThrowsError(try router.route(
            url: URL(fileURLWithPath: "/tmp/Blocked.md"),
            expectedEditor: expectedEditor,
            markdownCoordinator: makeMarkdownCoordinator { _ in
                bodyReadCount += 1
                return Data()
            },
            flushBridge: bridge,
            importMarkdown: { _ in
                persistenceCount += 1
                publicationCount += 1
                undoCount += 1
                refreshCount += 1
                selectionCount += 1
            },
            importMyRAM: { _ in XCTFail("Unexpected .myram import", file: file, line: line) }
        )) {
            XCTAssertEqual(
                $0 as? MarkdownImportOperationError,
                .editorPreconditionFailed(expectedResult),
                file: file,
                line: line
            )
        }
        XCTAssertEqual(bodyReadCount, 0, file: file, line: line)
        XCTAssertEqual(persistenceCount, 0, file: file, line: line)
        XCTAssertEqual(publicationCount, 0, file: file, line: line)
        XCTAssertEqual(undoCount, 0, file: file, line: line)
        XCTAssertEqual(refreshCount, 0, file: file, line: line)
        XCTAssertEqual(selectionCount, 0, file: file, line: line)
    }

    private func makeMarkdownCoordinator(
        dataLoader: @escaping (URL) throws -> Data
    ) -> MarkdownImportOperationCoordinator {
        MarkdownImportOperationCoordinator(
            classifier: MarkdownFileClassifier(contentTypeProvider: { _ in
                MarkdownFileClassifier.markdownContentType
            }),
            reader: MarkdownFileReader(dataLoader: dataLoader)
        )
    }
}
