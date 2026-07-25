import Foundation

public enum SyncTextSequenceStateError: Error, Equatable, Sendable {
    case identicalOriginEndpoints(SyncTextElementID)
    case emptyRunText(SyncOperationID)
    case negativeRangeOffset(Int)
    case nonpositiveRangeLength(Int)
    case rangeOverflow(startOffset: Int, utf16Length: Int)
    case duplicateRun(SyncOperationID)
    case noncanonicalRunOrder(previous: SyncOperationID, current: SyncOperationID)
    case noncanonicalSiblingOrder(previous: SyncOperationID, current: SyncOperationID)
    case unknownOrigin(SyncTextElementID)
    case selfOrigin(SyncOperationID)
    case originSplitsSurrogatePair(SyncTextElementID)
    case cyclicOriginDependency
    case unreachableOriginGap(SyncOperationID)
    case duplicateStructuralReachability(SyncOperationID)
    case fragmentReferencesUnknownRun(SyncOperationID)
    case fragmentRangeExceedsRun(SyncOperationID)
    case fragmentSplitsSurrogatePair(SyncOperationID, offset: Int)
    case fragmentOrderNotMatchingOrigins
    case mergeableAdjacentFragments(SyncOperationID)
    case countOverflow
    case visibleOffsetOutOfBounds(Int)
    case visibleOffsetSplitsSurrogatePair(Int)
    case invalidVisibleRange(Range<Int>)
    case visibleRangeSplitsSurrogatePair(Int)
}

public enum SyncOperationIDCanonicalOrder {
    public static func isOrderedBefore(
        _ lhs: SyncOperationID,
        _ rhs: SyncOperationID
    ) -> Bool {
        let lhsBytes = rawBytes(of: lhs.deviceID)
        let rhsBytes = rawBytes(of: rhs.deviceID)

        if lhsBytes != rhsBytes {
            return lhsBytes.lexicographicallyPrecedes(rhsBytes)
        }
        return lhs.localCounter < rhs.localCounter
    }

    /// UUID tuple storage exposes the RFC 4122 bytes without string formatting semantics.
    private static func rawBytes(of uuid: UUID) -> [UInt8] {
        var value = uuid.uuid
        return withUnsafeBytes(of: &value) { Array($0) }
    }
}

public struct SyncTextInsertionOrigin: Equatable, Hashable, Sendable {
    public let leftElementID: SyncTextElementID?
    public let rightElementID: SyncTextElementID?

    public init(
        leftElementID: SyncTextElementID?,
        rightElementID: SyncTextElementID?
    ) throws {
        if let leftElementID, leftElementID == rightElementID {
            throw SyncTextSequenceStateError.identicalOriginEndpoints(leftElementID)
        }

        self.leftElementID = leftElementID
        self.rightElementID = rightElementID
    }
}

public enum SyncTextSequenceElementVisibility: String, Equatable, Hashable, Sendable {
    case visible
    case tombstone
}

public struct SyncTextSequenceRun: Equatable, Hashable, Sendable {
    public let operationID: SyncOperationID
    public let origin: SyncTextInsertionOrigin
    public let text: String

    public init(
        operationID: SyncOperationID,
        origin: SyncTextInsertionOrigin,
        text: String
    ) throws {
        guard !text.isEmpty else {
            throw SyncTextSequenceStateError.emptyRunText(operationID)
        }

        self.operationID = operationID
        self.origin = origin
        self.text = text
    }
}

public struct SyncTextSequenceFragment: Equatable, Hashable, Sendable {
    public let operationID: SyncOperationID
    public let startOffset: Int
    public let utf16Length: Int
    public let visibility: SyncTextSequenceElementVisibility

    public init(
        operationID: SyncOperationID,
        startOffset: Int,
        utf16Length: Int,
        visibility: SyncTextSequenceElementVisibility
    ) throws {
        _ = try SyncTextSequenceRangeValidation.checkedEnd(
            startOffset: startOffset,
            utf16Length: utf16Length
        )
        self.operationID = operationID
        self.startOffset = startOffset
        self.utf16Length = utf16Length
        self.visibility = visibility
    }
}

public struct SyncTextElementIDSpan: Equatable, Hashable, Sendable {
    public let operationID: SyncOperationID
    public let startOffset: Int
    public let utf16Length: Int

