// MyRAMApp.swift
import SwiftUI
import UIKit

@main
struct MyRAMApp: App {
    @AppStorage("appearanceSetting") private var appearanceSettingRaw = AppearanceSetting.system.rawValue
    @AppStorage("editorChromeStyle") private var editorChromeStyleRaw = EditorChromeStyle.standard.rawValue
    @StateObject private var notesState: NotesListState
#if !targetEnvironment(macCatalyst)
    @StateObject private var externalOpenDispatcher = MyRAMExternalOpenDispatcher()
    @StateObject private var widgetCoordinator: MyRAMWidgetHostCoordinator
#endif
    private let isUITestMode = ProcessInfo.processInfo.arguments.contains("UITEST_MODE")
    private let usesBareTextViewProfiling = ProcessInfo.processInfo.arguments.contains("MYR_PROFILE_BARE_TEXTVIEW")
    private let isSyncEnduranceMode = MyRAMSyncBenchmarkConfiguration.isEnduranceRequested()

    init() {
#if DEBUG && !targetEnvironment(macCatalyst)
        MyRAMSyncBenchmarkEnduranceIOSIsolation.activateOrFailIfRequested()
        if MyRAMSyncBenchmarkConfiguration.isEnduranceRequested() {
            UIApplication.shared.isIdleTimerDisabled = true
        }
#endif
        let context = PersistenceManager.shared.context
        _notesState = StateObject(wrappedValue: NotesListState(context: context))
#if !targetEnvironment(macCatalyst)
        _widgetCoordinator = StateObject(wrappedValue: MyRAMWidgetHostCoordinator(
            container: PersistenceManager.shared.container,
            observedContext: context,
            platform: .iOS
        ))
#endif

        if let forcedAppearance = ProcessInfo.processInfo.environment["UITEST_FORCE_APPEARANCE"],
           AppearanceSetting(rawValue: forcedAppearance) != nil {
            UserDefaults.standard.set(forcedAppearance, forKey: "appearanceSetting")
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if usesBareTextViewProfiling {
                    BareTextViewProfilingView()
                } else {
                    NotesListView(state: notesState)
#if !targetEnvironment(macCatalyst)
                        .environmentObject(externalOpenDispatcher)
                        .environmentObject(widgetCoordinator)
                        .onAppear {
                            if !isSyncEnduranceMode {
                                widgetCoordinator.start()
                                if notesState.bootstrapState == .ready {
                                    widgetCoordinator.publishNow()
                                }
                            }
#if DEBUG
                            MyRAMSyncBenchmarkEnduranceIOSDriver.shared.startIfNeeded(state: notesState)
#endif
                        }
                        .onChange(of: notesState.bootstrapState) { _, state in
                            guard !isSyncEnduranceMode, state == .ready else { return }
                            widgetCoordinator.publishNow()
                        }
#endif
                }
            }
                .preferredColorScheme(editorChromeStyle.colorSchemeOverride ?? appearanceSetting.colorScheme)
                .tint(editorChromeStyle.appTintColor)
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

    private var editorChromeStyle: EditorChromeStyle {
        EditorChromeStyle(rawValue: editorChromeStyleRaw) ?? .standard
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

enum WarmPaperPalette {
    static let backgroundUIColor = dynamicColor(
        light: UIColor(red: 240 / 255, green: 229 / 255, blue: 211 / 255, alpha: 1),
        dark: UIColor(red: 34 / 255, green: 29 / 255, blue: 23 / 255, alpha: 1)
    )
    static let surfaceUIColor = dynamicColor(
        light: UIColor(red: 255 / 255, green: 250 / 255, blue: 241 / 255, alpha: 1),
        dark: UIColor(red: 46 / 255, green: 39 / 255, blue: 31 / 255, alpha: 1)
    )
    static let toolbarUIColor = dynamicColor(
        light: UIColor(red: 250 / 255, green: 239 / 255, blue: 219 / 255, alpha: 1),
        dark: UIColor(red: 57 / 255, green: 47 / 255, blue: 36 / 255, alpha: 1)
    )
    static let controlUIColor = dynamicColor(
        light: UIColor(red: 236 / 255, green: 218 / 255, blue: 187 / 255, alpha: 1),
        dark: UIColor(red: 73 / 255, green: 58 / 255, blue: 43 / 255, alpha: 1)
    )
    static let accentUIColor = dynamicColor(
        light: UIColor(red: 199 / 255, green: 109 / 255, blue: 0 / 255, alpha: 1),
        dark: UIColor(red: 235 / 255, green: 159 / 255, blue: 66 / 255, alpha: 1)
    )

    static let background = Color(uiColor: backgroundUIColor)
    static let surface = Color(uiColor: surfaceUIColor)
    static let toolbar = Color(uiColor: toolbarUIColor)
    static let control = Color(uiColor: controlUIColor)
    static let accent = Color(uiColor: accentUIColor)

    private static func dynamicColor(light: UIColor, dark: UIColor) -> UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        }
    }
}

enum EditorChromeStyle: String, CaseIterable, Identifiable {
    case standard
    case chromeAccent
    case warmPaper

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard:
            "None"
        case .chromeAccent:
            "Chrome Accent"
        case .warmPaper:
            "Warm Paper"
        }
    }

    var isWarmPaper: Bool {
        self == .warmPaper
    }

    var isChromeAccent: Bool {
        self == .chromeAccent
    }

    var appTintColor: Color {
        isWarmPaper ? WarmPaperPalette.accent : .accentColor
    }

    var appBackgroundColor: Color {
        isWarmPaper ? WarmPaperPalette.background : Color(.systemGroupedBackground)
    }

    var listRowBackgroundColor: Color {
        isWarmPaper ? WarmPaperPalette.surface : Color(.secondarySystemGroupedBackground)
    }

    var toolbarFillColor: Color {
        isWarmPaper ? WarmPaperPalette.toolbar : Color(.secondarySystemGroupedBackground)
    }

    var toolbarStrokeColor: Color {
        if isWarmPaper {
            return Color(red: 136 / 255, green: 91 / 255, blue: 39 / 255).opacity(0.34)
        }

        return Color.secondary.opacity(0.3)
    }

    var toolbarControlFillColor: Color {
        isWarmPaper ? WarmPaperPalette.control : Color(.tertiarySystemFill)
    }

    var editorBackgroundColor: Color {
        isWarmPaper ? WarmPaperPalette.background : Color(.systemBackground)
    }

    var editorSurfaceColor: Color {
        Color(uiColor: editorSurfaceUIColor)
    }

    var editorSurfaceUIColor: UIColor {
        isWarmPaper ? WarmPaperPalette.surfaceUIColor : .secondarySystemBackground
    }

    var editorTintUIColor: UIColor? {
        isWarmPaper ? WarmPaperPalette.accentUIColor : nil
    }

    var editorTextUIColor: UIColor {
        .label
    }

    var colorSchemeOverride: ColorScheme? {
        nil
    }
}
