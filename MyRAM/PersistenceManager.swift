// PersistenceManager.swift
import SwiftData

@MainActor
final class PersistenceManager {
    static let shared = PersistenceManager()

    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    private init() {
        do {
            let configuration = ModelConfiguration(
                "MyRAM_Main",
                schema: Schema([Note.self]),
                isStoredInMemoryOnly: false
            )
            
            container = try ModelContainer(
                for: Note.self,
                configurations: configuration   // ← Removed the [ ]
            )
            
            print("✅ Fresh SwiftData store initialized successfully")
        } catch {
            fatalError("❌ Failed to initialize SwiftData: \(error)")
        }
    }
}
