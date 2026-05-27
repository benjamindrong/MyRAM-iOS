//
//  Folder.swift
//  MyRAM
//

import Foundation
import SwiftData

@Model
final class Folder {
    @Attribute(.unique) var id: UUID = UUID()
    var name: String
    var createdAt: Date
    var modifiedAt: Date
    var parentFolder: Folder?
    @Relationship(deleteRule: .cascade, inverse: \Folder.parentFolder) var childFolders: [Folder] = []
    @Relationship(deleteRule: .cascade, inverse: \Note.folder) var notes: [Note] = []

    init(name: String, parentFolder: Folder? = nil) {
        self.name = name
        self.createdAt = .now
        self.modifiedAt = .now
        self.parentFolder = parentFolder
    }
}
