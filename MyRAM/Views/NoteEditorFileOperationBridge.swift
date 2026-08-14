import Foundation
import UniformTypeIdentifiers

struct ImportedMarkdownDocument: Equatable {
    let suggestedTitle: String
    let source: String
}

enum EditorLocalFlushOutcome: Equatable {
    case succeeded
    case failed(message: String)
}

enum ExpectedEditor: Equatable {
    case none
    case note(UUID)
}

enum EditorFlushResult: Equatable {
    case noActiveEditor
    case succeeded(noteID: UUID)
    case expectedEditorUnavailable(noteID: UUID)
    case editorMismatch(expected: ExpectedEditor, actualNoteID: UUID)
    case failed(noteID: UUID, message: String)
}

@MainActor
final class NoteEditorLifecycleDurabilityRegistry {
    static let shared = NoteEditorLifecycleDurabilityRegistry()

    typealias WaitForDurability = @MainActor (UUID) async -> Bool
    typealias RetryRetained = @MainActor () -> Void
    typealias Activation = @MainActor () -> Bool

    private var waitForDurability: WaitForDurability = { _ in true }
    private var retryRetained: RetryRetained = {}
    private var activation: Activation = { SyncBatchAnchoredPayloadCapability.isEnabled }

    private init() {}

    func install(
        waitForDurability: @escaping WaitForDurability,
        retryRetained: @escaping RetryRetained,
        activation: @escaping Activation = { SyncBatchAnchoredPayloadCapability.isEnabled }
    ) {
        self.waitForDurability = waitForDurability
        self.retryRetained = retryRetained
        self.activation = activation
    }

    func awaitDurableCompletion(noteID: UUID) async -> Bool {
        guard activation() else { return true }
        return await waitForDurability(noteID)
    }

    func retryRetainedIfEnabled() {
        guard activation() else { return }
        retryRetained()
    }

#if DEBUG
    func resetForTesting() {
        waitForDurability = { _ in true }
        retryRetained = {}
        activation = { SyncBatchAnchoredPayloadCapability.isEnabled }
    }
#endif
}

@MainActor
final class NoteEditorFileOperationBridge: ObservableObject {
    private struct Registration {
        let noteID: UUID
        let flush: @MainActor () async -> EditorLocalFlushOutcome
    }

    @Published private(set) var externalOpenRetryRevision = 0

    private var registration: Registration?

