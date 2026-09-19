import Foundation

public enum SyncTextMarkPayloadFormatVersion:
    UInt32,
    Equatable,
    Hashable,
    Sendable
{
    case v1 = 1
}

public enum SyncTextMarkKey:
    String,
    Codable,
    CaseIterable,
    Equatable,
    Hashable,
    Sendable
{
    case bold
    case italic
    case underline
    case strikethrough
    case fontSize
    case textColor

    fileprivate var canonicalOrder: Int {
        switch self {
        case .bold: 0
        case .italic: 1
        case .underline: 2
        case .strikethrough: 3
        case .fontSize: 4
        case .textColor: 5
        }
    }

    fileprivate var isBoolean: Bool {
        switch self {
        case .bold, .italic, .underline, .strikethrough:
            true
        case .fontSize, .textColor:
            false
        }
    }
}

public struct SyncTextMarkRGBAColor:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8
    public let alpha: UInt8

    public init(
        red: UInt8,
        green: UInt8,
        blue: UInt8,
        alpha: UInt8
    ) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    fileprivate var canonicalBytes: [UInt8] {
        [red, green, blue, alpha]
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case red
        case green
        case blue
        case alpha
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(red, forKey: .red)
        try container.encode(green, forKey: .green)
        try container.encode(blue, forKey: .blue)
        try container.encode(alpha, forKey: .alpha)
    }

    public init(from decoder: Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try markAuditedContainer(
            from: decoder,
            allowedKeys: CodingKeys.allCases
        )
        self.init(
            red: try container.decode(UInt8.self, forKey: .red),
            green: try container.decode(UInt8.self, forKey: .green),
            blue: try container.decode(UInt8.self, forKey: .blue),
            alpha: try container.decode(UInt8.self, forKey: .alpha)
        )
    }
}

public enum SyncTextMarkAssignment:
    Equatable,
    Hashable,
    Sendable
{
    case clear
    case enabled
    case fontSizeMilliPoints(Int)
    case textColor(SyncTextMarkRGBAColor)

    fileprivate var canonicalRank: Int {
        switch self {
        case .clear: 0
        case .enabled: 1
        case .fontSizeMilliPoints(_): 2
        case .textColor(_): 3
        }
    }

    fileprivate static func isOrderedBefore(
        _ lhs: SyncTextMarkAssignment,
        _ rhs: SyncTextMarkAssignment
    ) -> Bool {
        if lhs.canonicalRank != rhs.canonicalRank {
            return lhs.canonicalRank < rhs.canonicalRank
        }

        switch (lhs, rhs) {
        case (.fontSizeMilliPoints(let lhsValue), .fontSizeMilliPoints(let rhsValue)):
            return lhsValue < rhsValue
        case (.textColor(let lhsColor), .textColor(let rhsColor)):
            return lhsColor.canonicalBytes.lexicographicallyPrecedes(
                rhsColor.canonicalBytes
            )
        default:
            return false
        }
    }
}

extension SyncTextMarkAssignment: Codable {
    private enum Kind: String {
        case clear
        case enabled
        case fontSizeMilliPoints
        case textColor
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind
        case fontSizeMilliPoints
        case textColor
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .clear:
            try container.encode(Kind.clear.rawValue, forKey: .kind)
        case .enabled:
            try container.encode(Kind.enabled.rawValue, forKey: .kind)
        case .fontSizeMilliPoints(let value):
            try container.encode(Kind.fontSizeMilliPoints.rawValue, forKey: .kind)
            try container.encode(value, forKey: .fontSizeMilliPoints)
        case .textColor(let color):
            try container.encode(Kind.textColor.rawValue, forKey: .kind)
            try container.encode(color, forKey: .textColor)
        }
    }

    public init(from decoder: Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try markAuditedContainer(
            from: decoder,
            allowedKeys: CodingKeys.allCases
        )
        let rawKind = try container.decode(String.self, forKey: .kind)
        guard let kind = Kind(rawValue: rawKind) else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unsupported structural mark assignment kind."
            )
        }

        let hasFontSize = container.contains(.fontSizeMilliPoints)
        let hasTextColor = container.contains(.textColor)
        for key in [CodingKeys.fontSizeMilliPoints, .textColor]
        where container.contains(key) && (try container.decodeNil(forKey: key)) {
            throw DecodingError.valueNotFound(
                String.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath + [key],
                    debugDescription: "Structural mark assignment values cannot be null."
                )
            )
        }

        switch kind {
        case .clear:
            guard !hasFontSize, !hasTextColor else {
                throw Self.invalidShape(decoder)
            }
            self = .clear
        case .enabled:
            guard !hasFontSize, !hasTextColor else {
                throw Self.invalidShape(decoder)
            }
            self = .enabled
        case .fontSizeMilliPoints:
            guard hasFontSize, !hasTextColor else {
                throw Self.invalidShape(decoder)
            }
            self = .fontSizeMilliPoints(
                try container.decode(Int.self, forKey: .fontSizeMilliPoints)
            )
        case .textColor:
            guard !hasFontSize, hasTextColor else {
                throw Self.invalidShape(decoder)
            }
            self = .textColor(
                try container.decode(SyncTextMarkRGBAColor.self, forKey: .textColor)
            )
        }
    }

    private static func invalidShape(_ decoder: Decoder) -> DecodingError {
        .dataCorrupted(DecodingError.Context(
            codingPath: decoder.codingPath,
            debugDescription: "Invalid structural mark assignment shape."
        ))
    }
}

