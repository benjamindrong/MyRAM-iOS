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

struct SyncRemoteTextBaseline: Codable, Equatable {
    let entityType: SyncConflictEntityType
    let entityID: UUID
    let field: SyncConflictField
    let text: String
    let richTextContentData: Data?
    let modifiedAt: Date
}

private struct SyncResolvedConflict: Codable, Equatable {
    let entityType: SyncConflictEntityType
    let entityID: UUID
    let field: SyncConflictField
    let remoteText: String
    let remoteRichTextContentData: Data?
    let remoteModifiedAt: Date
    let resolvedAt: Date
    let expiresAt: Date
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
        guard !isResolved(conflict) else {
            return activeConflicts()
        }
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

    func removeResolvedConflict(_ conflict: SyncConflictVersion) -> [SyncConflictVersion] {
        recordResolvedConflict(conflict)
        let conflicts = activeConflicts().filter {
            $0.id != conflict.id
                && !sameRemoteConflict($0, conflict)
        }
        saveConflicts(conflicts)
        return conflicts
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

    private func isResolved(_ conflict: SyncConflictVersion, now: Date = Date()) -> Bool {
        loadResolvedConflicts(now: now).contains {
            sameRemoteConflict($0, conflict)
        }
    }

    private func recordResolvedConflict(_ conflict: SyncConflictVersion, now: Date = Date()) {
        var resolvedConflicts = loadResolvedConflicts(now: now)
        let resolvedConflict = SyncResolvedConflict(
            entityType: conflict.entityType,
            entityID: conflict.entityID,
            field: conflict.field,
            remoteText: conflict.remoteText,
            remoteRichTextContentData: conflict.remoteRichTextContentData,
            remoteModifiedAt: conflict.remoteModifiedAt,
            resolvedAt: now,
            expiresAt: now.addingTimeInterval(Self.retention)
        )
        if let index = resolvedConflicts.firstIndex(where: { sameRemoteConflict($0, conflict) }) {
            resolvedConflicts[index] = resolvedConflict
        } else {
            resolvedConflicts.append(resolvedConflict)
        }
        saveResolvedConflicts(resolvedConflicts)
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

    private func loadResolvedConflicts(now: Date = Date()) -> [SyncResolvedConflict] {
        guard let data = try? Data(contentsOf: resolvedFileURL) else { return [] }
        let resolvedConflicts = ((try? decoder.decode([SyncResolvedConflict].self, from: data)) ?? [])
            .filter { $0.expiresAt > now }
        saveResolvedConflicts(resolvedConflicts)
        return resolvedConflicts
    }

    private func saveResolvedConflicts(_ resolvedConflicts: [SyncResolvedConflict]) {
        do {
            try FileManager.default.createDirectory(
                at: resolvedFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(resolvedConflicts)
            try data.write(to: resolvedFileURL, options: [.atomic])
        } catch {
            assertionFailure("Unable to persist resolved sync conflicts: \(error)")
        }
    }

    private func sameRemoteConflict(_ lhs: SyncConflictVersion, _ rhs: SyncConflictVersion) -> Bool {
        lhs.entityType == rhs.entityType
            && lhs.entityID == rhs.entityID
            && lhs.field == rhs.field
            && lhs.remoteModifiedAt == rhs.remoteModifiedAt
            && lhs.remoteText == rhs.remoteText
            && lhs.remoteRichTextContentData == rhs.remoteRichTextContentData
    }

    private func sameRemoteConflict(_ lhs: SyncResolvedConflict, _ rhs: SyncConflictVersion) -> Bool {
        lhs.entityType == rhs.entityType
            && lhs.entityID == rhs.entityID
            && lhs.field == rhs.field
            && lhs.remoteModifiedAt == rhs.remoteModifiedAt
            && lhs.remoteText == rhs.remoteText
            && lhs.remoteRichTextContentData == rhs.remoteRichTextContentData
    }

    private var baselineFileURL: URL {
        fileURL.deletingLastPathComponent()
            .appendingPathComponent("sync-remote-text-baselines.json")
    }

    private var resolvedFileURL: URL {
        fileURL.deletingLastPathComponent()
            .appendingPathComponent("sync-resolved-conflicts.json")
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
