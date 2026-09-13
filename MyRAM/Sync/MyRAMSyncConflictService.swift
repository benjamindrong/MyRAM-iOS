import AnchoredSequenceCore
import CryptoKit
import Foundation
import NearbySyncCore
import SwiftData

struct SyncConflictRestoreResult {
    var conflicts: [SyncConflictVersion]
    var resolution: SyncTextConflictResolution
    var note: Note?
    var folder: Folder?
    var pinnedThought: PinnedThought?
    var shouldRefreshActiveNote = false
}

enum MyRAMSyncConflictResolutionError: Error, Equatable {
    case conflictUnavailable
    case duplicateResolution
    case staleStructuralConflict
    case modelSaveFailed
    case baselinePersistenceFailed
    case metadataPublicationFailed
    case terminalPersistenceFailed
}

enum SyncBootstrapStructuralConflictLifecycle: String, Codable, Equatable, Sendable {
    case preparing
    case active
    case resolvedLocalAuthority
    case terminallySuperseded
}

enum SyncBootstrapStructuralResolutionChoice: String, Codable, Equatable, Sendable {
    case acceptIncoming
    case keepLocal
    case merged
}

struct SyncBootstrapStructuralResolutionIntent: Codable, Equatable, Sendable {
    let choice: SyncBootstrapStructuralResolutionChoice
    let chosenFingerprint: String
    let rejectedFingerprint: String
    let preparedAt: Date
}

struct SyncBootstrapStructuralResolutionReceipt: Codable, Equatable, Sendable {
    let conflictID: UUID
    let noteID: UUID
    let choice: SyncBootstrapStructuralResolutionChoice
    let chosenFingerprint: String
    let rejectedFingerprint: String
    let resolvedAt: Date
}

struct SyncBootstrapStructuralConflictRecord: Codable, Equatable, Sendable {
    let conflictID: UUID
    let noteID: UUID
    var localText: String
    var localStructuralFingerprint: String
    let remoteText: String
    let remoteStatePayloadData: Data
    let remoteFormatVersion: Int
    let remoteRevision: UInt64
    let remoteVisibleUTF16Count: Int
    let remoteTombstonedUTF16Count: Int
    let remotePayloadByteCount: Int
    let remoteModifiedAt: Date
    let remoteStructuralFingerprint: String
    let bootstrapSnapshotID: UUID
    let preservedAt: Date
    var lifecycle: SyncBootstrapStructuralConflictLifecycle
    var visibleConflict: SyncConflictVersion?
    var pendingResolution: SyncBootstrapStructuralResolutionIntent?
}

private struct SyncBootstrapStructuralConflictEnvelope: Codable, Equatable, Sendable {
    static let supportedFormatVersion = 1

    let formatVersion: Int
    var records: [SyncBootstrapStructuralConflictRecord]
    var receipts: [SyncBootstrapStructuralResolutionReceipt]

    static let empty = Self(formatVersion: supportedFormatVersion, records: [], receipts: [])

    func validate() throws {
        guard formatVersion == Self.supportedFormatVersion else {
            throw SyncBootstrapStructuralConflictStoreError.unsupportedPersistenceVersion
        }
        var recordIDs: Set<UUID> = []
        for record in records {
            guard recordIDs.insert(record.conflictID).inserted,
                  record.conflictID.isBootstrapStructuralConflictID,
                  record.localStructuralFingerprint.isSHA256Hex,
                  record.remoteStructuralFingerprint.isSHA256Hex,
                  record.remotePayloadByteCount == record.remoteStatePayloadData.count else {
                throw SyncBootstrapStructuralConflictStoreError.contradictoryEvidence
            }
            if let visible = record.visibleConflict {
                guard visible.id == record.conflictID,
                      visible.entityType == .note,
                      visible.entityID == record.noteID,
                      visible.noteID == record.noteID,
                      visible.field == .noteContent,
                      visible.localText == record.localText,
                      visible.remoteText == record.remoteText,
                      visible.remoteModifiedAt == record.remoteModifiedAt else {
                    throw SyncBootstrapStructuralConflictStoreError.contradictoryEvidence
                }
            }
            switch record.lifecycle {
            case .preparing:
                break
            case .active, .resolvedLocalAuthority:
                guard record.visibleConflict != nil else {
                    throw SyncBootstrapStructuralConflictStoreError.contradictoryEvidence
                }
            case .terminallySuperseded:
                guard record.visibleConflict == nil,
                      record.pendingResolution == nil else {
                    throw SyncBootstrapStructuralConflictStoreError.contradictoryEvidence
                }
            }
            if let pending = record.pendingResolution {
                guard pending.chosenFingerprint.isSHA256Hex,
                      pending.rejectedFingerprint == record.remoteStructuralFingerprint else {
                    throw SyncBootstrapStructuralConflictStoreError.contradictoryEvidence
                }
            }
        }
        var receiptIDs: Set<UUID> = []
        for receipt in receipts {
            guard receiptIDs.insert(receipt.conflictID).inserted,
                  receipt.conflictID.isBootstrapStructuralConflictID,
                  receipt.chosenFingerprint.isSHA256Hex,
                  receipt.rejectedFingerprint.isSHA256Hex else {
                throw SyncBootstrapStructuralConflictStoreError.contradictoryReceipt
            }
        }
    }
}

struct SyncBootstrapStructuralConflictFileIO {
    var fileExists: (String) -> Bool
    var readData: (URL) throws -> Data
    var createDirectory: (URL) throws -> Void
    var writeData: (Data, URL) throws -> Void

    static let live = Self(
        fileExists: { FileManager.default.fileExists(atPath: $0) },
        readData: { try Data(contentsOf: $0) },
        createDirectory: {
            try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true)
        },
        writeData: { data, url in try data.write(to: url, options: [.atomic]) }
    )
}

enum SyncBootstrapStructuralConflictStoreError: Error, Equatable {
    case unsupportedPersistenceVersion
    case persistenceUnavailable
    case contradictoryEvidence
    case contradictoryReceipt
    case missingStructuralConflict
    case staleStructuralConflict
    case invalidRemoteState
    case visibleConflictPersistenceFailed
}

extension SyncConflictStore {
    static func defaultBootstrapStructuralConflictFileURL() -> URL {
        let supportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return supportDirectory
            .appendingPathComponent("MyRAM", isDirectory: true)
            .appendingPathComponent("sync-bootstrap-structural-conflicts.json")
    }

