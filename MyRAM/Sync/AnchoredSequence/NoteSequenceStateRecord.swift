import Foundation
import SwiftData

@Model
final class NoteSequenceStateRecord {
    @Attribute(.unique) var noteID: UUID
    var formatVersion: Int
    var revision: UInt64
    var visibleUTF16Count: Int
    var tombstonedUTF16Count: Int
    var payloadByteCount: Int
    var statePayloadData: Data

    // SwiftData property defaults intentionally identify pre-MYR-227 rows.
    // Programmatic construction below defaults new rows to schema 1 instead.
    var markFormatVersion: Int = 0
    var markRevision: UInt64 = 0
    var markStatePayloadData: Data = Data()

    init(
        noteID: UUID,
        formatVersion: Int,
        revision: UInt64,
        visibleUTF16Count: Int,
        tombstonedUTF16Count: Int,
        payloadByteCount: Int,
        statePayloadData: Data,
        markFormatVersion: Int = NoteStructuralFormattingPersistence.schemaVersion,
        markRevision: UInt64 = 0,
        markStatePayloadData: Data = NoteStructuralFormattingPersistence.canonicalEmptyPayload
    ) {
        self.noteID = noteID
        self.formatVersion = formatVersion
        self.revision = revision
        self.visibleUTF16Count = visibleUTF16Count
        self.tombstonedUTF16Count = tombstonedUTF16Count
        self.payloadByteCount = payloadByteCount
        self.statePayloadData = statePayloadData
        self.markFormatVersion = markFormatVersion
        self.markRevision = markRevision
        self.markStatePayloadData = markStatePayloadData
    }
}
