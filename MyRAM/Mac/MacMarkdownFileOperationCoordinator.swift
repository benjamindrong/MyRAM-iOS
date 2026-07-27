#if os(macOS)
import Foundation

struct MacMarkdownExportSource: Equatable {
    let title: String
    let source: String
}

enum MacMarkdownFileOperationError: LocalizedError, Equatable {
    case sourceFlushFailed
    case selectedNoteUnavailable

    var errorDescription: String? {
        switch self {
        case .sourceFlushFailed:
            return "The current note could not be saved before the Markdown file operation."
        case .selectedNoteUnavailable:
            return "The selected note is no longer available to export."
        }
    }
}

enum MacMarkdownImportResult {
    case cancelled
    case importedAndPresented(Note)
    case importedButPresentationFailed(Note, message: String)
}

struct MacMarkdownOpenURLQueue {
    private(set) var pendingURLs: [URL] = []
    private(set) var errorMessage: String?

    mutating func enqueue(_ url: URL) {
        pendingURLs.append(url)
    }

    /// Keeps queued work paused while the user-facing error remains unacknowledged.
    mutating func takeNextIfReady(
        startupIsReady: Bool,
        operationIsInProgress: Bool
    ) -> URL? {
        guard startupIsReady,
              !operationIsInProgress,
              errorMessage == nil,
              !pendingURLs.isEmpty else {
            return nil
        }
        return pendingURLs.removeFirst()
    }

    mutating func recordCompletion(errorMessage newErrorMessage: String?) {
        guard let newErrorMessage, errorMessage == nil else { return }
        errorMessage = newErrorMessage
    }

    mutating func acknowledgeError() {
        errorMessage = nil
    }
}

@MainActor
struct MacMarkdownFileOperationCoordinator {
    /// Owns ordering so a failed editor flush cannot present a panel or reach file/model work.
    func performImport(
        flush: () async -> Bool,
        selectSource: () -> URL?,
        consume: (URL) throws -> Note,
        publish: (Note) async -> Void,
        present: (Note) throws -> Void
    ) async throws -> MacMarkdownImportResult {
        guard await flush() else {
            throw MacMarkdownFileOperationError.sourceFlushFailed
        }
        guard let url = selectSource() else {
            return .cancelled
        }

        let note = try consume(url)
        await publish(note)
        do {
            try present(note)
            return .importedAndPresented(note)
        } catch {
            return .importedButPresentationFailed(
                note,
                message: error.localizedDescription
            )
        }
    }

    /// Loads canonical source only after the editor flush, then writes only after destination choice.
    func performExport(
        flush: () async -> Bool,
        loadSource: () throws -> MacMarkdownExportSource?,
        selectDestination: (String) -> URL?,
        write: (String, URL) throws -> Void
    ) async throws -> Bool {
        guard await flush() else {
            throw MacMarkdownFileOperationError.sourceFlushFailed
        }
        guard let exportSource = try loadSource() else {
            throw MacMarkdownFileOperationError.selectedNoteUnavailable
        }
        guard let url = selectDestination(
            MarkdownFilenamePolicy.exportFilename(for: exportSource.title)
        ) else {
            return false
        }

        try write(exportSource.source, url)
        return true
    }
}
#endif
