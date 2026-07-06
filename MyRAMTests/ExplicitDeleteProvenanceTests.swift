import SwiftData
import XCTest
@testable import MyRAM

final class ExplicitDeleteProvenanceTests: XCTestCase {
    func testValidASCIIDeleteBuildsAndValidatesDeterministically() throws {
        let fixture = try makeDeleteFixture(base: "alpha beta gamma", deletedText: "beta", offset: 6)

        let record = try buildRecord(fixture)
        XCTAssertEqual(record.noteID, fixture.noteID)
        XCTAssertEqual(record.deletedText, "beta")
        XCTAssertEqual(record.deletedTextDigest, SyncBatchContentHash.sha256Hex(for: "beta"))
        XCTAssertEqual(record.baseContentHash, SyncBatchContentHash.sha256Hex(for: fixture.base))
        XCTAssertEqual(record.resultContentHash, SyncBatchContentHash.sha256Hex(for: fixture.result))

        let first = ExplicitDeleteProvenanceValidator().validate(
            record: record,
            graph: fixture.graph,
            node: fixture.node,
            candidateBaseBody: fixture.base
        )
        let second = ExplicitDeleteProvenanceValidator().validate(record: record, candidateBaseBody: fixture.base)
        XCTAssertEqual(first, second)
        XCTAssertEqual(try validOccurrence(first).utf16Range, 6..<10)
    }

    func testEmojiDeleteUsesUTF16RangesAndRejectsSurrogateSplit() throws {
        let fixture = try makeDeleteFixture(base: "A😀B", deletedText: "😀", offset: 1)
        let record = try buildRecord(fixture)
        XCTAssertEqual(record.deletedUTF16Length, 2)
        XCTAssertEqual(
            try validOccurrence(ExplicitDeleteProvenanceValidator().validate(record: record, candidateBaseBody: fixture.base)).utf16Range,
            1..<3
        )

        let split = try makeDeleteFixture(
            base: "A😀B",
            deletedText: "B",
            offset: 2,
            utf16Length: 1,
            result: "A😀B"
        )
        XCTAssertEqual(buildResult(split), .recoveryRequired(.invalidUTF16Range))
    }

    func testRepeatedTextUsesContextAndOrdinalInsteadOfOriginalOffset() throws {
        let base = "red blue red green red"
        let fixture = try makeDeleteFixture(base: base, deletedText: "red", offset: 9)
        var record = try buildRecord(fixture)
        record = ExplicitDeleteProvenanceRecord(
            formatVersion: record.formatVersion,
            tier: record.tier,
            noteID: record.noteID,
            batchID: record.batchID,
            operationIndex: record.operationIndex,
            originDeviceID: record.originDeviceID,
            canonicalReplayKey: record.canonicalReplayKey,
            baseContentHash: record.baseContentHash,
            resultContentHash: record.resultContentHash,
            deletedText: record.deletedText,
            deletedTextDigest: record.deletedTextDigest,
            deletedUTF16Length: record.deletedUTF16Length,
            leftContext: record.leftContext,
            leftContextDigest: record.leftContextDigest,
            leftContextUTF16Length: record.leftContextUTF16Length,
            rightContext: record.rightContext,
            rightContextDigest: record.rightContextDigest,
            rightContextUTF16Length: record.rightContextUTF16Length,
            originalUTF16Offset: 0,
            occurrenceOrdinal: record.occurrenceOrdinal,
            createdAt: record.createdAt,
            createdAtBitPattern: record.createdAtBitPattern,
            payloadByteCount: record.payloadByteCount,
            baseSnapshotGeneration: record.baseSnapshotGeneration
        )

        let occurrence = try validOccurrence(ExplicitDeleteProvenanceValidator().validate(
            record: record,
            candidateBaseBody: base
        ))
        XCTAssertEqual(occurrence.utf16Range, 9..<12)
    }

