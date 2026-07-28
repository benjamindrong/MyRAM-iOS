// MarkdownPreviewModePolicy.swift
// Pure production selection and mode policy helpers.
// Used directly by MyRAMMacRootView, NoteEditorView, and unit tests.

import Foundation

/// Pure selection policy for Markdown Preview editor mode.
enum MarkdownPreviewSelectionPolicy {
    /// Resets mode to .edit if selectedNoteID changes (oldID != newID).
    /// Preserves current mode if selectedNoteID is unchanged (oldID == newID).
    static func modeAfterSelectionChange(
        currentMode: MarkdownEditorMode,
        oldID: UUID?,
        newID: UUID?
    ) -> MarkdownEditorMode {
        guard oldID != newID else { return currentMode }
        return .edit
    }
}

/// Request-correlated focus resignation seam value for iOS SelectableTextView.
struct MarkdownPreviewFocusRequest: Equatable {
    let id: UUID
}
