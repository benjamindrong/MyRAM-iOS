// Note.swift
import Foundation
import SwiftData

@Model
final class Note {
    @Attribute(.unique) var id: UUID = UUID()
    var title: String
    var content: String
    var createdAt: Date
    var modifiedAt: Date

    init(title: String = "", content: String = "") {
        self.title = title
        self.content = content
        self.createdAt = .now
        self.modifiedAt = .now
    }
}
