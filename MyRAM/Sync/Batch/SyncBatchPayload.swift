import Foundation

typealias SyncBatchDeviceID = UUID
typealias SyncBatchID = UUID
typealias SyncBatchNoteID = UUID
typealias SyncBatchFolderID = UUID

struct SyncBatch: Codable, Equatable, Identifiable, Sendable {
    let id: SyncBatchID
    let originDeviceID: SyncBatchDeviceID
    let createdAt: Date
    let changes: [SyncBatchChange]
}

enum SyncBatchChange: Codable, Equatable, Sendable {
    case noteCreated(SyncBatchNoteCreatedChange)
    case noteTitleChanged(SyncBatchNoteTitleChangedChange)
    case noteBodyTextInserted(SyncBatchNoteBodyTextInsertedChange)
    case noteBodyTextDeleted(SyncBatchNoteBodyTextDeletedChange)
}

struct SyncBatchNoteCreatedChange: Codable, Equatable, Sendable {
    let noteID: SyncBatchNoteID
    let title: String
    let body: String
    let folderID: SyncBatchFolderID?
    let createdAt: Date
    let modifiedAt: Date
    // MYR-123 keeps rich text out of the shared positional payload so text
    // mutations cannot target stale RTF bytes.
}

struct SyncBatchNoteTitleChangedChange: Codable, Equatable, Sendable {
    let noteID: SyncBatchNoteID
    let title: String
    let modifiedAt: Date
}

struct SyncBatchNoteBodyTextInsertedChange: Codable, Equatable, Sendable {
    let noteID: SyncBatchNoteID
    let utf16Offset: Int
    let text: String
    let modifiedAt: Date
}

struct SyncBatchNoteBodyTextDeletedChange: Codable, Equatable, Sendable {
    let noteID: SyncBatchNoteID
    let utf16Offset: Int
    let utf16Length: Int
    let expectedText: String?
    let modifiedAt: Date
}
