import Foundation
import NearbySyncCore

enum SyncConflictEntityType: String, Codable {
    case note
    case folder
    case pinnedThought
}

enum SyncConflictField: String, Codable {
    case noteTitle
    case noteContent
    case folderTitle
    case pinnedText
}

struct SyncConflictVersion: Codable, Equatable, Identifiable {
    let id: UUID
    let entityType: SyncConflictEntityType
    let entityID: UUID
    let noteID: UUID?
    let field: SyncConflictField
    let localText: String
    let remoteText: String
    let remoteRichTextContentData: Data?
    let remoteModifiedAt: Date
    let preservedAt: Date
    let expiresAt: Date

    init(
        id: UUID = UUID(),
        entityType: SyncConflictEntityType,
        entityID: UUID,
        noteID: UUID?,
        field: SyncConflictField,
        localText: String,
        remoteText: String,
        remoteRichTextContentData: Data? = nil,
        remoteModifiedAt: Date,
        preservedAt: Date = Date(),
        expiresAt: Date
    ) {
        self.id = id
        self.entityType = entityType
        self.entityID = entityID
        self.noteID = noteID
        self.field = field
        self.localText = localText
        self.remoteText = remoteText
        self.remoteRichTextContentData = remoteRichTextContentData
        self.remoteModifiedAt = remoteModifiedAt
        self.preservedAt = preservedAt
        self.expiresAt = expiresAt
    }
}

struct SyncRemoteTextBaseline: Codable, Equatable {
    let entityType: SyncConflictEntityType
    let entityID: UUID
    let field: SyncConflictField
    let text: String
    let richTextContentData: Data?
    let modifiedAt: Date
    let originDeviceID: String?
}

protocol SyncConflictStoring: AnyObject {
    func activeConflicts(now: Date) -> [SyncConflictVersion]
    func preserve(_ conflict: SyncConflictVersion) -> [SyncConflictVersion]
    func removeConflict(id: UUID) -> [SyncConflictVersion]
    func removeResolvedConflict(_ conflict: SyncConflictVersion) -> [SyncConflictVersion]
    func hasActiveConflict(
        entityType: SyncConflictEntityType,
        entityID: UUID,
        field: SyncConflictField,
        now: Date
    ) -> Bool
    func queuedConflict(
        entityType: SyncConflictEntityType,
        entityID: UUID,
        field: SyncConflictField
    ) -> SyncTextQueuedConflict?
    func remoteBaseline(
        entityType: SyncConflictEntityType,
        entityID: UUID,
        field: SyncConflictField
    ) -> SyncRemoteTextBaseline?
    func saveRemoteBaseline(_ baseline: SyncRemoteTextBaseline)
    func saveNoteTitleBaseline(noteID: UUID, title: String, modifiedAt: Date, originDeviceID: String?)
    func saveNoteContentBaseline(
        noteID: UUID,
        content: String,
        richTextContentData: Data?,
        modifiedAt: Date,
        originDeviceID: String?
    )
    func savePinnedTextBaseline(thoughtID: UUID, text: String, modifiedAt: Date, originDeviceID: String?)
}

extension SyncConflictStoring {
    func activeConflicts() -> [SyncConflictVersion] {
        activeConflicts(now: Date())
    }

    func hasActiveConflict(
        entityType: SyncConflictEntityType,
        entityID: UUID,
        field: SyncConflictField
    ) -> Bool {
        hasActiveConflict(entityType: entityType, entityID: entityID, field: field, now: Date())
    }
}

struct LegacyIncomingBufferedEffects: Equatable {
    var preservedConflicts: [SyncConflictVersion] = []
    var removedConflictIDs: [UUID] = []
    var removedResolvedConflicts: [SyncConflictVersion] = []
    var remoteBaselines: [SyncRemoteTextBaseline] = []
}

final class BufferedSyncConflictStore: SyncConflictStoring {
    private struct ConflictKey: Hashable {
        let entityType: SyncConflictEntityType
        let entityID: UUID
        let field: SyncConflictField
    }

    private let base: SyncConflictStoring
    private var bufferedConflicts: [SyncConflictVersion] = []
    private var preservedEffectConflicts: [SyncConflictVersion] = []
    private var removedConflictIDs: [UUID] = []
    private var removedResolvedConflicts: [SyncConflictVersion] = []
    private var queuedConflictsByKey: [ConflictKey: SyncTextQueuedConflict] = [:]
    private var baselinesByKey: [ConflictKey: SyncRemoteTextBaseline] = [:]

