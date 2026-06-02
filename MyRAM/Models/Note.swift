// Note.swift
import Foundation
import SwiftData

@Model
final class Note {
    @Attribute(.unique) var id: UUID = UUID()
    var title: String
    var content: String
    @Attribute(.externalStorage) var richTextContentData: Data?
    var isPinned: Bool?
    var createdAt: Date
    var modifiedAt: Date
    var deletedAt: Date?
    var folder: Folder?
    @Relationship(deleteRule: .cascade, inverse: \NotePhotoAttachment.note)
    var photoAttachments: [NotePhotoAttachment] = []
    @Relationship(deleteRule: .cascade, inverse: \PinnedThought.note)
    var pinnedThoughts: [PinnedThought] = []

    init(title: String = "", content: String = "", folder: Folder? = nil) {
        self.title = title
        self.content = content
        self.richTextContentData = nil
        self.isPinned = false
        self.createdAt = .now
        self.modifiedAt = .now
        self.deletedAt = nil
        self.folder = folder
    }
}

@Model
final class PinnedThought {
    @Attribute(.unique) var id: UUID = UUID()
    var text: String
    var order: Int
    var isCollapsed: Bool
    var createdAt: Date
    var modifiedAt: Date
    var note: Note?

    init(text: String, order: Int, note: Note? = nil) {
        self.text = text
        self.order = order
        self.isCollapsed = false
        self.createdAt = .now
        self.modifiedAt = .now
        self.note = note
    }
}

@Model
final class NotePhotoAttachment {
    @Attribute(.unique) var id: UUID = UUID()
    @Attribute(.externalStorage) var imageData: Data
    var createdAt: Date
    var note: Note?

    init(imageData: Data, note: Note? = nil) {
        self.imageData = imageData
        self.createdAt = .now
        self.note = note
    }
}