public enum SyncTextMarkRangeFailure:
    Error,
    Equatable,
    Sendable
{
    case invalidAnchor(SyncOperationAnchor)
    case nonforward(start: SyncOperationAnchor, end: SyncOperationAnchor)
}

public enum SyncTextMarkStateError:
    Error,
    Equatable,
    Sendable
{
    case unsupportedPayloadVersion(UInt32)
    case zeroLogicalClock(SyncOperationID)
    case invalidAssignment(
        key: SyncTextMarkKey,
        assignment: SyncTextMarkAssignment
    )
    case fontSizeOutOfRange(Int)
    case conflictingDuplicateOperationIdentity(SyncOperationID)
    case logicalClockOverflow
    case invalidOperationRange(
        operationID: SyncOperationID,
        failure: SyncTextMarkRangeFailure
    )
    case invalidDraftRange(SyncTextMarkRangeFailure)
    case overlappingDraftRanges(SyncTextMarkKey)
}

private enum SyncTextMarkValueValidation {
    static func validate(
        key: SyncTextMarkKey,
        assignment: SyncTextMarkAssignment
    ) throws {
        switch (key, assignment) {
        case (_, .clear):
            return
        case (let key, .enabled) where key.isBoolean:
            return
        case (.fontSize, .fontSizeMilliPoints(let value)):
            guard (11_000...40_000).contains(value) else {
                throw SyncTextMarkStateError.fontSizeOutOfRange(value)
            }
        case (.textColor, .textColor(_)):
            return
        default:
            throw SyncTextMarkStateError.invalidAssignment(
                key: key,
                assignment: assignment
            )
        }
    }
}

public struct SyncTextMarkOperation:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let formatVersion: SyncTextMarkPayloadFormatVersion
    public let operationID: SyncOperationID
    public let logicalClock: UInt64
    public let key: SyncTextMarkKey
    public let assignment: SyncTextMarkAssignment
    public let startAnchor: SyncOperationAnchor
    public let endAnchor: SyncOperationAnchor

    public init(
        operationID: SyncOperationID,
        logicalClock: UInt64,
        key: SyncTextMarkKey,
        assignment: SyncTextMarkAssignment,
        startAnchor: SyncOperationAnchor,
        endAnchor: SyncOperationAnchor,
        formatVersion: SyncTextMarkPayloadFormatVersion = .v1
    ) throws {
        guard logicalClock > 0 else {
            throw SyncTextMarkStateError.zeroLogicalClock(operationID)
        }
        try SyncTextMarkValueValidation.validate(
            key: key,
            assignment: assignment
        )
        self.formatVersion = formatVersion
        self.operationID = operationID
        self.logicalClock = logicalClock
        self.key = key
        self.assignment = assignment
        self.startAnchor = startAnchor
        self.endAnchor = endAnchor
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case formatVersion
        case operationID
        case logicalClock
        case key
        case assignment
        case startAnchor
        case endAnchor
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(formatVersion.rawValue, forKey: .formatVersion)
        try container.encode(operationID, forKey: .operationID)
        try container.encode(logicalClock, forKey: .logicalClock)
        try container.encode(key, forKey: .key)
        try container.encode(assignment, forKey: .assignment)
        try container.encode(startAnchor, forKey: .startAnchor)
        try container.encode(endAnchor, forKey: .endAnchor)
    }

    public init(from decoder: Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try markAuditedContainer(
            from: decoder,
            allowedKeys: CodingKeys.allCases
        )
        let rawVersion = try container.decode(UInt32.self, forKey: .formatVersion)
        guard let formatVersion = SyncTextMarkPayloadFormatVersion(rawValue: rawVersion) else {
            throw SyncTextMarkStateError.unsupportedPayloadVersion(rawVersion)
        }

        try self.init(
            operationID: try container.decode(SyncOperationID.self, forKey: .operationID),
            logicalClock: try container.decode(UInt64.self, forKey: .logicalClock),
            key: try container.decode(SyncTextMarkKey.self, forKey: .key),
            assignment: try container.decode(
                SyncTextMarkAssignment.self,
                forKey: .assignment
            ),
            startAnchor: try container.decode(
                SyncOperationAnchor.self,
                forKey: .startAnchor
            ),
            endAnchor: try container.decode(
                SyncOperationAnchor.self,
                forKey: .endAnchor
            ),
            formatVersion: formatVersion
        )
    }
}