    static func bootstrapStructuralFingerprint(
        noteID: UUID,
        state: SyncTextSequenceState
    ) throws -> String {
        let stateBytes = try NoteSequenceStatePersistenceCodec.encode(state: state, noteID: noteID)
        var bytes = Data("myram.bootstrap-structural-state.v1".utf8)
        bytes.append(0)
        bytes.append(Data(noteID.uuidString.lowercased().utf8))
        bytes.append(0)
        bytes.append(stateBytes)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    func materializeBootstrapStructuralConflictChecked(
        noteID: UUID,
        localText: String,
        localState: SyncTextSequenceState,
        remoteSnapshot: SyncPeerBootstrapNoteSnapshot,
        bootstrapSnapshotID: UUID,
        sidecarFileURL: URL = SyncConflictStore.defaultBootstrapStructuralConflictFileURL(),
        fileIO: SyncBootstrapStructuralConflictFileIO = .live,
        now: Date = Date()
    ) throws -> SyncConflictVersion {
        guard remoteSnapshot.id == noteID,
              NoteSequenceStateExactText.matches(localState.visibleText, localText) else {
            throw SyncBootstrapStructuralConflictStoreError.contradictoryEvidence
        }
        let remoteState = try validatedBootstrapStructuralRemoteState(remoteSnapshot)
        let localFingerprint = try Self.bootstrapStructuralFingerprint(noteID: noteID, state: localState)
        let remoteFingerprint = try Self.bootstrapStructuralFingerprint(noteID: noteID, state: remoteState)

        var envelope = try loadBootstrapStructuralEnvelopeChecked(
            fileURL: sidecarFileURL,
            fileIO: fileIO
        )

        if let resolvedIndex = envelope.records.firstIndex(where: {
            $0.noteID == noteID
                && $0.lifecycle == .resolvedLocalAuthority
                && $0.localStructuralFingerprint == localFingerprint
                && $0.remoteStructuralFingerprint == remoteFingerprint
        }) {
            let record = envelope.records[resolvedIndex]
            let visible = try ensureBootstrapStructuralVisibleConflictChecked(record)
            return visible
        }

        let conflictID = try Self.bootstrapStructuralConflictID(
            noteID: noteID,
            localFingerprint: localFingerprint,
            remoteFingerprint: remoteFingerprint
        )
        let visibleConflict = SyncConflictVersion(
            id: conflictID,
            entityType: .note,
            entityID: noteID,
            noteID: noteID,
            field: .noteContent,
            localText: localText,
            remoteText: remoteSnapshot.body,
            remoteModifiedAt: remoteSnapshot.modifiedAt,
            preservedAt: now,
            expiresAt: .distantFuture
        )

        if let existingIndex = envelope.records.firstIndex(where: { $0.conflictID == conflictID }) {
            let existing = envelope.records[existingIndex]
            guard existing.noteID == noteID,
                  existing.localText == localText,
                  existing.localStructuralFingerprint == localFingerprint,
                  existing.remoteText == remoteSnapshot.body,
                  existing.remoteStatePayloadData == remoteSnapshot.statePayloadData,
                  existing.remoteFormatVersion == remoteSnapshot.formatVersion,
                  existing.remoteRevision == remoteSnapshot.revision,
                  existing.remoteVisibleUTF16Count == remoteSnapshot.visibleUTF16Count,
                  existing.remoteTombstonedUTF16Count == remoteSnapshot.tombstonedUTF16Count,
                  existing.remotePayloadByteCount == remoteSnapshot.payloadByteCount,
                  existing.remoteModifiedAt == remoteSnapshot.modifiedAt,
                  existing.remoteStructuralFingerprint == remoteFingerprint else {
                throw SyncBootstrapStructuralConflictStoreError.contradictoryEvidence
            }
            if existing.lifecycle == .terminallySuperseded {
                throw SyncBootstrapStructuralConflictStoreError.contradictoryEvidence
            }
            if existing.lifecycle == .active || existing.lifecycle == .resolvedLocalAuthority {
                return try ensureBootstrapStructuralVisibleConflictChecked(existing)
            }
            if existing.visibleConflict == nil {
                envelope.records[existingIndex].visibleConflict = visibleConflict
                try saveBootstrapStructuralEnvelopeChecked(
                    envelope,
                    fileURL: sidecarFileURL,
                    fileIO: fileIO
                )
                envelope = try loadBootstrapStructuralEnvelopeChecked(
                    fileURL: sidecarFileURL,
                    fileIO: fileIO
                )
            }
        } else {
            envelope.records.append(SyncBootstrapStructuralConflictRecord(
                conflictID: conflictID,
                noteID: noteID,
                localText: localText,
                localStructuralFingerprint: localFingerprint,
                remoteText: remoteSnapshot.body,
                remoteStatePayloadData: remoteSnapshot.statePayloadData,
                remoteFormatVersion: remoteSnapshot.formatVersion,
                remoteRevision: remoteSnapshot.revision,
                remoteVisibleUTF16Count: remoteSnapshot.visibleUTF16Count,
                remoteTombstonedUTF16Count: remoteSnapshot.tombstonedUTF16Count,
                remotePayloadByteCount: remoteSnapshot.payloadByteCount,
                remoteModifiedAt: remoteSnapshot.modifiedAt,
                remoteStructuralFingerprint: remoteFingerprint,
                bootstrapSnapshotID: bootstrapSnapshotID,
                preservedAt: now,
                lifecycle: .preparing,
                visibleConflict: visibleConflict,
                pendingResolution: nil
            ))
            try saveBootstrapStructuralEnvelopeChecked(
                envelope,
                fileURL: sidecarFileURL,
                fileIO: fileIO
            )
            envelope = try loadBootstrapStructuralEnvelopeChecked(
                fileURL: sidecarFileURL,
                fileIO: fileIO
            )
        }

        guard let preparingIndex = envelope.records.firstIndex(where: { $0.conflictID == conflictID }),
              envelope.records[preparingIndex].lifecycle == .preparing,
              envelope.records[preparingIndex].visibleConflict == visibleConflict else {
            throw SyncBootstrapStructuralConflictStoreError.contradictoryEvidence
        }

        do {
            try commitLegacyIncomingEffectsChecked(LegacyIncomingBufferedEffects(
                preservedConflicts: [visibleConflict]
            ))
        } catch {
            throw SyncBootstrapStructuralConflictStoreError.visibleConflictPersistenceFailed
        }
        guard activeConflict(id: conflictID) == visibleConflict else {
            throw SyncBootstrapStructuralConflictStoreError.visibleConflictPersistenceFailed
        }

        envelope.records[preparingIndex].lifecycle = .active
        try saveBootstrapStructuralEnvelopeChecked(
            envelope,
            fileURL: sidecarFileURL,
            fileIO: fileIO
        )
        let verified = try loadBootstrapStructuralEnvelopeChecked(
            fileURL: sidecarFileURL,
            fileIO: fileIO
        )
        guard let active = verified.records.first(where: { $0.conflictID == conflictID }),
              active.lifecycle == .active,
              active.visibleConflict == visibleConflict,
              activeConflict(id: conflictID) == visibleConflict else {
            throw SyncBootstrapStructuralConflictStoreError.contradictoryEvidence
        }
        return visibleConflict
    }

    func bootstrapStructuralConflictRecordChecked(
        id: UUID,
        sidecarFileURL: URL = SyncConflictStore.defaultBootstrapStructuralConflictFileURL(),
        fileIO: SyncBootstrapStructuralConflictFileIO = .live
    ) throws -> SyncBootstrapStructuralConflictRecord? {
        guard id.isBootstrapStructuralConflictID else { return nil }
        return try loadBootstrapStructuralEnvelopeChecked(
            fileURL: sidecarFileURL,
            fileIO: fileIO
        ).records.first { $0.conflictID == id }
    }

    func validatedBootstrapStructuralRemoteState(
        _ record: SyncBootstrapStructuralConflictRecord
    ) throws -> SyncTextSequenceState {
        let snapshot = SyncPeerBootstrapNoteSnapshot(
            id: record.noteID,
            title: "",
            body: record.remoteText,
            isPinned: false,
            createdAt: .distantPast,
            modifiedAt: record.remoteModifiedAt,
            deletedAt: nil,
            folderID: nil,
            formatVersion: record.remoteFormatVersion,
            revision: record.remoteRevision,
            visibleUTF16Count: record.remoteVisibleUTF16Count,
            tombstonedUTF16Count: record.remoteTombstonedUTF16Count,
            payloadByteCount: record.remotePayloadByteCount,
            statePayloadData: record.remoteStatePayloadData
        )
        let state = try validatedBootstrapStructuralRemoteState(snapshot)
        guard try Self.bootstrapStructuralFingerprint(noteID: record.noteID, state: state)
            == record.remoteStructuralFingerprint else {
            throw SyncBootstrapStructuralConflictStoreError.invalidRemoteState
        }
        return state
    }

    func prepareBootstrapStructuralResolutionChecked(
        conflictID: UUID,
        choice: SyncBootstrapStructuralResolutionChoice,
        chosenFingerprint: String,
        sidecarFileURL: URL = SyncConflictStore.defaultBootstrapStructuralConflictFileURL(),
        fileIO: SyncBootstrapStructuralConflictFileIO = .live,
        now: Date = Date()
    ) throws {
        var envelope = try loadBootstrapStructuralEnvelopeChecked(fileURL: sidecarFileURL, fileIO: fileIO)
        guard let index = envelope.records.firstIndex(where: { $0.conflictID == conflictID }) else {
            throw SyncBootstrapStructuralConflictStoreError.missingStructuralConflict
        }
        let record = envelope.records[index]
        guard record.lifecycle == .active || record.lifecycle == .resolvedLocalAuthority,
              record.visibleConflict != nil,
              chosenFingerprint.isSHA256Hex else {
            throw SyncBootstrapStructuralConflictStoreError.contradictoryEvidence
        }
        let intent = SyncBootstrapStructuralResolutionIntent(
            choice: choice,
            chosenFingerprint: chosenFingerprint,
            rejectedFingerprint: record.remoteStructuralFingerprint,
            preparedAt: now
        )
        if let existing = record.pendingResolution, existing != intent {
            throw SyncBootstrapStructuralConflictStoreError.contradictoryReceipt
        }
        envelope.records[index].pendingResolution = intent
        try saveBootstrapStructuralEnvelopeChecked(envelope, fileURL: sidecarFileURL, fileIO: fileIO)
    }

    func finalizeBootstrapStructuralLocalAuthorityChecked(
        conflictID: UUID,
        chosenText: String,
        chosenFingerprint: String,
        choice: SyncBootstrapStructuralResolutionChoice,
        sidecarFileURL: URL = SyncConflictStore.defaultBootstrapStructuralConflictFileURL(),
        fileIO: SyncBootstrapStructuralConflictFileIO = .live,
        now: Date = Date()
    ) throws {
        guard choice == .keepLocal || choice == .merged else {
            throw SyncBootstrapStructuralConflictStoreError.contradictoryReceipt
        }
        var envelope = try loadBootstrapStructuralEnvelopeChecked(fileURL: sidecarFileURL, fileIO: fileIO)
        guard let index = envelope.records.firstIndex(where: { $0.conflictID == conflictID }) else {
            throw SyncBootstrapStructuralConflictStoreError.missingStructuralConflict
        }
        let record = envelope.records[index]
        guard let pending = record.pendingResolution,
              pending.choice == choice,
              pending.chosenFingerprint == chosenFingerprint,
              pending.rejectedFingerprint == record.remoteStructuralFingerprint else {
            throw SyncBootstrapStructuralConflictStoreError.contradictoryReceipt
        }
        let updatedVisible = SyncConflictVersion(
            id: record.conflictID,
            entityType: .note,
            entityID: record.noteID,
            noteID: record.noteID,
            field: .noteContent,
            localText: chosenText,
            remoteText: record.remoteText,
            remoteModifiedAt: record.remoteModifiedAt,
            preservedAt: record.preservedAt,
            expiresAt: .distantFuture
        )
        upsertBootstrapStructuralReceipt(
            SyncBootstrapStructuralResolutionReceipt(
                conflictID: conflictID,
                noteID: record.noteID,
                choice: choice,
                chosenFingerprint: chosenFingerprint,
                rejectedFingerprint: record.remoteStructuralFingerprint,
                resolvedAt: now
            ),
            in: &envelope
        )
        envelope.records[index].localText = chosenText
        envelope.records[index].localStructuralFingerprint = chosenFingerprint
        envelope.records[index].lifecycle = .resolvedLocalAuthority
        envelope.records[index].visibleConflict = updatedVisible
        envelope.records[index].pendingResolution = nil
        try saveBootstrapStructuralEnvelopeChecked(envelope, fileURL: sidecarFileURL, fileIO: fileIO)

        do {
            try commitLegacyIncomingEffectsChecked(LegacyIncomingBufferedEffects(
                preservedConflicts: [updatedVisible],
                removedConflictIDs: [conflictID]
            ))
        } catch {
            throw SyncBootstrapStructuralConflictStoreError.visibleConflictPersistenceFailed
        }
        guard activeConflict(id: conflictID) == updatedVisible else {
            throw SyncBootstrapStructuralConflictStoreError.visibleConflictPersistenceFailed
        }
    }

    func finalizeBootstrapStructuralAcceptIncomingChecked(
        conflictID: UUID,
        chosenFingerprint: String,
        sidecarFileURL: URL = SyncConflictStore.defaultBootstrapStructuralConflictFileURL(),
        fileIO: SyncBootstrapStructuralConflictFileIO = .live,
        now: Date = Date()
    ) throws {
        var envelope = try loadBootstrapStructuralEnvelopeChecked(fileURL: sidecarFileURL, fileIO: fileIO)
        guard let index = envelope.records.firstIndex(where: { $0.conflictID == conflictID }) else {
            throw SyncBootstrapStructuralConflictStoreError.missingStructuralConflict
        }
        let record = envelope.records[index]
        guard let pending = record.pendingResolution,
              pending.choice == .acceptIncoming,
              pending.chosenFingerprint == chosenFingerprint,
              chosenFingerprint == record.remoteStructuralFingerprint else {
            throw SyncBootstrapStructuralConflictStoreError.contradictoryReceipt
        }
        upsertBootstrapStructuralReceipt(
            SyncBootstrapStructuralResolutionReceipt(
                conflictID: conflictID,
                noteID: record.noteID,
                choice: .acceptIncoming,
                chosenFingerprint: chosenFingerprint,
                rejectedFingerprint: record.localStructuralFingerprint,
                resolvedAt: now
            ),
            in: &envelope
        )
        try saveBootstrapStructuralEnvelopeChecked(envelope, fileURL: sidecarFileURL, fileIO: fileIO)

        if let visible = record.visibleConflict {
            do {
                try commitLegacyIncomingEffectsChecked(LegacyIncomingBufferedEffects(
                    removedResolvedConflicts: [visible]
                ))
            } catch {
                throw SyncBootstrapStructuralConflictStoreError.visibleConflictPersistenceFailed
            }
        }

        var terminal = try loadBootstrapStructuralEnvelopeChecked(fileURL: sidecarFileURL, fileIO: fileIO)
        guard let terminalIndex = terminal.records.firstIndex(where: { $0.conflictID == conflictID }) else {
            throw SyncBootstrapStructuralConflictStoreError.missingStructuralConflict
        }
        terminal.records[terminalIndex].lifecycle = .terminallySuperseded
        terminal.records[terminalIndex].visibleConflict = nil
        terminal.records[terminalIndex].pendingResolution = nil
        try saveBootstrapStructuralEnvelopeChecked(terminal, fileURL: sidecarFileURL, fileIO: fileIO)
    }

    func terminalizeBootstrapStructuralConflictIfPeerAdoptedChecked(
        noteID: UUID,
        adoptedFingerprint: String,
        sidecarFileURL: URL = SyncConflictStore.defaultBootstrapStructuralConflictFileURL(),
        fileIO: SyncBootstrapStructuralConflictFileIO = .live
    ) throws {
        var envelope = try loadBootstrapStructuralEnvelopeChecked(fileURL: sidecarFileURL, fileIO: fileIO)
        let indices = envelope.records.indices.filter {
            envelope.records[$0].noteID == noteID
                && envelope.records[$0].lifecycle == .resolvedLocalAuthority
                && envelope.records[$0].localStructuralFingerprint == adoptedFingerprint
        }
        guard !indices.isEmpty else { return }
        for index in indices {
            let record = envelope.records[index]
            guard let receipt = envelope.receipts.first(where: { $0.conflictID == record.conflictID }),
                  receipt.chosenFingerprint == adoptedFingerprint else {
                throw SyncBootstrapStructuralConflictStoreError.contradictoryReceipt
            }
            if let visible = record.visibleConflict {
                do {
                    try commitLegacyIncomingEffectsChecked(LegacyIncomingBufferedEffects(
                        removedResolvedConflicts: [visible]
                    ))
                } catch {
                    throw SyncBootstrapStructuralConflictStoreError.visibleConflictPersistenceFailed
                }
            }
            envelope.records[index].lifecycle = .terminallySuperseded
            envelope.records[index].visibleConflict = nil
            envelope.records[index].pendingResolution = nil
        }
        try saveBootstrapStructuralEnvelopeChecked(envelope, fileURL: sidecarFileURL, fileIO: fileIO)
    }

    func bootstrapStructuralResolutionReceiptChecked(
        conflictID: UUID,
        sidecarFileURL: URL = SyncConflictStore.defaultBootstrapStructuralConflictFileURL(),
        fileIO: SyncBootstrapStructuralConflictFileIO = .live
    ) throws -> SyncBootstrapStructuralResolutionReceipt? {
        try loadBootstrapStructuralEnvelopeChecked(fileURL: sidecarFileURL, fileIO: fileIO)
            .receipts.first { $0.conflictID == conflictID }
    }

    private func ensureBootstrapStructuralVisibleConflictChecked(
        _ record: SyncBootstrapStructuralConflictRecord
    ) throws -> SyncConflictVersion {
        guard let visible = record.visibleConflict else {
            throw SyncBootstrapStructuralConflictStoreError.contradictoryEvidence
        }
        if activeConflict(id: record.conflictID) != visible {
            do {
                try commitLegacyIncomingEffectsChecked(LegacyIncomingBufferedEffects(
                    preservedConflicts: [visible]
                ))
            } catch {
                throw SyncBootstrapStructuralConflictStoreError.visibleConflictPersistenceFailed
            }
        }
        guard activeConflict(id: record.conflictID) == visible else {
            throw SyncBootstrapStructuralConflictStoreError.visibleConflictPersistenceFailed
        }
        return visible
    }

    private func validatedBootstrapStructuralRemoteState(
        _ snapshot: SyncPeerBootstrapNoteSnapshot
    ) throws -> SyncTextSequenceState {
        let record = NoteSequenceStateRecord(
            noteID: snapshot.id,
            formatVersion: snapshot.formatVersion,
            revision: snapshot.revision,
            visibleUTF16Count: snapshot.visibleUTF16Count,
            tombstonedUTF16Count: snapshot.tombstonedUTF16Count,
            payloadByteCount: snapshot.payloadByteCount,
            statePayloadData: snapshot.statePayloadData
        )
        do {
            let state = try NoteSequenceStatePersistenceCodec.decodeStructurallyValidatedState(
                record: record,
                noteID: snapshot.id
            )
            guard NoteSequenceStateExactText.matches(state.visibleText, snapshot.body) else {
                throw SyncBootstrapStructuralConflictStoreError.invalidRemoteState
            }
            return state
        } catch let error as SyncBootstrapStructuralConflictStoreError {
            throw error
        } catch {
            throw SyncBootstrapStructuralConflictStoreError.invalidRemoteState
        }
    }

    private static func bootstrapStructuralConflictID(
        noteID: UUID,
        localFingerprint: String,
        remoteFingerprint: String
    ) throws -> UUID {
        guard localFingerprint.isSHA256Hex, remoteFingerprint.isSHA256Hex else {
            throw SyncBootstrapStructuralConflictStoreError.contradictoryEvidence
        }
        var data = Data("myram.bootstrap-structural-conflict.id.v1".utf8)
        data.append(0)
        data.append(Data(noteID.uuidString.lowercased().utf8))
        data.append(0)
        data.append(Data(localFingerprint.utf8))
        data.append(0)
        data.append(Data(remoteFingerprint.utf8))
        var bytes = Array(SHA256.hash(data: data).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x90
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let value = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20).prefix(12))"
        guard let uuid = UUID(uuidString: value), uuid.isBootstrapStructuralConflictID else {
            throw SyncBootstrapStructuralConflictStoreError.contradictoryEvidence
        }
        return uuid
    }

