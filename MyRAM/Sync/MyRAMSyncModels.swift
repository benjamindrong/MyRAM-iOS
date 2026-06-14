import Foundation

enum MyRAMSyncPayloadKind: String, Codable {
    case note
    case folder
    case pinnedThought
}

struct MyRAMNoteSyncPayload: Codable, Equatable {
    let kind: MyRAMSyncPayloadKind
    let id: UUID
    let title: String
    let content: String
    let richTextContentData: Data?
    let isPinned: Bool
    let createdAt: Date
    let modifiedAt: Date
    let deletedAt: Date?
    let folderID: UUID?

    init(note: Note) {
        kind = .note
        id = note.id
        title = note.title
        content = note.content
        richTextContentData = note.richTextContentData
        isPinned = note.isPinned ?? false
        createdAt = note.createdAt
        modifiedAt = note.modifiedAt
        deletedAt = note.deletedAt
        folderID = note.folder?.id
    }
}

struct MyRAMFolderSyncPayload: Codable, Equatable {
    let kind: MyRAMSyncPayloadKind
    let id: UUID
    let name: String
    let createdAt: Date
    let modifiedAt: Date
    let parentFolderID: UUID?
    let isDeleted: Bool

    init(folder: Folder, isDeleted: Bool = false) {
        kind = .folder
        id = folder.id
        name = folder.name
        createdAt = folder.createdAt
        modifiedAt = folder.modifiedAt
        parentFolderID = folder.parentFolder?.id
        self.isDeleted = isDeleted
    }
}

struct MyRAMPinnedThoughtSyncPayload: Codable, Equatable {
    let kind: MyRAMSyncPayloadKind
    let id: UUID
    let noteID: UUID?
    let text: String
    let order: Int
    let isCollapsed: Bool
    let createdAt: Date
    let modifiedAt: Date
    let isDeleted: Bool

    init(thought: PinnedThought, isDeleted: Bool = false) {
        kind = .pinnedThought
        id = thought.id
        noteID = thought.note?.id
        text = thought.text
        order = thought.order
        isCollapsed = thought.isCollapsed
        createdAt = thought.createdAt
        modifiedAt = thought.modifiedAt
        self.isDeleted = isDeleted
    }
}

enum MyRAMSyncPayloadCoding {
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    static func encode(_ payload: MyRAMNoteSyncPayload) throws -> Data {
        try encoder.encode(payload)
    }

    static func encode(_ payload: MyRAMFolderSyncPayload) throws -> Data {
        try encoder.encode(payload)
    }

    static func encode(_ payload: MyRAMPinnedThoughtSyncPayload) throws -> Data {
        try encoder.encode(payload)
    }

    static func decodeNote(from data: Data) throws -> MyRAMNoteSyncPayload {
        try decoder.decode(MyRAMNoteSyncPayload.self, from: data)
    }

    static func decodeFolder(from data: Data) throws -> MyRAMFolderSyncPayload {
        try decoder.decode(MyRAMFolderSyncPayload.self, from: data)
    }

    static func decodePinnedThought(from data: Data) throws -> MyRAMPinnedThoughtSyncPayload {
        try decoder.decode(MyRAMPinnedThoughtSyncPayload.self, from: data)
    }
}

