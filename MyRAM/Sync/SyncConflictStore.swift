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
}

final class SyncConflictStore {
    static let retention = SyncTextConflictPolicy.retention

    private let fileURL: URL
    private let textConflictStore: SyncTextConflictStore
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileURL: URL = SyncConflictStore.defaultFileURL()) {
        self.fileURL = fileURL
        textConflictStore = SyncTextConflictStore(fileURL: fileURL)
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

    func saveNoteTitleBaseline(noteID: UUID, title: String, modifiedAt: Date) {
        saveRemoteBaseline(
            SyncRemoteTextBaseline(
                entityType: .note,
                entityID: noteID,
                field: .noteTitle,
                text: title,
                richTextContentData: nil,
                modifiedAt: modifiedAt
            )
        )
    }

    func saveNoteContentBaseline(noteID: UUID, content: String, richTextContentData: Data?, modifiedAt: Date) {
        saveRemoteBaseline(
            SyncRemoteTextBaseline(
                entityType: .note,
                entityID: noteID,
                field: .noteContent,
                text: content,
                richTextContentData: richTextContentData,
                modifiedAt: modifiedAt
            )
        )
    }

    func savePinnedTextBaseline(thoughtID: UUID, text: String, modifiedAt: Date) {
        saveRemoteBaseline(
            SyncRemoteTextBaseline(
                entityType: .pinnedThought,
                entityID: thoughtID,
                field: .pinnedText,
                text: text,
                richTextContentData: nil,
                modifiedAt: modifiedAt
            )
        )
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