    private func loadBootstrapStructuralEnvelopeChecked(
        fileURL: URL,
        fileIO: SyncBootstrapStructuralConflictFileIO
    ) throws -> SyncBootstrapStructuralConflictEnvelope {
        guard fileIO.fileExists(fileURL.path) else { return .empty }
        do {
            let envelope = try JSONDecoder().decode(
                SyncBootstrapStructuralConflictEnvelope.self,
                from: fileIO.readData(fileURL)
            )
            try envelope.validate()
            return envelope
        } catch let error as SyncBootstrapStructuralConflictStoreError {
            throw error
        } catch {
            throw SyncBootstrapStructuralConflictStoreError.persistenceUnavailable
        }
    }

    private func saveBootstrapStructuralEnvelopeChecked(
        _ envelope: SyncBootstrapStructuralConflictEnvelope,
        fileURL: URL,
        fileIO: SyncBootstrapStructuralConflictFileIO
    ) throws {
        try envelope.validate()
        do {
            try fileIO.createDirectory(fileURL.deletingLastPathComponent())
            try fileIO.writeData(try JSONEncoder().encode(envelope), fileURL)
            let persisted = try JSONDecoder().decode(
                SyncBootstrapStructuralConflictEnvelope.self,
                from: fileIO.readData(fileURL)
            )
            try persisted.validate()
            guard persisted == envelope else {
                throw SyncBootstrapStructuralConflictStoreError.persistenceUnavailable
            }
        } catch let error as SyncBootstrapStructuralConflictStoreError {
            throw error
        } catch {
            throw SyncBootstrapStructuralConflictStoreError.persistenceUnavailable
        }
    }