public struct SyncTextMarkOperationDraft:
    Equatable,
    Hashable,
    Sendable
{
    public let key: SyncTextMarkKey
    public let assignment: SyncTextMarkAssignment
    public let startAnchor: SyncOperationAnchor
    public let endAnchor: SyncOperationAnchor

    public init(
        key: SyncTextMarkKey,
        assignment: SyncTextMarkAssignment,
        startAnchor: SyncOperationAnchor,
        endAnchor: SyncOperationAnchor
    ) throws {
        try SyncTextMarkValueValidation.validate(
            key: key,
            assignment: assignment
        )
        self.key = key
        self.assignment = assignment
        self.startAnchor = startAnchor
        self.endAnchor = endAnchor
    }
}

public enum SyncTextMarkCanonicalEmissionOrder {
    public static func ordered(
        _ drafts: [SyncTextMarkOperationDraft],
        against sequence: SyncTextSequenceState
    ) throws -> [SyncTextMarkOperationDraft] {
        var entries: [
            (
                draft: SyncTextMarkOperationDraft,
                start: Int,
                end: Int
            )
        ] = []
        entries.reserveCapacity(drafts.count)

        for draft in drafts {
            do {
                let positions = try sequence.markRangePositions(
                    startAnchor: draft.startAnchor,
                    endAnchor: draft.endAnchor
                )
                entries.append((draft, positions.start, positions.end))
            } catch let failure as SyncTextMarkRangeFailure {
                throw SyncTextMarkStateError.invalidDraftRange(failure)
            }
        }

        entries.sort { lhs, rhs in
            if lhs.start != rhs.start {
                return lhs.start < rhs.start
            }
            if lhs.end != rhs.end {
                return lhs.end < rhs.end
            }
            if lhs.draft.key != rhs.draft.key {
                return lhs.draft.key.canonicalOrder < rhs.draft.key.canonicalOrder
            }
            return SyncTextMarkAssignment.isOrderedBefore(
                lhs.draft.assignment,
                rhs.draft.assignment
            )
        }

        var previousRangeByKey: [
            SyncTextMarkKey: (start: Int, end: Int)
        ] = [:]
        for entry in entries {
            if let previous = previousRangeByKey[entry.draft.key],
               entry.start < previous.end {
                throw SyncTextMarkStateError.overlappingDraftRanges(
                    entry.draft.key
                )
            }
            previousRangeByKey[entry.draft.key] = (
                entry.start,
                entry.end
            )
        }
        return entries.map(\.draft)
    }
}

public struct SyncTextResolvedMarkSpan:
    Equatable,
    Sendable
{
    public let startUTF16Offset: Int
    public let utf16Length: Int
    public let assignments: [SyncTextMarkKey: SyncTextMarkAssignment]

    public init(
        startUTF16Offset: Int,
        utf16Length: Int,
        assignments: [SyncTextMarkKey: SyncTextMarkAssignment]
    ) {
        self.startUTF16Offset = startUTF16Offset
        self.utf16Length = utf16Length
        self.assignments = assignments
    }
}

