import Foundation

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

final class SyncConflictStore {
    static let retention: TimeInterval = 7 * 24 * 60 * 60

    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileURL: URL = SyncConflictStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    func activeConflicts(now: Date = Date()) -> [SyncConflictVersion] {
        let active = loadConflicts().filter { $0.expiresAt > now }
        saveConflicts(active)
        return active.sorted { lhs, rhs in
            if lhs.preservedAt == rhs.preservedAt {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.preservedAt > rhs.preservedAt
        }
    }

    func preserve(_ conflict: SyncConflictVersion) -> [SyncConflictVersion] {
        var conflicts = activeConflicts()
        if let index = conflicts.firstIndex(where: {
            $0.entityType == conflict.entityType
                && $0.entityID == conflict.entityID
                && $0.field == conflict.field
                && $0.remoteModifiedAt == conflict.remoteModifiedAt
                && $0.remoteText == conflict.remoteText
        }) {
            conflicts[index] = conflict
        } else {
            conflicts.append(conflict)
        }
        saveConflicts(conflicts)
        return activeConflicts()
    }

    func removeConflict(id: UUID) -> [SyncConflictVersion] {
        let conflicts = activeConflicts().filter { $0.id != id }
        saveConflicts(conflicts)
        return conflicts
    }

    private func loadConflicts() -> [SyncConflictVersion] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? decoder.decode([SyncConflictVersion].self, from: data)) ?? []
    }

    private func saveConflicts(_ conflicts: [SyncConflictVersion]) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(conflicts)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            assertionFailure("Unable to persist sync conflicts: \(error)")
        }
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