    func testAmbiguousOrMissingOccurrenceFailsClosed() throws {
        let fixture = try makeDeleteFixture(base: "aaaa", deletedText: "aa", offset: 0)
        let record = try buildRecord(fixture)
        XCTAssertEqual(
            ExplicitDeleteProvenanceValidator().validate(record: record, candidateBaseBody: "bbbb"),
            .recoveryRequired(.baseHashMismatch)
        )

        var missingOrdinal = record
        missingOrdinal = ExplicitDeleteProvenanceRecord(
            formatVersion: record.formatVersion,
            tier: record.tier,
            noteID: record.noteID,
            batchID: record.batchID,
            operationIndex: record.operationIndex,
            originDeviceID: record.originDeviceID,
            canonicalReplayKey: record.canonicalReplayKey,
            baseContentHash: record.baseContentHash,
            resultContentHash: record.resultContentHash,
            deletedText: record.deletedText,
            deletedTextDigest: record.deletedTextDigest,
            deletedUTF16Length: record.deletedUTF16Length,
            leftContext: record.leftContext,
            leftContextDigest: record.leftContextDigest,
            leftContextUTF16Length: record.leftContextUTF16Length,
            rightContext: record.rightContext,
            rightContextDigest: record.rightContextDigest,
            rightContextUTF16Length: record.rightContextUTF16Length,
            originalUTF16Offset: record.originalUTF16Offset,
            occurrenceOrdinal: 99,
            createdAt: record.createdAt,
            createdAtBitPattern: record.createdAtBitPattern,
            payloadByteCount: record.payloadByteCount,
            baseSnapshotGeneration: record.baseSnapshotGeneration
        )
        XCTAssertEqual(
            ExplicitDeleteProvenanceValidator().validate(record: missingOrdinal, candidateBaseBody: fixture.base),
            .recoveryRequired(.occurrenceNotFound)
        )
    }

    func testRejectsNonDeleteAndMissingGraphNode() throws {
        let fixture = try makeDeleteFixture(base: "abc", deletedText: "b", offset: 1)
        var insertOperation = fixture.node.operation
        insertOperation = SyncConvergenceRetainedOperationRecord(
            noteID: insertOperation.noteID,
            batchID: insertOperation.batchID,
            originDeviceID: insertOperation.originDeviceID,
            operationIndex: insertOperation.operationIndex,
            operationKind: .insert,
            utf16Offset: insertOperation.utf16Offset,
            utf16Length: nil,
            text: "b",
            expectedText: nil,
            baseContentHash: insertOperation.baseContentHash,
            resultContentHash: insertOperation.resultContentHash,
            canonicalReplayKey: insertOperation.canonicalReplayKey,
            modifiedAt: insertOperation.modifiedAt
        )
        let insertNode = ValidatedRetainedOperationNode(
            operation: insertOperation,
            identity: fixture.node.identity,
            replayKey: fixture.node.replayKey,
            baseContentHash: fixture.node.baseContentHash,
            resultContentHash: fixture.node.resultContentHash,
            predecessorIdentity: nil,
            successorIdentity: nil
        )
        XCTAssertEqual(
            ExplicitDeleteProvenanceBuilder().build(graph: fixture.graph, node: insertNode, preDeleteBody: fixture.base),
            .recoveryRequired(.nodeAbsentFromGraph)
        )
    }

    func testPersistenceRoundTripRelaunchIdempotenceAndContradiction() throws {
        let fixture = try makeDeleteFixture(base: "alpha beta", deletedText: "beta", offset: 6)
        let record = try buildRecord(fixture)
        let container = try makeContainer()
        let context = ModelContext(container)
        let transaction = SwiftDataSyncConvergencePersistenceTransaction(context: context)

        try transaction.insertExplicitDeleteProvenance(record)
        try transaction.insertExplicitDeleteProvenance(record)
        try transaction.save()
        XCTAssertEqual(try context.fetch(FetchDescriptor<ExplicitDeleteProvenance>()).count, 1)

        let reloaded = SwiftDataSyncConvergencePersistenceTransaction(context: ModelContext(container))
        let projection = try XCTUnwrap(reloaded.loadExplicitDeleteProvenance(identity: record.identity))
        XCTAssertEqual(projection.record, record)
        XCTAssertEqual(
            ExplicitDeleteProvenanceValidator().validate(record: projection.record, candidateBaseBody: fixture.base),
            .valid(try validOccurrence(ExplicitDeleteProvenanceValidator().validate(record: record, candidateBaseBody: fixture.base)))
        )

        let contradictory = ExplicitDeleteProvenanceRecord(
            formatVersion: record.formatVersion,
            tier: record.tier,
            noteID: record.noteID,
            batchID: record.batchID,
            operationIndex: record.operationIndex,
            originDeviceID: record.originDeviceID,
            canonicalReplayKey: record.canonicalReplayKey,
            baseContentHash: record.baseContentHash,
            resultContentHash: record.resultContentHash,
            deletedText: "other",
            deletedTextDigest: SyncBatchContentHash.sha256Hex(for: "other"),
            deletedUTF16Length: 5,
            leftContext: record.leftContext,
            leftContextDigest: record.leftContextDigest,
            leftContextUTF16Length: record.leftContextUTF16Length,
            rightContext: record.rightContext,
            rightContextDigest: record.rightContextDigest,
            rightContextUTF16Length: record.rightContextUTF16Length,
            originalUTF16Offset: record.originalUTF16Offset,
            occurrenceOrdinal: record.occurrenceOrdinal,
            createdAt: record.createdAt,
            createdAtBitPattern: record.createdAtBitPattern,
            payloadByteCount: record.payloadByteCount,
            baseSnapshotGeneration: record.baseSnapshotGeneration
        )
        XCTAssertThrowsError(try transaction.insertExplicitDeleteProvenance(contradictory))
    }