    public init(
        operationID: SyncOperationID,
        startOffset: Int,
        utf16Length: Int
    ) throws {
        _ = try SyncTextSequenceRangeValidation.checkedEnd(
            startOffset: startOffset,
            utf16Length: utf16Length
        )
        self.operationID = operationID
        self.startOffset = startOffset
        self.utf16Length = utf16Length
    }

    fileprivate init(
        validatedOperationID operationID: SyncOperationID,
        startOffset: Int,
        utf16Length: Int
    ) {
        self.operationID = operationID
        self.startOffset = startOffset
        self.utf16Length = utf16Length
    }
}

private enum SyncTextSequenceRangeValidation {
    static func checkedEnd(startOffset: Int, utf16Length: Int) throws -> Int {
        guard startOffset >= 0 else {
            throw SyncTextSequenceStateError.negativeRangeOffset(startOffset)
        }
        guard utf16Length > 0 else {
            throw SyncTextSequenceStateError.nonpositiveRangeLength(utf16Length)
        }

        let (endOffset, overflow) = startOffset.addingReportingOverflow(utf16Length)
        guard !overflow else {
            throw SyncTextSequenceStateError.rangeOverflow(
                startOffset: startOffset,
                utf16Length: utf16Length
            )
        }
        return endOffset
    }
}

struct SyncTextSequenceTraversalMetrics: Equatable, Sendable {
    var processedFrames = 0
    var gapIndexLookups = 0
    var comparedSpans = 0
}

public struct SyncTextSequenceState: Equatable, Sendable {
    public let runs: [SyncTextSequenceRun]
    public let fragments: [SyncTextSequenceFragment]

    private let materializedVisibleText: String
    private let materializedVisibleUTF16Count: Int
    private let materializedTombstonedUTF16Count: Int

    /// Kept internal so complexity tests can prove traversal work without timing assertions.
    let validationMetrics: SyncTextSequenceTraversalMetrics

    public static let empty: SyncTextSequenceState = {
        do {
            return try SyncTextSequenceState(runs: [], fragments: [])
        } catch {
            preconditionFailure("The empty sequence state must always be valid: \(error)")
        }
    }()

    public init(
        runs: [SyncTextSequenceRun],
        fragments: [SyncTextSequenceFragment]
    ) throws {
        let validation = try SyncTextSequenceStateValidator.validate(
            runs: runs,
            fragments: fragments
        )
        self.runs = runs
        self.fragments = fragments
        self.materializedVisibleText = validation.visibleText
        self.materializedVisibleUTF16Count = validation.visibleUTF16Count
        self.materializedTombstonedUTF16Count = validation.tombstonedUTF16Count
        self.validationMetrics = validation.metrics
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.runs == rhs.runs && lhs.fragments == rhs.fragments
    }

    public var visibleText: String { materializedVisibleText }
    public var visibleUTF16Count: Int { materializedVisibleUTF16Count }
    public var tombstonedUTF16Count: Int { materializedTombstonedUTF16Count }

    public func visibility(
        of elementID: SyncTextElementID
    ) -> SyncTextSequenceElementVisibility? {
        for fragment in fragments where fragment.operationID == elementID.operationID {
            let endOffset = fragment.startOffset + fragment.utf16Length
            if fragment.startOffset <= elementID.elementOffset,
               elementID.elementOffset < endOffset {
                return fragment.visibility
            }
        }
        return nil
    }

    public func leftElementID(
        beforeVisibleUTF16Offset offset: Int
    ) throws -> SyncTextElementID? {
        guard offset >= 0, offset <= visibleUTF16Count else {
            throw SyncTextSequenceStateError.visibleOffsetOutOfBounds(offset)
        }
        guard SyncTextSequenceStringBoundary.isBoundary(
            offset,
            in: materializedVisibleText
        ) else {
            throw SyncTextSequenceStateError.visibleOffsetSplitsSurrogatePair(offset)
        }
        guard offset > 0 else { return nil }

        var consumed = 0
        for fragment in fragments where fragment.visibility == .visible {
            let nextConsumed = consumed + fragment.utf16Length
            if offset <= nextConsumed {
                return try SyncTextElementID(
                    operationID: fragment.operationID,
                    elementOffset: fragment.startOffset + offset - consumed - 1
                )
            }
            consumed = nextConsumed
        }

        preconditionFailure("Validated visible count did not resolve an anchor")
    }

