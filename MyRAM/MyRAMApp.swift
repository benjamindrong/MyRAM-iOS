// MyRAMApp.swift
import SwiftUI

@main
struct MyRAMApp: App {
    @AppStorage("appearanceSetting") private var appearanceSettingRaw = AppearanceSetting.system.rawValue

    var body: some Scene {
        WindowGroup {
            NotesListView(context: PersistenceManager.shared.context)
                .preferredColorScheme(appearanceSetting.colorScheme)
        }
    }

    private var appearanceSetting: AppearanceSetting {
        AppearanceSetting(rawValue: appearanceSettingRaw) ?? .system
    }
}

enum AppearanceSetting: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            "System"
        case .light:
            "Light"
        case .dark:
            "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system:
            nil
        case .light:
            .light
        case .dark:
            .dark
        }
    }
}