    func testCorruptReplayKeyAndUnknownFormatFailClosed() throws {
        let fixture = try makeDeleteFixture(base: "alpha beta", deletedText: "beta", offset: 6)
        let record = try buildRecord(fixture)
        let corruptReplay = ExplicitDeleteProvenanceRecord(
            formatVersion: record.formatVersion,
            tier: record.tier,
            noteID: record.noteID,
            batchID: record.batchID,
            operationIndex: record.operationIndex,
            originDeviceID: UUID(),
            canonicalReplayKey: record.canonicalReplayKey,
            baseContentHash: record.baseContentHash,
            resultContentHash: record.resultContentHash,
            deletedText: record.deletedText,
            deletedTextDigest: record.deletedTextDigest,
            deletedUTF16Length: record.deletedUTF16Length,
            leftContext: record.leftContext,
            leftContextDigest: record.leftContextDigest,
            leftContextUTF16Length: record.leftContextUTF16Length,
            rightContext: record.rightContext,
            rightContextDigest: record.rightContextDigest,
            rightContextUTF16Length: record.rightContextUTF16Length,
            originalUTF16Offset: record.originalUTF16Offset,
            occurrenceOrdinal: record.occurrenceOrdinal,
            createdAt: record.createdAt,
            createdAtBitPattern: record.createdAtBitPattern,
            payloadByteCount: record.payloadByteCount,
            baseSnapshotGeneration: record.baseSnapshotGeneration
        )
        XCTAssertEqual(
            ExplicitDeleteProvenanceValidator().validate(record: corruptReplay, candidateBaseBody: fixture.base),
            .recoveryRequired(.invalidOperationIdentity)
        )
        XCTAssertEqual(
            ExplicitDeleteProvenanceValidator().validate(
                record: record.withFormatVersion(99),
                candidateBaseBody: fixture.base
            ),
            .recoveryRequired(.unsupportedFormatVersion(99))
        )
    }

    func testCompactionRequiresExactSnapshotAndReloads() throws {
        let fixture = try makeDeleteFixture(base: "alpha beta gamma", deletedText: "beta", offset: 6)
        let record = try buildRecord(fixture)
        let snapshot = SyncConvergenceSnapshotRecord(
            noteID: record.noteID,
            contentHash: record.baseContentHash,
            body: fixture.base,
            generation: 3,
            createdAt: Date(timeIntervalSince1970: 30)
        )

        XCTAssertEqual(
            ExplicitDeleteProvenanceCompactor().compact(record: record, baseSnapshot: nil),
            .retainedFull(.missingSnapshot)
        )

        let compacted = try compactedRecord(ExplicitDeleteProvenanceCompactor().compact(
            record: record,
            baseSnapshot: snapshot
        ))
        XCTAssertEqual(compacted.tier, .compacted)
        XCTAssertNil(compacted.deletedText)
        XCTAssertEqual(compacted.baseSnapshotGeneration, 3)
        let fullOccurrence = try validOccurrence(ExplicitDeleteProvenanceValidator().validate(
            record: record,
            candidateBaseBody: fixture.base
        ))
        let compactedOccurrence = try validOccurrence(ExplicitDeleteProvenanceValidator().validate(
            record: compacted,
            candidateBaseBody: fixture.base
        ))
        XCTAssertEqual(compactedOccurrence.utf16Range, fullOccurrence.utf16Range)
        XCTAssertEqual(compactedOccurrence.resolvedDeletedText, fullOccurrence.resolvedDeletedText)
        XCTAssertEqual(compactedOccurrence.resolvedLeftContext, fullOccurrence.resolvedLeftContext)
        XCTAssertEqual(compactedOccurrence.resolvedRightContext, fullOccurrence.resolvedRightContext)
    }

    private func buildResult(_ fixture: DeleteFixture) -> ExplicitDeleteProvenanceBuildResult {
        ExplicitDeleteProvenanceBuilder().build(
            graph: fixture.graph,
            node: fixture.node,
            preDeleteBody: fixture.base,
            createdAt: Date(timeIntervalSince1970: 20)
        )
    }

    private func buildRecord(_ fixture: DeleteFixture) throws -> ExplicitDeleteProvenanceRecord {
        guard case .record(let record) = buildResult(fixture) else {
            return XCTFailAndThrow("expected provenance record")
        }
        return record
    }

