import XCTest
#if os(macOS)
@testable import MyRAMMac
#else
@testable import MyRAM
#endif

final class SyncConvergenceRewriteSafetyPolicyTests: XCTestCase {
    func testPreservationInsertionAndReorderAreSafe() {
        assertSafe(prior: "", candidate: "")
        assertSafe(prior: "", candidate: "new")
        assertSafe(prior: "foo bar", candidate: "bar foo")
    }

    func testUnprovenDuplicateDropIsUnsafe() {
        assertUnsafe(prior: "foo bar foo", candidate: "foo bar")
    }

    func testOneProofCoversOnlyOneDuplicateOccurrence() {
        assertSafe(prior: "foo foo", candidate: "foo", evidence: [deleteEvidence("foo", index: 0)])
        assertUnsafe(prior: "foo foo foo", candidate: "foo", evidence: [deleteEvidence("foo", index: 0)])
    }

    func testReorderPlusExplicitDeleteIsSafe() {
        assertSafe(prior: "foo bar foo", candidate: "foo foo", evidence: [deleteEvidence("bar", index: 0)])
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

    private func deleteEvidence(_ text: String, index: Int, declaredLength: Int? = nil) -> SyncConvergenceDeleteEvidence {
        let change = SyncBatchChange.noteBodyTextDeleted(.init(
            noteID: Self.noteID,
            utf16Offset: 0,
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
            utf16Offset: 0,
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
