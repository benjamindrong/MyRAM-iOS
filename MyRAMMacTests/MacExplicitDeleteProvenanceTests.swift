import XCTest
@testable import MyRAMMac

final class MacExplicitDeleteProvenanceTests: XCTestCase {
    func testMacTargetBuildsAndValidatesExplicitDeleteProvenance() throws {
        let fixture = try makeDeleteFixture(base: "one two one", deletedText: "two", offset: 4)
        guard case .record(let record) = ExplicitDeleteProvenanceBuilder().build(
            graph: fixture.graph,
            node: fixture.node,
            preDeleteBody: fixture.base
        ) else {
            return XCTFail("expected provenance record")
        }

        let occurrence = try validOccurrence(ExplicitDeleteProvenanceValidator().validate(
            record: record,
            graph: fixture.graph,
            node: fixture.node,
            candidateBaseBody: fixture.base
        ))
        XCTAssertEqual(occurrence.utf16Range, 4..<7)
        XCTAssertEqual(occurrence.resolvedDeletedText, "two")
    }

    func testMacTargetValidatesCompactedProvenanceFromSnapshot() throws {
        let fixture = try makeDeleteFixture(base: "alpha beta gamma", deletedText: "beta", offset: 6)
        guard case .record(let record) = ExplicitDeleteProvenanceBuilder().build(
            graph: fixture.graph,
            node: fixture.node,
            preDeleteBody: fixture.base
        ) else {
            return XCTFail("expected provenance record")
        }
        let snapshot = SyncConvergenceSnapshotRecord(
            noteID: record.noteID,
            contentHash: record.baseContentHash,
            body: fixture.base,
            generation: 1,
            createdAt: Date(timeIntervalSince1970: 30)
        )
        guard case .compacted(let compacted) = ExplicitDeleteProvenanceCompactor().compact(
            record: record,
            baseSnapshot: snapshot
        ) else {
            return XCTFail("expected compacted provenance")
        }
        XCTAssertEqual(compacted.tier, .compacted)
        XCTAssertNil(compacted.deletedText)
        XCTAssertEqual(
            try validOccurrence(ExplicitDeleteProvenanceValidator().validate(
                record: compacted,
                candidateBaseBody: fixture.base
            )).utf16Range,
            6..<10
        )
    }

    private func validOccurrence(
        _ result: ExplicitDeleteProvenanceValidationResult
    ) throws -> ValidatedExplicitDeleteOccurrence {
        guard case .valid(let occurrence) = result else {
            XCTFail("expected valid occurrence")
            throw TestFailure()
        }
        return occurrence
    }

    private func makeDeleteFixture(
        base: String,
        deletedText: String,
        offset: Int
    ) throws -> DeleteFixture {
        let noteID = UUID()
        let batchID = UUID()
        let originDeviceID = UUID()
        let modifiedAt = Date(timeIntervalSince1970: 10)
        var result = base
        result.removeSubrange(result.stringRange(utf16Offset: offset, utf16Length: deletedText.utf16.count)!)
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
            utf16Length: deletedText.utf16.count,
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
        guard case .valid(let graph) = validation, let node = graph.nodes.first else {
            XCTFail("expected valid graph")
            throw TestFailure()
        }
        return DeleteFixture(base: base, graph: graph, node: node)
    }
}

private struct DeleteFixture {
    let base: String
    let graph: RetainedOperationCausalGraph
    let node: ValidatedRetainedOperationNode
}

private struct TestFailure: Error {}
