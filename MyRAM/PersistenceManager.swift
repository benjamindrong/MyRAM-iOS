// PersistenceManager.swift
import Foundation
import SwiftData

@MainActor
final class PersistenceManager {
    static let shared = PersistenceManager()

    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    private init() {
        do {
            let isUITestMode = ProcessInfo.processInfo.arguments.contains("UITEST_MODE")
            let configuration = ModelConfiguration(
                isUITestMode ? "MyRAM_UITests" : "MyRAM_Main",
                schema: Schema([Folder.self, Note.self, NotePhotoAttachment.self, PinnedThought.self]),
                isStoredInMemoryOnly: isUITestMode
            )
            
            container = try ModelContainer(
                for: Folder.self, Note.self, NotePhotoAttachment.self, PinnedThought.self,
                configurations: configuration
            )
            
            print("✅ Fresh SwiftData store initialized successfully")
        } catch {
            fatalError("❌ Failed to initialize SwiftData: \(error)")
        }
    }
}
