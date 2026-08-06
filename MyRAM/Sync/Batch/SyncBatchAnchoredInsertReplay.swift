import AnchoredSequenceCore

struct SyncBatchAnchoredInsertReplayResult: Equatable, Sendable {
    let sequenceState: SyncTextSequenceState

    var visibleText: String {
        sequenceState.visibleText
    }
}

/// Applies one already-validated anchored insertion without persistence or activation.
enum SyncBatchAnchoredInsertReplay {
    static func applying(
        _ change: SyncBatchNoteBodyTextInsertedAnchoredChange,
        to state: SyncTextSequenceState
    ) throws -> SyncBatchAnchoredInsertReplayResult {
        SyncBatchAnchoredInsertReplayResult(
            sequenceState: try state.incorporating(
                insert: change.payload,
                insertedText: change.text
            )
        )
    }
}