    private func upsertBootstrapStructuralReceipt(
        _ receipt: SyncBootstrapStructuralResolutionReceipt,
        in envelope: inout SyncBootstrapStructuralConflictEnvelope
    ) {
        if let index = envelope.receipts.firstIndex(where: { $0.conflictID == receipt.conflictID }) {
            envelope.receipts[index] = receipt
        } else {
            envelope.receipts.append(receipt)
        }
    }
}

private extension String {
    var isSHA256Hex: Bool {
        count == 64 && allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}

private extension UUID {
    var isBootstrapStructuralConflictID: Bool {
        let components = uuidString.split(separator: "-")
        guard components.count == 5, let versionCharacter = components[2].first else { return false }
        return versionCharacter == "9"
    }
}

@MainActor
final class MyRAMSyncConflictService {
    private enum BootstrapStructuralAction {
        case keepLocal
        case acceptIncoming
        case merged(String)
    }

    private let context: ModelContext
    private let store: SyncConflictStore
    private let saveOperation: (ModelContext) throws -> Void
    private let bootstrapStructuralConflictFileURL: URL
    private let bootstrapStructuralConflictFileIO: SyncBootstrapStructuralConflictFileIO
    private var resolvingConflictIDs: Set<UUID> = []

    init(
        context: ModelContext,
        store: SyncConflictStore,
        bootstrapStructuralConflictFileURL: URL = SyncConflictStore.defaultBootstrapStructuralConflictFileURL(),
        bootstrapStructuralConflictFileIO: SyncBootstrapStructuralConflictFileIO = .live,
        saveOperation: @escaping (ModelContext) throws -> Void = { try $0.save() }
    ) {
        self.context = context
        self.store = store
        self.bootstrapStructuralConflictFileURL = bootstrapStructuralConflictFileURL
        self.bootstrapStructuralConflictFileIO = bootstrapStructuralConflictFileIO
        self.saveOperation = saveOperation
    }

