import Foundation
import XCTest
@testable import AnchoredSequenceCore

final class SyncActorSequenceReservationTests: XCTestCase {
    func testFirstReservationUsesCounterZero() throws {
        let actorID = uuid("00000000-0000-0000-0000-000000000001")

        let reservation = try SyncActorSequenceState(actorID: actorID).reservingNext()

        XCTAssertEqual(
            reservation.operationID,
            SyncOperationID(deviceID: actorID, localCounter: 0)
        )
        XCTAssertEqual(
            reservation.advancedState,
            SyncActorSequenceState(actorID: actorID, lastReservedCounter: 0)
        )
    }

    func testRepeatedTransitionsProduceMonotonicCounters() throws {
        let actorID = uuid("00000000-0000-0000-0000-000000000001")
        var state = SyncActorSequenceState(actorID: actorID)
        var reservations: [SyncActorSequenceReservation] = []

        for _ in 0..<3 {
            let reservation = try state.reservingNext()
            reservations.append(reservation)
            state = reservation.advancedState
        }

        XCTAssertEqual(reservations.map(\.operationID.localCounter), [0, 1, 2])
        XCTAssertTrue(reservations.allSatisfy { $0.operationID.deviceID == actorID })
        XCTAssertEqual(state, SyncActorSequenceState(actorID: actorID, lastReservedCounter: 2))
    }

    func testTransitionLeavesOriginalStateUnchanged() throws {
        let actorID = uuid("00000000-0000-0000-0000-000000000001")
        let original = SyncActorSequenceState(actorID: actorID, lastReservedCounter: 4)

        let reservation = try original.reservingNext()

        XCTAssertEqual(original.lastReservedCounter, 4)
        XCTAssertEqual(reservation.advancedState.lastReservedCounter, 5)
    }

    func testMaximumMinusOneReservesMaximumCounter() throws {
        let actorID = uuid("00000000-0000-0000-0000-000000000001")
        let state = SyncActorSequenceState(
            actorID: actorID,
            lastReservedCounter: UInt64.max - 1
        )

        let reservation = try state.reservingNext()

        XCTAssertEqual(reservation.operationID.localCounter, UInt64.max)
        XCTAssertEqual(reservation.advancedState.lastReservedCounter, UInt64.max)
    }

    func testMaximumCounterThrowsExhaustionWithoutAdvancedState() {
        let actorID = uuid("00000000-0000-0000-0000-000000000001")
        let state = SyncActorSequenceState(
            actorID: actorID,
            lastReservedCounter: UInt64.max
        )

        XCTAssertThrowsError(try state.reservingNext()) { error in
            XCTAssertEqual(
                error as? SyncActorSequenceReservationError,
                .counterExhausted(actorID: actorID)
            )
        }
        XCTAssertEqual(state.lastReservedCounter, UInt64.max)
    }

    func testReservationUsesExistingOperationIdentityType() throws {
        let actorID = uuid("00000000-0000-0000-0000-000000000001")

        let reservation: SyncActorSequenceReservation = try SyncActorSequenceState(
            actorID: actorID
        ).reservingNext()
        let operationID: SyncOperationID = reservation.operationID

        XCTAssertEqual(operationID.deviceID, actorID)
        XCTAssertEqual(operationID.localCounter, 0)
    }

    private func uuid(_ value: String) -> UUID {
        UUID(uuidString: value)!
    }
}