    public func elementIDSpans(
        inVisibleUTF16Range range: Range<Int>
    ) throws -> [SyncTextElementIDSpan] {
        guard range.lowerBound >= 0, range.upperBound <= visibleUTF16Count else {
            throw SyncTextSequenceStateError.invalidVisibleRange(range)
        }
        for boundary in [range.lowerBound, range.upperBound] where
            !SyncTextSequenceStringBoundary.isBoundary(boundary, in: materializedVisibleText) {
            throw SyncTextSequenceStateError.visibleRangeSplitsSurrogatePair(boundary)
        }
        guard !range.isEmpty else { return [] }

        var result: [SyncTextElementIDSpan] = []
        var visibleCursor = 0
        var previousSelectedFragmentIndex: Int?

        for (fragmentIndex, fragment) in fragments.enumerated() {
            guard fragment.visibility == .visible else { continue }
            let fragmentVisibleRange = visibleCursor..<(visibleCursor + fragment.utf16Length)
            visibleCursor = fragmentVisibleRange.upperBound
            let lower = max(range.lowerBound, fragmentVisibleRange.lowerBound)
            let upper = min(range.upperBound, fragmentVisibleRange.upperBound)
            guard lower < upper else { continue }

            let span = try SyncTextElementIDSpan(
                operationID: fragment.operationID,
                startOffset: fragment.startOffset + lower - fragmentVisibleRange.lowerBound,
                utf16Length: upper - lower
            )
            let isStructurallyAdjacent = previousSelectedFragmentIndex.map {
                $0 + 1 == fragmentIndex
            } ?? false
            append(span, to: &result, allowingCoalescing: isStructurallyAdjacent)
            previousSelectedFragmentIndex = fragmentIndex
        }
        return result
    }

    /// Resolves a visible cursor to one deterministic gap in the structural stream.
    public func operationAnchor(
        atVisibleUTF16Offset offset: Int
    ) throws -> SyncOperationAnchor {
        guard offset >= 0, offset <= visibleUTF16Count else {
            throw SyncTextSequenceStateError.visibleOffsetOutOfBounds(offset)
        }
        guard SyncTextSequenceStringBoundary.isBoundary(
            offset,
            in: materializedVisibleText
        ) else {
            throw SyncTextSequenceStateError.visibleOffsetSplitsSurrogatePair(offset)
        }
        guard !fragments.isEmpty else { return .empty }

        var visibleCursor = 0
        var leftElementID: SyncTextElementID?
        for fragment in fragments {
            if fragment.visibility == .visible {
                let nextVisibleCursor = visibleCursor + fragment.utf16Length
                if offset < nextVisibleCursor {
                    let offsetInFragment = offset - visibleCursor
                    let rightElementID = try SyncTextElementID(
                        operationID: fragment.operationID,
                        elementOffset: fragment.startOffset + offsetInFragment
                    )
                    if offsetInFragment > 0 {
                        leftElementID = try SyncTextElementID(
                            operationID: fragment.operationID,
                            elementOffset: fragment.startOffset + offsetInFragment - 1
                        )
                    }
                    return try Self.operationAnchor(
                        leftElementID: leftElementID,
                        rightElementID: rightElementID
                    )
                }
                visibleCursor = nextVisibleCursor
            }

            leftElementID = try SyncTextElementID(
                operationID: fragment.operationID,
                elementOffset: fragment.startOffset + fragment.utf16Length - 1
            )
        }

        guard let leftElementID else {
            preconditionFailure("A structurally nonempty state must have a final element")
        }
        return .after(leftElementID)
    }

    /// Derives a portable insertion payload without reserving or persisting identity.
    public func insertOperationPayload(
        operationID: SyncOperationID,
        atVisibleUTF16Offset offset: Int,
        formatVersion: SyncTextOperationPayloadFormatVersion = .v1
    ) throws -> SyncTextInsertOperationPayload {
        SyncTextInsertOperationPayload(
            operationID: operationID,
            anchor: try operationAnchor(atVisibleUTF16Offset: offset),
            formatVersion: formatVersion
        )
    }

    /// Derives compact deleted identity without mutating the authoritative state.
    public func deleteOperationPayload(
        operationID: SyncOperationID,
        inVisibleUTF16Range range: Range<Int>,
        formatVersion: SyncTextOperationPayloadFormatVersion = .v1
    ) throws -> SyncTextDeleteOperationPayload {
        try SyncTextDeleteOperationPayload(
            operationID: operationID,
            deletedElementIDSpans: elementIDSpans(inVisibleUTF16Range: range),
            formatVersion: formatVersion
        )
    }