    init(base: SyncConflictStoring) {
        self.base = base
    }

    var effects: LegacyIncomingBufferedEffects {
        LegacyIncomingBufferedEffects(
            preservedConflicts: preservedEffectConflicts,
            removedConflictIDs: removedConflictIDs,
            removedResolvedConflicts: removedResolvedConflicts,
            remoteBaselines: baselinesByKey.values.sorted {
                if $0.entityType.rawValue != $1.entityType.rawValue {
                    return $0.entityType.rawValue < $1.entityType.rawValue
                }
                if $0.entityID.uuidString != $1.entityID.uuidString {
                    return $0.entityID.uuidString < $1.entityID.uuidString
                }
                return $0.field.rawValue < $1.field.rawValue
            }
        )
    }

    func activeConflicts(now: Date) -> [SyncConflictVersion] {
        var conflicts = base.activeConflicts(now: now)
            .filter { !removedConflictIDs.contains($0.id) }
            .filter { conflict in
                !removedResolvedConflicts.contains {
                    $0.entityType == conflict.entityType
                        && $0.entityID == conflict.entityID
                        && $0.field == conflict.field
                }
            }
        for conflict in bufferedConflicts where !conflicts.contains(where: { $0.id == conflict.id }) {
            conflicts.append(conflict)
        }
        return conflicts.sorted {
            if $0.preservedAt == $1.preservedAt {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.preservedAt > $1.preservedAt
        }
    }

    func preserve(_ conflict: SyncConflictVersion) -> [SyncConflictVersion] {
        let conflicts = activeConflicts()
        if conflicts.contains(where: {
            SyncTextConflictStore.isExactRemoteMatch($0.syncTextConflict, conflict.syncTextConflict)
        }) {
            return conflicts
        }
        preservedEffectConflicts.append(conflict)
        if conflicts.contains(where: { sameLogicalConflict($0, conflict) }) {
            queuedConflictsByKey[ConflictKey(
                entityType: conflict.entityType,
                entityID: conflict.entityID,
                field: conflict.field
            )] = SyncTextQueuedConflict(conflict: conflict.syncTextConflict)
        } else {
            bufferedConflicts.append(conflict)
        }
        return activeConflicts()
    }

    func removeConflict(id: UUID) -> [SyncConflictVersion] {
        bufferedConflicts.removeAll { $0.id == id }
        if !removedConflictIDs.contains(id) {
            removedConflictIDs.append(id)
        }
        return activeConflicts()
    }

    func removeResolvedConflict(_ conflict: SyncConflictVersion) -> [SyncConflictVersion] {
        bufferedConflicts.removeAll { sameLogicalConflict($0, conflict) }
        removedResolvedConflicts.append(conflict)
        return activeConflicts()
    }

    func hasActiveConflict(
        entityType: SyncConflictEntityType,
        entityID: UUID,
        field: SyncConflictField,
        now: Date
    ) -> Bool {
        activeConflicts(now: now).contains {
            $0.entityType == entityType
                && $0.entityID == entityID
                && $0.field == field
        }
    }

    func queuedConflict(
        entityType: SyncConflictEntityType,
        entityID: UUID,
        field: SyncConflictField
    ) -> SyncTextQueuedConflict? {
        queuedConflictsByKey[ConflictKey(entityType: entityType, entityID: entityID, field: field)]
            ?? base.queuedConflict(entityType: entityType, entityID: entityID, field: field)
    }

    func remoteBaseline(
        entityType: SyncConflictEntityType,
        entityID: UUID,
        field: SyncConflictField
    ) -> SyncRemoteTextBaseline? {
        baselinesByKey[ConflictKey(entityType: entityType, entityID: entityID, field: field)]
            ?? base.remoteBaseline(entityType: entityType, entityID: entityID, field: field)
    }

    func saveRemoteBaseline(_ baseline: SyncRemoteTextBaseline) {
        baselinesByKey[ConflictKey(
            entityType: baseline.entityType,
            entityID: baseline.entityID,
            field: baseline.field
        )] = baseline
    }

    func saveNoteTitleBaseline(noteID: UUID, title: String, modifiedAt: Date, originDeviceID: String?) {
        saveRemoteBaseline(SyncRemoteTextBaseline(
            entityType: .note,
            entityID: noteID,
            field: .noteTitle,
            text: title,
            richTextContentData: nil,
            modifiedAt: modifiedAt,
            originDeviceID: originDeviceID
        ))
    }

    func saveNoteContentBaseline(
        noteID: UUID,
        content: String,
        richTextContentData: Data?,
        modifiedAt: Date,
        originDeviceID: String?
    ) {
        saveRemoteBaseline(SyncRemoteTextBaseline(
            entityType: .note,
            entityID: noteID,
            field: .noteContent,
            text: content,
            richTextContentData: richTextContentData,
            modifiedAt: modifiedAt,
            originDeviceID: originDeviceID
        ))
    }

    func savePinnedTextBaseline(thoughtID: UUID, text: String, modifiedAt: Date, originDeviceID: String?) {
        saveRemoteBaseline(SyncRemoteTextBaseline(
            entityType: .pinnedThought,
            entityID: thoughtID,
            field: .pinnedText,
            text: text,
            richTextContentData: nil,
            modifiedAt: modifiedAt,
            originDeviceID: originDeviceID
        ))
    }

    private func sameLogicalConflict(_ lhs: SyncConflictVersion, _ rhs: SyncConflictVersion) -> Bool {
        lhs.entityType == rhs.entityType
            && lhs.entityID == rhs.entityID
            && lhs.field == rhs.field
    }
}

enum SyncConflictBaselineSnapshotState: Equatable {
    case absent
    case present(Data)
}

enum SyncConflictStoreSnapshotError: Error, Equatable {
    case baselineCaptureFailed(path: String)
    case baselineRestoreFailed(path: String)
}

struct SyncConflictStoreSnapshot {
    let textConflicts: SyncTextConflictStoreSnapshot
    let baselines: SyncConflictBaselineSnapshotState
}

extension SyncRemoteTextBaseline {
    var syncTextBaseline: SyncTextTrackedBaseline {
        SyncTextTrackedBaseline(
            text: text,
            data: richTextContentData,
            originDeviceID: originDeviceID
        )
    }
}

final class SyncConflictStore: SyncConflictStoring {
    struct FileIO {
        var fileExists: (String) -> Bool
        var readData: (URL) throws -> Data
        var createDirectory: (URL) throws -> Void
        var writeData: (Data, URL) throws -> Void
        var removeItem: (URL) throws -> Void

