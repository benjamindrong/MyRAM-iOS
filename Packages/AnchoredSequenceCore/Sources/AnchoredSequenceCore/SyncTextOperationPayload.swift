import Foundation

/// Versions the portable structural payload independently from any app envelope.
public enum SyncTextOperationPayloadFormatVersion:
    UInt32,
    Equatable,
    Hashable,
    Sendable
{
    case v1 = 1
}

/// Reports semantic failures after primitive payload fields have decoded.
public enum SyncTextOperationPayloadError:
    Error,
    Equatable,
    Sendable
{
    case unsupportedPayloadVersion(rawValue: UInt32)
    case unsupportedAnchorKind(rawValue: String)
    case invalidAnchorShape(
        kind: SyncOperationAnchor.Kind,
        hasLeftElementID: Bool,
        hasRightElementID: Bool
    )
    case emptyDeletedElementIDSpans
    case duplicateDeletedElementIDSpan(SyncTextElementIDSpan)
    case overlappingDeletedElementIDSpans(
        previous: SyncTextElementIDSpan,
        current: SyncTextElementIDSpan
    )
    case noncanonicalDeletedElementIDSpanOrder(
        previous: SyncTextElementIDSpan,
        current: SyncTextElementIDSpan
    )
}

/// Identifies one validated gap in a text sequence's structural element stream.
public struct SyncOperationAnchor:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public enum Kind: String, Equatable, Hashable, Sendable {
        case empty
        case before
        case between
        case after
    }

    public let kind: Kind
    public let leftElementID: SyncTextElementID?
    public let rightElementID: SyncTextElementID?

    public static let empty = SyncOperationAnchor(
        kind: .empty,
        leftElementID: nil,
        rightElementID: nil
    )

    public static func before(
        _ rightElementID: SyncTextElementID
    ) -> SyncOperationAnchor {
        SyncOperationAnchor(
            kind: .before,
            leftElementID: nil,
            rightElementID: rightElementID
        )
    }

    public static func between(
        left leftElementID: SyncTextElementID,
        right rightElementID: SyncTextElementID
    ) throws -> SyncOperationAnchor {
        guard leftElementID != rightElementID else {
            throw SyncTextSequenceStateError.identicalOriginEndpoints(leftElementID)
        }
        return SyncOperationAnchor(
            kind: .between,
            leftElementID: leftElementID,
            rightElementID: rightElementID
        )
    }

    public static func after(
        _ leftElementID: SyncTextElementID
    ) -> SyncOperationAnchor {
        SyncOperationAnchor(
            kind: .after,
            leftElementID: leftElementID,
            rightElementID: nil
        )
    }

    private init(
        kind: Kind,
        leftElementID: SyncTextElementID?,
        rightElementID: SyncTextElementID?
    ) {
        self.kind = kind
        self.leftElementID = leftElementID
        self.rightElementID = rightElementID
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind
        case leftElementID
        case rightElementID
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind.rawValue, forKey: .kind)
        if let leftElementID {
            try container.encode(leftElementID, forKey: .leftElementID)
        }
        if let rightElementID {
            try container.encode(rightElementID, forKey: .rightElementID)
        }
    }

    public init(from decoder: Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try auditedContainer(
            from: decoder,
            allowedKeys: CodingKeys.allCases
        )
        let rawKind = try container.decode(String.self, forKey: .kind)
        guard let kind = Kind(rawValue: rawKind) else {
            throw SyncTextOperationPayloadError.unsupportedAnchorKind(rawValue: rawKind)
        }

        let hasLeftElementID = container.contains(.leftElementID)
        let hasRightElementID = container.contains(.rightElementID)
        for (key, isPresent) in [
            (CodingKeys.leftElementID, hasLeftElementID),
            (CodingKeys.rightElementID, hasRightElementID)
        ] {
            guard isPresent, try container.decodeNil(forKey: key) else { continue }
            throw DecodingError.valueNotFound(
                SyncTextElementID.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath + [key],
                    debugDescription: "Anchor endpoints cannot be null."
                )
            )
        }

        let leftElementID = hasLeftElementID
            ? try container.decode(SyncTextElementID.self, forKey: .leftElementID)
            : nil
        let rightElementID = hasRightElementID
            ? try container.decode(SyncTextElementID.self, forKey: .rightElementID)
            : nil

        switch (kind, leftElementID, rightElementID) {
        case (.empty, nil, nil):
            self = .empty
        case (.before, nil, let rightElementID?):
            self = .before(rightElementID)
        case (.between, let leftElementID?, let rightElementID?):
            self = try .between(left: leftElementID, right: rightElementID)
        case (.after, let leftElementID?, nil):
            self = .after(leftElementID)
        default:
            throw SyncTextOperationPayloadError.invalidAnchorShape(
                kind: kind,
                hasLeftElementID: hasLeftElementID,
                hasRightElementID: hasRightElementID
            )
        }
    }
}

/// Carries the structural identity required to position one future insertion.
public struct SyncTextInsertOperationPayload:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let formatVersion: SyncTextOperationPayloadFormatVersion
    public let operationID: SyncOperationID
    public let anchor: SyncOperationAnchor

    public init(
        operationID: SyncOperationID,
        anchor: SyncOperationAnchor,
        formatVersion: SyncTextOperationPayloadFormatVersion = .v1
    ) {
        self.formatVersion = formatVersion
        self.operationID = operationID
        self.anchor = anchor
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case formatVersion
        case operationID
        case anchor
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(formatVersion.rawValue, forKey: .formatVersion)
        try container.encode(operationID, forKey: .operationID)
        try container.encode(anchor, forKey: .anchor)
    }

    public init(from decoder: Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try auditedContainer(
            from: decoder,
            allowedKeys: CodingKeys.allCases
        )
        let formatVersion = try decodePayloadFormatVersion(
            from: container,
            forKey: .formatVersion
        )
        let operationID = try container.decode(SyncOperationID.self, forKey: .operationID)
        let anchor = try container.decode(SyncOperationAnchor.self, forKey: .anchor)
        self.init(
            operationID: operationID,
            anchor: anchor,
            formatVersion: formatVersion
        )
    }
}

