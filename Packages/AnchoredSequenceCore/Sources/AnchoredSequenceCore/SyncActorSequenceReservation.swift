import Foundation

public enum SyncActorSequenceReservationError: Error, Equatable, Sendable {
    case counterExhausted(actorID: UUID)
}

/// Immutable actor-scoped reservation state used to calculate the next operation identity.
public struct SyncActorSequenceState: Equatable, Sendable {
    public let actorID: UUID
    public let lastReservedCounter: UInt64?

    public init(
        actorID: UUID,
        lastReservedCounter: UInt64? = nil
    ) {
        self.actorID = actorID
        self.lastReservedCounter = lastReservedCounter
    }
}

/// Couples an operation identity with the state that must be persisted before exposing it.
public struct SyncActorSequenceReservation: Equatable, Sendable {
    public let operationID: SyncOperationID
    public let advancedState: SyncActorSequenceState

    init(
        operationID: SyncOperationID,
        advancedState: SyncActorSequenceState
    ) {
        self.operationID = operationID
        self.advancedState = advancedState
    }
}

public extension SyncActorSequenceState {
    func reservingNext() throws -> SyncActorSequenceReservation {
        let nextCounter: UInt64
        if let lastReservedCounter {
            guard lastReservedCounter < UInt64.max else {
                throw SyncActorSequenceReservationError.counterExhausted(actorID: actorID)
            }
            nextCounter = lastReservedCounter + 1
        } else {
            nextCounter = 0
        }

        let advancedState = SyncActorSequenceState(
            actorID: actorID,
            lastReservedCounter: nextCounter
        )
        return SyncActorSequenceReservation(
            operationID: SyncOperationID(
                deviceID: actorID,
                localCounter: nextCounter
            ),
            advancedState: advancedState
        )
    }
}
