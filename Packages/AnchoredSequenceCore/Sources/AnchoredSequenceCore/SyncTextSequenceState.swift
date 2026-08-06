import Foundation

public enum SyncTextSequenceStateError: Error, Equatable, Sendable {
    case identicalOriginEndpoints(SyncTextElementID)
    case emptyRunText(SyncOperationID)
    case negativeRangeOffset(Int)
    case nonpositiveRangeLength(Int)
    case rangeOverflow(startOffset: Int, utf16Length: Int)
    case duplicateRun(SyncOperationID)
    case missingAnchorDependency(SyncTextElementID)
    case anchorElementOutOfBounds(SyncTextElementID)
    case betweenAnchorEndpointsReversed(
        left: SyncTextElementID,
        right: SyncTextElementID
    )
    case anchorGapNotDurable(
        left: SyncTextElementID?,
        right: SyncTextElementID?
    )
    case missingDeleteDependency(SyncOperationID)
    case deleteTargetRangeExceedsRun(SyncTextElementIDSpan)
    case deleteTargetSplitsSurrogatePair(
        SyncTextElementIDSpan,
        offset: Int
    )
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
        let lhsBytes = SyncOperationIDRawUUIDBytes.bytes(of: lhs.deviceID)
        let rhsBytes = SyncOperationIDRawUUIDBytes.bytes(of: rhs.deviceID)

        if lhsBytes != rhsBytes {
            return lhsBytes.lexicographicallyPrecedes(rhsBytes)
        }
        return lhs.localCounter < rhs.localCounter
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

struct SyncTextSequenceAnchorResolutionMetrics: Equatable, Sendable {
    var indexedRuns = 0
    var declaredOrigins = 0
    var visitedFragments = 0
    var durableGapChecks = 0
}

struct SyncTextSequenceDeletionMetrics: Equatable, Sendable {
    var preflightedSpans = 0
    var visitedFragments = 0
    var targetIntersections = 0
    var emittedFragments = 0
}

public struct SyncTextSequenceState: Equatable, Sendable {
    public let runs: [SyncTextSequenceRun]
    public let fragments: [SyncTextSequenceFragment]

    private let materializedVisibleText: String
    private let materializedVisibleUTF16Count: Int
    private let materializedTombstonedUTF16Count: Int
    private let anchorResolutionIndex: SyncTextSequenceAnchorResolutionIndex

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
        let anchorResolutionIndex = try SyncTextSequenceAnchorResolutionIndex(
            runs: runs,
            fragments: fragments
        )
        self.runs = runs
        self.fragments = fragments
        self.materializedVisibleText = validation.visibleText
        self.materializedVisibleUTF16Count = validation.visibleUTF16Count
        self.materializedTombstonedUTF16Count = validation.tombstonedUTF16Count
        self.anchorResolutionIndex = anchorResolutionIndex
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

    /// Resolves a visible cursor to one deterministic durable structural gap.
    public func operationAnchor(
        atVisibleUTF16Offset offset: Int
    ) throws -> SyncOperationAnchor {
        try operationAnchorWithMetrics(atVisibleUTF16Offset: offset).anchor
    }

