//
//  Note.swift
//  MyRAM
//
//  Created by Benjamin Drong on 10/19/25.
//

import Foundation
import SwiftData

@Model
final class Note {
    var title: String
    var content: String
    var createdAt: Date
    var modifiedAt: Date
    var folder: Folder?

    init(title: String, content: String, folder: Folder? = nil) {
        self.title = title
        self.content = content
        self.createdAt = .now
        self.modifiedAt = .now
        self.folder = folder
    }
}
