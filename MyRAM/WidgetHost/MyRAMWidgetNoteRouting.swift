import Foundation

@MainActor
enum MyRAMWidgetNoteRouteOutcome: Equatable {
    case completed
    case retainedForRetry
}

#if os(iOS)
@MainActor
struct MyRAMWidgetIOSNoteRouter {
    func route(
        noteID: UUID,
        expectedEditor: ExpectedEditor,
        flushBridge: NoteEditorFileOperationBridge,
        fetchActiveNote: (UUID) -> Note?,
        present: (Note) -> Void
    ) -> MyRAMWidgetNoteRouteOutcome {
        switch flushBridge.flushEditor(expected: expectedEditor) {
        case .noActiveEditor, .succeeded:
            break
        case .expectedEditorUnavailable, .editorMismatch, .failed:
            return .retainedForRetry
        }

        guard let note = fetchActiveNote(noteID), note.deletedAt == nil else {
            return .completed
        }

        present(note)
        return .completed
    }
}
#endif

@MainActor
struct MyRAMWidgetMacNoteRouter {
    func route(
        noteID: UUID,
        flushPendingSave: () async -> Bool,
        fetchActiveNote: (UUID) throws -> Note?,
        present: (Note) throws -> Void
    ) async -> MyRAMWidgetNoteRouteOutcome {
        guard await flushPendingSave() else {
            return .retainedForRetry
        }

        do {
            guard let note = try fetchActiveNote(noteID), note.deletedAt == nil else {
                return .completed
            }
            try present(note)
            return .completed
        } catch {
            return .retainedForRetry
        }
    }
}