    /// Kept internal so complexity tests can prove capture work without timing assertions.
    func operationAnchorWithMetrics(
        atVisibleUTF16Offset offset: Int
    ) throws -> (
        anchor: SyncOperationAnchor,
        metrics: SyncTextSequenceAnchorResolutionMetrics
    ) {
        guard offset >= 0, offset <= visibleUTF16Count else {
            throw SyncTextSequenceStateError.visibleOffsetOutOfBounds(offset)
        }
        guard SyncTextSequenceStringBoundary.isBoundary(
            offset,
            in: materializedVisibleText
        ) else {
            throw SyncTextSequenceStateError.visibleOffsetSplitsSurrogatePair(offset)
        }

        var metrics = SyncTextSequenceAnchorResolutionMetrics()
        let durableGaps = anchorResolutionIndex.durableGaps
        guard !fragments.isEmpty else {
            return (.empty, metrics)
        }

        if let entry = anchorResolutionIndex.visibleFragment(
            containingVisibleUTF16Offset: offset,
            metrics: &metrics
        ) {
            let offsetInFragment = offset - entry.visibleStartOffset
            var leftElementID = entry.structuralLeftElementID
            let rightElementID = try SyncTextElementID(
                operationID: entry.fragment.operationID,
                elementOffset: entry.fragment.startOffset + offsetInFragment
            )
            if offsetInFragment > 0 {
                leftElementID = try SyncTextElementID(
                    operationID: entry.fragment.operationID,
                    elementOffset: entry.fragment.startOffset + offsetInFragment - 1
                )
            }
            let anchor = try canonicalOperationAnchor(
                leftElementID: leftElementID,
                rightElementID: rightElementID,
                durableGaps: durableGaps,
                metrics: &metrics
            )
            return (anchor, metrics)
        }

        guard let leftElementID = anchorResolutionIndex.finalStructuralElementID else {
            preconditionFailure("A structurally nonempty state must have a final element")
        }
        let anchor = try canonicalOperationAnchor(
            leftElementID: leftElementID,
            rightElementID: nil,
            durableGaps: durableGaps,
            metrics: &metrics
        )
        return (anchor, metrics)
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

    /// Incorporates one validated structural insertion without mutating this state.
    public func incorporating(
        insert payload: SyncTextInsertOperationPayload,
        insertedText: String
    ) throws -> SyncTextSequenceState {
        guard !insertedText.isEmpty else {
            throw SyncTextSequenceStateError.emptyRunText(payload.operationID)
        }
        guard !runs.contains(where: { $0.operationID == payload.operationID }) else {
            throw SyncTextSequenceStateError.duplicateRun(payload.operationID)
        }

        let endpoints = [
            payload.anchor.leftElementID,
            payload.anchor.rightElementID
        ].compactMap { $0 }
        if endpoints.contains(where: { $0.operationID == payload.operationID }) {
            throw SyncTextSequenceStateError.selfOrigin(payload.operationID)
        }

        let durableGaps = anchorResolutionIndex.durableGaps

        func resolveEndpoint(
            _ elementID: SyncTextElementID,
            isLeftEndpoint: Bool
        ) throws {
            guard let owner = durableGaps.run(owning: elementID) else {
                throw SyncTextSequenceStateError.missingAnchorDependency(elementID)
            }
            guard elementID.elementOffset < owner.text.utf16.count else {
                throw SyncTextSequenceStateError.anchorElementOutOfBounds(elementID)
            }

            let boundaryOffset = isLeftEndpoint
                ? elementID.elementOffset + 1
                : elementID.elementOffset
            guard SyncTextSequenceStringBoundary.isBoundary(
                boundaryOffset,
                in: owner.text
            ) else {
                throw SyncTextSequenceStateError.originSplitsSurrogatePair(elementID)
            }
        }

        switch payload.anchor.kind {
        case .empty:
            break
        case .before:
            try resolveEndpoint(payload.anchor.rightElementID!, isLeftEndpoint: false)
        case .between:
            try resolveEndpoint(payload.anchor.leftElementID!, isLeftEndpoint: true)
            try resolveEndpoint(payload.anchor.rightElementID!, isLeftEndpoint: false)
        case .after:
            try resolveEndpoint(payload.anchor.leftElementID!, isLeftEndpoint: true)
        }

        let resolvedOrigin = try SyncTextInsertionOrigin(
            leftElementID: payload.anchor.leftElementID,
            rightElementID: payload.anchor.rightElementID
        )
        let declaredGap = SyncTextSequenceGap(
            left: resolvedOrigin.leftElementID,
            right: resolvedOrigin.rightElementID
        )

        if payload.anchor.kind == .between {
            let left = payload.anchor.leftElementID!
            let right = payload.anchor.rightElementID!
            if structuralPosition(of: right) < structuralPosition(of: left) {
                throw SyncTextSequenceStateError.betweenAnchorEndpointsReversed(
                    left: left,
                    right: right
                )
            }
        }

        guard durableGaps.contains(declaredGap) else {
            throw SyncTextSequenceStateError.anchorGapNotDurable(
                left: declaredGap.left,
                right: declaredGap.right
            )
        }

        let insertedRun = try SyncTextSequenceRun(
            operationID: payload.operationID,
            origin: resolvedOrigin,
            text: insertedText
        )
        var replacementRuns = runs
        let insertionIndex = replacementRuns.firstIndex {
            SyncOperationIDCanonicalOrder.isOrderedBefore(
                payload.operationID,
                $0.operationID
            )
        } ?? replacementRuns.endIndex
        replacementRuns.insert(insertedRun, at: insertionIndex)

        let replacementSpans = try SyncTextSequenceStateValidator.projectStructuralSpans(
            runs: replacementRuns
        )
        let replacementFragments = try remapVisibility(
            across: replacementSpans,
            insertedOperationID: payload.operationID
        )

        return try SyncTextSequenceState(
            runs: replacementRuns,
            fragments: replacementFragments
        )
    }


    /// Incorporates one validated identity-targeted deletion without mutating this state.
    public func incorporating(
        delete payload: SyncTextDeleteOperationPayload
    ) throws -> SyncTextSequenceState {
        try incorporatingDeleteWithMetrics(payload).state
    }

    /// Kept internal so complexity tests can prove bounded work without timing assertions.
    func incorporatingDeleteWithMetrics(
        _ payload: SyncTextDeleteOperationPayload
    ) throws -> (
        state: SyncTextSequenceState,
        metrics: SyncTextSequenceDeletionMetrics
    ) {
        var metrics = SyncTextSequenceDeletionMetrics()
        let runsByOperation = Dictionary(
            uniqueKeysWithValues: runs.map { ($0.operationID, $0) }
        )
        var spansByOperation: [
            SyncOperationID: [SyncTextElementIDSpan]
        ] = [:]

        for span in payload.deletedElementIDSpans {
            metrics.preflightedSpans += 1
            guard let run = runsByOperation[span.operationID] else {
                throw SyncTextSequenceStateError.missingDeleteDependency(
                    span.operationID
                )
            }

            let endOffset = span.startOffset + span.utf16Length
            guard endOffset <= run.text.utf16.count else {
                throw SyncTextSequenceStateError.deleteTargetRangeExceedsRun(span)
            }
            guard SyncTextSequenceStringBoundary.isBoundary(
                span.startOffset,
                in: run.text
            ) else {
                throw SyncTextSequenceStateError.deleteTargetSplitsSurrogatePair(
                    span,
                    offset: span.startOffset
                )
            }
            guard SyncTextSequenceStringBoundary.isBoundary(
                endOffset,
                in: run.text
            ) else {
                throw SyncTextSequenceStateError.deleteTargetSplitsSurrogatePair(
                    span,
                    offset: endOffset
                )
            }

            spansByOperation[span.operationID, default: []].append(span)
        }

        var nextSpanIndexByOperation: [SyncOperationID: Int] = [:]
        var replacementFragments: [SyncTextSequenceFragment] = []
        replacementFragments.reserveCapacity(fragments.count)
        var changed = false

        func appendFragment(
            operationID: SyncOperationID,
            startOffset: Int,
            utf16Length: Int,
            visibility: SyncTextSequenceElementVisibility
        ) throws {
            guard utf16Length > 0 else { return }

            if let previous = replacementFragments.last,
               previous.operationID == operationID,
               previous.visibility == visibility,
               previous.startOffset + previous.utf16Length == startOffset {
                replacementFragments[replacementFragments.count - 1] =
                    try SyncTextSequenceFragment(
                        operationID: operationID,
                        startOffset: previous.startOffset,
                        utf16Length: previous.utf16Length + utf16Length,
                        visibility: visibility
                    )
            } else {
                replacementFragments.append(
                    try SyncTextSequenceFragment(
                        operationID: operationID,
                        startOffset: startOffset,
                        utf16Length: utf16Length,
                        visibility: visibility
                    )
                )
            }
        }

        for fragment in fragments {
            metrics.visitedFragments += 1
            guard let operationSpans = spansByOperation[fragment.operationID] else {
                try appendFragment(
                    operationID: fragment.operationID,
                    startOffset: fragment.startOffset,
                    utf16Length: fragment.utf16Length,
                    visibility: fragment.visibility
                )
                continue
            }

            let fragmentEnd = fragment.startOffset + fragment.utf16Length
            var spanIndex = nextSpanIndexByOperation[fragment.operationID] ?? 0
            while spanIndex < operationSpans.count {
                let span = operationSpans[spanIndex]
                let spanEnd = span.startOffset + span.utf16Length
                guard spanEnd <= fragment.startOffset else { break }
                spanIndex += 1
            }

            var cursor = fragment.startOffset
            var scanIndex = spanIndex
            while scanIndex < operationSpans.count {
                let span = operationSpans[scanIndex]
                let spanEnd = span.startOffset + span.utf16Length

                if spanEnd <= cursor {
                    scanIndex += 1
                    continue
                }
                if span.startOffset >= fragmentEnd {
                    break
                }

                let intersectionStart = max(cursor, span.startOffset)
                let intersectionEnd = min(fragmentEnd, spanEnd)
                if cursor < intersectionStart {
                    try appendFragment(
                        operationID: fragment.operationID,
                        startOffset: cursor,
                        utf16Length: intersectionStart - cursor,
                        visibility: fragment.visibility
                    )
                }
                if intersectionStart < intersectionEnd {
                    metrics.targetIntersections += 1
                    changed = changed || fragment.visibility == .visible
                    try appendFragment(
                        operationID: fragment.operationID,
                        startOffset: intersectionStart,
                        utf16Length: intersectionEnd - intersectionStart,
                        visibility: .tombstone
                    )
                    cursor = intersectionEnd
                }

                if spanEnd <= fragmentEnd {
                    scanIndex += 1
                } else {
                    break
                }
            }

            if cursor < fragmentEnd {
                try appendFragment(
                    operationID: fragment.operationID,
                    startOffset: cursor,
                    utf16Length: fragmentEnd - cursor,
                    visibility: fragment.visibility
                )
            }
            nextSpanIndexByOperation[fragment.operationID] = scanIndex
        }

        metrics.emittedFragments = replacementFragments.count
        guard changed else {
            return (self, metrics)
        }

        return (
            try SyncTextSequenceState(
                runs: runs,
                fragments: replacementFragments
            ),
            metrics
        )
    }

    private func canonicalOperationAnchor(
        leftElementID: SyncTextElementID?,
        rightElementID: SyncTextElementID?,
        durableGaps: SyncTextSequenceDurableGapIndex,
        metrics: inout SyncTextSequenceAnchorResolutionMetrics
    ) throws -> SyncOperationAnchor {
        let immediateGap = SyncTextSequenceGap(
            left: leftElementID,
            right: rightElementID
        )
        metrics.durableGapChecks += 1
        if durableGaps.contains(immediateGap) {
            return try Self.operationAnchor(
                leftElementID: immediateGap.left,
                rightElementID: immediateGap.right
            )
        }

        guard let leftElementID,
              let owner = durableGaps.run(owning: leftElementID),
              leftElementID.elementOffset == owner.text.utf16.count - 1 else {
            preconditionFailure(
                "A validated cursor boundary must resolve to a durable structural gap"
            )
        }

        let exitGap = SyncTextSequenceGap(
            left: leftElementID,
            right: owner.origin.rightElementID
        )
        metrics.durableGapChecks += 1
        guard durableGaps.contains(exitGap) else {
            preconditionFailure(
                "A completed structural subtree must expose its durable exit gap"
            )
        }
        return try Self.operationAnchor(
            leftElementID: exitGap.left,
            rightElementID: exitGap.right
        )
    }

    private func structuralPosition(of elementID: SyncTextElementID) -> Int {
        var position = 0
        for fragment in fragments {
            let endOffset = fragment.startOffset + fragment.utf16Length
            if fragment.operationID == elementID.operationID,
               fragment.startOffset <= elementID.elementOffset,
               elementID.elementOffset < endOffset {
                return position + elementID.elementOffset - fragment.startOffset
            }
            position += fragment.utf16Length
        }
        preconditionFailure("A preflight-resolved element must exist in the structural stream")
    }

    private func remapVisibility(
        across structuralSpans: [SyncTextSequenceStructuralSpan],
        insertedOperationID: SyncOperationID
    ) throws -> [SyncTextSequenceFragment] {
        var sourceFragmentsByOperation: [
            SyncOperationID: [SyncTextSequenceFragment]
        ] = [:]
        for fragment in fragments {
            sourceFragmentsByOperation[fragment.operationID, default: []].append(fragment)
        }

        var sourceIndexByOperation: [SyncOperationID: Int] = [:]
        var result: [SyncTextSequenceFragment] = []

        func appendFragment(
            operationID: SyncOperationID,
            startOffset: Int,
            utf16Length: Int,
            visibility: SyncTextSequenceElementVisibility
        ) throws {
            if let previous = result.last,
               previous.operationID == operationID,
               previous.visibility == visibility,
               previous.startOffset + previous.utf16Length == startOffset {
                result[result.count - 1] = try SyncTextSequenceFragment(
                    operationID: operationID,
                    startOffset: previous.startOffset,
                    utf16Length: previous.utf16Length + utf16Length,
                    visibility: visibility
                )
            } else {
                result.append(try SyncTextSequenceFragment(
                    operationID: operationID,
                    startOffset: startOffset,
                    utf16Length: utf16Length,
                    visibility: visibility
                ))
            }
        }

        for span in structuralSpans {
            if span.operationID == insertedOperationID {
                try appendFragment(
                    operationID: span.operationID,
                    startOffset: span.startOffset,
                    utf16Length: span.utf16Length,
                    visibility: .visible
                )
                continue
            }

            guard let sourceFragments = sourceFragmentsByOperation[span.operationID] else {
                throw SyncTextSequenceStateError.fragmentOrderNotMatchingOrigins
            }

            var sourceIndex = sourceIndexByOperation[span.operationID] ?? 0
            var nextOffset = span.startOffset
            let spanEnd = span.startOffset + span.utf16Length

            while sourceIndex < sourceFragments.count,
                  sourceFragments[sourceIndex].startOffset
                    + sourceFragments[sourceIndex].utf16Length <= nextOffset {
                sourceIndex += 1
            }

            while nextOffset < spanEnd {
                guard sourceIndex < sourceFragments.count else {
                    throw SyncTextSequenceStateError.fragmentOrderNotMatchingOrigins
                }
                let source = sourceFragments[sourceIndex]
                let sourceEnd = source.startOffset + source.utf16Length
                guard source.startOffset <= nextOffset, nextOffset < sourceEnd else {
                    throw SyncTextSequenceStateError.fragmentOrderNotMatchingOrigins
                }

                let nextEnd = min(spanEnd, sourceEnd)
                try appendFragment(
                    operationID: span.operationID,
                    startOffset: nextOffset,
                    utf16Length: nextEnd - nextOffset,
                    visibility: source.visibility
                )
                nextOffset = nextEnd
                if nextOffset == sourceEnd {
                    sourceIndex += 1
                }
            }
            sourceIndexByOperation[span.operationID] = sourceIndex
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

private struct SyncTextSequenceVisibleFragmentAnchorEntry: Sendable {
    let fragment: SyncTextSequenceFragment
    let visibleStartOffset: Int
    let visibleEndOffset: Int
    let structuralLeftElementID: SyncTextElementID?
}

private struct SyncTextSequenceAnchorResolutionIndex: Sendable {
    let durableGaps: SyncTextSequenceDurableGapIndex
    let visibleFragments: [SyncTextSequenceVisibleFragmentAnchorEntry]
    let finalStructuralElementID: SyncTextElementID?

    init(
        runs: [SyncTextSequenceRun],
        fragments: [SyncTextSequenceFragment]
    ) throws {
        self.durableGaps = SyncTextSequenceDurableGapIndex(runs: runs)

        var visibleFragments: [SyncTextSequenceVisibleFragmentAnchorEntry] = []
        visibleFragments.reserveCapacity(fragments.count)
        var visibleCursor = 0
        var structuralLeftElementID: SyncTextElementID?

        for fragment in fragments {
            if fragment.visibility == .visible {
                let (visibleEndOffset, overflow) = visibleCursor.addingReportingOverflow(
                    fragment.utf16Length
                )
                guard !overflow else {
                    throw SyncTextSequenceStateError.countOverflow
                }
                visibleFragments.append(
                    SyncTextSequenceVisibleFragmentAnchorEntry(
                        fragment: fragment,
                        visibleStartOffset: visibleCursor,
                        visibleEndOffset: visibleEndOffset,
                        structuralLeftElementID: structuralLeftElementID
                    )
                )
                visibleCursor = visibleEndOffset
            }

            structuralLeftElementID = try SyncTextElementID(
                operationID: fragment.operationID,
                elementOffset: fragment.startOffset + fragment.utf16Length - 1
            )
        }

        self.visibleFragments = visibleFragments
        self.finalStructuralElementID = structuralLeftElementID
    }

    func visibleFragment(
        containingVisibleUTF16Offset offset: Int,
        metrics: inout SyncTextSequenceAnchorResolutionMetrics
    ) -> SyncTextSequenceVisibleFragmentAnchorEntry? {
        var lowerBound = 0
        var upperBound = visibleFragments.count

        while lowerBound < upperBound {
            metrics.visitedFragments += 1
            let middle = lowerBound + (upperBound - lowerBound) / 2
            if offset < visibleFragments[middle].visibleEndOffset {
                upperBound = middle
            } else {
                lowerBound = middle + 1
            }
        }

        guard lowerBound < visibleFragments.count else { return nil }
        let entry = visibleFragments[lowerBound]
        guard entry.visibleStartOffset <= offset else {
            preconditionFailure(
                "A validated visible offset must resolve inside the indexed fragment"
            )
        }
        return entry
    }
}

private struct SyncTextSequenceGap: Equatable, Hashable, Sendable {
    let left: SyncTextElementID?
    let right: SyncTextElementID?
}

private struct SyncTextSequenceDurableGapIndex: Sendable {
    private let runs: [SyncTextSequenceRun]
    private let runIndex: [SyncOperationID: Int]
    private let declaredOrigins: Set<SyncTextSequenceGap>

    init(runs: [SyncTextSequenceRun]) {
        self.runs = runs
        self.runIndex = Dictionary(
            uniqueKeysWithValues: runs.enumerated().map { ($1.operationID, $0) }
        )
        self.declaredOrigins = Set(runs.map {
            SyncTextSequenceGap(
                left: $0.origin.leftElementID,
                right: $0.origin.rightElementID
            )
        })
    }

    var declaredOriginCount: Int { declaredOrigins.count }

    func run(owning elementID: SyncTextElementID) -> SyncTextSequenceRun? {
        guard let index = runIndex[elementID.operationID] else { return nil }
        return runs[index]
    }

    func contains(_ gap: SyncTextSequenceGap) -> Bool {
        if gap.left == nil, gap.right == nil {
            return true
        }
        if declaredOrigins.contains(gap) {
            return true
        }

        switch (gap.left, gap.right) {
        case (nil, let right?):
            guard let owner = run(owning: right) else { return false }
            return right.elementOffset == 0 && owner.origin.leftElementID == nil

        case (let left?, nil):
            guard let owner = run(owning: left) else { return false }
            return left.elementOffset == owner.text.utf16.count - 1
                && owner.origin.rightElementID == nil

        case (let left?, let right?):
            if left.operationID == right.operationID {
                let (nextOffset, overflow) = left.elementOffset.addingReportingOverflow(1)
                if !overflow, nextOffset == right.elementOffset {
                    return true
                }
            }

            if let rightOwner = run(owning: right),
               right.elementOffset == 0,
               rightOwner.origin.leftElementID == left {
                return true
            }

            if let leftOwner = run(owning: left),
               left.elementOffset == leftOwner.text.utf16.count - 1,
               leftOwner.origin.rightElementID == right {
                return true
            }
            return false

        case (nil, nil):
            return true
        }
    }
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
    static func projectStructuralSpans(
        runs: [SyncTextSequenceRun]
    ) throws -> [SyncTextSequenceStructuralSpan] {
        let runIndex = try validatedRunIndex(runs)
        try validateCanonicalRunOrder(runs)
        let scalarSpans = runs.map {
            SyncTextSequenceStringBoundary.scalarSpans(in: $0.text)
        }
        let legalBoundaries = scalarSpans.map(
            SyncTextSequenceStringBoundary.legalBoundaryOffsets
        )
        try validateOrigins(
            runs,
            runIndex: runIndex,
            legalBoundaries: legalBoundaries
        )
        try validateAcyclicOrigins(runs, runIndex: runIndex)

        var metrics = SyncTextSequenceTraversalMetrics()
        return try deriveStructuralSpans(
            runs: runs,
            scalarSpans: scalarSpans,
            gapIndex: makeGapIndex(runs),
            metrics: &metrics
        )
    }

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

        let gapIndex = makeGapIndex(runs)
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
    ) -> [SyncTextSequenceGap: [Int]] {
        var result: [SyncTextSequenceGap: [Int]] = [:]
        for (index, run) in runs.enumerated() {
            let gap = SyncTextSequenceGap(
                left: run.origin.leftElementID,
                right: run.origin.rightElementID
            )
            result[gap, default: []].append(index)
        }
        return result.mapValues {
            SyncOperationIDSameAnchorSiblingOrder.orderedRunIndices($0, runs: runs)
        }
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
                // Reverse-push ordered roots so LIFO traversal expands each subtree contiguously.
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
