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
            let isUnitTestMode = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            let configuration = ModelConfiguration(
                isUITestMode ? "MyRAM_UITests" : "MyRAM_Main",
                schema: Schema(MyRAMModelRegistry.models),
                isStoredInMemoryOnly: isUITestMode || isUnitTestMode
            )
            
            container = try ModelContainer(
                for: Schema(MyRAMModelRegistry.models),
                configurations: configuration
            )
            
            print("✅ Fresh SwiftData store initialized successfully")
        } catch {
            fatalError("❌ Failed to initialize SwiftData: \(error)")
        }
    }
}