    public var tombstonedElementIDSpans: [SyncTextElementIDSpan] {
        var result: [SyncTextElementIDSpan] = []
        var previousSelectedFragmentIndex: Int?

        for (fragmentIndex, fragment) in fragments.enumerated() {
            guard fragment.visibility == .tombstone else { continue }
            let span = SyncTextElementIDSpan(
                validatedOperationID: fragment.operationID,
                startOffset: fragment.startOffset,
                utf16Length: fragment.utf16Length
            )
            let isStructurallyAdjacent = previousSelectedFragmentIndex.map {
                $0 + 1 == fragmentIndex
            } ?? false
            append(span, to: &result, allowingCoalescing: isStructurallyAdjacent)
            previousSelectedFragmentIndex = fragmentIndex
        }
        return result
    }

    private func append(
        _ span: SyncTextElementIDSpan,
        to result: inout [SyncTextElementIDSpan],
        allowingCoalescing: Bool
    ) {
        if allowingCoalescing,
           let previous = result.last,
           previous.operationID == span.operationID,
           previous.startOffset + previous.utf16Length == span.startOffset {
            result[result.count - 1] = SyncTextElementIDSpan(
                validatedOperationID: previous.operationID,
                startOffset: previous.startOffset,
                utf16Length: previous.utf16Length + span.utf16Length
            )
        } else {
            result.append(span)
        }
    }

    private static func operationAnchor(
        leftElementID: SyncTextElementID?,
        rightElementID: SyncTextElementID?
    ) throws -> SyncOperationAnchor {
        switch (leftElementID, rightElementID) {
        case (nil, nil):
            return .empty
        case (nil, let rightElementID?):
            return .before(rightElementID)
        case (let leftElementID?, let rightElementID?):
            return try .between(left: leftElementID, right: rightElementID)
        case (let leftElementID?, nil):
            return .after(leftElementID)
        }
    }
}

private struct SyncTextSequenceGap: Equatable, Hashable {
    let left: SyncTextElementID?
    let right: SyncTextElementID?
}

private struct SyncTextSequenceScalarSpan {
    let startOffset: Int
    let utf16Length: Int
}

private struct SyncTextSequenceStructuralSpan {
    let operationID: SyncOperationID
    let startOffset: Int
    let utf16Length: Int
}

private enum SyncTextSequenceTraversalCommand {
    case expandGap(SyncTextSequenceGap)
    case expandRun(Int)
    case emit(SyncTextSequenceStructuralSpan)
}

private struct SyncTextSequenceValidationResult {
    let visibleText: String
    let visibleUTF16Count: Int
    let tombstonedUTF16Count: Int
    let metrics: SyncTextSequenceTraversalMetrics
}

private enum SyncTextSequenceStateValidator {
    static func validate(
        runs: [SyncTextSequenceRun],
        fragments: [SyncTextSequenceFragment]
    ) throws -> SyncTextSequenceValidationResult {
        let runIndex = try validatedRunIndex(runs)
        try validateCanonicalRunOrder(runs)

        let scalarSpans = runs.map { SyncTextSequenceStringBoundary.scalarSpans(in: $0.text) }
        let legalBoundaries = scalarSpans.map(
            SyncTextSequenceStringBoundary.legalBoundaryOffsets
        )
        try validateOrigins(
            runs,
            runIndex: runIndex,
            legalBoundaries: legalBoundaries
        )
        try validateAcyclicOrigins(runs, runIndex: runIndex)

        let gapIndex = try makeGapIndex(runs)
        var metrics = SyncTextSequenceTraversalMetrics()
        let structuralSpans = try deriveStructuralSpans(
            runs: runs,
            scalarSpans: scalarSpans,
            gapIndex: gapIndex,
            metrics: &metrics
        )

        try validateFragments(
            fragments,
            runs: runs,
            runIndex: runIndex,
            legalBoundaries: legalBoundaries
        )
        try compareProjection(
            structuralSpans,
            fragments: fragments,
            metrics: &metrics
        )

        return try materialize(
            fragments: fragments,
            runs: runs,
            runIndex: runIndex,
            metrics: metrics
        )
    }