    func activeConflicts() -> [SyncConflictVersion] {
        store.activeConflicts()
    }

    func activeConflicts(for note: Note, in _: [SyncConflictVersion]) -> [SyncConflictVersion] {
        store.activeConflicts().filter { conflict in
            conflict.noteID == note.id || (conflict.entityType == .note && conflict.entityID == note.id)
        }
    }

    func keepLocal(_ conflict: SyncConflictVersion, activeNoteID: UUID?) -> SyncConflictRestoreResult? {
        resolve(
            conflict,
            choice: .keepLocal(
                currentLocalText: currentText(for: conflict),
                currentLocalData: currentData(for: conflict)
            ),
            activeNoteID: activeNoteID
        )
    }

    func acceptIncoming(_ conflict: SyncConflictVersion, activeNoteID: UUID?) -> SyncConflictRestoreResult? {
        resolve(conflict, choice: .acceptIncoming, activeNoteID: activeNoteID)
    }

    func saveMergedText(
        _ conflict: SyncConflictVersion,
        text: String,
        activeNoteID: UUID?
    ) -> SyncConflictRestoreResult? {
        resolve(
            conflict,
            choice: .merged(text: text, data: nil),
            activeNoteID: activeNoteID
        )
    }

    func keepLocalChecked(
        _ conflict: SyncConflictVersion,
        activeNoteID: UUID?,
        publishResolution: ((MyRAMSyncConflictPayload) async throws -> Void)? = nil
    ) async throws -> SyncConflictRestoreResult {
        if try store.bootstrapStructuralConflictRecordChecked(
            id: conflict.id,
            sidecarFileURL: bootstrapStructuralConflictFileURL,
            fileIO: bootstrapStructuralConflictFileIO
        ) != nil {
            return try await resolveBootstrapStructuralChecked(
                conflict,
                action: .keepLocal,
                activeNoteID: activeNoteID
            )
        }
        return try await resolveChecked(
            conflict,
            choice: .keepLocal(
                currentLocalText: currentText(for: conflict),
                currentLocalData: currentData(for: conflict)
            ),
            activeNoteID: activeNoteID,
            publishResolution: publishResolution
        )
    }