        static let live = FileIO(
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            readData: { try Data(contentsOf: $0) },
            createDirectory: {
                try FileManager.default.createDirectory(
                    at: $0,
                    withIntermediateDirectories: true
                )
            },
            writeData: { data, url in try data.write(to: url, options: [.atomic]) },
            removeItem: { try FileManager.default.removeItem(at: $0) }
        )
    }

    static let retention = SyncTextConflictPolicy.retention

    private let fileURL: URL
    private let textConflictStore: SyncTextConflictStore
    private let fileIO: FileIO
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    convenience init(fileURL: URL = SyncConflictStore.defaultFileURL()) {
        self.init(fileURL: fileURL, fileIO: .live, textFileIO: .live)
    }

    init(
        fileURL: URL = SyncConflictStore.defaultFileURL(),
        fileIO: FileIO,
        textFileIO: SyncTextConflictStore.FileIO = .live
    ) {
        self.fileURL = fileURL
        self.fileIO = fileIO
        textConflictStore = SyncTextConflictStore(fileURL: fileURL, fileIO: textFileIO)
        migrateLegacyConflictsIfNeeded()
    }

    func activeConflicts(now: Date = Date()) -> [SyncConflictVersion] {
        textConflictStore.activeConflicts(now: now).compactMap(SyncConflictVersion.init)
    }

    func preserve(_ conflict: SyncConflictVersion) -> [SyncConflictVersion] {
        textConflictStore.preserve(conflict.syncTextConflict).compactMap(SyncConflictVersion.init)
    }

    func removeConflict(id: UUID) -> [SyncConflictVersion] {
        textConflictStore.removeConflict(id: id).compactMap(SyncConflictVersion.init)
    }

    func removeResolvedConflict(_ conflict: SyncConflictVersion) -> [SyncConflictVersion] {
        textConflictStore.removeResolvedConflict(conflict.syncTextConflict).compactMap(SyncConflictVersion.init)
    }

    func hasActiveConflict(
        entityType: SyncConflictEntityType,
        entityID: UUID,
        field: SyncConflictField,
        now: Date = Date()
    ) -> Bool {
        textConflictStore.hasActiveConflict(
            entityType: entityType.syncEntityType,
            entityID: entityID.uuidString,
            fieldID: field.rawValue,
            now: now
        )
    }

