// MyRAMApp.swift
import SwiftUI

@main
struct MyRAMApp: App {
    @AppStorage("appearanceSetting") private var appearanceSettingRaw = AppearanceSetting.system.rawValue
    private let isUITestMode = ProcessInfo.processInfo.arguments.contains("UITEST_MODE")

    init() {
        if let forcedAppearance = ProcessInfo.processInfo.environment["UITEST_FORCE_APPEARANCE"],
           AppearanceSetting(rawValue: forcedAppearance) != nil {
            UserDefaults.standard.set(forcedAppearance, forKey: "appearanceSetting")
        }
    }

    var body: some Scene {
        WindowGroup {
            NotesListView(context: PersistenceManager.shared.context)
                .preferredColorScheme(appearanceSetting.colorScheme)
                .overlay(alignment: .topLeading) {
                    if isUITestMode {
                        Color.clear
                            .frame(width: 1, height: 1)
                            .accessibilityElement(children: .ignore)
                            .accessibilityIdentifier("appearance-setting-raw")
                            .accessibilityLabel(appearanceSettingRaw)
                    }
                }
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

enum EditorChromeStyle: String, CaseIterable, Identifiable {
    case standard
    case chromeAccent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard:
            "Standard"
        case .chromeAccent:
            "Chrome Accent"
        }
    }
}
