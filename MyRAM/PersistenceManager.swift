//
//  PersistenceManager.swift
//  MyRAM
//
//  Created by Benjamin Drong on 10/19/25.
//

import SwiftData
import SwiftUI

/// A lightweight wrapper around SwiftData for clean persistence access.
@MainActor
final class PersistenceManager {
    static let shared = PersistenceManager()

    /// The container that holds our SwiftData model.
    let container: ModelContainer

    /// The active model context.
    var context: ModelContext {
        container.mainContext
    }

    private init() {
        do {
            // Create a container for our models
            container = try ModelContainer(for: Folder.self, Note.self)
        } catch {
            fatalError("❌ Failed to initialize SwiftData ModelContainer: \(error)")
        }
    }

    /// Inserts a model into the context and saves.
    func insert<T: PersistentModel>(_ model: T) {
        context.insert(model)
        save()
    }

    /// Deletes a model from the context and saves.
    func delete<T: PersistentModel>(_ model: T) {
        context.delete(model)
        save()
    }

    /// Saves changes to disk, handling errors gracefully.
    func save() {
        do {
            try context.save()
        } catch {
            print("⚠️ SwiftData save error:", error)
        }
    }
}