    func queuedConflict(
        entityType: SyncConflictEntityType,
        entityID: UUID,
        field: SyncConflictField
    ) -> SyncTextQueuedConflict? {
        textConflictStore.queuedConflict(
            entityType: entityType.syncEntityType,
            entityID: entityID.uuidString,
            fieldID: field.rawValue
        )
    }

    func remoteBaseline(
        entityType: SyncConflictEntityType,
        entityID: UUID,
        field: SyncConflictField
    ) -> SyncRemoteTextBaseline? {
        loadBaselines().first {
            $0.entityType == entityType
                && $0.entityID == entityID
                && $0.field == field
        }
    }

    func saveRemoteBaseline(_ baseline: SyncRemoteTextBaseline) {
        var baselines = loadBaselines()
        if let index = baselines.firstIndex(where: {
            $0.entityType == baseline.entityType
                && $0.entityID == baseline.entityID
                && $0.field == baseline.field
        }) {
            baselines[index] = baseline
        } else {
            baselines.append(baseline)
        }
        saveBaselines(baselines)
    }

    func commitLegacyIncomingEffectsChecked(_ effects: LegacyIncomingBufferedEffects) throws {
        try textConflictStore.commitChecked(SyncTextConflictCommitEffects(
            preservedConflicts: effects.preservedConflicts.map(\.syncTextConflict),
            removedConflictIDs: effects.removedConflictIDs,
            removedResolvedConflicts: effects.removedResolvedConflicts.map(\.syncTextConflict)
        ))
        try saveRemoteBaselinesChecked(effects.remoteBaselines)
    }

    func saveNoteTitleBaseline(noteID: UUID, title: String, modifiedAt: Date, originDeviceID: String?) {
        saveRemoteBaseline(
            SyncRemoteTextBaseline(
                entityType: .note,
                entityID: noteID,
                field: .noteTitle,
                text: title,
                richTextContentData: nil,
                modifiedAt: modifiedAt,
                originDeviceID: originDeviceID
            )
        )
    }

    func saveNoteContentBaseline(
        noteID: UUID,
        content: String,
        richTextContentData: Data?,
        modifiedAt: Date,
        originDeviceID: String?
    ) {
        saveRemoteBaseline(
            SyncRemoteTextBaseline(
                entityType: .note,
                entityID: noteID,
                field: .noteContent,
                text: content,
                richTextContentData: richTextContentData,
                modifiedAt: modifiedAt,
                originDeviceID: originDeviceID
            )
        )
    }

    func savePinnedTextBaseline(thoughtID: UUID, text: String, modifiedAt: Date, originDeviceID: String?) {
        saveRemoteBaseline(
            SyncRemoteTextBaseline(
                entityType: .pinnedThought,
                entityID: thoughtID,
                field: .pinnedText,
                text: text,
                richTextContentData: nil,
                modifiedAt: modifiedAt,
                originDeviceID: originDeviceID
            )
        )
    }

    /// Captures the exact on-disk conflict-store and remote-text-baseline
    /// state. Intended for callers that speculatively apply an incoming
    /// change (which may write conflict/baseline state as a side effect)
    /// before a separate, later persistence step (e.g. a SwiftData save) is
    /// known to succeed, so that write can be rolled back on failure.
    func snapshot() throws -> SyncConflictStoreSnapshot {
        SyncConflictStoreSnapshot(
            textConflicts: try textConflictStore.snapshot(),
            baselines: try baselineSnapshotState()
        )
    }

    /// Restores exactly the state captured by `snapshot()`.
    func restore(_ snapshot: SyncConflictStoreSnapshot) throws {
        try textConflictStore.restore(snapshot.textConflicts)
        do {
            switch snapshot.baselines {
            case .absent:
                if fileIO.fileExists(baselineFileURL.path) {
                    try fileIO.removeItem(baselineFileURL)
                }
            case .present(let baselinesData):
                try fileIO.createDirectory(baselineFileURL.deletingLastPathComponent())
                try fileIO.writeData(baselinesData, baselineFileURL)
            }
        } catch {
            throw SyncConflictStoreSnapshotError.baselineRestoreFailed(path: baselineFileURL.path)
        }
    }

