import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum NoteEditorFileOperationFlushResult: Equatable {
    case noActiveEditor
    case succeeded(noteID: UUID)
    case failed(noteID: UUID, message: String)
}

@MainActor
final class NoteEditorFileOperationBridge: ObservableObject {
    private struct Registration {
        let noteID: UUID
        let flush: @MainActor () -> NoteEditorFileOperationFlushResult
    }

    private var registration: Registration?

    func register(
        noteID: UUID,
        flush: @escaping @MainActor () -> NoteEditorFileOperationFlushResult
    ) {
        registration = Registration(noteID: noteID, flush: flush)
    }

    func unregister(noteID: UUID) {
        guard registration?.noteID == noteID else { return }
        registration = nil
    }

    func flushActiveEditor() -> NoteEditorFileOperationFlushResult {
        registration?.flush() ?? .noActiveEditor
    }
}

enum MarkdownImportOperationError: Error, Equatable, LocalizedError {
    case operationInProgress
    case sourceFlushFailed(String)
    case unsupportedFileType

    var errorDescription: String? {
        switch self {
        case .operationInProgress:
            return "Another Markdown file operation is already in progress."
        case .sourceFlushFailed:
            return "The current note could not be saved before importing Markdown."
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
        flushBridge: NoteEditorFileOperationBridge,
        consume: (ImportedMarkdownDocument) throws -> Result
    ) throws -> Result {
        guard !isProcessing else {
            throw MarkdownImportOperationError.operationInProgress
        }

        isProcessing = true
        defer { isProcessing = false }

        switch flushBridge.flushActiveEditor() {
        case .noActiveEditor, .succeeded:
            break
        case .failed(_, let message):
            throw MarkdownImportOperationError.sourceFlushFailed(message)
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
        flush: () -> NoteEditorFileOperationFlushResult,
        snapshot: () -> (title: String, source: String)
    ) throws -> PreparedMarkdownExport {
        switch flush() {
        case .noActiveEditor, .succeeded:
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
