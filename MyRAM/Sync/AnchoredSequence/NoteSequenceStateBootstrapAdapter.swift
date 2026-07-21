import AnchoredSequenceCore
import Foundation

/// Bridges persisted note values to the frozen transport-neutral bootstrap rule.
enum NoteSequenceStateBootstrapAdapter {
    static func makeInitialState(
        noteID: UUID,
        body: String
    ) throws -> SyncTextSequenceState {
        try SyncTextLegacyBootstrap.makeState(
            noteID: noteID,
            body: body,
            formatVersion: .v1
        )
    }
}

/// Compares authoritative text without Unicode normalization.
enum NoteSequenceStateExactText {
    static func matches(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf16.elementsEqual(rhs.utf16)
    }
}
