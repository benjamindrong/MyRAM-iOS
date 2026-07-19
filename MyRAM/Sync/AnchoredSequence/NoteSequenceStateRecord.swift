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

    init(
        noteID: UUID,
        formatVersion: Int,
        revision: UInt64,
        visibleUTF16Count: Int,
        tombstonedUTF16Count: Int,
        payloadByteCount: Int,
        statePayloadData: Data
    ) {
        self.noteID = noteID
        self.formatVersion = formatVersion
        self.revision = revision
        self.visibleUTF16Count = visibleUTF16Count
        self.tombstonedUTF16Count = tombstonedUTF16Count
        self.payloadByteCount = payloadByteCount
        self.statePayloadData = statePayloadData
    }
}
