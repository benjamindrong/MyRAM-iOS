#if os(macOS)
import Foundation

typealias MacSyncDeviceID = UUID
typealias MacSyncBatchID = UUID
typealias MacSyncNoteID = UUID
typealias MacSyncFolderID = UUID

struct MacSyncBatch: Codable, Equatable, Identifiable, Sendable {
    let id: MacSyncBatchID
    let originDeviceID: MacSyncDeviceID
    let createdAt: Date
    let changes: [MacSyncChange]
}

enum MacSyncChange: Codable, Equatable, Sendable {
    case noteCreated(MacSyncNoteCreatedChange)
    case noteTitleChanged(MacSyncNoteTitleChangedChange)
    case noteBodyTextInserted(MacSyncNoteBodyTextInsertedChange)
    case noteBodyTextDeleted(MacSyncNoteBodyTextDeletedChange)
}

struct MacSyncNoteCreatedChange: Codable, Equatable, Sendable {
    let noteID: MacSyncNoteID
    let title: String
    let body: String
    let folderID: MacSyncFolderID?
    let createdAt: Date
    let modifiedAt: Date
    // TODO: MYR-124 richTextContentData is not synced on note creation.
    // Notes with rich text formatting arrive as plain text on the receiving device.
}

struct MacSyncNoteTitleChangedChange: Codable, Equatable, Sendable {
    let noteID: MacSyncNoteID
    let title: String
    let modifiedAt: Date
}

struct MacSyncNoteBodyTextInsertedChange: Codable, Equatable, Sendable {
    let noteID: MacSyncNoteID
    let utf16Offset: Int
    let text: String
    let modifiedAt: Date
}

struct MacSyncNoteBodyTextDeletedChange: Codable, Equatable, Sendable {
    let noteID: MacSyncNoteID
    let utf16Offset: Int
    let utf16Length: Int
    let expectedText: String?
    let modifiedAt: Date
}
#endif
