import Foundation

enum MyRAMSyncPayloadKind: String, Codable {
    case note
    case folder
    case pinnedThought
    case photoAttachment
    case syncConflict
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
    let baseTitle: String?
    let baseContent: String?
    let baseRichTextContentData: Data?

    init(
        note: Note,
        baseTitle: String? = nil,
        baseContent: String? = nil,
        baseRichTextContentData: Data? = nil
    ) {
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
        self.baseTitle = baseTitle
        self.baseContent = baseContent
        self.baseRichTextContentData = baseRichTextContentData
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
    let baseText: String?

    init(thought: PinnedThought, isDeleted: Bool = false, baseText: String? = nil) {
        kind = .pinnedThought
        id = thought.id
        noteID = thought.note?.id
        text = thought.text
        order = thought.order
        isCollapsed = thought.isCollapsed
        createdAt = thought.createdAt
        modifiedAt = thought.modifiedAt
        self.isDeleted = isDeleted
        self.baseText = baseText
    }
}

struct MyRAMPhotoAttachmentSyncPayload: Codable, Equatable {
    let kind: MyRAMSyncPayloadKind
    let id: UUID
    let noteID: UUID?
    let imageData: Data
    let createdAt: Date
    let isDeleted: Bool

    init(attachment: NotePhotoAttachment, isDeleted: Bool = false) {
        kind = .photoAttachment
        id = attachment.id
        noteID = attachment.note?.id
        imageData = attachment.imageData
        createdAt = attachment.createdAt
        self.isDeleted = isDeleted
    }
}

enum MyRAMSyncConflictAction: String, Codable {
    case preserved
    case resolved
}

struct MyRAMSyncConflictPayload: Codable, Equatable {
    let kind: MyRAMSyncPayloadKind
    let action: MyRAMSyncConflictAction
    let conflict: SyncConflictVersion?
    let conflictID: UUID
    let resolvedText: String?
    let baseText: String?
    let updatedAt: Date

    init(
        action: MyRAMSyncConflictAction,
        conflict: SyncConflictVersion,
        resolvedText: String? = nil,
        baseText: String? = nil,
        updatedAt: Date = Date()
    ) {
        kind = .syncConflict
        self.action = action
        self.conflict = conflict
        conflictID = conflict.id
        self.resolvedText = resolvedText
        self.baseText = baseText
        self.updatedAt = updatedAt
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

    static func encode(_ payload: MyRAMPhotoAttachmentSyncPayload) throws -> Data {
        try encoder.encode(payload)
    }

    static func encode(_ payload: MyRAMSyncConflictPayload) throws -> Data {
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

    static func decodePhotoAttachment(from data: Data) throws -> MyRAMPhotoAttachmentSyncPayload {
        try decoder.decode(MyRAMPhotoAttachmentSyncPayload.self, from: data)
    }

    static func decodeSyncConflict(from data: Data) throws -> MyRAMSyncConflictPayload {
        try decoder.decode(MyRAMSyncConflictPayload.self, from: data)
    }
}
