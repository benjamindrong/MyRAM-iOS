#if os(iOS)
import UIKit

// MARK: - Synchronization ownership

/// Identifies one editor-content observation. Restore requests use separate token types.
@MainActor
struct MarkdownPreviewUIKitSyncGeneration: Equatable, Hashable {
    let rawValue: UInt64
}

/// Owns synchronization ordering for exactly one UIKit editor coordinator.
@MainActor
final class MarkdownPreviewUIKitSyncGenerationOwner {
    private var nextRawValue: UInt64 = 0
    private(set) var current: MarkdownPreviewUIKitSyncGeneration?

    func begin() -> MarkdownPreviewUIKitSyncGeneration {
        precondition(
            nextRawValue < UInt64.max,
            "Markdown Preview synchronization generation exhausted"
        )
        nextRawValue += 1
        let generation = MarkdownPreviewUIKitSyncGeneration(rawValue: nextRawValue)
        current = generation
        return generation
    }

    func isCurrent(_ generation: MarkdownPreviewUIKitSyncGeneration) -> Bool {
        current == generation
    }
}

// MARK: - Rich-text binding state

/// Distinguishes an intentional replacement from deferred serialization, which preserves the
/// existing rich-text binding until the deferred encoder supplies its replacement.
enum MarkdownPreviewUIKitRichTextBindingDisposition: Equatable {
    case preserveExisting
    case replace(Data?)

    func differs(from currentData: Data?) -> Bool {
        switch self {
        case .preserveExisting:
            return false
        case .replace(let replacement):
            return currentData != replacement
        }
    }

    var pendingWrite: MarkdownPreviewUIKitPendingRichTextBindingWrite {
        switch self {
        case .preserveExisting:
            return .none
        case .replace(let replacement):
            return .replace(replacement)
        }
    }
}

/// Three-state bookkeeping for no write, replace-with-data, and replace-with-nil.
enum MarkdownPreviewUIKitPendingRichTextBindingWrite: Equatable {
    case none
    case replace(Data?)

    func differs(from currentData: Data?) -> Bool {
        switch self {
        case .none:
            return false
        case .replace(let replacement):
            return currentData != replacement
        }
    }
}

/// Generation-owned pending state shared by the coordinator, reconciliation operation, and tests.
@MainActor
struct MarkdownPreviewUIKitAppliedContentState: Equatable {
    private(set) var generation: MarkdownPreviewUIKitSyncGeneration?
    private(set) var plainText: String?
    private(set) var richTextWrite: MarkdownPreviewUIKitPendingRichTextBindingWrite = .none

    mutating func recordAppliedContentIfCurrent(
        generation: MarkdownPreviewUIKitSyncGeneration,
        generationOwner: MarkdownPreviewUIKitSyncGenerationOwner,
        plainText: String,
        richTextWrite: MarkdownPreviewUIKitPendingRichTextBindingWrite
    ) -> Bool {
        guard generationOwner.isCurrent(generation) else { return false }
        self.generation = generation
        self.plainText = plainText
        self.richTextWrite = richTextWrite
        return true
    }

    mutating func clearAppliedContentIfOwned(
        by generation: MarkdownPreviewUIKitSyncGeneration,
        boundPlainText: String,
        boundRichTextData: Data?
    ) -> Bool {
        guard self.generation == generation,
              plainText == boundPlainText,
              !richTextWrite.differs(from: boundRichTextData) else {
            return false
        }
        clear()
        return true
    }

    mutating func discardAppliedContentSuperseded(
        by generation: MarkdownPreviewUIKitSyncGeneration,
        generationOwner: MarkdownPreviewUIKitSyncGenerationOwner
    ) -> Bool {
        guard generationOwner.isCurrent(generation),
              let storedGeneration = self.generation,
              storedGeneration != generation else {
            return false
        }
        clear()
        return true
    }