    func acceptIncomingChecked(
        _ conflict: SyncConflictVersion,
        activeNoteID: UUID?,
        publishResolution: ((MyRAMSyncConflictPayload) async throws -> Void)? = nil
    ) async throws -> SyncConflictRestoreResult {
        if try store.bootstrapStructuralConflictRecordChecked(
            id: conflict.id,
            sidecarFileURL: bootstrapStructuralConflictFileURL,
            fileIO: bootstrapStructuralConflictFileIO
        ) != nil {
            return try await resolveBootstrapStructuralChecked(
                conflict,
                action: .acceptIncoming,
                activeNoteID: activeNoteID
            )
        }
        return try await resolveChecked(
            conflict,
            choice: .acceptIncoming,
            activeNoteID: activeNoteID,
            publishResolution: publishResolution
        )
    }

    func saveMergedTextChecked(
        _ conflict: SyncConflictVersion,
        text: String,
        activeNoteID: UUID?,
        publishResolution: ((MyRAMSyncConflictPayload) async throws -> Void)? = nil
    ) async throws -> SyncConflictRestoreResult {
        if try store.bootstrapStructuralConflictRecordChecked(
            id: conflict.id,
            sidecarFileURL: bootstrapStructuralConflictFileURL,
            fileIO: bootstrapStructuralConflictFileIO
        ) != nil {
            return try await resolveBootstrapStructuralChecked(
                conflict,
                action: .merged(text),
                activeNoteID: activeNoteID
            )
        }
        return try await resolveChecked(
            conflict,
            choice: .merged(text: text, data: nil),
            activeNoteID: activeNoteID,
            publishResolution: publishResolution
        )
    }

    private func resolveBootstrapStructuralChecked(
        _ conflict: SyncConflictVersion,
        action: BootstrapStructuralAction,
        activeNoteID: UUID?
    ) async throws -> SyncConflictRestoreResult {
        guard resolvingConflictIDs.insert(conflict.id).inserted else {
            throw MyRAMSyncConflictResolutionError.duplicateResolution
        }
        defer { resolvingConflictIDs.remove(conflict.id) }
        guard store.activeConflict(id: conflict.id) == conflict,
              let record = try store.bootstrapStructuralConflictRecordChecked(
                id: conflict.id,
                sidecarFileURL: bootstrapStructuralConflictFileURL,
                fileIO: bootstrapStructuralConflictFileIO
              ),
              record.lifecycle == .active || record.lifecycle == .resolvedLocalAuthority,
              record.visibleConflict == conflict,
              let note = fetchNote(withID: conflict.entityID) else {
            throw MyRAMSyncConflictResolutionError.conflictUnavailable
        }

        let current = try NoteSequenceStateFullBodyIntegration.loadMutationSnapshot(for: note, in: context)
        let currentFingerprint = try SyncConflictStore.bootstrapStructuralFingerprint(
            noteID: note.id,
            state: current.state
        )
        let resolutionChoice: SyncTextConflictResolutionChoice
        let now = Date()

        switch action {
        case .keepLocal:
            guard currentFingerprint == record.localStructuralFingerprint else {
                throw MyRAMSyncConflictResolutionError.staleStructuralConflict
            }
            try store.prepareBootstrapStructuralResolutionChecked(
                conflictID: conflict.id,
                choice: .keepLocal,
                chosenFingerprint: currentFingerprint,
                sidecarFileURL: bootstrapStructuralConflictFileURL,
                fileIO: bootstrapStructuralConflictFileIO,
                now: now
            )
            try store.finalizeBootstrapStructuralLocalAuthorityChecked(
                conflictID: conflict.id,
                chosenText: note.content,
                chosenFingerprint: currentFingerprint,
                choice: .keepLocal,
                sidecarFileURL: bootstrapStructuralConflictFileURL,
                fileIO: bootstrapStructuralConflictFileIO,
                now: now
            )
            resolutionChoice = .keepLocal(
                currentLocalText: note.content,
                currentLocalData: note.richTextContentData
            )

        case .acceptIncoming:
            let remoteState = try store.validatedBootstrapStructuralRemoteState(record)
            if currentFingerprint != record.remoteStructuralFingerprint {
                guard currentFingerprint == record.localStructuralFingerprint else {
                    throw MyRAMSyncConflictResolutionError.staleStructuralConflict
                }
                try store.prepareBootstrapStructuralResolutionChecked(
                    conflictID: conflict.id,
                    choice: .acceptIncoming,
                    chosenFingerprint: record.remoteStructuralFingerprint,
                    sidecarFileURL: bootstrapStructuralConflictFileURL,
                    fileIO: bootstrapStructuralConflictFileIO,
                    now: now
                )
                _ = try NoteSequenceStateFullBodyIntegration.stageSuppliedStateMutation(
                    of: note,
                    expected: current,
                    newBody: record.remoteText,
                    finalState: remoteState,
                    in: context
                )
                note.richTextContentData = nil
                note.modifiedAt = record.remoteModifiedAt
                do {
                    try saveOperation(context)
                } catch {
                    context.rollback()
                    throw MyRAMSyncConflictResolutionError.modelSaveFailed
                }
            }
            let committed = try NoteSequenceStateFullBodyIntegration.loadMutationSnapshot(for: note, in: context)
            let committedFingerprint = try SyncConflictStore.bootstrapStructuralFingerprint(
                noteID: note.id,
                state: committed.state
            )
            guard committedFingerprint == record.remoteStructuralFingerprint,
                  NoteSequenceStateExactText.matches(note.content, record.remoteText) else {
                throw MyRAMSyncConflictResolutionError.modelSaveFailed
            }
            if record.pendingResolution == nil {
                try store.prepareBootstrapStructuralResolutionChecked(
                    conflictID: conflict.id,
                    choice: .acceptIncoming,
                    chosenFingerprint: committedFingerprint,
                    sidecarFileURL: bootstrapStructuralConflictFileURL,
                    fileIO: bootstrapStructuralConflictFileIO,
                    now: now
                )
            }
            try store.finalizeBootstrapStructuralAcceptIncomingChecked(
                conflictID: conflict.id,
                chosenFingerprint: committedFingerprint,
                sidecarFileURL: bootstrapStructuralConflictFileURL,
                fileIO: bootstrapStructuralConflictFileIO,
                now: now
            )
            resolutionChoice = .acceptIncoming

        case .merged(let text):
            guard currentFingerprint == record.localStructuralFingerprint else {
                if let pending = record.pendingResolution,
                   pending.choice == .merged,
                   currentFingerprint == pending.chosenFingerprint,
                   NoteSequenceStateExactText.matches(note.content, text) {
                    try store.finalizeBootstrapStructuralLocalAuthorityChecked(
                        conflictID: conflict.id,
                        chosenText: text,
                        chosenFingerprint: currentFingerprint,
                        choice: .merged,
                        sidecarFileURL: bootstrapStructuralConflictFileURL,
                        fileIO: bootstrapStructuralConflictFileIO,
                        now: now
                    )
                    resolutionChoice = .merged(text: text, data: nil)
                    break
                }
                throw MyRAMSyncConflictResolutionError.staleStructuralConflict
            }
            _ = try NoteSequenceStateFullBodyIntegration.replaceBody(
                of: note,
                with: text,
                in: context
            )
            note.richTextContentData = nil
            note.modifiedAt = now
            let staged = try NoteSequenceStateFullBodyIntegration.loadMutationSnapshot(for: note, in: context)
            let stagedFingerprint = try SyncConflictStore.bootstrapStructuralFingerprint(
                noteID: note.id,
                state: staged.state
            )
            try store.prepareBootstrapStructuralResolutionChecked(
                conflictID: conflict.id,
                choice: .merged,
                chosenFingerprint: stagedFingerprint,
                sidecarFileURL: bootstrapStructuralConflictFileURL,
                fileIO: bootstrapStructuralConflictFileIO,
                now: now
            )
            do {
                try saveOperation(context)
            } catch {
                context.rollback()
                throw MyRAMSyncConflictResolutionError.modelSaveFailed
            }
            try store.finalizeBootstrapStructuralLocalAuthorityChecked(
                conflictID: conflict.id,
                chosenText: text,
                chosenFingerprint: stagedFingerprint,
                choice: .merged,
                sidecarFileURL: bootstrapStructuralConflictFileURL,
                fileIO: bootstrapStructuralConflictFileIO,
                now: now
            )
            resolutionChoice = .merged(text: text, data: nil)
        }

        let resolution = SyncTextConflictResolver.resolve(
            conflict.syncTextConflict,
            choice: resolutionChoice
        )
        return SyncConflictRestoreResult(
            conflicts: store.activeConflicts(),
            resolution: resolution,
            note: note,
            folder: note.folder,
            pinnedThought: nil,
            shouldRefreshActiveNote: activeNoteID == note.id
        )
    }