    private static func validatedRunIndex(
        _ runs: [SyncTextSequenceRun]
    ) throws -> [SyncOperationID: Int] {
        var result: [SyncOperationID: Int] = [:]
        result.reserveCapacity(runs.count)
        for (index, run) in runs.enumerated() {
            guard result.updateValue(index, forKey: run.operationID) == nil else {
                throw SyncTextSequenceStateError.duplicateRun(run.operationID)
            }
        }
        return result
    }

    private static func validateCanonicalRunOrder(
        _ runs: [SyncTextSequenceRun]
    ) throws {
        for index in runs.indices.dropFirst() {
            let previous = runs[index - 1].operationID
            let current = runs[index].operationID
            guard SyncOperationIDCanonicalOrder.isOrderedBefore(previous, current) else {
                throw SyncTextSequenceStateError.noncanonicalRunOrder(
                    previous: previous,
                    current: current
                )
            }
        }
    }

    private static func validateOrigins(
        _ runs: [SyncTextSequenceRun],
        runIndex: [SyncOperationID: Int],
        legalBoundaries: [Set<Int>]
    ) throws {
        for run in runs {
            for (elementID, isLeftEndpoint) in [
                (run.origin.leftElementID, true),
                (run.origin.rightElementID, false)
            ] {
                guard let elementID else { continue }
                guard let ownerIndex = runIndex[elementID.operationID] else {
                    throw SyncTextSequenceStateError.unknownOrigin(elementID)
                }
                let ownerLength = runs[ownerIndex].text.utf16.count
                guard elementID.elementOffset < ownerLength else {
                    throw SyncTextSequenceStateError.unknownOrigin(elementID)
                }
                guard elementID.operationID != run.operationID else {
                    throw SyncTextSequenceStateError.selfOrigin(run.operationID)
                }

                let boundaryOffset = isLeftEndpoint
                    ? elementID.elementOffset + 1
                    : elementID.elementOffset
                guard legalBoundaries[ownerIndex].contains(boundaryOffset) else {
                    throw SyncTextSequenceStateError.originSplitsSurrogatePair(elementID)
                }
            }
        }
    }

    private static func validateAcyclicOrigins(
        _ runs: [SyncTextSequenceRun],
        runIndex: [SyncOperationID: Int]
    ) throws {
        var dependencyCount = Array(repeating: 0, count: runs.count)
        var dependents = Array(repeating: [Int](), count: runs.count)

        for (runIndexValue, run) in runs.enumerated() {
            let dependencies = Set([
                run.origin.leftElementID?.operationID,
                run.origin.rightElementID?.operationID
            ].compactMap { $0 })
            dependencyCount[runIndexValue] = dependencies.count
            for dependency in dependencies {
                dependents[runIndex[dependency]!].append(runIndexValue)
            }
        }

        var ready = dependencyCount.indices.filter { dependencyCount[$0] == 0 }
        var processed = 0
        while let next = ready.popLast() {
            processed += 1
            for dependent in dependents[next] {
                dependencyCount[dependent] -= 1
                if dependencyCount[dependent] == 0 {
                    ready.append(dependent)
                }
            }
        }
        guard processed == runs.count else {
            throw SyncTextSequenceStateError.cyclicOriginDependency
        }
    }

    private static func makeGapIndex(
        _ runs: [SyncTextSequenceRun]
    ) throws -> [SyncTextSequenceGap: [Int]] {
        var result: [SyncTextSequenceGap: [Int]] = [:]
        for (index, run) in runs.enumerated() {
            let gap = SyncTextSequenceGap(
                left: run.origin.leftElementID,
                right: run.origin.rightElementID
            )
            if let previousIndex = result[gap]?.last {
                let previous = runs[previousIndex].operationID
                guard SyncOperationIDCanonicalOrder.isOrderedBefore(previous, run.operationID) else {
                    throw SyncTextSequenceStateError.noncanonicalSiblingOrder(
                        previous: previous,
                        current: run.operationID
                    )
                }
            }
            result[gap, default: []].append(index)
        }
        return result
    }