    private func baselineSnapshotState() throws -> SyncConflictBaselineSnapshotState {
        guard fileIO.fileExists(baselineFileURL.path) else {
            return .absent
        }
        do {
            return .present(try fileIO.readData(baselineFileURL))
        } catch {
            throw SyncConflictStoreSnapshotError.baselineCaptureFailed(path: baselineFileURL.path)
        }
    }

    private func migrateLegacyConflictsIfNeeded() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if (try? decoder.decode([SyncTextConflictVersion].self, from: data)) != nil {
            return
        }
        guard let legacyConflicts = try? decoder.decode([SyncConflictVersion].self, from: data) else {
            return
        }
        _ = textConflictStore.replaceConflicts(legacyConflicts.map(\.syncTextConflict))
    }

    private func loadBaselines() -> [SyncRemoteTextBaseline] {
        guard let data = try? Data(contentsOf: baselineFileURL) else { return [] }
        return (try? decoder.decode([SyncRemoteTextBaseline].self, from: data)) ?? []
    }

    private func loadBaselinesChecked() throws -> [SyncRemoteTextBaseline] {
        guard fileIO.fileExists(baselineFileURL.path) else { return [] }
        let data = try fileIO.readData(baselineFileURL)
        return try decoder.decode([SyncRemoteTextBaseline].self, from: data)
    }

    private func saveRemoteBaselinesChecked(_ baselines: [SyncRemoteTextBaseline]) throws {
        guard !baselines.isEmpty else { return }
        var updatedBaselines = try loadBaselinesChecked()
        for baseline in baselines {
            if let index = updatedBaselines.firstIndex(where: {
                $0.entityType == baseline.entityType
                    && $0.entityID == baseline.entityID
                    && $0.field == baseline.field
            }) {
                updatedBaselines[index] = baseline
            } else {
                updatedBaselines.append(baseline)
            }
        }
        try fileIO.createDirectory(baselineFileURL.deletingLastPathComponent())
        try fileIO.writeData(try encoder.encode(updatedBaselines), baselineFileURL)
    }

    private func saveBaselines(_ baselines: [SyncRemoteTextBaseline]) {
        do {
            try FileManager.default.createDirectory(
                at: baselineFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(baselines)
            try data.write(to: baselineFileURL, options: [.atomic])
        } catch {
            assertionFailure("Unable to persist sync baselines: \(error)")
        }
    }

    private var baselineFileURL: URL {
        fileURL.deletingLastPathComponent()
            .appendingPathComponent("sync-remote-text-baselines.json")
    }

    private static func defaultFileURL() -> URL {
        let supportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return supportDirectory
            .appendingPathComponent("MyRAM", isDirectory: true)
            .appendingPathComponent("sync-conflicts.json")
    }
}

extension SyncConflictVersion {
    init?(_ conflict: SyncTextConflictVersion) {
        guard let entityID = UUID(uuidString: conflict.entityID),
              let entityType = SyncConflictEntityType(conflict.entityType),
              let field = SyncConflictField(rawValue: conflict.fieldID) else {
            return nil
        }
        let noteID = conflict.contextID.flatMap(UUID.init(uuidString:))
            ?? (entityType == .note ? entityID : nil)
        self.init(
            id: conflict.id,
            entityType: entityType,
            entityID: entityID,
            noteID: noteID,
            field: field,
            localText: conflict.localText,
            remoteText: conflict.remoteText,
            remoteRichTextContentData: conflict.remoteData,
            remoteModifiedAt: conflict.remoteUpdatedAt,
            preservedAt: conflict.preservedAt,
            expiresAt: conflict.expiresAt
        )
    }

    var syncTextConflict: SyncTextConflictVersion {
        SyncTextConflictVersion(
            id: id,
            entityType: entityType.syncEntityType,
            entityID: entityID.uuidString,
            fieldID: field.rawValue,
            contextID: noteID?.uuidString,
            localText: localText,
            remoteText: remoteText,
            remoteData: remoteRichTextContentData,
            remoteUpdatedAt: remoteModifiedAt,
            preservedAt: preservedAt,
            expiresAt: expiresAt
        )
    }
}

private extension SyncConflictEntityType {
    init?(_ entityType: SyncEntityType) {
        switch entityType {
        case .item:
            self = .note
        case .collection:
            self = .folder
        case .marker:
            self = .pinnedThought
        case .attachment, .conflict:
            return nil
        }
    }

    var syncEntityType: SyncEntityType {
        switch self {
        case .note:
            .item
        case .folder:
            .collection
        case .pinnedThought:
            .marker
        }
    }
}
