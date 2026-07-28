// MarkdownPreviewModePolicy.swift
// Pure production selection, resignation, command, search, and acknowledgment policy types.
// Shared across production code (NoteEditorView, MyRAMMacRootView) and unit tests.

import Foundation

// MARK: - Selection Policy

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

// MARK: - Focus Request & Acknowledgment Seams

/// Request-correlated focus resignation seam value for iOS SelectableTextView.
struct MarkdownPreviewFocusRequest: Equatable {
    let id: UUID
}

/// Dispatches focus resignation acknowledgment to the main actor after the view update cycle unwinds,
/// preventing synchronous SwiftUI @State mutation inside updateUIView or delegate calls.
struct MarkdownPreviewAcknowledgmentDispatcher {
    static func dispatch(
        requestID: UUID,
        acknowledge: @escaping @MainActor (UUID) -> Void
    ) {
        Task { @MainActor in
            acknowledge(requestID)
        }
    }
}

// MARK: - Resignation Policy

enum MarkdownPreviewResignationDisposition: Equatable {
    /// Pure Preview focus resignation: update text binding, skip publication, acknowledge focus release.
    case acknowledgeWithoutPublication
    /// IME / marked-text finalized a genuine text mutation: publish edit exactly once, then acknowledge.
    case publishFinalizedUserEditThenAcknowledge
    /// Ordinary focus loss unrelated to Preview: proceed with standard end-editing publication.
    case ordinaryEndEditing
}

struct MarkdownPreviewResignationPolicy {
    static func disposition(
        isPreviewResignation: Bool,
        boundPlainText: String,
        nativePlainText: String
    ) -> MarkdownPreviewResignationDisposition {
        guard isPreviewResignation else {
            return .ordinaryEndEditing
        }
        if boundPlainText != nativePlainText {
            return .publishFinalizedUserEditThenAcknowledge
        }
        return .acknowledgeWithoutPublication
    }
}

// MARK: - Command Consumption Policy

enum MarkdownPreviewCommandDisposition: Equatable {
    case execute
    case consumeWithoutExecution
}

struct MarkdownPreviewCommandConsumptionPolicy {
    static func disposition(
        forMode mode: MarkdownEditorMode
    ) -> MarkdownPreviewCommandDisposition {
        switch mode {
        case .edit:
            return .execute
        case .preview:
            return .consumeWithoutExecution
        }
    }
}

// MARK: - Search Isolation Policy

struct MarkdownPreviewSearchInteractionPolicy {
    static func isSearchPresented(
        mode: MarkdownEditorMode,
        isSearchActiveInState: Bool
    ) -> Bool {
        mode == .edit && isSearchActiveInState
    }

    static func bodyHighlightRange(
        mode: MarkdownEditorMode,
        highlightRange: NSRange?
    ) -> NSRange? {
        guard mode == .edit else { return nil }
        return highlightRange
    }
}
