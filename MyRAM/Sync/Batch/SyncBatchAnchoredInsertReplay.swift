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

struct SyncBatchAnchoredDeleteReplayResult: Equatable, Sendable {
    let sequenceState: SyncTextSequenceState

    var visibleText: String {
        sequenceState.visibleText
    }
}

/// Applies one already-validated anchored deletion without persistence or activation.
enum SyncBatchAnchoredDeleteReplay {
    static func applying(
        _ change: SyncBatchNoteBodyTextDeletedAnchoredChange,
        to state: SyncTextSequenceState
    ) throws -> SyncBatchAnchoredDeleteReplayResult {
        SyncBatchAnchoredDeleteReplayResult(
            sequenceState: try state.incorporating(delete: change.payload)
        )
    }
}
