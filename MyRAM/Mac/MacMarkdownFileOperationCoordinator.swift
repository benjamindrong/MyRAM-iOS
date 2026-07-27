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

@MainActor
struct MacMarkdownFileOperationCoordinator {
    /// Owns ordering so a failed editor flush cannot present a panel or reach file/model work.
    func performImport(
        flush: () async -> Bool,
        selectSource: () -> URL?,
        consume: (URL) throws -> Note,
        publish: (Note) async -> Void,
        present: (Note) throws -> Void
    ) async throws -> Bool {
        guard await flush() else {
            throw MacMarkdownFileOperationError.sourceFlushFailed
        }
        guard let url = selectSource() else {
            return false
        }

        let note = try consume(url)
        await publish(note)
        try present(note)
        return true
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