    private func resolveChecked(
        _ conflict: SyncConflictVersion,
        choice: SyncTextConflictResolutionChoice,
        activeNoteID: UUID?,
        publishResolution: ((MyRAMSyncConflictPayload) async throws -> Void)?
    ) async throws -> SyncConflictRestoreResult {
        guard resolvingConflictIDs.insert(conflict.id).inserted else {
            throw MyRAMSyncConflictResolutionError.duplicateResolution
        }
        defer { resolvingConflictIDs.remove(conflict.id) }
        guard store.activeConflict(id: conflict.id) == conflict else {
            throw MyRAMSyncConflictResolutionError.conflictUnavailable
        }

        let now = Date()
        let resolution = SyncTextConflictResolver.resolve(conflict.syncTextConflict, choice: choice)
        var result = SyncConflictRestoreResult(conflicts: store.activeConflicts(), resolution: resolution)
        do {
            switch conflict.field {
            case .noteTitle:
                guard let note = fetchNote(withID: conflict.entityID) else {
                    throw MyRAMSyncConflictResolutionError.conflictUnavailable
                }
                note.title = resolution.resolvedText
                note.modifiedAt = now
                result.note = note
                result.folder = note.folder
                result.shouldRefreshActiveNote = activeNoteID == note.id
            case .noteContent:
                guard let note = fetchNote(withID: conflict.entityID) else {
                    throw MyRAMSyncConflictResolutionError.conflictUnavailable
                }
                let previousContent = note.content
                let resolvedRichTextData: Data?
                if resolution.usesRemoteData {
                    resolvedRichTextData = sanitizedConflictRichTextData(
                        resolution.resolvedData,
                        plainText: resolution.resolvedText
                    )
                } else if previousContent != resolution.resolvedText {
                    resolvedRichTextData = resolution.resolvedData
                        ?? sanitizedConflictRichTextData(
                            note.richTextContentData,
                            plainText: resolution.resolvedText
                        )
                } else {
                    resolvedRichTextData = note.richTextContentData
                }
                _ = try NoteSequenceStateFullBodyIntegration.replaceBody(
                    of: note,
                    with: resolution.resolvedText,
                    in: context
                )
                note.richTextContentData = resolvedRichTextData
                note.modifiedAt = now
                result.note = note
                result.folder = note.folder
                result.shouldRefreshActiveNote = activeNoteID == note.id
            case .folderTitle:
                guard let folder = fetchFolder(withID: conflict.entityID) else {
                    throw MyRAMSyncConflictResolutionError.conflictUnavailable
                }
                folder.name = resolution.resolvedText
                folder.modifiedAt = now
                result.folder = folder
            case .pinnedText:
                guard let thought = fetchPinnedThought(withID: conflict.entityID) else {
                    throw MyRAMSyncConflictResolutionError.conflictUnavailable
                }
                thought.text = resolution.resolvedText
                thought.modifiedAt = now
                thought.note?.modifiedAt = now
                result.pinnedThought = thought
                result.note = thought.note
                result.folder = thought.note?.folder
                result.shouldRefreshActiveNote = activeNoteID == thought.note?.id
            }
            try saveOperation(context)
        } catch let error as MyRAMSyncConflictResolutionError {
            context.rollback()
            throw error
        } catch {
            context.rollback()
            throw MyRAMSyncConflictResolutionError.modelSaveFailed
        }

        do {
            if let baseline = checkedBaseline(
                for: conflict,
                resolvedText: resolution.resolvedText,
                result: result
            ) {
                try store.saveRemoteBaselineChecked(baseline)
            }
        } catch {
            throw MyRAMSyncConflictResolutionError.baselinePersistenceFailed
        }

        if let publishResolution {
            do {
                try await publishResolution(MyRAMSyncConflictPayload(
                    action: .resolved,
                    conflict: conflict,
                    resolvedText: resolution.resolvedText,
                    baseText: resolution.baseText
                ))
            } catch {
                throw MyRAMSyncConflictResolutionError.metadataPublicationFailed
            }
        }

        do {
            if conflict.id.isLifecycleConflictID {
                try store.markLifecycleResolvedChecked(id: conflict.id)
                try store.cleanupResolvedLifecycleConflictChecked(id: conflict.id)
                result.conflicts = store.activeConflicts()
            } else {
                result.conflicts = store.removeResolvedConflict(conflict)
            }
        } catch {
            throw MyRAMSyncConflictResolutionError.terminalPersistenceFailed
        }
        return result
    }

