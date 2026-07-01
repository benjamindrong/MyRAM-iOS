#if os(macOS)
import Foundation

typealias MacSyncDeviceID = SyncBatchDeviceID
typealias MacSyncBatchID = SyncBatchID
typealias MacSyncNoteID = SyncBatchNoteID
typealias MacSyncFolderID = SyncBatchFolderID

typealias MacSyncBatch = SyncBatch
typealias MacSyncChange = SyncBatchChange
typealias MacSyncNoteCreatedChange = SyncBatchNoteCreatedChange
typealias MacSyncNoteTitleChangedChange = SyncBatchNoteTitleChangedChange
typealias MacSyncNoteBodyTextInsertedChange = SyncBatchNoteBodyTextInsertedChange
typealias MacSyncNoteBodyTextDeletedChange = SyncBatchNoteBodyTextDeletedChange
#endif
