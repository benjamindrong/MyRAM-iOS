//
//  MyRAMApp.swift
//  MyRAM
//
//  Created by Benjamin Drong on 10/18/25.
//

import SwiftUI
import SwiftData

@main
struct MyRAMApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [Folder.self, Note.self])
    }
}