    private func checkedBaseline(
        for conflict: SyncConflictVersion,
        resolvedText: String,
        result: SyncConflictRestoreResult
    ) -> SyncRemoteTextBaseline? {
        switch conflict.field {
        case .noteTitle:
            guard let note = result.note else { return nil }
            return SyncRemoteTextBaseline(
                entityType: .note,
                entityID: conflict.entityID,
                field: .noteTitle,
                text: resolvedText,
                richTextContentData: nil,
                modifiedAt: note.modifiedAt,
                originDeviceID: nil
            )
        case .noteContent:
            guard let note = result.note else { return nil }
            return SyncRemoteTextBaseline(
                entityType: .note,
                entityID: conflict.entityID,
                field: .noteContent,
                text: resolvedText,
                richTextContentData: note.richTextContentData,
                modifiedAt: note.modifiedAt,
                originDeviceID: nil
            )
        case .pinnedText:
            guard let thought = result.pinnedThought else { return nil }
            return SyncRemoteTextBaseline(
                entityType: .pinnedThought,
                entityID: conflict.entityID,
                field: .pinnedText,
                text: resolvedText,
                richTextContentData: nil,
                modifiedAt: thought.modifiedAt,
                originDeviceID: nil
            )
        case .folderTitle:
            return nil
        }
    }

    private func resolve(
        _ conflict: SyncConflictVersion,
        choice: SyncTextConflictResolutionChoice,
        activeNoteID: UUID?
    ) -> SyncConflictRestoreResult? {
        let now = Date()
        let resolution = SyncTextConflictResolver.resolve(conflict.syncTextConflict, choice: choice)
        var result = SyncConflictRestoreResult(conflicts: store.activeConflicts(), resolution: resolution)

        do {
            switch conflict.field {
            case .noteTitle:
                guard let note = fetchNote(withID: conflict.entityID) else { return nil }
                note.title = resolution.resolvedText
                note.modifiedAt = now
                result.note = note
                result.folder = note.folder
                result.shouldRefreshActiveNote = activeNoteID == note.id

            case .noteContent:
                guard let note = fetchNote(withID: conflict.entityID) else { return nil }
                let previousContent = note.content
                let resolvedRichTextData: Data?
                if resolution.usesRemoteData {
                    resolvedRichTextData = sanitizedConflictRichTextData(
                        resolution.resolvedData,
                        plainText: resolution.resolvedText
                    )
                } else if previousContent != resolution.resolvedText {
                    resolvedRichTextData = resolution.resolvedData
                        ?? sanitizedConflictRichTextData(
                            note.richTextContentData,
                            plainText: resolution.resolvedText
                        )
                } else {
                    resolvedRichTextData = note.richTextContentData
                }
                _ = try NoteSequenceStateFullBodyIntegration.replaceBody(
                    of: note,
                    with: resolution.resolvedText,
                    in: context
                )
                note.richTextContentData = resolvedRichTextData
                note.modifiedAt = now
                result.note = note
                result.folder = note.folder
                result.shouldRefreshActiveNote = activeNoteID == note.id

            case .folderTitle:
                guard let folder = fetchFolder(withID: conflict.entityID) else { return nil }
                folder.name = resolution.resolvedText
                folder.modifiedAt = now
                result.folder = folder

            case .pinnedText:
                guard let thought = fetchPinnedThought(withID: conflict.entityID) else { return nil }
                thought.text = resolution.resolvedText
                thought.modifiedAt = now
                thought.note?.modifiedAt = now
                result.pinnedThought = thought
                result.note = thought.note
                result.folder = thought.note?.folder
                result.shouldRefreshActiveNote = activeNoteID == thought.note?.id
            }

            try saveOperation(context)
        } catch {
            context.rollback()
            return nil
        }
        result.conflicts = store.removeResolvedConflict(conflict)
        return result
    }

    func markReviewed(_ conflict: SyncConflictVersion, activeNoteID: UUID?) -> SyncConflictRestoreResult? {
        keepLocal(conflict, activeNoteID: activeNoteID)
    }

    func discard(_ conflict: SyncConflictVersion, activeNoteID: UUID?) -> SyncConflictRestoreResult? {
        keepLocal(conflict, activeNoteID: activeNoteID)
    }

    func restore(_ conflict: SyncConflictVersion, activeNoteID: UUID?) -> SyncConflictRestoreResult? {
        acceptIncoming(conflict, activeNoteID: activeNoteID)
    }

    private func currentText(for conflict: SyncConflictVersion) -> String {
        switch conflict.field {
        case .noteTitle:
            fetchNote(withID: conflict.entityID)?.title ?? conflict.localText
        case .noteContent:
            fetchNote(withID: conflict.entityID)?.content ?? conflict.localText
        case .folderTitle:
            fetchFolder(withID: conflict.entityID)?.name ?? conflict.localText
        case .pinnedText:
            fetchPinnedThought(withID: conflict.entityID)?.text ?? conflict.localText
        }
    }

    private func currentData(for conflict: SyncConflictVersion) -> Data? {
        switch conflict.field {
        case .noteContent:
            fetchNote(withID: conflict.entityID)?.richTextContentData
        case .noteTitle, .folderTitle, .pinnedText:
            nil
        }
    }

    private func sanitizedConflictRichTextData(_ data: Data?, plainText: String) -> Data? {
        #if os(iOS)
        return RichTextContentCodec.sanitizedConflictRichTextData(data, plainText: plainText)
        #else
        guard let data,
              let attributedText = try? NSAttributedString(
                  data: data,
                  options: [.documentType: NSAttributedString.DocumentType.rtf],
                  documentAttributes: nil
              ),
              let compatibleText = attributedText.myramCompatibleConflictText(matching: plainText) else {
            return nil
        }
        return RTFCoding.encode(NSMutableAttributedString(attributedString: compatibleText))
        #endif
    }

    private func fetchNote(withID noteID: UUID) -> Note? {
        let descriptor = FetchDescriptor<Note>(
            predicate: #Predicate { note in
                note.id == noteID
            }
        )
        return (try? context.fetch(descriptor))?.first
    }

    private func fetchFolder(withID folderID: UUID) -> Folder? {
        let descriptor = FetchDescriptor<Folder>(
            predicate: #Predicate { folder in
                folder.id == folderID
            }
        )
        return (try? context.fetch(descriptor))?.first
    }

    private func fetchPinnedThought(withID thoughtID: UUID) -> PinnedThought? {
        let descriptor = FetchDescriptor<PinnedThought>(
            predicate: #Predicate { thought in
                thought.id == thoughtID
            }
        )
        return (try? context.fetch(descriptor))?.first
    }
}