    private func validOccurrence(
        _ result: ExplicitDeleteProvenanceValidationResult
    ) throws -> ValidatedExplicitDeleteOccurrence {
        guard case .valid(let occurrence) = result else {
            return XCTFailAndThrow("expected valid occurrence")
        }
        return occurrence
    }

    private func compactedRecord(
        _ result: ExplicitDeleteProvenanceCompactionResult
    ) throws -> ExplicitDeleteProvenanceRecord {
        guard case .compacted(let record) = result else {
            return XCTFailAndThrow("expected compacted record")
        }
        return record
    }

    private func makeDeleteFixture(
        base: String,
        deletedText: String,
        offset: Int,
        utf16Length: Int? = nil,
        result explicitResult: String? = nil
    ) throws -> DeleteFixture {
        let noteID = UUID()
        let batchID = UUID()
        let originDeviceID = UUID()
        let modifiedAt = Date(timeIntervalSince1970: 10)
        let result = explicitResult ?? deleting(base, offset: offset, length: utf16Length ?? deletedText.utf16.count)
        let replayKey = CanonicalReplayKeyPayload(
            modifiedAtBitPattern: SyncConvergenceDateBits.bitPattern(for: modifiedAt),
            originDeviceIDLowercase: originDeviceID.uuidString.lowercased(),
            batchOrderKind: .sequenced,
            legacyCreatedAtBitPattern: nil,
            sequence: 1,
            batchIDLowercase: batchID.uuidString.lowercased(),
            operationIndex: 0
        )
        let operation = SyncConvergenceRetainedOperationRecord(
            noteID: noteID,
            batchID: batchID,
            originDeviceID: originDeviceID,
            operationIndex: 0,
            operationKind: .delete,
            utf16Offset: offset,
            utf16Length: utf16Length ?? deletedText.utf16.count,
            text: nil,
            expectedText: deletedText,
            baseContentHash: SyncBatchContentHash.sha256Hex(for: base),
            resultContentHash: SyncBatchContentHash.sha256Hex(for: result),
            canonicalReplayKey: replayKey,
            modifiedAt: modifiedAt
        )
        let validation = RetainedOperationCausalGraphValidator().validate(
            IncrementalEditCausalValidationInput(
                anchorContent: base,
                anchorContentHash: SyncBatchContentHash.sha256Hex(for: base),
                operations: [operation],
                incorporatedOperationIdentities: []
            )
        )
        guard case .valid(let graph) = validation,
              let node = graph.nodes.first
        else {
            return XCTFailAndThrow("expected valid graph")
        }
        return DeleteFixture(noteID: noteID, base: base, result: result, graph: graph, node: node)
    }

    private func deleting(_ body: String, offset: Int, length: Int) -> String {
        guard let range = body.stringRange(utf16Offset: offset, utf16Length: length) else {
            return body
        }
        var copy = body
        copy.removeSubrange(range)
        return copy
    }

    private func makeContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: Schema(MyRAMModelRegistry.models), configurations: configuration)
    }
}

private struct DeleteFixture {
    let noteID: UUID
    let base: String
    let result: String
    let graph: RetainedOperationCausalGraph
    let node: ValidatedRetainedOperationNode
}

private extension ExplicitDeleteProvenanceRecord {
    func withFormatVersion(_ version: Int) -> Self {
        ExplicitDeleteProvenanceRecord(
            formatVersion: version,
            tier: tier,
            noteID: noteID,
            batchID: batchID,
            operationIndex: operationIndex,
            originDeviceID: originDeviceID,
            canonicalReplayKey: canonicalReplayKey,
            baseContentHash: baseContentHash,
            resultContentHash: resultContentHash,
            deletedText: deletedText,
            deletedTextDigest: deletedTextDigest,
            deletedUTF16Length: deletedUTF16Length,
            leftContext: leftContext,
            leftContextDigest: leftContextDigest,
            leftContextUTF16Length: leftContextUTF16Length,
            rightContext: rightContext,
            rightContextDigest: rightContextDigest,
            rightContextUTF16Length: rightContextUTF16Length,
            originalUTF16Offset: originalUTF16Offset,
            occurrenceOrdinal: occurrenceOrdinal,
            createdAt: createdAt,
            createdAtBitPattern: createdAtBitPattern,
            payloadByteCount: payloadByteCount,
            baseSnapshotGeneration: baseSnapshotGeneration
        )
    }
}

private func XCTFailAndThrow<T>(_ message: String, file: StaticString = #filePath, line: UInt = #line) -> T {
    XCTFail(message, file: file, line: line)
    fatalError(message)
}
