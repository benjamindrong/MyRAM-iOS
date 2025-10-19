//
//  FoldersViewModel.swift
//  MyRAM
//
//  Created by Benjamin Drong on 10/19/25.
//

import Foundation
import SwiftData

@MainActor
final class FoldersViewModel: ObservableObject {
    private let persistence = PersistenceManager.shared

    func addFolder(name: String) {
        let folder = Folder(name: name)
        persistence.insert(folder)
    }

    func deleteFolder(_ folder: Folder) {
        persistence.delete(folder)
    }
}
