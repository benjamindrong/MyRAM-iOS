import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum ExpectedEditor: Equatable {
    case none
    case note(UUID)
}

enum EditorLocalFlushOutcome: Equatable {
    case succeeded
    case failed(message: String)
}

enum EditorFlushResult: Equatable {
    case noActiveEditor
    case succeeded(noteID: UUID)
    case expectedEditorUnavailable(noteID: UUID)
    case editorMismatch(expected: ExpectedEditor, actualNoteID: UUID)
    case failed(noteID: UUID, message: String)
}

@MainActor
final class NoteEditorFileOperationBridge: ObservableObject {
    private struct Registration {
        let noteID: UUID
        let flush: @MainActor () -> EditorLocalFlushOutcome
    }

    @Published private(set) var externalOpenRetryRevision = 0

    private var registration: Registration?

    func register(
        noteID: UUID,
        flush: @escaping @MainActor () -> EditorLocalFlushOutcome
    ) {
        registration = Registration(noteID: noteID, flush: flush)
        externalOpenRetryRevision &+= 1
    }

    func unregister(noteID: UUID) {
        guard registration?.noteID == noteID else { return }
        registration = nil
        externalOpenRetryRevision &+= 1
    }

    func notifyPersistenceSucceeded(noteID: UUID) {
        guard registration?.noteID == noteID else { return }
        externalOpenRetryRevision &+= 1
    }

    /// Authorizes the registered editor identity before invoking editor-owned persistence.
    func flushEditor(expected: ExpectedEditor) -> EditorFlushResult {
        switch (expected, registration) {
        case (.none, nil):
            return .noActiveEditor

        case (.none, let registration?):
            return .editorMismatch(
                expected: .none,
                actualNoteID: registration.noteID
            )

        case (.note(let expectedID), nil):
            return .expectedEditorUnavailable(noteID: expectedID)

        case (.note(let expectedID), let registration?):
            guard expectedID == registration.noteID else {
                return .editorMismatch(
                    expected: .note(expectedID),
                    actualNoteID: registration.noteID
                )
            }

            switch registration.flush() {
            case .succeeded:
                return .succeeded(noteID: registration.noteID)
            case .failed(let message):
                return .failed(noteID: registration.noteID, message: message)
            }
        }
    }
}

enum MarkdownImportOperationError: Error, Equatable, LocalizedError {
    case operationInProgress
    case editorPreconditionFailed(EditorFlushResult)
    case unsupportedFileType

    var errorDescription: String? {
        switch self {
        case .operationInProgress:
            return "Another Markdown file operation is already in progress."
        case .editorPreconditionFailed:
            return "The current note could not be saved before continuing."
        case .unsupportedFileType:
            return "The selected file is not a Markdown document."
        }
    }
}

@MainActor
final class MarkdownImportOperationCoordinator: ObservableObject {
    @Published private(set) var isProcessing = false

    private let classifier: MarkdownFileClassifier
    private let reader: MarkdownFileReader

    init(
        classifier: MarkdownFileClassifier = MarkdownFileClassifier(),
        reader: MarkdownFileReader = MarkdownFileReader()
    ) {
        self.classifier = classifier
        self.reader = reader
    }

    func perform<Result>(
        url: URL,
        expectedEditor: ExpectedEditor,
        flushBridge: NoteEditorFileOperationBridge,
        consume: (ImportedMarkdownDocument) throws -> Result
    ) throws -> Result {
        guard !isProcessing else {
            throw MarkdownImportOperationError.operationInProgress
        }

        isProcessing = true
        defer { isProcessing = false }

        let flushResult = flushBridge.flushEditor(expected: expectedEditor)
        switch flushResult {
        case .noActiveEditor, .succeeded:
            break
        case .expectedEditorUnavailable,
             .editorMismatch,
             .failed:
            throw MarkdownImportOperationError.editorPreconditionFailed(
                flushResult
            )
        }

        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        guard classifier.kind(for: url) == .markdown else {
            throw MarkdownImportOperationError.unsupportedFileType
        }

        return try consume(reader.read(from: url))
    }
}

enum ExternalImportRoutingResult<MarkdownResult, MyRAMResult> {
    case markdown(MarkdownResult)
    case myram(MyRAMResult)
}

enum ExternalImportRoutingError: Error, Equatable, LocalizedError {
    case unsupportedFileType

    var errorDescription: String? {
        "The selected file is not a supported MyRAM import format."
    }
}

@MainActor
struct ExternalImportURLRouter {
    private let classifier: MarkdownFileClassifier

    init(classifier: MarkdownFileClassifier = MarkdownFileClassifier()) {
        self.classifier = classifier
    }

    /// Performs metadata-only routing before delegating Markdown body access to its coordinator.
    func route<MarkdownResult, MyRAMResult>(
        url: URL,
        expectedEditor: ExpectedEditor,
        markdownCoordinator: MarkdownImportOperationCoordinator,
        flushBridge: NoteEditorFileOperationBridge,
        importMarkdown: (ImportedMarkdownDocument) throws -> MarkdownResult,
        importMyRAM: (URL) throws -> MyRAMResult
    ) throws -> ExternalImportRoutingResult<MarkdownResult, MyRAMResult> {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        let kind = classifier.kind(for: url)
        if didStartAccessing {
            url.stopAccessingSecurityScopedResource()
        }

        switch kind {
        case .markdown:
            return try .markdown(markdownCoordinator.perform(
                url: url,
                expectedEditor: expectedEditor,
                flushBridge: flushBridge,
                consume: importMarkdown
            ))
        case .myram:
            return try .myram(importMyRAM(url))
        case .unsupported:
            throw ExternalImportRoutingError.unsupportedFileType
        }
    }
}

struct MarkdownExportDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        [MarkdownFileClassifier.markdownContentType]
    }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw MarkdownFileIOError.fileUnavailable
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct PreparedMarkdownExport: Equatable {
    let data: Data
    let filename: String
}

enum MarkdownExportPreparationError: Error, Equatable {
    case sourceFlushFailed
}

@MainActor
struct MarkdownExportPreparationCoordinator {
    /// Captures editor-owned source only after the current editor reports a durable flush.
    func prepare(
        flush: () -> EditorLocalFlushOutcome,
        snapshot: () -> (title: String, source: String)
    ) throws -> PreparedMarkdownExport {
        switch flush() {
        case .succeeded:
            break
        case .failed:
            throw MarkdownExportPreparationError.sourceFlushFailed
        }

        let snapshot = snapshot()
        return PreparedMarkdownExport(
            data: MarkdownFileWriter.encodedData(for: snapshot.source),
            filename: MarkdownFilenamePolicy.exportFilename(for: snapshot.title)
        )
    }
}
