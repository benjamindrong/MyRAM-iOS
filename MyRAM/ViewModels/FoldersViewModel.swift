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
    private let context: ModelContext

    init(context: ModelContext = PersistenceManager.shared.context) {
        self.context = context
    }

    func addFolder(name: String) {
        let folder = Folder(name: name)
        context.insert(folder)
        try? context.save()
    }

    func deleteFolder(_ folder: Folder) {
        context.delete(folder)
        try? context.save()
    }
}
