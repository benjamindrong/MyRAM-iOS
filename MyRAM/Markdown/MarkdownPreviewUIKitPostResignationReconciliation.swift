#if os(iOS)
import UIKit

/// Identifies consumption of an explicit restore command.
struct MarkdownPreviewUIKitRestoreToken: Equatable, Hashable {
    let rawValue: Int
}

/// Owns the content version associated with an explicit restore command.
struct MarkdownPreviewUIKitRestoreGeneration: Equatable, Hashable {
    let rawValue: UInt64
}

/// Classifies a restore request without consulting synchronization ownership or native content.
enum MarkdownPreviewUIKitRestoreAcceptance: Equatable {
    case accepted
    case rejectedAlreadyHandledToken
    case rejectedInvalidGeneration
    case rejectedDuplicateGeneration
    case rejectedStaleGeneration
}

/// Issues restore generations independently from editor synchronization generations.
@MainActor
final class MarkdownPreviewUIKitRestoreGenerationOwner {
    private var nextRawValue: UInt64 = 0

    func begin() -> MarkdownPreviewUIKitRestoreGeneration {
        precondition(
            nextRawValue < UInt64.max,
            "Markdown Preview restore generation exhausted"
        )
        nextRawValue += 1
        return MarkdownPreviewUIKitRestoreGeneration(rawValue: nextRawValue)
    }
}

/// Owns the post-resignation preserve-versus-replace decision and performs the native mutation.
@MainActor
enum MarkdownPreviewUIKitPostResignationReconciliation {
    struct RestoreRequest {
        let token: MarkdownPreviewUIKitRestoreToken
        let lastHandledToken: MarkdownPreviewUIKitRestoreToken
        let generation: MarkdownPreviewUIKitRestoreGeneration
        let lastAppliedGeneration: MarkdownPreviewUIKitRestoreGeneration?
        let requestedAttributedText: NSAttributedString
    }

    struct FormattingState {
        let hasPendingNativeFormattingMutation: Bool
        let pendingFormattingToken: Int?
    }

    struct FocusState {
        let isFirstResponder: Bool
        let isHandlingUserFocusChange: Bool
        let isResigningForPreview: Bool
        let hasMarkedText: Bool
    }

    struct Input {
        let synchronizationGeneration: MarkdownPreviewUIKitSyncGeneration?
        let isSynchronizationGenerationCurrent: Bool
        let nativePlainText: String
        let nativeAttributedText: NSAttributedString
        let boundPlainText: String
        let boundRichTextData: Data?
        let boundAttributedText: NSAttributedString
        let appliedContentState: MarkdownPreviewUIKitAppliedContentState
        let nativeMatchesLatestEditorPublication: Bool
        let restoreRequest: RestoreRequest?
        let formattingState: FormattingState
        let focusState: FocusState
        let isPreviewTransitionPending: Bool
        let isPreviewVisible: Bool
    }

    struct Dependencies {
        /// Brackets the native mutation with coordinator-only selection and rendering maintenance.
        let willApplyReplacement: () -> Void
        let didApplyReplacement: (_ previousSelection: NSRange) -> Void
        let markRestoreHandled: (
            _ token: MarkdownPreviewUIKitRestoreToken,
            _ generation: MarkdownPreviewUIKitRestoreGeneration
        ) -> Void
        /// Invalidates every editor synchronization observed before an accepted restore.
        let supersedeEditorSynchronizationForAcceptedRestore:
            () -> MarkdownPreviewUIKitSyncGeneration
        let clearAppliedContentIfOwned: (
            _ generation: MarkdownPreviewUIKitSyncGeneration,
            _ boundPlainText: String,
            _ boundRichTextData: Data?
        ) -> Void
    }

    static func reconcile(
        textView: UITextView,
        input: Input,
        dependencies: Dependencies
    ) {
        if let restoreRequest = input.restoreRequest {
            guard classify(restoreRequest) == .accepted else { return }
            _ = dependencies.supersedeEditorSynchronizationForAcceptedRestore()
            apply(
                restoreRequest.requestedAttributedText,
                to: textView,
                input: input,
                dependencies: dependencies
            )
            dependencies.markRestoreHandled(
                restoreRequest.token,
                restoreRequest.generation
            )
            return
        }

        guard input.isSynchronizationGenerationCurrent else { return }

        guard !input.focusState.hasMarkedText,
              !input.formattingState.hasPendingNativeFormattingMutation else {
            return
        }

        let ownsLatestNativeContent = input.nativeMatchesLatestEditorPublication
            && input.appliedContentState.ownsNativeContent(
                generation: input.synchronizationGeneration,
                nativePlainText: input.nativePlainText
            )
        let isPreviewTransition = input.isPreviewTransitionPending || input.isPreviewVisible

        if isPreviewTransition,
           input.focusState.isResigningForPreview,
           ownsLatestNativeContent {
            clearAppliedContentIfSynchronized(input: input, dependencies: dependencies)
            return
        }

        if ownsLatestNativeContent {
            clearAppliedContentIfSynchronized(input: input, dependencies: dependencies)
            return
        }

        guard !input.focusState.isFirstResponder,
              !input.focusState.isHandlingUserFocusChange,
              input.nativePlainText != input.boundPlainText else {
            return
        }

        apply(
            input.boundAttributedText,
            to: textView,
            input: input,
            dependencies: dependencies
        )
    }

    private static func classify(
        _ request: RestoreRequest
    ) -> MarkdownPreviewUIKitRestoreAcceptance {
        guard request.generation.rawValue > 0 else {
            return .rejectedInvalidGeneration
        }
        guard request.token != request.lastHandledToken else {
            return .rejectedAlreadyHandledToken
        }
        guard let lastAppliedGeneration = request.lastAppliedGeneration else {
            return .accepted
        }
        if request.generation.rawValue > lastAppliedGeneration.rawValue {
            return .accepted
        }
        if request.generation.rawValue == lastAppliedGeneration.rawValue {
            return .rejectedDuplicateGeneration
        }
        return .rejectedStaleGeneration
    }

    private static func clearAppliedContentIfSynchronized(
        input: Input,
        dependencies: Dependencies
    ) {
        guard let synchronizationGeneration = input.synchronizationGeneration else { return }
        dependencies.clearAppliedContentIfOwned(
            synchronizationGeneration,
            input.boundPlainText,
            input.boundRichTextData
        )
    }

    private static func apply(
        _ attributedText: NSAttributedString,
        to textView: UITextView,
        input: Input,
        dependencies: Dependencies
    ) {
        guard !input.nativeAttributedText.isEqual(to: attributedText) else { return }
        let previousSelection = textView.selectedRange
        dependencies.willApplyReplacement()
        textView.attributedText = attributedText
        dependencies.didApplyReplacement(previousSelection)
    }
}
#endif
