// MarkdownPreviewModePolicy.swift
// Pure production selection, resignation, command, search, and interaction state policy types.
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

// MARK: - Interaction State (§7)

enum MarkdownPreviewInteractionState: Equatable {
    case editInteractive
    case previewTransitionPending
    case previewVisible

    var isPreviewOrPending: Bool {
        self != .editInteractive
    }
}

struct MarkdownPreviewInteractionPolicy {
    static func state(
        requestedMode: MarkdownEditorMode,
        committedMode: MarkdownEditorMode,
        hasPendingFocusRequest: Bool
    ) -> MarkdownPreviewInteractionState {
        if hasPendingFocusRequest {
            return .previewTransitionPending
        } else if committedMode == .preview {
            return .previewVisible
        } else if requestedMode == .preview {
            return .previewTransitionPending
        } else {
            return .editInteractive
        }
    }
}

// MARK: - Resignation Policy (§8)

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

// MARK: - Command Consumption Policy (§7 & §9)

enum MarkdownPreviewCommandDisposition: Equatable {
    case execute
    case consumeWithoutExecution
}

struct MarkdownPreviewCommandConsumptionPolicy {
    static func disposition(
        forState state: MarkdownPreviewInteractionState
    ) -> MarkdownPreviewCommandDisposition {
        switch state {
        case .editInteractive:
            return .execute
        case .previewTransitionPending, .previewVisible:
            return .consumeWithoutExecution
        }
    }
}

// MARK: - Search Isolation Policy (§10)

struct MarkdownPreviewSearchInteractionPolicy {
    static func isSearchPresented(
        state: MarkdownPreviewInteractionState,
        isSearchActiveInState: Bool
    ) -> Bool {
        state == .editInteractive && isSearchActiveInState
    }

    static func bodyHighlightRange(
        state: MarkdownPreviewInteractionState,
        highlightRange: NSRange?
    ) -> NSRange? {
        guard state == .editInteractive else { return nil }
        return highlightRange
    }
}
