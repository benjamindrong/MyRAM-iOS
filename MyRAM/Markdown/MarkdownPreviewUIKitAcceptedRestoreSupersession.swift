#if os(iOS)
/// Transfers authority from every older editor synchronization to an accepted explicit restore.
@MainActor
enum MarkdownPreviewUIKitAcceptedRestoreSupersession {
    static func perform(
        generationOwner: MarkdownPreviewUIKitSyncGenerationOwner,
        appliedContentState: inout MarkdownPreviewUIKitAppliedContentState
    ) -> MarkdownPreviewUIKitSyncGeneration {
        let generation = generationOwner.begin()
        _ = appliedContentState.discardAppliedContentSuperseded(
            by: generation,
            generationOwner: generationOwner
        )
        return generation
    }
}
#endif
