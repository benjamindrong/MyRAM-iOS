import XCTest
#if os(macOS)
@testable import MyRAMMac
#else
@testable import MyRAM
#endif

final class SyncConvergenceRewriteSafetyPolicyTests: XCTestCase {
    func testIdenticalNonEmptyBodyConsumesNoEvidence() {
        guard case .safe(let receipt) = result(
            prior: "unchanged",
            candidate: "unchanged",
            evidence: [deleteEvidence("changed", index: 0)]
        ) else { return XCTFail("Expected identical body to be safe") }
        XCTAssertTrue(receipt.consumedDeleteIdentities.isEmpty)
    }

    func testEmptyEvidenceAndMismatchedExpectedTextCannotProveLoss() {
        assertUnsafe(prior: "alpha beta", candidate: "alpha")
        assertUnsafe(prior: "alpha beta", candidate: "alpha", evidence: [deleteEvidence("alpha", index: 0)])
    }

    func testOffsetDriftDoesNotInvalidateExpectedTextProof() {
        assertSafe(prior: "prefix target", candidate: "prefix ", evidence: [deleteEvidence("target", index: 0, offset: 0)])
    }

    func testDuplicateDeleteIdentityIsRejected() {
        let evidence = deleteEvidence("foo", index: 0)
        guard case .unsafe(.duplicateDeleteIdentity) = result(
            prior: "foo foo",
            candidate: "",
            evidence: [evidence, evidence]
        ) else { return XCTFail("Expected duplicate identity rejection") }
    }

    func testMultiCharacterEvidenceCoversOnlyItsExactMultiset() {
        assertSafe(prior: "abc", candidate: "c", evidence: [deleteEvidence("ab", index: 0)])
        assertUnsafe(prior: "abc", candidate: "a", evidence: [deleteEvidence("ab", index: 0)])
    }
    func testPreservationInsertionAndReorderAreSafe() {
        assertSafe(prior: "", candidate: "")
        assertSafe(prior: "", candidate: "new")
        assertSafe(prior: "foo bar", candidate: "bar foo")
    }

    func testUnprovenDuplicateDropIsUnsafe() {
        assertUnsafe(prior: "foo bar foo", candidate: "foo bar")
    }

    func testOneProofCoversOnlyOneDuplicateOccurrence() {
        assertSafe(prior: "foo foo", candidate: "foo", evidence: [deleteEvidence(" foo", index: 0)])
        assertUnsafe(prior: "foo foo foo", candidate: "foo", evidence: [deleteEvidence("foo", index: 0)])
    }

    func testReorderPlusExplicitDeleteIsSafe() {
        assertSafe(prior: "foo bar foo", candidate: "foo foo", evidence: [deleteEvidence("bar ", index: 0)])
    }

    func testWhitespaceOmissionRequiresExplicitEvidence() {
        assertUnsafe(prior: "foo foo", candidate: "foo", evidence: [deleteEvidence("foo", index: 0)])
    }

    func testWhitespaceAndUnicodeRequireExactUTF16Evidence() {
        assertUnsafe(prior: "  ", candidate: " ")
        assertSafe(prior: "A👨‍👩‍👧‍👦B", candidate: "BA", evidence: [deleteEvidence("👨‍👩‍👧‍👦", index: 0)])
        assertUnsafe(prior: "A😀B", candidate: "AB", evidence: [deleteEvidence("😀", index: 0, declaredLength: 1)])
    }

    private func assertSafe(prior: String, candidate: String, evidence: [SyncConvergenceDeleteEvidence] = [], file: StaticString = #filePath, line: UInt = #line) {
        guard case .safe = result(prior: prior, candidate: candidate, evidence: evidence) else {
            return XCTFail("Expected safe rewrite", file: file, line: line)
        }
    }

    private func assertUnsafe(prior: String, candidate: String, evidence: [SyncConvergenceDeleteEvidence] = [], file: StaticString = #filePath, line: UInt = #line) {
        guard case .unsafe = result(prior: prior, candidate: candidate, evidence: evidence) else {
            return XCTFail("Expected unsafe rewrite", file: file, line: line)
        }
    }

    private func result(prior: String, candidate: String, evidence: [SyncConvergenceDeleteEvidence]) -> SyncConvergenceRewriteSafetyResult {
        SyncConvergenceRewriteSafetyPolicy().validate(.init(
            noteID: Self.noteID,
            sourceBatchID: Self.batchID,
            priorBody: prior,
            candidateBody: candidate,
            deleteEvidence: evidence,
            context: .plannerMerge
        ))
    }

    private func deleteEvidence(_ text: String, index: Int, declaredLength: Int? = nil, offset: Int = 0) -> SyncConvergenceDeleteEvidence {
        let change = SyncBatchChange.noteBodyTextDeleted(.init(
            noteID: Self.noteID,
            utf16Offset: offset,
            utf16Length: declaredLength ?? text.utf16.count,
            expectedText: text,
            modifiedAt: Date(timeIntervalSinceReferenceDate: 1),
            baseContentHash: nil
        ))
        let batch = SyncBatch(id: Self.batchID, originDeviceID: Self.originID, createdAt: Date(timeIntervalSinceReferenceDate: 1), changes: [change])
        return .init(
            operationIdentity: .init(
                batchID: batch.id,
                originDeviceID: batch.originDeviceID,
                operationIndex: index,
                operationKind: "delete",
                canonicalReplayKey: .init(replayKey: SyncBatchReplayKey(batch: batch, change: change, operationIndex: index))
            ),
            utf16Offset: offset,
            utf16Length: declaredLength ?? text.utf16.count,
            expectedText: text,
            baseContentHash: nil,
            resultContentHash: nil
        )
    }

    private static let noteID = UUID(uuidString: "00000000-0000-0000-0000-000000155001")!
    private static let batchID = UUID(uuidString: "00000000-0000-0000-0000-000000155002")!
    private static let originID = UUID(uuidString: "00000000-0000-0000-0000-000000155003")!
}
