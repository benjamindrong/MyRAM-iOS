import SwiftData
import XCTest
@testable import MyRAM

final class ExplicitDeleteProvenanceTests: XCTestCase {
    func testDeterministicReconstructionIsByteIdenticalAcrossRetryAndRelaunch() throws {
        let fixture = try makeDeleteFixture(base: "alpha beta gamma", deletedText: "beta", offset: 6)
        let first = try buildRecord(fixture)
        Thread.sleep(forTimeInterval: 0.01)
        let second = try buildRecord(fixture)
        XCTAssertEqual(first, second)
        XCTAssertEqual(try first.canonicalPayloadData(), try second.canonicalPayloadData())
        XCTAssertEqual(first.createdAt, fixture.node.operation.modifiedAt)
        XCTAssertEqual(first.createdAtBitPattern, SyncConvergenceDateBits.bitPattern(for: fixture.node.operation.modifiedAt))

        let container = try makeContainer()
        let firstTransaction = SwiftDataSyncConvergencePersistenceTransaction(context: ModelContext(container))
        try firstTransaction.insertExplicitDeleteProvenance(first)
        try firstTransaction.insertExplicitDeleteProvenance(second)
        try firstTransaction.save()

        let reloadedTransaction = SwiftDataSyncConvergencePersistenceTransaction(context: ModelContext(container))
        let reloaded = try XCTUnwrap(reloadedTransaction.loadExplicitDeleteProvenance(identity: first.identity))
        XCTAssertEqual(reloaded.record, first)
        XCTAssertEqual(reloaded.canonicalPayloadData, try first.canonicalPayloadData())
        XCTAssertEqual(try buildRecord(fixture), reloaded.record)
    }

    func testChangedOperationTimestampEvidenceChangesCanonicalProvenance() throws {
        let first = try buildRecord(try makeDeleteFixture(
            base: "alpha beta",
            deletedText: "beta",
            offset: 6,
            modifiedAt: Date(timeIntervalSince1970: 10)
        ))
        let second = try buildRecord(try makeDeleteFixture(
            base: "alpha beta",
            deletedText: "beta",
            offset: 6,
            noteID: first.noteID,
            batchID: first.batchID,
            originDeviceID: first.originDeviceID,
            modifiedAt: Date(timeIntervalSince1970: 11)
        ))

        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(try first.canonicalPayloadData(), try second.canonicalPayloadData())
        XCTAssertEqual(second.createdAt, Date(timeIntervalSince1970: 11))
        XCTAssertEqual(second.createdAtBitPattern, SyncConvergenceDateBits.bitPattern(for: second.createdAt))
    }


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

    func testOverlapSafeTextOccurrenceEnumerationUsesAscendingUTF16Starts() {
        XCTAssertEqual(
            ExplicitDeleteOccurrenceEnumerator.matchingTextOccurrences(in: "aaaa", deletedText: "aa").map(\.utf16Range.lowerBound),
            [0, 1, 2]
        )
        XCTAssertEqual(
            ExplicitDeleteOccurrenceEnumerator.matchingTextOccurrences(in: "aaa", deletedText: "aa").map(\.utf16Range.lowerBound),
            [0, 1]
        )
        let unicodeBody = "😀😀😀"
        let unicodeOccurrences = ExplicitDeleteOccurrenceEnumerator.matchingTextOccurrences(
            in: unicodeBody,
            deletedText: "😀😀"
        )
        XCTAssertEqual(unicodeOccurrences.map(\.utf16Range.lowerBound), [0, 2])
        XCTAssertTrue(unicodeOccurrences.allSatisfy {
            unicodeBody.stringRange(utf16Offset: $0.utf16Range.lowerBound, utf16Length: $0.utf16Range.count) != nil
        })
    }

