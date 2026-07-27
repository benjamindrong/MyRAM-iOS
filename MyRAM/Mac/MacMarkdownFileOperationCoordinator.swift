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

/// Application-scoped coordinator that enforces a single active external-import
/// request across all scenes and holds every scene's drain gate open until any
/// unacknowledged error is explicitly dismissed.
///
/// Invariants (enforced structurally, not by post-hoc rejection):
///   1. At most one `activeRequest` exists application-wide at any moment.
///   2. `claimNext` returns nil while a `pendingError` exists.
///   3. `claimNext` grants only the request whose `sceneID` matches the caller.
///   4. `complete` is a no-op when `requestID` does not match `activeRequest`.
///   5. `enqueue` never touches `pendingError`.
///   6. `acknowledgeError` is the only path that clears `pendingError`.
///   7. When a URL arrives while an error is pending, presentation ownership
///      transfers to the newly active scene without clearing or replacing the error.
@MainActor
final class MacMarkdownExternalImportCoordinator: ObservableObject {
    struct Request: Equatable {
        let id: UUID
        let sceneID: UUID
        let url: URL
    }

    struct PendingError: Equatable {
        let requestID: UUID
        let message: String
        var presentingSceneID: UUID
    }

    /// Incremented on every state change so scenes can react via `.onChange(of: revision)`.
    @Published private(set) var revision = 0
    private(set) var pendingRequests: [Request] = []
    private(set) var activeRequest: Request?
    private(set) var pendingError: PendingError?

    /// Records a new external Open With URL associated with the given scene.
    /// If a `pendingError` exists, presentation ownership transfers to `sceneID`
    /// so the error remains visible in the scene that is now active; the error
    /// message and the import gate are not changed.
    func enqueue(url: URL, sceneID: UUID) {
        let request = Request(id: UUID(), sceneID: sceneID, url: url)
        pendingRequests.append(request)
        if pendingError != nil {
            pendingError?.presentingSceneID = sceneID
        }
        bumpRevision()
    }

    /// Returns the next pending request whose `sceneID` matches, provided startup
    /// is ready, no request is already active, and no error awaits acknowledgment.
    /// Only the scene that owns the first request in the queue may claim; later
    /// requests cannot bypass earlier ones from other scenes.
    /// Returns `nil` in all other cases without mutating state.
    func claimNext(sceneID: UUID, startupIsReady: Bool) -> Request? {
        guard startupIsReady,
              activeRequest == nil,
              pendingError == nil,
              pendingRequests.first?.sceneID == sceneID else {
            return nil
        }
        let request = pendingRequests.removeFirst()
        activeRequest = request
        bumpRevision()
        return request
    }

    /// Called by a scene after it finishes processing a granted request.
    /// A non-nil `errorMessage` sets a `pendingError` only if no error already
    /// exists; a nil message clears `activeRequest` silently.
    /// Completions for a request ID that is not currently active are ignored.
    func complete(requestID: UUID, errorMessage: String?) {
        guard activeRequest?.id == requestID else { return }
        if let errorMessage, pendingError == nil {
            pendingError = PendingError(
                requestID: requestID,
                message: errorMessage,
                presentingSceneID: activeRequest?.sceneID ?? UUID()
            )
        }
        activeRequest = nil
        bumpRevision()
    }

    /// Acknowledges and clears the pending error, releasing the application-wide
    /// gate so scenes may claim the next queued request.
    func acknowledgeError(sceneID: UUID) {
        guard pendingError != nil else { return }
        pendingError = nil
        bumpRevision()
    }

    /// Returns true when this scene is the one designated to show the error alert.
    func shouldPresentError(in sceneID: UUID) -> Bool {
        pendingError?.presentingSceneID == sceneID
    }

    private func bumpRevision() {
        revision &+= 1
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