    func register(
        noteID: UUID,
        flush: @escaping @MainActor () async -> EditorLocalFlushOutcome
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

    /// Authorizes the registered editor identity and any transferred lifecycle-owned
    /// persistence before invoking editor-owned persistence.
    func flushEditor(expected: ExpectedEditor) async -> EditorFlushResult {
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
            guard await NoteEditorLifecycleDurabilityRegistry.shared.awaitDurableCompletion(
                noteID: expectedID
            ) else {
                return .failed(
                    noteID: registration.noteID,
                    message: "Unable to save the current note."
                )
            }

            switch await registration.flush() {
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
    ) async throws -> Result {
        guard !isProcessing else {
            throw MarkdownImportOperationError.operationInProgress
        }
        guard classifier.kind(for: url) == .markdown else {
            throw MarkdownImportOperationError.unsupportedFileType
        }

        isProcessing = true
        defer { isProcessing = false }

        let flushResult = await flushBridge.flushEditor(expected: expectedEditor)
        switch flushResult {
        case .noActiveEditor, .succeeded:
            break
        case .expectedEditorUnavailable, .editorMismatch, .failed:
            throw MarkdownImportOperationError.editorPreconditionFailed(flushResult)
        }

        let source = try reader.readSource(from: url)
        return try consume(ImportedMarkdownDocument(
            suggestedTitle: MarkdownImportedTitle.suggestedTitle(for: url),
            source: source
        ))
    }
}

enum ExternalImportKind: Equatable {
    case markdown
    case myram
    case unsupported
}

enum ExternalImportRoutingResult<MarkdownResult, MyRAMResult> {
    case markdown(MarkdownResult)
    case myram(MyRAMResult)
}

struct ExternalImportURLRouter {
    let classifier: MarkdownFileClassifier

    init(classifier: MarkdownFileClassifier = MarkdownFileClassifier()) {
        self.classifier = classifier
    }

    func route<MarkdownResult, MyRAMResult>(
        url: URL,
        expectedEditor: ExpectedEditor,
        markdownCoordinator: MarkdownImportOperationCoordinator,
        flushBridge: NoteEditorFileOperationBridge,
        importMarkdown: (ImportedMarkdownDocument) throws -> MarkdownResult,
        importMyRAM: (URL) throws -> MyRAMResult
    ) async throws -> ExternalImportRoutingResult<MarkdownResult, MyRAMResult> {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        let kind = classifier.kind(for: url)
        if didStartAccessing {
            url.stopAccessingSecurityScopedResource()
        }

        switch kind {
        case .markdown:
            return .markdown(try await markdownCoordinator.perform(
                url: url,
                expectedEditor: expectedEditor,
                flushBridge: flushBridge,
                consume: importMarkdown
            ))

        case .myram:
            return try .myram(importMyRAM(url))

        case .unsupported:
            throw MarkdownImportOperationError.unsupportedFileType
        }
    }
}

enum MarkdownExportPreparationError: Error, Equatable {
    case localFlushFailed
    case utf8EncodingFailed
}

struct PreparedMarkdownExport: Equatable {
    let filename: String
    let data: Data
}

struct MarkdownExportPreparationCoordinator {
    /// Captures editor-owned source only after the current editor reports a durable flush.
    func prepare(
        flush: () async -> EditorLocalFlushOutcome,
        snapshot: () -> (title: String, source: String)
    ) async throws -> PreparedMarkdownExport {
        switch await flush() {
        case .succeeded:
            break
        case .failed:
            throw MarkdownExportPreparationError.localFlushFailed
        }

        let snapshot = snapshot()
        guard let data = snapshot.source.data(using: .utf8) else {
            throw MarkdownExportPreparationError.utf8EncodingFailed
        }
        return PreparedMarkdownExport(
            filename: MarkdownExportFilename.filename(for: snapshot.title),
            data: data
        )
    }
}

enum MarkdownExternalImportKind: Equatable {
    case markdown
    case myram
    case unsupported
}

struct MarkdownFileClassifier {
    static let markdownContentType = UTType(filenameExtension: "md")
        ?? UTType(importedAs: "net.daringfireball.markdown")

    private let contentTypeProvider: (URL) -> UTType?

    init(contentTypeProvider: @escaping (URL) -> UTType? = { url in
        (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
    }) {
        self.contentTypeProvider = contentTypeProvider
    }

    func kind(for url: URL) -> MarkdownExternalImportKind {
        if url.pathExtension.lowercased() == "myram" {
            return .myram
        }
        if url.pathExtension.lowercased() == "md" {
            return .markdown
        }
        if let type = contentTypeProvider(url),
           type.conforms(to: Self.markdownContentType) {
            return .markdown
        }
        return .unsupported
    }
}

struct MarkdownFileReader {
    private let dataLoader: (URL) throws -> Data

    init(dataLoader: @escaping (URL) throws -> Data = { try Data(contentsOf: $0) }) {
        self.dataLoader = dataLoader
    }

    func readSource(from url: URL) throws -> String {
        let data = try dataLoader(url)
        guard let source = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return source
    }
}

enum MarkdownImportedTitle {
    static func suggestedTitle(for url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stem.isEmpty ? "Untitled" : stem
    }
}

enum MarkdownExportFilename {
    static func filename(for rawTitle: String) -> String {
        let trimmed = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let mapped = trimmed
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\n", with: " ")
            .prefix(80)
        let safe = String(mapped).trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(safe.isEmpty ? "Untitled" : safe).md"
    }
}