    func hasUnsyncedContent(
        currentGeneration: MarkdownPreviewUIKitSyncGeneration?,
        boundPlainText: String,
        boundRichTextData: Data?
    ) -> Bool {
        guard generation == currentGeneration, let plainText else { return false }
        return boundPlainText != plainText || richTextWrite.differs(from: boundRichTextData)
    }

    func ownsNativeContent(
        generation: MarkdownPreviewUIKitSyncGeneration?,
        nativePlainText: String
    ) -> Bool {
        self.generation == generation && plainText == nativePlainText
    }

    private mutating func clear() {
        generation = nil
        plainText = nil
        richTextWrite = .none
    }
}

// MARK: - Executor dependencies

/// Stable state and side-effect hooks injected by the private coordinator or focused tests.
@MainActor
struct MarkdownPreviewUIKitSyncDependencies {
    /// Reports whether weak production dependencies still exist. It is pure and non-reentrant.
    var isAvailable: () -> Bool
    /// Bound-value getters are pure, synchronous, and non-reentrant.
    var getBoundPlainText: () -> String
    var getBoundRichTextData: () -> Data?
    /// Binding and publication callbacks may synchronously re-enter synchronization.
    var setBoundPlainText: (_ plainText: String) -> Void
    var setBoundRichTextData: (_ data: Data?) -> Void
    var publish: (_ plainText: String, _ richTextUpdate: EditorRichTextContentUpdate) -> Void
    /// Bookkeeping operations validate ownership internally and invoke no external callbacks.
    var recordAppliedContentIfCurrent: (
        _ generation: MarkdownPreviewUIKitSyncGeneration,
        _ generationOwner: MarkdownPreviewUIKitSyncGenerationOwner,
        _ plainText: String,
        _ richTextWrite: MarkdownPreviewUIKitPendingRichTextBindingWrite
    ) -> Bool
    var clearAppliedContentIfOwned: (
        _ generation: MarkdownPreviewUIKitSyncGeneration,
        _ boundPlainText: String,
        _ boundRichTextData: Data?
    ) -> Bool
    var discardAppliedContentSuperseded: (
        _ generation: MarkdownPreviewUIKitSyncGeneration,
        _ generationOwner: MarkdownPreviewUIKitSyncGenerationOwner
    ) -> Bool
    /// Production supplies MarkdownPreviewUIKitDeferredScheduler.enqueue; tests inject a queue.
    var scheduleDeferred: (@escaping @MainActor () -> Void) -> Void
}

// MARK: - Executor