/// Carries the operation and compact element identities for one future deletion.
public struct SyncTextDeleteOperationPayload:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    public let formatVersion: SyncTextOperationPayloadFormatVersion
    public let operationID: SyncOperationID
    public let deletedElementIDSpans: [SyncTextElementIDSpan]

    public init(
        operationID: SyncOperationID,
        deletedElementIDSpans: [SyncTextElementIDSpan],
        formatVersion: SyncTextOperationPayloadFormatVersion = .v1
    ) throws {
        try Self.validate(deletedElementIDSpans)
        self.formatVersion = formatVersion
        self.operationID = operationID
        self.deletedElementIDSpans = deletedElementIDSpans
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case formatVersion
        case operationID
        case deletedElementIDSpans
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(formatVersion.rawValue, forKey: .formatVersion)
        try container.encode(operationID, forKey: .operationID)
        try container.encode(deletedElementIDSpans, forKey: .deletedElementIDSpans)
    }

    public init(from decoder: Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try auditedContainer(
            from: decoder,
            allowedKeys: CodingKeys.allCases
        )
        let formatVersion = try decodePayloadFormatVersion(
            from: container,
            forKey: .formatVersion
        )
        let operationID = try container.decode(SyncOperationID.self, forKey: .operationID)
        let deletedElementIDSpans = try container.decode(
            [SyncTextElementIDSpan].self,
            forKey: .deletedElementIDSpans
        )
        try self.init(
            operationID: operationID,
            deletedElementIDSpans: deletedElementIDSpans,
            formatVersion: formatVersion
        )
    }

    private static func validate(
        _ spans: [SyncTextElementIDSpan]
    ) throws {
        guard !spans.isEmpty else {
            throw SyncTextOperationPayloadError.emptyDeletedElementIDSpans
        }

        var uniqueSpans = Set<SyncTextElementIDSpan>()
        for span in spans where !uniqueSpans.insert(span).inserted {
            throw SyncTextOperationPayloadError.duplicateDeletedElementIDSpan(span)
        }

        var previousByOperation: [SyncOperationID: SyncTextElementIDSpan] = [:]
        for span in spans {
            if let previous = previousByOperation[span.operationID] {
                guard span.startOffset >= previous.startOffset else {
                    throw SyncTextOperationPayloadError
                        .noncanonicalDeletedElementIDSpanOrder(
                            previous: previous,
                            current: span
                        )
                }
                let previousEnd = previous.startOffset + previous.utf16Length
                guard span.startOffset >= previousEnd else {
                    throw SyncTextOperationPayloadError.overlappingDeletedElementIDSpans(
                        previous: previous,
                        current: span
                    )
                }
            }
            previousByOperation[span.operationID] = span
        }
    }
}

/// Keeps decoded wire spans on the same validated construction path as local spans.
extension SyncTextElementIDSpan: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case operationID
        case startOffset
        case utf16Length
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(operationID, forKey: .operationID)
        try container.encode(startOffset, forKey: .startOffset)
        try container.encode(utf16Length, forKey: .utf16Length)
    }

    public init(from decoder: Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try auditedContainer(
            from: decoder,
            allowedKeys: CodingKeys.allCases
        )
        let operationID = try container.decode(SyncOperationID.self, forKey: .operationID)
        let startOffset = try container.decode(Int.self, forKey: .startOffset)
        let utf16Length = try container.decode(Int.self, forKey: .utf16Length)
        try self.init(
            operationID: operationID,
            startOffset: startOffset,
            utf16Length: utf16Length
        )
    }
}

private struct SyncTextOperationPayloadDynamicCodingKey: CodingKey {
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

private func auditedContainer<Key, AllowedKey>(
    from decoder: Decoder,
    allowedKeys: [AllowedKey]
) throws -> KeyedDecodingContainer<Key>
where Key: CodingKey, AllowedKey: CodingKey {
    let auditContainer = try decoder.container(
        keyedBy: SyncTextOperationPayloadDynamicCodingKey.self
    )
    let allowedKeyNames = Set(allowedKeys.map(\.stringValue))
    if let unexpectedKey = auditContainer.allKeys
        .filter({ !allowedKeyNames.contains($0.stringValue) })
        .sorted(by: { $0.stringValue < $1.stringValue })
        .first {
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: decoder.codingPath + [unexpectedKey],
                debugDescription: "Unexpected key in V1 anchored payload."
            )
        )
    }
    return try decoder.container(keyedBy: Key.self)
}

private func decodePayloadFormatVersion<Key: CodingKey>(
    from container: KeyedDecodingContainer<Key>,
    forKey key: Key
) throws -> SyncTextOperationPayloadFormatVersion {
    let rawValue = try container.decode(UInt32.self, forKey: key)
    guard let version = SyncTextOperationPayloadFormatVersion(rawValue: rawValue) else {
        throw SyncTextOperationPayloadError.unsupportedPayloadVersion(rawValue: rawValue)
    }
    return version
}
