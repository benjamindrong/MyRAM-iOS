import Foundation
import NearbySyncCore
import SwiftData

struct SyncRecoveryReplacementState: Equatable {
    let legacySnapshot: SyncQueueSnapshot
    let unsentBatches: [SyncBatch]
    let localConvergenceBatches: [SyncBatch]
    let replacedLegacyCount: Int
    let replacedUnsentBatchCount: Int
    let replacedLocalObligationCount: Int
}

enum SyncRecoveryStateBuilderError: Error, Equatable {
    case activeConflict(entityType: SyncConflictEntityType, entityID: UUID)
    case invalidLegacyEntityID(String)
    case missingCurrentEntity(entityType: SyncEntityType, entityID: UUID)
    case missingCurrentNoteReferencedByUnsentBatch(UUID)
    case missingCurrentNoteReferencedByLocalObligation(UUID)
    case unsupportedPendingLegacyConflictMetadata(UUID)
    case targetCoverageMismatch
}

enum SyncRecoveryStateBuilder {
    static func build(
        context: ModelContext,
        conflictStore: SyncConflictStore,
        legacySnapshot: SyncQueueSnapshot,
        unsentBatches: [SyncBatch],
        localConvergenceBatches: [SyncBatch],
        currentDeviceID: String,
        recoveryTimestamp: Date
    ) throws -> SyncRecoveryReplacementState {
        try unsentBatches.forEach(SyncBatchAnchoredPayloadPolicy.validateRecovery)
        try localConvergenceBatches.forEach(
            SyncBatchAnchoredPayloadPolicy.validateRecovery
        )
        let legacyTargets = try targets(from: legacySnapshot.pendingChanges)
        let allAffectedNoteIDs = try affectedNoteIDs(
            context: context,
            legacyChanges: legacySnapshot.pendingChanges,
            unsentBatches: unsentBatches,
            localConvergenceBatches: localConvergenceBatches
        )
        try validateNoActiveConflicts(
            conflictStore: conflictStore,
            legacyTargets: legacyTargets,
            affectedNoteIDs: allAffectedNoteIDs
        )

        let notes = try fetchNotes(context: context, ids: allAffectedNoteIDs)
        try validateBatchNoteCoverage(
            requestedNoteIDs: affectedNoteIDs(in: unsentBatches),
            notes: notes,
            legacyChanges: legacySnapshot.pendingChanges,
            error: SyncRecoveryStateBuilderError.missingCurrentNoteReferencedByUnsentBatch
        )
        try validateBatchNoteCoverage(
            requestedNoteIDs: affectedNoteIDs(in: localConvergenceBatches),
            notes: notes,
            legacyChanges: legacySnapshot.pendingChanges,
            error: SyncRecoveryStateBuilderError.missingCurrentNoteReferencedByLocalObligation
        )

        var replacementChanges: [SyncChange] = []
        var emittedTargets = Set<SyncTarget>()

        let folders = try fetchFolders(context: context, ids: affectedFolderIDs(legacyTargets: legacyTargets))
        let thoughts = try context.fetch(FetchDescriptor<PinnedThought>())
        let attachments = try context.fetch(FetchDescriptor<NotePhotoAttachment>())
        try validateLegacyCoverage(
            targets: legacyTargets,
            notes: notes,
            folders: folders,
            thoughts: thoughts,
            attachments: attachments,
            legacyChanges: legacySnapshot.pendingChanges
        )

        for folder in folders.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            for folder in folderChain(for: folder).sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
                append(
                    try MyRAMLegacySyncPayloadBuilder.change(
                        folder: folder,
                        updatedAt: recoveryTimestamp,
                        originDeviceID: currentDeviceID
                    ),
                    to: &replacementChanges,
                    emittedTargets: &emittedTargets
                )
            }
        }

        for note in notes.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            for folder in folderChain(for: note).sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
                append(
                    try MyRAMLegacySyncPayloadBuilder.change(
                        folder: folder,
                        updatedAt: recoveryTimestamp,
                        originDeviceID: currentDeviceID
                    ),
                    to: &replacementChanges,
                    emittedTargets: &emittedTargets
                )
            }

            append(
                try MyRAMLegacySyncPayloadBuilder.change(
                    note: note,
                    operation: note.deletedAt == nil ? .upsert : .delete,
                    conflictStore: conflictStore,
                    updatedAt: recoveryTimestamp,
                    originDeviceID: currentDeviceID
                ),
                to: &replacementChanges,
                emittedTargets: &emittedTargets
            )

            for thought in note.pinnedThoughts.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
                append(
                    try MyRAMLegacySyncPayloadBuilder.change(
                        thought: thought,
                        conflictStore: conflictStore,
                        updatedAt: recoveryTimestamp,
                        originDeviceID: currentDeviceID
                    ),
                    to: &replacementChanges,
                    emittedTargets: &emittedTargets
                )
            }

            for attachment in note.photoAttachments.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
                append(
                    try MyRAMLegacySyncPayloadBuilder.change(
                        attachment: attachment,
                        updatedAt: recoveryTimestamp,
                        originDeviceID: currentDeviceID
                    ),
                    to: &replacementChanges,
                    emittedTargets: &emittedTargets
                )
            }
        }

        replacementChanges.append(
            contentsOf: retainedDeletionTombstones(
                from: legacySnapshot.pendingChanges,
                excluding: emittedTargets,
                recoveryTimestamp: recoveryTimestamp,
                originDeviceID: currentDeviceID
            )
        )

        try validateReplacementCoverage(
            legacyTargets: legacyTargets,
            unsentNoteIDs: affectedNoteIDs(in: unsentBatches),
            localNoteIDs: affectedNoteIDs(in: localConvergenceBatches),
            replacementChanges: replacementChanges
        )

        return SyncRecoveryReplacementState(
            legacySnapshot: SyncQueueSnapshot(
                pendingChanges: replacementChanges,
                appliedChangeIDs: legacySnapshot.appliedChangeIDs,
                pendingAcknowledgementIDs: legacySnapshot.pendingAcknowledgementIDs
            ),
            unsentBatches: [],
            localConvergenceBatches: [],
            replacedLegacyCount: legacySnapshot.pendingChanges.count,
            replacedUnsentBatchCount: unsentBatches.count,
            replacedLocalObligationCount: localConvergenceBatches.count
        )
    }

    static func affectedNoteIDs(in batches: [SyncBatch]) -> Set<UUID> {
        Set(batches.flatMap { batch in
            batch.changes.map(\.noteID)
        })
    }

    private static func affectedNoteIDs(
        context: ModelContext,
        legacyChanges: [SyncChange],
        unsentBatches: [SyncBatch],
        localConvergenceBatches: [SyncBatch]
    ) throws -> Set<UUID> {
        var noteIDs = affectedNoteIDs(in: unsentBatches + localConvergenceBatches)
        var markerIDs = Set<UUID>()
        var attachmentIDs = Set<UUID>()
        for change in legacyChanges {
            guard let target = SyncTarget(change: change) else {
                throw SyncRecoveryStateBuilderError.invalidLegacyEntityID(change.entityID)
            }
            switch target.entityType {
            case .item:
                noteIDs.insert(target.entityID)
            case .marker:
                if let noteID = try? MyRAMSyncPayloadCoding.decodePinnedThought(from: change.payload).noteID {
                    noteIDs.insert(noteID)
                } else {
                    markerIDs.insert(target.entityID)
                }
            case .attachment:
                if let noteID = try? MyRAMSyncPayloadCoding.decodePhotoAttachment(from: change.payload).noteID {
                    noteIDs.insert(noteID)
                } else {
                    attachmentIDs.insert(target.entityID)
                }
            case .conflict:
                if let noteID = try? MyRAMSyncPayloadCoding.decodeSyncConflict(from: change.payload).conflict?.noteID {
                    noteIDs.insert(noteID)
                }
            case .collection:
                continue
            }
        }
        if !markerIDs.isEmpty {
            let thoughts = try context.fetch(FetchDescriptor<PinnedThought>())
            noteIDs.formUnion(thoughts.compactMap { markerIDs.contains($0.id) ? $0.note?.id : nil })
        }
        if !attachmentIDs.isEmpty {
            let attachments = try context.fetch(FetchDescriptor<NotePhotoAttachment>())
            noteIDs.formUnion(attachments.compactMap { attachmentIDs.contains($0.id) ? $0.note?.id : nil })
        }
        return noteIDs
    }

    private static func affectedFolderIDs(legacyTargets: Set<SyncTarget>) -> Set<UUID> {
        Set(legacyTargets.compactMap { $0.entityType == .collection ? $0.entityID : nil })
    }

    private static func targets(from changes: [SyncChange]) throws -> Set<SyncTarget> {
        var targets = Set<SyncTarget>()
        for change in changes {
            guard let target = SyncTarget(change: change) else {
                throw SyncRecoveryStateBuilderError.invalidLegacyEntityID(change.entityID)
            }
            guard target.entityType != .conflict else {
                throw SyncRecoveryStateBuilderError.unsupportedPendingLegacyConflictMetadata(target.entityID)
            }
            targets.insert(target)
        }
        return targets
    }

    private static func validateBatchNoteCoverage(
        requestedNoteIDs: Set<UUID>,
        notes: [Note],
        legacyChanges: [SyncChange],
        error: (UUID) -> SyncRecoveryStateBuilderError
    ) throws {
        let currentNoteIDs = Set(notes.map(\.id))
        for noteID in requestedNoteIDs where !currentNoteIDs.contains(noteID) {
            guard hasValidDeletionTombstone(
                entityType: .item,
                entityID: noteID,
                in: legacyChanges
            ) else {
                throw error(noteID)
            }
        }
    }

    private static func validateLegacyCoverage(
        targets: Set<SyncTarget>,
        notes: [Note],
        folders: [Folder],
        thoughts: [PinnedThought],
        attachments: [NotePhotoAttachment],
        legacyChanges: [SyncChange]
    ) throws {
        let noteIDs = Set(notes.map(\.id))
        let folderIDs = Set(folders.map(\.id))
        let thoughtIDs = Set(thoughts.map(\.id))
        let attachmentIDs = Set(attachments.map(\.id))

        for target in targets {
            let isCovered: Bool
            switch target.entityType {
            case .item:
                isCovered = noteIDs.contains(target.entityID)
            case .collection:
                isCovered = folderIDs.contains(target.entityID)
            case .marker:
                isCovered = thoughtIDs.contains(target.entityID)
            case .attachment:
                isCovered = attachmentIDs.contains(target.entityID)
            case .conflict:
                isCovered = false
            }
            if !isCovered,
               !hasValidDeletionTombstone(entityType: target.entityType, entityID: target.entityID, in: legacyChanges) {
                throw SyncRecoveryStateBuilderError.missingCurrentEntity(
                    entityType: target.entityType,
                    entityID: target.entityID
                )
            }
        }
    }

    private static func validateReplacementCoverage(
        legacyTargets: Set<SyncTarget>,
        unsentNoteIDs: Set<UUID>,
        localNoteIDs: Set<UUID>,
        replacementChanges: [SyncChange]
    ) throws {
        let replacementTargets = Set(replacementChanges.compactMap(SyncTarget.init(change:)))
        for target in legacyTargets where !replacementTargets.contains(target) {
            throw SyncRecoveryStateBuilderError.targetCoverageMismatch
        }
        for noteID in unsentNoteIDs.union(localNoteIDs)
            where !replacementTargets.contains(SyncTarget(entityType: .item, entityID: noteID)) {
            throw SyncRecoveryStateBuilderError.targetCoverageMismatch
        }
    }

    private static func validateNoActiveConflicts(
        conflictStore: SyncConflictStore,
        legacyTargets: Set<SyncTarget>,
        affectedNoteIDs: Set<UUID>,
        now: Date = Date()
    ) throws {
        for conflict in conflictStore.activeConflicts(now: now) {
            if affectedNoteIDs.contains(conflict.noteID ?? conflict.entityID)
                || legacyTargets.contains(SyncTarget(entityType: conflict.entityType.syncEntityType, entityID: conflict.entityID)) {
                throw SyncRecoveryStateBuilderError.activeConflict(
                    entityType: conflict.entityType,
                    entityID: conflict.entityID
                )
            }
        }
    }

    private static func fetchNotes(context: ModelContext, ids: Set<UUID>) throws -> [Note] {
        guard !ids.isEmpty else { return [] }
        return try context.fetch(FetchDescriptor<Note>()).filter { ids.contains($0.id) }
    }

    private static func fetchFolders(context: ModelContext, ids: Set<UUID>) throws -> [Folder] {
        guard !ids.isEmpty else { return [] }
        return try context.fetch(FetchDescriptor<Folder>()).filter { ids.contains($0.id) }
    }

    private static func folderChain(for note: Note) -> [Folder] {
        guard let folder = note.folder else { return [] }
        return folderChain(for: folder)
    }

    private static func folderChain(for folder: Folder) -> [Folder] {
        var folders: [Folder] = []
        var current: Folder? = folder
        while let folder = current {
            folders.append(folder)
            current = folder.parentFolder
        }
        return folders.reversed()
    }

    private static func append(
        _ change: SyncChange,
        to changes: inout [SyncChange],
        emittedTargets: inout Set<SyncTarget>
    ) {
        guard let target = SyncTarget(change: change) else { return }
        if emittedTargets.insert(target).inserted {
            changes.append(change)
        }
    }

    private static func retainedDeletionTombstones(
        from changes: [SyncChange],
        excluding emittedTargets: Set<SyncTarget>,
        recoveryTimestamp: Date,
        originDeviceID: String
    ) -> [SyncChange] {
        var newestByTarget: [SyncTarget: (originalUpdatedAt: Date, change: SyncChange)] = [:]
        for change in changes where change.operation == .delete && isValidDeletionTombstone(change) {
            guard let target = SyncTarget(change: change), !emittedTargets.contains(target) else { continue }
            if let existing = newestByTarget[target], existing.originalUpdatedAt >= change.updatedAt {
                continue
            }
            newestByTarget[target] = (
                originalUpdatedAt: change.updatedAt,
                change: SyncChange(
                    entityType: change.entityType,
                    entityID: change.entityID,
                    operation: .delete,
                    payload: change.payload,
                    updatedAt: recoveryTimestamp,
                    originDeviceID: originDeviceID
                )
            )
        }
        return newestByTarget.values.map(\.change).sorted {
            if $0.entityType.rawValue != $1.entityType.rawValue {
                return $0.entityType.rawValue < $1.entityType.rawValue
            }
            return $0.entityID < $1.entityID
        }
    }

    private static func isValidDeletionTombstone(_ change: SyncChange) -> Bool {
        switch change.entityType {
        case .item:
            return ((try? MyRAMSyncPayloadCoding.decodeNote(from: change.payload))?.deletedAt) != nil
        case .collection:
            return ((try? MyRAMSyncPayloadCoding.decodeFolder(from: change.payload))?.isDeleted) == true
        case .marker:
            return ((try? MyRAMSyncPayloadCoding.decodePinnedThought(from: change.payload))?.isDeleted) == true
        case .attachment:
            return ((try? MyRAMSyncPayloadCoding.decodePhotoAttachment(from: change.payload))?.isDeleted) == true
        case .conflict:
            return false
        }
    }

    private static func hasValidDeletionTombstone(
        entityType: SyncEntityType,
        entityID: UUID,
        in changes: [SyncChange]
    ) -> Bool {
        changes.contains { change in
            change.entityType == entityType
                && change.operation == .delete
                && UUID(uuidString: change.entityID) == entityID
                && isValidDeletionTombstone(change)
        }
    }
}

private struct SyncTarget: Hashable {
    let entityType: SyncEntityType
    let entityID: UUID

    init(entityType: SyncEntityType, entityID: UUID) {
        self.entityType = entityType
        self.entityID = entityID
    }

    init?(change: SyncChange) {
        guard let id = UUID(uuidString: change.entityID) else { return nil }
        self.init(entityType: change.entityType, entityID: id)
    }
}

private extension SyncConflictEntityType {
    var syncEntityType: SyncEntityType {
        switch self {
        case .note:
            return .item
        case .folder:
            return .collection
        case .pinnedThought:
            return .marker
        }
    }
}