/// Owns synchronization ordering while the private coordinator owns UIKit-specific observations.
@MainActor
enum MarkdownPreviewUIKitSyncExecutor {
    @discardableResult
    static func synchronize(
        nativePlainText: String,
        richTextBindingDisposition: MarkdownPreviewUIKitRichTextBindingDisposition,
        richTextUpdate: EditorRichTextContentUpdate,
        isUpdatingUIView: Bool,
        generationOwner: MarkdownPreviewUIKitSyncGenerationOwner,
        dependencies: MarkdownPreviewUIKitSyncDependencies,
        completion: @escaping @MainActor () -> Void
    ) -> MarkdownPreviewUIKitSyncGeneration {
        let generation = generationOwner.begin()
        let gate = EditorContentSyncCompletionGate(completion: completion)

        _ = dependencies.discardAppliedContentSuperseded(generation, generationOwner)
        guard canContinue(
            generation,
            generationOwner: generationOwner,
            dependencies: dependencies
        ) else {
            gate.complete()
            return generation
        }

        let currentBoundText = dependencies.getBoundPlainText()
        let currentBoundRichTextData = dependencies.getBoundRichTextData()

        guard currentBoundText != nativePlainText
            || richTextBindingDisposition.differs(from: currentBoundRichTextData) else {
            _ = dependencies.clearAppliedContentIfOwned(
                generation,
                currentBoundText,
                currentBoundRichTextData
            )
            guard canContinue(
                generation,
                generationOwner: generationOwner,
                dependencies: dependencies
            ) else {
                gate.complete()
                return generation
            }
            gate.complete()
            return generation
        }

        let didRecord = dependencies.recordAppliedContentIfCurrent(
            generation,
            generationOwner,
            nativePlainText,
            richTextBindingDisposition.pendingWrite
        )
        guard didRecord,
              canContinue(
                generation,
                generationOwner: generationOwner,
                dependencies: dependencies
              ) else {
            gate.complete()
            return generation
        }

        if isUpdatingUIView {
            dependencies.scheduleDeferred { [gate, generationOwner] in
                guard canContinue(
                    generation,
                    generationOwner: generationOwner,
                    dependencies: dependencies
                ) else {
                    gate.complete()
                    return
                }

                let recheckBoundText = dependencies.getBoundPlainText()
                let recheckBoundData = dependencies.getBoundRichTextData()
                guard recheckBoundText != nativePlainText
                    || richTextBindingDisposition.differs(from: recheckBoundData) else {
                    _ = dependencies.clearAppliedContentIfOwned(
                        generation,
                        recheckBoundText,
                        recheckBoundData
                    )
                    guard canContinue(
                        generation,
                        generationOwner: generationOwner,
                        dependencies: dependencies
                    ) else {
                        gate.complete()
                        return
                    }
                    gate.complete()
                    return
                }

                applyAndPublish(
                    generation: generation,
                    generationOwner: generationOwner,
                    nativePlainText: nativePlainText,
                    richTextBindingDisposition: richTextBindingDisposition,
                    richTextUpdate: richTextUpdate,
                    dependencies: dependencies,
                    gate: gate
                )
            }
            return generation
        }

        applyAndPublish(
            generation: generation,
            generationOwner: generationOwner,
            nativePlainText: nativePlainText,
            richTextBindingDisposition: richTextBindingDisposition,
            richTextUpdate: richTextUpdate,
            dependencies: dependencies,
            gate: gate
        )
        return generation
    }

    private static func applyAndPublish(
        generation: MarkdownPreviewUIKitSyncGeneration,
        generationOwner: MarkdownPreviewUIKitSyncGenerationOwner,
        nativePlainText: String,
        richTextBindingDisposition: MarkdownPreviewUIKitRichTextBindingDisposition,
        richTextUpdate: EditorRichTextContentUpdate,
        dependencies: MarkdownPreviewUIKitSyncDependencies,
        gate: EditorContentSyncCompletionGate
    ) {
        dependencies.setBoundPlainText(nativePlainText)
        guard canContinue(
            generation,
            generationOwner: generationOwner,
            dependencies: dependencies
        ) else {
            gate.complete()
            return
        }

        if case .replace(let replacement) = richTextBindingDisposition {
            dependencies.setBoundRichTextData(replacement)
            guard canContinue(
                generation,
                generationOwner: generationOwner,
                dependencies: dependencies
            ) else {
                gate.complete()
                return
            }
        }

        dependencies.publish(nativePlainText, richTextUpdate)
        guard canContinue(
            generation,
            generationOwner: generationOwner,
            dependencies: dependencies
        ) else {
            gate.complete()
            return
        }

        let boundPlainText = dependencies.getBoundPlainText()
        let boundRichTextData = dependencies.getBoundRichTextData()
        _ = dependencies.clearAppliedContentIfOwned(
            generation,
            boundPlainText,
            boundRichTextData
        )
        guard canContinue(
            generation,
            generationOwner: generationOwner,
            dependencies: dependencies
        ) else {
            gate.complete()
            return
        }
        gate.complete()
    }

    private static func canContinue(
        _ generation: MarkdownPreviewUIKitSyncGeneration,
        generationOwner: MarkdownPreviewUIKitSyncGenerationOwner,
        dependencies: MarkdownPreviewUIKitSyncDependencies
    ) -> Bool {
        generationOwner.isCurrent(generation) && dependencies.isAvailable()
    }
}
#endif
