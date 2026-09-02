import XCTest
@testable import MyRAM

final class MYR184SyncConflictRoutingTests: XCTestCase {
    func testStage3TaxonomyRoutesOnlyPreserveLiveNoteToLifecycleConflictIntent() {
        XCTAssertFalse(SyncConvergenceLifecycleConflictIntentEligibility.isEligible(.apply))
        XCTAssertTrue(SyncConvergenceLifecycleConflictIntentEligibility.isEligible(.preserveLiveNote))
    }
}
