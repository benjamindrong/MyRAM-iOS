import AnchoredSequenceCore
import Foundation

struct NoteStructuralFormattingProjectionRun:
    Equatable,
    Sendable
{
    let startUTF16Offset: Int
    let utf16Length: Int
    let assignments: [SyncTextMarkKey: SyncTextMarkAssignment]

    init(
        startUTF16Offset: Int,
        utf16Length: Int,
        assignments: [SyncTextMarkKey: SyncTextMarkAssignment]
    ) {
        self.startUTF16Offset = startUTF16Offset
        self.utf16Length = utf16Length
        self.assignments = assignments
    }
}

struct NoteStructuralFormattingProjection:
    Equatable,
    Sendable
{
    let plainText: String
    let runs: [NoteStructuralFormattingProjectionRun]

    init(
        plainText: String,
        runs: [NoteStructuralFormattingProjectionRun]
    ) {
        self.plainText = plainText
        self.runs = runs
    }
}

enum NoteStructuralFormattingEditPlannerError:
    Error,
    Equatable
{
    case projectionTextMismatch
    case projectionCoverageMismatch
    case projectionMissingSupportedKey(SyncTextMarkKey)
    case projectionRangeOverflow
}

struct PreparedStructuralFormattingEdit:
    Equatable,
    Sendable
{
    let finalMarkState: SyncTextMarkState
    let emittedOperations: [SyncTextMarkOperation]

    var hasAuthoritativeMutation: Bool {
        !emittedOperations.isEmpty
    }
}

enum NoteStructuralFormattingEditPlanner {
    static func prepare(
        sequence: SyncTextSequenceState,
        currentMarkState: SyncTextMarkState,
        desiredProjection: NoteStructuralFormattingProjection,
        operationIDReserver: any SyncOperationIDReserving
    ) async throws -> PreparedStructuralFormattingEdit {
        guard NoteSequenceStateExactText.matches(
            sequence.visibleText,
            desiredProjection.plainText
        ) else {
            throw NoteStructuralFormattingEditPlannerError.projectionTextMismatch
        }
        try currentMarkState.validating(against: sequence)

        let desiredByKey = try denseAssignments(
            from: desiredProjection,
            expectedUTF16Count: sequence.visibleUTF16Count
        )
        let currentByKey = try denseCurrentAssignments(
            state: currentMarkState,
            sequence: sequence
        )

        var drafts: [SyncTextMarkOperationDraft] = []
        for key in SyncTextMarkKey.allCases {
            guard let desired = desiredByKey[key],
                  let current = currentByKey[key] else {
                preconditionFailure("Every supported structural mark key must be dense.")
            }

            var offset = 0
            while offset < desired.count {
                guard desired[offset] != current[offset] else {
                    offset += 1
                    continue
                }

                let assignment = desired[offset]
                let start = offset
                offset += 1
                while offset < desired.count,
                      desired[offset] == assignment,
                      current[offset] != assignment {
                    offset += 1
                }

                drafts.append(try SyncTextMarkOperationDraft(
                    key: key,
                    assignment: assignment,
                    startAnchor: sequence.operationAnchor(
                        atVisibleUTF16Offset: start
                    ),
                    endAnchor: sequence.operationAnchor(
                        atVisibleUTF16Offset: offset
                    )
                ))
            }
        }

        guard !drafts.isEmpty else {
            return PreparedStructuralFormattingEdit(
                finalMarkState: currentMarkState,
                emittedOperations: []
            )
        }

        // Clock exhaustion is checked before any durable ID reservation.
        let logicalClock = try currentMarkState.nextLogicalClock()
        let orderedDrafts = try SyncTextMarkCanonicalEmissionOrder.ordered(
            drafts,
            against: sequence
        )

        var operations: [SyncTextMarkOperation] = []
        operations.reserveCapacity(orderedDrafts.count)
        for draft in orderedDrafts {
            let operationID = try await operationIDReserver.reserveOperationID()
            operations.append(try SyncTextMarkOperation(
                operationID: operationID,
                logicalClock: logicalClock,
                key: draft.key,
                assignment: draft.assignment,
                startAnchor: draft.startAnchor,
                endAnchor: draft.endAnchor
            ))
        }

        let finalState = try currentMarkState.merging(
            with: SyncTextMarkState(operations: operations)
        )
        try finalState.validating(against: sequence)
        return PreparedStructuralFormattingEdit(
            finalMarkState: finalState,
            emittedOperations: operations
        )
    }

    private static func denseAssignments(
        from projection: NoteStructuralFormattingProjection,
        expectedUTF16Count: Int
    ) throws -> [SyncTextMarkKey: [SyncTextMarkAssignment]] {
        var output = Dictionary(
            uniqueKeysWithValues: SyncTextMarkKey.allCases.map {
                ($0, Array(repeating: SyncTextMarkAssignment.clear, count: expectedUTF16Count))
            }
        )

        if expectedUTF16Count == 0 {
            guard projection.runs.isEmpty else {
                throw NoteStructuralFormattingEditPlannerError.projectionCoverageMismatch
            }
            return output
        }

        var expectedStart = 0
        let requiredKeys = Set(SyncTextMarkKey.allCases)
        for run in projection.runs {
            guard run.startUTF16Offset == expectedStart,
                  run.startUTF16Offset >= 0,
                  run.utf16Length > 0 else {
                throw NoteStructuralFormattingEditPlannerError.projectionCoverageMismatch
            }
            let (end, overflow) = run.startUTF16Offset.addingReportingOverflow(
                run.utf16Length
            )
            guard !overflow else {
                throw NoteStructuralFormattingEditPlannerError.projectionRangeOverflow
            }
            guard end <= expectedUTF16Count else {
                throw NoteStructuralFormattingEditPlannerError.projectionCoverageMismatch
            }
            guard Set(run.assignments.keys) == requiredKeys else {
                let missing = SyncTextMarkKey.allCases.first {
                    run.assignments[$0] == nil
                } ?? .bold
                throw NoteStructuralFormattingEditPlannerError
                    .projectionMissingSupportedKey(missing)
            }

            for key in SyncTextMarkKey.allCases {
                guard let assignment = run.assignments[key] else {
                    preconditionFailure("Projection key audit already proved completeness.")
                }
                for offset in run.startUTF16Offset..<end {
                    output[key]![offset] = assignment
                }
            }
            expectedStart = end
        }

        guard expectedStart == expectedUTF16Count else {
            throw NoteStructuralFormattingEditPlannerError.projectionCoverageMismatch
        }
        return output
    }

    private static func denseCurrentAssignments(
        state: SyncTextMarkState,
        sequence: SyncTextSequenceState
    ) throws -> [SyncTextMarkKey: [SyncTextMarkAssignment]] {
        var output = Dictionary(
            uniqueKeysWithValues: SyncTextMarkKey.allCases.map {
                (
                    $0,
                    Array(
                        repeating: SyncTextMarkAssignment.clear,
                        count: sequence.visibleUTF16Count
                    )
                )
            }
        )

        for span in try state.visibleProjection(in: sequence) {
            let end = span.startUTF16Offset + span.utf16Length
            for key in SyncTextMarkKey.allCases {
                let assignment = span.assignments[key] ?? .clear
                for offset in span.startUTF16Offset..<end {
                    output[key]![offset] = assignment
                }
            }
        }
        return output
    }
}