public struct SyncTextMarkState:
    Codable,
    Equatable,
    Sendable
{
    public let operations: [SyncTextMarkOperation]

    public static let empty: SyncTextMarkState = {
        do {
            return try SyncTextMarkState(operations: [])
        } catch {
            preconditionFailure("Empty structural mark state must be valid: \(error)")
        }
    }()

    public init(operations: [SyncTextMarkOperation]) throws {
        var operationByID: [SyncOperationID: SyncTextMarkOperation] = [:]
        operationByID.reserveCapacity(operations.count)

        for operation in operations {
            if let existing = operationByID[operation.operationID] {
                guard existing == operation else {
                    throw SyncTextMarkStateError.conflictingDuplicateOperationIdentity(
                        operation.operationID
                    )
                }
                continue
            }
            operationByID[operation.operationID] = operation
        }

        self.operations = operationByID.values.sorted(by: Self.isOrderedBefore)
    }

    public var maxLogicalClock: UInt64 {
        operations.map(\.logicalClock).max() ?? 0
    }

    public func nextLogicalClock() throws -> UInt64 {
        let (next, overflow) = maxLogicalClock.addingReportingOverflow(1)
        guard !overflow else {
            throw SyncTextMarkStateError.logicalClockOverflow
        }
        return next
    }

    public func merging(
        with other: SyncTextMarkState
    ) throws -> SyncTextMarkState {
        try SyncTextMarkState(operations: operations + other.operations)
    }

    @discardableResult
    public func validating(
        against sequence: SyncTextSequenceState
    ) throws -> SyncTextMarkState {
        for operation in operations {
            do {
                _ = try sequence.markRangePositions(
                    startAnchor: operation.startAnchor,
                    endAnchor: operation.endAnchor
                )
            } catch let failure as SyncTextMarkRangeFailure {
                throw SyncTextMarkStateError.invalidOperationRange(
                    operationID: operation.operationID,
                    failure: failure
                )
            }
        }
        return self
    }

    public func visibleProjection(
        in sequence: SyncTextSequenceState
    ) throws -> [SyncTextResolvedMarkSpan] {
        try validating(against: sequence)

        var winners: [
            SyncTextElementID: [SyncTextMarkKey: SyncTextMarkOperation]
        ] = [:]
        for operation in operations {
            let elementIDs = try sequence.markRangeElementIDs(
                startAnchor: operation.startAnchor,
                endAnchor: operation.endAnchor
            )
            for elementID in elementIDs {
                let existing = winners[elementID]?[operation.key]
                if existing == nil || Self.wins(operation, over: existing!) {
                    winners[elementID, default: [:]][operation.key] = operation
                }
            }
        }

        let visibleElementIDs = try sequence.visibleElementIDsForMarkProjection()
        guard visibleElementIDs.count == sequence.visibleUTF16Count else {
            preconditionFailure(
                "Validated sequence visible identities must match visible UTF-16 count."
            )
        }
        guard !visibleElementIDs.isEmpty else { return [] }

        var result: [SyncTextResolvedMarkSpan] = []
        result.reserveCapacity(visibleElementIDs.count)
        for (offset, elementID) in visibleElementIDs.enumerated() {
            let assignments = winners[elementID]?.mapValues { $0.assignment } ?? [:]
            if let previous = result.last,
               previous.assignments == assignments,
               previous.startUTF16Offset + previous.utf16Length == offset {
                result[result.count - 1] = SyncTextResolvedMarkSpan(
                    startUTF16Offset: previous.startUTF16Offset,
                    utf16Length: previous.utf16Length + 1,
                    assignments: previous.assignments
                )
            } else {
                result.append(SyncTextResolvedMarkSpan(
                    startUTF16Offset: offset,
                    utf16Length: 1,
                    assignments: assignments
                ))
            }
        }
        return result
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case operations
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(operations, forKey: .operations)
    }

    public init(from decoder: Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try markAuditedContainer(
            from: decoder,
            allowedKeys: CodingKeys.allCases
        )
        try self.init(
            operations: try container.decode(
                [SyncTextMarkOperation].self,
                forKey: .operations
            )
        )
    }

    private static func isOrderedBefore(
        _ lhs: SyncTextMarkOperation,
        _ rhs: SyncTextMarkOperation
    ) -> Bool {
        if lhs.logicalClock != rhs.logicalClock {
            return lhs.logicalClock < rhs.logicalClock
        }
        return SyncOperationIDCanonicalOrder.isOrderedBefore(
            lhs.operationID,
            rhs.operationID
        )
    }

    private static func wins(
        _ candidate: SyncTextMarkOperation,
        over existing: SyncTextMarkOperation
    ) -> Bool {
        if candidate.logicalClock != existing.logicalClock {
            return candidate.logicalClock > existing.logicalClock
        }
        return SyncOperationIDCanonicalOrder.isOrderedBefore(
            existing.operationID,
            candidate.operationID
        )
    }
}

private struct SyncTextMarkDynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

private func markAuditedContainer<Key, AllowedKey>(
    from decoder: Decoder,
    allowedKeys: [AllowedKey]
) throws -> KeyedDecodingContainer<Key>
where Key: CodingKey, AllowedKey: CodingKey {
    let auditContainer = try decoder.container(
        keyedBy: SyncTextMarkDynamicCodingKey.self
    )
    let allowedKeyNames = Set(allowedKeys.map(\.stringValue))
    if let unexpectedKey = auditContainer.allKeys
        .filter({ !allowedKeyNames.contains($0.stringValue) })
        .sorted(by: { $0.stringValue < $1.stringValue })
        .first {
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: decoder.codingPath + [unexpectedKey],
                debugDescription: "Unexpected key in V1 structural mark payload."
            )
        )
    }
    return try decoder.container(keyedBy: Key.self)
}