    private static func deriveStructuralSpans(
        runs: [SyncTextSequenceRun],
        scalarSpans: [[SyncTextSequenceScalarSpan]],
        gapIndex: [SyncTextSequenceGap: [Int]],
        metrics: inout SyncTextSequenceTraversalMetrics
    ) throws -> [SyncTextSequenceStructuralSpan] {
        var commands: [SyncTextSequenceTraversalCommand] = [
            .expandGap(SyncTextSequenceGap(left: nil, right: nil))
        ]
        var reached = Set<SyncOperationID>()
        var output: [SyncTextSequenceStructuralSpan] = []

        while let command = commands.popLast() {
            metrics.processedFrames += 1
            switch command {
            case .expandGap(let gap):
                metrics.gapIndexLookups += 1
                for runIndex in (gapIndex[gap] ?? []).reversed() {
                    commands.append(.expandRun(runIndex))
                }

            case .expandRun(let runIndex):
                let run = runs[runIndex]
                guard reached.insert(run.operationID).inserted else {
                    throw SyncTextSequenceStateError.duplicateStructuralReachability(
                        run.operationID
                    )
                }

                let spans = scalarSpans[runIndex]
                let finalLeft = try SyncTextElementID(
                    operationID: run.operationID,
                    elementOffset: run.text.utf16.count - 1
                )
                commands.append(.expandGap(SyncTextSequenceGap(
                    left: finalLeft,
                    right: run.origin.rightElementID
                )))

                for scalarIndex in spans.indices.reversed() {
                    let scalar = spans[scalarIndex]
                    commands.append(.emit(SyncTextSequenceStructuralSpan(
                        operationID: run.operationID,
                        startOffset: scalar.startOffset,
                        utf16Length: scalar.utf16Length
                    )))

                    let right = try SyncTextElementID(
                        operationID: run.operationID,
                        elementOffset: scalar.startOffset
                    )
                    let left = scalarIndex == spans.startIndex
                        ? run.origin.leftElementID
                        : try SyncTextElementID(
                            operationID: run.operationID,
                            elementOffset: scalar.startOffset - 1
                        )
                    commands.append(.expandGap(SyncTextSequenceGap(
                        left: left,
                        right: right
                    )))
                }

            case .emit(let span):
                if let previous = output.last,
                   previous.operationID == span.operationID,
                   previous.startOffset + previous.utf16Length == span.startOffset {
                    output[output.count - 1] = SyncTextSequenceStructuralSpan(
                        operationID: previous.operationID,
                        startOffset: previous.startOffset,
                        utf16Length: previous.utf16Length + span.utf16Length
                    )
                } else {
                    output.append(span)
                }
            }
        }

        if reached.count != runs.count,
           let unreachable = runs.first(where: { !reached.contains($0.operationID) }) {
            throw SyncTextSequenceStateError.unreachableOriginGap(unreachable.operationID)
        }
        return output
    }

    private static func validateFragments(
        _ fragments: [SyncTextSequenceFragment],
        runs: [SyncTextSequenceRun],
        runIndex: [SyncOperationID: Int],
        legalBoundaries: [Set<Int>]
    ) throws {
        for (fragmentIndex, fragment) in fragments.enumerated() {
            guard let ownerIndex = runIndex[fragment.operationID] else {
                throw SyncTextSequenceStateError.fragmentReferencesUnknownRun(
                    fragment.operationID
                )
            }
            let endOffset = try SyncTextSequenceRangeValidation.checkedEnd(
                startOffset: fragment.startOffset,
                utf16Length: fragment.utf16Length
            )
            guard endOffset <= runs[ownerIndex].text.utf16.count else {
                throw SyncTextSequenceStateError.fragmentRangeExceedsRun(
                    fragment.operationID
                )
            }
            for boundary in [fragment.startOffset, endOffset] {
                guard legalBoundaries[ownerIndex].contains(boundary) else {
                    throw SyncTextSequenceStateError.fragmentSplitsSurrogatePair(
                        fragment.operationID,
                        offset: boundary
                    )
                }
            }

            if fragmentIndex > 0 {
                let previous = fragments[fragmentIndex - 1]
                if previous.operationID == fragment.operationID,
                   previous.visibility == fragment.visibility,
                   previous.startOffset + previous.utf16Length == fragment.startOffset {
                    throw SyncTextSequenceStateError.mergeableAdjacentFragments(
                        fragment.operationID
                    )
                }
            }
        }
    }

