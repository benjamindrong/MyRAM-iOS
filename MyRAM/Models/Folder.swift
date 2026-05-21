//
//  Foler.swift
//  MyRAM
//
//  Created by Benjamin Drong on 10/19/25.
//

import Foundation
import SwiftData

@Model
final class Folder {
    var name: String
    @Relationship(deleteRule: .cascade) var notes: [Note] = []

    init(name: String) {
        self.name = name
    }
}