    func testMiddleOverlappingDeleteBuildsFullAndCompactedValidationToSameRange() throws {
        let fixture = try makeDeleteFixture(base: "aaaa", deletedText: "aa", offset: 1)
        let record = try buildRecord(fixture)
        XCTAssertEqual(record.originalUTF16Offset, 1)
        XCTAssertEqual(record.occurrenceOrdinal, 0)

        let fullOccurrence = try validOccurrence(ExplicitDeleteProvenanceValidator().validate(
            record: record,
            graph: fixture.graph,
            node: fixture.node,
            candidateBaseBody: fixture.base
        ))
        XCTAssertEqual(fullOccurrence.utf16Range, 1..<3)
        var result = fixture.base
        result.removeSubrange(try XCTUnwrap(fixture.base.stringRange(utf16Offset: 1, utf16Length: 2)))
        XCTAssertEqual(SyncBatchContentHash.sha256Hex(for: result), record.resultContentHash)

        let wrongOrdinal = record.withOccurrenceOrdinal(1)
        XCTAssertEqual(
            ExplicitDeleteProvenanceValidator().validate(record: wrongOrdinal, candidateBaseBody: fixture.base),
            .recoveryRequired(.occurrenceNotFound)
        )

        let snapshot = SyncConvergenceSnapshotRecord(
            noteID: record.noteID,
            contentHash: record.baseContentHash,
            body: fixture.base,
            generation: 7,
            createdAt: Date(timeIntervalSince1970: 70)
        )
        let compacted = try compactedRecord(ExplicitDeleteProvenanceCompactor().compact(
            record: record,
            baseSnapshot: snapshot
        ))
        XCTAssertNil(compacted.deletedText)
        let compactedOccurrence = try validOccurrence(ExplicitDeleteProvenanceValidator().validate(
            record: compacted,
            candidateBaseBody: fixture.base
        ))
        XCTAssertEqual(compactedOccurrence.utf16Range, fullOccurrence.utf16Range)
        XCTAssertEqual(compactedOccurrence.resolvedDeletedText, fullOccurrence.resolvedDeletedText)
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

    func testContradictoryDuplicateRollbackPreservesOriginalRowAcrossFreshContext() throws {
        let fixture = try makeDeleteFixture(base: "alpha beta", deletedText: "beta", offset: 6)
        let record = try buildRecord(fixture)
        let container = try makeContainer()
        let context = ModelContext(container)
        let transaction = SwiftDataSyncConvergencePersistenceTransaction(context: context)
        try transaction.insertExplicitDeleteProvenance(record)
        try transaction.save()
        let originalProjection = try XCTUnwrap(transaction.loadExplicitDeleteProvenance(identity: record.identity))
        let originalBytes = originalProjection.canonicalPayloadData

        let contradictory = record.withDeletedEvidence("other")
        XCTAssertThrowsError(try transaction.insertExplicitDeleteProvenance(contradictory)) { error in
            XCTAssertEqual(
                error as? SyncConvergenceTransactionFailure,
                .inconsistentIncorporationState(noteID: record.noteID)
            )
        }
        transaction.rollback()

        let freshContext = ModelContext(container)
        let rows = try freshContext.fetch(FetchDescriptor<ExplicitDeleteProvenance>())
        XCTAssertEqual(rows.count, 1)
        let reloadedTransaction = SwiftDataSyncConvergencePersistenceTransaction(context: freshContext)
        let reloaded = try XCTUnwrap(reloadedTransaction.loadExplicitDeleteProvenance(identity: record.identity))
        XCTAssertEqual(reloaded.record, record)
        XCTAssertEqual(reloaded.canonicalPayloadData, originalBytes)
        XCTAssertEqual(reloaded.record.deletedText, record.deletedText)
        XCTAssertEqual(reloaded.record.deletedTextDigest, record.deletedTextDigest)
        XCTAssertEqual(
            ExplicitDeleteProvenanceValidator().validate(record: reloaded.record, candidateBaseBody: fixture.base),
            .valid(try validOccurrence(ExplicitDeleteProvenanceValidator().validate(record: record, candidateBaseBody: fixture.base)))
        )

        try reloadedTransaction.insertExplicitDeleteProvenance(record)
        try reloadedTransaction.save()
        XCTAssertEqual(try ModelContext(container).fetch(FetchDescriptor<ExplicitDeleteProvenance>()).count, 1)
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

    func testLargeNoteCompactedValidationIsDeterministicAndBoundarySafe() throws {
        let prefix = (0..<160).map { "p\($0 % 10)" }.joined(separator: "-")
        let suffix = (0..<160).map { "s\($0 % 7)" }.joined(separator: "_")
        let base = "\(prefix) aaa aaa target aaa aaa \(suffix)"
        let offset = try XCTUnwrap(base.range(of: "target")).lowerBound.samePosition(in: base.utf16)!
        let utf16Offset = base.utf16.distance(from: base.utf16.startIndex, to: offset)
        let fixture = try makeDeleteFixture(base: base, deletedText: "target", offset: utf16Offset)
        let record = try buildRecord(fixture)
        let snapshot = SyncConvergenceSnapshotRecord(
            noteID: record.noteID,
            contentHash: record.baseContentHash,
            body: base,
            generation: 11,
            createdAt: Date(timeIntervalSince1970: 110)
        )
        let compacted = try compactedRecord(ExplicitDeleteProvenanceCompactor().compact(
            record: record,
            baseSnapshot: snapshot
        ))

        let candidates = ExplicitDeleteOccurrenceEnumerator.compactedOccurrences(
            in: base,
            deletedUTF16Length: compacted.deletedUTF16Length,
            leftContextUTF16Length: compacted.leftContextUTF16Length,
            rightContextUTF16Length: compacted.rightContextUTF16Length,
            deletedTextDigest: compacted.deletedTextDigest,
            leftContextDigest: compacted.leftContextDigest,
            rightContextDigest: compacted.rightContextDigest
        )
        XCTAssertEqual(candidates.count, 1)
        XCTAssertTrue(candidates.allSatisfy {
            base.stringRange(utf16Offset: $0.utf16Range.lowerBound, utf16Length: $0.utf16Range.count) != nil
        })
        let first = ExplicitDeleteProvenanceValidator().validate(record: compacted, candidateBaseBody: base)
        let second = ExplicitDeleteProvenanceValidator().validate(record: compacted, candidateBaseBody: base)
        XCTAssertEqual(first, second)
        XCTAssertEqual(try validOccurrence(first).utf16Range, record.originalUTF16Offset..<(record.originalUTF16Offset + record.deletedUTF16Length))
    }

    private func buildResult(_ fixture: DeleteFixture) -> ExplicitDeleteProvenanceBuildResult {
        ExplicitDeleteProvenanceBuilder().build(
            graph: fixture.graph,
            node: fixture.node,
            preDeleteBody: fixture.base
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
        result explicitResult: String? = nil,
        noteID explicitNoteID: UUID? = nil,
        batchID explicitBatchID: UUID? = nil,
        originDeviceID explicitOriginDeviceID: UUID? = nil,
        modifiedAt: Date = Date(timeIntervalSince1970: 10)
    ) throws -> DeleteFixture {
        let noteID = explicitNoteID ?? UUID()
        let batchID = explicitBatchID ?? UUID()
        let originDeviceID = explicitOriginDeviceID ?? UUID()
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
    func withOccurrenceOrdinal(_ ordinal: Int) -> Self {
        copy(occurrenceOrdinal: ordinal)
    }

    func withDeletedEvidence(_ deletedText: String) -> Self {
        copy(
            deletedText: deletedText,
            deletedTextDigest: SyncBatchContentHash.sha256Hex(for: deletedText),
            deletedUTF16Length: deletedText.utf16.count
        )
    }

    func withFormatVersion(_ version: Int) -> Self {
        copy(formatVersion: version)
    }

    private func copy(
        formatVersion: Int? = nil,
        deletedText: String? = nil,
        deletedTextDigest: String? = nil,
        deletedUTF16Length: Int? = nil,
        occurrenceOrdinal: Int? = nil
    ) -> Self {
        ExplicitDeleteProvenanceRecord(
            formatVersion: formatVersion ?? self.formatVersion,
            tier: tier,
            noteID: noteID,
            batchID: batchID,
            operationIndex: operationIndex,
            originDeviceID: originDeviceID,
            canonicalReplayKey: canonicalReplayKey,
            baseContentHash: baseContentHash,
            resultContentHash: resultContentHash,
            deletedText: deletedText ?? self.deletedText,
            deletedTextDigest: deletedTextDigest ?? self.deletedTextDigest,
            deletedUTF16Length: deletedUTF16Length ?? self.deletedUTF16Length,
            leftContext: leftContext,
            leftContextDigest: leftContextDigest,
            leftContextUTF16Length: leftContextUTF16Length,
            rightContext: rightContext,
            rightContextDigest: rightContextDigest,
            rightContextUTF16Length: rightContextUTF16Length,
            originalUTF16Offset: originalUTF16Offset,
            occurrenceOrdinal: occurrenceOrdinal ?? self.occurrenceOrdinal,
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
