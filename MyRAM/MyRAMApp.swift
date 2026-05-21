// MyRAMApp.swift
import SwiftUI

@main
struct MyRAMApp: App {
    var body: some Scene {
        WindowGroup {
            NotesListView(context: PersistenceManager.shared.context)
        }
    }
}
