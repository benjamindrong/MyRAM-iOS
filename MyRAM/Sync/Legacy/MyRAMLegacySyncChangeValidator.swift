import Foundation
import NearbySyncCore

enum MyRAMLegacySyncChangeValidationResult: Equatable {
    case valid
    case invalid(MyRAMLegacySyncChangeValidationError)
}

enum MyRAMLegacySyncChangeValidationError: Error, Equatable {
    case malformedPayload
    case entityIDMismatch
    case deletePayloadNotDeleted
    case upsertPayloadMarkedDeleted
    case missingRequiredRelationship
    case invalidConflictAction
}

enum MyRAMLegacySyncChangeValidator {
    static func validate(_ change: SyncChange) -> MyRAMLegacySyncChangeValidationResult {
        switch change.entityType {
        case .collection:
            return validateFolder(change)
        case .item:
            return validateNote(change)
        case .marker:
            return validatePinnedThought(change)
        case .attachment:
            return validateAttachment(change)
        case .conflict:
            return validateConflict(change)
        }
    }

    private static func validateNote(_ change: SyncChange) -> MyRAMLegacySyncChangeValidationResult {
        guard let payload = try? MyRAMSyncPayloadCoding.decodeNote(from: change.payload) else {
            return .invalid(.malformedPayload)
        }
        guard payload.id.uuidString == change.entityID else {
            return .invalid(.entityIDMismatch)
        }
        return validateDeletionConsistency(operation: change.operation, isDeleted: payload.deletedAt != nil)
    }

    private static func validateFolder(_ change: SyncChange) -> MyRAMLegacySyncChangeValidationResult {
        guard let payload = try? MyRAMSyncPayloadCoding.decodeFolder(from: change.payload) else {
            return .invalid(.malformedPayload)
        }
        guard payload.id.uuidString == change.entityID else {
            return .invalid(.entityIDMismatch)
        }
        return validateDeletionConsistency(operation: change.operation, isDeleted: payload.isDeleted)
    }

    private static func validatePinnedThought(_ change: SyncChange) -> MyRAMLegacySyncChangeValidationResult {
        guard let payload = try? MyRAMSyncPayloadCoding.decodePinnedThought(from: change.payload) else {
            return .invalid(.malformedPayload)
        }
        guard payload.id.uuidString == change.entityID else {
            return .invalid(.entityIDMismatch)
        }
        return validateDeletionConsistency(operation: change.operation, isDeleted: payload.isDeleted)
    }

    private static func validateAttachment(_ change: SyncChange) -> MyRAMLegacySyncChangeValidationResult {
        guard let payload = try? MyRAMSyncPayloadCoding.decodePhotoAttachment(from: change.payload) else {
            return .invalid(.malformedPayload)
        }
        guard payload.id.uuidString == change.entityID else {
            return .invalid(.entityIDMismatch)
        }
        return validateDeletionConsistency(operation: change.operation, isDeleted: payload.isDeleted)
    }

    private static func validateConflict(_ change: SyncChange) -> MyRAMLegacySyncChangeValidationResult {
        guard let payload = try? MyRAMSyncPayloadCoding.decodeSyncConflict(from: change.payload) else {
            return .invalid(.malformedPayload)
        }
        guard payload.conflictID.uuidString == change.entityID else {
            return .invalid(.entityIDMismatch)
        }
        switch payload.action {
        case .preserved:
            guard payload.conflict != nil else { return .invalid(.invalidConflictAction) }
        case .resolved:
            break
        }
        return .valid
    }

    private static func validateDeletionConsistency(
        operation: SyncOperation,
        isDeleted: Bool
    ) -> MyRAMLegacySyncChangeValidationResult {
        switch operation {
        case .delete:
            return isDeleted ? .valid : .invalid(.deletePayloadNotDeleted)
        case .upsert:
            return isDeleted ? .invalid(.upsertPayloadMarkedDeleted) : .valid
        }
    }
}
