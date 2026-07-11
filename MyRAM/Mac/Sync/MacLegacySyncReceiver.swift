#if os(macOS)
import Foundation
import NearbySyncCore
import SwiftData

protocol MacLegacyAppliedChangeStoring: AnyObject {
    func contains(_ id: UUID) -> Bool
    func insert(_ ids: Set<UUID>) throws
}

struct MacLegacyReceiveResult: Equatable {
    let acknowledgementIDs: [UUID]
    let rejectedChangeIDs: [UUID]
    let applyResult: MyRAMSyncApplyResult
}

enum MacLegacySyncReceiverError: Error, Equatable {
    case preExistingModelSaveFailed
    case modelSaveFailed
    case appliedLedgerPersistenceFailed
}

@MainActor
final class MacLegacySyncReceiver {
    private let context: ModelContext
    private let applier: MyRAMSyncChangeApplier
    private let appliedStore: MacLegacyAppliedChangeStoring
    private let performSave: () throws -> Void

    init(
        context: ModelContext,
        conflictStore: SyncConflictStore = SyncConflictStore(),
        appliedStore: MacLegacyAppliedChangeStoring = FileBackedMacLegacyAppliedChangeStore(),
        performSave: (() throws -> Void)? = nil
    ) {
        self.context = context
        self.applier = MyRAMSyncChangeApplier(context: context, conflictStore: conflictStore)
        self.appliedStore = appliedStore
        self.performSave = performSave ?? { try context.save() }
    }

    func receive(_ envelope: SyncEnvelope) throws -> MacLegacyReceiveResult {
        guard !envelope.changes.isEmpty else {
            return MacLegacyReceiveResult(
                acknowledgementIDs: [],
                rejectedChangeIDs: [],
                applyResult: MyRAMSyncApplyResult()
            )
        }

        var duplicateAcknowledgements: [UUID] = []
        var newValidChanges: [SyncChange] = []
        var rejectedChangeIDs: [UUID] = []

        for change in envelope.changes {
            guard Self.hasValidPayload(change) else {
                rejectedChangeIDs.append(change.id)
                continue
            }
            if appliedStore.contains(change.id) {
                duplicateAcknowledgements.append(change.id)
            } else {
                newValidChanges.append(change)
            }
        }

        if context.hasChanges {
            do {
                try performSave()
            } catch {
                throw MacLegacySyncReceiverError.preExistingModelSaveFailed
            }
        }

        let applyResult = applier.apply(
            newValidChanges,
            activeNoteID: nil,
            currentNoteID: nil,
            currentFolderID: nil
        )
        let terminalChangeIDs = Set(applyResult.outcomes.filter(\.shouldAcknowledge).map(\.changeID))

        do {
            try performSave()
        } catch {
            context.rollback()
            throw MacLegacySyncReceiverError.modelSaveFailed
        }

        do {
            try appliedStore.insert(terminalChangeIDs)
        } catch {
            throw MacLegacySyncReceiverError.appliedLedgerPersistenceFailed
        }

        return MacLegacyReceiveResult(
            acknowledgementIDs: duplicateAcknowledgements + newValidChanges.map(\.id).filter(terminalChangeIDs.contains),
            rejectedChangeIDs: rejectedChangeIDs,
            applyResult: applyResult
        )
    }

    private static func hasValidPayload(_ change: SyncChange) -> Bool {
        do {
            switch change.entityType {
            case .collection:
                _ = try MyRAMSyncPayloadCoding.decodeFolder(from: change.payload)
            case .item:
                _ = try MyRAMSyncPayloadCoding.decodeNote(from: change.payload)
            case .marker:
                _ = try MyRAMSyncPayloadCoding.decodePinnedThought(from: change.payload)
            case .attachment:
                _ = try MyRAMSyncPayloadCoding.decodePhotoAttachment(from: change.payload)
            case .conflict:
                _ = try MyRAMSyncPayloadCoding.decodeSyncConflict(from: change.payload)
            }
            return true
        } catch {
            return false
        }
    }
}

final class FileBackedMacLegacyAppliedChangeStore: MacLegacyAppliedChangeStoring {
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var appliedIDs: Set<UUID>

    init(fileURL: URL = FileBackedMacLegacyAppliedChangeStore.defaultFileURL()) {
        self.fileURL = fileURL
        appliedIDs = (try? Self.loadIDs(from: fileURL, decoder: decoder)) ?? []
    }

    func contains(_ id: UUID) -> Bool {
        appliedIDs.contains(id)
    }

    func insert(_ ids: Set<UUID>) throws {
        guard !ids.isEmpty else { return }
        let replacement = appliedIDs.union(ids)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(Array(replacement))
        try data.write(to: fileURL, options: .atomic)
        appliedIDs = replacement
    }

    private static func loadIDs(from fileURL: URL, decoder: JSONDecoder) throws -> Set<UUID> {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return Set(try decoder.decode([UUID].self, from: data))
    }

    private static func defaultFileURL() -> URL {
        let supportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory

        return supportDirectory
            .appendingPathComponent("MyRAM", isDirectory: true)
            .appendingPathComponent("mac-legacy-applied-change-ids.json")
    }
}
#endif