    private static func compareProjection(
        _ structuralSpans: [SyncTextSequenceStructuralSpan],
        fragments: [SyncTextSequenceFragment],
        metrics: inout SyncTextSequenceTraversalMetrics
    ) throws {
        var structuralIndex = 0
        var fragmentIndex = 0
        var structuralConsumed = 0
        var fragmentConsumed = 0

        while structuralIndex < structuralSpans.count, fragmentIndex < fragments.count {
            metrics.comparedSpans += 1
            let structural = structuralSpans[structuralIndex]
            let fragment = fragments[fragmentIndex]
            guard structural.operationID == fragment.operationID,
                  structural.startOffset + structuralConsumed ==
                    fragment.startOffset + fragmentConsumed else {
                throw SyncTextSequenceStateError.fragmentOrderNotMatchingOrigins
            }

            let structuralRemaining = structural.utf16Length - structuralConsumed
            let fragmentRemaining = fragment.utf16Length - fragmentConsumed
            let comparedLength = min(structuralRemaining, fragmentRemaining)
            structuralConsumed += comparedLength
            fragmentConsumed += comparedLength

            if structuralConsumed == structural.utf16Length {
                structuralIndex += 1
                structuralConsumed = 0
            }
            if fragmentConsumed == fragment.utf16Length {
                fragmentIndex += 1
                fragmentConsumed = 0
            }
        }

        guard structuralIndex == structuralSpans.count,
              fragmentIndex == fragments.count else {
            throw SyncTextSequenceStateError.fragmentOrderNotMatchingOrigins
        }
    }

    private static func materialize(
        fragments: [SyncTextSequenceFragment],
        runs: [SyncTextSequenceRun],
        runIndex: [SyncOperationID: Int],
        metrics: SyncTextSequenceTraversalMetrics
    ) throws -> SyncTextSequenceValidationResult {
        var visibleText = ""
        var visibleCount = 0
        var tombstonedCount = 0

        for fragment in fragments {
            switch fragment.visibility {
            case .visible:
                let (nextCount, overflow) = visibleCount.addingReportingOverflow(
                    fragment.utf16Length
                )
                guard !overflow else { throw SyncTextSequenceStateError.countOverflow }
                visibleCount = nextCount
                let text = runs[runIndex[fragment.operationID]!].text
                visibleText.append(contentsOf: SyncTextSequenceStringBoundary.substring(
                    text,
                    startOffset: fragment.startOffset,
                    utf16Length: fragment.utf16Length
                ))
            case .tombstone:
                let (nextCount, overflow) = tombstonedCount.addingReportingOverflow(
                    fragment.utf16Length
                )
                guard !overflow else { throw SyncTextSequenceStateError.countOverflow }
                tombstonedCount = nextCount
            }
        }

        return SyncTextSequenceValidationResult(
            visibleText: visibleText,
            visibleUTF16Count: visibleCount,
            tombstonedUTF16Count: tombstonedCount,
            metrics: metrics
        )
    }
}

private enum SyncTextSequenceStringBoundary {
    static func scalarSpans(in text: String) -> [SyncTextSequenceScalarSpan] {
        var result: [SyncTextSequenceScalarSpan] = []
        result.reserveCapacity(text.unicodeScalars.count)
        var offset = 0
        for scalar in text.unicodeScalars {
            let length = scalar.utf16.count
            result.append(SyncTextSequenceScalarSpan(
                startOffset: offset,
                utf16Length: length
            ))
            offset += length
        }
        return result
    }

    /// Boundary lookup remains constant-time even when many runs target one long run.
    static func legalBoundaryOffsets(
        for spans: [SyncTextSequenceScalarSpan]
    ) -> Set<Int> {
        var result: Set<Int> = [0]
        result.reserveCapacity(spans.count + 1)
        for span in spans {
            result.insert(span.startOffset)
            result.insert(span.startOffset + span.utf16Length)
        }
        return result
    }

    static func isBoundary(_ offset: Int, in text: String) -> Bool {
        guard offset >= 0, offset <= text.utf16.count else { return false }
        let utf16Index = text.utf16.index(text.utf16.startIndex, offsetBy: offset)
        return String.Index(utf16Index, within: text) != nil
    }

    static func substring(
        _ text: String,
        startOffset: Int,
        utf16Length: Int
    ) -> Substring {
        let utf16Start = text.utf16.index(text.utf16.startIndex, offsetBy: startOffset)
        let utf16End = text.utf16.index(utf16Start, offsetBy: utf16Length)
        let start = String.Index(utf16Start, within: text)!
        let end = String.Index(utf16End, within: text)!
        return text[start..<end]
    }
}
